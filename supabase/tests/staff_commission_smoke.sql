-- ============================================================================
-- Helios — Prueba de humo de la comisión de la secretaria (H5, docs/00 §6)
--
--   bash supabase/tests/run.sh staff_commission_smoke
--
-- Cubre 20261003000200…000600:
--   1. Devengo al registrar: asiento Dr commission_expense / Cr
--      merchant_payable, liquidación `staff_commission` del mismo día y la
--      fila en `staff_commissions`.
--   2. El monto: el parámetro global vs. el pactado con la clínica, con su
--      vigencia; 0 = sin comisión; la instantánea no se recalcula.
--   3. El cierre del lunes la incluye y el cron de las cuotas no le resta la
--      comisión a la mitad de la clínica.
--   4. La transferencia: parcial (la comisión sigue devengada) y entera
--      (pasa a pagada); el reparto consultas / comisiones; lo que ve la
--      clínica (`merchant_commissions`, `merchant_commission_items`, ventas por
--      persona) y el equipo (detalle y lista de transferencias).
--   5. La reversa antes de pagar revierte la comisión; después, se bloquea.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_gerente uuid := gen_random_uuid();
  v_ana     uuid := gen_random_uuid();
  v_bea     uuid := gen_random_uuid();
  v_m       uuid;
  v_br      uuid;
  v_bdate   date := public.helios_business_date(now());
  v_ch_a    uuid;
  v_ch_b    uuid;
  v_ch_c    uuid;
  v_ch_d    uuid;
  v_set_a   uuid;
  v_set_b   uuid;
  v_set_c   uuid;
  v_inst_a  uuid;
  v_payout  uuid;
  v_j       jsonb;
  v_row     record;
  v_n       integer;
  v_num     numeric;
  v_err     text;
  v_failed  boolean;
  v_pac     jsonb;
