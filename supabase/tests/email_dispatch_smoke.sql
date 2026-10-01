-- ============================================================================
-- Helios — El comprobante sale por correo (H6, 20261004000100)
--
--   bash supabase/tests/run.sh email_dispatch_smoke
--
-- NUNCA sale a la red ni toca un secreto de verdad: dentro de la transacción
-- se sustituyen `helios_resend_api_key()` (la clave de Vault) y
-- `helios_resend_request(...)` (la única llamada HTTP) por dobles que leen
-- respuestas simuladas de una tabla temporal y anotan cada llamada. El
-- rollback final devuelve las de verdad.
--
--  1. Sin clave → no-op: los correos siguen `pendiente`, sin gastar intento.
--  2. Con clave y sin remitente → no-op.
--  3. 2xx → `enviado` con `provider_id`; la petición lleva from/to/subject/
--     html/text e `Idempotency-Key` = id del mensaje. No se reenvía.
--  4. 4xx → `fallido` con el motivo.
--  5. 429 y 5xx → reintento con espera creciente; no sale antes de tiempo.
--  6. Al 6.º intento sin respuesta → `fallido`.
--  7. 401 → espera sin gastar intento y corta el lote.
--  8. Estado: delivered; luego bounced → `email_invalid_at`, el siguiente
--     comprobante sale `omitido` y la alerta `correo_rebotado` aparece.
--  9. `admin_resend_receipt` corrige el correo (bitácora) y reencola.
-- 10. El comprobante dice lo que tiene que decir (docs/00 §7.3) y el fee
--     nunca va sumado en un total.
-- 11. Los crons existen.
-- ============================================================================

begin;

-- @ayudas

create temp table _respuestas (n serial primary key, status integer, body text) on commit drop;
create temp table _llamadas (n serial primary key, method text, path text, body jsonb, idem text, api_key text) on commit drop;
create temp table _clave (k text) on commit drop;
-- Qué respuesta va ahora: una secuencia, porque un «timeout» simulado es una
-- excepción y deshace todo lo que el doble escribió en tablas.
create temp sequence _pos minvalue 0 start 0;

-- Los dobles. Misma firma que las de verdad.
create or replace function public.helios_resend_api_key()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$ select k from pg_temp._clave limit 1 $$;

