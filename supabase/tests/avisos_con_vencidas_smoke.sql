-- ============================================================================
-- Helios — Los avisos de cuota cuentan lo vencido (20261029110000)
--
--   bash supabase/tests/run.sh avisos_con_vencidas_smoke
--
--   1. Al día: el aviso de siempre, sin «⚠️» y con un solo monto.
--   2. Caso 1: viene una cuota y debe otra → «También tienes 1 cuota
--      vencida…», «Para ponerte al día» y «Para pagar todo de una vez»; en el
--      correo también. Sin la plantilla nueva conectada, la de siempre; con
--      ella, sus 13 variables.
--   3. Caso 2: se vence una cuota y ya debía otra → «Con ella tienes 2 cuotas
--      pendientes…», «Puedes pagar las dos…», «Para pagar la más antigua».
--   4. Caso 5: dos cuotas el mismo día → «tus 2 cuotas… vencen».
--   5. Caso 4: pago confirmado con algo aún vencido → «⚠️ Aún tienes 1 cuota
--      vencida» y el botón «Pagar mi cuota».
--
-- Nada de esto llama a `helios_dispatch_*`: los mensajes se quedan en la cola
-- de la transacción y se van con el rollback.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_op     uuid := gen_random_uuid();
  v_staff  uuid := gen_random_uuid();
  v_pac    uuid := gen_random_uuid();
  v_pac2   uuid := gen_random_uuid();
  v_m      uuid;
  v_branch uuid;
  v_c1     uuid;
  v_ca     uuid;
  v_cb     uuid;
  v_i1     uuid;
  v_i2     uuid;
  v_hoy    date := public.helios_business_date(now());
  v_row    public.outbound_messages%rowtype;
  v_txt    text;
  v_j      jsonb;
