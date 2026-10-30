-- ============================================================================
-- Helios — El directorio de médicos (20261026190000)
--
--   bash supabase/tests/run.sh directorio_smoke
--
-- Se comprueba que:
--   1. Alguien de fuera del equipo no lee la pestaña ni cambia nada (42501).
--   2. Nadie sale sin que el equipo lo encienda; al encenderlo sale con los
--      datos de su ficha (nombre con título, especialidad presentable, la
--      clave deducida y el WhatsApp del alta).
--   3. Guardar valida (22023 / P0002) y no publica lo que no se puede
--      publicar (de prueba, pausada, sin WhatsApp).
--   4. Un dato propio manda; vacío o igual al de la ficha vuelve a la ficha.
--   5. Los clics: cuentan los públicos; el doble toque, una clínica oculta y
--      los del equipo no. La pestaña los trae por médico y por día.
--   6. Al pausar la clínica desaparece sola, y todo queda en la bitácora.
--   7. El orden reparte los clics.
--   8. La lista ampliada: cada nombre del desplegable da su clave y el texto
--      libre de antes deduce lo mismo (20261030100000).
--
-- No manda nada: no llama a `helios_dispatch_*`.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_extrano uuid := gen_random_uuid();
  v_m       uuid;
  v_otra    uuid;
  v_prueba  uuid;
  v_j       jsonb;
  v_c       jsonb;
  v_n       integer;
  v_ok      boolean;
  v_fallo   boolean;
  v_fila    record;
  v_orden   uuid[];
