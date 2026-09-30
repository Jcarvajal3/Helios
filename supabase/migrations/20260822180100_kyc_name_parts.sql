-- ============================================================================
-- Ronda — Nombres y apellidos por separado
--
-- La cédula imprime dos campos, APELLIDOS y NOMBRES, y el OCR ya los extraía
-- por separado. Pero solo se guardaba la concatenación, así que la pantalla
-- de confirmación mostraba un único campo con todo junto y sin forma de saber
-- dónde acababa un apellido y empezaba un nombre.
--
-- Guardar las dos partes tiene además una consecuencia práctica: lo que el
-- usuario corrige a mano queda estructurado y sirve para cotejar contra un
-- registro civil sin volver a adivinar el corte.
-- ============================================================================

alter table kyc.verifications
  add column if not exists extracted_first_name text,
  add column if not exists extracted_last_name  text;

comment on column kyc.verifications.extracted_first_name is
  'Nombres tal y como los leyó el OCR. Null si no se pudo atribuir el corte.';
comment on column kyc.verifications.extracted_last_name is
  'Apellidos tal y como los leyó el OCR. Null si no se pudo atribuir el corte.';

alter table public.profiles
  add column if not exists first_name text,
  add column if not exists last_name  text;

-- ---------------------------------------------------------------------------
-- record_decision: acepta las dos partes del nombre
-- ---------------------------------------------------------------------------
-- Los nuevos parámetros van al final y con default, así que una llamada con
-- los argumentos de antes sigue resolviendo. La firma vieja se elimina para
-- que no queden dos candidatas y la resolución se vuelva ambigua.

