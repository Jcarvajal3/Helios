-- ============================================================================
-- Helios — El bot lee los comprobantes (20261021200000, docs/03)
--
--   bash supabase/tests/run.sh lector_comprobantes_smoke
--
--  1. Qué cuotas paga un monto: la primera, las dos, o ninguna si no es exacto.
--  2. Apagado: no se encola nada.
--  3. Sombra: se lee y se anota lo que se habría hecho; ningún pago.
--  4. Activo, captura completa: se crea el pago (sin firma, con la lectura) y
--     el SMS del BNC lo aprueba.
--  5. La misma captura otra vez: duplicado.
--  6. Sin referencia: se pide; con la referencia escrita, se registra.
--  7. Lo que va al equipo: monto que no cuadra, cuenta ajena, no es un
--     comprobante, tres fallos del lector.
--  8. Datos escritos: primero los datos y luego el SMS; primero el SMS y
--     luego los datos; un teléfono que no encaja espera.
--  9. Lo que vence a las 24 h.
-- 10. El contexto del bot y el panel: el modo solo lo cambia el super admin.
--
-- Nada sale a la red: los mensajes del bot se encolan dentro de la
-- transacción y el rollback se los lleva.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_op       uuid := gen_random_uuid();
  v_super    uuid := gen_random_uuid();
  v_staff    uuid := gen_random_uuid();
  v_pac      uuid := gen_random_uuid();
  v_tel      text := '+584140009501';
  v_merchant uuid;
  v_branch   uuid;
  v_ca       uuid;
  v_cb       uuid;
  v_cc       uuid;
  v_a1       uuid;
  v_a2       uuid;
  v_b1       uuid;
  v_b2       uuid;
  v_c1       uuid;
  v_today    date := public.helios_business_date(now());
  v_dia      text := to_char(public.helios_business_date(now()), 'DD/MM/YY');
  v_res      jsonb;
  v_id       uuid;
  v_r        public.payment_receipt_reads%rowtype;
  v_rep      public.payment_reports%rowtype;
  v_monto    numeric;
  v_ids      uuid[];
  v_n        integer;
  v_datos    jsonb;
  v_x        jsonb := jsonb_build_object('es_comprobante', true, 'estado', 'exitosa');
