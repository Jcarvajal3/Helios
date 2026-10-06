-- ============================================================================
-- Helios — A la clínica se le paga a los 8 y a los 15 días
--
-- Regla del negocio publicada el 2026-10-06 (Javier): el médico o el centro
-- recibe su dinero en dos partes, **a los 8 y a los 15 días** de la consulta,
-- pague el paciente o no. Hasta hoy era la regla de Ronda: cada mitad se
-- devengaba al vencer su cuota (días 7 y 14) y se pagaba todo junto en el
-- cierre del lunes siguiente, así que la clínica cobraba entre 8 y 20 días
-- después.
--
-- El devengo no cambia: el cron de las 10:10 sigue creando la liquidación de
-- cada mitad el día en que vence la cuota del paciente (`due_date` = día 7 o
-- 14) y la comisión de la secretaria el día en que el paciente confirma. Lo
-- que cambia es **cuándo toca pagarla**: el día siguiente a su vencimiento, y
-- no el lunes. La consulta del día 0 se le paga a la clínica el día 8 y el 15;
-- la comisión, el día 1.
--
-- Todo el calendario del pago a la clínica vive en dos funciones, a propósito
-- (20260902120000): `helios_settlement_run_for(due_date)` y
-- `helios_next_settlement_run(ts)`. Se redefinen y las ~20 lecturas que las
-- usan (outlook de la clínica, cola de pagos del superadmin, historial,
-- exportaciones, detalle de la orden) pasan solas al calendario diario. Se
-- conservan los nombres para no tocar esas lecturas; «cierre» pasa a ser el
-- pago de un día.
--
-- Solo las tres previsiones de caja agrupaban por «el lunes del cierre» y se
-- ajustan: lo que sale a las clínicas se agrupa por la semana (de lunes a
-- domingo) del día en que toca pagarlo.
--
-- Los días son corridos: si el día 8 cae en sábado, domingo o feriado, el
-- pago toca ese día (Pago Móvil y transferencias entre bancos salen igual).
-- La foto semanal de la previsión (`helios_cash_forecast_snapshot`, lunes) se
-- queda como está.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El calendario: el día siguiente al vencimiento
-- ---------------------------------------------------------------------------

create or replace function public.helios_settlement_run_for(p_due_date date)
returns date
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select p_due_date + 1;
$$;

comment on function public.helios_settlement_run_for(date) is
  'Día en que se le paga a la clínica una liquidación que vence ese día operativo: el siguiente (cuotas del día 7 y 14 → pagos del día 8 y 15). Antes de 2026-10-06, el lunes siguiente.';

/**
 * El pago que viene: hoy. Lo de días anteriores sin transferir está atrasado;
 * lo que vence hoy toca mañana.
 */
create or replace function public.helios_next_settlement_run(p_ts timestamptz)
returns date
language sql
stable
set search_path = public, pg_temp
as $$
  select public.helios_business_date(p_ts);
$$;

comment on function public.helios_next_settlement_run(timestamptz) is
  'Día del próximo pago a las clínicas: el día operativo de p_ts (se paga a diario desde 2026-10-06).';

