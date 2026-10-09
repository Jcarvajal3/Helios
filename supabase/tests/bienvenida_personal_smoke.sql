-- ============================================================================
-- Helios — Prueba de humo del correo de bienvenida al personal
-- (20261009000300_el_personal_recibe_su_bienvenida_por_correo)
--
-- Sustituye `helios_resend_api_key` y `helios_resend_request` (la única
-- llamada HTTP) por dobles dentro de la transacción: NO sale ningún correo.
-- El rollback devuelve las de verdad.
--
-- 1. Sin remitente configurado → `sin_configurar`, sin llamar a Resend.
-- 2. Con remitente: un POST /emails al correo de la persona, con bcc a la
--    copia, la contraseña en el texto y el HTML, y el enlace del panel.
-- 3. Con su WhatsApp registrado, el correo dice su número y cómo empezar.
-- 4. Una contraseña que no es la de la cuenta → 22023, sin llamar a Resend.
-- 5. Quien no gestiona el personal no puede mandarlo.
-- 6. Resend responde 4xx → `fallido`, sin lanzar.
-- 7. La bitácora no guarda la contraseña.
-- ============================================================================

begin;
-- @ayudas

create temp table _llamadas (path text, body jsonb) on commit drop;
create temp table _respuesta (status int) on commit drop;
insert into _respuesta values (200);
grant all on _llamadas, _respuesta to authenticated;

create or replace function public.helios_resend_api_key()
returns text language sql stable as $$ select 're_prueba'::text $$;

create or replace function public.helios_resend_request(
  p_method text, p_path text, p_api_key text, p_body jsonb default null, p_idempotency_key text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into pg_temp._llamadas (path, body) values (p_path, p_body);
  return jsonb_build_object('status', (select status from pg_temp._respuesta), 'body', '{"id":"re_1"}');
end;
$$;

do $$
declare
  v_super    uuid := gen_random_uuid();
  v_merchant uuid;
  v_res      jsonb;
  v_staff    uuid;
  v_otro     uuid;
  v_body     jsonb;
  v_failed   boolean;
begin
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values (v_super, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000093', now(), now(), now());
  insert into public.platform_admins (user_id, role, full_name) values (v_super, 'super_admin', 'Jefa');

  insert into public.merchants (name, tax_id) values ('Consultorio Bienvenida Prueba', 'J-509876543')
  returning id into v_merchant;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  v_res := public.merchant_staff_add(v_merchant, 'maria.bienvenida.prueba@example.com', 'Clave-Segura-1', 'María González', 'cajero');
  v_staff := (v_res->>'user_id')::uuid;

  -- --- 1. Sin remitente --------------------------------------------------
  v_res := public.merchant_staff_send_welcome(v_merchant, v_staff, 'Clave-Segura-1');
  if v_res->>'status' <> 'sin_configurar' then raise exception 'Sin remitente debía quedar sin_configurar: %', v_res; end if;
  if exists (select 1 from pg_temp._llamadas) then raise exception 'Sin remitente no debía llamar a Resend'; end if;

  reset role;
  update public.platform_contact
     set sender_email = 'soporte@example.com', sender_name = 'Helios',
         whatsapp_number = '+584120000000', staff_welcome_copy = 'copia@example.com'
   where id;
  set local role authenticated;

  -- --- 2. Sale con su copia ---------------------------------------------
  v_res := public.merchant_staff_send_welcome(v_merchant, v_staff, 'Clave-Segura-1');
  if v_res->>'status' <> 'enviado' then raise exception 'Debía enviarse: %', v_res; end if;
  select body into v_body from pg_temp._llamadas where path = '/emails';
  if v_body->'to' <> '["maria.bienvenida.prueba@example.com"]'::jsonb
     or v_body->'bcc' <> '["copia@example.com"]'::jsonb
     or v_body->>'from' <> 'Helios <soporte@example.com>'
     or v_body->>'subject' <> 'Tu acceso a Helios · Consultorio Bienvenida Prueba'
     or position('Clave-Segura-1' in v_body->>'text') = 0
     or position('Clave-Segura-1' in v_body->>'html') = 0
     or position('https://conhelios.com/login' in v_body->>'html') = 0
     or position('Hola, María González' in v_body->>'text') = 0
     or position('secretaria' in v_body->>'text') = 0
     or position('registre tu número' in v_body->>'text') = 0 then
    raise exception 'El correo no salió como debía: %', v_body;
  end if;
  if (v_body->>'text') ~* 'cr[eé]dito|financ|préstamo|\mfee\M' then
    raise exception 'El correo usa una palabra prohibida';
  end if;

  -- --- 3. Con su WhatsApp ------------------------------------------------
  perform public.admin_set_staff_whatsapp(v_staff, v_merchant, '0426-999-0001');
  delete from pg_temp._llamadas;
  v_res := public.merchant_staff_send_welcome(v_merchant, v_staff, 'Clave-Segura-1');
  select body into v_body from pg_temp._llamadas;
  if position('04269990001' in v_body->>'text') = 0 or position('https://wa.me/584120000000' in v_body->>'html') = 0 then
    raise exception 'Con WhatsApp registrado, el correo debía decir su número y el enlace del bot: %', v_body->>'text';
  end if;

  -- --- 4. Contraseña equivocada ------------------------------------------
  delete from pg_temp._llamadas;
  v_failed := false;
  begin
    perform public.merchant_staff_send_welcome(v_merchant, v_staff, 'otra-clave');
  exception when invalid_parameter_value then v_failed := true;
  end;
  if not v_failed or exists (select 1 from pg_temp._llamadas) then
    raise exception 'Una contraseña que no es la de la cuenta no debía mandarse';
  end if;

  -- --- 5. Quien no gestiona el personal ----------------------------------
  v_res := public.merchant_staff_add(v_merchant, 'otro.bienvenida.prueba@example.com', 'Clave-Segura-2', 'Otro', 'cajero');
  v_otro := (v_res->>'user_id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', v_otro::text, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  v_failed := false;
  begin
    perform public.merchant_staff_send_welcome(v_merchant, v_staff, 'Clave-Segura-1');
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'Una secretaria no debía poder mandar la bienvenida de otra'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- --- 6. Resend rechaza --------------------------------------------------
  update pg_temp._respuesta set status = 422;
  v_res := public.merchant_staff_send_welcome(v_merchant, v_staff, 'Clave-Segura-1');
  if v_res->>'status' <> 'fallido' then raise exception 'Un 4xx debía quedar fallido: %', v_res; end if;

  -- --- 7. La bitácora sin contraseña -------------------------------------
  reset role;
  if not exists (select 1 from audit.admin_actions where action = 'merchant.staff_welcome_sent' and target_id = v_merchant) then
    raise exception 'El envío debía quedar en la bitácora';
  end if;
  if exists (select 1 from audit.admin_actions where target_id = v_merchant and detail::text like '%Clave-Segura%') then
    raise exception 'La bitácora no debe guardar la contraseña';
  end if;

  raise notice '=== BIENVENIDA AL PERSONAL: TODO OK ===';
end $$;

set constraints all immediate;

rollback;
