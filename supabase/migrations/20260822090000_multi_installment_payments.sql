-- ============================================================================
-- Ronda — Pago de VARIAS cuotas con un solo reporte
--
-- El diseño de la pantalla "Pagos" (Figma 66:1127 y 68:1497) permite marcar
-- varias cuotas —incluso de órdenes distintas— y pagarlas con UNA sola
-- transferencia y UNA sola referencia. El modelo anterior
-- (20260822056000_payment_reports.sql) cotizaba y reportaba una cuota
-- suelta, así que no podía expresar eso.
--
-- Cambios:
--   * Una cotización agrupa N cuotas (`payment_quote_items`).
--   * El reporte cuelga de la cotización, no de una cuota.
--   * Se capturan los datos del pagador que pide el diseño: banco de origen,
--     cédula y teléfono.
--   * La cuenta destino deja de ser un texto en la pantalla y pasa a ser una
--     tabla que administra el super admin.
--
-- No hay datos en producción todavía, así que se reestructura en limpio en
-- vez de arrastrar columnas muertas.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Cuentas destino
-- ---------------------------------------------------------------------------
-- El diseño muestra Banco / RIF / Teléfono con un botón de copiar. Esos
-- valores NO se hardcodean: a qué cuenta paga el usuario es la decisión D-01
-- de docs/00-BASES §4.1, todavía sin cerrar. Modelarlo como tabla permite
-- construir la pantalla hoy y que el super admin ponga la cuenta real cuando
-- exista, sin tocar código ni publicar una versión nueva de la app.

create table if not exists public.payment_destinations (
  id           uuid primary key default gen_random_uuid(),
  bank_name    text not null,
  rif          text not null,
  phone        text not null,
  holder_name  text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);

comment on table public.payment_destinations is
  'Cuentas de Pago Móvil a las que reporta el usuario. Las crea el super admin.';

-- Una sola cuenta activa a la vez: si hubiera dos, la app tendría que elegir
-- y el usuario podría pagar a la vieja después de un cambio de banco.
create unique index payment_destinations_one_active
  on public.payment_destinations (is_active) where is_active;

alter table public.payment_destinations enable row level security;

create policy "payment_destinations_read_active"
  on public.payment_destinations for select to authenticated
  using (is_active);

grant select on public.payment_destinations to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Cotizaciones de varias cuotas
-- ---------------------------------------------------------------------------

drop function if exists public.quote_installment_payment(uuid);
drop function if exists public.report_installment_payment(uuid, text, text, text, text);

-- El reporte pasa a colgar de la cotización.
alter table public.payment_reports drop column if exists installment_id;
alter table public.payment_quotes  drop column if exists installment_id;

alter table public.payment_quotes
  add column if not exists installment_count smallint not null default 0;

create table if not exists public.payment_quote_items (
  quote_id       uuid not null references public.payment_quotes (id) on delete cascade,
  installment_id uuid not null references public.installments (id),
  amount_usd     numeric(18,4) not null check (amount_usd > 0),
  primary key (quote_id, installment_id)
);

create index payment_quote_items_installment_idx
  on public.payment_quote_items (installment_id);

alter table public.payment_quote_items enable row level security;

create policy "quote_items_read_own"
  on public.payment_quote_items for select to authenticated
  using (
    quote_id in (select id from public.payment_quotes where user_id = (select auth.uid()))
  );

grant select on public.payment_quote_items to authenticated;

-- Datos del pagador que pide el diseño (Figma 68:1497). Sin ellos, conciliar
-- a mano contra el estado de cuenta del banco es adivinar.
alter table public.payment_reports
  add column if not exists payer_document text,
  add column if not exists payer_phone    text,
  add column if not exists destination_id uuid references public.payment_destinations (id);

-- ---------------------------------------------------------------------------
-- 3. Cotizar un conjunto de cuotas
-- ---------------------------------------------------------------------------

