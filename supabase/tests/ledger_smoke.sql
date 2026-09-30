-- ============================================================================
-- Ronda — Prueba de humo del ledger
--
-- No es pgTAP: son asserts en PL/pgSQL que abortan con RAISE EXCEPTION si
-- algo no cuadra. Corre contra una base local recién reseteada:
--
--   supabase db reset
--   docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f supabase/tests/ledger_smoke.sql
--
-- Cubre: cobro feliz, límite insuficiente, "no hay liberación parcial",
-- cierre de bloque al pagar todo, cuadre de partida doble, y demora →
-- congelado / bajada de nivel / expulsión.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_customer   uuid := gen_random_uuid();
  v_cajero     uuid := gen_random_uuid();
  v_merchant   uuid;
  v_branch     uuid;
  v_charge1    uuid;
  v_charge2    uuid;
  v_result     jsonb;
  v_avail      jsonb;
  v_inst1      uuid;
  v_inst2      uuid;
  v_quote      uuid;
  v_report     uuid;
  v_recv       numeric;
  v_pay        numeric;
  v_rev        numeric;
  v_cash       numeric;
  v_failed     boolean;
  /**
   * Lo que de verdad se cobró y lo que de verdad se le debe al comercio.
   *
   * 🐛 Antes esta prueba daba por hecho que un consumo de $20 creaba $20 de
   * deuda, y desde la facturación por cuenta de terceros (20260827100000) el
   * usuario debe $20 + IVA + comisión. Todos los números mágicos que había
   * aquí abajo llevaban rotos desde entonces, así que la prueba no protegía
   * nada — lo que se comprueba ahora es la RELACIÓN (disponible = límite −
   * cobrado), que es lo que la regla de negocio dice y no cambia si mañana se
   * mueve un porcentaje.
   */
  v_amount1    numeric;
  /** Lo que ese consumo ocupa de cupo: la base, sin el fee del servicio. */
  v_financed1  numeric;
  v_net1       numeric;
  v_upfront    numeric;
  v_limit      numeric := 50.00;
