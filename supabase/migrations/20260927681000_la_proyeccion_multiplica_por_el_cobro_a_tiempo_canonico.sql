-- ============================================================================
-- Ronda — La proyección de caja multiplica por el cobro a tiempo canónico
--
-- Repaso de rigor (AUD-CAJA-LOCALES-GENTE, 27-09). Métricas › Caja ›
-- Proyección dice «Lo que vence multiplicado por el cobro a tiempo
-- histórico, que hoy es del X %». Ese X no era el «Cobrado a tiempo» del
-- resto de Métricas:
--
--   * juzgaba por el día en que se APROBÓ el pago, no por el día en que se
--     reportó (decisión de Javier del 27-09, 20260927580000);
--   * metía en el denominador las cuotas que aún estaban dentro de la gracia
--     y sin pagar, que todavía pueden llegar a tiempo.
--
-- En dev el 27-09 daba 76,94 % donde el canónico de los mismos 90 días da
-- 80,34 % (519 a tiempo de 646 con el plazo cerrado). Ahora es el canónico:
-- metricas.cuotas_al(p_today), plazo_cerrado y estado 'a_tiempo'. Todo lo
-- demás (lo que vence, lo que sale a los locales, la caja de partida, la
-- firma y las claves) no cambia. Lo usan admin_cash_forecast y la foto de
-- cada lunes (helios_snapshot_cash_forecast): desde ahora la foto guarda el
-- factor canónico.
--
-- Copia de 20260925143000 (su última versión). La genera
-- <scratchpad AUD-CLG>/gen_681.cjs. Si alguien reaplica 20260925143000, hay
-- que reaplicar esta.
-- ============================================================================

create or replace function public.helios_cash_forecast(
  p_today      date,
  p_first_week date,
  p_rows       integer,
  p_due_until  date
)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $fn$
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
      -- Lo que sale a los locales, por el lunes en que le toca a cada
      -- liquidación. Lo atrasado cae en la primera semana: sigue teniendo que
      -- salir.
      select
        greatest(public.helios_settlement_run_for(st.due_date), p_first_week) as semana,
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
$fn$;

comment on function public.helios_cash_forecast(date, date, integer, date) is
  'La proyección de caja por semanas (interna). La usan admin_cash_forecast y la foto de los lunes.';

revoke all on function public.helios_cash_forecast(date, date, integer, date) from public, anon, authenticated;
