-- ============================================================================
-- Ronda — Comercios, sucursales, roles y catálogo
--
-- Las sucursales existen desde el primer día aunque la v1 no las use en la UI:
-- todo comercio nace con una sucursal por defecto. Añadir `branch_id` después
-- habría obligado a migrar transacciones, liquidaciones y permisos en
-- producción; crearlo ahora no cuesta nada.
-- ============================================================================

create type public.merchant_status as enum ('active', 'paused', 'terminated');

create type public.merchant_role as enum (
  'gerente',    -- ve facturación y liquidaciones de su alcance
  'cajero',     -- cobra; ve solo sus propias transacciones
  'inventario'  -- gestiona el catálogo; no ve dinero
);

/** Política de liquidación al comercio. Ver docs/05-REGLAS-CONFIRMADAS.md §3. */
create type public.settlement_policy as enum (
  'scheduled',      -- paga en las fechas pactadas aunque el usuario se atrase
  'on_collection'   -- paga a medida que se cobra al usuario
);

-- ---------------------------------------------------------------------------
-- Comercios
-- ---------------------------------------------------------------------------

create table if not exists public.merchants (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  legal_name text,
  tax_id     text unique,               -- RIF
  status     public.merchant_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.merchants is
  'Las cuentas de comercio las crea el super admin, nunca se autorregistran.';

create table if not exists public.merchant_branches (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references public.merchants(id) on delete cascade,
  name        text not null,
  address     text,
  -- Cada comercio tiene exactamente una sucursal por defecto: es a la que se
  -- imputa todo mientras la UI no exponga el selector.
  is_default  boolean not null default false,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create index if not exists branches_merchant_idx
  on public.merchant_branches (merchant_id);

create unique index if not exists branches_one_default_per_merchant
  on public.merchant_branches (merchant_id)
  where is_default;

-- ---------------------------------------------------------------------------
-- Condiciones de liquidación
-- ---------------------------------------------------------------------------
-- Negociables por comercio. Los valores por defecto son los del modelo
-- acordado: 30% al vender, 25% + 25% en cada cuota, 20% de comisión.

create table if not exists public.merchant_settlement_terms (
  merchant_id         uuid primary key references public.merchants(id) on delete cascade,
  upfront_pct         numeric(5,2) not null default 30.00,
  per_installment_pct numeric(5,2) not null default 25.00,
  commission_pct      numeric(5,2) not null default 20.00,
  policy              public.settlement_policy not null default 'scheduled',
  updated_at          timestamptz not null default now(),

  -- Lo que recibe el comercio más la comisión debe sumar exactamente el
  -- consumo. Sin esta comprobación, un error de tipeo en el super admin
  -- descuadraría el libro contable de forma silenciosa.
  constraint settlement_adds_up check (
    upfront_pct + (per_installment_pct * 2) + commission_pct = 100.00
  ),
  constraint settlement_non_negative check (
    upfront_pct >= 0 and per_installment_pct >= 0 and commission_pct >= 0
  )
);

-- ---------------------------------------------------------------------------
-- Personal del comercio
-- ---------------------------------------------------------------------------

create table if not exists public.merchant_users (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  merchant_id uuid not null references public.merchants(id) on delete cascade,
  -- Null = alcance sobre todo el comercio (un gerente general).
  -- Con valor = limitado a esa sucursal (el caso típico del cajero).
  branch_id   uuid references public.merchant_branches(id) on delete cascade,
  role        public.merchant_role not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (user_id, merchant_id, branch_id)
);

create index if not exists merchant_users_user_idx on public.merchant_users (user_id);
create index if not exists merchant_users_merchant_idx on public.merchant_users (merchant_id);

-- Un cajero siempre trabaja en una sucursal concreta.
alter table public.merchant_users
  add constraint cajero_requires_branch
  check (role <> 'cajero' or branch_id is not null);

-- ---------------------------------------------------------------------------
-- Catálogo
-- ---------------------------------------------------------------------------
-- Deliberadamente mínimo: nombre, precio y categoría. Sin imágenes.

create table if not exists public.product_categories (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references public.merchants(id) on delete cascade,
  name        text not null,
  sort_order  smallint not null default 0,
  unique (merchant_id, name)
);

create table if not exists public.products (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references public.merchants(id) on delete cascade,
  -- Null = disponible en todas las sucursales del comercio.
  branch_id   uuid references public.merchant_branches(id) on delete cascade,
  category_id uuid references public.product_categories(id) on delete set null,
  name        text not null,
  -- El USD es la moneda canónica en todo el sistema. Ver docs 05 §1.
  price_usd   numeric(18,4) not null check (price_usd >= 0),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists products_merchant_idx on public.products (merchant_id)
  where is_active;
create index if not exists products_branch_idx on public.products (branch_id);

-- ---------------------------------------------------------------------------
-- Automatismos
-- ---------------------------------------------------------------------------

-- Todo comercio nuevo nace con su sucursal principal y sus condiciones de
-- liquidación por defecto. Evita comercios a medio configurar.
create or replace function public.bootstrap_merchant()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.merchant_branches (merchant_id, name, is_default)
  values (new.id, 'Principal', true);

  insert into public.merchant_settlement_terms (merchant_id)
  values (new.id);

  return new;
end;
$$;

revoke all on function public.bootstrap_merchant() from public, anon, authenticated;

drop trigger if exists on_merchant_created on public.merchants;
create trigger on_merchant_created
  after insert on public.merchants
  for each row execute function public.bootstrap_merchant();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
-- El panel web usa estas políticas. La app móvil solo necesita leer comercios
-- activos (para mostrar dónde puede pagar) y su catálogo.

alter table public.merchants enable row level security;
alter table public.merchant_branches enable row level security;
alter table public.merchant_settlement_terms enable row level security;
alter table public.merchant_users enable row level security;
alter table public.product_categories enable row level security;
alter table public.products enable row level security;

/** Comercios a los que pertenece el usuario actual. */
create or replace function public.my_merchant_ids()
returns setof uuid
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select merchant_id from public.merchant_users
  where user_id = auth.uid() and is_active;
$$;

revoke all on function public.my_merchant_ids() from public, anon;
grant execute on function public.my_merchant_ids() to authenticated;

-- Cualquier usuario autenticado ve los comercios activos y sus sucursales.
create policy "merchants_read_active"
  on public.merchants for select to authenticated
  using (status = 'active' or id in (select public.my_merchant_ids()));

create policy "branches_read_active"
  on public.merchant_branches for select to authenticated
  using (is_active or merchant_id in (select public.my_merchant_ids()));

create policy "products_read_active"
  on public.products for select to authenticated
  using (is_active or merchant_id in (select public.my_merchant_ids()));

create policy "categories_read"
  on public.product_categories for select to authenticated
  using (true);

-- El personal ve su propia vinculación.
create policy "merchant_users_read_own"
  on public.merchant_users for select to authenticated
  using (user_id = (select auth.uid()));

-- Las condiciones de liquidación solo las ve el personal del comercio.
-- Nunca un cajero: es información de negocio del dueño.
create policy "settlement_terms_read_staff"
  on public.merchant_settlement_terms for select to authenticated
  using (
    merchant_id in (
      select merchant_id from public.merchant_users
      where user_id = auth.uid() and is_active and role = 'gerente'
    )
  );

-- Sin políticas de escritura: crear comercios, mover porcentajes y asignar
-- personal son operaciones del super admin, que corre con service role.

drop trigger if exists merchants_touch_updated_at on public.merchants;
create trigger merchants_touch_updated_at
  before update on public.merchants
  for each row execute function public.touch_updated_at();

drop trigger if exists products_touch_updated_at on public.products;
create trigger products_touch_updated_at
  before update on public.products
  for each row execute function public.touch_updated_at();
