-- ============================================================================
-- RX — El buscador de medicamentos (20261106180000)
--
--   bash supabase/tests/run.sh rx_catalogo_smoke
--
-- Todo dentro de la transacción, con datos inventados. Sin HTTP.
--
--   1. El buscador: nombres y nada más, sin farmacias ni precios.
--   2. Lo escrito se anota sin precio, solo para su clínica.
--   3. Lo que no parece un medicamento no se anota, y el récipe sale igual.
--   4. Permisos.
-- ============================================================================

begin;
-- @ayudas

create function pg_temp.como(p_usuario uuid, p_sql text)
returns jsonb
language plpgsql
as $$
declare
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_usuario::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  execute p_sql into v;
  reset role;
  return v;
end;
$$;

create function pg_temp.fallo(p_rol text, p_usuario uuid, p_sql text)
returns text
language plpgsql
as $$
declare
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_usuario::text, 'role', p_rol)::text, true);
  begin
    execute format('set local role %I', p_rol);
    execute p_sql into v;
    reset role;
    return null;
  exception when others then
    return sqlstate || ': ' || sqlerrm;
  end;
end;
$$;

create function pg_temp.espera_fallo(p_titulo text, p_rol text, p_usuario uuid, p_sql text, p_codigo text)
returns void
language plpgsql
as $$
declare
  v text := pg_temp.fallo(p_rol, p_usuario, p_sql);
begin
  if v is null then
    raise exception '%: debía fallar y no falló', p_titulo;
  end if;
  if left(v, 5) <> p_codigo then
    raise exception '%: esperaba %, salió «%»', p_titulo, p_codigo, v;
  end if;
end;
$$;

