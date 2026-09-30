-- ============================================================================
-- Ronda — La confirmación deja de ser un cheque en blanco
--
-- `confirm_kyc_data` es la única RPC de KYC que el cliente puede llamar con
-- datos libres, y hasta ahora no comparaba NADA contra lo que leyó el OCR.
-- Tres consecuencias, todas explotables con una cuenta normal:
--
--   · Sustitución de identidad: alguien con SU cédula y SU cara (el cotejo
--     aprueba) confirmaba con el nombre y el número de otra persona. El perfil
--     quedaba con una identidad ajena marcada como verificada.
--
--   · Ocupación del número: el `update public.profiles` corría sin mirar el
--     estado de la verificación, así que un rechazado podía plantar la cédula
--     de otro en su perfil. Cuando el dueño real confirmaba, chocaba con
--     'duplicate_document' y caía en revisión manual. Denegación de servicio
--     por dos pesos.
--
--   · Borrado de la evidencia: el update escribía sobre `extracted_*`, o sea
--     que la corrección del usuario DESTRUÍA lo que decía la cédula. Después
--     no había forma de auditar si lo confirmado se parecía a lo leído.
--
-- El arreglo tiene tres partes: lo confirmado va a columnas propias, se cruza
-- contra el OCR con tolerancia a sus errores típicos, y el perfil solo se
-- toca cuando la verificación está aprobada.
--
-- Nota sobre datos existentes: las filas confirmadas antes de esta migración
-- ya tienen `extracted_*` sobrescrito. Eso no se puede recuperar; a partir de
-- aquí deja de pasar.
-- ============================================================================

alter table kyc.verifications
  add column if not exists confirmed_name       text,
  add column if not exists confirmed_first_name text,
  add column if not exists confirmed_last_name  text,
  add column if not exists confirmed_document   text,
  add column if not exists confirmed_birth      date;

comment on column kyc.verifications.confirmed_document is
  'Lo que afirmó la persona. Nunca pisa extracted_document: la comparación '
  'entre ambos es la señal de que alguien está declarando otra identidad.';


-- ---------------------------------------------------------------------------
-- Comparadores tolerantes a los errores del OCR
--
-- Se implementan en plpgsql en vez de con `unaccent`/`levenshtein` para no
-- añadir extensiones al proyecto por esto. Son deterministas e inmutables, así
-- que Postgres puede cachearlas.
-- ---------------------------------------------------------------------------

-- Mayúsculas, sin acentos y sin nada que no sea letra o espacio.
create or replace function kyc.normalize_name(p_text text)
returns text
language sql
immutable
as $$
  select nullif(
    btrim(regexp_replace(
      regexp_replace(
        translate(
          upper(coalesce(p_text, '')),
          'ÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ',
          'AAAAAEEEEIIIIOOOOOUUUUNC'
        ),
        '[^A-Z ]', ' ', 'g'
      ),
      '\s+', ' ', 'g'
    )),
    ''
  );
$$;

-- Dígitos de una cédula, deshaciendo antes las confusiones habituales del OCR.
--
-- Esto importa más de lo que parece: sin el mapeo, `regexp_replace('\D','')`
-- BORRA el carácter mal leído — una "B" donde iba un "8" no da error, da un
-- número de siete dígitos que sigue pareciendo válido.
create or replace function kyc.normalize_document(p_text text)
returns text
language sql
immutable
as $$
  select nullif(
    regexp_replace(
      translate(upper(coalesce(p_text, '')), 'OQILBSZG', '00118526'),
      '\D', '', 'g'
    ),
    ''
  );
$$;

-- ¿Son el mismo número, admitiendo un carácter mal leído?
--
-- Devuelve null cuando el OCR no leyó nada: no es coincidencia ni
-- discrepancia, es ausencia de dato, y quien llama decide qué hacer.
create or replace function kyc.document_matches(p_ocr text, p_claimed text)
returns boolean
language plpgsql
immutable
as $$
declare
  v_ocr     text := kyc.normalize_document(p_ocr);
  v_claimed text := kyc.normalize_document(p_claimed);
  v_diff    int  := 0;
  i         int;
begin
  if v_ocr is null or v_claimed is null then
    return null;
  end if;

  if v_ocr = v_claimed then
    return true;
  end if;

  -- Una sustitución se tolera; una longitud distinta ya no es un dígito mal
  -- leído sino otro número.
  if length(v_ocr) <> length(v_claimed) then
    return false;
  end if;

  for i in 1..length(v_ocr) loop
    if substr(v_ocr, i, 1) <> substr(v_claimed, i, 1) then
      v_diff := v_diff + 1;
      if v_diff > 1 then
        return false;
      end if;
    end if;
  end loop;

  return true;
end;
$$;

