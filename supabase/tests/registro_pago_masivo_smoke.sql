-- ============================================================================
-- Helios — Prueba de humo del registro del pago masivo
--
--   bash supabase/tests/run.sh registro_pago_masivo_smoke
--
-- Bajar el archivo guarda el lote (`admin_create_bulk_payout`) y, cuando el
-- banco lo procesa, se registra de una vez (`admin_register_bulk_payout`).
-- Lo que se vigila: que solo lo haga un super admin, que el lote no se guarde
-- si los bolívares ya no son los de hoy, que el registro sea todo o nada, que
-- cada transferencia lleve los bolívares, la fecha, la referencia y las tasas
-- del archivo, que una línea pagada por otro lado no se registre y que
-- registrar dos veces no registre nada dos veces.
-- ============================================================================

begin;

-- @ayudas

-- Un lote de `admin_bulk_payouts` por su id: los de la prueba nacen en el
-- mismo instante y el orden entre ellos no está dicho.
create function pg_temp.lote(p_id uuid)
returns jsonb
language sql
as $$
  select b from jsonb_array_elements(public.admin_bulk_payouts(50)) b where (b->>'id')::uuid = p_id;
$$;

do $$
declare
  v_admin    uuid := gen_random_uuid();
  v_operador uuid := gen_random_uuid();
  v_cajero_a uuid := gen_random_uuid();
  v_cajero_b uuid := gen_random_uuid();
  v_pac_a    uuid := gen_random_uuid();
  v_pac_b    uuid := gen_random_uuid();
  v_hoy      date := public.helios_business_date(now());
  v_m_a      uuid;
  v_m_b      uuid;
  v_br_a     uuid;
  v_br_b     uuid;
  v_ch_a     uuid;
  v_ch_b     uuid;
  v_due      date;
  v_hoja     jsonb;
  v_fa       jsonb;
  v_fb       jsonb;
  v_lineas   jsonb;
  v_res      jsonb;
  v_lote     uuid;
  v_lote2    uuid;
  v_lotes    jsonb;
  v_la       uuid;
  v_lb       uuid;
  v_p        public.merchant_payouts%rowtype;
  v_n        integer;
  v_failed   boolean;
  v_msg      text;
