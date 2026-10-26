-- ============================================================================
-- Helios — Un pago cuadra con margen: 10 Bs por debajo, 100 por encima
-- (20261026150000)
--
--   bash supabase/tests/run.sh margen_de_pago_smoke
--
--  1. La regla y sus bordes, y que manda el parámetro.
--  2. El lector: 13,42 Bs de más (el caso de Andrea Toledo) registra el pago;
--     10,01 de menos o 100,01 de más van al equipo.
--  3. El aviso del BNC aprueba el pago que cuadra con margen.
--  4. El extracto: la línea con 13,42 de más es candidata del pago, y un pago
--     aprobado la saca de «Abonos sin dueño».
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_op       uuid := gen_random_uuid();
  v_super    uuid := gen_random_uuid();
  v_staff    uuid := gen_random_uuid();
  v_pac      uuid := gen_random_uuid();
  v_tel      text := '+584140009601';
  v_merchant uuid;
  v_branch   uuid;
  v_ca       uuid;
  v_cb       uuid;
  v_a1       uuid;
  v_b1       uuid;
  v_today    date := public.helios_business_date(now());
  v_dia      text := to_char(public.helios_business_date(now()), 'DD/MM/YY');
  v_q        numeric;
  v_res      jsonb;
  v_id       uuid;
  v_rep      uuid;
  v_linea    uuid;
  v_x        jsonb := jsonb_build_object('es_comprobante', true, 'estado', 'exitosa');
