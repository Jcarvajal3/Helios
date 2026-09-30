-- ============================================================================
-- Ronda — El acuse solo puede hablar de adelanto si de verdad lo hubo
--
-- La pantalla de "Tu pago está en revisión" daba las gracias **por adelantar**
-- a todo el mundo, pagara antes de tiempo, el mismo día del vencimiento o tres
-- días tarde. A quien pagó en fecha se le agradece algo que no hizo; a quien
-- pagó tarde, encima.
--
-- ---------------------------------------------------------------------------
-- Qué es un adelanto, y por qué lo tiene que decir el servidor
-- ---------------------------------------------------------------------------
-- La definición existe desde el 2026-08-25 y no cambia aquí: **una cuota
-- saldada antes del día operativo de su vencimiento** (20260825190000, la
-- cabecera de Bits). Pagar el 31 lo que vence el 31 no es adelanto; pagar el
-- 30, sí. Es `due_date > helios_business_date(...)`, con el `>` estricto.
--
-- El cliente no puede decidirlo por su cuenta sin arriesgarse a contradecir al
-- servidor, y aquí la contradicción se ve: quien premia el adelanto es el
-- trigger `installments_award_bits`, que lo mide contra
-- `payment_reports.created_at` —cuándo dijo el usuario que había pagado, no
-- cuándo lo aprobó el operador—. Así que **el acuse promete Bits exactamente
-- cuando el trigger los va a dar**: los dos leen la misma fecha y el mismo
-- `>`. Calcularlo en la app abriría la puerta a una pantalla que da las
-- gracias por un adelanto que luego no aparece en el saldo de Bits.
--
-- `early_count` y no un booleano: el usuario puede pagar dos cuotas de golpe y
-- adelantar solo una — la que vence hoy y la que vence a los siete días. El
-- acuse tiene que poder decir "una de las dos".
--
-- Cuerpo idéntico al de 20260825120000 salvo el bloque marcado NUEVO.
-- ============================================================================

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

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- Cuántas de las cuotas de este pago son ADELANTO. Se mide contra
  -- `v_row.created_at`, que es la misma fecha que leerá el trigger de Bits al
  -- conciliar: lo que promete el acuse es lo que se va a premiar.
  select count(*) into v_early
  from public.payment_quote_items qi
  join public.installments i on i.id = qi.installment_id
  where qi.quote_id = p_quote_id
    and i.due_date > public.helios_business_date(v_row.created_at);
  -- ─────────────────────────────────────────────────────────────────────────

  return jsonb_build_object(
    'report_id', v_row.id,
    'status', v_row.status,
    'amount_usd', v_quote.amount_usd,
    'amount_ves', v_quote.amount_ves,
    'installment_count', v_quote.installment_count,
    'reported_at', v_row.created_at,
    -- NUEVO
    'early_count', v_early
  );
end;
$$;

revoke all on function public.report_payment(uuid, text, text, text, text, text, text)
  from public, anon;
grant execute on function public.report_payment(uuid, text, text, text, text, text, text)
  to authenticated;

comment on function public.report_payment(uuid, text, text, text, text, text, text) is
  'Registra el reporte de una transferencia. Devuelve `early_count`: cuantas de las cuotas del pago son adelanto, con la misma regla y la misma fecha que usa el trigger de Bits.';
