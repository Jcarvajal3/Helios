-- ============================================================================
-- Helios — Prueba de humo del aviso de la transferencia a la clínica
-- (20261020100000 y 20261020100100)
--
-- Solo encola: inserta en `outbound_messages`, que se va con el rollback. El
-- despachador de correos (cron) nunca lo ve: NO sale ningún correo.
--
-- 1. Registrar una transferencia encola un correo por administrador activo de
--    la clínica (no a la secretaria, no a un administrador dado de baja).
-- 2. Por correo, nunca por WhatsApp; dice el monto, la referencia y el
--    reparto, y nunca la Comisión Helios.
-- 3. Solo de comisiones: no dice «consultas».
-- 4. Con la plantilla apagada no se encola nada.
-- ============================================================================

begin;
-- @ayudas

do $$
declare
  v_merchant uuid;
  v_branch   uuid;
  v_gerente  uuid := gen_random_uuid();
  v_baja     uuid := gen_random_uuid();
  v_cajera   uuid := gen_random_uuid();
  v_super    uuid := gen_random_uuid();
  v_payout   uuid;
  v_n        integer;
  v_texto    text;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
    (v_gerente, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'jefa.aviso@prueba.helios', now(), now()),
    (v_baja,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'baja.aviso@prueba.helios', now(), now()),
    (v_cajera,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cajera.aviso@prueba.helios', now(), now()),
    (v_super,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'equipo.aviso@prueba.helios', now(), now());

  insert into public.merchants (name) values ('Consultorio Aviso Prueba') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;

  insert into public.merchant_users (user_id, merchant_id, branch_id, role, is_active) values
    (v_gerente, v_merchant, v_branch, 'gerente', true),
    (v_baja,    v_merchant, v_branch, 'gerente', false),
    (v_cajera,  v_merchant, v_branch, 'cajero',  true);

  -- --- 1 y 2. Una transferencia con consultas y comisiones -------------------
  insert into public.merchant_payouts (merchant_id, amount_usd, amount_ves, method, reference, business_date, consultas_usd, comisiones_usd, paid_by)
  values (v_merchant, 100.50, 98000.00, 'pago_movil', '123456789', current_date, 100.00, 0.50, v_super)
  returning id into v_payout;
  set constraints all immediate;

  select count(*) into v_n from public.outbound_messages where template_key = 'pago_a_clinica' and rendered_text like '%Consultorio Aviso Prueba%';
  if v_n <> 1 then
    raise exception 'Debía encolarse 1 correo (solo el administrador activo), hay %', v_n;
  end if;
  if exists (select 1 from public.outbound_messages where template_key = 'pago_a_clinica' and channel <> 'email') then
    raise exception 'El aviso de la transferencia va solo por correo';
  end if;

  select rendered_text into v_texto from public.outbound_messages
  where template_key = 'pago_a_clinica' and recipient = 'jefa.aviso@prueba.helios';
  if v_texto is null then
    raise exception 'El correo debía ir al administrador activo';
  end if;
  if v_texto not like '%123456789%' or v_texto not like '%consultas%' or v_texto not like '%comisiones de su personal%' then
    raise exception 'El correo debía decir la referencia y el reparto: %', v_texto;
  end if;
  if v_texto ilike '%Comisión Helios%' or v_texto ilike '%fee%' then
    raise exception 'A la clínica nunca se le enseña la Comisión Helios: %', v_texto;
  end if;
  raise notice 'TEST AVISO 1-2 OK — un correo al administrador, con la referencia y el reparto';

  -- --- 3. Solo comisiones ------------------------------------------------
  insert into public.merchant_payouts (merchant_id, amount_usd, method, reference, business_date, consultas_usd, comisiones_usd, paid_by)
  values (v_merchant, 1.50, 'transferencia', 'R-2', current_date, 0, 1.50, v_super)
  returning id into v_payout;
  set constraints all immediate;

  select rendered_text into v_texto from public.outbound_messages
  where dedupe_key = format('pago_a_clinica:%s:%s', v_payout, v_gerente);
  if v_texto is null or v_texto like '%consultas%' then
    raise exception 'Solo de comisiones no debía hablar de consultas: %', v_texto;
  end if;
  raise notice 'TEST AVISO 3 OK — solo comisiones, sin «consultas $0»';

  -- --- 4. Plantilla apagada ----------------------------------------------
  update public.notification_templates set enabled = false where key = 'pago_a_clinica';
  insert into public.merchant_payouts (merchant_id, amount_usd, method, reference, business_date, paid_by)
  values (v_merchant, 10, 'transferencia', 'R-3', current_date, v_super)
  returning id into v_payout;
  set constraints all immediate;
  if exists (select 1 from public.outbound_messages where dedupe_key like format('pago_a_clinica:%s:%%', v_payout)) then
    raise exception 'Con la plantilla apagada no se debía encolar nada';
  end if;
  raise notice 'TEST AVISO 4 OK — apagada, no se encola';

  raise notice '=== TODOS LOS TESTS DEL AVISO DE LA TRANSFERENCIA PASARON ===';
end $$;

set constraints all immediate;

rollback;
