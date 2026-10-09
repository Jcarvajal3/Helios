-- ============================================================================
-- Helios — Los médicos piden su alta desde la portada
--
-- El alta de una clínica pasa a pedir los datos del médico titular y el Pago
-- Móvil al que se le paga, y esos mismos datos los puede mandar el médico
-- desde la portada («Quiero afiliarme»). La solicitud queda pendiente hasta
-- que un super admin la aprueba (y entonces nace la clínica) o la rechaza.
--
-- 1. `merchants` gana el titular: `owner_name`, `owner_document` (cédula o
--    pasaporte) y `college_number` (Colegio o Federación). El RIF deja de ser
--    obligatorio en el alta: un médico independiente puede no tenerlo.
-- 2. `helios_datos_de_alta(p)`: valida y normaliza los datos del alta. La
--    usan la solicitud pública y el alta del equipo, así que las dos piden lo
--    mismo y dicen los mismos errores.
-- 3. `helios_crear_clinica(p, actor)`: crea la clínica con su cuenta de Pago
--    Móvil y deja la bitácora. Interna: solo la llaman las RPC de abajo.
-- 4. `admin_create_clinic(p)`: el alta desde el panel (super admin).
-- 5. `merchant_applications` y `helios_solicitar_afiliacion(p)`: la
--    solicitud pública (anon), con freno contra el abuso.
-- 6. `admin_merchant_applications`, `admin_approve_merchant_application`,
--    `admin_reject_merchant_application`: la revisión.
-- 7. `admin_set_merchant_owner(p_merchant_id, p)`: corregir el titular.
-- 8. `admin_merchant_detail` devuelve el titular en `profile`.
--
-- `admin_create_merchant` (heredada) se queda como está: la usan las suites.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El titular de la clínica
-- ---------------------------------------------------------------------------

alter table public.merchants
  add column owner_name     text,
  add column owner_document text,
  add column college_number text;

comment on column public.merchants.owner_name     is 'Nombre completo del médico titular de la clínica o consultorio.';
comment on column public.merchants.owner_document is 'Cédula (V12345678) o pasaporte del médico titular.';
comment on column public.merchants.college_number is 'Número del Colegio o Federación profesional del titular. Opcional.';

-- ---------------------------------------------------------------------------
-- 2. Los datos del alta, validados
-- ---------------------------------------------------------------------------

/** Un teléfono venezolano (fijo o móvil) en E.164, o null. Como `telefonoAE164` del panel. */
create or replace function public.helios_normalize_ve_phone(p_phone text)
returns text
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
declare
  v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if v_digits ~ '^58[0-9]{10}$' then
    v_digits := substr(v_digits, 3);
  elsif v_digits ~ '^0[0-9]{10}$' then
    v_digits := substr(v_digits, 2);
  end if;
  if v_digits !~ '^[0-9]{10}$' then
    return null;
  end if;
  return '+58' || v_digits;
end;
$$;

/**
 * La categoría de una clínica nueva, sacada de su especialidad: el alta ya
 * no la pregunta. Se corrige luego en la ficha si hace falta.
 */
create or replace function public.helios_categoria_por_especialidad(p_specialty text)
returns public.merchant_category
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case
    when lower(coalesce(p_specialty, '')) ~ 'odont|dental|ortodon|endodon|periodon' then 'odontologia'::public.merchant_category
    when lower(coalesce(p_specialty, '')) ~ 'cosmet|est[eé]tic' then 'cosmetologia'::public.merchant_category
    else 'consultorio'::public.merchant_category
  end;
$$;

/**
 * Valida y normaliza los datos del alta de una clínica. `p` trae:
 * `owner_name`, `owner_document`, `tax_id` (opcional), `specialty`,
 * `college_number` (opcional), `mpps_number` (opcional), `clinic_name`,
 * `address`, `phone`, `email`, `pago_movil_bank`, `pago_movil_document` y
 * `pago_movil_phone`. Devuelve las mismas claves ya limpias; un dato que no
 * vale levanta 22023 con un mensaje que se puede enseñar tal cual (lo lee el
 * médico en la portada).
 */