create or replace function public.quote_installments(p_installment_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user       uuid := auth.uid();
  v_rate       numeric(18,6);
  v_total_usd  numeric(18,4);
  v_count      integer;
  v_quote      public.payment_quotes%rowtype;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if p_installment_ids is null or array_length(p_installment_ids, 1) is null then
    raise exception 'Selecciona al menos una cuota' using errcode = '22023';
  end if;

  -- Solo cuotas propias y pendientes. Si el cliente manda una ajena o ya
  -- pagada, no se cotiza a medias: se rechaza entero.
  select coalesce(sum(amount_usd), 0), count(*)
    into v_total_usd, v_count
  from public.installments
  where id = any(p_installment_ids)
    and user_id = v_user
    and status = 'pending';

  if v_count <> array_length(p_installment_ids, 1) then
    raise exception 'Alguna de las cuotas no es tuya o ya está pagada'
      using errcode = '22023';
  end if;

  v_rate := public.current_fx_rate();
  if v_rate is null then
    raise exception 'No hay tasa de cambio vigente' using errcode = 'P0002';
  end if;

  insert into public.payment_quotes
    (user_id, amount_usd, fx_rate, amount_ves, installment_count, valid_until)
  values (
    v_user,
    v_total_usd,
    v_rate,
    round(v_total_usd * v_rate, 2),
    v_count,
    -- Fin del día calendario en Caracas (docs/05 §1): el BCV publica una vez
    -- al día, así que una cotización de la tarde sigue viva esa noche.
    (date_trunc('day', now() at time zone 'America/Caracas') + interval '1 day')
      at time zone 'America/Caracas'
  )
  returning * into v_quote;

  insert into public.payment_quote_items (quote_id, installment_id, amount_usd)
  select v_quote.id, id, amount_usd
  from public.installments
  where id = any(p_installment_ids);

  return jsonb_build_object(
    'quote_id', v_quote.id,
    'amount_usd', v_quote.amount_usd,
    'fx_rate', v_quote.fx_rate,
    'amount_ves', v_quote.amount_ves,
    'installment_count', v_quote.installment_count,
    'valid_until', v_quote.valid_until,
    'destination', (
      select jsonb_build_object(
        'bank_name', bank_name, 'rif', rif, 'phone', phone, 'holder_name', holder_name
      )
      from public.payment_destinations where is_active limit 1
    )
  );
end;
$$;

revoke all on function public.quote_installments(uuid[]) from public, anon;
grant execute on function public.quote_installments(uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Reportar el pago
-- ---------------------------------------------------------------------------
-- ⚠️ Sobre la referencia: el diseño pide solo los ÚLTIMOS 6 DÍGITOS. Eso
-- debilita el control antifraude número uno de docs/01 §8, que asumía la
-- referencia completa. Con 6 dígitos hay un millón de valores posibles, así
-- que dos pagos legítimos distintos coinciden por puro azar mucho antes de
-- lo que parece (con ~1.200 pagos del mismo banco la probabilidad de al
-- menos una colisión pasa del 50%).
--
-- Por eso NO se rechaza un duplicado: se marca `in_review` para que lo mire
-- una persona. Rechazar en duro convertiría una coincidencia estadística en
-- un usuario legítimo que no puede pagar.

create or replace function public.report_payment(
  p_quote_id       uuid,
  p_method         text,
  p_bank           text,
  p_reference      text,
  p_payer_document text default null,
  p_payer_phone    text default null,
  p_receipt_path   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user      uuid := auth.uid();
  v_quote     public.payment_quotes%rowtype;
  v_dest      uuid;
  v_duplicate boolean;
  v_status    public.payment_report_status;
  v_row       public.payment_reports%rowtype;
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
    raise exception 'La referencia es obligatoria para %', p_method using errcode = '22023';
  end if;

  if exists (
    select 1 from public.payment_reports r
    join public.payment_quote_items i on i.quote_id = r.quote_id
    join public.payment_quote_items j on j.installment_id = i.installment_id
    where j.quote_id = p_quote_id and r.status in ('reported', 'in_review')
  ) then
    raise exception 'Ya hay un reporte pendiente para alguna de esas cuotas'
      using errcode = '22023';
  end if;

  select id into v_dest from public.payment_destinations where is_active limit 1;

  -- Coincidencia de referencia: sospechosa, no concluyente. Va a revisión.
  v_duplicate := p_reference is not null and exists (
    select 1 from public.payment_reports
    where bank = p_bank and reference = p_reference and status <> 'rejected'
  );

  v_status := case when v_duplicate then 'in_review' else 'reported' end;

  insert into public.payment_reports (
    quote_id, user_id, method, bank, reference,
    payer_document, payer_phone, destination_id, receipt_path, status,
    rejection_note
  )
  values (
    p_quote_id, v_user, p_method, p_bank, p_reference,
    p_payer_document, p_payer_phone, v_dest, p_receipt_path, v_status,
    case when v_duplicate
      then 'Referencia repetida: revisar contra el estado de cuenta antes de aprobar.'
      else null end
  )
  returning * into v_row;

  return jsonb_build_object(
    'report_id', v_row.id,
    'status', v_row.status,
    'amount_usd', v_quote.amount_usd,
    'amount_ves', v_quote.amount_ves,
    'installment_count', v_quote.installment_count
  );
end;
$$;

revoke all on function public.report_payment(uuid, text, text, text, text, text, text)
  from public, anon;
grant execute on function public.report_payment(uuid, text, text, text, text, text, text)
  to authenticated;

-- El índice único de (banco, referencia) se sustituye por uno NO único: con
-- 6 dígitos la coincidencia es esperable, y bloquearla en la base impediría
-- pagar a gente legítima. La detección vive ahora en report_payment, que
-- marca `in_review` en vez de rechazar.
drop index if exists public.payment_reports_reference_unique;
create index if not exists payment_reports_reference_idx
  on public.payment_reports (bank, reference) where reference is not null;
