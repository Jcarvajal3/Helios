-- ============================================================================
-- Helios — El pago duplicado se cierra sin avisar, y asignar un abono no crea
-- otro (20261026170000)
--
--   bash supabase/tests/run.sh pago_duplicado_smoke
--
--  1. Asignar un abono a cuotas con un pago pendiente que salda justo esas
--     cuotas aprueba ESE pago con el abono: un solo pago (el caso de Andrea).
--  2. Si el pendiente salda también otras cuotas, no se adivina: error.
--  3. «Marcar como duplicado»: con motivo, sin aviso al paciente, con
--     bitácora; solo el equipo, y solo un pago pendiente.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_op       uuid := gen_random_uuid();
  v_staff    uuid := gen_random_uuid();
  v_pac      uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_ca       uuid;
  v_cb       uuid;
  v_cc       uuid;
  v_a1       uuid;
  v_b1       uuid;
  v_c1       uuid;
  v_today    date := public.helios_business_date(now());
  v_q        numeric;
  v_res      jsonb;
  v_rep      uuid;
  v_linea    uuid;
  v_n        integer;
begin
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'u-' || u || '@prueba.helios.test', now(), now(), now()
  from unnest(array[v_op, v_staff]) u;
  insert into public.platform_admins (user_id, role, full_name, is_active) values (v_op, 'operador', 'Operadora Dup', true);
  insert into public.merchants (name) values ('Clínica Dup') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values (v_staff, v_merchant, v_branch, 'cajero');
  insert into public.profiles (id, phone_e164, first_name, full_name, email)
  values (v_pac, '+584140009701', 'Andrea', 'Andrea Dup', 'andrea.dup@prueba.helios.test');

  update public.levels set monthly_limit_usd = 500 where level = 1;
  insert into public.business_parameters (key, value, effective_from, note)
  values ('payment_four_eyes', 0, v_today, 'prueba')
  on conflict (key, effective_from) do update set value = excluded.value;
  insert into public.exchange_rates (source, rate, effective_date)
  values ('BCV', 886.227100, v_today - 1)
  on conflict (source, effective_date) do update set rate = excluded.rate;

  v_ca := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 28.00, 'dup-a')->>'charge_id')::uuid;
  v_cb := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 28.00, 'dup-b')->>'charge_id')::uuid;
  v_cc := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 28.00, 'dup-c')->>'charge_id')::uuid;
  select id into v_a1 from public.installments where charge_id = v_ca and sequence = 1;
  select id into v_b1 from public.installments where charge_id = v_cb and sequence = 1;
  select id into v_c1 from public.installments where charge_id = v_cc and sequence = 1;
  v_q := public.helios_installments_ves(v_pac, array[v_a1], v_today);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- --- 1. El abono aprueba el pago pendiente ----------------------------------
  v_rep := (public.admin_register_payment(v_pac, array[v_a1], 'pago_movil', 'Banco de Venezuela', '1194314348',
                                          v_today, v_q + 13.42, null, null)->>'report_id')::uuid;
  insert into public.bank_statement_lines (bank, moved_on, reference, amount_ves, fingerprint, imported_by, description)
  values ('BNC Banco Nacional de Crédito', v_today, '1194314348', v_q + 13.42, 'prueba-dup-' || gen_random_uuid(),
          v_op, 'Abono Pago Movil BNC - ref: 1194314348')
  returning id into v_linea;

  v_res := public.admin_assign_deposit(v_linea, v_pac, array[v_a1], 'Revisado');
  if not (v_res->>'reused_open_report')::boolean or (v_res->>'report_id')::uuid <> v_rep then
    raise exception 'El abono debía aprobar el pago pendiente, no crear otro: %', v_res;
  end if;
  select count(*) into v_n from public.payment_reports where user_id = v_pac;
  if v_n <> 1 then
    raise exception 'Debía quedar un solo pago, hay %', v_n;
  end if;
  if (select status from public.payment_reports where id = v_rep) <> 'reconciled'
     or (select statement_line_id from public.payment_reports where id = v_rep) is distinct from v_linea
     or (select status::text from public.bank_statement_lines where id = v_linea) <> 'asignado'
     or (select report_id from public.bank_statement_lines where id = v_linea) is distinct from v_rep then
    raise exception 'El pago pendiente debía quedar aprobado y ligado a su abono';
  end if;
  if not exists (select 1 from audit.admin_actions
                 where action = 'deposit.assigned' and target_id = v_linea
                   and (detail->>'closed_open_report')::uuid = v_rep) then
    raise exception 'La bitácora del abono debía decir qué pago cerró';
  end if;

  -- --- 2. Un pendiente que salda otras cuotas además -------------------------
  v_rep := (public.admin_register_payment(v_pac, array[v_b1, v_c1], 'pago_movil', 'Banesco', '55554444',
                                          v_today, 2 * v_q, null, null)->>'report_id')::uuid;
  insert into public.bank_statement_lines (bank, moved_on, reference, amount_ves, fingerprint, imported_by, description)
  values ('BNC Banco Nacional de Crédito', v_today, '55554444', v_q, 'prueba-dup-' || gen_random_uuid(),
          v_op, 'Abono Pago Movil BNC - ref: 55554444')
  returning id into v_linea;
  begin
    perform public.admin_assign_deposit(v_linea, v_pac, array[v_b1], null);
    raise exception 'Con un pendiente que salda otras cuotas, asignar el abono a una debía fallar';
  exception when sqlstate '22023' then
    if sqlerrm not like 'Esas cuotas ya tienen un pago registrado pendiente%' then
      raise;
    end if;
  end;

  -- --- 3. Marcar como duplicado -----------------------------------------------
  begin
    perform public.admin_mark_payment_duplicate(v_rep, '');
    raise exception 'Sin motivo debía fallar';
  exception when sqlstate '22023' then null;
  end;

  v_res := public.admin_mark_payment_duplicate(v_rep, 'Ya se aprobó con el abono del extracto');
  if (select status from public.payment_reports where id = v_rep) <> 'duplicate'
     or (select reviewed_by from public.payment_reports where id = v_rep) is distinct from v_op
     or (select rejection_note from public.payment_reports where id = v_rep) <> 'Duplicado: Ya se aprobó con el abono del extracto' then
    raise exception 'El pago debía quedar como duplicado, con quién y por qué';
  end if;
  set constraints all immediate;
  set constraints all deferred;
  if exists (select 1 from public.outbound_messages
             where profile_id = v_pac and template_key in ('pago_rechazado', 'bot_paciente')
               and created_at >= now()
               and coalesce(rendered_text, '') not like '%¡Gracias por tu pago%') then
    raise exception 'Marcar como duplicado no avisa al paciente';
  end if;
  if not exists (select 1 from audit.admin_actions where action = 'payment.marked_duplicate' and target_id = v_rep) then
    raise exception 'Falta la bitácora del duplicado';
  end if;

  begin
    perform public.admin_mark_payment_duplicate(v_rep, 'otra vez');
    raise exception 'Un pago ya resuelto no se marca otra vez';
  exception when sqlstate '22023' then null;
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  begin
    perform public.admin_mark_payment_duplicate(v_rep, 'una clínica');
    raise exception 'Solo el equipo de Helios marca duplicados';
  exception when sqlstate '42501' then null;
  end;
end $$;

rollback;
