-- ============================================================================
-- Ronda — Conciliación de pagos y liquidación al comercio
--
-- reconcile_payment          → super admin aprueba/rechaza un reporte de
--                               pago; si aprueba, mueve dinero de verdad.
-- run_scheduled_settlements  → el cron de cierre (docs/01 §7): liquida al
--                               comercio en la fecha pactada, pase lo que
--                               pase con la mora del usuario (docs/05 §3).
--
-- `public.settlements` es el historial legible por el comercio de lo que se
-- le ha pagado; `ledger.entries` es el detalle contable que lo sustenta.
-- ============================================================================

create type public.settlement_reason as enum (
  'advance',              -- 30% al vender (ya postea confirm_charge, ver abajo)
  'scheduled_installment', -- 25%/25% por fecha, política 'scheduled'
  'on_collection'          -- 50% de lo cobrado, política 'on_collection'
);

create table if not exists public.settlements (
  id             uuid primary key default gen_random_uuid(),
  merchant_id    uuid not null references public.merchants (id),
  charge_id      uuid references public.charges (id),
  installment_id uuid references public.installments (id),
  reason         public.settlement_reason not null,
  amount_usd     numeric(18,4) not null check (amount_usd > 0),
  business_date  date not null,
  created_at     timestamptz not null default now()
);

create index settlements_merchant_idx on public.settlements (merchant_id, business_date desc);

alter table public.settlements enable row level security;

create policy "settlements_read_merchant_staff"
  on public.settlements for select
  to authenticated
  using (
    merchant_id in (
      select merchant_id from public.merchant_users
      where user_id = auth.uid() and is_active and role = 'gerente'
    )
  );

-- El adelanto del 30% ya se postea en confirm_charge (migración
-- 20260822055000); esta fila lo deja visible en el historial del comercio.
create or replace function ledger.record_advance_settlement(
  p_merchant_id uuid, p_charge_id uuid, p_amount numeric, p_business_date date
)
returns void
language sql
set search_path = public, pg_temp
as $$
  insert into public.settlements (merchant_id, charge_id, reason, amount_usd, business_date)
  values (p_merchant_id, p_charge_id, 'advance', p_amount, p_business_date);
$$;

revoke all on function ledger.record_advance_settlement(uuid, uuid, numeric, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- reconcile_payment — solo super admin (service role).
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
  v_report  public.payment_reports%rowtype;
  v_inst    public.installments%rowtype;
  v_merchant_id uuid;
  v_terms   public.merchant_settlement_terms%rowtype;
  v_bdate   date;
  v_tx      uuid;
  v_acct_recv uuid;
  v_acct_cash uuid;
  v_acct_pay  uuid;
  v_settle_amount numeric(18,4);
  v_block   public.user_credit_blocks%rowtype;
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

  select * into v_inst from public.installments where id = v_report.installment_id for update;
  if v_inst.status = 'paid' then
    raise exception 'Esta cuota ya estaba pagada' using errcode = '22023';
  end if;

  select merchant_id into v_merchant_id from public.charges where id = v_inst.charge_id;
  select * into v_terms from public.merchant_settlement_terms where merchant_id = v_merchant_id;

  v_bdate := public.helios_business_date(now());

  -- --- Ledger: el usuario pagó ------------------------------------------
  v_acct_recv := ledger.get_or_create_account('user_receivable', v_inst.user_id);
  v_acct_cash := ledger.get_or_create_account('cash', null);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('installment_payment', 'reconcile:' || p_report_id::text, v_bdate, v_inst.id, 'Cuota conciliada')
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_cash, v_inst.amount_usd, 0),
    (v_tx, v_acct_recv, 0, v_inst.amount_usd);

  update public.installments set status = 'paid', paid_at = now() where id = v_inst.id;

  update public.payment_reports
    set status = 'reconciled', reviewed_by = p_actor, reviewed_at = now(), rejection_note = p_note
  where id = p_report_id;

  -- --- Liquidación al comercio en modo 'on_collection' -------------------
  -- En modo 'scheduled' el comercio ya cobra por fecha via
  -- run_scheduled_settlements, pase o no pase esto.
  if v_terms.policy = 'on_collection' then
    v_settle_amount := round(v_inst.amount_usd * v_terms.per_installment_pct * 2 / 100, 4);
    v_acct_pay := ledger.get_or_create_account('merchant_payable', v_merchant_id);

    insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
    values (
      'merchant_settlement', 'reconcile:' || p_report_id::text || ':settlement', v_bdate, v_inst.id,
      'Liquidación por cobranza'
    )
    returning id into v_tx;

    insert into ledger.entries (transaction_id, account_id, debit, credit) values
      (v_tx, v_acct_pay, v_settle_amount, 0),
      (v_tx, v_acct_cash, 0, v_settle_amount);

    insert into public.settlements (merchant_id, installment_id, reason, amount_usd, business_date)
    values (v_merchant_id, v_inst.id, 'on_collection', v_settle_amount, v_bdate);
  end if;

  -- --- Bloque de crédito: aplicar el pago y cerrar si ya saldó todo ------
  select * into v_block
  from public.user_credit_blocks
  where user_id = v_inst.user_id and closed_at is null
  for update;

  if found then
    update public.user_credit_blocks
      set paid_usd = paid_usd + v_inst.amount_usd
    where id = v_block.id;

    if v_block.paid_usd + v_inst.amount_usd >= v_block.charged_usd then
      update public.user_credit_blocks
        set closed_at = now(), close_reason = 'paid'
      where id = v_block.id;
    end if;
  end if;

  perform public.recompute_profile_mora_state(v_inst.user_id);

  return jsonb_build_object('ok', true, 'status', 'reconciled', 'installment_id', v_inst.id);
