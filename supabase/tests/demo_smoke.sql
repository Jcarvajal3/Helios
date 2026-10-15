-- ============================================================================
-- Helios — Prueba de humo de los números de capacitación
--
--   bash supabase/tests/run.sh demo_smoke
--
-- Cubre 20261014100000, 20261014100200 y 20261014100300:
--   1. Alta del número: solo el super admin; ni repetido ni de un paciente
--      real.
--   2. En una clínica REAL, un paciente NUEVO con el número de capacitación
--      nace de prueba y demo, con el límite real ($150); se pueden crear
--      varios con el mismo número. Sus órdenes no devengan comisión ni
--      liquidaciones, tampoco al vencer las cuotas. Un paciente real en la
--      misma clínica sigue liquidando.
--   3. El reinicio BORRA a los pacientes y sus órdenes (20261014100300): no
--      entran al libro; esa cédula vuelve a ser «nuevo». Lo que sí tiene
--      asiento se revierte y se retira. No toca lo real; deja bitácora.
--   4. Quitar el número: lo nuevo con él ya es real. El nivel Demo ya no
--      existe y el trabajo de medianoche sí.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_cajera  uuid := gen_random_uuid();
  v_m       uuid;
  v_br      uuid;
  v_bdate   date := public.helios_business_date(now());
  v_tel     text := '+584129990101';
  v_pac_a   jsonb;
  v_pac_b   jsonb;
  v_pac_r   jsonb;
  v_ch_a    uuid;
  v_ch_b    uuid;
  v_ch_r    uuid;
  v_demo_a  uuid;
  v_j       jsonb;
  v_err     text;