create or replace function public.helios_datos_de_alta(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_texto   text;
  v_nombre  text := nullif(btrim(regexp_replace(coalesce(p->>'owner_name', ''), '\s+', ' ', 'g')), '');
  v_doc     text;
  v_rif     text;
  v_esp     text := nullif(btrim(coalesce(p->>'specialty', '')), '');
  v_colegio text := nullif(btrim(coalesce(p->>'college_number', '')), '');
  v_mpps    text := nullif(btrim(coalesce(p->>'mpps_number', '')), '');
  v_clinica text := nullif(btrim(regexp_replace(coalesce(p->>'clinic_name', ''), '\s+', ' ', 'g')), '');
  v_dir     text := nullif(btrim(coalesce(p->>'address', '')), '');
  v_tel     text;
  v_correo  text := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  v_banco   text := nullif(btrim(coalesce(p->>'pago_movil_bank', '')), '');
  v_pm_doc  text;
  v_pm_tel  text;
begin
  if v_nombre is null or length(v_nombre) < 3 or length(v_nombre) > 120 then
    raise exception 'Escribe tu nombre completo.' using errcode = '22023';
  end if;

  v_texto := upper(regexp_replace(coalesce(p->>'owner_document', ''), '[^A-Za-z0-9]', '', 'g'));
  if v_texto !~ '^([VE]?[0-9]{6,9}|[A-Z0-9]{5,20})$' then
    raise exception 'La cédula o el pasaporte no parecen válidos: V12345678 o el número del pasaporte.'
      using errcode = '22023';
  end if;
  v_doc := public.normalize_document(v_texto);

  -- normalize_tax_id ya explica qué está mal.
  v_rif := public.normalize_tax_id(p->>'tax_id');

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

  if v_banco is null or length(v_banco) > 60 then
    raise exception 'Elige el banco del Pago Móvil.' using errcode = '22023';
  end if;

  -- El Pago Móvil puede estar a nombre del médico (cédula) o de la clínica (RIF).
  v_texto := upper(regexp_replace(coalesce(p->>'pago_movil_document', ''), '[^A-Za-z0-9]', '', 'g'));
  if v_texto ~ '^[JGP][0-9]{8,9}$' then
    v_pm_doc := public.normalize_tax_id(v_texto);
  elsif v_texto ~ '^[VE]?[0-9]{6,9}$' then
    v_pm_doc := public.normalize_document(v_texto);
  else
    raise exception 'La cédula o el RIF del Pago Móvil no parecen válidos: V12345678 o J-123456789.'
      using errcode = '22023';
  end if;

  v_pm_tel := public.helios_normalize_ve_mobile(p->>'pago_movil_phone');
  if v_pm_tel is null then
    raise exception 'El teléfono del Pago Móvil tiene que ser un celular: 0414 1234567.' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'owner_name',          v_nombre,
    'owner_document',      v_doc,
    'tax_id',              v_rif,
    'specialty',           v_esp,
    'college_number',      v_colegio,
    'mpps_number',         v_mpps,
    'clinic_name',         v_clinica,
    'address',             v_dir,
    'phone',               v_tel,
    'email',               v_correo,
    'pago_movil_bank',     v_banco,
    'pago_movil_document', v_pm_doc,
    'pago_movil_phone',    v_pm_tel
  );
end;
$$;

revoke all on function public.helios_normalize_ve_phone(text)         from public, anon, authenticated;
revoke all on function public.helios_categoria_por_especialidad(text) from public, anon, authenticated;
revoke all on function public.helios_datos_de_alta(jsonb)             from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Crear la clínica
-- ---------------------------------------------------------------------------

