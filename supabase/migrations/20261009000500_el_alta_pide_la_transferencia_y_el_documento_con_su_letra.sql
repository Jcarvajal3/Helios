-- ============================================================================
-- Helios — El alta pide la transferencia, y cada documento va con su letra
--
-- 1. `helios_documento(p, p_letras)`: una cédula, un pasaporte o un RIF en
--    UN formato. El panel manda la letra elegida en un selector y los
--    números (sin puntos ni guiones); aquí se deja como se guarda siempre:
--      · cédula V/E   → `V12345678` (sin ceros a la izquierda)
--      · pasaporte P  → `PAB1234567`
--      · RIF J/G      → `J-123456789`
--    Lo que no casa con las letras permitidas → null (el llamador explica).
-- 2. Los datos de pago del alta pasan a ser los de `merchant_payout_accounts`:
--    `account_holder` y `holder_document` (el titular), la transferencia
--    (`bank`, `account_number` de 20 dígitos) y el Pago Móvil
--    (`pago_movil_bank`, `pago_movil_phone`). El equipo pone una, otra o las
--    dos; la solicitud de la portada solo la transferencia.
-- 3. `merchant_applications`: `pago_movil_document` pasa a `holder_document`
--    (no había ninguna pendiente), y se añaden el titular y la cuenta. El
--    Pago Móvil deja de ser obligatorio.
-- 4. Se reescriben `helios_datos_de_alta`, `helios_crear_clinica`,
--    `helios_solicitar_afiliacion` y `admin_merchant_applications`, y
--    `admin_set_merchant_owner` usa el formato nuevo del documento.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El documento en un solo formato
-- ---------------------------------------------------------------------------

create or replace function public.helios_documento(p_valor text, p_letras text default 'VEJGP')
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v text := upper(regexp_replace(coalesce(p_valor, ''), '[^A-Za-z0-9]', '', 'g'));
  l text := left(v, 1);
  n text := substr(v, 2);
begin
  if v = '' or position(l in upper(p_letras)) = 0 then
    return null;
  end if;
  if l in ('V', 'E') and n ~ '^[0-9]{6,9}$' then
    return public.normalize_document(v);
  elsif l in ('J', 'G') and n ~ '^[0-9]{8,9}$' then
    return public.normalize_tax_id(v);
  elsif l = 'P' and n ~ '^[A-Z0-9]{5,15}$' then
    return v;
  end if;
  return null;
end;
$$;

