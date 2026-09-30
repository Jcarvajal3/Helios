-- ============================================================================
-- Ronda — Conciliar un pago que cubre varias cuotas
--
-- Sustituye a la versión de 20260822057000_settlements.sql, que saldaba una
-- sola cuota. Ahora un reporte cubre las N cuotas de su cotización y se
-- asienta como UNA transacción en el ledger: en el estado de cuenta del
-- banco hay una transferencia, no N.
-- ============================================================================

create or replace function public.reconcile_payment(
  p_report_id uuid,
  p_actor     uuid,
  p_approve   boolean,
  p_note      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_report    public.payment_reports%rowtype;
  v_quote     public.payment_quotes%rowtype;
  v_item      record;
  v_bdate     date;
  v_tx        uuid;
  v_acct_recv uuid;
  v_acct_cash uuid;
  v_acct_pay  uuid;
  v_block     public.user_credit_blocks%rowtype;
  v_total     numeric(18,4) := 0;
  v_settled   numeric(18,4) := 0;
begin
  select * into v_report from public.payment_reports where id = p_report_id for update;
  if not found then
    raise exception 'Reporte no encontrado' using errcode = 'P0002';
  end if;

  if v_report.status not in ('reported', 'in_review') then
    raise exception 'Este reporte ya fue resuelto (%)', v_report.status using errcode = '22023';
  end if;

  if not p_approve then
    update public.payment_reports
      set status = 'rejected', reviewed_by = p_actor, reviewed_at = now(),
          rejection_note = p_note
    where id = p_report_id;

    return jsonb_build_object('ok', true, 'status', 'rejected');
  end if;

  select * into v_quote from public.payment_quotes where id = v_report.quote_id;

  v_bdate := public.helios_business_date(now());
  v_acct_recv := ledger.get_or_create_account('user_receivable', v_report.user_id);
  v_acct_cash := ledger.get_or_create_account('cash', null);

  -- Un solo asiento por el total: es lo que de verdad entró en la cuenta.
  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'installment_payment', 'reconcile:' || p_report_id::text, v_bdate, p_report_id,
    format('Pago conciliado de %s cuota(s)', v_quote.installment_count)
  )
  returning id into v_tx;

  for v_item in
    select i.installment_id, i.amount_usd, c.merchant_id, t.policy, t.per_installment_pct
    from public.payment_quote_items i
    join public.installments ins on ins.id = i.installment_id
    join public.charges c on c.id = ins.charge_id
    join public.merchant_settlement_terms t on t.merchant_id = c.merchant_id
    where i.quote_id = v_quote.id
    for update of ins
  loop
    if (select status from public.installments where id = v_item.installment_id) = 'paid' then
      raise exception 'La cuota % ya estaba pagada', v_item.installment_id using errcode = '22023';
    end if;

    update public.installments
      set status = 'paid', paid_at = now()
    where id = v_item.installment_id;

    v_total := v_total + v_item.amount_usd;

    -- Liquidación por cobranza: solo para comercios en esa política. Los de
    -- 'scheduled' ya cobran por fecha con run_scheduled_settlements.
    if v_item.policy = 'on_collection' then
      v_settled := round(v_item.amount_usd * v_item.per_installment_pct * 2 / 100, 4);
      v_acct_pay := ledger.get_or_create_account('merchant_payable', v_item.merchant_id);

      insert into ledger.entries (transaction_id, account_id, debit, credit) values
        (v_tx, v_acct_pay, v_settled, 0),
        (v_tx, v_acct_cash, 0, v_settled);

      insert into public.settlements
        (merchant_id, installment_id, reason, amount_usd, business_date)
      values
        (v_item.merchant_id, v_item.installment_id, 'on_collection', v_settled, v_bdate);
    end if;
  end loop;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_cash, v_total, 0),
    (v_tx, v_acct_recv, 0, v_total);

  update public.payment_reports
    set status = 'reconciled', reviewed_by = p_actor, reviewed_at = now(),
        rejection_note = coalesce(p_note, rejection_note)
  where id = p_report_id;

  -- Bloque de crédito: se aplica el total y se cierra si ya no queda deuda.
  select * into v_block
  from public.user_credit_blocks
  where user_id = v_report.user_id and closed_at is null
  for update;

  if found then
    update public.user_credit_blocks
      set paid_usd = paid_usd + v_total
    where id = v_block.id;

    if v_block.paid_usd + v_total >= v_block.charged_usd then
      update public.user_credit_blocks
        set closed_at = now(), close_reason = 'paid'
      where id = v_block.id;
    end if;
  end if;

  perform public.recompute_profile_mora_state(v_report.user_id);

  return jsonb_build_object(
    'ok', true, 'status', 'reconciled',
    'amount_usd', v_total,
    'installments', v_quote.installment_count
  );
end;
$$;

revoke all on function public.reconcile_payment(uuid, uuid, boolean, text)
  from public, anon, authenticated;
