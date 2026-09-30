-- ============================================================================
-- Ronda — Mora e impago: dos números distintos, y hoy eran uno solo mal medido
--
-- El resumen del super admin enseña "Mora": cuotas pendientes con el
-- vencimiento pasado, sobre la exposición viva. El problema es lo que NO hace
-- el castigo contable.
--
-- 🐛 **`charge_off_user_debt` nunca tocó las cuotas.** Cierra el bloque de
-- crédito, mueve el libro (Dr `bad_debt_provision` / Cr `user_receivable`) y
-- marca los cargos de mora como `written_off`. Pero `installments.status` solo
-- tiene `pending` y `paid`, así que la deuda castigada **se queda en
-- `pending` para siempre**. Consecuencias, las dos malas:
--
--   * La mora del panel **no puede bajar nunca**. Una deuda que se dio por
--     perdida a los 60 días sigue contando como vencida a los 200, y sigue
--     inflando el tramo de expulsión de "Antigüedad de la mora".
--   * Y **no hay forma de preguntar cuánto se ha perdido de verdad**: el dato
--     existe en el libro, pero suelto de la cuota que lo originó, así que no se
--     puede repartir por mes de consumo ni por comercio.
--
-- Es el peor tipo de métrica rota: sube sola, nadie la ve bajar, y el número
-- que la explicaría no se puede calcular.
--
-- ---------------------------------------------------------------------------
-- Lo que se añade: una fecha, no un estado
-- ---------------------------------------------------------------------------
-- `installments.written_off_at`, nula mientras la deuda siga viva.
--
-- **Por qué una columna nueva y no un tercer valor del enum.** Medio esquema
-- pregunta `status = 'pending'` —el cupo, la app del usuario, la cobranza, la
-- liquidación—, y meter `written_off` ahí cambiaría en silencio el significado
-- de todas esas consultas a la vez. Una columna aparte deja `pending`
-- queriendo decir exactamente lo que decía y hace que la pregunta nueva
-- —¿sigue siendo cobrable?— haya que escribirla a propósito.
--
-- Con eso, las dos cifras quedan separadas y sumadas dan la cartera vencida:
--
--     MORA     pending · vencida · written_off_at is null   → todavía se cobra
--     IMPAGO   written_off_at is not null                    → se dio por perdida
--
-- ---------------------------------------------------------------------------
-- Y cómo se mide: por COSECHA, no por mes natural
-- ---------------------------------------------------------------------------
-- La tentación es dividir lo castigado este mes entre lo financiado este mes.
-- No significa nada: la cuota 2 vence a los 14 días y el castigo llega a los
-- 60, así que **lo que se castiga en septiembre nació en junio o julio**. Ese
-- cociente sube cuando las ventas bajan y baja cuando suben, sin que la calidad
-- del crédito se haya movido un milímetro.
--
-- `admin_credit_cohorts` agrupa por el **mes del consumo** y sigue a esa
-- cosecha hasta hoy: de lo que financiamos en julio, cuánto se cobró, cuánto
-- está vencido y cuánto se perdió. Ese cociente sí es comparable entre meses,
-- y es el que dice si el negocio va bien.
--
-- Con un aviso que hay que dar en pantalla: **una cosecha joven no tiene
-- todavía su número de impago**. Hasta que su última cuota pudo vencer (14
-- días) y agotar la escalera (60), su impago es 0 por construcción, no por
-- mérito. Por eso cada fila viene con `matured`.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La cuota sabe si se dio por perdida
-- ---------------------------------------------------------------------------

alter table public.installments
  add column if not exists written_off_at timestamptz;

comment on column public.installments.written_off_at is
  'Cuando se castigo como incobrable (expulsion a los 60 dias). Null mientras siga siendo cobrable. El status sigue en pending a proposito: lo que cambia es si se espera cobrarla, no si esta pagada.';

create index if not exists installments_written_off_idx
  on public.installments (written_off_at) where written_off_at is not null;

-- Backfill de lo ya castigado. Solo hay un bloque abierto por usuario a la vez
-- (20260822053000) y acumula todos sus consumos, así que las cuotas pendientes
-- de alguien a quien se le castigó la deuda son exactamente las de ese bloque.
update public.installments i
set written_off_at = b.closed_at
from public.user_credit_blocks b
where b.close_reason = 'charged_off'
  and b.user_id = i.user_id
  and i.status = 'pending'
  and i.written_off_at is null
  and i.created_at <= b.closed_at;

-- ---------------------------------------------------------------------------
-- 2. El castigo marca las cuotas
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260830190000 salvo el bloque marcado NUEVO y el memo,
-- que decía "> 30 días" desde antes de que la escalera se alargara a 60
-- (20260830230000). Ahora sale del parámetro y no puede volver a quedarse viejo.