revoke all on function public.helios_documento(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2 y 3. Las solicitudes guardan la transferencia
-- ---------------------------------------------------------------------------

alter table public.merchant_applications rename column pago_movil_document to holder_document;
alter table public.merchant_applications
  add column account_holder text,
  add column bank           text,
  add column account_number text check (account_number is null or account_number ~ '^[0-9]{20}$'),
  alter column pago_movil_bank  drop not null,
  alter column pago_movil_phone drop not null;

update public.merchant_applications set account_holder = owner_name where account_holder is null;
alter table public.merchant_applications alter column account_holder set not null;

-- ---------------------------------------------------------------------------
-- 4. Los datos del alta
-- ---------------------------------------------------------------------------

/**
 * Valida y normaliza los datos del alta de una clínica. `p` trae:
 * `owner_name`, `owner_document` (V/E/P), `tax_id` (opcional), `specialty`,
 * `college_number` y `mpps_number` (opcionales), `clinic_name`, `address`,
 * `phone`, `email`, y los datos de pago: `account_holder`, `holder_document`
 * (V/E/J/G/P), `bank` + `account_number` (transferencia) y/o
 * `pago_movil_bank` + `pago_movil_phone` (Pago Móvil). Hace falta al menos
 * uno de los dos. Devuelve las mismas claves ya limpias; un dato que no vale
 * levanta 22023 con un mensaje que se puede enseñar tal cual.
 */
create or replace function public.helios_datos_de_alta(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_nombre  text := nullif(btrim(regexp_replace(coalesce(p->>'owner_name', ''), '\s+', ' ', 'g')), '');
  v_doc     text := public.helios_documento(p->>'owner_document', 'VEP');
  v_rif     text;
  v_esp     text := nullif(btrim(coalesce(p->>'specialty', '')), '');
  v_colegio text := nullif(btrim(coalesce(p->>'college_number', '')), '');
  v_mpps    text := nullif(btrim(coalesce(p->>'mpps_number', '')), '');
  v_clinica text := nullif(btrim(regexp_replace(coalesce(p->>'clinic_name', ''), '\s+', ' ', 'g')), '');
  v_dir     text := nullif(btrim(coalesce(p->>'address', '')), '');
  v_tel     text;
  v_correo  text := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  v_titular text := nullif(btrim(regexp_replace(coalesce(p->>'account_holder', ''), '\s+', ' ', 'g')), '');
  v_tit_doc text := public.helios_documento(p->>'holder_document', 'VEJGP');
  v_banco   text := nullif(btrim(coalesce(p->>'bank', '')), '');
  v_cuenta  text := nullif(regexp_replace(coalesce(p->>'account_number', ''), '\D', '', 'g'), '');
  v_pm_bank text := nullif(btrim(coalesce(p->>'pago_movil_bank', '')), '');
  v_pm_raw  text := nullif(btrim(coalesce(p->>'pago_movil_phone', '')), '');
  v_pm_tel  text;
begin
  if v_nombre is null or length(v_nombre) < 3 or length(v_nombre) > 120 then
    raise exception 'Escribe tu nombre completo.' using errcode = '22023';
  end if;
  if v_doc is null then
    raise exception 'La cédula o el pasaporte no parecen válidos: elige V, E o P y escribe solo los números.'
      using errcode = '22023';
  end if;

  if nullif(btrim(coalesce(p->>'tax_id', '')), '') is not null then
    v_rif := public.helios_documento(p->>'tax_id', 'JGVEP');
    if v_rif is null or v_rif !~ '^[JGVEP]-?[0-9]{8,9}$' then
      raise exception 'El RIF no parece válido: elige la letra y escribe sus 8 o 9 números.' using errcode = '22023';
    end if;
    v_rif := public.normalize_tax_id(v_rif);
  end if;

  if v_esp is null or length(v_esp) > 80 then
    raise exception 'Escribe tu especialidad.' using errcode = '22023';
  end if;
  if v_colegio is not null and length(v_colegio) > 30 then
    raise exception 'El número del Colegio o la Federación es demasiado largo.' using errcode = '22023';
  end if;
  if v_mpps is not null and length(v_mpps) > 30 then
    raise exception 'La matrícula o el MPPS es demasiado largo.' using errcode = '22023';
  end if;

  if v_clinica is null or length(v_clinica) < 2 or length(v_clinica) > 120 then
    raise exception 'Escribe el nombre del consultorio o centro médico.' using errcode = '22023';
  end if;
  if v_dir is null or length(v_dir) < 5 or length(v_dir) > 300 then
    raise exception 'Escribe la dirección del consultorio.' using errcode = '22023';
  end if;

  v_tel := public.helios_normalize_ve_phone(p->>'phone');
  if v_tel is null then
    raise exception 'El teléfono no parece venezolano: 0212 5551234 o 0414 1234567.' using errcode = '22023';
  end if;
  if v_correo is null or not public.helios_valid_email(v_correo) then
    raise exception 'El correo no parece un correo.' using errcode = '22023';
  end if;

  -- Los datos de pago
  if v_titular is null or length(v_titular) < 3 or length(v_titular) > 120 then
    raise exception 'Escribe el titular de la cuenta.' using errcode = '22023';
  end if;
  if v_tit_doc is null then
    raise exception 'La cédula o el RIF del titular no parecen válidos: elige la letra y escribe solo los números.'
      using errcode = '22023';
  end if;

  if v_cuenta is not null then
    if v_cuenta !~ '^[0-9]{20}$' then
      raise exception 'El número de cuenta tiene 20 dígitos.' using errcode = '22023';
    end if;
    if v_banco is null or length(v_banco) > 60 then
      raise exception 'Elige el banco de la cuenta.' using errcode = '22023';
    end if;
  else
    v_banco := null;
  end if;

  if v_pm_raw is not null then
    v_pm_tel := public.helios_normalize_ve_mobile(v_pm_raw);
    if v_pm_tel is null then
      raise exception 'El teléfono del Pago Móvil tiene que ser un celular: 0414 1234567.' using errcode = '22023';
    end if;
    if v_pm_bank is null or length(v_pm_bank) > 60 then
      raise exception 'Elige el banco del Pago Móvil.' using errcode = '22023';
    end if;
  else
    v_pm_bank := null;
  end if;

  if v_cuenta is null and v_pm_tel is null then
    raise exception 'Pon los datos de la transferencia.' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'owner_name',       v_nombre,
    'owner_document',   v_doc,
    'tax_id',           v_rif,
    'specialty',        v_esp,
    'college_number',   v_colegio,
    'mpps_number',      v_mpps,
    'clinic_name',      v_clinica,
    'address',          v_dir,
    'phone',            v_tel,
    'email',            v_correo,
    'account_holder',   v_titular,
    'holder_document',  v_tit_doc,
    'bank',             v_banco,
    'account_number',   v_cuenta,
    'pago_movil_bank',  v_pm_bank,
    'pago_movil_phone', v_pm_tel
  );
end;
$$;

/** Crea la clínica con los datos de `helios_datos_de_alta` (y `logo_url`) y su cuenta de pago. Interna. */
create or replace function public.helios_crear_clinica(p jsonb, p_actor uuid)
returns uuid
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  d      jsonb := public.helios_datos_de_alta(p);
  v_id   uuid;
  v_logo text := nullif(btrim(coalesce(p->>'logo_url', '')), '');
begin
  if d->>'tax_id' is not null and exists (select 1 from public.merchants where tax_id = d->>'tax_id') then
    raise exception 'Ya hay una clínica dada de alta con el RIF %', d->>'tax_id' using errcode = '23505';
  end if;

  insert into public.merchants
    (name, tax_id, category, logo_url, specialty, mpps_number, phone, email, address,
     owner_name, owner_document, college_number)
  values (
    d->>'clinic_name', d->>'tax_id', public.helios_categoria_por_especialidad(d->>'specialty'), v_logo,
    d->>'specialty', d->>'mpps_number', d->>'phone', d->>'email', d->>'address',
    d->>'owner_name', d->>'owner_document', d->>'college_number'
  )
  returning id into v_id;

  insert into public.merchant_payout_accounts
    (merchant_id, account_holder, holder_document, bank, account_number,
     pago_movil_phone, pago_movil_bank, updated_by)
  values (
    v_id, d->>'account_holder', d->>'holder_document', d->>'bank', d->>'account_number',
    d->>'pago_movil_phone', d->>'pago_movil_bank', p_actor
  );

  perform audit.log(p_actor, 'merchant.created', v_id, jsonb_build_object(
    'name', d->>'clinic_name', 'tax_id', d->>'tax_id', 'specialty', d->>'specialty',
    'owner_name', d->>'owner_name', 'owner_document', d->>'owner_document',
    'mpps_number', d->>'mpps_number', 'college_number', d->>'college_number'));

  perform audit.log(p_actor, 'merchant.payout_account_set', v_id, jsonb_build_object(
    'antes', null,
    'despues', (select to_jsonb(a) - 'updated_by' - 'updated_at'
                from public.merchant_payout_accounts a where a.merchant_id = v_id)));

  return v_id;
end;
$$;

/**
 * La solicitud de afiliación de la portada (anon). Igual que antes, pero la
 * portada solo pide la TRANSFERENCIA: es obligatoria y cualquier Pago Móvil
 * que llegue se ignora (el equipo puede añadirlo al aprobar).
 */
create or replace function public.helios_solicitar_afiliacion(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d      jsonb;
  v_hdrs jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_ip   text := nullif(btrim(split_part(coalesce(v_hdrs->>'x-forwarded-for', v_hdrs->>'x-real-ip', ''), ',', 1)), '');
begin
  if nullif(btrim(coalesce(p->>'sitio_web', '')), '') is not null then
    return jsonb_build_object('ok', true);
  end if;

  if nullif(regexp_replace(coalesce(p->>'account_number', ''), '\D', '', 'g'), '') is null then
    raise exception 'Pon los datos de la transferencia: banco y número de cuenta.' using errcode = '22023';
  end if;
  d := public.helios_datos_de_alta(p - 'pago_movil_bank' - 'pago_movil_phone');

  if (select count(*) from public.merchant_applications
      where created_at > now() - interval '1 hour') >= 60 then
    raise exception 'Estamos recibiendo muchas solicitudes. Inténtalo de nuevo en un rato.'
      using errcode = '54000';
  end if;

  if v_ip is not null and (select count(*) from public.merchant_applications
      where ip = v_ip and created_at > now() - interval '1 day') >= 5 then
    raise exception 'Ya recibimos varias solicitudes desde esta conexión. Te escribiremos pronto.'
      using errcode = '54000';
  end if;

  if exists (select 1 from public.merchant_applications
             where status = 'pending'
               and (owner_document = d->>'owner_document' or email = d->>'email' or phone = d->>'phone')) then
    raise exception 'Ya tenemos una solicitud tuya en revisión. Te escribiremos pronto.'
      using errcode = '23505';
  end if;

  insert into public.merchant_applications
    (owner_name, owner_document, tax_id, specialty, college_number, mpps_number,
     clinic_name, address, phone, email,
     account_holder, holder_document, bank, account_number,
     ip, user_agent)
  values (
    d->>'owner_name', d->>'owner_document', d->>'tax_id', d->>'specialty', d->>'college_number', d->>'mpps_number',
    d->>'clinic_name', d->>'address', d->>'phone', d->>'email',
    d->>'account_holder', d->>'holder_document', d->>'bank', d->>'account_number',
    v_ip, left(v_hdrs->>'user-agent', 300)
  );

  return jsonb_build_object('ok', true);
end;
$$;

/** Las solicitudes, las más nuevas primero. `p_status` null = todas. Solo el equipo. */
create or replace function public.admin_merchant_applications(p_status text default 'pending')
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',               a.id,
      'status',           a.status,
      'owner_name',       a.owner_name,
      'owner_document',   a.owner_document,
      'tax_id',           a.tax_id,
      'specialty',        a.specialty,
      'college_number',   a.college_number,
      'mpps_number',      a.mpps_number,
      'clinic_name',      a.clinic_name,
      'address',          a.address,
      'phone',            a.phone,
      'email',            a.email,
      'account_holder',   a.account_holder,
      'holder_document',  a.holder_document,
      'bank',             a.bank,
      'account_number',   a.account_number,
      'pago_movil_bank',  a.pago_movil_bank,
      'pago_movil_phone', a.pago_movil_phone,
      'created_at',       a.created_at,
      'merchant_id',      a.merchant_id,
      'reviewed_at',      a.reviewed_at,
      'reviewed_by_name', (select full_name from public.platform_admins where user_id = a.reviewed_by),
      'reject_reason',    a.reject_reason
    ) order by a.created_at desc)
    from public.merchant_applications a
    where p_status is null or a.status = p_status
  ), '[]'::jsonb);