-- ¿Es la misma persona, admitiendo que abrevie?
--
-- Nadie teclea sus cuatro nombres: el caso legítimo más común es que el OCR
-- lea "JAVIER ANDRES CARVAJAL PEREZ" y la persona confirme "Javier Carvajal".
-- Por eso se mide coincidencia de partes y no igualdad de la cadena. Dos
-- partes en común (normalmente un nombre y un apellido) es la barra; una sola
-- no basta, porque los apellidos se repiten mucho.
create or replace function kyc.name_matches(p_ocr text, p_claimed text)
returns boolean
language plpgsql
immutable
as $$
declare
  v_ocr_parts     text[];
  v_claimed_parts text[];
  v_common        int;
begin
  select array_agg(part) into v_ocr_parts
  from unnest(string_to_array(kyc.normalize_name(p_ocr), ' ')) as part
  where length(part) >= 3;

  select array_agg(part) into v_claimed_parts
  from unnest(string_to_array(kyc.normalize_name(p_claimed), ' ')) as part
  where length(part) >= 3;

  if v_ocr_parts is null or v_claimed_parts is null then
    return null;
  end if;

  select count(*) into v_common
  from unnest(v_ocr_parts) as part
  where part = any (v_claimed_parts);

  if least(array_length(v_ocr_parts, 1), array_length(v_claimed_parts, 1)) = 1 then
    return v_common >= 1;
  end if;

  return v_common >= 2;
end;
$$;

-- Misma fecha, admitiendo que el OCR intercambiara día y mes: los formatos
-- dd/mm y mm/dd conviven en los documentos y es la confusión más frecuente.
create or replace function kyc.birth_matches(p_ocr date, p_claimed date)
returns boolean
language sql
immutable
as $$
  select case
    when p_ocr is null or p_claimed is null then null
    when p_ocr = p_claimed then true
    when extract(day from p_ocr) = extract(month from p_claimed)
     and extract(month from p_ocr) = extract(day from p_claimed)
     and extract(year from p_ocr) = extract(year from p_claimed) then true
    else false
  end;
$$;

revoke all on function kyc.normalize_name(text) from public, anon, authenticated;
revoke all on function kyc.normalize_document(text) from public, anon, authenticated;
revoke all on function kyc.document_matches(text, text) from public, anon, authenticated;
revoke all on function kyc.name_matches(text, text) from public, anon, authenticated;
revoke all on function kyc.birth_matches(date, date) from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- El perfil se llena con lo confirmado, no con lo leído
-- ---------------------------------------------------------------------------
--
-- Antes daba igual porque `confirm_kyc_data` pisaba `extracted_*` con la
-- corrección del usuario. Ahora que cada cosa vive en su columna, hay que
-- decir explícitamente cuál manda: la que la persona confirmó y —si hubo
-- discrepancia— un operador aprobó.

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

  update public.profiles p
    set full_name       = coalesce(v_row.confirmed_name, v_row.extracted_name, p.full_name),
        first_name      = coalesce(v_row.confirmed_first_name, v_row.extracted_first_name, p.first_name),
        last_name       = coalesce(v_row.confirmed_last_name, v_row.extracted_last_name, p.last_name),
        document_number = coalesce(v_row.confirmed_document, v_row.extracted_document, p.document_number),
        birth_date      = coalesce(v_row.confirmed_birth, v_row.extracted_birth, p.birth_date),
        status = case
          when exists (select 1 from public.user_pins up where up.user_id = p.id)
            then 'active'::public.profile_status
          else 'pending_pin'::public.profile_status
        end,
        updated_at = now()
  where p.id = v_row.user_id;
end;
$$;


