-- ============================================================================
-- Helios — El equipo registra los pagos (20261004000300, docs/01 §2.1)
--
--   bash supabase/tests/run.sh register_payment_smoke
--
--  1. Validaciones: solo el equipo; método, referencia, banco, fecha, monto.
--  2. Las reglas de la cotización de Ronda: lo vencido va primero.
--  3. El registro: `payment_report` en `reported` con quién lo registró, la
--     fecha, lo declarado, la nota y la captura; cotizado a la tasa BCV del
--     DÍA DEL PAGO; bitácora. Las mismas cuotas no se registran dos veces.
--  4. Los candidatos del extracto (referencia + monto ±1 Bs + ±5 días de la
--     fecha del pago).
--  5. La cola de pagos trae quién lo registró y la captura para firmarla.
--  6. Doble control: con `payment_four_eyes = 0` quien registra aprueba; con
--     1, no (42501), salvo un super admin; otra persona sí.
--  7. Conciliar → `pago_recibido` y los avisos de esas fechas cancelados;
--     rechazar → `pago_rechazado` con el motivo.
--  8. El bucket `payment-receipts` es privado y solo el equipo sube y lee.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_op1      uuid := gen_random_uuid();
  v_op2      uuid := gen_random_uuid();
  v_super    uuid := gen_random_uuid();
  v_staff    uuid := gen_random_uuid();
  v_pac      uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_ca       uuid;
  v_cb       uuid;
  v_a1       uuid;
  v_a2       uuid;
  v_b1       uuid;
  v_b2       uuid;
  v_today    date := public.helios_business_date(now());
  v_res      jsonb;
  v_res2     jsonb;
  v_res3     jsonb;
  v_rep      public.payment_reports%rowtype;
  v_item     jsonb;
  v_rate     numeric;
