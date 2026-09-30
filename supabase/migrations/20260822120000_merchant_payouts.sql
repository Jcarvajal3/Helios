-- ============================================================================
-- Ronda — Pagos al comercio: devengar ≠ pagar
--
-- Decisión confirmada 2026-08-22: **al comercio se le paga por fuera** (D-02).
-- No hay integración bancaria: alguien de Ronda hace la transferencia y la
-- reporta en el super admin.
--
-- Eso obliga a corregir algo que estaba mal desde el principio. Hasta ahora,
-- `confirm_charge` asentaba en el mismo instante de la venta:
--
--     Dr merchant_payable 30 / Cr cash 30
--
-- Es decir, **el libro afirmaba que el dinero ya había salido de la caja de
-- Ronda** cuando en realidad nadie había transferido nada todavía. Dos
-- consecuencias, ambas malas:
--
--   * `cash` mostraba menos dinero del que de verdad hay en el banco.
--   * `merchant_payable` mostraba menos deuda de la que de verdad se le debe
--     al comercio, que es justo el número que hay que mirar para pagarle.
--
-- El modelo correcto separa los dos hechos:
--
--   1. Al vender se DEVENGA la obligación → fila en `settlements` pendiente.
--      No se mueve caja, porque no se movió nada.
--   2. Cuando alguien transfiere de verdad y lo reporta → se mueve la caja.
--
-- Así `merchant_payable` pasa a significar exactamente lo que su nombre dice:
-- lo que Ronda le debe al comercio ahora mismo.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las liquidaciones tienen estado y fecha de vencimiento
-- ---------------------------------------------------------------------------

create type public.settlement_status as enum ('pending', 'paid');

alter table public.settlements
  add column if not exists status public.settlement_status not null default 'pending',
  -- Cuándo le toca cobrar al comercio. El adelanto vence el mismo día de la
  -- venta; los 25% vencen en la fecha de cada cuota (docs/05 §3: por fecha,
  -- pague o no pague el usuario).
  add column if not exists due_date date;

update public.settlements set due_date = business_date where due_date is null;
alter table public.settlements alter column due_date set not null;

create index if not exists settlements_pending_idx
  on public.settlements (merchant_id, due_date) where status = 'pending';

-- ---------------------------------------------------------------------------
-- 2. El pago externo al comercio
-- ---------------------------------------------------------------------------
-- Una transferencia real cubre normalmente varias liquidaciones a la vez —
-- igual que el usuario paga varias cuotas con una sola referencia. Se modela
-- igual: un `payout` con sus `items`.

create table if not exists public.merchant_payouts (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references public.merchants (id),
  amount_usd  numeric(18,4) not null check (amount_usd > 0),
  -- Lo que se transfirió de verdad. Puede no ser USD: si se pagó en
  -- bolívares, aquí va el monto y la tasa que se usó.
  amount_ves  numeric(18,2),
  fx_rate     numeric(18,6),
  method      text not null check (method in ('pago_movil', 'transferencia', 'zelle', 'usdt', 'efectivo')),
  reference   text,
  note        text,
  paid_by     uuid not null references auth.users (id),
  business_date date not null,
  created_at  timestamptz not null default now()
);

create index merchant_payouts_merchant_idx
  on public.merchant_payouts (merchant_id, created_at desc);

create table if not exists public.merchant_payout_items (
  payout_id     uuid not null references public.merchant_payouts (id) on delete cascade,
  settlement_id uuid not null references public.settlements (id),
  amount_usd    numeric(18,4) not null check (amount_usd > 0),
  primary key (payout_id, settlement_id)
);

-- Una liquidación solo se puede pagar una vez.
create unique index payout_items_settlement_unique
  on public.merchant_payout_items (settlement_id);

alter table public.merchant_payouts enable row level security;
alter table public.merchant_payout_items enable row level security;

create policy "payouts_read_admin"
  on public.merchant_payouts for select to authenticated
  using (public.is_platform_admin());

create policy "payout_items_read_admin"
  on public.merchant_payout_items for select to authenticated
  using (public.is_platform_admin());

-- El gerente del comercio ve lo que le han pagado.
create policy "payouts_read_merchant"
  on public.merchant_payouts for select to authenticated
  using (
    merchant_id in (
      select merchant_id from public.merchant_users
      where user_id = auth.uid() and is_active and role = 'gerente'
    )
  );

grant select on public.merchant_payouts, public.merchant_payout_items to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Devengar sin mover caja
-- ---------------------------------------------------------------------------

create or replace function ledger.record_advance_settlement(
  p_merchant_id uuid, p_charge_id uuid, p_amount numeric, p_business_date date
)
returns void
language sql
set search_path = public, pg_temp
as $$
  insert into public.settlements
    (merchant_id, charge_id, reason, amount_usd, business_date, due_date, status)
  values
    (p_merchant_id, p_charge_id, 'advance', p_amount, p_business_date, p_business_date, 'pending');
$$;

revoke all on function ledger.record_advance_settlement(uuid, uuid, numeric, date)
  from public, anon, authenticated;

-- --- confirm_charge sin el asiento de caja ---------------------------------
-- Idéntica a la versión de 20260822070000 salvo que el adelanto ya NO mueve
-- `cash`: solo deja la obligación devengada.

