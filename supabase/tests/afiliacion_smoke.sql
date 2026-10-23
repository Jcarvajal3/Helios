-- ============================================================================
-- Helios — Prueba de humo de la solicitud de afiliación y el alta nueva
-- (20261009000200_los_medicos_piden_su_alta_desde_la_portada)
--
-- 1. anon manda una solicitud: queda pendiente, con los datos normalizados.
-- 2. El campo escondido (robot) contesta que sí y no guarda nada.
-- 3. Una segunda solicitud pendiente con la misma cédula se rechaza.
-- 4. Datos inválidos: errores legibles.
-- 5. anon no lee las solicitudes; un operador no aprueba.
-- 6. El super admin aprueba (corrigiendo un dato): nace la clínica con su
--    titular, su categoría y su Pago Móvil.
-- 7. Rechazar exige motivo; una revisada no se vuelve a revisar.
-- 8. `admin_create_clinic` crea igual, sin RIF.
-- 9. `admin_set_merchant_owner` corrige el titular.
-- La red social (20261023130000) va en 1, 4, 6 y 8: opcional, la red y el
-- usuario juntos.
-- ============================================================================

begin;

do $$
declare
  v_super    uuid := gen_random_uuid();
  v_operador uuid := gen_random_uuid();
  v_app      uuid;
  v_app2     uuid;
  v_merchant uuid;
  v_res      jsonb;
  v_failed   boolean;
  v_m        public.merchants%rowtype;
  v_cuenta   public.merchant_payout_accounts%rowtype;
  v_datos    jsonb := jsonb_build_object(
    'owner_name', '  Ana   María Pérez ',
    'owner_document', 'V12345678',
    'tax_id', '',
    'specialty', 'Odontología',
    'college_number', 'COV-1234',
    'mpps_number', '98765',
    'clinic_name', 'Consultorio Dental Prueba Afiliación',
    'address', 'Av. Principal, Torre Médica, piso 3',
    'phone', '0212 555 1234',
    'email', 'Ana.Prueba.Afiliacion@Example.com',
    'social_network', ' Instagram ',
    'social_user', '  @dra.ana.prueba  ',
    'account_holder', 'Ana María Pérez',
    'holder_document', 'V12345678',
    'bank', 'Banesco',
    'account_number', '0134 0000 0000 0000 0001',
    -- La portada no pide Pago Móvil: si llega, se ignora.
    'pago_movil_bank', 'Mercantil',
    'pago_movil_phone', '0414-123-4567');