drop function if exists kyc.record_decision(
  uuid, numeric, numeric, numeric, boolean, text, text, date, kyc.rejection_reason
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
  p_extracted_last   text default null
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

revoke all on function kyc.record_decision(
  uuid, numeric, numeric, numeric, boolean, text, text, date,
  kyc.rejection_reason, text, text
) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- apply_status: al aprobar, el perfil hereda también las dos partes
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

  -- Al aprobar, el perfil avanza al siguiente paso del registro: crear el PIN.
  -- Si ya lo tiene, queda activo directamente.
  if p_status = 'approved' then
    update public.profiles p
      set full_name       = coalesce(v_row.extracted_name, p.full_name),
          first_name      = coalesce(v_row.extracted_first_name, p.first_name),
          last_name       = coalesce(v_row.extracted_last_name, p.last_name),
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

revoke all on function kyc.apply_status(
  uuid, kyc.verification_status, kyc.rejection_reason, text, jsonb
) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- confirm_kyc_data: recibe las dos partes
-- ---------------------------------------------------------------------------

drop function if exists public.confirm_kyc_data(uuid, text, text, date);

create or replace function public.confirm_kyc_data(
  p_verification_id uuid,
  p_full_name       text,
  p_document_number text,
  p_birth_date      date,
  p_first_name      text default null,
  p_last_name       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_age  int;
  v_full text;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if not exists (
    select 1 from kyc.verifications
    where id = p_verification_id and user_id = v_user
  ) then
    raise exception 'Verificación no encontrada' using errcode = 'P0002';
  end if;

  -- El nombre completo se compone de las partes cuando vienen, para que no
  -- puedan contradecirse entre sí. `p_full_name` se sigue aceptando por
  -- compatibilidad con clientes que aún mandan un solo campo.
  v_full := nullif(
    btrim(regexp_replace(
      coalesce(nullif(btrim(coalesce(p_first_name, '') || ' ' || coalesce(p_last_name, '')), ''),
               p_full_name,
               ''),
      '\s+', ' ', 'g'
    )),
    ''
  );

  if v_full is null then
    raise exception 'El nombre no puede estar vacío' using errcode = '22023';
  end if;

  -- Cédula venezolana: entre 6 y 9 dígitos, sin prefijo de nacionalidad.
  if p_document_number !~ '^\d{6,9}$' then
    raise exception 'El número de cédula no es válido' using errcode = '22023';
  end if;

  v_age := extract(year from age(current_date, p_birth_date));

  -- La mayoría de edad es requisito legal y se comprueba en el servidor:
  -- el cliente puede mentir, la base de datos no.
  if v_age < 18 then
    update kyc.verifications
      set status = 'rejected',
          rejection_reason = 'underage',
          rejection_detail = format('Edad calculada: %s años', v_age),
          updated_at = now()
    where id = p_verification_id;

    insert into kyc.decision_log (verification_id, to_status, actor, signals)
    values (p_verification_id, 'rejected', 'system',
            jsonb_build_object('reason', 'underage', 'age', v_age));

    return jsonb_build_object('ok', false, 'reason', 'underage');
  end if;

  -- Una cédula, una cuenta. Si ya existe en otro perfil, es un intento de
  -- duplicado y hay que revisarlo a mano.
  if exists (
    select 1 from public.profiles
    where document_number = p_document_number and id <> v_user
  ) then
    update kyc.verifications
      set status = 'manual_review',
          rejection_detail = 'Cédula ya registrada en otra cuenta',
          updated_at = now()
    where id = p_verification_id;

    insert into kyc.decision_log (verification_id, to_status, actor, signals)
    values (p_verification_id, 'manual_review', 'system',
            jsonb_build_object('reason', 'duplicate_document'));

    return jsonb_build_object('ok', false, 'reason', 'duplicate_document');
  end if;

  update kyc.verifications
    set extracted_name       = v_full,
        extracted_first_name = coalesce(nullif(btrim(p_first_name), ''), extracted_first_name),
        extracted_last_name  = coalesce(nullif(btrim(p_last_name), ''), extracted_last_name),
        extracted_document   = p_document_number,
        extracted_birth      = p_birth_date,
        updated_at           = now()
  where id = p_verification_id;

  update public.profiles
    set full_name       = v_full,
        first_name      = coalesce(nullif(btrim(p_first_name), ''), first_name),
        last_name       = coalesce(nullif(btrim(p_last_name), ''), last_name),
        document_number = p_document_number,
        birth_date      = p_birth_date,
        updated_at      = now()
  where id = v_user;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.confirm_kyc_data(uuid, text, text, date, text, text)
  from public, anon;
grant execute on function public.confirm_kyc_data(uuid, text, text, date, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- my_account_state: devuelve las dos partes para prellenar la confirmación
-- ---------------------------------------------------------------------------

create or replace function public.my_account_state()
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, pg_temp
stable
as $$
declare
  v_user  uuid := auth.uid();
  v_kyc   kyc.verifications%rowtype;
  v_prof  public.profiles%rowtype;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_prof from public.profiles where id = v_user;

  select * into v_kyc
  from kyc.verifications
  where user_id = v_user
  order by created_at desc
  limit 1;

  return jsonb_build_object(
    'has_pin', exists (select 1 from public.user_pins where user_id = v_user),
    'terms_accepted', exists (
      select 1 from public.terms_acceptances where user_id = v_user
    ),
    'profile', jsonb_build_object(
      'status', v_prof.status,
      'level', v_prof.level,
      'full_name', v_prof.full_name
    ),
    'kyc', case when v_kyc.id is null then
      jsonb_build_object('status', 'none')
    else
      jsonb_build_object(
        'id', v_kyc.id,
        'status', v_kyc.status,
        'rejection_reason', v_kyc.rejection_reason,
        -- Los datos extraídos solo se devuelven cuando hay algo que confirmar.
        -- Nunca devolvemos los puntajes: le darían a un atacante una señal
        -- para calibrar sus intentos.
        'extracted', case
          when v_kyc.extracted_document is not null then
            jsonb_build_object(
              'full_name', v_kyc.extracted_name,
              'first_name', v_kyc.extracted_first_name,
              'last_name', v_kyc.extracted_last_name,
              'document_number', v_kyc.extracted_document,
              'birth_date', v_kyc.extracted_birth
            )
          else null
        end,
        -- true cuando el OCR ya dio resultado pero el usuario aún no lo ha
        -- confirmado contra su perfil.
        'needs_confirmation', (
          v_kyc.status in ('processing', 'manual_review')
          and v_kyc.extracted_document is not null
          and v_prof.document_number is null
        )
      )
    end
  );
end;
$$;

revoke all on function public.my_account_state() from public, anon;
grant execute on function public.my_account_state() to authenticated;

-- ---------------------------------------------------------------------------
-- Cola de revisión: el revisor ve el corte que hizo el OCR
-- ---------------------------------------------------------------------------

drop view if exists kyc.review_queue;

create view kyc.review_queue as
select
  v.id,
  v.user_id,
  p.phone_e164,
  v.extracted_name,
  v.extracted_first_name,
  v.extracted_last_name,
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
