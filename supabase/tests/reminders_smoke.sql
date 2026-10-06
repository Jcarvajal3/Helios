-- ============================================================================
-- Helios — Los avisos los manda una persona (H7, 20261004000200)
--
--   bash supabase/tests/run.sh reminders_smoke
--
--  1. El día operativo empieza a medianoche (la fecha de los avisos).
--  2. Los 5 momentos de una fecha de vencimiento D:
--       D-1 cuota_manana (WhatsApp + correo) · D cuota_hoy · D+1 cuota_vencida_d1
--       · D+4 cargo_por_atraso_d4 (solo con el cargo ya cobrado, y lo suma)
--       · D+7 ningún mensaje.
--     Y ninguno sale en un día que no le toca.
--  3. Correrlo dos veces no duplica nada (dedupe_key por plantilla, canal,
--     paciente y fecha). El texto queda listo para pegar.
--  4. Dos financiamientos que vencen el mismo día: un solo aviso con la suma.
--  5. Registrar un pago cancela los avisos pendientes de las fechas que cubre,
--     y solo esos.
--  6. Conciliar → pago_recibido.
--  7. cuenta_congelada solo en el paso activa → congelada; al descongelarse
--     el pendiente se cancela.
--  8. A los 7 días el caso está en Cobranza (admin_collections).
--  9. La cola del equipo: admin_outbound_queue, admin_mark_outbound (enviado
--     → collection_contacts; omitido exige nota), admin_outbound_history.
-- 10. Los crons: los 4 de Helios a su hora y ninguno de los 12 de Ronda;
--     admin_set_notification_schedule los reprograma.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin    uuid := gen_random_uuid();
  v_super    uuid := gen_random_uuid();
  v_staff    uuid := gen_random_uuid();
  v_pac      uuid := gen_random_uuid();
  v_pac2     uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_c1       uuid;
  v_c2       uuid;
  v_c3       uuid;
  v_i1       public.installments%rowtype;
  v_i2       public.installments%rowtype;
  v_d        date;
  v_d2       date;
  v_today    date := public.helios_business_date(now());
  v_n        integer;
  v_res      jsonb;
  v_rep      jsonb;
  v_row      public.outbound_messages%rowtype;
  v_msg      uuid;
