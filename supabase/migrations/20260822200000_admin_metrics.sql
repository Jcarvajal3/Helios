-- ============================================================================
-- Ronda — Tablero del super admin: métricas, caja y exposición
--
-- docs/00-BASES §4.2 #8 lista los números que hay que ver todos los días y
-- §1.3 dice que el capital disponible "debería estar en el super admin como
-- un semáforo, no en una hoja aparte". Esto es esa pantalla.
--
-- Dos principios que explican por qué está escrito así:
--
--   1. **El dinero se lee del ledger, no de las tablas de negocio.** Sumar
--      `installments` pendientes da un número parecido a la exposición pero
--      no idéntico, y en el momento en que se separen nadie sabrá cuál está
--      mal. El libro contable es la fuente de verdad (docs/01 §5.1).
--
--   2. **Toda fecha pasa por `helios_business_date()`.** El día operativo va
--      de 10 AM a 10 AM (docs/06 §1): un consumo del 15 a las 3 AM cuenta en
--      el día 14. Un `date_trunc('day', ...)` aquí metería la mitad de las
--      ventas de la noche en el día siguiente y ninguna métrica cuadraría
--      con lo que ve el comercio en su propio panel.
--
-- Convención de signos del ledger: activo (cash, user_receivable) tiene saldo
-- deudor y sale positivo; pasivo e ingreso (merchant_payable,
-- platform_revenue, bad_debt_provision) tienen saldo acreedor y salen
-- negativos de `debit - credit`. Aquí se devuelven ya con el signo que un
-- humano espera leer: "te deben 500" y "debes 300", ambos positivos.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Saldo agregado por tipo de cuenta
-- ---------------------------------------------------------------------------
-- `ledger.account_balance()` responde por una cuenta. Para el tablero hace
-- falta el agregado de todas las cuentas de un tipo: hay una cuenta
-- `user_receivable` por usuario y una `merchant_payable` por comercio.

create or replace function ledger.balance_by_type(p_type ledger.account_type)
returns numeric
language sql
stable
set search_path = ledger, pg_temp
as $$
  select coalesce(sum(e.debit) - sum(e.credit), 0)
  from ledger.entries e
  join ledger.accounts a on a.id = e.account_id
  where a.account_type = p_type;
$$;

revoke all on function ledger.balance_by_type(ledger.account_type)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Caja y exposición — el semáforo de capital
-- ---------------------------------------------------------------------------
-- La pregunta que responde: *¿cuánto dinero mío está en la calle ahora mismo
-- y cuánto me queda para seguir financiando?*
--
-- Con liquidación **por fecha** (docs/05 §3) el 100% del riesgo de crédito es
-- de Ronda y la exposición llega al 80% del volumen vivo. El compromiso real
-- no es solo lo que deben los usuarios: hay que sumarle lo que ya se devengó
-- a favor de los comercios y todavía no se ha transferido, porque eso sale de
-- la misma caja pase lo que pase.

create or replace function public.admin_cash_position()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_cash        numeric(18,4);
  v_receivable  numeric(18,4);
  v_payable     numeric(18,4);
  v_revenue     numeric(18,4);
  v_written_off numeric(18,4);
  v_fx          numeric(18,4);
  v_overdue     numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_cash        :=  ledger.balance_by_type('cash');
  v_receivable  :=  ledger.balance_by_type('user_receivable');
  v_payable     := -ledger.balance_by_type('merchant_payable');
  v_revenue     := -ledger.balance_by_type('platform_revenue');
  v_written_off := -ledger.balance_by_type('bad_debt_provision');
  v_fx          :=  ledger.balance_by_type('fx_difference');

  -- Cuánto de la exposición ya está vencido. No es lo mismo tener $5.000 en
  -- la calle al corriente que $5.000 con la mitad vencida.
  select coalesce(sum(amount_usd), 0) into v_overdue
  from public.installments
  where status = 'pending'
    and due_date < public.helios_business_date(now());

  return jsonb_build_object(
    'cash', v_cash,
    'user_receivable', v_receivable,
    'overdue_receivable', v_overdue,
    'merchant_payable', v_payable,
    'platform_revenue', v_revenue,
    'written_off', v_written_off,
    'fx_difference', v_fx,
    -- Todo lo que está comprometido y todavía no ha vuelto a caja.
    'committed', v_receivable + v_payable,
    -- Lo que queda libre para seguir financiando. Puede salir negativo, y
    -- que salga negativo es exactamente la señal que hay que ver.
    'free_capital', v_cash - v_payable
  );
end;
$$;

revoke all on function public.admin_cash_position() from public, anon;
grant execute on function public.admin_cash_position() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Asientos recientes del libro
-- ---------------------------------------------------------------------------
-- Sin esto, "la caja dice X" es un número sin explicación. Con esto se puede
-- bajar del saldo al asiento que lo movió.

