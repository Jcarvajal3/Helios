-- ============================================================================
-- Ronda — RPCs de cobro en el local
--
-- request_charge  → el cajero/gerente genera el cobro (el "QR").
-- confirm_charge   → el usuario confirma. Es el único punto del sistema que
--                     mueve dinero por una venta: valida el bloque de
--                     crédito, postea la venta y el adelanto al comercio, y
--                     crea las dos cuotas con sus vencimientos.
-- void_charge      → válvula de escape del super admin (docs/06 §2): sin
--                     reversa para el comercio, pero un cajero se equivoca de
--                     monto tarde o temprano.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- request_charge
-- ---------------------------------------------------------------------------

create or replace function public.request_charge(
  p_merchant_id   uuid,
  p_branch_id     uuid,
  p_user_id       uuid,
  p_amount_usd    numeric,
  p_idempotency_key text
)
returns public.charges
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := auth.uid();
  v_row   public.charges%rowtype;
  v_allowed boolean;
begin
  if v_staff is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if p_amount_usd < 5.00 then
    raise exception 'El monto mínimo por cobro es $5.00' using errcode = '22023';
  end if;

  select exists (
    select 1 from public.merchant_users
    where user_id = v_staff
      and merchant_id = p_merchant_id
      and is_active
      -- Un gerente (branch_id null) cubre todas las sucursales; un cajero
      -- solo la suya (ya lo exige el check cajero_requires_branch).
      and (branch_id is null or branch_id = p_branch_id)
  ) into v_allowed;

  if not v_allowed then
    raise exception 'No autorizado a cobrar en este comercio/sucursal' using errcode = '42501';
  end if;

  -- Idempotente: si ya existe un cobro con esta clave (reintento de red del
  -- cajero), se devuelve el mismo en vez de crear uno nuevo.
  insert into public.charges (user_id, merchant_id, branch_id, requested_by, amount_usd, idempotency_key)
  values (p_user_id, p_merchant_id, p_branch_id, v_staff, p_amount_usd, p_idempotency_key)
  on conflict (idempotency_key) do nothing
  returning * into v_row;

  if not found then
    select * into v_row from public.charges where idempotency_key = p_idempotency_key;
  end if;

  return v_row;
end;
$$;

