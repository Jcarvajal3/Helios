-- ============================================================================
-- Helios — Prueba de humo del bot del médico (20261005000600)
--
--   bash supabase/tests/run.sh bot_smoke
--
--  1. Un número sin registrar no tiene bot (42501).
--  2. Sin PIN (20261013000200): no quedan sus funciones ni su tabla.
--  3. Las operaciones van como la persona: elegibilidad con su límite, la
--     orden con su nombre y `channel = 'whatsapp'`, la regla de «primero
--     consulta la cédula», y la lista solo de su clínica.
--  4. El médico se entera: aceptada, rechazada y vencida (con su ventana
--     abierta), también si registró en el panel, y el administrador de la
--     clínica aunque registre la secretaria (una vez cada uno); con la ventana cerrada, solo
--     «aceptó» y solo con la plantilla `aviso_al_medico` conectada.
--  5. La sesión: nueva, guardada y vencida por inactividad.
--  6. Solo el webhook (service_role) llama al bot.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_doc     uuid := gen_random_uuid();
  v_otro    uuid := gen_random_uuid();
  v_sec     uuid := gen_random_uuid();
  v_charge3 uuid;
  v_m       uuid;
  v_otra    uuid;
  v_bdate   date := public.helios_business_date(now());
  v_tel     text := '584245550001';
  v_pac     jsonb;
  v_j       jsonb;
  v_charge  uuid;
  v_charge2 uuid;
  v_failed  boolean;
  v_err     text;
  v_i       integer;
  v_row     record;
