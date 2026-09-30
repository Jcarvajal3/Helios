-- ============================================================================
-- Ronda — El resumen de la semana, y la serie diaria sin el fee
--
-- Gerencia lee el negocio por semanas: cuánto se financió, cuánto ganó Ronda,
-- cuánta gente y cuántos locales se movieron, cuánto se dio por perdido y cómo
-- cerró la mora. Y compara un día con el mismo día de la semana anterior, que
-- es la única comparación honesta en un negocio de noches de fin de semana.
--
-- ── La serie diaria tenía el fee dentro ─────────────────────────────────────
-- `admin_daily_series` existía y nadie la usaba, y por suerte: su
-- `financed_usd` sumaba `charges.amount_usd`, que lleva el servicio de Ronda y
-- su IVA. Un «financiado» con el fee sumado es justo el total que no se enseña
-- nunca. Se corrige (sale de `installments.financed_usd`) y se le añaden al
-- final las columnas que el resumen necesita por día. La firma no cambia; el
-- tipo de salida sí, y por eso se borra y se vuelve a crear.
--
-- ── Por qué la semana no suma días ──────────────────────────────────────────
-- Las personas y los locales de una semana no son la suma de los de cada día:
-- quien sale el viernes y el sábado cuenta una vez. Por eso el resumen semanal
-- se calcula sobre las filas y no sobre la serie diaria.
--
-- ── La mora al cierre ───────────────────────────────────────────────────────
-- Se reconstruye con las fechas de cada cuota: al cierre del domingo, lo que
-- había vencido y no estaba ni pagado ni dado por perdido, sobre lo que seguía
-- vivo. Es la misma cuenta que `admin_overview`, movida en el tiempo. Lo que
-- no puede ver es lo que ya no existe: las cuotas de un consumo revertido se
-- borran, y con ellas su pasado.
-- ============================================================================

drop function if exists public.admin_daily_series(integer);

