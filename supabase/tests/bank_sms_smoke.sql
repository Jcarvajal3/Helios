-- ============================================================================
-- Helios — El aviso del BNC aprueba lo que encaja exacto (20261015100000)
--
--   bash supabase/tests/run.sh bank_sms_smoke
--
--  1. La lectura del SMS: monto con coma, miles con punto, «Enviado» no vale.
--  2. El encaje de la referencia que teclea el equipo: entera o el final.
--  3. Sombra: el SMS llega antes que el registro y, al registrarlo, el bot
--     anota que lo aprobaría sin tocar el pago. Repetido no entra.
--  4. Un aviso de un pago de Ronda (misma cuenta) se queda esperando.
--  5. El monto del comprobante distinto del SMS no encaja.
--  6. Activo: el pago registrado se aprueba al llegar su SMS, con bitácora.
--  7. El remitente fijado: otro remitente no aprueba nada.
--  8. El panel: la revisión la lee el equipo; el modo solo lo cambia el super
--     admin, con motivo.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_op       uuid := gen_random_uuid();
  v_super    uuid := gen_random_uuid();
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
  v_dia      text;
  v_res      jsonb;
  v_rep      public.payment_reports%rowtype;
  v_monto    numeric;
  v_sms      text;
  v_n        public.bank_sms_notices%rowtype;
  v_p        record;
