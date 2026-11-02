-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — Lo que puede hacer el capacitador
--
-- El rol `capacitador` (20261102130000) entra a superadmin › Agenda y a
-- superadmin › Clínicas.
--
-- 1. `is_platform_admin()` lo deja fuera, como al rol de la agenda: no lee
--    pacientes, pagos, el libro ni la bitácora.
-- 2. La agenda: `helios_puede_usar_la_agenda()` lo incluye.
-- 3. Ver las clínicas: `helios_puede_ver_clinicas()` (super admin, operador
--    o capacitador) pasa a ser la guardia de la lectura de `merchants` (y
--    con ella de `merchant_directory`), de las solicitudes y de la ficha de
--    una clínica. La ficha, al capacitador, le llega sin dinero: sin
--    condiciones, sin lo que se le debe y sin su cuenta de cobro.
-- 4. Afiliar: `helios_assert_puede_afiliar()` (super admin o capacitador,
--    con el segundo factor si se exige) sustituye a
--    `helios_assert_super_admin()` en el alta, en aprobar y rechazar
--    solicitudes, y en el número del bot y su bienvenida.
-- 5. El acceso del titular: `merchant_staff_add` y
--    `merchant_staff_send_welcome` dejan pasar al capacitador, pero solo
--    para el primer acceso de una clínica (sin personal activo). Lo demás del
--    personal (cambiar, quitar, contraseñas) sigue siendo del equipo y del
--    administrador de la clínica. Y el número del bot solo lo registra para
--    quien recibió su acceso hace menos de un día.
--
-- Los cuerpos de las funciones salen tal cual de la base, con solo esas
-- sustituciones.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 2 y 3. Las guardias
-- ---------------------------------------------------------------------------

/** La agenda: los cuatro roles. */
create or replace function public.helios_puede_usar_la_agenda()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.helios_es_del_equipo(array['super_admin', 'operador', 'agenda', 'capacitador']::public.platform_role[]);
$$;

comment on function public.helios_puede_usar_la_agenda() is
  'Agenda: si quien llama puede usarla (super admin, operador, el rol agenda o el capacitador), con el segundo factor si se exige.';

/** Las clínicas y sus solicitudes, para leer: el superadmin y el capacitador. */
create or replace function public.helios_puede_ver_clinicas()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.helios_es_del_equipo(array['super_admin', 'operador', 'capacitador']::public.platform_role[]);
$$;

comment on function public.helios_puede_ver_clinicas() is
  'Clínicas: si quien llama puede leerlas (super admin, operador o capacitador), con el segundo factor si se exige.';

revoke all on function public.helios_puede_ver_clinicas() from public, anon;
grant execute on function public.helios_puede_ver_clinicas() to authenticated;

/**
 * Afiliar médicos (el alta, las solicitudes, el acceso del titular): un super
 * admin o un capacitador. Devuelve quién llama, como
 * `helios_assert_super_admin()`.
 */
create or replace function public.helios_assert_puede_afiliar(p_what text)
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role in ('super_admin', 'capacitador')
  ) then
    raise exception 'Solo un super admin o un capacitador puede %', p_what using errcode = '42501';
  end if;

  -- Ya se sabe que la cuenta vale: un false solo puede ser la sesión sin el
  -- segundo factor, cuando se exige.
  if not public.helios_es_del_equipo(array['super_admin', 'capacitador']::public.platform_role[]) then
    raise exception 'Para % hace falta entrar con el segundo factor. Vuelve a iniciar sesión.', p_what
      using errcode = '42501';
  end if;

  return v_actor;
end;
$$;

revoke all on function public.helios_assert_puede_afiliar(text) from public, anon, authenticated;

/**
 * El acceso del titular. Al capacitador le deja dar el primer acceso de una
 * clínica (`p_user_id` null, sin personal activo) y mandar la bienvenida de
 * una cuenta que no es del equipo; a los demás, lo de siempre
 * (`helios_assert_staff_manager`).
 */
create or replace function public.helios_assert_alta_de_personal(p_merchant_id uuid, p_user_id uuid default null)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_admin()
     and public.helios_es_del_equipo(array['capacitador']::public.platform_role[]) then
    if p_user_id is null then
      if exists (select 1 from public.merchant_users
                 where merchant_id = p_merchant_id and is_active) then
        raise exception 'Esta clínica ya tiene su acceso: su personal lo maneja su administrador o un super admin'
          using errcode = '42501';
      end if;
    elsif exists (select 1 from public.platform_admins where user_id = p_user_id and is_active) then
      raise exception 'Esa cuenta es del equipo de Helios: solo ellos pueden cambiarla'
        using errcode = '42501';
    end if;
    return;
  end if;

  perform public.helios_assert_staff_manager(p_merchant_id, p_user_id);
