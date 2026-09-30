-- ============================================================================
-- Ronda — Corrige el modelo de cobro: el QR se reclama, no se dirige
--
-- Bug de diseño en 20260822055000_charge_rpcs.sql: `request_charge` exigía
-- `p_user_id`, o sea, asumía que el cajero ya sabe quién es el cliente en el
-- momento de generar el cobro. El mecanismo decidido (docs/06-REGLAS §2) es
-- un **QR dinámico generado por el comercio**: el cajero teclea el monto y
-- muestra el QR en la tablet SIN saber quién lo va a escanear. Es el usuario
-- quien, al escanear y confirmar, se identifica.
--
-- El modelo correcto:
--   1. El cajero llama request_charge(comercio, sucursal, monto) → cobro
--      pendiente SIN dueño. La tablet muestra el QR con el id.
--   2. El usuario escanea y llama preview_charge(id) para ver qué le van a
--      cobrar y de qué local ANTES de aceptar nada.
--   3. Al confirmar, confirm_charge(id) RECLAMA el cobro para quien lo
--      llama. El primero que llega se lo lleva; los demás reciben error.
--
-- Añade caducidad, que sin dueño pasa a ser una defensa real: un QR
-- fotografiado de la pantalla de la tablet lo puede reclamar un tercero.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El dueño del cobro pasa a ser desconocido hasta que alguien lo reclama
-- ---------------------------------------------------------------------------

alter table public.charges alter column user_id drop not null;

comment on column public.charges.user_id is
  'Null mientras el cobro está pendiente: se fija al reclamarlo (confirm_charge).';

-- Un cobro confirmado SIEMPRE tiene dueño. Sin esto, un bug futuro podría
-- dejar una venta sin a quién cobrarle y el descuadre sería silencioso.
alter table public.charges
  add constraint charges_confirmed_has_owner
  check (status <> 'confirmed' or user_id is not null);

-- Caducidad del QR. docs/00-BASES §2.3 lo dejó sin confirmar ("se propuso
-- ~2 min"); se implementa en 5 porque la secuencia real del usuario en un
-- local a las 3 AM —desbloquear el teléfono, abrir la app, meter el PIN,
-- escanear, confirmar— no cabe cómoda en dos minutos. Es un parámetro, no
-- una constante: cambiarlo es un ALTER del default.
alter table public.charges
  add column expires_at timestamptz not null default (now() + interval '5 minutes');

comment on column public.charges.expires_at is
  'Caducidad del QR. Sin dueño hasta que se reclama, la ventana corta es la defensa.';

create index charges_pending_expiry_idx
  on public.charges (expires_at) where status = 'pending';

-- La política de lectura del usuario ya filtra por user_id = auth.uid(), así
-- que un cobro pendiente (user_id null) es invisible para todos. Correcto:
-- el usuario lo consulta por RPC con el id que acaba de escanear, no
-- navegando la tabla.

-- ---------------------------------------------------------------------------
-- 2. request_charge sin destinatario
-- ---------------------------------------------------------------------------

drop function if exists public.request_charge(uuid, uuid, uuid, numeric, text);

create or replace function public.request_charge(
  p_merchant_id     uuid,
  p_branch_id       uuid,
  p_amount_usd      numeric,
  p_idempotency_key text
)
returns public.charges
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff   uuid := auth.uid();
  v_row     public.charges%rowtype;
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
  -- cajero), se devuelve el mismo en vez de generar un segundo QR vivo.
  insert into public.charges (merchant_id, branch_id, requested_by, amount_usd, idempotency_key)
  values (p_merchant_id, p_branch_id, v_staff, p_amount_usd, p_idempotency_key)
  on conflict (idempotency_key) do nothing
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from public.charges where idempotency_key = p_idempotency_key;
  end if;

  return v_row;
end;
$$;

revoke all on function public.request_charge(uuid, uuid, numeric, text) from public, anon;
grant execute on function public.request_charge(uuid, uuid, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. preview_charge — qué me van a cobrar, antes de aceptar
-- ---------------------------------------------------------------------------
-- Devuelve solo lo que el usuario necesita para decidir. Nada del comercio
-- más allá del nombre: ni sus condiciones de liquidación, ni quién es el
-- cajero.

create or replace function public.preview_charge(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user    uuid := auth.uid();
  v_charge  public.charges%rowtype;
  v_name    text;
  v_branch  text;
  v_avail   jsonb;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  select m.name, b.name into v_name, v_branch
  from public.merchants m
  join public.merchant_branches b on b.id = v_charge.branch_id
  where m.id = v_charge.merchant_id;

  v_avail := public.my_available_balance();

  return jsonb_build_object(
    'charge_id', v_charge.id,
    'merchant_name', v_name,
    'branch_name', v_branch,
    'amount_usd', v_charge.amount_usd,
    'status', v_charge.status,
    'expired', v_charge.expires_at < now(),
    -- Ya reclamado por otra persona: la app debe decirlo con claridad en vez
    -- de dejar al usuario reintentando un QR muerto.
    'claimed_by_other', (v_charge.user_id is not null and v_charge.user_id <> v_user),
    'available_usd', (v_avail->>'available_usd')::numeric,
    'sufficient_balance', (v_avail->>'available_usd')::numeric >= v_charge.amount_usd
  );
end;
$$;

revoke all on function public.preview_charge(uuid) from public, anon;
grant execute on function public.preview_charge(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. confirm_charge reclama el cobro
-- ---------------------------------------------------------------------------
-- Igual que la versión anterior salvo el bloque de identificación: en vez de
-- comprobar que el cobro "te pertenece", lo reclama para quien lo confirma.
-- El SELECT ... FOR UPDATE del principio serializa a dos usuarios que
-- escanean el mismo QR a la vez: el segundo ve user_id ya puesto y falla.

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

  -- Idempotente: el mismo usuario confirmando dos veces (reintento de red)
  -- obtiene el mismo resultado sin volver a mover dinero.
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

  -- Reclamo: si alguien ya lo tomó, no es tuyo. Si no, pasa a serlo.
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
  -- los dos créditos siempre suman exactamente el débito.
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

-- ---------------------------------------------------------------------------
-- 5. Barrido de QR caducados
-- ---------------------------------------------------------------------------
-- Un pendiente caducado no hace daño (confirm_charge lo rechaza), pero
-- dejarlo pendiente para siempre ensucia el panel del comercio.

create or replace function public.expire_stale_charges()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  update public.charges
    set status = 'voided', void_reason = 'QR caducado sin usar', voided_at = now()
  where status = 'pending' and expires_at < now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.expire_stale_charges() from public, anon, authenticated;

select cron.schedule(
  'helios_expire_stale_charges',
  '*/10 * * * *',
  $$ select public.expire_stale_charges(); $$
);
