-- ============================================================================
-- Helios — Prueba de humo de la inicial del 50% (docs/07-INICIAL-DEL-50.md)
--
--   POR_LANZAR=1 bash supabase/tests/run.sh inicial_smoke
--
-- Solo corre con `supabase/por-lanzar/` aplicado dentro de la misma
-- transacción (`POR_LANZAR=1`): sin eso, la primera comprobación falla.
--
--   1. La vista previa: $100 → 56,96 + 28,48 + 28,48; $30 → 17,09 + 8,55 +
--      8,54; la consulta (financed) repartida igual.
--   2. La orden nace pendiente con su inicial y la pregunta es la de la
--      inicial (plantilla v3), sin «sin inicial».
--   3. «Sí» + cédula → espera la inicial: 3 cuotas (la 0 hoy, sin día de pago
--      a la clínica), asiento, sin comisión, comprobante ni aviso al médico;
--      el mensaje de la inicial con su bloque de pago; el límite cuenta la
--      consulta entera; la clínica la ve en su lista; ni la mora ni el lote
--      de liquidaciones la tocan.
--   4. Captura de la inicial (lector) → vence el plazo con el pago abierto y
--      no se anula → el aviso del BNC la aprueba → activa: comisión,
--      comprobante con la inicial pagada, aviso al médico, aviso de pago con
--      sus 2 cuotas; liquidaciones a la clínica en sus dos fechas.
--   5. Datos escritos + aviso del BNC, en $30.
--   6. En euros: el reparto en la moneda de la orden.
--   7. Vence sin pago → se anula sola: asiento contrario, cuotas fuera, cupo
--      de vuelta, avisos al paciente y al médico, la cola cancelada.
--   8. Pago abierto al vencer → no se anula; se rechaza → se anula.
--   9. Una orden sin inicial (down_payment_pct 0) → como siempre.
--  10. El límite cuenta la consulta entera también con la inicial pagada.
--
-- Dentro de la transacción `now()` no avanza: «vence el plazo» se simula con
-- `down_payment_due_at = now()` (un pago llegado «ahora» llegó a tiempo).
--
-- Nada sale de verdad: los mensajes solo se encolan (los despachadores no
-- corren dentro de la transacción) y el `rollback` se lo lleva todo.
-- ============================================================================

begin;

-- @ayudas

-- Una orden de una clínica, como la registra la secretaria desde el panel.
create function pg_temp.ini_orden(
  p_staff uuid, p_merchant uuid, p_pac jsonb, p_amount numeric, p_key text, p_currency text default 'USD')
returns jsonb
language plpgsql
as $$
declare
  v_j jsonb;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', p_staff::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(p_merchant, p_pac->>'document');
  v_j := public.create_patient_charge(p_merchant, null, p_pac, p_amount, 'Consulta', null, p_key, p_currency);
  reset role;
  return v_j;
end;
$$;

create function pg_temp.ini_paciente(p_doc text, p_tel text, p_nombre text)
returns jsonb
language sql
as $$
  select jsonb_build_object(
    'document', p_doc,
    'first_name', p_nombre, 'last_name', 'Prueba',
    'birth_date', (public.helios_business_date(now()) - interval '30 years')::date,
    'sex', 'F', 'phone', p_tel, 'email', lower(p_nombre) || '.inicial@prueba.helios.test',
    'state', 'Miranda', 'city', 'Caracas', 'address', 'Los Palos Grandes',
    'reference_name', 'Ref Prueba', 'reference_phone', '02125551234', 'reference_relationship', 'Madre');
$$;

-- «Sí» con la cédula ya guardada: la orden queda esperando la inicial.
create function pg_temp.ini_si(p_charge uuid, p_wamid text)
returns jsonb
language plpgsql
as $$
declare
  v_c public.charges%rowtype;
  v_p public.profiles%rowtype;
begin
  select * into v_c from public.charges where id = p_charge;
  select * into v_p from public.profiles where id = v_c.user_id;
  update public.profiles set id_photo_at = now(), id_photo_path = v_p.id || '/prueba.jpg' where id = v_p.id;
  return public.helios_patient_decision(p_charge, 'si', v_p.phone_e164, p_wamid);
end;
$$;

do $$
declare
  v_admin   uuid;
  v_cajero  uuid := gen_random_uuid();
  v_gerente uuid := gen_random_uuid();
  v_m       uuid;
  v_bdate   date := public.helios_business_date(now());
  v_dia     text := to_char(public.helios_business_date(now()), 'DD/MM/YY');
  v_j       jsonb;
  v_res     jsonb;
  v_ca      uuid;  -- $100, pagada por captura + BNC
  v_cb      uuid;  -- $30, pagada por datos + BNC
  v_cc      uuid;  -- €100
  v_cd      uuid;  -- vence sin pago
  v_ce      uuid;  -- pago abierto, luego rechazado
  v_cf      uuid;  -- sin inicial
  v_cg      uuid;
  v_ch      uuid;
  v_pg      uuid;
  v_k1      uuid;
  v_k2      uuid;
  v_pk      uuid;
  v_k2ids   uuid[];
  v_pa      uuid;
  v_pb      uuid;
  v_pd      uuid;
  v_pe      uuid;
  v_c       public.charges%rowtype;
  v_i0      uuid;
  v_ids     uuid[];
  v_monto   numeric;
  v_id      uuid;
  v_r       public.payment_receipt_reads%rowtype;
  v_rep     uuid;
  v_n       integer;
  v_txt     text;
  v_err     text;
  v_x       jsonb := jsonb_build_object('es_comprobante', true, 'estado', 'exitosa');
  v_int     integer := public.helios_settlement_interval_days();
