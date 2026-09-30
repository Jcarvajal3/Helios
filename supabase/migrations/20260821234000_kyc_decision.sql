-- ============================================================================
-- Ronda — Motor de decisión de KYC
--
-- Estas funciones son la frontera entre el servicio de verificación (repo
-- aparte, Python + ONNX) y la base de datos. El servicio evalúa y llama aquí
-- con sus señales; la base decide, registra y actualiza el perfil.
--
-- Ninguna se expone a `authenticated`: solo service role. Un usuario no puede
-- aprobarse a sí mismo.
-- ============================================================================

-- Deja la verificación lista para evaluar y devuelve lo que el servicio
-- necesita. Es lo que consulta el worker para tomar trabajo pendiente.
create or replace function kyc.claim_pending(p_limit int default 10)
returns table (
  verification_id uuid,
  user_id         uuid,
  document_path   text,
  selfie_path     text
)
language sql
security definer
set search_path = kyc, public, pg_temp
as $$
  select v.id, v.user_id, v.document_path, v.selfie_path
  from kyc.verifications v
  where v.status = 'processing'
    and v.document_path is not null
    and v.selfie_path is not null
  order by v.created_at
  limit p_limit
  for update skip locked;
$$;

-- Registra el resultado de la evaluación automática.
--
-- El servicio manda sus señales crudas; los umbrales viven aquí para poder
-- recalibrarlos sin volver a desplegar el servicio.
create or replace function kyc.record_decision(
  p_verification_id  uuid,
  p_face_match_score numeric default null,
  p_liveness_score   numeric default null,
  p_ocr_confidence   numeric default null,
  p_registry_matched boolean default null,
  p_extracted_name   text default null,
  p_extracted_doc    text default null,
  p_extracted_birth  date default null,
  p_hard_failure     kyc.rejection_reason default null
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
begin
  select * into v_row from kyc.verifications
  where id = p_verification_id for update;

  if not found then
    raise exception 'Verificación no encontrada' using errcode = 'P0002';
  end if;

  update kyc.verifications
    set face_match_score   = coalesce(p_face_match_score, face_match_score),
        liveness_score     = coalesce(p_liveness_score, liveness_score),
        ocr_confidence     = coalesce(p_ocr_confidence, ocr_confidence),
        registry_matched   = coalesce(p_registry_matched, registry_matched),
        extracted_name     = coalesce(p_extracted_name, extracted_name),
        extracted_document = coalesce(p_extracted_doc, extracted_document),
        extracted_birth    = coalesce(p_extracted_birth, extracted_birth),
        updated_at         = now()
  where id = p_verification_id;

  -- Umbrales. Ver docs/02-KYC-PROPIO.md §3: hay que recalibrarlos con datos
  -- reales, los de aquí son el punto de partida.
  if p_hard_failure is not null then
    v_status := 'rejected';
    v_reason := p_hard_failure;
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
    jsonb_build_object(
      'face_match_score', p_face_match_score,
      'liveness_score', p_liveness_score,
      'ocr_confidence', p_ocr_confidence,
      'registry_matched', p_registry_matched
    )
  );
end;
$$;

-- Aplica un estado, deja constancia y sincroniza el perfil.
-- Es el único sitio donde cambia el estado de una verificación.
create or replace function kyc.apply_status(
  p_verification_id uuid,
  p_status          kyc.verification_status,
  p_reason          kyc.rejection_reason default null,
  p_actor           text default 'system',
  p_signals         jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $$
declare
  v_row kyc.verifications%rowtype;
begin
  select * into v_row from kyc.verifications
  where id = p_verification_id for update;

  if not found then
    raise exception 'Verificación no encontrada' using errcode = 'P0002';
  end if;

  update kyc.verifications
    set status           = p_status,
        rejection_reason = p_reason,
        reviewed_at      = case when p_actor <> 'system' then now() else reviewed_at end,
        updated_at       = now()
  where id = p_verification_id;

  insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
  values (p_verification_id, v_row.status, p_status, p_actor, p_signals);

  -- Al aprobar, el perfil avanza al siguiente paso del registro: crear el PIN.
  -- Si ya lo tiene, queda activo directamente.
  if p_status = 'approved' then
    update public.profiles p
      set full_name       = coalesce(v_row.extracted_name, p.full_name),
          document_number = coalesce(v_row.extracted_document, p.document_number),
          birth_date      = coalesce(v_row.extracted_birth, p.birth_date),
          status = case
            when exists (select 1 from public.user_pins up where up.user_id = p.id)
              then 'active'::public.profile_status
            else 'pending_pin'::public.profile_status
          end,
          updated_at = now()
    where p.id = v_row.user_id;
  end if;

  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

-- Resolución manual desde el super admin.
create or replace function kyc.review(
  p_verification_id uuid,
  p_approve         boolean,
  p_reviewer        uuid,
  p_note            text default null
)
returns jsonb
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $$
begin
  update kyc.verifications
    set reviewed_by = p_reviewer,
        rejection_detail = coalesce(p_note, rejection_detail)
  where id = p_verification_id;

  return kyc.apply_status(
    p_verification_id,
    case when p_approve then 'approved' else 'rejected' end,
    case when p_approve then null else 'manual_rejection' end,
    p_reviewer::text,
    jsonb_build_object('note', p_note)
  );
end;
$$;

-- Ninguna de estas es invocable desde la app.
revoke all on function kyc.claim_pending(int) from public, anon, authenticated;
revoke all on function kyc.record_decision(uuid, numeric, numeric, numeric, boolean, text, text, date, kyc.rejection_reason) from public, anon, authenticated;
revoke all on function kyc.apply_status(uuid, kyc.verification_status, kyc.rejection_reason, text, jsonb) from public, anon, authenticated;
revoke all on function kyc.review(uuid, boolean, uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Cola de revisión para el super admin
-- ---------------------------------------------------------------------------

create or replace view kyc.review_queue as
select
  v.id,
  v.user_id,
  p.phone_e164,
  v.extracted_name,
  v.extracted_document,
  v.extracted_birth,
  v.face_match_score,
  v.liveness_score,
  v.registry_matched,
  v.rejection_detail,
  v.document_path,
  v.selfie_path,
  v.created_at,
  now() - v.created_at as waiting_for
from kyc.verifications v
join public.profiles p on p.id = v.user_id
where v.status = 'manual_review'
order by v.created_at;
