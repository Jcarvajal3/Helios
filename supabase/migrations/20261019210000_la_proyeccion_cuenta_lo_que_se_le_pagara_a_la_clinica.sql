-- ============================================================================
-- Helios — La proyección de caja cuenta lo que se le pagará a la clínica
--
-- La proyección sumaba como «sale» solo las liquidaciones que ya existían.
-- Pero la mitad de la clínica no existe hasta el día en que vence la cuota
-- del paciente (el cron de las 10:10, `run_scheduled_settlements_batch`), y a
-- la clínica se le paga el día siguiente pague o no el paciente. Así que lo
-- que salía era casi nada: el 2026-10-19 proyectaba $1,50 de salida en la
-- semana con unos $100 por pagar a las clínicas, y de la tercera semana en
-- adelante siempre 0.
--
-- 1. `metricas.mitades_por_devengar`: las mitades que todavía no se han
--    devengado, con el mismo cálculo que el cron (el neto de la consulta por
--    el % por cuota de las condiciones vigentes el día de la orden), en el día
--    en que se pagarán (`helios_settlement_run_for(vencimiento)`).
-- 2. Las dos proyecciones por semanas (`helios_cash_forecast` y
--    `metricas.caja_proyeccion`) suman esas mitades a lo que sale.
-- 3. `admin_cash_forecast_days`: la proyección día a día. Con dos cuotas a
--    los 7 y 14 días, todo lo que hoy está en la calle entra y sale en los
--    próximos 15 días: por semanas se veía una semana llena y el resto vacío.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las mitades por devengar
-- ---------------------------------------------------------------------------

create or replace function metricas.mitades_por_devengar(
  p_desde date,
  p_hasta date,
  p_merchant_id uuid default null
)
returns table(dia date, merchant_id uuid, usd numeric)
language sql
stable
set search_path = public, pg_temp
as $$
  -- Una por orden y día de vencimiento, como el cron (que recorre las
  -- órdenes con alguna cuota que vence ese día, pagada o no). Lo que ya se
  -- devengó está en `settlements` y no se cuenta dos veces.
  with x as (
    select distinct c.id as charge_id, c.merchant_id, i.due_date,
           coalesce(c.merchant_net_usd, c.amount_usd) as neto,
           coalesce(c.business_date, i.due_date) as dia_orden
    from public.installments i
    join public.charges c on c.id = i.charge_id
    join public.merchants m on m.id = c.merchant_id
    where i.due_date between p_desde and p_hasta
      and c.status = 'confirmed'
      and not i.is_test
      and not m.is_test
      and (p_merchant_id is null or c.merchant_id = p_merchant_id)
      and not exists (
        select 1 from public.settlements s
        where s.charge_id = c.id
          and s.reason = 'scheduled_installment'
          and s.business_date = i.due_date
      )
  )
  select public.helios_settlement_run_for(x.due_date) as dia,
         x.merchant_id,
         sum(round(x.neto * t.per_installment_pct / 100, 4)) as usd
  from x
  cross join lateral public.helios_terms_at(x.merchant_id, x.dia_orden) t
  where t.policy = 'scheduled'
  group by 1, 2;
$$;

comment on function metricas.mitades_por_devengar(date, date, uuid) is
  'Lo que se le pagará a cada clínica por las cuotas que vencen entre dos días y aún no se han devengado, en el día del pago (el siguiente al vencimiento).';

-- ---------------------------------------------------------------------------
-- 2. Las proyecciones por semanas
-- ---------------------------------------------------------------------------

create or replace function public.helios_cash_forecast(p_today date, p_first_week date, p_rows integer, p_due_until date)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_grace   integer := public.helios_on_time_grace_days();
  v_on_time numeric;
  v_cash    numeric;
  v_rows    jsonb;