/**
 * Crea la clínica con los datos de `helios_datos_de_alta` (más `logo_url`
 * opcional) y su cuenta de Pago Móvil. El titular de la cuenta es el médico
 * si el Pago Móvil va con cédula, o la clínica si va con RIF. Devuelve el id.
 * Interna: quien la llama ya comprobó los permisos.
 */
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
    (merchant_id, account_holder, holder_document, pago_movil_phone, pago_movil_bank, updated_by)
  values (
    v_id,
    case when d->>'pago_movil_document' ~ '^[JGP]' then d->>'clinic_name' else d->>'owner_name' end,
    d->>'pago_movil_document', d->>'pago_movil_phone', d->>'pago_movil_bank', p_actor
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

revoke all on function public.helios_crear_clinica(jsonb, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. El alta desde el panel
-- ---------------------------------------------------------------------------

/** Da de alta una clínica con los datos de `helios_datos_de_alta`. Solo super admin. */
create or replace function public.admin_create_clinic(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.helios_assert_super_admin('dar de alta clínicas');
begin
  return jsonb_build_object('merchant_id', public.helios_crear_clinica(p, v_actor));
end;
$$;

revoke all on function public.admin_create_clinic(jsonb) from public, anon;
grant execute on function public.admin_create_clinic(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. La solicitud desde la portada
-- ---------------------------------------------------------------------------

create table public.merchant_applications (
  id                  uuid primary key default gen_random_uuid(),
  status              text not null default 'pending'
                      check (status in ('pending', 'approved', 'rejected')),
  owner_name          text not null,
  owner_document      text not null,
  tax_id              text,
  specialty           text not null,
  college_number      text,
  mpps_number         text,
  clinic_name         text not null,
  address             text not null,
  phone               text not null,
  email               text not null,
  pago_movil_bank     text not null,
  pago_movil_document text not null,
  pago_movil_phone    text not null,
  -- Para frenar el abuso, no se enseñan.
  ip                  text,
  user_agent          text,
  created_at          timestamptz not null default now(),
  merchant_id         uuid references public.merchants(id),
  reviewed_by         uuid references auth.users(id),
  reviewed_at         timestamptz,
  reject_reason       text,
  constraint merchant_applications_aprobada_con_clinica
    check (status <> 'approved' or merchant_id is not null),
  constraint merchant_applications_rechazada_con_motivo
    check (status <> 'rejected' or nullif(btrim(reject_reason), '') is not null)
);

comment on table public.merchant_applications is
  'Solicitudes de afiliación que mandan los médicos desde la portada. Las aprueba o rechaza un super admin; al aprobar nace la clínica (merchant_id).';

create index merchant_applications_pendientes on public.merchant_applications (created_at desc)
  where status = 'pending';
create index merchant_applications_por_ip on public.merchant_applications (ip, created_at);

alter table public.merchant_applications enable row level security;
revoke all on public.merchant_applications from anon, authenticated;

/**
 * La solicitud de afiliación de la portada. Abierta a anon. `p` trae los
 * datos de `helios_datos_de_alta` y `sitio_web`, un campo que la portada
 * esconde: si llega con algo, lo rellenó un robot y se contesta que sí sin
 * guardar nada. Frenos: una solicitud pendiente por cédula, correo o
 * teléfono; cinco al día por IP; sesenta por hora en total.
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

  d := public.helios_datos_de_alta(p);

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
     clinic_name, address, phone, email, pago_movil_bank, pago_movil_document, pago_movil_phone,
     ip, user_agent)
  values (
    d->>'owner_name', d->>'owner_document', d->>'tax_id', d->>'specialty', d->>'college_number', d->>'mpps_number',
    d->>'clinic_name', d->>'address', d->>'phone', d->>'email',
    d->>'pago_movil_bank', d->>'pago_movil_document', d->>'pago_movil_phone',
    v_ip, left(v_hdrs->>'user-agent', 300)
  );

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.helios_solicitar_afiliacion(jsonb) from public;
grant execute on function public.helios_solicitar_afiliacion(jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. La revisión
-- ---------------------------------------------------------------------------

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
      'id',                  a.id,
      'status',              a.status,
      'owner_name',          a.owner_name,
      'owner_document',      a.owner_document,
      'tax_id',              a.tax_id,
      'specialty',           a.specialty,
      'college_number',      a.college_number,
      'mpps_number',         a.mpps_number,
      'clinic_name',         a.clinic_name,
      'address',             a.address,
      'phone',               a.phone,
      'email',               a.email,
      'pago_movil_bank',     a.pago_movil_bank,
      'pago_movil_document', a.pago_movil_document,
      'pago_movil_phone',    a.pago_movil_phone,
      'created_at',          a.created_at,
      'merchant_id',         a.merchant_id,
      'reviewed_at',         a.reviewed_at,
      'reviewed_by_name',    (select full_name from public.platform_admins where user_id = a.reviewed_by),
      'reject_reason',       a.reject_reason
    ) order by a.created_at desc)
    from public.merchant_applications a
    where p_status is null or a.status = p_status
  ), '[]'::jsonb);
end;
$$;

/**
 * Aprueba una solicitud pendiente: nace la clínica. `p` (opcional) trae los
 * datos corregidos por el equipo, con las mismas claves (más `logo_url`);
 * sin él, se usan los de la solicitud. Solo super admin.
 */
create or replace function public.admin_approve_merchant_application(p_id uuid, p jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := public.helios_assert_super_admin('aprobar solicitudes de afiliación');
  v_app   public.merchant_applications%rowtype;
  v_datos jsonb;
  v_id    uuid;
begin
  select * into v_app from public.merchant_applications where id = p_id for update;
  if not found then
    raise exception 'Solicitud no encontrada' using errcode = 'P0002';
  end if;
  if v_app.status <> 'pending' then
    raise exception 'Esa solicitud ya se revisó' using errcode = '22023';
  end if;

  v_datos := (to_jsonb(v_app) - 'id' - 'status' - 'ip' - 'user_agent' - 'created_at'
              - 'merchant_id' - 'reviewed_by' - 'reviewed_at' - 'reject_reason')
             || coalesce(p, '{}'::jsonb);

  v_id := public.helios_crear_clinica(v_datos, v_actor);

  update public.merchant_applications
     set status = 'approved', merchant_id = v_id, reviewed_by = v_actor, reviewed_at = now()
   where id = p_id;

  perform audit.log(v_actor, 'merchant_application.approved', v_id,
    jsonb_build_object('application_id', p_id, 'name', v_datos->>'clinic_name'));

  return jsonb_build_object('merchant_id', v_id);
end;
$$;

/** Rechaza una solicitud pendiente, con su motivo (interno). Solo super admin. */
create or replace function public.admin_reject_merchant_application(p_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('rechazar solicitudes de afiliación');
  v_motivo text := nullif(btrim(coalesce(p_reason, '')), '');
  v_app    public.merchant_applications%rowtype;
begin
  if v_motivo is null then
    raise exception 'Escribe el motivo del rechazo' using errcode = '22023';
  end if;

  select * into v_app from public.merchant_applications where id = p_id for update;
  if not found then
    raise exception 'Solicitud no encontrada' using errcode = 'P0002';
  end if;
  if v_app.status <> 'pending' then
    raise exception 'Esa solicitud ya se revisó' using errcode = '22023';
  end if;

  update public.merchant_applications
     set status = 'rejected', reject_reason = v_motivo, reviewed_by = v_actor, reviewed_at = now()
   where id = p_id;

  perform audit.log(v_actor, 'merchant_application.rejected', p_id,
    jsonb_build_object('name', v_app.clinic_name, 'owner_name', v_app.owner_name, 'motivo', v_motivo));
end;
$$;

revoke all on function public.admin_merchant_applications(text)                from public, anon;
revoke all on function public.admin_approve_merchant_application(uuid, jsonb)  from public, anon;
revoke all on function public.admin_reject_merchant_application(uuid, text)    from public, anon;
grant execute on function public.admin_merchant_applications(text)               to authenticated;
grant execute on function public.admin_approve_merchant_application(uuid, jsonb) to authenticated;
grant execute on function public.admin_reject_merchant_application(uuid, text)   to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Corregir el titular
-- ---------------------------------------------------------------------------

/**
 * Edita el titular de una clínica: `owner_name`, `owner_document`,
 * `college_number`. Como en `admin_set_merchant_profile`, una clave ausente o
 * null = no tocar y '' = borrar (salvo el nombre: vacío lo deja como está).
 */
create or replace function public.admin_set_merchant_owner(p_merchant_id uuid, p jsonb)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('editar clínicas');
  v_nombre text := nullif(btrim(regexp_replace(p->>'owner_name', '\s+', ' ', 'g')), '');
  v_doc    text := upper(regexp_replace(p->>'owner_document', '[^A-Za-z0-9]', '', 'g'));
  v_col    text := btrim(p->>'college_number');
begin
  if v_nombre is not null and (length(v_nombre) < 3 or length(v_nombre) > 120) then
    raise exception 'El nombre del titular no es válido' using errcode = '22023';
  end if;
  if nullif(v_doc, '') is not null then
    if v_doc !~ '^([VE]?[0-9]{6,9}|[A-Z0-9]{5,20})$' then
      raise exception 'La cédula o el pasaporte del titular no parecen válidos' using errcode = '22023';
    end if;
    v_doc := public.normalize_document(v_doc);
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

revoke all on function public.admin_set_merchant_owner(uuid, jsonb) from public, anon;
grant execute on function public.admin_set_merchant_owner(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. La ficha devuelve el titular
-- ---------------------------------------------------------------------------
-- Copia de la definición viva (pg_get_functiondef, 2026-10-09) con las tres
-- claves nuevas en `profile`, marcadas NUEVO.

create or replace function public.admin_merchant_detail(p_merchant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_merchant public.merchants%rowtype;
  v_terms    public.merchant_settlement_terms%rowtype;
  v_staff    jsonb;
  v_owed     numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_merchant from public.merchants where id = p_merchant_id;
  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  select * into v_terms from public.merchant_settlement_terms
  where merchant_id = p_merchant_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', mu.user_id,
    'name', coalesce(nullif(trim(au.raw_user_meta_data ->> 'full_name'), ''), au.email),
    'email', au.email,
    'phone', au.phone,
    'role', mu.role,
    'branch', b.name
  ) order by mu.created_at), '[]'::jsonb) into v_staff
  from public.merchant_users mu
  join auth.users au on au.id = mu.user_id
  left join public.merchant_branches b on b.id = mu.branch_id
  where mu.merchant_id = p_merchant_id and mu.is_active;

  -- La misma cuenta que el guardia de `terminated`: es la cifra que la ficha
  -- enseña como «Le debes X» y la que decide si el botón de Terminar está vivo.
  select coalesce(sum(amount_usd - paid_usd), 0) into v_owed
  from public.settlements
  where merchant_id = p_merchant_id and status in ('pending', 'partial');

  return jsonb_build_object(
    'profile', jsonb_build_object(
      'category', v_merchant.category,
      'city', v_merchant.city,
      'handle', v_merchant.handle,
      'logo_url', v_merchant.logo_url,
      'social_url', v_merchant.social_url,
      'tax_id', v_merchant.tax_id,
      'specialty', v_merchant.specialty,
      'mpps_number', v_merchant.mpps_number,
      'phone', v_merchant.phone,
      'email', v_merchant.email,
      'address', v_merchant.address,
      -- NUEVO (2026-10-09): el titular.
      'owner_name', v_merchant.owner_name,
      'owner_document', v_merchant.owner_document,
      'college_number', v_merchant.college_number
    ),
    'terms', jsonb_build_object(
      'upfront_pct', v_terms.upfront_pct,
      'per_installment_pct', v_terms.per_installment_pct,
      'commission_pct', v_terms.commission_pct,
      'policy', v_terms.policy,
      -- Helios: la comisión pactada (null = la global) y la que se aplica hoy.
      'staff_commission_usd', (select t.staff_commission_usd
                                 from public.helios_terms_at(p_merchant_id, public.helios_business_date(now())) t),
      'staff_commission_effective_usd', public.helios_staff_commission_for(p_merchant_id, public.helios_business_date(now()))
    ),
    'staff', v_staff,
    'pending_usd', v_owed,
    'payout_account', public.admin_merchant_payout_account(p_merchant_id)
  );
end;
$$;