begin
  -- --- 1. Medianoche -------------------------------------------------------
  if public.helios_business_date(timestamptz '2026-10-08 00:00:30-04') <> date '2026-10-08'
     or public.helios_business_date(timestamptz '2026-10-07 23:59:59-04') <> date '2026-10-07' then
    raise exception 'El día operativo debía empezar a medianoche de Caracas';
  end if;
  raise notice 'TEST AVISOS 1 OK — el día operativo empieza a medianoche';

  -- Fixtures -----------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  values
    (v_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'op-' || v_admin || '@prueba.helios.test', now(), now(), now()),
    (v_super, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'sa-' || v_super || '@prueba.helios.test', now(), now(), now()),
    (v_staff, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'staff-' || v_staff || '@prueba.helios.test', now(), now(), now());
  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_admin, 'operador', 'Operadora Avisos', true),
         (v_super, 'super_admin', 'Super Avisos', true);

  insert into public.merchants (name) values ('Clínica Avisos') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_staff, v_merchant, v_branch, 'cajero');

  insert into public.profiles (id, phone_e164, first_name, full_name, email)
  values (v_pac,  '+584140009201', 'María', 'María Avisos', 'maria.avisos@prueba.helios.test'),
         (v_pac2, '+584140009202', 'Pedro', 'Pedro Avisos', null);

  update public.levels set monthly_limit_usd = 150 where level = 1;
  update public.notification_templates set enabled = true
   where key in ('cuota_manana', 'cuota_hoy', 'cuota_vencida_d1', 'cargo_por_atraso_d4',
                 'pago_recibido', 'pago_rechazado', 'cuenta_congelada');

  v_c1 := (pg_temp.prueba_cobro(v_pac, v_merchant, v_branch, v_staff, 100.00, 'aviso-1')->>'charge_id')::uuid;
  select * into v_i1 from public.installments where charge_id = v_c1 and sequence = 1;
  select * into v_i2 from public.installments where charge_id = v_c1 and sequence = 2;
  v_d  := v_i1.due_date;
  v_d2 := v_i2.due_date;

  -- --- 2. Los momentos de D ------------------------------------------------
  -- Ningún momento sale el día que no le toca.
  perform public.helios_enqueue_reminders('cuota_manana', v_d - 2);
  perform public.helios_enqueue_reminders('cuota_hoy', v_d - 1);
  perform public.helios_enqueue_reminders('cuota_vencida_d1', v_d);
  perform public.helios_enqueue_reminders('cargo_por_atraso_d4', v_d + 3);
  if exists (select 1 from public.outbound_messages where profile_id = v_pac and installment_due_date = v_d) then
    raise exception 'Ningún aviso de D debía salir en un día que no le toca';
  end if;

  -- D-1: víspera, por WhatsApp y por correo.
  v_res := public.helios_enqueue_reminders('cuota_manana', v_d - 1);
  if v_res->>'due_date' <> v_d::text then
    raise exception 'La víspera debía apuntar a D: %', v_res;
  end if;
  select count(*) into v_n from public.outbound_messages
   where profile_id = v_pac and template_key = 'cuota_manana' and installment_due_date = v_d;
  if v_n <> 2 or not exists (select 1 from public.outbound_messages
                             where profile_id = v_pac and template_key = 'cuota_manana'
                               and channel = 'email' and recipient = 'maria.avisos@prueba.helios.test'
                               and status = 'pendiente') then
    raise exception 'La víspera debía salir por WhatsApp y por correo (hay %)', v_n;
  end if;
  select * into v_row from public.outbound_messages
   where profile_id = v_pac and template_key = 'cuota_manana' and channel = 'whatsapp_manual';
  if v_row.recipient <> '+584140009201' or v_row.charge_id <> v_c1
     or v_row.rendered_text not like '%mañana%56,96%'
     or v_row.rendered_text like '%{%' or v_row.dedupe_key <> format('cuota_manana:whatsapp_manual:%s:%s', v_pac, v_d) then
    raise exception 'El WhatsApp de la víspera no está listo para pegar: %', to_jsonb(v_row);
  end if;

  -- --- 3. Dos veces no duplica ---------------------------------------------
  perform public.helios_enqueue_reminders('cuota_manana', v_d - 1);
  if (select count(*) from public.outbound_messages
       where profile_id = v_pac and template_key = 'cuota_manana' and installment_due_date = v_d) <> 2 then
    raise exception 'Correr la víspera dos veces no puede duplicar';
  end if;
  raise notice 'TEST AVISOS 3 OK — dedupe por plantilla, canal, paciente y fecha';

  -- D: el día.
  perform public.helios_enqueue_reminders('cuota_hoy', v_d);
  -- D+1.
  perform public.helios_enqueue_reminders('cuota_vencida_d1', v_d + 1);
  if (select count(*) from public.outbound_messages
       where profile_id = v_pac and installment_due_date = v_d
         and template_key in ('cuota_hoy', 'cuota_vencida_d1') and channel = 'whatsapp_manual') <> 2 then
    raise exception 'Faltan los avisos del día y del día siguiente';
  end if;
  if exists (select 1 from public.outbound_messages
             where profile_id = v_pac and template_key in ('cuota_hoy', 'cuota_vencida_d1') and channel = 'email') then
    raise exception 'cuota_hoy y cuota_vencida_d1 son solo WhatsApp';
  end if;

  -- D+4 sin cargo cobrado: no sale.
  perform public.helios_enqueue_reminders('cargo_por_atraso_d4', v_d + 4);
  if exists (select 1 from public.outbound_messages where profile_id = v_pac and template_key = 'cargo_por_atraso_d4') then
    raise exception 'El aviso del cargo no puede salir si el cargo no se cobró';
  end if;
  -- Con el cargo: sale y lo suma.
  perform public.charge_late_fee(v_i1.id, 4);
  perform public.helios_enqueue_reminders('cargo_por_atraso_d4', v_d + 4);
  select * into v_row from public.outbound_messages
   where profile_id = v_pac and template_key = 'cargo_por_atraso_d4' and installment_due_date = v_d;
  if not found or v_row.rendered_text not like '%$58,96%' or v_row.rendered_text not like '%$2%' then
    raise exception 'El aviso del cargo debía llevar la cuota con el cargo ($58,96): %', v_row.rendered_text;
  end if;

  -- D+7: ningún mensaje nuevo para D.
  perform public.helios_enqueue_reminders('cuota_manana', v_d + 7);
  perform public.helios_enqueue_reminders('cuota_hoy', v_d + 7);
  perform public.helios_enqueue_reminders('cuota_vencida_d1', v_d + 7);
  perform public.helios_enqueue_reminders('cargo_por_atraso_d4', v_d + 7);
  select count(*) into v_n from public.outbound_messages where profile_id = v_pac and installment_due_date = v_d;
  if v_n <> 5 then
    raise exception 'Una fecha tiene 5 mensajes (víspera ×2, día, +1, +4) y ninguno a los 7 días; hay %', v_n;
  end if;
  -- (La víspera de la cuota 2 cae justo en D+6: otra fecha, su propio aviso.)
  raise notice 'TEST AVISOS 2 OK — 5 mensajes por fecha en sus días, el +4 con el cargo';

  -- --- 4. Dos financiamientos el mismo día: un aviso con la suma -------------
  v_c2 := (pg_temp.prueba_cobro(v_pac2, v_merchant, v_branch, v_staff, 50.00, 'aviso-2')->>'charge_id')::uuid;
  v_c3 := (pg_temp.prueba_cobro(v_pac2, v_merchant, v_branch, v_staff, 50.00, 'aviso-3')->>'charge_id')::uuid;
  perform public.helios_enqueue_reminders('cuota_hoy', v_d);
  select * into v_row from public.outbound_messages
   where profile_id = v_pac2 and template_key = 'cuota_hoy' and installment_due_date = v_d;
  if (select count(*) from public.outbound_messages where profile_id = v_pac2 and template_key = 'cuota_hoy') <> 1
     or v_row.charge_id is not null or v_row.rendered_text not like '%$56,96%' then
    raise exception 'Dos financiamientos del mismo día: un aviso con la suma ($56.96): %', to_jsonb(v_row);
  end if;
  -- Sin correo, la víspera sale solo por WhatsApp.
  perform public.helios_enqueue_reminders('cuota_manana', v_d - 1);
  if exists (select 1 from public.outbound_messages where profile_id = v_pac2 and channel = 'email') then
    raise exception 'Sin correo no se encola el correo de la víspera';
  end if;
  raise notice 'TEST AVISOS 4 OK — un aviso por paciente y fecha, con la suma';

  -- --- 5. Registrar un pago cancela los avisos de esa fecha -----------------
  perform public.helios_enqueue_reminders('cuota_manana', v_d2 - 1);   -- la otra fecha

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_rep := public.admin_register_payment(v_pac, array[v_i1.id], 'pago_movil', 'Banesco', '55667788',
                                         v_today, 1000.00, null, 'Prueba de avisos');

  if exists (select 1 from public.outbound_messages
             where profile_id = v_pac and installment_due_date = v_d and status = 'pendiente') then
    raise exception 'Registrar el pago debía cancelar los avisos pendientes de D';
  end if;
  if (select count(*) from public.outbound_messages
       where profile_id = v_pac and installment_due_date = v_d and status = 'cancelado') <> 5 then
    raise exception 'Los 5 avisos de D debían quedar cancelados';
  end if;
  if not exists (select 1 from public.outbound_messages
                 where profile_id = v_pac and installment_due_date = v_d2 and status = 'pendiente') then
    raise exception 'Los avisos de la otra fecha no se tocan';
  end if;
  -- Con el pago esperando conciliación, D ya no genera avisos.
  delete from public.outbound_messages where profile_id = v_pac and installment_due_date = v_d and template_key = 'cuota_hoy';
  perform public.helios_enqueue_reminders('cuota_hoy', v_d);
  if exists (select 1 from public.outbound_messages
             where profile_id = v_pac and installment_due_date = v_d and template_key = 'cuota_hoy') then
    raise exception 'Con un pago registrado no se avisa de esa cuota';
  end if;
  raise notice 'TEST AVISOS 5 OK — el pago registrado cancela los avisos de su fecha y solo de ella';

  -- --- 6. Conciliar → pago_recibido ----------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_reconcile_payment((v_rep->>'report_id')::uuid, true, 'Cotejado a mano en la prueba');
  select * into v_row from public.outbound_messages where dedupe_key = 'pago_recibido:' || (v_rep->>'report_id');
  if not found or v_row.channel <> 'whatsapp_manual' or v_row.profile_id <> v_pac
     or v_row.rendered_text not like '%$58,96%' then
    raise exception 'Conciliar debía encolar pago_recibido con el monto: %', to_jsonb(v_row);
  end if;
  raise notice 'TEST AVISOS 6 OK — conciliar encola pago_recibido';

  -- --- 7. cuenta_congelada en la transición ---------------------------------
  update public.installments set due_date = v_today - 1 where id = v_i2.id;
  perform public.recompute_profile_mora_state(v_pac);
  if (select status from public.profiles where id = v_pac) <> 'frozen' then
    raise exception 'Con una cuota vencida ayer la cuenta debía congelarse';
  end if;
  select count(*) into v_n from public.outbound_messages where profile_id = v_pac and template_key = 'cuenta_congelada';
  if v_n <> 1 then
    raise exception 'Congelar debía encolar un cuenta_congelada (hay %)', v_n;
  end if;
  perform public.recompute_profile_mora_state(v_pac);
  if (select count(*) from public.outbound_messages where profile_id = v_pac and template_key = 'cuenta_congelada') <> 1 then
    raise exception 'Seguir congelada no es una transición: ningún aviso más';
  end if;
  update public.installments set due_date = v_today + 1 where id = v_i2.id;
  perform public.recompute_profile_mora_state(v_pac);
  if (select status from public.profiles where id = v_pac) <> 'active'
     or exists (select 1 from public.outbound_messages
                where profile_id = v_pac and template_key = 'cuenta_congelada' and status = 'pendiente') then
    raise exception 'Al descongelarse, el cuenta_congelada pendiente debía cancelarse';
  end if;
  raise notice 'TEST AVISOS 7 OK — cuenta_congelada solo al congelarse; se cancela al descongelar';

  -- --- 8. A los 7 días, Cobranza ----------------------------------------------
  update public.installments set due_date = v_today - 7 where id = v_i2.id;
  if not exists (
    select 1 from jsonb_array_elements(public.admin_collections(0) -> 'rows') r
    where r->>'user_id' = v_pac::text and (r->>'days_overdue')::integer = 7
  ) then
    raise exception 'Con 7 días de atraso el paciente debía estar en Cobranza';
  end if;
  raise notice 'TEST AVISOS 8 OK — a los 7 días el caso está en admin_collections';

  -- --- 9. La cola del equipo -------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  select id into v_msg from public.outbound_messages
   where profile_id = v_pac2 and template_key = 'cuota_hoy' and status = 'pendiente';

  if not exists (select 1 from public.admin_outbound_queue() q
                 where q.id = v_msg and q.template_label is not null and q.patient_name = 'Pedro Avisos'
                   and q.phone_e164 = '+584140009202' and q.due_date = v_d
                   and q.whatsapp_url like 'https://wa.me/584140009202?text=%') then
    raise exception 'El aviso debía estar en la cola de hoy con su enlace wa.me';
  end if;
  if exists (select 1 from public.admin_outbound_queue(null, 'whatsapp_manual') q where q.channel <> 'whatsapp_manual') then
    raise exception 'La cola de WhatsApp no trae correos';
  end if;

  -- omitido exige nota.
  begin
    perform public.admin_mark_outbound(v_msg, 'omitido', null);
    raise exception 'Omitir sin nota debía fallar';
  exception when sqlstate '22023' then null;
  end;

  perform public.admin_mark_outbound(v_msg, 'enviado');
  select * into v_row from public.outbound_messages where id = v_msg;
  if v_row.status <> 'enviado' or v_row.sent_by <> v_admin or v_row.sent_at is null then
    raise exception 'Marcar enviado no guardó quién y cuándo: %', to_jsonb(v_row);
  end if;
  if not exists (select 1 from public.collection_contacts
                 where user_id = v_pac2 and channel = 'whatsapp' and actor = v_admin
                   and template = 'cuota_hoy' and outcome = 'mensaje_enviado') then
    raise exception 'Marcar enviado debía anotar la gestión en collection_contacts';
  end if;
  if not exists (select 1 from audit.admin_actions where action = 'outbound.marked' and target_id = v_msg) then
    raise exception 'Marcar un aviso debía quedar en la bitácora';
  end if;
  -- Idempotente; y lo enviado no se omite.
  perform public.admin_mark_outbound(v_msg, 'enviado');
  begin
    perform public.admin_mark_outbound(v_msg, 'omitido', 'ya no');
    raise exception 'Lo enviado no se puede omitir';
  exception when sqlstate '22023' then null;
  end;
  -- Un correo no se marca enviado a mano.
  select id into v_msg from public.outbound_messages where profile_id = v_pac and channel = 'email' and status = 'pendiente' limit 1;
