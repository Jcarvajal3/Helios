-- ============================================================================
-- Helios — Lo que el superadmin necesita ver de pacientes y clínicas (docs/01 §2.4-2.5)
--
-- Arreglos hacia delante de 1B, pedidos por el panel del superadmin:
--
-- 1. `admin_user_directory` añade `registered_merchant_name` y
--    `email_invalid_at` al final.
-- 2. `admin_merchant_detail.terms` añade `staff_commission_usd` (la pactada;
--    null = la global) y `staff_commission_effective_usd` (la que se aplica
--    hoy). `admin_merchant_terms_history` añade `staff_commission_usd`.
-- 3. `admin_profile_change_requests` devuelve, además de `field_changes`
--    (`{campo: {antes, propuesto}}`), `proposed` y `current` como objetos
--    campo → valor (lo propuesto y lo que el paciente tiene HOY), y
--    `resolved_at` / `resolved_by_name` (alias de `reviewed_*`).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. admin_user_directory: dónde se registró y si su correo rebotó
-- ---------------------------------------------------------------------------
-- Copia de la vigente (pg_get_functiondef, 2026-10-01) con dos columnas al
-- final. Cambia el tipo de retorno: se borra y se crea.

drop function public.admin_user_directory(text, text, integer, smallint, boolean, boolean, integer, text, text);

