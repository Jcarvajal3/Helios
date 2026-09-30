-- ============================================================================
-- Ronda — La verificación de identidad pasa a Didit
--
-- Hasta ahora Ronda pedía las fotos, las guardaba en Storage y un servicio
-- propio en Fly.io las evaluaba: OCR, cotejo facial, liveness, duplicados y
-- umbrales calibrados a mano. A partir de aquí eso lo hace Didit entero, en su
-- propia interfaz, y Ronda no llega a ver una imagen.
--
-- Lo que NO cambia, y por eso el cambio es pequeño: `kyc.verifications` sigue
-- siendo el expediente, `apply_status` sigue siendo el único sitio donde cambia
-- un estado, `decision_log` sigue registrando todo y la cola de revisión manual
-- del panel sigue funcionando igual. Solo cambia quién produce el veredicto.
--
-- Dos reglas se quedan del lado de Ronda a propósito, porque no son de
-- identidad sino de negocio y Didit no puede conocerlas:
--
--   · Mayoría de edad. Es un requisito legal del producto. La regla vive
--     también en el flujo de Didit, pero comprobarla aquí cuesta nada y cubre
--     el caso de que allí se desconfigure.
--   · Una cédula, una cuenta. Didit verifica a la persona que tiene delante;
--     no sabe cuántas cuentas de Ronda existen ya con ese número.
-- ============================================================================

alter table kyc.verifications
  add column if not exists didit_session_id text;

comment on column kyc.verifications.didit_session_id is
  'Sesión de Didit que resolvió esta verificación. Es la llave para casar el '
  'webhook con el expediente.';

create unique index if not exists verifications_didit_session_key
  on kyc.verifications (didit_session_id)
  where didit_session_id is not null;


-- ---------------------------------------------------------------------------
-- Enlazar la sesión con el expediente
-- ---------------------------------------------------------------------------
--
-- La llama la función de borde justo después de crear la sesión en Didit. Deja
-- la verificación en 'processing', que es lo que la pantalla de estado de la
-- app ya sabe interpretar como "esto está en marcha".

create or replace function kyc.attach_didit_session(
  p_verification_id uuid,
  p_session_id      text
)
returns void
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

  if v_row.status not in ('pending', 'processing') then
    raise exception 'La verificación ya está resuelta' using errcode = '22023';
  end if;

  update kyc.verifications
     set didit_session_id = p_session_id,
         status           = 'processing',
         updated_at       = now()
   where id = p_verification_id;

  insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
  values (p_verification_id, v_row.status, 'processing', 'system',
          jsonb_build_object('provider', 'didit', 'session_id', p_session_id));
end;
$$;

revoke all on function kyc.attach_didit_session(uuid, text)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- Registrar el veredicto de Didit
-- ---------------------------------------------------------------------------
--
-- Traduce su resultado al expediente. No re-evalúa nada: los umbrales de
-- identidad son suyos ahora. Lo único que decide aquí es la elegibilidad de
-- negocio (edad y unicidad de la cédula), y solo puede empeorar el veredicto,
-- nunca mejorarlo — un rechazo de Didit no se convierte en aprobación por
-- ninguna vía.

