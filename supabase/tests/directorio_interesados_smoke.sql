-- ============================================================================
-- Helios — El directorio pasa por el WhatsApp de Helios (20261027100000)
--
--   bash supabase/tests/run.sh directorio_interesados_smoke
--
-- Se comprueba que:
--   1. Permisos: solo el webhook (service_role) llama a
--      `bot_directorio_interesado`; nadie de la API lee `directory_leads`; la
--      lista de interesados es solo del equipo (42501).
--   2. Cada tarjeta tiene su código DIR-XXXX, la página lo lee con el número
--      de Helios, y editar la tarjeta no lo cambia.
--   3. El bot: un código desconocido o una tarjeta que no sale no guardan
--      nada; el primer mensaje crea el interesado con los datos de la
--      tarjeta; el segundo del mismo teléfono suma; un reintento del mismo
--      wamid no; un teléfono malo es 22023.
--   4. La conversión: solo una orden confirmada, no de prueba, de ESE médico,
--      creada en o después del primer mensaje, de un paciente con ese
--      teléfono.
--   5. `admin_directorio()` trae los totales y los interesados de cada
--      médico sin perder lo de antes; `admin_directorio_interesados()` los
--      lista con su paciente y su orden.
--
-- No manda nada: no llama a `helios_dispatch_*` (las órdenes se crean con
-- `pg_temp.prueba_cobro`, que no despacha).
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_extrano uuid := gen_random_uuid();
  v_staff   uuid := gen_random_uuid();
  v_pac     uuid := gen_random_uuid();
  v_tel     text := '+584140009711';
  v_m       uuid;
  v_otra    uuid;
  v_tercera uuid;
  v_oculta  uuid;
  v_branch  uuid;
  v_cod     text;
  v_cod_oc  text;
  v_cod_ot  text;
  v_n       integer;
  v_r       jsonb;
  v_j       jsonb;
  v_c       jsonb;
  v_uno     jsonb;
  v_lead    uuid;
  v_vieja   uuid;
  v_prueba  uuid;
  v_buena   uuid;
  v_fila    record;
  v_fallo   boolean;
