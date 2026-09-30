-- ============================================================================
-- Ronda — Cerrar los caminos de aprobación sin identidad
--
-- Auditoría del 26-08-2026. Tres agujeros encadenados permitían terminar con
-- una cuenta activa sin haber mostrado nunca una cédula:
--
--   1. `submit_kyc_verification` solo comprobaba el PREFIJO de las rutas, así
--      que el mismo archivo podía declararse como documento y como selfie.
--   2. La compuerta del documento solo exige que haya "un rostro" — y una
--      selfie lo tiene.
--   3. `record_decision` aprobaba con el cotejo facial a solas: sin exigir que
--      el OCR hubiera leído un número de cédula, y con `registry_matched` en
--      null resolviendo a `coalesce(null, true)`.
--
-- Resultado: selfie contra sí misma → similitud ≈ 1.0 → aprobado. Y la
-- variante con dos fotos de la cédula funcionaba igual, con la agravante de
-- que ahí el OCR sí extrae datos y el flujo de confirmación fluye normal.
--
-- Esta migración cierra 1 y 3. La 2 no se toca a propósito: exigirle más al
-- detector sobre la foto de un documento rechazaría cédulas legítimas, y con
-- 1 y 3 cerrados deja de ser explotable.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Rutas exactas, no prefijos
-- ---------------------------------------------------------------------------
--
-- La app sube siempre a `{uid}/{vid}/document.jpg` y `{uid}/{vid}/selfie.jpg`
-- (ver src/features/kyc/api.ts). Comprobar el nombre completo —y no solo la
-- carpeta— hace imposible declarar el mismo objeto dos veces, que era el
-- primer eslabón del ataque.
--
-- Se aceptan las extensiones de imagen que admite el bucket, para que un
-- cambio de formato en el cliente no tumbe el registro en producción; el
-- nombre base sí es obligatorio.

create or replace function public.submit_kyc_verification(
  p_verification_id uuid,
  p_document_path   text,
  p_selfie_path     text
)
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, pg_temp
as $$
declare
  v_user   uuid := auth.uid();
  v_prefix text;
  v_row    kyc.verifications%rowtype;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_row
  from kyc.verifications
  where id = p_verification_id and user_id = v_user
  for update;

  if not found then
    raise exception 'Verificación no encontrada' using errcode = 'P0002';
  end if;

  if v_row.status not in ('pending', 'processing') then
    return jsonb_build_object('ok', false, 'reason', 'not_pending', 'status', v_row.status);
  end if;

  -- Las rutas las manda el cliente. Comprobar la carpeta impide declarar las
  -- fotos de otro; comprobar el nombre impide declarar la misma foto dos
  -- veces, que es lo que permitía aprobar sin cédula.
  --
  -- El prefijo solo contiene hexadecimal, guiones y barras: no hay
  -- metacaracteres que escapar al meterlo en la expresión regular.
  v_prefix := v_user::text || '/' || p_verification_id::text || '/';

  if p_document_path !~ ('^' || v_prefix || 'document\.(jpg|jpeg|png)$')
     or p_selfie_path !~ ('^' || v_prefix || 'selfie\.(jpg|jpeg|png)$') then
    raise exception 'Rutas de archivo inválidas' using errcode = '42501';
  end if;

  update kyc.verifications
    set document_path = p_document_path,
        selfie_path   = p_selfie_path,
        status        = 'processing',
        updated_at    = now()
  where id = p_verification_id;

  insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
  values (p_verification_id, v_row.status, 'processing', 'user',
          jsonb_build_object('document_path', p_document_path, 'selfie_path', p_selfie_path));

  return jsonb_build_object('ok', true, 'status', 'processing');
end;
$$;

revoke all on function public.submit_kyc_verification(uuid, text, text) from public, anon;
grant execute on function public.submit_kyc_verification(uuid, text, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 2. Aprobar exige identidad, no solo parecido
-- ---------------------------------------------------------------------------
--
-- Cambia la forma de la decisión: antes la aprobación era la primera rama que
-- encajaba; ahora es una conjunción que enumera todo lo que tiene que ser
-- cierto a la vez. Lo que falle cae a revisión manual en vez de aprobar, que
-- es el sentido correcto del error: revisar de más cuesta minutos de un
-- operador, aprobar de menos cuesta una identidad robada.
--
-- Las tres condiciones nuevas:
--
--   · Documento leído. Sin número de cédula extraído no hay identidad que
--     verificar, solo dos caras que se parecen. Éste es el cierre del ataque
--     de la misma imagen: sin OCR no se aprueba solo.
--
--   · Liveness presente. Hoy el worker siempre lo manda, pero esta función es
--     la frontera del sistema de decisión: cualquier caller futuro que mande
--     cotejo sin liveness no debe poder aprobar sin antisuplantación.
--
--   · Similitud plausible. Una selfie contra el retrato IMPRESO de una cédula
--     —otra cámara, otra luz, papel, años de diferencia— casi nunca pasa de
--     ~0.85. Por encima de 0.92 lo más probable es que las dos imágenes
--     vengan de la misma fuente: el mismo archivo subido dos veces, o dos
--     fotos del mismo documento. Es la única señal que distingue ese caso, y
--     por eso va aquí y no en el servicio: se recalibra sin redesplegar.

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
  v_row      kyc.verifications%rowtype;
  v_status   kyc.verification_status;
  v_reason   kyc.rejection_reason;
  v_birth    date;
  v_age      int;
  v_document text;
  v_note     text;
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

  -- Umbrales. Ver docs/02-KYC-PROPIO.md §3: hay que recalibrarlos con datos
  -- reales, los de aquí son el punto de partida.
  if p_hard_failure is not null then
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
    -- Los puntajes de decisión primero, las métricas crudas debajo: si alguna
    -- vez coinciden las claves, mandan los que decidieron.
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
