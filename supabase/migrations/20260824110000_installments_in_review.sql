-- ============================================================================
-- Ronda — Cuotas con un pago ya reportado ("en revisión")
--
-- Reportar un pago NO salda la cuota: la conciliación se hace a mano contra el
-- estado de cuenta del banco (docs/00-BASES §3.7), así que la cuota se queda
-- en `pending` durante horas o días. La app no tenía forma de saber eso, y de
-- ahí salía el fallo que se ve desde el teléfono:
--
--   1. El usuario reporta un pago. Todo bien, "Tu pago está en revisión".
--   2. Vuelve a Cuotas y las mismas cuotas siguen ahí, seleccionables, y
--      "Pagar todo" las incluye.
--   3. Cotiza, TRANSFIERE EL DINERO, rellena banco, cédula, teléfono y
--      referencia, y pulsa "Reportar pago".
--   4. Solo entonces el servidor contesta "Ya hay un reporte pendiente para
--      alguna de esas cuotas", y la pantalla dice "No pudimos registrar tu
--      pago".
--
-- La comprobación era correcta; el sitio era el peor posible: después de mover
-- el dinero, y sin haber avisado en ningún momento de que ya había un pago en
-- camino. Este archivo la adelanta al principio del flujo y le da a la app el
-- dato que le faltaba:
--
--   * `quote_installments` rechaza en la COTIZACIÓN una cuota con reporte
--     abierto — antes de que nadie transfiera nada.
--   * `my_installments_in_review()` dice qué cuotas tienen un pago esperando
--     revisión, para que la lista de Cuotas las marque y no deje re-pagarlas.
--
-- El guardia de `report_payment` se queda donde está: es el que cierra la
-- carrera de dos envíos a la vez (va con `for update` sobre la cotización).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Qué cuotas tienen un pago esperando revisión
-- ---------------------------------------------------------------------------
-- Un reporte cuelga de la cotización y la cotización agrupa N cuotas, así que
-- "esta cuota está en revisión" es una pregunta de dos saltos. La app no debe
-- reconstruirla a mano: si la definición de "abierto" cambia (hoy `reported` e
-- `in_review`), tiene que cambiar en un solo sitio — este.
--
-- Se devuelve el reporte MÁS RECIENTE por cuota. En la práctica solo hay uno
-- abierto a la vez, pero `distinct on` evita duplicar la fila si algún día
-- llegaran a convivir dos.

create or replace function public.my_installments_in_review()
returns table (
  installment_id uuid,
  report_id      uuid,
  status         text,
  reported_at    timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select distinct on (i.installment_id)
         i.installment_id,
         r.id,
         r.status::text,
         r.created_at
  from public.payment_reports r
  join public.payment_quote_items i on i.quote_id = r.quote_id
  where r.user_id = (select auth.uid())
    and r.status in ('reported', 'in_review')
  order by i.installment_id, r.created_at desc
$fn$;

comment on function public.my_installments_in_review() is
  'Cuotas del usuario con un pago reportado pendiente de conciliar. La app las marca "En revisión" y no deja volver a pagarlas.';

revoke all on function public.my_installments_in_review() from public, anon;
grant execute on function public.my_installments_in_review() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Cotizar deja de aceptar cuotas ya reportadas
-- ---------------------------------------------------------------------------
-- Único cambio respecto a 20260822090000: el bloque nuevo marcado abajo. El
-- resto va igual, reescrito entero porque `create or replace` sustituye el
-- cuerpo completo.

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

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- Cuota con un pago ya reportado y sin conciliar. Se corta AQUÍ, en la
  -- cotización, y no al reportar: entre una cosa y la otra el usuario hace la
  -- transferencia, y negarle el reporte con el dinero ya enviado es el peor
  -- momento posible para decirle que no hacía falta pagar.
  if exists (
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
  -- ─────────────────────────────────────────────────────────────────────────

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
-- 3. El guardia de `report_payment`, dicho en cristiano
-- ---------------------------------------------------------------------------
-- Con lo de arriba, llegar hasta aquí ya solo pasa en una carrera: dos envíos
-- a la vez, o dos teléfonos. Aun así el texto se ve tal cual en la pantalla,
-- así que dice qué pasó y qué esperar, no la mecánica interna. Cuerpo idéntico
-- al de 20260822090000 salvo ese mensaje.

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
    raise exception
      'Ya reportaste un pago para alguna de esas cuotas y está en revisión. Te avisamos en cuanto lo confirmemos.'
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