begin
  update public.platform_maintenance set is_active = false;

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_m := (public.admin_create_merchant('Consultorio Directorio', null, 'J-620000001', 'consultorio')).id;
  v_otra := (public.admin_create_merchant('Consultorio Sin Teléfono', null, 'J-620000002', 'consultorio')).id;
  v_prueba := (public.admin_create_merchant('Consultorio Prueba Dir', null, 'J-620000003', 'odontologia')).id;
  reset role;

  update public.merchants
     set owner_name = 'Ana Pérez', doctor_title = 'Dra.', specialty = 'TRAUMATOLOGIA Y ORTOPEDIA,',
         address = 'Av. Lara, Torre Médica', city = 'Barquisimeto', phone = '0414-999.00.10',
         social_network = 'instagram', social_user = '@draanaperez'
   where id = v_m;
  update public.merchants set phone = null, owner_name = 'Luis Gómez', doctor_title = 'Dr.' where id = v_otra;
  update public.merchants set is_test = true, phone = '+584149990011' where id = v_prueba;

  -- =========================================================================
  -- 1. Fuera del equipo
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_extrano::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_directorio();
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '1. alguien de fuera del equipo leyó la pestaña'; end if;

  v_fallo := false;
  begin
    perform public.admin_directorio_guardar(v_m, '{"visible": true}');
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '1. alguien de fuera del equipo publicó a un médico'; end if;
  reset role;

  -- =========================================================================
  -- 2. Nadie sale sin encenderlo; al encenderlo, con los datos de la ficha
  -- =========================================================================
  set local role anon;
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  if exists (select 1 from public.helios_directorio() d where d.merchant_id = v_m) then
    raise exception '2. el médico salió sin que nadie lo encendiera';
  end if;
  reset role;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_directorio_guardar(v_m, '{"visible": true}');
  reset role;

  set local role anon;
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  select * into v_fila from public.helios_directorio() d where d.merchant_id = v_m;
  reset role;
  if v_fila.merchant_id is null then raise exception '2. el médico encendido no sale'; end if;
  if v_fila.name <> 'Dra. Ana Pérez' or v_fila.specialty <> 'Traumatologia y ortopedia'
     or v_fila.specialty_key <> 'traumatologia' or v_fila.whatsapp <> '+584149990010'
     or v_fila.address <> 'Av. Lara, Torre Médica' or v_fila.city <> 'Barquisimeto'
     or v_fila.social_network <> 'instagram' or v_fila.social_user <> '@draanaperez' then
    raise exception '2. la tarjeta no trae los datos de la ficha: %', row_to_json(v_fila);
  end if;
  if (select published_at from public.directory_listings where merchant_id = v_m) is null then
    raise exception '2. no se apuntó cuándo se publicó';
  end if;

  -- =========================================================================
  -- 3. Validaciones
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  v_fallo := false;
  begin
    perform public.admin_directorio_guardar(v_m, '{"specialty_key": "astrologia"}');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó una especialidad que no existe'; end if;

  v_fallo := false;
  begin
    perform public.admin_directorio_guardar(v_m, '{"whatsapp": "12345"}');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó un WhatsApp malo'; end if;

  v_fallo := false;
  begin
    perform public.admin_directorio_guardar(v_m, '{"foto": "x"}');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó un dato desconocido'; end if;

  v_fallo := false;
  begin
    perform public.admin_directorio_guardar(v_m, '{"visible": "si"}');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó un visible que no es booleano'; end if;

  v_fallo := false;
  begin
    perform public.admin_directorio_guardar(gen_random_uuid(), '{"visible": true}');
  exception when sqlstate 'P0002' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó una clínica que no existe'; end if;

  v_fallo := false;
  begin
    perform public.admin_directorio_guardar(v_prueba, '{"visible": true}');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. publicó una clínica de prueba'; end if;

  v_fallo := false;
  begin
    perform public.admin_directorio_guardar(v_otra, '{"visible": true}');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. publicó una clínica sin WhatsApp'; end if;

  v_fallo := false;
  begin
    perform public.admin_directorio_guardar(v_m, '{"social_network": "myspace"}');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó una red social que no existe'; end if;

  -- Luis no tiene red en la ficha: un usuario sin red no vale.
  v_fallo := false;
  begin
    perform public.admin_directorio_guardar(v_otra, '{"social_user": "@drluis"}');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó un usuario de red social sin red'; end if;

  -- Con el WhatsApp que faltaba, en la misma llamada, sí.
  perform public.admin_directorio_guardar(v_otra, '{"visible": true, "whatsapp": "0424 555 66 77"}');
  reset role;
  -- Las tablas no se leen con el rol de la API: solo por las RPC.
  if (select whatsapp from public.directory_listings where merchant_id = v_otra) <> '+584245556677' then
    raise exception '3. el WhatsApp nuevo no se guardó en E.164';
  end if;

  -- =========================================================================
  -- 4. Lo propio manda; vacío o igual a la ficha vuelve a la ficha
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_directorio_guardar(v_m,
    '{"name": "  Dra.   Ana Pérez Rojas ", "specialty_key": "medicina_general", "city": ""}');
  reset role;
  select display_name, specialty_key, city into v_fila from public.directory_listings where merchant_id = v_m;
  if v_fila.display_name <> 'Dra. Ana Pérez Rojas' or v_fila.specialty_key <> 'medicina_general'
     or v_fila.city is not null then
    raise exception '4. los datos propios no se guardaron limpios: %', row_to_json(v_fila);
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_directorio_guardar(v_m, '{"name": "Dra. Ana Pérez", "specialty_key": ""}');
  reset role;
  select display_name, specialty_key into v_fila from public.directory_listings where merchant_id = v_m;
  if v_fila.display_name is not null or v_fila.specialty_key is not null then
    raise exception '4. igual a la ficha o vacío debía volver a la ficha: %', row_to_json(v_fila);
  end if;

  -- La red: propia manda; vacía, vuelve la de la ficha.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_directorio_guardar(v_m, '{"social_network": "TikTok", "social_user": " @ana.perez "}');
  reset role;
  select social_network, social_user into v_fila from public.directory_listings where merchant_id = v_m;
  if v_fila.social_network <> 'tiktok' or v_fila.social_user <> '@ana.perez' then
    raise exception '4. la red propia no se guardó limpia: %', row_to_json(v_fila);
  end if;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_directorio_guardar(v_m, '{"social_network": "", "social_user": ""}');
  reset role;
  select social_network, social_user into v_fila from public.directory_listings where merchant_id = v_m;
  if v_fila.social_network is not null or v_fila.social_user is not null then
    raise exception '4. la red vacía debía volver a la de la ficha: %', row_to_json(v_fila);
  end if;

  -- =========================================================================
  -- 5. Los clics
  -- =========================================================================
  set local role anon;
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  if not public.helios_directorio_contacto(v_m, 'visitante-0001') then
    raise exception '5. el primer clic no contó';
  end if;
  if public.helios_directorio_contacto(v_m, 'visitante-0001') then
    raise exception '5. el doble toque contó';
  end if;
  if not public.helios_directorio_contacto(v_m, 'visitante-0002') then
    raise exception '5. el clic de otra persona no contó';
  end if;
  -- Un identificador raro no se guarda, pero el clic cuenta.
  if not public.helios_directorio_contacto(v_m, '<script>') then
    raise exception '5. un clic con un identificador raro no contó';
  end if;
  if public.helios_directorio_contacto(v_prueba, 'visitante-0003') then
    raise exception '5. contó un clic a una clínica que no está publicada';
  end if;
  reset role;

  -- El del equipo se guarda, pero no cuenta.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.helios_directorio_contacto(v_m, 'visitante-admin');
  v_j := public.admin_directorio();
  reset role;

  select count(*) into v_n from public.directory_contact_clicks where merchant_id = v_m;
  if v_n <> 4 then raise exception '5. debía haber 4 clics guardados, hay %', v_n; end if;
  if (select count(*) from public.directory_contact_clicks where merchant_id = v_m and origin = 'equipo') <> 1 then
    raise exception '5. el clic del equipo no quedó marcado como del equipo';
  end if;

  -- El del equipo no cuenta, pero la pestaña dice que lo hubo.
  if (v_j -> 'totales' ->> 'clics_internos_30d')::int < 1 or v_j -> 'totales' ->> 'ultimo_interno' is null then
    raise exception '5. la pestaña no dice cuántos clics del equipo dejó fuera: %', v_j -> 'totales';
  end if;

  select e into v_c from jsonb_array_elements(v_j -> 'medicos') e where e ->> 'merchant_id' = v_m::text;
  if v_c is null then raise exception '5. el médico no sale en la pestaña'; end if;
  if (v_c -> 'clics' ->> 'd30')::int <> 3 or (v_c -> 'clics' ->> 'd7')::int <> 3
     or (v_c -> 'clics' ->> 'total')::int <> 3 or (v_c -> 'clics' ->> 'visitantes_30d')::int <> 2 then
    raise exception '5. los clics del médico no cuadran: %', v_c -> 'clics';
  end if;
  if jsonb_array_length(v_c -> 'clics' -> 'por_dia') <> 30
     or (v_c -> 'clics' -> 'por_dia' ->> 29)::int <> 3 then
    raise exception '5. el día a día del médico no cuadra: %', v_c -> 'clics' -> 'por_dia';
  end if;
  if jsonb_array_length(v_j -> 'por_dia') <> 30 or (v_j -> 'por_dia' -> 29 ->> 'clics')::int < 3 then
    raise exception '5. el día a día del directorio no cuadra: %', v_j -> 'por_dia' -> 29;
  end if;
  if v_c -> 'listing' ->> 'name' <> 'Dra. Ana Pérez' or v_c -> 'base' ->> 'specialty_key' <> 'traumatologia'
     or (v_c ->> 'is_visible')::boolean is not true or v_c ->> 'blocked_reason' is not null then
    raise exception '5. la pestaña no trae la tarjeta y la ficha: %', v_c;
  end if;

  select e into v_c from jsonb_array_elements(v_j -> 'medicos') e where e ->> 'merchant_id' = v_prueba::text;
  if v_c ->> 'blocked_reason' <> 'prueba' then
    raise exception '5. la clínica de prueba debía salir bloqueada: %', v_c;
  end if;

  -- =========================================================================
  -- 6. Pausada, desaparece sola; y la bitácora
  -- =========================================================================
  update public.merchants set status = 'paused' where id = v_m;

  set local role anon;
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  if exists (select 1 from public.helios_directorio() d where d.merchant_id = v_m) then
    raise exception '6. una clínica pausada sigue saliendo';
  end if;
  v_ok := public.helios_directorio_contacto(v_m, 'visitante-0009');
  reset role;
  if v_ok then raise exception '6. contó un clic a una clínica pausada'; end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_directorio_guardar(v_m, '{"visible": true, "city": "Caracas"}');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '6. volvió a publicar una clínica pausada'; end if;
  -- Ocultarla sí se puede.
  perform public.admin_directorio_guardar(v_m, '{"visible": false}');
  reset role;

  select count(*) into v_n from audit.admin_actions
   where action = 'directory.listing.update' and target_id = v_m and actor = v_admin;
  if v_n <> 6 then raise exception '6. debía haber 6 líneas en la bitácora, hay %', v_n; end if;
  if not exists (
    select 1 from audit.admin_actions
     where action = 'directory.listing.update' and target_id = v_m
       and detail -> 'cambios' ->> 'visible' = 'false'
       and (detail -> 'antes' ->> 'is_visible')::boolean
       and not (detail -> 'despues' ->> 'is_visible')::boolean
  ) then
    raise exception '6. la bitácora no dice qué cambió';
  end if;

  -- =========================================================================
  -- 7. El orden reparte los clics (20261029100000)
  -- =========================================================================
  -- Luis (publicado en el paso 3) no tiene clics públicos; otro médico
  -- publicado, 30 esta semana. Luis tiene que salir por encima casi siempre
  -- (31 de cada 32 veces): en 200 sorteos, al menos 150. Los 100 clics del
  -- equipo que se le dan a Luis no cuentan.
  delete from public.directory_contact_clicks where created_at > now() - interval '7 days';
  select d.merchant_id into v_prueba from public.helios_directorio() d where d.merchant_id <> v_otra limit 1;
  insert into public.directory_contact_clicks (merchant_id, visitor_id, origin)
  select v_prueba, 'orden-clic-' || g, 'publico' from generate_series(1, 30) g;
  insert into public.directory_contact_clicks (merchant_id, visitor_id, origin)
  select v_otra, 'orden-equipo-' || g, 'equipo' from generate_series(1, 100) g;

  -- Un solo sorteo por vuelta: cada llamada ordena distinto.
  v_n := 0;
  for v_ok in select true from generate_series(1, 200) loop
    select array_agg(d.merchant_id) into v_orden from public.helios_directorio() d;
    if array_position(v_orden, v_otra) < array_position(v_orden, v_prueba) then
      v_n := v_n + 1;
    end if;
  end loop;
  if v_n < 150 then
    raise exception '7. el médico sin clics debía salir por encima casi siempre: % de 200', v_n;
  end if;

  -- =========================================================================
  -- 8. La lista ampliada (20261030100000)
  -- =========================================================================
  -- El desplegable de `/afiliacion` guarda el nombre tal cual de la lista:
  -- cada nombre tiene que dar su clave, y no la de una parecida.
  if cardinality(public.helios_directorio_especialidades()) <> 43 then
    raise exception '8. debían ser 43 claves, son %', cardinality(public.helios_directorio_especialidades());
  end if;
  if public.helios_directorio_especialidad_sugerida('Cirugía general') <> 'cirugia_general'
     or public.helios_directorio_especialidad_sugerida('Cirugía pediátrica') <> 'cirugia_pediatrica'
     or public.helios_directorio_especialidad_sugerida('Cirugía cardíaca') <> 'cirugia_cardiaca'
     or public.helios_directorio_especialidad_sugerida('Neurocirugía') <> 'neurocirugia'
     or public.helios_directorio_especialidad_sugerida('Psiquiatría') <> 'psiquiatria'
     or public.helios_directorio_especialidad_sugerida('Psicología') <> 'psicologia'
     or public.helios_directorio_especialidad_sugerida('Ortodoncia') <> 'ortodoncia'
     or public.helios_directorio_especialidad_sugerida('Radiodiagnóstico (imágenes)') <> 'radiologia'
     or public.helios_directorio_especialidad_sugerida('Angiología y cirugía vascular') <> 'angiologia'
     or public.helios_directorio_especialidad_sugerida('Traumatología y ortopedia') <> 'traumatologia' then
    raise exception '8. un nombre de la lista no dio su clave';
  end if;
  -- El texto libre de antes sigue deduciendo lo mismo.
  if public.helios_directorio_especialidad_sugerida('Traumotología, cirugía cadera, rodilla y pelvis') <> 'traumatologia'
     or public.helios_directorio_especialidad_sugerida('Medico internista y gastroenterologo') <> 'gastroenterologia'
     or public.helios_directorio_especialidad_sugerida('Obstetricia, Ginecólogo Oncologo') <> 'ginecologia'
     or public.helios_directorio_especialidad_sugerida('Pediatría, vacunación') <> 'pediatria'
     or public.helios_directorio_especialidad_sugerida('Cardiologo/Neumonologo adultos') <> 'cardiologia'
     or public.helios_directorio_especialidad_sugerida('') <> 'medicina_general' then
    raise exception '8. el texto libre de siempre cambió de clave';
  end if;
end;
$$;

rollback;