create or replace function public.helios_resend_request(
  p_method text, p_path text, p_api_key text, p_body jsonb default null, p_idempotency_key text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v record;
begin
  insert into pg_temp._llamadas (method, path, body, idem, api_key)
  values (p_method, p_path, p_body, p_idempotency_key, p_api_key);

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
  v_admin    uuid := gen_random_uuid();
  v_staff    uuid := gen_random_uuid();
  v_pac      uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_charge   uuid;
  v_m1       uuid;
  v_m2       uuid;
  v_m3       uuid;
  v_m4       uuid;
  v_row      public.outbound_messages%rowtype;
  v_res      jsonb;
  v_call     record;
  v_n        integer;
begin
  -- Fixtures -----------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
  values
    (v_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'admin-' || v_admin || '@prueba.helios.test', now(), '{}'::jsonb, now(), now()),
    (v_staff, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'staff-' || v_staff || '@prueba.helios.test', now(), '{"full_name":"Ana Secretaria"}'::jsonb, now(), now());
  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_admin, 'operador', 'Operador de prueba', true);

  insert into public.merchants (name, tax_id) values ('Clínica Correo', 'J-123456789') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_staff, v_merchant, v_branch, 'cajero');

  insert into public.profiles (id, phone_e164, first_name, last_name, full_name, document_number, email)
  values (v_pac, '+584140009101', 'José', 'Pérez', 'José Pérez', 'V12345678', 'jose.correo@prueba.helios.test');

  update public.levels set monthly_limit_usd = 350 where level = 1;

  -- Contacto de Helios sin remitente y con WhatsApp.
  update public.platform_contact
     set whatsapp_number = '+584140000000', sender_email = null, sender_name = 'Helios',
         support_email = 'soporte@prueba.helios.test'
   where id;

  -- Los correos que ya hubiera en la base no entran en esta prueba.
  update public.outbound_messages set next_attempt_at = now() + interval '1 year'
   where channel = 'email' and status = 'pendiente';

  v_charge := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 100.00, 'correo-1')->>'charge_id')::uuid;
  v_m1 := public.helios_enqueue_charge_receipt(v_charge);

  -- --- 10. El comprobante ----------------------------------------------------
  select * into v_row from public.outbound_messages where id = v_m1;
  if v_row.status <> 'pendiente' or v_row.recipient <> 'jose.correo@prueba.helios.test' then
    raise exception 'El comprobante debía quedar pendiente al correo registrado: %', to_jsonb(v_row);
  end if;
  if v_row.subject not like 'Tu financiamiento en Clínica Correo — 2 cuotas de $61.60' then
    raise exception 'Asunto inesperado: %', v_row.subject;
  end if;
  if v_row.rendered_text not like '%Monto de la consulta: $100.00%'
     or v_row.rendered_text not like '%Servicio Helios (20 % + IVA) de $23.20%'
     or v_row.rendered_text not like '%Cuota 1: $61.60%'
     or v_row.rendered_text not like '%Si no reconoces este financiamiento%'
     or v_row.rendered_text not like '%Este comprobante no es una factura fiscal.%'
     or v_row.rendered_text not like '%C.I. V-****5678%'
     or v_row.rendered_text not like '%Registró: Ana%' then
    raise exception 'Al texto del comprobante le falta algo: %', v_row.rendered_text;
  end if;
  if v_row.html is null
     or v_row.html not like '%https://wa.me/584140000000?text=%'
     or v_row.html not like '%Servicio Helios (20&nbsp;% + IVA)</strong> de $23.20%'
     or v_row.html not like '%Este comprobante no es una factura fiscal.%'
     or v_row.html not like '%Si no reconoces este financiamiento%'
     or v_row.html not like '%role="presentation"%' then
    raise exception 'Al HTML del comprobante le falta algo';
  end if;
  -- Ningún total con el fee: ni 123.20 ni la palabra «Total».
  if v_row.rendered_text like '%123.20%' or v_row.html like '%123.20%'
     or v_row.rendered_text ilike '%total%' or v_row.html ilike '%total%' then
    raise exception 'El comprobante no puede mostrar un total que sume el fee';
  end if;
  raise notice 'TEST CORREO 10 OK — comprobante completo, fee en línea aparte y sin total';

  -- --- 1. Sin clave → no-op --------------------------------------------------
  v_res := public.helios_dispatch_email_batch();
  if v_res->>'skipped' <> 'sin_clave' then
    raise exception 'Sin clave el despacho no debía hacer nada: %', v_res;
  end if;
  select * into v_row from public.outbound_messages where id = v_m1;
  if v_row.status <> 'pendiente' or v_row.attempts <> 0 or (select count(*) from _llamadas) <> 0 then
    raise exception 'Sin clave el correo debía seguir pendiente y sin intentos: %', to_jsonb(v_row);
  end if;
  v_res := public.helios_check_email_status();
  if v_res->>'skipped' <> 'sin_clave' then
    raise exception 'Sin clave la consulta de estado no debía hacer nada: %', v_res;
  end if;
  raise notice 'TEST CORREO 1 OK — sin clave no se toca nada';

  -- --- 2. Con clave, sin remitente → no-op ----------------------------------
  insert into _clave values ('re_prueba_no_es_real');
  v_res := public.helios_dispatch_email_batch();
  if v_res->>'skipped' <> 'sin_remitente' or (select count(*) from _llamadas) <> 0 then
    raise exception 'Sin remitente el despacho no debía hacer nada: %', v_res;
  end if;
  raise notice 'TEST CORREO 2 OK — sin remitente no se toca nada';

  update public.platform_contact set sender_email = 'avisos@prueba.helios.test' where id;

  -- --- 3. 2xx → enviado ------------------------------------------------------
  insert into _respuestas (status, body) values (200, '{"id":"re_msg_0001"}');
  v_res := public.helios_dispatch_email_batch();
  select * into v_row from public.outbound_messages where id = v_m1;
  if v_row.status <> 'enviado' or v_row.provider_id <> 're_msg_0001' or v_row.sent_at is null
     or v_row.attempts <> 1 or v_row.last_event <> 'sent' then
    raise exception 'Con 200 debía quedar enviado: % / %', to_jsonb(v_row), v_res;
  end if;
  select * into v_call from _llamadas order by n desc limit 1;
  if v_call.method <> 'POST' or v_call.path <> '/emails' or v_call.idem <> v_m1::text
     or v_call.api_key <> 're_prueba_no_es_real'
     or v_call.body->>'from' <> 'Helios <avisos@prueba.helios.test>'
     or v_call.body->'to'->>0 <> 'jose.correo@prueba.helios.test'
     or v_call.body->>'subject' is null or v_call.body->>'html' is null or v_call.body->>'text' is null
     or v_call.body->>'reply_to' <> 'soporte@prueba.helios.test' then
    raise exception 'La petición a Resend no es la esperada: %', to_jsonb(v_call);
  end if;

  -- Ya enviado: otra pasada no lo vuelve a mandar.
  select count(*) into v_n from _llamadas;
  perform public.helios_dispatch_email_batch();
  if (select count(*) from _llamadas) <> v_n then
    raise exception 'Un correo enviado no se vuelve a mandar';
  end if;
  raise notice 'TEST CORREO 3 OK — 200: enviado con provider_id e Idempotency-Key = id';

  -- --- 4. 4xx → fallido ------------------------------------------------------
  v_m2 := public.helios_enqueue_charge_receipt(v_charge);
  insert into _respuestas (status, body) values (422, '{"name":"validation_error","message":"Invalid `to` field"}');
  perform public.helios_dispatch_email_batch();
  select * into v_row from public.outbound_messages where id = v_m2;
  if v_row.status <> 'fallido' or v_row.last_error not like 'HTTP 422%' or v_row.attempts <> 1 then
    raise exception 'Con 422 debía quedar fallido: %', to_jsonb(v_row);
  end if;
  raise notice 'TEST CORREO 4 OK — 4xx: fallido con el motivo';

  -- --- 5. 429 y 5xx → reintento con espera creciente -----------------------
  v_m3 := public.helios_enqueue_charge_receipt(v_charge);
  insert into _respuestas (status, body) values (429, '{"name":"rate_limit_exceeded"}');
  perform public.helios_dispatch_email_batch();
  select * into v_row from public.outbound_messages where id = v_m3;
  if v_row.status <> 'pendiente' or v_row.attempts <> 1
     or v_row.next_attempt_at not between now() + interval '50 seconds' and now() + interval '70 seconds' then
    raise exception 'Con 429 debía esperar ~1 min: %', to_jsonb(v_row);
  end if;

  -- Antes de su hora no sale.
  select count(*) into v_n from _llamadas;
  perform public.helios_dispatch_email_batch();
  if (select count(*) from _llamadas) <> v_n then
    raise exception 'Un reintento no puede salir antes de next_attempt_at';
  end if;

  update public.outbound_messages set next_attempt_at = now() - interval '1 second' where id = v_m3;
  insert into _respuestas (status, body) values (503, 'Service Unavailable');
  perform public.helios_dispatch_email_batch();
  select * into v_row from public.outbound_messages where id = v_m3;
  if v_row.status <> 'pendiente' or v_row.attempts <> 2
     or v_row.next_attempt_at not between now() + interval '110 seconds' and now() + interval '130 seconds'
     or v_row.last_error not like 'HTTP 503%' then
    raise exception 'Con 503 debía esperar ~2 min: %', to_jsonb(v_row);
  end if;
  raise notice 'TEST CORREO 5 OK — 429/5xx: reintento a 1 y 2 minutos';

  -- --- 6. Se rinde al 6.º intento -------------------------------------------
  update public.outbound_messages set attempts = 5, next_attempt_at = now() - interval '1 second' where id = v_m3;
  insert into _respuestas (status, body) values (null, null);  -- timeout
  perform public.helios_dispatch_email_batch();
  select * into v_row from public.outbound_messages where id = v_m3;
  if v_row.status <> 'fallido' or v_row.attempts <> 6 or v_row.last_error not like 'Sin entregar a Resend tras 6 intentos%' then
    raise exception 'Al 6.º intento debía quedar fallido: %', to_jsonb(v_row);
  end if;
  raise notice 'TEST CORREO 6 OK — tras 6 intentos: fallido';

  -- --- 7. 401: la configuración, no el mensaje --------------------------------
  v_m4 := public.helios_enqueue_charge_receipt(v_charge);
  perform public.helios_enqueue_charge_receipt(v_charge);   -- otro más, que no debe salir
  select count(*) into v_n from _llamadas;
  insert into _respuestas (status, body) values (401, '{"name":"invalid_api_key"}');
  perform public.helios_dispatch_email_batch();
  if (select count(*) from _llamadas) <> v_n + 1 then
    raise exception 'Con 401 el lote debía cortarse en el primero';
  end if;
  select * into v_row from public.outbound_messages
   where charge_id = v_charge and status = 'pendiente' and attempts = 0 and last_error like '%HTTP 401%';
  if not found or v_row.next_attempt_at < now() + interval '14 minutes' then
    raise exception 'Con 401 el mensaje debía esperar 15 min sin gastar intento';
  end if;
  -- Para lo que sigue, que no estorben.
  update public.outbound_messages set status = 'cancelado'
   where charge_id = v_charge and status = 'pendiente';
  raise notice 'TEST CORREO 7 OK — 401: espera 15 min sin gastar intento y corta el lote';

  -- --- 8. Estado en Resend: entregado, luego rebotado -----------------------
  insert into _respuestas (status, body) values (200, '{"object":"email","id":"re_msg_0001","last_event":"delivered"}');
  v_res := public.helios_check_email_status();
  select * into v_row from public.outbound_messages where id = v_m1;
  if v_row.last_event <> 'delivered' or v_row.last_checked_at is null then
    raise exception 'Debía quedar delivered: % / %', to_jsonb(v_row), v_res;
  end if;
  select * into v_call from _llamadas order by n desc limit 1;
  if v_call.method <> 'GET' or v_call.path <> '/emails/re_msg_0001' then
    raise exception 'La consulta de estado debía ser GET /emails/{id}: %', to_jsonb(v_call);
  end if;

  -- Entregado y mirado hace poco: no se vuelve a preguntar todavía.
  select count(*) into v_n from _llamadas;
  perform public.helios_check_email_status();
  if (select count(*) from _llamadas) <> v_n then
    raise exception 'Un entregado recién consultado no se vuelve a consultar';
  end if;

  update public.outbound_messages set last_checked_at = now() - interval '7 hours' where id = v_m1;
  insert into _respuestas (status, body) values (200, '{"object":"email","id":"re_msg_0001","last_event":"bounced"}');
  perform public.helios_check_email_status();
  select * into v_row from public.outbound_messages where id = v_m1;
  if v_row.last_event <> 'bounced' then
    raise exception 'Debía quedar bounced: %', to_jsonb(v_row);
  end if;
  if (select email_invalid_at from public.profiles where id = v_pac) is null then
    raise exception 'Un rebote debía marcar email_invalid_at';
  end if;

  -- El siguiente comprobante a ese correo sale omitido.
  select * into v_row from public.outbound_messages where id = public.helios_enqueue_charge_receipt(v_charge);
  if v_row.status <> 'omitido' or v_row.last_error <> 'El correo del paciente rebotó' then
    raise exception 'Con el correo rebotado el comprobante debía salir omitido: %', to_jsonb(v_row);
  end if;

  -- Y la alerta aparece (el equipo la ve).
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  if not exists (
    select 1 from jsonb_array_elements(public.admin_risk_alerts(50, array['correo_rebotado'], v_pac) -> 'rows') r
    where r->>'subject_id' = v_pac::text and r->>'severity' = 'alta' and r->'detail'->>'event' = 'bounced'
  ) then
    raise exception 'El rebote debía crear la alerta correo_rebotado';
  end if;
  -- El historial filtra los rebotados.
  if not exists (select 1 from public.admin_outbound_history('email', 'rebotado', null, 50, 0) h
                 where h.id = v_m1 and h.last_event = 'bounced' and h.provider_id = 're_msg_0001')
     or exists (select 1 from public.admin_outbound_history('email', 'rebotado', null, 50, 0) h
                where h.last_event not in ('bounced', 'complained')) then
    raise exception 'El historial debía filtrar los rebotados';
  end if;
  raise notice 'TEST CORREO 8 OK — delivered, luego bounced → email_invalid_at, omitido y alerta';

  -- --- 9. admin_resend_receipt con corrección del correo --------------------
  v_res := public.admin_resend_receipt(v_charge, '  Jose.Nuevo@Prueba.Helios.Test ');
  if (v_res->>'email_changed')::boolean is not true or v_res->>'status' <> 'pendiente'
     or v_res->>'email_enmascarado' <> 'j***@prueba.helios.test' then
    raise exception 'El reenvío con correo nuevo no devolvió lo esperado: %', v_res;
  end if;
  if (select email from public.profiles where id = v_pac) <> 'jose.nuevo@prueba.helios.test'
     or (select email_invalid_at from public.profiles where id = v_pac) is not null then
    raise exception 'El correo debía corregirse y limpiar email_invalid_at';
  end if;
  if not exists (select 1 from audit.admin_actions
                 where action = 'patient.email_corrected' and target_id = v_pac and actor = v_admin
                   and detail->>'antes' = 'jose.correo@prueba.helios.test') then
    raise exception 'La corrección del correo debía quedar en la bitácora';
  end if;
  if not exists (select 1 from audit.admin_actions where action = 'receipt.resent' and target_id = v_charge) then
    raise exception 'El reenvío debía quedar en la bitácora';
  end if;

  -- Sin correo nuevo: solo reenvía.
  v_res := public.admin_resend_receipt(v_charge);
  if (v_res->>'email_changed')::boolean or v_res->>'status' <> 'pendiente' then
    raise exception 'El reenvío simple no devolvió lo esperado: %', v_res;
  end if;

  -- Un correo inválido se rechaza.
  begin
    perform public.admin_resend_receipt(v_charge, 'no-es-un-correo');
    raise exception 'Un correo inválido debía rechazarse';
  exception when sqlstate '22023' then null;
  end;

  -- Sin ser del equipo, no.
  perform set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
  begin
    perform public.admin_resend_receipt(v_charge);
    raise exception 'El personal de la clínica no usa admin_resend_receipt';
  exception when sqlstate '42501' then null;
  end;
  raise notice 'TEST CORREO 9 OK — admin_resend_receipt corrige el correo con bitácora y reencola';

  -- --- 11. Los crons --------------------------------------------------------
  if (select count(*) from cron.job
      where (jobname = 'helios_email_dispatch' and schedule = '* * * * *')
         or (jobname = 'helios_email_status' and schedule = '*/15 * * * *')) <> 2 then
    raise exception 'Faltan los crons del correo';
  end if;
  raise notice 'TEST CORREO 11 OK — crons de despacho (1 min) y estado (15 min)';
end;
$$;

set constraints all immediate;
rollback;
