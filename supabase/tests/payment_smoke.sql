-- ============================================================================
-- Ronda — Prueba de humo del pago de varias cuotas
--
-- docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--   -v ON_ERROR_STOP=1 -f supabase/tests/payment_smoke.sql
--
-- Cubre el flujo del diseño (Figma 66:1127 → 68:1497 → 68:1602): marcar
-- varias cuotas de órdenes distintas, cotizarlas juntas, reportar un pago
-- con una sola referencia y conciliarlo.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_ana      uuid := gen_random_uuid();
  v_cajero   uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_charge1  uuid;
  v_charge2  uuid;
  v_charge3  uuid;
  v_insts    uuid[];
  v_quote    jsonb;
  v_quote_id uuid;
  v_report   jsonb;
  v_result   jsonb;
  v_avail    jsonb;
  v_failed   boolean;
  v_paid     integer;
  v_pending  integer;
  v_review   integer;
  v_recv     numeric;
begin
  -- --- Fixtures: dos consumos, cuatro cuotas -----------------------------
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_ana,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000031', now(), now(), now()),
    (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000032', now(), now(), now());

  update public.profiles set status = 'active' where id = v_ana;

  -- Helios: la prueba razona con un nivel 1 de $50 (el de Ronda cuando se
  -- escribió; hoy los niveles son configuración y H1 los cambia).
  update public.levels set monthly_limit_usd = 50.00 where level = 1;

  -- Helios: las cuentas de cobro se configuran en Ajustes (H11) y la base
  -- nace sin ninguna (la provisional de Ronda se podó). La cotización tiene
  -- que traer una, así que la prueba siembra la suya.
  insert into public.payment_destinations (bank_name, rif, phone, holder_name, is_active)
  values ('Banco de Prueba', 'J-000000000', '0414 0000000', 'Helios (prueba)', true);

  insert into public.merchants (name) values ('Bar Pagos') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_merchant, v_branch, 'cajero');

  -- Helios: aquí iba el PIN de la prueba (`set_user_pin` y el pepper de
  -- Vault). Sin app no hay PIN: la deuda la crea `pg_temp.prueba_cobro`.

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  v_charge1 := (pg_temp.prueba_cobro(v_ana, v_merchant, v_branch, v_cajero, 20.00, 'pay-1', 'Consumo')->>'charge_id')::uuid;
  v_charge2 := (pg_temp.prueba_cobro(v_ana, v_merchant, v_branch, v_cajero, 10.00, 'pay-2', 'Consumo')->>'charge_id')::uuid;

  -- --- 1. Cotizar TODAS las cuotas de las dos órdenes ---------------------
  select array_agg(id) into v_insts
  from public.installments where user_id = v_ana and status = 'pending';

  if array_length(v_insts, 1) <> 4 then
    raise exception 'Esperaba 4 cuotas pendientes, hay %', array_length(v_insts, 1);
  end if;

  v_quote := public.quote_installments(v_insts);
  v_quote_id := (v_quote->>'quote_id')::uuid;

  -- Contra la suma REAL de las cuotas cotizadas, no contra la base del pedido:
  -- lo que se debe lleva IVA y comisión (ver la nota en `ledger_smoke`).
  if (v_quote->>'amount_usd')::numeric
     <> (select sum(amount_usd) from public.installments where id = any(v_insts)) then
    raise exception 'La cotización debía sumar lo que suman sus cuotas (%), obtuve %',
      (select sum(amount_usd) from public.installments where id = any(v_insts)), v_quote;
  end if;
  if (v_quote->>'installment_count')::int <> 4 then
    raise exception 'La cotización debía cubrir 4 cuotas, obtuve %', v_quote;
  end if;
  if (v_quote->'destination'->>'bank_name') is null then
    raise exception 'La cotización debía traer la cuenta destino: %', v_quote;
  end if;
  raise notice 'TEST PAGO 1 OK — 4 cuotas de 2 órdenes cotizadas juntas: $% = % Bs (tasa %), destino %',
    v_quote->>'amount_usd', v_quote->>'amount_ves', v_quote->>'fx_rate',
    v_quote->'destination'->>'bank_name';

  -- --- 2. No se puede cotizar una cuota ajena ----------------------------
  v_failed := false;
  begin
    perform public.quote_installments(array[gen_random_uuid()]);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Cotizar una cuota inexistente/ajena debía fallar';
  end if;
  raise notice 'TEST PAGO 2 OK — no se pueden cotizar cuotas ajenas';

  -- --- 3. Reportar el pago con UNA sola referencia ------------------------
  v_report := public.report_payment(
    v_quote_id, 'pago_movil', 'BNC', '123456', 'V-12345678', '04141234567'
  );

  if (v_report->>'status') <> 'reported' then
    raise exception 'El reporte debía quedar en reported, obtuve %', v_report;
  end if;
  raise notice 'TEST PAGO 3 OK — reporte creado en estado % por $%',
    v_report->>'status', v_report->>'amount_usd';

  -- --- 4. Segundo reporte sobre las mismas cuotas: rechazado -------------
  v_failed := false;
  begin
    perform public.report_payment(v_quote_id, 'pago_movil', 'BNC', '999999', 'V-1', '0414');
  exception when others then
    v_failed := true;
    raise notice 'TEST PAGO 4 OK — segundo reporte rechazado: %', sqlerrm;
  end;
  if not v_failed then
    raise exception 'No debía permitirse un segundo reporte sobre cuotas ya reportadas';
  end if;

  -- --- 4b. Con un pago en revisión NO se puede volver a cotizar ----------
  -- El corte tiene que estar en la COTIZACIÓN y no solo en el reporte: si no,
  -- el usuario transfiere el dinero y descubre el rechazo después.
  v_failed := false;
  begin
    perform public.quote_installments(v_insts);
  exception when others then
    v_failed := true;
    raise notice 'TEST PAGO 4b OK — cotizar cuotas ya reportadas se rechaza: %', sqlerrm;
  end;
  if not v_failed then
    raise exception 'Cotizar cuotas con un pago en revisión debía fallar antes de transferir';
  end if;

  -- --- 4c. La app puede saber cuáles están en revisión --------------------
  -- Helios: `my_installments_in_review()` era la vista de la app (podada). Lo
  -- mismo que contaba, leído directo: cuotas con un reporte abierto de v_ana.
  select count(distinct qi.installment_id) into v_review
  from public.payment_reports r
  join public.payment_quote_items qi on qi.quote_id = r.quote_id
  where r.user_id = v_ana and r.status in ('reported', 'in_review');
  if v_review <> 4 then
    raise exception 'Las 4 cuotas debían salir en revisión, salen %', v_review;
  end if;
  raise notice 'TEST PAGO 4c OK — % cuotas marcadas en revisión para la app', v_review;

  -- --- 5. Conciliar: las 4 cuotas quedan pagadas de una vez ---------------
  reset role;
  v_result := public.reconcile_payment((v_report->>'report_id')::uuid, v_cajero, true, null);

  if (v_result->>'amount_usd')::numeric <> (v_quote->>'amount_usd')::numeric then
    raise exception 'La conciliación debía mover lo cotizado (%), obtuve %',
      v_quote->>'amount_usd', v_result;
  end if;

  select count(*) into v_paid
  from public.installments where user_id = v_ana and status = 'paid';
  if v_paid <> 4 then
    raise exception 'Las 4 cuotas debían quedar pagadas, hay %', v_paid;
  end if;
  raise notice 'TEST PAGO 5 OK — % cuotas saldadas con un solo asiento por $%',
    v_paid, v_result->>'amount_usd';

  -- --- 6. Deuda a cero: el bloque se cierra y el límite vuelve entero -----
  select ledger.account_balance(id) into v_recv
    from ledger.accounts where account_type = 'user_receivable' and owner_id = v_ana;
  if v_recv <> 0 then
    raise exception 'user_receivable debía quedar en 0, quedó en %', v_recv;
  end if;

  if not exists (
    select 1 from public.user_credit_blocks
    where user_id = v_ana and close_reason = 'paid' and closed_at is not null
  ) then
    raise exception 'El bloque debía cerrarse al saldar todo';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  -- Conciliado el reporte, ninguna cuota sigue "en revisión": el estado lo
  -- manda el reporte, no una marca aparte que haya que acordarse de limpiar.
  -- Helios: `my_installments_in_review()` era la vista de la app (podada). Lo
  -- mismo que contaba, leído directo: cuotas con un reporte abierto de v_ana.
  select count(distinct qi.installment_id) into v_review
  from public.payment_reports r
  join public.payment_quote_items qi on qi.quote_id = r.quote_id
  where r.user_id = v_ana and r.status in ('reported', 'in_review');
  if v_review <> 0 then
    raise exception 'Tras conciliar no debía quedar ninguna cuota en revisión, quedan %', v_review;
  end if;
  raise notice 'TEST PAGO 6a OK — ninguna cuota queda en revisión tras conciliar';

  v_avail := pg_temp.prueba_saldo(v_ana);
  if (v_avail->>'available_usd')::numeric <> 50.00 then
    raise exception 'El disponible debía volver a 50.00, obtuve %', v_avail;
  end if;
  raise notice 'TEST PAGO 6 OK — bloque cerrado, disponible restablecido a %',
    v_avail->>'available_usd';

  -- --- 7. Un comercio sin condiciones de liquidación no salda a medias ----
  -- REGRESIÓN. El bucle de conciliación unía `merchant_settlement_terms` con
  -- INNER JOIN: una cuota de un comercio sin condiciones se caía del bucle
  -- entero. Seguía `pending`, no sumaba al asiento del ledger ni al bloque de
  -- crédito, y el reporte se marcaba `reconciled` igual. El usuario pagaba y
  -- la app le seguía pidiendo la misma cuota, sin error en ninguna parte.
  --
  -- Ahora o se saldan todas o no se salda ninguna.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  v_charge3 := (pg_temp.prueba_cobro(v_ana, v_merchant, v_branch, v_cajero, 8.00, 'pay-3', 'Consumo')->>'charge_id')::uuid;

  select array_agg(id) into v_insts
  from public.installments where user_id = v_ana and status = 'pending';

  v_quote := public.quote_installments(v_insts);
  v_report := public.report_payment(
    (v_quote->>'quote_id')::uuid, 'pago_movil', 'BNC', '654321', 'V-12345678', '04141234567'
  );

  reset role;
  -- `merchant_settlement_terms` es una vista desde 20260911206000 (las
  -- condiciones tienen vigencia): se borran las filas de `merchant_terms`.
  delete from public.merchant_terms where merchant_id = v_merchant;

  v_failed := false;
  begin
    perform public.reconcile_payment((v_report->>'report_id')::uuid, v_cajero, true, null);
  exception when others then
    v_failed := true;
    raise notice 'TEST PAGO 7 OK — conciliar un comercio sin condiciones se rechaza: %', sqlerrm;
  end;

  if not v_failed then
    raise exception 'Conciliar sin condiciones de liquidación debía fallar, no saltarse la cuota';
  end if;

  -- Y al fallar no deja nada a medias: las dos cuotas siguen pendientes.
  select count(*) into v_pending
  from public.installments where user_id = v_ana and status = 'pending';
  if v_pending <> 2 then
    raise exception 'Tras el fallo debían quedar 2 cuotas pendientes, hay %', v_pending;
  end if;
  raise notice 'TEST PAGO 7b OK — la conciliación fallida no dejó ninguna cuota saldada a medias';

  raise notice '=== TODOS LOS TESTS DE PAGO PASARON ===';
end $$;

-- Fuerza el disparo de los constraint triggers DIFERIDOS del ledger.
set constraints all immediate;

rollback;
