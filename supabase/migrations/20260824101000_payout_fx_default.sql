-- ============================================================================
-- Ronda — El pago al comercio también cotiza a la tasa del día
--
-- `admin_report_merchant_payout` guardaba `amount_ves` y `fx_rate` tal como
-- llegaran, y el panel nunca los mandaba: todos los pagos a comercios quedaban
-- con las dos columnas en null. Un pago hecho por pago móvil del que no consta
-- ni cuántos bolívares salieron ni a qué tasa no se puede cotejar contra el
-- extracto del banco — que es justo para lo que existe la conciliación.
--
-- Ahora, cuando el método es en bolívares y el operador no teclea nada, se
-- rellena con la tasa BCV del día operativo (la misma que ya usan las
-- cotizaciones al usuario, `20260824100000_bcv_rate_ingest.sql`). Si el
-- operador transfirió otra cifra —redondeó, el banco cobró comisión— manda lo
-- que él escriba: el dato de verdad es el del banco, no el calculado.
--
-- Zelle, USDT y efectivo en dólares no se convierten: ahí no hay bolívares que
-- registrar.
-- ============================================================================

create or replace function public.admin_report_merchant_payout(
  p_merchant_id    uuid,
  p_settlement_ids uuid[],
  p_method         text,
  p_reference      text default null,
  p_amount_ves     numeric default null,
  p_fx_rate        numeric default null,
  p_note           text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $fn$
declare
  v_actor  uuid := auth.uid();
  v_total  numeric(18,4);
  v_count  integer;
  v_bdate  date;
  v_payout public.merchant_payouts%rowtype;
  v_tx     uuid;
  v_acct_pay  uuid;
  v_acct_cash uuid;
  v_fx     numeric;
  v_ves    numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  if p_settlement_ids is null or array_length(p_settlement_ids, 1) is null then
    raise exception 'Selecciona al menos una liquidación' using errcode = '22023';
  end if;

  -- Se bloquean las filas antes de sumar: dos operadores pagando el mismo
  -- comercio a la vez no pueden liquidar dos veces lo mismo.
  perform 1 from public.settlements
  where id = any(p_settlement_ids) for update;

  select coalesce(sum(amount_usd), 0), count(*)
    into v_total, v_count
  from public.settlements
  where id = any(p_settlement_ids)
    and merchant_id = p_merchant_id
    and status = 'pending';

  if v_count <> array_length(p_settlement_ids, 1) then
    raise exception 'Alguna liquidación no es de este comercio o ya fue pagada'
      using errcode = '22023';
  end if;

  v_bdate := public.helios_business_date(now());

  -- La conversión, si toca. `current_fx_rate()` puede devolver null si la
  -- ingesta lleva días rota: en ese caso se guarda null, como antes, en vez
  -- de inventar una tasa. El aviso de tasa vieja del panel es lo que tiene
  -- que sonar ahí, no este pago.
  if p_method in ('pago_movil', 'transferencia') then
    v_fx  := coalesce(p_fx_rate, public.current_fx_rate('BCV', v_bdate));
    v_ves := coalesce(p_amount_ves, round(v_total * v_fx, 2));
  else
    v_fx  := p_fx_rate;
    v_ves := p_amount_ves;
  end if;

  insert into public.merchant_payouts
    (merchant_id, amount_usd, amount_ves, fx_rate, method, reference, note, paid_by, business_date)
  values
    (p_merchant_id, v_total, v_ves, v_fx, p_method, p_reference, p_note, v_actor, v_bdate)
  returning * into v_payout;

  insert into public.merchant_payout_items (payout_id, settlement_id, amount_usd)
  select v_payout.id, id, amount_usd
  from public.settlements where id = any(p_settlement_ids);

  update public.settlements set status = 'paid' where id = any(p_settlement_ids);

  -- AHORA sí sale el dinero: es el momento en que de verdad salió del banco.
  v_acct_pay  := ledger.get_or_create_account('merchant_payable', p_merchant_id);
  v_acct_cash := ledger.get_or_create_account('cash', null);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'merchant_settlement', 'payout:' || v_payout.id::text, v_bdate, v_payout.id,
    format('Pago al comercio (%s liquidaciones)', v_count)
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_pay, v_total, 0),
    (v_tx, v_acct_cash, 0, v_total);

  perform audit.log(v_actor, 'merchant.paid', p_merchant_id,
    jsonb_build_object(
      'payout_id', v_payout.id, 'amount_usd', v_total,
      'settlements', v_count, 'method', p_method, 'reference', p_reference,
      'amount_ves', v_ves, 'fx_rate', v_fx
    ));

  return jsonb_build_object(
    'ok', true, 'payout_id', v_payout.id,
    'amount_usd', v_total, 'settlements', v_count,
    'amount_ves', v_ves, 'fx_rate', v_fx
  );
end;
$fn$;

revoke all on function public.admin_report_merchant_payout(uuid, uuid[], text, text, numeric, numeric, text)
  from public, anon;
grant execute on function public.admin_report_merchant_payout(uuid, uuid[], text, text, numeric, numeric, text)
  to authenticated;