begin
  update public.platform_maintenance set is_active = false;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values
    (v_gerente, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'sc-gerente@prueba.helios.test', now(), now(), '{"full_name":"Gabriel Gerente"}'),
    (v_ana, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'sc-ana@prueba.helios.test', now(), now(), '{"full_name":"Ana Secretaria"}'),
    (v_bea, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'sc-bea@prueba.helios.test', now(), now(), '{"full_name":"Bea Secretaria"}');

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_m := (public.admin_create_merchant('Clínica Comisiones', null, 'J-600000001', 'clinica')).id;
  reset role;
  select id into v_br from public.merchant_branches where merchant_id = v_m and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_gerente, v_m, v_br, 'gerente'),
    (v_ana, v_m, v_br, 'cajero'),
    (v_bea, v_m, v_br, 'cajero');

  v_pac := jsonb_build_object(
    'document', 'V60000001', 'first_name', 'Carla', 'last_name', 'Rojas',
    'birth_date', '1985-05-05', 'sex', 'F', 'phone', '04121234567', 'email', 'carla@correo.com',
    'state', 'Lara', 'city', 'Barquisimeto', 'address', 'Centro',
    'reference_name', 'Luis Rojas', 'reference_phone', '04241234567', 'reference_relationship', 'Hermano');

  -- =========================================================================
  -- 1. Devengo al registrar (global: $0,50)
  -- =========================================================================
  if public.helios_staff_commission_for(v_m, v_bdate) <> 0.50 then
    raise exception 'La comisión de partida debía ser el global 0.50';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V60000001');
  v_ch_a := (public.create_patient_charge(v_m, null, v_pac, 100, null, null, 'sc-a')->>'id')::uuid;
  reset role;

  select sc.settlement_id into v_set_a from public.staff_commissions sc
  where sc.charge_id = v_ch_a and sc.staff_user_id = v_ana and sc.amount_usd = 0.50
    and sc.status = 'devengada' and sc.merchant_id = v_m;
  if v_set_a is null then
    raise exception 'La comisión de A no se devengó';
  end if;
  select * into v_row from public.settlements where id = v_set_a;
  if v_row.reason <> 'staff_commission' or v_row.amount_usd <> 0.50 or v_row.due_date <> v_bdate
     or v_row.business_date <> v_bdate or v_row.status <> 'pending' or v_row.charge_id <> v_ch_a then
    raise exception 'Liquidación de la comisión inesperada: %', to_jsonb(v_row);
  end if;
  select sum(e.debit) filter (where a.account_type = 'commission_expense' and a.owner_id is null)
    into v_num
  from ledger.transactions t
  join ledger.entries e on e.transaction_id = t.id
  join ledger.accounts a on a.id = e.account_id
  where t.idempotency_key = 'staff_commission:' || v_ch_a and t.type = 'staff_commission';
  if v_num is distinct from 0.50 then
    raise exception 'El asiento de la comisión debía cargar 0.50 a commission_expense';
  end if;
  if (select sum(e.credit) - sum(e.debit) from ledger.entries e join ledger.accounts a on a.id = e.account_id
      where a.account_type = 'merchant_payable' and a.owner_id = v_m) <> 100.50 then
    raise exception 'A la clínica se le debían 100 de la consulta + 0.50 de comisión';
  end if;
  -- Idempotente.
  if public.helios_accrue_staff_commission(v_ch_a) <> (select id from public.staff_commissions where charge_id = v_ch_a)
     or (select count(*) from public.settlements where charge_id = v_ch_a and reason = 'staff_commission') <> 1 then
    raise exception 'Devengar dos veces no debía duplicar nada';
  end if;
  raise notice 'TEST 1 OK — devengo: asiento, liquidación del día y fila de comisión';

  -- =========================================================================
  -- 2. Global vs. pactado con la clínica, con vigencia
  -- =========================================================================
  -- El global sube hoy a 0.75.
  insert into public.business_parameters (key, value, effective_from, note)
  values ('staff_commission_usd', 0.75, v_bdate, 'prueba')
  on conflict (key, effective_from) do update set value = excluded.value;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_bea::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V60000001');
  v_ch_b := (public.create_patient_charge(v_m, null, '{"document":"V60000001"}', 50, null, null, 'sc-b')->>'id')::uuid;
  reset role;
  if (select staff_commission_usd from public.charges where id = v_ch_b) <> 0.75
     or (select amount_usd from public.staff_commissions where charge_id = v_ch_b) <> 0.75
     or (select staff_commission_usd from public.charges where id = v_ch_a) <> 0.50 then
    raise exception 'B debía llevar el global nuevo (0.75) y A conservar su instantánea (0.50)';
  end if;
  select settlement_id into v_set_b from public.staff_commissions where charge_id = v_ch_b;

  -- La clínica pacta 0.30 desde hoy y 1.00 desde dentro de 3 días.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_j := public.admin_set_settlement_terms(v_m, 0, 50, 0, 'scheduled', null, 'pacto', 0.30);
  if (v_j->>'staff_commission_usd')::numeric <> 0.30 then
    raise exception 'admin_set_settlement_terms no devolvió la comisión: %', v_j;
  end if;
  perform public.admin_set_settlement_terms(v_m, 0, 50, 0, 'scheduled', v_bdate + 3, null, 1.00);
  reset role;
  if public.helios_staff_commission_for(v_m, v_bdate) <> 0.30
     or public.helios_staff_commission_for(v_m, v_bdate + 3) <> 1.00
     or public.helios_staff_commission_for(v_m, v_bdate + 2) <> 0.30 then
    raise exception 'La comisión pactada no respeta la vigencia';
  end if;
  set local role authenticated;
  foreach v_num in array array[-1, 0.333, 101]::numeric[] loop
    v_failed := false;
    begin
      perform public.admin_set_settlement_terms(v_m, 0, 50, 0, 'scheduled', null, null, v_num);
    exception when sqlstate '22023' then
      v_failed := true;
    end;
    if not v_failed then
      raise exception 'Una comisión de % debía rechazarse', v_num;
    end if;
  end loop;
  -- La firma vieja de 5 argumentos sigue funcionando (y deja la global).
  perform public.admin_set_settlement_terms(v_m, 0::numeric, 50::numeric, 0::numeric, 'scheduled'::public.settlement_policy);
  reset role;
  if public.helios_staff_commission_for(v_m, v_bdate) <> 0.75 then
    raise exception 'Sin comisión pactada debía usarse la global (0.75)';
  end if;
  set local role authenticated;
  perform public.admin_set_settlement_terms(v_m, 0, 50, 0, 'scheduled', null, 'pacto', 0.30);

  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.admin_set_settlement_terms(v_m, 0, 50, 0, 'scheduled', null, null, 5);
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'La clínica no pacta su propia comisión';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  v_ch_c := (public.create_patient_charge(v_m, null, '{"document":"V60000001"}', 50, null, null, 'sc-c')->>'id')::uuid;
  reset role;
  if (select amount_usd from public.staff_commissions where charge_id = v_ch_c) <> 0.30 then
    raise exception 'C debía llevar la comisión pactada (0.30)';
  end if;
  select settlement_id into v_set_c from public.staff_commissions where charge_id = v_ch_c;
  if not exists (select 1 from audit.admin_actions where action = 'merchant.set_terms' and target_id = v_m
                 and (detail->>'to_staff_commission_usd')::numeric = 0.30) then
    raise exception 'La comisión pactada debía quedar en la bitácora';
  end if;

  -- Pactada en 0: sin comisión.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  perform public.admin_set_settlement_terms(v_m, 0, 50, 0, 'scheduled', null, 'sin comisión', 0);
  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  v_j := public.create_patient_charge(v_m, null, '{"document":"V60000001"}', 20, null, null, 'sc-d');
  v_ch_d := (v_j->>'id')::uuid;
  reset role;
  if v_j->'staff_commission_usd' <> 'null'::jsonb
     or exists (select 1 from public.staff_commissions where charge_id = v_ch_d)
     or exists (select 1 from public.settlements where charge_id = v_ch_d and reason = 'staff_commission')
     or exists (select 1 from ledger.transactions where idempotency_key = 'staff_commission:' || v_ch_d) then
    raise exception 'Con la comisión pactada en 0 no se devenga nada';
  end if;
  raise notice 'TEST 2 OK — global vs. pactada con vigencia, 0 = sin comisión, instantánea';

  -- =========================================================================
  -- 3. El cierre del lunes
  -- =========================================================================
  -- 0.50 + 0.75 + 0.30, todas del día: entran en el primer lunes después.
  select * into v_row from public.helios_settlement_outlook(v_m);
  -- Si hoy fuese lunes, el cierre de hoy ya no las recoge: van al siguiente.
  v_num := 0;
  if v_row.next_run_date > v_bdate then
    v_num := 1.55;
  end if;
  if v_row.accrued_comisiones_usd <> 1.55 or v_row.accrued_consultas_usd <> 0
     or v_row.next_run_comisiones_usd <> v_num
     or v_row.upcoming_usd <> 220 then
    raise exception 'Previsión inesperada: %', to_jsonb(v_row);
  end if;
  if public.helios_settlement_run_for(v_bdate) <= v_bdate
     or extract(isodow from public.helios_settlement_run_for(v_bdate)) <> 1 then
    raise exception 'La comisión debía caer en el lunes siguiente al alta';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_j := public.admin_merchant_settlements(v_m, public.helios_settlement_run_for(v_bdate));
  select count(*) into v_n from jsonb_array_elements(v_j) x where x->>'reason' = 'staff_commission';
  if v_n <> 3 then
    raise exception 'El cierre del lunes debía traer las 3 comisiones: %', v_j;
  end if;
  v_j := public.admin_merchant_payables(v_m);
  if (v_j->0->>'comisiones_usd')::numeric <> 1.55 or (v_j->0->>'consultas_usd')::numeric <> 0 then
    raise exception 'admin_merchant_payables debía partir consultas y comisiones: %', v_j;
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  v_j := public.merchant_settlement_outlook();
  if (v_j->>'comisiones_usd')::numeric <> 1.55 or not v_j ? 'next_run_consultas_usd'
     or not v_j ? 'next_run_comisiones_usd' then
    raise exception 'merchant_settlement_outlook sin el reparto: %', v_j;
  end if;
  reset role;

  -- El cron de las cuotas: la mitad de A es 50, no 49.50.
  perform public.run_scheduled_settlements(v_bdate + 7);
  select id, amount_usd into v_inst_a, v_num from public.settlements
  where charge_id = v_ch_a and reason = 'scheduled_installment' and business_date = v_bdate + 7;
  if v_num is distinct from 50.00 then
    raise exception 'La primera mitad de A debía ser 50.00, fue %', v_num;
  end if;
  perform public.run_scheduled_settlements(v_bdate + 14);
  if (select sum(amount_usd) from public.settlements where charge_id = v_ch_a and reason = 'scheduled_installment') <> 100 then
    raise exception 'Las dos mitades de A debían sumar su neto (100)';
  end if;
  raise notice 'TEST 3 OK — el lunes incluye la comisión y las mitades no la descuentan';

  -- =========================================================================
  -- 4. Transferencias
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  -- Parcial: 0.20 de los 0.50 de A.
  v_j := public.admin_report_merchant_payout(v_m, array[v_set_a], 'zelle', 'Z-1', null, null, null, 0.20);
  if (v_j->>'comisiones_usd')::numeric <> 0.20 or (v_j->>'consultas_usd')::numeric <> 0 then
    raise exception 'La parcial debía ser toda comisión: %', v_j;
  end if;
  reset role;
  if (select status from public.settlements where id = v_set_a) <> 'partial'
     or (select status from public.staff_commissions where charge_id = v_ch_a) <> 'devengada' then
    raise exception 'Con un pago parcial la comisión sigue devengada';
  end if;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  select * into v_row from public.merchant_commissions(v_bdate, v_bdate) mc where mc.staff_user_id = v_ana;
  if v_row.paid_usd <> 0.20 or v_row.pending_usd <> 0.60 or v_row.amount_usd <> 0.80 or v_row.charge_count <> 2 then
    raise exception 'merchant_commissions con un pago parcial: %', to_jsonb(v_row);
  end if;

  -- El resto de A, la de B y la primera mitad de A, en una transferencia.
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_j := public.admin_report_merchant_payout(v_m, array[v_set_a, v_set_b, v_inst_a], 'zelle', 'Z-2');
  v_payout := (v_j->>'payout_id')::uuid;
  if (v_j->>'amount_usd')::numeric <> 51.05 or (v_j->>'consultas_usd')::numeric <> 50
     or (v_j->>'comisiones_usd')::numeric <> 1.05 then
    raise exception 'Reparto de la transferencia inesperado: %', v_j;
  end if;
  v_j := public.admin_payout_detail(v_payout);
  if (v_j->>'consultas_usd')::numeric <> 50 or (v_j->>'comisiones_usd')::numeric <> 1.05
     or (select count(*) from jsonb_array_elements(v_j->'items') x
         where x->>'reason' = 'staff_commission' and x->>'staff_name' in ('Ana Secretaria', 'Bea Secretaria')) <> 2
     or (select count(*) from jsonb_array_elements(v_j->'items') x where x->>'reason' = 'scheduled_installment') <> 1 then
    raise exception 'admin_payout_detail sin el reparto: %', v_j;
  end if;
  v_j := public.admin_merchant_payouts(v_m);
  if (select count(*) from jsonb_array_elements(v_j) x
      where x->>'id' = v_payout::text and (x->>'comisiones_usd')::numeric = 1.05
        and (x->>'consultas_usd')::numeric = 50) <> 1 then
    raise exception 'admin_merchant_payouts sin el reparto: %', v_j;
  end if;
  reset role;
  if (select status from public.staff_commissions where charge_id = v_ch_a) <> 'pagada'
     or (select status from public.staff_commissions where charge_id = v_ch_b) <> 'pagada'
     or (select status from public.staff_commissions where charge_id = v_ch_c) <> 'devengada' then
    raise exception 'A y B debían quedar pagadas y C devengada';
  end if;

  -- Lo que ve la clínica.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.merchant_commissions(v_bdate, v_bdate);
  if v_n <> 2 then
    raise exception 'El gerente debía ver las comisiones de las dos secretarias, vio %', v_n;
  end if;
  select * into v_row from public.merchant_commissions(v_bdate, v_bdate) mc where mc.staff_user_id = v_ana;
  if v_row.amount_usd <> 0.80 or v_row.paid_usd <> 0.50 or v_row.pending_usd <> 0.30 or v_row.staff_name <> 'Ana Secretaria' then
    raise exception 'Comisiones de Ana: %', to_jsonb(v_row);
  end if;
  select * into v_row from public.merchant_commission_items(v_bdate, v_bdate) i where i.charge_id = v_ch_a;
  if v_row.status <> 'pagada' or v_row.payout_id is null or v_row.paid_on <> v_bdate
     or v_row.staff_user_id <> v_ana or v_row.staff_name <> 'Ana Secretaria' or v_row.amount_usd <> 0.50 then
    raise exception 'merchant_commission_items de A: %', to_jsonb(v_row);
  end if;
  if (select count(*) from public.merchant_commission_items(v_bdate, v_bdate, v_bea)) <> 1 then
    raise exception 'El filtro por persona no funciona';
  end if;
  -- Ventas por persona con su comisión.
  v_j := public.merchant_sales_by_staff(v_bdate, v_bdate);
  if (select (x->>'commission_usd')::numeric from jsonb_array_elements(v_j->'rows') x where x->>'user_id' = v_ana::text) <> 0.80
     or (select (x->>'commission_usd')::numeric from jsonb_array_elements(v_j->'rows') x where x->>'user_id' = v_bea::text) <> 0.75 then
    raise exception 'merchant_sales_by_staff sin la comisión: %', v_j;
  end if;
  -- El gerente lee sus transferencias con el reparto y el motivo de cada línea.
  if (select comisiones_usd from public.merchant_payouts where id = v_payout) <> 1.05
     or (select count(*) from public.merchant_payout_items it join public.settlements s on s.id = it.settlement_id
         where it.payout_id = v_payout and s.reason = 'staff_commission') <> 2 then
    raise exception 'El gerente debía leer la transferencia partida y sus líneas';
  end if;

  -- Bea solo ve lo suyo.
  perform set_config('request.jwt.claims', json_build_object('sub', v_bea::text, 'role', 'authenticated')::text, true);
  if (select count(*) from public.merchant_commissions(v_bdate, v_bdate)) <> 1
     or (select staff_user_id from public.merchant_commissions(v_bdate, v_bdate)) <> v_bea
     or (select count(*) from public.merchant_commission_items(v_bdate, v_bdate)) <> 1
     or (select count(*) from public.merchant_commission_items(v_bdate, v_bdate, v_ana)) <> 0
     or (select count(*) from public.staff_commissions) <> 0
     or (select count(*) from public.merchant_payouts) <> 0 then
    raise exception 'Una secretaria solo ve sus comisiones (y no lee las tablas)';
  end if;
  reset role;
  raise notice 'TEST 4 OK — transferencia parcial y entera, reparto y lo que ve la clínica';

  -- =========================================================================
  -- 5. Reversa
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_j := public.admin_reverse_charge(v_ch_c, 'La consulta no se prestó');
  if (v_j->>'staff_commission_reverted_usd')::numeric <> 0.30 then
    raise exception 'La reversa debía decir la comisión revertida: %', v_j;
  end if;
  reset role;
  if (select status from public.staff_commissions where charge_id = v_ch_c) <> 'revertida'
     or (select settlement_id from public.staff_commissions where charge_id = v_ch_c) is not null
     or exists (select 1 from public.settlements where id = v_set_c)
     or (select status from public.charges where id = v_ch_c) <> 'reverted' then
    raise exception 'La reversa debía revertir la comisión y borrar su liquidación pendiente';
  end if;
  if (select sum(e.debit) - sum(e.credit)
      from ledger.transactions t join ledger.entries e on e.transaction_id = t.id
      join ledger.accounts a on a.id = e.account_id
      where t.reference_id = v_ch_c and a.account_type = 'commission_expense') <> 0
     or (select sum(e.debit) - sum(e.credit)
      from ledger.transactions t join ledger.entries e on e.transaction_id = t.id
      where t.reference_id = v_ch_c) <> 0 then
    raise exception 'El espejo de la reversa debía dejar la comisión de C en cero';
  end if;

  set local role authenticated;
  v_err := null;
  begin
    perform public.admin_reverse_charge(v_ch_b, 'Ya pagada');
  exception when sqlstate '22023' then
    get stacked diagnostics v_err = message_text;
  end;
  if v_err is distinct from 'No se puede revertir: al local ya se le transfirió su parte.' then
    raise exception 'Con la comisión ya pagada la reversa debía bloquearse: %', v_err;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  select * into v_row from public.merchant_commissions(v_bdate, v_bdate) mc where mc.staff_user_id = v_ana;
  if v_row.amount_usd <> 0.50 or v_row.pending_usd <> 0 or v_row.charge_count <> 1 then
    raise exception 'La revertida no debía contar: %', to_jsonb(v_row);
  end if;
  if (select status from public.merchant_commission_items(v_bdate, v_bdate) i where i.charge_id = v_ch_c) <> 'revertida' then
    raise exception 'El detalle debía mostrar la comisión revertida';
  end if;
  reset role;

  -- Todo el libro cuadra.
  if (select sum(debit) - sum(credit) from ledger.entries) <> 0 then
    raise exception 'El libro no cuadra';
  end if;
  raise notice 'TEST 5 OK — la reversa revierte la comisión antes de pagarse y se bloquea después';

  raise notice '=== TODOS LOS TESTS DE COMISIONES PASARON ===';
end $$;

set constraints all immediate;

rollback;
