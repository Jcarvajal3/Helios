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
--   8. WhatsApp Cloud API: helios_whatsapp_carousel y helios_whatsapp_payload
--      para carousel, list, text y button.
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
  v_cards     jsonb;
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
  if not (v_res->>'is_enabled')::boolean or (v_res->>'catalog_provider') <> 'mock' then
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

  -- Reporte por bot sin monto (p_amount_ves = null) → usa expected_ves del día (6600.00)
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
     or (v_res->>'declared_amount_ves')::numeric <> 6600.00
     or not (v_res->>'monto_cuadra')::boolean then
    raise exception 'Reporte por bot sin monto inesperado: %', v_res;
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
  if (v_counts->>'entregado')::integer < 1 or (v_counts->>'simulador_count')::integer < 1 then
    raise exception 'admin_purchase_counts incorrecto: %', v_counts;
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

  -- ── 8. WhatsApp Cloud API: carousel, list y retrocompatibilidad ──────────
  v_cards := jsonb_build_array(
    jsonb_build_object('card_index', 0, 'type', 'cta_url', 'header', jsonb_build_object('type', 'image', 'image', jsonb_build_object('link', 'https://example.com/1.jpg'))),
    jsonb_build_object('card_index', 1, 'type', 'cta_url', 'header', jsonb_build_object('type', 'image', 'image', jsonb_build_object('link', 'https://example.com/2.jpg')))
  );

  -- 1 sola tarjeta debe fallar
  begin
    perform public.helios_whatsapp_carousel(v_phone, 'Resultados', jsonb_build_array(v_cards->0), v_doc);
    raise exception 'Carrusel con 1 tarjeta debía fallar';
  exception when sqlstate '22023' then null;
  end;

  -- Ventana cerrada debe fallar
  begin
    perform public.helios_whatsapp_carousel('+584140009988', 'Resultados', v_cards, v_doc);
    raise exception 'Carrusel con ventana cerrada debía fallar';
  exception when sqlstate '22023' then null;
  end;

  -- Carrusel válido
  v_msg_id := public.helios_whatsapp_carousel(v_phone, 'Elige un producto de Amazon:', v_cards, v_doc);
  select * into v_msg_row from public.outbound_messages where id = v_msg_id;
  v_payload := public.helios_whatsapp_payload(v_msg_row);
  if v_payload->>'type' <> 'interactive'
     or v_payload->'interactive'->>'type' <> 'carousel'
     or jsonb_array_length(v_payload->'interactive'->'action'->'cards') <> 2 then
    raise exception 'Payload de carousel incorrecto: %', v_payload;
  end if;

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

set constraints all immediate;

rollback;
