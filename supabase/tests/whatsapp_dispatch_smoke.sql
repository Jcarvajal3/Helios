-- ============================================================================
-- Helios — Prueba de humo del despacho de WhatsApp (20261005000400)
--
--   bash supabase/tests/run.sh whatsapp_dispatch_smoke
--
-- NUNCA sale a la red: dentro de la transacción se sustituye
-- `helios_d360_request(...)` (la única llamada HTTP) por un doble que lee
-- respuestas simuladas de una tabla temporal y anota cada llamada. Si no hay
-- claves de 360dialog en Vault, se crean dentro de la transacción. El
-- rollback final devuelve todo como estaba.
--
--  1. Sin claves → todo lo pendiente pasa a la cola manual (si no las hay).
--  2. Al encolar, la plantilla de Meta queda resuelta: nombre, idioma, las 6
--     variables en una línea y los botones con el id de la orden.
--  3. Ventana cerrada → la plantilla, con sus variables y los payloads de los
--     botones; 2xx → `enviado` con el wamid.
--  4. Los estados de entrega solo avanzan; la clínica ve «leída».
--  5. Ventana abierta → botones interactivos (la pregunta) o texto (la
--     bienvenida); ventana cerrada y sin plantilla → cola manual.
--  6. Teléfono sin WhatsApp (131026) → `fallido`; plantilla sin aprobar
--     (132001) → cola manual; 5xx → reintento y, al rendirse, cola manual;
--     401 → espera sin gastar intento y corta el lote.
--  7. Un `failed` del webhook deja el mensaje `fallido`.
--  8. El cron existe y la configuración dice que la API está lista.
-- ============================================================================

begin;

-- @ayudas

create temp table _respuestas (n serial primary key, status integer, body text) on commit drop;
create temp table _llamadas (n serial primary key, method text, path text, body jsonb) on commit drop;
create temp sequence _pos minvalue 0 start 0;