begin
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_super,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000091', now(), now(), now()),
    (v_operador, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000092', now(), now(), now());
  insert into public.platform_admins (user_id, role, full_name) values
    (v_super, 'super_admin', 'Jefa'), (v_operador, 'operador', 'Operador');

  -- --- 1. anon solicita ---------------------------------------------------
  set local role anon;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.headers', '{"x-forwarded-for":"203.0.113.9, 10.0.0.1","user-agent":"prueba"}', true);

  v_res := public.helios_solicitar_afiliacion(v_datos);
  if not (v_res->>'ok')::boolean then raise exception 'La solicitud debía responder ok'; end if;

  -- --- 2. El robot -------------------------------------------------------
  v_res := public.helios_solicitar_afiliacion(v_datos || '{"sitio_web":"http://spam"}');

  -- --- 3. Repetida -------------------------------------------------------
  v_failed := false;
  begin
    perform public.helios_solicitar_afiliacion(v_datos || '{"email":"otro.correo@example.com","phone":"02125559999"}');
  exception when unique_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'Una segunda solicitud con la misma cédula debía rechazarse'; end if;

  -- --- 4. Inválidos ------------------------------------------------------
  v_failed := false;
  begin
    perform public.helios_solicitar_afiliacion(v_datos || '{"account_number":"0134 0000"}');
  exception when invalid_parameter_value then
    v_failed := sqlerrm like '%20 dígitos%';
  end;
  if not v_failed then raise exception 'Una cuenta corta debía rechazarse'; end if;

  v_failed := false;
  begin
    perform public.helios_solicitar_afiliacion(v_datos - 'account_number');
  exception when invalid_parameter_value then
    v_failed := sqlerrm like '%transferencia%';
  end;
  if not v_failed then raise exception 'La portada sin transferencia debía rechazarse'; end if;

  v_failed := false;
  begin
    perform public.helios_solicitar_afiliacion(v_datos || '{"owner_document":"12.345.678"}');
  exception when invalid_parameter_value then v_failed := true;
  end;
  if not v_failed then raise exception 'Una cédula sin su letra debía rechazarse'; end if;

  v_failed := false;
  begin
    perform public.helios_solicitar_afiliacion(v_datos || '{"email":"no-es-correo"}');
  exception when invalid_parameter_value then v_failed := true;
  end;
  if not v_failed then raise exception 'Un correo inválido debía rechazarse'; end if;

  v_failed := false;
  begin
    perform public.helios_solicitar_afiliacion(v_datos - 'social_network');
  exception when invalid_parameter_value then
    v_failed := sqlerrm like '%qué red social%';
  end;
  if not v_failed then raise exception 'Un usuario sin su red social debía rechazarse'; end if;

  v_failed := false;
  begin
    perform public.helios_solicitar_afiliacion(v_datos || '{"social_network":"myspace"}');
  exception when invalid_parameter_value then v_failed := true;
  end;
  if not v_failed then raise exception 'Una red social fuera de la lista debía rechazarse'; end if;

  v_failed := false;
  begin
    perform public.helios_solicitar_afiliacion(v_datos || '{"social_user":"  "}');
  exception when invalid_parameter_value then
    v_failed := sqlerrm like '%usuario o el enlace%';
  end;
  if not v_failed then raise exception 'Una red social sin usuario debía rechazarse'; end if;

  -- La capacitación (20261023140000): de mañana a 90 días.
  v_failed := false;
  begin
    perform public.helios_solicitar_afiliacion(v_datos || jsonb_build_object('training_at', now()::text));
  exception when invalid_parameter_value then
    v_failed := sqlerrm like '%de mañana en adelante%';
  end;
  if not v_failed then raise exception 'Una capacitación para hoy debía rechazarse'; end if;

  v_failed := false;
  begin
    perform public.helios_solicitar_afiliacion(v_datos || jsonb_build_object('training_at', (now() + interval '120 days')::text));
  exception when invalid_parameter_value then
    v_failed := sqlerrm like '%90 días%';
  end;
  if not v_failed then raise exception 'Una capacitación a 120 días debía rechazarse'; end if;

  v_failed := false;
  begin
    perform public.helios_solicitar_afiliacion(v_datos || '{"training_at":"el martes"}');
  exception when invalid_parameter_value then v_failed := true;
  end;
  if not v_failed then raise exception 'Una capacitación ilegible debía rechazarse'; end if;

  -- --- 5. Quién lee y quién aprueba --------------------------------------
  v_failed := false;
  begin
    perform public.admin_merchant_applications();
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'anon no debía poder leer las solicitudes'; end if;

  v_failed := false;
  begin
    perform count(*) from public.merchant_applications;
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'anon no debía leer la tabla de solicitudes'; end if;

  reset role;
  select id into v_app from public.merchant_applications where owner_document = 'V12345678' and status = 'pending';
  if v_app is null then raise exception 'La solicitud no quedó pendiente con la cédula normalizada'; end if;
  if (select count(*) from public.merchant_applications where owner_document = 'V12345678') <> 1 then
    raise exception 'El robot no debía dejar solicitud';
  end if;
  if not exists (select 1 from public.merchant_applications where id = v_app
                 and owner_name = 'Ana María Pérez' and phone = '+582125551234'
                 and email = 'ana.prueba.afiliacion@example.com' and tax_id is null
                 and account_number = '01340000000000000001' and bank = 'Banesco'
                 and holder_document = 'V12345678' and pago_movil_phone is null
                 and social_network = 'instagram' and social_user = '@dra.ana.prueba'
                 and ip = '203.0.113.9') then
    raise exception 'La solicitud no se guardó normalizada';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_operador::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  if jsonb_array_length(public.admin_merchant_applications()) < 1 then
    raise exception 'El operador debía ver la solicitud pendiente';
  end if;
  v_failed := false;
  begin
    perform public.admin_approve_merchant_application(v_app);
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'Un operador no debía aprobar'; end if;

  -- --- 6. Aprobar ---------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_res := public.admin_approve_merchant_application(v_app, '{"clinic_name":"Consultorio Dental Ana Pérez"}');
  v_merchant := (v_res->>'merchant_id')::uuid;

  reset role;
  select * into v_m from public.merchants where id = v_merchant;
  if v_m.name <> 'Consultorio Dental Ana Pérez' or v_m.owner_name <> 'Ana María Pérez'
     or v_m.owner_document <> 'V12345678' or v_m.college_number <> 'COV-1234'
     or v_m.category <> 'odontologia' or v_m.tax_id is not null or v_m.status <> 'active'
     or v_m.social_network <> 'instagram' or v_m.social_user <> '@dra.ana.prueba' then
    raise exception 'La clínica no nació con los datos de la solicitud: %', to_jsonb(v_m);
  end if;
  select * into v_cuenta from public.merchant_payout_accounts where merchant_id = v_merchant;
  if v_cuenta.account_number <> '01340000000000000001' or v_cuenta.bank <> 'Banesco'
     or v_cuenta.pago_movil_phone is not null
     or v_cuenta.account_holder <> 'Ana María Pérez' or v_cuenta.holder_document <> 'V12345678' then
    raise exception 'La cuenta de pago no quedó bien: %', to_jsonb(v_cuenta);
  end if;
  if not exists (select 1 from public.merchant_applications where id = v_app and status = 'approved' and merchant_id = v_merchant) then
    raise exception 'La solicitud debía quedar aprobada y ligada a la clínica';
  end if;
  if not exists (select 1 from audit.admin_actions where action = 'merchant_application.approved' and target_id = v_merchant) then
    raise exception 'La aprobación debía quedar en la bitácora';
  end if;

  -- --- 7. Rechazar --------------------------------------------------------
  insert into public.merchant_applications
    (owner_name, owner_document, specialty, clinic_name, address, phone, email,
     account_holder, holder_document, bank, account_number)
  values ('Luis Prueba', 'V87654321', 'Cosmetología', 'Estética Prueba', 'Calle 1, local 2',
          '+582125550000', 'luis.prueba@example.com', 'Luis Prueba', 'V87654321', 'Mercantil', '01050000000000000002')
  returning id into v_app2;

  set local role authenticated;
  v_failed := false;
  begin
    perform public.admin_reject_merchant_application(v_app2, '  ');
  exception when invalid_parameter_value then v_failed := true;
  end;
  if not v_failed then raise exception 'Rechazar sin motivo debía fallar'; end if;

  perform public.admin_reject_merchant_application(v_app2, 'No es un consultorio');
  v_failed := false;
  begin
    perform public.admin_approve_merchant_application(v_app2);
  exception when invalid_parameter_value then v_failed := true;
  end;
  if not v_failed then raise exception 'Una solicitud rechazada no se aprueba'; end if;

  -- --- 8. El alta desde el panel -----------------------------------------
  -- El equipo: solo Pago Móvil, con el titular por RIF.
  v_res := public.admin_create_clinic((v_datos - 'account_number' - 'bank' - 'social_network' - 'social_user') ||'{"clinic_name":"Clínica Prueba Panel","tax_id":"J501234567","specialty":"Pediatría","account_holder":"Clínica Prueba Panel C.A.","holder_document":"J501234567","owner_document":"V11222333","email":"panel.prueba@example.com"}');
  reset role;
  select * into v_m from public.merchants where id = (v_res->>'merchant_id')::uuid;
  if v_m.category <> 'consultorio' or v_m.tax_id <> 'J-501234567' or v_m.social_network is not null then
    raise exception 'El alta del panel no guardó la categoría o el RIF: %', to_jsonb(v_m);
  end if;
  select * into v_cuenta from public.merchant_payout_accounts where merchant_id = v_m.id;
  if v_cuenta.holder_document <> 'J-501234567' or v_cuenta.pago_movil_phone <> '+584141234567'
     or v_cuenta.pago_movil_bank <> 'Mercantil' or v_cuenta.account_number is not null then
    raise exception 'El Pago Móvil del equipo no quedó bien: %', to_jsonb(v_cuenta);
  end if;
  set local role authenticated;
  v_failed := false;
  begin
    perform public.admin_create_clinic(v_datos - 'account_number' - 'pago_movil_phone' || '{"email":"sin.pago@example.com","owner_document":"V11222334"}');
  exception when invalid_parameter_value then v_failed := true;
  end;
  if not v_failed then raise exception 'Sin transferencia ni Pago Móvil no debía crearse'; end if;
  reset role;

  -- --- 9. Corregir el titular ---------------------------------------------
  set local role authenticated;
  perform public.admin_set_merchant_owner(v_m.id, '{"owner_name":"","owner_document":"E8123456","college_number":""}');
  reset role;
  select * into v_m from public.merchants where id = v_m.id;
  if v_m.owner_name <> 'Ana María Pérez' or v_m.owner_document <> 'E8123456' or v_m.college_number is not null then
    raise exception 'El titular no se corrigió bien: %', to_jsonb(v_m);
  end if;

  raise notice '=== AFILIACIÓN: TODO OK ===';
end $$;

set constraints all immediate;

rollback;
