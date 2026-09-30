-- ============================================================================
-- Ronda — Reportar un pago al comercio hecho por fuera
--
-- Continúa 20260822120000: allí la obligación pasó a devengarse sin mover
-- caja. Aquí se cierra el círculo — cuando alguien de Ronda transfiere de
-- verdad y lo reporta, ESE es el momento en que sale el dinero.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. reconcile_payment en modo 'on_collection' tampoco mueve caja
-- ---------------------------------------------------------------------------

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
  v_block     public.user_credit_blocks%rowtype;
  v_total     numeric(18,4) := 0;
  v_settled   numeric(18,4);
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

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'installment_payment', 'reconcile:' || p_report_id::text, v_bdate, p_report_id,
    format('Pago conciliado de %s cuota(s)', v_quote.installment_count)
  )
  returning id into v_tx;

  for v_item in
    select i.installment_id, i.amount_usd, c.merchant_id, t.policy, t.per_installment_pct,
           ins.due_date
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

    -- En 'on_collection' la obligación nace al cobrar. Se DEVENGA, igual que
    -- el adelanto: la caja se mueve cuando se reporte la transferencia.
    if v_item.policy = 'on_collection' then
      v_settled := round(v_item.amount_usd * v_item.per_installment_pct * 2 / 100, 4);

      insert into public.settlements
        (merchant_id, installment_id, reason, amount_usd, business_date, due_date, status)
      values
        (v_item.merchant_id, v_item.installment_id, 'on_collection', v_settled,
         v_bdate, v_bdate, 'pending');
    end if;
  end loop;

  -- Lo único que mueve caja aquí es el dinero que ENTRÓ del usuario.
  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_cash, v_total, 0),
    (v_tx, v_acct_recv, 0, v_total);

  update public.payment_reports
    set status = 'reconciled', reviewed_by = p_actor, reviewed_at = now(),
        rejection_note = coalesce(p_note, rejection_note)
  where id = p_report_id;

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

-- ---------------------------------------------------------------------------
-- 2. Qué se le debe a cada comercio
-- ---------------------------------------------------------------------------

create or replace view public.merchant_payables
with (security_invoker = true)
as
select
  m.id            as merchant_id,
  m.name          as merchant_name,
  m.tax_id,
  count(s.id)                                as pending_count,
  coalesce(sum(s.amount_usd), 0)             as pending_usd,
  min(s.due_date)                            as oldest_due_date,
  -- Vencido = le tocaba cobrar y todavía no se le ha pagado. Es el número
  -- que hay que mirar: al comercio se le liquida por fecha, se retrase o no
  -- el usuario (docs/05 §3).
  coalesce(sum(s.amount_usd) filter (
    where s.due_date <= public.helios_business_date(now())
  ), 0)                                      as overdue_usd
from public.merchants m
join public.settlements s
  on s.merchant_id = m.id and s.status = 'pending'
group by m.id, m.name, m.tax_id;

grant select on public.merchant_payables to authenticated;

/** Detalle de lo pendiente de un comercio, para elegir qué se está pagando. */
create or replace function public.admin_merchant_settlements(p_merchant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.due_date), '[]'::jsonb) into v_rows
  from (
    select
      s.id,
      s.reason,
      s.amount_usd,
      s.due_date,
      s.due_date <= public.helios_business_date(now()) as is_due,
      c.id as charge_id
    from public.settlements s
    left join public.charges c on c.id = s.charge_id
    where s.merchant_id = p_merchant_id and s.status = 'pending'
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_merchant_settlements(uuid) from public, anon;
grant execute on function public.admin_merchant_settlements(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Reportar la transferencia
-- ---------------------------------------------------------------------------

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
as $$
declare
  v_actor  uuid := auth.uid();
  v_total  numeric(18,4);
  v_count  integer;
  v_bdate  date;
  v_payout public.merchant_payouts%rowtype;
  v_tx     uuid;
  v_acct_pay  uuid;
  v_acct_cash uuid;
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

  insert into public.merchant_payouts
    (merchant_id, amount_usd, amount_ves, fx_rate, method, reference, note, paid_by, business_date)
  values
    (p_merchant_id, v_total, p_amount_ves, p_fx_rate, p_method, p_reference, p_note, v_actor, v_bdate)
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
      'settlements', v_count, 'method', p_method, 'reference', p_reference
    ));

  return jsonb_build_object(
    'ok', true, 'payout_id', v_payout.id,
    'amount_usd', v_total, 'settlements', v_count
  );
end;
$$;

revoke all on function public.admin_report_merchant_payout(uuid, uuid[], text, text, numeric, numeric, text)
  from public, anon;
grant execute on function public.admin_report_merchant_payout(uuid, uuid[], text, text, numeric, numeric, text)
  to authenticated;