create or replace function public.confirm_charge(p_charge_id uuid, p_idempotency_key text)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_user        uuid := auth.uid();
  v_charge      public.charges%rowtype;
  v_profile     public.profiles%rowtype;
  v_limit       numeric(18,4);
  v_block       public.user_credit_blocks%rowtype;
  v_open_debt   numeric(18,4);
  v_terms       public.merchant_settlement_terms%rowtype;
  v_bdate       date;
  v_due_1       date;
  v_due_2       date;
  v_tx          uuid;
  v_acct_recv   uuid;
  v_acct_pay    uuid;
  v_acct_rev    uuid;
  v_upfront     numeric(18,4);
  v_revenue     numeric(18,4);
  v_merchant_share numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  if v_charge.status = 'confirmed' then
    if v_charge.user_id <> v_user then
      raise exception 'Este cobro ya fue tomado por otra persona' using errcode = '42501';
    end if;
    return jsonb_build_object('ok', true, 'charge_id', v_charge.id, 'already_confirmed', true);
  end if;

  if v_charge.status <> 'pending' then
    raise exception 'Este cobro ya no está disponible (%)', v_charge.status using errcode = '22023';
  end if;

  if v_charge.expires_at < now() then
    raise exception 'Este QR caducó, pídele al local que genere uno nuevo' using errcode = '22023';
  end if;

  if v_charge.user_id is not null and v_charge.user_id <> v_user then
    raise exception 'Este cobro ya fue tomado por otra persona' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where id = v_user for update;

  if v_profile.status <> 'active' then
    raise exception 'Tu cuenta no puede consumir en este estado (%)', v_profile.status
      using errcode = '22023';
  end if;

  select monthly_limit_usd into v_limit from public.levels where level = v_profile.level;

  select * into v_block
  from public.user_credit_blocks
  where user_id = v_user and closed_at is null
  for update;

  if not found then
    insert into public.user_credit_blocks (user_id) values (v_user)
    returning * into v_block;
  end if;

  -- El disponible depende de lo CARGADO, no de lo pagado (docs/00-BASES §2.2).
  v_open_debt := v_block.charged_usd;

  if v_open_debt + v_charge.amount_usd > v_limit then
    raise exception 'Saldo insuficiente: disponible $%, cobro $%',
      (v_limit - v_open_debt), v_charge.amount_usd
      using errcode = '22023';
  end if;

  select * into v_terms from public.merchant_settlement_terms where merchant_id = v_charge.merchant_id;

  v_bdate := public.helios_business_date(now());
  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_bdate);

  -- --- Ledger: la venta -------------------------------------------------
  v_acct_recv := ledger.get_or_create_account('user_receivable', v_user);
  v_acct_pay  := ledger.get_or_create_account('merchant_payable', v_charge.merchant_id);
  v_acct_rev  := ledger.get_or_create_account('platform_revenue', null);

  v_revenue := round(v_charge.amount_usd * v_terms.commission_pct / 100, 4);
  v_merchant_share := v_charge.amount_usd - v_revenue;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', p_idempotency_key, v_bdate, v_charge.id, 'Venta en comercio')
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_recv, v_charge.amount_usd, 0),
    (v_tx, v_acct_pay, 0, v_merchant_share),
    (v_tx, v_acct_rev, 0, v_revenue);

  -- --- El adelanto se DEVENGA, no se paga -------------------------------
  -- Antes aquí salía dinero de `cash`. Ahora solo queda la obligación: la
  -- caja se mueve cuando alguien transfiera de verdad y lo reporte.
  v_upfront := round(v_charge.amount_usd * v_terms.upfront_pct / 100, 4);
  perform ledger.record_advance_settlement(v_charge.merchant_id, v_charge.id, v_upfront, v_bdate);

  -- --- Cuotas y bloque ---------------------------------------------------
  insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
    (v_charge.id, v_user, 1, round(v_charge.amount_usd / 2, 4), v_due_1),
    (v_charge.id, v_user, 2, v_charge.amount_usd - round(v_charge.amount_usd / 2, 4), v_due_2);

  update public.user_credit_blocks
    set charged_usd = charged_usd + v_charge.amount_usd
  where id = v_block.id;

  update public.charges
    set status = 'confirmed', user_id = v_user, business_date = v_bdate, confirmed_at = now()
  where id = v_charge.id;

  return jsonb_build_object(
    'ok', true, 'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'due_1', v_due_1, 'due_2', v_due_2
  );
end;
$$;

revoke all on function public.confirm_charge(uuid, text) from public, anon;
grant execute on function public.confirm_charge(uuid, text) to authenticated;

-- --- run_scheduled_settlements: devengar, no pagar -------------------------

create or replace function public.run_scheduled_settlements(p_business_date date)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_inst   record;
  v_terms  public.merchant_settlement_terms%rowtype;
  v_amount numeric(18,4);
  v_count  integer := 0;
begin
  for v_inst in
    select i.id, i.amount_usd, i.due_date, c.merchant_id
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.due_date = p_business_date
  loop
    select * into v_terms from public.merchant_settlement_terms where merchant_id = v_inst.merchant_id;

    if v_terms.policy <> 'scheduled' then
      continue;
    end if;

    -- Idempotente: si ya se devengó esta cuota, no se duplica.
    if exists (
      select 1 from public.settlements
      where installment_id = v_inst.id and reason = 'scheduled_installment'
    ) then
      continue;
    end if;

    v_amount := round(v_inst.amount_usd * v_terms.per_installment_pct / 100, 4);

    insert into public.settlements
      (merchant_id, installment_id, reason, amount_usd, business_date, due_date, status)
    values
      (v_inst.merchant_id, v_inst.id, 'scheduled_installment', v_amount,
       p_business_date, v_inst.due_date, 'pending');

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.run_scheduled_settlements(date) from public, anon, authenticated;
