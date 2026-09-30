-- ============================================================================
-- Ronda — El resumen y las cosechas leen las métricas
--
-- `admin_overview` y `admin_credit_cohorts` arrastraban claves viejas que
-- decían una cosa y valían otra: `volume.financed_usd` sumaba la deuda con el
-- servicio y su IVA dentro, `volume.active_users` y `user_count` contaban a
-- quien abrió la cuenta, `bad_debt.financed_usd` era deuda. Nadie en el panel
-- las lee ya (el asistente las tapa), pero una clave que miente es una trampa
-- para el siguiente que la lea. Ahora valen lo que dicen, leídas de
-- `metricas` (20260927500000):
--
--   admin_overview
--     volume    financed_usd, previous_usd y avg_ticket_usd en consumo, sin
--               servicio (= financed_volume_usd, previous_financed_volume_usd,
--               avg_ticket_financed_usd); active_users = personas con cuota
--               (= active_people). Nueva: account_openers, quien abrió la
--               cuenta, con su nombre de verdad.
--     arrears   la misma mora de siempre (vencido ÷ vencido + por vencer),
--               sacada de metricas.cartera_al. Nuevas: el desglose financed +
--               fee de lo vivo y de lo vencido.
--     bad_debt  todo en consumo: written_off_usd, financed_usd, window_usd y
--               rate_pct valen lo mismo que sus gemelas *_financed_*. «Dado por
--               perdido» es lo perdido y SIN pagar: lo que se recupera después
--               deja de contar. Nuevas: written_off_debt_usd y
--               written_off_fee_usd (lo mismo en deuda, con su desglose).
--     users     los REGISTROS (metricas.personas: perfil real con el teléfono
--               confirmado), como Crecimiento y Métricas. Contaba todos los
--               perfiles, también los números que pidieron el código por SMS y
--               nunca lo metieron, y `new_in_window` cortaba por la medianoche
--               UTC en vez de por el día operativo. Nueva: unconfirmed_phone,
--               esos perfiles que no llegaron a registrarse.
--   admin_credit_cohorts
--     user_count = personas con cuota (= people_count); financed_usd en
--     consumo (= financed_volume_usd). Las demás cifras en deuda siguen igual
--     y `billed_debt_usd` sigue siendo la deuda facturada. Lo «dado por
--     perdido» es lo perdido y sin pagar.
-- ============================================================================

