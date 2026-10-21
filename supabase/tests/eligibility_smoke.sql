-- ============================================================================
-- Helios — Prueba de humo de la consulta de cédula (H4, docs/01 §1.1)
--
--   bash supabase/tests/run.sh eligibility_smoke
--
-- Cubre `helios_patient_eligibility` (20261003000400) y la tabla
-- `eligibility_lookups` (20261003000100):
--   1. Formatos de cédula y los datos del paciente conocido (completos
--      desde el 2026-10-21, más los enmascarados de antes).
--   2. «No disponible» nunca dice por qué: la misma forma y el mismo texto
--      para lista negra, expulsado, suspendido, bloqueado, moroso y cupo
--      agotado; sin WhatsApp configurado, el texto de reserva.
--   3. El límite diario por persona (parámetro) y que cada consulta queda
--      anotada con su resultado y la cédula normalizada.
--   4. Permisos: personal de otra clínica, clínica pausada, mantenimiento.
--   5. RLS: el personal no lee `profiles`, `installments`, `payment_reports`,
--      `eligibility_lookups` ni `staff_commissions` directamente; el equipo sí
--      lee las consultas.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_cajero  uuid := gen_random_uuid();
  v_cajero2 uuid := gen_random_uuid();
  v_otro    uuid := gen_random_uuid();
  v_m       uuid;
  v_otra    uuid;
  v_br      uuid;
  v_bdate   date := public.helios_business_date(now());
  v_j       jsonb;
  v_ref     jsonb;
  v_doc     text;
  v_x       uuid;
  v_n       integer;
  v_err     text;
  v_failed  boolean;
