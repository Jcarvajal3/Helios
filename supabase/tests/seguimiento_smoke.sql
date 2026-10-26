-- ============================================================================
-- Helios — El seguimiento de las clínicas (20261021100000)
--
--   bash supabase/tests/run.sh seguimiento_smoke
--
-- Se comprueba que:
--   1. Alguien de fuera del equipo no lee el tablero ni anota (42501).
--   2. El tablero trae la clínica con su personal, el número del bot de cada
--      uno y cuántas órdenes registró cada quien (las de un paciente de
--      prueba no cuentan).
--   3. Anotar valida canal, motivo, nota, persona y fecha (22023).
--   4. Lo anotado sale en la historia y en el tablero (último contacto y
--      próximo), y queda en audit.admin_actions.
--   5. La nota más nueva manda sobre «volver a llamar».
--   6. El panel anota el uso solo del personal de esa clínica, el bot anota
--      cada mensaje del personal (un reintento no cuenta dos veces) y el
--      tablero trae el último panel, el último bot y los días de uso.
--
-- No manda nada: no llama a `helios_dispatch_*`.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_extrano uuid := gen_random_uuid();
  v_gerente uuid := gen_random_uuid();
  v_ana     uuid := gen_random_uuid();
  v_ajena   uuid := gen_random_uuid();
  v_m       uuid;
  v_br      uuid;
  v_hoy     date := public.helios_business_date(now());
  v_pac     jsonb;
  v_j       jsonb;
  v_c       jsonb;
  v_s       jsonb;
  v_id      uuid;
  v_n       integer;
  v_usos    integer;
  v_fallo   boolean;
  v_fila    audit.admin_actions;
