-- ============================================================================
-- Ronda — Cuánto deja cada 100 € financiados
--
-- La pregunta de Gerencia es por cada 100 € que Ronda adelanta a los locales,
-- cuánto vuelve como servicio, cuánto como cargos por atraso y cuánto se
-- pierde. `admin_overview` no la contesta limpia: su «financiado» suma
-- `charges.amount_usd`, que lleva el fee dentro, y su impago es el acumulado
-- de toda la historia, no el de un periodo.
--
-- ── Por cosecha ─────────────────────────────────────────────────────────────
-- Todo sale de los consumos del periodo y de lo que les pasó después, como en
-- `admin_credit_cohorts`: el servicio de esos consumos, los cargos por atraso
-- de sus cuotas y lo que de ellas se dio por perdido. Dividir lo perdido este
-- mes entre lo vendido este mes mezclaría cosechas distintas. El precio es
-- que un periodo reciente no tiene todavía su impago: `matured` dice si ya
-- pasó la escalera entera.
--
-- Cada cifra va por su lado. Aquí no hay ningún total que sume consumo y fee.
-- ============================================================================

create or replace function public.admin_unit_economics(
  p_from date default null,
  p_to   date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date    := public.helios_business_date(now());
  v_season integer := 2 * public.helios_installment_interval_days()
                    + public.helios_mora_expulsion_days();
  v_from   date;
  v_to     date;
  v_days   integer;
  v_out    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select w.desde, w.hasta, w.dias into v_from, v_to, v_days
  from public.helios_growth_window(p_from, p_to) w;

  with
  cargo as (
    select c.id,
           coalesce(c.consumer_fee_usd, 0) as fee,
           c.merchant_net_usd,
           c.amount_usd
    from public.charges c
    where c.status = 'confirmed'
      and not c.is_test
      and c.business_date between v_from and v_to
  ),
  cuota as (
    select i.id, i.financed_usd, i.written_off_at
    from public.installments i
    join cargo c on c.id = i.charge_id
    where not i.is_test
  ),
  -- Los cargos por atraso de esas cuotas. Los condonados no son ingreso.
  atraso as (
    select lf.amount_usd, lf.status
    from public.late_fees lf
    join cuota q on q.id = lf.installment_id
    where lf.waived_at is null
  ),
  cifra as (
    select
      (select coalesce(sum(q.financed_usd), 0) from cuota q)                                   as financiado,
      (select count(*) from cargo)                                                              as consumos,
      (select coalesce(sum(c.fee), 0) from cargo c)                                             as servicio,
      (select coalesce(sum(a.amount_usd), 0) from atraso a)                                     as atraso,
      (select coalesce(sum(a.amount_usd) filter (where a.status = 'paid'), 0) from atraso a)    as atraso_cobrado,
      (select coalesce(sum(q.financed_usd) filter (where q.written_off_at is not null), 0) from cuota q) as perdido,
      -- El mismo punto de empate que `admin_overview`, sobre los consumos del
      -- periodo: fee / (neto transferido al local + fee).
      (select case
         when coalesce(sum(coalesce(c.merchant_net_usd, c.amount_usd) + c.fee), 0) > 0
         then round(100 * sum(c.fee) / sum(coalesce(c.merchant_net_usd, c.amount_usd) + c.fee), 2)
       end from cargo c)                                                                        as empate
  )
  select jsonb_build_object(
    'business_date',            v_today,
    'from',                     v_from,
    'to',                       v_to,
    'window_days',              v_days,
    'season_days',              v_season,
    -- El impago de un periodo solo es definitivo cuando su último consumo ya
    -- recorrió la escalera entera.
    'matured',                  (v_to + v_season) <= v_today,
    'financed_usd',             x.financiado,
    'charge_count',             x.consumos,
    'service_fee_usd',          x.servicio,
    'late_fee_usd',             x.atraso,
    'late_fee_collected_usd',   x.atraso_cobrado,
    'written_off_financed_usd', x.perdido,
    'written_off_pct',          round(100 * x.perdido / nullif(x.financiado, 0), 2),
    'break_even_pct',           x.empate,
    'per_100', case when x.financiado > 0 then jsonb_build_object(
      'service_fee_usd',          round(100 * x.servicio / x.financiado, 2),
      'late_fee_usd',             round(100 * x.atraso   / x.financiado, 2),
      'written_off_financed_usd', round(100 * x.perdido  / x.financiado, 2)
    ) end
  )
  into v_out
  from cifra x;

  return v_out;
end;
$$;

comment on function public.admin_unit_economics(date, date) is
  'Por cosecha de un periodo: financiado, servicio sin IVA, cargos por atraso y dado por perdido (financed), cada uno por 100 EUR financiados, y el punto de empate. Nunca un total de consumo mas fee. Sin cuentas de prueba.';

revoke all on function public.admin_unit_economics(date, date) from public, anon;
grant execute on function public.admin_unit_economics(date, date) to authenticated;
