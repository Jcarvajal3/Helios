-- ============================================================================
-- Helios — Prueba de humo de lo que el webhook usa de la base (20261005000500)
--
--   bash supabase/tests/run.sh whatsapp_webhook_smoke
--
--  1. Los números del bot: registrar (móvil VE, solo personal activo de esa
--     clínica), un número es de una sola persona, cambiar de número revoca el
--     anterior, revocar exige motivo, resetear el PIN, la bitácora y que solo
--     el super_admin escribe.
--  2. Recibir: se guarda una vez (el reintento es `duplicate`), abre la
--     ventana de 24 h, reconoce al personal y la orden pendiente del paciente.
--  3. El PIN del personal se guarda tachado; el de un paciente no se toca.
--  4. Dos órdenes esperando al mismo teléfono (una familia): ninguna se
--     decide por texto.
--  5. Dar de baja a la persona revoca su número; anotar adónde fue un mensaje.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_gerente uuid := gen_random_uuid();
  v_cajero  uuid := gen_random_uuid();
  v_otra_p  uuid := gen_random_uuid();
  v_m       uuid;
  v_otra    uuid;
  v_bdate   date := public.helios_business_date(now());
  v_pac     jsonb;
  v_j       jsonb;
  v_charge  uuid;
  v_charge2 uuid;
  v_num     uuid;
  v_failed  boolean;
  v_err     text;
  v_row     record;
