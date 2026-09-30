-- ============================================================================
-- Ronda — La cédula se compara normalizada
--
-- Hasta aquí el número de documento se guardaba tal cual lo devolvía Didit,
-- con un `btrim` y nada más, y la regla de "una cédula, una cuenta" comparaba
-- cadenas exactas. Basta con que el OCR escriba una vez `12345678` y otra
-- `V-12.345.678` para que el sistema vea dos personas distintas: ni la
-- comprobación blanda de `record_didit_decision` ni el índice único de
-- `profiles` detectan nada. Una persona, dos cuentas.
--
-- El flujo viejo no tenía este agujero por accidente: la persona TECLEABA el
-- número en `confirm_kyc_data` y allí se exigía `^\d{6,9}$`. Ese paso vive
-- ahora dentro de Didit, así que el formato dejó de estar bajo nuestro control
-- y hay que normalizar de este lado.
--
-- La forma de arreglarlo es separar las dos cosas que estaban mezcladas en una
-- sola columna:
--
--   · `document_number` sigue siendo lo que dice el documento. Es lo que se
--     enseña en el panel y lo que busca el buscador de usuarios.
--   · `document_key` es la forma canónica, y es la única que compara. Se
--     calcula sola —columna generada—, así que no hay forma de escribir una
--     sin la otra ni de que se desincronicen.
--
-- La unicidad se muda a la clave: `V-12.345.678` y `12345678` dejan de poder
-- coexistir.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- La forma canónica
-- ---------------------------------------------------------------------------
--
-- Se conserva el prefijo de nacionalidad y se le pone `V` a la cédula pelada,
-- que es como Didit la devuelve casi siempre. Es deliberado: en Venezuela
-- V-12345678 y E-12345678 son DOS personas, así que borrar la letra fusionaría
-- dos identidades reales. Poner la V por defecto hace que `12345678` y
-- `V-12.345.678` caigan en la misma clave, que es justo el caso que falla hoy.
--
-- Un pasaporte —o cualquier cosa sin pinta de cédula— se queda como está, solo
-- sin puntuación y en mayúsculas. Recortarlo a dígitos convertiría el
-- pasaporte `A1234567` en la cédula `1234567` e inventaría duplicados entre
-- documentos que no tienen nada que ver.

create or replace function public.normalize_document(p_document text)
returns text
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
declare
  v_clean  text;
  v_prefix text;
  v_digits text;
begin
  v_clean := upper(regexp_replace(coalesce(p_document, ''), '[^A-Za-z0-9]', '', 'g'));

  if v_clean = '' then
    return null;
  end if;

  if v_clean ~ '^[VE][0-9]+$' then
    v_prefix := left(v_clean, 1);
    v_digits := substr(v_clean, 2);
  elsif v_clean ~ '^[0-9]+$' then
    v_prefix := 'V';
    v_digits := v_clean;
  else
    -- Pasaporte u otro documento.
    return v_clean;
  end if;

  -- Los ceros a la izquierda son ruido del OCR: `00012345678` es la misma
  -- cédula que `12345678`.
  v_digits := coalesce(nullif(ltrim(v_digits, '0'), ''), '0');

  -- Si no cabe en el rango de una cédula venezolana no inventamos un prefijo
  -- que no estaba: se devuelve limpio y ya.
  if length(v_digits) not between 6 and 9 then
    return v_clean;
  end if;

  return v_prefix || v_digits;
end;
$$;

comment on function public.normalize_document(text) is
  'Forma canónica del número de documento, para comparar. Conserva el prefijo '
  'de nacionalidad (V/E) y se lo pone a la cédula pelada; deja el pasaporte '
  'intacto salvo puntuación.';

revoke all on function public.normalize_document(text) from public, anon;
grant execute on function public.normalize_document(text) to authenticated, service_role;


-- ---------------------------------------------------------------------------
-- La clave, en el perfil
-- ---------------------------------------------------------------------------
--
-- Columna GENERADA a propósito, no un campo que alguien tenga que acordarse de
-- rellenar: cualquier vía que escriba `document_number` —`advance_profile`, un
-- ajuste del panel, un UPDATE de emergencia— produce la clave correcta sin
-- saber siquiera que existe.

alter table public.profiles
  add column if not exists document_key text
  generated always as (public.normalize_document(document_number)) stored;