create or replace function public.admin_overview(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today     date    := metricas.hoy();
  v_days      integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_from      date;
  v_prev_from date;
  v_count     integer;
  v_openers   integer;
  v_fin       numeric;
  v_prev_fin  numeric;
  v_people    integer;
  v_cartera   record;
  v_result    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from      := v_today - (v_days - 1);
  v_prev_from := v_from - v_days;

  -- El consumo de la ventana y de la anterior, sin el servicio de Ronda.
  select coalesce(sum(k.financed_usd) filter (where k.business_date >= v_from), 0),
         coalesce(sum(k.financed_usd) filter (where k.business_date <  v_from), 0),
         (count(*) filter (where k.business_date >= v_from))::integer,
         (count(distinct k.abrio_user_id) filter (where k.business_date >= v_from))::integer
    into v_fin, v_prev_fin, v_count, v_openers
  from metricas.consumos k
  where k.business_date between v_prev_from and v_today;

  -- La gente: todos los que tienen cuota, no quien abrió la cuenta.
  select count(distinct q.user_id)::integer into v_people
  from metricas.cuotas q
  where q.business_date between v_from and v_today;

  v_result := jsonb_build_object(
    'business_date', v_today,
    'window_days',   v_days,
    'volume', jsonb_build_object(
      'financed_usd',   v_fin,
      'previous_usd',   v_prev_fin,
      'charge_count',   v_count,
      'active_users',   v_people,
      'avg_ticket_usd', case when v_count > 0 then round(v_fin / v_count, 2) else 0 end,
      'financed_volume_usd',          v_fin,
      'previous_financed_volume_usd', v_prev_fin,
      'financed_change_pct', case when v_prev_fin > 0
        then round(100 * (v_fin - v_prev_fin) / v_prev_fin, 1) else null end,
      'avg_ticket_financed_usd', case when v_count > 0 then round(v_fin / v_count, 2) else null end,
      'active_people',   v_people,
      -- Quien abrió la cuenta. En un consumo de grupo pagan más.
      'account_openers', v_openers
    )
  );

  -- La mora. Es *el* número del negocio (docs/00-BASES §1.2). Sobre lo que
  -- todavía se puede cobrar: lo dado por perdido tiene su cifra aparte.
  select * into v_cartera from metricas.cartera_al(v_today);

  v_result := v_result || jsonb_build_object('arrears', (
    select jsonb_build_object(
      'open_usd',             v_cartera.vencido_payable_usd + v_cartera.por_vencer_payable_usd,
      'open_financed_usd',    v_cartera.vencido_financed_usd + v_cartera.por_vencer_financed_usd,
      'open_fee_usd',         v_cartera.vencido_fee_usd + v_cartera.por_vencer_fee_usd,
      'overdue_usd',          v_cartera.vencido_payable_usd,
      'overdue_financed_usd', v_cartera.vencido_financed_usd,
      'overdue_fee_usd',      v_cartera.vencido_fee_usd,
      'overdue_users',        v_cartera.personas_vencidas,
      'due_today_usd',        coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'por_vencer' and q.due_date = v_today), 0),
      'rate_pct',             coalesce(v_cartera.mora_pct, 0),
      -- Tramos de la escalera de consecuencias (docs/06 §3), leídos de los
      -- parámetros: la escalera ya se alargó una vez.
      'demotion_days',        public.helios_mora_demotion_days(),
      'expulsion_days',       public.helios_mora_expulsion_days(),
      'bucket_frozen_usd',    coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'vencida'
                                   and q.dias_atraso <= public.helios_mora_demotion_days()), 0),
      'bucket_demotion_usd',  coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'vencida'
                                   and q.dias_atraso >  public.helios_mora_demotion_days()
                                   and q.dias_atraso <= public.helios_mora_expulsion_days()), 0),
      'bucket_expulsion_usd', coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'vencida'
                                   and q.dias_atraso >  public.helios_mora_expulsion_days()), 0)
    )
    from metricas.cuotas q
    where q.estado_hoy in ('vencida', 'por_vencer')
  ));

  -- Impago: lo dado por perdido, en consumo. La tasa va sobre TODO lo
  -- financiado en la historia y no sobre la ventana: lo que se pierde hoy
  -- nació hace dos o tres meses. El comparable cosecha a cosecha es
  -- `admin_credit_cohorts`.
  v_result := v_result || jsonb_build_object('bad_debt', (
    select jsonb_build_object(
      'written_off_usd',          coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'perdida'), 0),
      'written_off_users',        count(distinct q.user_id) filter (where q.estado_hoy = 'perdida'),
      'financed_usd',             coalesce(sum(q.financed_usd), 0),
      'window_usd',               coalesce(sum(q.financed_usd) filter (
                                     where q.estado_hoy = 'perdida'
                                       and public.helios_business_date(q.written_off_at) between v_from and v_today), 0),
      'rate_pct', case
        when coalesce(sum(q.financed_usd), 0) > 0
        then round(100 * coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'perdida'), 0)
                       / sum(q.financed_usd), 2)
        else 0 end,
      'written_off_financed_usd', coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'perdida'), 0),
      'lifetime_financed_usd',    coalesce(sum(q.financed_usd), 0),
      'window_financed_usd',      coalesce(sum(q.financed_usd) filter (
                                     where q.estado_hoy = 'perdida'
                                       and public.helios_business_date(q.written_off_at) between v_from and v_today), 0),
      'rate_financed_pct', case
        when coalesce(sum(q.financed_usd), 0) > 0
        then round(100 * coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'perdida'), 0)
                       / sum(q.financed_usd), 2)
        else null end,
      -- Lo mismo en deuda (payable), con su desglose.
      'written_off_debt_usd',     coalesce(sum(q.payable_usd) filter (where q.estado_hoy = 'perdida'), 0),
      'written_off_fee_usd',      coalesce(sum(q.fee_usd) filter (where q.estado_hoy = 'perdida'), 0),
      -- El impago con el que Ronda ni gana ni pierde. Ronda gana el servicio y,
      -- cuando alguien no paga, pierde el neto que ya le transfirió al local
      -- (docs/05 §3): empatan en  d = servicio / (servicio + neto).  El IVA no
      -- entra por ningún lado: se cobra y se remite.
      'break_even_pct', (
        select case
          when coalesce(sum(k.neto_local_usd + k.servicio_usd), 0) > 0
          then round(100 * sum(k.servicio_usd) / sum(k.neto_local_usd + k.servicio_usd), 2)
          else null end
        from metricas.consumos k
      )
    )
    from metricas.cuotas q
  ));

  -- Los registros por estado. `frozen`/`suspended`/`expelled` son la salida
  -- del motor de mora, así que esta línea es su marcador.
  v_result := v_result || jsonb_build_object('users', (
    select jsonb_build_object(
      'total',         count(*),
      'pending_kyc',   count(*) filter (where p.estado in ('pending_kyc', 'pending_pin')),
      'active',        count(*) filter (where p.estado = 'active'),
      'frozen',        count(*) filter (where p.estado = 'frozen'),
      'suspended',     count(*) filter (where p.estado = 'suspended'),
      'expelled',      count(*) filter (where p.estado = 'expelled'),
      'blacklisted',   count(*) filter (where pr.is_blacklisted),
      'new_in_window', count(*) filter (where p.registro_dia between v_from and v_today),
      -- Perfiles que pidieron el código por SMS y nunca lo metieron: no son
      -- registros, pero el hueco es la única señal de que los SMS no llegan.
      'unconfirmed_phone', (
        select count(*) from public.profiles x
        where not x.is_test
          and not exists (select 1 from metricas.personas y where y.user_id = x.id)
      )
    )
    from metricas.personas p
    join public.profiles pr on pr.id = p.user_id
  ));

  -- Embudo de KYC. La tasa de aprobación y el tamaño de la cola manual son
  -- las dos cifras que deciden si hace falta más gente revisando.
  v_result := v_result || jsonb_build_object('kyc', (
    select jsonb_build_object(
      'pending_review', count(*) filter (where v.status = 'manual_review'),
      'processing',     count(*) filter (where v.status = 'processing'),
      'approved',       count(*) filter (where v.status = 'approved'),
      'rejected',       count(*) filter (where v.status = 'rejected'),
      'approval_rate_pct', case
        when count(*) filter (where v.status in ('approved', 'rejected')) > 0
        then round(100.0 * count(*) filter (where v.status = 'approved')
                        / count(*) filter (where v.status in ('approved', 'rejected')), 1)
        else null end,
      'oldest_pending_hours', coalesce(round(extract(epoch from
        (now() - min(v.created_at) filter (where v.status = 'manual_review'))) / 3600.0, 1), 0)
    )
    from kyc.verifications v
    where not public.helios_is_test_user(v.user_id)
  ));

  -- Colas de trabajo. Lo que se les debe a los locales es el resto de lo
  -- pendiente Y de lo pagado a medias, como `helios_settlement_outlook`.
  v_result := v_result || jsonb_build_object('queues', jsonb_build_object(
    'payments_to_reconcile', (
      select count(*) from public.payment_reports r
      where r.status in ('reported', 'in_review')
        and not public.helios_is_test_user(r.user_id)
    ),
    'merchant_payouts_due', (
      select coalesce(sum(s.amount_usd - s.paid_usd), 0) from public.settlements s
      where s.status in ('pending', 'partial') and s.due_date <= v_today
        and not public.helios_is_test_merchant(s.merchant_id)
    ),
    'merchant_payouts_pending', (
      select coalesce(sum(s.amount_usd - s.paid_usd), 0) from public.settlements s
      where s.status in ('pending', 'partial')
        and not public.helios_is_test_merchant(s.merchant_id)
    )
  ));

  v_result := v_result || jsonb_build_object('merchants', (
    select jsonb_build_object(
      'total',      count(*),
      'active',     count(*) filter (where m.status = 'active'),
      'paused',     count(*) filter (where m.status = 'paused'),
      'terminated', count(*) filter (where m.status = 'terminated'),
      'selling_in_window', (
        select count(distinct k.merchant_id) from metricas.consumos k
        where k.business_date between v_from and v_today
      )
    )
    from public.merchants m
    where not m.is_test
  ));

  -- Tasa BCV: si lleva más de 48 h sin actualizarse, el scraper se rompió y se
  -- está cobrando a una tasa vieja (docs/05 §1).
  v_result := v_result || jsonb_build_object('fx', (
    select jsonb_build_object(
      'rate',           e.rate,
      'effective_date', e.effective_date,
      'fetched_at',     e.fetched_at,
      'age_hours',      round(extract(epoch from (now() - e.fetched_at)) / 3600.0, 1),
      'stale',          (now() - e.fetched_at) > interval '48 hours'
    )
    from public.exchange_rates e
    order by e.effective_date desc limit 1
  ));

  v_result := v_result || jsonb_build_object('cash', public.admin_cash_position());

  return v_result;