begin
  -- --- Fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values (v_customer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          '+584140000001', now(), now(), now());

  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          '+584140000002', now(), now(), now());

  update public.profiles set status = 'active', full_name = 'Cliente Prueba' where id = v_customer;
  -- Helios: la prueba razona con un nivel 1 de $50 (`v_limit`); se fija aquí
  -- para no depender de la configuración de niveles (H1 la cambia).
  update public.levels set monthly_limit_usd = v_limit where level = 1;

  insert into public.merchants (name) values ('Bar de Prueba') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;

  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_merchant, v_branch, 'cajero');

  raise notice 'FIXTURES OK — customer=%, merchant=%, branch=%', v_customer, v_merchant, v_branch;

  -- Helios: aquí iba el PIN de la prueba (`set_user_pin` y el pepper de
  -- Vault). Sin app no hay PIN: la deuda la crea `pg_temp.prueba_cobro`.

  -- --- 1. Cobro feliz: $20 sobre un límite de $50 -------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);


  perform set_config('request.jwt.claims', json_build_object('sub', v_customer::text, 'role', 'authenticated')::text, true);
  v_result := pg_temp.prueba_cobro(v_customer, v_merchant, v_branch, v_cajero, 20.00, 'smoke-charge-1', 'Consumo');
  v_charge1 := (v_result->>'charge_id')::uuid;

  if not (v_result->>'ok')::boolean then
    raise exception 'confirm_charge debía tener éxito: %', v_result;
  end if;

  -- Lo que se DEBE (base + fee + IVA del fee) y lo que se FINANCIA (la base).
  -- Desde 20260830190000 son cifras distintas y el cupo lo mueve la segunda.
  select amount_usd, merchant_net_usd, coalesce(base_usd, amount_usd)
    into v_amount1, v_net1, v_financed1
  from public.charges where id = v_charge1;

  v_avail := pg_temp.prueba_saldo(v_customer);
  if (v_avail->>'available_usd')::numeric <> v_limit - v_financed1 then
    raise exception 'Disponible esperado % (límite % − consumo %), obtuve %',
      v_limit - v_financed1, v_limit, v_financed1, v_avail;
  end if;
  -- El fee se debe pero NO ocupa cupo: esa es la diferencia entre las dos.
  if (v_avail->>'service_fee_usd')::numeric <> v_amount1 - v_financed1 then
    raise exception 'El fee debía quedar fuera del cupo (% esperado), obtuve %',
      v_amount1 - v_financed1, v_avail->>'service_fee_usd';
  end if;
  raise notice 'TEST 1 OK — consumo de $% (se pagan $%) sobre un límite de $%: disponible %',
    v_financed1, v_amount1, v_limit, v_avail->>'available_usd';

  -- --- 2. Límite insuficiente: intentar $35 más (30 disponibles) ---------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  perform set_config('request.jwt.claims', json_build_object('sub', v_customer::text, 'role', 'authenticated')::text, true);

  v_failed := false;
  begin
    v_charge2 := (pg_temp.prueba_cobro(v_customer, v_merchant, v_branch, v_cajero, 35.00, 'smoke-charge-2', 'Consumo')->>'charge_id')::uuid;
  exception when others then
    v_failed := true;
    raise notice 'TEST 2 OK — rechazado como se esperaba: %', sqlerrm;
  end;

  if not v_failed then
    raise exception 'confirm_charge debía fallar por saldo insuficiente';
  end if;

  -- --- 3. No hay liberación parcial: pagar 1 de 2 cuotas no libera cupo --
  select id into v_inst1 from public.installments where charge_id = v_charge1 and sequence = 1;
  select id into v_inst2 from public.installments where charge_id = v_charge1 and sequence = 2;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_customer::text, 'role', 'authenticated')::text, true);

  v_quote := (public.quote_installments(array[v_inst1])->>'quote_id')::uuid;
  v_report := (public.report_payment(v_quote, 'pago_movil', 'Banesco', '100001')->>'report_id')::uuid;

  reset role;
  v_result := public.reconcile_payment(v_report, v_cajero, true, 'conciliado en prueba');
  if not (v_result->>'ok')::boolean then
    raise exception 'reconcile_payment debía tener éxito: %', v_result;
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_customer::text, 'role', 'authenticated')::text, true);
  v_avail := pg_temp.prueba_saldo(v_customer);

  if (v_avail->>'available_usd')::numeric <> v_limit - v_financed1 then
    raise exception 'Disponible tras pagar 1 de 2 cuotas debía seguir en % (no hay liberación parcial), obtuve %',
      v_limit - v_financed1, v_avail;
  end if;
  -- Lo que falta para liberar es exactamente la cuota que queda sin pagar.
  if (v_avail->>'amount_to_unlock_usd')::numeric
     <> (select amount_usd from public.installments where id = v_inst2) then
    raise exception 'Faltante para liberar debía ser la cuota 2 (%), obtuve %',
      (select amount_usd from public.installments where id = v_inst2), v_avail;
  end if;
  raise notice 'TEST 3 OK — tras pagar 1 de 2 cuotas: disponible=% (sin cambio), falta_liberar=%',
    v_avail->>'available_usd', v_avail->>'amount_to_unlock_usd';

  -- --- 4. Pagar la segunda cuota cierra el bloque y libera el límite -----
  v_quote := (public.quote_installments(array[v_inst2])->>'quote_id')::uuid;
  v_report := (public.report_payment(v_quote, 'pago_movil', 'Banesco', '100002')->>'report_id')::uuid;

  reset role;
  v_result := public.reconcile_payment(v_report, v_cajero, true, 'conciliado en prueba');
  if not (v_result->>'ok')::boolean then
    raise exception 'reconcile_payment (cuota 2) debía tener éxito: %', v_result;
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_customer::text, 'role', 'authenticated')::text, true);
  v_avail := pg_temp.prueba_saldo(v_customer);

  if (v_avail->>'available_usd')::numeric <> v_limit then
    raise exception 'Disponible tras saldar todo debía volver a %, obtuve %', v_limit, v_avail;
  end if;
  raise notice 'TEST 4 OK — bloque cerrado, disponible restablecido a %', v_avail->>'available_usd';

  reset role;
  if not exists (
    select 1 from public.user_credit_blocks
    where user_id = v_customer and close_reason = 'paid' and closed_at is not null
  ) then
    raise exception 'El bloque debía quedar cerrado con close_reason=paid';
  end if;

  -- --- 5. Cuadre de partida doble ------------------------------------------
  -- Las cuentas del usuario y del comercio sí son suyas y se pueden afirmar
  -- en concreto.
  select ledger.account_balance(id) into v_recv
    from ledger.accounts where account_type = 'user_receivable' and owner_id = v_customer;
  select ledger.account_balance(id) into v_pay
    from ledger.accounts where account_type = 'merchant_payable' and owner_id = v_merchant;

  if v_recv <> 0 then
    raise exception 'user_receivable debía quedar en 0 tras pagar todo, quedó en %', v_recv;
  end if;

  -- Al comercio se le debe SU NETO entero: desde 20260822120000 el adelanto se
  -- DEVENGA al vender pero no se paga hasta que alguien reporte la
  -- transferencia. Nadie ha transferido nada en esta prueba, así que la deuda
  -- con el local sigue completa. (El neto es la venta del comercio menos su
  -- comisión, no el total que paga el usuario: ese lleva además el IVA y la
  -- comisión del consumidor, que no son del local.)
  if v_pay <> -v_net1 then
    raise exception 'Al comercio debía debérsele su neto entero (%), el libro dice %',
      v_net1, v_pay;
  end if;

  -- En la cola de pago solo tiene que estar el adelanto del día de la venta,
  -- que desde 20260902120000 es CERO: el comercio devenga media venta en la
  -- fecha de cada cuota y cobra en el cierre del lunes siguiente. El
  -- porcentaje sale de las condiciones del comercio y no de un número escrito
  -- a mano, así que esto sigue valiendo si el reparto vuelve a cambiar. El
  -- flujo completo —devengar por fecha y transferir— lo cubre
  -- `merchant_payout_smoke`.
  select round(v_net1 * upfront_pct / 100, 4) into v_upfront
  from public.merchant_settlement_terms where merchant_id = v_merchant;

  if (
    select coalesce(sum(amount_usd), 0) from public.settlements
    where merchant_id = v_merchant and status = 'pending'
  ) <> v_upfront then
    raise exception 'La cola de pago debía tener % (el adelanto), no otra cosa', v_upfront;
  end if;

  -- El cuadre se comprueba sobre el libro ENTERO, no sumando cuentas
  -- escogidas a mano. `cash` y `platform_revenue` son globales y acumulan las
  -- ventas de todos: sumarlas junto a las de un solo usuario solo da cero por
  -- casualidad, cuando la base está vacía.
  select round(sum(debit) - sum(credit), 4) into v_cash from ledger.entries;
  if v_cash <> 0 then
    raise exception 'El libro completo no cuadra: diferencia %', v_cash;
  end if;

  raise notice 'TEST 5 OK — libro completo cuadra en cero · pendiente al comercio: %', v_pay;

  raise notice '=== TODOS LOS TESTS DE COBRO/PAGO PASARON ===';
end $$;

-- Fuerza el disparo de los constraint triggers DIFERIDOS del ledger (el
-- cuadre de partida doble). Sin esto, el rollback los saltaria y la prueba
-- pasaria en verde sin haber comprobado nunca que el libro cuadra.
set constraints all immediate;

rollback;
