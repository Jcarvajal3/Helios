-- ============================================================================
-- Ronda — Prueba de humo del pago al comercio
--
-- docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--   -v ON_ERROR_STOP=1 -f supabase/tests/merchant_payout_smoke.sql
--
-- Lo que se comprueba es la separación entre DEVENGAR y PAGAR: al vender, el
-- comercio queda acreedor y la caja de Ronda NO se mueve; solo se mueve
-- cuando alguien reporta la transferencia real.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin    uuid := gen_random_uuid();
  v_ana      uuid := gen_random_uuid();
  v_cajero   uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_charge   uuid;
  v_cash0    numeric;
  v_cash1    numeric;
  v_cash2    numeric;
  v_payable  numeric;
  v_pending  numeric;
  /** El neto del comercio y el tramo de una cuota, derivados de lo que guardó
   *  la base. Ver la nota en `ledger_smoke`: los números fijos de esta prueba
   *  daban por hecho que el usuario debe la base pelada, y desde
   *  20260827100000 no. */
  v_net      numeric;
  v_tranche  numeric;
  v_due1     date;
  v_ids      uuid[];
  v_result   jsonb;
  v_failed   boolean;
begin
  -- --- Fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_admin,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000061', now(), now(), now()),
    (v_ana,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000062', now(), now(), now()),
    (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000063', now(), now(), now());

  -- Nivel 3 ($200 de límite) para que un consumo de $100 quepa y los
  -- porcentajes salgan en números redondos.
  update public.profiles set status = 'active', level = 3 where id = v_ana;
  -- Helios: el nivel 3 ya no es de $200 en la configuración heredada; se
  -- fija aquí para que la prueba no dependa de ella.
  update public.levels set monthly_limit_usd = 200.00 where level = 3;
  insert into public.platform_admins (user_id, role, full_name)
  values (v_admin, 'super_admin', 'Jefa');

  insert into public.merchants (name) values ('Bar Payout') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_merchant, v_branch, 'cajero');

  select ledger.account_balance(id) into v_cash0
    from ledger.accounts where account_type = 'cash' and owner_id is null;
  v_cash0 := coalesce(v_cash0, 0);

  -- Helios: aquí iba el PIN de la prueba (`set_user_pin` y el pepper de
  -- Vault). Sin app no hay PIN: la deuda la crea `pg_temp.prueba_cobro`.

  -- --- 1. Vender NO mueve la caja de Ronda -------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  v_charge := (pg_temp.prueba_cobro(v_ana, v_merchant, v_branch, v_cajero, 100.00, 'payout-1', 'Consumo')->>'charge_id')::uuid;

  reset role;
  select coalesce(ledger.account_balance(id), 0) into v_cash1
    from ledger.accounts where account_type = 'cash' and owner_id is null;

  if coalesce(v_cash1, 0) <> v_cash0 then
    raise exception 'Vender no debía mover la caja. Antes %, después %', v_cash0, v_cash1;
  end if;
  raise notice 'TEST PAYOUT 1 OK — la venta no movió la caja (sigue en %)', v_cash0;

  -- --- 2. Pero sí deja al comercio acreedor por el 80% -------------------
  select ledger.account_balance(id) into v_payable
    from ledger.accounts where account_type = 'merchant_payable' and owner_id = v_merchant;

  -- El acreedor es por SU NETO (venta menos su comisión), no por el 80% del
  -- total que paga el usuario: ese lleva además IVA y comisión del consumidor,
  -- que no son del local. Ver la nota en `ledger_smoke`.
  if v_payable <> -(select merchant_net_usd from public.charges where id = v_charge) then
    raise exception 'Se le debía su neto (%) al comercio, el libro dice %',
      (select merchant_net_usd from public.charges where id = v_charge), v_payable;
  end if;
  raise notice 'TEST PAYOUT 2 OK — el comercio queda acreedor por su neto ($%)',
    (select merchant_net_usd from public.charges where id = v_charge);

  -- --- 3. Vender no encola NADA: el comercio cobra por fecha de cuota -----
  -- Desde 20260902120000 el reparto es 0 / 50 / 50: al vender no se devenga
  -- nada en la cola de pago, y cada mitad nace el día que vence su cuota. El
  -- porcentaje sale de las condiciones del comercio, no de un número a mano.
  select merchant_net_usd into v_net from public.charges where id = v_charge;
  select round(v_net * per_installment_pct / 100, 4) into v_tranche
  from public.merchant_settlement_terms where merchant_id = v_merchant;

  -- `merchant_payables` hace join con lo pendiente: sin nada devengado, el
  -- comercio no sale en la vista y `v_pending` se queda en null. Por eso el
  -- coalesce, y por eso la comparación es explícita contra cero.
  select coalesce(pending_usd, 0) into v_pending
  from public.merchant_payables where merchant_id = v_merchant;

  if coalesce(v_pending, 0) <> 0 then
    raise exception 'Al vender no debía encolarse nada, hay % pendiente', v_pending;
  end if;
  raise notice 'TEST PAYOUT 3 OK — vender no encola nada (se cobra por fecha de cuota)';

  -- --- 3-bis. Al vencer la cuota 1 se devenga la mitad -------------------
  select due_date into v_due1 from public.installments
  where charge_id = v_charge and sequence = 1;

  perform public.run_scheduled_settlements(v_due1);

  select coalesce(pending_usd, 0) into v_pending
  from public.merchant_payables where merchant_id = v_merchant;

  if coalesce(v_pending, 0) <> v_tranche then
    raise exception 'Al vencer la cuota 1 debían devengarse %, hay %', v_tranche, v_pending;
  end if;
  raise notice 'TEST PAYOUT 3-BIS OK — la cuota 1 devengó $% al comercio', v_pending;

  -- Correrlo dos veces el mismo día no duplica: la idempotencia es por
  -- consumo Y FECHA (20260827080000).
  perform public.run_scheduled_settlements(v_due1);
  select coalesce(pending_usd, 0) into v_pending
  from public.merchant_payables where merchant_id = v_merchant;
  if coalesce(v_pending, 0) <> v_tranche then
    raise exception 'El cron duplicó el devengo: % en vez de %', v_pending, v_tranche;
  end if;

  -- --- 4. Reportar la transferencia SÍ mueve la caja ---------------------
  select array_agg(id) into v_ids
  from public.settlements where merchant_id = v_merchant and status = 'pending';

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  v_result := public.admin_report_merchant_payout(
    v_merchant, v_ids, 'pago_movil', 'REF-99887', 1200.00, 40.00, 'cierre del lunes'
  );

  reset role;
  select coalesce(ledger.account_balance(id), 0) into v_cash2
    from ledger.accounts where account_type = 'cash' and owner_id is null;

  if v_cash2 <> v_cash0 - v_tranche then
    raise exception 'Al reportar el pago la caja debía bajar %. Era %, ahora %', v_tranche, v_cash0, v_cash2;
  end if;
  raise notice 'TEST PAYOUT 4 OK — reportar la transferencia bajó la caja a % (pagados $%)',
    v_cash2, v_result->>'amount_usd';

  -- --- 5. Al comercio le queda la cuota 2 por cobrar --------------------
  select ledger.account_balance(id) into v_payable
    from ledger.accounts where account_type = 'merchant_payable' and owner_id = v_merchant;

  if v_payable <> -(v_net - v_tranche) then
    raise exception 'Tras pagar la cuota 1 debían quedar %, el libro dice %', v_net - v_tranche, v_payable;
  end if;
  raise notice 'TEST PAYOUT 5 OK — al comercio le queda $% (la cuota 2)', v_net - v_tranche;

  -- --- 6. No se puede pagar dos veces la misma liquidación ---------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  v_failed := false;
  begin
    perform public.admin_report_merchant_payout(v_merchant, v_ids, 'pago_movil', 'REF-DUP');
  exception when others then
    v_failed := true;
    raise notice 'TEST PAYOUT 6 OK — doble pago rechazado: %', sqlerrm;
  end;
  if not v_failed then
    raise exception 'No debía poder pagarse dos veces la misma liquidación';
  end if;

  -- --- 7. Un usuario cualquiera no puede reportar pagos ------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  v_failed := false;
  begin
    perform public.admin_report_merchant_payout(v_merchant, v_ids, 'pago_movil', 'REF-X');
  exception when others then
    v_failed := true;
    raise notice 'TEST PAYOUT 7 OK — sin permisos rebota: %', sqlerrm;
  end;
  if not v_failed then
    raise exception 'Un cajero no debía poder reportar pagos al comercio';
  end if;

  -- --- 8. Queda en la bitácora ------------------------------------------
  reset role;
  if not exists (
    select 1 from audit.admin_actions
    -- La acción se llama 'merchant.payout' desde que el pago admite parciales
    -- (Ronda la renombró y esta prueba se quedó con 'merchant.paid').
    where actor = v_admin and action = 'merchant.payout' and target_id = v_merchant
  ) then
    raise exception 'El pago al comercio debía quedar en la bitácora';
  end if;
  raise notice 'TEST PAYOUT 8 OK — registrado en audit.admin_actions';

  -- --- 9. El libro sigue cuadrando --------------------------------------
  if (select round(sum(debit) - sum(credit), 4) from ledger.entries) <> 0 then
    raise exception 'El libro dejó de cuadrar';
  end if;
  raise notice 'TEST PAYOUT 9 OK — el libro completo cuadra en cero';

  raise notice '=== TODOS LOS TESTS DE PAGO AL COMERCIO PASARON ===';
end $$;

set constraints all immediate;

rollback;
