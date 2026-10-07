-- ============================================================================
-- Helios — El paciente solo paga en bolívares, a la tasa de su moneda
-- (Javier, 2026-10-07)
--
-- 1. **Solo bolívares.** El paciente paga por Pago Móvil o transferencia, en
--    bolívares. Se retiran Zelle, USDT y efectivo de todo lo que es del
--    paciente: las cuentas de cobro (`admin_set_payment_destination` ya no
--    acepta Zelle y las de Zelle que hubiera se apagan), el texto con las
--    cuentas que va en los mensajes, y el registro de un pago
--    (`admin_register_payment`, `report_payment`). Los pagos de antes se
--    quedan como están: son historia. Lo que Helios le paga a la clínica no
--    cambia.
--
-- 2. **Cada cuota, a la tasa de su moneda.** Una cotización
--    (`helios_quote_installments`) pasa a bolívares lo que va en dólares (las
--    cuotas de órdenes en dólares y los cargos por atraso) con la tasa BCV del
--    dólar, y lo que va en euros con la del euro. Guarda las dos tasas y cada
--    cuota guarda su moneda y su monto en ella. `amount_usd` sigue siendo
--    dólares: lo que entra al libro.
--
-- 3. **Registrar un pago con fecha** vuelve a cotizar en bolívares con las
--    tasas de ESE día (`helios_reprice_quote`), como antes pero por moneda.
--
-- 4. **`admin_payment_preview`**: lo que debería decir el comprobante en
--    bolívares para unas cuotas y un día, sin crear nada. El panel lo usa en
--    vez de multiplicar a mano por una sola tasa.
--
-- 5. Los permisos de los ayudantes nuevos de las dos migraciones anteriores.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columnas de la cotización
-- ---------------------------------------------------------------------------

alter table public.payment_quotes
  add column if not exists fx_rate_eur numeric(18,6),
  add column if not exists amount_eur  numeric(18,4);

comment on column public.payment_quotes.amount_eur is
  'La parte de la cotización que va en euros (cuotas de órdenes en euros), en euros. Se pasa a bolívares con `fx_rate_eur`; el resto (dólares y cargos por atraso), con `fx_rate`.';

alter table public.payment_quote_items
  add column if not exists currency   text not null default 'USD',
  add column if not exists amount_cur numeric(18,4);

update public.payment_quote_items set amount_cur = amount_usd where amount_cur is null;

-- ---------------------------------------------------------------------------
-- 2. Los bolívares de una cotización
-- ---------------------------------------------------------------------------

/**
 * Bolívares de una parte en dólares y otra en euros, cada una con la tasa BCV
 * de su moneda vigente ese día. Sin la tasa que hace falta, error.
 */
