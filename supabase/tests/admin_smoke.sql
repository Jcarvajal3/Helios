-- ============================================================================
-- Ronda — Prueba de humo del super admin
--
-- docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--   -v ON_ERROR_STOP=1 -f supabase/tests/admin_smoke.sql
--
-- Lo que de verdad importa comprobar aquí es el aislamiento: que el operador
-- vea la cola completa y que un usuario normal NO vea nada ajeno, ni pueda
-- conciliarse un pago a sí mismo.
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
  v_seen     integer;
  v_failed   boolean;
  v_result   jsonb;
  v_logged   integer;
  v_queue    jsonb;
  v_pago     jsonb;
  v_compra   jsonb;
begin
  -- --- Fixtures ----------------------------------------------------------
  -- Helios (H3): el paciente no tiene cuenta en Auth; es solo una fila de `profiles`.
  insert into public.profiles (id, phone_e164) values
    (v_ana, '+584140000042');

  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_admin,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000041', now(), now(), now()),
    (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000043', now(), now(), now());

  update public.profiles set status = 'active' where id in (v_ana, v_cajero);

  insert into public.platform_admins (user_id, role, full_name)
  values (v_admin, 'super_admin', 'Operador Test');

  insert into public.merchants (name) values ('Bar Admin') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_merchant, v_branch, 'cajero');

  -- Helios: aquí iba el PIN de la prueba (`set_user_pin` y el pepper de
  -- Vault). Sin app no hay PIN: la deuda la crea `pg_temp.prueba_cobro`.

  -- Una venta y su reporte de pago.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  reset role;  -- Helios (H3): el paciente no se autentica; esto corre como el sistema, con sus claims.
  v_charge := (pg_temp.prueba_cobro(v_ana, v_merchant, v_branch, v_cajero, 16.00, 'admin-1', 'Consumo')->>'charge_id')::uuid;

  select array_agg(id) into v_insts
  from public.installments where user_id = v_ana and status = 'pending';

  v_qid := (pg_temp.quote_installments(v_insts)->>'quote_id')::uuid;
  v_report := (pg_temp.report_payment(v_qid, 'pago_movil', 'BNC', '777001', 'V-1', '0414')->>'report_id')::uuid;

  -- --- 1. El operador ve la cola -----------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  select count(*) into v_seen from public.payment_queue where report_id = v_report;
  if v_seen <> 1 then
    raise exception 'El operador debía ver el reporte en la cola, vio % filas', v_seen;
  end if;
  raise notice 'TEST ADMIN 1 OK — el operador ve la cola de conciliación';

  -- --- 1b. Y ve DE QUÉ es cada pago --------------------------------------
  -- Un importe con un banco y una referencia no se puede conciliar: hay que
  -- saber qué compra, qué cuota y de quién. Se comprueba el árbol entero
  -- porque es el dato que hace aprobable el pago, no un adorno.
  v_queue := public.admin_payment_queue(array['reported', 'in_review']);

  select item into v_pago
  from jsonb_array_elements(v_queue) item
  where (item->>'report_id')::uuid = v_report;

  if v_pago is null then
    raise exception 'El reporte debía salir en admin_payment_queue';
  end if;

  if jsonb_array_length(v_pago->'purchases') <> 1 then
    raise exception 'El pago cubre UNA compra, la cola devuelve %',
      jsonb_array_length(v_pago->'purchases');
  end if;

  v_compra := v_pago->'purchases'->0;

  if (v_compra->>'charge_id')::uuid <> v_charge then
    raise exception 'La compra del pago debía ser %, es %', v_charge, v_compra->>'charge_id';
  end if;

  if v_compra->>'merchant_name' <> 'Bar Admin' then
    raise exception 'La compra debía traer el comercio, trajo %', v_compra->>'merchant_name';
  end if;

  -- Las dos cuotas del consumo, con su número y su vencimiento.
  if jsonb_array_length(v_compra->'installments') <> 2
     or (v_compra->>'installments_total')::integer <> 2 then
    raise exception 'La compra debía traer sus 2 cuotas: %', v_compra;
  end if;

  if (v_compra->'installments'->0->>'sequence')::integer <> 1
     or (v_compra->'installments'->0->>'due_date') is null then
    raise exception 'La cuota debía traer número y vencimiento: %', v_compra->'installments'->0;
  end if;

  if (v_pago->'user'->>'user_id')::uuid <> v_ana then
    raise exception 'El pago debía decir de quién es, dijo %', v_pago->'user';
  end if;

  raise notice 'TEST ADMIN 1b OK — la cola dice compra, cuota y usuario de cada pago';

  -- Y sigue siendo cosa de Ronda: la RPC tiene el mismo portero que la vista.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.admin_payment_queue();
  exception when others then
    v_failed := true;
    raise notice 'TEST ADMIN 1c OK — un cajero no puede leer la cola: %', sqlerrm;
  end;
  if not v_failed then
    raise exception 'admin_payment_queue no debía contestarle a un cajero';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  -- --- 2. Un usuario normal NO ve pagos ajenos ---------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  select count(*) into v_seen from public.payment_queue;
  if v_seen <> 0 then
    raise exception 'Un cajero no debía ver NINGÚN pago en la cola, vio %', v_seen;
  end if;
  raise notice 'TEST ADMIN 2 OK — un usuario normal no ve la cola (%)', v_seen;

  -- --- 3. Un usuario normal no puede conciliar ----------------------------
  v_failed := false;
  begin
    perform public.admin_reconcile_payment(v_report, true, null);
  exception when others then
    v_failed := true;
    raise notice 'TEST ADMIN 3 OK — conciliar sin ser admin rebota: %', sqlerrm;
  end;
  if not v_failed then
    raise exception 'Un cajero no debía poder conciliar un pago';
  end if;

  -- --- 4. Rechazar exige motivo -------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  v_failed := false;
  begin
    perform public.admin_reconcile_payment(v_report, false, null);
  exception when others then
    v_failed := true;
    raise notice 'TEST ADMIN 4 OK — rechazar sin motivo rebota: %', sqlerrm;
  end;
  if not v_failed then
    raise exception 'Rechazar sin motivo no debía permitirse';
  end if;

  -- --- 5. El operador concilia, y queda en la bitácora --------------------
  v_result := public.admin_reconcile_payment(v_report, true, 'verificado en estado de cuenta');

  if (v_result->>'status') <> 'reconciled' then
    raise exception 'La conciliación debía tener éxito: %', v_result;
  end if;

  reset role;
  select count(*) into v_logged
  from audit.admin_actions
  where actor = v_admin and action = 'payment.reconciled' and target_id = v_report;

  if v_logged <> 1 then
    raise exception 'La acción debía quedar en la bitácora, hay % filas', v_logged;
  end if;
  raise notice 'TEST ADMIN 5 OK — conciliado por $% y registrado en audit.admin_actions',
    v_result->>'amount_usd';

  -- --- 5b. La cuota dice qué pago la saldó --------------------------------
  -- `paid_at` decía cuándo y nunca con qué. Sin esta columna, atribuir un pago
  -- a una cuota era un `join` de tres saltos que el esquema no garantizaba
  -- único.
  select count(*) into v_seen
  from public.installments
  where user_id = v_ana and status = 'paid' and paid_by_report_id = v_report;

  if v_seen <> 2 then
    raise exception 'Las 2 cuotas debían apuntar al reporte que las saldó, apuntan %', v_seen;
  end if;
  raise notice 'TEST ADMIN 5b OK — % cuotas saben qué pago las saldó', v_seen;

  -- Y al revés: desde la cuota se llega a todos sus intentos de pago.
  select count(*) into v_seen
  from public.installment_payments
  where installment_id = v_insts[1] and report_id = v_report;

  if v_seen <> 1 then
    raise exception 'installment_payments debía enlazar la cuota con su pago, devolvió %', v_seen;
  end if;
  raise notice 'TEST ADMIN 5c OK — desde la cuota se ven sus pagos';

  -- --- 6. La bitácora no se puede reescribir ------------------------------
  v_failed := false;
  begin
    update audit.admin_actions set action = 'manipulado' where actor = v_admin;
  exception when others then
    v_failed := true;
    raise notice 'TEST ADMIN 6 OK — la bitácora es append-only: %', sqlerrm;
  end;
  if not v_failed then
    raise exception 'La bitácora no debía admitir UPDATE';
  end if;

  raise notice '=== TODOS LOS TESTS DE SUPER ADMIN PASARON ===';
end $$;

set constraints all immediate;

rollback;
