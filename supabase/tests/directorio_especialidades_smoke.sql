-- ============================================================================
-- Helios — Un médico en varias especialidades del directorio (20261110120000)
--
--   bash supabase/tests/run.sh directorio_especialidades_smoke
--
-- Se comprueba que:
--   1. `admin_directorio_guardar` guarda las otras especialidades sin
--      repetir y sin la principal, y rechaza «otra», las desconocidas, más
--      de tres y lo que no sea una lista.
--   2. `helios_directorio()`, `helios_directorio_medico()` y
--      `helios_directorio_consultas()` las traen; la de consultas sigue en su
--      orden (la columna nueva no se come el `with ordinality`).
--   3. Si la principal pasa a ser una de las otras, no sale dos veces.
--   4. `admin_directorio()` las enseña en la tarjeta y la ficha no tiene.
--   5. Una lista vacía las quita.
--   6. El capacitador las lee y las guarda desde el perfil
--      (`admin_medico_especialidades[_guardar]`, 20261125100000), limpias y
--      con las mismas reglas; a un médico sin tarjeta se la crea oculta. No
--      publica tarjetas; el operador y un anónimo, nada.
--
-- No manda nada: no llama a `helios_dispatch_*`.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin uuid;
  v_cap   uuid := gen_random_uuid();
  v_op    uuid := gen_random_uuid();
  v_m2    uuid;
  v_m     uuid;
  v_slug  text;
  v_otras text[];
  v_j     jsonb;
  v_fallo boolean;
  v_mal   text;
  v_entra boolean;