begin
  update public.platform_maintenance set is_active = false;
  insert into public.business_parameters (key, value, effective_from, note)
  values ('patient_confirmation_required', 1, v_bdate, 'prueba')
  on conflict (key, effective_from) do update set value = 1;
  if not public.helios_whatsapp_api_ready() then
    perform vault.create_secret('prueba', 'd360_api_key');
    perform vault.create_secret('https://waba-sandbox.360dialog.io/v1', 'd360_base_url');
  end if;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values
    (v_doc, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'bot-doc@prueba.helios.test', now(), now(), '{"full_name":"Dr. Ramón Díaz"}'),
    (v_otro, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'bot-otro@prueba.helios.test', now(), now(), '{"full_name":"Otra Doctora"}');

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_m    := (public.admin_create_merchant('Consultorio Bot', null, 'J-400000041', 'consultorio')).id;
  v_otra := (public.admin_create_merchant('Otra Bot', null, 'J-400000042', 'clinica')).id;
  reset role;

  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_doc,  v_m,    (select id from public.merchant_branches where merchant_id = v_m and is_default), 'gerente'),
    (v_otro, v_otra, (select id from public.merchant_branches where merchant_id = v_otra and is_default), 'gerente');

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  perform public.admin_set_staff_whatsapp(v_doc, v_m, '0424-555.00.01');
  reset role;

  v_pac := jsonb_build_object(
    'document', 'V50000001', 'first_name', 'José', 'last_name', 'Pérez',
    'birth_date', (v_bdate - interval '30 years')::date, 'sex', 'M',
    'phone', '04141234567', 'email', 'jose@gmail.com',
    'state', 'Miranda', 'city', 'Caracas', 'address', 'Los Palos Grandes',
    'reference_name', 'María Pérez', 'reference_phone', '02125551234', 'reference_relationship', 'Madre');

  -- =========================================================================
  -- 1. Un número sin registrar
  -- =========================================================================
  v_failed := false;
  begin
    perform public.bot_patient_eligibility('584149990000', 'V50000001');
  exception when insufficient_privilege then v_failed := true; v_err := sqlerrm; end;
  if not v_failed or v_err <> 'Este número no está registrado en Helios' then
    raise exception 'Un número sin registrar no tiene bot: %', coalesce(v_err, 'sin error');
  end if;

  -- =========================================================================
  -- 2. Sin PIN
  -- =========================================================================
  if exists (select 1 from pg_proc where proname in ('bot_set_pin', 'helios_bot_check_pin', 'admin_reset_staff_pin'))
     or to_regclass('public.staff_pins') is not null then
    raise exception 'Quedó algo del PIN';
  end if;

  perform public.bot_patient_eligibility(v_tel, 'V50000001');

  -- =========================================================================
  -- 3. Como la persona
  -- =========================================================================
  v_failed := false;
  begin
    perform public.bot_create_charge(v_tel,
      v_pac || jsonb_build_object('document', 'V50000009'), 50, null, null, 'wa:sin-consulta');
  exception when others then v_failed := true; v_err := sqlerrm; end;
  if not v_failed or v_err <> 'Primero consulta la cédula del paciente' then
    raise exception 'El bot sigue la regla de consultar la cédula: %', coalesce(v_err, 'sin error');
  end if;

  v_j := public.bot_create_charge(v_tel, v_pac, 100, 'Consulta', null, 'wa:msg-1');
  v_charge := (v_j->'charge'->>'id')::uuid;
  select * into v_row from public.charges where id = v_charge;
  if not (v_j->>'ok')::boolean or v_row.status <> 'pending' or v_row.channel <> 'whatsapp'
     or v_row.requested_by <> v_doc or v_row.merchant_id <> v_m
     or v_j->'charge'->>'registered_by' <> 'Dr. Ramón Díaz (Administrador)' then
    raise exception 'La orden del bot no quedó como de la persona: % %', v_j, to_jsonb(v_row);
  end if;
  if not exists (select 1 from public.eligibility_lookups where staff_user_id = v_doc and document_key = 'V50000001') then
    raise exception 'La consulta de cédula del bot cuenta para esa persona';
  end if;

  -- Idempotente por el id del mensaje.
  if (public.bot_create_charge(v_tel, v_pac, 100, 'Consulta', null, 'wa:msg-1'))->'charge'->>'id' <> v_charge::text then
    raise exception 'El mismo mensaje no crea otra orden';
  end if;

  v_j := public.bot_recent_charges(v_tel, 10);
  if jsonb_array_length(v_j) <> 1 or v_j->0->>'status' <> 'pending' or v_j->0->>'charge_id' <> v_charge::text then
    raise exception 'La lista del bot: %', v_j;
  end if;

  if (public.bot_charge_by_order(v_tel, (select order_number from public.charges where id = v_charge)))->>'id' <> v_charge::text then
    raise exception 'Una orden por su número';
  end if;
  v_failed := false;
  begin
    perform public.bot_charge_by_order(v_tel, 999999999);
  exception when no_data_found then v_failed := true; end;
  if not v_failed then
    raise exception 'Una orden que no es de la clínica no existe para el bot';
  end if;

  -- =========================================================================
  -- 4. El médico se entera
  -- =========================================================================
  -- Sin ventana abierta no se le escribe.
  delete from public.whatsapp_contacts where phone_e164 = '+' || v_tel;
  v_failed := false;
  begin
    perform public.helios_whatsapp_text(v_tel, 'hola', v_doc);
  exception when others then v_failed := true; end;
  if not v_failed then
    raise exception 'Fuera de la ventana, el bot no escribe';
  end if;

  insert into public.whatsapp_contacts (phone_e164, last_inbound_at, staff_user_id)
  values ('+' || v_tel, now(), v_doc);

  v_j := public.helios_patient_decision(v_charge, 'si', '584141234567', 'wamid.bot.si');
  if not (v_j->>'ok')::boolean then
    raise exception 'El paciente debía poder aceptar: %', v_j;
  end if;
  select * into v_row from public.outbound_messages
  where recipient_staff_id = v_doc and template_key = 'bot_respuesta' order by created_at desc limit 1;
  if v_row.id is null or v_row.profile_id is not null or v_row.recipient <> '+' || v_tel
     or v_row.rendered_text not like E'¡Buenas noticias! José P. aceptó su pago en cuotas.\n\nLa orden #% por una consulta de $100 ya está confirmada ✅' then
    raise exception 'El médico debía enterarse de que aceptó: %', to_jsonb(v_row);
  end if;

  perform public.bot_patient_eligibility(v_tel, 'V50000002');
  v_charge2 := ((public.bot_create_charge(v_tel,
                  v_pac || jsonb_build_object('document', 'V50000002', 'phone', '04161112233', 'email', 'b@gmail.com'),
                  40, null, null, 'wa:msg-2'))->'charge'->>'id')::uuid;
  update public.charges set expires_at = now() - interval '1 minute' where id = v_charge2;
  perform public.helios_expire_pending_charges();
  if not exists (select 1 from public.outbound_messages
                  where recipient_staff_id = v_doc and rendered_text like '⌛ La orden #% venció sin respuesta.%reenviar%') then
    raise exception 'El médico debía enterarse de que venció';
  end if;

  perform public.bot_resend_confirmation(v_tel, v_charge2);
  v_j := public.helios_patient_decision(v_charge2, 'no', '584161112233', 'wamid.bot.no');
  if not exists (select 1 from public.outbound_messages
                  where recipient_staff_id = v_doc and rendered_text like '❌ José P. no aceptó la orden #%') then
    raise exception 'El médico debía enterarse del No: %', v_j;
  end if;

  -- Registrada desde el PANEL (20261013000300): también se entera. El bot dejó
  -- `helios.canal = whatsapp` en esta transacción: se limpia.
  perform set_config('helios.canal', '', true);
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_doc::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V50000004');
  v_charge2 := (public.create_patient_charge(v_m, null,
                  v_pac || jsonb_build_object('document', 'V50000004', 'phone', '04161114455', 'email', 'c@gmail.com'),
                  60, null, null, 'panel-aviso-1')->>'id')::uuid;
  reset role;
  if (select channel from public.charges where id = v_charge2) <> 'panel' then
    raise exception 'La orden debía ser del panel';
  end if;
  perform public.helios_patient_decision(v_charge2, 'si', '584161114455', 'wamid.bot.panel.si');
  if not exists (select 1 from public.outbound_messages
                  where recipient_staff_id = v_doc and template_key = 'bot_respuesta'
                    and rendered_text like E'¡Buenas noticias! José P. aceptó su pago en cuotas.\n\nLa orden #% por una consulta de $60 ya está confirmada ✅') then
    raise exception 'Con una orden del panel, el médico también debía enterarse';
  end if;
  if (select count(*) from public.outbound_messages where charge_id is null and recipient_staff_id = v_doc
        and rendered_text like '%#' || (select order_number from public.charges where id = v_charge2) || ' por una consulta%') <> 1 then
    raise exception 'Quien registró y además es administrador recibe el aviso una sola vez';
  end if;

  -- La SECRETARIA registra en el panel, sin número del bot (20261015000300):
  -- el aviso le llega al administrador de la clínica.
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values (v_sec, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'bot-sec@prueba.helios.test', now(), now(), '{"full_name":"Ana Secretaria"}');
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_sec, v_m, (select id from public.merchant_branches where merchant_id = v_m and is_default), 'cajero');
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sec::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V50000005');
  v_charge3 := (public.create_patient_charge(v_m, null,
                  v_pac || jsonb_build_object('document', 'V50000005', 'phone', '04161116677', 'email', 'd@gmail.com'),
                  70, null, null, 'panel-aviso-sec')->>'id')::uuid;
  reset role;
  perform public.helios_patient_decision(v_charge3, 'si', '584161116677', 'wamid.bot.sec.si');
  if (select count(*) from public.outbound_messages
       where recipient_staff_id = v_doc and template_key = 'bot_respuesta'
         and rendered_text like '%#' || (select order_number from public.charges where id = v_charge3) || ' por una consulta de $70%') <> 1 then
    raise exception 'Si la secretaria registra, el administrador debía enterarse (una vez)';
  end if;
  if exists (select 1 from public.outbound_messages where recipient_staff_id = v_sec) then
    raise exception 'La secretaria sin número del bot no recibe WhatsApp';
  end if;

  -- Ventana cerrada: sin plantilla, nada; con la plantilla, sale con ella.
  update public.notification_templates set wa_template_name = null where key = 'aviso_al_medico';
  delete from public.whatsapp_contacts where phone_e164 = '+' || v_tel;
  perform public.helios_notify_staff_of_charge(v_charge2, 'aceptada');
  if exists (select 1 from public.outbound_messages where template_key = 'aviso_al_medico' and charge_id = v_charge2) then
    raise exception 'Sin plantilla aprobada, fuera de la ventana no se le escribe';
  end if;
  update public.notification_templates set wa_template_name = 'helios_paciente_acepto' where key = 'aviso_al_medico';
  perform public.helios_notify_staff_of_charge(v_charge2, 'aceptada');
  select * into v_row from public.outbound_messages where template_key = 'aviso_al_medico' and charge_id = v_charge2;
  if v_row.id is null or v_row.recipient_staff_id <> v_doc or v_row.wa_template->>'name' <> 'helios_paciente_acepto'
     or v_row.wa_template->'params' <> jsonb_build_array('José P.', (select order_number::text from public.charges where id = v_charge2), '$60') then
    raise exception 'Fuera de la ventana, el aviso sale con la plantilla: %', to_jsonb(v_row);
  end if;
  perform public.helios_notify_staff_of_charge(v_charge2, 'vencida');
  if (select count(*) from public.outbound_messages where recipient_staff_id = v_doc and rendered_text like '⌛%#' || (select order_number from public.charges where id = v_charge2) || '%') > 0 then
    raise exception 'Fuera de la ventana, solo «aceptó» sale con plantilla';
  end if;
  update public.notification_templates set wa_template_name = null where key = 'aviso_al_medico';
  insert into public.whatsapp_contacts (phone_e164, last_inbound_at, staff_user_id)
  values ('+' || v_tel, now(), v_doc);

  -- =========================================================================
  -- 5. La sesión
  -- =========================================================================
  v_j := public.bot_session(v_tel);
  if v_j->>'state' <> 'menu' or not (v_j->>'nueva')::boolean then
    raise exception 'Sin sesión, una nueva en el menú: %', v_j;
  end if;
  perform public.bot_session_save(v_tel, 'datos', '{"cedula":"V50000003"}');
  v_j := public.bot_session(v_tel);
  if v_j->>'state' <> 'datos' or v_j->'data'->>'cedula' <> 'V50000003' or (v_j->>'nueva')::boolean then
    raise exception 'La sesión guardada: %', v_j;
  end if;
  update public.whatsapp_sessions set updated_at = now() - interval '31 minutes' where phone_e164 = '+' || v_tel;
  if not ((public.bot_session(v_tel))->>'nueva')::boolean then
    raise exception 'Tras 30 minutos sin actividad, la conversación empieza de nuevo';
  end if;

  -- =========================================================================
  -- 6. Solo el webhook
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_doc::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.bot_create_charge(v_tel, v_pac, 10, null, null, 'wa:api');
  exception when insufficient_privilege then v_failed := true; end;
  reset role;
  if not v_failed then
    raise exception 'Ni el propio médico llama al bot desde la API';
  end if;
end;
$$;

set constraints all immediate;

rollback;