begin
  -- =========================================================================
  -- 0. Preparación
  -- =========================================================================
  if not exists (select 1 from pg_proc where proname = 'helios_activate_charge') then
    raise exception 'inicial_smoke necesita supabase/por-lanzar/ aplicado: POR_LANZAR=1 bash supabase/tests/run.sh inicial_smoke';
  end if;

  update public.platform_maintenance set is_active = false;
  update public.platform_contact set whatsapp_number = '+584140001122', support_email = 'ayuda@prueba.helios.test';

  insert into public.business_parameters (key, value, effective_from, note) values
    ('patient_confirmation_required', 1, v_bdate, 'prueba'),
    ('down_payment_pct', 50, v_bdate, 'prueba'),
    ('payment_four_eyes', 0, v_bdate, 'prueba')
  on conflict (key, effective_from) do update set value = excluded.value;

  insert into public.exchange_rates (source, rate, effective_date) values
    ('BCV', 100, v_bdate - 1), ('BCV_EUR', 110, v_bdate - 1),
    ('BCV', 100, v_bdate), ('BCV_EUR', 110, v_bdate)
  on conflict (source, effective_date) do update set rate = excluded.rate;

  insert into public.payment_destinations (bank_name, rif, phone, holder_name, method, is_active)
  values ('BNC', 'J-50496786-6', '0412-1714930', 'Quarto Latam, C.A.', 'pago_movil', true);

  if not public.helios_whatsapp_api_ready() then
    perform vault.create_secret('prueba', 'd360_api_key');
    perform vault.create_secret('https://waba-sandbox.360dialog.io/v1', 'd360_base_url');
  end if;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ini-cajero@prueba.helios.test', now(), now(), '{"full_name":"Ana Secretaria"}'),
         (v_gerente, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ini-gerente@prueba.helios.test', now(), now(), '{"full_name":"Laura Gerente"}');

  v_admin := pg_temp.prueba_admin();
  update public.bank_sms_settings set mode = 'activo', actor = v_admin, allowed_sender = null;
  update public.receipt_reader_settings set mode = 'activo', daily_cap = 50;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_m := (public.admin_create_merchant('Clínica Inicial', null, 'J-400000091', 'clinica')).id;
  reset role;

  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_m, (select id from public.merchant_branches where merchant_id = v_m and is_default), 'cajero'),
         (v_gerente, v_m, (select id from public.merchant_branches where merchant_id = v_m and is_default), 'gerente');

  -- El número del bot de la secretaria, con su ventana abierta: los avisos
  -- al médico se encolan como texto.
  insert into public.staff_whatsapp_numbers (phone_e164, user_id, merchant_id, created_by)
  values ('+584120009100', v_cajero, v_m, v_admin);
  insert into public.whatsapp_contacts (phone_e164, last_inbound_at)
  select t, now() from unnest(array['+584120009100', '+584140009101', '+584140009102', '+584140009103',
                                    '+584140009104', '+584140009105', '+584140009106', '+584140009107', '+584140009108', '+584140009109', '+584140009110', '+584140009111']) t
  on conflict (phone_e164) do update set last_inbound_at = now();

  -- =========================================================================
  -- 1. La vista previa
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_j := public.preview_patient_charge(v_m, null, 100, 'USD');
  reset role;
  if (v_j->>'down_payment_pct')::numeric <> 50 or (v_j->>'down_payment_minutes')::integer <> 120
     or jsonb_array_length(v_j->'installments') <> 3
     or (select array_agg((x->>'amount_usd')::numeric order by (x->>'sequence')::integer)
         from jsonb_array_elements(v_j->'installments') x) <> array[56.96, 28.48, 28.48]::numeric[]
     or (select array_agg((x->>'financed_usd')::numeric order by (x->>'sequence')::integer)
         from jsonb_array_elements(v_j->'installments') x) <> array[50, 25, 25]::numeric[]
     or (select array_agg((x->>'due_date')::date order by (x->>'sequence')::integer)
         from jsonb_array_elements(v_j->'installments') x) <> array[v_bdate, v_bdate + 14, v_bdate + 28]
     or (v_j->'installments'->0->>'amount_ves')::numeric <> 5696.00 then
    raise exception '1. La vista previa de $100 no reparte bien: %', v_j;
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_j := public.preview_patient_charge(v_m, null, 30, 'USD');
  reset role;
  if (select array_agg((x->>'amount_usd')::numeric order by (x->>'sequence')::integer)
      from jsonb_array_elements(v_j->'installments') x) <> array[17.09, 8.55, 8.54]::numeric[]
     or (select array_agg((x->>'financed_usd')::numeric order by (x->>'sequence')::integer)
         from jsonb_array_elements(v_j->'installments') x) <> array[15, 7.5, 7.5]::numeric[] then
    raise exception '1. La vista previa de $30 no reparte bien: %', v_j->'installments';
  end if;

  -- =========================================================================
  -- 2. La orden nace pendiente con su inicial
  -- =========================================================================
  v_j := pg_temp.ini_orden(v_cajero, v_m, pg_temp.ini_paciente('V20009101', '04140009101', 'Ana'), 100, 'ini-a');
  v_ca := (v_j->>'id')::uuid;
  select * into v_c from public.charges where id = v_ca;
  v_pa := v_c.user_id;

  if v_c.status <> 'pending' or v_c.down_payment_pct <> 50 or v_c.down_payment_due_at is not null
     or jsonb_array_length(v_j->'installments') <> 3
     or (v_j->'installments'->0->>'sequence')::integer <> 0
     or (v_j->>'down_payment_pct')::numeric <> 50 then
    raise exception '2. La orden debía nacer pendiente con su inicial: % / %', to_jsonb(v_c), v_j;
  end if;

  select rendered_text into v_txt from public.outbound_messages
  where charge_id = v_ca and template_key = 'confirmar_pago_con_inicial';
  if v_txt is null or v_txt not like '%💳 Inicial, hoy: $56,96%' or v_txt not like '%📅 Cuotas: $28,48 el % y $28,48 el %'
     or v_txt not like '%Responde Sí o No. Tienes 2 horas para responder. Al confirmar, paga la inicial%'
     or v_txt ilike '%sin inicial%' or v_txt not like '%Comisión de servicio (12%): $12%' then
    raise exception '2. La pregunta con inicial no quedó bien: %', v_txt;
  end if;
  if (select wa_template->>'name' from public.outbound_messages
      where charge_id = v_ca and template_key = 'confirmar_pago_con_inicial') <> 'helios_confirmar_pago_en_cuotas_v3'
     or (select jsonb_array_length(wa_template->'params') from public.outbound_messages
         where charge_id = v_ca and template_key = 'confirmar_pago_con_inicial') <> 11
     or (select wa_template->'params'->>8 from public.outbound_messages
         where charge_id = v_ca and template_key = 'confirmar_pago_con_inicial') <> '$56,96' then
    raise exception '2. La plantilla de Meta v3 no quedó conectada con sus 11 variables';
  end if;
  if exists (select 1 from public.outbound_messages where charge_id = v_ca and template_key = 'confirmar_financiamiento') then
    raise exception '2. Una orden con inicial no pregunta con la plantilla vieja';
  end if;
  if (public.helios_charge_confirmation(v_ca))->>'status' not in ('por_enviar', 'enviada') then
    raise exception '2. El estado de la pregunta debía verse: %', public.helios_charge_confirmation(v_ca);
  end if;

  -- =========================================================================
  -- 3. «Sí» + cédula → espera la inicial
  -- =========================================================================
  v_j := public.helios_patient_decision(v_ca, 'si', '584140009101', 'wamid.ini.a.si');
  if v_j->>'reason' <> 'pide_cedula' then
    raise exception '3. Sin cédula, el «Sí» la pide: %', v_j;
  end if;
  v_j := public.helios_patient_id_photo('584140009101', 'wamid.ini.a.foto', 'media-ced-a', 'image/jpeg');
  if v_j->>'status' <> 'awaiting_down_payment' or not (v_j->>'handled')::boolean then
    raise exception '3. La cédula debía dejar la orden esperando la inicial: %', v_j;
  end if;

  select * into v_c from public.charges where id = v_ca;
  if v_c.status <> 'awaiting_down_payment' or v_c.confirmed_at is not null or v_c.activated_at is not null
     or v_c.down_payment_due_at not between now() + interval '119 minutes' and now() + interval '121 minutes' then
    raise exception '3. La orden no quedó esperando la inicial: %', to_jsonb(v_c);
  end if;

  if (select array_agg(sequence order by sequence) from public.installments where charge_id = v_ca) <> array[0, 1, 2]::smallint[]
     or (select array_agg(amount_usd order by sequence) from public.installments where charge_id = v_ca) <> array[56.96, 28.48, 28.48]::numeric[]
     or (select array_agg(financed_usd order by sequence) from public.installments where charge_id = v_ca) <> array[50, 25, 25]::numeric[]
     or (select array_agg(amount_cur order by sequence) from public.installments where charge_id = v_ca) <> array[56.96, 28.48, 28.48]::numeric[]
     or (select array_agg(due_date order by sequence) from public.installments where charge_id = v_ca) <> array[v_bdate, v_bdate + 14, v_bdate + 28]
     or (select settlement_due_date from public.installments where charge_id = v_ca and sequence = 0) is not null
     or (select array_agg(settlement_due_date order by sequence) from public.installments where charge_id = v_ca and sequence > 0)
          <> array[v_bdate + v_int, v_bdate + v_int * 2] then
    raise exception '3. Las 3 cuotas no quedaron bien: %',
      (select jsonb_agg(to_jsonb(i) order by sequence) from public.installments i where charge_id = v_ca);
  end if;

  if not exists (select 1 from ledger.transactions t where t.reference_id = v_ca and t.type = 'charge') then
    raise exception '3. El «Sí» debía dejar el asiento de la orden';
  end if;
  if exists (select 1 from public.staff_commissions where charge_id = v_ca)
     or exists (select 1 from public.outbound_messages where charge_id = v_ca and template_key in ('comprobante_financiamiento', 'bienvenida'))
     or exists (select 1 from public.outbound_messages where recipient = '+584120009100' and rendered_text like '%Ana P.%') then
    raise exception '3. Antes de la inicial no hay comisión, comprobante, bienvenida ni aviso al médico';
  end if;

  select rendered_text into v_txt from public.outbound_messages
  where charge_id = v_ca and template_key = 'pagar_inicial';
  if v_txt is null or v_txt not like '✅ ¡Listo, Ana! Aceptaste tu pago en cuotas #%'
     or v_txt not like '%paga tu *inicial de $56,96* antes de las %'
     or v_txt not like '%💳 Inicial: $56,96 · hoy%' or v_txt not like '%1️⃣ $28,48 · %'
     or v_txt not like '%Bs 5.696,00%'
     or v_txt not like '%⭐ Recuerda pagar a tiempo para subir de nivel y disponer de mayores beneficios.' then
    raise exception '3. El mensaje de la inicial no quedó bien: %', v_txt;
  end if;
  if not exists (select 1 from public.outbound_messages
                 where recipient = '+584140009101' and template_key = 'bot_paciente'
                   and rendered_text like '%Recibimos tu cédula. Ya solo falta tu inicial%') then
    raise exception '3. El acuse de la cédula ya no dice «confirmado»';
  end if;

  if public.helios_credit_used_usd(v_pa) <> 100 then
    raise exception '3. El límite debía contar la consulta entera: %', public.helios_credit_used_usd(v_pa);
  end if;

  -- La inicial nunca está «vencida», aunque el plazo cruce la medianoche.
  update public.installments set due_date = v_bdate - 1 where charge_id = v_ca and sequence = 0;
  if public.helios_in_arrears(v_pa) or not public.can_take_debt(v_pa) then
    raise exception '3. La inicial no deja en mora';
  end if;
  perform public.recompute_profile_mora_state(v_pa);
  if (select status from public.profiles where id = v_pa) <> 'active' then
    raise exception '3. La inicial no congela la cuenta';
  end if;

  -- Ni en las fichas del superadmin.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_charge_detail(v_ca);
  reset role;
  -- (interna, sin permiso para la API: la llama la RPC de la ficha)
  v_res := public.helios_admin_user_detail_base(v_pa);
  if (select (x->>'days_overdue')::integer from jsonb_array_elements(v_j->'installments') x
      where (x->>'sequence')::integer = 0) <> 0
     or (v_j->>'down_payment_pct')::numeric <> 50
     or (v_res->'debt'->>'days_overdue')::integer <> 0 or (v_res->'debt'->>'overdue_usd')::numeric <> 0
     or exists (select 1 from jsonb_array_elements(v_res->'installments') x
                where (x->>'sequence')::integer = 0 and (x->>'days_overdue')::integer <> 0) then
    raise exception '3. En el superadmin la inicial no tiene días de atraso: % / %', v_j->'installments', v_res->'debt';
  end if;

  -- Y el cron le pasa la fecha a hoy mientras la orden la espera.
  perform public.helios_revert_unpaid_down_payments();
  if (select due_date from public.installments where charge_id = v_ca and sequence = 0) <> v_bdate then
    raise exception '3. Mientras espera, la inicial vence hoy';
  end if;

  -- La clínica la ve en su lista, con su plazo.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.merchant_transactions(v_bdate, v_bdate, 50) t
  where t.charge_id = v_ca and t.status = 'awaiting_down_payment' and t.down_payment_due_at = v_c.down_payment_due_at
    and t.cuota_1_due = v_bdate + 14;
  v_j := public.merchant_charge_detail(v_ca);
  reset role;
  if v_n <> 1 then
    raise exception '3. La lista de la clínica debía enseñar la orden esperando la inicial';
  end if;
  if v_j->>'status' <> 'awaiting_down_payment' or (v_j->>'down_payment_pct')::numeric <> 50
     or jsonb_array_length(v_j->'installments') <> 2 then
    raise exception '3. El detalle de la clínica: los datos de la inicial y solo las cuotas 1 y 2: %', v_j;
  end if;

  -- Ni el lote de liquidaciones ni la cobranza la tocan.
  perform public.run_scheduled_settlements_batch(v_bdate + v_int, '00000000-0000-0000-0000-000000000000'::uuid, 1000);
  if exists (select 1 from public.settlements where charge_id = v_ca) then
    raise exception '3. A la clínica no se le devenga nada antes de la inicial';
  end if;
  if (public.helios_collection_amounts(v_pa, v_bdate, 30))->>'upcoming_text'
       is distinct from public.helios_amounts_label(0, 0) then
    raise exception '3. Cobranza no persigue la inicial: %', public.helios_collection_amounts(v_pa, v_bdate, 30);
  end if;

  -- =========================================================================
  -- 4. Captura → plazo vencido con el pago abierto → aviso del BNC → activa
  -- =========================================================================
  select id into v_i0 from public.installments where charge_id = v_ca and sequence = 0;
  v_monto := public.helios_installments_ves(v_pa, array[v_i0], v_bdate);
  if v_monto <> 5696.00 or public.helios_receipt_tramo(v_pa, v_bdate, v_monto) is distinct from array[v_i0] then
    raise exception '4. El monto de la inicial debía pagar la cuota 0: % %', v_monto,
      public.helios_receipt_tramo(v_pa, v_bdate, v_monto);
  end if;

  v_id := (public.bot_comprobante_nuevo('wamid.ini.a.cap', '+584140009101', v_pa, 'media-a', 'image/png')->>'id')::uuid;
  perform public.lector_tomar(5);
  v_res := public.lector_leido(v_id, null, v_x,
             jsonb_build_object('method', 'pago_movil', 'bank', 'Banesco', 'reference', '1191010101',
                                'amount_ves', v_monto, 'paid_on', v_bdate),
             'claude-sonnet-5-5', '{}');
  if v_res->>'status' <> 'registrado' then
    raise exception '4. La captura de la inicial debía registrarse: %', v_res;
  end if;

  update public.charges set down_payment_due_at = now() where id = v_ca;
  if not public.helios_down_payment_open(v_ca) then
    raise exception '4. Un pago reportado de la inicial es un pago abierto';
  end if;
  perform public.helios_revert_unpaid_down_payments();
  if (select status from public.charges where id = v_ca) <> 'awaiting_down_payment' then
    raise exception '4. Con un pago abierto la orden no se anula';
  end if;

  v_res := public.helios_bank_sms_ingest(format(
    'BNC Pago Movil Recibido Bs.%s Telf.0414***9101 Dia:%s-10:07 Ref:191010101 Llamar',
    replace(to_char(v_monto, 'FM999999990.00'), '.', ','), v_dia), '2622');
  if v_res->>'outcome' <> 'aprobado' then
    raise exception '4. El aviso del BNC debía aprobar la inicial: %', v_res;
  end if;

  select * into v_c from public.charges where id = v_ca;
  if v_c.status <> 'confirmed' or v_c.activated_at is null or v_c.confirmed_at is null
     or (select status from public.installments where id = v_i0) <> 'paid' then
    raise exception '4. Pagada la inicial, la orden debía quedar activa: %', to_jsonb(v_c);
  end if;
  if not exists (select 1 from public.staff_commissions where charge_id = v_ca and staff_user_id = v_cajero) then
    raise exception '4. Al activarse se devenga la comisión de la secretaria';
  end if;

  -- El comprobante sale cuando el pago queda aprobado entero (el reporte pasa
  -- a reconciled tras marcar todas sus cuotas).
  select rendered_text into v_txt from public.outbound_messages
  where charge_id = v_ca and template_key = 'comprobante_financiamiento' and channel = 'email';
  if v_txt is null or v_txt ilike '%sin inicial%' or v_txt not like '%• Inicial: $56,96, pagada el %'
     or v_txt not like '%• Cuota 1: $28,48%' or v_txt not like '%• Cuota 2: $28,48%' then
    raise exception '4. El comprobante sale al activarse, con la inicial pagada: %', v_txt;
  end if;
  if (select subject from public.outbound_messages
      where charge_id = v_ca and template_key = 'comprobante_financiamiento') not like '%2 cuotas de $28,48' then
    raise exception '4. El asunto del comprobante habla de las 2 cuotas';
  end if;

  if not exists (select 1 from public.outbound_messages
                 where recipient = '+584120009100'
                   and rendered_text like '¡Buenas noticias! Ana P. pagó su inicial y su pago en cuotas quedó activo.%'
                   and rendered_text like '%consulta de $100 %') then
    raise exception '4. Al activarse se avisa al médico (sin la comisión)';
  end if;

  select rendered_text into v_txt from public.outbound_messages
  where recipient = '+584140009101' and template_key = 'bot_paciente' and rendered_text like '✅ ¡Gracias por tu pago%'
  order by created_at desc limit 1;
  if v_txt is null or v_txt not like '%Recibimos $56,96%' or v_txt not like '%quedó activo%'
     or v_txt not like '%1️⃣ $28,48 · %' or v_txt not like '%2️⃣ $28,48 · %'
     or v_txt not like '%⭐ Si pagas a tiempo, puedes subir de nivel y aumentar tu saldo máximo.' then
    raise exception '4. El aviso de pago debía decir que la orden quedó activa: %', v_txt;
  end if;

  -- A la clínica, en sus dos fechas, pague o no el paciente.
  perform public.run_scheduled_settlements_batch(v_bdate + v_int, '00000000-0000-0000-0000-000000000000'::uuid, 1000);
  perform public.run_scheduled_settlements_batch(v_bdate + v_int * 2, '00000000-0000-0000-0000-000000000000'::uuid, 1000);
  if (select array_agg(business_date order by business_date) from public.settlements
      where charge_id = v_ca and reason = 'scheduled_installment') <> array[v_bdate + v_int, v_bdate + v_int * 2]
     or (select sum(amount_usd) from public.settlements
         where charge_id = v_ca and reason = 'scheduled_installment') <> 100 then
    raise exception '4. Las dos mitades a la clínica, en sus fechas: %',
      (select jsonb_agg(to_jsonb(s)) from public.settlements s where charge_id = v_ca);
  end if;

  -- =========================================================================
  -- 5. $30: datos escritos + aviso del BNC
  -- =========================================================================
  v_j := pg_temp.ini_orden(v_cajero, v_m, pg_temp.ini_paciente('V20009102', '04140009102', 'Bea'), 30, 'ini-b');
  v_cb := (v_j->>'id')::uuid;
  v_pb := (select user_id from public.charges where id = v_cb);
  v_j := pg_temp.ini_si(v_cb, 'wamid.ini.b.si');
  if v_j->>'status' <> 'awaiting_down_payment' then
    raise exception '5. El «Sí» con la cédula guardada deja la orden esperando la inicial: %', v_j;
  end if;
  if (select array_agg(amount_usd order by sequence) from public.installments where charge_id = v_cb)
       <> array[17.09, 8.55, 8.54]::numeric[] then
    raise exception '5. Las cuotas de $30 no quedaron bien';
  end if;

  select id into v_i0 from public.installments where charge_id = v_cb and sequence = 0;
  v_monto := public.helios_installments_ves(v_pb, array[v_i0], v_bdate);
  v_res := public.bot_comprobante_datos('wamid.ini.b.datos', '+584140009102', v_pb, 'Banesco', '0414-000-9102', '0009102910');
  if v_res->>'outcome' <> 'esperando' then
    raise exception '5. Los datos sin el aviso del BNC esperan: %', v_res;
  end if;
  update public.charges set down_payment_due_at = now() where id = v_cb;
  if not public.helios_down_payment_open(v_cb) then
    raise exception '5. Unos datos esperando el aviso del BNC son un pago abierto';
  end if;
  v_res := public.helios_bank_sms_ingest(format(
    'BNC Pago Movil Recibido Bs.%s Telf.0414***9102 Dia:%s-10:15 Ref:009102910',
    replace(to_char(v_monto, 'FM999999990.00'), '.', ','), v_dia), '2622');
  set constraints all immediate;
  set constraints all deferred;
  if (select status from public.charges where id = v_cb) <> 'confirmed'
     or (select activated_at from public.charges where id = v_cb) is null then
    raise exception '5. Los datos con su aviso del BNC debían activar la orden: % / %', v_res,
      (select status from public.charges where id = v_cb);
  end if;

  -- =========================================================================
  -- 6. En euros
  -- =========================================================================
  v_j := pg_temp.ini_orden(v_cajero, v_m, pg_temp.ini_paciente('V20009103', '04140009103', 'Cira'), 100, 'ini-c', 'EUR');
  v_cc := (v_j->>'id')::uuid;
  v_j := pg_temp.ini_si(v_cc, 'wamid.ini.c.si');
  select * into v_c from public.charges where id = v_cc;
  if v_c.status <> 'awaiting_down_payment' or v_c.currency <> 'EUR'
     or (select array_agg(amount_cur order by sequence) from public.installments where charge_id = v_cc)
          <> array[56.96, 28.48, 28.48]::numeric[]
     or (select array_agg(financed_cur order by sequence) from public.installments where charge_id = v_cc)
          <> array[50, 25, 25]::numeric[]
     or (select sum(amount_usd) from public.installments where charge_id = v_cc) <> v_c.amount_usd
     or (select sum(financed_usd) from public.installments where charge_id = v_cc) <> v_c.base_usd then
    raise exception '6. El reparto en euros no quedó bien: %',
      (select jsonb_agg(jsonb_build_object('s', sequence, 'usd', amount_usd, 'cur', amount_cur, 'fcur', financed_cur))
       from public.installments where charge_id = v_cc);
  end if;
  if (select rendered_text from public.outbound_messages where charge_id = v_cc and template_key = 'pagar_inicial')
       not like '%inicial de €56,96%' then
    raise exception '6. El mensaje de la inicial va en euros';
  end if;

  -- =========================================================================
  -- 7. Vence sin pago → se anula sola
  -- =========================================================================
  v_j := pg_temp.ini_orden(v_cajero, v_m, pg_temp.ini_paciente('V20009104', '04140009104', 'Dora'), 40, 'ini-d');
  v_cd := (v_j->>'id')::uuid;
  v_pd := (select user_id from public.charges where id = v_cd);
  perform pg_temp.ini_si(v_cd, 'wamid.ini.d.si');
  if public.helios_credit_used_usd(v_pd) <> 40 then
    raise exception '7. Esperando la inicial, el límite ya cuenta la consulta';
  end if;

  -- Aún en plazo: no se toca.
  perform public.helios_revert_unpaid_down_payments();
  if (select status from public.charges where id = v_cd) <> 'awaiting_down_payment' then
    raise exception '7. En plazo, la orden no se anula';
  end if;

  update public.charges set down_payment_due_at = now() where id = v_cd;
  perform public.helios_revert_unpaid_down_payments();
  select * into v_c from public.charges where id = v_cd;
  if v_c.status <> 'reverted' or v_c.down_payment_expired_at is null
     or v_c.void_reason <> 'La inicial no se pagó a tiempo' then
    raise exception '7. Sin la inicial a tiempo la orden se anula sola: %', to_jsonb(v_c);
  end if;
  if exists (select 1 from public.installments where charge_id = v_cd) or public.helios_credit_used_usd(v_pd) <> 0 then
    raise exception '7. Anulada, sin cuotas y con el cupo de vuelta';
  end if;
  if (select coalesce(sum(e.debit - e.credit), 0)
      from ledger.transactions t join ledger.entries e on e.transaction_id = t.id
      where t.reference_id = v_cd) <> 0
     or not exists (select 1 from ledger.transactions t
                    where t.reference_id = v_cd and t.type = 'manual_adjustment'
                      and t.idempotency_key = 'reverse_charge:' || v_cd) then
    raise exception '7. El asiento contrario debía dejar la orden en cero';
  end if;
  if (select status from public.outbound_messages where charge_id = v_cd and template_key = 'pagar_inicial') <> 'cancelado' then
    raise exception '7. El mensaje de la inicial que no salió se cancela';
  end if;
  if not exists (select 1 from public.outbound_messages
                 where recipient = '+584140009104' and template_key = 'bot_paciente'
                   and rendered_text like 'Dora, tu pago en cuotas #% se anuló porque no recibimos tu inicial a tiempo%') then
    raise exception '7. Al paciente se le avisa que se anuló';
  end if;
  if not exists (select 1 from public.outbound_messages
                 where recipient = '+584120009100'
                   and rendered_text like '⌛ La orden #% de Dora P. se anuló: no pagó la inicial a tiempo.%') then
    raise exception '7. Al médico se le avisa que se anuló';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.merchant_transactions(v_bdate, v_bdate, 50) t
  where t.charge_id = v_cd and t.status = 'reverted' and t.down_payment_expired_at is not null
    and t.cuota_1_due is null and t.cuota_1_run is null and t.cuota_2_due is null and t.cuota_2_run is null;
  reset role;
  if v_n <> 1 then
    raise exception '7. La clínica ve la orden anulada por no pagar la inicial (con down_payment_expired_at y sin fechas de cuotas)';
  end if;

  -- El libro de ventas de la clínica no la trae: nunca fue una venta.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.merchant_sales_export(v_bdate, v_bdate) x where x.charge_id = v_cd)
     or not exists (select 1 from public.merchant_sales_export(v_bdate, v_bdate) x where x.charge_id = v_ca) then
    raise exception '7. El libro de ventas excluye la anulada por la inicial y trae la activa';
  end if;
  reset role;

  -- El superadmin: la lista de órdenes y la Caja dicen la inicial.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  if not exists (select 1 from public.admin_charges(null, v_m, null, null, null, 100) a
                 where a.charge_id = v_cd and a.down_payment_expired_at is not null and a.down_payment_pct = 50)
     or not exists (select 1 from public.admin_charges(null, v_m, null, null, null, 100) a
                    where a.charge_id = v_ca and a.installments_total = 3 and a.activated_at is not null
                      and a.down_payment_expired_at is null) then
    raise exception '7. admin_charges debía traer los datos de la inicial';
  end if;
  reset role;
  v_rep := (select r.id from public.payment_reports r
            join public.payment_quote_items qi on qi.quote_id = r.quote_id
            join public.installments i on i.id = qi.installment_id
            where i.charge_id = v_ca and i.sequence = 0 limit 1);
  v_j := public.helios_admin_payment_item(v_rep, v_bdate + 3);
  if v_j::text not like '%"down_payment_pct": 50%' or v_j::text not like '%"days_overdue": 0%' then
    raise exception '7. La Caja dice la inicial y no le pone días de atraso: %', v_j;
  end if;

  -- =========================================================================
  -- 8. Pago abierto al vencer → espera; rechazado → se anula
  -- =========================================================================
  v_j := pg_temp.ini_orden(v_cajero, v_m, pg_temp.ini_paciente('V20009105', '04140009105', 'Eva'), 50, 'ini-e');
  v_ce := (v_j->>'id')::uuid;
  v_pe := (select user_id from public.charges where id = v_ce);
  perform pg_temp.ini_si(v_ce, 'wamid.ini.e.si');

  select id into v_i0 from public.installments where charge_id = v_ce and sequence = 0;
  v_monto := public.helios_installments_ves(v_pe, array[v_i0], v_bdate);
  v_id := (public.bot_comprobante_nuevo('wamid.ini.e.cap', '+584140009105', v_pe, 'media-e', 'image/jpeg')->>'id')::uuid;
  perform public.lector_tomar(5);
  v_res := public.lector_leido(v_id, null, v_x,
             jsonb_build_object('method', 'pago_movil', 'bank', 'Banesco', 'reference', '1195050505',
                                'amount_ves', v_monto, 'paid_on', v_bdate),
             'claude-sonnet-5-5', '{}');
  v_rep := (select report_id from public.payment_receipt_reads where id = v_id);
  if v_rep is null then
    raise exception '8. La captura debía quedar como un pago reportado: %', v_res;
  end if;

  update public.charges set down_payment_due_at = now() where id = v_ce;
  perform public.helios_revert_unpaid_down_payments();
  if (select status from public.charges where id = v_ce) <> 'awaiting_down_payment' then
    raise exception '8. Con el pago en revisión, la orden espera';
  end if;

  perform public.reconcile_payment(v_rep, v_admin, false, 'No llegó a la cuenta');
  perform public.helios_revert_unpaid_down_payments();
  if (select status from public.charges where id = v_ce) <> 'reverted'
     or exists (select 1 from public.installments where charge_id = v_ce)
     or (select status from public.payment_reports where id = v_rep) <> 'rejected' then
    raise exception '8. Rechazado el pago, la orden se anula en la siguiente pasada (y el pago rechazado queda)';
  end if;

  -- Una captura que aún se lee también es un pago abierto.
  v_j := pg_temp.ini_orden(v_cajero, v_m, pg_temp.ini_paciente('V20009106', '04140009106', 'Flor'), 20, 'ini-e2');
  perform pg_temp.ini_si((v_j->>'id')::uuid, 'wamid.ini.e2.si');
  perform public.bot_comprobante_nuevo('wamid.ini.e2.cap', '+584140009106',
                                       (select user_id from public.charges where id = (v_j->>'id')::uuid),
                                       'media-e2', 'image/jpeg');
  update public.charges set down_payment_due_at = now() where id = (v_j->>'id')::uuid;
  perform public.helios_revert_unpaid_down_payments();
  if (select status from public.charges where id = (v_j->>'id')::uuid) <> 'awaiting_down_payment' then
    raise exception '8. Con la captura por leer, la orden espera';
  end if;

  -- Una imagen que llegó a tiempo y el lector no tomó (apagado) también.
  update public.receipt_reader_settings set mode = 'apagado';
  v_j := pg_temp.ini_orden(v_cajero, v_m, pg_temp.ini_paciente('V20009108', '04140009108', 'Hilda'), 20, 'ini-h');
  v_id := (v_j->>'id')::uuid;
  perform pg_temp.ini_si(v_id, 'wamid.ini.h.si');
  -- La «foto de la cédula» (la respuesta del «Sí») no cuenta como pago.
  insert into public.whatsapp_inbound (wa_message_id, from_phone, type, payload)
  values ('wamid.ini.h.si', '+584140009108', 'image', '{}');
  update public.charges set down_payment_due_at = now() where id = v_id;
  if public.helios_down_payment_open(v_id) then
    raise exception '8. La respuesta del «Sí» no es un pago abierto';
  end if;
  insert into public.whatsapp_inbound (wa_message_id, from_phone, type, payload)
  values ('wamid.ini.h.img', '+584140009108', 'image', '{}');
  perform public.helios_revert_unpaid_down_payments();
  if (select status from public.charges where id = v_id) <> 'awaiting_down_payment' then
    raise exception '8. Con una imagen a tiempo que nadie leyó, la orden espera';
  end if;
  -- Pasadas 24 h del plazo, se anula.
  update public.charges set answered_at = now() - interval '26 hours',
                            down_payment_due_at = now() - interval '25 hours' where id = v_id;
  update public.whatsapp_inbound set received_at = now() - interval '25 hours 30 minutes'
   where wa_message_id in ('wamid.ini.h.img', 'wamid.ini.h.si');
  if not public.helios_down_payment_open(v_id) is false then
    raise exception '8. Pasadas 24 h del plazo, la imagen ya no lo sostiene';
  end if;
  perform public.helios_revert_unpaid_down_payments();
  if (select status from public.charges where id = v_id) <> 'reverted' then
    raise exception '8. Pasadas 24 h del plazo, la orden se anula';
  end if;
  update public.receipt_reader_settings set mode = 'activo';

  -- Una lectura colgada (el lector se cayó) sostiene la orden como mucho 24 h
  -- después del plazo.
  v_j := pg_temp.ini_orden(v_cajero, v_m, pg_temp.ini_paciente('V20009109', '04140009109', 'Ines'), 20, 'ini-i');
  v_id := (v_j->>'id')::uuid;
  perform pg_temp.ini_si(v_id, 'wamid.ini.i.si');
  perform public.bot_comprobante_nuevo('wamid.ini.i.cap', '+584140009109',
                                       (select user_id from public.charges where id = v_id), 'media-i', 'image/jpeg');
  update public.charges set down_payment_due_at = now() - interval '25 hours' where id = v_id;
  update public.payment_receipt_reads set created_at = now() - interval '25 hours 30 minutes'
   where wa_message_id = 'wamid.ini.i.cap';
  update public.charges set created_at = now() - interval '26 hours' where id = v_id;
  if public.helios_down_payment_open(v_id) then
    raise exception '8. Una lectura colgada no sostiene la orden pasadas 24 h del plazo';
  end if;
  perform public.helios_revert_unpaid_down_payments();
  if (select status from public.charges where id = v_id) <> 'reverted' then
    raise exception '8. Con la lectura colgada, pasadas 24 h, se anula';
  end if;

  -- =========================================================================
  -- 8b. Ronda 3: el reparto de un monto, la alerta, la activación tardía,
  --     el parámetro, la reversa a mano y la ficha del paciente
  -- =========================================================================
  -- Dos órdenes esperando la inicial del mismo monto: el monto no se adivina.
  v_j := pg_temp.ini_orden(v_cajero, v_m, pg_temp.ini_paciente('V20009110', '04140009110', 'Julia'), 30, 'ini-g');
  v_cg := (v_j->>'id')::uuid;
  v_pg := (select user_id from public.charges where id = v_cg);
  perform pg_temp.ini_si(v_cg, 'wamid.ini.g.si');
  select id into v_i0 from public.installments where charge_id = v_cg and sequence = 0;
  v_monto := public.helios_installments_ves(v_pg, array[v_i0], v_bdate);
  if public.helios_receipt_tramo(v_pg, v_bdate, v_monto) is distinct from array[v_i0] then
    raise exception '8b. Con una sola orden esperando, el monto de la inicial paga su cuota 0';
  end if;
  -- Otra orden igual del mismo paciente, de otra clínica no hace falta: el
  -- cupo da para dos de $30.
  v_j := pg_temp.ini_orden(v_cajero, v_m,
           pg_temp.ini_paciente('V20009110', '04140009110', 'Julia'), 30, 'ini-g2');
  v_ch := (v_j->>'id')::uuid;
  perform pg_temp.ini_si(v_ch, 'wamid.ini.g2.si');
  if public.helios_receipt_tramo(v_pg, v_bdate, v_monto) is not null then
    raise exception '8b. Dos iniciales del mismo monto: el monto va al equipo, no se adivina';
  end if;
  -- El doble de una inicial no es ambiguo: paga las dos (las iniciales primero).
  if cardinality(public.helios_receipt_tramo(v_pg, v_bdate, v_monto * 2)) <> 2 then
    raise exception '8b. El monto de las dos iniciales paga las dos';
  end if;

  -- La alerta de una orden que lleva horas pasada su plazo (un pago en
  -- revisión la sostiene).
  update public.charges set down_payment_due_at = now() - interval '7 hours' where id = v_ch;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_risk_alerts(200, array['inicial_atascada'], null);
  reset role;
  if not exists (select 1 from jsonb_array_elements(v_j->'rows') x
                 where x->>'kind' = 'inicial_atascada' and (x->'detail'->>'charge_id')::uuid = v_ch) then
    raise exception '8b. Debía salir la alerta inicial_atascada: %', v_j;
  end if;
  update public.charges set down_payment_due_at = now() + interval '1 hour' where id = v_ch;

  -- Activación tardía, pasadas las dos fechas de la clínica: la 1.ª mitad hoy
  -- y la 2.ª mañana (nunca el mismo día), y el lote crea las dos.
  update public.installments set settlement_due_date = v_bdate - 9 where charge_id = v_cg and sequence = 1;
  update public.installments set settlement_due_date = v_bdate - 2 where charge_id = v_cg and sequence = 2;
  perform public.helios_activate_charge(v_cg);
  if (select array_agg(settlement_due_date order by sequence) from public.installments
      where charge_id = v_cg and sequence > 0) <> array[v_bdate, v_bdate + 1] then
    raise exception '8b. Activada tarde: la 1.ª mitad hoy y la 2.ª mañana: %',
      (select array_agg(settlement_due_date order by sequence) from public.installments where charge_id = v_cg);
  end if;
  perform public.run_scheduled_settlements_batch(v_bdate, '00000000-0000-0000-0000-000000000000'::uuid, 1000);
  perform public.run_scheduled_settlements_batch(v_bdate + 1, '00000000-0000-0000-0000-000000000000'::uuid, 1000);
  if (select count(*) from public.settlements where charge_id = v_cg and reason = 'scheduled_installment') <> 2
     or (select sum(amount_usd) from public.settlements where charge_id = v_cg and reason = 'scheduled_installment') <> 30 then
    raise exception '8b. Activada tarde, la clínica cobra sus dos mitades';
  end if;

  -- La inicial nunca va a la clínica, tampoco con «al cobrar».
  insert into public.settlements (merchant_id, installment_id, reason, amount_usd, business_date, due_date, status)
  select v_m, i.id, 'on_collection', 10, v_bdate, v_bdate, 'pending'
  from public.installments i where i.charge_id = v_cg and i.sequence = 0;
  if exists (select 1 from public.settlements s join public.installments i on i.id = s.installment_id
             where i.charge_id = v_cg and i.sequence = 0) then
    raise exception '8b. La cuota 0 no genera liquidación on_collection';
  end if;

  -- Paciente recurrente: una orden activa (K1) cuyas 2 cuotas, que aún no
  -- vencen, suman lo mismo que la inicial de su orden nueva (K2). Gana la
  -- inicial; y pagar K2 entera paga K2, no la inicial de K2 con cuotas de K1.
  v_j := pg_temp.ini_orden(v_cajero, v_m, pg_temp.ini_paciente('V20009111', '04140009111', 'Karla'), 30, 'ini-k1');
  v_k1 := (v_j->>'id')::uuid;
  v_pk := (select user_id from public.charges where id = v_k1);
  perform pg_temp.ini_si(v_k1, 'wamid.ini.k1.si');
  update public.installments set status = 'paid', paid_at = now() where charge_id = v_k1 and sequence = 0;
  if (select status from public.charges where id = v_k1) <> 'confirmed' then
    raise exception '8b. K1 debía quedar activa';
  end if;
  v_j := pg_temp.ini_orden(v_cajero, v_m, pg_temp.ini_paciente('V20009111', '04140009111', 'Karla'), 30, 'ini-k2');
  v_k2 := (v_j->>'id')::uuid;
  perform pg_temp.ini_si(v_k2, 'wamid.ini.k2.si');
  select id into v_i0 from public.installments where charge_id = v_k2 and sequence = 0;
  v_monto := public.helios_installments_ves(v_pk, array[v_i0], v_bdate);
  if public.helios_installments_ves(v_pk, array(select id from public.installments where charge_id = v_k1 and sequence > 0), v_bdate)
       <> v_monto then
    raise exception '8b. La prueba necesita que las 2 cuotas de K1 valgan lo mismo que la inicial de K2';
  end if;
  if public.helios_receipt_tramo(v_pk, v_bdate, v_monto) is distinct from array[v_i0] then
    raise exception '8b. Entre la inicial y adelantar cuotas que no vencen, gana la inicial: %',
      public.helios_receipt_tramo(v_pk, v_bdate, v_monto);
  end if;
  v_k2ids := array(select id from public.installments where charge_id = v_k2 order by sequence);
  v_monto := public.helios_installments_ves(v_pk, v_k2ids, v_bdate);
  if public.helios_receipt_tramo(v_pk, v_bdate, v_monto) is distinct from v_k2ids then
    raise exception '8b. Pagar K2 entera paga K2: %', public.helios_receipt_tramo(v_pk, v_bdate, v_monto);
  end if;

  -- Y así, de una vez (datos + aviso del BNC): el comprobante sale con las
  -- cuotas 1 y 2 pagadas.
  v_res := public.bot_comprobante_datos('wamid.ini.k2.datos', '+584140009111', v_pk, 'Banesco', '0414-000-9111', '0009111911');
  v_res := public.helios_bank_sms_ingest(format(
    'BNC Pago Movil Recibido Bs.%s Telf.0414***9111 Dia:%s-11:15 Ref:009111911',
    replace(to_char(v_monto, 'FM999999990.00'), '.', ','), v_dia), '2622');
  set constraints all immediate;
  set constraints all deferred;
  select rendered_text into v_txt from public.outbound_messages
  where charge_id = v_k2 and template_key = 'comprobante_financiamiento';
  if (select status from public.charges where id = v_k2) <> 'confirmed'
     or exists (select 1 from public.installments where charge_id = v_k1 and status = 'paid' and sequence > 0)
     or v_txt is null or v_txt not like '%• Cuota 1: $8,55, pagada el %' or v_txt not like '%• Cuota 2: $8,54, pagada el %' then
    raise exception '8b. Pagada K2 entera: activa, K1 intacta y el comprobante con sus cuotas pagadas: % / %', v_res, v_txt;
  end if;

  -- El parámetro: la inicial va de 0 a 90 y el plazo es de al menos 1 minuto.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_err := null;
  begin
    perform public.admin_set_business_parameter('down_payment_pct', 95, null, 'prueba');
  exception when others then v_err := sqlerrm;
  end;
  if v_err is null or v_err not like 'La inicial va de 0 a 90%' then
    raise exception '8b. Una inicial de 95%% no se guarda: %', v_err;
  end if;
  v_err := null;
  begin
    perform public.admin_set_business_parameter('down_payment_minutes', 0, null, 'prueba');
  exception when others then v_err := sqlerrm;
  end;
  if v_err is null then
    raise exception '8b. Un plazo de 0 minutos no se guarda';
  end if;

  -- La reversa a mano de una que espera la inicial: tampoco va al libro.
  perform public.admin_reverse_charge(v_ch, 'Prueba de reversa a mano');
  reset role;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.merchant_sales_export(v_bdate, v_bdate) x where x.charge_id = v_ch) then
    raise exception '8b. Una orden con inicial nunca activada no va al libro de ventas, la revierta quien la revierta';
  end if;
  reset role;

  -- La ficha del paciente: «Sus financiamientos» trae la inicial.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.helios_admin_user_detail_base(v_pg);
  if not exists (select 1 from jsonb_array_elements(v_j->'consumos') x
                 where (x->>'charge_id')::uuid = v_cg and (x->>'down_payment_pct')::numeric = 50
                   and x->>'activated_at' is not null and x ? 'down_payment_expired_at') then
    raise exception '8b. consumos debía traer los datos de la inicial: %', v_j->'consumos';
  end if;

  -- =========================================================================
  -- 9. Una orden sin inicial: como siempre
  -- =========================================================================
  update public.business_parameters set value = 0 where key = 'down_payment_pct' and effective_from = v_bdate;
  v_j := pg_temp.ini_orden(v_cajero, v_m, pg_temp.ini_paciente('V20009107', '04140009107', 'Gala'), 100, 'ini-f');
  v_cf := (v_j->>'id')::uuid;
  update public.business_parameters set value = 50 where key = 'down_payment_pct' and effective_from = v_bdate;

  if (select down_payment_pct from public.charges where id = v_cf) <> 0
     or jsonb_array_length(v_j->'installments') <> 2
     or not exists (select 1 from public.outbound_messages where charge_id = v_cf and template_key = 'confirmar_financiamiento'
                      and rendered_text like '%*2 cuotas, sin inicial*%') then
    raise exception '9. Sin inicial, la pregunta de siempre: %', v_j;
  end if;
  v_j := pg_temp.ini_si(v_cf, 'wamid.ini.f.si');
  if v_j->>'status' <> 'confirmed'
     or (select array_agg(sequence order by sequence) from public.installments where charge_id = v_cf) <> array[1, 2]::smallint[]
     or (select array_agg(amount_usd order by sequence) from public.installments where charge_id = v_cf) <> array[56.96, 56.96]::numeric[]
     or not exists (select 1 from public.outbound_messages where charge_id = v_cf and template_key = 'bienvenida')
     or not exists (select 1 from public.outbound_messages where charge_id = v_cf and template_key = 'comprobante_financiamiento'
                      and rendered_text like '%TU PLAN DE PAGOS (sin inicial)%')
     or exists (select 1 from public.outbound_messages where charge_id = v_cf and template_key = 'pagar_inicial') then
    raise exception '9. Sin inicial, el «Sí» confirma como siempre: %', v_j;
  end if;

  -- =========================================================================
  -- 10. El límite cuenta la consulta entera con la inicial pagada
  -- =========================================================================
  if public.helios_credit_used_usd(v_pa) <> 100 then
    raise exception '10. Con la inicial pagada, el límite sigue contando la consulta entera: %',
      public.helios_credit_used_usd(v_pa);
  end if;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V20009101');
  v_j := public.preview_patient_charge(v_m, 'V20009101', 60, 'USD');
  reset role;
  if (v_j->>'cabe')::boolean or (v_j->>'disponible_usd')::numeric <> 50 then
    raise exception '10. Con $100 ocupados de $150, $60 no caben: %', v_j;
  end if;
end $$;

set constraints all immediate;

rollback;