begin
  -- --- Fixtures ----------------------------------------------------------
  insert into public.profiles (id, phone_e164) values
    (v_pac_a, '+584140000171'),
    (v_pac_b, '+584140000172');

  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_admin,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000173', now(), now(), now()),
    (v_operador, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000174', now(), now(), now()),
    (v_cajero_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000175', now(), now(), now()),
    (v_cajero_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000176', now(), now(), now());

  insert into public.platform_admins (user_id, role, full_name) values
    (v_admin, 'super_admin', 'Jefa'),
    (v_operador, 'operador', 'Caja');

  -- Tasas fijas de hoy: los bolívares salen en números conocidos.
  perform public.record_fx_rate(800, v_hoy, 'BCV');
  perform public.record_fx_rate(900, v_hoy, 'BCV_EUR');

  insert into public.merchants (name) values ('Clínica Masiva A') returning id into v_m_a;
  insert into public.merchants (name) values ('Clínica Masiva B') returning id into v_m_b;
  select id into v_br_a from public.merchant_branches where merchant_id = v_m_a and is_default;
  select id into v_br_b from public.merchant_branches where merchant_id = v_m_b and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_cajero_a, v_m_a, v_br_a, 'cajero'),
    (v_cajero_b, v_m_b, v_br_b, 'cajero');

  insert into public.merchant_payout_accounts (merchant_id, bank, account_holder, holder_document, account_number)
  values
    (v_m_a, 'Banco A', 'Clínica Masiva A, C.A.', 'J-12345678-9', '01020000000000000171'),
    (v_m_b, 'Banco B', 'Clínica Masiva B, C.A.', 'J-87654321-0', '01020000000000000172');

  -- Una consulta en cada una; su primera mitad vence y se pasa a ayer, para
  -- que entre en el pago de hoy.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_pac_a::text, 'role', 'authenticated')::text, true);
  v_ch_a := (pg_temp.prueba_cobro(v_pac_a, v_m_a, v_br_a, v_cajero_a, 100.00, 'masivo-a', 'Consulta')->>'charge_id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', v_pac_b::text, 'role', 'authenticated')::text, true);
  v_ch_b := (pg_temp.prueba_cobro(v_pac_b, v_m_b, v_br_b, v_cajero_b, 80.00, 'masivo-b', 'Consulta')->>'charge_id')::uuid;
  reset role;

  select due_date into v_due from public.installments where charge_id = v_ch_a and sequence = 1;
  perform public.run_scheduled_settlements(v_due);
  select due_date into v_due from public.installments where charge_id = v_ch_b and sequence = 1;
  perform public.run_scheduled_settlements(v_due);

  update public.settlements set due_date = v_hoy - 1
  where merchant_id in (v_m_a, v_m_b);

  -- --- 1. Un operador no guarda el lote ----------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_operador::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  v_failed := false;
  begin
    perform public.admin_create_bulk_payout(v_hoy, 'Pago Helios', '01910000000000000001', '[]'::jsonb);
  exception when others then
    v_failed := sqlstate = '42501';
  end;
  if not v_failed then
    raise exception 'REGISTRO MASIVO 1: un operador guardó un lote';
  end if;

  -- --- 2. El super admin guarda el lote con las filas de la hoja ---------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  v_hoja := public.admin_bulk_payout_sheet();
  -- Con los claims puestos, las RPC saben quién es; sin el rol, la prueba
  -- puede mirar las tablas y la bitácora (los permisos los vigilan 1 y 9).
  reset role;
  select f into v_fa from jsonb_array_elements(v_hoja->'merchants') f where (f->>'merchant_id')::uuid = v_m_a;
  select f into v_fb from jsonb_array_elements(v_hoja->'merchants') f where (f->>'merchant_id')::uuid = v_m_b;

  if v_fa is null or v_fb is null then
    raise exception 'REGISTRO MASIVO 2: las clínicas de la prueba no están en la hoja';
  end if;
  if (v_fa->>'pending_ves')::numeric <> round((v_fa->>'pending_usd_part')::numeric * 800, 2) then
    raise exception 'REGISTRO MASIVO 2: los bolívares de A no van a la tasa de la prueba: %', v_fa;
  end if;

  v_lineas := jsonb_build_array(
    jsonb_build_object('merchant_id', v_m_a, 'reference', to_char(v_hoy, 'MMDD') || '0001',
      'amount_ves', v_fa->'pending_ves', 'beneficiary_account', '01020000000000000171',
      'beneficiary_id', 'J123456789', 'beneficiary_name', 'Clínica Masiva A, C.A.'),
    jsonb_build_object('merchant_id', v_m_b, 'reference', to_char(v_hoy, 'MMDD') || '0002',
      'amount_ves', v_fb->'pending_ves', 'beneficiary_account', '01020000000000000172',
      'beneficiary_id', 'J876543210', 'beneficiary_name', 'Clínica Masiva B, C.A.'));

  -- 2a. Si los bolívares ya no son los de hoy, no se guarda.
  v_failed := false;
  begin
    perform public.admin_create_bulk_payout(v_hoy, 'Pago Helios', '01910000000000000001',
      jsonb_set(v_lineas, '{0,amount_ves}', to_jsonb((v_fa->>'pending_ves')::numeric + 1)));
  exception when others then
    v_failed := sqlerrm like '%cambió%';
  end;
  if not v_failed then
    raise exception 'REGISTRO MASIVO 2a: se guardó un lote con bolívares que ya no son los de hoy';
  end if;

  -- 2b. Ni con fecha de pago de ayer.
  v_failed := false;
  begin
    perform public.admin_create_bulk_payout(v_hoy - 1, 'Pago Helios', '01910000000000000001', v_lineas);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'REGISTRO MASIVO 2b: se guardó un lote con fecha de pago de ayer';
  end if;

  v_res := public.admin_create_bulk_payout(v_hoy, 'Pago Helios', '01910000000000000001', v_lineas);
  v_lote := (v_res->>'bulk_payout_id')::uuid;

  if (v_res->>'lines')::int <> 2
     or (v_res->>'total_ves')::numeric
        <> (v_fa->>'pending_ves')::numeric + (v_fb->>'pending_ves')::numeric then
    raise exception 'REGISTRO MASIVO 2: el lote no trae las dos filas con sus bolívares: %', v_res;
  end if;
  if not exists (select 1 from audit.admin_actions where action = 'merchant.bulk_payout_file' and target_id = v_lote) then
    raise exception 'REGISTRO MASIVO 2: guardar el lote no dejó bitácora';
  end if;

  -- --- 3. La lectura: las dos líneas, pendientes --------------------------
  v_lotes := pg_temp.lote(v_lote);
  if v_lotes is null
     or jsonb_array_length(v_lotes->'lines') <> 2
     or exists (select 1 from jsonb_array_elements(v_lotes->'lines') l where l->>'state' <> 'pendiente') then
    raise exception 'REGISTRO MASIVO 3: el lote no se lee con sus dos líneas pendientes: %', v_lotes;
  end if;

  select id into v_la from public.bulk_payout_lines where bulk_payout_id = v_lote and merchant_id = v_m_a;
  select id into v_lb from public.bulk_payout_lines where bulk_payout_id = v_lote and merchant_id = v_m_b;

  -- --- 4. Un lote que el banco paga mañana no se registra hoy ------------
  v_lote2 := (public.admin_create_bulk_payout(v_hoy + 1, 'Pago Helios', '01910000000000000001', v_lineas)->>'bulk_payout_id')::uuid;
  v_failed := false;
  begin
    perform public.admin_register_bulk_payout(v_lote2,
      (select jsonb_agg(jsonb_build_object('line_id', id)) from public.bulk_payout_lines where bulk_payout_id = v_lote2));
  exception when others then
    v_failed := sqlerrm like '%regístralo ese día%';
  end;
  if not v_failed then
    raise exception 'REGISTRO MASIVO 4: se registró un lote antes de su fecha de pago';
  end if;

  -- --- 5. B se paga a mano: su línea cambia y el registro es todo o nada --
  perform public.admin_report_merchant_payout(v_m_b,
    (select array_agg(id) from public.settlements where merchant_id = v_m_b and status = 'pending'),
    'transferencia', 'MANUAL-B');

  if (select l->>'state' from jsonb_array_elements(pg_temp.lote(v_lote)->'lines') l
      where (l->>'id')::uuid = v_lb) <> 'cambio' then
    raise exception 'REGISTRO MASIVO 5: la línea de B no dice que se pagó por otro lado';
  end if;

  v_failed := false;
  begin
    perform public.admin_register_bulk_payout(v_lote,
      jsonb_build_array(jsonb_build_object('line_id', v_la), jsonb_build_object('line_id', v_lb)));
  exception when others then
    v_failed := sqlerrm like '%Clínica Masiva B%';
  end;
  if not v_failed then
    raise exception 'REGISTRO MASIVO 5: se registró una línea que ya se había pagado por otro lado';
  end if;
  if exists (select 1 from public.merchant_payouts where merchant_id = v_m_a)
     or (select payout_id from public.bulk_payout_lines where id = v_la) is not null then
    raise exception 'REGISTRO MASIVO 5: el registro fallido dejó registrada la línea de A';
  end if;

  -- --- 6. Se registra A, con la referencia del banco ---------------------
  v_res := public.admin_register_bulk_payout(v_lote,
    jsonb_build_array(jsonb_build_object('line_id', v_la, 'reference', 'BANCO123')),
    'Pago masivo de hoy');

  if (v_res->>'registered')::int <> 1 or (v_res->>'already_registered')::int <> 0 then
    raise exception 'REGISTRO MASIVO 6: debía registrarse una línea: %', v_res;
  end if;

  select * into v_p from public.merchant_payouts where merchant_id = v_m_a;
  if v_p.method <> 'transferencia'
     or v_p.reference <> 'BANCO123'
     or v_p.paid_on <> v_hoy
     or v_p.amount_ves <> (v_fa->>'pending_ves')::numeric
     or abs(v_p.amount_usd - (v_fa->>'pending_usd')::numeric) > 0.00005
     or v_p.fx_rate <> 800
     or v_p.fx_rate_eur is not null
     or v_p.note <> 'Pago masivo de hoy' then
    raise exception 'REGISTRO MASIVO 6: la transferencia no lleva lo del archivo: %', to_jsonb(v_p);
  end if;

  if exists (select 1 from public.settlements where merchant_id = v_m_a and status <> 'paid') then
    raise exception 'REGISTRO MASIVO 6: las liquidaciones de A no quedaron pagadas';
  end if;
  if not exists (select 1 from ledger.transactions where idempotency_key = 'payout:' || v_p.id::text) then
    raise exception 'REGISTRO MASIVO 6: la transferencia no tiene su asiento';
  end if;
  if (select payout_id from public.bulk_payout_lines where id = v_la) <> v_p.id then
    raise exception 'REGISTRO MASIVO 6: la línea no apunta a su transferencia';
  end if;
  if not exists (select 1 from audit.admin_actions where action = 'merchant.bulk_payout' and target_id = v_lote)
     or not exists (select 1 from audit.admin_actions where action = 'merchant.payout' and target_id = v_m_a) then
    raise exception 'REGISTRO MASIVO 6: el registro no dejó bitácora';
  end if;

  -- --- 7. Registrarlo otra vez no registra nada --------------------------
  v_res := public.admin_register_bulk_payout(v_lote, jsonb_build_array(jsonb_build_object('line_id', v_la)));
  select count(*) into v_n from public.merchant_payouts where merchant_id = v_m_a;
  if (v_res->>'registered')::int <> 0 or (v_res->>'already_registered')::int <> 1 or v_n <> 1 then
    raise exception 'REGISTRO MASIVO 7: registrar dos veces registró algo: % (% transferencias)', v_res, v_n;
  end if;

  if (select l->>'state' from jsonb_array_elements(pg_temp.lote(v_lote)->'lines') l
      where (l->>'id')::uuid = v_la) <> 'registrada' then
    raise exception 'REGISTRO MASIVO 7: la línea de A no se lee como registrada';
  end if;

  -- --- 8. El otro lote, con lo mismo, ya no se puede registrar -----------
  if exists (
    select 1 from jsonb_array_elements(pg_temp.lote(v_lote2)->'lines') l
    where l->>'state' <> 'cambio'
  ) then
    raise exception 'REGISTRO MASIVO 8: el lote de mañana sigue ofreciendo lo que ya se pagó';
  end if;

  -- --- 9. Un operador lee, pero no registra ------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_operador::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_bulk_payouts(5);
  v_failed := false;
  begin
    perform public.admin_register_bulk_payout(v_lote, jsonb_build_array(jsonb_build_object('line_id', v_la)));
  exception when others then
    v_failed := sqlstate = '42501';
  end;
  if not v_failed then
    raise exception 'REGISTRO MASIVO 9: un operador registró un pago masivo';
  end if;
  reset role;

  raise notice 'REGISTRO MASIVO OK';
end;
$$;

set constraints all immediate;
rollback;
