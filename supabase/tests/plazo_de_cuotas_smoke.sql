-- ============================================================================
-- Helios — Prueba de humo del plazo de las cuotas (2026-11-06)
--
--   bash supabase/tests/run.sh plazo_de_cuotas_smoke
--
-- Cubre 20261106220000 y 20261106220100. Las cuotas del paciente pasan a +14 y
-- +28 días y la clínica sigue cobrando a los días 8 y 15, con su propia fecha:
--   1. Las funciones de las fechas: el intervalo vigente en la fecha de la orden.
--   2. Orden nueva: vence a +14/+28 y se devenga a la clínica a +7/+14; lo que ve
--      la clínica (crear, vista previa, plan).
--   3. El trigger: pone la fecha si viene vacía y no se cuela un null.
--   4. Lo que se prevé pagarle a la clínica, antes de devengarse.
--   5. Lo que ve la clínica de su orden: cada fecha de quien es.
--   6. La comisión del personal: día 8, con la primera mitad.
--   7. El cron: +7 y +14, sin duplicar, y +28 no crea una tercera.
--   8. Después del cron: la previsión queda en cero y el pago del paciente se
--      cruza con su mitad.
--   9. Orden de antes del corte: conserva +7/+14 aunque se finalice hoy.
--
-- Pasa con y sin 20261106220100: fija aquí el parámetro con el corte real.
-- ============================================================================

begin;

-- @ayudas

insert into public.business_parameters (key, value, effective_from, note)
values ('installment_interval_days', 14, '2026-11-06', 'pruebas (rollback)')
on conflict (key, effective_from) do update set value = 14;

do $$
declare
  v_admin   uuid;
  v_gerente uuid := gen_random_uuid();
  v_ana     uuid := gen_random_uuid();
  v_m       uuid;
  v_br      uuid;
  v_bdate   date := public.helios_business_date(now());
  v_viejo   date := '2026-10-01';
  v_ch      uuid;
  v_ch_pend uuid;
  v_ch_vie  uuid;
  v_pac     uuid;
  v_i1      public.installments%rowtype;
  v_i2      public.installments%rowtype;
  v_r       jsonb;
  v_j       jsonb;
  v_row     record;
  v_b       jsonb;
  v_n       integer;
  v_num     numeric;
  v_falla   boolean;
  v_d1      date;
  v_d2      date;