create or replace function public.helios_bolivares(p_usd numeric, p_eur numeric, p_as_of date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_usd numeric := public.current_fx_rate('BCV', p_as_of);
  v_eur numeric;
begin
  if v_usd is null then
    raise exception 'No hay tasa de cambio vigente' using errcode = 'P0002';
  end if;

  if coalesce(p_eur, 0) > 0 then
    v_eur := public.current_fx_rate('BCV_EUR', p_as_of);
    if v_eur is null then
      raise exception 'No hay tasa BCV del euro vigente' using errcode = 'P0002';
    end if;
  end if;

  return jsonb_build_object(
    'fx_rate', v_usd,
    'fx_rate_eur', v_eur,
    'amount_ves', round(coalesce(p_usd, 0) * v_usd, 2) + coalesce(round(coalesce(p_eur, 0) * v_eur, 2), 0)
  );
end;
$$;

revoke all on function public.helios_bolivares(numeric, numeric, date) from public, anon, authenticated;

/**
 * Vuelve a pasar una cotización a bolívares con las tasas de un día: el del
 * pago, que es la que usó el paciente.
 */
create or replace function public.helios_reprice_quote(p_quote_id uuid, p_as_of date)
returns public.payment_quotes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_q   public.payment_quotes%rowtype;
  v_eur numeric(18,4);
  v_bs  jsonb;
begin
  select * into v_q from public.payment_quotes where id = p_quote_id for update;
  if not found then
    raise exception 'Cotización no encontrada' using errcode = 'P0002';
  end if;

  v_eur := coalesce(v_q.amount_eur, 0);

  begin
    v_bs := public.helios_bolivares(v_q.amount_usd - coalesce((
              select sum(qi.amount_usd) from public.payment_quote_items qi
              where qi.quote_id = v_q.id and qi.currency = 'EUR'), 0),
            v_eur, p_as_of);
  exception when sqlstate 'P0002' then
    -- Sin tasa de ese día se queda la de la cotización.
    return v_q;
  end;

  update public.payment_quotes
     set fx_rate = (v_bs->>'fx_rate')::numeric,
         fx_rate_eur = (v_bs->>'fx_rate_eur')::numeric,
         amount_ves = (v_bs->>'amount_ves')::numeric
   where id = v_q.id
  returning * into v_q;

  return v_q;
end;
$$;

revoke all on function public.helios_reprice_quote(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. La cotización: cada cuota a la tasa de su moneda
-- ---------------------------------------------------------------------------

create or replace function public.helios_quote_installments(
  p_user               uuid,
  p_installment_ids    uuid[],
  p_ignore_open_report boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user       uuid := p_user;
  v_bd         date := public.helios_business_date(now());
  v_left       integer;
  v_total_usd  numeric(18,4);
  v_count      integer;
  v_eur        numeric(18,4);
  v_eur_usd    numeric(18,4);
  v_fee_ids    uuid[];
  v_fee_usd    numeric(18,4) := 0;
  v_grand_usd  numeric(18,4);
  v_bs         jsonb;
  v_quote      public.payment_quotes%rowtype;
begin
  if v_user is null then
    raise exception 'Falta de quién es el pago' using errcode = '22023';
  end if;

  if p_installment_ids is null or array_length(p_installment_ids, 1) is null then
    raise exception 'Selecciona al menos una cuota' using errcode = '22023';
  end if;

  -- Solo cuotas propias y pendientes. Si el cliente manda una ajena o ya
  -- pagada, no se cotiza a medias: se rechaza entero. Lo que va en euros, a
  -- un lado: se pasa a bolívares con la tasa del euro.
  select coalesce(sum(i.amount_usd), 0), count(*),
         coalesce(sum(coalesce(i.amount_cur, i.amount_usd)) filter (where c.currency = 'EUR'), 0),
         coalesce(sum(i.amount_usd) filter (where c.currency = 'EUR'), 0)
    into v_total_usd, v_count, v_eur, v_eur_usd
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where i.id = any(p_installment_ids)
    and i.user_id = v_user
    and i.status = 'pending';

  if v_count <> array_length(p_installment_ids, 1) then
    raise exception 'Alguna de las cuotas no es tuya o ya está pagada'
      using errcode = '22023';
  end if;

  -- Cuota con un pago ya reportado y sin conciliar.
  if not p_ignore_open_report and exists (
    select 1
    from public.payment_quote_items i
    join public.payment_reports r on r.quote_id = i.quote_id
    where i.installment_id = any(p_installment_ids)
      and r.user_id = v_user
      and r.status in ('reported', 'in_review')
  ) then
    raise exception
      'Ya reportaste un pago para alguna de esas cuotas y está en revisión. Te avisamos en cuanto lo confirmemos.'
      using errcode = '22023';
  end if;

  -- Lo que vence hoy o antes va primero.
  if exists (
    select 1 from public.installments
    where id = any(p_installment_ids) and due_date > v_bd
  ) then
    select count(*) into v_left
    from public.installments i
    where i.user_id = v_user
      and i.status = 'pending'
      and i.due_date <= v_bd
      and not (i.id = any(p_installment_ids))
      and not exists (
        select 1
        from public.payment_quote_items qi
        join public.payment_reports r on r.quote_id = qi.quote_id
        where qi.installment_id = i.id
          and r.status in ('reported', 'in_review')
      );

    if v_left > 0 then
      if p_ignore_open_report then
        raise exception
          'Esta persona tiene % cuota(s) que vencen hoy o antes y no están en la selección: para adelantar una cuota hay que incluirlas.',
          v_left using errcode = '22023';
      end if;

      raise exception
        'Tienes una cuota que vence hoy o antes. Inclúyela en este pago para poder adelantar las siguientes.'
        using errcode = '22023';
    end if;
  end if;

  -- Los cargos de las cuotas elegidas, más los huérfanos. En dólares.
  select coalesce(array_agg(f.id), '{}'::uuid[]), coalesce(sum(f.amount_usd), 0)
    into v_fee_ids, v_fee_usd
  from public.late_fees f
  left join public.installments i on i.id = f.installment_id
  where f.user_id = v_user
    and f.status = 'pending'
    and (
      f.installment_id = any(p_installment_ids)
      or f.installment_id is null
      or i.status <> 'pending'
    );

  v_grand_usd := v_total_usd + v_fee_usd;

  -- A bolívares: lo de dólares a la tasa del dólar, lo de euros a la del euro.
  v_bs := public.helios_bolivares(v_grand_usd - v_eur_usd, v_eur, v_bd);

  insert into public.payment_quotes
    (user_id, amount_usd, fx_rate, amount_ves, installment_count, valid_until,
     late_fee_usd, fx_rate_eur, amount_eur)
  values (
    v_user,
    v_grand_usd,
    (v_bs->>'fx_rate')::numeric,
    (v_bs->>'amount_ves')::numeric,
    v_count,
    -- Fin del día calendario en Caracas: el BCV publica una vez al día.
    (date_trunc('day', now() at time zone 'America/Caracas') + interval '1 day')
      at time zone 'America/Caracas',
    v_fee_usd,
    (v_bs->>'fx_rate_eur')::numeric,
    nullif(v_eur, 0)
  )
  returning * into v_quote;

  insert into public.payment_quote_items (quote_id, installment_id, amount_usd, currency, amount_cur)
  select v_quote.id, i.id, i.amount_usd, c.currency, coalesce(i.amount_cur, i.amount_usd)
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where i.id = any(p_installment_ids);

  -- El detalle de los cargos, con su importe congelado.
  insert into public.payment_quote_late_fees (quote_id, late_fee_id, amount_usd)
  select v_quote.id, f.id, f.amount_usd
  from public.late_fees f
  where f.id = any(v_fee_ids);

  return jsonb_build_object(
    'quote_id', v_quote.id,
    'amount_usd', v_quote.amount_usd,
    'fx_rate', v_quote.fx_rate,
    'fx_rate_eur', v_quote.fx_rate_eur,
    'amount_eur', v_quote.amount_eur,
    'amount_ves', v_quote.amount_ves,
    'installment_count', v_quote.installment_count,
    'installments_usd', v_total_usd,
    'late_fee_usd', v_quote.late_fee_usd,
    'late_fee_count', coalesce(array_length(v_fee_ids, 1), 0),
    'valid_until', v_quote.valid_until,
    'destination', (
      select jsonb_build_object(
        'bank_name', bank_name, 'rif', rif, 'phone', phone, 'holder_name', holder_name
      )
      from public.payment_destinations
      where is_active and method in ('pago_movil', 'transferencia')
      -- Helios (H11): puede haber varias activas; va la primera por orden.
      order by sort_order, created_at limit 1
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Lo que debería decir el comprobante, sin crear nada
-- ---------------------------------------------------------------------------

/**
 * Para el formulario de «Registrar pago»: lo que suman en dólares unas cuotas
 * del paciente (y los cargos por atraso que viajarían con ellas) y lo que son
 * en bolívares el día del pago, cada parte con la tasa de su moneda. No crea
 * cotización ni comprueba el orden de las cuotas: eso lo hace el registro.
 */
create or replace function public.admin_payment_preview(
  p_user            uuid,
  p_installment_ids uuid[],
  p_paid_on         date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_day     date := coalesce(p_paid_on, public.helios_business_date(now()));
  v_usd     numeric(18,4);
  v_eur     numeric(18,4);
  v_eur_usd numeric(18,4);
  v_fee     numeric(18,4);
  v_bs      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(sum(i.amount_usd), 0),
         coalesce(sum(coalesce(i.amount_cur, i.amount_usd)) filter (where c.currency = 'EUR'), 0),
         coalesce(sum(i.amount_usd) filter (where c.currency = 'EUR'), 0)
    into v_usd, v_eur, v_eur_usd
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where i.id = any(coalesce(p_installment_ids, '{}'::uuid[]))
    and i.user_id = p_user
    and i.status = 'pending';

  select coalesce(sum(f.amount_usd), 0) into v_fee
  from public.late_fees f
  left join public.installments i on i.id = f.installment_id
  where f.user_id = p_user
    and f.status = 'pending'
    and (
      f.installment_id = any(coalesce(p_installment_ids, '{}'::uuid[]))
      or f.installment_id is null
      or i.status <> 'pending'
    );

  begin
    v_bs := public.helios_bolivares(v_usd + v_fee - v_eur_usd, v_eur, v_day);
  exception when sqlstate 'P0002' then
    v_bs := jsonb_build_object('fx_rate', public.current_fx_rate('BCV', v_day),
                               'fx_rate_eur', public.current_fx_rate('BCV_EUR', v_day),
                               'amount_ves', null);
  end;

  return jsonb_build_object(
    'paid_on', v_day,
    'installments_usd', v_usd,
    'late_fee_usd', v_fee,
    'amount_usd', v_usd + v_fee,
    -- Lo que va en euros (en euros) y lo que va en dólares (en dólares).
    'amount_eur', v_eur,
    'amount_usd_part', v_usd + v_fee - v_eur_usd,
    'fx_rate', (v_bs->>'fx_rate')::numeric,
    'fx_rate_eur', (v_bs->>'fx_rate_eur')::numeric,
    'amount_ves', (v_bs->>'amount_ves')::numeric
  );
end;
$$;

revoke all on function public.admin_payment_preview(uuid, uuid[], date) from public, anon;
grant execute on function public.admin_payment_preview(uuid, uuid[], date) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Registrar un pago: solo en bolívares y a las tasas del día del pago
-- ---------------------------------------------------------------------------

create or replace function public.admin_register_payment(
  p_user            uuid,
  p_installment_ids uuid[],
  p_method          text,
  p_bank            text,
  p_reference       text,
  p_paid_on         date,
  p_amount_ves      numeric,
  p_receipt_path    text,
  p_note            text
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_today  date := public.helios_business_date(now());
  v_method text := lower(btrim(coalesce(p_method, '')));
  v_bank   text := nullif(btrim(coalesce(p_bank, '')), '');
  v_ref    text := nullif(btrim(coalesce(p_reference, '')), '');
  v_path   text := nullif(btrim(coalesce(p_receipt_path, '')), '');
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_quote  jsonb;
  v_q      public.payment_quotes%rowtype;
  v_dup    boolean;
  v_dest   uuid;
  v_status public.payment_report_status;
  v_row    public.payment_reports%rowtype;
  v_cands  integer;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- El paciente solo paga en bolívares (2026-10-07).
  if v_method not in ('pago_movil', 'transferencia') then
    raise exception 'El paciente solo paga en bolívares: Pago Móvil o transferencia'
      using errcode = '22023';
  end if;

  if v_ref is null then
    raise exception 'La referencia es obligatoria para %', replace(v_method, '_', ' ')
      using errcode = '22023';
  end if;

  if v_bank is null then
    raise exception 'Falta el banco del pago' using errcode = '22023';
  end if;

  if p_paid_on is null then
    raise exception 'Falta la fecha del pago' using errcode = '22023';
  end if;
  if p_paid_on > v_today then
    raise exception 'La fecha del pago no puede ser posterior a hoy' using errcode = '22023';
  end if;
  if p_paid_on < v_today - 120 then
    raise exception 'La fecha del pago es de hace más de 120 días: revísala' using errcode = '22023';
  end if;

  if p_amount_ves is null then
    raise exception 'Falta el monto en bolívares que dice el comprobante' using errcode = '22023';
  end if;
  if p_amount_ves <= 0 then
    raise exception 'El monto en bolívares tiene que ser mayor que cero' using errcode = '22023';
  end if;
  if p_amount_ves <> round(p_amount_ves, 2) then
    raise exception 'El monto en bolívares admite como mucho 2 decimales' using errcode = '22023';
  end if;

  if v_path is not null and (v_path like '/%' or v_path like '%..%' or length(v_path) > 500) then
    raise exception 'Ruta de la captura no válida' using errcode = '22023';
  end if;

  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'Paciente no encontrado' using errcode = 'P0002';
  end if;

  -- La red de «ya hay un pago abierto» se revisa aquí, con palabras del
  -- equipo; la cotización se pide sin ella.
  if exists (
    select 1
    from public.payment_quote_items i
    join public.payment_reports r on r.quote_id = i.quote_id
    where i.installment_id = any(coalesce(p_installment_ids, '{}'::uuid[]))
      and r.status in ('reported', 'in_review')
  ) then
    raise exception 'Alguna de esas cuotas ya tiene un pago registrado esperando aprobación'
      using errcode = '22023';
  end if;

  v_quote := public.helios_quote_installments(p_user, p_installment_ids, true);

  -- En bolívares a las tasas del día del pago, que son las que usó el
  -- paciente: cada parte con la de su moneda.
  v_q := public.helios_reprice_quote((v_quote ->> 'quote_id')::uuid, p_paid_on);

  -- Coincidencia de referencia: sospechosa, no concluyente. Va a revisión.
  v_dup := exists (
    select 1 from public.payment_reports
    where reference = v_ref
      and coalesce(bank, '') = coalesce(v_bank, '')
      and status <> 'rejected'
  );
  v_status := case when v_dup then 'in_review' else 'reported' end;

  select id into v_dest
  from public.payment_destinations
  where is_active and method = v_method
  order by sort_order, created_at
  limit 1;

  insert into public.payment_reports (
    quote_id, user_id, method, bank, reference, receipt_path, status, rejection_note,
    destination_id, registered_by, paid_on, declared_amount_ves, note
  ) values (
    v_q.id, p_user, v_method, v_bank, v_ref, v_path, v_status,
    case when v_dup then 'Referencia repetida: revisar contra el estado de cuenta antes de aprobar.' end,
    v_dest, v_actor, p_paid_on, p_amount_ves, v_note
  )
  returning * into v_row;

  select count(*)::integer into v_cands
  from public.helios_statement_candidates(v_row.id) c
  where c.used_by_report_id is null and not c.discarded;

  perform audit.log(v_actor, 'payment.registered', v_row.id, jsonb_build_object(
    'user_id', p_user,
    'quote_id', v_q.id,
    'installments', to_jsonb(p_installment_ids),
    'method', v_method, 'bank', v_bank, 'reference', v_ref,
    'paid_on', p_paid_on,
    'declared_amount_ves', p_amount_ves,
    'amount_usd', v_q.amount_usd, 'amount_ves', v_q.amount_ves, 'fx_rate', v_q.fx_rate,
    'amount_eur', v_q.amount_eur, 'fx_rate_eur', v_q.fx_rate_eur,
    'receipt_path', v_path,
    'status', v_status,
    'note', v_note
  ));

  return jsonb_build_object(
    'report_id', v_row.id,
    'quote_id', v_q.id,
    'amount_usd', v_q.amount_usd,
    'late_fee_usd', v_q.late_fee_usd,
    'installments_usd', v_q.amount_usd - v_q.late_fee_usd,
    'installment_count', v_q.installment_count,
    'fx_rate', v_q.fx_rate,
    'fx_rate_eur', v_q.fx_rate_eur,
    'amount_eur', v_q.amount_eur,
    'amount_ves', v_q.amount_ves,
    'declared_amount_ves', p_amount_ves,
    'diferencia_ves', round(p_amount_ves - v_q.amount_ves, 2),
    'status', v_row.status,
    'candidatos_extracto', v_cands
  );
end;
$$;

-- El reporte desde la app (heredado de Ronda): las mismas dos vías.
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
  v_early     integer;
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

  if coalesce(p_method, '') not in ('pago_movil', 'transferencia') then
    raise exception 'Se paga en bolívares: Pago Móvil o transferencia' using errcode = '22023';
  end if;

  if p_reference is null or length(trim(p_reference)) = 0 then
    raise exception 'La referencia es obligatoria para %', p_method using errcode = '22023';
  end if;

  if exists (
    select 1 from public.payment_reports r
    join public.payment_quote_items i on i.quote_id = r.quote_id
    join public.payment_quote_items j on j.installment_id = i.installment_id
    where j.quote_id = p_quote_id and r.status in ('reported', 'in_review')
  ) then
    raise exception
      'Ya reportaste un pago para alguna de esas cuotas y está en revisión. Te avisamos en cuanto lo confirmemos.'
      using errcode = '22023';
  end if;

  -- Helios (H11): puede haber varias activas; va la primera de ese método.
  select id into v_dest from public.payment_destinations
  where is_active and method = p_method
  order by sort_order, created_at limit 1;

  v_duplicate := exists (
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

  select
    count(*) filter (where i.due_date > public.helios_business_date(v_row.created_at))
  into v_early
  from public.payment_quote_items qi
  join public.installments i on i.id = qi.installment_id
  where qi.quote_id = p_quote_id;

  return jsonb_build_object(
    'report_id', v_row.id,
    'status', v_row.status,
    'amount_usd', v_quote.amount_usd,
    'amount_ves', v_quote.amount_ves,
    'installment_count', v_quote.installment_count,
    'reported_at', v_row.created_at,
    'early_count', v_early,
    'bits_pending', 0
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Las cuentas de cobro: Pago Móvil y transferencia
-- ---------------------------------------------------------------------------

update public.payment_destinations
set is_active = false, updated_at = now()
where method not in ('pago_movil', 'transferencia') and is_active;

create or replace function public.admin_set_payment_destination(
  p_bank_name      text,
  p_rif            text,
  p_phone          text,
  p_holder_name    text default null,
  p_note           text default null,
  p_sort_order     integer default null,
  p_is_active      boolean default true,
  p_id             uuid default null,
  p_method         text default 'pago_movil',
  p_account_number text default null,
  p_email          text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor   uuid := auth.uid();
  v_id      uuid;
  v_method  text := coalesce(nullif(btrim(p_method), ''), 'pago_movil');
  v_bank    text := nullif(btrim(coalesce(p_bank_name, '')), '');
  v_rif     text := nullif(btrim(coalesce(p_rif, '')), '');
  v_phone   text := nullif(btrim(coalesce(p_phone, '')), '');
  v_holder  text := nullif(btrim(coalesce(p_holder_name, '')), '');
  v_account text := nullif(regexp_replace(coalesce(p_account_number, ''), '\D', '', 'g'), '');
begin
  perform public.helios_assert_super_admin('cambiar las cuentas de cobro');

  -- El paciente solo paga en bolívares (2026-10-07): Zelle ya no.
  if v_method not in ('pago_movil', 'transferencia') then
    raise exception 'El paciente solo paga en bolívares: la cuenta es de Pago Móvil o de transferencia'
      using errcode = '22023';
  end if;

  if v_method = 'pago_movil' and (v_bank is null or v_rif is null or v_phone is null) then
    raise exception 'Banco, RIF y teléfono son obligatorios' using errcode = '22023';
  end if;

  if v_method = 'transferencia'
     and (v_bank is null or v_rif is null or v_account is null or v_holder is null) then
    raise exception 'Banco, RIF, número de cuenta y titular son obligatorios' using errcode = '22023';
  end if;

  if v_method = 'transferencia' and v_account !~ '^[0-9]{20}$' then
    raise exception 'El número de cuenta tiene 20 dígitos' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.payment_destinations
      (method, bank_name, rif, phone, holder_name, account_number, email, is_active, sort_order)
    values (v_method, v_bank, v_rif, v_phone, v_holder, v_account, null,
            coalesce(p_is_active, true), coalesce(p_sort_order, 100))
    returning id into v_id;
  else
    update public.payment_destinations
       set method         = v_method,
           bank_name      = v_bank,
           rif            = v_rif,
           phone          = v_phone,
           holder_name    = v_holder,
           account_number = v_account,
           email          = null,
           is_active      = coalesce(p_is_active, is_active),
           sort_order     = coalesce(p_sort_order, sort_order),
           updated_at     = now()
     where id = p_id
    returning id into v_id;

    if v_id is null then
      raise exception 'Cuenta de cobro no encontrada' using errcode = 'P0002';
    end if;
  end if;

  perform audit.log(v_actor, 'payment_destination.set', v_id, jsonb_build_object(
    'method', v_method, 'bank_name', v_bank, 'rif', v_rif, 'phone', v_phone,
    'holder_name', v_holder, 'account_number', v_account,
    'is_active', coalesce(p_is_active, true), 'sort_order', p_sort_order,
    'edit', p_id is not null, 'note', nullif(trim(p_note), '')
  ));

  return v_id;
end;
$$;

-- El texto con las cuentas que llevan los mensajes: solo las de bolívares.
create or replace function public.helios_payment_accounts_text()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    string_agg(
      case d.method
        when 'pago_movil' then
          format('• Pago Móvil: %s · %s · %s%s', d.bank_name, d.rif,
                 coalesce(public.helios_format_ve_phone(d.phone), d.phone),
                 coalesce(' · ' || d.holder_name, ''))
        when 'transferencia' then
          format('• Transferencia: %s · Cuenta %s · %s · %s', d.bank_name, d.account_number,
                 d.holder_name, d.rif)
      end,
      E'\n' order by d.sort_order, d.created_at),
    'Helios te escribirá por WhatsApp con las instrucciones de pago.')
  from public.payment_destinations d
  where d.is_active and d.method in ('pago_movil', 'transferencia');
$$;

-- ---------------------------------------------------------------------------
-- 7. Permisos de los ayudantes nuevos (20261007000100 y 000200)
-- ---------------------------------------------------------------------------

revoke all on function public.helios_charge_amounts(numeric, text, numeric, numeric) from public, anon, authenticated;
revoke all on function public.helios_charge_currency(text) from public, anon, authenticated;
revoke all on function public.helios_installment_currency() from public, anon, authenticated;
revoke all on function public.helios_settlement_currency() from public, anon, authenticated;
revoke all on function public.helios_fx_series(text) from public, anon, authenticated;
revoke all on function public.helios_currency_symbol(text) from public, anon, authenticated;
revoke all on function public.helios_money_cur_text(numeric, text) from public, anon, authenticated;
revoke all on function public.helios_ves_text(numeric) from public, anon, authenticated;
