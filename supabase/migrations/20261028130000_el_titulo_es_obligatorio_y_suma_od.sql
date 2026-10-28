-- ============================================================================
-- Helios — El título del médico es obligatorio en el alta, y suma «Od.»
--
-- Javier, 2026-10-28:
--
-- 1. «Od.» (odontólogo, odontóloga) se suma a Dr., Dra., Lcdo. y Lcda. La
--    lista vive en `helios_titulos_del_medico()`, y la usan los `check` de
--    `merchants` y `merchant_applications`, el alta y la ficha.
-- 2. El alta pide el título (`helios_datos_de_alta`): la solicitud de la
--    portada, el alta del equipo y la aprobación de una solicitud. Una
--    solicitud de antes sin título se aprueba eligiéndolo en la revisión. En
--    la ficha (`admin_set_merchant_owner`) se puede seguir dejando vacío: hay
--    clínicas de antes sin título.
-- 3. `helios_person_name_text` quita también un «Od.» escrito delante del
--    nombre, para que no salga dos veces.
--
-- Con «Od.», `helios_doctor_ref` no pone artículo (no dice si es él o
-- ella): «la consulta con Od. Ana Pérez».
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La lista
-- ---------------------------------------------------------------------------

/** Los títulos que puede llevar el médico delante de su nombre. El mismo que `TITULOS_DEL_MEDICO` en el panel. */
create or replace function public.helios_titulos_del_medico()
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select array['Dr.', 'Dra.', 'Lcdo.', 'Lcda.', 'Od.']
$$;

alter table public.merchants drop constraint merchants_doctor_title_valido;
alter table public.merchants add constraint merchants_doctor_title_valido
  check (doctor_title is null or doctor_title = any (public.helios_titulos_del_medico()));

alter table public.merchant_applications drop constraint merchant_applications_doctor_title_check;
alter table public.merchant_applications add constraint merchant_applications_doctor_title_check
  check (doctor_title is null or doctor_title = any (public.helios_titulos_del_medico()));

comment on column public.merchants.doctor_title is
  'El título delante del nombre del médico en los mensajes a sus pacientes: Dr., Dra., Lcdo., Lcda. u Od. (helios_titulos_del_medico).';

-- ---------------------------------------------------------------------------
-- 2. El alta lo pide
-- ---------------------------------------------------------------------------

/**
 * Valida y normaliza los datos del alta de una clínica (ver 20261028120000).
 * `doctor_title` pasa a ser obligatorio, de `helios_titulos_del_medico()`.
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
  if v_titulo is null then
    raise exception 'Elige cómo te nombran tus pacientes: Dr., Dra., Lcdo., Lcda. u Od.' using errcode = '22023';
  end if;
  if not (v_titulo = any (public.helios_titulos_del_medico())) then
    raise exception 'Elige el título de la lista: Dr., Dra., Lcdo., Lcda. u Od.' using errcode = '22023';
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

-- ---------------------------------------------------------------------------
-- La ficha: el título de la lista, o vacío (ver 20261019000300)
-- ---------------------------------------------------------------------------

-- `p`: las claves que se tocan. Ausente o null = no tocar; '' = borrar (salvo
-- el nombre del titular, que no se borra).
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
  v_titulo text := btrim(p->>'doctor_title');
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
  if v_titulo <> '' and not (v_titulo = any (public.helios_titulos_del_medico())) then
    raise exception 'El título debe ser Dr., Dra., Lcdo., Lcda. u Od.' using errcode = '22023';
  end if;

  update public.merchants
     set owner_name     = coalesce(v_nombre, owner_name),
         owner_document = case when v_doc is null then owner_document else nullif(v_doc, '') end,
         college_number = case when v_col is null then college_number else nullif(v_col, '') end,
         doctor_title   = case when v_titulo is null then doctor_title else nullif(v_titulo, '') end,
         updated_at     = now()
   where id = p_merchant_id;

  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.set_owner', p_merchant_id, jsonb_build_object(
    'owner_name', v_nombre, 'owner_document', v_doc, 'college_number', v_col,
    'doctor_title', v_titulo));
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. El nombre sin un «Od.» escrito delante (ver 20261019000300)
-- ---------------------------------------------------------------------------

create or replace function public.helios_person_name_text(p_name text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select nullif(string_agg(
           case when n > 1 and lower(w) in ('de', 'del', 'la', 'las', 'los', 'y')
                then lower(w) else initcap(w) end,
           ' ' order by n), '')
  from regexp_split_to_table(
         btrim(regexp_replace(regexp_replace(coalesce(p_name, ''),
                                             '^\s*((dra|dr|lcda|lcdo|licda|licdo)\.?|od\.)\s+', '', 'i'),
                              '\s+', ' ', 'g')),
         ' ') with ordinality as t(w, n)
  where w <> '';
$$;

revoke all on function public.helios_person_name_text(text) from public, anon, authenticated;
