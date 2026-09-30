-- ============================================================================
-- Ronda — Núcleo de identidad: perfiles, PIN, dispositivos y niveles.
--
-- Principios:
--   * El PIN nunca sale del servidor en claro ni se verifica en el cliente.
--   * Todo acceso del cliente pasa por RLS. Las funciones sensibles son
--     SECURITY DEFINER con search_path fijo.
--   * La app móvil LEE con RLS; las escrituras sensibles van por RPC.
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Niveles de gamificación
-- ---------------------------------------------------------------------------
-- Parametrizable desde el super admin: los límites y requisitos NO se
-- hardcodean en la app.

create table if not exists public.levels (
  level                smallint primary key check (level between 1 and 5),
  monthly_limit_usd    numeric(18,4) not null check (monthly_limit_usd >= 0),
  required_spend_usd   numeric(18,4) not null default 0 check (required_spend_usd >= 0),
  required_months      smallint      not null default 0 check (required_months >= 0),
  -- Los niveles 4 y 5 existen en el esquema pero salen como "próximamente"
  -- hasta que se definan sus reglas.
  is_active            boolean       not null default true,
  label                text          not null,
  updated_at           timestamptz   not null default now()
);

comment on table public.levels is
  'Configuración de niveles. Editable desde el super admin; la app la lee.';

insert into public.levels (level, monthly_limit_usd, required_spend_usd, required_months, is_active, label)
values
  (1,  50.0000,   0.0000, 0, true,  'Nivel 1'),
  (2, 100.0000, 200.0000, 1, true,  'Nivel 2'),
  (3, 200.0000, 600.0000, 2, true,  'Nivel 3'),
  (4,   0.0000,   0.0000, 0, false, 'Nivel 4'),
  (5,   0.0000,   0.0000, 0, false, 'Nivel 5')
on conflict (level) do nothing;

alter table public.levels enable row level security;

-- Cualquier usuario autenticado puede leer la tabla de niveles: la app muestra
-- la escalera completa como incentivo.
create policy "levels_read_authenticated"
  on public.levels for select
  to authenticated
  using (true);

-- ---------------------------------------------------------------------------
-- Perfiles
-- ---------------------------------------------------------------------------

create type public.profile_status as enum (
  'pending_kyc',      -- registrado, sin verificar identidad
  'pending_pin',      -- KYC listo, falta definir PIN
  'active',           -- operativo
  'frozen',           -- saldo congelado por mora (< 15 días)
  'suspended',        -- bajado de nivel y bloqueado (> 15 días de mora)
  'expelled'          -- fuera del sistema (> 30 días de mora)
);

create table if not exists public.profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  phone_e164       text not null unique,
  full_name        text,
  document_number  text unique,
  birth_date       date,
  status           public.profile_status not null default 'pending_kyc',
  level            smallint not null default 1 references public.levels(level),
  -- Marca interna que sobrevive a la expulsión: si un cédula vuelve a
  -- intentar registrarse, queremos saberlo.
  is_blacklisted   boolean not null default false,
  blacklist_reason text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

comment on column public.profiles.document_number is
  'Cédula. Único en todo el sistema: una persona, una cuenta.';

create index if not exists profiles_status_idx on public.profiles (status);
create index if not exists profiles_document_idx on public.profiles (document_number);

alter table public.profiles enable row level security;

create policy "profiles_read_own"
  on public.profiles for select
  to authenticated
  using (id = (select auth.uid()));

-- Deliberadamente NO hay política de INSERT/UPDATE para el cliente.
-- El perfil lo crea un trigger y lo actualizan funciones SECURITY DEFINER:
-- un usuario no puede cambiarse el nivel ni el estado.

-- Crear el perfil automáticamente al registrarse.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, phone_e164)
  values (new.id, new.phone)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- PIN de seguridad
-- ---------------------------------------------------------------------------
-- Hash con bcrypt (pgcrypto) más un "pepper" del servidor.
--
-- Por qué bcrypt y no Argon2id: el PIN son 6 dígitos (10^6 combinaciones), así
-- que la fortaleza real no viene del algoritmo sino del bloqueo por intentos,
-- que aplicamos abajo de forma estricta. bcrypt mantiene toda la verificación
-- dentro de una transacción de Postgres, sin depender de una Edge Function.
--
-- El pepper vive en Vault, no en la tabla: una filtración de la base de datos
-- sola no permite atacar los hashes por fuerza bruta.

create table if not exists public.user_pins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  pin_hash   text not null,
  updated_at timestamptz not null default now()
);

alter table public.user_pins enable row level security;
-- Sin políticas: la tabla es inaccesible desde el cliente por completo.

create table if not exists public.pin_attempts (
  user_id         uuid primary key references auth.users(id) on delete cascade,
  failed_count    smallint not null default 0,
  locked_until    timestamptz,
  -- Tras demasiados fallos exigimos volver a verificar por OTP: el PIN solo
  -- ya no basta.
  requires_otp    boolean not null default false,
  last_attempt_at timestamptz
);

alter table public.pin_attempts enable row level security;

-- Lee el pepper de Vault. Si no está configurado, falla ruidosamente en vez de
-- hashear sin pepper: un pepper vacío en producción sería un fallo silencioso.
create or replace function public.pin_pepper()
returns text
language plpgsql
security definer
set search_path = public, extensions, vault, pg_temp
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret
  from vault.decrypted_secrets
  where name = 'pin_pepper'
  limit 1;

  if v_secret is null or length(v_secret) < 16 then
    raise exception 'Falta el secreto pin_pepper en Vault (mínimo 16 caracteres)';
  end if;

  return v_secret;
