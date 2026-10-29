-- ============================================================================
-- Helios — Prueba de humo de la secretaria que solo registra
-- (20261029160000_la_secretaria_que_solo_registra)
--
--   bash supabase/tests/run.sh secretaria_solo_registra_smoke
--
-- 1. El alta guarda `solo_registra` solo para una secretaria (un
--    administrador nunca lo es) y la lista del personal lo devuelve.
-- 2. La secretaria que solo registra no consulta el historial: las RPC del
--    historial le responden 42501 (no una lista vacía) y la ficha de la
--    orden tampoco; los renglones de la orden le salen vacíos.
-- 3. Sí ve la orden que acaba de registrar (la pantalla de espera) y sus
--    comisiones.
-- 4. La secretaria de siempre sigue viendo sus pagos en cuotas.
-- 5. «Editar»: sin el parámetro conserva lo que tenía, se puede apagar y
--    encender, y pasar a administrador lo apaga.
-- ============================================================================

begin;
-- @ayudas

do $$
declare
  v_super    uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_gerente  uuid;
  v_solo     uuid;
  v_normal   uuid;
  v_pac      uuid;
  v_charge   uuid;
  v_res      jsonb;
  v_n        integer;
  v_failed   boolean;
  v_flag     boolean;
begin
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values (v_super, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000094', now(), now(), now());
  insert into public.platform_admins (user_id, role, full_name) values (v_super, 'super_admin', 'Jefa');

  insert into public.merchants (name, tax_id) values ('Consultorio Solo Registra Prueba', 'J-509876544')
  returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;

  insert into public.profiles (phone_e164, full_name, document_number, email)
  values ('+584141230094', 'Paciente Prueba', 'V30940094', 'paciente.solo@example.com')
  returning id into v_pac;

  -- --- 1. El alta ---------------------------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- Un administrador nunca solo registra, aunque se pida.
  v_gerente := (public.merchant_staff_add(v_merchant, 'gerente.solo.prueba@example.com', 'Clave-Segura-1',
                                          'Gerente', 'gerente', null, true)->>'user_id')::uuid;

  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  v_solo   := (public.merchant_staff_add(v_merchant, 'solo.prueba@example.com', 'Clave-Segura-2',
                                         'Solo Registra', 'cajero', null, true)->>'user_id')::uuid;
  -- Sin el parámetro, como antes: ve su historial.
  v_normal := (public.merchant_staff_add(v_merchant, 'normal.prueba@example.com', 'Clave-Segura-3',
                                         'De Siempre', 'cajero')->>'user_id')::uuid;

  v_res := public.merchant_staff_list(v_merchant);
  select (r->>'solo_registra')::boolean into v_flag
  from jsonb_array_elements(v_res->'rows') r where (r->>'user_id')::uuid = v_gerente;
  if v_flag is distinct from false then
    raise exception 'Un administrador no debía quedar como «solo registra»: %', v_res;
  end if;
  select (r->>'solo_registra')::boolean into v_flag
  from jsonb_array_elements(v_res->'rows') r where (r->>'user_id')::uuid = v_solo;
  if v_flag is distinct from true then
    raise exception 'La secretaria debía quedar como «solo registra»: %', v_res;
  end if;
  select (r->>'solo_registra')::boolean into v_flag
  from jsonb_array_elements(v_res->'rows') r where (r->>'user_id')::uuid = v_normal;
  if v_flag is distinct from false then
    raise exception 'Sin el parámetro, la secretaria debía ver su historial: %', v_res;
  end if;
  raise notice 'TEST 1 OK — el alta guarda solo_registra solo para la secretaria';

  -- Una orden de cada secretaria.
  reset role;
  v_charge := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_solo, 100.00, 'solo-registra-1')->>'charge_id')::uuid;
  perform pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_normal, 30.00, 'solo-registra-2');
  set local role authenticated;

  -- --- 2. Sin historial -----------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_solo::text, 'role', 'authenticated')::text, true);
  if not public.helios_solo_registra() then
    raise exception 'helios_solo_registra debía decir true para ella';
  end if;

  v_failed := false;
  begin
    perform public.merchant_transactions(current_date - 30, current_date + 1);
  exception when sqlstate '42501' then v_failed := true;
  end;
  if not v_failed then raise exception 'merchant_transactions debía rechazarla'; end if;

  v_failed := false;
  begin
    perform public.merchant_transactions_summary(current_date - 30, current_date + 1);
  exception when sqlstate '42501' then v_failed := true;
  end;
  if not v_failed then raise exception 'merchant_transactions_summary debía rechazarla'; end if;

  v_failed := false;
  begin
    perform public.merchant_sales_by_staff(current_date - 30, current_date + 1);
  exception when sqlstate '42501' then v_failed := true;
  end;
  if not v_failed then raise exception 'merchant_sales_by_staff debía rechazarla'; end if;

  v_failed := false;
  begin
    perform public.merchant_charge_detail(v_charge);
  exception when sqlstate '42501' then v_failed := true;
  end;
  if not v_failed then raise exception 'merchant_charge_detail debía rechazarla, aun siendo su orden'; end if;

  select count(*) into v_n from public.merchant_charge_items(v_charge);
  if v_n <> 0 then raise exception 'merchant_charge_items no debía darle renglones, dio %', v_n; end if;
  raise notice 'TEST 2 OK — sin historial ni ficha de la orden';

  -- --- 3. Lo que sí ve ------------------------------------------------------
  v_res := public.helios_charge_for_staff(v_charge);
  if (v_res->>'id')::uuid is distinct from v_charge then
    raise exception 'Debía ver la orden que acaba de registrar: %', v_res;
  end if;
  perform public.merchant_commissions(current_date - 30, current_date + 1);
  perform public.merchant_commission_items(current_date - 30, current_date + 1, null);
  raise notice 'TEST 3 OK — la orden recién registrada y sus comisiones';

  -- --- 4. La secretaria de siempre -----------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_normal::text, 'role', 'authenticated')::text, true);
  if public.helios_solo_registra() then
    raise exception 'helios_solo_registra debía decir false para la secretaria de siempre';
  end if;
  select count(*) into v_n from public.merchant_transactions(current_date - 30, current_date + 1);
  if v_n <> 1 then
    raise exception 'La secretaria de siempre debía ver su pago en cuotas (y solo el suyo), vio %', v_n;
  end if;
  raise notice 'TEST 4 OK — la secretaria de siempre ve sus pagos en cuotas';

  -- --- 5. Editar --------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);

  -- Cambiar solo el nombre (sin el parámetro) no le abre el historial.
  perform public.merchant_staff_update(v_merchant, v_solo, 'Solo Registra Bis', 'cajero');
  select (r->>'solo_registra')::boolean into v_flag
  from jsonb_array_elements(public.merchant_staff_list(v_merchant)->'rows') r where (r->>'user_id')::uuid = v_solo;
  if v_flag is distinct from true then raise exception 'Sin el parámetro debía conservar solo_registra'; end if;

  perform public.merchant_staff_update(v_merchant, v_solo, 'Solo Registra Bis', 'cajero', null, false);
  select (r->>'solo_registra')::boolean into v_flag
  from jsonb_array_elements(public.merchant_staff_list(v_merchant)->'rows') r where (r->>'user_id')::uuid = v_solo;
  if v_flag is distinct from false then raise exception 'Debía poder apagarse'; end if;

  perform public.merchant_staff_update(v_merchant, v_solo, 'Solo Registra Bis', 'cajero', null, true);
  select (r->>'solo_registra')::boolean into v_flag
  from jsonb_array_elements(public.merchant_staff_list(v_merchant)->'rows') r where (r->>'user_id')::uuid = v_solo;
  if v_flag is distinct from true then raise exception 'Debía poder encenderse'; end if;

  perform public.merchant_staff_update(v_merchant, v_solo, 'Solo Registra Bis', 'gerente', null, true);
  select (r->>'solo_registra')::boolean into v_flag
  from jsonb_array_elements(public.merchant_staff_list(v_merchant)->'rows') r where (r->>'user_id')::uuid = v_solo;
  if v_flag is distinct from false then raise exception 'Al pasar a administrador debía apagarse'; end if;

  -- Y vuelve a secretaria sin el parámetro: como antes, con historial.
  perform public.merchant_staff_update(v_merchant, v_solo, 'Solo Registra Bis', 'cajero');
  select (r->>'solo_registra')::boolean into v_flag
  from jsonb_array_elements(public.merchant_staff_list(v_merchant)->'rows') r where (r->>'user_id')::uuid = v_solo;
  if v_flag is distinct from false then raise exception 'De administrador a secretaria debía volver con historial'; end if;
  raise notice 'TEST 5 OK — editar conserva, apaga, enciende y el administrador nunca solo registra';
end $$;

set constraints all immediate;

rollback;
