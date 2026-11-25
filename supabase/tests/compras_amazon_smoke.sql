-- ============================================================================
-- Helios — Compras Amazon para Médicos (20261124120000)
--
--   bash supabase/tests/run.sh compras_amazon_smoke
--
-- Prueba de humo integral (en transacción con rollback):
--   1. Cálculo aéreo, volumétrico, fallback y marítimo en numeric(18,4)/(18,2).
--   2. Creación normal y con restricción aduanal, caché de catálogo y bloque
--      de pago con cuentas reales sin titular ni palabras prohibidas.
--   3. Aprobación y rechazo de revisión aduanal.
--   4. Reporte de pago por bot (con y sin monto) y por admin, validación de
--      ruta de captura, detección de referencia duplicada, marcado en revisión
--      y cierre como duplicado (sin avisar al médico).
--   5. Regla four-eyes (operador vs otro operador vs super_admin).
--   6. Simulador aislado: rechazar (vuelve a esperando_pago) y aprobar (pasa a
--      pagado) escriben en purchase_simulator_messages y JAMÁS en outbound_messages.
--   7. Avance logístico completo hasta entregado, transiciones inválidas y
--      protección append-only de purchase_request_events.
--   8. WhatsApp Cloud API: helios_whatsapp_payload para list, text y button
--      (el carrusel se retiró en 20261125120000).
--   9. Configuración purchase_settings solo editable por super_admin + audit.log.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_super     uuid := pg_temp.prueba_admin();
  v_op1       uuid := gen_random_uuid();
  v_op2       uuid := gen_random_uuid();
  v_doc       uuid := gen_random_uuid();
  v_merchant  uuid;
  v_branch    uuid;
  v_phone     text := '+584149991122';
  v_sim_phone text := '+584128887766';
  v_today     date := public.helios_business_date(now());
  v_fx        numeric(18,6) := 50.000000;
  v_calc      jsonb;
  v_res       jsonb;
  v_req1      uuid;
  v_req2      uuid;
  v_req3      uuid;
  v_sim_req   uuid;
  v_rep1      uuid;
  v_rep2      uuid;
  v_rep_dup   uuid;
  v_rep_sim1  uuid;
  v_rep_sim2  uuid;
  v_out_before integer;
  v_out_after  integer;
  v_sim_count  integer;
  v_msg_id    uuid;
  v_msg_row   public.outbound_messages%rowtype;
  v_payload   jsonb;
  v_block     text;
  v_detail    jsonb;
  v_counts    jsonb;