begin
  update public.platform_maintenance set is_active = false;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values
    (v_gerente, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'seg-gerente@prueba.helios.test', now(), now(), '{"full_name":"Gabriela Gerente"}'),
    (v_ana, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'seg-ana@prueba.helios.test', now(), now(), '{"full_name":"Ana Secretaria"}'),
    (v_ajena, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'seg-ajena@prueba.helios.test', now(), now(), '{"full_name":"De Otra Clínica"}');

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_m := (public.admin_create_merchant('Clínica Seguimiento', null, 'J-610000001', 'clinica')).id;
  reset role;

  select id into v_br from public.merchant_branches where merchant_id = v_m and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_gerente, v_m, v_br, 'gerente'),
    (v_ana, v_m, v_br, 'cajero');
  insert into public.staff_whatsapp_numbers (phone_e164, user_id, merchant_id, created_by)
  values ('+584149990001', v_ana, v_m, v_admin);

  -- Ana registra dos órdenes; el gerente, ninguna.
  v_pac := jsonb_build_object(
    'document', 'V61000001', 'first_name', 'Carla', 'last_name', 'Rojas',
    'birth_date', '1985-05-05', 'sex', 'F', 'phone', '04121230001', 'email', 'carla.seg@correo.com',
    'state', 'Lara', 'city', 'Barquisimeto', 'address', 'Centro');
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V61000001');
  perform public.create_patient_charge(v_m, null, v_pac, 40, null, null, 'seg-a');
  perform public.create_patient_charge(v_m, null, v_pac, 30, null, null, 'seg-b');
  reset role;

  -- =========================================================================
  -- 1. Fuera del equipo
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_extrano::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_followups_board();
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '1. alguien de fuera del equipo leyó el tablero'; end if;

  v_fallo := false;
  begin
    perform public.admin_log_merchant_followup(v_m, 'llamada', 'seguimiento', 'Hola');
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '1. alguien de fuera del equipo anotó un contacto'; end if;

  -- Desde aquí, el admin.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- =========================================================================
  -- 2. El tablero
  -- =========================================================================
  v_j := public.admin_followups_board();
  select e into v_c from jsonb_array_elements(v_j) e where e ->> 'merchant_id' = v_m::text;
  if v_c is null then raise exception '2. la clínica no sale en el tablero'; end if;
  if (v_c ->> 'orders_confirmed')::int <> 2 or (v_c ->> 'orders_30d')::int <> 2 then
    raise exception '2. la clínica debía llevar 2 órdenes: %', v_c;
  end if;
  if jsonb_array_length(v_c -> 'staff') <> 2 then
    raise exception '2. el personal debía ser de 2: %', v_c -> 'staff';
  end if;
  if v_c -> 'last_followup' <> 'null'::jsonb or v_c ->> 'next_contact_on' is not null
     or (v_c ->> 'followups_count')::int <> 0 then
    raise exception '2. una clínica sin contactos no puede tener último contacto: %', v_c;
  end if;

  -- El primero del personal es quien más órdenes registró.
  v_s := v_c -> 'staff' -> 0;
  if v_s ->> 'user_id' <> v_ana::text then raise exception '2. Ana debía ir primero: %', v_c -> 'staff'; end if;
  if (v_s ->> 'orders_confirmed')::int <> 2 or (v_s ->> 'orders_registered')::int <> 2 then
    raise exception '2. Ana debía llevar 2 órdenes: %', v_s;
  end if;
  if v_s ->> 'phone' <> '+584149990001' or v_s ->> 'role' <> 'cajero' or v_s ->> 'name' <> 'Ana Secretaria' then
    raise exception '2. los datos de Ana no son los esperados: %', v_s;
  end if;
  v_s := v_c -> 'staff' -> 1;
  if (v_s ->> 'orders_confirmed')::int <> 0 or v_s ->> 'last_order_at' is not null then
    raise exception '2. el gerente no registró órdenes: %', v_s;
  end if;

  -- =========================================================================
  -- 3. Validaciones
  -- =========================================================================
  v_fallo := false;
  begin
    perform public.admin_log_merchant_followup(v_m, 'paloma', 'seguimiento', 'Hola, ¿qué tal?');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó un canal desconocido'; end if;

  v_fallo := false;
  begin
    perform public.admin_log_merchant_followup(v_m, 'llamada', 'chisme', 'Hola, ¿qué tal?');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó un motivo desconocido'; end if;

  v_fallo := false;
  begin
    perform public.admin_log_merchant_followup(v_m, 'llamada', 'seguimiento', '  ok ');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó una nota vacía'; end if;

  v_fallo := false;
  begin
    perform public.admin_log_merchant_followup(v_m, 'llamada', 'seguimiento', 'Hablamos un rato', v_ajena);
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó a una persona que no es de la clínica'; end if;

  v_fallo := false;
  begin
    perform public.admin_log_merchant_followup(v_m, 'llamada', 'seguimiento', 'Hablamos un rato', null, v_hoy - 1);
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó volver a llamar ayer'; end if;

  v_fallo := false;
  begin
    perform public.admin_log_merchant_followup(gen_random_uuid(), 'llamada', 'seguimiento', 'Hablamos un rato');
  exception when sqlstate 'P0002' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó una clínica que no existe'; end if;

  -- =========================================================================
  -- 4. Anotar
  -- =========================================================================
  v_id := public.admin_log_merchant_followup(
    v_m, 'whatsapp', 'opinion', '  Dice que el bot le resulta cómodo  ', v_ana, v_hoy + 7);

  select count(*) into v_n from public.admin_merchant_followups(v_m);
  if v_n <> 1 then raise exception '4. la historia debía tener 1 contacto, tiene %', v_n; end if;
  if not exists (
    select 1 from public.admin_merchant_followups(v_m) h
     where h.id = v_id and h.note = 'Dice que el bot le resulta cómodo'
       and h.contact_name = 'Ana Secretaria' and h.actor_name = 'Admin de prueba'
       and h.next_contact_on = v_hoy + 7
  ) then
    raise exception '4. la historia no trae lo anotado';
  end if;

  v_j := public.admin_followups_board();
  select e into v_c from jsonb_array_elements(v_j) e where e ->> 'merchant_id' = v_m::text;
  if (v_c ->> 'followups_count')::int <> 1 or (v_c ->> 'next_contact_on')::date <> v_hoy + 7
     or v_c -> 'last_followup' ->> 'topic' <> 'opinion'
     or v_c -> 'last_followup' ->> 'contact_name' <> 'Ana Secretaria' then
    raise exception '4. el tablero no trae el último contacto: %', v_c;
  end if;

  reset role;
  select * into v_fila from audit.admin_actions
   where actor = v_admin and action = 'merchant.followup' and target_id = v_m
   order by created_at desc limit 1;
  if v_fila.actor is null then raise exception '4. el contacto no quedó en audit.admin_actions'; end if;
  if v_fila.detail ->> 'followup_id' <> v_id::text or v_fila.detail ->> 'channel' <> 'whatsapp' then
    raise exception '4. el detalle de la bitácora no es el esperado: %', v_fila.detail;
  end if;

  -- =========================================================================
  -- 5. La nota más nueva manda sobre «volver a llamar»
  -- =========================================================================
  -- Un instante después: dos notas de la misma transacción tendrían el mismo now().
  update public.merchant_followups set created_at = created_at - interval '1 minute' where id = v_id;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_log_merchant_followup(v_m, 'llamada', 'soporte', 'Le explicamos cómo anular una orden');

  v_j := public.admin_followups_board();
  select e into v_c from jsonb_array_elements(v_j) e where e ->> 'merchant_id' = v_m::text;
  if (v_c ->> 'followups_count')::int <> 2 or v_c ->> 'next_contact_on' is not null
     or v_c -> 'last_followup' ->> 'topic' <> 'soporte' or v_c -> 'last_followup' ->> 'contact_name' is not null then
    raise exception '5. la nota nueva sin fecha debía dejar sin «volver a llamar»: %', v_c;
  end if;
  reset role;

  -- =========================================================================
  -- 6. El uso del panel y del bot (20261026200000)
  -- =========================================================================
  set local role authenticated;
  -- Quien no es del personal de esa clínica no se anota.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_ajena::text, 'role', 'authenticated')::text, true);
  if public.helios_staff_seen_in_panel(v_m) then
    raise exception '6. anotó el panel de alguien que no es de la clínica';
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  if public.helios_staff_seen_in_panel(v_m) then
    raise exception '6. anotó el panel de un admin de Helios';
  end if;

  -- Ana abre el panel dos veces el mismo día: un solo día, dos usos.
  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  if not public.helios_staff_seen_in_panel(v_m) then raise exception '6. no anotó el panel de Ana'; end if;
  perform public.helios_staff_seen_in_panel(v_m);
  reset role;

  select count(*), max(hits) into v_n, v_usos
    from public.staff_activity_days
   where user_id = v_ana and merchant_id = v_m and channel = 'panel';
  if v_n <> 1 or v_usos <> 2 then
    raise exception '6. el panel de Ana debía ser 1 día con 2 usos: % días, % usos', v_n, v_usos;
  end if;

  -- Ana le escribe al bot; el reintento del mismo mensaje no cuenta otra vez.
  perform public.helios_whatsapp_inbound('wamid.seg-uso-1', '584149990001', 'text', '{"text":{"body":"hola"}}');
  perform public.helios_whatsapp_inbound('wamid.seg-uso-1', '584149990001', 'text', '{"text":{"body":"hola"}}');
  select count(*), max(hits) into v_n, v_usos
    from public.staff_activity_days
   where user_id = v_ana and merchant_id = v_m and channel = 'bot';
  if v_n <> 1 or v_usos <> 1 then
    raise exception '6. el bot de Ana debía ser 1 día con 1 uso: % días, % usos', v_n, v_usos;
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_followups_board();
  reset role;
  select e into v_c from jsonb_array_elements(v_j) e where e ->> 'merchant_id' = v_m::text;
  select s into v_s from jsonb_array_elements(v_c -> 'staff') s where s ->> 'user_id' = v_ana::text;
  if v_s ->> 'last_panel_at' is null or v_s ->> 'last_bot_at' is null
     or (v_s ->> 'active_days_30d')::int <> 1 then
    raise exception '6. el tablero no trae el uso de Ana: %', v_s;
  end if;
  select s into v_s from jsonb_array_elements(v_c -> 'staff') s where s ->> 'user_id' = v_gerente::text;
  if v_s ->> 'last_panel_at' is not null or v_s ->> 'last_bot_at' is not null
     or (v_s ->> 'active_days_30d')::int <> 0 then
    raise exception '6. el gerente no ha usado nada: %', v_s;
  end if;
end;
$$;

rollback;
