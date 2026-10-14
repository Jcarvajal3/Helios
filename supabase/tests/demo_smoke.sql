-- ============================================================================
-- Helios — Prueba de humo de los pacientes demo
--
--   bash supabase/tests/run.sh demo_smoke
--
-- Cubre 20261014100000 y 20261014100100:
--   1. Alta del paciente demo: de prueba, demo y en el nivel Demo; cédula y
--      teléfono repetidos se rechazan; solo el super admin.
--   2. El nivel Demo no sale en «Niveles y cupos» ni se configura desde ahí.
--   3. En una clínica REAL: el médico lo ve disponible con el límite de demo y
--      registra; la orden es de prueba, sin comisión del personal y sin
--      liquidaciones, tampoco al vencer las cuotas. Un paciente real en la
--      misma clínica sigue liquidando.
--   4. El límite de demo frena como cualquier otro.
--   5. El reinicio revierte las órdenes demo, devuelve el límite, deja
--      bitácora y no toca las órdenes reales; la reversa demo rechaza una
--      orden real.
--   6. El límite se cambia desde la demo; el trabajo de la noche existe.
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
  v_demo    uuid;
  v_real    uuid := gen_random_uuid();
  v_ch_d1   uuid;
  v_ch_d2   uuid;
  v_ch_r    uuid;
  v_j       jsonb;
  v_err     text;
  v_comision numeric;
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

  if (select is_test from public.merchants where id = v_m) then
    raise exception 'La clínica de la prueba tenía que ser real';
  end if;

  -- =========================================================================
  -- 1. El alta
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_demo := (public.admin_create_demo_patient('V-99.000.001', 'Paciente', 'Demo Uno',
                                              '0414 111 0001', 'demo1@prueba.helios.test')->>'id')::uuid;

  v_err := null;
  begin
    perform public.admin_create_demo_patient('V99000001', 'Otra', 'Vez', '04141110002', 'otra@prueba.helios.test');
  exception when sqlstate '22023' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is null or v_err not like '%cédula%' then
    raise exception 'Una cédula repetida debía rechazarse: %', v_err;
  end if;

  v_err := null;
  begin
    perform public.admin_create_demo_patient('V99000002', 'Otra', 'Vez', '04141110001', 'otra@prueba.helios.test');
  exception when sqlstate '22023' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is null or v_err not like '%teléfono%' then
    raise exception 'Un teléfono repetido debía rechazarse: %', v_err;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_cajera::text, 'role', 'authenticated')::text, true);
  v_err := null;
  begin
    perform public.admin_create_demo_patient('V99000003', 'Otra', 'Vez', '04141110003', 'otra@prueba.helios.test');
  exception when sqlstate '42501' then
    v_err := 'ok';
  end;
  if v_err is null then
    raise exception 'Solo un super admin crea pacientes demo';
  end if;
  reset role;

  if not exists (select 1 from public.profiles
                 where id = v_demo and is_test and is_demo and level = 9 and status = 'active'
                   and document_key = 'V99000001' and phone_e164 = '+584141110001') then
    raise exception 'El paciente demo nació mal: %', (select to_jsonb(p) from public.profiles p where p.id = v_demo);
  end if;

  begin
    update public.profiles set is_test = false where id = v_demo;
    raise exception 'Un demo no puede dejar de ser de prueba';
  exception when check_violation then
    null;
  end;
  raise notice 'TEST 1 OK — alta del paciente demo';

  -- =========================================================================
  -- 2. El nivel Demo, fuera de «Niveles y cupos»
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.admin_level_config() where level = 9) then
    raise exception 'El nivel Demo no debía salir en Niveles y cupos';
  end if;
  v_err := null;
  begin
    perform public.admin_set_level_config(9::smallint, 3000, 0, 0::smallint, true);
  exception when sqlstate '22023' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is null or v_err not like '%Pacientes demo%' then
    raise exception 'El nivel Demo no debía configurarse desde Niveles: %', v_err;
  end if;
  reset role;
  raise notice 'TEST 2 OK — el nivel Demo no se toca desde Niveles';

  -- =========================================================================
  -- 3. En una clínica real: sin liquidaciones ni comisión
  -- =========================================================================
  insert into public.business_parameters (key, value, effective_from, note)
  values ('staff_commission_usd', 0.50, v_bdate, 'prueba')
  on conflict (key, effective_from) do update set value = excluded.value;
  v_comision := public.helios_staff_commission_for(v_m, v_bdate);

  insert into public.profiles (id, phone_e164) values (v_real, '+584149990099');
  update public.profiles
     set document_number = 'V60000099', first_name = 'Rita', last_name = 'Real', full_name = 'Rita Real',
         email = 'rita@correo.com'
   where id = v_real;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajera::text, 'role', 'authenticated')::text, true);
  v_j := public.helios_patient_eligibility(v_m, 'V99000001');
  if v_j->>'estado' <> 'disponible' or (v_j->>'disponible_usd')::numeric <> 3000 then
    raise exception 'El demo debía estar disponible con $3.000: %', v_j;
  end if;
  v_ch_d1 := (public.create_patient_charge(v_m, null, '{"document":"V99000001"}', 100, null, null, 'demo-1')->>'id')::uuid;

  perform public.helios_patient_eligibility(v_m, 'V60000099');
  v_ch_r := (public.create_patient_charge(v_m, null, '{"document":"V60000099"}', 50, null, null, 'demo-real')->>'id')::uuid;
  reset role;

  if not (select is_test from public.charges where id = v_ch_d1 and status = 'confirmed') then
    raise exception 'La orden demo debía estar confirmada y marcada de prueba';
  end if;
  if (select is_test from public.charges where id = v_ch_r) then
    raise exception 'La orden real no debía quedar de prueba';
  end if;
  if exists (select 1 from public.staff_commissions where charge_id = v_ch_d1)
     or exists (select 1 from public.settlements where charge_id = v_ch_d1) then
    raise exception 'La orden demo no debía devengar comisión ni liquidación';
  end if;
  if v_comision > 0 and not exists (
    select 1 from public.settlements where charge_id = v_ch_r and reason = 'staff_commission') then
    raise exception 'La orden real debía seguir devengando la comisión del personal';
  end if;

  perform public.run_scheduled_settlements(v_bdate + 7);
  perform public.run_scheduled_settlements(v_bdate + 14);
  if exists (select 1 from public.settlements s
             left join public.installments i on i.id = s.installment_id
             where s.charge_id = v_ch_d1 or i.charge_id = v_ch_d1) then
    raise exception 'Al vencer las cuotas, la orden demo no debía liquidar nada';
  end if;
  if (select count(*) from public.settlements
      where charge_id = v_ch_r and reason = 'scheduled_installment') <> 2 then
    raise exception 'La orden real debía liquidar sus dos mitades';
  end if;
  raise notice 'TEST 3 OK — clínica real: la orden demo no liquida, la real sí';

  -- =========================================================================
  -- 4. El límite de demo frena
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajera::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V99000001');
  v_ch_d2 := (public.create_patient_charge(v_m, null, '{"document":"V99000001"}', 2800, null, null, 'demo-2')->>'id')::uuid;
  v_err := null;
  begin
    perform public.create_patient_charge(v_m, null, '{"document":"V99000001"}', 200, null, null, 'demo-3');
  exception when sqlstate '22023' then
    get stacked diagnostics v_err = message_text;
  end;
  reset role;
  if v_err is null or v_err not like '%supera lo disponible%' then
    raise exception 'Pasado el límite de demo debía frenar: %', v_err;
  end if;
  raise notice 'TEST 4 OK — el límite de demo frena';

  -- =========================================================================
  -- 5. El reinicio
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
    perform public.admin_reset_demo(null);
  exception when sqlstate '42501' then
    v_err := 'ok';
  end;
  if v_err is null then
    raise exception 'Solo un super admin reinicia la demo';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_j := public.admin_reset_demo(null);
  reset role;

  if (v_j->>'revertidas')::int <> 2 or jsonb_array_length(v_j->'sin_reiniciar') <> 0 then
    raise exception 'El reinicio debía revertir las dos órdenes demo: %', v_j;
  end if;
  if (select count(*) from public.charges where id in (v_ch_d1, v_ch_d2) and status = 'reverted') <> 2
     or exists (select 1 from public.installments where charge_id in (v_ch_d1, v_ch_d2)) then
    raise exception 'Las órdenes demo debían quedar revertidas y sin cuotas';
  end if;
  if (select status from public.charges where id = v_ch_r) <> 'confirmed'
     or not exists (select 1 from public.installments where charge_id = v_ch_r) then
    raise exception 'El reinicio no debía tocar la orden real';
  end if;
  if public.helios_credit_used_usd(v_demo) <> 0 then
    raise exception 'Tras el reinicio el demo debía tener todo su límite';
  end if;
  if not exists (select 1 from ledger.transactions where idempotency_key = 'reverse_charge:' || v_ch_d1) then
    raise exception 'La reversa demo debía dejar su asiento espejo';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_j := public.admin_demo_patients();
  if jsonb_array_length(v_j->'patients') < 1
     or (v_j->'last_reset'->>'automatic')::boolean
     or not exists (select 1 from jsonb_array_elements(v_j->'patients') e
                    where (e->>'id')::uuid = v_demo and (e->>'available_usd')::numeric = 3000
                      and (e->>'open_orders')::int = 0) then
    raise exception 'La pantalla de la demo debía decir el límite entero y el último reinicio: %', v_j;
  end if;

  -- Un segundo reinicio no encuentra nada.
  v_j := public.admin_reset_demo(v_demo);
  if (v_j->>'revertidas')::int <> 0 then
    raise exception 'Un segundo reinicio no debía revertir nada: %', v_j;
  end if;
  raise notice 'TEST 5 OK — el reinicio revierte lo demo y nada más';

  -- =========================================================================
  -- 6. El límite y el trabajo de la noche
  -- =========================================================================
  perform public.admin_set_demo_limit(500);
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajera::text, 'role', 'authenticated')::text, true);
  v_j := public.helios_patient_eligibility(v_m, 'V99000001');
  reset role;
  if (v_j->>'disponible_usd')::numeric <> 500 then
    raise exception 'El límite de demo nuevo debía leerse al consultar: %', v_j;
  end if;

  if not exists (select 1 from cron.job where jobname = 'helios_demo_reset' and schedule = '30 3 * * *') then
    raise exception 'Falta el reinicio de cada noche';
  end if;

  v_j := public.helios_demo_reset();
  if not exists (select 1 from public.demo_resets where actor is null and user_id is null) then
    raise exception 'El reinicio automático debía quedar en demo_resets';
  end if;
  if not exists (select 1 from audit.admin_actions where action = 'demo.reset' and actor = v_admin) then
    raise exception 'El reinicio a mano debía quedar en la bitácora';
  end if;
  raise notice 'TEST 6 OK — el límite se cambia y la noche reinicia';
end;
$$;

set constraints all immediate;
rollback;
