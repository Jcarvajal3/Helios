-- ============================================================================
-- Login sin OTP en dispositivos de confianza.
--
-- Decisión de producto (2026-08-22): un dispositivo ya marcado como confiable
-- en user_devices (ver register_device en 20260821210000_auth_core.sql) puede
-- entrar solo con PIN, sin pasar por OTP. Supabase Auth (GoTrue) solo emite
-- sesiones nuevas por OTP, password u OAuth — no existe un "verifica esto por
-- RPC y dame una sesión". Para lograrlo sin tocar tablas internas de auth.*,
-- el PIN se sincroniza como password nativo de Supabase Auth al crearlo
-- (features/auth/pin.ts#setPin llama a supabase.auth.updateUser además de
-- set_user_pin) y el login en dispositivo confiable hace
-- signInWithPassword({ phone, password: pin }) directo contra GoTrue.
--
-- ⚠️ Consecuencia de seguridad: el comentario de la sección "PIN de seguridad"
-- de 20260821210000_auth_core.sql dice que la fortaleza del PIN de 6 dígitos
-- viene del bloqueo por intentos, no del algoritmo. Ese bloqueo (verify_user_pin)
-- corre dentro de la misma transacción que valida el hash — pero
-- signInWithPassword lo resuelve GoTrue, que no conoce pin_attempts. Aquí
-- replicamos la misma escalada 3/5/7 a partir de lo que el cliente reporta
-- después de cada intento fallido, pero un cliente que no juegue limpio podría
-- no reportarlo e insistir contra GoTrue directamente. El freno duro para ese
-- camino pasa a ser el rate limit de Auth del proyecto (Dashboard →
-- Authentication → Rate Limits), no esta tabla. Decisión aceptada
-- explícitamente para no tener que desplegar una Edge Function nueva.
-- ============================================================================

-- Decide si el teléfono + dispositivo puede saltar directo al PIN.
-- Responde 'otp' tanto si el teléfono no existe como si el dispositivo no es
-- de confianza, no hay PIN creado, o ya está bloqueado — para no delatar cuál
-- de esos casos es el real (evita usar esto como oráculo de qué números
-- tienen cuenta).
create or replace function public.check_device_login(p_phone text, p_device_hash text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user     uuid;
  v_attempts public.pin_attempts%rowtype;
begin
  if p_phone is null or p_device_hash is null or length(p_device_hash) < 8 then
    return 'otp';
  end if;

  select id into v_user from public.profiles where phone_e164 = p_phone;
  if v_user is null then
    return 'otp';
  end if;

  if not exists (
    select 1 from public.user_devices
    where user_id = v_user and device_hash = p_device_hash and is_trusted
  ) then
    return 'otp';
  end if;

  if not exists (select 1 from public.user_pins where user_id = v_user) then
    return 'otp';
  end if;

  select * into v_attempts from public.pin_attempts where user_id = v_user;
  if found and (
    v_attempts.requires_otp
    or (v_attempts.locked_until is not null and v_attempts.locked_until > now())
  ) then
    return 'otp';
  end if;

  return 'pin';
end;
$$;

-- anon puede llamarla: se invoca antes de que exista sesión. A diferencia de
-- set_user_pin/verify_user_pin (revocadas de anon en 20260821213000 por el
-- costo de CPU de bcrypt), esta función solo hace lecturas indexadas — no hay
-- vector de agotamiento de CPU al exponerla.
revoke all on function public.check_device_login(text, text) from public;
grant execute on function public.check_device_login(text, text) to anon, authenticated;

-- Registra un intento fallido de login por PIN vía signInWithPassword, donde
-- Postgres nunca ve el PIN real. Comparte pin_attempts (por user_id) con
-- verify_user_pin, así que un bloqueo cuenta para ambos caminos.
create or replace function public.record_failed_pin_login(p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user     uuid;
  v_attempts public.pin_attempts%rowtype;
  v_failed   smallint;
  v_lock     timestamptz;
begin
  select id into v_user from public.profiles where phone_e164 = p_phone;

  -- Teléfono desconocido: misma forma de respuesta que un fallo real, para no
  -- servir de oráculo de qué números tienen cuenta.
  if v_user is null then
    return jsonb_build_object(
      'ok', false, 'reason', 'wrong_pin',
      'attempts_left', 6, 'retry_after_seconds', 0, 'requires_otp', false
    );
  end if;

  insert into public.pin_attempts (user_id) values (v_user)
  on conflict (user_id) do nothing;

  select * into v_attempts from public.pin_attempts where user_id = v_user for update;

  v_failed := v_attempts.failed_count + 1;

  -- Misma escalada que verify_user_pin: 3 fallos → 30s, 5 → 5min, 7 → OTP.
  v_lock := case
    when v_failed >= 7 then now() + interval '15 minutes'
    when v_failed >= 5 then now() + interval '5 minutes'
    when v_failed >= 3 then now() + interval '30 seconds'
    else null
  end;

  update public.pin_attempts
    set failed_count = v_failed,
        locked_until = v_lock,
        requires_otp = (v_failed >= 7),
        last_attempt_at = now()
  where user_id = v_user;

  return jsonb_build_object(
    'ok', false,
    'reason', 'wrong_pin',
    'attempts_left', greatest(0, 7 - v_failed),
    'retry_after_seconds',
      case when v_lock is null then 0 else ceil(extract(epoch from (v_lock - now())))::int end,
    'requires_otp', v_failed >= 7
  );
end;
$$;

revoke all on function public.record_failed_pin_login(text) from public;
grant execute on function public.record_failed_pin_login(text) to anon, authenticated;

-- Limpia el historial de bloqueos tras un login por PIN exitoso.
-- signInWithPassword ya deja sesión activa en este punto, así que va por
-- auth.uid() como el resto de las funciones autenticadas.
create or replace function public.clear_pin_lockout()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  update public.pin_attempts
    set failed_count = 0, locked_until = null, requires_otp = false, last_attempt_at = now()
  where user_id = v_user;
end;
$$;

revoke all on function public.clear_pin_lockout() from public, anon;
grant execute on function public.clear_pin_lockout() to authenticated;
