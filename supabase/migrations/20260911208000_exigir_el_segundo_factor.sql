-- ============================================================================
-- Ronda — Exigir el segundo factor
--
-- El panel está en una URL pública y mueve dinero: aprueba pagos, registra
-- transferencias a locales, cambia cupos y expulsa gente. Entrar con correo y
-- contraseña significa que la seguridad de todo eso es la de la contraseña más
-- débil del equipo.
--
-- Activar el segundo factor ya se puede desde el panel. Lo que falta es
-- **exigirlo**, y eso es una comprobación aquí: que el token de la sesión tenga
-- nivel `aal2`, que es como Supabase marca una sesión que pasó por el segundo
-- factor.
--
-- ---------------------------------------------------------------------------
-- Por qué nace apagada
-- ---------------------------------------------------------------------------
-- Encender la exigencia antes de que todo el equipo lo tenga activado **deja a
-- todos fuera del panel a la vez**, incluido quien tendría que encenderlo. Y no
-- hay forma de arreglarlo desde dentro.
--
-- Así que el interruptor nace en `false` y el super admin lo enciende cuando
-- `admin_platform_team` dice que todos tienen el suyo. La pantalla no deja
-- encenderlo mientras quede alguien sin él, y aquí se comprueba otra vez:
-- una regla que solo vive en la pantalla no es una regla.
--
-- ---------------------------------------------------------------------------
-- Y la sesión que ya estaba abierta
-- ---------------------------------------------------------------------------
-- Una sesión abierta antes de activar el factor sigue siendo `aal1` hasta que
-- se vuelve a entrar. Es correcto que no valga: si valiera, una sesión robada
-- ayer seguiría sirviendo hoy. El panel lo dice con esas palabras en vez de
-- devolver un error críptico.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El interruptor
-- ---------------------------------------------------------------------------

create table if not exists public.platform_security (
  -- Fila única, como `platform_maintenance`. El check sobre la clave lo
  -- garantiza sin que nadie tenga que acordarse de filtrar.
  id          boolean primary key default true check (id),
  require_mfa boolean not null default false,
  updated_by  uuid references auth.users (id),
  updated_at  timestamptz not null default now()
);

insert into public.platform_security (id) values (true) on conflict (id) do nothing;

comment on table public.platform_security is
  'Nace con require_mfa en false a proposito: encenderlo antes de que todo el equipo tenga su segundo factor deja a todos fuera del panel a la vez, incluido quien tendria que apagarlo.';

alter table public.platform_security enable row level security;
revoke all on table public.platform_security from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Quién tiene el suyo
-- ---------------------------------------------------------------------------

