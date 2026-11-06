-- ============================================================================
-- Helios — El rol capacitador (20261102130100)
--
--   bash supabase/tests/run.sh capacitador_smoke
--
-- Se comprueba que el capacitador:
--   1. Usa la agenda, pero `is_platform_admin()` le dice que no: no lee
--      pacientes ni pagos.
--   2. Lee las clínicas (`merchant_directory`, todas, también las de prueba)
--      y las solicitudes.
--   3. Da de alta una clínica y, para su titular, el primer acceso, la
--      bienvenida y el número del bot.
--   4. No da un segundo acceso a una clínica que ya lo tiene, ni registra el
--      número del bot de alguien que ya tenía su acceso.
--   5. Ve el perfil de una clínica sin su dinero (condiciones, lo que se le
--      debe, su cuenta de cobro); el super admin sí lo ve.
--   6. Aprueba y rechaza solicitudes.
--   7. Corrige el perfil y el titular (20261102230000), y sube el logo; no
--      cambia la contraseña del titular. El operador no edita el perfil.
--   8. El rol de la agenda no lee clínicas ni afilia.
--
-- No manda nada: `_ayudas.sql` apaga las cuentas de envío y la bienvenida
-- por WhatsApp queda en la cola (sin despachar).
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin    uuid;
  v_cap      uuid := gen_random_uuid();
  v_agenda   uuid := gen_random_uuid();
  v_op       uuid := gen_random_uuid();
  v_merchant uuid;
  v_titular  uuid;
  v_app      uuid;
  v_app2     uuid;
  v_res      jsonb;
  v_fallo    boolean;
  v_alta     jsonb := jsonb_build_object(
    'owner_name', 'Carla Capacitada',
    'doctor_title', 'Dra.',
    'owner_document', 'V19876501',
    'specialty', 'Dermatología',
    'clinic_name', 'Consultorio Capacitador',
    'address', 'Av. Libertador, Torre Prueba, piso 2',
    'phone', '0212 555 7001',
    'email', 'carla.capacitador@example.com',
    'account_holder', 'Carla Capacitada',
    'holder_document', 'V19876501',
    'bank', 'Banesco',
    'account_number', '0134 0000 0000 0000 0701');
