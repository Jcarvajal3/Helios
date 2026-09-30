-- ============================================================================
-- Ronda — La deuda vencida de la semana dice cuántos usuarios la deben
--
-- AUD-OPERACION (27-09): la tarjeta «Vencido» de Inicio enseñaba lo vencido
-- de la semana (sin la deuda dada por perdida) y, en el pie, los usuarios con
-- algo vencido de la cola de Por cobrar, que SÍ cuenta lo perdido. En dev:
-- €777,73 de 44 usuarios, y el pie decía 46. Una cifra y su gente tienen que
-- salir de la misma cuenta.
--
-- Cada semana gana dos claves, sin quitar ninguna:
--   * overdue_users: usuarios distintos (installments.user_id) con alguna
--     cuota vencida y sin pagar al cierre, sin lo dado por perdido. Es la
--     gente de overdue_debt_usd.
--   * open_users: lo mismo de la deuda viva (open_debt_usd).
--
-- Misma firma y misma cuenta (las mismas cuotas en el mismo corte). Copiada
-- de 20260927652000, la última que la define, con solo esto añadido.
-- ============================================================================

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
    select i.amount_usd, i.financed_usd, i.due_date, i.status, i.paid_at, i.written_off_at,
           i.user_id, c.business_date as dia
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
      -- El desglose de las dos deudas: consumo + service fee (con su IVA).
      coalesce(mo.viva_fin, 0)                                    as open_financed_usd,
      coalesce(mo.viva, 0) - coalesce(mo.viva_fin, 0)             as open_fee_usd,
      coalesce(mo.vencida_fin, 0)                                 as overdue_financed_usd,
      coalesce(mo.vencida, 0) - coalesce(mo.vencida_fin, 0)       as overdue_fee_usd,
      case when coalesce(mo.viva, 0) > 0
        then round(100 * mo.vencida / mo.viva, 2) end            as overdue_pct,
      -- La gente de las dos deudas, por sus cuotas: la de lo vencido es la de
      -- overdue_debt_usd (sin lo dado por perdido), no la de la cola de cobro.
      coalesce(mo.gente_vencida, 0)                               as overdue_users,
      coalesce(mo.gente_viva, 0)                                  as open_users
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
        coalesce(sum(v.amount_usd) filter (where v.due_date < s.vence_antes), 0) as vencida,
        -- Lo mismo en consumo, para el desglose: fee = deuda − consumo.
        sum(v.financed_usd)                                      as viva_fin,
        coalesce(sum(v.financed_usd) filter (where v.due_date < s.vence_antes), 0) as vencida_fin,
        count(distinct v.user_id)::integer                       as gente_viva,
        count(distinct v.user_id) filter (where v.due_date < s.vence_antes)::integer as gente_vencida
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
  'Una fila por semana operativa (lunes a domingo): consumo (sin fee), consumos, service fee sin IVA, cargos por atraso, gente, locales, registros, primeros consumos, dado por perdido y la mora al cierre. La deuda viva y la vencida al cierre (payable) llevan su desglose: open_/overdue_financed_usd (consumo) y open_/overdue_fee_usd (service fee con IVA), y su gente: open_users y overdue_users (usuarios por sus cuotas, sin lo dado por perdido). Sin cuentas de prueba.';

revoke all on function public.admin_weekly_summary(integer) from public, anon;
grant execute on function public.admin_weekly_summary(integer) to authenticated;
