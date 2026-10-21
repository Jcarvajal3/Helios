-- ============================================================================
-- Helios — Prueba de humo de «Nuevo financiamiento» (H4, docs/00 §5)
--
--   bash supabase/tests/run.sh patient_charge_smoke
--
-- Cubre `helios_patient_eligibility` + `preview_patient_charge` +
-- `create_patient_charge` (20261003000400) de punta a punta:
--   1. Paciente nuevo: vista previa, alta, cuotas a +7/+14 desde el día
--      operativo (medianoche), una sola línea libre, asiento de 4 patas
--      cuadrado, comisión devengada, comprobante + bienvenida encolados,
--      condiciones v1, bitácora y la respuesta del contrato.
--   2. Idempotencia (misma clave → el mismo financiamiento, sin tocar nada).
--   3. Paciente conocido: datos distintos → propuesta de cambio sin
--      sobrescribir; el comprobante va al correo registrado.
--   4. Cupo: dos financiamientos seguidos que no caben juntos (doble gasto) y
--      el cupo agotado como «no disponible».
--   5. Mayoría de edad, datos inválidos, referencia fija y referencia = paciente.
--   6. Lista negra, expulsado, bloqueado y con cuota vencida: el mismo texto
--      neutro que la elegibilidad.
--   7. Clínica pausada y mantenimiento (55000).
--   8. Reglas de sede: gerente en cualquiera (sin sede, la principal),
--      secretaria solo en la suya, y quien no es personal.
--   9. Sin consultar antes la cédula no hay vista previa ni alta.
--  10. Reenviar el comprobante (límite diario) y lo que ve la clínica.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin    uuid;
  v_gerente  uuid := gen_random_uuid();
  v_cajero   uuid := gen_random_uuid();
  v_cajero_b uuid := gen_random_uuid();
  v_otro     uuid := gen_random_uuid();
  v_m        uuid;
  v_otra     uuid;
  v_br_a     uuid;
  v_br_b     uuid;
  v_bdate    date := public.helios_business_date(now());
  v_pac      jsonb;
  v_j        jsonb;
  v_j2       jsonb;
  v_charge   uuid;
  v_charge2  uuid;
  v_profile  uuid;
  v_n        integer;
  v_num      numeric;
  v_err      text;
  v_neutral  text;
  v_failed   boolean;
  v_tx       record;
  v_row      record;
  v_doc      text;
  v_x        uuid;