begin
  -- Fixtures -----------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'u-' || u || '@prueba.helios.test', now(), now(), now()
  from unnest(array[v_op1, v_op2, v_super, v_staff]) u;
  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_op1, 'operador', 'Operadora Uno', true),
         (v_op2, 'operador', 'Operador Dos', true),
         (v_super, 'super_admin', 'Super Pagos', true);

  insert into public.merchants (name) values ('Clínica Pagos') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_staff, v_merchant, v_branch, 'cajero');

  insert into public.profiles (id, phone_e164, first_name, full_name, email)
  values (v_pac, '+584140009301', 'Luis', 'Luis Pagos', 'luis.pagos@prueba.helios.test');

  update public.levels set monthly_limit_usd = 150 where level = 1;
  update public.notification_templates set enabled = true
   where key in ('cuota_vencida_d1', 'pago_recibido', 'pago_rechazado');

  -- El doble control empieza apagado (lo que se siembra).
  insert into public.business_parameters (key, value, effective_from, note)
  values ('payment_four_eyes', 0, v_today, 'prueba')
  on conflict (key, effective_from) do update set value = excluded.value;

  -- Una tasa propia del día del pago (hace 3 días), distinta de cualquier otra.
  insert into public.exchange_rates (source, rate, effective_date)
  values ('BCV', 123.456789, v_today - 3)
  on conflict (source, effective_date) do update set rate = excluded.rate;

  v_ca := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 100.00, 'reg-a')->>'charge_id')::uuid;
  v_cb := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 50.00, 'reg-b')->>'charge_id')::uuid;
  select id into v_a1 from public.installments where charge_id = v_ca and sequence = 1;
  select id into v_a2 from public.installments where charge_id = v_ca and sequence = 2;
  select id into v_b1 from public.installments where charge_id = v_cb and sequence = 1;
  select id into v_b2 from public.installments where charge_id = v_cb and sequence = 2;

  -- La cuota A1 venció hace 2 días (sin cargo todavía: la gracia es de 3).
  update public.installments set due_date = v_today - 2 where id = v_a1;
  perform public.helios_enqueue_reminders('cuota_vencida_d1', v_today - 1);
  if not exists (select 1 from public.outbound_messages
                 where profile_id = v_pac and template_key = 'cuota_vencida_d1' and status = 'pendiente') then
    raise exception 'Faltaba el aviso de la cuota vencida para la prueba';
  end if;

  -- --- 1. Validaciones -------------------------------------------------------
  begin
    perform public.admin_register_payment(v_pac, array[v_a1], 'pago_movil', 'Banesco', '123456',
                                          v_today, 100, null, null);
    raise exception 'Sin sesión del equipo debía fallar';
  exception when sqlstate '42501' then null;
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op1::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  begin
    perform public.admin_register_payment(v_pac, array[v_a1], 'bitcoin', null, '1', v_today, null, null, null);
    raise exception 'Un método desconocido debía fallar';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.admin_register_payment(v_pac, array[v_a1], 'pago_movil', 'Banesco', null, v_today, 100, null, null);
    raise exception 'Pago Móvil sin referencia debía fallar';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.admin_register_payment(v_pac, array[v_a1], 'pago_movil', 'Banesco', '1', v_today + 1, 100, null, null);
    raise exception 'Una fecha futura debía fallar';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.admin_register_payment(v_pac, array[v_a1], 'transferencia', 'Banesco', '1', v_today, null, null, null);
    raise exception 'Una transferencia sin monto en bolívares debía fallar';
  exception when sqlstate '22023' then null;
  end;
  -- El paciente solo paga en bolívares (2026-10-07): Zelle, USDT y efectivo, no.
  begin
    perform public.admin_register_payment(v_pac, array[v_a1], 'zelle', null, 'ZL-1', v_today, null, null, null);
    raise exception 'Un Zelle debía fallar: el paciente solo paga en bolívares';
  exception when sqlstate '22023' then
    if sqlerrm not like 'El paciente solo paga en bolívares%' then
      raise exception 'Texto inesperado para un Zelle: %', sqlerrm;
    end if;
  end;
  begin
    perform public.admin_register_payment(v_pac, array[v_a1], 'efectivo', null, null, v_today, null, null, null);
    raise exception 'Un pago en efectivo debía fallar';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.admin_register_payment(v_pac, array[v_a1], 'usdt', null, 'TX-1', v_today, null, null, null);
    raise exception 'Un pago en USDT debía fallar';
  exception when sqlstate '22023' then null;
  end;
  raise notice 'TEST REGISTRO 1 OK — validaciones (solo bolívares)';

  -- --- 2. Lo vencido va primero ---------------------------------------------
  begin
    perform public.admin_register_payment(v_pac, array[v_b1], 'pago_movil', 'Banesco', '777001',
                                          v_today, 100, null, null);
    raise exception 'Adelantar B1 sin la vencida A1 debía fallar';
  exception when sqlstate '22023' then
    if sqlerrm not like '%vencen hoy o antes%' then
      raise exception 'Mensaje inesperado: %', sqlerrm;
    end if;
  end;
  raise notice 'TEST REGISTRO 2 OK — lo vencido va primero';

  -- --- 4 (preparación). Una línea del extracto que casa con el pago de A1 ----
  -- A la tasa de hace 3 días: 56.96 × 123.456789 = 7032.10 Bs.
  insert into public.bank_statement_lines (bank, moved_on, reference, amount_ves, fingerprint, imported_by)
  values ('Banesco', v_today - 3, '0000123456', round(56.96 * 123.456789, 2),
          'prueba-registro-' || gen_random_uuid(), v_super);

  -- --- 3. El registro --------------------------------------------------------
  v_res := public.admin_register_payment(
    v_pac, array[v_a1], 'pago_movil', ' Banesco ', ' 123456 ', v_today - 3,
    7032.10, v_pac || '/captura.jpg', 'Lo mandó por WhatsApp');

  select * into v_rep from public.payment_reports where id = (v_res->>'report_id')::uuid;
  if v_rep.status <> 'reported' or v_rep.registered_by <> v_op1 or v_rep.paid_on <> v_today - 3
     or v_rep.declared_amount_ves <> 7032.10 or v_rep.note <> 'Lo mandó por WhatsApp'
     or v_rep.receipt_path <> v_pac || '/captura.jpg' or v_rep.reference <> '123456' or v_rep.bank <> 'Banesco'
     or v_rep.method <> 'pago_movil' then
    raise exception 'El reporte no quedó como debía: %', to_jsonb(v_rep);
  end if;
  if (v_res->>'amount_usd')::numeric <> 56.96 or (v_res->>'late_fee_usd')::numeric <> 0
     or (v_res->>'fx_rate')::numeric <> 123.456789
     or (v_res->>'amount_ves')::numeric <> round(56.96 * 123.456789, 2)
     or v_res->>'status' <> 'reported' or (v_res->>'diferencia_ves')::numeric <> 0 then
    raise exception 'La respuesta no es la del contrato (tasa del día del pago): %', v_res;
  end if;
  if (select fx_rate from public.payment_quotes where id = (v_res->>'quote_id')::uuid) <> 123.456789 then
    raise exception 'La cotización debía quedar a la tasa del día del pago';
  end if;
  if not exists (select 1 from audit.admin_actions
                 where action = 'payment.registered' and target_id = v_rep.id and actor = v_op1) then
    raise exception 'El registro debía quedar en la bitácora';
  end if;

  -- --- 4. Candidatos del extracto -------------------------------------------
  if (v_res->>'candidatos_extracto')::integer <> 1 then
    raise exception 'Debía casar 1 línea del extracto: %', v_res;
  end if;

  -- Las mismas cuotas no se registran dos veces.
  begin
    perform public.admin_register_payment(v_pac, array[v_a1], 'pago_movil', 'Banesco', '999999',
                                          v_today, 100, null, null);
    raise exception 'Registrar otra vez la misma cuota debía fallar';
  exception when sqlstate '22023' then null;
  end;

  -- Y el aviso de A1 se canceló al registrar.
  if exists (select 1 from public.outbound_messages
             where profile_id = v_pac and template_key = 'cuota_vencida_d1' and status = 'pendiente') then
    raise exception 'Registrar el pago debía cancelar el aviso de esa fecha';
  end if;
  raise notice 'TEST REGISTRO 3-4 OK — reporte con quién/fecha/declarado/captura, tasa del día del pago, bitácora, 1 candidato';

  -- --- 5. La cola de pagos ---------------------------------------------------
  select x into v_item from jsonb_array_elements(public.admin_payment_queue()) x
   where x->>'report_id' = v_rep.id::text;
  if v_item is null or v_item->>'registered_by_name' <> 'Operadora Uno'
     or v_item->'receipt'->>'bucket' <> 'payment-receipts'
     or v_item->'receipt'->>'path' <> v_pac || '/captura.jpg'
     or v_item->>'paid_on' <> (v_today - 3)::text
     or (v_item->>'statement_matches_available')::integer <> 1
     or (v_item->>'can_approve')::boolean is not true then
    raise exception 'La cola de pagos no trae lo del registro: %', v_item;
  end if;
  if public.admin_payment_report(v_rep.id)->>'registered_by_name' <> 'Operadora Uno' then
    raise exception 'La ficha del pago debía decir quién lo registró';
  end if;
  raise notice 'TEST REGISTRO 5 OK — la cola trae quién registró y la captura';

  -- --- 6. Doble control ------------------------------------------------------
  -- Apagado: quien registró aprueba (el comportamiento de siempre). Aquí se
  -- registra A2 + B1 + B2 (lo vencido —A1— ya tiene pago abierto) y se aprueba
  -- más abajo; antes, el doble control.
  update public.business_parameters set value = 1
   where key = 'payment_four_eyes' and effective_from = v_today;
  if not public.helios_payment_four_eyes() then
    raise exception 'El doble control debía estar encendido';
  end if;

  select x into v_item from jsonb_array_elements(public.admin_payment_queue()) x
   where x->>'report_id' = v_rep.id::text;
  if (v_item->>'can_approve')::boolean then
    raise exception 'Con doble control, quien registró no puede aprobar (can_approve)';
  end if;

  begin
    perform public.admin_reconcile_payment(v_rep.id, true, null);
    raise exception 'Con doble control quien registró no podía aprobar';
  exception when sqlstate '42501' then null;
  end;

  -- Otra persona aprueba.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op2::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_res2 := public.admin_reconcile_payment(v_rep.id, true, null);
  if v_res2->>'status' <> 'reconciled' then
    raise exception 'Otra persona debía poder aprobar: %', v_res2;
  end if;
  -- Con un único candidato libre, se liga solo.
  if (select statement_line_id from public.payment_reports where id = v_rep.id) is null then
    raise exception 'El único candidato del extracto debía ligarse al aprobar';
  end if;

  -- --- 7a. pago_recibido -------------------------------------------------------
  if not exists (select 1 from public.outbound_messages
                 where dedupe_key = 'pago_recibido:email:' || v_rep.id and status = 'pendiente'
                   and rendered_text like '%$56,96%') then
    raise exception 'Conciliar debía encolar pago_recibido';
  end if;

  -- Un super admin sí aprueba lo que él mismo registró.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_res3 := public.admin_register_payment(v_pac, array[v_b1], 'pago_movil', 'Venezuela', 'PM-778899',
                                          v_today, 4000, null, null);
  perform public.admin_reconcile_payment((v_res3->>'report_id')::uuid, true, null);
  if (select status from public.payment_reports where id = (v_res3->>'report_id')::uuid) <> 'reconciled' then
    raise exception 'El super admin debía poder aprobar su propio registro';
  end if;

  -- Con el doble control apagado, quien registra aprueba (como siempre).
  update public.business_parameters set value = 0
   where key = 'payment_four_eyes' and effective_from = v_today;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op1::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_res3 := public.admin_register_payment(v_pac, array[v_a2], 'transferencia', 'Banesco', 'TR-990011',
                                          v_today, 4000, null, 'Transferencia desde otra cuenta');
  perform public.admin_reconcile_payment((v_res3->>'report_id')::uuid, true, null);
  if (select status from public.payment_reports where id = (v_res3->>'report_id')::uuid) <> 'reconciled' then
    raise exception 'Sin doble control quien registra debía poder aprobar';
  end if;
  raise notice 'TEST REGISTRO 6 OK — doble control: el registrante no aprueba, otro sí, el super admin sí; apagado, como siempre';

  -- --- 7b. Rechazar → pago_rechazado ----------------------------------------
  v_res3 := public.admin_register_payment(v_pac, array[v_b2], 'transferencia', 'Mercantil', '445566',
                                          v_today, 4000, null, null);
  perform public.admin_reconcile_payment((v_res3->>'report_id')::uuid, false, 'la referencia no aparece en el banco');
  if not exists (select 1 from public.outbound_messages
                 where dedupe_key = 'pago_rechazado:email:' || (v_res3->>'report_id')
                   and rendered_text like '%la referencia no aparece en el banco%') then
    raise exception 'Rechazar debía encolar pago_rechazado con el motivo';
  end if;
  raise notice 'TEST REGISTRO 7 OK — conciliar → pago_recibido; rechazar → pago_rechazado';

  -- --- 8. El bucket ------------------------------------------------------------
  if not exists (select 1 from storage.buckets where id = 'payment-receipts' and not public) then
    raise exception 'Falta el bucket privado payment-receipts';
  end if;
  if (select count(*) from pg_policies
      where schemaname = 'storage' and tablename = 'objects'
        and policyname in ('payment_receipts_admin_insert', 'payment_receipts_admin_select')
        and coalesce(qual, with_check) like '%payment-receipts%is_platform_admin%') <> 2 then
    raise exception 'Las políticas del bucket payment-receipts no son las esperadas';
  end if;
  if exists (select 1 from pg_policies
             where schemaname = 'storage' and tablename = 'objects'
               and coalesce(qual, '') || coalesce(with_check, '') like '%payment-receipts%'
               and policyname not in ('payment_receipts_admin_insert', 'payment_receipts_admin_select')) then
    raise exception 'Nadie más puede tocar payment-receipts';
  end if;
  raise notice 'TEST REGISTRO 8 OK — bucket privado, solo el equipo sube y lee';
end;
$$;

set constraints all immediate;
rollback;
