-- ============================================================================
-- Helios — El alta pide el título del médico (Dr., Dra., Lcdo., Lcda.)
--
-- Javier, 2026-10-28: el médico elige en la solicitud de la portada cómo lo
-- nombran sus pacientes. Es el mismo `merchants.doctor_title` de la ficha
-- (20261019000300), que va delante de su nombre en los mensajes
-- (`helios_doctor_name`, `helios_doctor_ref`). Opcional: sin título se le
-- nombra solo por su nombre.
--
-- 1. `merchant_applications.doctor_title`, con el mismo check que
--    `merchants`.
-- 2. Se reescriben `helios_datos_de_alta` (valida `doctor_title`),
--    `helios_crear_clinica` (lo guarda en la clínica),
--    `helios_solicitar_afiliacion` (en la solicitud) y
--    `admin_merchant_applications` (lo devuelve). Aprobar ya pasa todas las
--    columnas de la solicitud a `helios_crear_clinica`: no cambia.
-- ============================================================================

alter table public.merchant_applications
  add column doctor_title text
    check (doctor_title is null or doctor_title in ('Dr.', 'Dra.', 'Lcdo.', 'Lcda.'));

comment on column public.merchant_applications.doctor_title is
  'El título que eligió el médico para que lo lean sus pacientes (Dr., Dra., Lcdo., Lcda.). Pasa a merchants.doctor_title al aprobar.';

/**
 * Valida y normaliza los datos del alta de una clínica (ver 20261023130000).
 * Añade `doctor_title`, opcional: 'Dr.', 'Dra.', 'Lcdo.' o 'Lcda.'.
 */
create or replace function public.helios_datos_de_alta(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_nombre  text := nullif(btrim(regexp_replace(coalesce(p->>'owner_name', ''), '\s+', ' ', 'g')), '');
  v_titulo  text := nullif(btrim(coalesce(p->>'doctor_title', '')), '');
  v_doc     text := public.helios_documento(p->>'owner_document', 'VEP');
  v_rif     text;
  v_esp     text := nullif(btrim(coalesce(p->>'specialty', '')), '');
  v_colegio text := nullif(btrim(coalesce(p->>'college_number', '')), '');
  v_mpps    text := nullif(btrim(coalesce(p->>'mpps_number', '')), '');
  v_clinica text := nullif(btrim(regexp_replace(coalesce(p->>'clinic_name', ''), '\s+', ' ', 'g')), '');
  v_dir     text := nullif(btrim(coalesce(p->>'address', '')), '');
  v_tel     text;
  v_correo  text := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  v_red     text := nullif(lower(btrim(coalesce(p->>'social_network', ''))), '');
  v_usuario text := nullif(btrim(regexp_replace(coalesce(p->>'social_user', ''), '\s+', ' ', 'g')), '');
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
  if v_titulo is not null and v_titulo not in ('Dr.', 'Dra.', 'Lcdo.', 'Lcda.') then
    raise exception 'Elige el título de la lista: Dr., Dra., Lcdo. o Lcda.' using errcode = '22023';
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

  -- La red social: opcional, pero la red y el usuario van juntos.
  if v_red is not null and not (v_red = any (public.helios_redes_sociales())) then
    raise exception 'Elige la red social de la lista.' using errcode = '22023';
  end if;
  if v_usuario is not null and v_red is null then
    raise exception 'Elige qué red social es.' using errcode = '22023';
  end if;
  if v_red is not null and v_usuario is null then
    raise exception 'Escribe el usuario o el enlace de la red social.' using errcode = '22023';
  end if;
  if v_usuario is not null and length(v_usuario) > 150 then
    raise exception 'El usuario o el enlace de la red social es demasiado largo.' using errcode = '22023';
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
    'doctor_title',     v_titulo,
    'owner_document',   v_doc,
    'tax_id',           v_rif,
    'specialty',        v_esp,
    'college_number',   v_colegio,
    'mpps_number',      v_mpps,
    'clinic_name',      v_clinica,
    'address',          v_dir,
    'phone',            v_tel,
    'email',            v_correo,
    'social_network',   v_red,
    'social_user',      v_usuario,
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
     owner_name, owner_document, college_number, doctor_title, social_network, social_user)
  values (
    d->>'clinic_name', d->>'tax_id', public.helios_categoria_por_especialidad(d->>'specialty'), v_logo,
    d->>'specialty', d->>'mpps_number', d->>'phone', d->>'email', d->>'address',
    d->>'owner_name', d->>'owner_document', d->>'college_number', d->>'doctor_title',
    d->>'social_network', d->>'social_user'
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
    'doctor_title', d->>'doctor_title',
    'mpps_number', d->>'mpps_number', 'college_number', d->>'college_number',
    'social_network', d->>'social_network', 'social_user', d->>'social_user'));

  perform audit.log(p_actor, 'merchant.payout_account_set', v_id, jsonb_build_object(
    'antes', null,
    'despues', (select to_jsonb(a) - 'updated_by' - 'updated_at'
                from public.merchant_payout_accounts a where a.merchant_id = v_id)));

  return v_id;