begin
  -- Fixtures -----------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'u-' || u || '@prueba.helios.test', now(), now(), now()
  from unnest(array[v_op, v_super, v_staff]) u;
  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_op, 'operador', 'Operadora Lector', true),
         (v_super, 'super_admin', 'Super Lector', true);

  insert into public.merchants (name) values ('Clínica Lector') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_staff, v_merchant, v_branch, 'cajero');

  insert into public.profiles (id, phone_e164, first_name, full_name, email)
  values (v_pac, v_tel, 'Lia', 'Lia Lectora', 'lia.lectora@prueba.helios.test');

  update public.levels set monthly_limit_usd = 500 where level = 1;
  insert into public.business_parameters (key, value, effective_from, note)
  values ('payment_four_eyes', 0, v_today, 'prueba')
  on conflict (key, effective_from) do update set value = excluded.value;
  insert into public.exchange_rates (source, rate, effective_date)
  values ('BCV', 123.456789, v_today - 1)
  on conflict (source, effective_date) do update set rate = excluded.rate;

  insert into public.payment_destinations (bank_name, rif, phone, holder_name, method, is_active)
  values ('BNC', 'J-50496786-6', '0412-1714930', 'Quarto Latam, C.A.', 'pago_movil', true);

  update public.bank_sms_settings set mode = 'activo', actor = v_super, allowed_sender = null;
  -- El tope de verdad es 10; la suite manda más (se prueba al final).
  update public.receipt_reader_settings set mode = 'apagado', daily_cap = 50;

  -- La ventana de 24 h abierta: el paciente acaba de escribir.
  insert into public.whatsapp_contacts (phone_e164, last_inbound_at) values (v_tel, now())
  on conflict (phone_e164) do update set last_inbound_at = now();

  v_ca := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 100.00, 'lec-a')->>'charge_id')::uuid;
  v_cb := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 60.00, 'lec-b')->>'charge_id')::uuid;
  v_cc := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 40.00, 'lec-c')->>'charge_id')::uuid;
  select id into v_a1 from public.installments where charge_id = v_ca and sequence = 1;
  select id into v_a2 from public.installments where charge_id = v_ca and sequence = 2;
  select id into v_b1 from public.installments where charge_id = v_cb and sequence = 1;
  select id into v_b2 from public.installments where charge_id = v_cb and sequence = 2;
  select id into v_c1 from public.installments where charge_id = v_cc and sequence = 1;

  -- --- 1. Qué cuotas paga un monto ------------------------------------------
  -- Las tres órdenes vencen igual: el orden es el de creación.
  v_monto := public.helios_installments_ves(v_pac, array[v_a1], v_today);
  v_ids := public.helios_receipt_tramo(v_pac, v_today, v_monto);
  if v_ids is distinct from array[v_a1] then
    raise exception 'El monto de una cuota debía pagar esa cuota: %', v_ids;
  end if;

  v_ids := public.helios_receipt_tramo(v_pac, v_today,
             public.helios_installments_ves(v_pac, array[v_a1, v_b1], v_today));
  if v_ids is distinct from array[v_a1, v_b1] then
    raise exception 'El monto de dos cuotas debía pagar las dos primeras: %', v_ids;
  end if;

  -- Con margen (20261026150000): de 10 Bs menos a 100 Bs más; fuera, nada.
  if public.helios_receipt_tramo(v_pac, v_today, v_monto + 13.42) is distinct from array[v_a1]
     or public.helios_receipt_tramo(v_pac, v_today, v_monto - 10) is distinct from array[v_a1] then
    raise exception 'Dentro del margen el monto paga la cuota';
  end if;
  if public.helios_receipt_tramo(v_pac, v_today, v_monto - 10.01) is not null
     or public.helios_receipt_tramo(v_pac, v_today, v_monto + 100.01) is not null then
    raise exception 'Fuera del margen no paga cuotas completas';
  end if;

  -- --- 2. Apagado -------------------------------------------------------------
  v_res := public.bot_comprobante_nuevo('wamid.lec.0', v_tel, v_pac, 'media-0', 'image/jpeg');
  if (v_res->>'ok')::boolean or v_res->>'motivo' <> 'apagado' then
    raise exception 'Apagado no se encola nada: %', v_res;
  end if;
  if (public.bot_paciente_contexto(v_tel))->>'lector' <> 'apagado' then
    raise exception 'El contexto del bot debía decir que el lector está apagado';
  end if;

  -- --- 3. Sombra ---------------------------------------------------------------
  update public.receipt_reader_settings set mode = 'sombra';

  v_res := public.bot_comprobante_nuevo('wamid.lec.1', v_tel, v_pac, 'media-1', 'image/jpeg');
  if not (v_res->>'ok')::boolean or v_res->>'mode' <> 'sombra' then
    raise exception 'En sombra la captura se encola: %', v_res;
  end if;
  v_id := (v_res->>'id')::uuid;

  if (public.bot_comprobante_nuevo('wamid.lec.1', v_tel, v_pac, 'media-1', 'image/jpeg'))->>'motivo' <> 'repetido' then
    raise exception 'El mismo mensaje dos veces no se encola dos veces';
  end if;
  if (public.bot_comprobante_nuevo('wamid.lec.1b', v_tel, v_pac, 'media-1b', 'audio/ogg'))->>'motivo' <> 'formato' then
    raise exception 'Un audio no es una captura';
  end if;

  v_res := public.lector_tomar(5);
  if jsonb_array_length(v_res) <> 1 or (v_res->0->>'id')::uuid <> v_id then
    raise exception 'El lector debía tomar la captura pendiente: %', v_res;
  end if;
  if jsonb_array_length(public.lector_tomar(5)) <> 0 then
    raise exception 'Una captura que ya se está leyendo no se toma dos veces';
  end if;

  v_datos := jsonb_build_object('method', 'pago_movil', 'bank', 'Banesco', 'reference', '1158795645',
                                'amount_ves', v_monto, 'paid_on', v_today);
  v_res := public.lector_leido(v_id, 'bot/' || v_pac || '/' || v_id || '.jpg', v_x, v_datos,
                               'claude-sonnet-5-5', '{"input_tokens": 2000}');
  select * into v_r from public.payment_receipt_reads where id = v_id;
  if v_r.status <> 'sombra' or v_r.reason <> 'registraria' then
    raise exception 'En sombra se anota lo que se habría hecho: % %', v_r.status, v_r.reason;
  end if;
  if exists (select 1 from public.payment_reports where user_id = v_pac) then
    raise exception 'En sombra no se crea ningún pago';
  end if;

  -- --- 4. Activo: captura completa y su SMS ----------------------------------
  update public.receipt_reader_settings set mode = 'activo';

  v_id := (public.bot_comprobante_nuevo('wamid.lec.2', v_tel, v_pac, 'media-2', 'image/png')->>'id')::uuid;
  perform public.lector_tomar(5);
  v_res := public.lector_leido(v_id, 'bot/' || v_pac || '/' || v_id || '.png', v_x, v_datos,
                               'claude-sonnet-5-5', '{}');
  if v_res->>'status' <> 'registrado' then
    raise exception 'La captura completa debía registrarse: %', v_res;
  end if;

  select * into v_r from public.payment_receipt_reads where id = v_id;
  select * into v_rep from public.payment_reports where id = v_r.report_id;
  if v_rep.receipt_read_id is distinct from v_id or v_rep.registered_by is not null
     or v_rep.declared_amount_ves <> v_monto or v_rep.status <> 'reported'
     or v_rep.receipt_path is distinct from v_r.receipt_path then
    raise exception 'El pago del bot no quedó como debía: %', to_jsonb(v_rep);
  end if;
  if not exists (select 1 from public.payment_quote_items where quote_id = v_rep.quote_id and installment_id = v_a1) then
    raise exception 'El pago del bot debía pagar la primera cuota';
  end if;

  v_res := public.helios_bank_sms_ingest(format(
    'BNC Pago Movil Recibido Bs.%s Telf.0424***9037 Dia:%s-19:07 Ref:158795645 Llamar',
    replace(to_char(v_monto, 'FM999999990.00'), '.', ','), v_dia), '2622');
  if v_res->>'outcome' <> 'aprobado' then
    raise exception 'El SMS debía aprobar el pago del bot: %', v_res;
  end if;
  if (select status from public.payment_reports where id = v_rep.id) <> 'reconciled' then
    raise exception 'El pago del bot debía quedar aprobado';
  end if;

  -- --- 5. La misma captura otra vez -------------------------------------------
  v_id := (public.bot_comprobante_nuevo('wamid.lec.3', v_tel, v_pac, 'media-3', 'image/jpeg')->>'id')::uuid;
  perform public.lector_tomar(5);
  v_res := public.lector_leido(v_id, null, v_x, v_datos, 'claude-sonnet-5-5', '{}');
  if v_res->>'status' <> 'duplicado' then
    raise exception 'La misma captura otra vez es un duplicado: %', v_res;
  end if;

  -- --- 6. Sin referencia: se pide y se escribe --------------------------------
  v_monto := public.helios_installments_ves(v_pac, array[v_b1], v_today);
  v_id := (public.bot_comprobante_nuevo('wamid.lec.4', v_tel, v_pac, 'media-4', 'image/jpeg')->>'id')::uuid;
  perform public.lector_tomar(5);
  v_res := public.lector_leido(v_id, null, v_x,
             jsonb_build_object('method', 'pago_movil', 'bank', 'Mercantil', 'amount_ves', v_monto),
             'claude-sonnet-5-5', '{}');
  if v_res->>'status' <> 'esperando_referencia' then
    raise exception 'Sin referencia, se pide: %', v_res;
  end if;
  if (public.bot_paciente_contexto(v_tel))->>'estado' <> 'referencia' then
    raise exception 'El bot debía quedar esperando la referencia';
  end if;
  if not exists (select 1 from public.outbound_messages
                 where recipient = v_tel and template_key = 'bot_paciente'
                   and rendered_text like '%últimas 6 cifras%') then
    raise exception 'Faltó el mensaje que pide la referencia';
  end if;

  v_res := public.bot_comprobante_referencia(v_tel, 'Ref: 4447 7712');
  if v_res->>'outcome' <> 'registrado' then
    raise exception 'Con la referencia escrita debía registrarse: %', v_res;
  end if;
  select * into v_r from public.payment_receipt_reads where id = v_id;
  if v_r.reference <> '44477712' or (public.bot_paciente_contexto(v_tel))->>'estado' is not null then
    raise exception 'La referencia escrita no quedó, o el estado no se limpió: %', v_r.reference;
  end if;
  if (public.bot_comprobante_referencia(v_tel, '123456'))->>'motivo' <> 'sin_lectura' then
    raise exception 'Sin lectura esperando, una referencia escrita no hace nada';
  end if;

  -- --- 7. Lo que va al equipo -------------------------------------------------
  v_id := (public.bot_comprobante_nuevo('wamid.lec.5', v_tel, v_pac, 'media-5', 'image/jpeg')->>'id')::uuid;
  perform public.lector_tomar(5);
  perform public.lector_leido(v_id, null, v_x,
            jsonb_build_object('method', 'pago_movil', 'bank', 'Banesco', 'reference', '9990001112',
                               'amount_ves', 5000), 'claude-sonnet-5-5', '{}');
  select * into v_r from public.payment_receipt_reads where id = v_id;
  if v_r.status <> 'para_el_equipo' or v_r.reason <> 'monto_no_cuadra' then
    raise exception 'Un abono va al equipo: % %', v_r.status, v_r.reason;
  end if;
  if not (public.bot_paciente_contexto(v_tel)->>'humano')::boolean then
    raise exception 'Lo que va al equipo deja que una persona atienda el chat';
  end if;
  if (select human_until from public.whatsapp_contacts where phone_e164 = v_tel) <> now() + interval '8 hours' then
    raise exception 'El bot se calla 8 h, no 24 (20261022235500)';
  end if;
  perform public.bot_paciente_guardar(v_tel, null, 0, null, null);

  v_id := (public.bot_comprobante_nuevo('wamid.lec.6', v_tel, v_pac, 'media-6', 'image/jpeg')->>'id')::uuid;
  perform public.lector_tomar(5);
  perform public.lector_leido(v_id, null,
            v_x || jsonb_build_object('documento_destino', 'J-11111111-1'),
            jsonb_build_object('method', 'pago_movil', 'bank', 'Banesco', 'reference', '9990001113',
                               'amount_ves', v_monto), 'claude-sonnet-5-5', '{}');
  select * into v_r from public.payment_receipt_reads where id = v_id;
  if v_r.reason is distinct from 'cuenta_ajena' then
    raise exception 'Un pago a otra cuenta va al equipo: % %', v_r.status, v_r.reason;
  end if;

  -- Un destino enmascarado no se compara, y el de Helios vale.
  v_monto := public.helios_installments_ves(v_pac, array[v_c1], v_today);
  v_id := (public.bot_comprobante_nuevo('wamid.lec.7', v_tel, v_pac, 'media-7', 'image/jpeg')->>'id')::uuid;
  perform public.lector_tomar(5);
  v_res := public.lector_leido(v_id, null,
             v_x || jsonb_build_object('telefono_destino', '0412***4930', 'documento_destino', 'J504967866'),
             jsonb_build_object('method', 'pago_movil', 'bank', 'Banesco', 'reference', '9990001114',
                                'amount_ves', v_monto), 'claude-sonnet-5-5', '{}');
  if v_res->>'status' <> 'registrado' then
    raise exception 'Con el destino de Helios (o enmascarado) se registra: %', v_res;
  end if;

  v_id := (public.bot_comprobante_nuevo('wamid.lec.8', v_tel, v_pac, 'media-8', 'image/jpeg')->>'id')::uuid;
  perform public.lector_tomar(5);
  v_res := public.lector_leido(v_id, null, jsonb_build_object('es_comprobante', false), '{}'::jsonb,
                               'claude-sonnet-5-5', '{}');
  if v_res->>'status' <> 'descartado' then
    raise exception 'Una foto que no es un comprobante se descarta: %', v_res;
  end if;
  perform public.bot_paciente_guardar(v_tel, null, 0, null, null);

  -- Tres fallos del lector (20261021230000: con espera entre intentos y la
  -- captura guardada aunque falle).
  v_id := (public.bot_comprobante_nuevo('wamid.lec.9', v_tel, v_pac, 'media-9', 'image/jpeg')->>'id')::uuid;
  for v_n in 1..3 loop
    if jsonb_array_length(public.lector_tomar(5)) <> 1 then
      raise exception 'El intento % debía tomar la captura', v_n;
    end if;
    perform public.lector_fallo(v_id, 'prueba ' || v_n, 'bot/' || v_pac || '/' || v_id || '.jpg');
    if v_n = 1 and jsonb_array_length(public.lector_tomar(5)) <> 0 then
      raise exception 'Una captura que acaba de fallar espera antes de volver a tomarse';
    end if;
    update public.payment_receipt_reads set taken_at = now() - interval '3 minutes' where id = v_id;
  end loop;
  select * into v_r from public.payment_receipt_reads where id = v_id;
  if v_r.status <> 'para_el_equipo' or v_r.reason <> 'no_se_pudo_leer' or v_r.attempts <> 3 then
    raise exception 'Tres fallos del lector van al equipo: % % %', v_r.status, v_r.reason, v_r.attempts;
  end if;
  if v_r.receipt_path is null then
    raise exception 'Lo que va al equipo por un fallo del lector lleva su captura';
  end if;
  perform public.bot_paciente_guardar(v_tel, null, 0, null, null);

  -- --- 8. Datos escritos -------------------------------------------------------
  -- Primero los datos, luego el SMS.
  v_monto := public.helios_installments_ves(v_pac, array[v_a2], v_today);
  v_res := public.bot_comprobante_datos('wamid.lec.10', v_tel, v_pac, 'Banesco', '0416-123-4567', '0001234567890');
  if v_res->>'outcome' <> 'esperando' then
    raise exception 'Los datos sin SMS esperan al aviso: %', v_res;
  end if;
  v_id := (v_res->>'id')::uuid;
  if (public.bot_comprobante_datos('wamid.lec.10b', v_tel, v_pac, 'Banesco', '04161234567', '0001234567890'))->>'outcome' <> 'duplicado' then
    raise exception 'Los mismos datos dos veces son un duplicado';
  end if;
  if (public.bot_comprobante_datos('wamid.lec.10c', v_tel, v_pac, 'Banesco', '02121234567', '0001234567891'))->>'campo' <> 'telefono' then
    raise exception 'Un teléfono fijo no es un Pago Móvil';
  end if;

  -- Un SMS con otro teléfono no los empareja (otro monto: el mismo SMS dos
  -- veces no entra).
  v_res := public.helios_bank_sms_ingest(format(
    'BNC Pago Movil Recibido Bs.%s Telf.0414***4567 Dia:%s-10:00 Ref:234567890',
    replace(to_char(v_monto + 1, 'FM999999990.00'), '.', ','), v_dia), '2622');
  if (select status from public.payment_receipt_reads where id = v_id) <> 'esperando_aviso' then
    raise exception 'Un SMS de otro teléfono no empareja los datos';
  end if;

  v_res := public.helios_bank_sms_ingest(format(
    'BNC Pago Movil Recibido Bs.%s Telf.0416***4567 Dia:%s-10:05 Ref:234567890',
    replace(to_char(v_monto, 'FM999999990.00'), '.', ','), v_dia), '2622');
  if v_res->>'datos' <> 'registrado' then
    raise exception 'El SMS que encaja debía registrar los datos: %', v_res;
  end if;
  set constraints all immediate;
  set constraints all deferred;
  select * into v_r from public.payment_receipt_reads where id = v_id;
  select * into v_rep from public.payment_reports where id = v_r.report_id;
  if v_r.amount_ves <> v_monto or v_rep.status <> 'reconciled' or v_rep.payer_phone <> '04161234567' then
    raise exception 'Los datos con su SMS debían quedar aprobados: % % %', v_r.amount_ves, v_rep.status, v_rep.payer_phone;
  end if;

  -- Primero el SMS, luego los datos.
  v_monto := public.helios_installments_ves(v_pac, array[v_b2], v_today);
  v_res := public.helios_bank_sms_ingest(format(
    'BNC Pago Movil Recibido Bs.%s Telf.0424***7788 Dia:%s-11:00 Ref:556677889',
    replace(to_char(v_monto, 'FM999999990.00'), '.', ','), v_dia), '2622');
  if v_res->>'outcome' <> 'esperando' then
    raise exception 'Sin datos todavía, el SMS espera: %', v_res;
  end if;
  v_res := public.bot_comprobante_datos('wamid.lec.11', v_tel, v_pac, 'Mercantil', '04240007788', '10556677889');
  if v_res->>'outcome' <> 'registrado' then
    raise exception 'Los datos de un SMS que esperaba se registran al momento: %', v_res;
  end if;
  set constraints all immediate;
  set constraints all deferred;
  if (select p.status from public.payment_reports p
      join public.payment_receipt_reads r on r.report_id = p.id
      where r.id = (v_res->>'id')::uuid) <> 'reconciled' then
    raise exception 'El pago de los datos debía aprobarse con el SMS que esperaba';
  end if;

  -- --- 9. Lo que vence ---------------------------------------------------------
  v_res := public.bot_comprobante_datos('wamid.lec.12', v_tel, v_pac, 'Banesco', '04129998877', '77788899900');
  v_id := (v_res->>'id')::uuid;
  update public.payment_receipt_reads set created_at = now() - interval '25 hours' where id = v_id;
  perform public.helios_receipt_reads_expire();
  select * into v_r from public.payment_receipt_reads where id = v_id;
  if v_r.status <> 'para_el_equipo' or v_r.reason <> 'sin_aviso' then
    raise exception 'Datos sin aviso en 24 h van al equipo: % %', v_r.status, v_r.reason;
  end if;
  perform public.bot_paciente_guardar(v_tel, null, 0, null, null);

  -- Un estado de hace más de 24 h no cuenta.
  perform public.bot_paciente_guardar(v_tel, null, null, 'datos_pago', null);
  update public.whatsapp_contacts set patient_state_at = now() - interval '25 hours' where phone_e164 = v_tel;
  if (public.bot_paciente_contexto(v_tel))->>'estado' is not null then
    raise exception 'El estado datos_pago caduca a las 24 h';
  end if;

  -- --- 10. El panel -----------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_res := public.admin_receipt_reads(v_today - 1, v_today + 1);
  if v_res->>'mode' <> 'activo' or jsonb_array_length(v_res->'reads') < 10 then
    raise exception 'El panel debía ver las lecturas: % %', v_res->>'mode', jsonb_array_length(v_res->'reads');
  end if;
  if public.admin_receipt_read_latest(v_pac) is null then
    raise exception 'Debía haber una lectura para rellenar «Registrar pago»';
  end if;
  if (public.admin_receipt_read_for_report(v_rep.id))->>'kind' <> 'datos' then
    raise exception 'La ficha del pago debía traer su lectura';
  end if;
  begin
    perform public.admin_set_receipt_reader_mode('apagado', 'prueba del operador');
    raise exception 'Un operador no puede cambiar el modo del lector';
  exception when sqlstate '42501' then null;
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  begin
    perform public.admin_set_receipt_reader_mode('sombra', '');
    raise exception 'Cambiar el modo del lector sin motivo debía fallar';
  exception when sqlstate '22023' then null;
  end;
  perform public.admin_set_receipt_reader_mode('sombra', 'vuelta a sombra en la prueba');
  if (select mode from public.receipt_reader_settings) <> 'sombra'
     or not exists (select 1 from audit.admin_actions
                    where actor = v_super and action = 'receipt_reader.mode_changed') then
    raise exception 'El modo del lector no cambió, o no dejó bitácora';
  end if;

  -- El tope por teléfono y día.
  update public.receipt_reader_settings set daily_cap = 1;
  if (public.bot_comprobante_nuevo('wamid.lec.13', v_tel, v_pac, 'media-13', 'image/jpeg'))->>'motivo' <> 'tope' then
    raise exception 'Pasado el tope del día, la captura no se lee';
  end if;
