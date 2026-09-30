-- ============================================================================
-- Ronda — Libro contable de partida doble (append-only)
--
-- docs/01-ARQUITECTURA.md §5.1 y §5.4: todo movimiento de dinero es un
-- asiento inmutable, nunca un UPDATE de saldo. El esquema `ledger` es
-- inaccesible desde el cliente — ni RLS de lectura ni policies de escritura.
-- Todo acceso pasa por funciones SECURITY DEFINER en `public`.
--
-- Convención de signos: cada cuenta tiene un "saldo normal". Para las
-- cuentas de activo (user_receivable, cash) el saldo normal es deudor: el
-- balance sube con débitos. Para pasivo e ingreso (merchant_payable,
-- platform_revenue, bad_debt_provision) el saldo normal es acreedor: el
-- balance de ledger.account_balance() será negativo para esas cuentas
-- cuando tengan saldo — es la convención contable estándar, no un error.
-- ============================================================================

create schema if not exists ledger;
revoke all on schema ledger from public, anon, authenticated;

create type ledger.account_type as enum (
  'user_receivable',     -- lo que nos debe un usuario — una cuenta por usuario
  'merchant_payable',    -- lo que le debemos a un comercio — una cuenta por comercio
  'platform_revenue',    -- comisión devengada por Ronda — cuenta única
  'cash',                -- caja/banco propio — cuenta única
  'bad_debt_provision',  -- provisión de incobrables — cuenta única
  'fx_difference'        -- diferencia cambiaria de conciliación — cuenta única
);

create table ledger.accounts (
  id           uuid primary key default gen_random_uuid(),
  account_type ledger.account_type not null,
  -- user_id o merchant_id para las cuentas por titular; null para las cuentas
  -- únicas de la plataforma (cash, platform_revenue, bad_debt_provision, fx_difference).
  owner_id     uuid,
  created_at   timestamptz not null default now()
);

-- Una sola cuenta global por tipo, una sola cuenta por titular y tipo.
create unique index accounts_global_unique
  on ledger.accounts (account_type) where owner_id is null;
create unique index accounts_owner_unique
  on ledger.accounts (account_type, owner_id) where owner_id is not null;

create type ledger.transaction_type as enum (
  'charge',               -- consumo en el local (venta)
  'merchant_advance',     -- adelanto al comercio al vender
  'installment_payment',  -- el usuario paga/reporta una cuota, conciliada
  'merchant_settlement',  -- liquidación al comercio (por fecha o por cobranza)
  'charge_off',           -- castigo por impago (> 30 días de mora)
  'fx_adjustment',        -- diferencia cambiaria detectada en conciliación
  'manual_adjustment'     -- ajuste del super admin — siempre con actor y motivo
);

create table ledger.transactions (
  id              uuid primary key default gen_random_uuid(),
  type            ledger.transaction_type not null,
  -- Obligatoria en toda mutación de dinero (docs/01 §5.3): evita procesar dos
  -- veces el mismo evento ante un reintento de red.
  idempotency_key text not null unique,
  business_date   date not null,
  -- Fila de origen en public (charge, installment, payment_report...). Sin FK
  -- porque el origen varía según el tipo; es solo trazabilidad para auditoría.
  reference_id    uuid,
  memo            text,
  -- null = generado por el sistema. Con valor, el admin que lo autorizó.
  created_by      uuid,
  created_at      timestamptz not null default now()
);

create index transactions_business_date_idx on ledger.transactions (business_date);
create index transactions_reference_idx on ledger.transactions (reference_id);

create table ledger.entries (
  id             bigint generated always as identity primary key,
  transaction_id uuid not null references ledger.transactions (id),
  account_id     uuid not null references ledger.accounts (id),
  debit          numeric(18,4) not null default 0 check (debit >= 0),
  credit         numeric(18,4) not null default 0 check (credit >= 0),
  created_at     timestamptz not null default now(),
  -- Un asiento mueve un lado a la vez. Un "debit y credit" en la misma fila
  -- es el error clásico que hace que el libro cuadre por accidente.
  constraint entries_one_side check ((debit = 0) <> (credit = 0))
);

create index entries_account_idx on ledger.entries (account_id);
create index entries_transaction_idx on ledger.entries (transaction_id);

-- ---------------------------------------------------------------------------
-- Inmutabilidad: nada de UPDATE ni DELETE sobre transacciones ni asientos.
-- ---------------------------------------------------------------------------

create or replace function ledger.block_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
begin
  raise exception 'ledger.% es append-only: % no está permitido', tg_table_name, tg_op;
end;
$$;

create trigger transactions_no_update before update on ledger.transactions
  for each row execute function ledger.block_mutation();
create trigger transactions_no_delete before delete on ledger.transactions
  for each row execute function ledger.block_mutation();
create trigger entries_no_update before update on ledger.entries
  for each row execute function ledger.block_mutation();
create trigger entries_no_delete before delete on ledger.entries
  for each row execute function ledger.block_mutation();

-- ---------------------------------------------------------------------------
-- Cuadre: cada transacción debe sumar débitos = créditos. Se valida al final
-- de la transacción de Postgres (deferred), después de insertar todos sus
-- asientos, para no exigir un orden particular de inserción.
-- ---------------------------------------------------------------------------

create or replace function ledger.check_transaction_balances()
returns trigger
language plpgsql
set search_path = ledger, pg_temp
as $$
declare
  v_diff numeric(18,4);
begin
  select coalesce(sum(debit) - sum(credit), 0) into v_diff
  from ledger.entries
  where transaction_id = new.transaction_id;

  if v_diff <> 0 then
    raise exception 'ledger.entries no cuadra para la transacción %: diferencia %',
      new.transaction_id, v_diff;
  end if;

  return null;
end;
$$;

create constraint trigger entries_balance_check
  after insert on ledger.entries
  deferrable initially deferred
  for each row execute function ledger.check_transaction_balances();

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Obtiene la cuenta de un tipo/titular, creándola si es la primera vez.
create or replace function ledger.get_or_create_account(p_type ledger.account_type, p_owner_id uuid)
returns uuid
language plpgsql
set search_path = ledger, pg_temp
as $$
declare
  v_id uuid;
begin
  if p_owner_id is null then
    select id into v_id from ledger.accounts where account_type = p_type and owner_id is null;
  else
    select id into v_id from ledger.accounts where account_type = p_type and owner_id = p_owner_id;
  end if;

  if v_id is not null then
    return v_id;
  end if;

  begin
    insert into ledger.accounts (account_type, owner_id) values (p_type, p_owner_id)
    returning id into v_id;
  exception when unique_violation then
    -- Otra transacción concurrente la creó primero.
    if p_owner_id is null then
      select id into v_id from ledger.accounts where account_type = p_type and owner_id is null;
    else
      select id into v_id from ledger.accounts where account_type = p_type and owner_id = p_owner_id;
    end if;
  end;

  return v_id;
end;
$$;

-- Saldo de una cuenta, en la convención de signos del encabezado de este archivo.
create or replace function ledger.account_balance(p_account_id uuid)
returns numeric
language sql
stable
set search_path = ledger, pg_temp
as $$
  select coalesce(sum(debit) - sum(credit), 0)
  from ledger.entries
  where account_id = p_account_id;
$$;
