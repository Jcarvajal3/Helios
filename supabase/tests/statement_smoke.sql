-- ============================================================================
-- Ronda — Prueba de humo del importador de estados de cuenta
--
-- docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--   -v ON_ERROR_STOP=1 -f supabase/tests/statement_smoke.sql
--
-- Lo importante: que el cotejo sea FUERTE pese a que el usuario solo reporta
-- 6 dígitos. Se comprueba que exige las tres condiciones a la vez —
-- referencia, monto y fecha— y que ninguna sobra.
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
  v_insts    uuid[];
  v_qid      uuid;
  v_report   uuid;
  v_result   jsonb;
  v_matches  jsonb;
  v_hits     integer;
  v_ves      numeric;
begin
  -- --- Fixtures: una venta de $20 reportada con referencia 447781 --------
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_admin,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000071', now(), now(), now()),
    (v_ana,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000072', now(), now(), now()),
    (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000073', now(), now(), now());

  update public.profiles set status = 'active' where id = v_ana;
  insert into public.platform_admins (user_id, role, full_name)
  values (v_admin, 'operador', 'Operador');

  insert into public.merchants (name) values ('Bar Estado') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_merchant, v_branch, 'cajero');

  -- Helios: aquí iba el PIN de la prueba (`set_user_pin` y el pepper de
  -- Vault). Sin app no hay PIN: la deuda la crea `pg_temp.prueba_cobro`.

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  v_charge := (pg_temp.prueba_cobro(v_ana, v_merchant, v_branch, v_cajero, 20.00, 'stmt-1', 'Consumo')->>'charge_id')::uuid;

  select array_agg(id) into v_insts
  from public.installments where user_id = v_ana and status = 'pending';

  v_qid := (public.quote_installments(v_insts)->>'quote_id')::uuid;
  select amount_ves into v_ves from public.payment_quotes where id = v_qid;

  v_report := (public.report_payment(v_qid, 'pago_movil', 'Banesco', '447781', 'V-1', '0414')->>'report_id')::uuid;

  -- --- 1. Sin estado de cuenta importado, no hay cotejo ------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  select statement_matches into v_hits from public.payment_queue where report_id = v_report;
  if v_hits <> 0 then
    raise exception 'Sin importar nada no debía haber coincidencias, hubo %', v_hits;
  end if;
  raise notice 'TEST STMT 1 OK — sin estado de cuenta, 0 coincidencias';

  -- --- 2. Importar el movimiento real -----------------------------------
  -- El banco da la referencia COMPLETA; el usuario solo reportó los 6
  -- últimos dígitos.
  v_result := public.admin_import_statement('Banesco', jsonb_build_array(
    jsonb_build_object(
      'moved_on', to_char(now(), 'YYYY-MM-DD'),
      'reference', '000123447781',
      'amount_ves', v_ves,
      'description', 'PAGO MOVIL RECIBIDO'
    ),
    jsonb_build_object(
      'moved_on', to_char(now(), 'YYYY-MM-DD'),
      'reference', '000999888777',
      'amount_ves', 5000.00,
      'description', 'OTRO MOVIMIENTO'
    )
  ));

  if (v_result->>'inserted')::int <> 2 then
    raise exception 'Debían importarse 2 líneas: %', v_result;
  end if;
  raise notice 'TEST STMT 2 OK — importadas % líneas', v_result->>'inserted';

  -- --- 3. El reporte queda verificado contra el banco --------------------
  select statement_matches into v_hits from public.payment_queue where report_id = v_report;
  if v_hits <> 1 then
    raise exception 'Debía encontrarse exactamente 1 movimiento, encontró %', v_hits;
  end if;

  v_matches := public.admin_statement_matches(v_report);
  if (v_matches->0->>'reference') <> '000123447781' then
    raise exception 'El cotejo debía traer el movimiento del banco: %', v_matches;
  end if;
  raise notice 'TEST STMT 3 OK — reporte cotejado con el movimiento % del banco',
    v_matches->0->>'reference';

  -- --- 4. Reimportar el mismo archivo no duplica -------------------------
  v_result := public.admin_import_statement('Banesco', jsonb_build_array(
    jsonb_build_object(
      'moved_on', to_char(now(), 'YYYY-MM-DD'),
      'reference', '000123447781',
      'amount_ves', v_ves,
      'description', 'PAGO MOVIL RECIBIDO'
    )
  ));

  if (v_result->>'inserted')::int <> 0 or (v_result->>'duplicates')::int <> 1 then
    raise exception 'Reimportar lo mismo no debía insertar nada: %', v_result;
  end if;
  raise notice 'TEST STMT 4 OK — reimportar no duplica (% duplicados detectados)',
    v_result->>'duplicates';

  -- --- 5. El monto tiene que cuadrar: la referencia sola no basta --------
  -- Movimiento con la MISMA referencia pero otro importe. Si el cotejo se
  -- fiara solo de la referencia, esto daría un falso positivo — que es justo
  -- el riesgo de pedir solo 6 dígitos.
  perform public.admin_import_statement('Banesco', jsonb_build_array(
    jsonb_build_object(
      'moved_on', to_char(now(), 'YYYY-MM-DD'),
      'reference', '777777447781',
      'amount_ves', v_ves + 500,
      'description', 'COINCIDENCIA DE REFERENCIA, OTRO MONTO'
    )
  ));

  select statement_matches into v_hits from public.payment_queue where report_id = v_report;
  if v_hits <> 1 then
    raise exception 'Un movimiento con la misma referencia pero otro monto no debía contar. Coincidencias: %', v_hits;
  end if;
  raise notice 'TEST STMT 5 OK — misma referencia con otro monto NO cuenta como cotejo';

  -- --- 6. La fecha también acota ----------------------------------------
  perform public.admin_import_statement('Banesco', jsonb_build_array(
    jsonb_build_object(
      'moved_on', to_char(now() - interval '40 days', 'YYYY-MM-DD'),
      'reference', '111111447781',
      'amount_ves', v_ves,
      'description', 'MISMO MONTO Y REFERENCIA PERO DE HACE UN MES'
    )
  ));

  select statement_matches into v_hits from public.payment_queue where report_id = v_report;
  if v_hits <> 1 then
    raise exception 'Un movimiento fuera de la ventana de fechas no debía contar. Coincidencias: %', v_hits;
  end if;
  raise notice 'TEST STMT 6 OK — fuera de la ventana de fechas tampoco cuenta';

  -- --- 7. Un usuario cualquiera no puede importar ------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  declare v_failed boolean := false;
  begin
    begin
      perform public.admin_import_statement('Banesco', jsonb_build_array(
        jsonb_build_object('moved_on', '2026-08-22', 'reference', '1', 'amount_ves', 1)
      ));
    exception when others then
      v_failed := true;
      raise notice 'TEST STMT 7 OK — sin permisos rebota: %', sqlerrm;
    end;
    if not v_failed then
      raise exception 'Un cajero no debía poder importar estados de cuenta';
    end if;
  end;

  raise notice '=== TODOS LOS TESTS DE ESTADO DE CUENTA PASARON ===';
end $$;

set constraints all immediate;

rollback;
