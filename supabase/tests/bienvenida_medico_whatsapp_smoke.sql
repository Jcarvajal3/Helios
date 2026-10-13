-- ============================================================================
-- Helios — Prueba de humo del WhatsApp de bienvenida al médico aprobado
-- (20261013000400_al_aprobar_al_medico_le_llega_su_bienvenida y
-- 20261013000500_la_bienvenida_del_medico_usa_helios_cuenta_activa)
--
-- No sale nada: los mensajes se encolan dentro de la transacción y el
-- rollback los borra antes de que el cron los vea. La ventana de 24 h se
-- sustituye por un doble (también se va con el rollback).
--
-- 1. Sin número del bot → `sin_numero`.
-- 2. Ventana cerrada y sin plantilla conectada → `sin_plantilla`, sin encolar.
-- 3. Ventana cerrada con plantilla → en cola con la plantilla y sus variables.
-- 4. La segunda vez → `ya_enviado`.
-- 5. Ventana abierta (otra persona) → el texto de la plantilla con el botón
--    «Empezar», sin la contraseña ni palabras prohibidas.
-- 6. Un operador no la manda.
-- ============================================================================

begin;

create temp table _ventana (abierta boolean) on commit drop;
insert into _ventana values (false);
grant all on _ventana to authenticated;

create or replace function public.helios_whatsapp_window_open(p_phone text)
returns boolean language sql stable as $$ select abierta from pg_temp._ventana $$;

do $$
declare
  v_super    uuid := gen_random_uuid();
  v_operador uuid := gen_random_uuid();
  v_merchant uuid;
  v_medico   uuid;
  v_otra     uuid;
  v_res      jsonb;
  v_msg      public.outbound_messages%rowtype;
  v_failed   boolean;
begin
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values (v_super,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000094', now(), now(), now()),
         (v_operador, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000095', now(), now(), now());
  insert into public.platform_admins (user_id, role, full_name) values
    (v_super, 'super_admin', 'Jefa'), (v_operador, 'operador', 'Operador');

  insert into public.merchants (name, tax_id) values ('Consultorio Bienvenida WA Prueba', 'J-509876500')
  returning id into v_merchant;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  v_medico := (public.merchant_staff_add(v_merchant, 'medico.wa.prueba@example.com', 'Clave-Segura-1', 'Ana Pérez', 'gerente')->>'user_id')::uuid;

  -- --- 1. Sin número -----------------------------------------------------
  v_res := public.admin_send_staff_whatsapp_welcome(v_merchant, v_medico);
  if v_res->>'status' <> 'sin_numero' then raise exception '1: %', v_res; end if;

  -- --- 2. Ventana cerrada, sin plantilla ---------------------------------
  perform public.admin_set_staff_whatsapp(v_medico, v_merchant, '0426-999-0011');
  reset role;
  if (select wa_template_name from public.notification_templates where key = 'bienvenida_medico') <> 'helios_cuenta_activa' then
    raise exception 'La bienvenida debía estar conectada a helios_cuenta_activa';
  end if;
  update public.notification_templates set wa_template_name = null where key = 'bienvenida_medico';
  set local role authenticated;
  v_res := public.admin_send_staff_whatsapp_welcome(v_merchant, v_medico);
  if v_res->>'status' <> 'sin_plantilla' then raise exception '2: %', v_res; end if;
  reset role;
  if exists (select 1 from public.outbound_messages where recipient_staff_id = v_medico) then
    raise exception '2: sin plantilla no debía encolar nada';
  end if;

  -- --- 3. Con plantilla ---------------------------------------------------
  update public.notification_templates set wa_template_name = 'helios_cuenta_activa' where key = 'bienvenida_medico';
  set local role authenticated;
  v_res := public.admin_send_staff_whatsapp_welcome(v_merchant, v_medico);
  if v_res->>'status' <> 'en_cola' or v_res->>'via' <> 'plantilla' then raise exception '3: %', v_res; end if;
  reset role;
  select * into v_msg from public.outbound_messages where recipient_staff_id = v_medico;
  if v_msg.recipient <> '+584269990011' or v_msg.status <> 'pendiente' or v_msg.channel <> 'whatsapp'
     or v_msg.wa_template->>'name' <> 'helios_cuenta_activa'
     or v_msg.wa_template->>'language' <> 'es'
     or v_msg.wa_template->'params' <> '["Ana Pérez", "Consultorio Bienvenida WA Prueba", "medico.wa.prueba@example.com"]'::jsonb
     or v_msg.wa_template->'buttons' <> '[]'::jsonb then
    raise exception '3: el mensaje no quedó como debía: %', to_jsonb(v_msg);
  end if;

  -- --- 4. Una sola vez ------------------------------------------------------
  set local role authenticated;
  v_res := public.admin_send_staff_whatsapp_welcome(v_merchant, v_medico);
  if v_res->>'status' <> 'ya_enviado' then raise exception '4: %', v_res; end if;

  -- --- 5. Ventana abierta: texto libre ------------------------------------
  v_otra := (public.merchant_staff_add(v_merchant, 'otra.wa.prueba@example.com', 'Clave-Segura-2', 'Luis Gómez', 'gerente')->>'user_id')::uuid;
  perform public.admin_set_staff_whatsapp(v_otra, v_merchant, '0426-999-0012');
  update pg_temp._ventana set abierta = true;
  v_res := public.admin_send_staff_whatsapp_welcome(v_merchant, v_otra);
  if v_res->>'via' <> 'texto' then raise exception '5: %', v_res; end if;
  reset role;
  select * into v_msg from public.outbound_messages where recipient_staff_id = v_otra;
  if v_msg.wa_template->>'name' is not null
     or v_msg.wa_template->'buttons' <> '[{"id": "menu:empezar", "title": "Empezar"}]'::jsonb
     or position('Tu cuenta en Consultorio Bienvenida WA Prueba ya está activa' in v_msg.rendered_text) = 0
     or position('otra.wa.prueba@example.com' in v_msg.rendered_text) = 0
     or position('¡Hola, Luis Gómez!' in v_msg.rendered_text) = 0
     or position('Clave-Segura' in v_msg.rendered_text) > 0
     or v_msg.rendered_text ~* 'cr[eé]dito|financ|préstamo|\mfee\M' then
    raise exception '5: el texto no salió como debía: %', v_msg.rendered_text;
  end if;

  -- --- 6. Un operador no ----------------------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_operador::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_failed := false;
  begin
    perform public.admin_send_staff_whatsapp_welcome(v_merchant, v_otra);
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception '6: un operador no debía mandarla'; end if;
  reset role;

  raise notice '=== BIENVENIDA POR WHATSAPP: TODO OK ===';
end $$;

set constraints all immediate;

rollback;