begin
  -- ── Preparación de actores, clínica, tasa BCV y cuentas de cobro ──────────
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'amz-' || u || '@prueba.helios.test', now(), now(), now()
  from unnest(array[v_op1, v_op2, v_doc]) u;

  insert into public.platform_admins (user_id, role, full_name, is_active) values
    (v_op1, 'operador', 'Operador Uno', true),
    (v_op2, 'operador', 'Operador Dos', true);

  insert into public.merchants (name) values ('Clínica Amazon Prueba') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_doc, v_merchant, v_branch, 'gerente');

  insert into public.staff_whatsapp_numbers (phone_e164, user_id, merchant_id, created_by)
  values (v_phone, v_doc, v_merchant, v_super);

  -- Ventana de 24 h abierta para v_phone
  insert into public.whatsapp_contacts (phone_e164, last_inbound_at)
  values (v_phone, now())
  on conflict (phone_e164) do update set last_inbound_at = excluded.last_inbound_at;

  -- Tasa BCV conocida (50 Bs/USD) y cuentas de pago activas (con titular para verificar que NO salga)
  insert into public.exchange_rates (source, rate, effective_date)
  values ('BCV', v_fx, v_today)
  on conflict (source, effective_date) do update set rate = excluded.rate;

  insert into public.payment_destinations (method, bank_name, phone, rif, holder_name, is_active, sort_order)
  values ('pago_movil', 'BNC Prueba', '04141234567', 'J-50123456-7', 'NO DEBE SALIR TITULAR', true, 1);

  -- Activar four-eyes
  insert into public.business_parameters (key, value, effective_from, note)
  values ('payment_four_eyes', 1, v_today, 'prueba compras amazon')
  on conflict (key, effective_from) do update set value = 1;

  -- El módulo nace APAGADO y con el catálogo falso (20261124180100): las
  -- pruebas lo abren con `rainforest` (el único proveedor que puede abrirse a
  -- todos). Nunca se llama a la API de Amazon: solo se prueba la base.
  update public.purchase_settings
     set catalog_provider = 'rainforest', is_enabled = true, pilot_phones = '{}'
   where id;

  -- ── 1. Cálculos: aéreo mínimo, volumétrico, fallback y marítimo ──────────
  -- 1a) Aéreo por debajo del mínimo: $100 x 1, peso 1.0 lb → ship = max(15, 6.50) = 15.00
  v_calc := public.helios_purchase_calculate(100.00, 1, 'aereo', 1.0, null, null);
  if (v_calc->>'subtotal_usd')::numeric <> 100.00
     or (v_calc->>'tax_usa_usd')::numeric <> 7.00
     or (v_calc->>'shipping_usd')::numeric <> 15.00
     or (v_calc->>'service_fee_usd')::numeric <> 10.00
     or (v_calc->>'total_usd')::numeric <> 132.00
     or (v_calc->>'quoted_ves')::numeric <> 6600.00
     or (v_calc->>'weight_estimated')::boolean then
    raise exception 'Cálculo aéreo mínimo incorrecto: %', v_calc;
  end if;

  -- 1b) Aéreo con peso volumétrico mayor (4.0 lb > 1.0 lb) → 4 * 6.50 = 26.00
  v_calc := public.helios_purchase_calculate(100.00, 1, 'aereo', 1.0, 4.0, null);
  if (v_calc->>'billable_lb')::numeric <> 4.0
     or (v_calc->>'shipping_usd')::numeric <> 26.00
     or (v_calc->>'total_usd')::numeric <> 143.00 then
    raise exception 'Cálculo aéreo volumétrico incorrecto: %', v_calc;
  end if;

  -- 1c) Aéreo con fallback (sin peso real ni volumétrico) → 1.5 lb * 2 = 3.0 lb → 19.50
  v_calc := public.helios_purchase_calculate(50.00, 2, 'aereo', null, null, null);
  if not (v_calc->>'weight_estimated')::boolean
     or (v_calc->>'billable_lb')::numeric <> 3.0
     or (v_calc->>'shipping_usd')::numeric <> 19.50 then
    raise exception 'Cálculo aéreo fallback incorrecto: %', v_calc;
  end if;

  -- 1d) Marítimo por encima del mínimo (2.0 ft3 * 28 = 56.00) y por debajo (0.5 ft3 → 35.00)
  v_calc := public.helios_purchase_calculate(200.00, 1, 'maritimo', null, null, 2.0);
  if (v_calc->>'shipping_usd')::numeric <> 56.00
     or (v_calc->>'total_usd')::numeric <> 290.00 then
    raise exception 'Cálculo marítimo > mínimo incorrecto: %', v_calc;
  end if;
  v_calc := public.helios_purchase_calculate(200.00, 1, 'maritimo', null, null, 0.5);
  if (v_calc->>'shipping_usd')::numeric <> 35.00 then
    raise exception 'Cálculo marítimo mínimo incorrecto: %', v_calc;
  end if;

  -- ── 2. Caché, bot_compra_config, creación normal y restringida ───────────
  v_res := public.bot_compra_config();
  if not (v_res->>'is_enabled')::boolean or (v_res->>'catalog_provider') <> 'rainforest' then
    raise exception 'bot_compra_config inesperado: %', v_res;
  end if;

  perform public.bot_compra_cache_set('search:estetoscopio', 'search', 'mock', '[{"asin":"B00TEST001"}]'::jsonb, 30);
  if coalesce((public.bot_compra_cache_get('search:estetoscopio')->0->>'asin'), '') <> 'B00TEST001' then
    raise exception 'bot_compra_cache_get no devolvió el payload esperado';
  end if;

  -- Creación normal → esperando_pago + bloque de pago sin titular ni palabras prohibidas
  v_res := public.bot_compra_crear(
    p_phone => v_phone,
    p_asin => 'B00LITTM01',
    p_product_title => 'Estetoscopio Littmann Classic III',
    p_quantity => 1,
    p_weight_lb => 1.2,
    p_shipping_method => 'aereo',
    p_unit_price_usd => 100.00
  );
  v_req1 := (v_res->>'request_id')::uuid;
  v_block := v_res->>'payment_block';
  if v_res->>'status' <> 'esperando_pago' or v_block is null then
    raise exception 'Solicitud normal debía quedar esperando_pago con bloque de pago: %', v_res;
  end if;
  if position('BNC Prueba' in v_block) = 0 or position('J-50123456-7' in v_block) = 0 then
    raise exception 'Bloque de pago no incluye las cuentas activas: %', v_block;
  end if;
  if position('NO DEBE SALIR TITULAR' in v_block) > 0
     or position('Titular' in v_block) > 0
     or lower(v_block) ~ '(préstamo|prestamo|financiamiento|financiar|crédito|credito|\yfee\y)' then
    raise exception 'Bloque de pago contiene titular o palabra prohibida: %', v_block;
  end if;

  -- Creación con restricción aduanal → revision_aduanal sin bloque de pago
  v_res := public.bot_compra_crear(
    p_phone => v_phone,
    p_asin => 'B00LASER99',
    p_product_title => 'Láser quirúrgico portátil',
    p_quantity => 1,
    p_weight_lb => 2.0,
    p_restricted_flag => true,
    p_restricted_reason => 'Requiere permiso sanitario',
    p_shipping_method => 'aereo',
    p_unit_price_usd => 250.00
  );
  v_req2 := (v_res->>'request_id')::uuid;
  if v_res->>'status' <> 'revision_aduanal' or (v_res->>'payment_block') is not null then
    raise exception 'Solicitud restringida debía quedar en revision_aduanal sin bloque: %', v_res;
  end if;

  -- Solicitud extra para probar rechazo aduanal
  v_res := public.bot_compra_crear(
    p_phone => v_phone,
    p_asin => 'B00PROHIB1',
    p_product_title => 'Reactivo químico restringido',
    p_restricted_flag => true,
    p_restricted_reason => 'Sustancia controlada',
    p_unit_price_usd => 80.00
  );
  v_req3 := (v_res->>'request_id')::uuid;

  if jsonb_array_length(public.bot_compra_mis_solicitudes(v_phone, 8)) <> 3 then
    raise exception 'bot_compra_mis_solicitudes debía devolver 3 solicitudes';
  end if;
  if (public.bot_compra_pendiente_de_pago(v_phone)->>'request_id')::uuid <> v_req1 then
    raise exception 'bot_compra_pendiente_de_pago debía devolver v_req1';
  end if;

  -- ── 3. Revisión aduanal (aprobar y rechazar) ─────────────────────────────
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op1::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  v_res := public.admin_purchase_approve_customs(v_req2, true, 'Permiso validado');
  if v_res->>'status' <> 'esperando_pago' or (v_res->>'payment_block') is null then
    raise exception 'Aprobación aduanal falló: %', v_res;
  end if;

  begin
    perform public.admin_purchase_approve_customs(v_req3, false, '');
    raise exception 'Rechazo aduanal sin motivo debía fallar';
  exception when sqlstate '22023' then null;
  end;

  v_res := public.admin_purchase_approve_customs(v_req3, false, 'Artículo no importable por normativa');
  if v_res->>'status' <> 'cancelado' then
    raise exception 'Rechazo aduanal debía cancelar la solicitud: %', v_res;
  end if;

  -- ── 4. Reporte por bot (sin monto), path traversal, duplicado y flag ─────
  begin
    perform public.bot_compra_reportar_pago(
      v_phone, v_req1, 'pago_movil', 'Banesco', '12345678', null, null, '../malicioso.jpg'
    );
    raise exception 'Ruta con path traversal debía fallar';
  exception when sqlstate '22023' then null;
  end;

  begin
    perform public.bot_compra_reportar_pago(
      v_phone, v_req1, 'pago_movil', 'Banesco', '12345678', null, null, 'otro_prefijo/cap.jpg'
    );
    raise exception 'Ruta fuera de compras/ debía fallar';
  exception when sqlstate '22023' then null;
  end;

  -- Reporte por bot sin monto (p_amount_ves = null) → el monto declarado queda
  -- NULO (ya no se autocompleta con el esperado: antes «cuadraba» siempre).
  v_res := public.bot_compra_reportar_pago(
    p_phone => v_phone,
    p_request_id => v_req1,
    p_method => 'pago_movil',
    p_bank => 'Banesco',
    p_reference => 'REF99001122',
    p_payer_phone => '04141112233',
    p_amount_ves => null,
    p_receipt_path => 'compras/req1/cap.jpg',
    p_wa_message_id => 'wamid.test.001'
  );
  v_rep1 := (v_res->>'report_id')::uuid;
  if v_res->>'status' <> 'reported'
     or (v_res->>'expected_ves')::numeric <> 6600.00
     or (v_res->'declared_amount_ves') <> 'null'::jsonb
     or (v_res->'monto_cuadra') <> 'null'::jsonb
     or (v_res->>'monto_declarado')::boolean then
    raise exception 'Reporte por bot sin monto inesperado: %', v_res;
  end if;
  if (select declared_amount_ves from public.purchase_payment_reports where id = v_rep1) is not null then
    raise exception 'El monto declarado debía quedar nulo cuando el médico no lo dice';
  end if;

  -- Preview de pago por admin
  v_res := public.admin_purchase_payment_preview(v_req2, v_today);
  if (v_res->>'expected_ves')::numeric <= 0 then
    raise exception 'admin_purchase_payment_preview inválido: %', v_res;
  end if;

  -- Reporte por admin con misma referencia y banco → debe caer en 'in_review' (referencia repetida)
  v_res := public.admin_purchase_register_payment(
    p_request_id => v_req2,
    p_method => 'pago_movil',
    p_bank => 'banesco',
    p_reference => 'REF99001122',
    p_paid_on => v_today,
    p_amount_ves => (v_res->>'expected_ves')::numeric,
    p_receipt_path => 'compras/req2/dup.jpg',
    p_payer_phone => '04141112233',
    p_note => 'Registrado por op1'
  );
  v_rep_dup := (v_res->>'report_id')::uuid;
  if v_res->>'status' <> 'in_review' then
    raise exception 'Referencia duplicada debía entrar en in_review: %', v_res;
  end if;

  -- Marcar pago duplicado: sin motivo >= 3 chars falla; con motivo cierra sin avisar y devuelve a esperando_pago
  begin
    perform public.admin_purchase_mark_payment_duplicate(v_rep_dup, 'ab');
    raise exception 'Motivo corto en duplicado debía fallar';
  exception when sqlstate '22023' then null;
  end;

  select count(*) into v_out_before from public.outbound_messages;
  v_res := public.admin_purchase_mark_payment_duplicate(v_rep_dup, 'Misma referencia que la solicitud anterior');
  select count(*) into v_out_after from public.outbound_messages;
  if v_res->>'status' <> 'duplicate'
     or v_res->>'request_status' <> 'esperando_pago'
     or v_out_after <> v_out_before then
    raise exception 'Marcar duplicado debía cerrar sin avisar y devolver solicitud a esperando_pago: %', v_res;
  end if;

  -- Flag en revisión sobre v_rep1 + consulta de cola de pagos
  v_res := public.admin_purchase_flag_payment(v_rep1, 'Verificar titularidad en extracto');
  if v_res->>'status' <> 'in_review' then
    raise exception 'admin_purchase_flag_payment debía poner in_review: %', v_res;
  end if;
  if jsonb_array_length(public.admin_purchase_payment_queue(array['reported', 'in_review'])) < 1 then
    raise exception 'admin_purchase_payment_queue debía devolver al menos v_rep1';
  end if;

  -- ── 5. Regla four-eyes (operador vs otro operador vs super_admin) ────────
  -- v_op1 registra pago sobre v_req2
  v_res := public.admin_purchase_register_payment(
    p_request_id => v_req2,
    p_method => 'transferencia',
    p_bank => 'Mercantil',
    p_reference => 'TRF44556677',
    p_paid_on => v_today,
    p_amount_ves => (public.admin_purchase_payment_preview(v_req2, v_today)->>'expected_ves')::numeric
  );
  v_rep2 := (v_res->>'report_id')::uuid;

  -- v_op1 NO puede aprobar su propio pago con four_eyes = 1
  begin
    perform public.admin_purchase_reconcile_payment(v_rep2, true, 'Intento propio');
    raise exception 'Four-eyes debía impedir que op1 apruebe su propio pago';
  exception when sqlstate '42501' then null;
  end;

  -- v_op2 SÍ puede aprobar el pago registrado por v_op1
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op2::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_res := public.admin_purchase_reconcile_payment(v_rep2, true, 'Verificado por op2');
  if v_res->>'report_status' <> 'reconciled' or v_res->>'request_status' <> 'pagado' then
    raise exception 'op2 debía poder aprobar el pago de op1: %', v_res;
  end if;

  -- super_admin SÍ puede aprobar incluso un pago que él mismo registró
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  -- Rechazamos v_rep1 y registramos como super_admin para probar autoaprobación de super_admin
  perform public.admin_purchase_reconcile_payment(v_rep1, false, 'Monto no coincide en banco');
  if (select status from public.purchase_requests where id = v_req1) <> 'esperando_pago' then
    raise exception 'Al rechazar v_rep1, v_req1 debía volver a esperando_pago';
  end if;
  v_rep1 := (public.admin_purchase_register_payment(
    v_req1, 'pago_movil', 'BNC', 'SUPER998877', v_today, 6600.00
  )->>'report_id')::uuid;
  v_res := public.admin_purchase_reconcile_payment(v_rep1, true, 'Super admin aprueba');
  if v_res->>'request_status' <> 'pagado' then
    raise exception 'super_admin debía poder aprobar su propio registro: %', v_res;
  end if;

  -- ── 6. Simulador aislado: JAMÁS toca outbound_messages ───────────────────
  perform public.admin_purchase_sim_append(v_sim_phone, 'in', 'text', 'Quiero comprar un oxímetro');
  v_res := public.admin_purchase_sim_create(
    p_merchant_id => v_merchant,
    p_phone => v_sim_phone,
    p_asin => 'B00OXIM001',
    p_product_title => 'Oxímetro de pulso profesional',
    p_quantity => 1,
    p_weight_lb => 0.8,
    p_shipping_method => 'aereo',
    p_unit_price_usd => 60.00
  );
  v_sim_req := (v_res->>'request_id')::uuid;

  select count(*) into v_out_before from public.outbound_messages;

  v_rep_sim1 := (public.admin_purchase_sim_report_payment(
    v_sim_req, 'pago_movil', 'Banesco', 'SIMREF1001', '04128887766', null, 'compras/sim/cap1.jpg', null
  )->>'report_id')::uuid;

  -- Rechazo sin motivo debe fallar
  begin
    perform public.admin_purchase_reconcile_payment(v_rep_sim1, false, '   ');
    raise exception 'Rechazar pago sin motivo debía fallar';
  exception when sqlstate '22023' then null;
  end;

  -- Rechazo con motivo: vuelve a esperando_pago y avisa en purchase_simulator_messages
  v_res := public.admin_purchase_reconcile_payment(v_rep_sim1, false, 'Referencia ilegible');
  if v_res->>'request_status' <> 'esperando_pago' then
    raise exception 'Rechazo en simulador debía devolver a esperando_pago: %', v_res;
  end if;

  -- Segundo reporte y aprobación en simulador
  v_rep_sim2 := (public.admin_purchase_sim_report_payment(
    v_sim_req, 'pago_movil', 'Banesco', 'SIMREF1002', '04128887766', null, 'compras/sim/cap2.jpg', null
  )->>'report_id')::uuid;
  v_res := public.admin_purchase_reconcile_payment(v_rep_sim2, true, 'Aprobado simulador');
  if v_res->>'request_status' <> 'pagado' then
    raise exception 'Aprobación en simulador debía pasar a pagado: %', v_res;
  end if;

  select count(*) into v_out_after from public.outbound_messages;
  if v_out_after <> v_out_before then
    raise exception 'El simulador NUNCA debe insertar en outbound_messages (antes %, después %)', v_out_before, v_out_after;
  end if;

  select count(*) into v_sim_count
  from public.purchase_simulator_messages
  where phone_e164 = v_sim_phone and direction = 'out';
  if v_sim_count < 2 then
    raise exception 'El simulador debía tener al menos 2 notificaciones salientes, hay %', v_sim_count;
  end if;

  -- ── 7. Avance logístico completo hasta entregado + append-only ───────────
  begin
    perform public.admin_purchase_advance_status(v_sim_req, 'entregado');
    raise exception 'Saltar de pagado a entregado debía fallar';
  exception when sqlstate '22023' then null;
  end;

  perform public.admin_purchase_advance_status(v_sim_req, 'comprado_amazon', '114-1234567-8901234', null, 'Comprado Prime');
  perform public.admin_purchase_advance_status(v_sim_req, 'en_almacen_usa', null, '1Z999AA10123456784', 'Recibido en Miami');
  perform public.admin_purchase_advance_status(v_sim_req, 'en_transito', null, null, 'Salió vuelo aéreo');
  perform public.admin_purchase_advance_status(v_sim_req, 'en_aduana');
  perform public.admin_purchase_advance_status(v_sim_req, 'listo_entrega');
  perform public.admin_purchase_advance_status(v_sim_req, 'entregado', null, null, 'Recibido por el médico');

  if (select status from public.purchase_requests where id = v_sim_req) <> 'entregado'
     or (select purchased_at from public.purchase_requests where id = v_sim_req) is null
     or (select delivered_at from public.purchase_requests where id = v_sim_req) is null then
    raise exception 'La solicitud debía quedar entregada con timestamps';
  end if;

  -- Desde entregado no se puede cancelar ni avanzar
  begin
    perform public.admin_purchase_advance_status(v_sim_req, 'cancelado', null, null, 'Tarde');
    raise exception 'Cancelar una solicitud ya entregada debía fallar';
  exception when sqlstate '22023' then null;
  end;

  -- El simulador siguió sin tocar outbound_messages en todo el avance logístico
  select count(*) into v_out_after from public.outbound_messages;
  if v_out_after <> v_out_before then
    raise exception 'El avance logístico de una solicitud simulador tocó outbound_messages';
  end if;

  -- Consultas de panel y simulador
  v_detail := public.admin_purchase_detail(v_sim_req);
  if (v_detail->'request'->>'status') <> 'entregado'
     or jsonb_array_length(v_detail->'events') < 8 then
    raise exception 'admin_purchase_detail incompleto: %', v_detail;
  end if;
  if jsonb_array_length(public.admin_purchase_list(array['entregado'], 'simulador', 'Oxímetro', 10)) < 1 then
    raise exception 'admin_purchase_list no encontró la solicitud entregada';
  end if;
  v_counts := public.admin_purchase_counts();
  -- Los conteos de siempre son de solicitudes REALES; el simulador va aparte.
  if (v_counts->'simulador'->>'entregado')::integer < 1
     or (v_counts->>'simulador_count')::integer < 1
     or (v_counts->>'simulador_count')::integer <> (v_counts->'simulador'->>'total')::integer
     or (v_counts->>'whatsapp_count')::integer <> (v_counts->>'total')::integer then
    raise exception 'admin_purchase_counts incorrecto: %', v_counts;
  end if;
  if exists (
    select 1 from public.purchase_requests where channel = 'simulador' and status = 'entregado'
  ) and (v_counts->>'entregado')::integer
        <> (select count(*)::integer from public.purchase_requests where channel = 'whatsapp' and status = 'entregado') then
    raise exception 'Los conteos reales no deben mezclar el simulador: %', v_counts;
  end if;
  if jsonb_array_length(public.admin_purchase_sim_merchants()) < 1
     or jsonb_array_length(public.admin_purchase_sim_messages(v_sim_phone)) < 8
     or jsonb_array_length(public.admin_purchase_sim_requests(v_sim_phone)) <> 1 then
    raise exception 'RPCs de lectura del simulador fallaron';
  end if;
  perform public.admin_purchase_sim_reset(v_sim_phone);
  if jsonb_array_length(public.admin_purchase_sim_messages(v_sim_phone)) <> 0 then
    raise exception 'admin_purchase_sim_reset debía limpiar el historial del simulador';
  end if;

  -- purchase_request_events es append-only
  begin
    update public.purchase_request_events set title = 'Editado' where request_id = v_sim_req;
    raise exception 'UPDATE en purchase_request_events debía estar bloqueado';
  exception when sqlstate '42501' then null;
  end;
  begin
    delete from public.purchase_request_events where request_id = v_sim_req;
    raise exception 'DELETE en purchase_request_events debía estar bloqueado';
  exception when sqlstate '42501' then null;
  end;

  -- ── 8. WhatsApp Cloud API: list y retrocompatibilidad ───────────────────
  -- Lista interactiva
  insert into public.outbound_messages (
    channel, template_key, recipient_staff_id, recipient,
    subject, rendered_text, status, next_attempt_at, wa_template
  ) values (
    'whatsapp', 'bot_respuesta', v_doc, v_phone,
    'Helios', 'Selecciona una variante:', 'pendiente', now(),
    jsonb_build_object(
      'kind', 'list',
      'button', 'Ver colores',
      'sections', jsonb_build_array(
        jsonb_build_object('title', 'Colores', 'rows', jsonb_build_array(
          jsonb_build_object('id', 'var_negro', 'title', 'Negro')
        ))
      )
    )
  )
  returning * into v_msg_row;

  v_payload := public.helios_whatsapp_payload(v_msg_row);
  if v_payload->>'type' <> 'interactive'
     or v_payload->'interactive'->>'type' <> 'list'
     or v_payload->'interactive'->'action'->>'button' <> 'Ver colores'
     or jsonb_array_length(v_payload->'interactive'->'action'->'sections') <> 1 then
    raise exception 'Payload de list incorrecto: %', v_payload;
  end if;

  -- Lista por la RPC de encolado: forma exacta de la Cloud API
  begin
    perform public.helios_whatsapp_list(v_phone, 'Tus compras', 'Ver compras',
      jsonb_build_array(jsonb_build_object('title', 'Compras', 'rows', jsonb_build_array(
        jsonb_build_object('id', 'x', 'title', 'Un título de fila demasiado largo', 'description', 'd')))), v_doc);
    raise exception 'Lista con título de fila > 24 debía fallar';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.helios_whatsapp_list('+584140009988', 'Tus compras', 'Ver compras',
      jsonb_build_array(jsonb_build_object('title', 'Compras', 'rows', jsonb_build_array(
        jsonb_build_object('id', 'x', 'title', 'Fila', 'description', 'd')))), v_doc);
    raise exception 'Lista con ventana cerrada debía fallar';
  exception when sqlstate '22023' then null;
  end;
  v_msg_id := public.helios_whatsapp_list(v_phone, 'Tus compras en Amazon', 'Ver compras',
    jsonb_build_array(jsonb_build_object('title', 'Compras', 'rows', jsonb_build_array(
      jsonb_build_object('id', 'compra:det:1', 'title', '#C-1', 'description', 'En camino'),
      jsonb_build_object('id', 'compra:det:2', 'title', '#C-2', 'description', 'Pago reportado')))), v_doc);
  select * into v_msg_row from public.outbound_messages where id = v_msg_id;
  v_payload := public.helios_whatsapp_payload(v_msg_row);
  if v_payload->>'type' <> 'interactive'
     or v_payload->'interactive'->>'type' <> 'list'
     or v_payload->'interactive'->'body'->>'text' <> 'Tus compras en Amazon'
     or v_payload->'interactive'->'action'->>'button' <> 'Ver compras'
     or v_payload->'interactive'->'action'->'sections'->0->>'title' <> 'Compras'
     or v_payload->'interactive'->'action'->'sections'->0->'rows'->1->>'id' <> 'compra:det:2'
     or v_payload->'interactive'->'action'->'sections'->0->'rows'->1->>'description' <> 'Pago reportado' then
    raise exception 'Payload de la lista encolada incorrecto: %', v_payload;
  end if;

  -- Un aviso al personal sin paciente que pasó a la cola manual aparece en «Avisos de hoy»
  insert into public.outbound_messages (
    channel, template_key, profile_id, recipient_staff_id, recipient,
    subject, rendered_text, status, next_attempt_at, wa_template
  ) values (
    'whatsapp_manual', 'bot_respuesta', null, v_doc, '+584140009977',
    'Helios', 'Aviso de compra fuera de ventana', 'pendiente', null,
    jsonb_build_object('name', null, 'language', 'es', 'params', '[]'::jsonb, 'buttons', '[]'::jsonb)
  )
  returning id into v_msg_id;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  if not exists (
    select 1 from public.admin_outbound_queue(null, 'whatsapp_manual') q
     where q.id = v_msg_id and q.profile_id is null
       and q.phone_e164 = '+584140009977' and q.patient_name is not null
       and q.whatsapp_url is not null
  ) then
    raise exception 'La cola manual debía listar el aviso al personal (sin profile_id)';
  end if;

  -- Retrocompatibilidad: texto simple con ventana abierta
  v_msg_id := public.helios_whatsapp_text(v_phone, 'Hola doctor', v_doc, '[]'::jsonb);
  select * into v_msg_row from public.outbound_messages where id = v_msg_id;
  v_payload := public.helios_whatsapp_payload(v_msg_row);
  if v_payload->>'type' <> 'text' then
    raise exception 'Retrocompatibilidad de texto rota: %', v_payload;
  end if;

  -- ── 9. Edición de purchase_settings (solo super_admin + audit.log) ───────
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op1::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  begin
    perform public.admin_purchase_settings_set(8.00, 12.00, 7.00, 18.00, 30.00, 40.00, 2.000, 48, 'rainforest', true);
    raise exception 'Un operador no debía poder editar purchase_settings';
  exception when sqlstate '42501' then null;
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_res := public.admin_purchase_settings_set(8.00, 12.00, 7.00, 18.00, 30.00, 40.00, 2.000, 48, 'rainforest', true);
  if (v_res->>'tax_usa_pct')::numeric <> 8.00
     or (v_res->>'service_fee_pct')::numeric <> 12.00
     or (v_res->>'catalog_provider') <> 'rainforest' then
    raise exception 'admin_purchase_settings_set no guardó los valores: %', v_res;
  end if;

  if not exists (
    select 1 from audit.admin_actions
    where actor = v_super and action = 'purchase_settings.updated'
  ) then
    raise exception 'Falta el registro en audit.admin_actions para purchase_settings.updated';
  end if;

  -- Confirmar que el nuevo cálculo refleja la configuración actualizada
  v_calc := public.helios_purchase_calculate(100.00, 1, 'aereo', 1.0, null, null);
  if (v_calc->>'tax_usa_usd')::numeric <> 8.00
     or (v_calc->>'service_fee_usd')::numeric <> 12.00
     or (v_calc->>'shipping_usd')::numeric <> 18.00
     or (v_calc->>'total_usd')::numeric <> 138.00 then
    raise exception 'El cálculo no reflejó los nuevos purchase_settings: %', v_calc;
  end if;
