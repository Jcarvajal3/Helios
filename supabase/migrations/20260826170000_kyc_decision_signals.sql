-- ============================================================================
-- Ronda — Guardar las señales crudas de cada decisión de KYC
--
-- El servicio ya calcula todo lo que haría falta para entender un rechazo:
-- confianza del detector, yaw, roll, puntos fuera del encuadre, desbordamiento
-- de la caja, residuo del alineado, motivos del liveness y qué compuerta
-- concreta bloqueó la selfie. Nada de eso llegaba aquí: `record_decision` solo
-- recibía los cuatro puntajes finales y el resto moría en el log del
-- contenedor, que rota.
--
-- La consecuencia se vio en el primer caso real: tres verificaciones legítimas
-- rechazadas como 'selfie_unusable' y ninguna forma de saber cuál de las siete
-- comprobaciones falló, porque el dato se calculó y se tiró.
--
-- Un umbral no se puede recalibrar sin la distribución de la métrica que
-- corta. Esto es lo que hace posible la calibración: a partir de aquí cada
-- decisión deja en `kyc.decision_log.signals` las métricas que la sustentan.
-- ============================================================================

-- La firma anterior se elimina en vez de convivir: como el parámetro nuevo
-- lleva valor por defecto, mantener ambas haría ambigua cualquier llamada con
-- los once argumentos de antes.
drop function if exists kyc.record_decision(
  uuid, numeric, numeric, numeric, boolean, text, text, date,
  kyc.rejection_reason, text, text
);

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
  -- Métricas crudas del pipeline. Es diagnóstico, no entra en la decisión:
  -- los umbrales siguen siendo los de abajo.
  p_signals          jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $$
declare
  v_row    kyc.verifications%rowtype;
  v_status kyc.verification_status;
  v_reason kyc.rejection_reason;
  v_birth  date;
  v_age    int;
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

  -- Umbrales. Ver docs/02-KYC-PROPIO.md §3: hay que recalibrarlos con datos
  -- reales, los de aquí son el punto de partida.
  if p_hard_failure is not null then
    v_status := 'rejected';
    v_reason := p_hard_failure;
  elsif v_age is not null and v_age < 18 then
    v_status := 'manual_review';
    update kyc.verifications
      set rejection_detail = format('El OCR leyó una edad de %s años', v_age)
    where id = p_verification_id;
  elsif p_liveness_score is not null and p_liveness_score < 0.50 then
    v_status := 'rejected';
    v_reason := 'liveness_failed';
  elsif p_face_match_score is null then
    v_status := 'manual_review';
  elsif p_face_match_score >= 0.45 and coalesce(p_registry_matched, true) then
    v_status := 'approved';
  elsif p_face_match_score < 0.30 then
    v_status := 'rejected';
    v_reason := 'face_mismatch';
  else
    -- Zona gris: la mira una persona.
    v_status := 'manual_review';
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
      'ocr_age', v_age
    )
  );
end;
$$;

revoke all on function kyc.record_decision(
  uuid, numeric, numeric, numeric, boolean, text, text, date,
  kyc.rejection_reason, text, text, jsonb
) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Lectura cómoda para calibrar
--
-- Sin esto, mirar por qué se rechaza hoy es leer JSON a mano en la bitácora.
-- La vista deja las métricas de la compuerta en columnas, que es como se
-- pueden ordenar, promediar y comparar contra el umbral que las corta.
-- ---------------------------------------------------------------------------

create or replace view kyc.gate_metrics as
select
  d.verification_id,
  v.status,
  v.rejection_reason,
  d.created_at,
  d.signals -> 'selfie_blockers'                        as selfie_blockers,
  (d.signals -> 'selfie_geometry' ->> 'detection_score')::numeric  as detection_score,
  (d.signals -> 'selfie_geometry' ->> 'yaw')::numeric              as yaw,
  (d.signals -> 'selfie_geometry' ->> 'roll_deg')::numeric         as roll_deg,
  (d.signals -> 'selfie_geometry' ->> 'landmarks_outside')::numeric as landmarks_outside,
  (d.signals -> 'selfie_geometry' ->> 'bbox_overflow')::numeric    as bbox_overflow,
  (d.signals -> 'selfie_geometry' ->> 'mouth_eye_ratio')::numeric  as mouth_eye_ratio,
  (d.signals -> 'selfie_geometry' ->> 'interocular_px')::numeric   as interocular_px,
  (d.signals -> 'align_residual' ->> 'selfie')::numeric            as align_residual_selfie,
  (d.signals -> 'align_residual' ->> 'document')::numeric          as align_residual_document,
  d.signals -> 'selfie_quality'                         as selfie_quality,
  d.signals -> 'document_quality'                       as document_quality,
  d.signals -> 'liveness_reasons'                       as liveness_reasons,
  (d.signals ->> 'face_match_score')::numeric           as face_match_score
from kyc.decision_log d
join kyc.verifications v on v.id = d.verification_id
where d.actor = 'system'
order by d.created_at desc;
