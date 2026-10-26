-- ============================================================================
-- Helios — El superadmin ve la moneda de cada orden y la tasa de cada cuota
--
-- Javier (2026-10-26):
--
--   · En Financiamientos, cada orden dice en qué moneda se hizo (dólares o
--     euros). Las métricas no cambian: siguen en dólares, con la conversión
--     que la orden guardó al registrarse.
--   · En Pagos a clínicas, cada liquidación dice a qué tasa pagó el paciente
--     su cuota (bolívares a la tasa del dólar o a la del euro, y cuál fue) y a
--     qué tasa hay que pagarle al médico. La lista de lo que se debe dice en
--     qué monedas va lo de cada médico.
--
-- Lo que cambia (todo lecturas; ninguna escribe):
--
-- 1. `admin_charges` añade al final `currency`, `fx_usd_per_unit`,
--    `amount_cur` y `financed_cur` (la base en la moneda de la orden). Cambia
--    la forma de la tabla: se borra y se crea, con sus permisos.
--
-- 2. `helios_cuota_pagada(charge, día)`: cómo pagó el paciente las cuotas de
--    una orden que vencen ese día. La tasa sale de la cotización del pago
--    (`payment_quotes`): la del euro si la cuota es de una orden en euros, la
--    del dólar si no.
--
-- 3. `admin_merchant_settlements` y `admin_merchant_upcoming_settlements`
--    añaden por línea `tasa_hoy` (la de su moneda, hoy: es la que se le paga
--    al médico), lo de la cuota del paciente (`cuotas`, `cuotas_pagadas`,
--    `paciente_pago_el`, `paciente_tasa`) y, en las ya transferidas, la tasa
--    con la que salió (`pagado_el`, `pagado_tasa`).
--
-- 4. `admin_merchant_payables` añade `monedas` (las monedas de lo que se le
--    debe: dólares primero) y `next_run_eur` (de lo que sale hoy, lo que va en
--    euros, en euros).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Financiamientos: la moneda de la orden
-- ---------------------------------------------------------------------------

drop function if exists public.admin_charges(text, uuid, text, date, date, integer);

