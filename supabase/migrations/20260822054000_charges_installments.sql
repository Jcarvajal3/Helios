-- ============================================================================
-- Ronda — Consumos (charges) y cuotas (installments)
--
-- Viven en `public` con RLS de solo lectura, a diferencia de `ledger`: el
-- usuario y el comercio necesitan ver "cuánto compré" y "cuándo vence cada
-- cuota" en tiempo real (Home, panel del comercio). El detalle contable de
-- partida doble que sustenta estas filas vive oculto en `ledger`.
--
-- Regla de cobro en el local (docs/06-REGLAS-OPERATIVAS.md §2): QR dinámico,
-- sin reversas, mínimo $5, máximo el disponible del usuario. El cajero
-- solicita el cobro (`request_charge`); el usuario lo confirma desde su
-- teléfono (`confirm_charge`, migración siguiente) — ese confirm es el único
-- instante en que se mueve dinero.
-- ============================================================================

create type public.charge_status as enum (
  'pending',    -- el comercio la generó, esperando confirmación del usuario
  'confirmed',  -- el usuario confirmó: ya generó deuda y cuotas
  'voided'      -- anulada por el super admin (docs/06 §2: no hay reversa del comercio)
);

create table if not exists public.charges (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  merchant_id   uuid not null references public.merchants (id),
  branch_id     uuid not null references public.merchant_branches (id),
  -- Quién generó el QR en el comercio.
  requested_by  uuid not null references auth.users (id),
  amount_usd    numeric(18,4) not null check (amount_usd >= 5.00),
  -- Obligatoria en toda mutación de dinero (docs/01 §5.3): un reintento de
  -- red del cajero no debe generar un segundo cobro pendiente.
  idempotency_key text not null unique,
  status        public.charge_status not null default 'pending',
  business_date date,  -- se fija al confirmar, con el día operativo de ese instante
  void_reason   text,
  voided_by     uuid references auth.users (id),
  created_at    timestamptz not null default now(),
  confirmed_at  timestamptz,
  voided_at     timestamptz
);

create index charges_user_idx on public.charges (user_id);
create index charges_merchant_idx on public.charges (merchant_id);
create index charges_status_idx on public.charges (status) where status = 'pending';

alter table public.charges enable row level security;

create policy "charges_read_own"
  on public.charges for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy "charges_read_merchant_staff"
  on public.charges for select
  to authenticated
  using (merchant_id in (select public.my_merchant_ids()));

-- Sin políticas de escritura: crear, confirmar y anular son siempre RPC.

create type public.installment_status as enum ('pending', 'paid');

create table if not exists public.installments (
  id           uuid primary key default gen_random_uuid(),
  charge_id    uuid not null references public.charges (id),
  user_id      uuid not null references auth.users (id) on delete cascade,
  -- 1 o 2. No hay una tercera cuota, así que un smallint con check basta.
  sequence     smallint not null check (sequence in (1, 2)),
  amount_usd   numeric(18,4) not null check (amount_usd > 0),
  due_date     date not null,
  status       public.installment_status not null default 'pending',
  paid_at      timestamptz,
  created_at   timestamptz not null default now(),
  unique (charge_id, sequence)
);

create index installments_user_idx on public.installments (user_id);
create index installments_due_pending_idx
  on public.installments (user_id, due_date) where status = 'pending';

alter table public.installments enable row level security;

create policy "installments_read_own"
  on public.installments for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Sin políticas de escritura: solo las mueven las RPC de cobro y conciliación.