begin
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'u-' || u || '@prueba.helios.test', now(), now(), now()
  from unnest(array[v_op, v_super, v_staff]) u;
  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_op, 'operador', 'Operadora Margen', true),
         (v_super, 'super_admin', 'Super Margen', true);
  insert into public.merchants (name) values ('Clínica Margen') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values (v_staff, v_merchant, v_branch, 'cajero');
  insert into public.profiles (id, phone_e164, first_name, full_name) values (v_pac, v_tel, 'Andrea', 'Andrea Margen');

  update public.levels set monthly_limit_usd = 500 where level = 1;
  insert into public.business_parameters (key, value, effective_from, note)
  values ('payment_four_eyes', 0, v_today, 'prueba')
  on conflict (key, effective_from) do update set value = excluded.value;
  insert into public.exchange_rates (source, rate, effective_date)
  values ('BCV', 886.227100, v_today - 1)
  on conflict (source, effective_date) do update set rate = excluded.rate;

  update public.bank_sms_settings set mode = 'activo', actor = v_super, allowed_sender = null;
  update public.receipt_reader_settings set mode = 'activo', daily_cap = 50;
  insert into public.whatsapp_contacts (phone_e164, last_inbound_at) values (v_tel, now())
  on conflict (phone_e164) do update set last_inbound_at = now();

  v_ca := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 28.00, 'margen-a')->>'charge_id')::uuid;
  v_cb := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 28.00, 'margen-b')->>'charge_id')::uuid;
  select id into v_a1 from public.installments where charge_id = v_ca and sequence = 1;
  select id into v_b1 from public.installments where charge_id = v_cb and sequence = 1;
  v_q := public.helios_installments_ves(v_pac, array[v_a1], v_today);

  -- --- 1. La regla ------------------------------------------------------------
  if public.helios_parameter('payment_margin_under_ves', null) <> 10
     or public.helios_parameter('payment_margin_over_ves', null) <> 100 then
    raise exception 'Los márgenes por defecto son 10 y 100 Bs';
  end if;
  if not (public.helios_monto_cuadra(v_q + 13.42, v_q) and public.helios_monto_cuadra(v_q - 10, v_q)
          and public.helios_monto_cuadra(v_q + 100, v_q) and public.helios_monto_cuadra(v_q, v_q)) then
    raise exception 'Dentro del margen tiene que cuadrar';
  end if;
  if public.helios_monto_cuadra(v_q - 10.01, v_q) or public.helios_monto_cuadra(v_q + 100.01, v_q) then
    raise exception 'Fuera del margen no cuadra';
  end if;
  if not public.helios_monto_cuadra(v_q + 500, v_q, 600) then
    raise exception 'Con una tolerancia propia (el panel ensancha la búsqueda) también cuadra';
  end if;

  -- --- 2. El lector -----------------------------------------------------------
  -- El caso de Andrea: 13,42 Bs de más.
  v_id := (public.bot_comprobante_nuevo('wamid.mrg.1', v_tel, v_pac, 'm1', 'image/jpeg')->>'id')::uuid;
  perform public.lector_tomar(5);
  v_res := public.lector_leido(v_id, null, v_x,
             jsonb_build_object('method', 'pago_movil', 'bank', 'Banco de Venezuela', 'reference', '001194314348',
                                'amount_ves', v_q + 13.42, 'paid_on', v_today), 'claude-sonnet-5-5', '{}');
  if v_res->>'status' <> 'registrado' then
    raise exception 'Con 13,42 Bs de más el lector registra el pago: %', v_res;
  end if;
  select report_id into v_rep from public.payment_receipt_reads where id = v_id;

  -- El SMS de ese pago, por lo pagado: lo aprueba.
  v_res := public.helios_bank_sms_ingest(format(
    'BNC Pago Movil Recibido Bs.%s Telf.0422***8234 Dia:%s-16:35 Ref:194314348',
    replace(to_char(v_q + 13.42, 'FM999999990.00'), '.', ','), v_dia), '2622');
  set constraints all immediate;
  set constraints all deferred;
  if (select status from public.payment_reports where id = v_rep) <> 'reconciled' then
    raise exception '3. El SMS que cuadra con margen aprueba el pago: %', v_res;
  end if;

  -- Fuera del margen, al equipo.
  v_id := (public.bot_comprobante_nuevo('wamid.mrg.2', v_tel, v_pac, 'm2', 'image/jpeg')->>'id')::uuid;
  perform public.lector_tomar(5);
  perform public.lector_leido(v_id, null, v_x,
            jsonb_build_object('method', 'pago_movil', 'bank', 'Banesco', 'reference', '0099887766',
                               'amount_ves', v_q - 10.01, 'paid_on', v_today), 'claude-sonnet-5-5', '{}');
  if (select reason from public.payment_receipt_reads where id = v_id) <> 'monto_no_cuadra' then
    raise exception '10,01 Bs de menos no cuadra';
  end if;
  perform public.bot_paciente_guardar(v_tel, null, 0, null, null);

  v_id := (public.bot_comprobante_nuevo('wamid.mrg.3', v_tel, v_pac, 'm3', 'image/jpeg')->>'id')::uuid;
  perform public.lector_tomar(5);
  perform public.lector_leido(v_id, null, v_x,
            jsonb_build_object('method', 'pago_movil', 'bank', 'Banesco', 'reference', '0099887767',
                               'amount_ves', v_q + 100.01, 'paid_on', v_today), 'claude-sonnet-5-5', '{}');
  if (select reason from public.payment_receipt_reads where id = v_id) <> 'monto_no_cuadra' then
    raise exception '100,01 Bs de más no cuadra';
  end if;
  perform public.bot_paciente_guardar(v_tel, null, 0, null, null);

  -- El parámetro manda: con margen 0 por encima, 13,42 de más ya no cuadra.
  insert into public.business_parameters (key, value, effective_from, note)
  values ('payment_margin_over_ves', 0, v_today, 'prueba')
  on conflict (key, effective_from) do update set value = excluded.value;
  if public.helios_monto_cuadra(v_q + 13.42, v_q) then
    raise exception 'El margen por encima lo decide el parámetro';
  end if;
  update public.business_parameters set value = 100 where key = 'payment_margin_over_ves' and effective_from = v_today;

  -- --- 4. El extracto ---------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_res := public.admin_register_payment(v_pac, array[v_b1], 'pago_movil', 'Banco de Venezuela', '1194319999',
                                         v_today, v_q + 13.42, null, null);
  v_rep := (v_res->>'report_id')::uuid;

  insert into public.bank_statement_lines (bank, moved_on, reference, amount_ves, fingerprint, imported_by, description)
  values ('BNC Banco Nacional de Crédito', v_today, '1194319999', v_q + 13.42, 'prueba-margen-' || gen_random_uuid(),
          v_op, 'Abono Pago Movil BNC - ref: 1194319999')
  returning id into v_linea;

  if not exists (select 1 from public.helios_statement_candidates(v_rep) c where c.id = v_linea) then
    raise exception 'La línea del extracto con 13,42 Bs de más es candidata del pago registrado';
  end if;
  if (public.helios_admin_payment_item(v_rep, v_today)->>'statement_matches')::integer < 1 then
    raise exception 'La ficha del pago cuenta la línea que cuadra con margen';
  end if;

  -- Aprobado el pago (sin ligar la línea), la línea deja de ser «sin dueño».
  perform public.reconcile_payment(v_rep, v_op, true, 'prueba');
  update public.payment_reports set statement_line_id = null where id = v_rep;
  if exists (select 1 from jsonb_array_elements(public.admin_unmatched_deposits(500)) e
             where (e->>'id')::uuid = v_linea) then
    raise exception 'Una línea que cuadra con margen con un pago aprobado no es un abono sin dueño';
  end if;
end $$;

rollback;