create or replace function public.helios_d360_request(
  p_method text, p_path text, p_api_key text, p_base_url text, p_body jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v record;
begin
  insert into pg_temp._llamadas (method, path, body) values (p_method, p_path, p_body);

  select * into v from pg_temp._respuestas
  where n > (select last_value from pg_temp._pos) order by n limit 1;
  if not found then
    raise exception 'La prueba no preparó respuesta para % %', p_method, p_path;
  end if;
  perform setval('pg_temp._pos', v.n);

  if v.status is null then
    raise exception 'timeout simulado';
  end if;
  return jsonb_build_object('status', v.status, 'body', v.body);
end;
$$;

do $$
declare
  v_admin   uuid;
  v_cajero  uuid := gen_random_uuid();
  v_m       uuid;
  v_bdate   date := public.helios_business_date(now());
  v_pac     jsonb;
  v_j       jsonb;
  v_charge  uuid;
  v_profile uuid;
  v_msg     uuid;
  v_row     record;
  v_call    record;
  v_r       jsonb;
begin
  update public.platform_maintenance set is_active = false;
  update public.platform_contact set whatsapp_number = '+584140001122';
  -- Primero sin la confirmación del paciente (para tener un paciente con el
  -- que probar la cola sin claves); se enciende en la sección 2.
  insert into public.business_parameters (key, value, effective_from, note)
  values ('patient_confirmation_required', 0, v_bdate, 'prueba')
  on conflict (key, effective_from) do update set value = 0;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'wd-cajero@prueba.helios.test', now(), now(), '{"full_name":"Ana Secretaria"}');

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_m := (public.admin_create_merchant('Clínica Despacho', null, 'J-400000021', 'clinica')).id;
  reset role;

  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_m, (select id from public.merchant_branches where merchant_id = v_m and is_default), 'cajero');

  v_pac := jsonb_build_object(
    'document', 'V30000001', 'first_name', 'José', 'last_name', 'Pérez',
    'birth_date', (v_bdate - interval '30 years')::date, 'sex', 'M',
    'phone', '04141234567', 'email', 'jose@gmail.com',
    'state', 'Miranda', 'city', 'Caracas', 'address', 'Los Palos Grandes',
    'reference_name', 'María Pérez', 'reference_phone', '02125551234', 'reference_relationship', 'Madre');

  -- =========================================================================
  -- 1. Sin claves, todo a la cola manual
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V30000009');
  v_j := public.create_patient_charge(v_m, null, v_pac || jsonb_build_object('document', 'V30000009'),
                                      20, null, null, 'wd-key-0');
  reset role;
  select user_id into v_profile from public.charges where id = (v_j->>'id')::uuid;

  if public.helios_vault_secret('d360_api_key') is null then
    v_msg := public.helios_enqueue_message('bienvenida', v_profile, null, 'whatsapp',
               jsonb_build_object('clinica', 'Sol', 'orden', '1', 'moneda', 'dólar', 'cuotas', '• Cuota 1'));
    v_r := public.helios_dispatch_whatsapp_batch();
    select * into v_row from public.outbound_messages where id = v_msg;
    if v_r->>'skipped' <> 'sin_clave' or v_row.channel <> 'whatsapp_manual' or v_row.status <> 'pendiente'
       or v_row.last_error not like 'Pasó a la cola manual: la API de WhatsApp no está configurada%' then
      raise exception 'Sin claves, el WhatsApp debía pasar a la cola manual: % %', v_r, to_jsonb(v_row);
    end if;
    if exists (select 1 from pg_temp._llamadas) then
      raise exception 'Sin claves no se llama a nadie';
    end if;

    perform vault.create_secret('prueba', 'd360_api_key');
    perform vault.create_secret('https://waba-sandbox.360dialog.io/v1', 'd360_base_url');
  end if;

  -- =========================================================================
  -- 2. La plantilla de Meta queda resuelta al encolar
  -- =========================================================================
  update public.business_parameters set value = 1
   where key = 'patient_confirmation_required' and effective_from = v_bdate;
  -- Desde 20261006002000 la pregunta no tiene plantilla de Meta (la v1 decía
  -- «20 %» y «financiamiento»): fuera de la ventana va a la cola manual. Para
  -- probar el camino de la plantilla se simula una aprobada, con las 6
  -- variables de la v1.
  if (select wa_template_name from public.notification_templates where key = 'confirmar_financiamiento') is not null then
    raise exception 'La pregunta al paciente no debía tener plantilla de Meta hasta que se apruebe la v3';
  end if;
  update public.notification_templates set wa_template_name = 'helios_confirmar_financiamiento'
   where key = 'confirmar_financiamiento';
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V30000001');
  v_j := public.create_patient_charge(v_m, null, v_pac, 100, null, null, 'wd-key-1');
  reset role;
  v_charge := (v_j->>'id')::uuid;
  select user_id into v_profile from public.charges where id = v_charge;

  select * into v_row from public.outbound_messages
  where charge_id = v_charge and template_key = 'confirmar_financiamiento';
  if v_row.wa_template->>'name' <> 'helios_confirmar_financiamiento'
     or v_row.wa_template->>'language' <> 'es'
     or jsonb_array_length(v_row.wa_template->'params') <> 6
     or v_row.wa_template->'params'->>0 <> 'José'
     or v_row.wa_template->'params'->>1 <> 'Clínica Despacho'
     -- Desde el 2026-10-07 las variables de dinero traen su símbolo.
     or v_row.wa_template->'params'->>2 <> '$100'
     or v_row.wa_template->'params'->>3 <> '$12'
     or v_row.wa_template->'params'->>4 <> '$1,92'
     or v_row.wa_template->'params'->>5 not like '$56,96 el % y $56,96 el %'
     or v_row.wa_template->'buttons'->0->>'id' <> 'confirmar:' || v_charge
     or v_row.wa_template->'buttons'->1->>'id' <> 'rechazar:' || v_charge
     or v_row.wa_template->'buttons'->0->>'title' <> 'Sí' then
    raise exception 'La plantilla de Meta no quedó resuelta: %', v_row.wa_template;
  end if;

  -- =========================================================================
  -- 3. Ventana cerrada: la plantilla
  -- =========================================================================
  delete from public.whatsapp_contacts where phone_e164 = '+584141234567';
  insert into pg_temp._respuestas (status, body) values (200, '{"messages":[{"id":"wamid.A"}]}');
  v_r := public.helios_dispatch_whatsapp_batch();

  select * into v_call from pg_temp._llamadas order by n desc limit 1;
  if v_call.path <> '/messages' or v_call.body->>'type' <> 'template'
     or v_call.body->>'to' <> '584141234567'
     or v_call.body->>'messaging_product' <> 'whatsapp'
     or v_call.body->'template'->>'name' <> 'helios_confirmar_financiamiento'
     or v_call.body->'template'->'language'->>'code' <> 'es'
     or jsonb_array_length(v_call.body->'template'->'components'->0->'parameters') <> 6
     or v_call.body->'template'->'components'->1->>'sub_type' <> 'quick_reply'
     or v_call.body->'template'->'components'->1->'parameters'->0->>'payload' <> 'confirmar:' || v_charge
     or v_call.body->'template'->'components'->2->>'index' <> '1' then
    raise exception 'La plantilla no salió como manda la Cloud API: %', v_call.body;
  end if;

  select * into v_row from public.outbound_messages where id = (
    select id from public.outbound_messages where charge_id = v_charge and template_key = 'confirmar_financiamiento');
  if v_row.status <> 'enviado' or v_row.provider_id <> 'wamid.A' or v_row.last_event <> 'sent'
     or v_row.sent_at is null or v_row.attempts <> 1 then
    raise exception 'El enviado no quedó bien: %', to_jsonb(v_row);
  end if;

  -- =========================================================================
  -- 4. Los estados solo avanzan
  -- =========================================================================
  perform public.helios_whatsapp_status('wamid.A', 'delivered');
  perform public.helios_whatsapp_status('wamid.A', 'sent');
  if (select last_event from public.outbound_messages where provider_id = 'wamid.A') <> 'delivered' then
    raise exception 'Un estado no puede retroceder';
  end if;
  perform public.helios_whatsapp_status('wamid.A', 'read');
  if public.helios_whatsapp_status('wamid.nadie', 'read') then
    raise exception 'Un wamid desconocido no se encuentra';
  end if;
  if (public.helios_charge_confirmation(v_charge))->>'status' <> 'leida' then
    raise exception 'La clínica debía ver la pregunta leída: %', public.helios_charge_confirmation(v_charge);
  end if;

  -- =========================================================================
  -- 5. Ventana abierta: botones y texto; cerrada y sin plantilla: manual
  -- =========================================================================
  insert into public.whatsapp_contacts (phone_e164, last_inbound_at) values ('+584141234567', now());

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.staff_resend_confirmation(v_charge);
  reset role;

  insert into pg_temp._respuestas (status, body) values (200, '{"messages":[{"id":"wamid.B"}]}');
  perform public.helios_dispatch_whatsapp_batch();
  select * into v_call from pg_temp._llamadas order by n desc limit 1;
  if v_call.body->>'type' <> 'interactive'
     or v_call.body->'interactive'->>'type' <> 'button'
     or v_call.body->'interactive'->'body'->>'text' not like '👋 Hola, José. Bienvenido a Helios 💙%'
     or jsonb_array_length(v_call.body->'interactive'->'action'->'buttons') <> 2
     or v_call.body->'interactive'->'action'->'buttons'->0->'reply'->>'id' <> 'confirmar:' || v_charge
     or v_call.body->'interactive'->'action'->'buttons'->1->'reply'->>'title' <> 'No' then
    raise exception 'Con la ventana abierta la pregunta va con botones: %', v_call.body;
  end if;

  v_msg := public.helios_enqueue_message('bienvenida', v_profile, v_charge, 'whatsapp',
             jsonb_build_object('clinica', 'Sol', 'orden', '1', 'moneda', 'dólar', 'cuotas', E'• Cuota 1\n• Cuota 2'));
  insert into pg_temp._respuestas (status, body) values (200, '{"messages":[{"id":"wamid.C"}]}');
  perform public.helios_dispatch_whatsapp_batch();
  select * into v_call from pg_temp._llamadas order by n desc limit 1;
  if v_call.body->>'type' <> 'text' or v_call.body->'text'->>'body' not like '🩺 ¡Listo, José!%'
     or v_call.body->'text'->>'body' not like E'%• Cuota 1\n• Cuota 2%' then
    raise exception 'Con la ventana abierta la bienvenida va como texto, con sus saltos de línea: %', v_call.body;
  end if;

  delete from public.whatsapp_contacts where phone_e164 = '+584141234567';
  v_msg := public.helios_enqueue_message('bienvenida', v_profile, v_charge, 'whatsapp',
             jsonb_build_object('clinica', 'Sol', 'orden', '1', 'moneda', 'dólar', 'cuotas', '• Cuota 1'));
  perform public.helios_dispatch_whatsapp_batch();
  select * into v_row from public.outbound_messages where id = v_msg;
  if v_row.channel <> 'whatsapp_manual' or v_row.status <> 'pendiente'
     or v_row.last_error not like '%fuera de la ventana de 24 h y sin plantilla aprobada%' then
    raise exception 'Sin ventana ni plantilla, a la cola manual: %', to_jsonb(v_row);
  end if;

  -- La pregunta sin plantilla de Meta (como quedó en 20261006002000): fuera
  -- de la ventana no sale por la API, va a la cola manual.
  update public.notification_templates set wa_template_name = null where key = 'confirmar_financiamiento';
  v_msg := public.helios_enqueue_confirmation(v_charge);
  perform public.helios_dispatch_whatsapp_batch();
  select * into v_row from public.outbound_messages where id = v_msg;
  if v_row.channel <> 'whatsapp_manual' or v_row.status <> 'pendiente'
     or v_row.last_error not like '%fuera de la ventana de 24 h y sin plantilla aprobada%'
     or v_row.rendered_text not like '%¿Confirmas tu pago en cuotas? Responde Sí o No.%' then
    raise exception 'La pregunta sin plantilla, fuera de la ventana, va a la cola manual: %', to_jsonb(v_row);
  end if;
  update public.outbound_messages set status = 'cancelado' where id = v_msg;
  update public.notification_templates set wa_template_name = 'helios_confirmar_financiamiento'
   where key = 'confirmar_financiamiento';

  -- =========================================================================
  -- 6. Los errores
  -- =========================================================================
  -- Para cada caso, una pregunta nueva (ventana cerrada → plantilla).
  update public.outbound_messages set status = 'cancelado'
   where channel = 'whatsapp' and status = 'pendiente';

  v_msg := public.helios_enqueue_confirmation(v_charge);
  -- En una sola transacción todos los mensajes tienen el mismo created_at:
  -- este tiene que ser el último para lo que ve la clínica.
  update public.outbound_messages set created_at = clock_timestamp() where id = v_msg;
  insert into pg_temp._respuestas (status, body)
  values (400, '{"error":{"message":"Message undeliverable","code":131026}}');
  perform public.helios_dispatch_whatsapp_batch();
  select * into v_row from public.outbound_messages where id = v_msg;
  if v_row.status <> 'fallido' or v_row.last_event <> 'failed'
     or v_row.last_error not like 'No se le puede escribir a este teléfono (131026)%' then
    raise exception 'Un teléfono sin WhatsApp deja el mensaje fallido: %', to_jsonb(v_row);
  end if;
  if (public.helios_charge_confirmation(v_charge))->>'status' <> 'fallida' then
    raise exception 'La clínica debía ver «No se pudo enviar»';
  end if;

  v_msg := public.helios_enqueue_confirmation(v_charge);
  insert into pg_temp._respuestas (status, body)
  values (404, '{"error":{"message":"Template name does not exist","code":132001}}');
  perform public.helios_dispatch_whatsapp_batch();
  select * into v_row from public.outbound_messages where id = v_msg;
  if v_row.channel <> 'whatsapp_manual' or v_row.status <> 'pendiente'
     or v_row.last_error not like '%(132001)%' then
    raise exception 'Una plantilla sin aprobar pasa a la cola manual: %', to_jsonb(v_row);
  end if;

  v_msg := public.helios_enqueue_confirmation(v_charge);
  insert into pg_temp._respuestas (status, body) values (503, 'caído');
  perform public.helios_dispatch_whatsapp_batch();
  select * into v_row from public.outbound_messages where id = v_msg;
  if v_row.status <> 'pendiente' or v_row.channel <> 'whatsapp' or v_row.attempts <> 1
     or v_row.next_attempt_at <= now() then
    raise exception 'Un 5xx se reintenta más tarde: %', to_jsonb(v_row);
  end if;
  -- Todavía no le toca: no se llama.
  perform public.helios_dispatch_whatsapp_batch();
  if (select count(*) from pg_temp._llamadas) <> 6 then
    raise exception 'Un mensaje en espera no sale antes de tiempo (llamadas: %)', (select count(*) from pg_temp._llamadas);
  end if;
  -- Al quinto intento sin respuesta, a la cola manual.
  update public.outbound_messages set attempts = 4, next_attempt_at = now() - interval '1 second' where id = v_msg;
  insert into pg_temp._respuestas (status, body) values (null, null);
  perform public.helios_dispatch_whatsapp_batch();
  select * into v_row from public.outbound_messages where id = v_msg;
  if v_row.channel <> 'whatsapp_manual' or v_row.attempts <> 5
     or v_row.last_error not like '%sin respuesta de 360dialog tras 5 intentos%' then
    raise exception 'Al rendirse, a la cola manual: %', to_jsonb(v_row);
  end if;

  v_msg := public.helios_enqueue_confirmation(v_charge);
  insert into pg_temp._respuestas (status, body) values (401, '{"error":"invalid key"}');
  v_r := public.helios_dispatch_whatsapp_batch();
  select * into v_row from public.outbound_messages where id = v_msg;
  if v_row.status <> 'pendiente' or v_row.attempts <> 0 or v_row.next_attempt_at < now() + interval '14 minutes'
     or v_row.last_error not like '360dialog rechazó la configuración (HTTP 401)%' then
    raise exception 'Un 401 espera sin gastar intento: %', to_jsonb(v_row);
  end if;

  -- =========================================================================
  -- 7. Un `failed` del webhook
  -- =========================================================================
  perform public.helios_whatsapp_status('wamid.B', 'failed',
    '{"code":131049,"title":"This message was not delivered to maintain healthy ecosystem engagement."}'::jsonb);
  select * into v_row from public.outbound_messages where provider_id = 'wamid.B';
  if v_row.status <> 'fallido' or v_row.last_event <> 'failed'
     or v_row.last_error not like 'WhatsApp no lo entregó (131049)%' then
    raise exception 'Un failed del webhook deja el mensaje fallido: %', to_jsonb(v_row);
  end if;

  -- =========================================================================
  -- 8. El cron y la configuración
  -- =========================================================================
  if not exists (select 1 from cron.job where jobname = 'helios_whatsapp_dispatch' and schedule = '10 seconds')
     or not exists (select 1 from cron.job where jobname = 'helios_expire_pending_charges') then
    raise exception 'Faltan los crons de WhatsApp';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_r := public.helios_config_status();
  reset role;
  if not (v_r->>'whatsapp_api')::boolean or (v_r->>'whatsapp_sandbox') is null then
    raise exception 'La configuración debía decir que la API está lista: %', v_r;
  end if;
end;
$$;

set constraints all immediate;

rollback;