comment on column public.profiles.document_key is
  'Cédula normalizada. Es la que decide si dos cuentas son la misma persona; '
  '`document_number` es solo lo que se leyó del documento y lo que se enseña.';


-- La unicidad se muda de la cadena literal a la clave. La vieja se va porque
-- ya no protege nada que esta no cubra, y dejarla invitaría a comparar por la
-- columna equivocada. El índice de búsqueda sobre `document_number` se queda:
-- el buscador del panel sigue mirando ahí.
alter table public.profiles
  drop constraint if exists profiles_document_number_key;

create unique index if not exists profiles_document_key_uidx
  on public.profiles (document_key);


-- ---------------------------------------------------------------------------
-- El veredicto de Didit compara por la clave
-- ---------------------------------------------------------------------------
--
-- Cuerpo idéntico al de 20260828120200 salvo el bloque marcado NUEVO.

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
      -- persona sigue dentro del flujo. NO se guardan datos extraídos todavía:
      -- rellenar `extracted_document` antes de tener veredicto es lo que
      -- disparaba `needs_confirmation` y desviaba a la pantalla equivocada.
      insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
      values (v_row.id, v_row.status, v_row.status, 'system',
              coalesce(p_signals, '{}'::jsonb) || jsonb_build_object('didit_status', p_status));

      return jsonb_build_object('ok', true, 'status', v_row.status, 'pending', true);
  end case;

  -- --- Datos del documento, ya con veredicto ------------------------------
  --
  -- `data_confirmed_at` se sella en todo estado terminal, no solo al aprobar:
  -- describe que la persona vio y aceptó sus datos dentro de Didit, que es
  -- cierto en los tres casos. Y es lo que permite que, si un operador aprueba
  -- después desde el panel, `advance_profile` active la cuenta.
  --
  -- El número se guarda TAL COMO lo leyó Didit. La forma canónica no se
  -- almacena aquí: se deriva sola en el perfil, y el expediente tiene que
  -- poder enseñar lo que decía el documento.
  update kyc.verifications
     set extracted_name       = coalesce(v_full, extracted_name),
         extracted_first_name = coalesce(nullif(btrim(coalesce(p_first_name, '')), ''), extracted_first_name),
         extracted_last_name  = coalesce(nullif(btrim(coalesce(p_last_name, '')), ''), extracted_last_name),
         extracted_document   = coalesce(nullif(btrim(coalesce(p_document, '')), ''), extracted_document),
         extracted_birth      = coalesce(p_birth_date, extracted_birth),
         confirmed_name       = coalesce(v_full, confirmed_name),
         confirmed_first_name = coalesce(nullif(btrim(coalesce(p_first_name, '')), ''), confirmed_first_name),
         confirmed_last_name  = coalesce(nullif(btrim(coalesce(p_last_name, '')), ''), confirmed_last_name),
         confirmed_document   = coalesce(nullif(btrim(coalesce(p_document, '')), ''), confirmed_document),
         confirmed_birth      = coalesce(p_birth_date, confirmed_birth),
         data_confirmed_at    = coalesce(data_confirmed_at, now()),
         updated_at           = now()
   where id = v_row.id;

  -- --- Reglas de negocio, solo hacia abajo --------------------------------
  if v_status = 'approved' then
    if v_age is not null and v_age < 18 then
      v_status := 'rejected';
      v_reason := 'underage';
      v_note   := format('La fecha de nacimiento del documento da %s años.', v_age);

    elsif exists (
      -- NUEVO: se compara por la clave normalizada, no por la cadena literal.
      -- Con la comparación exacta, `12345678` y `V-12.345.678` pasaban como
      -- personas distintas y "una cédula, una cuenta" no se cumplía.
      --
      -- `normalize_document(null)` devuelve null, y `document_key = null`
      -- nunca es cierto: un veredicto sin número no marca duplicado a nadie.
      select 1 from public.profiles
      where document_key = public.normalize_document(p_document)
        and id <> v_row.user_id
    ) then
      -- Didit verifica a la persona que tiene delante; no sabe qué cuentas
      -- existen ya en Ronda con esa cédula.
      v_status := 'manual_review';
      v_reason := null;
      v_note   := 'Esa cédula ya está registrada en otra cuenta.';
    end if;
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