-- ---------------------------------------------------------------------------
-- confirm_kyc_data, con guardias y cruce
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
  v_user        uuid := auth.uid();
  v_row         kyc.verifications%rowtype;
  v_age         int;
  v_full        text;
  v_doc_match   boolean;
  v_name_match  boolean;
  v_birth_match boolean;
  v_note        text;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_row from kyc.verifications
  where id = p_verification_id and user_id = v_user
  for update;

  if not found then
    raise exception 'Verificación no encontrada' using errcode = 'P0002';
  end if;

  -- Una verificación rechazada no se "arregla" confirmando datos. Sin esta
  -- guardia, el rechazado escribía igualmente en su perfil.
  if v_row.status = 'rejected' then
    return jsonb_build_object('ok', false, 'reason', 'rejected');
  end if;

  -- Y no se confirma dos veces: si no, una cuenta ya activa podía reescribir
  -- su nombre y su cédula cuando quisiera, sin volver a verificarse.
  if v_row.data_confirmed_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'already_confirmed');
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
  -- cliente puede mentir, la base de datos no.
  if v_age < 18 then
    update kyc.verifications
      set status = 'rejected',
          rejection_reason = 'underage',
          rejection_detail = format('Edad calculada: %s años', v_age),
          confirmed_name = v_full,
          confirmed_document = p_document_number,
          confirmed_birth = p_birth_date,
          data_confirmed_at = now(),
          updated_at = now()
    where id = p_verification_id;

    insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
    values (p_verification_id, v_row.status, 'rejected', 'user',
            jsonb_build_object('reason', 'underage', 'age', v_age));

    return jsonb_build_object('ok', false, 'reason', 'underage');
  end if;

  -- Una cédula, una cuenta. Ahora que el perfil solo se escribe al aprobar,
  -- este choque significa de verdad que hay otra cuenta verificada con ese
  -- número, no que alguien lo plantó ahí.
  if exists (
    select 1 from public.profiles
    where document_number = p_document_number and id <> v_user
  ) then
    update kyc.verifications
      set status = 'manual_review',
          rejection_detail = 'Cédula ya registrada en otra cuenta',
          confirmed_name = v_full,
          confirmed_document = p_document_number,
          confirmed_birth = p_birth_date,
          data_confirmed_at = now(),
          updated_at = now()
    where id = p_verification_id;

    insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
    values (p_verification_id, v_row.status, 'manual_review', 'user',
            jsonb_build_object('reason', 'duplicate_document'));

    return jsonb_build_object('ok', false, 'reason', 'duplicate_document');
  end if;

  -- --- El cruce ------------------------------------------------------------
  v_doc_match   := kyc.document_matches(v_row.extracted_document, p_document_number);
  v_name_match  := kyc.name_matches(v_row.extracted_name, v_full);
  v_birth_match := kyc.birth_matches(v_row.extracted_birth, p_birth_date);

  if v_doc_match is false then
    v_note := format('La cédula confirmada (%s) no es la que leyó el OCR (%s).',
                     p_document_number, coalesce(v_row.extracted_document, '—'));
  elsif v_name_match is false then
    v_note := format('El nombre confirmado (%s) no se parece al de la cédula (%s).',
                     v_full, coalesce(v_row.extracted_name, '—'));
  elsif v_birth_match is false then
    v_note := format('La fecha de nacimiento confirmada (%s) no es la de la cédula (%s).',
                     p_birth_date, coalesce(v_row.extracted_birth::text, '—'));
  elsif v_doc_match is null then
    -- El OCR no leyó el número: no hay nada contra qué cruzar, y aceptar lo
    -- tecleado a ciegas sería exactamente el agujero que cierra esta
    -- migración. Lo mira una persona, que para eso tiene la cédula delante.
    v_note := 'El OCR no leyó la cédula: hay que cotejar los datos a mano.';
  end if;

  -- Lo confirmado va a sus columnas, pase lo que pase con el cruce: es lo que
  -- la persona afirmó y forma parte del expediente.
  update kyc.verifications
    set confirmed_name       = v_full,
        confirmed_first_name = nullif(btrim(coalesce(p_first_name, '')), ''),
        confirmed_last_name  = nullif(btrim(coalesce(p_last_name, '')), ''),
        confirmed_document   = p_document_number,
        confirmed_birth      = p_birth_date,
        data_confirmed_at    = now(),
        updated_at           = now()
  where id = p_verification_id;

  -- El delta OCR→confirmado queda registrado SIEMPRE, coincida o no. Es lo
  -- que permite auditar después si alguien declaró otra identidad, y lo que
  -- alimenta la calibración de los comparadores.
  insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
  values (
    p_verification_id, v_row.status, coalesce(v_row.status, 'pending'), 'user',
    jsonb_build_object(
      'event', 'data_confirmed',
      'ocr', jsonb_build_object(
        'document', v_row.extracted_document,
        'name', v_row.extracted_name,
        'birth', v_row.extracted_birth
      ),
      'confirmed', jsonb_build_object(
        'document', p_document_number,
        'name', v_full,
        'birth', p_birth_date
      ),
      'match', jsonb_build_object(
        'document', v_doc_match,
        'name', v_name_match,
        'birth', v_birth_match
      )
    )
  );

  if v_note is not null then
    -- Discrepancia: no se aprueba sola. Si ya estaba aprobada por el cotejo
    -- facial, esto la baja a revisión — el parecido de la cara no dice nada
    -- sobre qué identidad se está declarando.
    -- Los dos parámetros enum van casteados a propósito: pasarlos como
    -- literales sueltos hace que PL/pgSQL los tome por `text` y la llamada
    -- falle en RESOLUCIÓN, siempre, sin importar los datos. Es el mismo error
    -- que dejó la revisión manual sin funcionar hasta 20260822111000.
    perform kyc.apply_status(
      p_verification_id,
      'manual_review'::kyc.verification_status,
      null::kyc.rejection_reason,
      'system',
      jsonb_build_object('reason', 'confirm_mismatch', 'detail', v_note)
    );

    update kyc.verifications
      set rejection_detail = v_note
    where id = p_verification_id;

    return jsonb_build_object('ok', false, 'reason', 'needs_review');
  end if;

  -- Todo cuadra. Si el veredicto ya había llegado, esto es lo que faltaba
  -- para activar la cuenta; si no, lo hará `apply_status` cuando llegue.
  perform kyc.advance_profile(p_verification_id);

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.confirm_kyc_data(uuid, text, text, date, text, text)
  from public, anon;
grant execute on function public.confirm_kyc_data(uuid, text, text, date, text, text)
  to authenticated;