create or replace function kyc.record_didit_decision(
  p_session_id text,
  p_status     text,
  p_document   text default null,
  p_first_name text default null,
  p_last_name  text default null,
  p_full_name  text default null,
  p_birth_date date default null,
  p_detail     text default null,
  p_signals    jsonb default '{}'::jsonb
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
  v_full   text;
  v_age    int;
  v_note   text;
begin
  select * into v_row from kyc.verifications
  where didit_session_id = p_session_id for update;

  if not found then
    raise exception 'Sesión de Didit desconocida: %', p_session_id
      using errcode = 'P0002';
  end if;

  -- Los webhooks se reentregan. Volver a aplicar un estado ya alcanzado
  -- duplicaría renglones en la bitácora y volvería a tocar el perfil.
  if v_row.status in ('approved', 'rejected') then
    return jsonb_build_object('ok', true, 'status', v_row.status, 'ignored', 'already_resolved');
  end if;

  v_full := nullif(
    btrim(regexp_replace(
      coalesce(
        nullif(btrim(coalesce(p_first_name, '') || ' ' || coalesce(p_last_name, '')), ''),
        p_full_name,
        ''
      ),
      '\s+', ' ', 'g'
    )),
    ''
  );

  update kyc.verifications
     set extracted_name       = coalesce(v_full, extracted_name),
         extracted_first_name = coalesce(nullif(btrim(coalesce(p_first_name, '')), ''), extracted_first_name),
         extracted_last_name  = coalesce(nullif(btrim(coalesce(p_last_name, '')), ''), extracted_last_name),
         extracted_document   = coalesce(nullif(btrim(coalesce(p_document, '')), ''), extracted_document),
         extracted_birth      = coalesce(p_birth_date, extracted_birth),
         updated_at           = now()
   where id = v_row.id;

  v_age := case
    when coalesce(p_birth_date, v_row.extracted_birth) is null then null
    else extract(year from age(current_date, coalesce(p_birth_date, v_row.extracted_birth)))::int
  end;

  -- --- Traducción del veredicto ------------------------------------------
  case p_status
    when 'Approved' then
      v_status := 'approved';

    when 'Declined' then
      v_status := 'rejected';
      v_reason := 'provider_declined';
      v_note   := p_detail;

    when 'In Review' then
      v_status := 'manual_review';
      v_note   := coalesce(p_detail, 'Didit la dejó en revisión.');

    when 'Abandoned' then
      v_status := 'rejected';
      v_reason := 'provider_declined';
      v_note   := 'La verificación se abandonó sin terminar.';

    when 'Expired' then
      v_status := 'rejected';
      v_reason := 'provider_declined';
      v_note   := 'La sesión de verificación caducó.';

    when 'Kyc Expired' then
      v_status := 'rejected';
      v_reason := 'provider_declined';
      v_note   := 'La sesión de verificación caducó.';

    else
      -- 'In Progress', 'Not Started', 'Resubmitted', 'Awaiting User': la
      -- persona sigue dentro del flujo. Se guardan los datos que hayan llegado
      -- y se espera al webhook definitivo.
      insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
      values (v_row.id, v_row.status, v_row.status, 'system',
              coalesce(p_signals, '{}'::jsonb) || jsonb_build_object('didit_status', p_status));

      return jsonb_build_object('ok', true, 'status', v_row.status, 'pending', true);
  end case;

  -- --- Reglas de negocio, solo hacia abajo --------------------------------
  if v_status = 'approved' then
    if v_age is not null and v_age < 18 then
      v_status := 'rejected';
      v_reason := 'underage';
      v_note   := format('La fecha de nacimiento del documento da %s años.', v_age);

    elsif exists (
      select 1 from public.profiles
      where document_number = nullif(btrim(coalesce(p_document, '')), '')
        and id <> v_row.user_id
    ) then
      -- Didit verifica a la persona que tiene delante; no sabe qué cuentas
      -- existen ya en Ronda con esa cédula.
      v_status := 'manual_review';
      v_reason := null;
      v_note   := 'Esa cédula ya está registrada en otra cuenta.';
    end if;
  end if;

  -- Aprobada de verdad: los datos vienen del documento y la persona ya los
  -- revisó dentro del flujo de Didit, así que no hay nada más que confirmar.
  -- Sin esto `advance_profile` no activaría nunca la cuenta.
  if v_status = 'approved' then
    update kyc.verifications
       set confirmed_name       = coalesce(v_full, extracted_name),
           confirmed_first_name = coalesce(nullif(btrim(coalesce(p_first_name, '')), ''), extracted_first_name),
           confirmed_last_name  = coalesce(nullif(btrim(coalesce(p_last_name, '')), ''), extracted_last_name),
           confirmed_document   = coalesce(nullif(btrim(coalesce(p_document, '')), ''), extracted_document),
           confirmed_birth      = coalesce(p_birth_date, extracted_birth),
           data_confirmed_at    = coalesce(data_confirmed_at, now()),
           updated_at           = now()
     where id = v_row.id;
  end if;

  if v_note is not null then
    update kyc.verifications
       set rejection_detail = v_note
     where id = v_row.id;
  end if;

  -- El actor es 'system' y no 'didit' a propósito: `apply_status` sella
  -- `reviewed_at` con cualquier actor distinto de 'system', y esto es una
  -- decisión automática, no la revisión de una persona. Que venga de Didit se
  -- registra en las señales, donde no falsea la bitácora.
  return kyc.apply_status(
    v_row.id,
    v_status,
    v_reason,
    'system',
    coalesce(p_signals, '{}'::jsonb) || jsonb_build_object(
      'provider', 'didit',
      'didit_status', p_status,
      'ocr_age', v_age,
      'review_note', v_note
    )
  );
end;
$$;

revoke all on function kyc.record_didit_decision(
  text, text, text, text, text, text, date, text, jsonb
) from public, anon, authenticated;