begin
  -- El cobro a tiempo de los últimos 90 días, que es el multiplicador: el
  -- CANÓNICO de Métricas (metricas.cuotas_al), el mismo «Cobrado a tiempo»
  -- que enseñan Cobros, Mora y Clínicas. Solo se juzgan las cuotas con el
  -- plazo cerrado (vencimiento + gracia < hoy). Sin historia suficiente
  -- (menos de 20 cuotas juzgadas) se usa 1: es preferible una proyección
  -- optimista y señalada como tal que un número sacado de cuatro cuotas.
  select case
    when count(*) filter (where q.plazo_cerrado) >= 20
    then round(
      count(*) filter (where q.plazo_cerrado and q.estado_hoy = 'a_tiempo')::numeric
      / count(*) filter (where q.plazo_cerrado), 4)
    else null
  end
  into v_on_time
  from metricas.cuotas_al(p_today) q
  where q.due_date between p_today - 90 and p_today;

  v_cash := ledger.balance_by_type('cash');

  select coalesce(jsonb_agg(to_jsonb(q) order by q.week_start), '[]'::jsonb)
  into v_rows
  from (
    select
      s.semana                                   as week_start,
      s.semana + 6                               as week_end,
      coalesce(e.bruto, 0)                       as expected_gross_usd,
      round(coalesce(e.bruto, 0) * coalesce(v_on_time, 1), 2) as expected_in_usd,
      coalesce(o.usd, 0)                         as expected_out_usd,
      round(coalesce(e.bruto, 0) * coalesce(v_on_time, 1) - coalesce(o.usd, 0), 2) as net_usd
    from (
      select generate_series(
        p_first_week,
        p_first_week + ((greatest(p_rows, 1) - 1) * 7),
        interval '7 days'
      )::date as semana
    ) s
    left join (
      -- Lo que vence a los pacientes cada semana.
      select
        (date_trunc('week', i.due_date::timestamp))::date as semana,
        sum(i.amount_usd) as bruto
      from public.installments i
      where i.status = 'pending'
        and i.written_off_at is null
        and not i.is_test
        and i.due_date between p_today and p_due_until
      group by 1
    ) e on e.semana = s.semana
    left join (
      -- Lo que sale a las clínicas, por la semana del día en que le toca:
      -- las liquidaciones ya devengadas (lo atrasado cae en la primera
      -- semana: sigue teniendo que salir) y las mitades que se devengarán
      -- cuando venzan sus cuotas, pague o no el paciente.
      select
        greatest(date_trunc('week', o.dia::timestamp)::date, p_first_week) as semana,
        sum(o.usd) as usd
      from (
        select public.helios_settlement_run_for(st.due_date) as dia,
               st.amount_usd - st.paid_usd as usd
        from public.settlements st
        join public.merchants m on m.id = st.merchant_id
        where st.status in ('pending', 'partial')
          and not m.is_test
        union all
        select f.dia, f.usd
        from metricas.mitades_por_devengar(p_today, p_due_until) f
      ) o
      group by 1
    ) o on o.semana = s.semana
  ) q;

  return jsonb_build_object(
    'cash_now_usd', v_cash,
    'on_time_factor', v_on_time,
    'grace_days', v_grace,
    'rows', v_rows
  );
end;
$function$;

create or replace function metricas.caja_proyeccion(p_hoy date, p_primera date, p_semanas integer, p_hasta date, p_merchant_id uuid default null::uuid)
 returns table(week_start date, vence_payable_usd numeric, vence_financed_usd numeric, vence_fee_usd numeric, sale_usd numeric)
 language sql
 stable
as $function$
  select
    s.semana,
    coalesce(v.payable, 0),
    coalesce(v.financed, 0),
    coalesce(v.payable, 0) - coalesce(v.financed, 0),
    coalesce(o.usd, 0)
  from (
    select generate_series(
      p_primera,
      p_primera + ((greatest(p_semanas, 1) - 1) * 7),
      interval '7 days'
    )::date as semana
  ) s
  left join (
    -- Lo que vence a los pacientes cada semana: cuotas por vencer (sin
    -- pagar, no perdidas, con vencimiento de hoy en adelante).
    select date_trunc('week', q.due_date::timestamp)::date as semana,
           sum(q.payable_usd)  as payable,
           sum(q.financed_usd) as financed
    from metricas.cuotas q
    where q.estado_hoy = 'por_vencer'
      and q.due_date between p_hoy and p_hasta
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    group by 1
  ) v on v.semana = s.semana
  left join (
    -- Lo que sale a las clínicas, por la semana del día en que le toca: lo
    -- ya devengado (lo atrasado cae en la primera semana) y las mitades que
    -- se devengarán al vencer sus cuotas.
    select greatest(date_trunc('week', o.dia::timestamp)::date, p_primera) as semana,
           sum(o.usd) as usd
    from (
      select public.helios_settlement_run_for(st.due_date) as dia,
             st.amount_usd - st.paid_usd as usd
      from public.settlements st
      join public.merchants m on m.id = st.merchant_id
      where st.status in ('pending', 'partial')
        and not m.is_test
        and (p_merchant_id is null or st.merchant_id = p_merchant_id)
      union all
      select f.dia, f.usd
      from metricas.mitades_por_devengar(p_hoy, p_hasta, p_merchant_id) f
    ) o
    group by 1
  ) o on o.semana = s.semana;
$function$;