end;
$$;

/**
 * La solicitud de afiliación de la portada (anon), ver 20261023140000. Ahora
 * guarda también el título del médico.
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
  v_cap_raw text := nullif(btrim(coalesce(p->>'training_at', '')), '');
  v_cap  timestamptz;
  v_hoy  date := public.helios_business_date(now());
begin
  if nullif(btrim(coalesce(p->>'sitio_web', '')), '') is not null then
    return jsonb_build_object('ok', true);
  end if;

  if nullif(regexp_replace(coalesce(p->>'account_number', ''), '\D', '', 'g'), '') is null then
    raise exception 'Pon los datos de la transferencia: banco y número de cuenta.' using errcode = '22023';
  end if;
  d := public.helios_datos_de_alta(p - 'pago_movil_bank' - 'pago_movil_phone');

  if v_cap_raw is not null then
    begin
      v_cap := v_cap_raw::timestamptz;
    exception when others then
      raise exception 'La fecha de la capacitación no es válida.' using errcode = '22023';
    end;
    if (v_cap at time zone 'America/Caracas')::date <= v_hoy then
      raise exception 'La capacitación tiene que ser de mañana en adelante.' using errcode = '22023';
    end if;
    if (v_cap at time zone 'America/Caracas')::date > v_hoy + 90 then
      raise exception 'La capacitación tiene que ser en los próximos 90 días.' using errcode = '22023';
    end if;
  end if;

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
    (owner_name, doctor_title, owner_document, tax_id, specialty, college_number, mpps_number,
     clinic_name, address, phone, email, social_network, social_user,
     account_holder, holder_document, bank, account_number,
     training_at, ip, user_agent)
  values (
    d->>'owner_name', d->>'doctor_title', d->>'owner_document', d->>'tax_id', d->>'specialty',
    d->>'college_number', d->>'mpps_number',
    d->>'clinic_name', d->>'address', d->>'phone', d->>'email', d->>'social_network', d->>'social_user',
    d->>'account_holder', d->>'holder_document', d->>'bank', d->>'account_number',
    v_cap, v_ip, left(v_hdrs->>'user-agent', 300)
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
      'doctor_title',     a.doctor_title,
      'owner_document',   a.owner_document,
      'tax_id',           a.tax_id,
      'specialty',        a.specialty,
      'college_number',   a.college_number,
      'mpps_number',      a.mpps_number,
      'clinic_name',      a.clinic_name,
      'address',          a.address,
      'phone',            a.phone,
      'email',            a.email,
      'social_network',   a.social_network,
      'social_user',      a.social_user,
      'account_holder',   a.account_holder,
      'holder_document',  a.holder_document,
      'bank',             a.bank,
      'account_number',   a.account_number,
      'pago_movil_bank',  a.pago_movil_bank,
      'pago_movil_phone', a.pago_movil_phone,
      'training_at',      a.training_at,
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