end $$;

-- El equipo firma: un registro suyo deja `registered_by` y la bitácora.
do $$
declare
  v_op   uuid := gen_random_uuid();
  v_staff uuid := gen_random_uuid();
  v_pac  uuid := gen_random_uuid();
  v_m    uuid;
  v_b    uuid;
  v_c    uuid;
  v_i    uuid;
  v_res  jsonb;
  v_today date := public.helios_business_date(now());
begin
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'u-' || u || '@prueba.helios.test', now(), now(), now()
  from unnest(array[v_op, v_staff]) u;
  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_op, 'operador', 'Operadora Firma', true);
  insert into public.merchants (name) values ('Clínica Firma') returning id into v_m;
  select id into v_b from public.merchant_branches where merchant_id = v_m and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values (v_staff, v_m, v_b, 'cajero');
  insert into public.profiles (id, phone_e164, first_name, full_name) values (v_pac, '+584140009502', 'Rita', 'Rita Firma');
  v_c := (pg_temp.prueba_cobro(v_pac, v_m, v_b, v_staff, 50.00, 'firma')->>'charge_id')::uuid;
  select id into v_i from public.installments where charge_id = v_c and sequence = 1;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_res := public.admin_register_payment(v_pac, array[v_i], 'transferencia', 'Banesco', '31313131',
                                         v_today, 1, null, null);
  if (select registered_by from public.payment_reports where id = (v_res->>'report_id')::uuid) is distinct from v_op then
    raise exception 'El pago del equipo debía quedar firmado';
  end if;
  if not exists (select 1 from audit.admin_actions
                 where target_id = (v_res->>'report_id')::uuid and action = 'payment.registered' and actor = v_op) then
    raise exception 'Faltó la bitácora del registro del equipo';
  end if;
end $$;

rollback;
