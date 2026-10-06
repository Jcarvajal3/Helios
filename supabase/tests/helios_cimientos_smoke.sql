-- ============================================================================
-- Helios — Prueba de humo de los cimientos de la fase 1A
--
--   bash supabase/tests/run.sh helios_cimientos_smoke
--
-- Cubre las migraciones 20261002000100…000700:
--   H1  el dólar es la moneda (tasa BCV = USD, espejos del dólar), niveles,
--       parámetros nuevos y sus lectores, el monto mínimo;
--   H2  el día operativo empieza a medianoche (alrededor de las 00:00 y de las
--       10:00 de Caracas);
--   H3  el paciente es una fila de `profiles` sin cuenta en Auth, las FK del
--       deudor, el teléfono repetido, los ayudantes de normalizar y enmascarar,
--       y que el personal no lee pacientes;
--   H8  la ficha de la clínica, su cuenta de pago y quién la lee (RLS);
--   H11 el contacto de Helios, `helios_config_status`, varias cuentas de
--       cobro, la cola de mensajes y el comprobante.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin     uuid;
  v_gerente   uuid := gen_random_uuid();
  v_cajero    uuid := gen_random_uuid();
  v_otro      uuid := gen_random_uuid();
  v_pac       uuid;
  v_pac2      uuid;
  v_sin_mail  uuid;
  v_merchant  public.merchants%rowtype;
  v_otra      uuid;
  v_branch    uuid;
  v_charge    uuid;
  v_msg       uuid;
  v_msg2      uuid;
  v_row       public.outbound_messages%rowtype;
  v_j         jsonb;
  v_n         integer;
  v_failed    boolean;
  v_err       text;
  v_resend    boolean := exists (select 1 from vault.secrets where name = 'resend_api_key');