-- ---------------------------------------------------------------------------
-- 3. La proyección día a día
-- ---------------------------------------------------------------------------

create or replace function public.admin_cash_forecast_days(p_days integer default 15, p_merchant_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_days   integer := greatest(least(coalesce(p_days, 15), 31), 1);
  v_hasta  date;
  v_f      jsonb;
  v_factor numeric;
  v_rows   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_hasta := v_today + v_days - 1;

  -- La caja de hoy y el cobro a tiempo que multiplica salen de la proyección
  -- por semanas: una sola fuente para las dos vistas.
  v_f := public.helios_cash_forecast(v_today, date_trunc('week', v_today::timestamp)::date, 1, v_today);
  v_factor := (v_f ->> 'on_time_factor')::numeric;

  select coalesce(jsonb_agg(jsonb_build_object(
    'day',                         d.dia,
    'expected_gross_usd',          coalesce(v.payable, 0),
    'expected_gross_financed_usd', coalesce(v.financed, 0),
    'expected_gross_fee_usd',      coalesce(v.payable, 0) - coalesce(v.financed, 0),
    'expected_in_usd',             round(coalesce(v.payable, 0) * coalesce(v_factor, 1), 2),
    'expected_in_financed_usd',    round(coalesce(v.financed, 0) * coalesce(v_factor, 1), 2),
    'expected_in_fee_usd',         round(coalesce(v.payable, 0) * coalesce(v_factor, 1), 2)
                                     - round(coalesce(v.financed, 0) * coalesce(v_factor, 1), 2),
    'out_accrued_usd',             coalesce(o.devengado, 0),
    'out_to_accrue_usd',           coalesce(o.por_devengar, 0),
    'expected_out_usd',            coalesce(o.devengado, 0) + coalesce(o.por_devengar, 0),
    'net_usd',                     round(coalesce(v.payable, 0) * coalesce(v_factor, 1)
                                     - coalesce(o.devengado, 0) - coalesce(o.por_devengar, 0), 2)
  ) order by d.dia), '[]'::jsonb)
  into v_rows
  from (
    select generate_series(v_today, v_hasta, interval '1 day')::date as dia
  ) d
  left join (
    -- Lo que vence a los pacientes cada día.
    select q.due_date as dia,
           sum(q.payable_usd)  as payable,
           sum(q.financed_usd) as financed
    from metricas.cuotas q
    where q.estado_hoy = 'por_vencer'
      and q.due_date between v_today and v_hasta
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    group by 1
  ) v on v.dia = d.dia
  left join (
    -- Lo que sale a las clínicas el día en que toca pagarlo. Lo atrasado,
    -- hoy: sigue teniendo que salir.
    select greatest(o.dia, v_today) as dia,
           sum(o.usd) filter (where o.ya)     as devengado,
           sum(o.usd) filter (where not o.ya) as por_devengar
    from (
      select public.helios_settlement_run_for(st.due_date) as dia,
             st.amount_usd - st.paid_usd as usd,
             true as ya
      from public.settlements st
      join public.merchants m on m.id = st.merchant_id
      where st.status in ('pending', 'partial')
        and not m.is_test
        and (p_merchant_id is null or st.merchant_id = p_merchant_id)
      union all
      select f.dia, f.usd, false
      from metricas.mitades_por_devengar(v_today, v_hasta, p_merchant_id) f
    ) o
    group by 1
  ) o on o.dia = d.dia;

  return jsonb_build_object(
    'business_date', v_today,
    'merchant_id', p_merchant_id,
    -- La caja es de todo Helios: con una clínica no hay caja de partida.
    'cash_now_usd', case when p_merchant_id is null then v_f -> 'cash_now_usd' end,
    'days', v_days,
    -- Null cuando no hay historia suficiente. Es el de toda la cartera,
    -- también con una clínica: el de una sola tendría muy pocas cuotas.
    'on_time_factor', v_f -> 'on_time_factor',
    'grace_days', v_f -> 'grace_days',
    'rows', v_rows
  );
end;
$$;

comment on function public.admin_cash_forecast_days(integer, uuid) is
  'Proyección de caja día a día desde hoy (15 días por defecto): lo que vence a los pacientes, lo que se espera cobrar y lo que se le pagará a las clínicas (ya devengado y por devengar).';

revoke all on function public.admin_cash_forecast_days(integer, uuid) from public, anon;
grant execute on function public.admin_cash_forecast_days(integer, uuid) to authenticated;

-- Solo la leen las proyecciones de arriba, que corren como su dueño.
revoke all on function metricas.mitades_por_devengar(date, date, uuid) from public, anon, authenticated;