create or replace function public.admin_ledger_entries(
  p_limit integer default 100,
  p_type  text default null
)
returns table (
  transaction_id  uuid,
  type            text,
  business_date   date,
  memo            text,
  created_at      timestamptz,
  created_by      uuid,
  actor_name      text,
  lines           jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  select
    t.id,
    t.type::text,
    t.business_date,
    t.memo,
    t.created_at,
    t.created_by,
    pa.full_name,
    (
      select jsonb_agg(
        jsonb_build_object(
          'account', a.account_type::text,
          'owner_id', a.owner_id,
          'debit', e.debit,
          'credit', e.credit
        ) order by e.id
      )
      from ledger.entries e
      join ledger.accounts a on a.id = e.account_id
      where e.transaction_id = t.id
    )
  from ledger.transactions t
  left join public.platform_admins pa on pa.user_id = t.created_by
  where p_type is null or t.type::text = p_type
  order by t.created_at desc
  limit least(coalesce(p_limit, 100), 500);
end;
$$;

revoke all on function public.admin_ledger_entries(integer, text) from public, anon;
grant execute on function public.admin_ledger_entries(integer, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Resumen del negocio
-- ---------------------------------------------------------------------------
-- Un solo viaje al servidor devuelve todo el tablero. Son consultas pequeñas
-- pero muchas; hacerlas por separado desde el cliente convertiría la pantalla
-- de inicio en doce peticiones.
--
-- La ventana por defecto son 30 días operativos, no "el mes": el negocio es
-- nocturno y de fin de semana, y comparar un mes de cinco viernes con uno de
-- cuatro no dice nada.

create or replace function public.admin_overview(p_days integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today     date := public.helios_business_date(now());
  v_from      date;
  v_prev_from date;
  v_days      integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_volume    numeric(18,4);
  v_prev_vol  numeric(18,4);
  v_count     integer;
  v_users     integer;
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
  where status = 'confirmed' and business_date between v_from and v_today;

  select coalesce(sum(amount_usd), 0) into v_prev_vol
  from public.charges
  where status = 'confirmed' and business_date between v_prev_from and v_from - 1;

  v_result := jsonb_build_object(
    'business_date', v_today,
    'window_days', v_days,
    'volume', jsonb_build_object(
      'financed_usd', v_volume,
      'previous_usd', v_prev_vol,
      'charge_count', v_count,
      'active_users', v_users,
      'avg_ticket_usd', case when v_count > 0 then round(v_volume / v_count, 2) else 0 end
    )
  );

  -- Mora. Es *el* número del negocio: docs/00-BASES §1.2 — "con 10% de mora
  -- $8 de pérdida por cada $100 se lleva el 40% de la comisión".
  -- Se mide sobre la exposición viva, no sobre el volumen histórico: lo que
  -- importa es qué porcentaje de lo que está hoy en la calle no va a volver.
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
      -- Tramos de la escalera de consecuencias (docs/06 §3): 1 día congela,
      -- 15 baja de nivel, 30 expulsa. Ver la distribución dice si la mora es
      -- un retraso de días o cartera que ya no vuelve.
      'bucket_1_14_usd', coalesce(sum(amount_usd)
        filter (where due_date < v_today and due_date >= v_today - 14), 0),
      'bucket_15_30_usd', coalesce(sum(amount_usd)
        filter (where due_date < v_today - 14 and due_date >= v_today - 30), 0),
      'bucket_30_plus_usd', coalesce(sum(amount_usd)
        filter (where due_date < v_today - 30), 0)
    )
    from public.installments where status = 'pending'
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
    from kyc.verifications
  ));

  -- Colas de trabajo. Lo que hay pendiente de que una persona lo toque.
  v_result := v_result || jsonb_build_object('queues', jsonb_build_object(
    'payments_to_reconcile', (
      select count(*) from public.payment_reports
      where status in ('reported', 'in_review')
    ),
    'merchant_payouts_due', (
      select coalesce(sum(amount_usd), 0) from public.settlements
      where status = 'pending' and due_date <= v_today
    ),
    'merchant_payouts_pending', (
      select coalesce(sum(amount_usd), 0) from public.settlements
      where status = 'pending'
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
        where status = 'confirmed' and business_date between v_from and v_today
      )
    )
    from public.merchants
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
$$;

revoke all on function public.admin_overview(integer) from public, anon;
grant execute on function public.admin_overview(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Serie diaria — la forma de la curva, no solo el total
-- ---------------------------------------------------------------------------
-- Un total de 30 días esconde si el negocio crece o se apaga. Y en un
-- producto nocturno la serie diaria enseña algo más: el pico de viernes y
-- sábado. Si un martes aparece con volumen de viernes, eso es una señal de
-- fraude antes que de éxito.

create or replace function public.admin_daily_series(p_days integer default 30)
returns table (
  business_date date,
  financed_usd  numeric,
  charge_count  integer,
  collected_usd numeric,
  settled_usd   numeric
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today date := public.helios_business_date(now());
  v_days  integer := greatest(least(coalesce(p_days, 30), 365), 1);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  with days as (
    select generate_series(v_today - (v_days - 1), v_today, interval '1 day')::date as d
  )
  select
    days.d,
    coalesce(c.financed, 0)::numeric,
    coalesce(c.cnt, 0)::integer,
    coalesce(p.collected, 0)::numeric,
    coalesce(s.settled, 0)::numeric
  from days
  left join (
    select ch.business_date as d, sum(ch.amount_usd) as financed, count(*)::integer as cnt
    from public.charges ch
    where ch.status = 'confirmed'
    group by 1
  ) c on c.d = days.d
  left join (
    -- Cobrado de verdad: cuotas conciliadas, por día operativo del cobro.
    select public.helios_business_date(i.paid_at) as d, sum(i.amount_usd) as collected
    from public.installments i
    where i.status = 'paid' and i.paid_at is not null
    group by 1
  ) p on p.d = days.d
  left join (
    -- Salido de caja hacia comercios.
    select mp.business_date as d, sum(mp.amount_usd) as settled
    from public.merchant_payouts mp
    group by 1
  ) s on s.d = days.d
  order by days.d;
end;
$$;

revoke all on function public.admin_daily_series(integer) from public, anon;
grant execute on function public.admin_daily_series(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Riesgo por comercio — la primera línea de defensa antifraude
-- ---------------------------------------------------------------------------
-- docs/00-BASES §4.2 #9 lo dice sin rodeos: *"el vector más rentable de
-- fraude en tu modelo no es el usuario, es el comercio"*. Con liquidación por
-- fecha, un local puede facturar consumos falsos con cuentas cómplices y
-- cobrar el 80% sin que nadie pague nunca.
--
-- La señal que lo delata no es una sola: es la combinación de mora alta,
-- pocos usuarios distintos repitiendo, y concentración del volumen total.
-- Por eso salen las tres juntas en la misma fila.

create or replace function public.admin_merchant_risk(p_days integer default 90)
returns table (
  merchant_id      uuid,
  merchant_name    text,
  status           text,
  charge_count     integer,
  financed_usd     numeric,
  distinct_users   integer,
  repeat_ratio     numeric,
  overdue_usd      numeric,
  arrears_pct      numeric,
  volume_share_pct numeric,
  pending_payout_usd numeric
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today date := public.helios_business_date(now());
  v_from  date;
  v_total numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := v_today - (greatest(least(coalesce(p_days, 90), 365), 1) - 1);

  -- Alias explícito: esta función declara OUT parameters llamados `status` y
  -- `financed_usd`, y sin calificar la columna Postgres no sabe si `status`
  -- es la de la tabla o la variable.
  select coalesce(sum(c0.amount_usd), 0) into v_total
  from public.charges c0
  where c0.status = 'confirmed' and c0.business_date between v_from and v_today;

  return query
  with per_merchant as (
    select
      ch.merchant_id as mid,
      count(*)::integer as cnt,
      sum(ch.amount_usd) as financed,
      count(distinct ch.user_id)::integer as users
    from public.charges ch
    where ch.status = 'confirmed' and ch.business_date between v_from and v_today
    group by 1
  ),
  arrears as (
    -- La mora se imputa al comercio que originó el consumo. Es la métrica que
    -- docs/05 §3 llama "de primera línea" y la que dispararía el holdback.
    select
      ch.merchant_id as mid,
      sum(i.amount_usd) filter (where i.status = 'pending' and i.due_date < v_today) as overdue,
      sum(i.amount_usd) as billed
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    where ch.business_date between v_from and v_today
    group by 1
  ),
  payables as (
    select s.merchant_id as mid, sum(s.amount_usd) as pending
    from public.settlements s
    where s.status = 'pending'
    group by 1
  )
  select
    m.id,
    m.name,
    m.status::text,
    coalesce(pm.cnt, 0),
    coalesce(pm.financed, 0)::numeric,
    coalesce(pm.users, 0),
    case when coalesce(pm.users, 0) > 0
         then round(pm.cnt::numeric / pm.users, 2) else 0 end,
    coalesce(a.overdue, 0)::numeric,
    case when coalesce(a.billed, 0) > 0
         then round(100 * coalesce(a.overdue, 0) / a.billed, 2) else 0 end,
    case when v_total > 0
         then round(100 * coalesce(pm.financed, 0) / v_total, 2) else 0 end,
    coalesce(p.pending, 0)::numeric
  from public.merchants m
  left join per_merchant pm on pm.mid = m.id
  left join arrears a on a.mid = m.id
  left join payables p on p.mid = m.id
  order by coalesce(pm.financed, 0) desc;
end;
$$;

revoke all on function public.admin_merchant_risk(integer) from public, anon;
grant execute on function public.admin_merchant_risk(integer) to authenticated;