end $$;

-- ============================================================================
-- 10. Correcciones de la revisión (20261124180100). Nunca se llama a
--     helios_dispatch_* ni a funciones http: solo se mira lo que queda en cola.
-- ============================================================================
do $$
declare
  v_super    uuid;
  v_op       uuid := gen_random_uuid();
  v_doc      uuid := gen_random_uuid();
  v_doc2     uuid := gen_random_uuid();
  v_pac      uuid := gen_random_uuid();
  v_staff    uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_phone    text := '+584149990000';
  v_phone2   text := '+584149990001';
  v_today    date := public.helios_business_date(now());
  v_res      jsonb;
  v_res2     jsonb;
  v_a        uuid;
  v_b        uuid;
  v_c        uuid;
  v_d        uuid;
  v_s        uuid;
  v_rep      uuid;
  v_n        integer;
  v_msg      text;
  v_keys     text[];
  v_counts   jsonb;
  v_total0   integer;
  v_ca       uuid;
  v_a1       uuid;
  v_q        numeric;
begin
  v_super := pg_temp.prueba_admin();

  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'amz2-' || u || '@prueba.helios.test', now(), now(), now()
  from unnest(array[v_op, v_doc, v_doc2, v_staff]) u;
  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_op, 'operador', 'Operador Tres', true);
  insert into public.merchants (name) values ('Clínica Amazon Correcciones') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_doc, v_merchant, v_branch, 'gerente'),
    (v_doc2, v_merchant, v_branch, 'cajero'),
    (v_staff, v_merchant, v_branch, 'cajero');
  insert into public.staff_whatsapp_numbers (phone_e164, user_id, merchant_id, created_by) values
    (v_phone, v_doc, v_merchant, v_super),
    (v_phone2, v_doc2, v_merchant, v_super);
  insert into public.whatsapp_contacts (phone_e164, last_inbound_at) values (v_phone, now()), (v_phone2, now())
  on conflict (phone_e164) do update set last_inbound_at = excluded.last_inbound_at;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- ── 10a. Habilitación y piloto ───────────────────────────────────────────
  update public.purchase_settings set is_enabled = false, catalog_provider = 'mock', pilot_phones = '{}' where id;
  v_res := public.bot_compra_habilitada(v_phone);
  if (v_res->>'habilitada')::boolean or (v_res->>'piloto')::boolean or v_res->>'proveedor' <> 'mock' then
    raise exception 'Apagado y sin piloto no debía estar habilitada: %', v_res;
  end if;
  begin
    perform public.bot_compra_crear(p_phone => v_phone, p_asin => 'B00PILOTO1', p_product_title => 'X', p_unit_price_usd => 10);
    raise exception 'Con el servicio apagado el bot no debía crear solicitudes';
  exception when sqlstate '22023' then null;
  end;
  begin
    update public.purchase_settings set is_enabled = true where id;
    raise exception 'El catálogo mock no debía poder abrirse a todos';
  exception when check_violation then null;
  end;
  begin
    perform public.admin_purchase_settings_set(8, 12, 7, 18, 30, 40, 2, 48, 'mock', true);
    raise exception 'admin_purchase_settings_set no debía abrir el mock';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.admin_purchase_settings_set(8, 12, 7, 18, 30, 40, 2, 48, 'oxylabs', false);
    raise exception 'oxylabs ya no es un proveedor válido';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.admin_purchase_settings_set(8, 12, 7, 18, 30, 40, 2, 48, 'mock', false, array['0414123']);
    raise exception 'Un teléfono del piloto sin formato E.164 debía fallar';
  exception when sqlstate '22023' then null;
  end;
  v_res := public.admin_purchase_settings_set(8, 12, 7, 18, 30, 40, 2, 48, 'mock', false, array[v_phone]);
  if jsonb_typeof(v_res->'pilot_phones') <> 'array' or v_res->'pilot_phones'->>0 <> v_phone then
    raise exception 'pilot_phones no se guardó: %', v_res;
  end if;
  v_res := public.bot_compra_habilitada(v_phone);
  if not (v_res->>'habilitada')::boolean or not (v_res->>'piloto')::boolean then
    raise exception 'El número del piloto debía estar habilitado: %', v_res;
  end if;
  if (public.bot_compra_habilitada(v_phone2)->>'habilitada')::boolean then
    raise exception 'Un número fuera del piloto no debía estar habilitado';
  end if;
  -- Vuelve a abrir (rainforest) para el resto de las pruebas.
  perform public.admin_purchase_settings_set(8, 12, 7, 18, 30, 40, 2, 48, 'rainforest', true, array[]::text[]);

  -- ── 10b. Idempotencia de crear y total_cambio ────────────────────────────
  v_res := public.bot_compra_crear(p_phone => v_phone, p_asin => 'B00IDEM001', p_product_title => 'Idempotente',
    p_weight_lb => 1, p_unit_price_usd => 100, p_idempotency_key => 'wamid.crear.1', p_session_total_usd => 1.00);
  v_res2 := public.bot_compra_crear(p_phone => v_phone, p_asin => 'B00IDEM001', p_product_title => 'Idempotente',
    p_weight_lb => 1, p_unit_price_usd => 100, p_idempotency_key => 'wamid.crear.1', p_session_total_usd => (v_res->>'total_usd')::numeric);
  v_a := (v_res->>'request_id')::uuid;
  if v_res2->>'request_id' <> v_res->>'request_id'
     or (select count(*) from public.purchase_requests where idempotency_key = 'wamid.crear.1') <> 1 then
    raise exception 'bot_compra_crear no es idempotente: % / %', v_res, v_res2;
  end if;
  if not (v_res->>'total_cambio')::boolean or (v_res2->>'total_cambio')::boolean then
    raise exception 'total_cambio incorrecto: % / %', v_res->>'total_cambio', v_res2->>'total_cambio';
  end if;

  -- ── 10c. Idempotencia de reportar pago; ventana de monto ─────────────────
  v_res := public.bot_compra_reportar_pago(v_phone, v_a, 'pago_movil', 'Banesco', '00778899', null, null, null, 'wamid.pago.1');
  v_res2 := public.bot_compra_reportar_pago(v_phone, v_a, 'pago_movil', 'Banesco', '00778899', null, null, null, 'wamid.pago.1');
  if not (v_res2->>'ya_registrado')::boolean or v_res2->>'report_id' <> v_res->>'report_id'
     or (select count(*) from public.purchase_payment_reports where request_id = v_a) <> 1 then
    raise exception 'bot_compra_reportar_pago no es idempotente: % / %', v_res, v_res2;
  end if;
  v_rep := (v_res->>'report_id')::uuid;

  -- ── 10d. C2: cancelar con un reporte abierto lo cierra; no resucita ──────
  v_res := public.admin_purchase_advance_status(v_a, 'cancelado', null, null, 'Cliente desistió');
  if v_res->>'status' <> 'cancelado' or (v_res->>'closed_reports')::integer <> 1
     or (select status from public.purchase_payment_reports where id = v_rep) <> 'rejected'
     or (select rejection_note from public.purchase_payment_reports where id = v_rep) is null then
    raise exception 'Cancelar debía cerrar el reporte abierto: %', v_res;
  end if;
  begin
    perform public.admin_purchase_reconcile_payment(v_rep, true, 'Intento resucitar');
    raise exception 'Aprobar el pago de una solicitud cancelada debía fallar';
  exception when sqlstate '22023' then null;
  end;
  if (select status from public.purchase_requests where id = v_a) <> 'cancelado' then
    raise exception 'La solicitud cancelada no debía resucitar';
  end if;

  -- Aprobar en un estado equivocado (reporte abierto pero la solicitud ya no espera confirmación)
  v_res := public.bot_compra_crear(p_phone => v_phone, p_asin => 'B00ESTADO01', p_product_title => 'Estado', p_weight_lb => 1, p_unit_price_usd => 50);
  v_b := (v_res->>'request_id')::uuid;
  v_rep := (public.bot_compra_reportar_pago(v_phone, v_b, 'transferencia', 'Mercantil', 'EST1122334')->>'report_id')::uuid;
  update public.purchase_requests set status = 'esperando_pago' where id = v_b;
  begin
    perform public.admin_purchase_reconcile_payment(v_rep, true, 'Estado equivocado');
    raise exception 'Aprobar con la solicitud fuera de pago_reportado debía fallar';
  exception when sqlstate '22023' then null;
  end;
  update public.purchase_requests set status = 'pago_reportado' where id = v_b;

  -- ── 10e. TTL de la cotización ────────────────────────────────────────────
  v_res := public.bot_compra_crear(p_phone => v_phone, p_asin => 'B00TTL00001', p_product_title => 'Vencida', p_weight_lb => 1, p_unit_price_usd => 40);
  v_c := (v_res->>'request_id')::uuid;
  update public.purchase_requests set quote_expires_at = now() - interval '1 minute' where id = v_c;
  begin
    perform public.bot_compra_reportar_pago(v_phone, v_c, 'pago_movil', 'Banesco', 'TTL55667788');
    raise exception 'Reportar pago sobre una cotización vencida debía fallar';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like 'cotizacion_vencida%' then
      raise exception 'El error debía empezar por cotizacion_vencida: %', v_msg;
    end if;
  end;
  v_res := public.bot_compra_pendiente_de_pago(v_phone);
  if (v_res->>'request_id')::uuid <> v_c or not (v_res->>'vencida')::boolean
     or v_res->>'status' <> 'esperando_pago' or (v_res->>'payment_block') is not null then
    raise exception 'pendiente_de_pago debía marcar la vencida y no dar bloque: %', v_res;
  end if;
  -- Recotizar: renueva la vigencia y conserva el total anterior
  v_res := public.bot_compra_recotizar(v_phone, v_c);
  if (v_res->>'quote_expires_at')::timestamptz <= now() or (v_res->>'total_anterior_usd') is null
     or (v_res->>'payment_block') is null then
    raise exception 'bot_compra_recotizar inesperado: %', v_res;
  end if;
  -- El administrador SÍ puede registrar un pago sobre una cotización vencida, y queda marcado
  update public.purchase_requests set quote_expires_at = now() - interval '1 minute' where id = v_c;
  v_res := public.admin_purchase_register_payment(v_c, 'pago_movil', 'Banesco', 'TTL55667788', v_today, 1000.00);
  if not (v_res->>'cotizacion_vencida')::boolean then
    raise exception 'El pago manual sobre cotización vencida debía marcarse: %', v_res;
  end if;

  -- ── 10f. Referencias: normalizadas y cruzadas con los pagos de pacientes ─
  insert into public.profiles (id, phone_e164, first_name, full_name, email)
  values (v_pac, '+584140009799', 'Paciente', 'Paciente Cruce', 'cruce@prueba.helios.test');
  update public.levels set monthly_limit_usd = 500 where level = 1;
  insert into public.business_parameters (key, value, effective_from, note)
  values ('payment_four_eyes', 0, v_today, 'prueba')
  on conflict (key, effective_from) do update set value = excluded.value;
  v_ca := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 28.00, 'amz-cruce')->>'charge_id')::uuid;
  select id into v_a1 from public.installments where charge_id = v_ca and sequence = 1;
  v_q := public.helios_installments_ves(v_pac, array[v_a1], v_today);
  perform public.admin_register_payment(v_pac, array[v_a1], 'pago_movil', 'Banco de Venezuela', '00555-123456',
                                        v_today, v_q, null, null);
  if public.helios_purchase_ref_norm('00555-123456') is distinct from '555123456'
     or public.helios_purchase_ref_norm(' ab 0012 ') is distinct from 'AB0012' then
    raise exception 'La normalización de la referencia falló';
  end if;

  v_res := public.bot_compra_crear(p_phone => v_phone, p_asin => 'B00CRUCE001', p_product_title => 'Cruce', p_weight_lb => 1, p_unit_price_usd => 30);
  v_d := (v_res->>'request_id')::uuid;
  v_res := public.bot_compra_reportar_pago(v_phone, v_d, 'pago_movil', 'Banesco', '555 123456', null, null, null, 'wamid.cruce.1');
  if v_res->>'status' <> 'in_review' then
    raise exception 'La referencia de un pago de paciente debía mandar el reporte a revisión: %', v_res;
  end if;

  -- ── 10g. Quien no es admin no llama a las RPC admin_* ────────────────────
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_doc::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  begin
    perform public.admin_purchase_list();
    raise exception 'Un no-admin no debía listar compras';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.admin_purchase_reconcile_payment(v_rep, true, 'No soy admin');
    raise exception 'Un no-admin no debía conciliar pagos';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.admin_purchase_sim_autorizar();
    raise exception 'Un no-admin no debía autorizar el simulador';
  exception when sqlstate '42501' then null;
  end;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  if public.admin_purchase_sim_autorizar() <> v_super then
    raise exception 'admin_purchase_sim_autorizar debía devolver el uid del admin';
  end if;

  -- ── 10i. Cancelar por el bot ─────────────────────────────────────────────
  v_res := public.bot_compra_crear(p_phone => v_phone, p_asin => 'B00CANCEL01', p_product_title => 'Cancelable', p_weight_lb => 1, p_unit_price_usd => 20);
  v_s := (v_res->>'request_id')::uuid;
  begin
    perform public.bot_compra_cancelar(v_phone2, v_s);
    raise exception 'Otro número no debía cancelar la solicitud';
  exception when sqlstate '42501' then null;
  end;
  v_res := public.bot_compra_cancelar(v_phone, v_s);
  if v_res->>'status' <> 'cancelado' or not (v_res->>'ok')::boolean then
    raise exception 'bot_compra_cancelar inesperado: %', v_res;
  end if;
  begin
    perform public.bot_compra_cancelar(v_phone, v_s);
    raise exception 'Cancelar dos veces debía fallar';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.bot_compra_cancelar(v_phone, v_d);
    raise exception 'No se cancela una solicitud con pago reportado';
  exception when sqlstate '22023' then null;
  end;

  -- ── 10j. Proyecciones del bot sin campos internos ────────────────────────
  update public.purchase_requests set internal_notes = 'nota interna', delivery_address = 'Calle 1' where id = v_d;
  select array_agg(k order by k) into v_keys
  from jsonb_object_keys(public.bot_compra_mis_solicitudes(v_phone, 5)->0) k;
  if not (v_keys @> array['created_at', 'product_title', 'quantity', 'quote_expires_at', 'request_id',
       'request_number', 'shipping_method', 'status', 'total_usd', 'us_tracking_number', 'vencida']
     and v_keys <@ array['created_at', 'product_title', 'quantity', 'quote_expires_at', 'request_id',
       'request_number', 'shipping_method', 'status', 'total_usd', 'us_tracking_number', 'vencida']) then
    raise exception 'bot_compra_mis_solicitudes con campos de más o de menos: %', v_keys;
  end if;
  v_res := public.bot_compra_detalle(v_phone, v_d);
  if v_res::text ilike '%nota interna%' or v_res::text ilike '%Calle 1%'
     or jsonb_array_length(v_res->'eventos') > 5
     or exists (select 1 from jsonb_array_elements(v_res->'eventos') e where e->>'kind' in ('payment_flagged', 'payment_duplicate')) then
    raise exception 'bot_compra_detalle filtró datos internos: %', v_res;
  end if;

  -- ── 10k. Avisos: ventana cerrada, texto y botones del rechazo ────────────
  update public.whatsapp_contacts set last_inbound_at = now() - interval '2 days' where phone_e164 = v_phone;
  v_rep := (select id from public.purchase_payment_reports where request_id = v_d);
  perform public.admin_purchase_flag_payment(v_rep, 'Revisar el cruce');
  perform public.admin_purchase_reconcile_payment(v_rep, false, 'Referencia de otro pago');
  select count(*) into v_n from public.outbound_messages
   where recipient = v_phone and channel = 'whatsapp' and rendered_text like '%No pudimos confirmar tu pago de #C-%';
  if v_n <> 1 then
    raise exception 'Con la ventana cerrada el aviso debía encolarse (no descartarse): %', v_n;
  end if;
  update public.whatsapp_contacts set last_inbound_at = now() where phone_e164 = v_phone;

  v_rep := (public.bot_compra_reportar_pago(v_phone, v_d, 'pago_movil', 'Banesco', 'OKREF778899', null, 6600.00, null, 'wamid.ok.1')->>'report_id')::uuid;
  v_res := public.admin_purchase_reconcile_payment(v_rep, true, 'Verificado');
  if v_res->>'request_status' <> 'pagado'
     or not exists (select 1 from public.outbound_messages
                    where recipient = v_phone and rendered_text like 'Confirmamos tu pago de #C-%. Ya lo estamos comprando en Amazon%') then
    raise exception 'El aviso de pago aprobado no salió: %', v_res;
  end if;
  if exists (select 1 from public.outbound_messages where recipient = v_phone
             and (lower(rendered_text) ~ '(préstamo|prestamo|financiamiento|financiar|crédito|credito|\yfee\y)'
                  or rendered_text ~ 'Bs ')) then
    raise exception 'Un aviso al médico trae una palabra prohibida o bolívares fuera del bloque de pago';
  end if;

  -- Rechazo: botones del contrato (en el simulador, forma canónica)
  v_res := public.admin_purchase_sim_create(v_merchant, v_phone, 'B00SIMBTN01', 'Botones', p_weight_lb => 1, p_unit_price_usd => 25);
  v_s := (v_res->>'request_id')::uuid;
  perform public.admin_purchase_sim_report_payment(v_s, 'pago_movil', 'Banesco', 'SIMBTN556677');
  v_rep := (select id from public.purchase_payment_reports where request_id = v_s);
  if (select registered_by from public.purchase_payment_reports where id = v_rep) is distinct from v_super
     or (select declared_amount_ves from public.purchase_payment_reports where id = v_rep) is not null then
    raise exception 'El simulador debía registrar con actor real y sin monto inventado';
  end if;
  perform public.admin_purchase_reconcile_payment(v_rep, false, 'Captura ilegible');
  select payload into v_res from public.purchase_simulator_messages
   where phone_e164 = v_phone and kind = 'buttons' order by created_at desc, id desc limit 1;
  if jsonb_array_length(v_res->'buttons') <> 3
     or v_res->'buttons'->0->>'id' <> 'compra:reenviar:' || v_s::text
     or v_res->'buttons'->1->>'id' <> 'compra:persona'
     or v_res->'buttons'->2->>'id' <> 'compra:mis' then
    raise exception 'Botones del rechazo incorrectos: %', v_res;
  end if;

  -- Cuatro ojos con actor real en el simulador: quien lo registró (operador) no lo aprueba
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  insert into public.business_parameters (key, value, effective_from, note)
  values ('payment_four_eyes', 1, v_today, 'prueba')
  on conflict (key, effective_from) do update set value = 1;
  perform public.admin_purchase_sim_report_payment(v_s, 'pago_movil', 'Banesco', 'SIMBTN998811');
  v_rep := (select id from public.purchase_payment_reports where request_id = v_s and status = 'reported');
  begin
    perform public.admin_purchase_reconcile_payment(v_rep, true, 'Yo mismo');
    raise exception 'Cuatro ojos: el operador no debía aprobar su propio pago del simulador';
  exception when sqlstate '42501' then null;
  end;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- ── 10l. Conteos reales vs simulador ─────────────────────────────────────
  v_total0 := (public.admin_purchase_counts()->>'total')::integer;
  perform public.admin_purchase_sim_create(v_merchant, v_phone, 'B00SIMCNT01', 'Conteo', p_weight_lb => 1, p_unit_price_usd => 15);
  v_counts := public.admin_purchase_counts();
  if (v_counts->>'total')::integer <> v_total0 then
    raise exception 'Una solicitud del simulador no debe contar en los totales reales';
  end if;

  -- ── 10m. Cola con límite, detalle sin bloque en revisión aduanal, búsqueda literal
  if jsonb_array_length(public.admin_purchase_payment_queue(array['reported', 'in_review', 'reconciled', 'rejected'], 1)) <> 1 then
    raise exception 'admin_purchase_payment_queue debía respetar p_limit';
  end if;
  v_res := public.bot_compra_crear(p_phone => v_phone, p_asin => 'B00ADUANA01', p_product_title => 'Escape_Test1',
    p_weight_lb => 1, p_unit_price_usd => 90, p_restricted_flag => true, p_restricted_reason => 'Permiso');
  v_s := (v_res->>'request_id')::uuid;
  if (public.admin_purchase_detail(v_s)->>'payment_block') is not null then
    raise exception 'En revisión aduanal el detalle no debe dar bloque de pago';
  end if;
  perform public.bot_compra_crear(p_phone => v_phone, p_asin => 'B00ADUANA02', p_product_title => 'EscapeXTest1', p_weight_lb => 1, p_unit_price_usd => 90);
  if jsonb_array_length(public.admin_purchase_list(null, null, 'escape_test1', 50)) <> 1 then
    raise exception 'El guion bajo de la búsqueda debía ser literal, no comodín';
  end if;

  -- ── 10n. Restricciones: FK restrict e identidad siempre ──────────────────
  begin
    delete from public.purchase_requests where id = v_d;
    raise exception 'Borrar una solicitud con pagos debía bloquearse';
  exception when restrict_violation or foreign_key_violation then null;
  end;
  begin
    update public.purchase_requests set request_number = 1 where id = v_d;
    raise exception 'request_number es generated always';
  exception when sqlstate '428C9' then null;
  end;

  -- ── 10o. Sesión y mensajes del simulador; reinicio ───────────────────────
  if not (public.sim_compra_sesion(v_phone)->>'nueva')::boolean then
    raise exception 'Sin sesión previa debía ser nueva';
  end if;
  perform public.sim_compra_sesion_guardar(v_phone, 'buscando', '{"q":"oxímetro"}'::jsonb);
  v_res := public.sim_compra_sesion(v_phone);
  if (v_res->>'nueva')::boolean or v_res->>'state' <> 'buscando' or v_res->'data'->>'q' <> 'oxímetro' then
    raise exception 'La sesión del simulador no se guardó: %', v_res;
  end if;
  update public.purchase_simulator_sessions set updated_at = now() - interval '2 days' where phone_e164 = v_phone;
  if not (public.sim_compra_sesion(v_phone)->>'nueva')::boolean then
    raise exception 'La sesión vencida debía empezar de nuevo';
  end if;
  perform public.sim_compra_mensaje(v_phone, 'out', 'buttons', 'Elige', '{"buttons":[{"id":"a","title":"A"}]}'::jsonb);
  begin
    perform public.sim_compra_mensaje(v_phone, 'out', 'carousel', 'Ya no existe', '{"cards":[{},{}]}'::jsonb);
    raise exception 'El simulador ya no acepta carruseles';
  exception when sqlstate '22023' then null;
  end;
  perform public.sim_compra_sesion_guardar(v_phone, 'x', '{}'::jsonb);
  perform public.sim_compra_reiniciar(v_phone, v_super);
  if exists (select 1 from public.purchase_simulator_messages where phone_e164 = v_phone)
     or exists (select 1 from public.purchase_simulator_sessions where phone_e164 = v_phone) then
    raise exception 'sim_compra_reiniciar debía borrar mensajes y sesión';
  end if;
  if not exists (select 1 from audit.admin_actions where actor = v_super and action = 'purchase.sim_reset' and detail ->> 'via' = 'edge_function') then
    raise exception 'sim_compra_reiniciar debía auditarse con el actor';
  end if;
  perform public.admin_purchase_sim_reset(v_phone);
  if not exists (select 1 from audit.admin_actions where actor = v_super and action = 'purchase.sim_reset') then
    raise exception 'admin_purchase_sim_reset debía auditarse';
  end if;

  -- ── 10p. Pedir hablar con una persona ────────────────────────────────────
  delete from public.internal_alert_recipients where topic = 'compras_persona';
  insert into public.internal_alert_recipients (topic, email) values ('compras_persona', 'equipo@prueba.helios.test');
  perform public.bot_compra_pedir_persona(v_phone, v_d, 'Necesito ayuda con mi pago');
  if not exists (select 1 from public.purchase_request_events where request_id = v_d and kind = 'human_requested')
     or not exists (select 1 from public.outbound_messages
                    where channel = 'email' and template_key = 'alerta_compras_persona'
                      and recipient = 'equipo@prueba.helios.test') then
    raise exception 'bot_compra_pedir_persona debía dejar evento y aviso por correo interno';
  end if;

  -- ── 10q. El simulador y WhatsApp no comparten solicitudes de un mismo teléfono ──
  declare
    v_sim uuid;
    v_chan_res jsonb;
  begin
    v_chan_res := public.bot_compra_crear(
      p_phone => v_phone, p_asin => 'B00CANAL001', p_product_title => 'Solicitud del simulador',
      p_weight_lb => 1, p_unit_price_usd => 20, p_channel => 'simulador'
    );
    v_sim := (v_chan_res->>'request_id')::uuid;

    -- Listas y recuperación del pago: cada canal ve lo suyo.
    if exists (select 1 from jsonb_array_elements(public.bot_compra_mis_solicitudes(v_phone, 30)) e where (e->>'request_id')::uuid = v_sim) then
      raise exception 'WhatsApp no debía ver una solicitud del simulador en «Mis compras»';
    end if;
    if not exists (select 1 from jsonb_array_elements(public.bot_compra_mis_solicitudes(v_phone, 30, 'simulador')) e where (e->>'request_id')::uuid = v_sim) then
      raise exception 'El simulador debía ver su solicitud en «Mis compras»';
    end if;
    if exists (select 1 from jsonb_array_elements(public.bot_compra_mis_solicitudes(v_phone, 30, 'simulador')) e where (e->>'request_id')::uuid = v_d) then
      raise exception 'El simulador no debía ver una solicitud real';
    end if;
    if (public.bot_compra_pendiente_de_pago(v_phone)->>'request_id')::uuid = v_sim then
      raise exception 'La recuperación del pago de WhatsApp no debía devolver la solicitud del simulador';
    end if;
    if (public.bot_compra_pendiente_de_pago(v_phone, 'simulador')->>'request_id')::uuid is distinct from v_sim then
      raise exception 'La recuperación del pago del simulador debía devolver su solicitud';
    end if;

    -- Una solicitud de otro canal: 42501 en las cuatro RPC de una sola solicitud.
    begin
      perform public.bot_compra_detalle(v_phone, v_sim);
      raise exception 'WhatsApp no debía abrir el detalle de una solicitud del simulador';
    exception when sqlstate '42501' then null;
    end;
    begin
      perform public.bot_compra_cancelar(v_phone, v_sim);
      raise exception 'WhatsApp no debía cancelar una solicitud del simulador';
    exception when sqlstate '42501' then null;
    end;
    begin
      perform public.bot_compra_recotizar(v_phone, v_sim);
      raise exception 'WhatsApp no debía recotizar una solicitud del simulador';
    exception when sqlstate '42501' then null;
    end;
    begin
      perform public.bot_compra_reportar_pago(v_phone, v_sim, 'pago_movil', 'Banesco', 'CANAL778899');
      raise exception 'WhatsApp no debía reportar un pago sobre una solicitud del simulador';
    exception when sqlstate '42501' then null;
    end;
    -- ...y al revés: el simulador no toca una solicitud real.
    begin
      perform public.bot_compra_cancelar(v_phone, v_d, 'simulador');
      raise exception 'El simulador no debía cancelar una solicitud real';
    exception when sqlstate '42501' then null;
    end;
    begin
      perform public.bot_compra_detalle(v_phone, v_d, 'simulador');
      raise exception 'El simulador no debía abrir el detalle de una solicitud real';
    exception when sqlstate '42501' then null;
    end;
    begin
      perform public.bot_compra_reportar_pago(v_phone, v_d, 'pago_movil', 'Banesco', 'CANAL112233', null, null, null, null, null, 'simulador');
      raise exception 'El simulador no debía reportar un pago sobre una solicitud real';
    exception when sqlstate '42501' then null;
    end;
    begin
      perform public.bot_compra_mis_solicitudes(v_phone, 5, 'otro');
      raise exception 'Un canal desconocido debía rechazarse';
    exception when sqlstate '22023' then null;
    end;

    -- En su propio canal sí funciona.
    if (public.bot_compra_detalle(v_phone, v_sim, 'simulador')->>'request_id')::uuid <> v_sim then
      raise exception 'El simulador debía abrir su propia solicitud';
    end if;
    v_chan_res := public.bot_compra_cancelar(v_phone, v_sim, 'simulador');
    if v_chan_res->>'status' <> 'cancelado' then
      raise exception 'El simulador debía poder cancelar su solicitud: %', v_chan_res;
    end if;
  end;