end;
$$;

/** Edita el titular de una clínica (ver 20261009000200), con el documento en el formato de `helios_documento`. */
create or replace function public.admin_set_merchant_owner(p_merchant_id uuid, p jsonb)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('editar clínicas');
  v_nombre text := nullif(btrim(regexp_replace(p->>'owner_name', '\s+', ' ', 'g')), '');
  v_raw    text := btrim(p->>'owner_document');
  v_doc    text;
  v_col    text := btrim(p->>'college_number');
begin
  if v_nombre is not null and (length(v_nombre) < 3 or length(v_nombre) > 120) then
    raise exception 'El nombre del titular no es válido' using errcode = '22023';
  end if;
  if nullif(v_raw, '') is not null then
    v_doc := public.helios_documento(v_raw, 'VEP');
    if v_doc is null then
      raise exception 'La cédula o el pasaporte del titular no parecen válidos' using errcode = '22023';
    end if;
  elsif v_raw = '' then
    v_doc := '';
  end if;
  if v_col is not null and length(v_col) > 30 then
    raise exception 'El número del Colegio es demasiado largo' using errcode = '22023';
  end if;

  update public.merchants
     set owner_name     = coalesce(v_nombre, owner_name),
         owner_document = case when v_doc is null then owner_document else nullif(v_doc, '') end,
         college_number = case when v_col is null then college_number else nullif(v_col, '') end,
         updated_at     = now()
   where id = p_merchant_id;

  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.set_owner', p_merchant_id, jsonb_build_object(
    'owner_name', v_nombre, 'owner_document', v_doc, 'college_number', v_col));
end;
$$;