revoke all on function public.request_charge(uuid, uuid, uuid, numeric, text) from public, anon;
grant execute on function public.request_charge(uuid, uuid, uuid, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- confirm_charge
-- ---------------------------------------------------------------------------

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
  v_acct_cash   uuid;
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

  if v_charge.user_id <> v_user then
    raise exception 'Este cobro no te pertenece' using errcode = '42501';
  end if;

  if v_charge.status = 'confirmed' then
    -- Idempotente: confirmar dos veces devuelve el mismo resultado sin
    -- volver a mover dinero.
    return jsonb_build_object('ok', true, 'charge_id', v_charge.id, 'already_confirmed', true);
  end if;

  if v_charge.status <> 'pending' then
    raise exception 'Este cobro ya no está disponible (%)', v_charge.status using errcode = '22023';
  end if;

  select * into v_profile from public.profiles where id = v_user for update;

  if v_profile.status <> 'active' then
    raise exception 'Tu cuenta no puede consumir en este estado (%)', v_profile.status
      using errcode = '22023';
  end if;

  select monthly_limit_usd into v_limit from public.levels where level = v_profile.level;

  -- Bloque de crédito: uno abierto por usuario. Se abre uno nuevo si no hay.
  select * into v_block
  from public.user_credit_blocks
  where user_id = v_user and closed_at is null
  for update;

  if not found then
    insert into public.user_credit_blocks (user_id) values (v_user)
    returning * into v_block;
  end if;

  -- El disponible depende de lo CARGADO, no de lo pagado: pagar una cuota no
  -- libera cupo nuevo (docs/00-BASES §2.2, "no hay liberación parcial").
  v_open_debt := v_block.charged_usd;

  if v_open_debt + v_charge.amount_usd > v_limit then
    raise exception 'Saldo insuficiente: disponible $%, cobro $%',
      (v_limit - v_open_debt), v_charge.amount_usd
      using errcode = '22023';
  end if;

  select * into v_terms from public.merchant_settlement_terms where merchant_id = v_charge.merchant_id;

  v_bdate := public.helios_business_date(now());
  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_bdate);

  -- --- Ledger: venta ---------------------------------------------------
  v_acct_recv := ledger.get_or_create_account('user_receivable', v_user);
  v_acct_pay  := ledger.get_or_create_account('merchant_payable', v_charge.merchant_id);
  v_acct_rev  := ledger.get_or_create_account('platform_revenue', null);
  v_acct_cash := ledger.get_or_create_account('cash', null);

  -- La comisión se redondea una sola vez y el comercio recibe el resto: así
  -- los dos créditos siempre suman exactamente el débito, sin depender de
  -- que dos redondeos independientes coincidan.
  v_revenue := round(v_charge.amount_usd * v_terms.commission_pct / 100, 4);
  v_merchant_share := v_charge.amount_usd - v_revenue;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', p_idempotency_key, v_bdate, v_charge.id, 'Venta en comercio')
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_recv, v_charge.amount_usd, 0),
    (v_tx, v_acct_pay, 0, v_merchant_share),
    (v_tx, v_acct_rev, 0, v_revenue);

  -- --- Ledger: adelanto inmediato al comercio (docs/05 §3) --------------
  v_upfront := round(v_charge.amount_usd * v_terms.upfront_pct / 100, 4);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('merchant_advance', p_idempotency_key || ':advance', v_bdate, v_charge.id, 'Adelanto al vender')
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_pay, v_upfront, 0),
    (v_tx, v_acct_cash, 0, v_upfront);

  perform ledger.record_advance_settlement(v_charge.merchant_id, v_charge.id, v_upfront, v_bdate);

  -- --- Cuotas y bloque ---------------------------------------------------
  insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
    (v_charge.id, v_user, 1, round(v_charge.amount_usd / 2, 4), v_due_1),
    (v_charge.id, v_user, 2, v_charge.amount_usd - round(v_charge.amount_usd / 2, 4), v_due_2);

  update public.user_credit_blocks
    set charged_usd = charged_usd + v_charge.amount_usd
  where id = v_block.id;

  update public.charges
    set status = 'confirmed', business_date = v_bdate, confirmed_at = now()
  where id = v_charge.id;

  return jsonb_build_object('ok', true, 'charge_id', v_charge.id, 'due_1', v_due_1, 'due_2', v_due_2);
end;
$$;

revoke all on function public.confirm_charge(uuid, text) from public, anon;
grant execute on function public.confirm_charge(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- void_charge — solo super admin (service role). No hay reversa para el
-- comercio: esto es la excepción manual, auditada, para un cajero que se
-- equivocó de monto. Solo antes de confirmar; una vez confirmada, revertir
-- ya movió dinero real y requiere un ajuste manual explícito, no un void.
-- ---------------------------------------------------------------------------

create or replace function public.void_charge(p_charge_id uuid, p_actor uuid, p_reason text)
returns public.charges
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.charges%rowtype;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'Anular un cobro requiere motivo' using errcode = '22023';
  end if;

  select * into v_row from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  if v_row.status <> 'pending' then
    raise exception 'Solo se puede anular un cobro pendiente (estado actual: %)', v_row.status
      using errcode = '22023';
  end if;

  update public.charges
    set status = 'voided', void_reason = p_reason, voided_by = p_actor, voided_at = now()
  where id = p_charge_id
  returning * into v_row;

  return v_row;
end;
$$;

-- Sin grant: solo el service role (super admin) puede anular.
revoke all on function public.void_charge(uuid, uuid, text) from public, anon, authenticated;