create function pg_temp.fila(p_farmacia text, p_nombre text, p_precio text)
returns jsonb
language sql
as $$
  select jsonb_build_object('farmacia', p_farmacia, 'nombre', p_nombre, 'precio', p_precio, 'moneda', 'USD',
                            'visto_en', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
$$;

-- Lo que encuentra un médico, como texto.
create function pg_temp.busca(p_usuario uuid, p_texto text)
returns jsonb
language sql
as $$
  select pg_temp.como(p_usuario, format('select public.rx_buscar_medicamentos(%L)', p_texto));
$$;

do $$
declare
  v_g1 uuid := gen_random_uuid();
  v_g2 uuid := gen_random_uuid();
  v_c1 uuid := gen_random_uuid();
  v_m1 uuid;
  v_m2 uuid;
  v_b1 uuid;
  v_b2 uuid;
  v_r1 uuid := gen_random_uuid();
  v_res jsonb;
  v_txt text;
  v_lista jsonb;
begin
  perform public.rx_agregar_farmacia('Zzfarma Secreta');
  perform public.rx_agregar_farmacia('Zzfarma Otra');
  perform public.rx_agregar_farmacia('Zzfarma Apagada');
  perform public.rx_cargar_precios('prueba', null, jsonb_build_array(
    pg_temp.fila('Zzfarma Secreta', 'ZZCATALOGO 500MG', '99.50'),
    pg_temp.fila('Zzfarma Otra', 'Zzcatálogo 500 mg cápsulas', '1.25'),
    pg_temp.fila('Zzfarma Secreta', 'ZZCATALOGO 875MG', '2.00'),
    pg_temp.fila('Zzfarma Secreta', 'OTRO ZZCATALOGO 10MG', '3.00'),
    pg_temp.fila('Zzfarma Apagada', 'ZZAPAGADO 10MG', '4.00'),
    pg_temp.fila('Zzfarma Secreta', 'ZZMUCHOS%_ 10MG', '5.00')));
  update public.rx_farmacias set activa = false where slug = public.rx_slug_farmacia('Zzfarma Apagada');

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'rx-' || u || '@prueba.helios.test', now(), now()
  from unnest(array[v_g1, v_g2, v_c1]) u;
  insert into public.merchants (name, tax_id, owner_name, doctor_title, email)
  values ('Consultorio Zz1', 'J-509876644', 'Ana Zzuno', 'Dra.', 'a.zz@example.com') returning id into v_m1;
  insert into public.merchants (name, tax_id, owner_name, doctor_title, email)
  values ('Consultorio Zz2', 'J-509876655', 'Beto Zzdos', 'Dr.', 'b.zz@example.com') returning id into v_m2;
  select id into v_b1 from public.merchant_branches where merchant_id = v_m1 and is_default;
  select id into v_b2 from public.merchant_branches where merchant_id = v_m2 and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_g1, v_m1, v_b1, 'gerente'),
    (v_c1, v_m1, v_b1, 'cajero'),
    (v_g2, v_m2, v_b2, 'gerente');
  perform pg_temp.como(v_g1, format('select public.rx_guardar_imagen(%L, %L)', 'firma', v_m1 || '/firma/a.png'));
  perform pg_temp.como(v_g2, format('select public.rx_guardar_imagen(%L, %L)', 'firma', v_m2 || '/firma/a.png'));

  -- --- 1. El buscador ----------------------------------------------------------------------
  v_lista := pg_temp.busca(v_g1, 'zzcatalogo');
  if jsonb_typeof(v_lista) <> 'array' or exists (select 1 from jsonb_array_elements(v_lista) e where jsonb_typeof(e) <> 'string') then
    raise exception '1. debe ser una lista de nombres: %', v_lista;
  end if;
  v_txt := v_lista::text;
  if v_txt ~* '(secreta|otra"|99\.5|1\.25|sku|moneda|precio)' then raise exception '1. el buscador filtra farmacia o precio: %', v_lista; end if;

  -- Una sola vez aunque lo vendan dos farmacias, y por orden alfabético, no por precio.
  if v_lista <> '["ZZCATALOGO 500MG", "ZZCATALOGO 875MG", "OTRO ZZCATALOGO 10MG"]'::jsonb
     and v_lista <> '["Zzcatálogo 500 mg cápsulas", "ZZCATALOGO 875MG", "OTRO ZZCATALOGO 10MG"]'::jsonb then
    raise exception '1. la lista: %', v_lista;
  end if;
  update public.rx_precios set precio_usd = 0.06 where nombre = 'ZZCATALOGO 875MG';
  if pg_temp.busca(v_g1, 'zzcatalogo') <> v_lista then raise exception '1. el precio movió el orden'; end if;

  if jsonb_array_length(pg_temp.busca(v_g1, 'ZZCATÁLOGO')) <> 3 then raise exception '1. acentos y mayúsculas'; end if;
  if jsonb_array_length(pg_temp.busca(v_g1, '875 zzcatalogo')) <> 1 then raise exception '1. en cualquier orden'; end if;
  if pg_temp.busca(v_g1, 'z') <> '[]'::jsonb then raise exception '1. con una letra no se busca'; end if;
  if pg_temp.busca(v_g1, '   ') <> '[]'::jsonb or pg_temp.como(v_g1, 'select public.rx_buscar_medicamentos(null)') <> '[]'::jsonb then raise exception '1. vacío'; end if;
  if pg_temp.busca(v_g1, 'zzapagado') <> '[]'::jsonb then raise exception '1. salió una farmacia apagada'; end if;
  if jsonb_array_length(pg_temp.busca(v_g1, 'zzmuchos%_')) <> 1 then raise exception '1. los comodines son texto'; end if;
  if pg_temp.busca(v_g1, '%') <> '[]'::jsonb and jsonb_array_length(pg_temp.busca(v_g1, '%%')) > 1 then raise exception '1. un comodín no lo trae todo'; end if;
  if jsonb_array_length(pg_temp.como(v_g1, 'select public.rx_buscar_medicamentos(''zzcatalogo'', 1)')) <> 1 then raise exception '1. el límite'; end if;

  -- --- 2. Lo escrito se anota sin precio, solo para su clínica ------------------------------
  perform pg_temp.como(v_g1, format(
    'select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, %L)', v_r1, '{"nombre": "Paciente Zzprivado"}',
    '[{"medicamento": "Zznuevo 20 mg"},
      {"medicamento": "ZZCATALOGO 500MG"},
      {"medicamento": "Zzcliente Pérez 10 mg"}]', ''));

  if not exists (select 1 from public.rx_medicamentos where merchant_id = v_m1 and nombre = 'Zznuevo 20 mg' and veces = 1) then
    raise exception '2. no se anotó el nuevo';
  end if;
  if exists (select 1 from public.rx_medicamentos where nombre = 'ZZCATALOGO 500MG') then raise exception '2. se anotó uno que ya tiene producto'; end if;

  -- Lo ve su clínica, no otra.
  if pg_temp.busca(v_g1, 'zznuevo') <> '["Zznuevo 20 mg"]'::jsonb then raise exception '2. su clínica debía verlo: %', pg_temp.busca(v_g1, 'zznuevo'); end if;
  if pg_temp.busca(v_g2, 'zznuevo') <> '[]'::jsonb then raise exception '2. otra clínica lo ve'; end if;
  if pg_temp.busca(v_g2, 'perez') <> '[]'::jsonb then raise exception '2. texto libre cruzó de clínica'; end if;

  -- Revisado a mano y puesto para todas, sí lo ve.
  insert into public.rx_medicamentos (merchant_id, clave, nombre)
  values (null, public.rx_clave_medicamento('Zzgeneral 5 mg'), 'Zzgeneral 5 mg');
  if pg_temp.busca(v_g2, 'zzgeneral') <> '["Zzgeneral 5 mg"]'::jsonb then raise exception '2. el general es para todas'; end if;

  -- Reemitir no cuenta; otro récipe sí; otra forma de escribirlo es el mismo.
  perform pg_temp.como(v_g1, format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, %L)', v_r1, '{"nombre": "Paciente Zzprivado"}', '[{"medicamento": "Zznuevo 20 mg"}]', ''));
  if (select veces from public.rx_medicamentos where merchant_id = v_m1 and nombre = 'Zznuevo 20 mg') <> 1 then raise exception '2. reemitir contó'; end if;
  perform pg_temp.como(v_g1, format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, %L)', gen_random_uuid(), '{"nombre": "Otro"}', '[{"medicamento": "ZZNUEVO 20MG tabletas"}]', ''));
  if (select veces from public.rx_medicamentos where merchant_id = v_m1 and clave = public.rx_clave_medicamento('Zznuevo 20 mg')) <> 2 then raise exception '2. otra forma de escribirlo'; end if;
  if (select count(*) from public.rx_medicamentos where merchant_id = v_m1 and clave = public.rx_clave_medicamento('Zznuevo 20 mg')) <> 1 then raise exception '2. se duplicó'; end if;

  -- La lista de trabajo: lo más recetado primero, entre clínicas, y sale cuando llega un precio.
  perform pg_temp.como(v_g2, format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, %L)', gen_random_uuid(), '{"nombre": "Otra"}', '[{"medicamento": "Zznuevo 20 mg"}]', ''));
  select jsonb_build_object('veces', veces, 'clinicas', clinicas) into v_res from public.rx_medicamentos_sin_precio where clave = public.rx_clave_medicamento('Zznuevo 20 mg');
  if (v_res ->> 'veces')::int <> 3 or (v_res ->> 'clinicas')::int <> 2 then raise exception '2. la lista de trabajo: %', v_res; end if;
  perform public.rx_cargar_precios('prueba', null, jsonb_build_array(pg_temp.fila('Zzfarma Otra', 'ZZNUEVO 20MG', '1')));
  if exists (select 1 from public.rx_medicamentos_sin_precio where clave = public.rx_clave_medicamento('Zznuevo 20 mg')) then raise exception '2. ya tiene precio y sigue en la lista'; end if;
  -- Con el precio cargado aparece una sola vez.
  if jsonb_array_length(pg_temp.busca(v_g1, 'zznuevo')) <> 1 then raise exception '2. se duplicó en el buscador: %', pg_temp.busca(v_g1, 'zznuevo'); end if;

  -- Un controlado se anota para su clínica, pero no se busca precio.
  perform pg_temp.como(v_g1, format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, %L)', gen_random_uuid(), '{"nombre": "Otra"}', '[{"medicamento": "Clonazepam 2 mg"}]', ''));
  if not exists (select 1 from public.rx_medicamentos where merchant_id = v_m1 and nombre = 'Clonazepam 2 mg') then raise exception '2. el controlado es para su clínica'; end if;
  if exists (select 1 from public.rx_medicamentos_sin_precio where nombre = 'Clonazepam 2 mg') then raise exception '2. a un controlado no se le busca precio'; end if;

  -- --- 3. Lo que no parece un medicamento no se anota, y el récipe sale igual ----------------
  perform pg_temp.como(v_g1, format(
    'select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, %L)', gen_random_uuid(), '{"nombre": "Otra"}',
    '[{"medicamento": "Farmacia Mi Socio 0412-1234567"},
      {"medicamento": "Compra en https://malo.example"},
      {"medicamento": "Escribe a socio@malo.example"},
      {"medicamento": "visita farmacia.com"},
      {"medicamento": "500 mg"}]', ''));
  if exists (select 1 from public.rx_medicamentos where nombre ~* '(socio|malo|farmacia\.com)' or nombre = '500 mg') then raise exception '3. se anotó lo que no era un medicamento'; end if;

  -- Si anotar falla, el récipe se emite igual.
  alter table public.rx_medicamentos add constraint rx_prueba_falla check (nombre <> 'Zzrevienta 10 mg');
  v_res := pg_temp.como(v_g1, format(
    'select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, %L)', gen_random_uuid(), '{"nombre": "Otra"}',
    '[{"medicamento": "Zzrevienta 10 mg"}]', ''));
  if v_res ->> 'id' is null then raise exception '3. el récipe debía emitirse'; end if;
  alter table public.rx_medicamentos drop constraint rx_prueba_falla;

  -- --- 4. Permisos ---------------------------------------------------------------------------
  perform pg_temp.espera_fallo('4. la secretaria', 'authenticated', v_c1, 'select public.rx_buscar_medicamentos(''zzcatalogo'')', '42501');
  perform pg_temp.espera_fallo('4. anon', 'anon', null, 'select public.rx_buscar_medicamentos(''zzcatalogo'')', '42501');
  perform pg_temp.espera_fallo('4. el médico lee la tabla', 'authenticated', v_g1, 'select count(*)::text::jsonb from public.rx_medicamentos', '42501');
  perform pg_temp.espera_fallo('4. el médico lee la lista de trabajo', 'authenticated', v_g1, 'select count(*)::text::jsonb from public.rx_medicamentos_sin_precio', '42501');
  perform pg_temp.espera_fallo('4. anon lee la lista de trabajo', 'anon', null, 'select count(*)::text::jsonb from public.rx_medicamentos_sin_precio', '42501');
  perform pg_temp.espera_fallo('4. el médico anota a otra clínica', 'authenticated', v_g1,
    format('select to_jsonb(public.rx_anotar_medicamento(%L::uuid, %L)::text)', v_m2, 'Zzajeno 1 mg'), '42501');
  if has_table_privilege('authenticated', 'public.rx_medicamentos', 'insert') or has_table_privilege('anon', 'public.rx_medicamentos', 'select') then
    raise exception '4. la tabla tiene permisos para la API';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.rx_medicamentos'::regclass) then raise exception '4. sin RLS'; end if;
  if exists (select 1 from pg_policy where polrelid = 'public.rx_medicamentos'::regclass) then raise exception '4. tiene políticas'; end if;
end;
$$;

set constraints all immediate;

rollback;
