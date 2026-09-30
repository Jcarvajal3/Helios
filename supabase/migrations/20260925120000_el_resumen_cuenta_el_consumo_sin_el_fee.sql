-- ============================================================================
-- Ronda — El resumen cuenta el consumo sin el fee
--
-- `admin_overview` sumaba `charges.amount_usd` para el «volumen financiado»,
-- su ventana anterior y el ticket medio, y `installments.amount_usd` para el
-- «financiado» contra el que se mide el impago. Las dos llevan el servicio de
-- Ronda y su IVA dentro: un financiado con el fee sumado es justo el total que
-- no se enseña nunca.
--
-- Todo es aditivo, porque el panel de `main` también lee dev y lee esos
-- campos por su nombre:
--   volume   + financed_volume_usd, previous_financed_volume_usd,
--              financed_change_pct, avg_ticket_financed_usd, active_people
--   bad_debt + written_off_financed_usd, lifetime_financed_usd,
--              window_financed_usd, rate_financed_pct
-- Los viejos se quedan con su valor de siempre.
--
-- Lo que SÍ cambia de valor: `queues.merchant_payouts_due` y
-- `queues.merchant_payouts_pending`. Dicen «lo que se les debe a los locales»
-- y solo contaban las liquidaciones 'pending'; ahora cuentan el resto de las
-- 'pending' y de las 'partial'. Es un arreglo, no otro significado: es la
-- cuenta de `helios_settlement_outlook` y de `admin_merchant_settlements`.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_overview(p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today     date := public.helios_business_date(now());
  v_from      date;
  v_prev_from date;
  v_days      integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_volume    numeric(18,4);
  v_prev_vol  numeric(18,4);
  v_count     integer;
  v_users     integer;
  v_fin       numeric(18,4);
  v_prev_fin  numeric(18,4);
  v_people    integer;
  v_result    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from      := v_today - (v_days - 1);
  v_prev_from := v_from - v_days;

  -- Volumen financiado de la ventana y de la ventana anterior, para poder
  -- decir "sube o baja" y no solo un número suelto.
  select coalesce(sum(amount_usd), 0), count(*), count(distinct user_id)
    into v_volume, v_count, v_users
  from public.charges
  where status = 'confirmed' and not is_test
    and business_date between v_from and v_today;

  select coalesce(sum(amount_usd), 0) into v_prev_vol
  from public.charges
  where status = 'confirmed' and not is_test
    and business_date between v_prev_from and v_from - 1;

  -- Lo mismo en FINANCED: el consumo, sin el servicio de Ronda ni su IVA.
  -- `amount_usd` lleva el fee dentro, y un «volumen financiado» con el fee
  -- sumado es el total que no se enseña nunca. Sale de las cuotas, como
  -- `admin_daily_series`: su suma es el `base_usd` de cada consumo, y son lo
  -- único que sabe quién puso qué en un consumo de grupo.
  select coalesce(sum(i.financed_usd) filter (where c.business_date >= v_from), 0),
         coalesce(sum(i.financed_usd) filter (where c.business_date < v_from), 0),
         count(distinct i.user_id) filter (where c.business_date >= v_from)
    into v_fin, v_prev_fin, v_people
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where c.status = 'confirmed' and not c.is_test and not i.is_test
    and c.business_date between v_prev_from and v_today;

  v_result := jsonb_build_object(
    'business_date', v_today,
    'window_days', v_days,
    'volume', jsonb_build_object(
      'financed_usd', v_volume,
      'previous_usd', v_prev_vol,
      'charge_count', v_count,
      'active_users', v_users,
      'avg_ticket_usd', case when v_count > 0 then round(v_volume / v_count, 2) else 0 end,
      -- Las tres de arriba llevan el servicio y su IVA dentro y se quedan por el
      -- panel de `main`. El panel nuevo lee estas, en FINANCED.
      'financed_volume_usd', v_fin,
      'previous_financed_volume_usd', v_prev_fin,
      'financed_change_pct', case when v_prev_fin > 0
        then round(100 * (v_fin - v_prev_fin) / v_prev_fin, 1) else null end,
      'avg_ticket_financed_usd', case when v_count > 0 then round(v_fin / v_count, 2) else null end,
      -- `active_users` cuenta a quien abrió la cuenta; esto, a todos los que
      -- pusieron algo (por cuotas).
      'active_people', v_people
    )
  );

  -- Mora. Es *el* número del negocio: docs/00-BASES §1.2 — "con 10% de mora
  -- $8 de pérdida por cada $100 se lleva el 40% de la comisión".
  -- Se mide sobre la exposición viva, no sobre el volumen histórico: lo que
  -- importa es qué porcentaje de lo que está hoy en la calle no va a volver.
  --
  -- 🔁 Y desde el 2026-09-02, **solo lo que todavía se puede cobrar**. El
  -- `written_off_at is null` es lo que cambia. Antes la
  -- deuda castigada seguía contando aquí —`status` sigue en 'pending' aunque se
  -- haya dado por perdida— y este porcentaje no podía bajar nunca: sumaba
  -- cartera muerta a un numerador que se suponía cobrable. Lo perdido tiene su
  -- propia cifra más abajo, y las dos juntas son la cartera vencida entera.
  v_result := v_result || jsonb_build_object('arrears', (
    select jsonb_build_object(
      'open_usd', coalesce(sum(amount_usd), 0),
      'overdue_usd', coalesce(sum(amount_usd) filter (where due_date < v_today), 0),
      'overdue_users', count(distinct user_id) filter (where due_date < v_today),
      'due_today_usd', coalesce(sum(amount_usd) filter (where due_date = v_today), 0),
      'rate_pct', case
        when coalesce(sum(amount_usd), 0) > 0
        then round(100 * coalesce(sum(amount_usd) filter (where due_date < v_today), 0)
                       / sum(amount_usd), 2)
        else 0 end,
      -- Tramos de la escalera de consecuencias (docs/06 §3), leídos de los
      -- PARÁMETROS y no de números escritos aquí: la escalera ya se alargó una
      -- vez (15/30 → 30/60) y estos tramos se quedaron cortando por donde ya no
      -- pasaba nada. Las claves tampoco llevan el número dentro, por lo mismo.
      'demotion_days', public.helios_mora_demotion_days(),
      'expulsion_days', public.helios_mora_expulsion_days(),
      'bucket_frozen_usd', coalesce(sum(amount_usd)
        filter (where due_date < v_today
                  and due_date >= v_today - public.helios_mora_demotion_days()), 0),
      'bucket_demotion_usd', coalesce(sum(amount_usd)
        filter (where due_date < v_today - public.helios_mora_demotion_days()
                  and due_date >= v_today - public.helios_mora_expulsion_days()), 0),
      'bucket_expulsion_usd', coalesce(sum(amount_usd)
        filter (where due_date < v_today - public.helios_mora_expulsion_days()), 0)
    )
    from public.installments
    where status = 'pending' and written_off_at is null and not is_test
  ));

  -- Impago: lo que ya se dio por perdido.
  --
  -- La tasa va sobre TODO lo financiado en la historia y no sobre la ventana:
  -- lo que se castiga hoy nació hace dos o tres meses, así que dividirlo entre
  -- las ventas de los últimos 30 días daría un número que se mueve con el
  -- volumen y no con la calidad del crédito. El desglose comparable —cosecha a
  -- cosecha— lo da `admin_credit_cohorts`; esto es el acumulado del negocio.
  v_result := v_result || jsonb_build_object('bad_debt', (
    select jsonb_build_object(
      'written_off_usd', coalesce(sum(amount_usd) filter (where written_off_at is not null), 0),
      'written_off_users', count(distinct user_id) filter (where written_off_at is not null),
      'financed_usd', coalesce(sum(amount_usd), 0),
      'window_usd', coalesce(sum(amount_usd) filter (
        where written_off_at is not null
          and public.helios_business_date(written_off_at) between v_from and v_today), 0),
      'rate_pct', case
        when coalesce(sum(amount_usd), 0) > 0
        then round(100 * coalesce(sum(amount_usd) filter (where written_off_at is not null), 0)
                       / sum(amount_usd), 2)
        else 0 end,
      -- Lo mismo en FINANCED. Las de arriba suman deuda (`amount_usd`, con el
      -- servicio y su IVA) aunque una se llame `financed_usd`. El impago se
      -- mide sobre el consumo: estas son las que lee el panel nuevo.
      'written_off_financed_usd', coalesce(sum(financed_usd) filter (where written_off_at is not null), 0),
      'lifetime_financed_usd', coalesce(sum(financed_usd), 0),
      'window_financed_usd', coalesce(sum(financed_usd) filter (
        where written_off_at is not null
          and public.helios_business_date(written_off_at) between v_from and v_today), 0),
      'rate_financed_pct', case
        when coalesce(sum(financed_usd), 0) > 0
        then round(100 * coalesce(sum(financed_usd) filter (where written_off_at is not null), 0)
                       / sum(financed_usd), 2)
        else null end,
      -- El umbral en el que el impago se come el negocio entero, calculado y
      -- no escrito a mano: el fee ya subió del 10% al 20% este mismo mes.
      --
      -- Ronda gana el fee y, cuando alguien no paga, pierde el neto que ya le
      -- transfirió al comercio (docs/05 §3). Con una tasa de impago `d`:
      --
      --     gana  fee × (1 − d)      pierde  neto × d
      --     empatan en   d = fee / (fee + neto)
      --
      -- Con base 100 y fee del 20% eso es 20/120 ≈ 16,7%. El IVA no entra por
      -- ninguno de los dos lados: se cobra al usuario y se remite, no es de
      -- Ronda ni cuando se paga ni cuando no. Y como `d` sale de una fracción
      -- uniforme de la cartera, se compara directo con `rate_pct`.
      'break_even_pct', (
        select case
          when coalesce(sum(coalesce(c.merchant_net_usd, c.amount_usd)
                          + coalesce(c.consumer_fee_usd, 0)), 0) > 0
          then round(100 * sum(coalesce(c.consumer_fee_usd, 0))
                         / sum(coalesce(c.merchant_net_usd, c.amount_usd)
                             + coalesce(c.consumer_fee_usd, 0)), 2)
          else null end
        from public.charges c where c.status = 'confirmed' and not c.is_test
      )
    )
    from public.installments
    where not is_test
  ));

  -- Cartera de usuarios por estado. `frozen`/`suspended`/`expelled` son la
  -- salida del motor de mora, así que esta línea es su marcador.
  v_result := v_result || jsonb_build_object('users', (
    select jsonb_build_object(
      'total', count(*),
      'pending_kyc', count(*) filter (where status in ('pending_kyc', 'pending_pin')),
      'active', count(*) filter (where status = 'active'),
      'frozen', count(*) filter (where status = 'frozen'),
      'suspended', count(*) filter (where status = 'suspended'),
      'expelled', count(*) filter (where status = 'expelled'),
      'blacklisted', count(*) filter (where is_blacklisted),
      'new_in_window', count(*) filter (where created_at >= v_from)
    )
    from public.profiles
    where not is_test
  ));

  -- Embudo de KYC. La tasa de aprobación y el tamaño de la cola manual son
  -- las dos cifras que deciden si hace falta más gente revisando
  -- (docs/00-BASES §3.3: el SLA de revisión manual sigue sin definirse).
  v_result := v_result || jsonb_build_object('kyc', (
    select jsonb_build_object(
      'pending_review', count(*) filter (where status = 'manual_review'),
      'processing', count(*) filter (where status = 'processing'),
      'approved', count(*) filter (where status = 'approved'),
      'rejected', count(*) filter (where status = 'rejected'),
      'approval_rate_pct', case
        when count(*) filter (where status in ('approved', 'rejected')) > 0
        then round(100.0 * count(*) filter (where status = 'approved')
                        / count(*) filter (where status in ('approved', 'rejected')), 1)
        else null end,
      'oldest_pending_hours', coalesce(round(extract(epoch from
        (now() - min(created_at) filter (where status = 'manual_review'))) / 3600.0, 1), 0)
    )
    from kyc.verifications v
    where not public.helios_is_test_user(v.user_id)
  ));

  -- Colas de trabajo. Lo que hay pendiente de que una persona lo toque.
  -- Lo que se les debe a los locales es el resto de lo pendiente Y de lo
  -- pagado a medias (`amount_usd - paid_usd` sobre 'pending' y 'partial'),
  -- como `helios_settlement_outlook`. Hasta el 2026-09-25 solo miraba
  -- 'pending' y un pago parcial se comía el resto entero.
  v_result := v_result || jsonb_build_object('queues', jsonb_build_object(
    'payments_to_reconcile', (
      select count(*) from public.payment_reports
      where status in ('reported', 'in_review')
        and not public.helios_is_test_user(user_id)
    ),
    'merchant_payouts_due', (
      select coalesce(sum(amount_usd - paid_usd), 0) from public.settlements
      where status in ('pending', 'partial') and due_date <= v_today
        and not public.helios_is_test_merchant(merchant_id)
    ),
    'merchant_payouts_pending', (
      select coalesce(sum(amount_usd - paid_usd), 0) from public.settlements
      where status in ('pending', 'partial')
        and not public.helios_is_test_merchant(merchant_id)
    )
  ));

  -- Comercios.
  v_result := v_result || jsonb_build_object('merchants', (
    select jsonb_build_object(
      'total', count(*),
      'active', count(*) filter (where status = 'active'),
      'paused', count(*) filter (where status = 'paused'),
      'terminated', count(*) filter (where status = 'terminated'),
      'selling_in_window', (
        select count(distinct merchant_id) from public.charges
        where status = 'confirmed' and not is_test
          and business_date between v_from and v_today
      )
    )
    from public.merchants
    where not is_test
  ));

  -- Tasa BCV. docs/05 §1 la exige como alerta: si lleva más de 48 h sin
  -- actualizarse en día hábil, el scraper se rompió y estás cobrando a una
  -- tasa vieja. El aviso vale más aquí que en un log que nadie lee.
  v_result := v_result || jsonb_build_object('fx', (
    select jsonb_build_object(
      'rate', rate,
      'effective_date', effective_date,
      'fetched_at', fetched_at,
      'age_hours', round(extract(epoch from (now() - fetched_at)) / 3600.0, 1),
      'stale', (now() - fetched_at) > interval '48 hours'
    )
    from public.exchange_rates
    order by effective_date desc limit 1
  ));

  v_result := v_result || jsonb_build_object('cash', public.admin_cash_position());

  return v_result;
end;
$function$;

revoke all on function public.admin_overview(integer) from public, anon;
grant execute on function public.admin_overview(integer) to authenticated;
