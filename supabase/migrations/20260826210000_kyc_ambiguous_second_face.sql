-- ============================================================================
-- Ronda — Una segunda cara ambigua no aprueba sola
--
-- El servicio ya distingue tres tamaños de cara secundaria: comparable al
-- sujeto (rechazo, hay dos personas o una foto sostenida), fondo (se ignora,
-- es un transeúnte) y una banda intermedia que no es ninguna de las dos.
--
-- Esa banda es el tamaño típico del atacante que sostiene la foto de la
-- víctima delante de la cámara: la foto es la cara mayor —el "sujeto"— y la
-- suya queda detrás, sobre el 30-40% del área. Rechazar por eso sería excesivo
-- (una persona sentada al fondo cae ahí), pero ignorarlo deja el ataque sin
-- más defensa que el liveness.
--
-- Así que se combina con él: la señal por sí sola no hace nada, y solo bloquea
-- la aprobación automática cuando ADEMÁS el liveness no va sobrado. Dos
-- señales flojas que se apoyan valen más que cualquiera de las dos sola, y
-- ninguna rechaza a nadie: lo peor que pasa es que lo mire una persona.
--
-- El umbral de 0.70 es deliberadamente más alto que el 0.50 que rechaza: aquí
-- no se pide "parece vivo", se pide "está fuera de toda duda".
-- ============================================================================

create or replace function kyc.record_decision(
  p_verification_id  uuid,
  p_face_match_score numeric default null,
  p_liveness_score   numeric default null,
  p_ocr_confidence   numeric default null,
  p_registry_matched boolean default null,
  p_extracted_name   text default null,
  p_extracted_doc    text default null,
  p_extracted_birth  date default null,
  p_hard_failure     kyc.rejection_reason default null,
  p_extracted_first  text default null,
  p_extracted_last   text default null,
  p_signals          jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $$
declare
  v_row       kyc.verifications%rowtype;
  v_status    kyc.verification_status;
  v_reason    kyc.rejection_reason;
  v_birth     date;
  v_age       int;
  v_document  text;
  v_note      text;
  v_ambiguous boolean;
begin
  select * into v_row from kyc.verifications
  where id = p_verification_id for update;

  if not found then
    raise exception 'Verificación no encontrada' using errcode = 'P0002';
  end if;

  update kyc.verifications
    set face_match_score     = coalesce(p_face_match_score, face_match_score),
        liveness_score       = coalesce(p_liveness_score, liveness_score),
        ocr_confidence       = coalesce(p_ocr_confidence, ocr_confidence),
        registry_matched     = coalesce(p_registry_matched, registry_matched),
        extracted_name       = coalesce(p_extracted_name, extracted_name),
        extracted_first_name = coalesce(p_extracted_first, extracted_first_name),
        extracted_last_name  = coalesce(p_extracted_last, extracted_last_name),
        extracted_document   = coalesce(p_extracted_doc, extracted_document),
        extracted_birth      = coalesce(p_extracted_birth, extracted_birth),
        updated_at           = now()
  where id = p_verification_id;

  v_birth := coalesce(p_extracted_birth, v_row.extracted_birth);
  v_age := case
    when v_birth is null then null
    else extract(year from age(current_date, v_birth))::int
  end;

  v_document := nullif(btrim(coalesce(p_extracted_doc, v_row.extracted_document, '')), '');

  -- La señal viaja en el jsonb de diagnóstico que ya manda el pipeline.
  v_ambiguous := coalesce((p_signals ->> 'ambiguous_second_face')::boolean, false);

  -- Umbrales. Ver docs/02-KYC-PROPIO.md §3: hay que recalibrarlos con datos
  -- reales, los de aquí son el punto de partida.
  if p_hard_failure = 'duplicate_identity' then
    v_status := 'manual_review';
    v_note := 'Esta cara se parece a la de otra cuenta ya verificada. '
              || 'Compara las dos cédulas antes de decidir.';

  elsif p_hard_failure is not null then
    v_status := 'rejected';
    v_reason := p_hard_failure;

  elsif v_age is not null and v_age < 18 then
    v_status := 'manual_review';
    v_note := format('El OCR leyó una edad de %s años', v_age);

  elsif p_liveness_score is not null and p_liveness_score < 0.50 then
    v_status := 'rejected';
    v_reason := 'liveness_failed';

  elsif p_face_match_score is null then
    v_status := 'manual_review';

  elsif p_face_match_score < 0.30 then
    v_status := 'rejected';
    v_reason := 'face_mismatch';

  elsif p_face_match_score > 0.92 then
    -- Demasiado bueno para venir de dos capturas distintas.
    v_status := 'manual_review';
    v_note := format(
      'Cotejo de %s: las dos capturas parecen salir de la misma imagen. '
      || 'Comprueba que la selfie sea una persona y no una foto del documento.',
      round(p_face_match_score, 4)
    );

  elsif v_ambiguous and coalesce(p_liveness_score, 0) < 0.70 then
    v_status := 'manual_review';
    v_note := 'Hay otra cara en la selfie y la señal de vida no va sobrada. '
              || 'Comprueba que la persona esté delante de la cámara y no sea '
              || 'una foto sostenida.';

  elsif p_face_match_score >= 0.45
        and coalesce(p_registry_matched, true)
        and p_liveness_score is not null
        and v_document is not null
        and coalesce(p_ocr_confidence, 0) >= 0.50 then
    v_status := 'approved';

  else
    -- Zona gris, o le falta alguna de las condiciones de arriba: la mira una
    -- persona. Dejar dicho qué faltó ahorra que el revisor lo deduzca.
    v_status := 'manual_review';

    if v_document is null then
      v_note := 'El OCR no leyó el número de cédula.';
    elsif coalesce(p_ocr_confidence, 0) < 0.50 then
      v_note := format('Lectura de la cédula poco fiable (%s).', round(coalesce(p_ocr_confidence, 0), 2));
    elsif p_liveness_score is null then
      v_note := 'La verificación llegó sin señal de vida.';
    elsif not coalesce(p_registry_matched, true) then
      v_note := 'Los datos no cuadraron con el registro civil.';
    end if;
  end if;

  if v_note is not null then
    update kyc.verifications
      set rejection_detail = v_note
    where id = p_verification_id;
  end if;

  return kyc.apply_status(
    p_verification_id,
    v_status,
    v_reason,
    'system',
    coalesce(p_signals, '{}'::jsonb) || jsonb_build_object(
      'face_match_score', p_face_match_score,
      'liveness_score', p_liveness_score,
      'ocr_confidence', p_ocr_confidence,
      'registry_matched', p_registry_matched,
      'ocr_age', v_age,
      'review_note', v_note
    )
  );
end;
$$;

revoke all on function kyc.record_decision(
  uuid, numeric, numeric, numeric, boolean, text, text, date,
  kyc.rejection_reason, text, text, jsonb
) from public, anon, authenticated;