begin
  update public.platform_maintenance set is_active = false;
  update public.platform_contact set whatsapp_number = '+584240009988';

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values
    (v_cajero,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'el-cajero@prueba.helios.test', now(), now(), '{"full_name":"Eli Secretaria"}'),
    (v_cajero2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'el-cajero2@prueba.helios.test', now(), now(), '{"full_name":"Eva Secretaria"}'),
    (v_otro,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'el-otro@prueba.helios.test', now(), now(), '{"full_name":"Otro"}');

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_m    := (public.admin_create_merchant('Clínica Elegibilidad', null, 'J-500000001', 'clinica')).id;
  v_otra := (public.admin_create_merchant('Otra Elegibilidad', null, 'J-500000002', 'clinica')).id;
  reset role;
  select id into v_br from public.merchant_branches where merchant_id = v_m and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_cajero,  v_m, v_br, 'cajero'),
    (v_cajero2, v_m, v_br, 'cajero'),
    (v_otro, v_otra, (select id from public.merchant_branches where merchant_id = v_otra and is_default), 'gerente');

  -- Pacientes: uno disponible y uno por cada motivo de «no disponible».
  insert into public.profiles (phone_e164, first_name, last_name, full_name, document_number, email)
  values ('+584141234567', 'José', 'Pérez', 'José Pérez', 'V11111111', 'jose@gmail.com');
  insert into public.profiles (phone_e164, full_name, document_number, is_blacklisted, blacklist_reason)
  values ('+584141000011', 'Lista Negra', 'V11111112', true, 'Fraude');
  insert into public.profiles (phone_e164, full_name, document_number, status)
  values ('+584141000012', 'Expulsado', 'V11111113', 'expelled');
  insert into public.profiles (phone_e164, full_name, document_number, status)
  values ('+584141000013', 'Suspendido', 'V11111114', 'suspended');
  insert into public.profiles (phone_e164, full_name, document_number)
  values ('+584141000014', 'Bloqueado', 'V11111115') returning id into v_x;
  insert into public.user_blocks (user_id, reason, message, blocked_by) values (v_x, 'manual', 'Bloqueado', v_admin);
  insert into public.profiles (phone_e164, full_name, document_number)
  values ('+584141000015', 'Moroso', 'V11111116') returning id into v_x;
  perform pg_temp.prueba_cobro(v_x, v_m, v_br, v_cajero, 20, 'el-moroso');
  update public.installments set due_date = v_bdate - 2 where user_id = v_x and sequence = 1;
  insert into public.profiles (phone_e164, full_name, document_number)
  values ('+584141000016', 'Sin Cupo', 'E11111117') returning id into v_x;
  perform pg_temp.prueba_cobro(v_x, v_m, v_br, v_cajero, 145, 'el-sin-cupo');

  -- =========================================================================
  -- 1. Formatos y datos del paciente
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  foreach v_doc in array array['11111111', 'V11111111', 'v-11.111.111', ' V 011111111 '] loop
    v_j := public.helios_patient_eligibility(v_m, v_doc);
    if v_j->>'estado' <> 'disponible' then
      raise exception '«%» debía encontrar al paciente V11111111: %', v_doc, v_j;
    end if;
  end loop;
  if (v_j->>'disponible_usd')::numeric <> 150 or (v_j->>'min_charge_usd')::numeric <> 10
     or v_j->>'nombre' <> 'José Pérez'
     or v_j->>'telefono' <> '0414-1234567'
     or v_j->>'email' <> 'jose@gmail.com'
     or v_j->>'nombre_enmascarado' <> 'J*** P***'
     or v_j->>'telefono_enmascarado' <> '0414-***-**67'
     or v_j->>'email_enmascarado' <> 'j***@gmail.com' then
    raise exception 'Datos del paciente inesperados: %', v_j;
  end if;
  -- Sus datos de contacto sí (2026-10-21); nada más de él: ni el id ni el nivel.
  if v_j ? 'id' or v_j ? 'user_id' or v_j ? 'level' or v_j ? 'document_number' then
    raise exception 'La elegibilidad filtra datos del paciente: %', v_j;
  end if;

  v_j := public.helios_patient_eligibility(v_m, 'E-22.222.222');
  if v_j->>'estado' <> 'nuevo' or (v_j->>'limite_usd')::numeric <> 150 then
    raise exception 'Una cédula E desconocida debía ser nueva: %', v_j;
  end if;

  foreach v_doc in array array['X', '', 'P1234567', '12345'] loop
    v_err := null;
    begin
      perform public.helios_patient_eligibility(v_m, v_doc);
    exception when sqlstate '22023' then
      get stacked diagnostics v_err = message_text;
    end;
    if v_err is distinct from 'Cédula inválida' then
      raise exception '«%» debía ser una cédula inválida: %', v_doc, v_err;
    end if;
  end loop;
  raise notice 'TEST 1 OK — formatos de cédula y datos del paciente';

  -- =========================================================================
  -- 2. «No disponible» nunca dice por qué
  -- =========================================================================
  v_ref := null;
  foreach v_doc in array array['V11111112', 'V11111113', 'V11111114', 'V11111115', 'V11111116', 'E11111117'] loop
    v_j := public.helios_patient_eligibility(v_m, v_doc);
    if v_j->>'estado' <> 'no_disponible'
       or (select array_agg(k order by k) from jsonb_object_keys(v_j) k) <> array['estado', 'mensaje', 'whatsapp_helios']
       or v_j->>'whatsapp_helios' <> '+584240009988' then
      raise exception '% debía ser no_disponible con forma fija: %', v_doc, v_j;
    end if;
    if v_ref is not null and v_j <> v_ref then
      raise exception 'La respuesta de % es distinta de las demás (filtra el motivo): % vs %', v_doc, v_j, v_ref;
    end if;
    v_ref := v_j;
  end loop;
  if v_ref->>'mensaje' <> 'Esta persona no puede pagar en cuotas con Helios. Si tiene dudas, puede escribir a Helios al 0424-0009988.'
     or lower(v_ref->>'mensaje') ~ '(mora|lista|bloque|expuls|suspend|vencid|cupo|deuda)' then
    raise exception 'El texto neutro no es el esperado: %', v_ref->>'mensaje';
  end if;

  -- Sin WhatsApp configurado: texto de reserva y null.
  reset role;
  update public.platform_contact set whatsapp_number = null;
  set local role authenticated;
  v_j := public.helios_patient_eligibility(v_m, 'V11111112');
  if v_j->>'mensaje' <> 'Esta persona no puede pagar en cuotas con Helios. Si tiene dudas, puede escribir a Helios.'
     or v_j->'whatsapp_helios' <> 'null'::jsonb then
    raise exception 'Sin WhatsApp configurado: %', v_j;
  end if;
  raise notice 'TEST 2 OK — no disponible: misma forma y mismo texto para todos los motivos';

  -- =========================================================================
  -- 3. Límite diario y bitácora
  -- =========================================================================
  reset role;
  select count(*) into v_n from public.eligibility_lookups where staff_user_id = v_cajero;
  -- 4 + 1 + 6 + 1 (las inválidas no se anotan: el error deshace).
  if v_n <> 12 then
    raise exception 'Debía haber 12 consultas anotadas, hay %', v_n;
  end if;
  if (select array_agg(distinct result order by result) from public.eligibility_lookups where staff_user_id = v_cajero)
       <> array['disponible', 'no_disponible', 'nuevo']
     or exists (select 1 from public.eligibility_lookups where staff_user_id = v_cajero
                and (document_key !~ '^[VE][0-9]+$' or merchant_id <> v_m))
     or (select count(*) from public.eligibility_lookups
         where staff_user_id = v_cajero and document_key = 'V11111111' and result = 'disponible') <> 4 then
    raise exception 'Las consultas no quedaron anotadas con la cédula normalizada y su resultado';
  end if;

  -- El tope de hoy pasa a 13: una más y se acaba.
  insert into public.business_parameters (key, value, effective_from, note)
  values ('eligibility_lookups_per_staff_day', 13, v_bdate, 'prueba')
  on conflict (key, effective_from) do update set value = excluded.value;
  if public.helios_eligibility_lookups_per_staff_day() <> 13 then
    raise exception 'El parámetro del límite no se leyó';
  end if;

  set local role authenticated;
  perform public.helios_patient_eligibility(v_m, 'V33333333');
  v_err := null;
  begin
    perform public.helios_patient_eligibility(v_m, 'V33333334');
  exception when sqlstate '22023' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is distinct from 'Llegaste al límite de consultas de hoy. Inténtalo mañana.' then
    raise exception 'La consulta 14 debía rechazarse por el límite: %', v_err;
  end if;
  -- Otra persona del personal tiene su propio límite.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero2::text, 'role', 'authenticated')::text, true);
  v_j := public.helios_patient_eligibility(v_m, 'V33333334');
  if v_j->>'estado' <> 'nuevo' then
    raise exception 'El límite es por persona: %', v_j;
  end if;
  reset role;
  if (select count(*) from public.eligibility_lookups where staff_user_id = v_cajero) <> 13 then
    raise exception 'La consulta rechazada no debía anotarse';
  end if;
  raise notice 'TEST 3 OK — límite diario por persona y bitácora de consultas';

  -- =========================================================================
  -- 4. Permisos y estados
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_otro::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.helios_patient_eligibility(v_m, 'V11111111');
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Personal de otra clínica no consulta aquí';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero2::text, 'role', 'authenticated')::text, true);
  reset role;
  update public.merchants set status = 'terminated' where id = v_m;
  set local role authenticated;
  v_err := null;
  begin
    perform public.helios_patient_eligibility(v_m, 'V11111111');
  exception when sqlstate '55000' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is distinct from 'La clínica ya no opera con Helios' then
    raise exception 'Una clínica terminada debía dar 55000: %', v_err;
  end if;
  reset role;
  update public.merchants set status = 'active' where id = v_m;
  update public.platform_maintenance set is_active = true, blocks_balance = true,
         message = 'Mantenimiento de prueba', expected_back = 'a las 3 pm';
  set local role authenticated;
  v_err := null;
  begin
    perform public.helios_patient_eligibility(v_m, 'V11111111');
  exception when sqlstate '55000' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is distinct from 'Mantenimiento de prueba Volvemos a las 3 pm.' then
    raise exception 'El mantenimiento debía dar 55000 con su texto: %', v_err;
  end if;
  -- Un mantenimiento que no apaga no frena.
  reset role;
  update public.platform_maintenance set blocks_balance = false;
  set local role authenticated;
  perform public.helios_patient_eligibility(v_m, 'V11111111');
  reset role;
  update public.platform_maintenance set is_active = false;
  raise notice 'TEST 4 OK — otra clínica, clínica terminada y mantenimiento';

  -- =========================================================================
  -- 5. RLS: el personal no lee pacientes ni su deuda
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  if (select count(*) from public.profiles) <> 0
     or (select count(*) from public.installments) <> 0
     or (select count(*) from public.payment_reports) <> 0
     or (select count(*) from public.user_credit_blocks) <> 0
     or (select count(*) from public.eligibility_lookups) <> 0
     or (select count(*) from public.staff_commissions) <> 0
     or (select count(*) from public.profile_change_requests) <> 0
     or (select count(*) from public.outbound_messages) <> 0 then
    raise exception 'El personal no debía leer datos de pacientes directamente';
  end if;
  v_failed := false;
  begin
    insert into public.eligibility_lookups (staff_user_id, merchant_id, document_key, result)
    values (v_cajero, v_m, 'V1', 'nuevo');
  exception when insufficient_privilege then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'El personal no debía escribir en eligibility_lookups';
  end if;
  -- Ni las ayudas internas.
  v_failed := false;
  begin
    perform public.helios_not_available_message();
  exception when insufficient_privilege then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'helios_not_available_message no debía estar abierta a la API';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  if (select count(*) from public.eligibility_lookups where merchant_id = v_m) < 14 then
    raise exception 'El equipo debía leer las consultas';
  end if;
  reset role;
  raise notice 'TEST 5 OK — RLS: el personal no lee pacientes, cuotas, pagos ni consultas';

  raise notice '=== TODOS LOS TESTS DE ELEGIBILIDAD PASARON ===';
end $$;

set constraints all immediate;

rollback;