if v_msg is null then raise exception 'Faltaba un correo pendiente para la prueba'; end if;
  begin
    perform public.admin_mark_outbound(v_msg, 'enviado');
    raise exception 'Un correo no se marca enviado a mano';
  exception when sqlstate '22023' then null;
  end;

  if (select count(*) from public.admin_outbound_history(null, null, 'Pedro Avisos', 50, 0)) < 1
     or exists (select 1 from public.admin_outbound_history('email', null, null, 50, 0) h where h.channel <> 'email')
     or not exists (select 1 from public.admin_outbound_history('email', null, 'maria.avisos', 50, 0) h
                    where h.email = 'maria.avisos@prueba.helios.test' and h.attempts = 0 and h.total_count >= 1) then
    raise exception 'El historial no filtra como debía';
  end if;
  raise notice 'TEST AVISOS 9 OK — cola de hoy, marcar enviado/omitido e historial';

  -- --- 10. Los crons ---------------------------------------------------------
  if exists (select 1 from cron.job where jobname like 'helios_installment_%') then
    raise exception 'Los 12 crons de avisos de Ronda debían irse';
  end if;
  if (select count(*) from cron.job where
        (jobname = 'helios_aviso_cuota_manana'        and schedule = '0 23 * * *')
     or (jobname = 'helios_aviso_cuota_hoy'           and schedule = '0 12 * * *')
     or (jobname = 'helios_aviso_cuota_vencida_d1'    and schedule = '5 12 * * *')
     or (jobname = 'helios_aviso_cargo_por_atraso_d4' and schedule = '30 14 * * *')) <> 4 then
    raise exception 'Los 4 crons de Helios no están a su hora';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_set_notification_schedule('cuota_manana', time '18:30', 2);
  if not exists (select 1 from cron.job where jobname = 'helios_aviso_cuota_manana' and schedule = '30 22 * * *'
                   and command like '%helios_enqueue_reminders(''cuota_manana'')%')
     or (select lead_days from public.notification_templates where key = 'cuota_manana') <> 2 then
    raise exception 'admin_set_notification_schedule debía reprogramar el cron y la antelación';
  end if;
  if public.helios_reminder_offset('cuota_manana') <> -2 then
    raise exception 'Con lead_days = 2 la víspera es D-2';
  end if;
  begin
    perform public.admin_set_notification_schedule('cuota_hoy', time '09:00', 3);
    raise exception 'cuota_hoy no lleva días';
  exception when sqlstate '22023' then null;
  end;
  raise notice 'TEST AVISOS 10 OK — 4 crons de Helios, ninguno de Ronda; se reprograman desde el panel';
end;
$$;

set constraints all immediate;
rollback;