create or replace function public.admin_daily_series(p_days integer default 30)
returns table (
  business_date            date,
  financed_usd             numeric,
  charge_count             integer,
  collected_usd            numeric,
  settled_usd              numeric,
  service_fee_usd          numeric,
  late_fee_usd             numeric,
  active_users             integer,
  merchants_with_sales     integer,
  new_users                integer,
  first_time_buyers        integer,
  written_off_financed_usd numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date    := public.helios_business_date(now());
  v_days  integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_from  date;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := v_today - (v_days - 1);

  return query
  with
  dias as (
    select generate_series(v_from, v_today, interval '1 day')::date as d
  ),
  cargo as (
    select ch.business_date as d,
           count(*)::integer                         as cnt,
           count(distinct ch.merchant_id)::integer   as locales,
           sum(coalesce(ch.consumer_fee_usd, 0))     as fee
    from public.charges ch
    where ch.status = 'confirmed' and not ch.is_test
      and ch.business_date between v_from and v_today
    group by 1
  ),
  cuota as (
    select ch.business_date as d,
           sum(i.financed_usd)                       as fin,
           count(distinct i.user_id)::integer        as gente
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    where ch.status = 'confirmed' and not ch.is_test and not i.is_test
      and ch.business_date between v_from and v_today
    group by 1
  ),
  cobrado as (
    -- Cobrado de verdad: cuotas aprobadas, por día operativo del cobro. Es
    -- deuda que vuelve, así que va en payable.
    select public.helios_business_date(i.paid_at) as d, sum(i.amount_usd) as cob
    from public.installments i
    where i.status = 'paid' and i.paid_at is not null and not i.is_test
      and i.paid_at >= public.helios_business_day_end(v_from - 1)
    group by 1
  ),
  pagado as (
    -- Salido de caja hacia los locales.
    select mp.business_date as d, sum(mp.amount_usd) as pag
    from public.merchant_payouts mp
    where not public.helios_is_test_merchant(mp.merchant_id)
      and mp.business_date between v_from and v_today
    group by 1
  ),
  atraso as (
    -- Cargos por atraso que cayeron ese día. Los condonados no son ingreso.
    select lf.business_date as d, sum(lf.amount_usd) as cargo
    from public.late_fees lf
    join public.profiles p on p.id = lf.user_id and not p.is_test
    where lf.waived_at is null
      and lf.business_date between v_from and v_today
    group by 1
  ),
  registro as (
    select s.dia as d, count(*)::integer as n
    from public.helios_signups s
    where s.dia between v_from and v_today
    group by 1
  ),
  primer as (
    select x.d, count(*)::integer as n
    from (
      select i.user_id, min(ch.business_date) as d
      from public.installments i
      join public.charges ch on ch.id = i.charge_id
      where ch.status = 'confirmed' and not ch.is_test and not i.is_test
      group by 1
    ) x
    where x.d between v_from and v_today
    group by 1
  ),
  perdido as (
    select public.helios_business_date(i.written_off_at) as d, sum(i.financed_usd) as fin
    from public.installments i
    where i.written_off_at is not null and not i.is_test
      and i.written_off_at >= public.helios_business_day_end(v_from - 1)
    group by 1
  )
  select
    dias.d,
    coalesce(cu.fin, 0)::numeric,
    coalesce(ca.cnt, 0)::integer,
    coalesce(co.cob, 0)::numeric,
    coalesce(pa.pag, 0)::numeric,
    coalesce(ca.fee, 0)::numeric,
    coalesce(at.cargo, 0)::numeric,
    coalesce(cu.gente, 0)::integer,
    coalesce(ca.locales, 0)::integer,
    coalesce(re.n, 0)::integer,
    coalesce(pr.n, 0)::integer,
    coalesce(pe.fin, 0)::numeric
  from dias
  left join cargo ca    on ca.d = dias.d
  left join cuota cu    on cu.d = dias.d
  left join cobrado co  on co.d = dias.d
  left join pagado pa   on pa.d = dias.d
  left join atraso at   on at.d = dias.d
  left join registro re on re.d = dias.d
  left join primer pr   on pr.d = dias.d
  left join perdido pe  on pe.d = dias.d
  order by dias.d;
end;
$$;

comment on function public.admin_daily_series(integer) is
  'Una fila por dia operativo: financiado (financed), consumos, cobrado (payable), pagado a locales, servicio sin IVA, cargos por atraso, gente, locales, registros, primeros consumos y dado por perdido (financed). Sin cuentas de prueba.';

revoke all on function public.admin_daily_series(integer) from public, anon;
grant execute on function public.admin_daily_series(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- El resumen semanal
-- ---------------------------------------------------------------------------

create or replace function public.admin_weekly_summary(p_weeks integer default 12)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today   date    := public.helios_business_date(now());
  v_weeks   integer := greatest(least(coalesce(p_weeks, 12), 52), 1);
  v_lunes   date;
  v_from    date;
  v_primer_corte timestamptz;
  v_rows    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_lunes := public.helios_cohort_bucket(v_today, 'week');
  v_from  := v_lunes - 7 * (v_weeks - 1);
  -- Una cuota pagada o dada por perdida antes del primer cierre no puede estar
  -- viva en ninguno: se descarta de entrada.
  v_primer_corte := least(public.helios_business_day_end(v_from + 6), now());

  with
  semana as (
    select
      s::date                                     as desde,
      (s::date + 6)                               as hasta,
      (s::date + 6) < v_today                     as completa,
      -- El cierre: el final del domingo operativo o, si la semana sigue en
      -- curso, ahora mismo.
      case when (s::date + 6) < v_today
        then public.helios_business_day_end(s::date + 6) else now() end as corte,
      -- Vencida al cierre = su día ya pasó entero.
      case when (s::date + 6) < v_today then s::date + 7 else v_today end as vence_antes,
      -- Hasta qué día operativo existían consumos en ese cierre.
      least(s::date + 6, v_today)                 as hasta_real
    from generate_series(v_from, v_lunes, interval '7 days') s
  ),
  consumo as (
    -- Una fila por persona y consumo: su parte, sin el fee.
    select i.user_id, c.id as charge_id, c.merchant_id, c.business_date as dia,
           sum(i.financed_usd) as fin
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.status = 'confirmed' and not c.is_test and not i.is_test
      and c.business_date >= v_from
    group by i.user_id, c.id
  ),
  cargo as (
    select c.id, c.business_date as dia, c.merchant_id,
           coalesce(c.consumer_fee_usd, 0) as fee
    from public.charges c
    where c.status = 'confirmed' and not c.is_test
      and c.business_date >= v_from
  ),
  primer as (
    select i.user_id, min(c.business_date) as dia
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.status = 'confirmed' and not c.is_test and not i.is_test
    group by 1
  ),
  atraso as (
    select lf.business_date as dia, lf.amount_usd, lf.paid_at, lf.status
    from public.late_fees lf
    join public.profiles p on p.id = lf.user_id and not p.is_test
    where lf.waived_at is null
  ),
  perdido as (
    select public.helios_business_date(i.written_off_at) as dia,
           i.financed_usd, i.amount_usd
    from public.installments i
    where i.written_off_at is not null and not i.is_test
      and i.written_off_at >= public.helios_business_day_end(v_from - 1)
  ),
  viva as (
    -- Las cuotas que pudieron estar vivas en algún cierre de la ventana.
    select i.amount_usd, i.due_date, i.status, i.paid_at, i.written_off_at,
           c.business_date as dia
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.status = 'confirmed' and not c.is_test and not i.is_test
      and (i.status = 'pending' or i.paid_at > v_primer_corte)
      and (i.written_off_at is null or i.written_off_at > v_primer_corte)
  )
  select coalesce(jsonb_agg(to_jsonb(r) order by r.week_start), '[]'::jsonb)
  into v_rows
  from (
    select
      s.desde                                                     as week_start,
      s.hasta                                                     as week_end,
      s.completa                                                  as complete,
      s.hasta_real - s.desde + 1                                  as days_elapsed,
      coalesce(co.fin, 0)                                         as financed_usd,
      coalesce(ca.n, 0)                                           as charge_count,
      coalesce(ca.fee, 0)                                         as service_fee_usd,
      coalesce(at.cargo, 0)                                       as late_fee_usd,
      coalesce(atc.cobrado, 0)                                    as late_fee_collected_usd,
      coalesce(co.gente, 0)                                       as active_users,
      coalesce(ca.locales, 0)                                     as merchants_with_sales,
      coalesce(re.n, 0)                                           as new_users,
      coalesce(pr.n, 0)                                           as first_time_buyers,
      coalesce(pe.fin, 0)                                         as written_off_financed_usd,
      coalesce(pe.deuda, 0)                                       as written_off_debt_usd,
      coalesce(mo.viva, 0)                                        as open_debt_usd,
      coalesce(mo.vencida, 0)                                     as overdue_debt_usd,
      case when coalesce(mo.viva, 0) > 0
        then round(100 * mo.vencida / mo.viva, 2) end            as overdue_pct
    from semana s
    left join lateral (
      select sum(x.fin) as fin, count(distinct x.user_id)::integer as gente
      from consumo x where x.dia between s.desde and s.hasta
    ) co on true
    left join lateral (
      select count(*)::integer as n, sum(x.fee) as fee,
             count(distinct x.merchant_id)::integer as locales
      from cargo x where x.dia between s.desde and s.hasta
    ) ca on true
    left join lateral (
      select sum(x.amount_usd) as cargo
      from atraso x where x.dia between s.desde and s.hasta
    ) at on true
    left join lateral (
      select sum(x.amount_usd) as cobrado
      from atraso x
      where x.status = 'paid' and x.paid_at is not null
        and public.helios_business_date(x.paid_at) between s.desde and s.hasta
    ) atc on true
    left join lateral (
      select count(*)::integer as n
      from public.helios_signups x where x.dia between s.desde and s.hasta
    ) re on true
    left join lateral (
      select count(*)::integer as n
      from primer x where x.dia between s.desde and s.hasta
    ) pr on true
    left join lateral (
      select sum(x.financed_usd) as fin, sum(x.amount_usd) as deuda
      from perdido x where x.dia between s.desde and s.hasta
    ) pe on true
    left join lateral (
      select
        sum(v.amount_usd)                                        as viva,
        coalesce(sum(v.amount_usd) filter (where v.due_date < s.vence_antes), 0) as vencida
      from viva v
      where v.dia <= s.hasta_real
        and not (v.status = 'paid' and (v.paid_at is null or v.paid_at <= s.corte))
        and not (v.written_off_at is not null and v.written_off_at <= s.corte)
    ) mo on true
  ) r;

  return jsonb_build_object(
    'business_date', v_today,
    'weeks',         v_weeks,
    'from',          v_from,
    'rows',          v_rows
  );
end;
$$;

comment on function public.admin_weekly_summary(integer) is
  'Una fila por semana operativa (lunes a domingo): financiado, consumos, servicio sin IVA, cargos por atraso, gente, locales, registros, primeros consumos, dado por perdido y la mora al cierre. Sin cuentas de prueba.';

revoke all on function public.admin_weekly_summary(integer) from public, anon;
grant execute on function public.admin_weekly_summary(integer) to authenticated;