create or replace function public.helios_has_mfa(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = auth, public, pg_temp
as $fn$
  select exists (
    select 1 from auth.mfa_factors f
    where f.user_id = p_user and f.status = 'verified'
  );
$fn$;

revoke all on function public.helios_has_mfa(uuid) from public, anon;
grant execute on function public.helios_has_mfa(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. La puerta
-- ---------------------------------------------------------------------------
-- `is_platform_admin()` la comprueban las RLS y **todas** las RPC del panel, así
-- que es el único sitio donde hace falta poner esto. Cuando la exigencia está
-- encendida, una sesión de un solo factor deja de ser admin — y todo el panel
-- responde lo mismo que le responde a alguien que no es del equipo.

create or replace function public.is_platform_admin()
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_req  boolean;
  v_aal  text;
begin
  if v_user is null then
    return false;
  end if;

  if not exists (
    select 1 from public.platform_admins
    where user_id = v_user and is_active
  ) then
    return false;
  end if;

  select require_mfa into v_req from public.platform_security where id;

  if not coalesce(v_req, false) then
    return true;
  end if;

  -- El nivel de la sesión, tal y como lo pone Supabase en el token. `aal2`
  -- quiere decir que pasó por el segundo factor en ESTA sesión: una abierta
  -- antes de activarlo sigue siendo `aal1`, y tiene que dejar de valer.
  v_aal := coalesce(
    current_setting('request.jwt.claims', true)::jsonb ->> 'aal',
    'aal1'
  );

  return v_aal = 'aal2';
exception when others then
  -- Un token sin `claims` legibles —una llamada desde el propio servidor, por
  -- ejemplo— no puede dar acceso por accidente cuando la exigencia está
  -- encendida.
  return false;
end;
$$;

comment on function public.is_platform_admin() is
  'Si quien llama es del equipo de Helios. Cuando platform_security.require_mfa esta encendido, exige ademas que la sesion sea de nivel aal2: una sesion de un solo factor deja de ser admin.';

revoke all on function public.is_platform_admin() from public, anon;
grant execute on function public.is_platform_admin() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. El estado, y el interruptor
-- ---------------------------------------------------------------------------

create or replace function public.admin_security_status()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
stable
as $$
declare
  v_req    boolean;
  v_total  integer;
  v_con    integer;
  v_rows   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select require_mfa into v_req from public.platform_security where id;

  select
    count(*)::integer,
    count(*) filter (where public.helios_has_mfa(t.user_id))::integer
  into v_total, v_con
  from public.platform_admins t
  where t.is_active;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.full_name), '[]'::jsonb)
  into v_rows
  from (
    select
      t.user_id,
      t.full_name,
      u.email::text as email,
      t.role::text as role,
      public.helios_has_mfa(t.user_id) as has_mfa
    from public.platform_admins t
    left join auth.users u on u.id = t.user_id
    where t.is_active
  ) q;

  return jsonb_build_object(
    'require_mfa', coalesce(v_req, false),
    'team_total', v_total,
    'team_with_mfa', v_con,
    -- Se puede encender solo cuando no queda nadie sin él. La pantalla lo usa
    -- para apagar el interruptor y decir por qué.
    'can_require', v_total > 0 and v_con = v_total,
    'members', v_rows
  );
end;
$$;

create or replace function public.admin_set_require_mfa(p_require boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_total integer;
  v_con   integer;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede tocar la seguridad del panel'
      using errcode = '42501';
  end if;

  if p_require then
    select
      count(*)::integer,
      count(*) filter (where public.helios_has_mfa(t.user_id))::integer
    into v_total, v_con
    from public.platform_admins t
    where t.is_active;

    -- La red que impide dejar al equipo fuera. Vive aquí y no solo en la
    -- pantalla: una regla que solo vive en la pantalla no es una regla.
    if v_con < v_total then
      raise exception 'Todavía hay % de % personas del equipo sin segundo factor. Que lo activen antes de exigirlo.',
        v_total - v_con, v_total using errcode = '22023';
    end if;

    -- Y quien lo enciende tiene que estar entrando con el suyo, o se queda
    -- fuera en el mismo instante en que lo enciende.
    if coalesce(
      current_setting('request.jwt.claims', true)::jsonb ->> 'aal', 'aal1'
    ) <> 'aal2' then
      raise exception 'Tu sesión es de un solo factor. Vuelve a entrar con el segundo factor antes de exigirlo.'
        using errcode = '22023';
    end if;
  end if;

  update public.platform_security
  set require_mfa = p_require, updated_by = v_actor, updated_at = now()
  where id;

  perform audit.log(v_actor, 'security.require_mfa', null,
    jsonb_build_object('require_mfa', p_require));

  return jsonb_build_object('ok', true, 'require_mfa', p_require);
end;
$$;

comment on function public.admin_set_require_mfa(boolean) is
  'Enciende o apaga la exigencia del segundo factor. No deja encenderla si queda alguien del equipo sin el, ni si la sesion de quien la enciende es de un solo factor.';

revoke all on function public.admin_security_status() from public, anon;
revoke all on function public.admin_set_require_mfa(boolean) from public, anon;
grant execute on function public.admin_security_status() to authenticated;
grant execute on function public.admin_set_require_mfa(boolean) to authenticated;