begin
  -- =========================================================================
  -- Preparación
  -- =========================================================================
  perform public.record_fx_rate(800, v_hoy, 'BCV');
  update public.platform_contact set whatsapp_number = '+584140001122';
  insert into public.payment_destinations (method, bank_name, rif, phone, holder_name, is_active, sort_order)
  values ('pago_movil', 'BNC (0191)', 'J504967866', '04121714930', 'Quarto Latam, C.A.', true, 1);
  update public.notification_templates set enabled = true
   where key in ('cuota_en_3_dias', 'cuota_manana', 'cuota_hoy', 'cuota_vencida_d1', 'pago_recibido');

  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'venc-' || u || '@prueba.helios.test', now(), now(), now()
  from unnest(array[v_op, v_staff]) u;
  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_op, 'operador', 'Operadora Vencidas', true);

  insert into public.merchants (name, owner_name, doctor_title)
  values ('Consultorio Vencidas', 'NADIA prueba', 'Dra.') returning id into v_m;
  select id into v_branch from public.merchant_branches where merchant_id = v_m and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_staff, v_m, v_branch, 'cajero');

  insert into public.profiles (id, phone_e164, first_name, full_name, email)
  values (v_pac,  '+584140009301', 'María', 'María Vencidas', 'maria.vencidas@prueba.helios.test'),
         (v_pac2, '+584140009302', 'Pedro', 'Pedro Vencidas', null);
  update public.levels set monthly_limit_usd = 1000 where level = 1;

  v_c1 := (pg_temp.prueba_cobro(v_pac, v_m, v_branch, v_staff, 100.00, 'venc-1')->>'charge_id')::uuid;
  select id into v_i1 from public.installments where charge_id = v_c1 and sequence = 1;
  select id into v_i2 from public.installments where charge_id = v_c1 and sequence = 2;

  -- =========================================================================
  -- 1. Al día: el aviso de siempre
  -- =========================================================================
  update public.installments set due_date = v_hoy + 3 where id = v_i1;
  update public.installments set due_date = v_hoy + 10 where id = v_i2;
  perform public.helios_enqueue_reminders('cuota_en_3_dias', v_hoy);
  select rendered_text into v_txt from public.outbound_messages
  where profile_id = v_pac and template_key = 'cuota_en_3_dias' and channel = 'whatsapp';
  if v_txt not like 'Hola, María 👋 Te recordamos que tu cuota de $56,96 de la consulta con la Dra. Nadia Prueba vence el '
                    || public.helios_dia_text(v_hoy + 3) || E'.\n\n💵 *Monto en bolívares hoy: Bs 45.568,00*%'
     or v_txt like '%⚠️%' or v_txt like '%Para pagar todo%' then
    raise exception 'Al día, el aviso debía ser el de siempre: %', v_txt;
  end if;
  delete from public.outbound_messages where profile_id = v_pac;
  raise notice 'TEST VENCIDAS 1 OK — al día, el aviso de siempre';

  -- =========================================================================
  -- 2. Caso 1: viene la cuota 2 y debe la 1
  -- =========================================================================
  update public.installments set due_date = v_hoy - 3 where id = v_i1;
  update public.installments set due_date = v_hoy + 3 where id = v_i2;
  perform public.helios_enqueue_reminders('cuota_en_3_dias', v_hoy);
  select * into v_row from public.outbound_messages
  where profile_id = v_pac and template_key = 'cuota_en_3_dias' and channel = 'whatsapp';
  v_txt := v_row.rendered_text;
  if v_txt not like 'Hola, María 👋 Te recordamos que tu cuota de $56,96 de la consulta con la Dra. Nadia Prueba vence el '
                    || public.helios_dia_text(v_hoy + 3) || E'.\n\n⚠️ También tienes 1 cuota vencida de $56,96 (venció el '
                    || public.helios_dia_text(v_hoy - 3) || '). Te recomendamos pagarla primero para ponerte al día 💙%'
     or v_txt not like E'%💵 *Para ponerte al día hoy: Bs 45.568,00*\nEs tu cuota vencida ($56,96) a la tasa BCV del dólar de hoy.%'
     or v_txt not like E'%💰 *Para pagar todo de una vez hoy: Bs 91.136,00*\nSon tus 2 cuotas ($113,92).%'
     or v_txt not like '%Si pagas otro día, paga el equivalente a la tasa BCV de ese día.%'
     or v_txt not like '%📸 Cuando pagues, envíanos la foto del comprobante por este chat.%'
     or v_txt like '%Monto en bolívares hoy%' then
    raise exception 'Caso 1: el aviso debía contar lo vencido: %', v_txt;
  end if;
  -- Sin la plantilla nueva conectada, la de siempre.
  if v_row.wa_template->>'name' is distinct from (select wa_template_name from public.notification_templates where key = 'cuota_en_3_dias') then
    raise exception 'Sin conectar la plantilla nueva debía salir la de siempre: %', v_row.wa_template;
  end if;
  -- El correo también lo dice.
  select * into v_row from public.outbound_messages
  where profile_id = v_pac and template_key = 'cuota_en_3_dias' and channel = 'email';
  if v_row.html not like '%También tienes 1 cuota vencida de $56,96</strong>%'
     or v_row.html not like '%Para ponerte al día hoy: <strong>Bs 45.568,00</strong>%'
     or v_row.rendered_text not like '%comprobante por WhatsApp al 0414-%' then
    raise exception 'Caso 1: el correo debía contar lo vencido: %', v_row.html;
  end if;

  -- Con la plantilla nueva conectada: sus 13 variables.
  update public.notification_templates set wa_template_name = 'helios_cuota_con_vencidas' where key = 'cuota_con_vencidas';
  delete from public.outbound_messages where profile_id = v_pac;
  perform public.helios_enqueue_reminders('cuota_en_3_dias', v_hoy);
  select * into v_row from public.outbound_messages
  where profile_id = v_pac and template_key = 'cuota_en_3_dias' and channel = 'whatsapp';
  if v_row.wa_template->>'name' <> 'helios_cuota_con_vencidas'
     or jsonb_array_length(v_row.wa_template->'params') <> 13
     or v_row.wa_template->'params'->>0 <> 'María'
     or v_row.wa_template->'params'->>1 <> '$56,96'
     or v_row.wa_template->'params'->>2 <> 'la Dra. Nadia Prueba'
     or v_row.wa_template->'params'->>3 <> 'el ' || public.helios_dia_text(v_hoy + 3)
     or v_row.wa_template->'params'->>4 <> '1 cuota vencida de $56,96 (venció el ' || public.helios_dia_text(v_hoy - 3) || ')'
     or v_row.wa_template->'params'->>5 <> 'Bs 45.568,00'
     or v_row.wa_template->'params'->>6 <> 'tu cuota vencida ($56,96)'
     or v_row.wa_template->'params'->>7 <> 'dólar'
     or v_row.wa_template->'params'->>8 <> 'Bs 91.136,00'
     or v_row.wa_template->'params'->>9 <> 'tus 2 cuotas ($113,92)'
     or v_row.wa_template->'params'->>10 <> 'BNC (0191)'
     or v_row.wa_template->'params'->>12 <> 'J-50496786-6'
     or v_row.wa_template->'buttons'->0->>'id' <> 'paciente:ya_pague' then
    raise exception 'Caso 1: la plantilla nueva no quedó resuelta: %', v_row.wa_template;
  end if;
  -- Mañana y hoy también.
  delete from public.outbound_messages where profile_id = v_pac;
  update public.installments set due_date = v_hoy + 1 where id = v_i2;
  perform public.helios_enqueue_reminders('cuota_manana', v_hoy);
  select * into v_row from public.outbound_messages
  where profile_id = v_pac and template_key = 'cuota_manana' and channel = 'whatsapp';
  if v_row.rendered_text not like '%⚠️ También tienes 1 cuota vencida%'
     or v_row.wa_template->'params'->>3 <> 'mañana, ' || public.helios_dia_text(v_hoy + 1) then
    raise exception 'Caso 1: la víspera también debía contar lo vencido: %', to_jsonb(v_row);
  end if;
  delete from public.outbound_messages where profile_id = v_pac;
  raise notice 'TEST VENCIDAS 2 OK — caso 1: viene una cuota y debe otra';

  -- =========================================================================
  -- 3. Caso 2: se vence la cuota 2 y ya debía la 1
  -- =========================================================================
  update public.installments set due_date = v_hoy - 1 where id = v_i2;
  perform public.helios_enqueue_reminders('cuota_vencida_d1', v_hoy);
  select * into v_row from public.outbound_messages
  where profile_id = v_pac and template_key = 'cuota_vencida_d1' and channel = 'whatsapp';
  v_txt := v_row.rendered_text;
  if v_txt not like 'Hola, María. Tu cuota de $56,96 de la consulta con la Dra. Nadia Prueba venció ayer, '
                    || public.helios_dia_text(v_hoy - 1)
                    || '. Con ella tienes 2 cuotas pendientes por $113,92. Sabemos que a veces pasa 💙 Mientras estén pendientes no podrás pagar nuevas consultas en cuotas; en cuanto te pongas al día, se reactiva.'
                    -- (Las suites prueban con el cargo por atraso de $2: su aviso va aquí.)
                    || E'%\n\nPuedes pagar las dos de una vez o empezar por la más antigua.%'
     or v_txt not like E'%💵 *Para pagar la más antigua hoy: Bs 45.568,00*\nEs tu cuota del '
                       || public.helios_dia_text(v_hoy - 3) || ' ($56,96) a la tasa BCV del dólar de hoy.%'
     or v_txt not like E'%💰 *Para pagar todo de una vez hoy: Bs 91.136,00*\nSon tus 2 cuotas ($113,92).%'
     or v_txt not like '%Si tienes algún inconveniente, escríbenos por este chat y lo resolvemos juntos.' then
    raise exception 'Caso 2: el aviso debía contar las dos: %', v_txt;
  end if;
  -- Sin conectar `cuotas_vencidas`, la de siempre; conectada, sus 14 variables.
  if v_row.wa_template->>'name' is distinct from (select wa_template_name from public.notification_templates where key = 'cuota_vencida_d1') then
    raise exception 'Caso 2: sin conectar la plantilla nueva debía salir la de siempre';
  end if;
  update public.notification_templates set wa_template_name = 'helios_cuotas_vencidas' where key = 'cuotas_vencidas';
  delete from public.outbound_messages where profile_id = v_pac;
  perform public.helios_enqueue_reminders('cuota_vencida_d1', v_hoy);
  select * into v_row from public.outbound_messages
  where profile_id = v_pac and template_key = 'cuota_vencida_d1' and channel = 'whatsapp';
  if v_row.wa_template->>'name' <> 'helios_cuotas_vencidas'
     or jsonb_array_length(v_row.wa_template->'params') <> 14
     or v_row.wa_template->'params'->>3 <> public.helios_dia_text(v_hoy - 1)
     or v_row.wa_template->'params'->>4 <> '2 cuotas pendientes por $113,92'
     or v_row.wa_template->'params'->>5 <> 'Bs 45.568,00'
     or v_row.wa_template->'params'->>6 <> public.helios_dia_text(v_hoy - 3)
     or v_row.wa_template->'params'->>7 <> '$56,96'
     or v_row.wa_template->'params'->>8 <> 'dólar'
     or v_row.wa_template->'params'->>9 <> 'Bs 91.136,00'
     or v_row.wa_template->'params'->>10 <> 'tus 2 cuotas ($113,92)' then
    raise exception 'Caso 2: la plantilla nueva no quedó resuelta: %', v_row.wa_template;
  end if;
  raise notice 'TEST VENCIDAS 3 OK — caso 2: se vence una y ya debía otra';

  -- =========================================================================
  -- 4. Caso 5: dos cuotas el mismo día
  -- =========================================================================
  v_ca := (pg_temp.prueba_cobro(v_pac2, v_m, v_branch, v_staff, 100.00, 'venc-a')->>'charge_id')::uuid;
  v_cb := (pg_temp.prueba_cobro(v_pac2, v_m, v_branch, v_staff, 100.00, 'venc-b')->>'charge_id')::uuid;
  update public.installments set due_date = v_hoy + 3 where charge_id in (v_ca, v_cb) and sequence = 1;
  update public.installments set due_date = v_hoy + 10 where charge_id in (v_ca, v_cb) and sequence = 2;
  perform public.helios_enqueue_reminders('cuota_en_3_dias', v_hoy);
  select * into v_row from public.outbound_messages
  where profile_id = v_pac2 and template_key = 'cuota_en_3_dias' and channel = 'whatsapp';
  if v_row.rendered_text not like 'Hola, Pedro 👋 Te recordamos que tus 2 cuotas de $113,92 de las consultas con la Dra. Nadia Prueba vencen el %'
     or v_row.wa_template->'params'->>1 <> '$113,92 (2 cuotas)' then
    raise exception 'Caso 5: dos cuotas el mismo día van en plural: %', to_jsonb(v_row);
  end if;
  raise notice 'TEST VENCIDAS 4 OK — caso 5: varias cuotas el mismo día';

  -- =========================================================================
  -- 5. Caso 4: paga la más antigua y aún debe la otra
  -- =========================================================================
  insert into public.whatsapp_contacts (phone_e164, last_inbound_at)
  values (public.helios_wa_e164('+584140009301'), now())
  on conflict (phone_e164) do update set last_inbound_at = now();

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_register_payment(v_pac, array[v_i1], 'pago_movil', 'Banesco', 'VENC-1', v_hoy,
           (public.admin_payment_preview(v_pac, array[v_i1], v_hoy)->>'amount_ves')::numeric, null, null);
  perform public.admin_reconcile_payment((v_j->>'report_id')::uuid, true, null);
  reset role;

  select * into v_row from public.outbound_messages
  where profile_id = v_pac and template_key = 'bot_paciente' and rendered_text like '✅ ¡Gracias por tu pago%';
  if v_row.rendered_text not like E'%\n\n⚠️ Aún tienes 1 cuota vencida: $56,96 (venció el '
                                  || public.helios_dia_text(v_hoy - 1) || '). Cuando la pagues, tu cuenta se reactiva.%'
     or v_row.rendered_text like '%Tu próxima cuota%'
     or v_row.wa_template->'buttons'->0->>'id' <> 'paciente:pagar' then
    raise exception 'Caso 4: el pago confirmado debía decir lo que aún está vencido: %', to_jsonb(v_row);
  end if;
  raise notice 'TEST VENCIDAS 5 OK — caso 4: pago confirmado con algo aún vencido';
end $$;

set constraints all immediate;
rollback;