end;
$$;

comment on function public.admin_overview(integer) is
  'El pulso del negocio: consumo de la ventana y la anterior (sin servicio), personas con cuota, la mora canónica con sus tramos, el impago en consumo con su punto de empate, los registros por estado, KYC, colas, locales, tasa BCV y caja. Lee de metricas.';

revoke all on function public.admin_overview(integer) from public, anon;
grant execute on function public.admin_overview(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Las cosechas por mes
-- ---------------------------------------------------------------------------

create or replace function public.admin_credit_cohorts(p_months integer default 6)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date    := metricas.hoy();
  v_months integer := greatest(least(coalesce(p_months, 6), 24), 1);
  v_from   date;
  -- Cuántos días tarda una cosecha en tener su número definitivo: lo que tarda
  -- la última cuota en vencer, más la escalera entera.
  v_season integer := 2 * public.helios_installment_interval_days()
                    + public.helios_mora_expulsion_days();
  v_rows   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := (date_trunc('month', v_today::timestamp)
             - ((v_months - 1) * interval '1 month'))::date;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.month desc), '[]'::jsonb)
  into v_rows
  from (
    select
      to_char(date_trunc('month', q.business_date::timestamp), 'YYYY-MM')   as month,
      count(distinct q.charge_id)::integer                                   as charge_count,
      -- Personas con cuota, no quien abrió la cuenta.
      count(distinct q.user_id)::integer                                     as user_count,
      -- Consumo, sin el servicio (la deuda facturada es billed_debt_usd).
      sum(q.financed_usd)                                                    as financed_usd,
      -- En deuda (payable), con el servicio y su IVA dentro:
      sum(q.payable_usd) filter (where q.status = 'paid')                    as paid_usd,
      sum(q.payable_usd) filter (where q.estado_hoy = 'vencida')             as overdue_usd,
      sum(q.payable_usd) filter (where q.estado_hoy = 'por_vencer')          as current_usd,
      sum(q.payable_usd) filter (where q.estado_hoy = 'perdida')             as written_off_usd,
      -- Deuda vencida sobre TODA la deuda que facturó la cosecha. No es la
      -- mora de la cartera (vencido ÷ lo vivo): una cosecha vieja casi
      -- pagada tendría ahí un 100 % con un euro vencido.
      round(100 * sum(q.payable_usd) filter (where q.estado_hoy = 'vencida')
                / nullif(sum(q.payable_usd), 0), 2)                          as overdue_pct,
      round(100 * sum(q.payable_usd) filter (where q.estado_hoy = 'perdida')
                / nullif(sum(q.payable_usd), 0), 2)                          as written_off_pct,
      -- Una cosecha joven da 0 % de impago por construcción, no por mérito.
      (max(q.business_date) + v_season) <= v_today                          as matured,
      sum(q.payable_usd)                                                     as billed_debt_usd,
      sum(q.financed_usd)                                                    as financed_volume_usd,
      coalesce(sum(q.financed_usd) filter (where q.status = 'paid'), 0)      as paid_financed_usd,
      coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'vencida'), 0)    as overdue_financed_usd,
      coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'por_vencer'), 0) as current_financed_usd,
      coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'perdida'), 0)    as written_off_financed_usd,
      -- El impago, consumo perdido sobre consumo.
      round(100 * coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'perdida'), 0)
                / nullif(sum(q.financed_usd), 0), 2)                         as written_off_financed_pct,
      count(distinct q.user_id)::integer                                     as people_count
    from metricas.cuotas q
    where q.business_date >= v_from
    group by 1
  ) r;

  return jsonb_build_object(
    'business_date',  v_today,
    'months',         v_months,
    'season_days',    v_season,
    'expulsion_days', public.helios_mora_expulsion_days(),
    'rows',           v_rows
  );
end;
$$;

comment on function public.admin_credit_cohorts(integer) is
  'Una fila por mes de consumo: consumos, personas con cuota, consumo (financed) y deuda (payable) cobrada, vencida, viva y perdida, con el impago en consumo. Lee de metricas.';

revoke all on function public.admin_credit_cohorts(integer) from public, anon;
grant execute on function public.admin_credit_cohorts(integer) to authenticated;