-- ---------------------------------------------------------------------------
-- 2. Las previsiones de caja, por semana del día de pago
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.helios_cash_forecast(p_today date, p_first_week date, p_rows integer, p_due_until date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_grace   integer := public.helios_on_time_grace_days();
  v_on_time numeric;
  v_cash    numeric;
  v_rows    jsonb;
begin
  -- El cobro a tiempo de los últimos 90 días, que es el multiplicador: el
  -- CANÓNICO de Métricas (metricas.cuotas_al), el mismo «Cobrado a tiempo»
  -- que enseñan Cobros, Mora y Locales. Solo se juzgan las cuotas con el
  -- plazo cerrado (vencimiento + gracia < hoy) y un pago cuenta el día en que
  -- se REPORTÓ. Sin historia suficiente (menos de 20 cuotas juzgadas) se usa
  -- 1: es preferible una proyección optimista y señalada como tal que un
  -- número sacado de cuatro cuotas.
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
      -- Lo que vence a los usuarios cada semana.
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
      -- Lo que sale a las clínicas, por la semana del día en que le toca a
      -- cada liquidación (el siguiente a su vencimiento). Lo atrasado cae en
      -- la primera semana: sigue teniendo que salir.
      select
        greatest(
          date_trunc('week', public.helios_settlement_run_for(st.due_date)::timestamp)::date,
          p_first_week
        ) as semana,
        sum(st.amount_usd - st.paid_usd) as usd
      from public.settlements st
      join public.merchants m on m.id = st.merchant_id
      where st.status in ('pending', 'partial')
        and not m.is_test
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

CREATE OR REPLACE FUNCTION metricas.caja_proyeccion(p_hoy date, p_primera date, p_semanas integer, p_hasta date, p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(week_start date, vence_payable_usd numeric, vence_financed_usd numeric, vence_fee_usd numeric, sale_usd numeric)
 LANGUAGE sql
 STABLE
AS $function$
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
    -- Lo que vence a los usuarios cada semana: cuotas por vencer (sin pagar,
    -- no perdidas, con vencimiento de hoy en adelante).
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
    -- Lo que sale a las clínicas, por la semana del día en que le toca a cada
    -- liquidación (el siguiente a su vencimiento). Lo atrasado cae en la
    -- primera semana.
    select greatest(
             date_trunc('week', public.helios_settlement_run_for(st.due_date)::timestamp)::date,
             p_primera
           ) as semana,
           sum(st.amount_usd - st.paid_usd) as usd
    from public.settlements st
    join public.merchants m on m.id = st.merchant_id
    where st.status in ('pending', 'partial')
      and not m.is_test
      and (p_merchant_id is null or st.merchant_id = p_merchant_id)
    group by 1
  ) o on o.semana = s.semana;
$function$;

CREATE OR REPLACE FUNCTION public.admin_cash_forecast(p_weeks integer DEFAULT 4, p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today  date := public.helios_business_date(now());
  v_weeks  integer := greatest(least(coalesce(p_weeks, 4), 12), 1);
  v_lunes  date := date_trunc('week', public.helios_business_date(now())::timestamp)::date;
  v_f      jsonb;
  v_factor numeric;
  v_rows   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- Las semanas van de lunes a domingo y la primera es la de hoy. Desde el
  -- 2026-10-06 a la clínica se le paga a diario (el día siguiente a cada
  -- vencimiento): ya no hay «lunes del cierre» con el que alinearlas.
  -- La caja de hoy, el cobro a tiempo que multiplica y la gracia salen de la
  -- proyección de siempre (la foto que se guarda cada lunes).
  v_f := public.helios_cash_forecast(v_today, v_lunes, v_weeks + 1, v_today + (v_weeks * 7));
  v_factor := (v_f ->> 'on_time_factor')::numeric;

  select coalesce(jsonb_agg(jsonb_build_object(
    'week_start',                p.week_start,
    'week_end',                  p.week_start + 6,
    'expected_gross_usd',        p.vence_payable_usd,
    'expected_gross_financed_usd', p.vence_financed_usd,
    'expected_gross_fee_usd',    p.vence_fee_usd,
    'expected_in_usd',           round(p.vence_payable_usd * coalesce(v_factor, 1), 2),
    'expected_in_financed_usd',  round(p.vence_financed_usd * coalesce(v_factor, 1), 2),
    'expected_in_fee_usd',       round(p.vence_payable_usd * coalesce(v_factor, 1), 2)
                                   - round(p.vence_financed_usd * coalesce(v_factor, 1), 2),
    'expected_out_usd',          p.sale_usd,
    'net_usd',                   round(p.vence_payable_usd * coalesce(v_factor, 1) - p.sale_usd, 2)
  ) order by p.week_start), '[]'::jsonb)
  into v_rows
  from metricas.caja_proyeccion(v_today, v_lunes, v_weeks + 1, v_today + (v_weeks * 7), p_merchant_id) p;

  return jsonb_build_object(
    'business_date', v_today,
    'merchant_id', p_merchant_id,
    -- La caja es de todo Ronda: con local no hay caja de partida.
    'cash_now_usd', case when p_merchant_id is null then v_f -> 'cash_now_usd' end,
    'weeks', v_weeks,
    -- Null cuando no hay historia suficiente. Es el de toda la cartera,
    -- también con un local: el de uno solo tendría muy pocas cuotas.
    'on_time_factor', v_f -> 'on_time_factor',
    'grace_days', v_f -> 'grace_days',
    'rows', v_rows
  );
end;
$function$;