end;
$$;

-- Sin grant: solo el service role (super admin) puede conciliar.
revoke all on function public.reconcile_payment(uuid, uuid, boolean, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- run_scheduled_settlements — el cron de cierre de ciclo.
-- ---------------------------------------------------------------------------
-- Para comercios en política 'scheduled': liquida el 25% de cada cuota que
-- vence en la fecha dada, haya pagado el usuario o no (docs/05 §3). Es
-- idempotente por fecha: correrla dos veces el mismo día no duplica el pago.

create or replace function public.run_scheduled_settlements(p_business_date date)
returns integer
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_inst  record;
  v_terms public.merchant_settlement_terms%rowtype;
  v_amount numeric(18,4);
  v_tx     uuid;
  v_acct_pay  uuid;
  v_acct_cash uuid;
  v_count integer := 0;
begin
  for v_inst in
    select i.id, i.amount_usd, c.merchant_id
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.due_date = p_business_date
  loop
    select * into v_terms from public.merchant_settlement_terms where merchant_id = v_inst.merchant_id;

    if v_terms.policy <> 'scheduled' then
      continue;
    end if;

    v_amount := round(v_inst.amount_usd * v_terms.per_installment_pct / 100, 4);
    v_acct_pay := ledger.get_or_create_account('merchant_payable', v_inst.merchant_id);
    v_acct_cash := ledger.get_or_create_account('cash', null);

    begin
      insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
      values (
        'merchant_settlement', 'scheduled:' || v_inst.id::text, p_business_date, v_inst.id,
        'Liquidación por fecha'
      )
      returning id into v_tx;
    exception when unique_violation then
      -- Ya se liquidó esta cuota en una corrida anterior del mismo día.
      continue;
    end;

    insert into ledger.entries (transaction_id, account_id, debit, credit) values
      (v_tx, v_acct_pay, v_amount, 0),
      (v_tx, v_acct_cash, 0, v_amount);

    insert into public.settlements (merchant_id, installment_id, reason, amount_usd, business_date)
    values (v_inst.merchant_id, v_inst.id, 'scheduled_installment', v_amount, p_business_date);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Sin grant: solo el cron/service role la ejecuta.
revoke all on function public.run_scheduled_settlements(date) from public, anon, authenticated;
