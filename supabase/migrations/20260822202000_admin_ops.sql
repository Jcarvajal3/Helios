-- ============================================================================
-- Ronda — Super admin: transacciones, bitácora y configuración
--
-- Cierra las tres filas que quedaban en blanco en docs/00-BASES §3.12:
-- "Configuración de niveles y límites (ya modelado, sin UI)", "Anulación de
-- transacciones (`void_charge()` existe, sin UI)" y la bitácora, que se
-- escribía desde el día 1 y no se podía leer desde ninguna parte.
--
-- Sobre la anulación, una aclaración que importa: `void_charge()` solo mueve
-- cobros en estado `pending` — un QR generado y nunca reclamado. **No existe
-- todavía la anulación de un consumo ya confirmado**, que es la válvula de
-- escape que recomiendan docs/06 §2 y D-13 para el cajero que teclea $500 en
-- vez de $50. Esa sí toca el ledger (revertir el asiento, borrar el plan de
-- cuotas, devolver el cupo del bloque) y D-13 sigue sin decidirse, así que no
-- se construye a medias aquí: lo que hay es la lista con el botón para lo que
-- sí es seguro anular hoy.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Historial global de transacciones
-- ---------------------------------------------------------------------------
-- El panel del comercio ya tiene su historial, pero solo el suyo. Este es el
-- de Ronda: todos los consumos, de todos los locales, con quién los hizo.
--
-- Filtra por usuario, comercio, estado y rango de días operativos. El rango
-- va por `business_date` y no por `created_at` justo por lo de siempre: una
-- venta del sábado a las 2 AM pertenece al viernes (docs/06 §1), y si el
-- filtro usara la hora real no cuadraría con lo que ve el local.