begin
  update public.platform_maintenance set is_active = false;
  insert into public.business_parameters (key, value, effective_from, note)
  values ('patient_confirmation_required', 1, v_bdate, 'prueba')
  on conflict (key, effective_from) do update set value = 1;
  if not public.helios_whatsapp_api_ready() then
    perform vault.create_secret('prueba', 'd360_api_key');
    perform vault.create_secret('https://waba-sandbox.360dialog.io/v1', 'd360_base_url');
  end if;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values
    (v_gerente, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'wh-gerente@prueba.helios.test', now(), now(), '{"full_name":"Dra. Laura Gómez"}'),
    (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'wh-cajero@prueba.helios.test', now(), now(), '{"full_name":"Ana Secretaria"}'),
    (v_otra_p, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'wh-otra@prueba.helios.test', now(), now(), '{"full_name":"Otra Persona"}');

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_m    := (public.admin_create_merchant('Consultorio Webhook', null, 'J-400000031', 'consultorio')).id;
  v_otra := (public.admin_create_merchant('Otra Webhook', null, 'J-400000032', 'clinica')).id;
  reset role;

  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_gerente, v_m, (select id from public.merchant_branches where merchant_id = v_m and is_default), 'gerente'),
    (v_cajero,  v_m, (select id from public.merchant_branches where merchant_id = v_m and is_default), 'cajero'),
    (v_otra_p,  v_otra, (select id from public.merchant_branches where merchant_id = v_otra and is_default), 'gerente');

  -- =========================================================================
  -- 1. Los números del bot
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  v_j := public.admin_set_staff_whatsapp(v_gerente, v_m, '0414-555.66.77');
  v_num := (v_j->>'id')::uuid;
  if v_j->>'phone_e164' <> '+584145556677' or v_j->>'role' <> 'gerente'
     or v_j->>'staff_name' <> 'Dra. Laura Gómez' or (v_j->>'has_pin')::boolean then
    raise exception 'El número no quedó bien: %', v_j;
  end if;

  -- El mismo, otra vez: lo devuelve sin duplicar.
  if (public.admin_set_staff_whatsapp(v_gerente, v_m, '04145556677'))->>'id' <> v_num::text then
    raise exception 'Registrar el mismo número otra vez debía devolver el mismo';
  end if;

  v_failed := false;
  begin
    perform public.admin_set_staff_whatsapp(v_cajero, v_m, '04145556677');
  exception when others then v_failed := true; v_err := sqlerrm; end;
  if not v_failed or v_err not like 'Ese número ya está registrado para Dra. Laura Gómez%' then
    raise exception 'Un número activo es de una sola persona: %', coalesce(v_err, 'sin error');
  end if;

  v_failed := false;
  begin
    perform public.admin_set_staff_whatsapp(v_otra_p, v_m, '04121112233');
  exception when others then v_failed := true; v_err := sqlerrm; end;
  if not v_failed or v_err <> 'Esa persona no es personal activo de esa clínica' then
    raise exception 'Solo personal activo de esa clínica: %', coalesce(v_err, 'sin error');
  end if;

  v_failed := false;
  begin
    perform public.admin_set_staff_whatsapp(v_cajero, v_m, '02125551234');
  exception when others then v_failed := true; v_err := sqlerrm; end;
  if not v_failed or v_err <> 'Teléfono móvil inválido' then
    raise exception 'Solo móviles: %', coalesce(v_err, 'sin error');
  end if;

  -- Cambio de número: el anterior se revoca solo.
  v_j := public.admin_set_staff_whatsapp(v_gerente, v_m, '04245556677');
  reset role;
  if (select revoke_reason from public.staff_whatsapp_numbers where id = v_num) <> 'Cambio de número'
     or (select count(*) from public.staff_whatsapp_numbers where user_id = v_gerente and revoked_at is null) <> 1 then
    raise exception 'Cambiar de número debía revocar el anterior';
  end if;
  v_num := (v_j->>'id')::uuid;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  perform public.admin_set_staff_whatsapp(v_cajero, v_m, '04145556677');

  if jsonb_array_length(public.admin_staff_whatsapp(v_m)) <> 3
     or jsonb_array_length(public.admin_staff_whatsapp(v_otra)) <> 0 then
    raise exception 'La lista de números de la clínica no cuadra: %', public.admin_staff_whatsapp(v_m);
  end if;

  v_failed := false;
  begin
    perform public.admin_revoke_staff_whatsapp(v_num, ' ');
  exception when others then v_failed := true; v_err := sqlerrm; end;
  if not v_failed or v_err <> 'Escribe el motivo' then
    raise exception 'Revocar exige motivo: %', coalesce(v_err, 'sin error');
  end if;

  reset role;
  insert into public.staff_pins (user_id, pin_hash) values (v_gerente, extensions.crypt('4821', extensions.gen_salt('bf')));
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  if not ((select public.admin_staff_whatsapp(v_m)) @> jsonb_build_array(jsonb_build_object('id', v_num, 'has_pin', true))) then
    raise exception 'La lista debía decir que tiene PIN';
  end if;
  v_j := public.admin_reset_staff_pin(v_gerente, 'Olvidó el PIN');
  reset role;
  if not (v_j->>'had_pin')::boolean or exists (select 1 from public.staff_pins where user_id = v_gerente) then
    raise exception 'Resetear el PIN debía borrarlo: %', v_j;
  end if;

  if (select count(*) from audit.admin_actions
       where action in ('staff.whatsapp_set', 'staff.pin_reset') and target_id in (v_gerente, v_cajero)) < 4 then
    raise exception 'Faltan entradas en la bitácora';
  end if;

  -- El personal de la clínica no administra números.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_gerente::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.admin_set_staff_whatsapp(v_cajero, v_m, '04167778899');
  exception when others then v_failed := true; end;
  reset role;
  if not v_failed then
    raise exception 'Solo el super_admin registra números';
  end if;

  -- =========================================================================
  -- 2. Recibir
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_pac := jsonb_build_object(
    'document', 'V40000001', 'first_name', 'José', 'last_name', 'Pérez',
    'birth_date', (v_bdate - interval '30 years')::date, 'sex', 'M',
    'phone', '04141234567', 'email', 'jose@gmail.com',
    'state', 'Miranda', 'city', 'Caracas', 'address', 'Los Palos Grandes',
    'reference_name', 'María Pérez', 'reference_phone', '02125551234', 'reference_relationship', 'Madre');
  perform public.helios_patient_eligibility(v_m, 'V40000001');
  v_charge := ((public.create_patient_charge(v_m, null, v_pac, 50, null, null, 'wh-key-1'))->>'id')::uuid;
  reset role;

  v_j := public.helios_whatsapp_inbound('wamid.P1', '584141234567', 'text', '{"text":{"body":"Sí"}}');
  if not (v_j->>'ok')::boolean or (v_j->>'duplicate')::boolean or v_j->'staff' <> 'null'::jsonb
     or v_j->>'pending_charge_id' <> v_charge::text or v_j->>'phone_e164' <> '+584141234567' then
    raise exception 'El paciente con una orden esperando: %', v_j;
  end if;
  if not public.helios_whatsapp_window_open('+584141234567')
     or (select profile_id from public.whatsapp_contacts where phone_e164 = '+584141234567')
        <> (select user_id from public.charges where id = v_charge) then
    raise exception 'Recibir debía abrir la ventana y anotar al paciente';
  end if;

  v_j := public.helios_whatsapp_inbound('wamid.P1', '584141234567', 'text', '{"text":{"body":"Sí"}}');
  if not (v_j->>'duplicate')::boolean
     or (select count(*) from public.whatsapp_inbound where wa_message_id = 'wamid.P1') <> 1 then
    raise exception 'Un reintento es duplicate: %', v_j;
  end if;

  -- =========================================================================
  -- 3. El PIN se guarda tachado
  -- =========================================================================
  v_j := public.helios_whatsapp_inbound('wamid.G1', '584245556677', 'text', '{"text":{"body":" 4821 "}}');
  if v_j->'staff'->>'user_id' <> v_gerente::text or v_j->'staff'->>'merchant_id' <> v_m::text
     or v_j->'staff'->>'role' <> 'gerente' then
    raise exception 'Debía reconocer a la doctora: %', v_j;
  end if;
  if (select payload->'text'->>'body' from public.whatsapp_inbound where wa_message_id = 'wamid.G1') <> '[PIN]' then
    raise exception 'El PIN del personal se guarda tachado';
  end if;
  perform public.helios_whatsapp_inbound('wamid.P2', '584141234567', 'text', '{"text":{"body":"1234"}}');
  if (select payload->'text'->>'body' from public.whatsapp_inbound where wa_message_id = 'wamid.P2') <> '1234' then
    raise exception 'Lo que escribe un paciente no se toca';
  end if;

  -- El número que dejó la doctora ahora es de la secretaria.
  v_j := public.helios_whatsapp_inbound('wamid.G0', '584145556677', 'text', '{"text":{"body":"hola"}}');
  if v_j->>'staff' is null or v_j->'staff'->>'user_id' <> v_cajero::text then
    raise exception 'El número que pasó a la secretaria es de ella: %', v_j;
  end if;

  -- =========================================================================
  -- 4. Dos órdenes esperando al mismo teléfono
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V40000002');
  v_charge2 := ((public.create_patient_charge(v_m, null,
                  v_pac || jsonb_build_object('document', 'V40000002', 'first_name', 'Pedro', 'email', 'p@gmail.com'),
                  30, null, null, 'wh-key-2'))->>'id')::uuid;
  reset role;

  v_j := public.helios_whatsapp_inbound('wamid.P3', '584141234567', 'text', '{"text":{"body":"si"}}');
  if v_j->'pending_charge_id' <> 'null'::jsonb then
    raise exception 'Con dos órdenes esperando al mismo teléfono, el texto no decide: %', v_j;
  end if;

  -- =========================================================================
  -- 5. La baja revoca el número; anotar el destino
  -- =========================================================================
  update public.merchant_users set is_active = false where user_id = v_cajero and merchant_id = v_m;
  if exists (select 1 from public.staff_whatsapp_numbers where user_id = v_cajero and revoked_at is null) then
    raise exception 'Dar de baja a la persona debía revocar su número';
  end if;
  v_j := public.helios_whatsapp_inbound('wamid.C9', '584145556677', 'text', '{"text":{"body":"hola"}}');
  if v_j->'staff' <> 'null'::jsonb then
    raise exception 'Un número revocado ya no es personal: %', v_j;
  end if;

  perform public.helios_whatsapp_inbound_done('wamid.C9', 'nadie', null);
  select * into v_row from public.whatsapp_inbound where wa_message_id = 'wamid.C9';
  if v_row.route <> 'nadie' or v_row.routed_at is null then
    raise exception 'Debía anotar adónde fue el mensaje';
  end if;

  -- Solo el webhook (service_role) recibe.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.helios_whatsapp_inbound('wamid.X', '584141234567', 'text', '{}');
  exception when insufficient_privilege then v_failed := true; end;
  reset role;
  if not v_failed then
    raise exception 'Ni el equipo de Helios llama al webhook desde la API';
  end if;
end;
$$;

set constraints all immediate;

rollback;
