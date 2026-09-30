-- ============================================================================
-- Ronda — Login del panel: correo y contraseña, sin verificación de correo
--
-- Decisión 2026-08-22: el panel (comercio y super admin) deja de compartir el
-- teléfono+OTP de la app de consumidores. Entra con correo y contraseña,
-- **sin confirmación de correo** — `[auth.email] enable_confirmations` ya
-- estaba en `false` en config.toml, así que no hace falta tocarlo.
--
-- La cuenta la crea siempre el super admin (docs/00-BASES §2.9: "Creación de
-- cuenta: Solo desde el super admin"). No hay pantalla de autorregistro en el
-- panel — pero `enable_signup` de GoTrue sigue en `true` en config.toml
-- porque en local ese flag apaga el proveedor de correo completo, signup y
-- login juntos: no hay forma de permitir `signInWithPassword` y bloquear
-- `signUp()` por separado. La barrera real es la de siempre en este
-- proyecto: una cuenta autenticada sin rol en `merchant_users` ni
-- `platform_admins` no pasa de "esta cuenta no es de..." — identidad no es
-- autorización.
--
-- El punto técnico central: hasta ahora el único camino para entrar al panel
-- era ser antes un usuario de la app (registrado por teléfono) y que el super
-- admin te encontrara por ese teléfono. Eso nunca tuvo sentido para un cajero
-- que no es cliente de crédito de Ronda. A partir de aquí, el personal del
-- comercio y el equipo de Ronda tienen una identidad propia: una fila en
-- `auth.users` con correo y contraseña, creada directamente por una función
-- del servidor — nunca a través de `signUp()` y nunca con el service role en
-- el cliente.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. `handle_new_user()` ya no debe reventar con una cuenta sin teléfono
-- ---------------------------------------------------------------------------
-- `public.profiles` es la ficha del USUARIO de crédito: documento, nivel,
-- bloque de crédito. Una cuenta de panel (personal de comercio, equipo de
-- Ronda) no es eso y nunca debería tener una fila ahí — `merchant_users` y
-- `platform_admins` referencian `auth.users(id)` directamente, sin pasar por
-- `profiles`.
--
-- El trigger original insertaba `(id, phone)` sin condición. Con una cuenta
-- de solo-correo, `new.phone` es null y `profiles.phone_e164` es
-- `not null` — el insert fallaba y con él **toda la transacción que estaba
-- creando la cuenta**, así que hay que cortar aquí antes de tocar
-- `auth.users` desde ninguna función nueva.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.phone is not null then
    insert into public.profiles (id, phone_e164)
    values (new.id, new.phone)
    on conflict (id) do nothing;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Crear una cuenta de correo+contraseña directamente en `auth.users`
-- ---------------------------------------------------------------------------
-- No hay endpoint de admin de GoTrue disponible sin el service role, y el
-- panel nunca debe tenerlo (docs/00-BASES §3.12). La alternativa correcta en
-- Supabase autoalojado es escribir la fila igual que lo haría GoTrue: mismo
-- hash (bcrypt vía pgcrypto, el mismo mecanismo que ya usa `set_user_pin` para
-- el PIN), mismas columnas obligatorias, y `email_confirmed_at` puesto para
-- que no haga falta el paso de confirmación que el negocio no quiere.
--
-- Deliberadamente sin GRANT a `authenticated`: solo la llaman por nombre
-- otras funciones `security definer` que ya comprobaron que quien pidió el
-- alta es super_admin. Es la misma composición en capas de `audit.log()`.
create or replace function public.admin_create_auth_account(
  p_email     text,
  p_password  text,
  p_full_name text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_email   text := lower(trim(coalesce(p_email, '')));
  v_user_id uuid := gen_random_uuid();
begin
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Correo inválido' using errcode = '22023';
  end if;

  if p_password is null or length(p_password) < 8 then
    raise exception 'La contraseña debe tener al menos 8 caracteres' using errcode = '22023';
  end if;

  if exists (select 1 from auth.users where lower(email) = v_email) then
    raise exception 'Ya existe una cuenta con ese correo' using errcode = '23505';
  end if;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    -- Admiten NULL pero GoTrue las lee en structs de Go que no aceptan NULL:
    -- dejarlas vacías hace que el login falle con "Database error finding
    -- user" (mismo escollo que ya documentó seed.sql para el alta por
    -- teléfono).
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) values (
    '00000000-0000-0000-0000-000000000000',
    v_user_id, 'authenticated', 'authenticated', v_email,
    extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('full_name', nullif(trim(coalesce(p_full_name, '')), '')),
    '', '', '', ''
  );

  -- No estrictamente necesario para que `signInWithPassword` funcione, pero
  -- sin esto la cuenta queda inconsistente con lo que `signUp()` habría
  -- creado — y algunas vistas de Auth Admin en el dashboard de Supabase
  -- esperan una identidad por proveedor.
  insert into auth.identities (
    id, provider_id, user_id, identity_data, provider,
    created_at, updated_at, last_sign_in_at
  ) values (
    gen_random_uuid(), v_user_id, v_user_id,
    jsonb_build_object('sub', v_user_id::text, 'email', v_email),
    'email', now(), now(), now()
  );

  return v_user_id;
end;
$$;