begin
  update public.platform_maintenance set is_active = false;
  update public.levels set monthly_limit_usd = 500 where level = 1;
  perform public.record_fx_rate(800, v_bdate, 'BCV');
  perform public.record_fx_rate(900, v_bdate, 'BCV_EUR');

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values
    (v_gerente, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'pc-gerente@prueba.helios.test', now(), now(), '{"full_name":"Gabriel Gerente"}'),
    (v_ana, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'pc-ana@prueba.helios.test', now(), now(), '{"full_name":"Ana Secretaria"}');

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_m := (public.admin_create_merchant('Clínica Plazos', null, 'J-600000077', 'clinica')).id;
  reset role;
  select id into v_br from public.merchant_branches where merchant_id = v_m and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_gerente, v_m, v_br, 'gerente'),
    (v_ana, v_m, v_br, 'cajero');

  -- =========================================================================
  -- 1. Las funciones de las fechas
  -- =========================================================================
  if public.helios_settlement_interval_days() <> 7 then
    raise exception 'Lo pactado con la clínica son 7 días entre mitades';
  end if;
  if public.helios_installment_interval_days() <> 14 then
    raise exception 'El intervalo de hoy debía ser 14';
  end if;
  if public.helios_settlement_run_for(v_bdate + 7) <> v_bdate + 8
     or public.helios_settlement_run_for(v_bdate + 14) <> v_bdate + 15 then
    raise exception 'La mitad se paga el día siguiente a devengarse';
  end if;
  -- El corte: el día anterior, 7; ese día y después, 14; sin ninguna fila
  -- (antes de agosto de 2026), la reserva.
  select * into v_row from public.helios_installment_due_dates('2026-11-05');
  if v_row.due_1 <> '2026-11-12' or v_row.due_2 <> '2026-11-19' then
    raise exception 'Una orden del 05/11 vence a +7 y +14: %', to_jsonb(v_row);
  end if;
  select * into v_row from public.helios_installment_due_dates('2026-11-06');
  if v_row.due_1 <> '2026-11-20' or v_row.due_2 <> '2026-12-04' then
    raise exception 'Una orden del 06/11 vence a +14 y +28: %', to_jsonb(v_row);
  end if;
  select * into v_row from public.helios_installment_due_dates('2026-01-15');
  if v_row.due_1 <> '2026-01-22' or v_row.due_2 <> '2026-01-29' then
    raise exception 'Sin fila vigente, la reserva es 7: %', to_jsonb(v_row);
  end if;
  raise notice 'TEST 1 OK — el intervalo es el vigente en la fecha de la orden';

  -- =========================================================================
  -- 2. Orden nueva: la vista previa, lo que se crea y el plan
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V60000071');

  v_j := public.preview_patient_charge(v_m, 'V60000071', 100);
  if (v_j->'installments'->0->>'due_date')::date <> v_bdate + 14
     or (v_j->'installments'->1->>'due_date')::date <> v_bdate + 28 then
    raise exception 'La vista previa debía decir +14 y +28: %', v_j->'installments';
  end if;

  v_r := public.create_patient_charge(v_m, null, jsonb_build_object(
    'document', 'V60000071', 'first_name', 'Carla', 'last_name', 'Rojas',
    'birth_date', '1985-05-05', 'sex', 'F', 'phone', '04121234571', 'email', 'carla.pc@correo.com',
    'state', 'Lara', 'city', 'Barquisimeto', 'address', 'Centro',
    'reference_name', 'Luis Rojas', 'reference_phone', '04241234571', 'reference_relationship', 'Hermano'),
    100, null, null, 'pc-nueva');
  reset role;
  v_ch := (v_r->>'id')::uuid;

  if (v_r->'installments'->0->>'due_date')::date <> v_bdate + 14
     or (v_r->'installments'->1->>'due_date')::date <> v_bdate + 28 then
    raise exception 'Lo que devuelve la orden debía decir +14 y +28: %', v_r->'installments';
  end if;

  select * into v_i1 from public.installments where charge_id = v_ch and sequence = 1;
  select * into v_i2 from public.installments where charge_id = v_ch and sequence = 2;
  v_pac := v_i1.user_id;
  if v_i1.due_date <> v_bdate + 14 or v_i2.due_date <> v_bdate + 28 then
    raise exception 'La orden nueva vence a +14 y +28: % y %', v_i1.due_date, v_i2.due_date;
  end if;
  if v_i1.settlement_due_date <> v_bdate + 7 or v_i2.settlement_due_date <> v_bdate + 14 then
    raise exception 'A la clínica se le devenga a +7 y +14: % y %',
      v_i1.settlement_due_date, v_i2.settlement_due_date;
  end if;

  v_j := public.helios_charge_planned_installments(v_ch);
  if (v_j->0->>'due_date')::date <> v_bdate + 14 or (v_j->1->>'due_date')::date <> v_bdate + 28
     or (v_j->0->>'settlement_due_date')::date <> v_bdate + 7
     or (v_j->1->>'settlement_due_date')::date <> v_bdate + 14 then
    raise exception 'El plan de la orden confirmada, con las dos fechas: %', v_j;
  end if;

  -- El plan de una orden pendiente, que todavía no tiene cuotas, se calcula.
  insert into public.charges (merchant_id, branch_id, requested_by, idempotency_key, user_id, status,
                              business_date, expires_at, amount_usd, base_usd, merchant_net_usd)
  values (v_m, v_br, v_ana, 'pc-pendiente', v_pac, 'pending', v_bdate, now() + interval '1 hour', 100, 100, 100)
  returning id into v_ch_pend;
  v_j := public.helios_charge_planned_installments(v_ch_pend);
  if (v_j->0->>'due_date')::date <> v_bdate + 14 or (v_j->1->>'due_date')::date <> v_bdate + 28
     or (v_j->0->>'settlement_due_date')::date <> v_bdate + 7
     or (v_j->1->>'settlement_due_date')::date <> v_bdate + 14 then
    raise exception 'El plan de la orden pendiente, con las dos fechas: %', v_j;
  end if;
  delete from public.charges where id = v_ch_pend;
  raise notice 'TEST 2 OK — orden nueva: el paciente a +14/+28 y la clínica a +7/+14';

  -- =========================================================================
  -- 3. El trigger: una fecha explícita se respeta, sin fecha de orden usa la de
  --    hoy y no se cuela un null
  -- =========================================================================
  insert into public.charges (merchant_id, branch_id, requested_by, idempotency_key, user_id, status,
                              expires_at, amount_usd, base_usd, merchant_net_usd)
  values (v_m, v_br, v_ana, 'pc-sin-fecha', v_pac, 'pending', now() + interval '1 hour', 100, 100, 100)
  returning id into v_ch_pend;
  insert into public.installments (charge_id, user_id, sequence, amount_usd, financed_usd, due_date)
  values (v_ch_pend, v_pac, 1, 50, 50, v_bdate + 3);
  insert into public.installments (charge_id, user_id, sequence, amount_usd, financed_usd, due_date, settlement_due_date)
  values (v_ch_pend, v_pac, 2, 50, 50, v_bdate + 4, v_bdate + 99);
  if (select array_agg(i.settlement_due_date order by i.sequence) from public.installments i
      where i.charge_id = v_ch_pend) <> array[v_bdate + 7, v_bdate + 99] then
    raise exception 'La fecha de la clínica no sigue a due_date y la explícita se respeta: %',
      (select array_agg(i.settlement_due_date order by i.sequence) from public.installments i
       where i.charge_id = v_ch_pend);
  end if;
  delete from public.installments where charge_id = v_ch_pend;
  delete from public.charges where id = v_ch_pend;

  v_falla := false;
  begin
    update public.installments set settlement_due_date = null where id = v_i1.id;
  exception when not_null_violation then
    v_falla := true;
  end;
  if not v_falla then
    raise exception 'settlement_due_date no admite null';
  end if;
  raise notice 'TEST 3 OK — el trigger pone la fecha y no se cuela un null';

  -- =========================================================================
  -- 4. Lo que se prevé pagarle a la clínica, antes de devengarse
  -- =========================================================================
  select * into v_row from public.helios_settlement_outlook(v_m);
  if v_row.upcoming_usd <> 100 then
    raise exception 'La previsión debía tener por devengar las dos mitades: %', to_jsonb(v_row);
  end if;

  select count(*), sum(x.usd) into v_n, v_num
  from metricas.mitades_por_devengar(v_bdate, v_bdate + 60, v_m) x;
  if v_n <> 2 or v_num <> 100 then
    raise exception 'Por devengar: dos días, 100 en total (salió %, %)', v_n, v_num;
  end if;
  if (select x.usd from metricas.mitades_por_devengar(v_bdate + 7, v_bdate + 7, v_m) x
      where x.dia = v_bdate + 8) is distinct from 50::numeric
     or (select x.usd from metricas.mitades_por_devengar(v_bdate + 14, v_bdate + 14, v_m) x
         where x.dia = v_bdate + 15) is distinct from 50::numeric then
    raise exception 'Por devengar: 50 con pago el día 8 y 50 con pago el día 15';
  end if;
  if exists (select 1 from metricas.mitades_por_devengar(v_bdate + 28, v_bdate + 28, v_m)) then
    raise exception 'El día +28, el de la cuota del paciente, no se devenga nada';
  end if;

  if (select c.previsto_usd from metricas.locales_cierre(v_bdate + 8) c where c.merchant_id = v_m) <> 50
     or (select c.previsto_usd from metricas.locales_cierre(v_bdate + 15) c where c.merchant_id = v_m) <> 50 then
    raise exception 'El cierre debía prever 50 los días 8 y 15';
  end if;
  if exists (select 1 from metricas.locales_cierre(v_bdate + 29) c
             where c.merchant_id = v_m and c.previsto_usd <> 0) then
    raise exception 'El cierre del día 29 no prevé nada para esta clínica';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_j := public.admin_merchant_upcoming_settlements(v_m);
  reset role;
  if jsonb_array_length(v_j) <> 2
     or (v_j->0->>'due_date')::date <> v_bdate + 7 or (v_j->0->>'run_date')::date <> v_bdate + 8
     or (v_j->1->>'due_date')::date <> v_bdate + 14 or (v_j->1->>'run_date')::date <> v_bdate + 15
     or (v_j->0->>'amount_usd')::numeric <> 50 or (v_j->1->>'amount_usd')::numeric <> 50
     or (v_j->0->>'cuotas')::integer <> 1 or (v_j->1->>'cuotas')::integer <> 1 then
    raise exception 'Los próximos pagos: mitades a +7 y +14, pago a +8 y +15: %', v_j;
  end if;
  raise notice 'TEST 4 OK — lo previsto a la clínica sale de sus fechas, no de las del paciente';

  -- =========================================================================
  -- 5. Lo que ve la clínica de su orden
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  v_j := public.merchant_charge_detail(v_ch);
  if (v_j->'installments'->0->>'due_date')::date <> v_bdate + 14
     or (v_j->'installments'->0->>'run_date')::date <> v_bdate + 8
     or (v_j->'installments'->1->>'due_date')::date <> v_bdate + 28
     or (v_j->'installments'->1->>'run_date')::date <> v_bdate + 15 then
    raise exception 'La ficha: el vencimiento del paciente y el pago a la clínica: %', v_j->'installments';
  end if;
  if (select (x->>'due_date')::date from jsonb_array_elements(v_j->'payouts') x
      where x->>'kind' = 'installment' and (x->>'sequence')::integer = 1) <> v_bdate + 7
     or (select (x->>'run_date')::date from jsonb_array_elements(v_j->'payouts') x
         where x->>'kind' = 'installment' and (x->>'sequence')::integer = 2) <> v_bdate + 15 then
    raise exception 'Las líneas de pago van con las fechas de la clínica: %', v_j->'payouts';
  end if;

  select * into v_row from public.merchant_transactions(v_bdate, v_bdate) t where t.charge_id = v_ch;
  if v_row.cuota_1_due <> v_bdate + 14 or v_row.cuota_1_run <> v_bdate + 8
     or v_row.cuota_2_due <> v_bdate + 28 or v_row.cuota_2_run <> v_bdate + 15 then
    raise exception 'La lista de órdenes: %', to_jsonb(v_row);
  end if;

  select * into v_row from public.merchant_sales_export(v_bdate, v_bdate) t where t.charge_id = v_ch;
  if v_row.cuota_1_due <> v_bdate + 14 or v_row.cuota_1_run <> v_bdate + 8
     or v_row.cuota_2_due <> v_bdate + 28 or v_row.cuota_2_run <> v_bdate + 15 then
    raise exception 'La descarga: %', to_jsonb(v_row);
  end if;
  reset role;
  raise notice 'TEST 5 OK — en la ficha, la lista y la descarga, cada fecha es de quien es';

  -- =========================================================================
  -- 6. La comisión del personal: día 8, con la primera mitad
  -- =========================================================================
  select * into v_row from public.settlements
  where charge_id = v_ch and reason = 'staff_commission';
  if v_row.id is null or v_row.due_date <> v_bdate + 7
     or public.helios_settlement_run_for(v_row.due_date) <> v_bdate + 8 then
    raise exception 'La comisión del personal sale el día 8: %', to_jsonb(v_row);
  end if;
  raise notice 'TEST 6 OK — la comisión del personal, el día 8';

  -- =========================================================================
  -- 7. El cron
  -- =========================================================================
  perform public.run_scheduled_settlements(v_bdate + 7);
  select count(*), min(s.due_date), min(s.business_date), sum(s.amount_usd) into v_n, v_d1, v_d2, v_num
  from public.settlements s where s.charge_id = v_ch and s.reason = 'scheduled_installment';
  if v_n <> 1 or v_d1 <> v_bdate + 7 or v_d2 <> v_bdate + 7 or v_num <> 50 then
    raise exception 'El cron del día +7 crea la primera mitad: %, %, %, %', v_n, v_d1, v_d2, v_num;
  end if;

  perform public.run_scheduled_settlements(v_bdate + 7);
  if (select count(*) from public.settlements s
      where s.charge_id = v_ch and s.reason = 'scheduled_installment') <> 1 then
    raise exception 'El cron del día +7, otra vez, no duplica';
  end if;

  perform public.run_scheduled_settlements(v_bdate + 14);
  if (select count(*) from public.settlements s
      where s.charge_id = v_ch and s.reason = 'scheduled_installment') <> 2
     or (select max(s.due_date) from public.settlements s
         where s.charge_id = v_ch and s.reason = 'scheduled_installment') <> v_bdate + 14
     or (select sum(s.amount_usd) from public.settlements s
         where s.charge_id = v_ch and s.reason = 'scheduled_installment') <> 100 then
    raise exception 'El cron del día +14 crea la segunda mitad y completa el neto';
  end if;

  perform public.run_scheduled_settlements(v_bdate + 28);
  if (select count(*) from public.settlements s
      where s.charge_id = v_ch and s.reason = 'scheduled_installment') <> 2 then
    raise exception 'El día +28 no hay una tercera mitad';
  end if;
  raise notice 'TEST 7 OK — el cron devenga a +7 y +14, sin duplicar y sin tercera';

  -- =========================================================================
  -- 8. Después del cron
  -- =========================================================================
  select * into v_row from public.helios_settlement_outlook(v_m);
  if v_row.upcoming_usd <> 0 or v_row.accrued_consultas_usd <> 100 then
    raise exception 'Ya devengado, no queda nada por encolar: %', to_jsonb(v_row);
  end if;

  -- El médico cobra aunque el paciente no pague, y lo que se le enseña al
  -- equipo es si pagó la cuota que corresponde a ESA mitad.
  update public.installments set status = 'paid', paid_at = now() where id = v_i1.id;
  select * into v_row from public.helios_cuota_pagada(v_ch, v_bdate + 7);
  if v_row.cuotas <> 1 or v_row.cuotas_pagadas <> 1 then
    raise exception 'La primera mitad se cruza con la primera cuota: %', to_jsonb(v_row);
  end if;
  select * into v_row from public.helios_cuota_pagada(v_ch, v_bdate + 14);
  if v_row.cuotas <> 1 or v_row.cuotas_pagadas <> 0 then
    raise exception 'La segunda mitad se cruza con la segunda cuota: %', to_jsonb(v_row);
  end if;
  select * into v_row from public.helios_cuota_pagada(v_ch, v_bdate + 28);
  if v_row.cuotas <> 0 then
    raise exception 'El día del vencimiento de la cuota no es una fecha de la clínica: %', to_jsonb(v_row);
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_j := public.admin_merchant_settlements(v_m);
  reset role;
  if (select array_agg((x->>'run_date')::date order by (x->>'run_date')::date)
      from jsonb_array_elements(v_j) x where x->>'reason' = 'scheduled_installment')
       <> array[v_bdate + 8, v_bdate + 15]
     or (select (x->>'cuotas_pagadas')::integer from jsonb_array_elements(v_j) x
         where x->>'reason' = 'scheduled_installment' and (x->>'due_date')::date = v_bdate + 7) <> 1
     or (select (x->>'cuotas_pagadas')::integer from jsonb_array_elements(v_j) x
         where x->>'reason' = 'scheduled_installment' and (x->>'due_date')::date = v_bdate + 14) <> 0 then
    raise exception 'Las liquidaciones de la clínica, con su cuota: %', v_j;
  end if;
  raise notice 'TEST 8 OK — la previsión a cero y cada mitad con su cuota';

  -- =========================================================================
  -- 9. Orden de antes del corte: conserva +7/+14
  -- =========================================================================
  -- Una orden del 01/10 que se finaliza hoy: vence como se le dijo. Las
  -- condiciones de la clínica se adelantan para que estén vigentes ese día.
  update public.merchant_terms set effective_from = '2026-01-01' where merchant_id = v_m;
  v_b := public.helios_charge_breakdown(100, 0);
  insert into public.charges (
    merchant_id, branch_id, requested_by, idempotency_key, user_id, status, business_date, expires_at,
    amount_usd, base_usd, vat_pct, vat_usd,
    consumer_fee_pct, consumer_fee_usd, consumer_fee_vat_usd,
    merchant_fee_pct, merchant_fee_usd, merchant_fee_vat_usd, merchant_net_usd
  ) values (
    v_m, v_br, v_ana, 'pc-vieja', v_pac, 'pending', v_viejo, now() + interval '1 hour',
    (v_b->>'consumer_total_usd')::numeric, (v_b->>'base_usd')::numeric,
    (v_b->>'vat_pct')::numeric, (v_b->>'vat_usd')::numeric,
    (v_b->>'consumer_fee_pct')::numeric, (v_b->>'consumer_fee_usd')::numeric,
    (v_b->>'consumer_fee_vat_usd')::numeric,
    (v_b->>'merchant_fee_pct')::numeric, (v_b->>'merchant_fee_usd')::numeric,
    (v_b->>'merchant_fee_vat_usd')::numeric, (v_b->>'merchant_net_usd')::numeric
  )
  returning id into v_ch_vie;

  v_j := public.helios_charge_planned_installments(v_ch_vie);
  if (v_j->0->>'due_date')::date <> v_viejo + 7 or (v_j->1->>'due_date')::date <> v_viejo + 14
     or (v_j->0->>'settlement_due_date')::date <> v_viejo + 7
     or (v_j->1->>'settlement_due_date')::date <> v_viejo + 14 then
    raise exception 'El plan de la orden vieja conserva +7 y +14: %', v_j;
  end if;

  perform public.helios_finalize_charge(v_ch_vie, 'whatsapp_manual');
  select * into v_i1 from public.installments where charge_id = v_ch_vie and sequence = 1;
  select * into v_i2 from public.installments where charge_id = v_ch_vie and sequence = 2;
  if v_i1.due_date <> v_viejo + 7 or v_i2.due_date <> v_viejo + 14
     or v_i1.settlement_due_date <> v_viejo + 7 or v_i2.settlement_due_date <> v_viejo + 14 then
    raise exception 'La orden vieja conserva +7 y +14 para los dos: %, %', to_jsonb(v_i1), to_jsonb(v_i2);
  end if;

  perform public.run_scheduled_settlements(v_viejo + 7);
  perform public.run_scheduled_settlements(v_viejo + 14);
  if (select array_agg(s.due_date order by s.due_date) from public.settlements s
      where s.charge_id = v_ch_vie and s.reason = 'scheduled_installment')
       <> array[v_viejo + 7, v_viejo + 14] then
    raise exception 'La orden vieja se devenga a +7 y +14';
  end if;
  raise notice 'TEST 9 OK — la orden de antes del corte conserva sus fechas';

  raise notice '=== TODOS LOS TESTS DEL PLAZO DE LAS CUOTAS PASARON ===';
end $$;

set constraints all immediate;

rollback;
