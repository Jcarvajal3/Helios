-- ============================================================================
-- Ronda — El índice de duplicados solo con identidades aprobadas
--
-- `store_embedding` se llama antes de conocer el veredicto, así que la cara de
-- CUALQUIER intento quedaba en el índice: también la de los rechazados por
-- face_mismatch, por liveness, o por un revisor. El comentario del pipeline
-- ("se guarda solo cuando el intento es legítimo") describía una intención que
-- el orden de las llamadas no cumplía.
--
-- Lo que rompe en la práctica:
--
--   · Teléfono compartido. Un familiar hace el KYC sin darse cuenta de que la
--     sesión es de otro. Lo rechaza el cotejo facial —correctamente—, pero su
--     cara ya quedó ligada a esa cuenta ajena. Cuando después hace su propio
--     KYC, sale 'duplicate_identity' contra sí mismo. Sin salida.
--
--   · Bloqueo deliberado. Tras un rechazo se puede abrir otra verificación sin
--     límite, así que subir fotos de terceros bastaba para reservar sus caras
--     e impedirles registrarse más adelante.
--
-- Dos cambios: el embedding nace inactivo y solo lo activa la aprobación; y
-- 'duplicate_identity' deja de ser rechazo duro. Con umbrales todavía sin
-- calibrar, un falso positivo de duplicado expulsa a un usuario legítimo sin
-- explicación ni reintento posible — es de lo más caro que se le puede hacer.
-- ============================================================================

alter table kyc.face_embeddings
  add column if not exists active boolean not null default false;

comment on column kyc.face_embeddings.active is
  'Solo cuentan para la búsqueda de duplicados los embeddings de identidades '
  'aprobadas. Un intento rechazado no reserva una cara.';

-- Las verificaciones ya aprobadas sí son identidades confirmadas: su embedding
-- entra al índice.
update kyc.face_embeddings e
   set active = true
  from kyc.verifications v
 where v.id = e.verification_id
   and v.status = 'approved'
   and e.active = false;

-- Una verificación, un embedding. Sin esto, cada reproceso —hoy posible porque
-- el claim de la cola no marca nada— insertaba otra fila y engordaba el índice
-- HNSW con copias de la misma cara.
delete from kyc.face_embeddings a
 using kyc.face_embeddings b
 where a.verification_id = b.verification_id
   and a.ctid > b.ctid;

create unique index if not exists face_embeddings_verification_key
  on kyc.face_embeddings (verification_id);

-- El índice de duplicados solo recorre los activos. Parcial: además de ser
-- correcto, lo mantiene pequeño.
drop index if exists kyc.face_embeddings_vector_idx;
create index if not exists face_embeddings_vector_idx
  on kyc.face_embeddings
  using hnsw (embedding extensions.vector_cosine_ops)
  where active;


-- ---------------------------------------------------------------------------
-- La aprobación es lo que mete una cara en el índice
-- ---------------------------------------------------------------------------

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

  -- Aquí se decide si esta cara pasa a contar como identidad registrada. Va en
  -- `apply_status` y no en el servicio porque es el único sitio por donde
  -- pasan TODAS las resoluciones, incluida la aprobación manual de un operador.
  -- Solo 'approved' activa; cualquier otro estado desactiva. Escribirlo así
  -- —y no enumerando los rechazos— cubre también las transiciones de vuelta:
  -- una verificación ya aprobada que un operador baja a revisión deja de
  -- reservar esa cara mientras se decide.
  update kyc.face_embeddings
    set active = (p_status = 'approved')
  where verification_id = p_verification_id;

  -- Aprobar ya no escribe nada en el perfil: eso pasa cuando la persona
  -- confirma. Si confirmó antes que llegara el veredicto —el caso de la
  -- revisión manual—, esta llamada es la que lo activa.
  if p_status = 'approved' then
    perform kyc.advance_profile(p_verification_id);
  end if;

  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

revoke all on function kyc.apply_status(
  uuid, kyc.verification_status, kyc.rejection_reason, text, jsonb
) from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- Un duplicado se revisa, no se rechaza
-- ---------------------------------------------------------------------------
--
-- Es la única rama de `p_hard_failure` que cambia de destino. Las demás
-- (documento ilegible, selfie inservible, liveness) describen una captura que
-- el usuario puede repetir; 'duplicate_identity' acusa a la persona de tener
-- ya una cuenta, y si el parecido era casualidad no hay nada que pueda hacer.
-- Con la cédula delante, un operador resuelve en segundos lo que el coseno no
-- puede.

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