revoke all on function public.admin_create_auth_account(text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Alta de personal de comercio — ahora crea la cuenta, no la busca
-- ---------------------------------------------------------------------------
drop function if exists public.admin_add_merchant_staff(uuid, text, public.merchant_role, uuid);

create or replace function public.admin_add_merchant_staff(
  p_merchant_id uuid,
  p_email       text,
  p_password    text,
  p_full_name   text,
  p_role        public.merchant_role,
  p_branch_id   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_user   uuid;
  v_branch uuid := p_branch_id;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede asignar personal' using errcode = '42501';
  end if;

  v_user := public.admin_create_auth_account(p_email, p_password, p_full_name);

  -- Un cajero siempre trabaja en una sucursal concreta (lo exige el check
  -- cajero_requires_branch). Si no se indica, va a la principal.
  if p_role = 'cajero' and v_branch is null then
    select id into v_branch from public.merchant_branches
    where merchant_id = p_merchant_id and is_default;
  end if;

  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_user, p_merchant_id, v_branch, p_role)
  on conflict (user_id, merchant_id, branch_id) do update
    set role = excluded.role, is_active = true;

  perform audit.log(v_actor, 'merchant.staff_added', p_merchant_id,
    jsonb_build_object('user_id', v_user, 'email', lower(trim(p_email)), 'role', p_role));

  return jsonb_build_object('ok', true, 'user_id', v_user, 'branch_id', v_branch);
end;
$$;

revoke all on function public.admin_add_merchant_staff(uuid, text, text, text, public.merchant_role, uuid)
  from public, anon;
grant execute on function public.admin_add_merchant_staff(uuid, text, text, text, public.merchant_role, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Alta del equipo de Ronda — mismo cambio
-- ---------------------------------------------------------------------------
drop function if exists public.admin_set_platform_admin(text, public.platform_role, text);

create or replace function public.admin_set_platform_admin(
  p_email     text,
  p_password  text,
  p_full_name text,
  p_role      public.platform_role
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_user  uuid;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super_admin puede dar de alta al equipo'
      using errcode = '42501';
  end if;

  v_user := public.admin_create_auth_account(p_email, p_password, p_full_name);

  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_user, p_role, nullif(trim(coalesce(p_full_name, '')), ''), true);

  perform audit.log(v_actor, 'platform_admin.set', v_user, jsonb_build_object(
    'email', lower(trim(p_email)), 'role', p_role, 'full_name', p_full_name
  ));

  return v_user;
end;
$$;

revoke all on function public.admin_set_platform_admin(text, text, text, public.platform_role)
  from public, anon;
grant execute on function public.admin_set_platform_admin(text, text, text, public.platform_role)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Las lecturas que mostraban teléfono ahora muestran correo
-- ---------------------------------------------------------------------------
-- El personal nuevo no tiene `profiles` (§1), así que un INNER JOIN contra
-- esa tabla lo dejaría fuera de su propia lista de personal. El correo vive
-- en `auth.users`, legible aquí porque la función es `security definer`.

create or replace function public.admin_merchant_detail(p_merchant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_terms public.merchant_settlement_terms%rowtype;
  v_staff jsonb;
  v_owed  numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_terms from public.merchant_settlement_terms
  where merchant_id = p_merchant_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', mu.user_id,
    'name', coalesce(p.full_name, au.raw_user_meta_data ->> 'full_name'),
    'email', au.email,
    'phone', p.phone_e164,
    'role', mu.role,
    'branch', b.name
  ) order by mu.created_at), '[]'::jsonb) into v_staff
  from public.merchant_users mu
  join auth.users au on au.id = mu.user_id
  left join public.profiles p on p.id = mu.user_id
  left join public.merchant_branches b on b.id = mu.branch_id
  where mu.merchant_id = p_merchant_id and mu.is_active;

  select coalesce(sum(amount_usd), 0) into v_owed
  from public.settlements
  where merchant_id = p_merchant_id and status = 'pending';

  return jsonb_build_object(
    'terms', jsonb_build_object(
      'upfront_pct', v_terms.upfront_pct,
      'per_installment_pct', v_terms.per_installment_pct,
      'commission_pct', v_terms.commission_pct,
      'policy', v_terms.policy
    ),
    'staff', v_staff,
    'pending_usd', v_owed
  );
end;
$$;

revoke all on function public.admin_merchant_detail(uuid) from public, anon;
grant execute on function public.admin_merchant_detail(uuid) to authenticated;

-- Cambia `phone_e164` por `email` en la salida: no se puede hacer con
-- CREATE OR REPLACE cuando cambia el nombre de una columna de la tabla de
-- retorno, así que hay que soltarla primero.
drop function if exists public.admin_platform_team();

create or replace function public.admin_platform_team()
returns table (
  user_id     uuid,
  full_name   text,
  email       text,
  role        text,
  is_active   boolean,
  created_at  timestamptz,
  action_count integer,
  last_action_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  select pa.user_id, pa.full_name, au.email::text, pa.role::text, pa.is_active, pa.created_at,
         coalesce(a.cnt, 0)::integer, a.last_at
  from public.platform_admins pa
  join auth.users au on au.id = pa.user_id
  left join (
    -- Alias explícito: `created_at` es también un OUT parameter de esta
    -- función, y sin calificar la columna Postgres no sabe a cuál se refiere.
    select aa.actor as uid, count(*)::integer as cnt, max(aa.created_at) as last_at
    from audit.admin_actions aa group by 1
  ) a on a.uid = pa.user_id
  order by pa.is_active desc, pa.created_at;
end;
$$;

revoke all on function public.admin_platform_team() from public, anon;
grant execute on function public.admin_platform_team() to authenticated;