end;
$$;

revoke all on function public.helios_assert_alta_de_personal(uuid, uuid) from public, anon, authenticated;

alter policy merchants_read_admin on public.merchants
  using ((select public.helios_puede_ver_clinicas()));

-- ---------------------------------------------------------------------------
-- 3. Las solicitudes y la ficha de una clínica
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_merchant_applications(p_status text DEFAULT 'pending'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.helios_puede_ver_clinicas() then
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
$function$;

CREATE OR REPLACE FUNCTION public.admin_merchant_detail(p_merchant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_merchant public.merchants%rowtype;
  v_terms    public.merchant_settlement_terms%rowtype;
  v_staff    jsonb;
  v_owed     numeric(18,4);
  -- NUEVO (20261102130100): el capacitador ve el perfil, no el dinero.
  v_dinero   boolean := public.is_platform_admin();
begin
  if not public.helios_puede_ver_clinicas() then
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
      -- NUEVO (20261029190000): el nombre del consultorio.
      'consultorio', v_merchant.consultorio,
      -- (2026-10-09): el titular.
      'owner_name', v_merchant.owner_name,
      'owner_document', v_merchant.owner_document,
      'college_number', v_merchant.college_number,
      -- (2026-10-19): su título y cómo lo leen sus pacientes.
      'doctor_title', v_merchant.doctor_title,
      'doctor_name', public.helios_doctor_name(v_merchant.id)
    ),
    'terms', case when v_dinero then jsonb_build_object(
      'upfront_pct', v_terms.upfront_pct,
      'per_installment_pct', v_terms.per_installment_pct,
      'commission_pct', v_terms.commission_pct,
      'policy', v_terms.policy,
      -- Helios: la comisión pactada (null = la global) y la que se aplica hoy.
      'staff_commission_usd', (select t.staff_commission_usd
                                 from public.helios_terms_at(p_merchant_id, public.helios_business_date(now())) t),
      'staff_commission_effective_usd', public.helios_staff_commission_for(p_merchant_id, public.helios_business_date(now()))
    ) end,
    'staff', v_staff,
    'pending_usd', case when v_dinero then v_owed end,
    'payout_account', case when v_dinero then public.admin_merchant_payout_account(p_merchant_id) end
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Afiliar
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_create_clinic(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := public.helios_assert_puede_afiliar('dar de alta clínicas');
begin
  return jsonb_build_object('merchant_id', public.helios_crear_clinica(p, v_actor));
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_approve_merchant_application(p_id uuid, p jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := public.helios_assert_puede_afiliar('aprobar solicitudes de afiliación');
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
$function$;

CREATE OR REPLACE FUNCTION public.admin_reject_merchant_application(p_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor  uuid := public.helios_assert_puede_afiliar('rechazar solicitudes de afiliación');
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
$function$;

CREATE OR REPLACE FUNCTION public.admin_send_staff_whatsapp_welcome(p_merchant_id uuid, p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor   uuid := public.helios_assert_puede_afiliar('mandar la bienvenida por WhatsApp');
  v_phone   text;
  v_nombre  text;
  v_correo  text;
  v_clinica text;
  v_t       public.notification_templates%rowtype;
  v_texto   text;
  v_params  jsonb;
  v_via     text;
  v_dedupe  text := format('bienvenida_medico:%s:%s', p_merchant_id, p_user_id);
  v_id      uuid;
begin
  if not exists (select 1 from public.merchant_users
                 where merchant_id = p_merchant_id and user_id = p_user_id and is_active) then
    raise exception 'Esa persona no es personal de esta clínica' using errcode = 'P0002';
  end if;

  select n.phone_e164 into v_phone from public.staff_whatsapp_numbers n
  where n.user_id = p_user_id and n.merchant_id = p_merchant_id and n.revoked_at is null;
  if v_phone is null then
    return jsonb_build_object('status', 'sin_numero');
  end if;

  if exists (select 1 from public.outbound_messages where dedupe_key = v_dedupe) then
    return jsonb_build_object('status', 'ya_enviado', 'phone', v_phone);
  end if;

  select coalesce(nullif(btrim(au.raw_user_meta_data->>'full_name'), ''), 'doctor'), au.email
    into v_nombre, v_correo
  from auth.users au where au.id = p_user_id;
  select m.name into v_clinica from public.merchants m where m.id = p_merchant_id;

  v_texto := format(
    E'¡Hola, %s! 👋 Te damos la bienvenida a Helios 💙\n\n'
    'Tu cuenta en %s ya está activa ✅ Te enviamos tus datos de acceso al panel a %s.\n\n'
    'Si lo prefieres, también puedes registrar los pagos en cuotas de tus pacientes desde este mismo chat, sin entrar al panel. Toca «Empezar» y te guío paso a paso 🙌\n\n'
    'Cualquier duda, escríbenos por aquí. ¡Estamos para ayudarte!',
    v_nombre, v_clinica, v_correo);

  if public.helios_whatsapp_window_open(v_phone) then
    v_via := 'texto';
    insert into public.outbound_messages (
      channel, template_key, profile_id, recipient_staff_id, recipient,
      subject, rendered_text, status, next_attempt_at, wa_template, dedupe_key
    ) values (
      'whatsapp', 'bienvenida_medico', null, p_user_id, v_phone,
      'Helios', v_texto, 'pendiente', now(),
      jsonb_build_object('name', null, 'language', 'es', 'params', '[]'::jsonb,
                         'buttons', jsonb_build_array(jsonb_build_object('id', 'menu:empezar', 'title', 'Empezar'))),
      v_dedupe
    ) returning id into v_id;
  else
    select * into v_t from public.notification_templates where key = 'bienvenida_medico' and enabled;
    if nullif(btrim(v_t.wa_template_name), '') is null then
      return jsonb_build_object('status', 'sin_plantilla', 'phone', v_phone);
    end if;

    select coalesce(jsonb_agg(case p
             when 'nombre'  then v_nombre
             when 'clinica' then v_clinica
             when 'correo'  then v_correo
             else '' end order by i), '[]'::jsonb)
      into v_params
    from unnest(coalesce(v_t.wa_template_params, array['nombre'])) with ordinality as x(p, i);

    v_via := 'plantilla';
    insert into public.outbound_messages (
      channel, template_key, profile_id, recipient_staff_id, recipient,
      subject, rendered_text, status, next_attempt_at, wa_template, dedupe_key
    ) values (
      'whatsapp', 'bienvenida_medico', null, p_user_id, v_phone,
      'Helios', v_texto, 'pendiente', now(),
      jsonb_build_object('name', btrim(v_t.wa_template_name), 'language', coalesce(v_t.wa_template_lang, 'es'),
                         'params', v_params, 'buttons', '[]'::jsonb),
      v_dedupe
    ) returning id into v_id;
  end if;

  perform audit.log(v_actor, 'merchant.staff_whatsapp_welcome', p_merchant_id, jsonb_build_object(
    'user_id', p_user_id, 'phone_e164', v_phone, 'via', v_via, 'message_id', v_id));

  return jsonb_build_object('status', 'en_cola', 'via', v_via, 'phone', v_phone);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_staff_whatsapp(p_user_id uuid, p_merchant_id uuid, p_phone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_me    uuid := public.helios_assert_puede_afiliar('registrar números del bot');
  v_phone text := public.helios_normalize_ve_mobile(p_phone);
  v_otro  public.staff_whatsapp_numbers%rowtype;
  v_row   public.staff_whatsapp_numbers%rowtype;
begin

  if not exists (
    select 1 from public.merchant_users mu
    where mu.user_id = p_user_id and mu.merchant_id = p_merchant_id and mu.is_active
      and mu.role in ('gerente', 'cajero')
  ) then
    raise exception 'Esa persona no es personal activo de esa clínica' using errcode = '22023';
  end if;

  -- NUEVO (20261102130100): el capacitador registra el número al dar el
  -- acceso, no después.
  if not exists (select 1 from public.platform_admins
                 where user_id = v_me and is_active and role = 'super_admin')
     and not exists (
       select 1 from public.merchant_users mu
       where mu.user_id = p_user_id and mu.merchant_id = p_merchant_id and mu.is_active
         and mu.created_at > now() - interval '1 day'
     ) then
    raise exception 'El número del bot de alguien que ya tenía acceso lo registra un super admin'
      using errcode = '42501';
  end if;

  if v_phone is null then
    raise exception 'Teléfono móvil inválido' using errcode = '22023';
  end if;

  select * into v_otro from public.staff_whatsapp_numbers
  where phone_e164 = v_phone and revoked_at is null;
  if found then
    if v_otro.user_id = p_user_id and v_otro.merchant_id = p_merchant_id then
      return public.helios_staff_whatsapp_row(v_otro);
    end if;
    raise exception 'Ese número ya está registrado para %', coalesce(public.helios_staff_name(v_otro.user_id), 'otra persona')
      using errcode = '22023';
  end if;

  update public.staff_whatsapp_numbers
     set revoked_at = now(), revoked_by = v_me, revoke_reason = 'Cambio de número'
   where user_id = p_user_id and revoked_at is null;

  insert into public.staff_whatsapp_numbers (phone_e164, user_id, merchant_id, created_by)
  values (v_phone, p_user_id, p_merchant_id, v_me)
  returning * into v_row;

  perform audit.log(v_me, 'staff.whatsapp_set', p_user_id, jsonb_build_object(
    'merchant_id', p_merchant_id, 'phone_e164', v_phone, 'number_id', v_row.id));

  return public.helios_staff_whatsapp_row(v_row);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 5. El acceso del titular
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.merchant_staff_add(p_merchant_id uuid, p_email text, p_password text, p_full_name text, p_role merchant_role, p_branch_id uuid DEFAULT NULL::uuid, p_solo_registra boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor  uuid := auth.uid();
  v_user   uuid;
  v_branch uuid;
  v_solo   boolean := p_role = 'cajero' and coalesce(p_solo_registra, false);
begin
  perform public.helios_assert_alta_de_personal(p_merchant_id);

  -- Helios (H8): el rol «inventario» era del catálogo de productos, que no
  -- existe. Queda en el enum por las filas viejas, pero no se asigna.
  if p_role = 'inventario' then
    raise exception 'El rol inventario no existe en Helios: elige administrador o secretaria'
      using errcode = '22023';
  end if;

  v_user   := public.admin_create_auth_account(p_email, p_password, p_full_name);
  v_branch := public.helios_branch_for_role(p_merchant_id, p_role, p_branch_id);

  insert into public.merchant_users (user_id, merchant_id, branch_id, role, solo_registra)
  values (v_user, p_merchant_id, v_branch, p_role, v_solo)
  on conflict (user_id, merchant_id, branch_id) do update
    set role = excluded.role, is_active = true, solo_registra = excluded.solo_registra;

  perform audit.log(v_actor, 'merchant.staff_added', p_merchant_id,
    jsonb_build_object(
      'user_id',       v_user,
      'email',         lower(trim(p_email)),
      'role',          p_role,
      'solo_registra', v_solo
    ));

  return jsonb_build_object('ok', true, 'user_id', v_user, 'branch_id', v_branch);
end;
$function$;

CREATE OR REPLACE FUNCTION public.merchant_staff_send_welcome(p_merchant_id uuid, p_user_id uuid, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'extensions', 'pg_temp'
AS $function$
declare
  v_actor   uuid := auth.uid();
  v_hash    text;
  v_key     text;
  v_from    text;
  v_copia   text;
  v_correo  jsonb;
  v_body    jsonb;
  v_resp    jsonb;
  v_status  text;
  v_error   text;
begin
  perform public.helios_assert_alta_de_personal(p_merchant_id, p_user_id);

  if not exists (select 1 from public.merchant_users
                 where merchant_id = p_merchant_id and user_id = p_user_id and is_active) then
    raise exception 'Esa persona no es personal de esta clínica' using errcode = 'P0002';
  end if;

  select encrypted_password into v_hash from auth.users where id = p_user_id;
  if v_hash is null or p_password is null or extensions.crypt(p_password, v_hash) <> v_hash then
    raise exception 'Esa no es la contraseña de la cuenta' using errcode = '22023';
  end if;

  v_correo := public.helios_staff_welcome_email(p_merchant_id, p_user_id, p_password);
  v_key    := public.helios_resend_api_key();
  v_from   := public.helios_email_sender();
  select nullif(btrim(staff_welcome_copy), '') into v_copia from public.platform_contact where id;

  if v_correo->>'to' is null then
    v_status := 'fallido';
    v_error  := 'La cuenta no tiene correo';
  elsif v_key is null or v_from is null then
    v_status := 'sin_configurar';
  else
    v_body := jsonb_build_object(
      'from', v_from,
      'to', jsonb_build_array(v_correo->>'to'),
      'subject', v_correo->>'subject',
      'text', v_correo->>'text',
      'html', v_correo->>'html');
    if v_copia is not null and lower(v_copia) <> lower(v_correo->>'to') then
      v_body := v_body || jsonb_build_object('bcc', jsonb_build_array(v_copia));
    end if;

    begin
      v_resp := public.helios_resend_request('POST', '/emails', v_key, v_body, gen_random_uuid()::text);
      if (v_resp->>'status')::int between 200 and 299 then
        v_status := 'enviado';
      else
        v_status := 'fallido';
        v_error  := format('Resend respondió %s', v_resp->>'status');
      end if;
    exception when others then
      v_status := 'fallido';
      v_error  := 'Sin respuesta del servicio de correo';
    end;
  end if;

  perform audit.log(v_actor, 'merchant.staff_welcome_sent', p_merchant_id, jsonb_build_object(
    'user_id', p_user_id, 'email', v_correo->>'to', 'copia', v_copia, 'status', v_status, 'error', v_error));

  return jsonb_build_object('status', v_status, 'error', v_error);
end;
$function$;