begin
  update public.platform_maintenance set is_active = false;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values (v_cajera, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'demo-cajera@prueba.helios.test', now(), now(), '{"full_name":"Diana Secretaria"}');

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_m := (public.admin_create_merchant('Clínica Real Demo', null, 'J-600000099', 'clinica')).id;
  reset role;
  select id into v_br from public.merchant_branches where merchant_id = v_m and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajera, v_m, v_br, 'cajero');

  v_pac_a := jsonb_build_object(
    'document', 'V99000001', 'first_name', 'Ana', 'last_name', 'Ensayo',
    'birth_date', '1990-01-01', 'sex', 'F', 'phone', '0412 999 0101', 'email', 'ana@prueba.helios.test',
    'state', 'Lara', 'address', 'Centro');
  v_pac_b := v_pac_a || jsonb_build_object('document', 'V99000002', 'first_name', 'Beto');
  v_pac_r := v_pac_a || jsonb_build_object('document', 'V60000099', 'first_name', 'Rita',
                                           'phone', '04149990099', 'email', 'rita@correo.com');

  -- Una cajera que registra y su comisión, para ver que lo demo no la devenga.
  insert into public.business_parameters (key, value, effective_from, note)
  values ('staff_commission_usd', 0.50, v_bdate, 'prueba')
  on conflict (key, effective_from) do update set value = excluded.value;

  -- =========================================================================
  -- 1. El número
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajera::text, 'role', 'authenticated')::text, true);
  v_err := null;
  begin
    perform public.admin_add_demo_phone('0412 999 0101', 'Carla');
  exception when sqlstate '42501' then
    v_err := 'ok';
  end;
  if v_err is null then
    raise exception 'Solo un super admin añade números de capacitación';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_j := public.admin_add_demo_phone('0412 999 0101', '  Carla   Capacitadora ');
  if v_j->>'phone_e164' <> v_tel or v_j->>'label' <> 'Carla Capacitadora' then
    raise exception 'El número debía guardarse normalizado: %', v_j;
  end if;

  v_err := null;
  begin
    perform public.admin_add_demo_phone('04129990101', 'Otra vez');
  exception when sqlstate '22023' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is null or v_err not like '%ya es de capacitación%' then
    raise exception 'Un número repetido debía rechazarse: %', v_err;
  end if;
  reset role;

  insert into public.profiles (id, phone_e164, document_number) values (gen_random_uuid(), '+584149990077', 'V60000077');
  set local role authenticated;
  v_err := null;
  begin
    perform public.admin_add_demo_phone('04149990077', 'De un paciente');
  exception when sqlstate '22023' then
    get stacked diagnostics v_err = message_text;
  end;
  reset role;
  if v_err is null or v_err not like '%paciente real%' then
    raise exception 'El número de un paciente real debía rechazarse: %', v_err;
  end if;
  raise notice 'TEST 1 OK — el número de capacitación';

  -- =========================================================================
  -- 2. Pacientes nuevos con ese número, en una clínica real
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajera::text, 'role', 'authenticated')::text, true);
  v_j := public.helios_patient_eligibility(v_m, 'V99000001');
  if v_j->>'estado' <> 'nuevo' or (v_j->>'limite_usd')::numeric <> 150 then
    raise exception 'Una cédula inventada debía ser un paciente nuevo con $150: %', v_j;
  end if;
  v_ch_a := (public.create_patient_charge(v_m, null, v_pac_a, 100, null, null, 'demo-a')->>'id')::uuid;

  perform public.helios_patient_eligibility(v_m, 'V99000002');
  v_ch_b := (public.create_patient_charge(v_m, null, v_pac_b, 150, null, null, 'demo-b')->>'id')::uuid;

  perform public.helios_patient_eligibility(v_m, 'V60000099');
  v_ch_r := (public.create_patient_charge(v_m, null, v_pac_r, 50, null, null, 'demo-real')->>'id')::uuid;

  -- El segundo pago del mismo paciente: ya lo conoce y le quedan $50.
  v_j := public.helios_patient_eligibility(v_m, 'V99000001');
  reset role;
  if v_j->>'estado' <> 'disponible' or (v_j->>'disponible_usd')::numeric <> 50 then
    raise exception 'El paciente demo debía seguir con su límite real: %', v_j;
  end if;

  select user_id into v_demo_a from public.charges where id = v_ch_a;
  if (select count(*) from public.profiles
      where phone_e164 = v_tel and is_test and is_demo and level = 1 and demo_retired_at is null) <> 2 then
    raise exception 'Los dos pacientes del número debían nacer de prueba, demo y en el nivel 1';
  end if;
  if (select count(*) from public.charges where id in (v_ch_a, v_ch_b) and is_test and status = 'confirmed') <> 2 then
    raise exception 'Las órdenes demo debían estar confirmadas y marcadas de prueba';
  end if;
  if (select is_test from public.charges where id = v_ch_r)
     or (select is_demo from public.profiles p join public.charges c on c.user_id = p.id where c.id = v_ch_r) then
    raise exception 'El paciente real no debía quedar de prueba';
  end if;
  if exists (select 1 from public.staff_commissions where charge_id in (v_ch_a, v_ch_b))
     or exists (select 1 from public.settlements where charge_id in (v_ch_a, v_ch_b)) then
    raise exception 'Las órdenes demo no debían devengar comisión ni liquidación';
  end if;
  if public.helios_staff_commission_for(v_m, v_bdate) > 0 and not exists (
    select 1 from public.settlements where charge_id = v_ch_r and reason = 'staff_commission') then
    raise exception 'La orden real debía seguir devengando la comisión del personal';
  end if;

  perform public.run_scheduled_settlements(v_bdate + 7);
  perform public.run_scheduled_settlements(v_bdate + 14);
  if exists (select 1 from public.settlements s
             left join public.installments i on i.id = s.installment_id
             where s.charge_id in (v_ch_a, v_ch_b) or i.charge_id in (v_ch_a, v_ch_b)) then
    raise exception 'Al vencer las cuotas, las órdenes demo no debían liquidar nada';
  end if;
  if (select count(*) from public.settlements
      where charge_id = v_ch_r and reason = 'scheduled_installment') <> 2 then
    raise exception 'La orden real debía liquidar sus dos mitades';
  end if;
  -- 20261014100300: lo de capacitación no entra al libro.
  if exists (select 1 from ledger.transactions where reference_id in (v_ch_a, v_ch_b))
     or exists (select 1 from ledger.accounts a join public.profiles p on p.id = a.owner_id
                where p.phone_e164 = v_tel) then
    raise exception 'Las órdenes de capacitación no debían escribir en el libro';
  end if;
  if not exists (select 1 from ledger.transactions where reference_id = v_ch_r and type = 'charge') then
    raise exception 'La orden real debía seguir con su asiento';
  end if;
  if not exists (select 1 from public.outbound_messages where charge_id = v_ch_a) then
    raise exception 'La orden de capacitación debía seguir mandando su comprobante y su bienvenida';
  end if;
  raise notice 'TEST 2 OK — pacientes nuevos de prueba con el número, sin liquidar ni libro';

  -- =========================================================================
  -- 3. El reinicio retira
  -- =========================================================================
  v_err := null;
  begin
    perform public.helios_demo_reverse_charge(v_ch_r, null);
  exception when sqlstate '42501' then
    v_err := 'ok';
  end;
  if v_err is null then
    raise exception 'La reversa demo no debía aceptar una orden real';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajera::text, 'role', 'authenticated')::text, true);
  v_err := null;
  begin
    perform public.admin_reset_demo(v_tel);
  exception when sqlstate '42501' then
    v_err := 'ok';
  end;
  if v_err is null then
    raise exception 'Solo un super admin reinicia la demo';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_j := public.admin_reset_demo(v_tel);
  reset role;

  if (v_j->>'borrados')::int <> 2 or (v_j->>'ordenes_borradas')::int <> 2
     or (v_j->>'revertidas')::int <> 0 or (v_j->>'retirados')::int <> 0
     or jsonb_array_length(v_j->'sin_reiniciar') <> 0 then
    raise exception 'El reinicio debía borrar dos pacientes y sus dos órdenes: %', v_j;
  end if;
  if exists (select 1 from public.charges where id in (v_ch_a, v_ch_b))
     or exists (select 1 from public.installments where charge_id in (v_ch_a, v_ch_b))
     or exists (select 1 from public.outbound_messages where charge_id in (v_ch_a, v_ch_b))
     or exists (select 1 from public.profiles where phone_e164 = v_tel)
     or exists (select 1 from public.eligibility_lookups where document_key in ('V99000001', 'V99000002')) then
    raise exception 'De la capacitación no debía quedar nada';
  end if;
  if (select status from public.charges where id = v_ch_r) <> 'confirmed'
     or not exists (select 1 from public.installments where charge_id = v_ch_r)
     or (select document_number from public.profiles p join public.charges c on c.user_id = p.id
         where c.id = v_ch_r) is distinct from 'V60000099' then
    raise exception 'El reinicio no debía tocar la orden ni el paciente reales';
  end if;

  -- Un paciente de capacitación de ANTES (con asiento en el libro) no se
  -- borra: se revierte y se retira. Se simula marcando de capacitación a un
  -- paciente con una orden ya asentada.
  update public.profiles p set is_test = true, is_demo = true
   from public.charges c where c.id = v_ch_r and p.id = c.user_id;
  v_j := public.helios_demo_reset('+584149990099', v_admin);
  if (v_j->>'revertidas')::int <> 1 or (v_j->>'retirados')::int <> 1 or (v_j->>'borrados')::int <> 0 then
    raise exception 'Lo que tiene asiento debía revertirse y retirarse, no borrarse: %', v_j;
  end if;
  if (select status from public.charges where id = v_ch_r) <> 'reverted'
     or not exists (select 1 from ledger.transactions where idempotency_key = 'reverse_charge:' || v_ch_r)
     or exists (select 1 from public.profiles p join public.charges c on c.user_id = p.id
                where c.id = v_ch_r and (p.document_number is not null or p.demo_retired_at is null)) then
    raise exception 'La orden con asiento debía quedar revertida con su espejo y el paciente retirado';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajera::text, 'role', 'authenticated')::text, true);
  v_j := public.helios_patient_eligibility(v_m, 'V99000001');
  if v_j->>'estado' <> 'nuevo' then
    raise exception 'Tras el reinicio la cédula inventada debía volver a ser nueva: %', v_j;
  end if;
  -- Y se puede volver a usar el mismo día.
  v_ch_a := (public.create_patient_charge(v_m, null, v_pac_a, 100, null, null, 'demo-a2')->>'id')::uuid;
  if (select user_id from public.charges where id = v_ch_a) = v_demo_a then
    raise exception 'La cédula reutilizada debía ser un paciente nuevo, no el retirado';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_j := public.admin_demo_phones();
  reset role;
  if (v_j->'last_reset'->>'automatic')::boolean
     or not exists (select 1 from jsonb_array_elements(v_j->'phones') e
                    where e->>'phone_e164' = v_tel and e->>'label' = 'Carla Capacitadora'
                      and (e->>'patients')::int = 1 and (e->>'open_orders')::int = 1) then
    raise exception 'La pantalla debía decir el paciente y la orden abiertos del número: %', v_j;
  end if;
  if not exists (select 1 from audit.admin_actions where action = 'demo.reset' and actor = v_admin) then
    raise exception 'El reinicio a mano debía quedar en la bitácora';
  end if;
  raise notice 'TEST 3 OK — el reinicio borra lo de capacitación y libera la cédula';

  -- =========================================================================
  -- 4. Quitar el número, el nivel Demo y medianoche
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  perform public.admin_remove_demo_phone(v_tel);
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajera::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V99000003');
  v_ch_b := (public.create_patient_charge(v_m, null, v_pac_a || '{"document":"V99000003"}', 20, null, null, 'demo-c')->>'id')::uuid;
  reset role;
  if (select is_test from public.charges where id = v_ch_b) then
    raise exception 'Sin el número de capacitación, el paciente nuevo debía ser real';
  end if;

  if exists (select 1 from public.levels where level = 9)
     or exists (select 1 from pg_proc where proname in ('admin_create_demo_patient', 'admin_set_demo_limit', 'helios_demo_level')) then
    raise exception 'El nivel Demo y el alta a mano debían haberse ido';
  end if;

  if not exists (select 1 from cron.job where jobname = 'helios_demo_reset' and schedule = '0 4 * * *') then
    raise exception 'Falta el reinicio de medianoche';
  end if;

  perform public.helios_demo_reset();
  if not exists (select 1 from public.demo_resets where actor is null and phone_e164 is null) then
    raise exception 'El reinicio de medianoche debía quedar en demo_resets';
  end if;
  raise notice 'TEST 4 OK — quitar el número, sin nivel Demo, medianoche';
end;
$$;

set constraints all immediate;

rollback;
