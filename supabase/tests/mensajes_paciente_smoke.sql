-- ============================================================================
-- Helios — Prueba de humo de los mensajes al paciente (2026-10-19, docs/00 §15.8)
--
--   bash supabase/tests/run.sh mensajes_paciente_smoke
--
--   1. El nombre del médico: se guarda desde la ficha y se nombra con su
--      artículo; vacío, el nombre de la clínica.
--   2. El bloque de pago: los bolívares de hoy, cada dato en su línea, el RIF
--      con guiones y la frase de los niveles.
--   3. La pregunta nombra al médico y no dice bolívares.
--   4. El «Sí»: la bienvenida con las cuotas y cómo pagar la primera.
--   5. El «No», el «Sí» tardío y el «Sí» que no se puede confirmar: el
--      paciente recibe respuesta (si su ventana está abierta).
--   6. El resumen del bot: el médico, lo disponible y por qué es cero.
--   7. Pago confirmado y rechazado: también por WhatsApp con la ventana
--      abierta.
--
-- Nada de esto llama a `helios_dispatch_*`: los mensajes se quedan en la cola
-- de la transacción y se van con el rollback.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_op      uuid := gen_random_uuid();
  v_cajero  uuid := gen_random_uuid();
  v_m       uuid;
  v_bdate   date := public.helios_business_date(now());
  v_base    jsonb;
  v_j       jsonb;
  v_c1      uuid;
  v_c2      uuid;
  v_c3      uuid;
  v_c4      uuid;
  v_p1      uuid;
  v_p2      uuid;
  v_p3      uuid;
  v_i1      uuid;
  v_i2      uuid;
  v_rep     uuid;
  v_txt     text;
  v_bloque  text;