create or replace function public.admin_charges(
  p_search      text default null,
  p_merchant_id uuid default null,
  p_status      text default null,
  p_from        date default null,
  p_to          date default null,
  p_limit       integer default 100
)
returns table (
  charge_id      uuid,
  amount_usd     numeric,
  status         text,
  business_date  date,
  created_at     timestamptz,
  confirmed_at   timestamptz,
  void_reason    text,
  user_id        uuid,
  full_name      text,
  phone_e164     text,
  user_status    text,
  merchant_id    uuid,
  merchant_name  text,
  branch_name    text,
  is_group       boolean,
  installments_paid integer,
  installments_total integer
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_needle text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_needle := nullif(trim(coalesce(p_search, '')), '');

  return query
  select
    ch.id,
    ch.amount_usd,
    ch.status::text,
    ch.business_date,
    ch.created_at,
    ch.confirmed_at,
    ch.void_reason,
    ch.user_id,
    p.full_name,
    p.phone_e164,
    p.status::text,
    m.id,
    m.name,
    b.name,
    -- Un consumo de grupo genera N cargos hermanos con el mismo grupo detrás.
    -- Marcarlo evita que alguien lea ocho filas de $12,50 como ocho consumos
    -- sueltos de una noche rara.
    ch.group_id is not null,
    coalesce(i.paid, 0)::integer,
    coalesce(i.total, 0)::integer
  from public.charges ch
  left join public.profiles p on p.id = ch.user_id
  join public.merchants m on m.id = ch.merchant_id
  join public.merchant_branches b on b.id = ch.branch_id
  left join (
    -- `ins.` explícito: el OUT parameter de esta función también se llama
    -- `charge_id` y sin calificar la columna Postgres no sabe a cuál se
    -- refiere.
    select ins.charge_id as cid,
           count(*) filter (where ins.status = 'paid')::integer as paid,
           count(*)::integer as total
    from public.installments ins group by 1
  ) i on i.cid = ch.id
  where
    (p_merchant_id is null or ch.merchant_id = p_merchant_id)
    and (p_status is null or ch.status::text = p_status)
    and (p_from is null or ch.business_date >= p_from)
    and (p_to is null or ch.business_date <= p_to)
    and (
      v_needle is null
      or p.phone_e164 ilike '%' || v_needle || '%'
      or p.full_name ilike '%' || v_needle || '%'
      or p.document_number ilike '%' || v_needle || '%'
      or m.name ilike '%' || v_needle || '%'
    )
  order by ch.created_at desc
  limit least(coalesce(p_limit, 100), 500);
end;
$$;

revoke all on function public.admin_charges(text, uuid, text, date, date, integer)
  from public, anon;
grant execute on function public.admin_charges(text, uuid, text, date, date, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Anular un cobro pendiente
-- ---------------------------------------------------------------------------
-- Envoltorio con guardia y bitácora sobre `void_charge()`, que hasta ahora
-- solo podía llamar el service role.

create or replace function public.admin_void_charge(p_charge_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  perform public.void_charge(p_charge_id, v_actor, p_reason);

  perform audit.log(v_actor, 'charge.void', p_charge_id,
    jsonb_build_object('reason', p_reason));
end;
$$;

revoke all on function public.admin_void_charge(uuid, text) from public, anon;
grant execute on function public.admin_void_charge(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Bitácora
-- ---------------------------------------------------------------------------
-- `audit.admin_actions` es append-only desde que existe y no tenía lector.
-- Una bitácora que solo se consulta por SQL a mano es una bitácora que nadie
-- consulta.

create or replace function public.admin_audit_log(
  p_action text default null,
  p_actor  uuid default null,
  p_target uuid default null,
  p_limit  integer default 100
)
returns table (
  id         bigint,
  actor      uuid,
  actor_name text,
  action     text,
  target_id  uuid,
  detail     jsonb,
  created_at timestamptz
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
  select a.id, a.actor, pa.full_name, a.action, a.target_id, a.detail, a.created_at
  from audit.admin_actions a
  left join public.platform_admins pa on pa.user_id = a.actor
  where (p_action is null or a.action = p_action)
    and (p_actor is null or a.actor = p_actor)
    and (p_target is null or a.target_id = p_target)
  order by a.created_at desc
  limit least(coalesce(p_limit, 100), 500);
end;
$$;

revoke all on function public.admin_audit_log(text, uuid, uuid, integer) from public, anon;
grant execute on function public.admin_audit_log(text, uuid, uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Configuración de niveles
-- ---------------------------------------------------------------------------
-- `public.levels` se sembró el día 1 y nunca tuvo UI. Cambiar un límite desde
-- aquí cambia el disponible de todo el mundo en ese nivel al instante, así
-- que el motivo es obligatorio y queda en bitácora.
--
-- Sigue habiendo tres decisiones abiertas alrededor de esta tabla
-- (docs/00-BASES §2.6): límites de los niveles 4 y 5, si la bajada por mora
-- es de un nivel o directa al 1, y los 60 días de enfriamiento. Ninguna se
-- resuelve aquí; esto solo deja de obligar a escribir SQL para tocarlas.

create or replace function public.admin_set_level_config(
  p_level              smallint,
  p_monthly_limit_usd  numeric,
  p_required_spend_usd numeric,
  p_required_months    smallint,
  p_is_active          boolean,
  p_label              text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_before jsonb;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super_admin puede configurar los niveles'
      using errcode = '42501';
  end if;

  if p_monthly_limit_usd < 0 or p_required_spend_usd < 0 or p_required_months < 0 then
    raise exception 'Los valores de un nivel no pueden ser negativos'
      using errcode = '22023';
  end if;

  -- Activar un nivel con límite cero le daría a quien ascienda un cupo de
  -- cero: subiría de nivel para no poder gastar. Es el error exacto que
  -- cometería alguien activando el nivel 4 sin ponerle límite.
  if p_is_active and p_monthly_limit_usd <= 0 then
    raise exception 'Un nivel activo necesita un límite mayor que cero'
      using errcode = '22023';
  end if;

  select to_jsonb(l) into v_before from public.levels l where l.level = p_level;
  if v_before is null then
    raise exception 'Nivel no encontrado' using errcode = 'P0002';
  end if;

  update public.levels
    set monthly_limit_usd  = p_monthly_limit_usd,
        required_spend_usd = p_required_spend_usd,
        required_months    = p_required_months,
        is_active          = p_is_active,
        label              = coalesce(nullif(trim(p_label), ''), label),
        updated_at         = now()
  where level = p_level;

  perform audit.log(v_actor, 'level.configure', null, jsonb_build_object(
    'level', p_level,
    'before', v_before,
    'after', (select to_jsonb(l) from public.levels l where l.level = p_level)
  ));
end;
$$;

revoke all on function public.admin_set_level_config(smallint, numeric, numeric, smallint, boolean, text)
  from public, anon;
grant execute on function public.admin_set_level_config(smallint, numeric, numeric, smallint, boolean, text)
  to authenticated;

-- Cuánta gente hay en cada nivel: sin eso, subir el límite del nivel 2 es
-- una decisión a ciegas sobre cuánta exposición nueva se abre.
create or replace function public.admin_level_config()
returns table (
  level              smallint,
  label              text,
  monthly_limit_usd  numeric,
  required_spend_usd numeric,
  required_months    smallint,
  is_active          boolean,
  user_count         integer,
  exposure_usd       numeric
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
  select
    l.level, l.label, l.monthly_limit_usd, l.required_spend_usd,
    l.required_months, l.is_active,
    coalesce(u.cnt, 0)::integer,
    coalesce(u.debt, 0)::numeric
  from public.levels l
  left join (
    select p.level as lvl, count(*)::integer as cnt,
           sum(coalesce(d.open_debt, 0)) as debt
    from public.profiles p
    left join (
      select ins.user_id as uid, sum(ins.amount_usd) as open_debt
      from public.installments ins where ins.status = 'pending' group by 1
    ) d on d.uid = p.id
    group by 1
  ) u on u.lvl = l.level
  order by l.level;
end;
$$;

revoke all on function public.admin_level_config() from public, anon;
grant execute on function public.admin_level_config() to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Cuenta a la que paga el usuario
-- ---------------------------------------------------------------------------
-- D-01, el bloqueante más viejo del proyecto. La tabla existe y la app ya la
-- lee; en local hay una cuenta de mentira sembrada en `seed.sql`. Esto es lo
-- que permite sustituirla por la de verdad sin publicar una versión nueva de
-- la app.
--
-- Un índice único parcial impide que haya dos cuentas activas a la vez, así
-- que activar una desactiva la anterior dentro de la misma transacción — si
-- se hiciera en dos pasos, entre uno y otro un usuario podría pagar a una
-- cuenta que ya no es de Ronda.

create or replace function public.admin_set_payment_destination(
  p_bank_name   text,
  p_rif         text,
  p_phone       text,
  p_holder_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_id    uuid;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super_admin puede cambiar la cuenta de cobro'
      using errcode = '42501';
  end if;

  if coalesce(trim(p_bank_name), '') = ''
     or coalesce(trim(p_rif), '') = ''
     or coalesce(trim(p_phone), '') = '' then
    raise exception 'Banco, RIF y teléfono son obligatorios' using errcode = '22023';
  end if;

  update public.payment_destinations set is_active = false where is_active;

  insert into public.payment_destinations (bank_name, rif, phone, holder_name, is_active)
  values (trim(p_bank_name), trim(p_rif), trim(p_phone),
          nullif(trim(coalesce(p_holder_name, '')), ''), true)
  returning id into v_id;

  perform audit.log(v_actor, 'payment_destination.set', v_id, jsonb_build_object(
    'bank_name', p_bank_name, 'rif', p_rif, 'phone', p_phone, 'holder_name', p_holder_name
  ));

  return v_id;
end;
$$;

revoke all on function public.admin_set_payment_destination(text, text, text, text)
  from public, anon;
grant execute on function public.admin_set_payment_destination(text, text, text, text)
  to authenticated;

create or replace function public.admin_payment_destinations()
returns table (
  id          uuid,
  bank_name   text,
  rif         text,
  phone       text,
  holder_name text,
  is_active   boolean,
  created_at  timestamptz,
  report_count integer
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
  select d.id, d.bank_name, d.rif, d.phone, d.holder_name, d.is_active, d.created_at,
         coalesce(r.cnt, 0)::integer
  from public.payment_destinations d
  left join (
    select destination_id as did, count(*)::integer as cnt
    from public.payment_reports where destination_id is not null group by 1
  ) r on r.did = d.id
  order by d.is_active desc, d.created_at desc;
end;
$$;

revoke all on function public.admin_payment_destinations() from public, anon;
grant execute on function public.admin_payment_destinations() to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Equipo de Ronda
-- ---------------------------------------------------------------------------
-- `platform_admins` se daba de alta "a mano en la base: no hay autorregistro"
-- (comentario de la migración 20260822100000). Sigue sin haber autorregistro:
-- lo que cambia es que **un super_admin ya existente** puede dar de alta a
-- otro sin abrir un cliente de Postgres. La persona tiene que tener cuenta
-- creada antes; se busca por teléfono, igual que el personal de un comercio.
--
-- Una baranda deliberada: nadie puede desactivarse a sí mismo. Quedarse sin
-- ningún super_admin activo dejaría el panel inaccesible y solo se arreglaría
-- con el service role.

create or replace function public.admin_set_platform_admin(
  p_phone     text,
  p_role      public.platform_role,
  p_full_name text default null
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

  select id into v_user from public.profiles
  where public.phone_national_key(phone_e164) = public.phone_national_key(p_phone);

  if v_user is null then
    raise exception 'No hay ninguna cuenta con ese teléfono. La persona debe registrarse primero.'
      using errcode = 'P0002';
  end if;

  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_user, p_role, nullif(trim(coalesce(p_full_name, '')), ''), true)
  on conflict (user_id) do update
    set role = excluded.role,
        full_name = coalesce(excluded.full_name, public.platform_admins.full_name),
        is_active = true;

  perform audit.log(v_actor, 'platform_admin.set', v_user, jsonb_build_object(
    'role', p_role, 'full_name', p_full_name
  ));

  return v_user;
end;
$$;

revoke all on function public.admin_set_platform_admin(text, public.platform_role, text)
  from public, anon;
grant execute on function public.admin_set_platform_admin(text, public.platform_role, text)
  to authenticated;

create or replace function public.admin_revoke_platform_admin(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super_admin puede revocar accesos' using errcode = '42501';
  end if;

  if p_user_id = v_actor then
    raise exception 'No puedes revocarte a ti mismo' using errcode = '22023';
  end if;

  update public.platform_admins set is_active = false where user_id = p_user_id;

  perform audit.log(v_actor, 'platform_admin.revoke', p_user_id, '{}'::jsonb);
end;
$$;

revoke all on function public.admin_revoke_platform_admin(uuid) from public, anon;
grant execute on function public.admin_revoke_platform_admin(uuid) to authenticated;

create or replace function public.admin_platform_team()
returns table (
  user_id     uuid,
  full_name   text,
  phone_e164  text,
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
  select pa.user_id, pa.full_name, p.phone_e164, pa.role::text, pa.is_active, pa.created_at,
         coalesce(a.cnt, 0)::integer, a.last_at
  from public.platform_admins pa
  left join public.profiles p on p.id = pa.user_id
  left join (
    -- Alias explícito: `created_at` es también un OUT parameter de esta
    -- función, y sin calificar Postgres no sabe a cuál se refiere.
    select aa.actor as uid, count(*)::integer as cnt, max(aa.created_at) as last_at
    from audit.admin_actions aa group by 1
  ) a on a.uid = pa.user_id
  order by pa.is_active desc, pa.created_at;
end;
$$;

revoke all on function public.admin_platform_team() from public, anon;
grant execute on function public.admin_platform_team() to authenticated;
