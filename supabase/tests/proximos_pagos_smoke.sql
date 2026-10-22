-- ============================================================================
-- Helios — Prueba de humo de los próximos pagos a una clínica
--
--   bash supabase/tests/run.sh proximos_pagos_smoke
--
-- Cubre 20261021190000 y 20261021220000:
--   1. `admin_merchant_upcoming_settlements` trae una línea por mitad de la
--      consulta que todavía no existe, con su día de pago (8 y 15), y suma lo
--      mismo que «Por pagar en los próximos días» de la previsión.
--   2. En una orden en euros, sus euros: la segunda mitad completa el neto.
--   3. La comisión del personal sale el día 8, el mismo que la primera mitad.
--   4. Cuando el cron crea la mitad, deja de ser «por vencer» y la liquidación
--      real tiene el mismo monto, en dólares y en euros.
--   5. Solo el equipo de Helios la lee.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_ana     uuid := gen_random_uuid();
  v_m       uuid;
  v_br      uuid;
  v_bdate   date := public.helios_business_date(now());
  v_ch_usd  uuid;
  v_ch_eur  uuid;
  v_j       jsonb;
  v_p       jsonb;
  v_row     record;
  v_num     numeric;
  v_failed  boolean;
begin
  update public.platform_maintenance set is_active = false;
  update public.levels set monthly_limit_usd = 150 where level = 1;
  perform public.record_fx_rate(800, v_bdate, 'BCV');
  perform public.record_fx_rate(900, v_bdate, 'BCV_EUR');

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values (v_ana, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'pp-ana@prueba.helios.test', now(), now(), '{"full_name":"Ana Secretaria"}');

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_m := (public.admin_create_merchant('Clínica Próximos', null, 'J-600000002', 'clinica')).id;
  reset role;
  select id into v_br from public.merchant_branches where merchant_id = v_m and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values (v_ana, v_m, v_br, 'cajero');

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V60000011');
  v_ch_usd := (public.create_patient_charge(v_m, null, jsonb_build_object(
    'document', 'V60000011', 'first_name', 'Carla', 'last_name', 'Rojas',
    'birth_date', '1985-05-05', 'sex', 'F', 'phone', '04121234511', 'email', 'carla.pp@correo.com',
    'state', 'Lara', 'city', 'Barquisimeto', 'address', 'Centro',
    'reference_name', 'Luis Rojas', 'reference_phone', '04241234511', 'reference_relationship', 'Hermano'),
    100, null, null, 'pp-usd')->>'id')::uuid;
  perform public.helios_patient_eligibility(v_m, 'V60000012');
  v_ch_eur := (public.create_patient_charge(v_m, null, jsonb_build_object(
    'document', 'V60000012', 'first_name', 'Rosa', 'last_name', 'Pérez',
    'birth_date', '1980-03-03', 'sex', 'F', 'phone', '04121234512', 'email', 'rosa.pp@correo.com',
    'state', 'Lara', 'city', 'Barquisimeto', 'address', 'Centro',
    'reference_name', 'Juan Pérez', 'reference_phone', '04241234512', 'reference_relationship', 'Hermano'),
    100.01, null, null, 'pp-eur', 'EUR')->>'id')::uuid;
  reset role;

  -- =========================================================================
  -- 1. Las cuatro mitades por vencer, con su día de pago y el total
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_j := public.admin_merchant_upcoming_settlements(v_m);
  reset role;
  if jsonb_array_length(v_j) <> 4
     or exists (select 1 from jsonb_array_elements(v_j) x
                where x->>'reason' <> 'scheduled_installment' or x ? 'id'
                   or (x->>'run_date')::date not in (v_bdate + 8, v_bdate + 15)
                   or (x->>'run_date')::date <> (x->>'due_date')::date + 1) then
    raise exception 'Debían salir 4 mitades por vencer, los días 8 y 15: %', v_j;
  end if;
  if (select sum((x->>'amount_usd')::numeric) from jsonb_array_elements(v_j) x where (x->>'charge_id')::uuid = v_ch_usd) <> 100
     or (select count(*) from jsonb_array_elements(v_j) x
         where (x->>'charge_id')::uuid = v_ch_usd and (x->>'amount_usd')::numeric = 50
           and x->>'currency' = 'USD' and (x->>'amount_cur')::numeric = 50
           and (x->>'pending_ves_hoy')::numeric = 40000) <> 2 then
    raise exception 'La orden en dólares: dos mitades de 50 (Bs 40.000 hoy): %', v_j;
  end if;
  select * into v_row from public.helios_settlement_outlook(v_m);
  select sum((x->>'amount_usd')::numeric) into v_num from jsonb_array_elements(v_j) x;
  if v_num <> v_row.upcoming_usd then
    raise exception 'Las mitades por vencer (%) debían sumar lo de la previsión (%)', v_num, v_row.upcoming_usd;
  end if;
  raise notice 'TEST 1 OK — cuatro mitades por vencer, días 8 y 15, mismo total que la previsión';

  -- =========================================================================
  -- 2. La orden en euros: €100,01 en dos mitades que cuadran
  -- =========================================================================
  if (select array_agg((x->>'amount_cur')::numeric order by (x->>'due_date')::date)
      from jsonb_array_elements(v_j) x where (x->>'charge_id')::uuid = v_ch_eur) <> array[50.01, 50.00]::numeric[]
     and (select array_agg((x->>'amount_cur')::numeric order by (x->>'due_date')::date)
          from jsonb_array_elements(v_j) x where (x->>'charge_id')::uuid = v_ch_eur) <> array[50.00, 50.01]::numeric[] then
    raise exception 'Las mitades en euros debían sumar €100,01: %', v_j;
  end if;
  if exists (select 1 from jsonb_array_elements(v_j) x
             where (x->>'charge_id')::uuid = v_ch_eur
               and (x->>'currency' <> 'EUR'
                    or (x->>'pending_ves_hoy')::numeric <> round((x->>'amount_cur')::numeric * 900, 2))) then
    raise exception 'Las mitades en euros se pasan a bolívares a la tasa del euro: %', v_j;
  end if;
  raise notice 'TEST 2 OK — en euros, las mitades cuadran con el neto';

  -- =========================================================================
  -- 3. La comisión sale el día 8, con la primera mitad
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  if (select count(*) from jsonb_array_elements(public.admin_merchant_settlements(v_m)) x
      where x->>'reason' = 'staff_commission' and (x->>'run_date')::date = v_bdate + 8) <> 2 then
    raise exception 'Las dos comisiones debían salir el día 8: %', public.admin_merchant_settlements(v_m);
  end if;
  -- La lista de Pagos a clínicas: el médico y el próximo pago (20261022100000),
  -- que es el del día 8 con las dos primeras mitades y las dos comisiones.
  v_p := public.admin_merchant_payables(v_m);
  select sum((x->>'amount_usd')::numeric) into v_num
  from jsonb_array_elements(public.admin_merchant_upcoming_settlements(v_m)) x
  where (x->>'run_date')::date = v_bdate + 8;
  reset role;
  if v_p->0->>'doctor_name' is distinct from public.helios_doctor_name(v_m)
     or (v_p->0->>'next_pay_date')::date is distinct from v_bdate + 8
     or (v_p->0->>'next_pay_consultas_usd')::numeric <> v_num
     or (v_p->0->>'next_pay_comisiones_usd')::numeric <> 1.00
     or (v_p->0->>'next_pay_usd')::numeric <> v_num + 1.00
     or (v_p->0->>'next_run_usd')::numeric <> 0
     or (v_p->0->>'next_run_comisiones_usd')::numeric <> 0 then
    raise exception 'El próximo pago debía ser el día 8: consultas %, comisiones 1.00: %', v_num, v_p;
  end if;
  raise notice 'TEST 3 OK — la comisión sale el día 8, con la primera mitad, y es el próximo pago';

  -- =========================================================================
  -- 4. El cron crea la mitad: deja de ser «por vencer» y vale lo mismo
  -- =========================================================================
  perform public.run_scheduled_settlements(v_bdate + 7);
  perform public.run_scheduled_settlements(v_bdate + 14);
  for v_row in
    select x from jsonb_array_elements(v_j) x
  loop
    if not exists (
      select 1 from public.settlements s
      where s.charge_id = (v_row.x->>'charge_id')::uuid and s.reason = 'scheduled_installment'
        and s.due_date = (v_row.x->>'due_date')::date
        and s.amount_usd = (v_row.x->>'amount_usd')::numeric
        and s.currency = v_row.x->>'currency'
        and s.amount_cur = (v_row.x->>'amount_cur')::numeric) then
      raise exception 'La liquidación real no coincide con la mitad por vencer %', v_row.x;
    end if;
  end loop;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  if jsonb_array_length(public.admin_merchant_upcoming_settlements(v_m)) <> 0 then
    raise exception 'Con las mitades creadas no debía quedar nada por vencer';
  end if;
  reset role;
  raise notice 'TEST 4 OK — creada la mitad, deja de ser por vencer y coincide';

  -- =========================================================================
  -- 5. Solo el equipo de Helios
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.admin_merchant_upcoming_settlements(v_m);
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  reset role;
  if not v_failed then
    raise exception 'Una secretaria no debía leer los próximos pagos del equipo';
  end if;
  raise notice 'TEST 5 OK — solo el equipo de Helios';

  raise notice '=== TODOS LOS TESTS DE PRÓXIMOS PAGOS PASARON ===';
end $$;

rollback;