create or replace function public.charge_off_user_debt(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_block  public.user_credit_blocks%rowtype;
  v_amount numeric(18,4);
  v_tx     uuid;
  v_acct_recv     uuid;
  v_acct_provision uuid;
begin
  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user_id and closed_at is null
  for update;

  if not found then
    return;
  end if;

  -- Cupo + fee − pagado. Todo eso es receivable.
  v_amount := v_block.charged_usd + v_block.fee_usd - v_block.paid_usd;

  if v_amount <= 0 then
    update public.user_credit_blocks
      set closed_at = now(), close_reason = 'paid'
    where id = v_block.id;
    return;
  end if;

  v_acct_recv := ledger.get_or_create_account('user_receivable', p_user_id);
  v_acct_provision := ledger.get_or_create_account('bad_debt_provision', null);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'charge_off', 'charge_off:' || v_block.id::text, public.helios_business_date(now()),
    v_block.id,
    format('Castigo por mora > %s dias', public.helios_mora_expulsion_days())
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_provision, v_amount, 0),
    (v_tx, v_acct_recv, 0, v_amount);

  update public.late_fees
    set status = 'written_off'
  where credit_block_id = v_block.id and status = 'pending';

  -- NUEVO (2026-09-02): la cuota deja de contar como cobrable.
  --
  -- Sin esto el libro sabía que la deuda se había perdido y el panel seguía
  -- enseñándola como mora, para siempre. `status` NO se toca: sigue siendo
  -- 'pending' porque nadie la pagó, que es lo que esa columna significa.
  update public.installments
    set written_off_at = now()
  where user_id = p_user_id
    and status = 'pending'
    and written_off_at is null;

  update public.user_credit_blocks
    set closed_at = now(), close_reason = 'charged_off'
  where id = v_block.id;
end;
$$;

revoke all on function public.charge_off_user_debt(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. La cosecha mensual
-- ---------------------------------------------------------------------------
/**
 * De lo que se financió cada mes, en qué acabó.
 *
 * La base de todo es `installments.amount_usd`: el receivable que nació con el
 * consumo. Numerador y denominador miden lo mismo, que es lo que hace el
 * cociente comparable — y las dos mitades de una venta suman exactamente
 * `charges.amount_usd`, así que "financiado" sigue queriendo decir lo de
 * siempre.
 *
 * ⚠️ **El cargo por mora queda fuera a propósito.** No es crédito concedido
 * sino una penalización, y meterlo en el denominador haría que financiar peor
 * mejorara la tasa. Por eso el impago que sale de aquí no cuadra al céntimo con
 * el asiento de `charge_off`, que sí se lleva el fee: son dos preguntas
 * distintas —cuánto crédito se perdió y cuánto receivable se dio de baja— y la
 * primera es la que mide el negocio.
 */
create or replace function public.admin_credit_cohorts(p_months integer default 6)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
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

  select coalesce(jsonb_agg(to_jsonb(q) order by q.month desc), '[]'::jsonb)
  into v_rows
  from (
    select
      to_char(date_trunc('month', c.business_date::timestamp), 'YYYY-MM') as month,
      count(distinct c.id)::integer                                       as charge_count,
      count(distinct c.user_id)::integer                                  as user_count,
      sum(i.amount_usd)                                                   as financed_usd,
      sum(i.amount_usd) filter (where i.status = 'paid')                  as paid_usd,
      -- Vencido y todavía cobrable. Es la mora de esa cosecha, hoy.
      sum(i.amount_usd) filter (
        where i.status = 'pending' and i.written_off_at is null
          and i.due_date < v_today)                                       as overdue_usd,
      -- Vivo y sin vencer: ni cobrado ni problema, todavía.
      sum(i.amount_usd) filter (
        where i.status = 'pending' and i.written_off_at is null
          and i.due_date >= v_today)                                      as current_usd,
      sum(i.amount_usd) filter (where i.written_off_at is not null)       as written_off_usd,
      round(100 * sum(i.amount_usd) filter (
        where i.status = 'pending' and i.written_off_at is null
          and i.due_date < v_today) / nullif(sum(i.amount_usd), 0), 2)    as overdue_pct,
      round(100 * sum(i.amount_usd) filter (where i.written_off_at is not null)
                / nullif(sum(i.amount_usd), 0), 2)                        as written_off_pct,
      -- Una cosecha joven da 0% de impago por construcción, no por mérito: su
      -- última cuota todavía no ha tenido tiempo de recorrer la escalera. La
      -- pantalla tiene que poder decirlo en vez de dejar leer un cero limpio.
      (max(c.business_date) + v_season) <= v_today                        as matured
    from public.charges c
    join public.installments i on i.charge_id = c.id
    where c.status = 'confirmed'
      and c.business_date >= v_from
    group by 1
  ) q;

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
  'Cosecha mensual de credito: de lo financiado cada mes, cuanto se cobro, cuanto esta vencido y cuanto se perdio. Agrupa por mes del CONSUMO y no del castigo, que es lo unico comparable entre meses. Ver docs/00-BASES 1.2.';

revoke all on function public.admin_credit_cohorts(integer) from public, anon;
grant execute on function public.admin_credit_cohorts(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. El resumen: la mora deja de incluir lo ya perdido, y aparece el impago
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260830230000 salvo el bloque de `arrears` —que ahora
-- excluye lo castigado— y el bloque `bad_debt`, que es nuevo.

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
    where status = 'pending' and written_off_at is null
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
        from public.charges c where c.status = 'confirmed'
      )
    )
    from public.installments
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