begin
  -- Fixtures -----------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'u-' || u || '@prueba.helios.test', now(), now(), now()
  from unnest(array[v_op, v_super, v_staff]) u;
  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_op, 'operador', 'Operadora Avisos', true),
         (v_super, 'super_admin', 'Super Avisos', true);

  insert into public.merchants (name) values ('Clínica Avisos') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_staff, v_merchant, v_branch, 'cajero');

  insert into public.profiles (id, phone_e164, first_name, full_name, email)
  values (v_pac, '+584140009401', 'Ana', 'Ana Avisos', 'ana.avisos@prueba.helios.test');

  update public.levels set monthly_limit_usd = 500 where level = 1;
  insert into public.business_parameters (key, value, effective_from, note)
  values ('payment_four_eyes', 0, v_today, 'prueba')
  on conflict (key, effective_from) do update set value = excluded.value;
  insert into public.exchange_rates (source, rate, effective_date)
  values ('BCV', 123.456789, v_today - 1)
  on conflict (source, effective_date) do update set rate = excluded.rate;

  update public.bank_sms_settings set mode = 'sombra', actor = null, allowed_sender = null;

  v_ca := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 100.00, 'sms-a')->>'charge_id')::uuid;
  v_cb := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 60.00, 'sms-b')->>'charge_id')::uuid;
  v_cc := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 40.00, 'sms-c')->>'charge_id')::uuid;
  select id into v_a1 from public.installments where charge_id = v_ca and sequence = 1;
  select id into v_b1 from public.installments where charge_id = v_cb and sequence = 1;
  select id into v_c1 from public.installments where charge_id = v_cc and sequence = 1;

  v_dia := to_char(v_today - 1, 'DD/MM/YY');

  -- --- 1. La lectura del SMS -------------------------------------------------
  select * into v_p from public.helios_parse_bnc_sms(
    'BNC Pago Movil Recibido Bs.5442,41 Telf.0424***9037 Dia:12/10/26-19:07 Ref:158795645 Llamar al 0500-2625000 si no realizo esta Operacion');
  if v_p.reference is distinct from '158795645' or v_p.amount_ves is distinct from 5442.41
     or v_p.payer_phone_prefix is distinct from '0424' or v_p.payer_phone_last4 is distinct from '9037'
     or v_p.paid_at is distinct from '2026-10-12 19:07:00-04'::timestamptz then
    raise exception 'El SMS de muestra se leyó mal: %', to_jsonb(v_p);
  end if;

  select * into v_p from public.helios_parse_bnc_sms(
    'BNC Pago Móvil Recibido Bs.12.442,41 Telf.0412***0001 Día:01/02/26-09:05 Ref:000123456');
  if v_p.amount_ves is distinct from 12442.41 then
    raise exception 'Los miles con punto se leyeron mal: %', v_p.amount_ves;
  end if;

  select * into v_p from public.helios_parse_bnc_sms(
    'BNC Pago Movil Enviado Bs.100,00 Telf.0424***9037 Dia:12/10/26-19:07 Ref:158795645');
  if v_p.reference is not null then
    raise exception 'Un pago móvil ENVIADO no puede leerse como recibido';
  end if;

  -- --- 2. La referencia que teclea el equipo ---------------------------------
  if not public.helios_bank_sms_ref_match('158795645', '1158795645') then
    raise exception 'La referencia entera del extracto debía encajar';
  end if;
  if not public.helios_bank_sms_ref_match('158795645', '795645') then
    raise exception 'Las 6 últimas debían encajar';
  end if;
  if not public.helios_bank_sms_ref_match('158795645', 'Ref. 8795645') then
    raise exception 'Con letras y 7 cifras debía encajar';
  end if;
  if public.helios_bank_sms_ref_match('158795645', '95645') then
    raise exception 'Con 5 cifras no basta';
  end if;
  if public.helios_bank_sms_ref_match('158795645', '999795645') then
    raise exception 'Con 9 cifras tienen que coincidir las 9';
  end if;

  -- --- 3. Sombra: el SMS llega antes que el registro ------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- El monto se conoce al cotizar: se registra, se mira y se deshace con un
  -- savepoint implícito (bloque con excepción).
  begin
    v_res := public.admin_register_payment(v_pac, array[v_a1], 'pago_movil', 'Banesco', '1',
                                           v_today - 1, 1, null, null);
    select amount_ves into v_monto from public.payment_quotes where id = (v_res->>'quote_id')::uuid;
    raise exception 'deshacer' using errcode = 'P0001';
  exception when sqlstate 'P0001' then null;
  end;
  if v_monto is null then
    raise exception 'No se pudo conocer el monto de la cotización';
  end if;

  v_sms := format('BNC Pago Movil Recibido Bs.%s Telf.0424***9037 Dia:%s-19:07 Ref:158795645 Llamar',
                  replace(to_char(v_monto, 'FM999999990.00'), '.', ','), v_dia);

  v_res := public.helios_bank_sms_ingest(v_sms, '2622');
  if v_res->>'outcome' <> 'esperando' then
    raise exception 'Sin registro, el aviso debía esperar: %', v_res;
  end if;
  if (public.helios_bank_sms_ingest(v_sms, '2622'))->>'outcome' <> 'repetido' then
    raise exception 'El mismo SMS dos veces no puede entrar dos veces';
  end if;

  v_res := public.admin_register_payment(v_pac, array[v_a1], 'pago_movil', 'Banesco', '1158795645',
                                         v_today - 1, v_monto, null, null);
  set constraints all immediate;
  set constraints all deferred;

  select * into v_n from public.bank_sms_notices where reference = '158795645';
  if v_n.outcome <> 'aprobaria' or v_n.report_id is distinct from (v_res->>'report_id')::uuid then
    raise exception 'Al registrar el pago, la sombra debía anotar que lo aprobaría: % / %', v_n.outcome, v_n.note;
  end if;
  select * into v_rep from public.payment_reports where id = (v_res->>'report_id')::uuid;
  if v_rep.status <> 'reported' then
    raise exception 'En sombra el pago no se toca: %', v_rep.status;
  end if;

  -- --- 4. Un pago de Ronda (misma cuenta) se queda esperando ----------------
  v_res := public.helios_bank_sms_ingest(
    'BNC Pago Movil Recibido Bs.43730,28 Telf.0412***0084 Dia:' || v_dia || '-20:10 Ref:123801682', '2622');
  if v_res->>'outcome' <> 'esperando' then
    raise exception 'Un aviso sin pago en Helios debía esperar: %', v_res;
  end if;

  -- --- 5. El comprobante dice otro monto ------------------------------------
  v_res := public.admin_register_payment(v_pac, array[v_c1], 'pago_movil', 'Banesco', '555000111',
                                         v_today - 1, 1.00, null, null);
  select amount_ves into v_monto from public.payment_quotes where id = (v_res->>'quote_id')::uuid;
  v_res := public.helios_bank_sms_ingest(format(
    'BNC Pago Movil Recibido Bs.%s Telf.0414***0000 Dia:%s-10:00 Ref:555000111',
    replace(to_char(v_monto, 'FM999999990.00'), '.', ','), v_dia), '2622');
  if v_res->>'outcome' <> 'esperando' then
    raise exception 'Si el comprobante anotado no es el monto del SMS, no encaja: %', v_res;
  end if;

  -- --- 6. Activo: el registro primero, el SMS después ------------------------
  update public.bank_sms_settings set mode = 'activo', actor = v_super;

  v_res := public.admin_register_payment(v_pac, array[v_b1], 'pago_movil', 'Mercantil', '444777',
                                         v_today - 1, 1, null, null);
  select amount_ves into v_monto from public.payment_quotes where id = (v_res->>'quote_id')::uuid;
  update public.payment_reports set declared_amount_ves = v_monto where id = (v_res->>'report_id')::uuid;

  perform set_config('request.jwt.claims', null, true);
  v_res := public.helios_bank_sms_ingest(format(
    'BNC Pago Movil Recibido Bs.%s Telf.0416***1234 Dia:%s-21:30 Ref:321444777',
    replace(to_char(v_monto, 'FM999999990.00'), '.', ','), v_dia), '2622') || jsonb_build_object('report_id', v_res->>'report_id');
  if v_res->>'outcome' <> 'aprobado' then
    raise exception 'En activo el pago que encaja se aprueba: %', v_res;
  end if;
  select * into v_rep from public.payment_reports where id = (v_res->>'report_id')::uuid;
  if v_rep.status <> 'reconciled' or v_rep.reviewed_by is distinct from v_super then
    raise exception 'El pago debía quedar aprobado y firmado por quien activó el bot: % %', v_rep.status, v_rep.reviewed_by;
  end if;
  if not exists (select 1 from audit.admin_actions
                 where target_id = v_rep.id and action = 'payment.reconciled' and detail->>'via' = 'aviso_bnc') then
    raise exception 'Falta la bitácora de la aprobación por aviso';
  end if;

  -- --- 7. El remitente fijado ------------------------------------------------
  update public.bank_sms_settings set allowed_sender = '2622';
  v_res := public.helios_bank_sms_ingest(
    'BNC Pago Movil Recibido Bs.10,00 Telf.0414***3031 Dia:' || v_dia || '-17:30 Ref:777123456', '+58 414 0000000');
  if v_res->>'outcome' <> 'remitente_ajeno' then
    raise exception 'Un SMS de otro remitente no puede contar: %', v_res;
  end if;

  -- --- 8. El panel -----------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_res := public.admin_bank_sms_review(v_today - 30, v_today + 1);
  if jsonb_array_length(v_res->'notices') < 5 or v_res->>'mode' <> 'activo' then
    raise exception 'La revisión del panel no trae los avisos: %', v_res->>'mode';
  end if;
  begin
    perform public.admin_set_bank_sms_mode('sombra', 'prueba del operador');
    raise exception 'Un operador no puede cambiar el modo';
  exception when sqlstate '42501' then null;
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  begin
    perform public.admin_set_bank_sms_mode('sombra', '');
    raise exception 'Cambiar el modo sin motivo debía fallar';
  exception when sqlstate '22023' then null;
  end;
  perform public.admin_set_bank_sms_mode('sombra', 'vuelta a sombra en la prueba');
  if (select mode from public.bank_sms_settings) <> 'sombra' then
    raise exception 'El modo no cambió';
  end if;
end $$;

rollback;