begin
  -- =========================================================================
  -- H1 — El precio se pacta en dólares
  -- =========================================================================

  if exists (select 1 from public.exchange_rates where source = 'BCV_USD') then
    raise exception 'La serie del dólar debía estar bajo BCV, no bajo BCV_USD';
  end if;
  if not exists (select 1 from public.exchange_rates where source = 'BCV_EUR') then
    raise exception 'La serie del euro de Ronda debía quedar archivada como BCV_EUR';
  end if;
  if public.current_fx_rate('BCV') is null then
    raise exception 'Debía haber tasa BCV vigente';
  end if;
  -- La del dólar es menor que la del euro (859 vs 973 el 30/09): si BCV fuese
  -- el euro, este orden se invertiría.
  if public.current_fx_rate('BCV', date '2026-09-30') >= public.current_fx_rate('BCV_EUR', date '2026-09-30') then
    raise exception 'BCV del 30/09 debía ser el dólar (menor que el euro)';
  end if;

  select count(*) into v_n from public.fx_rate_sources
  where is_active
    and ((key = 'dolarapi' and url like '%/v1/dolares/oficial')
      or (key = 'er-api'   and url like '%/latest/USD'));
  if v_n <> 2 or exists (select 1 from public.fx_rate_sources where is_active and key like '%eur%') then
    raise exception 'Los espejos activos debían ser los dos del dólar y ninguno del euro';
  end if;
  raise notice 'TEST H1.1 OK — BCV es el dólar, el euro archivado, espejos del dólar';

  if (select monthly_limit_usd from public.levels where level = 1) <> 350
     or not (select is_active from public.levels where level = 1)
     or (select required_spend_usd from public.levels where level = 1) <> 0 then
    raise exception 'El nivel 1 debía ser $350, activo y sin requisitos';
  end if;
  if exists (select 1 from public.levels where level <> 1 and is_active) then
    raise exception 'Solo el nivel 1 debía estar activo';
  end if;
  if (select array_agg(monthly_limit_usd::int order by level) from public.levels where level between 2 and 4)
     <> array[500, 700, 1000] then
    raise exception 'Los niveles 2-4 de ejemplo debían ser 500, 700 y 1000';
  end if;
  if (select label from public.levels where level = 5) <> 'Próximamente'
     or (select label from public.levels where level = 0) <> 'Sin nivel' then
    raise exception 'Etiquetas de los niveles 0 y 5 incorrectas';
  end if;
  raise notice 'TEST H1.2 OK — niveles de Helios';

  if public.helios_min_charge_usd() <> 10
     or public.helios_staff_commission_usd() <> 0.50
     or public.helios_eligibility_lookups_per_staff_day() <> 60
     or public.helios_payment_four_eyes()
     or public.helios_receipt_resends_per_day() <> 3
     or public.helios_late_fee_usd() <> 2 then
    raise exception 'Parámetros: min %, comisión %, consultas %, 4 ojos %, reenvíos %, mora %',
      public.helios_min_charge_usd(), public.helios_staff_commission_usd(),
      public.helios_eligibility_lookups_per_staff_day(), public.helios_payment_four_eyes(),
      public.helios_receipt_resends_per_day(), public.helios_late_fee_usd();
  end if;
  if public.helios_parameter('alert_merchant_exposure_usd', -1) <> 3000
     or public.helios_parameter('alert_fpd_min_cases', -1) <> 5 then
    raise exception 'Los umbrales de alertas debían estar sembrados';
  end if;
  select count(*) into v_n from public.business_parameter_catalog
  where key in ('min_charge_usd', 'staff_commission_usd', 'eligibility_lookups_per_staff_day',
                'payment_four_eyes', 'receipt_resends_per_day', 'alert_charges_per_merchant_day',
                'alert_new_patients_per_merchant_day', 'alert_staff_share_pct', 'alert_fpd_merchant_pct',
                'alert_fpd_min_cases', 'alert_merchant_exposure_usd', 'alert_first_charge_limit_pct');
  if v_n <> 12 or exists (select 1 from public.business_parameter_catalog where unit = '€') then
    raise exception 'El catálogo debía tener los 12 parámetros nuevos y ninguna unidad en euros';
  end if;
  raise notice 'TEST H1.3 OK — parámetros y lectores';

  perform public.helios_assert_charge_amount(10);
  perform public.helios_assert_charge_amount(349.99);
  for v_err in select unnest(array['9.99', '10.001', '0']) loop
    v_failed := false;
    begin
      perform public.helios_assert_charge_amount(v_err::numeric);
    exception when sqlstate '22023' then
      v_failed := true;
      if v_err = '9.99' and sqlerrm <> 'El monto mínimo es $10' then
        raise exception 'Texto del mínimo inesperado: %', sqlerrm;
      end if;
    end;
    if not v_failed then
      raise exception 'El monto % debía rechazarse', v_err;
    end if;
  end loop;
  if exists (select 1 from pg_constraint where conname = 'charges_amount_usd_check') then
    raise exception 'El check rígido de €5 debía haberse ido';
  end if;
  raise notice 'TEST H1.4 OK — monto mínimo por parámetro, 2 decimales';

  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'ledger', 'audit', 'metricas', 'asistente')
      -- («euro» en singular queda en un comentario: la serie archivada BCV_EUR.)
      and (p.prosrc like '%€%' or p.prosrc ~* '\meuros\M')
  ) or exists (
    select 1 from public.notification_templates
    where concat(default_title, default_body, title, body, draft_title, draft_body) like '%€%'
  ) then
    raise exception 'Quedan euros en funciones o plantillas';
  end if;
  raise notice 'TEST H1.5 OK — ningún € en funciones ni plantillas';

  -- =========================================================================
  -- H2 — El día operativo empieza a medianoche
  -- =========================================================================

  if public.helios_business_date('2026-09-30 23:59:59-04') <> '2026-09-30'
     or public.helios_business_date('2026-10-01 00:00:00-04') <> '2026-10-01'
     or public.helios_business_date('2026-10-01 09:59:59-04') <> '2026-10-01'
     or public.helios_business_date('2026-10-01 10:00:00-04') <> '2026-10-01'
     or public.helios_business_date('2026-10-01 03:30:00+00') <> '2026-09-30' then
    raise exception 'helios_business_date no corta a medianoche de Caracas';
  end if;
  if public.helios_business_day_end('2026-09-30') <> '2026-10-01 00:00:00-04'::timestamptz then
    raise exception 'El día operativo debía terminar a medianoche: %', public.helios_business_day_end('2026-09-30');
  end if;
  if metricas.dia_operativo('2026-10-01 01:00-04') <> '2026-10-01'
     or asistente.dia_operativo('2026-10-01 01:00-04') <> '2026-10-01'
     or asistente.dia_operativo_actual() <> public.helios_business_date(now()) then
    raise exception 'Las copias del día operativo (metricas, asistente) no cortan a medianoche';
  end if;
  raise notice 'TEST H2 OK — el día operativo empieza a medianoche (00:00 y 10:00)';

  -- =========================================================================
  -- H3 — El paciente no tiene cuenta
  -- =========================================================================

  if public.helios_normalize_ve_mobile('0414-123.45.67') <> '+584141234567'
     or public.helios_normalize_ve_mobile('4221234567') <> '+584221234567'
     or public.helios_normalize_ve_mobile('+58 426 1234567') <> '+584261234567'
     or public.helios_normalize_ve_mobile('02121234567') is not null
     or public.helios_normalize_ve_mobile('0415123456') is not null then
    raise exception 'helios_normalize_ve_mobile no normaliza bien';
  end if;
  if not public.helios_valid_email('ana.perez+1@gmail.com')
     or public.helios_valid_email('ana@gmail')
     or public.helios_valid_email('ana perez@gmail.com')
     or public.helios_valid_email(null) then
    raise exception 'helios_valid_email no valida bien';
  end if;
  if public.helios_mask_name('José  Pérez') <> 'J*** P***'
     or public.helios_mask_phone('+584141234567') <> '0414-***-**67'
     or public.helios_mask_email('jose@gmail.com') <> 'j***@gmail.com'
     or public.helios_mask_document('V-12.345.678') <> 'V-****5678'
     or public.helios_mask_document('12345678') <> 'V-****5678' then
    raise exception 'Máscaras: %, %, %, %', public.helios_mask_name('José  Pérez'),
      public.helios_mask_phone('+584141234567'), public.helios_mask_email('jose@gmail.com'),
      public.helios_mask_document('V-12.345.678');
  end if;
  raise notice 'TEST H3.1 OK — normalizar, validar y enmascarar';

  -- Un paciente es una fila de profiles, sin auth.users. Nace activo, nivel 1.
  insert into public.profiles (phone_e164, first_name, last_name, full_name, document_number, email, sex)
  values ('+584141234567', 'José', 'Pérez', 'José Pérez', 'V12345678', 'jose@gmail.com', 'M')
  returning id into v_pac;
  if exists (select 1 from auth.users where id = v_pac) then
    raise exception 'El paciente no debía tener cuenta en Auth';
  end if;
  if (select status::text || ':' || level from public.profiles where id = v_pac) <> 'active:1' then
    raise exception 'Un paciente nuevo debía nacer activo y en nivel 1';
  end if;
  if exists (select 1 from public.level_changes where user_id = v_pac) then
    raise exception 'Nacer en el nivel 1 no es una subida';
  end if;

  -- Mismo teléfono (una familia): se permite. Misma cédula: no.
  insert into public.profiles (phone_e164, full_name, document_number)
  values ('+584141234567', 'María Pérez', 'V22345678') returning id into v_pac2;
  v_failed := false;
  begin
    insert into public.profiles (phone_e164, full_name, document_number)
    values ('+584149999999', 'Otro', 'V-12.345.678');
  exception when unique_violation then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'La cédula debía ser única';
  end if;
  v_failed := false;
  begin
    insert into public.profiles (phone_e164, email) values ('+584149999998', 'MAL@correo');
  exception when check_violation then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Un correo inválido debía rechazarse';
  end if;

  -- Crear personal en Auth ya no crea perfiles.
  insert into auth.users (id, instance_id, aud, role, email, phone, created_at, updated_at, raw_user_meta_data)
  values
    (v_gerente, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'gerente@prueba.helios.test', '584140001001', now(), now(), '{"full_name":"Laura Gerente"}'),
    (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'cajero@prueba.helios.test', '584140001002', now(), now(), '{"full_name":"Ana Secretaria"}'),
    (v_otro, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'otro@prueba.helios.test', '584140001003', now(), now(), '{"full_name":"Otro Gerente"}');
  if exists (select 1 from public.profiles where id in (v_gerente, v_cajero, v_otro)) then
    raise exception 'Una cuenta de personal no debía crear un perfil de paciente';
  end if;

  -- La deuda apunta a profiles: con un id que no es paciente, la FK salta.
  v_failed := false;
  begin
    insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date, status, financed_usd)
    values (gen_random_uuid(), v_cajero, 1, 1, current_date, 'pending', 1);
  exception when foreign_key_violation then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'installments.user_id debía exigir un paciente de profiles';
  end if;
  if exists (
    select 1 from pg_constraint
    where contype = 'f' and confrelid = 'auth.users'::regclass
      and conname in ('profiles_id_fkey', 'charges_user_id_fkey', 'installments_user_id_fkey',
                      'user_credit_blocks_user_id_fkey', 'payment_quotes_user_id_fkey',
                      'payment_reports_user_id_fkey', 'level_changes_user_id_fkey',
                      'notifications_user_id_fkey', 'late_fees_user_id_fkey', 'user_blocks_user_id_fkey')
  ) then
    raise exception 'Queda alguna FK de deudor apuntando a auth.users';
  end if;
  raise notice 'TEST H3.2 OK — paciente sin cuenta, teléfono compartido, cédula única, FK a profiles';

  -- =========================================================================
  -- H8 — La clínica, su personal y su cuenta de pago
  -- =========================================================================

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  v_merchant := public.admin_create_merchant(
    p_name => 'Consultorio <Sol> & Luna', p_tax_id => 'J-123456789', p_category => 'consultorio',
    p_city => 'Caracas', p_specialty => 'Medicina interna', p_mpps_number => '12345',
    p_phone => '02121234567', p_email => 'Consultorio@Sol.com', p_address => 'Chacao');
  if v_merchant.specialty <> 'Medicina interna' or v_merchant.email <> 'consultorio@sol.com' then
    raise exception 'El alta no guardó la ficha médica: %', to_jsonb(v_merchant);
  end if;
  v_otra := (public.admin_create_merchant('Otra clínica', null, 'J-223456789', 'clinica')).id;

  v_failed := false;
  begin
    perform public.admin_create_merchant('Bar', null, 'J-323456789', 'discoteca');
  exception when sqlstate '22023' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Una clínica nueva no debía poder ser discoteca';
  end if;

  select id into v_branch from public.merchant_branches where merchant_id = v_merchant.id and is_default;
  reset role;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_gerente, v_merchant.id, v_branch, 'gerente'),
    (v_cajero,  v_merchant.id, v_branch, 'cajero'),
    (v_otro,    v_otra, (select id from public.merchant_branches where merchant_id = v_otra and is_default), 'gerente');
  set local role authenticated;

  v_failed := false;
  begin
    perform public.merchant_staff_add(v_merchant.id, 'inv@prueba.helios.test', 'Clave-Segura-123',
                                      'Inventario', 'inventario');
  exception when sqlstate '22023' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'El rol inventario no debía asignarse';
  end if;

  v_j := public.admin_set_merchant_payout_account(v_merchant.id, jsonb_build_object(
    'bank', 'Banesco', 'account_holder', 'Consultorio Sol CA', 'holder_document', 'j-123456789',
    'account_number', '0134-0000-00-0000000001', 'pago_movil_phone', '0414-555.12.34',
    'pago_movil_bank', 'Banesco'));
  if v_j->>'account_number' <> '01340000000000000001'
     or v_j->>'pago_movil_phone' <> '+584145551234'
     or v_j->>'holder_document' <> 'J-123456789' then
    raise exception 'La cuenta de pago no se normalizó: %', v_j;
  end if;
  v_j := public.admin_merchant_detail(v_merchant.id);
  if v_j->'payout_account'->>'bank' <> 'Banesco'
     or v_j->'profile'->>'mpps_number' <> '12345'
     or v_j->'profile'->>'address' <> 'Chacao' then
    raise exception 'admin_merchant_detail no trae la ficha nueva: %', v_j;
  end if;
  reset role;  -- la bitácora no se lee desde la API
  if not exists (select 1 from audit.admin_actions
                 where action = 'merchant.payout_account_set' and target_id = v_merchant.id) then
    raise exception 'La cuenta de pago debía quedar en la bitácora';
  end if;
  set local role authenticated;

  -- RLS: el gerente de ESA clínica la lee; su secretaria y otra clínica, no.
  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.merchant_payout_accounts;
  if v_n <> 1 then
    raise exception 'El gerente debía ver la cuenta de su clínica, vio %', v_n;
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.merchant_payout_accounts;
  if v_n <> 0 then
    raise exception 'La secretaria no debía ver la cuenta de pago, vio %', v_n;
  end if;
  -- Y el personal no lee pacientes (H3: sin *_read_own).
  select count(*) into v_n from public.profiles;
  if v_n <> 0 then
    raise exception 'El personal no debía leer profiles, vio %', v_n;
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_otro::text, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.merchant_payout_accounts;
  if v_n <> 0 then
    raise exception 'Otra clínica no debía ver la cuenta de pago, vio %', v_n;
  end if;
  v_failed := false;
  begin
    perform public.admin_set_merchant_payout_account(v_otra, '{"account_holder":"X","holder_document":"V1","account_number":"01340000000000000001"}');
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Un gerente no debía poder escribir cuentas de pago';
  end if;
  raise notice 'TEST H8 OK — ficha médica, inventario fuera, cuenta de pago con RLS y bitácora';

  -- =========================================================================
  -- H11 — Contacto, configuración y cuentas de cobro
  -- =========================================================================

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  v_j := public.helios_config_status();
  if (v_j->>'whatsapp')::boolean or (v_j->>'remitente')::boolean then
    raise exception 'Sin configurar, whatsapp y remitente debían ser false: %', v_j;
  end if;
  if (v_j->>'resend')::boolean <> v_resend then
    raise exception 'resend debía decir si existe el secreto resend_api_key: %', v_j;
  end if;

  v_j := public.admin_set_platform_contact(jsonb_build_object(
    'whatsapp_number', '0414-000.11.22', 'support_email', 'Soporte@Helios.test',
    'sender_name', 'Helios', 'sender_email', 'hola@helios.test', 'support_hours', 'L-V 8 a 5'));
  if v_j->>'whatsapp_number' <> '+584140001122' or v_j->>'support_email' <> 'soporte@helios.test' then
    raise exception 'El contacto no se normalizó: %', v_j;
  end if;
  -- Solo cambian las claves que vienen.
  v_j := public.admin_set_platform_contact('{"support_hours": "L-S 8 a 6"}');
  if v_j->>'whatsapp_number' <> '+584140001122' or v_j->>'support_hours' <> 'L-S 8 a 6' then
    raise exception 'Una edición parcial no debía tocar lo demás: %', v_j;
  end if;

  perform public.admin_set_payment_destination('Banesco', 'J-000000001', '04141112233', 'Helios CA',
                                               null, 2, true);
  perform public.admin_set_payment_destination(null, null, null, 'Helios LLC', null, 1, true, null,
                                               'zelle', null, 'pagos@helios.test');
  v_j := public.helios_config_status();
  if not (v_j->>'whatsapp')::boolean or not (v_j->>'remitente')::boolean
     or (v_j->>'cuentas_de_cobro')::int < 2 then
    raise exception 'Configurado, el estado debía estar completo: %', v_j;
  end if;
  if public.helios_payment_accounts_text() not like '• Zelle: pagos@helios.test%' then
    raise exception 'Las cuentas debían listarse por sort_order (Zelle primero): %', public.helios_payment_accounts_text();
  end if;
  reset role;
  if (select count(*) from audit.admin_actions where action = 'platform.contact_set') < 2 then
    raise exception 'El contacto debía quedar en la bitácora';
  end if;
  set local role authenticated;

  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.admin_set_platform_contact('{"whatsapp_number": "04140000000"}');
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'El personal de una clínica no debía cambiar el contacto de Helios';
  end if;
  v_failed := false;
  begin
    perform public.helios_config_status();
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'helios_config_status es solo del equipo';
  end if;
  raise notice 'TEST H11.1 OK — contacto, estado de la configuración y varias cuentas activas';

  -- =========================================================================
  -- H11 — La cola y el comprobante
  -- =========================================================================

  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_charge := (pg_temp.prueba_cobro(v_pac, v_merchant.id, v_branch, v_cajero, 100.00, 'cimientos-1')->>'charge_id')::uuid;

  v_msg := public.helios_enqueue_charge_receipt(v_charge);
  select * into v_row from public.outbound_messages where id = v_msg;
  if v_row.channel <> 'email' or v_row.recipient <> 'jose@gmail.com' or v_row.status <> 'pendiente'
     or v_row.next_attempt_at is null or v_row.charge_id <> v_charge then
    raise exception 'El comprobante debía encolarse por correo al correo registrado: %', to_jsonb(v_row) - 'html';
  end if;
  if v_row.subject not like 'Tu financiamiento en Consultorio <Sol> & Luna — 2 cuotas de $61,60' then
    raise exception 'Asunto inesperado: %', v_row.subject;
  end if;
  if position('Monto de la consulta: $100' in v_row.rendered_text) = 0
     or position('Servicio Helios (20 % + IVA) de $23,20' in v_row.rendered_text) = 0
     or position('Cuota 2: $61,60' in v_row.rendered_text) = 0
     or position('Registró: Ana' in v_row.rendered_text) = 0
     or position('V-****5678' in v_row.rendered_text) = 0
     or position('0414-0001122' in v_row.rendered_text) = 0
     or position('Zelle: pagos@helios.test' in v_row.rendered_text) = 0 then
    raise exception 'Al comprobante le falta algo:%', v_row.rendered_text;
  end if;
  -- Ningún total que sume el fee.
  if position('123,20' in v_row.rendered_text) > 0 or position('123,20' in v_row.html) > 0 then
    raise exception 'El comprobante no puede mostrar el total con el fee (123.20)';
  end if;
  -- El HTML escapa lo que viene de los datos y no deja marcadores sin rellenar.
  if position('Consultorio &lt;Sol&gt; &amp; Luna' in v_row.html) = 0
     or position('<Sol>' in v_row.html) > 0
     or v_row.html ~ '\{[a-z_]+\}'
     or position('https://wa.me/584140001122?text=Hola%2C%20quiero' in v_row.html) = 0 then
    raise exception 'HTML mal renderizado';
  end if;

  -- Deduplicación, canal, variables que faltan.
  v_msg  := public.helios_enqueue_message('bienvenida', v_pac, v_charge, 'whatsapp_manual',
              jsonb_build_object('clinica', 'Sol', 'orden', '1', 'cuotas', '• Cuota 1'), null, 'bienvenida:' || v_charge);
  v_msg2 := public.helios_enqueue_message('bienvenida', v_pac, v_charge, 'whatsapp_manual',
              jsonb_build_object('clinica', 'Sol', 'orden', '1', 'cuotas', '• Cuota 1'), null, 'bienvenida:' || v_charge);
  if v_msg <> v_msg2 or (select count(*) from public.outbound_messages where dedupe_key = 'bienvenida:' || v_charge) <> 1 then
    raise exception 'La misma dedupe_key no debía encolar dos veces';
  end if;
  select * into v_row from public.outbound_messages where id = v_msg;
  if v_row.recipient <> '+584141234567' or v_row.rendered_text not like '🩺 ¡Listo, José! Tu financiamiento #1 ya está activo.%' then
    raise exception 'WhatsApp mal renderizado: % / %', v_row.recipient, v_row.rendered_text;
  end if;

  v_failed := false;
  begin
    perform public.helios_enqueue_message('bienvenida', v_pac, v_charge, 'email');
  exception when sqlstate '22023' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'bienvenida no sale por correo';
  end if;
  v_failed := false;
  begin
    perform public.helios_enqueue_message('bienvenida', v_pac, v_charge, 'whatsapp_manual', '{"clinica":"Sol"}');
  exception when sqlstate '22023' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Una plantilla sin sus variables no debía encolarse';
  end if;

  -- Sin correo: queda el rastro, como omitido.
  insert into public.profiles (phone_e164, full_name, document_number)
  values ('+584241234567', 'Sin Correo', 'V32345678') returning id into v_sin_mail;
  v_msg := public.helios_enqueue_message('cuota_manana', v_sin_mail, null, 'email',
             jsonb_build_object('clinica', 'Sol', 'orden', '2', 'monto_cuota', '10.00', 'fecha', '01/10/2026'));
  select * into v_row from public.outbound_messages where id = v_msg;
  if v_row.status <> 'omitido' or v_row.last_error <> 'El paciente no tiene correo' then
    raise exception 'Sin correo debía quedar omitido: % %', v_row.status, v_row.last_error;
  end if;

  -- Las plantillas de la app de Ronda están apagadas: no escriben en la bandeja.
  perform public.notify(v_pac, 'account_frozen', 't', 'b', '{}'::jsonb, 'account_frozen');
  if exists (select 1 from public.notifications where user_id = v_pac) then
    raise exception 'Los avisos de la app debían estar apagados';
  end if;

  -- La cola solo la lee el equipo; la API no puede encolar.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.outbound_messages;
  if v_n <> 0 then
    raise exception 'El personal no debía leer la cola, vio %', v_n;
  end if;
  v_failed := false;
  begin
    perform public.helios_enqueue_charge_receipt(v_charge);
  exception when insufficient_privilege then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'helios_enqueue_charge_receipt no debía estar abierta a la API';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.outbound_messages;
  if v_n < 3 then
    raise exception 'El equipo debía leer la cola, vio %', v_n;
  end if;
  reset role;
  raise notice 'TEST H11.2 OK — comprobante, WhatsApp, deduplicación, omitidos y permisos de la cola';

  raise notice '=== TODOS LOS TESTS DE LOS CIMIENTOS PASARON ===';
end $$;

set constraints all immediate;

rollback;
