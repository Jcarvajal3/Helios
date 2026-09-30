-- ============================================================================
-- Ronda — Prueba de humo de notificaciones
--
-- docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--   -v ON_ERROR_STOP=1 -f supabase/tests/notifications_smoke.sql
--
-- La que más importa es la del cargo de grupo: docs/05 §2 la llama "el
-- control" frente a la autorización permanente. Si esa no llega, el modelo de
-- grupos pierde su baranda principal.
-- ============================================================================

begin;

do $$
declare
  v_ana      uuid := gen_random_uuid();
  v_luis     uuid := gen_random_uuid();
  v_cajero   uuid := gen_random_uuid();
  v_admin    uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_group    uuid;
  v_code     text;
  v_charge   uuid;
  /** El importe real del cobro, con IVA y comisión. */
  v_amount   numeric;
  v_insts    uuid[];
  v_qid      uuid;
  v_report   uuid;
  v_count    integer;
  v_notif    public.notifications%rowtype;
  v_inbox    jsonb;
  v_pin_user   uuid;
  v_prod_40    uuid;
  v_prod_15    uuid;
begin
  -- --- Fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_ana,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000101', now(), now(), now()),
    (v_luis,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000102', now(), now(), now()),
    (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000103', now(), now(), now()),
    (v_admin,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000104', now(), now(), now());

  update public.profiles set status = 'active', level = 3, full_name = 'Ana'  where id = v_ana;
  update public.profiles set status = 'active', level = 3, full_name = 'Luis' where id = v_luis;

  insert into public.platform_admins (user_id, role, full_name)
  values (v_admin, 'super_admin', 'Jefa');

  insert into public.merchants (name) values ('Bar Aviso') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_merchant, v_branch, 'cajero');

  -- La carta. Desde 20260918190000 toda línea de un cobro es un producto del
  -- catálogo y el precio sale de aquí: `unit_price_usd` del item se ignora.
  insert into public.products (merchant_id, name, price_usd, is_active)
  values (v_merchant, 'Helios de 40', 40.00, true), (v_merchant, 'Helios de 15', 15.00, true);

  select id into v_prod_40 from public.products where merchant_id = v_merchant and price_usd = 40.00;
  select id into v_prod_15 from public.products where merchant_id = v_merchant and price_usd = 15.00;

  -- --- PIN de la prueba --------------------------------------------------
  -- Desde 20260824170000 confirmar un cobro exige PIN, así que toda prueba
  -- que pague necesita uno. Se le pone '7391' a quien no lo tenga, y se pasa
  -- por `set_user_pin` en vez de escribir el hash a mano: el día que cambie
  -- cómo se guarda, esto sigue valiendo.
  --
  -- El pepper de Vault se siembra si falta: una base de desarrollo recién
  -- levantada no lo trae, y sin él no se puede confirmar ni un consumo. Todo
  -- vive dentro de la transacción, que termina en rollback.
  if not exists (select 1 from vault.decrypted_secrets where name = 'pin_pepper') then
    perform vault.create_secret('smoke-pepper-0123456789', 'pin_pepper');
  end if;

  for v_pin_user in
    select p.id from public.profiles p
    where not exists (select 1 from public.user_pins up where up.user_id = p.id)
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_pin_user::text, 'role', 'authenticated')::text, true);
    perform public.set_user_pin('7391');
  end loop;
  perform set_config('request.jwt.claims', '', true);

  -- --- 1. El cargo de grupo avisa a quien NO lo inició --------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  -- Cada quien pone su propio techo al entrar (20260828000000), y tanto crear
  -- como entrar exigen PIN: son actos que comprometen crédito.
  v_group := (public.create_group('Sábado', 40.00, '7391')->>'group_id')::uuid;
  select invite_code into v_code from public.groups where id = v_group;

  perform set_config('request.jwt.claims', json_build_object('sub', v_luis::text, 'role', 'authenticated')::text, true);
  perform public.join_group(v_code, 40.00, '7391');

  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  select (public.request_charge(v_merchant, v_branch, jsonb_build_array(jsonb_build_object('product_id', v_prod_40, 'quantity', 1)), 'notif-1')).id into v_charge;

  -- El importe autorizado se lee con el rol RESETEADO: un cobro pendiente no
  -- tiene dueño y RLS lo esconde de `authenticated`.
  reset role;
  select amount_usd into v_amount from public.charges where id = v_charge;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  perform public.confirm_charge_as_group(v_charge, v_group, 'notif-1-split', '7391', v_amount);

  reset role;
  select * into v_notif from public.notifications
  where user_id = v_luis and type = 'group_charge';

  if not found then
    raise exception 'Luis debía recibir el aviso del cargo de grupo';
  end if;
  if v_notif.title not like '%Ana%' then
    raise exception 'El aviso debía decir quién lo inició: %', v_notif.title;
  end if;
  -- La mitad de lo que se cobró de verdad (IVA y comisión incluidos), no la
  -- mitad de la base del pedido.
  if (v_notif.data->>'amount_usd')::numeric <> round(v_amount / 2, 2) then
    raise exception 'El aviso debía traer los % que le tocaron: %', round(v_amount / 2, 2), v_notif.data;
  end if;
  raise notice 'TEST NOTIF 1 OK — "%": %', v_notif.title, v_notif.body;

  -- --- 2. A quien lo inició NO se le avisa -------------------------------
  select count(*) into v_count from public.notifications
  where user_id = v_ana and type = 'group_charge'
    and data->>'charge_id' = v_charge::text;
  if v_count <> 0 then
    raise exception 'Ana inició el cobro: no debía recibir aviso de ESE cobro, tiene %', v_count;
  end if;
  raise notice 'TEST NOTIF 2 OK — quien inicia no recibe su propio aviso';

  -- --- 3. Un solo aviso por consumo, no uno por cuota --------------------
  select count(*) into v_count from public.notifications
  where user_id = v_luis and type = 'group_charge'
    and data->>'charge_id' = v_charge::text;
  if v_count <> 1 then
    raise exception 'Debía haber 1 aviso por consumo (no uno por cuota), hay %', v_count;
  end if;
  raise notice 'TEST NOTIF 3 OK — un aviso por consumo, no dos';

  -- --- 4. Un consumo individual NO genera aviso de grupo -----------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  select (public.request_charge(v_merchant, v_branch, jsonb_build_array(jsonb_build_object('product_id', v_prod_15, 'quantity', 1)), 'notif-2')).id into v_charge;

  perform set_config('request.jwt.claims', json_build_object('sub', v_luis::text, 'role', 'authenticated')::text, true);
  perform public.confirm_charge(v_charge, 'notif-2-confirm', '7391');

  reset role;
  select count(*) into v_count from public.notifications
  where user_id = v_luis and type = 'group_charge';
  if v_count <> 1 then
    raise exception 'Un consumo propio no debía generar aviso de grupo. Avisos: %', v_count;
  end if;
  raise notice 'TEST NOTIF 4 OK — un consumo individual no genera aviso de grupo';

  -- --- 5. El pago conciliado avisa ---------------------------------------
  -- La noche del grupo se da por cerrada antes de pagar: desde 20260908170000
  -- una cuota de un grupo VIVO no se puede cotizar —todavía puede entrar
  -- alguien y bajar la parte— y el veredicto sale de comparar la fecha del
  -- grupo con el día operativo de hoy. Retrasarla un día es el equivalente a
  -- que hayan dado las 10 AM.
  update public.groups set business_date = business_date - 1 where id = v_group;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_luis::text, 'role', 'authenticated')::text, true);

  select array_agg(id) into v_insts
  from public.installments where user_id = v_luis and status = 'pending';

  v_qid := (public.quote_installments(v_insts)->>'quote_id')::uuid;
  v_report := (public.report_payment(v_qid, 'pago_movil', 'Banesco', '551122', 'V-1', '0414')->>'report_id')::uuid;

  reset role;
  perform public.reconcile_payment(v_report, v_admin, true, null);

  select * into v_notif from public.notifications
  where user_id = v_luis and type = 'payment_reconciled';
  if not found then
    raise exception 'Debía avisarse el pago conciliado';
  end if;
  raise notice 'TEST NOTIF 5 OK — "%": %', v_notif.title, v_notif.body;

  -- --- 6. La mora avisa en cada escalón ----------------------------------
  -- Ana quedó con deuda del cargo de grupo. Se le vence.
  update public.installments
    set due_date = public.helios_business_date(now()) - 1
  where user_id = v_ana and status = 'pending';
  perform public.process_mora();

  select count(*) into v_count from public.notifications
  where user_id = v_ana and type = 'account_frozen';
  if v_count <> 1 then
    raise exception 'Debía avisarse el congelamiento, hay % avisos', v_count;
  end if;

  -- 🔁 Del umbral, no de un 16 escrito a mano: la escalera pasó de 15/30 a
  -- 30/60 días el 2026-08-30 y este empujón se quedó corto, así que la prueba
  -- exigía un aviso de bajada que ya no tocaba dar.
  update public.installments
    set due_date = public.helios_business_date(now()) - public.helios_mora_demotion_days() - 1
  where user_id = v_ana and status = 'pending';
  perform public.process_mora();

  select * into v_notif from public.notifications
  where user_id = v_ana and type = 'account_suspended';
  if not found then
    raise exception 'Debía avisarse la bajada de nivel';
  end if;
  raise notice 'TEST NOTIF 6 OK — mora avisada: congelado y "%"', v_notif.title;

  -- --- 7. Nadie ve la bandeja de otro ------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  v_inbox := public.my_notifications();
  if jsonb_array_length(v_inbox) <> 0 then
    raise exception 'El cajero no debía ver ninguna notificación, ve %',
      jsonb_array_length(v_inbox);
  end if;
  raise notice 'TEST NOTIF 7 OK — la bandeja es de cada quien';

  -- --- 8. Marcar como leído solo afecta a lo propio ----------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_luis::text, 'role', 'authenticated')::text, true);
  v_count := public.mark_notifications_read();

  if v_count = 0 then
    raise exception 'Luis tenía avisos sin leer y no se marcó ninguno';
  end if;

  reset role;
  if exists (
    select 1 from public.notifications where user_id = v_ana and read_at is not null
  ) then
    raise exception 'Marcar como leído no debía tocar los avisos de Ana';
  end if;
  raise notice 'TEST NOTIF 8 OK — % avisos de Luis marcados, los de Ana intactos', v_count;

  -- --- 9. El recordatorio de cuota no se duplica -------------------------
  -- La fecha se pone con `helios_caracas_date` y no con `helios_business_date`:
  -- desde 20260918280000 los avisos se anclan al día del CALENDARIO, porque el
  -- día operativo va de 10 AM a 10 AM y esta prueba puede correr a cualquier
  -- hora. Con el ancla vieja, correrla de madrugada fallaba por un día.
  update public.installments
    set due_date = public.helios_caracas_date(now()) + 3,
        status = 'pending',
        -- Una cuota vuelve a deberse: el reporte que la pagó se suelta, que es
        -- lo que exige `installments_paid_by_report_only_when_paid`.
        paid_by_report_id = null
  where user_id = v_luis;

  perform public.notify_upcoming_installments(3);
  select count(*) into v_count from public.notifications
  where user_id = v_luis and type = 'installment_due';

  perform public.notify_upcoming_installments(3);
  if (select count(*) from public.notifications
      where user_id = v_luis and type = 'installment_due') <> v_count then
    raise exception 'Correr el recordatorio dos veces no debía duplicar avisos';
  end if;
  raise notice 'TEST NOTIF 9 OK — % recordatorio(s), sin duplicar al repetir el cron', v_count;

  -- --- 10. El día del vencimiento tiene DOS avisos -----------------------
  -- Uno abre el día y otro lo cierra. Son plantillas distintas, así que la
  -- idempotencia por (plantilla, fecha) no los confunde entre sí.
  insert into public.push_tokens (token, user_id, platform)
  values ('ExponentPushToken[smoke-luis]', v_luis, 'android');

  update public.installments
    set due_date = public.helios_caracas_date(now()),
        status = 'pending',
        paid_by_report_id = null
  where user_id = v_luis;

  perform public.notify_installments_due_today();
  perform public.notify_installments_due_today_evening();

  select count(*) into v_count from public.notifications
  where user_id = v_luis
    and template_key in ('installment_due_today', 'installment_due_today_evening')
    and data->>'due_date' = public.helios_caracas_date(now())::text;

  if v_count <> 2 then
    raise exception 'El día del vencimiento debía dejar 2 avisos (mañana y tarde), dejó %', v_count;
  end if;
  raise notice 'TEST NOTIF 10 OK — el día del vencimiento avisa dos veces';

  -- --- 11. Reportar un pago frena lo que quedara en la cola --------------
  -- El aviso se creó con un token activo, así que hay entregas esperando al
  -- despachador. Reportar el pago tiene que apagarlas antes de que salgan: el
  -- peor aviso posible es el que le pide pagar a quien acaba de pagar.
  select count(*) into v_count
  from public.push_deliveries d
  join public.notifications n on n.id = d.notification_id
  where n.user_id = v_luis and n.type = 'installment_due' and d.status = 'pending';

  if v_count = 0 then
    raise exception 'El aviso debía dejar entregas en cola y no dejó ninguna';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_luis::text, 'role', 'authenticated')::text, true);

  select array_agg(id) into v_insts
  from public.installments where user_id = v_luis and status = 'pending';

  v_qid := (public.quote_installments(v_insts)->>'quote_id')::uuid;
  v_report := (public.report_payment(v_qid, 'pago_movil', 'Banesco', '998877', 'V-1', '0414')->>'report_id')::uuid;

  reset role;

  if exists (
    select 1
    from public.push_deliveries d
    join public.notifications n on n.id = d.notification_id
    where n.user_id = v_luis and n.type = 'installment_due' and d.status = 'pending'
  ) then
    raise exception 'Reportar el pago debía cancelar los recordatorios en cola';
  end if;

  if exists (
    select 1 from public.notifications
    where user_id = v_luis and type = 'installment_due'
      and data->>'due_date' = public.helios_caracas_date(now())::text
      and read_at is null
  ) then
    raise exception 'Los recordatorios de esa fecha debían quedar leídos en la bandeja';
  end if;
  raise notice 'TEST NOTIF 11 OK — el pago reportado apagó la cola y la bandeja';

  -- --- 12. Con el pago en revisión no se vuelve a avisar -----------------
  delete from public.notifications
   where user_id = v_luis and template_key = 'installment_due_today';

  perform public.notify_installments_due_today();

  if exists (
    select 1 from public.notifications
    where user_id = v_luis and template_key = 'installment_due_today'
  ) then
    raise exception 'Con un pago esperando conciliación no debía volver a avisarse';
  end if;
  raise notice 'TEST NOTIF 12 OK — quien ya reportó no recibe el recordatorio';

  raise notice '=== TODOS LOS TESTS DE NOTIFICACIONES PASARON ===';
end $$;

set constraints all immediate;

rollback;