begin
  -- =========================================================================
  -- Preparación
  -- =========================================================================
  update public.platform_maintenance set is_active = false;
  update public.platform_contact set whatsapp_number = '+584140001122';
  insert into public.business_parameters (key, value, effective_from, note)
  values ('patient_confirmation_required', 1, v_bdate, 'prueba')
  on conflict (key, effective_from) do update set value = 1;
  perform public.record_fx_rate(800, v_bdate, 'BCV');

  if not public.helios_whatsapp_api_ready() then
    perform vault.create_secret('prueba', 'd360_api_key');
    perform vault.create_secret('https://waba-sandbox.360dialog.io/v1', 'd360_base_url');
  end if;

  insert into public.payment_destinations (method, bank_name, rif, phone, holder_name, is_active, sort_order)
  values ('pago_movil', 'BNC (0191)', 'J504967866', '04121714930', 'Quarto Latam, C.A.', true, 1);

  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at, raw_user_meta_data)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'msj-' || u || '@prueba.helios.test', now(), now(), now(), '{"full_name":"Ana Secretaria"}'
  from unnest(array[v_op, v_cajero]) u;
  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_op, 'operador', 'Operadora Mensajes', true);

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_m := (public.admin_create_merchant('Consultorio 999', null, 'J-400000099', 'consultorio')).id;
  reset role;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_m, (select id from public.merchant_branches where merchant_id = v_m and is_default), 'cajero');

  v_base := jsonb_build_object(
    'first_name', 'José', 'last_name', 'Pérez',
    'birth_date', (v_bdate - interval '30 years')::date,
    'sex', 'M', 'email', 'jose@gmail.com',
    'state', 'Miranda', 'city', 'Caracas', 'address', 'Los Palos Grandes',
    'reference_name', 'María Pérez', 'reference_phone', '02125551234', 'reference_relationship', 'Madre');

  -- =========================================================================
  -- 1. El nombre del médico
  -- =========================================================================
  if public.helios_person_name_text('jesus francisco VIVAS rodriguez') <> 'Jesus Francisco Vivas Rodriguez'
     or public.helios_person_name_text('Elizabeth Del valle  ponte Castillo') <> 'Elizabeth del Valle Ponte Castillo'
     or public.helios_person_name_text('DR. VICTOR GÓMEZ') <> 'Victor Gómez'
     or public.helios_person_name_text('  ') is not null then
    raise exception 'El nombre del titular no se arregla como se espera';
  end if;

  update public.merchants set owner_name = null where id = v_m;
  if public.helios_doctor_ref(v_m) <> 'Consultorio 999' then
    raise exception 'Sin titular debía usarse el nombre de la clínica: %', public.helios_doctor_ref(v_m);
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_set_merchant_owner(v_m, '{"owner_name":"ANA prueba"}'::jsonb);
  if public.admin_merchant_detail(v_m)->'profile'->>'doctor_name' <> 'Ana Prueba' then
    raise exception 'Sin título, el nombre del titular solo: %', public.admin_merchant_detail(v_m)->'profile';
  end if;
  perform public.admin_set_merchant_owner(v_m, '{"doctor_title":"Dra."}'::jsonb);
  if public.admin_merchant_detail(v_m)->'profile'->>'doctor_title' <> 'Dra.'
     or public.admin_merchant_detail(v_m)->'profile'->>'doctor_name' <> 'Dra. Ana Prueba' then
    raise exception 'La ficha debía devolver el título y cómo lo leen sus pacientes: %', public.admin_merchant_detail(v_m)->'profile';
  end if;
  begin
    perform public.admin_set_merchant_owner(v_m, '{"doctor_title":"Doctora"}'::jsonb);
    raise exception 'Un título fuera de la lista debía rechazarse';
  exception when sqlstate '22023' then null;
  end;
  reset role;

  if public.helios_doctor_ref(v_m) <> 'la Dra. Ana Prueba' then
    raise exception 'El médico debía ir con su artículo: %', public.helios_doctor_ref(v_m);
  end if;
  update public.merchants set doctor_title = 'Dr.' where id = v_m;
  if public.helios_doctor_ref(v_m) <> 'el Dr. Ana Prueba' then
    raise exception 'Un Dr. va con «el»: %', public.helios_doctor_ref(v_m);
  end if;
  update public.merchants set doctor_title = 'Dra.' where id = v_m;
  raise notice 'TEST MENSAJES 1 OK — el nombre del médico titular, con su título';

  -- =========================================================================
  -- 2. El bloque de pago
  -- =========================================================================
  if public.helios_rif_text('J504967866') <> 'J-50496786-6' or public.helios_rif_text('V12345678') <> 'V12345678' then
    raise exception 'El RIF debía ir con guiones (y una cédula, tal cual)';
  end if;
  v_bloque := public.helios_payment_block(45568.00, '$56,96', 'dólar');
  if v_bloque <> E'💵 *Monto en bolívares hoy: Bs 45.568,00*\n'
                || E'Es el equivalente a $56,96 a la tasa BCV del dólar de hoy. Si pagas otro día, paga el equivalente a la tasa BCV de ese día.\n\n'
                || E'🏦 *Pago Móvil*\nBanco: BNC (0191)\nTeléfono: 0412-1714930\nRIF: J-50496786-6\nTitular: Quarto Latam, C.A.\n\n'
                || E'📸 Cuando pagues, envíanos la foto del comprobante por este chat.\n\n'
                || '⭐ Recuerda pagar a tiempo para subir de nivel y disponer de mayores beneficios.' then
    raise exception 'El bloque de pago no es el esperado: %', v_bloque;
  end if;
  if public.helios_payment_block(null, '€10', 'euro') not like E'💵 *Monto en bolívares*\nPagas el equivalente a €10 a la tasa BCV del euro del día en que pagues.%' then
    raise exception 'Sin tasa, el bloque debía decir «del día en que pagues»';
  end if;
  if public.helios_message_builtins(null)->>'pago_movil_rif' <> 'J-50496786-6' then
    raise exception 'Las variables sueltas del Pago Móvil (para las plantillas _v2) no salen';
  end if;
  raise notice 'TEST MENSAJES 2 OK — el bloque de pago';

  -- =========================================================================
  -- 3. La pregunta
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V20000101');
  v_j := public.create_patient_charge(v_m, null,
           v_base || jsonb_build_object('document', 'V20000101', 'phone', '04141230001'), 100, 'Consulta', null, 'msj-1');
  reset role;
  v_c1 := (v_j->>'id')::uuid;
  select user_id into v_p1 from public.charges where id = v_c1;

  select rendered_text into v_txt from public.outbound_messages
  where charge_id = v_c1 and template_key = 'confirmar_financiamiento';
  if v_txt not like '👋 ¡Hola, José! Te damos la bienvenida a Helios 💙%'
     or v_txt not like '%Tu consulta con la Dra. Ana Prueba quedó registrada para que la pagues en *2 cuotas, sin inicial*.%'
     or v_txt not like '%*Total: $113,92*%'
     or v_txt not like '%📅 $56,96 · %'
     or v_txt like '%Bs %' or v_txt like '%Consultorio 999%' then
    raise exception 'La pregunta no dice lo esperado: %', v_txt;
  end if;
  raise notice 'TEST MENSAJES 3 OK — la pregunta';

  -- =========================================================================
  -- 4. El «Sí»: la bienvenida con cómo pagar la primera cuota
  -- =========================================================================
  insert into public.whatsapp_contacts (phone_e164, last_inbound_at)
  select public.helios_wa_e164(p.phone_e164), now() from public.profiles p where p.id = v_p1
  on conflict (phone_e164) do update set last_inbound_at = now();

  v_j := public.helios_patient_decision(v_c1, 'si', '584141230001', 'wamid.msj.1');
  if v_j->>'status' <> 'confirmed' then
    raise exception 'El «Sí» debía confirmar: %', v_j;
  end if;
  select rendered_text into v_txt from public.outbound_messages
  where charge_id = v_c1 and template_key = 'bienvenida';
  if v_txt not like '✅ ¡Listo, José! Tu pago en cuotas #% con la Dra. Ana Prueba está confirmado.%'
     or v_txt not like '%1️⃣ $56,96 · %' or v_txt not like '%2️⃣ $56,96 · %'
     -- 56,96 × 800 = 45.568,00
     or v_txt not like '%Monto en bolívares hoy: Bs 45.568,00*%'
     or v_txt not like '%Banco: BNC (0191)%'
     or v_txt not like '%subir de nivel%' then
    raise exception 'La bienvenida no dice lo esperado: %', v_txt;
  end if;
  raise notice 'TEST MENSAJES 4 OK — la bienvenida con los datos de pago';

  -- =========================================================================
  -- 5. El «No», el «Sí» tardío y el «Sí» que no se puede confirmar
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V20000102');
  v_c2 := (public.create_patient_charge(v_m, null,
             v_base || jsonb_build_object('document', 'V20000102', 'first_name', 'Luis', 'phone', '04141230002'),
             50, null, null, 'msj-2')->>'id')::uuid;
  perform public.helios_patient_eligibility(v_m, 'V20000103');
  v_c3 := (public.create_patient_charge(v_m, null,
             v_base || jsonb_build_object('document', 'V20000103', 'first_name', 'Rosa', 'phone', '04141230003'),
             50, null, null, 'msj-3')->>'id')::uuid;
  reset role;
  select user_id into v_p2 from public.charges where id = v_c2;
  select user_id into v_p3 from public.charges where id = v_c3;
  insert into public.whatsapp_contacts (phone_e164, last_inbound_at)
  select public.helios_wa_e164(p.phone_e164), now() from public.profiles p where p.id in (v_p2, v_p3)
  on conflict (phone_e164) do update set last_inbound_at = now();

  perform public.helios_patient_decision(v_c2, 'no', '584141230002', 'wamid.msj.2');
  if not exists (select 1 from public.outbound_messages
                  where profile_id = v_p2 and template_key = 'bot_paciente'
                    and rendered_text = E'Entendido, Luis. No se registró ningún pago en cuotas y no debes nada 💙\nSi fue un error, pídele a la Dra. Ana Prueba que te lo envíe de nuevo.') then
    raise exception 'El «No» debía tener respuesta: %',
      (select string_agg(rendered_text, ' | ') from public.outbound_messages where profile_id = v_p2);
  end if;

  update public.charges set expires_at = now() - interval '1 minute' where id = v_c3;
  v_j := public.helios_patient_decision(v_c3, 'si', '584141230003', 'wamid.msj.3');
  if v_j->>'reason' <> 'vencida'
     or not exists (select 1 from public.outbound_messages
                     where profile_id = v_p3 and template_key = 'bot_paciente'
                       and rendered_text like 'Rosa, esta solicitud venció porque pasaron más de 2 horas ⌛.%pídele a la Dra. Ana Prueba que te la envíe otra vez.') then
    raise exception 'El «Sí» tardío debía tener respuesta: %', v_j;
  end if;
  -- Y un «sí» escrito después: el bot sabe qué contestar.
  if public.bot_paciente_contexto('584141230003')->>'vencida_texto' not like 'Rosa, esta solicitud venció%' then
    raise exception 'El contexto del bot debía traer la respuesta a la orden vencida';
  end if;

  -- José debe una cuota (la primera vence ayer) y otra orden suya espera.
  select id into v_i1 from public.installments where charge_id = v_c1 and sequence = 1;
  select id into v_i2 from public.installments where charge_id = v_c1 and sequence = 2;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V20000101');
  v_c4 := (public.create_patient_charge(v_m, null,
             v_base || jsonb_build_object('document', 'V20000101', 'phone', '04141230001'), 20, null, null, 'msj-4')->>'id')::uuid;
  reset role;
  update public.installments set due_date = v_bdate - 1 where id = v_i1;
  v_j := public.helios_patient_decision(v_c4, 'si', '584141230001', 'wamid.msj.4');
  if v_j->>'reason' <> 'no_disponible'
     or not exists (select 1 from public.outbound_messages
                     where profile_id = v_p1 and template_key = 'bot_paciente'
                       and rendered_text like 'José, no pudimos confirmar este pago en cuotas porque tienes una cuota pendiente.%'
                       and wa_template->'buttons'->0->>'id' = 'paciente:pagar') then
    raise exception 'El «Sí» con una cuota vencida debía explicar por qué y ofrecer pagar: %', v_j;
  end if;
  raise notice 'TEST MENSAJES 5 OK — el No, el Sí tardío y el Sí que no se confirma tienen respuesta';

  -- =========================================================================
  -- 6. El resumen del bot
  -- =========================================================================
  v_j := public.bot_paciente_resumen(v_p1);
  if v_j->'financiamientos'->0->>'medico' <> 'Dra. Ana Prueba'
     or v_j->'financiamientos'->0->>'medico_ref' <> 'la Dra. Ana Prueba'
     or jsonb_array_length(v_j->'financiamientos'->0->'pagadas') <> 0
     or (v_j->>'disponible_usd')::numeric <> 0 or v_j->>'bloqueo' <> 'cuota_vencida'
     or v_j->>'datos_de_pago' not like '🏦 *Pago Móvil*%'
     -- 2026-10-23: el nivel y el saldo total (el tope de su nivel); ya no
     -- trae los pagos terminados.
     or (v_j->>'nivel')::integer <> 1 or v_j->>'nivel_nombre' <> 'Nivel 1'
     or (v_j->>'limite_usd')::numeric <> (select monthly_limit_usd from public.levels where level = 1)
     or v_j ? 'terminados' then
    raise exception 'El resumen del bot no trae lo esperado: %', v_j;
  end if;
  raise notice 'TEST MENSAJES 6 OK — el resumen del bot';

  -- =========================================================================
  -- 7. Pago confirmado y rechazado, también por WhatsApp
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_register_payment(v_p1, array[v_i1], 'pago_movil', 'Banesco', 'MSJ-1', v_bdate,
           (public.admin_payment_preview(v_p1, array[v_i1], v_bdate)->>'amount_ves')::numeric, null, null);
  v_rep := (v_j->>'report_id')::uuid;
  perform public.admin_reconcile_payment(v_rep, true, null);

  v_j := public.admin_register_payment(v_p1, array[v_i2], 'pago_movil', 'Banesco', 'MSJ-2', v_bdate,
           (public.admin_payment_preview(v_p1, array[v_i2], v_bdate)->>'amount_ves')::numeric, null, null);
  perform public.admin_reconcile_payment((v_j->>'report_id')::uuid, false, 'la referencia no aparece en el banco');
  reset role;

  if not exists (select 1 from public.outbound_messages
                  where profile_id = v_p1 and template_key = 'bot_paciente'
                    -- Con las gracias y la frase de niveles (20261023120000).
                    and rendered_text like E'✅ ¡Gracias por tu pago, José! Ya está confirmado 💙\nRecibimos $56,96 de tu orden #% con la Dra. Ana Prueba.\n\nTe queda: 2.ª cuota de $56,96 · %\n\n⭐ Si pagas a tiempo, puedes subir de nivel y aumentar tu saldo máximo.') then
    raise exception 'El pago confirmado debía llegar por WhatsApp: %',
      (select string_agg(rendered_text, ' | ') from public.outbound_messages where profile_id = v_p1 and template_key = 'bot_paciente');
  end if;
  if not exists (select 1 from public.outbound_messages
                  where profile_id = v_p1 and template_key = 'bot_paciente'
                    and rendered_text like E'José, no pudimos confirmar el pago que nos enviaste 😕\nMotivo: la referencia no aparece en el banco%'
                    and wa_template->'buttons'->0->>'id' = 'paciente:ayuda') then
    raise exception 'El pago rechazado debía llegar por WhatsApp con «Hablar con alguien»';
  end if;

  -- Con la ventana cerrada, solo el correo.
  update public.whatsapp_contacts set last_inbound_at = now() - interval '2 days'
   where phone_e164 = (select public.helios_wa_e164(phone_e164) from public.profiles where id = v_p1);
  perform public.helios_tell_patient(v_p1, 'hola');
  if exists (select 1 from public.outbound_messages
                 where profile_id = v_p1 and template_key = 'bot_paciente' and rendered_text = 'hola') then
    raise exception 'Con la ventana cerrada no se le escribe';
  end if;
  raise notice 'TEST MENSAJES 7 OK — pago confirmado y rechazado por WhatsApp con la ventana abierta';
end $$;

set constraints all immediate;
rollback;