begin
  v_admin := pg_temp.prueba_admin();
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  values
    (v_cap, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'capacitador-' || v_cap || '@prueba.helios.test', now(), now()),
    (v_agenda, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'agenda-' || v_agenda || '@prueba.helios.test', now(), now()),
    (v_op, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'operador-' || v_op || '@prueba.helios.test', now(), now());
  insert into public.platform_admins (user_id, role, full_name, is_active) values
    (v_op, 'operador', 'Operador de Prueba', true),
    (v_cap, 'capacitador', 'Capacitador de Prueba', true),
    (v_agenda, 'agenda', 'Agenda de Prueba', true);

  -- Dos solicitudes pendientes, como si llegaran por la portada.
  insert into public.merchant_applications
    (owner_name, doctor_title, owner_document, specialty, clinic_name, address, phone, email,
     account_holder, holder_document, bank, account_number)
  values ('Pedro Solicitud', 'Dr.', 'V19876502', 'Odontología', 'Dental Solicitud', 'Calle 3, local 4',
          '+582125557002', 'pedro.solicitud@example.com', 'Pedro Solicitud', 'V19876502', 'Banesco',
          '01340000000000000702')
  returning id into v_app;
  insert into public.merchant_applications
    (owner_name, doctor_title, owner_document, specialty, clinic_name, address, phone, email,
     account_holder, holder_document, bank, account_number)
  values ('Luisa Rechazo', 'Dra.', 'V19876503', 'Cosmetología', 'Estética Rechazo', 'Calle 5, local 6',
          '+582125557003', 'luisa.rechazo@example.com', 'Luisa Rechazo', 'V19876503', 'Mercantil',
          '01050000000000000703')
  returning id into v_app2;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_cap::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- --- 1. La agenda sí; el resto del superadmin, no ----------------------
  if public.is_platform_admin() then raise exception '1. el capacitador pasa por admin del superadmin'; end if;
  if not public.helios_puede_usar_la_agenda() then raise exception '1. el capacitador no puede usar la agenda'; end if;
  perform public.admin_doctor_leads();
  v_fallo := false;
  begin
    perform public.admin_user_directory();
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '1. el capacitador leyó el directorio de pacientes'; end if;

  -- --- 2. Lee las clínicas y las solicitudes -----------------------------
  reset role;
  v_res := jsonb_build_object('todas', (select count(*) from public.merchants));
  set local role authenticated;
  if (select count(*) from public.merchant_directory) <> (v_res ->> 'todas')::int then
    raise exception '2. el capacitador no ve todas las clínicas (% de %)',
      (select count(*) from public.merchant_directory), v_res ->> 'todas';
  end if;
  if not exists (select 1 from jsonb_array_elements(public.admin_merchant_applications()) a
                 where (a ->> 'id')::uuid = v_app) then
    raise exception '2. el capacitador no ve las solicitudes pendientes';
  end if;

  -- --- 3. Da de alta y da el primer acceso --------------------------------
  v_res := public.admin_create_clinic(v_alta);
  v_merchant := (v_res ->> 'merchant_id')::uuid;
  v_res := public.merchant_staff_add(v_merchant, 'carla.capacitador@example.com', 'Clave-de-prueba-1',
                                     'Carla Capacitada', 'gerente');
  v_titular := (v_res ->> 'user_id')::uuid;
  v_res := public.admin_set_staff_whatsapp(v_titular, v_merchant, '0414 555 7001');
  v_res := public.merchant_staff_send_welcome(v_merchant, v_titular, 'Clave-de-prueba-1');
  if v_res ->> 'status' not in ('sin_configurar', 'fallido', 'enviado') then
    raise exception '3. la bienvenida por correo respondió algo raro: %', v_res;
  end if;
  v_res := public.admin_send_staff_whatsapp_welcome(v_merchant, v_titular);

  reset role;
  if not exists (select 1 from audit.admin_actions
                 where actor = v_cap and action = 'merchant.staff_added' and target_id = v_merchant) then
    raise exception '3. el acceso que dio el capacitador no quedó en la bitácora';
  end if;
  set local role authenticated;

  -- --- 4. Ni un segundo acceso ni el bot de alguien que ya tenía acceso ---
  v_fallo := false;
  begin
    perform public.merchant_staff_add(v_merchant, 'otra.persona.cap@example.com', 'Clave-de-prueba-2',
                                      'Otra Persona', 'cajero');
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '4. el capacitador dio un segundo acceso a una clínica'; end if;

  reset role;
  update public.merchant_users set created_at = now() - interval '3 days'
  where merchant_id = v_merchant and user_id = v_titular;
  set local role authenticated;
  v_fallo := false;
  begin
    perform public.admin_set_staff_whatsapp(v_titular, v_merchant, '0414 555 7009');
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '4. el capacitador cambió el número del bot de alguien con acceso'; end if;

  -- --- 5. El perfil sin el dinero ----------------------------------------
  v_res := public.admin_merchant_detail(v_merchant);
  if v_res -> 'profile' ->> 'owner_name' <> 'Carla Capacitada' then
    raise exception '5. el capacitador no ve el perfil: %', v_res -> 'profile';
  end if;
  if jsonb_typeof(v_res -> 'terms') <> 'null' or jsonb_typeof(v_res -> 'pending_usd') <> 'null'
     or jsonb_typeof(v_res -> 'payout_account') <> 'null' then
    raise exception '5. el capacitador ve el dinero de la clínica: %', v_res - 'profile' - 'staff';
  end if;
  if jsonb_array_length(v_res -> 'staff') <> 1 then
    raise exception '5. el capacitador no ve el acceso del titular';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_res := public.admin_merchant_detail(v_merchant);
  if jsonb_typeof(v_res -> 'terms') <> 'object' or jsonb_typeof(v_res -> 'payout_account') <> 'object' then
    raise exception '5. el super admin dejó de ver el dinero de la clínica: %', v_res - 'profile' - 'staff';
  end if;
  -- Y él sí cambia el número de alguien que ya tenía acceso.
  perform public.admin_set_staff_whatsapp(v_titular, v_merchant, '0414 555 7009');

  -- --- 6. Aprueba y rechaza ---------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_cap::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_res := public.admin_approve_merchant_application(v_app);
  perform public.admin_reject_merchant_application(v_app2, 'Datos de prueba');
  reset role;
  if not exists (select 1 from public.merchant_applications
                 where id = v_app and status = 'approved' and reviewed_by = v_cap) then
    raise exception '6. la solicitud no quedó aprobada por el capacitador';
  end if;
  if not exists (select 1 from public.merchant_applications where id = v_app2 and status = 'rejected') then
    raise exception '6. la solicitud no quedó rechazada';
  end if;
  set local role authenticated;

  -- --- 7. Corrige el perfil y el titular, y sube el logo -----------------
  perform public.admin_set_merchant_owner(v_merchant, '{"owner_name":"Carla Corregida","doctor_title":"Lcda."}');
  perform public.admin_set_merchant_profile(
    p_merchant_id => v_merchant, p_category => null, p_city => 'Valencia', p_handle => null,
    p_logo_url => null, p_specialty => 'Dermatología estética', p_phone => '0241 555 7001',
    p_consultorio => 'Consultorio Corregido');
  insert into storage.objects (bucket_id, name, owner_id)
  values ('merchant-logos', v_merchant || '/logo-prueba.png', v_cap::text);
  reset role;
  if not exists (select 1 from public.merchants
                 where id = v_merchant and owner_name = 'Carla Corregida' and doctor_title = 'Lcda.'
                   and city = 'Valencia' and specialty = 'Dermatología estética'
                   and consultorio = 'Consultorio Corregido') then
    raise exception '7. el perfil corregido por el capacitador no quedó guardado';
  end if;
  if (select count(*) from audit.admin_actions
       where actor = v_cap and target_id = v_merchant
         and action in ('merchant.set_owner', 'merchant.set_profile')) <> 2 then
    raise exception '7. las correcciones del capacitador no quedaron en la bitácora';
  end if;
  set local role authenticated;

  v_fallo := false;
  begin
    perform public.merchant_staff_set_password(v_merchant, v_titular, 'Clave-de-prueba-3');
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '7. el capacitador cambió la contraseña del titular'; end if;

  -- El operador ve la clínica, pero no edita su perfil ni sube su logo.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_set_merchant_owner(v_merchant, '{"owner_name":"Otra Persona"}');
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '7. el operador corrigió el titular'; end if;
  v_fallo := false;
  begin
    insert into storage.objects (bucket_id, name, owner_id)
    values ('merchant-logos', v_merchant || '/logo-operador.png', v_op::text);
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '7. el operador subió un logo'; end if;

  -- --- 8. El rol de la agenda, no ---------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_agenda::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  if public.helios_puede_ver_clinicas() then raise exception '8. el rol de la agenda ve las clínicas'; end if;
  v_fallo := false;
  begin
    perform public.admin_create_clinic(v_alta || '{"owner_document":"V19876509","email":"otra.cap@example.com"}');
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '8. el rol de la agenda dio de alta una clínica'; end if;
  v_fallo := false;
  begin
    perform public.admin_merchant_detail(v_merchant);
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '8. el rol de la agenda leyó la ficha de una clínica'; end if;

  reset role;
  raise notice '=== CAPACITADOR: TODO OK ===';
end $$;

rollback;