CREATE FUNCTION public.admin_charges(p_search text DEFAULT NULL::text, p_merchant_id uuid DEFAULT NULL::uuid, p_status text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_limit integer DEFAULT 100)
 RETURNS TABLE(charge_id uuid, order_number bigint, amount_usd numeric, status text, business_date date, created_at timestamp with time zone, confirmed_at timestamp with time zone, void_reason text, user_id uuid, full_name text, phone_e164 text, user_status text, merchant_id uuid, merchant_name text, branch_name text, is_group boolean, is_test boolean, installments_paid integer, installments_total integer, financed_usd numeric, concept text, beneficiary_name text, registered_by_name text, staff_commission_usd numeric, document_number text, doctor_name text, currency text, fx_usd_per_unit numeric, amount_cur numeric, financed_cur numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_needle text;
  v_order  bigint;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_needle := nullif(trim(coalesce(p_search, '')), '');

  if v_needle ~ '^#?\d{1,18}$' then
    v_order := replace(v_needle, '#', '')::bigint;
  else
    v_order := null;
  end if;

  return query
  select
    ch.id,
    ch.order_number,
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
    ch.group_id is not null,
    ch.is_test,
    coalesce(i.paid, 0)::integer,
    coalesce(i.total, 0)::integer,
    coalesce(ch.base_usd, ch.amount_usd)::numeric,
    ch.concept,
    ch.beneficiary_name,
    public.helios_staff_name(ch.requested_by),
    ch.staff_commission_usd,
    p.document_number,
    public.helios_doctor_name(m.id),
    -- NUEVO: la moneda en la que se hizo y sus montos en esa moneda.
    ch.currency,
    ch.fx_usd_per_unit,
    coalesce(ch.amount_cur, ch.amount_usd)::numeric,
    coalesce(ch.base_cur, ch.amount_cur, ch.base_usd, ch.amount_usd)::numeric
  from public.charges ch
  left join public.profiles p on p.id = ch.user_id
  join public.merchants m on m.id = ch.merchant_id
  join public.merchant_branches b on b.id = ch.branch_id
  left join (
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
      or (v_order is not null and ch.order_number = v_order)
      or p.phone_e164 ilike '%' || v_needle || '%'
      or p.full_name ilike '%' || v_needle || '%'
      or p.document_number ilike '%' || v_needle || '%'
      or p.email ilike '%' || v_needle || '%'
      or m.name ilike '%' || v_needle || '%'
      or m.owner_name ilike '%' || v_needle || '%'
      or ch.concept ilike '%' || v_needle || '%'
      or ch.beneficiary_name ilike '%' || v_needle || '%'
    )
  order by ch.created_at desc
  limit least(coalesce(p_limit, 100), 500);
end;
$function$;

revoke all on function public.admin_charges(text, uuid, text, date, date, integer) from public, anon;
grant execute on function public.admin_charges(text, uuid, text, date, date, integer) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Cómo pagó el paciente la cuota de un día
-- ---------------------------------------------------------------------------

/**
 * Las cuotas de una orden que vencen `p_due_date` (la mitad de la consulta que
 * liquida ese día): cuántas son, cuántas están pagadas, cuándo se pagó la
 * última y a qué tasa. La tasa es la de la cotización del pago, en bolívares
 * por unidad de la moneda de la cuota: la del euro en una orden en euros, la
 * del dólar en una en dólares. Sin pago, `paid_on` y `fx_rate` van en null.
 *
 * Solo lectura, para el superadmin: no la llama nadie más.
 */
create or replace function public.helios_cuota_pagada(p_charge_id uuid, p_due_date date)
returns table(cuotas integer, cuotas_pagadas integer, paid_on date, fx_rate numeric)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select
    count(*)::integer,
    count(*) filter (where i.status = 'paid')::integer,
    (max(i.paid_at) filter (where i.status = 'paid') at time zone 'America/Caracas')::date,
    -- La del último pago: en una orden de un solo paciente es la única.
    (array_agg(
       case coalesce(qi.currency, c.currency) when 'EUR' then q.fx_rate_eur else q.fx_rate end
       order by i.paid_at desc nulls last
     ) filter (where i.status = 'paid'))[1]
  from public.installments i
  join public.charges c on c.id = i.charge_id
  left join public.payment_reports r on r.id = i.paid_by_report_id
  left join public.payment_quotes q on q.id = r.quote_id
  left join public.payment_quote_items qi on qi.quote_id = q.id and qi.installment_id = i.id
  where i.charge_id = p_charge_id
    and i.due_date = p_due_date
$$;

revoke all on function public.helios_cuota_pagada(uuid, date) from public, anon, authenticated;
grant execute on function public.helios_cuota_pagada(uuid, date) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Las liquidaciones dicen la tasa del paciente y la del médico
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_merchant_settlements(p_merchant_id uuid, p_run_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
  v_hoy  date := public.helios_business_date(now());
  v_usd  numeric := public.current_fx_rate('BCV', v_hoy);
  v_eur  numeric := public.current_fx_rate('BCV_EUR', v_hoy);
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.due_date, q.id), '[]'::jsonb)
  into v_rows
  from (
    select
      s.id,
      s.reason,
      s.status,
      s.amount_usd,
      s.paid_usd,
      s.amount_usd - s.paid_usd                          as pending_usd,
      s.currency,
      coalesce(s.amount_cur, s.amount_usd)               as amount_cur,
      s.paid_cur,
      coalesce(s.amount_cur, s.amount_usd) - s.paid_cur  as pending_cur,
      round((coalesce(s.amount_cur, s.amount_usd) - s.paid_cur)
            * case s.currency when 'EUR' then v_eur else v_usd end, 2) as pending_ves_hoy,
      coalesce(s.due_date, s.business_date)              as due_date,
      coalesce(s.due_date, s.business_date)
        <= v_hoy                                         as is_due,
      coalesce(s.due_date, s.business_date)
        < public.helios_next_settlement_run(now())        as in_next_run,
      public.helios_settlement_run_for(
        coalesce(s.due_date, s.business_date)
      )                                                  as run_date,
      c.id                                               as charge_id,
      c.order_number,
      -- NUEVO: la tasa de su moneda hoy, que es la que se le paga al médico.
      case s.currency when 'EUR' then v_eur else v_usd end as tasa_hoy,
      -- NUEVO: la cuota del paciente que liquida (no en la comisión del personal).
      cp.cuotas,
      cp.cuotas_pagadas,
      cp.paid_on                                         as paciente_pago_el,
      cp.fx_rate                                         as paciente_tasa,
      -- NUEVO: si ya se le transfirió, cuándo y a qué tasa de su moneda.
      tr.paid_on                                         as pagado_el,
      tr.fx_rate                                         as pagado_tasa
    from public.settlements s
    left join public.charges c on c.id = s.charge_id
    left join lateral public.helios_cuota_pagada(s.charge_id, s.business_date) cp
      on s.reason = 'scheduled_installment'
    left join lateral (
      select mp.paid_on,
             case s.currency when 'EUR' then mp.fx_rate_eur else mp.fx_rate end as fx_rate
      from public.merchant_payout_items it
      join public.merchant_payouts mp on mp.id = it.payout_id
      where it.settlement_id = s.id
      order by mp.paid_on desc nulls last, mp.created_at desc
      limit 1
    ) tr on true
    where s.merchant_id = p_merchant_id
      and (
        case
          -- Un cierre concreto: lo que fue, pagado o no.
          when p_run_date is not null then
            public.helios_settlement_run_for(
              coalesce(s.due_date, s.business_date)
            ) = p_run_date
          -- Sin cierre: lo que se le debe hoy, de cualquier semana.
          else s.status in ('pending', 'partial')
        end
      )
  ) q;

  return v_rows;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_merchant_upcoming_settlements(p_merchant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
  v_hoy  date := public.helios_business_date(now());
  v_usd  numeric := public.current_fx_rate('BCV', v_hoy);
  v_eur  numeric := public.current_fx_rate('BCV_EUR', v_hoy);
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.due_date, q.order_number), '[]'::jsonb)
  into v_rows
  from (
    select
      'scheduled_installment'                          as reason,
      f.amount_usd,
      f.currency,
      f.amount_cur,
      round(f.amount_cur * case f.currency when 'EUR' then v_eur else v_usd end, 2) as pending_ves_hoy,
      f.due_date,
      public.helios_settlement_run_for(f.due_date)     as run_date,
      f.charge_id,
      f.order_number,
      -- NUEVO: la tasa de hoy de su moneda y, si el paciente ya adelantó su
      -- cuota, a qué tasa la pagó.
      case f.currency when 'EUR' then v_eur else v_usd end as tasa_hoy,
      cp.cuotas,
      cp.cuotas_pagadas,
      cp.paid_on                                       as paciente_pago_el,
      cp.fx_rate                                       as paciente_tasa
    from (
      select
        g.*,
        -- En la moneda de la orden, como `helios_settlement_currency`: la
        -- mitad que completa el neto se lleva lo que falte; las otras, su
        -- parte proporcional.
        case
          when g.currency = 'USD' then g.amount_usd
          when g.prev_usd
               + coalesce(sum(g.amount_usd) over (
                   partition by g.charge_id order by g.due_date
                   rows between unbounded preceding and 1 preceding), 0)
               + g.amount_usd >= g.net_usd - 0.005
            then greatest(g.net_cur - g.prev_cur
                          - coalesce(sum(round(g.net_cur * g.amount_usd / nullif(g.net_usd, 0), 2)) over (
                              partition by g.charge_id order by g.due_date
                              rows between unbounded preceding and 1 preceding), 0), 0)
          else round(g.net_cur * g.amount_usd / nullif(g.net_usd, 0), 2)
        end as amount_cur
      from (
        select
          d.*,
          greatest(0, least(
            d.tranche,
            d.room - coalesce(sum(d.tranche) over (
              partition by d.charge_id order by d.due_date
              rows between unbounded preceding and 1 preceding
            ), 0)
          )) as amount_usd
        from (
          select distinct
            c.id                                                   as charge_id,
            c.order_number,
            c.currency,
            i.due_date,
            coalesce(c.merchant_net_usd, c.amount_usd)             as net_usd,
            coalesce(c.merchant_net_cur, c.amount_cur, c.merchant_net_usd, c.amount_usd) as net_cur,
            round(coalesce(c.merchant_net_usd, c.amount_usd) * t.per_installment_pct / 100, 4) as tranche,
            coalesce((
              select sum(s2.amount_usd) from public.settlements s2
              where s2.charge_id = c.id and s2.reason <> 'staff_commission'
            ), 0)                                                  as prev_usd,
            coalesce((
              select sum(coalesce(s2.amount_cur, s2.amount_usd)) from public.settlements s2
              where s2.charge_id = c.id and s2.reason <> 'staff_commission'
            ), 0)                                                  as prev_cur,
            coalesce(c.merchant_net_usd, c.amount_usd) - coalesce((
              select sum(s2.amount_usd) from public.settlements s2
              where s2.charge_id = c.id and s2.reason <> 'staff_commission'
            ), 0)                                                  as room
          from public.installments i
          join public.charges c on c.id = i.charge_id
          cross join lateral public.helios_terms_at(
            c.merchant_id, coalesce(c.business_date, v_hoy)
          ) t
          where c.merchant_id = p_merchant_id
            and t.policy = 'scheduled'
            and i.due_date >= v_hoy
            and not exists (
              select 1 from public.settlements s3
              where s3.charge_id = c.id
                and s3.reason = 'scheduled_installment'
                and s3.business_date = i.due_date
            )
            and not public.helios_charge_of_test_patient(c.id, null)
        ) d
      ) g
    ) f
    cross join lateral public.helios_cuota_pagada(f.charge_id, f.due_date) cp
    where f.amount_usd > 0
  ) q;

  return v_rows;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Lo que se debe dice en qué monedas va
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_merchant_payables(p_merchant_id uuid DEFAULT NULL::uuid)
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

  select coalesce(jsonb_agg(to_jsonb(q) order by q.total_pending_usd desc), '[]'::jsonb)
  into v_rows
  from (
    select
      m.id     as merchant_id,
      m.name   as merchant_name,
      m.tax_id,
      m.is_test,
      public.helios_doctor_name(m.id) as doctor_name,
      o.*,
      -- Helios: lo devengado y sin transferir, partido (docs/01 §2.5).
      o.accrued_consultas_usd  as consultas_usd,
      o.accrued_comisiones_usd as comisiones_usd,
      np.run_date              as next_pay_date,
      coalesce(np.usd, 0)       as next_pay_usd,
      coalesce(np.consultas, 0) as next_pay_consultas_usd,
      coalesce(np.comisiones, 0) as next_pay_comisiones_usd,
      -- NUEVO: las monedas de lo que se le debe, dólares primero, y de lo que
      -- sale hoy, lo que va en euros (en euros).
      coalesce(mon.monedas, '{}'::text[]) as monedas,
      coalesce(mon.next_run_eur, 0)       as next_run_eur
    from public.merchants m
    cross join lateral public.helios_settlement_outlook(m.id) o
    left join lateral (
      select
        l.run_date,
        sum(l.usd)                                                as usd,
        coalesce(sum(l.usd) filter (where l.reason <> 'staff_commission'), 0) as consultas,
        coalesce(sum(l.usd) filter (where l.reason = 'staff_commission'), 0)  as comisiones
      from (
        -- Lo que ya es liquidación y sale otro día.
        select public.helios_settlement_run_for(coalesce(s.due_date, s.business_date)) as run_date,
               s.reason::text                                                       as reason,
               s.amount_usd - s.paid_usd                                            as usd
        from public.settlements s
        where s.merchant_id = m.id
          and s.status in ('pending', 'partial')
        union all
        -- Las mitades de la consulta que el cron todavía no ha creado.
        select (u->>'run_date')::date, u->>'reason', (u->>'amount_usd')::numeric
        from jsonb_array_elements(public.admin_merchant_upcoming_settlements(m.id)) u
      ) l
      where l.run_date > o.next_run_date
        and l.usd > 0.005
      group by l.run_date
      order by l.run_date
      limit 1
    ) np on true
    left join lateral (
      select
        array_agg(distinct x.currency order by x.currency desc) as monedas,
        coalesce(sum(x.cur) filter (
          where x.currency = 'EUR' and x.due_date < o.next_run_date
        ), 0)                                                    as next_run_eur
      from (
        select s.currency,
               coalesce(s.amount_cur, s.amount_usd) - s.paid_cur as cur,
               coalesce(s.due_date, s.business_date)             as due_date
        from public.settlements s
        where s.merchant_id = m.id
          and s.status in ('pending', 'partial')
        union all
        select u->>'currency', (u->>'amount_cur')::numeric, (u->>'due_date')::date
        from jsonb_array_elements(public.admin_merchant_upcoming_settlements(m.id)) u
      ) x
      where x.cur > 0.005
    ) mon on true
    where (o.accrued_usd > 0 or o.upcoming_usd > 0)
      and (p_merchant_id is null or m.id = p_merchant_id)
  ) q;

  return v_rows;
end;
$function$;