CREATE FUNCTION public.admin_user_directory(p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_level smallint DEFAULT NULL::smallint, p_is_test boolean DEFAULT NULL::boolean, p_blacklisted boolean DEFAULT NULL::boolean, p_offset integer DEFAULT 0, p_orden text DEFAULT NULL::text, p_dir text DEFAULT NULL::text)
 RETURNS TABLE(user_id uuid, full_name text, phone_e164 text, document_number text, status text, level smallint, level_limit_usd numeric, is_blacklisted boolean, is_test boolean, created_at timestamp with time zone, open_debt_usd numeric, overdue_usd numeric, days_overdue integer, charge_count integer, last_charge_at timestamp with time zone, available_usd numeric, last_merchant_name text, on_time_paid integer, on_time_total integer, available_now_usd numeric, available_blocked_reason text, total_count bigint, open_debt_financed_usd numeric, open_debt_fee_usd numeric, overdue_financed_usd numeric, overdue_fee_usd numeric, registered_merchant_name text, email_invalid_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_limit  integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_orden  text := nullif(trim(coalesce(p_orden, '')), '');
  v_asc    boolean := lower(coalesce(p_dir, 'asc')) = 'asc';
  v_needle text;
  v_aguja  text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_orden is not null and v_orden not in (
    'persona', 'estado', 'nivel', 'deuda', 'vencido', 'dias-atraso',
    'a-tiempo', 'registro', 'ultimo', 'ultimo-local'
  ) then
    raise exception 'No se puede ordenar por «%»', p_orden using errcode = '22023';
  end if;
  if lower(coalesce(p_dir, 'asc')) not in ('asc', 'desc') then
    raise exception 'El sentido del orden es asc o desc' using errcode = '22023';
  end if;

  v_needle := nullif(trim(coalesce(p_search, '')), '');
  -- El nombre se compara sin tildes ni mayúsculas: «jose» encuentra a «JOSÉ».
  v_aguja  := public.helios_sin_tildes(v_needle);

  return query
  with cuotas as materialized (
    -- Las cuotas canónicas: sin pruebas, de consumos confirmados, con su
    -- estado de hoy (vencida, por vencer, perdida, a tiempo, tarde).
    select q.user_id, q.charge_id, q.payable_usd, q.financed_usd,
           q.estado_hoy, q.dias_atraso, q.plazo_cerrado
    from metricas.cuotas q
  ),
  base as (
    select
      p.id,
      p.full_name,
      p.phone_e164,
      p.document_number,
      p.status::text                                   as status,
      p.level,
      l.monthly_limit_usd,
      p.is_blacklisted,
      p.is_test,
      p.created_at,
      coalesce(d.open_debt, 0)::numeric                as open_debt,
      coalesce(d.overdue, 0)::numeric                  as overdue,
      coalesce(d.days_late, 0)::integer                as days_late,
      coalesce(c.cnt, 0)::integer                      as cnt,
      c.last_at,
      -- El cupo nominal, del bloque de crédito abierto, igual que en la ficha.
      greatest(l.monthly_limit_usd - coalesce(b.charged_usd - b.paid_usd, 0), 0)::numeric as disponible,
      c.last_merchant,
      coalesce(o.on_time, 0)::integer                  as on_time,
      coalesce(o.total, 0)::integer                    as on_time_total,
      coalesce(d.open_debt_fin, 0)::numeric            as open_debt_fin,
      coalesce(d.overdue_fin, 0)::numeric              as overdue_fin,
      -- Helios: dónde se registró y si su correo rebotó.
      (select rm.name from public.merchants rm where rm.id = p.registered_merchant_id) as reg_merchant,
      p.email_invalid_at                               as email_inv,
      -- Con texto, primero lo que más se parece: la coincidencia exacta, luego
      -- el nombre que empieza así, luego una palabra del nombre que empieza
      -- así, y al final el resto. Sin texto, todos en el mismo grupo.
      case
        when v_needle is null then 0
        when public.helios_sin_tildes(p.full_name) = v_aguja
          or p.phone_e164 = v_needle or p.document_number = v_needle then 0
        when public.helios_sin_tildes(p.full_name) like v_aguja || '%'
          or p.document_number ilike v_needle || '%' then 1
        when ' ' || public.helios_sin_tildes(p.full_name) like '% ' || v_aguja || '%' then 2
        else 3
      end                                              as parecido,
      count(*) over ()                                 as total
    from public.profiles p
    join public.levels l on l.level = p.level
    -- La deuda viva (vencido + por vencer) y lo vencido, sin lo dado por
    -- perdido: las definiciones de Vencido y Por vencer. Los días de atraso,
    -- los de su cuota vencida más antigua.
    left join (
      select
        x.user_id as uid,
        sum(x.payable_usd)                                          as open_debt,
        sum(x.financed_usd)                                         as open_debt_fin,
        sum(x.payable_usd)  filter (where x.estado_hoy = 'vencida') as overdue,
        sum(x.financed_usd) filter (where x.estado_hoy = 'vencida') as overdue_fin,
        max(x.dias_atraso)  filter (where x.estado_hoy = 'vencida') as days_late
      from cuotas x
      where x.estado_hoy in ('vencida', 'por_vencer')
      group by 1
    ) d on d.uid = p.id
    -- Los consumos en los que el usuario TIENE cuota (en un grupo, también
    -- los que abrió otro), el último y su local.
    left join (
      select
        y.uid,
        count(*)::integer as cnt,
        max(y.confirmed_at) as last_at,
        (array_agg(y.merchant_name order by y.confirmed_at desc))[1] as last_merchant
      from (
        select distinct x.user_id as uid, ch.id, ch.confirmed_at, m.name as merchant_name
        from cuotas x
        join public.charges ch on ch.id = x.charge_id
        join public.merchants m on m.id = ch.merchant_id
      ) y
      group by 1
    ) c on c.uid = p.id
    -- El bloque de crédito abierto. Hay como mucho uno por persona.
    left join public.user_credit_blocks b
      on b.user_id = p.id and b.closed_at is null
    -- Cobrado a tiempo: de sus cuotas con el plazo cerrado (vencimiento +
    -- días de gracia), cuántas se pagaron dentro de él, por el día del
    -- reporte. Lo dado por perdido cuenta como no pagado.
    left join (
      select
        x.user_id as uid,
        count(*) filter (where x.estado_hoy = 'a_tiempo')::integer as on_time,
        count(*)::integer as total
      from cuotas x
      where x.plazo_cerrado
      group by 1
    ) o on o.uid = p.id
    where
      (p_status is null or p.status::text = p_status)
      and (p_level is null or p.level = p_level)
      and (p_is_test is null or p.is_test = p_is_test)
      and (p_blacklisted is null or p.is_blacklisted = p_blacklisted)
      and (
        v_needle is null
        or p.phone_e164 ilike '%' || v_needle || '%'
        or public.helios_sin_tildes(p.full_name) like '%' || v_aguja || '%'
        or p.document_number ilike '%' || v_needle || '%'
      )
  ),
  -- La clave de la columna pedida, en una sola columna por tipo. Lo que no
  -- tiene valor sale null y va al final (`nulls last` en los dos sentidos).
  claves as (
    select
      b.*,
      case v_orden
        when 'persona'      then lower(public.helios_sin_tildes(b.full_name))
        when 'estado'       then b.status
        when 'ultimo-local' then lower(b.last_merchant)
      end                                              as clave_texto,
      case v_orden
        when 'nivel'       then b.level::numeric
        when 'deuda'       then b.open_debt
        when 'vencido'     then b.overdue
        when 'dias-atraso' then case when b.overdue > 0 then b.days_late::numeric end
        when 'a-tiempo'    then case when b.on_time_total > 0 then b.on_time::numeric / b.on_time_total end
      end                                              as clave_numero,
      case v_orden
        when 'registro' then b.created_at
        when 'ultimo'   then b.last_at
      end                                              as clave_fecha
    from base b
  ),
  pagina as (
    select k.*
    from claves k
    order by
      case when v_asc then k.clave_texto  end asc  nulls last,
      case when not v_asc then k.clave_texto  end desc nulls last,
      case when v_asc then k.clave_numero end asc  nulls last,
      case when not v_asc then k.clave_numero end desc nulls last,
      case when v_asc then k.clave_fecha  end asc  nulls last,
      case when not v_asc then k.clave_fecha  end desc nulls last,
      -- El orden de siempre: esta lista se abre para cobrar, no para navegar
      -- el padrón. Sin columna pedida es el único; con ella, el desempate.
      k.parecido, k.days_late desc, k.open_debt desc, k.created_at desc, k.id
    limit v_limit
    offset v_offset
  )
  select
    g.id, g.full_name, g.phone_e164, g.document_number, g.status, g.level,
    g.monthly_limit_usd, g.is_blacklisted, g.is_test, g.created_at,
    g.open_debt, g.overdue, g.days_late, g.cnt, g.last_at, g.disponible,
    g.last_merchant, g.on_time, g.on_time_total,
    public.helios_available_now_usd(g.id),
    public.helios_available_blocked_reason(g.id),
    g.total,
    g.open_debt_fin,
    g.open_debt - g.open_debt_fin,
    g.overdue_fin,
    g.overdue - g.overdue_fin,
    g.reg_merchant,
    g.email_inv
  from pagina g
  order by
    case when v_asc then g.clave_texto  end asc  nulls last,
    case when not v_asc then g.clave_texto  end desc nulls last,
    case when v_asc then g.clave_numero end asc  nulls last,
    case when not v_asc then g.clave_numero end desc nulls last,
    case when v_asc then g.clave_fecha  end asc  nulls last,
    case when not v_asc then g.clave_fecha  end desc nulls last,
    g.parecido, g.days_late desc, g.open_debt desc, g.created_at desc, g.id;
end;
$function$
;

revoke all on function public.admin_user_directory(text, text, integer, smallint, boolean, boolean, integer, text, text) from public, anon;
grant execute on function public.admin_user_directory(text, text, integer, smallint, boolean, boolean, integer, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. La ficha de la clínica y su historial de condiciones, con la comisión
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_merchant_detail(p_merchant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_merchant public.merchants%rowtype;
  v_terms    public.merchant_settlement_terms%rowtype;
  v_staff    jsonb;
  v_owed     numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_merchant from public.merchants where id = p_merchant_id;
  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  select * into v_terms from public.merchant_settlement_terms
  where merchant_id = p_merchant_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', mu.user_id,
    'name', coalesce(nullif(trim(au.raw_user_meta_data ->> 'full_name'), ''), au.email),
    'email', au.email,
    'phone', au.phone,
    'role', mu.role,
    'branch', b.name
  ) order by mu.created_at), '[]'::jsonb) into v_staff
  from public.merchant_users mu
  join auth.users au on au.id = mu.user_id
  left join public.merchant_branches b on b.id = mu.branch_id
  where mu.merchant_id = p_merchant_id and mu.is_active;

  -- La misma cuenta que el guardia de `terminated`: es la cifra que la ficha
  -- enseña como «Le debes X» y la que decide si el botón de Terminar está vivo.
  select coalesce(sum(amount_usd - paid_usd), 0) into v_owed
  from public.settlements
  where merchant_id = p_merchant_id and status in ('pending', 'partial');

  return jsonb_build_object(
    'profile', jsonb_build_object(
      'category', v_merchant.category,
      'city', v_merchant.city,
      'handle', v_merchant.handle,
      'logo_url', v_merchant.logo_url,
      'social_url', v_merchant.social_url,
      'tax_id', v_merchant.tax_id,
      'specialty', v_merchant.specialty,
      'mpps_number', v_merchant.mpps_number,
      'phone', v_merchant.phone,
      'email', v_merchant.email,
      'address', v_merchant.address
    ),
    'terms', jsonb_build_object(
      'upfront_pct', v_terms.upfront_pct,
      'per_installment_pct', v_terms.per_installment_pct,
      'commission_pct', v_terms.commission_pct,
      'policy', v_terms.policy,
      -- Helios: la comisión pactada (null = la global) y la que se aplica hoy.
      'staff_commission_usd', (select t.staff_commission_usd
                                 from public.helios_terms_at(p_merchant_id, public.helios_business_date(now())) t),
      'staff_commission_effective_usd', public.helios_staff_commission_for(p_merchant_id, public.helios_business_date(now()))
    ),
    'staff', v_staff,
    'pending_usd', v_owed,
    'payout_account', public.admin_merchant_payout_account(p_merchant_id)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_merchant_terms_history(p_merchant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.effective_from desc), '[]'::jsonb)
  into v_rows
  from (
    select
      t.id, t.upfront_pct, t.per_installment_pct, t.commission_pct,
      t.policy::text as policy, t.effective_from, t.note, t.created_at,
      t.staff_commission_usd,
      t.effective_from <= public.helios_business_date(now()) as is_current_or_past,
      coalesce(pa.full_name, 'Alguien del equipo') as created_by_name
    from public.merchant_terms t
    left join public.platform_admins pa on pa.user_id = t.created_by
    where t.merchant_id = p_merchant_id
  ) q;

  return v_rows;
