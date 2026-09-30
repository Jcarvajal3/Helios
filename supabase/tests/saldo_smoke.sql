-- ============================================================================
-- Ronda — Prueba de humo de cómo se ocupa y se libera el saldo
--
--   docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f supabase/tests/saldo_smoke.sql
--
-- Nueva el 2026-08-30, y existe porque tres reglas del producto no tenían
-- ninguna prueba que las sujetara:
--
--   1. El cupo se libera POR FACTURA, no al saldarlo todo.
--   2. Dentro de una factura NO hay liberación parcial.
--   3. En mora, TODO el saldo bloqueado — aunque hayas saldado otra factura.
--
-- Las tres se pueden romper sin que ninguna otra suite se entere: son la
-- aritmética del disponible, y las demás miran el libro o los estados.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_customer uuid := gen_random_uuid();
  v_cajero   uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_charge_a uuid;
  v_charge_b uuid;
  v_limit    numeric := 50.00;
  v_fin_a    numeric;
  v_fin_b    numeric;
  v_avail    jsonb;
  v_inst     uuid;
  v_report   jsonb;
  v_quote    jsonb;
  v_super    uuid := gen_random_uuid();
begin
  -- --- Montaje -----------------------------------------------------------
  -- Helios (H3): el paciente no tiene cuenta en Auth; es solo una fila de `profiles`.
  insert into public.profiles (id, phone_e164) values
    (v_customer, '+584140000030');

  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          '+584140000031', now(), now(), now());
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values (v_super, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          '+584140000032', now(), now(), now());

  update public.profiles set status = 'active', level = 1, full_name = 'Cliente Saldo'
  where id = v_customer;

  -- Nivel 1 con $50 clavados: la prueba razona con esa cifra.
  update public.levels set monthly_limit_usd = v_limit where level = 1;

  insert into public.merchants (name) values ('Bar Saldo') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_merchant, v_branch, 'cajero');

  insert into public.platform_admins (user_id, role, is_active)
  values (v_super, 'super_admin', true)
  on conflict do nothing;

  -- Helios: aquí iba el PIN de la prueba (`set_user_pin` y el pepper de
  -- Vault). Sin app no hay PIN: la deuda la crea `pg_temp.prueba_cobro`.

  -- --- Dos facturas de $20 de producto cada una --------------------------
  -- Helios: la deuda nace con `pg_temp.prueba_cobro` (lo que hacían
  -- request_charge + confirm_charge, sin PIN ni QR; ver _ayudas.sql).
  v_charge_a := (pg_temp.prueba_cobro(v_customer, v_merchant, v_branch, v_cajero, 20.00, 'saldo-a', 'Consumo A')->>'charge_id')::uuid;
  v_charge_b := (pg_temp.prueba_cobro(v_customer, v_merchant, v_branch, v_cajero, 20.00, 'saldo-b', 'Consumo B')->>'charge_id')::uuid;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_customer::text, 'role', 'authenticated')::text, true);
  reset role;  -- Helios (H3): el paciente no se autentica; esto corre como el sistema, con sus claims.

  select coalesce(base_usd, amount_usd) into v_fin_a from public.charges where id = v_charge_a;
  select coalesce(base_usd, amount_usd) into v_fin_b from public.charges where id = v_charge_b;

  v_avail := pg_temp.prueba_saldo(v_customer);

  -- --- 1. Las dos ocupan cupo, y solo por lo CONSUMIDO -------------------
  if (v_avail->>'available_usd')::numeric <> v_limit - v_fin_a - v_fin_b then
    raise exception 'Con dos facturas de $% debía quedar $%, quedó %',
      v_fin_a, v_limit - v_fin_a - v_fin_b, v_avail;
  end if;
  raise notice 'TEST SALDO 1 OK — dos consumos de $% ocupan $%: disponible %',
    v_fin_a, v_fin_a + v_fin_b, v_avail->>'available_usd';

  -- --- 2. Pagar UNA cuota de una factura NO libera nada -------------------
  reset role;
  select id into v_inst from public.installments
  where charge_id = v_charge_a and sequence = 1;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_customer::text, 'role', 'authenticated')::text, true);
  reset role;  -- Helios (H3): el paciente no se autentica; esto corre como el sistema, con sus claims.
  v_quote := pg_temp.quote_installments(array[v_inst]);
  v_report := pg_temp.report_payment(
    (v_quote->>'quote_id')::uuid, 'pago_movil', 'Banesco', '111111', 'V12345678', '+584140000030');
  reset role;

  perform public.reconcile_payment((v_report->>'report_id')::uuid, v_super, true, null);

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_customer::text, 'role', 'authenticated')::text, true);
  reset role;  -- Helios (H3): el paciente no se autentica; esto corre como el sistema, con sus claims.
  v_avail := pg_temp.prueba_saldo(v_customer);
  reset role;

  if (v_avail->>'available_usd')::numeric <> v_limit - v_fin_a - v_fin_b then
    raise exception
      'Media factura NO libera cupo: debía seguir en $%, quedó %',
      v_limit - v_fin_a - v_fin_b, v_avail;
  end if;
  raise notice 'TEST SALDO 2 OK — una de las dos cuotas pagada y el cupo NO se movió';

  -- --- 3. Pagar la SEGUNDA cuota libera la factura entera -----------------
  select id into v_inst from public.installments
  where charge_id = v_charge_a and sequence = 2;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_customer::text, 'role', 'authenticated')::text, true);
  reset role;  -- Helios (H3): el paciente no se autentica; esto corre como el sistema, con sus claims.
  v_quote := pg_temp.quote_installments(array[v_inst]);
  v_report := pg_temp.report_payment(
    (v_quote->>'quote_id')::uuid, 'pago_movil', 'Banesco', '222222', 'V12345678', '+584140000030');
  reset role;

  perform public.reconcile_payment((v_report->>'report_id')::uuid, v_super, true, null);

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_customer::text, 'role', 'authenticated')::text, true);
  reset role;  -- Helios (H3): el paciente no se autentica; esto corre como el sistema, con sus claims.
  v_avail := pg_temp.prueba_saldo(v_customer);
  reset role;

  if (v_avail->>'available_usd')::numeric <> v_limit - v_fin_b then
    raise exception
      'Al saldar la factura A debía volver su cupo ($% disponible), quedó %',
      v_limit - v_fin_b, v_avail;
  end if;
  raise notice 'TEST SALDO 3 OK — factura saldada: vuelven $% y queda ocupada solo la otra',
    v_fin_a;

  -- --- 4. En MORA, todo bloqueado ----------------------------------------
  -- La factura B se vence. La A ya está saldada y su cupo había vuelto: la
  -- regla dice que ahora no vale nada, porque hay una cuota vencida.
  update public.installments
    set due_date = public.helios_business_date(now()) - 1
  where charge_id = v_charge_b;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_customer::text, 'role', 'authenticated')::text, true);
  reset role;  -- Helios (H3): el paciente no se autentica; esto corre como el sistema, con sus claims.
  v_avail := pg_temp.prueba_saldo(v_customer);
  reset role;

  if (v_avail->>'available_usd')::numeric <> 0 then
    raise exception 'Con una cuota vencida el disponible debía ser 0, es %', v_avail;
  end if;
  if not (v_avail->>'in_arrears')::boolean then
    raise exception 'El saldo debía venir marcado como bloqueado por mora: %', v_avail;
  end if;
  raise notice 'TEST SALDO 4 OK — una cuota vencida apaga TODO el disponible, no solo el suyo';

  -- --- 5. Y al ponerse al día, vuelve ------------------------------------
  update public.installments
    set due_date = public.helios_business_date(now()) + 3
  where charge_id = v_charge_b;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_customer::text, 'role', 'authenticated')::text, true);
  reset role;  -- Helios (H3): el paciente no se autentica; esto corre como el sistema, con sus claims.
  v_avail := pg_temp.prueba_saldo(v_customer);
  reset role;

  if (v_avail->>'available_usd')::numeric <> v_limit - v_fin_b then
    raise exception 'Sin mora debía volver a $%, es %', v_limit - v_fin_b, v_avail;
  end if;
  raise notice 'TEST SALDO 5 OK — sin cuotas vencidas el disponible vuelve solo';

  raise notice '=== TODOS LOS TESTS DE SALDO PASARON ===';
end $$;

set constraints all immediate;

rollback;
