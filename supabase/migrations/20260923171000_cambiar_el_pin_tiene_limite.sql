-- ============================================================================
-- Ronda — Cambiar el PIN tiene límite, y no borra el bloqueo
--
-- `set_user_pin` está concedida a `authenticated`, no pide el PIN actual y
-- hashea con bcrypt cada vez que se la llama. Sin límite, una sola sesión con
-- 10-50 llamadas en paralelo llena la CPU de la base y el pool de PostgREST:
-- es el vector de un solo usuario contra todo el país. Y al final borraba
-- `pin_attempts`, así que también anulaba el bloqueo por intentos: quien
-- estuviera bloqueado por fallar el PIN podía poner uno nuevo y seguir.
--
-- Qué cambia:
--   · Como mucho CINCO PINes guardados por persona en una ventana de DIEZ
--     minutos. Crear el PIN, recuperarlo o cambiarlo es una llamada por vez;
--     cinco en diez minutos ya no es alguien que se equivocó.
--   · El contador vive en la fila de `pin_attempts` y se lee con `for update`,
--     igual que `verify_user_pin`: las llamadas de una misma persona se
--     ponen en fila, y la sexta se rechaza ANTES del bcrypt, sin gastar CPU.
--   · Las validaciones baratas (formato, PIN trivial) van antes del contador:
--     equivocarse al elegir no gasta cupo.
--   · Ya no se borra `pin_attempts`. Ningún camino de la app lo necesitaba:
--       - alta: la persona es nueva y no tiene fila;
--       - «¿Olvidaste tu PIN?»: pasa por el OTP, y `verifyOtp` llama a
--         `clear_pin_lockout` antes de llegar aquí;
--       - Perfil › Cambiar PIN: exige el PIN actual con `verify_user_pin`,
--         que deja los fallos en cero al acertar.
--     El bloqueo lo levantan ahora solo un PIN correcto o un OTP.
--
-- El rechazo va con 22023 a propósito: es el código que la app ya enseña tal
-- cual (`setPin` en features/auth/pin.ts), así que las versiones instaladas
-- dicen por qué sin esperar a una actualización.
--
-- Queda abierto, y es otro arreglo: `clear_pin_lockout` sigue sin pedir un OTP
-- reciente (auditoría de pagos del 2026-09-11, A-1).
-- ============================================================================

alter table public.pin_attempts
  add column if not exists pin_set_count smallint not null default 0,
  add column if not exists pin_set_window_started_at timestamptz;

comment on column public.pin_attempts.pin_set_count is
  'PINes guardados por set_user_pin dentro de la ventana que empieza en pin_set_window_started_at.';

-- Define o cambia el PIN del usuario autenticado.
create or replace function public.set_user_pin(p_pin text)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  c_window   constant interval := interval '10 minutes';
  c_max      constant smallint := 5;
  v_user     uuid := auth.uid();
  v_attempts public.pin_attempts%rowtype;
  v_minutes  integer;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if p_pin !~ '^\d{4}$' then
    raise exception 'El PIN debe ser de 4 dígitos' using errcode = '22023';
  end if;

  -- PINs trivialmente adivinables. Bloquearlos aquí, en el servidor, evita
  -- depender de que el cliente valide.
  --
  -- La lista crece respecto a la de 6 dígitos porque con 4 el problema es
  -- otro: no es que el espacio sea pequeño —el bloqueo por intentos se ocupa
  -- de eso—, es que las elecciones de la gente se amontonan en un puñado de
  -- combinaciones. Aquí están las de siempre: repeticiones, escaleras arriba
  -- y abajo, pares alternos y las dos rectas del teclado (2580 / 0852).
  if p_pin in ('0000','1111','2222','3333','4444','5555','6666','7777',
               '8888','9999','1234','4321','0123','3210','1212','2121',
               '1122','2211','1313','1010','2580','0852','6969','1004')
  then
    raise exception 'Ese PIN es demasiado fácil de adivinar' using errcode = '22023';
  end if;

  -- El cupo, antes del bcrypt. El `for update` pone en fila las llamadas en
  -- paralelo de la misma persona: sin él, las cincuenta leerían el mismo
  -- contador y pasarían todas.
  insert into public.pin_attempts (user_id) values (v_user)
  on conflict (user_id) do nothing;

  select * into v_attempts
  from public.pin_attempts
  where user_id = v_user
  for update;

  if v_attempts.pin_set_window_started_at is null
     or v_attempts.pin_set_window_started_at <= now() - c_window
  then
    update public.pin_attempts
      set pin_set_count = 1, pin_set_window_started_at = now()
    where user_id = v_user;
  elsif v_attempts.pin_set_count >= c_max then
    v_minutes := greatest(1, ceil(extract(epoch from
      (v_attempts.pin_set_window_started_at + c_window - now())) / 60)::int);
    raise exception 'Cambiaste tu PIN demasiadas veces seguidas. Intenta de nuevo en %.',
      case when v_minutes = 1 then 'un minuto' else v_minutes || ' minutos' end
      using errcode = '22023';
  else
    update public.pin_attempts
      set pin_set_count = pin_set_count + 1
    where user_id = v_user;
  end if;

  insert into public.user_pins (user_id, pin_hash, updated_at)
  values (
    v_user,
    -- Coste 10: el mismo que el rehash de `verify_user_pin`
    -- (20260923170000_el_pin_se_guarda_a_coste_diez.sql).
    extensions.crypt(p_pin || public.pin_pepper(), extensions.gen_salt('bf', 10)),
    now()
  )
  on conflict (user_id) do update
    set pin_hash = excluded.pin_hash,
        updated_at = now();

  -- `pin_attempts` NO se limpia aquí: guardar un PIN no prueba nada sobre
  -- quién lo guarda. Ver la cabecera.

  update public.profiles
    set status = case when status = 'pending_pin' then 'active' else status end,
        updated_at = now()
  where id = v_user;
end;
$$;

revoke all on function public.set_user_pin(text) from public, anon;
grant execute on function public.set_user_pin(text) to authenticated;