begin
  update public.platform_maintenance set is_active = false;
  update public.levels set monthly_limit_usd = 500 where level = 1;
  -- `_ayudas.sql` deja el contacto vacío: la prueba pone su número.
  update public.platform_contact set whatsapp_number = '+584120009700' where id;

  v_admin := pg_temp.prueba_admin();
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  values (v_staff, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'u-' || v_staff || '@prueba.helios.test', now(), now(), now());

  insert into public.merchants (name, owner_name, doctor_title, specialty, address, city, phone)
  values ('Consultorio Interesados', 'Ana Pérez', 'Dra.', 'Traumatología', 'Av. Lara, Torre Médica',
          'Barquisimeto', '0414-999.00.20')
  returning id into v_m;
  insert into public.merchants (name, owner_name, doctor_title, phone)
  values ('Consultorio Otra', 'Luis Gómez', 'Dr.', '0414-999.00.21') returning id into v_otra;
  insert into public.merchants (name, owner_name, doctor_title, phone)
  values ('Consultorio Tercera', 'Rosa Díaz', 'Dra.', '0414-999.00.22') returning id into v_tercera;
  insert into public.merchants (name, owner_name, doctor_title, phone)
  values ('Consultorio Oculto', 'Pedro Ruiz', 'Dr.', '0414-999.00.23') returning id into v_oculta;

  insert into public.directory_listings (merchant_id, is_visible, published_at)
  values (v_m, true, now()), (v_otra, true, now()), (v_oculta, false, null);

  -- =========================================================================
  -- 1. Permisos
  -- =========================================================================
  if has_function_privilege('anon', 'public.bot_directorio_interesado(text, text, text)', 'execute')
     or has_function_privilege('authenticated', 'public.bot_directorio_interesado(text, text, text)', 'execute')
     or not has_function_privilege('service_role', 'public.bot_directorio_interesado(text, text, text)', 'execute') then
    raise exception '1. bot_directorio_interesado debía ser solo de service_role';
  end if;
  if has_table_privilege('anon', 'public.directory_leads', 'select')
     or has_table_privilege('authenticated', 'public.directory_leads', 'select')
     or has_table_privilege('authenticated', 'public.directory_leads', 'insert') then
    raise exception '1. la API no debía tocar directory_leads';
  end if;
  if not has_function_privilege('anon', 'public.helios_directorio_whatsapp()', 'execute')
     or not has_function_privilege('authenticated', 'public.helios_directorio_whatsapp()', 'execute') then
    raise exception '1. helios_directorio_whatsapp debía ser pública';
  end if;
  if has_function_privilege('anon', 'public.admin_directorio_interesados(uuid, integer)', 'execute') then
    raise exception '1. anon no debía llamar a admin_directorio_interesados';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_extrano::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.bot_directorio_interesado('584140009711', 'DIR-2345', 'wamid.x');
  exception when insufficient_privilege then v_fallo := true;
  end;
  if not v_fallo then raise exception '1. alguien con sesión llamó al bot del directorio'; end if;

  v_fallo := false;
  begin
    perform count(*) from public.directory_leads;
  exception when insufficient_privilege then v_fallo := true;
  end;
  if not v_fallo then raise exception '1. alguien con sesión leyó los interesados'; end if;

  v_fallo := false;
  begin
    perform public.admin_directorio_interesados();
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '1. alguien de fuera del equipo leyó la lista de interesados'; end if;
  reset role;

  set local role anon;
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  v_fallo := false;
  begin
    perform public.bot_directorio_interesado('584140009711', 'DIR-2345', 'wamid.x');
  exception when insufficient_privilege then v_fallo := true;
  end;
  reset role;
  if not v_fallo then raise exception '1. anon llamó al bot del directorio'; end if;

  -- =========================================================================
  -- 2. El código de cada tarjeta
  -- =========================================================================
  select lead_code into v_cod from public.directory_listings where merchant_id = v_m;
  select lead_code into v_cod_ot from public.directory_listings where merchant_id = v_otra;
  select lead_code into v_cod_oc from public.directory_listings where merchant_id = v_oculta;
  if v_cod !~ '^DIR-[2-9A-HJKMNP-Z]{4}$' or v_cod_ot !~ '^DIR-[2-9A-HJKMNP-Z]{4}$'
     or v_cod_oc !~ '^DIR-[2-9A-HJKMNP-Z]{4}$' then
    raise exception '2. un código no tiene la forma DIR-XXXX: %, %, %', v_cod, v_cod_ot, v_cod_oc;
  end if;
  if v_cod = v_cod_ot or v_cod = v_cod_oc or v_cod_ot = v_cod_oc then
    raise exception '2. dos tarjetas con el mismo código';
  end if;
  if exists (select 1 from public.directory_listings where lead_code is null) then
    raise exception '2. quedó una tarjeta sin código';
  end if;

  set local role anon;
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  select * into v_fila from public.helios_directorio() d where d.merchant_id = v_m;
  if v_fila.lead_code is distinct from v_cod then
    reset role;
    raise exception '2. la página no trae el código de la tarjeta: %', row_to_json(v_fila);
  end if;
  if exists (select 1 from public.helios_directorio() d where d.merchant_id = v_oculta) then
    reset role;
    raise exception '2. salió una tarjeta oculta';
  end if;
  if public.helios_directorio_whatsapp() is distinct from '+584120009700' then
    reset role;
    raise exception '2. la página no lee el número de Helios: %', public.helios_directorio_whatsapp();
  end if;
  reset role;

  -- Editar la tarjeta no cambia el código.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_directorio_guardar(v_m, '{"city": "Cabudare", "name": "Dra. Ana Pérez Rojas"}');
  perform public.admin_directorio_guardar(v_m, '{"city": "", "name": ""}');
  -- Una tarjeta nueva desde la pestaña nace con su código.
  perform public.admin_directorio_guardar(v_tercera, '{"visible": false}');
  reset role;
  if (select lead_code from public.directory_listings where merchant_id = v_m) <> v_cod then
    raise exception '2. editar la tarjeta le cambió el código';
  end if;
  if (select lead_code from public.directory_listings where merchant_id = v_tercera) !~ '^DIR-[2-9A-HJKMNP-Z]{4}$' then
    raise exception '2. la tarjeta creada desde la pestaña no tiene código';
  end if;

  -- =========================================================================
  -- 3. El bot (como el webhook)
  -- =========================================================================
  select count(*) into v_n from public.directory_leads;

  set local role service_role;
  -- 0 no está en el alfabeto: nunca es de nadie.
  v_r := public.bot_directorio_interesado('584140009711', 'DIR-0000', 'wamid.dir.0');
  if v_r <> '{"ok": false, "motivo": "codigo_desconocido"}'::jsonb then
    reset role;
    raise exception '3. un código desconocido debía dar codigo_desconocido: %', v_r;
  end if;
  v_r := public.bot_directorio_interesado('584140009711', v_cod_oc, 'wamid.dir.1');
  if v_r <> '{"ok": false, "motivo": "no_publicado"}'::jsonb then
    reset role;
    raise exception '3. una tarjeta oculta debía dar no_publicado: %', v_r;
  end if;
  v_fallo := false;
  begin
    perform public.bot_directorio_interesado('no es un teléfono', v_cod, 'wamid.dir.2');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then reset role; raise exception '3. aceptó un teléfono malo'; end if;
  reset role;
  if (select count(*) from public.directory_leads) <> v_n then
    raise exception '3. un mensaje sin tarjeta publicada guardó un interesado';
  end if;

  -- El primero: en minúsculas y con espacios, como lo escribiría alguien.
  set local role service_role;
  v_r := public.bot_directorio_interesado('584140009711', '  ' || lower(v_cod) || ' ', 'wamid.dir.3');
  reset role;
  if not (v_r ->> 'ok')::boolean or not (v_r ->> 'nuevo')::boolean or (v_r ->> 'messages')::int <> 1
     or v_r ->> 'merchant_id' <> v_m::text or v_r ->> 'lead_id' is null
     or v_r ->> 'name' <> 'Dra. Ana Pérez' or v_r ->> 'specialty' <> 'Traumatología'
     or v_r ->> 'address' <> 'Av. Lara, Torre Médica' or v_r ->> 'city' <> 'Barquisimeto'
     or v_r ->> 'whatsapp' <> '+584149990020' then
    raise exception '3. el primer mensaje no devolvió la tarjeta: %', v_r;
  end if;
  v_lead := (v_r ->> 'lead_id')::uuid;
  select * into v_fila from public.directory_leads where id = v_lead;
  if v_fila.phone_e164 <> v_tel or v_fila.first_message_id <> 'wamid.dir.3' or v_fila.messages <> 1
     or v_fila.merchant_id <> v_m then
    raise exception '3. el interesado no se guardó bien: %', row_to_json(v_fila);
  end if;

  -- El mismo wamid otra vez (un reintento) no suma.
  set local role service_role;
  v_r := public.bot_directorio_interesado('+58 414 000 9711', v_cod, 'wamid.dir.3');
  reset role;
  if (v_r ->> 'nuevo')::boolean or (v_r ->> 'messages')::int <> 1 or (v_r ->> 'lead_id')::uuid <> v_lead then
    raise exception '3. un reintento del mismo mensaje sumó: %', v_r;
  end if;

  -- El segundo mensaje del mismo teléfono.
  set local role service_role;
  v_r := public.bot_directorio_interesado('584140009711', v_cod, 'wamid.dir.4');
  reset role;
  if (v_r ->> 'nuevo')::boolean or (v_r ->> 'messages')::int <> 2 or (v_r ->> 'lead_id')::uuid <> v_lead then
    raise exception '3. el segundo mensaje no sumó al mismo interesado: %', v_r;
  end if;
  if (select messages from public.directory_leads where id = v_lead) <> 2 then
    raise exception '3. la tabla no dice 2 mensajes';
  end if;

  -- El mismo teléfono con otro médico es otro interesado.
  set local role service_role;
  v_r := public.bot_directorio_interesado('584140009711', v_cod_ot, 'wamid.dir.5');
  reset role;
  if not (v_r ->> 'nuevo')::boolean or v_r ->> 'merchant_id' <> v_otra::text then
    raise exception '3. el mismo teléfono con otro médico debía ser otro interesado: %', v_r;
  end if;
  if (select count(*) from public.directory_leads) <> v_n + 2 then
    raise exception '3. debía haber 2 interesados nuevos';
  end if;

  -- =========================================================================
  -- 4. La conversión
  -- =========================================================================
  insert into public.profiles (id, phone_e164, first_name, full_name)
  values (v_pac, v_tel, 'Carla', 'Carla Interesada');

  -- Una orden de otra clínica no cuenta.
  select id into v_branch from public.merchant_branches where merchant_id = v_tercera and is_default;
  perform pg_temp.prueba_cobro(v_pac, v_tercera, v_branch, v_staff, 28.00, 'dir-int-tercera');

  select id into v_branch from public.merchant_branches where merchant_id = v_m and is_default;
  -- Una de antes del primer mensaje tampoco.
  v_vieja := (pg_temp.prueba_cobro(v_pac, v_m, v_branch, v_staff, 28.00, 'dir-int-vieja')->>'charge_id')::uuid;
  update public.charges set created_at = now() - interval '1 day' where id = v_vieja;
  -- Ni una de prueba.
  v_prueba := (pg_temp.prueba_cobro(v_pac, v_m, v_branch, v_staff, 28.00, 'dir-int-prueba')->>'charge_id')::uuid;
  update public.charges set is_test = true where id = v_prueba;

  if exists (select 1 from public.helios_directorio_conversion(v_m, v_tel, (select first_at from public.directory_leads where id = v_lead))) then
    raise exception '4. contó como convertido sin una orden válida';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_directorio_interesados(v_m);
  reset role;
  if jsonb_array_length(v_j) <> 1 or v_j -> 0 ->> 'lead_id' <> v_lead::text
     or v_j -> 0 -> 'conversion' <> 'null'::jsonb then
    raise exception '4. el interesado no debía estar convertido: %', v_j;
  end if;
  -- Sin orden que lo convierta, el paciente es el perfil de ese teléfono.
  if v_j -> 0 -> 'paciente' ->> 'profile_id' is null then
    raise exception '4. no encontró el perfil con ese teléfono: %', v_j -> 0;
  end if;

  -- Ahora sí: confirmada, de ese médico, después del primer mensaje.
  v_buena := (pg_temp.prueba_cobro(v_pac, v_m, v_branch, v_staff, 28.00, 'dir-int-buena')->>'charge_id')::uuid;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_directorio_interesados(v_m);
  reset role;
  v_c := v_j -> 0;
  if v_c -> 'conversion' ->> 'charge_id' is distinct from v_buena::text
     or (v_c -> 'conversion' ->> 'order_number')::bigint
        <> (select order_number from public.charges where id = v_buena)
     or v_c -> 'conversion' ->> 'created_at' is null then
    raise exception '4. la orden buena no lo convirtió: %', v_c;
  end if;
  if v_c -> 'paciente' ->> 'profile_id' <> v_pac::text or v_c -> 'paciente' ->> 'nombre' <> 'Carla Interesada' then
    raise exception '4. el paciente no es el de la orden: %', v_c -> 'paciente';
  end if;
  if v_c ->> 'medico' <> 'Dra. Ana Pérez' or v_c ->> 'phone' <> v_tel or (v_c ->> 'messages')::int <> 2
     or v_c ->> 'first_at' is null or v_c ->> 'last_at' is null or v_c ->> 'merchant_id' <> v_m::text then
    raise exception '4. la fila del interesado no trae sus datos: %', v_c;
  end if;

  -- =========================================================================
  -- 5. La pestaña
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_directorio();
  v_r := public.admin_directorio_interesados();
  v_uno := public.admin_directorio_interesados(null, 1);
  reset role;

  -- Lo de antes sigue ahí.
  if not (v_j -> 'totales' ?& array['clics_total', 'clics_7d', 'clics_30d', 'clics_30d_anteriores',
                                     'visitantes_30d', 'medicos_contactados_30d', 'clics_internos_30d',
                                     'ultimo_interno'])
     or jsonb_array_length(v_j -> 'por_dia') <> 30 then
    raise exception '5. la pestaña perdió cifras de antes: %', v_j -> 'totales';
  end if;
  if (v_j -> 'totales' ->> 'interesados_total')::int < 2 or (v_j -> 'totales' ->> 'interesados_30d')::int < 2
     or (v_j -> 'totales' ->> 'convertidos_total')::int < 1 or (v_j -> 'totales' ->> 'convertidos_30d')::int < 1 then
    raise exception '5. los totales de interesados no cuadran: %', v_j -> 'totales';
  end if;

  select e into v_c from jsonb_array_elements(v_j -> 'medicos') e where e ->> 'merchant_id' = v_m::text;
  if v_c is null or not (v_c ?& array['clics', 'listing', 'base', 'blocked_reason', 'interesados']) then
    raise exception '5. el médico no sale entero en la pestaña: %', v_c;
  end if;
  if (v_c -> 'interesados' ->> 'total')::int <> 1 or (v_c -> 'interesados' ->> 'd30')::int <> 1
     or (v_c -> 'interesados' ->> 'convertidos')::int <> 1 or v_c -> 'interesados' ->> 'ultimo' is null then
    raise exception '5. los interesados del médico no cuadran: %', v_c -> 'interesados';
  end if;
  select e into v_c from jsonb_array_elements(v_j -> 'medicos') e where e ->> 'merchant_id' = v_otra::text;
  if (v_c -> 'interesados' ->> 'total')::int <> 1 or (v_c -> 'interesados' ->> 'convertidos')::int <> 0 then
    raise exception '5. una orden con otra clínica convirtió al interesado de Luis: %', v_c -> 'interesados';
  end if;
  select e into v_c from jsonb_array_elements(v_j -> 'medicos') e where e ->> 'merchant_id' = v_oculta::text;
  if (v_c -> 'interesados' ->> 'total')::int <> 0 or v_c -> 'interesados' -> 'ultimo' <> 'null'::jsonb then
    raise exception '5. un médico sin interesados debía salir en cero: %', v_c -> 'interesados';
  end if;

  -- La lista entera trae a los dos; con límite 1, uno.
  if (select count(*) from jsonb_array_elements(v_r) e where e ->> 'merchant_id' in (v_m::text, v_otra::text)) <> 2 then
    raise exception '5. la lista de interesados no trae a los dos';
  end if;
  if jsonb_array_length(v_uno) <> 1 then
    raise exception '5. con límite 1 debía traer uno: %', jsonb_array_length(v_uno);
  end if;
end;
$$;

rollback;
