-- ============================================================================
-- Ronda — Confirmar los datos deja de depender del veredicto
--
-- El bug: `needs_confirmation` preguntaba "¿en qué estado está la
-- verificación?" cuando lo que necesitaba saber era "¿ya confirmó el usuario
-- sus datos?". Solo devolvía true para 'processing' y 'manual_review', así
-- que quien aprobaba a la primera NUNCA veía la pantalla de confirmación.
--
-- Tres consecuencias, de menor a mayor:
--
-- 1. El nombre y la cédula que leyó una máquina entraban al perfil sin que
--    nadie los mirara. `full_name` se usa en cobranza y `document_number` es
--    único en toda la base: un dígito mal podía bloquear después al dueño
--    real de ese número. Y si ese número YA existía en otro perfil, el update
--    de aprobación reventaba contra la restricción de unicidad, la
--    verificación se quedaba colgada y el worker la reintentaba en bucle.
--
-- 2. Ver "Confirma tus datos" se leía como aprobación, porque solo la veían
--    algunos: avanzar de pantalla parece premio. Si la ve todo el mundo, deja
--    de ser un veredicto y pasa a ser lo que es, un paso más del registro.
--
-- 3. La grave: **la comprobación de mayoría de edad no se ejecutaba**. El
--    único sitio de todo el sistema donde se verifica que el usuario tenga 18
--    años está dentro de `confirm_kyc_data`, y a `confirm_kyc_data` solo se
--    llega desde esa pantalla. Un menor con su cédula y una selfie que
--    coincidía entraba con crédito, porque a él justamente nunca se le
--    preguntaba la edad.
--
-- El arreglo es una marca explícita de "ya confirmó", más la regla de que un
-- perfil no se activa sin ella. Y, por si el usuario nunca vuelve a abrir la
-- app, una segunda comprobación de edad en el momento de decidir.
-- ============================================================================

alter table kyc.verifications
  add column if not exists data_confirmed_at timestamptz;

comment on column kyc.verifications.data_confirmed_at is
  'Cuándo el usuario revisó y afirmó los datos del OCR. Sin esto el perfil no '
  'se activa: es lo que separa un dato leído por una máquina de uno afirmado '
  'por una persona.';

-- Backfill: reproduce exactamente el criterio anterior para lo que ya existe,
-- que era "el perfil ya tiene cédula". Sin esto, cada usuario ya verificado
-- volvería a la pantalla de confirmación la próxima vez que abriera la app.
update kyc.verifications v
   set data_confirmed_at = coalesce(v.updated_at, now())
  from public.profiles p
 where p.id = v.user_id
   and v.data_confirmed_at is null
   and p.document_number is not null;

-- ---------------------------------------------------------------------------
-- Un solo sitio decide si el perfil avanza
-- ---------------------------------------------------------------------------
-- Antes esto vivía dentro de `apply_status` y se disparaba con la aprobación
-- a secas. Ahora hacen falta las DOS condiciones —aprobada y confirmada— y da
-- igual cuál de las dos llegue primero: manda la última.

create or replace function kyc.advance_profile(p_verification_id uuid)
returns void
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $$
declare
  v_row kyc.verifications%rowtype;
begin
  select * into v_row from kyc.verifications where id = p_verification_id;

  if not found
     or v_row.status <> 'approved'
     or v_row.data_confirmed_at is null then
    return;
  end if;

  -- Los datos salen de la verificación, que a estas alturas ya contiene lo
  -- que el usuario afirmó: `confirm_kyc_data` sobrescribe ahí lo que leyó el
  -- OCR con lo que la persona corrigió.
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
end;
$$;

revoke all on function kyc.advance_profile(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- apply_status: aprobar ya no activa por sí solo
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
-- record_decision: un menor no puede aprobarse, confirme o no
-- ---------------------------------------------------------------------------
-- La comprobación dura de edad sigue en `confirm_kyc_data`, sobre la fecha que
-- el usuario afirma. Esta de aquí es la red por debajo: si la fecha que leyó
-- el OCR ya dice que es menor, la verificación no puede aprobarse sola aunque
-- la persona no vuelva a abrir la app nunca más.
--
-- Manda a revisión manual en vez de rechazar porque la fecha todavía no la ha
-- visto nadie: el OCR confunde dígitos, y rechazar por 'underage' no ofrece
-- reintento. Un humano mira la cédula y decide.

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
    jsonb_build_object(
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
  kyc.rejection_reason, text, text
) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- confirm_kyc_data: deja constancia y, si procede, activa
-- ---------------------------------------------------------------------------

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

  -- La mayoría de edad es requisito legal y se comprueba en el servidor: el
  -- cliente puede mentir, la base de datos no. Esta es la comprobación que
  -- manda, sobre la fecha que la persona afirma — y ahora se ejecuta SIEMPRE,
  -- porque todo el mundo pasa por aquí, no solo quien cae en revisión manual.
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
        data_confirmed_at    = now(),
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

  -- Si el veredicto ya había llegado, esta confirmación es lo que faltaba
  -- para activar la cuenta. Si aún no ha llegado, no hace nada y ya lo hará
  -- `apply_status`.
  perform kyc.advance_profile(p_verification_id);

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.confirm_kyc_data(uuid, text, text, date, text, text)
  from public, anon;
grant execute on function public.confirm_kyc_data(uuid, text, text, date, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- my_account_state: la pregunta correcta
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
        -- La pregunta ya no es "¿en qué estado está la verificación?" sino
        -- "¿ya confirmó el usuario sus datos?". Confirmar es un paso del
        -- registro, no una consecuencia del veredicto: lo hace todo el mundo.
        'needs_confirmation', (
          v_kyc.extracted_document is not null
          and v_kyc.data_confirmed_at is null
        )
      )
    end
  );
end;
$$;

revoke all on function public.my_account_state() from public, anon;
grant execute on function public.my_account_state() to authenticated;
