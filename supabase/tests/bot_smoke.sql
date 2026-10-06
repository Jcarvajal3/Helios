-- ============================================================================
-- Helios — Prueba de humo del bot del médico (20261005000600)
--
--   bash supabase/tests/run.sh bot_smoke
--
--  1. Un número sin registrar no tiene bot (42501).
--  2. El PIN: 4 dígitos, sin los obvios, uno solo; el equivocado se cuenta
--     SIN lanzar; al 5.º se bloquea; resetearlo deja crear otro.
--  3. Las operaciones van como la persona: elegibilidad con su límite, la
--     orden con su nombre y `channel = 'whatsapp'`, la regla de «primero
--     consulta la cédula», y la lista solo de su clínica.
--  4. El médico se entera: aceptada, rechazada y vencida (solo con su ventana
--     abierta).
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
  -- 2. El PIN
  -- =========================================================================
  foreach v_err in array array['1234', '0000', '9876', '12a4', '123'] loop
    v_failed := false;
    begin
      perform public.bot_set_pin(v_tel, v_err);
    exception when others then v_failed := true; end;
    if not v_failed then
      raise exception 'El PIN «%» no debía aceptarse', v_err;
    end if;
  end loop;

  if not (public.bot_set_pin(v_tel, ' 4821 ')->>'ok')::boolean then
    raise exception 'Un PIN bueno debía guardarse';
  end if;
  v_failed := false;
  begin
    perform public.bot_set_pin(v_tel, '5937');
  exception when others then v_failed := true; end;
  if not v_failed then
    raise exception 'Con un PIN ya creado no se crea otro';
  end if;

  perform public.bot_patient_eligibility(v_tel, 'V50000001');

  v_j := public.bot_create_charge(v_tel, '0001', v_pac, 100, null, null, 'wa:pin-1');
  if (v_j->>'ok')::boolean or v_j->>'error' <> 'pin' or (v_j->>'attempts_left')::integer <> 4
     or (select failed_attempts from public.staff_pins where user_id = v_doc) <> 1 then
    raise exception 'Un PIN equivocado se cuenta sin lanzar: %', v_j;
  end if;
  if exists (select 1 from public.charges where idempotency_key = 'wa:pin-1') then
    raise exception 'Con el PIN equivocado no se crea nada';
  end if;

  for v_i in 2..5 loop
    v_j := public.bot_create_charge(v_tel, '0001', v_pac, 100, null, null, 'wa:pin-' || v_i);
  end loop;
  if not (v_j->>'locked')::boolean
     or (select locked_at from public.staff_pins where user_id = v_doc) is null then
    raise exception 'Al quinto PIN equivocado se bloquea: %', v_j;
  end if;
  v_j := public.bot_create_charge(v_tel, '4821', v_pac, 100, null, null, 'wa:pin-6');
  if (v_j->>'ok')::boolean or not (v_j->>'locked')::boolean then
    raise exception 'Bloqueado, ni el PIN bueno vale: %', v_j;
  end if;

  -- El bot dejó a la doctora como `auth.uid()` en esta transacción (en el
  -- webhook cada mensaje es su propia transacción): se vuelve al admin.
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  perform public.admin_reset_staff_pin(v_doc, 'Bloqueado en la prueba');
  reset role;
  perform public.bot_set_pin(v_tel, '4821');

  -- =========================================================================
  -- 3. Como la persona
  -- =========================================================================
  v_failed := false;
  begin
    perform public.bot_create_charge(v_tel, '4821',
      v_pac || jsonb_build_object('document', 'V50000009'), 50, null, null, 'wa:sin-consulta');
  exception when others then v_failed := true; v_err := sqlerrm; end;
  if not v_failed or v_err <> 'Primero consulta la cédula del paciente' then
    raise exception 'El bot sigue la regla de consultar la cédula: %', coalesce(v_err, 'sin error');
  end if;

  v_j := public.bot_create_charge(v_tel, '4821', v_pac, 100, 'Consulta', null, 'wa:msg-1');
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
  if (public.bot_create_charge(v_tel, '4821', v_pac, 100, 'Consulta', null, 'wa:msg-1'))->'charge'->>'id' <> v_charge::text then
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
     or v_row.rendered_text not like '✅ José P. aceptó. Orden #% confirmada: consulta de $100.' then
    raise exception 'El médico debía enterarse de que aceptó: %', to_jsonb(v_row);
  end if;

  perform public.bot_patient_eligibility(v_tel, 'V50000002');
  v_charge2 := ((public.bot_create_charge(v_tel, '4821',
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
    perform public.bot_create_charge(v_tel, '4821', v_pac, 10, null, null, 'wa:api');
  exception when insufficient_privilege then v_failed := true; end;
  reset role;
  if not v_failed then
    raise exception 'Ni el propio médico llama al bot desde la API';
  end if;
end;
$$;

set constraints all immediate;

rollback;
