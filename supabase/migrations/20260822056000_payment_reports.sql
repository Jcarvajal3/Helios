-- ============================================================================
-- Ronda — Cotización, reporte y conciliación de pagos
--
-- No hay procesador de pagos (docs/01-ARQUITECTURA.md §8): el usuario paga
-- por fuera (Pago Móvil, transferencia, Zelle, USDT) y reporta la
-- referencia. Este archivo cubre el mínimo de primera clase que pide el doc:
-- cotización con vigencia, UNIQUE de referencia, y una máquina de estados
-- auditada. El importador de estados de cuenta y el auto-match por CSV son
-- de la fase de Operación, no de esto.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Cotizaciones
-- ---------------------------------------------------------------------------
-- Se persiste cada cotización (no se recalcula al vuelo) porque la
-- conciliación necesita saber, seis meses después, a qué tasa exacta se le
-- cotizó al usuario ese pago.

create table if not exists public.payment_quotes (
  id             uuid primary key default gen_random_uuid(),
  installment_id uuid not null references public.installments (id),
  user_id        uuid not null references auth.users (id) on delete cascade,
  amount_usd     numeric(18,4) not null,
  fx_rate        numeric(18,6) not null,
  amount_ves     numeric(18,2) not null,
  -- Vence al final del día operativo America/Caracas: el BCV publica una
  -- vez al día, así que una cotización de la mañana sigue viva de noche.
  valid_until    timestamptz not null,
  created_at     timestamptz not null default now()
);

create index payment_quotes_installment_idx on public.payment_quotes (installment_id);

alter table public.payment_quotes enable row level security;

create policy "payment_quotes_read_own"
  on public.payment_quotes for select
  to authenticated
  using (user_id = (select auth.uid()));

create or replace function public.quote_installment_payment(p_installment_id uuid)
returns public.payment_quotes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_inst  public.installments%rowtype;
  v_rate  numeric(18,6);
  v_row   public.payment_quotes%rowtype;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_inst from public.installments where id = p_installment_id;
  if not found or v_inst.user_id <> v_user then
    raise exception 'Cuota no encontrada' using errcode = 'P0002';
  end if;

  if v_inst.status <> 'pending' then
    raise exception 'Esta cuota ya está pagada' using errcode = '22023';
  end if;

  v_rate := public.current_fx_rate();
  if v_rate is null then
    raise exception 'No hay tasa de cambio vigente' using errcode = 'P0002';
  end if;

  insert into public.payment_quotes (installment_id, user_id, amount_usd, fx_rate, amount_ves, valid_until)
  values (
    p_installment_id,
    v_user,
    v_inst.amount_usd,
    v_rate,
    round(v_inst.amount_usd * v_rate, 2),
    -- Fin del día calendario en Caracas (docs/05 §1), no del día operativo:
    -- una cotización de la tarde debe seguir viva esa misma noche.
    (date_trunc('day', now() at time zone 'America/Caracas') + interval '1 day') at time zone 'America/Caracas'
  )
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.quote_installment_payment(uuid) from public, anon;
grant execute on function public.quote_installment_payment(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Reportes de pago
-- ---------------------------------------------------------------------------

create type public.payment_report_status as enum (
  'reported', 'in_review', 'reconciled', 'rejected', 'duplicate'
);

create table if not exists public.payment_reports (
  id             uuid primary key default gen_random_uuid(),
  quote_id       uuid not null references public.payment_quotes (id),
  installment_id uuid not null references public.installments (id),
  user_id        uuid not null references auth.users (id) on delete cascade,
  method         text not null check (method in ('pago_movil', 'transferencia', 'zelle', 'usdt', 'efectivo')),
  bank           text,
  -- Nula para efectivo. Con valor, es el dato antifraude #1: reusar una
  -- referencia para pagar dos cuotas.
  reference      text,
  receipt_path   text,
  status         public.payment_report_status not null default 'reported',
  reviewed_by    uuid references auth.users (id),
  reviewed_at    timestamptz,
  rejection_note text,
  created_at     timestamptz not null default now()
);

-- Reusar una referencia real (no nula) es el fraude número uno del modelo.
create unique index payment_reports_reference_unique
  on public.payment_reports (bank, reference) where reference is not null;

create index payment_reports_installment_idx on public.payment_reports (installment_id);
create index payment_reports_status_idx on public.payment_reports (status) where status in ('reported', 'in_review');

alter table public.payment_reports enable row level security;

create policy "payment_reports_read_own"
  on public.payment_reports for select
  to authenticated
  using (user_id = (select auth.uid()));

create or replace function public.report_installment_payment(
  p_quote_id  uuid,
  p_method    text,
  p_bank      text,
  p_reference text,
  p_receipt_path text default null
)
returns public.payment_reports
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_quote public.payment_quotes%rowtype;
  v_row   public.payment_reports%rowtype;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_quote from public.payment_quotes where id = p_quote_id for update;
  if not found or v_quote.user_id <> v_user then
    raise exception 'Cotización no encontrada' using errcode = 'P0002';
  end if;

  if v_quote.valid_until < now() then
    raise exception 'La cotización venció, vuelve a cotizar' using errcode = '22023';
  end if;

  if p_method <> 'efectivo' and (p_reference is null or length(trim(p_reference)) = 0) then
    raise exception 'La referencia es obligatoria para % ' , p_method using errcode = '22023';
  end if;

  if exists (
    select 1 from public.payment_reports
    where installment_id = v_quote.installment_id and status in ('reported', 'in_review')
  ) then
    raise exception 'Ya hay un reporte pendiente para esta cuota' using errcode = '22023';
  end if;

  insert into public.payment_reports (quote_id, installment_id, user_id, method, bank, reference, receipt_path)
  values (p_quote_id, v_quote.installment_id, v_user, p_method, p_bank, p_reference, p_receipt_path)
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    -- Referencia ya usada — se marca como tal en vez de dejarla "reported"
    -- indefinidamente esperando revisión manual.
    insert into public.payment_reports
      (quote_id, installment_id, user_id, method, bank, reference, receipt_path, status)
    values (p_quote_id, v_quote.installment_id, v_user, p_method, p_bank, p_reference, p_receipt_path, 'duplicate')
    returning * into v_row;
    return v_row;
end;
$$;

revoke all on function public.report_installment_payment(uuid, text, text, text, text) from public, anon;
grant execute on function public.report_installment_payment(uuid, text, text, text, text) to authenticated;