end $$;

-- ============================================================================
-- 11. Limpieza (20261125120000): «la más reciente» determinista, piloto
--     normalizado y sin carrusel. Tampoco llama a helios_dispatch_* ni http.
-- ============================================================================
do $$
declare
  v_super    uuid := pg_temp.prueba_admin();
  v_doc      uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_phone    text := '+584147770001';
  v_phone2   text := '+584147770002';
  v_res      jsonb;
  v_r1       uuid;
  v_r2       uuid;
  v_n1       integer;
  v_n2       integer;
  v_msg      text;
  v_row      public.outbound_messages%rowtype;
  v_payload  jsonb;
begin
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  values (v_doc, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'amz3-' || v_doc || '@prueba.helios.test', now(), now(), now());
  insert into public.merchants (name) values ('Clínica Amazon Limpieza') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values (v_doc, v_merchant, v_branch, 'gerente');
  insert into public.staff_whatsapp_numbers (phone_e164, user_id, merchant_id, created_by)
  values (v_phone, v_doc, v_merchant, v_super);
  insert into public.whatsapp_contacts (phone_e164, last_inbound_at) values (v_phone, now())
  on conflict (phone_e164) do update set last_inbound_at = excluded.last_inbound_at;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- ── 11a. Piloto: cualquier forma del mismo teléfono guarda el mismo número ──
  if public.helios_purchase_pilot_phone('+5804149783031') is distinct from '+584149783031'
     or public.helios_purchase_pilot_phone('04149783031') is distinct from '+584149783031'
     or public.helios_purchase_pilot_phone('0414-978-3031') is distinct from '+584149783031'
     or public.helios_purchase_pilot_phone('+584149783031') is distinct from '+584149783031'
     or public.helios_purchase_pilot_phone('abc') is not null then
    raise exception 'La normalización del teléfono del piloto falló';
  end if;

  v_res := public.admin_purchase_settings_set(8, 12, 7, 18, 30, 40, 2, 48, 'mock', false,
    array['+5804147770001', '04147770001', '0414-777-0001', '+584147770001']);
  if jsonb_array_length(v_res->'pilot_phones') <> 1 or v_res->'pilot_phones'->>0 <> v_phone then
    raise exception 'El piloto debía guardarse normalizado y sin duplicados: %', v_res->'pilot_phones';
  end if;
  begin
    perform public.admin_purchase_settings_set(8, 12, 7, 18, 30, 40, 2, 48, 'mock', false, array[v_phone, 'abc']);
    raise exception 'Un teléfono basura del piloto debía fallar';
  exception when sqlstate '22023' then
    get stacked diagnostics v_msg = message_text;
    if v_msg <> 'telefono_piloto_invalido: abc' then
      raise exception 'Mensaje inesperado para el teléfono inválido: %', v_msg;
    end if;
  end;
  if (select pilot_phones from public.purchase_settings where id) <> array[v_phone] then
    raise exception 'Un guardado rechazado no debía cambiar el piloto';
  end if;

  -- El bot compara con el teléfono normalizado
  if not (public.bot_compra_habilitada('0414-777-0001')->>'piloto')::boolean
     or not (public.bot_compra_habilitada(v_phone)->>'piloto')::boolean then
    raise exception 'bot_compra_habilitada debía reconocer el piloto sin importar el formato';
  end if;

  -- pilot_status: registrado y nombre
  v_res := public.admin_purchase_settings_set(8, 12, 7, 18, 30, 40, 2, 48, 'mock', false, array[v_phone, v_phone2]);
  if jsonb_array_length(v_res->'pilot_status') <> 2
     or not (v_res->'pilot_status'->0->>'registrado')::boolean
     or v_res->'pilot_status'->0->>'phone' <> v_phone
     or (v_res->'pilot_status'->0->>'nombre') is distinct from public.helios_staff_name(v_doc)
     or (v_res->'pilot_status'->1->>'registrado')::boolean
     or v_res->'pilot_status'->1->>'phone' <> v_phone2
     or (v_res->'pilot_status'->1->'nombre') <> 'null'::jsonb then
    raise exception 'pilot_status incorrecto: %', v_res->'pilot_status';
  end if;
  if public.admin_purchase_settings_get() -> 'pilot_status' <> v_res -> 'pilot_status' then
    raise exception 'admin_purchase_settings_get debía traer el mismo pilot_status';
  end if;
  -- Un número revocado ya no cuenta como registrado
  update public.staff_whatsapp_numbers
     set revoked_at = now(), revoked_by = v_super, revoke_reason = 'prueba'
   where phone_e164 = v_phone and revoked_at is null;
  if (public.admin_purchase_settings_get()->'pilot_status'->0->>'registrado')::boolean then
    raise exception 'Un número revocado no debía figurar como registrado';
  end if;
  update public.staff_whatsapp_numbers set revoked_at = null, revoked_by = null, revoke_reason = null
   where phone_e164 = v_phone;

  -- ── 11b. «La más reciente» con el mismo created_at ───────────────────────
  perform public.admin_purchase_settings_set(8, 12, 7, 18, 30, 40, 2, 48, 'rainforest', true, array[]::text[]);
  v_res := public.bot_compra_crear(p_phone => v_phone, p_asin => 'B00DETER001', p_product_title => 'Primera',
    p_weight_lb => 1, p_unit_price_usd => 10);
  v_r1 := (v_res->>'request_id')::uuid;
  v_res := public.bot_compra_crear(p_phone => v_phone, p_asin => 'B00DETER002', p_product_title => 'Segunda',
    p_weight_lb => 1, p_unit_price_usd => 10);
  v_r2 := (v_res->>'request_id')::uuid;
  update public.purchase_requests set created_at = now() where id in (v_r1, v_r2);
  select request_number into v_n1 from public.purchase_requests where id = v_r1;
  select request_number into v_n2 from public.purchase_requests where id = v_r2;
  if v_n2 <= v_n1 then
    raise exception 'La segunda solicitud debía tener el número mayor (% / %)', v_n1, v_n2;
  end if;
  if (select count(distinct created_at) from public.purchase_requests where id in (v_r1, v_r2)) <> 1 then
    raise exception 'La prueba necesita dos solicitudes con el mismo created_at';
  end if;
  if (public.bot_compra_pendiente_de_pago(v_phone)->>'request_id')::uuid <> v_r2 then
    raise exception 'pendiente_de_pago debía devolver la de mayor request_number';
  end if;
  if (public.bot_compra_mis_solicitudes(v_phone, 5)->0->>'request_id')::uuid <> v_r2
     or (public.bot_compra_mis_solicitudes(v_phone, 5)->1->>'request_id')::uuid <> v_r1 then
    raise exception 'mis_solicitudes debía listar primero la de mayor request_number';
  end if;
  if (public.admin_purchase_list(null, 'whatsapp', 'B00DETER', 10)->0->>'id')::uuid <> v_r2 then
    raise exception 'admin_purchase_list debía listar primero la de mayor request_number';
  end if;

  -- ── 11c. Sin carrusel ────────────────────────────────────────────────────
  if to_regprocedure('public.helios_whatsapp_carousel(text,text,jsonb,uuid)') is not null then
    raise exception 'helios_whatsapp_carousel debía haberse eliminado';
  end if;
  begin
    insert into public.purchase_simulator_messages (phone_e164, direction, kind) values (v_phone, 'out', 'carousel');
    raise exception 'La restricción del simulador debía rechazar carousel';
  exception when check_violation then null;
  end;
  begin
    perform public.admin_purchase_sim_append(v_phone, 'out', 'carousel', 'x');
    raise exception 'admin_purchase_sim_append no debía aceptar carousel';
  exception when sqlstate '22023' then null;
  end;
  -- Una fila vieja de tipo carousel ya no tiene rama propia: sale como el
  -- texto de siempre (ventana abierta y sin botones), nunca como interactive.
  insert into public.outbound_messages (
    channel, template_key, recipient_staff_id, recipient,
    subject, rendered_text, status, next_attempt_at, wa_template
  ) values (
    'whatsapp', 'bot_respuesta', v_doc, v_phone,
    'Helios', 'Elige un producto', 'pendiente', now(),
    jsonb_build_object('kind', 'carousel', 'cards', jsonb_build_array('{}'::jsonb, '{}'::jsonb))
  )
  returning * into v_row;
  v_payload := public.helios_whatsapp_payload(v_row);
  if v_payload->>'type' <> 'text' or v_payload->'text'->>'body' <> 'Elige un producto' then
    raise exception 'Un carousel viejo debía caer en la rama de texto: %', v_payload;
  end if;
end $$;

set constraints all immediate;

rollback;
