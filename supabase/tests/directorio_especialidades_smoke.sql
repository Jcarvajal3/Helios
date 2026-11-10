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
--
-- No manda nada: no llama a `helios_dispatch_*`.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin uuid;
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
end;
$$;

rollback;