begin
  -- =========================================================================
  -- Preparación: una clínica con dos sedes, su personal y el contacto
  -- =========================================================================
  update public.platform_maintenance set is_active = false;
  update public.platform_contact set whatsapp_number = '+584140001122';

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values
    (v_gerente,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'pc-gerente@prueba.helios.test', now(), now(), '{"full_name":"Laura Gerente"}'),
    (v_cajero,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'pc-cajero@prueba.helios.test', now(), now(), '{"full_name":"Ana Secretaria"}'),
    (v_cajero_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'pc-cajerob@prueba.helios.test', now(), now(), '{"full_name":"Bea Secretaria"}'),
    (v_otro,     '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'pc-otro@prueba.helios.test', now(), now(), '{"full_name":"Otro Gerente"}');

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_m    := (public.admin_create_merchant('Clínica Prueba PC', null, 'J-400000001', 'clinica')).id;
  v_otra := (public.admin_create_merchant('Otra Clínica PC', null, 'J-400000002', 'consultorio')).id;
  reset role;

  select id into v_br_a from public.merchant_branches where merchant_id = v_m and is_default;
  insert into public.merchant_branches (merchant_id, name) values (v_m, 'Sede Este') returning id into v_br_b;

  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_gerente,  v_m, v_br_a, 'gerente'),
    (v_cajero,   v_m, v_br_a, 'cajero'),
    (v_cajero_b, v_m, v_br_b, 'cajero'),
    (v_otro,     v_otra, (select id from public.merchant_branches where merchant_id = v_otra and is_default), 'gerente');

  v_pac := jsonb_build_object(
    'document', '12345678',
    'first_name', 'José', 'last_name', 'Pérez',
    'birth_date', (v_bdate - interval '30 years')::date,
    'sex', 'm',
    'phone', '0414-123.45.67',
    'email', ' Jose@Gmail.com ',
    'state', 'Miranda', 'city', 'Caracas', 'address', 'Los Palos Grandes',
    'occupation', null,
    'reference_name', 'María Pérez', 'reference_phone', '0212-555.12.34', 'reference_relationship', 'Madre');

  -- =========================================================================
  -- 1. Paciente nuevo
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  v_j := public.helios_patient_eligibility(v_m, 'v-12.345.678');
  if v_j->>'estado' <> 'nuevo' or (v_j->>'limite_usd')::numeric <> 150 or (v_j->>'min_charge_usd')::numeric <> 10 then
    raise exception 'Una cédula nueva debía responder nuevo con límite 150: %', v_j;
  end if;

  v_j := public.preview_patient_charge(v_m, 'V12345678', 100);
  if (v_j->>'base_usd')::numeric <> 100 or (v_j->>'consumer_fee_usd')::numeric <> 12
     or (v_j->>'consumer_fee_vat_usd')::numeric <> 1.92
     or (v_j->'installments'->0->>'amount_usd')::numeric <> 56.96
     or (v_j->'installments'->1->>'amount_usd')::numeric <> 56.96
     or (v_j->'installments'->0->>'financed_usd')::numeric <> 50
     or (v_j->'installments'->0->>'due_date')::date <> v_bdate + 7
     or (v_j->'installments'->1->>'due_date')::date <> v_bdate + 14
     or not (v_j->>'cabe')::boolean or v_j->'disponible_usd' <> 'null'::jsonb
     or (v_j->>'late_fee_usd')::numeric <> 2 or (v_j->>'business_date')::date <> v_bdate then
    raise exception 'Vista previa inesperada: %', v_j;
  end if;
  -- Ningún total con el fee.
  if v_j ? 'amount_usd' or v_j ? 'consumer_total_usd' then
    raise exception 'La vista previa no puede devolver un total con el fee: %', v_j;
  end if;

  v_j := public.create_patient_charge(v_m, null, v_pac, 100, null, '  Pedrito   Pérez ', 'pc-key-1');
  v_charge := (v_j->>'id')::uuid;
  if v_j->>'status' <> 'confirmed' or (v_j->>'merchant_sale_usd')::numeric <> 100
     or v_j->>'concept' <> 'Consulta' or v_j->>'beneficiary_name' <> 'Pedrito Pérez'
     or v_j->'patient'->>'nombre' <> 'José Pérez'
     or v_j->'patient'->>'documento_enmascarado' <> 'V-****5678'
     or v_j->'patient'->>'email_enmascarado' <> 'j***@gmail.com'
     or jsonb_array_length(v_j->'installments') <> 2
     or (v_j->'installments'->0->>'amount_usd')::numeric <> 56.96
     or (v_j->'breakdown'->>'base_usd')::numeric <> 100
     or (v_j->'breakdown'->>'consumer_fee_pct')::numeric <> 12
     or v_j->'receipt'->>'status' not in ('pendiente', 'sin_configurar')
     or v_j->>'registered_by' <> 'Ana Secretaria (Secretaria)'
     or (v_j->>'staff_commission_usd')::numeric <> 0.50
     or (v_j->>'business_date')::date <> v_bdate
     or v_j->>'branch_id' <> v_br_a::text
     or (v_j->>'order_number') is null then
    raise exception 'Respuesta de create_patient_charge inesperada: %', v_j;
  end if;
  reset role;

  select p.id into v_profile from public.profiles p where p.document_key = 'V12345678';
  select * into v_row from public.profiles where id = v_profile;
  if v_row.status <> 'active' or v_row.level <> 1 or v_row.phone_e164 <> '+584141234567'
     or v_row.email <> 'jose@gmail.com' or v_row.full_name <> 'José Pérez' or v_row.sex <> 'M'
     or v_row.reference_phone <> '+582125551234' or v_row.registered_by <> v_cajero
     or v_row.registered_merchant_id <> v_m or v_row.state <> 'Miranda' then
    raise exception 'El paciente nuevo no quedó bien: %', to_jsonb(v_row);
  end if;

  select * into v_row from public.charges where id = v_charge;
  if v_row.user_id <> v_profile or v_row.requested_by <> v_cajero or v_row.branch_id <> v_br_a
     or v_row.confirmed_at is null or v_row.business_date <> v_bdate
     or v_row.amount_usd <> 113.92 or v_row.base_usd <> 100
     or v_row.terms_version_id is distinct from (select id from public.terms_versions where is_current)
     or v_row.terms_version_id is null
     or v_row.commission_staff_id <> v_cajero or v_row.staff_commission_usd <> 0.50 then
    raise exception 'El financiamiento no quedó bien: %', to_jsonb(v_row);
  end if;

  select count(*) into v_n from public.charge_items
  where charge_id = v_charge and product_id is null and name = 'Consulta' and unit_price_usd = 100 and quantity = 1;
  if v_n <> 1 or (select count(*) from public.charge_items where charge_id = v_charge) <> 1 then
    raise exception 'Debía haber una sola línea libre «Consulta»';
  end if;

  -- Las cuotas: +7 y +14 desde el día operativo, que empieza a medianoche.
  if (select array_agg(due_date order by sequence) from public.installments where charge_id = v_charge)
       <> array[v_bdate + 7, v_bdate + 14]
     or (select sum(amount_usd) from public.installments where charge_id = v_charge) <> 113.92
     or (select sum(financed_usd) from public.installments where charge_id = v_charge) <> 100 then
    raise exception 'Cuotas inesperadas';
  end if;
  if public.helios_business_date(timestamptz '2026-10-01 00:05:00-04') <> date '2026-10-01'
     or public.helios_business_date(timestamptz '2026-09-30 23:55:00-04') <> date '2026-09-30'
     or (select due_1 from public.helios_installment_due_dates(date '2026-10-01')) <> date '2026-10-08'
     or (select due_2 from public.helios_installment_due_dates(date '2026-10-01')) <> date '2026-10-15' then
    raise exception 'Las fechas de las cuotas debían contarse desde la medianoche de Caracas';
  end if;

  -- El libro: cada asiento del financiamiento cuadra; la venta tiene 4 patas.
  for v_tx in
    select t.id, t.type::text as type, t.idempotency_key, sum(e.debit) as d, sum(e.credit) as c, count(*) as n
    from ledger.transactions t join ledger.entries e on e.transaction_id = t.id
    where t.reference_id = v_charge group by t.id, t.type, t.idempotency_key
  loop
    if v_tx.d <> v_tx.c then
      raise exception 'Asiento descuadrado: %', to_jsonb(v_tx);
    end if;
    if v_tx.type = 'charge' and (v_tx.n <> 4 or v_tx.d <> 113.92 or v_tx.idempotency_key <> 'charge:pc-key-1') then
      raise exception 'La venta debía tener 4 patas por 113.92: %', to_jsonb(v_tx);
    end if;
    if v_tx.type = 'staff_commission' and (v_tx.n <> 2 or v_tx.d <> 0.50
                                           or v_tx.idempotency_key <> 'staff_commission:' || v_charge) then
      raise exception 'La comisión debía ser un asiento de 0.50: %', to_jsonb(v_tx);
    end if;
  end loop;
  if (select count(*) from ledger.transactions where reference_id = v_charge) <> 2 then
    raise exception 'Debía haber dos asientos (venta y comisión)';
  end if;
  if (select e.credit from ledger.entries e join ledger.transactions t on t.id = e.transaction_id
      join ledger.accounts a on a.id = e.account_id
      where t.reference_id = v_charge and t.type = 'charge' and a.account_type = 'merchant_payable') <> 100
     or (select e.credit from ledger.entries e join ledger.transactions t on t.id = e.transaction_id
      join ledger.accounts a on a.id = e.account_id
      where t.reference_id = v_charge and t.type = 'charge' and a.account_type = 'platform_revenue') <> 12
     or (select e.credit from ledger.entries e join ledger.transactions t on t.id = e.transaction_id
      join ledger.accounts a on a.id = e.account_id
      where t.reference_id = v_charge and t.type = 'charge' and a.account_type = 'vat_payable') <> 1.92 then
    raise exception 'Las patas de la venta no son 100 / 12 / 1.92';
  end if;

  -- Comisión devengada, liquidación del día y cupo ocupado.
  if not exists (select 1 from public.staff_commissions sc join public.settlements s on s.id = sc.settlement_id
                 where sc.charge_id = v_charge and sc.status = 'devengada' and sc.amount_usd = 0.50
                   and sc.staff_user_id = v_cajero and s.reason = 'staff_commission'
                   and s.due_date = v_bdate and s.status = 'pending') then
    raise exception 'La comisión debía quedar devengada con su liquidación de hoy';
  end if;
  if public.helios_credit_used_usd(v_profile) <> 100 then
    raise exception 'El cupo ocupado debía ser 100';
  end if;

  -- Mensajes: el comprobante por correo y la bienvenida por WhatsApp.
  if not exists (select 1 from public.outbound_messages
                 where charge_id = v_charge and template_key = 'comprobante_financiamiento'
                   and channel = 'email' and recipient = 'jose@gmail.com' and status = 'pendiente') then
    raise exception 'El comprobante debía encolarse por correo';
  end if;
  if not exists (select 1 from public.outbound_messages
                 where charge_id = v_charge and template_key = 'bienvenida' and channel = 'whatsapp_manual'
                   and recipient = '+584141234567' and dedupe_key = 'bienvenida:' || v_charge
                   and rendered_text like '✅ ¡Listo, José! Tu pago en cuotas #%' and rendered_text like '%1️⃣ $56,96 · %'
                   and rendered_text like '%Monto en bolívares hoy: Bs %') then
    raise exception 'La bienvenida debía encolarse por WhatsApp';
  end if;
  if not exists (select 1 from audit.admin_actions where action = 'charge.created' and target_id = v_charge
                 and actor = v_cajero) then
    raise exception 'El alta debía quedar en la bitácora';
  end if;
  if not exists (select 1 from public.eligibility_lookups where staff_user_id = v_cajero and merchant_id = v_m
                 and document_key = 'V12345678' and result = 'nuevo') then
    raise exception 'La consulta debía quedar anotada';
  end if;
  raise notice 'TEST 1 OK — paciente nuevo: alta, cuotas, libro, comisión, mensajes, bitácora';

  -- =========================================================================
  -- 2. Idempotencia
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_j2 := public.create_patient_charge(v_m, null, v_pac, 100, null, null, 'pc-key-1');
  if v_j2->>'id' <> v_charge::text then
    raise exception 'La misma clave debía devolver el mismo financiamiento';
  end if;
  reset role;
  if (select count(*) from public.charges where idempotency_key = 'pc-key-1') <> 1
     or (select count(*) from public.installments where charge_id = v_charge) <> 2
     or (select count(*) from public.outbound_messages where charge_id = v_charge) <> 2
     or (select count(*) from ledger.transactions where reference_id = v_charge) <> 2 then
    raise exception 'El reintento no debía tocar nada';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_otro::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.create_patient_charge(v_otra, null, v_pac, 100, null, null, 'pc-key-1');
  exception when sqlstate '22023' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'La clave de otro financiamiento no debía servir en otra clínica';
  end if;
  raise notice 'TEST 2 OK — idempotencia';

  -- =========================================================================
  -- 3. Paciente conocido con datos distintos (lo registra el gerente)
  -- =========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  v_j := public.helios_patient_eligibility(v_m, 'V12345678');
  if v_j->>'estado' <> 'disponible' or (v_j->>'disponible_usd')::numeric <> 50
     or v_j->>'nombre' <> 'José Pérez' or v_j->>'telefono' <> '0414-1234567'
     or v_j->>'email' <> 'jose@gmail.com' then
    raise exception 'Elegibilidad del conocido inesperada: %', v_j;
  end if;
  v_j := public.preview_patient_charge(v_m, 'V12345678', 60);
  if (v_j->>'cabe')::boolean or (v_j->>'disponible_usd')::numeric <> 50 then
    raise exception 'La vista previa debía decir que 60 no cabe en 50: %', v_j;
  end if;

  v_j := public.create_patient_charge(v_m, null,
    v_pac || jsonb_build_object('phone', '04241112233', 'email', 'otro@correo.com', 'first_name', 'Jose'),
    10, 'Consulta + eco', null, 'pc-key-2');
  v_charge2 := (v_j->>'id')::uuid;
  if v_j->>'concept' <> 'Consulta + eco' or v_j->>'branch_id' <> v_br_a::text
     or v_j->>'registered_by' <> 'Laura Gerente (Administrador)' then
    raise exception 'Segundo financiamiento inesperado: %', v_j;
  end if;
  reset role;

  select * into v_row from public.profiles where id = v_profile;
  if v_row.phone_e164 <> '+584141234567' or v_row.email <> 'jose@gmail.com' or v_row.first_name <> 'José' then
    raise exception 'Los datos de un conocido no se sobrescriben';
  end if;
  select field_changes into v_j from public.profile_change_requests
  where profile_id = v_profile and merchant_id = v_m and requested_by = v_gerente and status = 'pendiente';
  if v_j is null
     or v_j->'phone'->>'antes' <> '+584141234567' or v_j->'phone'->>'propuesto' <> '+584241112233'
     or v_j->'email'->>'antes' <> 'jose@gmail.com' or v_j->'email'->>'propuesto' <> 'otro@correo.com'
     or v_j->'first_name'->>'propuesto' <> 'Jose'
     or v_j ? 'last_name' or v_j ? 'birth_date' or v_j ? 'reference_phone' then
    raise exception 'La propuesta de cambio no es la esperada: %', v_j;
  end if;
  if not exists (select 1 from public.outbound_messages where charge_id = v_charge2
                 and template_key = 'comprobante_financiamiento' and recipient = 'jose@gmail.com') then
    raise exception 'El comprobante debía ir al correo REGISTRADO';
  end if;
  raise notice 'TEST 3 OK — conocido: propuesta de cambio sin sobrescribir, comprobante al correo registrado';

  -- =========================================================================
  -- 4. Cupo: doble gasto y cupo agotado (usado 110 de 150)
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero_b::text, 'role', 'authenticated')::text, true);
  v_j := public.helios_patient_eligibility(v_m, 'V12345678');
  if (v_j->>'disponible_usd')::numeric <> 40 then
    raise exception 'Debían quedar 40 disponibles: %', v_j;
  end if;
  -- Dos sedes a la vez, una detrás de otra: 25 cabe, el segundo 25 ya no.
  perform public.create_patient_charge(v_m, null, v_pac, 25, null, null, 'pc-key-3');
  v_err := null;
  begin
    perform public.create_patient_charge(v_m, null, v_pac, 25, null, null, 'pc-key-4');
  exception when sqlstate '22023' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is distinct from 'El monto supera lo disponible ($15).' then
    raise exception 'El segundo cargo debía rechazarse por cupo, dijo: %', v_err;
  end if;
  perform public.create_patient_charge(v_m, null, v_pac, 10, null, null, 'pc-key-5');
  -- Quedan 5 < mínimo: «no disponible», sin decir por qué.
  v_j := public.helios_patient_eligibility(v_m, 'V12345678');
  v_neutral := v_j->>'mensaje';
  if v_j->>'estado' <> 'no_disponible'
     or v_neutral <> 'Esta persona no puede pagar en cuotas con Helios. Si tiene dudas, puede escribir a Helios al 0414-0001122.'
     or v_j->>'whatsapp_helios' <> '+584140001122'
     or (select count(*) from jsonb_object_keys(v_j)) <> 3 then
    raise exception 'Cupo agotado debía ser no_disponible neutro: %', v_j;
  end if;
  v_err := null;
  begin
    perform public.create_patient_charge(v_m, null, v_pac, 10, null, null, 'pc-key-6');
  exception when sqlstate '22023' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is distinct from v_neutral then
    raise exception 'Con el cupo agotado debía salir el texto neutro, salió: %', v_err;
  end if;
  raise notice 'TEST 4 OK — cupo: doble gasto y agotado';

  -- =========================================================================
  -- 5. Datos del paciente nuevo
  -- =========================================================================
  perform public.helios_patient_eligibility(v_m, 'V20000001');
  for v_err, v_j in
    select * from (values
      ('El titular debe ser mayor de edad. Si el paciente es menor, registra a su representante',
       jsonb_build_object('birth_date', (v_bdate - interval '17 years' - interval '300 days')::date)),
      ('Teléfono móvil inválido', jsonb_build_object('phone', '02125551234')),
      ('Correo inválido', jsonb_build_object('email', 'jose@')),
      ('El teléfono del contacto de referencia tiene que ser distinto del del paciente',
       jsonb_build_object('reference_phone', '04141234567')),
      ('Teléfono del contacto de referencia inválido', jsonb_build_object('reference_phone', '123')),
      ('El sexo debe ser F o M', jsonb_build_object('sex', 'X'))
    ) t(msg, patch)
  loop
    v_doc := null;
    begin
      perform public.create_patient_charge(v_m, null,
        v_pac || jsonb_build_object('document', 'V20000001') || v_j, 50, null, null, 'pc-bad-' || md5(v_err));
    exception when sqlstate '22023' then
      get stacked diagnostics v_doc = message_text;
    end;
    if v_doc is distinct from v_err then
      raise exception 'Esperaba «%», salió «%»', v_err, v_doc;
    end if;
  end loop;
  v_err := null;
  begin
    perform public.create_patient_charge(v_m, null, v_pac || '{"document":"V20000001"}', 9.99, null, null, 'pc-bad-min');
  exception when sqlstate '22023' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is distinct from 'El monto mínimo es $10' then
    raise exception 'El mínimo debía ser $10: %', v_err;
  end if;

  -- Justo 18 hoy sí; la referencia puede ser un fijo.
  v_j := public.create_patient_charge(v_m, null,
    v_pac || jsonb_build_object('document', 'V20000001', 'birth_date', (v_bdate - interval '18 years')::date,
                                'phone', '04161234567', 'email', 'menor@correo.com'),
    50, null, null, 'pc-key-18');
  if v_j->>'status' <> 'confirmed' then
    raise exception 'Con 18 años cumplidos hoy debía poder: %', v_j;
  end if;
  raise notice 'TEST 5 OK — mayoría de edad y validación de datos';

  -- =========================================================================
  -- 6. No disponible: lista negra, expulsado, bloqueado, cuota vencida
  -- =========================================================================
  reset role;
  insert into public.profiles (phone_e164, full_name, document_number, is_blacklisted, blacklist_reason)
  values ('+584141000001', 'Lista Negra', 'V30000001', true, 'Fraude');
  insert into public.profiles (phone_e164, full_name, document_number, status)
  values ('+584141000002', 'Expulsado Uno', 'V30000002', 'expelled');
  insert into public.profiles (phone_e164, full_name, document_number)
  values ('+584141000003', 'Bloqueado Uno', 'V30000003') returning id into v_x;
  insert into public.user_blocks (user_id, reason, message, blocked_by) values (v_x, 'manual', 'Bloqueo de prueba', v_admin);
  insert into public.profiles (phone_e164, full_name, document_number, email)
  values ('+584141000004', 'Moroso Uno', 'V30000004', 'moroso@correo.com') returning id into v_x;
  perform pg_temp.prueba_cobro(v_x, v_m, v_br_a, v_cajero, 20, 'pc-moroso');
  update public.installments set due_date = v_bdate - 1
  where user_id = v_x and sequence = 1;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  foreach v_doc in array array['V30000001', 'V30000002', 'V30000003', 'V30000004'] loop
    v_j := public.helios_patient_eligibility(v_m, v_doc);
    if v_j->>'estado' <> 'no_disponible' or v_j->>'mensaje' <> v_neutral
       or (select count(*) from jsonb_object_keys(v_j)) <> 3 then
      raise exception '% debía ser no_disponible con el texto neutro: %', v_doc, v_j;
    end if;
    v_err := null;
    begin
      perform public.create_patient_charge(v_m, null, v_pac || jsonb_build_object('document', v_doc),
                                           20, null, null, 'pc-no-' || v_doc);
    exception when sqlstate '22023' then
      get stacked diagnostics v_err = message_text;
    end;
    if v_err is distinct from v_neutral then
      raise exception '% debía rechazarse con el texto neutro, salió: %', v_doc, v_err;
    end if;
  end loop;
  raise notice 'TEST 6 OK — lista negra, expulsado, bloqueado y moroso: el mismo texto neutro';

  -- =========================================================================
  -- 7. Clínica pausada y mantenimiento
  -- =========================================================================
  reset role;
  update public.merchants set status = 'paused' where id = v_m;
  set local role authenticated;
  v_err := null;
  begin
    perform public.helios_patient_eligibility(v_m, 'V12345678');
  exception when sqlstate '55000' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is distinct from 'La clínica está pausada' then
    raise exception 'Una clínica pausada debía dar 55000: %', v_err;
  end if;
  v_err := null;
  begin
    perform public.create_patient_charge(v_m, null, v_pac, 10, null, null, 'pc-paused');
  exception when sqlstate '55000' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is distinct from 'La clínica está pausada' then
    raise exception 'Una clínica pausada no registra: %', v_err;
  end if;
  reset role;
  update public.merchants set status = 'active' where id = v_m;
  update public.platform_maintenance
     set is_active = true, blocks_balance = true, message = 'Volvemos enseguida', expected_back = null;
  set local role authenticated;
  v_err := null;
  begin
    perform public.preview_patient_charge(v_m, null, 50);
  exception when sqlstate '55000' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is distinct from 'Volvemos enseguida' then
    raise exception 'El mantenimiento debía dar 55000 con su texto: %', v_err;
  end if;
  v_failed := false;
  begin
    perform public.create_patient_charge(v_m, null, v_pac, 10, null, null, 'pc-maint');
  exception when sqlstate '55000' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'En mantenimiento no se registra';
  end if;
  reset role;
  update public.platform_maintenance set is_active = false;
  raise notice 'TEST 7 OK — clínica pausada y mantenimiento';

  -- =========================================================================
  -- 8. Reglas de sede
  -- =========================================================================
  set local role authenticated;
  -- La secretaria de la sede A no registra en la B.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V40000001');
  v_failed := false;
  begin
    perform public.create_patient_charge(v_m, v_br_b, v_pac || '{"document":"V40000001","phone":"04261234567","email":"a@b.co"}',
                                         20, null, null, 'pc-sede-1');
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Una secretaria no registra en otra sede';
  end if;
  -- La de la B, sin sede: la suya.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero_b::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V40000001');
  v_j := public.create_patient_charge(v_m, null, v_pac || '{"document":"V40000001","phone":"04261234567","email":"a@b.co"}',
                                      20, null, null, 'pc-sede-2');
  if v_j->>'branch_id' <> v_br_b::text then
    raise exception 'Sin sede, la secretaria registra en la suya: %', v_j->>'branch_id';
  end if;
  -- El gerente, en cualquiera.
  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V40000001');
  v_j := public.create_patient_charge(v_m, v_br_b, v_pac || '{"document":"V40000001"}', 20, null, null, 'pc-sede-3');
  if v_j->>'branch_id' <> v_br_b::text then
    raise exception 'El gerente debía poder registrar en la sede B';
  end if;
  -- Una sede de otra clínica, no.
  v_failed := false;
  begin
    perform public.create_patient_charge(v_m, (select id from public.merchant_branches where merchant_id = v_otra limit 1),
                                         v_pac || '{"document":"V40000001"}', 20, null, null, 'pc-sede-4');
  exception when sqlstate '22023' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Una sede de otra clínica no vale';
  end if;
  -- Quien no es personal de la clínica.
  perform set_config('request.jwt.claims', json_build_object('sub', v_otro::text, 'role', 'authenticated')::text, true);
  v_err := null;
  begin
    perform public.create_patient_charge(v_m, null, v_pac, 20, null, null, 'pc-sede-5');
  exception when sqlstate '42501' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is distinct from 'No tienes permiso para registrar en esta clínica' then
    raise exception 'Quien no es personal debía recibir 42501: %', v_err;
  end if;
  v_failed := false;
  begin
    perform public.helios_patient_eligibility(v_m, 'V12345678');
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Quien no es personal no consulta cédulas de esta clínica';
  end if;
  raise notice 'TEST 8 OK — reglas de sede';

  -- =========================================================================
  -- 9. Sin consulta previa no hay vista previa ni alta
  -- =========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  v_err := null;
  begin
    perform public.preview_patient_charge(v_m, 'V50000001', 20);
  exception when sqlstate '22023' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is distinct from 'Primero consulta la cédula del paciente' then
    raise exception 'La vista previa sin consulta debía rechazarse: %', v_err;
  end if;
  v_err := null;
  begin
    perform public.create_patient_charge(v_m, null, v_pac || '{"document":"V50000001"}', 20, null, null, 'pc-sin-consulta');
  exception when sqlstate '22023' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is distinct from 'Primero consulta la cédula del paciente' then
    raise exception 'El alta sin consulta debía rechazarse: %', v_err;
  end if;
  raise notice 'TEST 9 OK — la vista previa y el alta exigen haber consultado la cédula';

  -- =========================================================================
  -- 10. Reenviar el comprobante y lo que ve la clínica
  -- =========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  for v_n in 1..3 loop
    v_j := public.staff_resend_receipt(v_charge);
    if not (v_j->>'ok')::boolean or v_j->>'email_enmascarado' <> 'j***@gmail.com'
       or v_j->>'status' not in ('pendiente', 'sin_configurar') then
      raise exception 'Reenvío % inesperado: %', v_n, v_j;
    end if;
  end loop;
  v_err := null;
  begin
    perform public.staff_resend_receipt(v_charge);
  exception when sqlstate '22023' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is null or v_err not like 'Ya reenviaste este comprobante 3 veces hoy%' then
    raise exception 'El cuarto reenvío del día debía rechazarse: %', v_err;
  end if;
  -- La otra secretaria no ve ni reenvía lo que no registró.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero_b::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.staff_resend_receipt(v_charge);
  exception when sqlstate 'P0002' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Otra secretaria no reenvía un comprobante ajeno';
  end if;
  v_failed := false;
  begin
    perform public.helios_charge_for_staff(v_charge);
  exception when sqlstate 'P0002' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Otra secretaria no ve un financiamiento ajeno';
  end if;
  -- El gerente ve la lista con lo nuevo.
  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  select * into v_row from public.merchant_transactions(v_bdate, v_bdate) t where t.charge_id = v_charge;
  if v_row.concept <> 'Consulta' or v_row.beneficiary_name <> 'Pedrito Pérez'
     or v_row.receipt_status not in ('pendiente', 'sin_configurar') or v_row.staff_commission_usd <> 0.50
     or v_row.registered_by_name <> 'Ana Secretaria' or v_row.merchant_sale_usd <> 100
     or v_row.cuota_1_due <> v_bdate + 7 then
    raise exception 'merchant_transactions sin lo nuevo: %', to_jsonb(v_row);
  end if;
  v_j := public.merchant_charge_detail(v_charge);
  if v_j->>'concept' <> 'Consulta' or v_j->'receipt'->>'status' is null
     or (v_j->>'staff_commission_usd')::numeric <> 0.50 or v_j->>'commission_staff_name' <> 'Ana Secretaria'
     or jsonb_array_length(v_j->'installments') <> 2
     or v_j->'installments'->0 ? 'status' or v_j->'installments'->0 ? 'amount_usd'
     or (v_j->'installments'->0->>'run_date')::date <> public.helios_settlement_run_for(v_bdate + 7)
     or not exists (select 1 from jsonb_array_elements(v_j->'payouts') x where x->>'kind' = 'staff_commission') then
    raise exception 'merchant_charge_detail sin lo nuevo: %', v_j;
  end if;
  -- La secretaria ve solo los suyos.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero_b::text, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.merchant_transactions(v_bdate, v_bdate) t where t.registered_by_name <> 'Bea Secretaria') then
    raise exception 'La secretaria debía ver solo lo que registró';
  end if;
  reset role;
  raise notice 'TEST 10 OK — reenvío con límite y lo que ve la clínica';

  -- =========================================================================
  -- 11. Superadmin: ficha, contacto y propuestas de cambio (docs/01 §2.4)
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_j := public.admin_user_detail(v_profile);
  if v_j->'datos'->>'document' <> 'V12345678' or (v_j->'datos'->>'age')::int <> 30
     or v_j->'datos'->>'registered_by_name' <> 'Ana Secretaria'
     or v_j->'datos'->>'registered_merchant_name' <> 'Clínica Prueba PC'
     or v_j->'datos'->>'reference_phone' <> '+582125551234'
     or (v_j->'datos'->>'pending_change_requests')::int <> 1
     or not v_j ? 'credit' or not v_j ? 'installments' then
    raise exception 'admin_user_detail sin la sección datos: %', v_j->'datos';
  end if;
  select * into v_row from public.admin_user_directory(p_search => 'V12345678') d;
  if v_row.registered_merchant_name <> 'Clínica Prueba PC' or v_row.email_invalid_at is not null then
    raise exception 'admin_user_directory sin las columnas nuevas: %', to_jsonb(v_row);
  end if;
  v_j := public.admin_merchant_detail(v_m);
  if not (v_j->'terms' ? 'staff_commission_usd') or (v_j->'terms'->>'staff_commission_effective_usd')::numeric <> 0.50 then
    raise exception 'admin_merchant_detail sin la comisión: %', v_j->'terms';
  end if;
  if not (public.admin_merchant_terms_history(v_m)->0 ? 'staff_commission_usd') then
    raise exception 'admin_merchant_terms_history sin la comisión';
  end if;

  -- Corregir el contacto: motivo obligatorio, solo campos de contacto.
  v_failed := false;
  begin
    perform public.admin_update_patient_contact(v_profile, '{"city":"Valencia"}', ' ');
  exception when sqlstate '22023' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Corregir el contacto sin motivo debía rechazarse';
  end if;
  v_failed := false;
  begin
    perform public.admin_update_patient_contact(v_profile, '{"first_name":"Otro"}', 'Pidió el paciente');
  exception when sqlstate '22023' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'El nombre no se cambia como contacto';
  end if;
  v_j := public.admin_update_patient_contact(v_profile,
           '{"city":"Valencia","occupation":"Docente","reference_phone":"0424-999.88.77"}', 'Llamó el paciente');
  if v_j->'changes'->'city'->>'despues' <> 'Valencia' or v_j->'datos'->>'occupation' <> 'Docente'
     or v_j->'datos'->>'reference_phone' <> '+584249998877' then
    raise exception 'admin_update_patient_contact inesperado: %', v_j;
  end if;

  -- La propuesta de la clínica: lo propuesto y lo actual.
  select * into v_row from public.admin_profile_change_requests() r where r.profile_id = v_profile;
  if v_row.proposed->>'phone' <> '+584241112233' or v_row."current"->>'phone' <> '+584141234567'
     or v_row.merchant_name <> 'Clínica Prueba PC' or v_row.requested_by_name <> 'Laura Gerente'
     or v_row.status <> 'pendiente' or v_row.resolved_at is not null then
    raise exception 'admin_profile_change_requests inesperado: %', to_jsonb(v_row);
  end if;
  v_x := v_row.id;
  v_j := public.admin_resolve_profile_change(v_x, true, 'Confirmado por teléfono');
  if v_j->>'status' <> 'aprobado' then
    raise exception 'Aprobar debía devolver aprobado: %', v_j;
  end if;
  v_failed := false;
  begin
    perform public.admin_resolve_profile_change(v_x, false, null);
  exception when sqlstate '22023' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Una propuesta revisada no se vuelve a resolver';
  end if;
  -- La del otro paciente (sede B), rechazada.
  select r.id into v_x from public.admin_profile_change_requests() r limit 1;
  perform public.admin_resolve_profile_change(v_x, false, 'No coincide');
  if exists (select 1 from public.admin_profile_change_requests()) then
    raise exception 'No debía quedar ninguna propuesta pendiente';
  end if;
  if (select count(*) from public.admin_profile_change_requests(null)) <> 2 then
    raise exception 'Con estado null debían salir todas';
  end if;

  -- La secretaria no puede nada de esto.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.admin_update_patient_contact(v_profile, '{"city":"X"}', 'motivo');
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'La clínica no corrige datos de pacientes';
  end if;
  reset role;

  select * into v_row from public.profiles where id = v_profile;
  if v_row.phone_e164 <> '+584241112233' or v_row.email <> 'otro@correo.com' or v_row.first_name <> 'Jose'
     or v_row.full_name <> 'Jose Pérez' or v_row.city <> 'Valencia' or v_row.email_invalid_at is not null then
    raise exception 'Aprobar debía aplicar lo propuesto: %', to_jsonb(v_row);
  end if;
  if (select count(*) from audit.admin_actions
      where target_id = v_profile and action in ('patient.contact_updated', 'patient.change_request_approved')) <> 2 then
    raise exception 'Las correcciones debían quedar en la bitácora';
  end if;
  raise notice 'TEST 11 OK — superadmin: datos, contacto con motivo y propuestas de cambio';

  raise notice '=== TODOS LOS TESTS DE NUEVO FINANCIAMIENTO PASARON ===';
end $$;

set constraints all immediate;

rollback;