end;
$$;

revoke all on function public.pin_pepper() from public, anon, authenticated;

-- Define o cambia el PIN del usuario autenticado.
create or replace function public.set_user_pin(p_pin text)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if p_pin !~ '^\d{6}$' then
    raise exception 'El PIN debe ser de 6 dígitos' using errcode = '22023';
  end if;

  -- PINs trivialmente adivinables. Bloquearlos aquí, en el servidor, evita
  -- depender de que el cliente valide.
  if p_pin in ('000000','111111','222222','333333','444444','555555',
               '666666','777777','888888','999999','123456','654321',
               '012345','543210')
  then
    raise exception 'Ese PIN es demasiado fácil de adivinar' using errcode = '22023';
  end if;

  insert into public.user_pins (user_id, pin_hash, updated_at)
  values (
    v_user,
    extensions.crypt(p_pin || public.pin_pepper(), extensions.gen_salt('bf', 12)),
    now()
  )
  on conflict (user_id) do update
    set pin_hash = excluded.pin_hash,
        updated_at = now();

  -- Un PIN nuevo limpia el historial de bloqueos.
  delete from public.pin_attempts where user_id = v_user;

  update public.profiles
    set status = case when status = 'pending_pin' then 'active' else status end,
        updated_at = now()
  where id = v_user;
end;
$$;

grant execute on function public.set_user_pin(text) to authenticated;

-- Verifica el PIN aplicando bloqueo progresivo.
-- Devuelve jsonb para poder informar al cliente cuánto falta del bloqueo sin
-- usar excepciones para el flujo normal de error.
create or replace function public.verify_user_pin(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user     uuid := auth.uid();
  v_hash     text;
  v_attempts public.pin_attempts%rowtype;
  v_ok       boolean;
  v_failed   smallint;
  v_lock     timestamptz;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- Serializa los intentos concurrentes del mismo usuario: sin esto, N
  -- peticiones en paralelo consumirían un solo intento.
  insert into public.pin_attempts (user_id) values (v_user)
  on conflict (user_id) do nothing;

  select * into v_attempts
  from public.pin_attempts
  where user_id = v_user
  for update;

  if v_attempts.locked_until is not null and v_attempts.locked_until > now() then
    return jsonb_build_object(
      'ok', false,
      'reason', 'locked',
      'retry_after_seconds', ceil(extract(epoch from (v_attempts.locked_until - now())))::int,
      'requires_otp', v_attempts.requires_otp
    );
  end if;

  if v_attempts.requires_otp then
    return jsonb_build_object('ok', false, 'reason', 'requires_otp', 'requires_otp', true);
  end if;

  select pin_hash into v_hash from public.user_pins where user_id = v_user;
  if v_hash is null then
    return jsonb_build_object('ok', false, 'reason', 'no_pin_set');
  end if;

  v_ok := (extensions.crypt(p_pin || public.pin_pepper(), v_hash) = v_hash);

  if v_ok then
    update public.pin_attempts
      set failed_count = 0, locked_until = null,
          requires_otp = false, last_attempt_at = now()
    where user_id = v_user;

    return jsonb_build_object('ok', true);
  end if;

  v_failed := v_attempts.failed_count + 1;

  -- Escalada: 3 fallos → 30s, 5 → 5min, 7 → exige OTP.
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
      case when v_lock is null then 0
           else ceil(extract(epoch from (v_lock - now())))::int end,
    'requires_otp', v_failed >= 7
  );
end;
$$;

grant execute on function public.verify_user_pin(text) to authenticated;

-- Indica si el usuario ya tiene PIN, sin exponer la tabla.
create or replace function public.has_user_pin()
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select exists (select 1 from public.user_pins where user_id = auth.uid());
$$;

grant execute on function public.has_user_pin() to authenticated;

-- ---------------------------------------------------------------------------
-- Dispositivos
-- ---------------------------------------------------------------------------
-- Ligar la sesión al dispositivo: un refresh token robado no sirve en otro
-- teléfono, y entrar desde un aparato nuevo obliga a pasar por OTP.

create table if not exists public.user_devices (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  device_hash   text not null,
  device_name   text,
  platform      text,
  is_trusted    boolean not null default false,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  unique (user_id, device_hash)
);

create index if not exists user_devices_user_idx on public.user_devices (user_id);

alter table public.user_devices enable row level security;

create policy "devices_read_own"
  on public.user_devices for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Registra el dispositivo actual. Devuelve true si ya era conocido y de
-- confianza: así el cliente sabe si puede ir directo al PIN o pedir OTP.
create or replace function public.register_device(
  p_device_hash text,
  p_device_name text default null,
  p_platform    text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user    uuid := auth.uid();
  v_trusted boolean;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if p_device_hash is null or length(p_device_hash) < 8 then
    raise exception 'device_hash inválido' using errcode = '22023';
  end if;

  insert into public.user_devices (user_id, device_hash, device_name, platform, is_trusted)
  values (v_user, p_device_hash, p_device_name, p_platform, true)
  on conflict (user_id, device_hash) do update
    set last_seen_at = now(),
        device_name = coalesce(excluded.device_name, public.user_devices.device_name)
  returning is_trusted into v_trusted;

  return coalesce(v_trusted, false);
end;
$$;

grant execute on function public.register_device(text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- updated_at automático
-- ---------------------------------------------------------------------------

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();
