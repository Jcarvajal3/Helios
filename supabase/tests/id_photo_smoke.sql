-- ============================================================================
-- Helios — Prueba de humo de la foto de la cédula (2026-11-02, docs/00 §15.11)
--
--   bash supabase/tests/run.sh id_photo_smoke
--
--   1. Sin foto, el «Sí» no confirma: la orden sigue pendiente, queda
--      «aceptó, falta la cédula» y se le pide la foto (texto aprobado).
--   2. Lo que no es la foto esperada sigue su camino: otro teléfono, una
--      imagen sin «Sí» antes, un archivo que no es imagen ni PDF (se le
--      vuelve a pedir).
--   3. La foto confirma por el camino del «Sí»: cuotas, la foto en su perfil
--      y en la cola del lector, el acuse ANTES de la bienvenida; un reintento
--      no repite nada.
--   4. Con la foto guardada, su siguiente orden se confirma con «Sí».
--   5. La foto que llega con la orden vencida se guarda y se le dice lo de
--      siempre.
--   6. El lector: toma la cola, compara número y nombre, falla tres veces;
--      lo que no cuadra sale en superadmin › Alertas.
--   7. Privacidad: la clínica no ve nada; el equipo ve la foto y abrirla
--      queda en la bitácora; solo el webhook la registra.
--   8. El reinicio de la capacitación (20261104120000): el de medianoche y
--      el de un número borran la foto y dejan el archivo por borrar; la misma
--      cédula y la misma imagen sirven en otra ronda.
--
-- Nada de esto llama a `helios_dispatch_*`: los mensajes se quedan en la cola
-- de la transacción y se van con el rollback.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_cajero  uuid := gen_random_uuid();
  v_m       uuid;
  v_bdate   date := public.helios_business_date(now());
  v_base    jsonb;
  v_j       jsonb;
  v_c1      uuid;
  v_c2      uuid;
  v_c3      uuid;
  v_p1      uuid;
  v_p3      uuid;
  v_f1      uuid;
  v_f3      uuid;
  v_demo    uuid;
  v_row     record;
  v_txt     text;
  v_failed  boolean;
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

  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at, raw_user_meta_data)
  values (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ced-' || v_cajero || '@prueba.helios.test', now(), now(), now(), '{"full_name":"Ana Secretaria"}');

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_m := (public.admin_create_merchant('Consultorio Cédula', null, 'J-400000098', 'consultorio')).id;
  reset role;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_m, (select id from public.merchant_branches where merchant_id = v_m and is_default), 'cajero');

  v_base := jsonb_build_object(
    'first_name', 'José', 'last_name', 'Pérez',
    'birth_date', (v_bdate - interval '30 years')::date,
    'sex', 'M', 'email', 'jose@gmail.com',
    'state', 'Miranda', 'city', 'Caracas', 'address', 'Los Palos Grandes',
    'reference_name', 'María Pérez', 'reference_phone', '02125551234', 'reference_relationship', 'Madre');

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V20000201');
  v_c1 := (public.create_patient_charge(v_m, null,
             v_base || jsonb_build_object('document', 'V20000201', 'phone', '04141230201'), 100, 'Consulta', null, 'ced-1')->>'id')::uuid;
  reset role;
  select user_id into v_p1 from public.charges where id = v_c1;

  -- La ventana de 24 h de su número, abierta: se le puede contestar.
  insert into public.whatsapp_contacts (phone_e164, last_inbound_at)
  values ('+584141230201', now())
  on conflict (phone_e164) do update set last_inbound_at = now();

  -- =========================================================================
  -- 1. Sin foto, el «Sí» pide la foto
  -- =========================================================================
  if not public.helios_patient_needs_id_photo(v_p1) then
    raise exception 'Un paciente nuevo no tiene foto de su cédula';
  end if;

  v_j := public.helios_patient_decision(v_c1, 'si', '584141230201', 'wamid.ced.si.1');
  select * into v_row from public.charges where id = v_c1;
  if not (v_j->>'ok')::boolean or v_j->>'status' <> 'pending' or v_j->>'reason' <> 'pide_cedula'
     or v_row.status <> 'pending' or v_row.id_photo_requested_at is null
     or v_row.answered_at is not null or v_row.answer_wa_message_id is not null
     or exists (select 1 from public.installments where charge_id = v_c1) then
    raise exception 'Sin foto, el «Sí» no confirma: debía pedir la foto: % %', v_j, to_jsonb(v_row);
  end if;
  if not exists (select 1 from public.outbound_messages
                  where profile_id = v_p1 and template_key = 'bot_paciente'
                    and rendered_text = 'Para confirmar tu pago en cuotas necesitamos una foto de tu cédula 🪪. Envíala por aquí.') then
    raise exception 'Debía pedírsele la foto con el texto aprobado: %',
      (select string_agg(rendered_text, ' | ') from public.outbound_messages where profile_id = v_p1);
  end if;

  -- Un segundo «sí» escrito: se le vuelve a pedir; la hora de la primera se queda.
  v_j := public.helios_patient_decision(v_c1, 'si', '584141230201', 'wamid.ced.si.2');
  if v_j->>'reason' <> 'pide_cedula'
     or (select id_photo_requested_at from public.charges where id = v_c1) <> v_row.id_photo_requested_at
     or (select count(*) from public.outbound_messages
          where profile_id = v_p1 and rendered_text like 'Para confirmar tu pago en cuotas necesitamos%') <> 2 then
    raise exception 'Otro «sí» sin foto debía pedirla otra vez: %', v_j;
  end if;
  raise notice 'TEST CÉDULA 1 OK — sin foto, el «Sí» la pide';

  -- =========================================================================
  -- 2. Lo que no es la foto esperada
  -- =========================================================================
  v_j := public.helios_patient_id_photo('584149999999', 'wamid.ced.otro', 'media-otro', 'image/jpeg');
  if (v_j->>'handled')::boolean or v_j->>'reason' <> 'no_esperada' then
    raise exception 'Una foto de otro teléfono no es la cédula esperada: %', v_j;
  end if;

  -- Otro paciente con su orden pendiente, sin haber tocado «Sí»: su imagen es
  -- otra cosa (un comprobante) y sigue al bot.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V20000203');
  v_c3 := (public.create_patient_charge(v_m, null,
             v_base || jsonb_build_object('document', 'V20000203', 'first_name', 'Rosa', 'last_name', 'Díaz',
                                          'phone', '04141230203'), 50, null, null, 'ced-3')->>'id')::uuid;
  reset role;
  select user_id into v_p3 from public.charges where id = v_c3;
  insert into public.whatsapp_contacts (phone_e164, last_inbound_at)
  values ('+584141230203', now())
  on conflict (phone_e164) do update set last_inbound_at = now();

  v_j := public.helios_patient_id_photo('584141230203', 'wamid.ced.sin.si', 'media-sin-si', 'image/jpeg');
  if (v_j->>'handled')::boolean then
    raise exception 'Sin «Sí» antes, una imagen no es la cédula: %', v_j;
  end if;

  -- Un archivo que no es imagen ni PDF: se le vuelve a pedir y no se guarda.
  v_j := public.helios_patient_id_photo('584141230201', 'wamid.ced.docx', 'media-docx',
           'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
  if not (v_j->>'handled')::boolean or v_j->>'reason' <> 'formato'
     or exists (select 1 from public.patient_id_photos where profile_id = v_p1)
     or (select status::text from public.charges where id = v_c1) <> 'pending'
     or (select count(*) from public.outbound_messages
          where profile_id = v_p1 and rendered_text like 'Para confirmar tu pago en cuotas necesitamos%') <> 3 then
    raise exception 'Un archivo que no es foto debía pedirla otra vez sin guardarlo: %', v_j;
  end if;
  raise notice 'TEST CÉDULA 2 OK — lo que no es la foto esperada sigue su camino';

  -- =========================================================================
  -- 3. La foto confirma
  -- =========================================================================
  v_j := public.helios_patient_id_photo('+58 414 123 0201', 'wamid.HBg=ced/1', 'media-ced-1', 'image/jpeg');
  select * into v_row from public.charges where id = v_c1;
  if not (v_j->>'ok')::boolean or not (v_j->>'handled')::boolean or v_j->>'status' <> 'confirmed'
     or v_row.status <> 'confirmed' or v_row.answer_wa_message_id <> 'wamid.HBg=ced/1'
     or (select count(*) from public.installments where charge_id = v_c1) <> 2 then
    raise exception 'La foto debía confirmar la orden: % %', v_j, to_jsonb(v_row);
  end if;
  v_f1 := (v_j->>'id_photo_id')::uuid;

  select * into v_row from public.patient_id_photos where id = v_f1;
  if v_row.profile_id <> v_p1 or v_row.charge_id <> v_c1 or v_row.status <> 'pendiente'
     or v_row.media_id <> 'media-ced-1' or v_row.stored_at is not null
     or v_row.storage_path <> v_p1 || '/wamid.HBg_ced_1.jpg' then
    raise exception 'La foto no quedó en la cola del lector: %', to_jsonb(v_row);
  end if;
  if (select id_photo_path from public.profiles where id = v_p1) <> v_p1 || '/wamid.HBg_ced_1.jpg'
     or (select id_photo_wa_message_id from public.profiles where id = v_p1) <> 'wamid.HBg=ced/1'
     or public.helios_patient_needs_id_photo(v_p1) then
    raise exception 'La foto debía quedar como la de su perfil';
  end if;

  -- El acuse, antes que la bienvenida.
  select * into v_row from public.outbound_messages
  where profile_id = v_p1 and rendered_text like '✅ ¡Gracias%';
  if v_row.id is null
     or v_row.rendered_text <> '✅ ¡Gracias, José! Recibimos tu cédula y tu pago en cuotas quedó confirmado.'
     or v_row.next_attempt_at >= (select next_attempt_at from public.outbound_messages
                                   where charge_id = v_c1 and template_key = 'bienvenida') then
    raise exception 'El acuse debía salir antes de la bienvenida: %', to_jsonb(v_row);
  end if;

  -- Un reintento de 360dialog: nada se repite.
  v_j := public.helios_patient_id_photo('584141230201', 'wamid.HBg=ced/1', 'media-ced-1', 'image/jpeg');
  if not (v_j->>'duplicate')::boolean or (v_j->>'id_photo_id')::uuid <> v_f1
     or (select count(*) from public.patient_id_photos where profile_id = v_p1) <> 1
     or (select count(*) from public.outbound_messages where profile_id = v_p1 and rendered_text like '✅ ¡Gracias%') <> 1 then
    raise exception 'Un reintento no debía repetir nada: %', v_j;
  end if;
  raise notice 'TEST CÉDULA 3 OK — la foto confirma y el acuse va primero';

  -- =========================================================================
  -- 4. Con la foto guardada, «Sí» como siempre
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_c2 := (public.create_patient_charge(v_m, null, jsonb_build_object('document', 'V20000201'), 20, null, null, 'ced-2')->>'id')::uuid;
  reset role;
  v_j := public.helios_patient_decision(v_c2, 'si', '584141230201', 'wamid.ced.si.3');
  if v_j->>'status' <> 'confirmed' or (select id_photo_requested_at from public.charges where id = v_c2) is not null then
    raise exception 'Con la foto guardada, el «Sí» confirma: %', v_j;
  end if;
  raise notice 'TEST CÉDULA 4 OK — con foto, «Sí» como siempre';

  -- =========================================================================
  -- 5. La foto con la orden vencida
  -- =========================================================================
  v_j := public.helios_patient_decision(v_c3, 'si', '584141230203', 'wamid.ced.si.rosa');
  if v_j->>'reason' <> 'pide_cedula' then
    raise exception 'Rosa no tiene foto: su «Sí» debía pedirla: %', v_j;
  end if;
  update public.charges set expires_at = now() - interval '1 minute' where id = v_c3;

  v_j := public.helios_patient_id_photo('584141230203', 'wamid.ced.rosa', 'media-rosa', 'application/pdf');
  v_f3 := (v_j->>'id_photo_id')::uuid;
  if not (v_j->>'handled')::boolean or v_j->>'reason' <> 'vencida'
     or (select status::text from public.charges where id = v_c3) <> 'expired'
     or (select storage_path from public.patient_id_photos where id = v_f3) <> v_p3 || '/wamid.ced.rosa.pdf'
     or public.helios_patient_needs_id_photo(v_p3)
     or not exists (select 1 from public.outbound_messages
                     where profile_id = v_p3 and rendered_text like 'Rosa, esta solicitud venció porque pasaron más de 2 horas ⌛.%')
     or exists (select 1 from public.outbound_messages where profile_id = v_p3 and rendered_text like '✅ ¡Gracias%') then
    raise exception 'Con la orden vencida, la foto se guarda y se le dice lo de siempre: %', v_j;
  end if;

  -- Ya tiene foto: otra imagen suya es otra cosa.
  v_j := public.helios_patient_id_photo('584141230203', 'wamid.ced.rosa.2', 'media-rosa-2', 'image/jpeg');
  if (v_j->>'handled')::boolean then
    raise exception 'Con su foto guardada, otra imagen no es la cédula: %', v_j;
  end if;
  raise notice 'TEST CÉDULA 5 OK — la foto con la orden vencida se guarda';

  -- =========================================================================
  -- 6. El lector
  -- =========================================================================
  if public.helios_palabras_del_nombre('MARÍA DE LOS ÁNGELES  Pérez-Núñez') <> array['angeles', 'maria', 'nunez', 'perez']
     or not (public.helios_palabras_del_nombre('José Pérez') <@ public.helios_palabras_del_nombre('PEREZ RODRIGUEZ JOSE GREGORIO')) then
    raise exception 'Las palabras del nombre no son las esperadas';
  end if;

  v_j := public.lector_cedula_tomar(10);
  if not exists (select 1 from jsonb_array_elements(v_j) e
                  where (e->>'id')::uuid = v_f1 and e->>'ruta' = v_p1 || '/wamid.HBg_ced_1.jpg'
                    and e->>'media_id' = 'media-ced-1' and not (e->>'guardada')::boolean)
     or (select status from public.patient_id_photos where id = v_f1) <> 'leyendo' then
    raise exception 'El lector debía tomar la foto: %', v_j;
  end if;

  -- José: el número con puntos y su nombre entre más nombres → coincide.
  v_txt := public.lector_cedula_leida(v_f1,
       '{"es_cedula": true, "numero": "V-20.000.201", "nombres": "JOSE GREGORIO", "apellidos": "PEREZ RODRIGUEZ"}',
       'claude-prueba', '{}');
  if v_txt <> 'coincide'
     or (select stored_at from public.patient_id_photos where id = v_f1) is null
     or (select read_number from public.patient_id_photos where id = v_f1) <> 'V-20.000.201' then
    raise exception 'La cédula de José debía coincidir: %', (select to_jsonb(f) from public.patient_id_photos f where id = v_f1);
  end if;

  -- Rosa: el número no es el suyo → no coincide.
  if (select status from public.patient_id_photos where id = v_f3) <> 'leyendo' then
    raise exception 'El lector debía haber tomado también la de Rosa';
  end if;
  v_txt := public.lector_cedula_leida(v_f3,
       '{"es_cedula": true, "numero": "V-9.999.999", "nombres": "ROSA", "apellidos": "DIAZ"}', 'claude-prueba', '{}');
  if v_txt <> 'no_coincide'
     or (select reason from public.patient_id_photos where id = v_f3) <> 'numero' then
    raise exception 'Otro número no coincide: %', (select to_jsonb(f) from public.patient_id_photos f where id = v_f3);
  end if;

  -- Lo que no es una cédula, y una que no se pudo bajar en tres intentos.
  insert into public.patient_id_photos (profile_id, charge_id, wa_message_id, phone_e164, media_id, mime, storage_path, status, attempts, taken_at)
  values (v_p3, v_c3, 'wamid.ced.gato', '+584141230203', 'media-gato', 'image/jpeg', v_p3 || '/gato.jpg', 'leyendo', 1, now())
  returning id into v_f3;
  if public.lector_cedula_leida(v_f3, '{"es_cedula": false, "numero": null, "nombres": null, "apellidos": null}', 'x', '{}')
     <> 'no_es_cedula' then
    raise exception 'Lo que no es una cédula debía decirlo';
  end if;

  update public.profiles set id_photo_wa_message_id = 'wamid.ced.perdida' where id = v_p3;
  insert into public.patient_id_photos (profile_id, wa_message_id, phone_e164, media_id, mime, storage_path, status, attempts, taken_at)
  values (v_p3, 'wamid.ced.perdida', '+584141230203', 'media-perdida', 'image/jpeg', v_p3 || '/perdida.jpg', 'leyendo', 1, now())
  returning id into v_f3;
  v_txt := public.lector_cedula_fallo(v_f3, 'prueba 1');
  if v_txt <> 'pendiente'
     or public.helios_patient_needs_id_photo(v_p3) then
    raise exception 'Un primer fallo se reintenta';
  end if;
  update public.patient_id_photos set status = 'leyendo', attempts = 3 where id = v_f3;
  v_txt := public.lector_cedula_fallo(v_f3, 'prueba 3');
  if v_txt <> 'no_se_pudo_bajar'
     or not public.helios_patient_needs_id_photo(v_p3) then
    raise exception 'Al tercer fallo sin bajarla, el perfil vuelve a no tener foto';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_risk_alerts(200, array['cedula_no_coincide'], v_p3);
  if (v_j->'counts'->'cedula_no_coincide'->>'total')::integer <> 3
     or not exists (select 1 from jsonb_array_elements(v_j->'rows') r
                     where r->>'kind' = 'cedula_no_coincide' and r->>'severity' = 'alta'
                       and r->'detail'->>'status' = 'no_coincide' and r->'detail'->>'reason' = 'numero'
                       and r->'detail'->>'document' = 'V20000203' and r->>'user_id' = v_p3::text)
     or not exists (select 1 from jsonb_array_elements(v_j->'rows') r
                     where r->'detail'->>'status' = 'no_se_pudo_bajar' and r->>'severity' = 'media') then
    raise exception 'Lo que no cuadra debía salir en Alertas: %', v_j;
  end if;
  if (public.admin_risk_alerts(200, array['cedula_no_coincide'], v_p1)->'counts'->'cedula_no_coincide'->>'total')::integer <> 0 then
    raise exception 'La cédula que coincide no da alerta';
  end if;
  v_txt := (select r->>'alert_key' from jsonb_array_elements(v_j->'rows') r
             where r->'detail'->>'status' = 'no_coincide' limit 1);
  perform public.admin_review_risk_alert(v_txt, 'La llamamos: era su cédula vieja');
  reset role;
  raise notice 'TEST CÉDULA 6 OK — el lector compara y lo que no cuadra va a Alertas';

  -- =========================================================================
  -- 7. Privacidad
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform 1 from public.patient_id_photos limit 1;
  exception when insufficient_privilege then v_failed := true; end;
  if not v_failed then
    raise exception 'La clínica no puede leer las fotos';
  end if;
  v_failed := false;
  begin
    perform public.admin_patient_id_photo(v_p1);
  exception when insufficient_privilege then v_failed := true; end;
  if not v_failed then
    raise exception 'La clínica no puede ver la foto de un paciente';
  end if;
  v_failed := false;
  begin
    perform public.helios_patient_id_photo('584141230201', 'wamid.ced.panel', 'm', 'image/jpeg');
  exception when insufficient_privilege then v_failed := true; end;
  if not v_failed then
    raise exception 'Solo el webhook registra la foto';
  end if;
  if exists (select 1 from storage.objects where bucket_id = 'patient-ids') then
    raise exception 'La clínica no puede listar el bucket de las cédulas';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_patient_id_photo(v_p1);
  if not (v_j->>'has_photo')::boolean or v_j->>'status' <> 'coincide' or not (v_j->>'stored')::boolean
     or v_j->>'read_name' <> 'JOSE GREGORIO PEREZ RODRIGUEZ' then
    raise exception 'El equipo debía ver la foto y lo que leyó el lector: %', v_j;
  end if;
  v_j := public.admin_open_patient_id_photo(v_p1);
  if v_j->>'bucket' <> 'patient-ids' or v_j->>'path' <> v_p1 || '/wamid.HBg_ced_1.jpg' then
    raise exception 'Abrir la foto debía dar su ruta en el bucket: %', v_j;
  end if;
  v_j := public.admin_patient_id_photo(v_p3);
  if (v_j->>'has_photo')::boolean or not (v_j->>'needs_photo')::boolean or v_j->>'photo_id' is null then
    raise exception 'Sin foto en su perfil, la ficha lo dice y enseña la última que mandó: %', v_j;
  end if;
  reset role;

  if not exists (select 1 from audit.admin_actions
                  where action = 'patient.id_photo_viewed' and target_id = v_p1 and actor = v_admin) then
    raise exception 'Abrir la foto debía quedar en la bitácora';
  end if;
  raise notice 'TEST CÉDULA 7 OK — solo el equipo la ve, y queda en la bitácora';

  -- =========================================================================
  -- 8. El reinicio de la capacitación
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_add_demo_phone('0412 999 0102', 'Carla');
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V99000011');
  v_c2 := (public.create_patient_charge(v_m, null,
             v_base || jsonb_build_object('document', 'V99000011', 'phone', '04129990102'), 30, null, null, 'ced-demo-1')->>'id')::uuid;
  reset role;
  select user_id into v_demo from public.charges where id = v_c2;
  insert into public.whatsapp_contacts (phone_e164, last_inbound_at)
  values ('+584129990102', now())
  on conflict (phone_e164) do update set last_inbound_at = now();

  v_j := public.helios_patient_decision(v_c2, 'si', '584129990102', 'wamid.ced.demo.si.1');
  if v_j->>'reason' <> 'pide_cedula' or not (select is_demo from public.profiles where id = v_demo) then
    raise exception 'Un paciente de capacitación sin foto también la da: %', v_j;
  end if;
  v_j := public.helios_patient_id_photo('584129990102', 'wamid.ced.demo.1', 'media-demo', 'image/jpeg');
  v_f3 := (v_j->>'id_photo_id')::uuid;
  if v_j->>'status' <> 'confirmed' then
    raise exception 'La foto debía confirmar la orden de capacitación: %', v_j;
  end if;
  v_txt := v_demo || '/wamid.ced.demo.1.jpg';

  -- Lo que hizo fallar el reinicio: abrirla deja bitácora, que no se borra.
  update public.patient_id_photos set stored_at = now() where id = v_f3;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_open_patient_id_photo(v_demo);
  reset role;

  -- El de medianoche, con todos los números.
  v_j := public.helios_demo_reset();
  if (v_j->>'borrados')::int < 1
     or exists (select 1 from public.profiles where id = v_demo)
     or exists (select 1 from public.patient_id_photos where id = v_f3)
     or not exists (select 1 from public.patient_id_photo_removals where storage_path = v_txt)
     or not exists (select 1 from audit.admin_actions where action = 'patient.id_photo_viewed' and target_id = v_demo) then
    raise exception 'El reinicio debía borrar al paciente y su foto y dejar el archivo por borrar: %', v_j;
  end if;

  -- El lector: toma el archivo una vez, y lo que se subía tras el reinicio no sigue.
  v_j := public.lector_cedula_por_borrar(100);
  if not exists (select 1 from jsonb_array_elements(v_j) e where e->>'ruta' = v_txt) then
    raise exception 'El lector debía tomar el archivo por borrar: %', v_j;
  end if;
  if exists (select 1 from jsonb_array_elements(public.lector_cedula_por_borrar(100)) e where e->>'ruta' = v_txt) then
    raise exception 'Un archivo ya tomado no se vuelve a tomar enseguida';
  end if;
  if public.lector_cedula_guardada(v_f3) or not public.lector_cedula_guardada(v_f1) then
    raise exception 'El lector debía saber qué fotos siguen existiendo';
  end if;
  perform public.lector_cedula_borrada(array(select (e->>'id')::uuid from jsonb_array_elements(v_j) e));
  if exists (select 1 from public.patient_id_photo_removals where storage_path = v_txt) then
    raise exception 'El archivo borrado no debía quedar en la cola';
  end if;

  -- La misma cédula y la misma imagen, otra ronda; ahora con el botón del panel.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_j := public.helios_patient_eligibility(v_m, 'V99000011');
  if v_j->>'estado' <> 'nuevo' then
    raise exception 'Tras el reinicio, la cédula vuelve a ser nueva: %', v_j;
  end if;
  v_c2 := (public.create_patient_charge(v_m, null,
             v_base || jsonb_build_object('document', 'V99000011', 'phone', '04129990102'), 30, null, null, 'ced-demo-2')->>'id')::uuid;
  reset role;
  v_j := public.helios_patient_decision(v_c2, 'si', '584129990102', 'wamid.ced.demo.si.2');
  if v_j->>'reason' <> 'pide_cedula' then
    raise exception 'El paciente nuevo vuelve a dar la foto: %', v_j;
  end if;
  v_j := public.helios_patient_id_photo('584129990102', 'wamid.ced.demo.2', 'media-demo', 'image/jpeg');
  if v_j->>'status' <> 'confirmed' then
    raise exception 'La misma imagen en otra ronda debía confirmar: %', v_j;
  end if;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_reset_demo('+584129990102');
  reset role;
  if (v_j->>'borrados')::int <> 1 or (v_j->>'ordenes_borradas')::int <> 1
     or exists (select 1 from public.patient_id_photos where phone_e164 = '+584129990102') then
    raise exception 'El reinicio de un número debía borrar también su foto: %', v_j;
  end if;
  raise notice 'TEST CÉDULA 8 OK — el reinicio de la capacitación borra las fotos';
end;
$$;

set constraints all immediate;

rollback;