begin
  update public.platform_maintenance set is_active = false;

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_m := (public.admin_create_merchant('Consultorio Dos Especialidades', null, 'J-640000001', 'consultorio')).id;
  reset role;

  update public.merchants
     set owner_name = 'Saúl Prueba Doble', doctor_title = 'Dr.', specialty = 'Psiquiatría',
         phone = '0414-999.40.01', city = 'Caracas'
   where id = v_m;

  -- =========================================================================
  -- 1. Se guardan limpias; lo malo se rechaza
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_directorio_guardar(v_m,
    '{"visible": true, "consultation_price_cur": "40",
      "other_specialty_keys": ["medicina_interna", "psiquiatria", "medicina_interna", "gastroenterologia"]}');

  foreach v_mal in array array[
    '{"other_specialty_keys": ["otra"]}',
    '{"other_specialty_keys": ["astrologia"]}',
    '{"other_specialty_keys": ["cardiologia", "neumologia", "nefrologia", "urologia"]}',
    '{"other_specialty_keys": "medicina_interna"}'
  ] loop
    v_fallo := false;
    begin
      perform public.admin_directorio_guardar(v_m, v_mal::jsonb);
    exception when sqlstate '22023' then v_fallo := true;
    end;
    if not v_fallo then raise exception '1. se aceptó %', v_mal; end if;
  end loop;
  reset role;

  select other_specialty_keys, slug into v_otras, v_slug from public.directory_listings where merchant_id = v_m;
  if v_otras is distinct from array['medicina_interna', 'gastroenterologia'] then
    raise exception '1. no se guardaron limpias (sin repetir, sin la principal, en su orden): %', v_otras;
  end if;

  -- =========================================================================
  -- 2. Las lecturas públicas las traen
  -- =========================================================================
  -- Con la configuración de hoy, ¿una consulta de $40 entra en /consultas?
  v_entra := public.helios_consultas_entra(40);

  set local role anon;
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  select d.other_specialty_keys into v_otras from public.helios_directorio() d where d.merchant_id = v_m;
  if v_otras is distinct from array['medicina_interna', 'gastroenterologia'] then
    raise exception '2. helios_directorio no trae las otras: %', v_otras;
  end if;
  if (select d.specialty_key from public.helios_directorio() d where d.merchant_id = v_m) is distinct from 'psiquiatria' then
    raise exception '2. la principal dejó de ser la de la ficha';
  end if;
  select d.other_specialty_keys into v_otras from public.helios_directorio_medico(v_slug) d;
  if v_otras is distinct from array['medicina_interna', 'gastroenterologia'] then
    raise exception '2. helios_directorio_medico no trae las otras: %', v_otras;
  end if;
  if v_entra then
    select d.other_specialty_keys into v_otras from public.helios_directorio_consultas() d where d.merchant_id = v_m;
    if v_otras is distinct from array['medicina_interna', 'gastroenterologia'] then
      raise exception '2. helios_directorio_consultas no trae las otras: %', v_otras;
    end if;
  end if;
  reset role;

  -- =========================================================================
  -- 3. La principal pasa a ser una de las otras: no sale dos veces
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_directorio_guardar(v_m, '{"specialty_key": "medicina_interna"}');
  reset role;

  select d.other_specialty_keys into v_otras from public.helios_directorio() d where d.merchant_id = v_m;
  if v_otras is distinct from array['gastroenterologia'] then
    raise exception '3. la principal sale también entre las otras: %', v_otras;
  end if;

  -- =========================================================================
  -- 4. El superadmin las ve en la tarjeta; la ficha no tiene
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  select m into v_j
    from jsonb_array_elements(public.admin_directorio() -> 'medicos') m
   where m ->> 'merchant_id' = v_m::text;
  if v_j -> 'listing' -> 'other_specialty_keys' is distinct from '["gastroenterologia"]'::jsonb then
    raise exception '4. la tarjeta del superadmin no trae las otras: %', v_j -> 'listing';
  end if;
  if v_j -> 'base' -> 'other_specialty_keys' is distinct from '[]'::jsonb then
    raise exception '4. la ficha de la clínica trae otras: %', v_j -> 'base';
  end if;

  -- =========================================================================
  -- 5. Una lista vacía las quita
  -- =========================================================================
  perform public.admin_directorio_guardar(v_m, '{"other_specialty_keys": []}');
  reset role;
  if (select other_specialty_keys from public.directory_listings where merchant_id = v_m) <> '{}'::text[] then
    raise exception '5. la lista vacía no las quitó';
  end if;

  -- =========================================================================
  -- 6. El capacitador las elige desde el perfil (20261125100000); el operador no
  -- =========================================================================
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  values
    (v_cap, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'capacitador-' || v_cap || '@prueba.helios.test', now(), now()),
    (v_op, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'operador-' || v_op || '@prueba.helios.test', now(), now());
  insert into public.platform_admins (user_id, role, full_name, is_active) values
    (v_cap, 'capacitador', 'Capacitador de Prueba', true),
    (v_op, 'operador', 'Operador de Prueba', true);

  -- Un médico sin tarjeta todavía.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_m2 := (public.admin_create_merchant('Consultorio Sin Tarjeta', null, 'J-640000002', 'consultorio')).id;
  reset role;
  update public.merchants
     set owner_name = 'Marta Prueba Sola', doctor_title = 'Dra.', specialty = 'Cardiología',
         phone = '0414-999.40.02', city = 'Caracas'
   where id = v_m2;
  if exists (select 1 from public.directory_listings where merchant_id = v_m2) then
    raise exception '6. el médico nuevo ya tenía tarjeta';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_cap::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- Lee la principal y las otras (todavía ninguna).
  v_j := public.admin_medico_especialidades(v_m2);
  if v_j ->> 'specialty_key' is distinct from 'cardiologia' or v_j -> 'other_specialty_keys' is distinct from '[]'::jsonb then
    raise exception '6. el capacitador no lee las especialidades: %', v_j;
  end if;

  -- Guarda limpias: sin repetir, sin la principal.
  perform public.admin_medico_especialidades_guardar(v_m2, '["neumologia", "cardiologia", "neumologia", "angiologia"]');
  v_j := public.admin_medico_especialidades(v_m2);
  if v_j -> 'other_specialty_keys' is distinct from '["neumologia", "angiologia"]'::jsonb then
    raise exception '6. el capacitador no las guardó limpias: %', v_j;
  end if;

  foreach v_mal in array array['["otra"]', '["astrologia"]', '["cardiologia", "neumologia", "nefrologia", "urologia", "angiologia"]', '"neumologia"', 'null']
  loop
    v_fallo := false;
    begin
      perform public.admin_medico_especialidades_guardar(v_m2, v_mal::jsonb);
    exception when sqlstate '22023' then v_fallo := true;
    end;
    if not v_fallo then raise exception '6. el capacitador guardó %', v_mal; end if;
  end loop;

  -- Lo que no es suyo, no lo toca: la tarjeta del directorio sigue siendo del super admin.
  v_fallo := false;
  begin
    perform public.admin_directorio_guardar(v_m2, '{"visible": true}');
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '6. el capacitador publicó una tarjeta'; end if;

  -- El operador ve las clínicas, pero no corrige a los médicos.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_medico_especialidades_guardar(v_m2, '["urologia"]');
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '6. el operador cambió las especialidades'; end if;
  v_fallo := false;
  begin
    perform public.admin_medico_especialidades(v_m2);
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '6. el operador leyó las especialidades'; end if;

  -- Un anónimo, tampoco.
  set local role anon;
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  v_fallo := false;
  begin
    perform public.admin_medico_especialidades_guardar(v_m2, '["urologia"]');
  exception when insufficient_privilege then v_fallo := true;
  end;
  if not v_fallo then raise exception '6. un anónimo cambió las especialidades'; end if;
  reset role;

  -- La tarjeta que se creó está oculta: elegir especialidades no publica nada.
  if not exists (select 1 from public.directory_listings
                  where merchant_id = v_m2 and not is_visible
                    and other_specialty_keys = array['neumologia', 'angiologia']) then
    raise exception '6. la tarjeta del capacitador no quedó oculta con sus especialidades';
  end if;
  if (select count(*) from audit.admin_actions
       where actor = v_cap and target_id = v_m2 and action = 'directory.listing.update') <> 1 then
    raise exception '6. el cambio del capacitador no quedó en la bitácora';
  end if;
end;
$$;

rollback;