end;
$function$
;

-- ---------------------------------------------------------------------------
-- 3. Las propuestas de cambio, con lo propuesto y lo actual
-- ---------------------------------------------------------------------------

drop function public.admin_profile_change_requests(text);

create function public.admin_profile_change_requests(p_status text default 'pendiente')
returns table(
  id uuid, profile_id uuid, patient_name text, document_number text,
  merchant_id uuid, merchant_name text, requested_by uuid, requested_by_name text,
  field_changes jsonb, proposed jsonb, "current" jsonb, status text,
  reviewed_by uuid, reviewed_by_name text, reviewed_at timestamptz,
  resolved_at timestamptz, resolved_by_name text, note text, created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_status is not null and p_status not in ('pendiente', 'aprobado', 'rechazado') then
    raise exception 'Estado no válido: %', p_status using errcode = '22023';
  end if;

  return query
  select r.id,
         r.profile_id,
         p.full_name,
         p.document_number,
         r.merchant_id,
         m.name,
         r.requested_by,
         public.helios_staff_name(r.requested_by),
         r.field_changes,
         x.propuesto,
         x.actual,
         r.status,
         r.reviewed_by,
         rv.full_name,
         r.reviewed_at,
         r.reviewed_at,
         rv.full_name,
         r.note,
         r.created_at
  from public.profile_change_requests r
  join public.profiles p on p.id = r.profile_id
  left join public.merchants m on m.id = r.merchant_id
  left join public.platform_admins rv on rv.user_id = r.reviewed_by
  cross join lateral (
    select coalesce(jsonb_object_agg(k.key, k.value -> 'propuesto'), '{}'::jsonb) as propuesto,
           coalesce(jsonb_object_agg(k.key,
             to_jsonb(p) -> (case when k.key = 'phone' then 'phone_e164' else k.key end)), '{}'::jsonb) as actual
    from jsonb_each(r.field_changes) k
  ) x
  where p_status is null or r.status = p_status
  order by case when r.status = 'pendiente' then r.created_at end asc nulls last,
           r.reviewed_at desc nulls last
  limit 500;
end;
$$;

revoke all on function public.admin_profile_change_requests(text) from public, anon;
grant execute on function public.admin_profile_change_requests(text) to authenticated;
