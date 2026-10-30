-- ============================================================================
-- Helios — Las fichas del directorio y el origen de los clics (20261030120000)
--
--   bash supabase/tests/run.sh directorio_fichas_smoke
--
-- Se comprueba que:
--   1. Al publicarse, cada médico recibe su enlace («dra-zoe-ficha»); con el
--      mismo nombre, el segundo lleva «-2». Cambiar el nombre no lo cambia.
--   2. `helios_directorio()` trae el enlace y `helios_directorio_medico`
--      encuentra al médico por él; oculto, ya no.
--   3. El clic guarda el origen de la visita y descarta lo malformado.
--   4. Los orígenes solo los lee el equipo, y cuentan solo los públicos.
--
-- No manda nada: no llama a `helios_dispatch_*`.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_extrano uuid := gen_random_uuid();
  v_a       uuid;
  v_b       uuid;
  v_slug_a  text;
  v_slug_b  text;
  v_fila    record;
  v_j       jsonb;
  v_fallo   boolean;
begin
  update public.platform_maintenance set is_active = false;

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_a := (public.admin_create_merchant('Consultorio Ficha A', null, 'J-630000001', 'consultorio')).id;
  v_b := (public.admin_create_merchant('Consultorio Ficha B', null, 'J-630000002', 'consultorio')).id;
  reset role;

  update public.merchants
     set owner_name = 'Zoé Fícha Prueba', doctor_title = 'Dra.', specialty = 'Odontología',
         phone = '0414-999.30.01', city = 'Caracas'
   where id in (v_a, v_b);
  update public.merchants set phone = '0414-999.30.02' where id = v_b;

  -- =========================================================================
  -- 1. El enlace nace al publicarse y no cambia
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_directorio_guardar(v_a, '{"visible": false}');
  reset role;
  if (select slug from public.directory_listings where merchant_id = v_a) is not null then
    raise exception '1. un médico sin publicar ya tiene enlace';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_directorio_guardar(v_a, '{"visible": true}');
  perform public.admin_directorio_guardar(v_b, '{"visible": true}');
  reset role;

  select slug into v_slug_a from public.directory_listings where merchant_id = v_a;
  select slug into v_slug_b from public.directory_listings where merchant_id = v_b;
  if v_slug_a is distinct from 'dra-zoe-ficha-prueba' then
    raise exception '1. el enlace no sale del nombre sin tildes: %', v_slug_a;
  end if;
  if v_slug_b is distinct from 'dra-zoe-ficha-prueba-2' then
    raise exception '1. el segundo con el mismo nombre no lleva «-2»: %', v_slug_b;
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_directorio_guardar(v_a, '{"name": "Dra. Zoé Otro Nombre", "visible": false}');
  perform public.admin_directorio_guardar(v_a, '{"visible": true}');
  reset role;
  if (select slug from public.directory_listings where merchant_id = v_a) is distinct from v_slug_a then
    raise exception '1. cambiar el nombre o despublicar cambió el enlace';
  end if;

  if public.helios_directorio_slug_base('Lcda. María-José  Núñez (Ñ)') <> 'lcda-maria-jose-nunez-n' then
    raise exception '1. la base del enlace: %', public.helios_directorio_slug_base('Lcda. María-José  Núñez (Ñ)');
  end if;

  -- =========================================================================
  -- 2. La lista trae el enlace y la ficha se encuentra por él
  -- =========================================================================
  set local role anon;
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  select * into v_fila from public.helios_directorio() d where d.merchant_id = v_a;
  if v_fila.slug is distinct from v_slug_a or v_fila.updated_at is null then
    raise exception '2. la lista no trae el enlace ni la fecha: %', row_to_json(v_fila);
  end if;
  select * into v_fila from public.helios_directorio_medico(upper(v_slug_b) || ' ');
  if v_fila.merchant_id is distinct from v_b then
    raise exception '2. la ficha no se encuentra por su enlace';
  end if;
  if exists (select 1 from public.helios_directorio_medico('no-existe-este-medico')) then
    raise exception '2. un enlace desconocido devolvió un médico';
  end if;
  reset role;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_directorio_guardar(v_b, '{"visible": false}');
  reset role;
  set local role anon;
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  if exists (select 1 from public.helios_directorio_medico(v_slug_b)) then
    raise exception '2. la ficha de un médico oculto sigue saliendo';
  end if;
  reset role;

  -- =========================================================================
  -- 3. El clic guarda el origen y descarta lo malformado
  -- =========================================================================
  set local role anon;
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  if not public.helios_directorio_contacto(v_a, 'visitante-ficha-1', jsonb_build_object(
    'fuente', 'google', 'dominio', 'www.google.com', 'entrada', '/directorio/odontologia',
    'pagina', '/medico/' || v_slug_a, 'utm_source', 'boletin', 'utm_medium', 'email',
    'utm_campaign', 'octubre'
  )) then
    raise exception '3. el clic con origen no contó';
  end if;
  if not public.helios_directorio_contacto(v_a, 'visitante-ficha-2', jsonb_build_object(
    'fuente', 'Google<script>', 'dominio', 'evil host', 'entrada', 'http://fuera.com', 'pagina', 42
  )) then
    raise exception '3. un origen malformado rechazó el clic (solo se descarta el dato)';
  end if;
  if not public.helios_directorio_contacto(v_a, 'visitante-ficha-3') then
    raise exception '3. el clic sin origen (dos argumentos) dejó de contar';
  end if;
  reset role;

  select * into v_fila from public.directory_contact_clicks
   where merchant_id = v_a and visitor_id = 'visitante-ficha-1';
  if v_fila.source <> 'google' or v_fila.referrer_host <> 'www.google.com'
     or v_fila.landing_path <> '/directorio/odontologia' or v_fila.page_path <> '/medico/' || v_slug_a
     or v_fila.utm_source <> 'boletin' or v_fila.utm_medium <> 'email' or v_fila.utm_campaign <> 'octubre' then
    raise exception '3. el origen no se guardó tal cual: %', row_to_json(v_fila);
  end if;
  select * into v_fila from public.directory_contact_clicks
   where merchant_id = v_a and visitor_id = 'visitante-ficha-2';
  if v_fila.source is not null or v_fila.referrer_host is not null
     or v_fila.landing_path is not null or v_fila.page_path is not null then
    raise exception '3. se guardó un origen malformado: %', row_to_json(v_fila);
  end if;

  -- =========================================================================
  -- 4. Los orígenes: solo el equipo, solo los públicos
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_extrano::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_directorio_origenes(30);
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '4. alguien de fuera del equipo leyó los orígenes'; end if;
  reset role;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  -- Un clic del equipo: no cuenta.
  perform public.helios_directorio_contacto(v_a, 'visitante-ficha-4', '{"fuente": "google"}');
  v_j := public.admin_directorio_origenes(1);
  reset role;

  if not exists (
    select 1 from jsonb_array_elements(v_j -> 'por_fuente') e
     where e ->> 'fuente' = 'google' and (e ->> 'clics')::int >= 1
  ) then
    raise exception '4. los orígenes no traen el clic de google: %', v_j;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_j -> 'por_entrada') e
     where e ->> 'pagina' = '/directorio/odontologia'
  ) then
    raise exception '4. los orígenes no traen la página de entrada: %', v_j;
  end if;
  if (select count(*) from public.directory_contact_clicks
       where merchant_id = v_a and origin = 'equipo') <> 1 then
    raise exception '4. el clic del equipo no se apuntó como del equipo';
  end if;
end;
$$;

rollback;
