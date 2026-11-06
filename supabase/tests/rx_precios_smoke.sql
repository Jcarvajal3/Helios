-- ============================================================================
-- RX — Los precios de las farmacias (20261106120000)
--
--   bash supabase/tests/run.sh rx_precios_smoke
--
-- Todo dentro de la transacción, con farmacias y productos de prueba cuyos
-- nombres no existen en los datos reales. No llama a nada que salga por HTTP.
--
--   1. Las piezas: dosis, miles, decimales y lo que trae la caja.
--   2. La carga: valida fila por fila, solo farmacias admitidas, y no retrocede.
--   3. La búsqueda: los que deben salir y, sobre todo, los que no.
--   4. Lo que se enseña: orden por precio, sin viejos, agotados ni apagadas.
--   5. El paciente: solo con el enlace, y sin saber de quién es el récipe.
--   6. El médico no puede tocar farmacias o precios, ni recibe el enlace.
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

create function pg_temp.espera_fallo(p_titulo text, p_rol text, p_usuario uuid, p_sql text, p_codigo text, p_mensaje text default null)
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
  if p_mensaje is not null and position(p_mensaje in v) = 0 then
    raise exception '%: esperaba el mensaje «%», salió «%»', p_titulo, p_mensaje, v;
  end if;
end;
$$;

-- Los productos que devuelve una búsqueda.
create function pg_temp.productos(p_medicamento text)
returns text[]
language sql
as $$
  select coalesce(array_agg(e ->> 'producto'), '{}')
  from jsonb_array_elements(public.rx_ofertas(p_medicamento, 30)) e;
$$;

create function pg_temp.fila(p_farmacia text, p_nombre text, p_precio text, p_moneda text default 'USD', p_extra jsonb default '{}')
returns jsonb
language sql
as $$
  select jsonb_build_object('farmacia', p_farmacia, 'nombre', p_nombre, 'precio', p_precio, 'moneda', p_moneda,
                            'visto_en', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')) || p_extra;
$$;

-- Lo recetado no debe encontrar nada.
create function pg_temp.nada(p_medicamento text)
returns void
language plpgsql
as $$
begin
  if pg_temp.productos(p_medicamento) <> '{}'::text[] then
    raise exception '3. «%» no debía encontrar nada y encontró %', p_medicamento, pg_temp.productos(p_medicamento);
  end if;
end;
$$;

-- Lo recetado debe encontrar exactamente esto.
create function pg_temp.solo(p_medicamento text, p_esperado text[])
returns void
language plpgsql
as $$
begin
  if pg_temp.productos(p_medicamento) <> p_esperado then
    raise exception '3. «%» debía encontrar % y encontró %', p_medicamento, p_esperado, pg_temp.productos(p_medicamento);
  end if;
end;
$$;

do $$
declare
  v_g1   uuid := gen_random_uuid();
  v_c1   uuid := gen_random_uuid();
  v_m1   uuid;
  v_b1   uuid;
  v_r1   uuid := gen_random_uuid();
  v_res  jsonb;
  v_tasa numeric;
  v_lista text[];
  v_token text;
  v_sig  text;
  v_antes bigint;
  v_txt  text;
  v_farm text;
begin
  select rate into v_tasa from public.exchange_rates where source = 'BCV' order by effective_date desc limit 1;
  if v_tasa is null then raise exception 'Sin tasa BCV: la suite la necesita'; end if;

  -- --- 1. Las piezas ---------------------------------------------------------------------
  if public.rx_tokens('AMOXICILINA 500MG CAPSULAS X 21') <> array['amoxicilina', '500mg', 'cap'] then raise exception '1. %', public.rx_tokens('AMOXICILINA 500MG CAPSULAS X 21'); end if;
  if public.rx_tokens('Acetaminofén 1.000 mg') <> array['acetaminofen', '1000mg'] then raise exception '1. los miles: %', public.rx_tokens('Acetaminofén 1.000 mg'); end if;
  if public.rx_tokens('Acetaminofén 1 g') <> array['acetaminofen', '1000mg'] then raise exception '1. los gramos'; end if;
  if public.rx_tokens('Penicilina 1.200.000 UI') <> array['penicilina', '1200000ui'] then raise exception '1. varios miles: %', public.rx_tokens('Penicilina 1.200.000 UI'); end if;
  if public.rx_tokens('Levotiroxina 0,125 mg') <> array['levotiroxina', '0.125mg'] then raise exception '1. el decimal: %', public.rx_tokens('Levotiroxina 0,125 mg'); end if;
  if public.rx_tokens('Haloperidol .5 mg') <> array['haloperidol', '0.5mg'] then raise exception '1. .5 multiplicó la dosis: %', public.rx_tokens('Haloperidol .5 mg'); end if;
  if public.rx_tokens('Haloperidol ,5 mg') <> array['haloperidol', '0.5mg'] then raise exception '1. ,5 multiplicó la dosis'; end if;
  if public.rx_tokens('Betametasona .05%') <> array['betametasona', '0.05%'] then raise exception '1. .05%%: %', public.rx_tokens('Betametasona .05%'); end if;
  if public.rx_tokens('Hidrocortisona crema 1% 30 g') <> array['hidrocortisona', 'crema', '1%', '30g'] then raise exception '1. el envase'; end if;
  if public.rx_tokens('Ibuprofeno 100mg/5ml jbe x 120 ml') <> array['ibuprofeno', '100mg', '5ml', 'jarabe'] then raise exception '1. el jarabe: %', public.rx_tokens('Ibuprofeno 100mg/5ml jbe x 120 ml'); end if;
  if public.rx_tokens('Budesonida/Formoterol 160/4,5 mcg') <> array['budesonida', 'formoterol', '160mcg', '4.5mcg'] then raise exception '1. dos dosis: %', public.rx_tokens('Budesonida/Formoterol 160/4,5 mcg'); end if;
  if public.rx_tokens('Vitamina D 100 ' || chr(956) || 'g') <> array['vitamina', 'd', '100mcg'] then raise exception '1. la micro griega'; end if;
  if public.rx_tokens('Amoxicilina 500 mgs') <> array['amoxicilina', '500mg'] then raise exception '1. mgs'; end if;
  if public.rx_tokens('Losartan 50') <> array['losartan', '50'] then raise exception '1. el número suelto se queda'; end if;
  if public.rx_tokens('Losartan 30 tabletas') <> array['losartan', 'tab'] then raise exception '1. la cantidad se va: %', public.rx_tokens('Losartan 30 tabletas'); end if;
  if public.rx_tokens(null) <> '{}'::text[] then raise exception '1. null'; end if;

  -- --- 2. La carga ----------------------------------------------------------------------
  foreach v_farm in array array['Zzfarmacia Uno', 'Zzfarmacia Dos', 'Zzfarmacia Tres', 'Zzfarmacia Apagable'] loop
    perform public.rx_agregar_farmacia(v_farm);
  end loop;

  v_res := public.rx_cargar_precios('prueba', 'prueba.csv', jsonb_build_array(
    pg_temp.fila('Zzfarmacia Uno', 'ZZAMOXI 500MG CAPSULAS X 21', '5.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZAMOXI 875MG TABLETAS X 14', '6.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZAMOXI 500MG + ZZCLAVU 125MG TABLETAS', '7.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZOTRO 500MG', '1.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZIBU JARABE 100MG/5ML', '3.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZIBU 400MG TABLETAS', '2.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZIBU 100MG/ML GOTAS', '2.50'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMETFOR 500MG', '1.50'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMETFOR XR 500MG', '2.50'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMETFOR LP 500 MG', '2.60'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZDICLO 75MG/3ML AMPOLLA', '2.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZDICLO 75MG TAB', '1.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZASPI NINOS 100MG', '1.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZLOSA ZZHIDRO 50MG', '1.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZAMLO 5MG + ZZBISO 5MG', '1.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZACIDO ZZVALPRO 500MG', '1.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZHALO 5MG', '1.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZHALO .5MG', '1.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZINSU 70/30', '1.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZINSU ZZGLAR 100UI', '1.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMARCA 20MG CAPS', '1.00', 'USD', '{"laboratorio": "Zzlab Bueno"}'),
    pg_temp.fila('Zzfarmacia Dos', 'ZZMARCA 20MG', '2.00', 'USD', '{"laboratorio": "Zzlab Otro"}'),
    pg_temp.fila('Zzfarmacia Dos', 'Zzamoxi 500 mg cápsulas', '4.50', 'USD', '{"url": "https://ejemplo.test/a", "laboratorio": "Lab Prueba"}'),
    pg_temp.fila('Zzfarmacia Dos', 'ZZIBU 400MG COMPRIMIDOS', '2.10', 'USD', '{"url": "javascript:alert(1)"}')
  ));
  if (v_res ->> 'aceptadas')::int <> 24 or (v_res ->> 'rechazadas')::int <> 0 then raise exception '2. la carga buena: %', v_res; end if;

  -- Cada fila mala se rechaza con su motivo y las buenas entran.
  v_res := public.rx_cargar_precios('prueba', null, jsonb_build_array(
    pg_temp.fila('Farmadon', 'ZZEXCLUIDA 10MG', '1.00'),
    pg_temp.fila('FARMAPAZ', 'ZZEXCLUIDA 10MG', '1.00'),
    pg_temp.fila('Farma Don', 'ZZEXCLUIDA 10MG', '1.00'),
    pg_temp.fila('Farmadon C.A.', 'ZZEXCLUIDA 10MG', '1.00'),
    pg_temp.fila('Farmapaz Caracas', 'ZZEXCLUIDA 10MG', '1.00'),
    pg_temp.fila('Farmacia Inventada', 'ZZEXCLUIDA 10MG', '1.00'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '0'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '-1'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '1.234'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '1,234'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '99999999999999999999'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '1', 'EUR'),
    -- La moneda equivocada: bolívares declarados como dólares y al revés.
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '5000', 'USD'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '5', 'VES'),
    pg_temp.fila('Zzfarmacia Uno', '500 MG', '1'),
    pg_temp.fila('', 'ZZMALA 10MG', '1'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA ' || chr(65533) || ' 10MG', '1'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '1', 'USD', jsonb_build_object('sku', repeat('x', 200))),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '1', 'USD', '{"visto_en": ""}'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '1', 'USD', '{"visto_en": "no es fecha"}'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '1', 'USD', '{"visto_en": "11/06/2026"}'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '1', 'USD', '{"visto_en": "2026-11-06"}'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '1', 'USD', '{"visto_en": "2026-11-06T10:00:00"}'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '1', 'USD', '{"visto_en": "2026-13-45T10:00:00Z"}'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '1', 'USD', '{"visto_en": "2099-01-01T00:00:00Z"}'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMALA 10MG', '1', 'USD', '{"disponible": "quizas"}'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZBUENA 10MG', '1')
  ));
  if (v_res ->> 'aceptadas')::int <> 1 or (v_res ->> 'rechazadas')::int <> 26 then raise exception '2. las malas: %', v_res; end if;
  if (select count(*) from jsonb_array_elements(v_res -> 'rechazos') r where r ->> 'motivo' = 'Farmacia excluida') <> 3 then
    raise exception '2. Farmadon y Farmapaz debían quedar fuera: %', v_res;
  end if;
  if (select count(*) from jsonb_array_elements(v_res -> 'rechazos') r where r ->> 'motivo' = 'Farmacia desconocida') <> 3 then
    raise exception '2. una farmacia desconocida no se crea: %', v_res;
  end if;
  if exists (select 1 from public.rx_precios where nombre like 'ZZEXCLUIDA%' or nombre like 'ZZMALA%') then raise exception '2. entró una fila mala'; end if;
  if exists (select 1 from public.rx_farmacias where slug in ('farmadonca', 'farmapazcaracas', 'inventada')) then raise exception '2. se creó una farmacia sola'; end if;
  if (select recibidas from public.rx_cargas where id = (v_res ->> 'carga_id')::uuid) <> 27 then raise exception '2. el registro de la carga'; end if;

  -- Una farmacia excluida tampoco entra por la puerta de agregar.
  perform pg_temp.espera_fallo('2. agregar Farmadon C.A.', 'postgres', null, $q$select to_jsonb(public.rx_agregar_farmacia('Farmadon C.A.'))$q$, '22023', 'excluida');
  perform pg_temp.espera_fallo('2. agregar Farma-Paz 2', 'postgres', null, $q$select to_jsonb(public.rx_agregar_farmacia('Farma-Paz 2'))$q$, '22023', 'excluida');

  -- «Farmacia SAAS» y «SAAS» son la misma.
  if public.rx_slug_farmacia('Farmacia SAAS') <> 'saas' or public.rx_slug_farmacia('SAAS') <> 'saas' then raise exception '2. el slug'; end if;

  -- Una fila que revienta al guardar no tumba el lote.
  v_res := public.rx_cargar_precios('prueba', null, jsonb_build_array(
    pg_temp.fila('Zzfarmacia Uno', 'ZZLOTE 10MG', '1', 'USD', jsonb_build_object('url', 'https://ejemplo.test/' || repeat('a', 500))),
    pg_temp.fila('Zzfarmacia Uno', 'ZZLOTE 20MG', '1')));
  if (v_res ->> 'aceptadas')::int <> 2 then raise exception '2. el lote: %', v_res; end if;

  -- Los controlados no entran, ni por el nombre, ni por la marca, ni marcados a mano.
  v_res := public.rx_cargar_precios('prueba', null, jsonb_build_array(
    pg_temp.fila('Zzfarmacia Uno', 'CLONAZEPAM 0,5 MG', '1'),
    pg_temp.fila('Zzfarmacia Uno', 'Clonazepám 2MG', '1'),
    pg_temp.fila('Zzfarmacia Uno', 'RIVOTRIL 2 MG', '1'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZTRAMA 50MG', '1', 'USD', '{"laboratorio": "Tramal"}'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMARCADO 10MG', '1', 'USD', '{"controlado": "si"}'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZNOMARCADO 10MG', '1', 'USD', '{"controlado": "no"}')));
  if (v_res ->> 'aceptadas')::int <> 1 or (select count(*) from jsonb_array_elements(v_res -> 'rechazos') r where r ->> 'motivo' = 'Medicamento controlado') <> 5 then
    raise exception '2. los controlados: %', v_res;
  end if;
  -- Y si una fila llega a estar en la tabla, tampoco sale.
  insert into public.rx_precios (farmacia_id, clave, nombre, tokens, tokens_propios, precio_usd, visto_en, fuente, carga_id)
  select f.id, 'prueba-ctrl', 'DIAZEPAM 10MG', array['diazepam', '10mg'], array['diazepam', '10mg'], 1, now(), 'prueba', (v_res ->> 'carga_id')::uuid
  from public.rx_farmacias f where f.slug = public.rx_slug_farmacia('Zzfarmacia Uno');
  perform pg_temp.nada('Diazepam 10 mg');
  -- Tampoco si lo controlado es la marca del laboratorio y no lo recetado.
  insert into public.rx_precios (farmacia_id, clave, nombre, tokens, tokens_propios, laboratorio, precio_usd, visto_en, fuente, carga_id)
  select f.id, 'prueba-ctrl-lab', 'ZZCONLAB 10MG', array['zzconlab', '10mg', 'tramal'], array['zzconlab', '10mg'], 'Tramal', 1, now(), 'prueba', (v_res ->> 'carga_id')::uuid
  from public.rx_farmacias f where f.slug = public.rx_slug_farmacia('Zzfarmacia Uno');
  perform pg_temp.nada('Zzconlab 10 mg');
  insert into public.rx_controlados (palabra) values ('zzcontrolado');
  perform public.rx_cargar_precios('prueba', null, jsonb_build_array(pg_temp.fila('Zzfarmacia Uno', 'ZZCONTROLADO 10MG ZZOTRA', '1')));
  if exists (select 1 from public.rx_precios where nombre like 'ZZCONTROLADO%') then raise exception '2. la lista se puede ampliar'; end if;

  -- El enlace que no es https no se guarda.
  if (select url from public.rx_precios where nombre = 'ZZIBU 400MG COMPRIMIDOS') is not null then raise exception '2. se guardó un enlace peligroso'; end if;

  -- Un dato viejo no pisa uno nuevo, y se cuenta aparte; uno nuevo sí pisa.
  v_res := public.rx_cargar_precios('prueba', null, jsonb_build_array(
    pg_temp.fila('Zzfarmacia Uno', 'ZZBUENA 10MG', '9', 'USD', jsonb_build_object('visto_en', to_char(now() - interval '3 days', 'YYYY-MM-DD"T"HH24:MI:SSOF')))));
  if (select precio_usd from public.rx_precios where nombre = 'ZZBUENA 10MG') <> 1 then raise exception '2. el viejo pisó al nuevo'; end if;
  if (v_res ->> 'ignoradas')::int <> 1 or (v_res ->> 'aceptadas')::int <> 0 then raise exception '2. el viejo se cuenta aparte: %', v_res; end if;
  perform public.rx_cargar_precios('prueba', null, jsonb_build_array(pg_temp.fila('Zzfarmacia Uno', 'ZZBUENA 10MG', '2')));
  if (select precio_usd from public.rx_precios where nombre = 'ZZBUENA 10MG') <> 2 then raise exception '2. el nuevo no actualizó'; end if;
  if (select count(*) from public.rx_precios where nombre = 'ZZBUENA 10MG') <> 1 then raise exception '2. se duplicó'; end if;

  -- Dos laboratorios con el mismo nombre son dos filas; el mismo sku, una.
  perform public.rx_cargar_precios('prueba', null, jsonb_build_array(
    pg_temp.fila('Zzfarmacia Uno', 'ZZDOSLAB 10MG', '1', 'USD', '{"laboratorio": "Zzlab A"}'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZDOSLAB 10MG', '2', 'USD', '{"laboratorio": "Zzlab B"}'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZSKU 10MG', '1', 'USD', '{"sku": "zz-1"}'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZSKU 10MG NUEVO', '2', 'USD', '{"sku": "zz-1"}')));
  if (select count(*) from public.rx_precios where nombre = 'ZZDOSLAB 10MG') <> 2 then raise exception '2. se fusionaron dos laboratorios'; end if;
  if (select count(*) from public.rx_precios where sku = 'zz-1') <> 1 then raise exception '2. el sku no dedupe'; end if;

  -- --- 3. La búsqueda: los que deben salir ---------------------------------------------------
  v_lista := pg_temp.productos('Zzamoxi 500 mg');
  if v_lista <> array['Zzamoxi 500 mg cápsulas', 'ZZAMOXI 500MG CAPSULAS X 21'] then raise exception '3. el orden por precio: %', v_lista; end if;
  perform pg_temp.solo('ZZAMOXI 500MG', v_lista);
  perform pg_temp.solo('zzámoxi 0,5 g', v_lista);
  perform pg_temp.solo('Zzamoxi 500 mg cápsulas', v_lista);
  perform pg_temp.solo('Zzamoxi 500 mg tabletas #21', v_lista);
  perform pg_temp.solo('Zzamoxi 500 mg + Zzclavu 125 mg', array['ZZAMOXI 500MG + ZZCLAVU 125MG TABLETAS']);
  perform pg_temp.solo('Zzamoxi/Zzclavu 500/125 mg', array['ZZAMOXI 500MG + ZZCLAVU 125MG TABLETAS']);
  perform pg_temp.solo('Zzibu jarabe 100 mg/5 ml', array['ZZIBU JARABE 100MG/5ML']);
  perform pg_temp.solo('Zzmetfor 500 mg', array['ZZMETFOR 500MG']);
  perform pg_temp.solo('Zzmetfor XR 500 mg', array['ZZMETFOR XR 500MG']);
  perform pg_temp.solo('Zzdiclo 75 mg', array['ZZDICLO 75MG TAB']);
  perform pg_temp.solo('Zzdiclo 75 mg/3 ml ampolla', array['ZZDICLO 75MG/3ML AMPOLLA']);
  perform pg_temp.solo('Zzhalo .5 mg', array['ZZHALO .5MG']);
  perform pg_temp.solo('Zzhalo 5 mg', array['ZZHALO 5MG']);

  -- Un producto sin dosis nunca coincide, aunque el nombre sea idéntico.
  perform public.rx_cargar_precios('prueba', null, jsonb_build_array(
    pg_temp.fila('Zzfarmacia Uno', 'ZZSINDOSIS CREMA', '1'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZCONLABNOMBRE 20MG ZZLABNOMBRE', '1', 'USD', '{"laboratorio": "Zzlabnombre"}')));
  perform pg_temp.nada('Zzsindosis crema');
  perform pg_temp.nada('Zzinsu 70/30');

  -- El laboratorio no estorba aunque venga dentro del nombre, y nombrarlo acota.
  perform pg_temp.solo('Zzconlabnombre 20 mg', array['ZZCONLABNOMBRE 20MG ZZLABNOMBRE']);
  perform pg_temp.solo('Zzmarca 20 mg', array['ZZMARCA 20MG CAPS', 'ZZMARCA 20MG']);
  perform pg_temp.solo('Zzmarca 20 mg Zzlab Bueno', array['ZZMARCA 20MG CAPS']);

  -- Los que NO deben salir: otra dosis, fármaco, liberación, vía o población.
  perform pg_temp.nada('Zzamoxi 250 mg');
  perform pg_temp.nada('Zzamox 500 mg');
  perform pg_temp.nada('500 mg');
  perform pg_temp.nada('');
  perform pg_temp.nada(null);
  perform pg_temp.nada('Zzamoxi');
  perform pg_temp.nada('Zzibu jarabe');
  perform pg_temp.nada('Zzibu 100 mg');
  perform pg_temp.nada('Zzaspi 100 mg');
  perform pg_temp.nada('Zzlosa 50 mg');
  perform pg_temp.nada('Zzamlo 5 mg');
  perform pg_temp.nada('Zzacido 500 mg');
  perform pg_temp.nada('Crema 1%');
  perform pg_temp.nada('Zzamoxi 500');
  perform pg_temp.nada('Zzinsu');
  perform pg_temp.nada('Zzinsu 100 UI');
  perform pg_temp.nada('Zzamoxi/Zzclavu 875/125 mg');
  perform pg_temp.nada('Zzmarca 20 mg Zzlab Inexistente');
  if 'ZZOTRO 500MG' = any (v_lista) or 'ZZAMOXI 875MG TABLETAS X 14' = any (v_lista)
     or 'ZZAMOXI 500MG + ZZCLAVU 125MG TABLETAS' = any (v_lista) then
    raise exception '3. salió otro producto: %', v_lista;
  end if;

  -- La presentación también define lo que se busca.
  if jsonb_array_length(public.rx_ofertas_del_renglon('{"medicamento": "Zzamoxi", "presentacion": "500 mg"}')) <> 2 then raise exception '3. la dosis en la presentación'; end if;
  if jsonb_array_length(public.rx_ofertas_del_renglon('{"medicamento": "Zzamoxi"}')) <> 0 then raise exception '3. sin dosis en ninguna parte'; end if;
  if jsonb_array_length(public.rx_ofertas_del_renglon('{"medicamento": "Zzibu 100 mg/5 ml", "presentacion": "Jarabe"}')) <> 1 then raise exception '3. la forma en la presentación'; end if;
  if jsonb_array_length(public.rx_ofertas_del_renglon('{"medicamento": "Zzibu 400 mg", "presentacion": "Jarabe"}')) <> 0 then raise exception '3. pidió jarabe y salieron sólidos'; end if;

  -- Si cambian las reglas, lo ya cargado se puede recalcular.
  update public.rx_precios set tokens = '{}', tokens_propios = '{}' where nombre = 'ZZMETFOR 500MG';
  perform pg_temp.nada('Zzmetfor 500 mg');
  perform public.rx_recalcular_tokens();
  perform pg_temp.solo('Zzmetfor 500 mg', array['ZZMETFOR 500MG']);

  -- --- 4. Lo que se enseña ---------------------------------------------------------------------
  -- Con monedas distintas se compara en dólares a la tasa BCV.
  perform public.rx_cargar_precios('prueba', null, jsonb_build_array(
    pg_temp.fila('Zzfarmacia Tres', 'ZZMIXTO 10MG', (round(v_tasa * 3, 2))::text, 'VES'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZMIXTO 10MG TAB', '2'),
    pg_temp.fila('Zzfarmacia Dos', 'ZZMIXTO 10MG CAP', '4')));
  perform pg_temp.solo('Zzmixto 10 mg', array['ZZMIXTO 10MG TAB', 'ZZMIXTO 10MG', 'ZZMIXTO 10MG CAP']);
  v_res := public.rx_ofertas('Zzmixto 10 mg');
  if v_res -> 1 ->> 'moneda' <> 'VES' or (v_res -> 1 ->> 'precio')::numeric <> round(v_tasa * 3, 2) then raise exception '4. se enseña en su moneda: %', v_res; end if;
  if jsonb_array_length(public.rx_ofertas('Zzmixto 10 mg', 1)) <> 1 then raise exception '4. el tope'; end if;
  if v_res ?& array['token_precios', 'carga_id'] then raise exception '4. la oferta lleva de más'; end if;

  -- Agotado, viejo y farmacia apagada no salen.
  perform public.rx_cargar_precios('prueba', null, jsonb_build_array(
    pg_temp.fila('Zzfarmacia Uno', 'ZZAGOTADO 10MG', '1', 'USD', '{"disponible": "no"}'),
    pg_temp.fila('Zzfarmacia Uno', 'ZZVIEJO 10MG', '1', 'USD', jsonb_build_object('visto_en', to_char(now() - interval '15 days', 'YYYY-MM-DD"T"HH24:MI:SSOF'))),
    pg_temp.fila('Zzfarmacia Uno', 'ZZRECIENTE 10MG', '1', 'USD', jsonb_build_object('visto_en', to_char(now() - interval '13 days', 'YYYY-MM-DD"T"HH24:MI:SSOF'))),
    pg_temp.fila('Zzfarmacia Apagable', 'ZZAPAGADA 10MG', '1')));
  perform pg_temp.nada('Zzagotado 10 mg');
  perform pg_temp.nada('Zzviejo 10 mg');
  if pg_temp.productos('Zzreciente 10 mg') = '{}'::text[] then raise exception '4. debía salir uno reciente'; end if;
  if pg_temp.productos('Zzapagada 10 mg') = '{}'::text[] then raise exception '4. antes de apagarla sale'; end if;
  update public.rx_farmacias set activa = false where slug = public.rx_slug_farmacia('Zzfarmacia Apagable');
  perform pg_temp.nada('Zzapagada 10 mg');

  -- Si por lo que sea hay filas de Farmadon, tampoco salen.
  insert into public.rx_precios (farmacia_id, clave, nombre, tokens, tokens_propios, precio_usd, visto_en, fuente, carga_id)
  select f.id, 'prueba', 'ZZFARMADON 10MG', array['zzfarmadon', '10mg'], array['zzfarmadon', '10mg'], 1, now(), 'prueba', (select id from public.rx_cargas limit 1)
  from public.rx_farmacias f where f.slug = 'farmadon';
  perform pg_temp.nada('Zzfarmadon 10 mg');

  -- --- 5. El paciente ------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'rx-' || u || '@prueba.helios.test', now(), now()
  from unnest(array[v_g1, v_c1]) u;
  insert into public.merchants (name, tax_id, owner_name, doctor_title, email)
  values ('Consultorio Zz', 'J-509876633', 'Ana Zzmedica', 'Dra.', 'ana.zz@example.com')
  returning id into v_m1;
  select id into v_b1 from public.merchant_branches where merchant_id = v_m1 and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_g1, v_m1, v_b1, 'gerente'),
    (v_c1, v_m1, v_b1, 'cajero');

  perform pg_temp.como(v_g1, format('select public.rx_guardar_imagen(%L, %L)', 'firma', v_m1 || '/firma/a.png'));
  perform pg_temp.como(v_g1, format(
    'select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, %L)', v_r1,
    '{"nombre": "Paciente Zzsecreto", "documento": "V99887766", "correo": "secreto@example.com"}',
    '[{"medicamento": "Zzamoxi 500 mg", "indicacion": "Zzindicacion privada"},
      {"medicamento": "Zzsin precio 10 mg"},
      {"medicamento": "Farmacia Mi Socio 0412-1234567 Zzamoxi 500 mg"},
      {"medicamento": "Zzamoxi 500 mg (Paciente Zzsecreto)"}]',
    'Zzgeneral privada'));
  select token_precios into v_token from public.rx_recipes where id = v_r1;
  if v_token !~ '^[0-9a-f]{32}$' then raise exception '5. el enlace: %', v_token; end if;

  -- Sin cuenta, con el enlace.
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  set local role anon;
  v_res := public.rx_precios_publicos(v_token);
  reset role;

  -- Claves exactas: lo que no esté aquí no sale.
  if (select array_agg(k order by k) from jsonb_object_keys(v_res) k) <> array['medicamentos', 'sin_precio'] then raise exception '5. las claves: %', v_res; end if;
  if jsonb_array_length(v_res -> 'medicamentos') <> 1 then raise exception '5. solo lo que coincidió: %', v_res; end if;
  if (select array_agg(k order by k) from jsonb_object_keys(v_res -> 'medicamentos' -> 0) k) <> array['nombre', 'ofertas'] then raise exception '5. las claves del medicamento'; end if;
  if (select array_agg(k order by k) from jsonb_object_keys(v_res -> 'medicamentos' -> 0 -> 'ofertas' -> 0) k)
     <> array['disponible', 'farmacia', 'laboratorio', 'moneda', 'precio', 'presentacion', 'producto', 'url', 'visto_en'] then
    raise exception '5. las claves de la oferta';
  end if;
  if v_res -> 'medicamentos' -> 0 ->> 'nombre' <> 'Zzamoxi 500 mg' then raise exception '5. el nombre: %', v_res; end if;
  if jsonb_array_length(v_res -> 'medicamentos' -> 0 -> 'ofertas') <> 2 then raise exception '5. las ofertas: %', v_res; end if;
  if (v_res ->> 'sin_precio')::int <> 3 then raise exception '5. sin precio se cuentan: %', v_res; end if;

  -- Ni los datos del récipe ni lo que el médico coló en el nombre del medicamento.
  v_txt := v_res::text;
  if v_txt ~* '(zzsecreto|V99887766|secreto@example|zzmedica|ana\.zz|zzindicacion|zzgeneral|socio|0412)' then raise exception '5. el enlace filtra datos: %', v_res; end if;

  -- Enlaces que no valen: todos con el mismo error.
  perform pg_temp.espera_fallo('5. enlace falso', 'anon', null, format('select public.rx_precios_publicos(%L)', repeat('a', 32)), 'P0002', 'no existe o ya venció');
  perform pg_temp.espera_fallo('5. enlace raro', 'anon', null, format('select public.rx_precios_publicos(%L)', '%'' or 1=1'), 'P0002', 'no existe o ya venció');
  perform pg_temp.espera_fallo('5. sin enlace', 'anon', null, 'select public.rx_precios_publicos(null)', 'P0002', 'no existe o ya venció');
  update public.rx_recipes set created_at = now() - interval '31 days' where id = v_r1;
  perform pg_temp.espera_fallo('5. enlace vencido', 'anon', null, format('select public.rx_precios_publicos(%L)', v_token), 'P0002', 'no existe o ya venció');
  if (public.rx_datos_precios_envio(v_r1) ->> 'hay_precios')::boolean is not false then raise exception '5. un enlace vencido no va en el correo'; end if;
  update public.rx_recipes set created_at = now() where id = v_r1;

  -- Cada récipe tiene su enlace.
  if (select count(distinct token_precios) = count(*) from public.rx_recipes) is not true then raise exception '5. enlaces repetidos'; end if;

  -- El correo recibe el enlace y sabe si hay precios.
  v_res := public.rx_datos_precios_envio(v_r1);
  if v_res ->> 'token_precios' <> v_token or (v_res ->> 'hay_precios')::boolean is not true then raise exception '5. los datos del envío: %', v_res; end if;
  update public.rx_recipes set medicamentos = '[{"medicamento": "Zzsin precio 10 mg"}]' where id = v_r1;
  if (public.rx_datos_precios_envio(v_r1) ->> 'hay_precios')::boolean is not false then raise exception '5. sin precios el correo no lleva el enlace'; end if;
  update public.rx_recipes set medicamentos = '[{"medicamento": "Zzamoxi 500 mg"}]' where id = v_r1;

  -- --- 6. El médico no puede tocar nada de esto ----------------------------------------------
  foreach v_sig in array array['public.rx_farmacias', 'public.rx_precios', 'public.rx_cargas', 'public.rx_controlados'] loop
    if not (select relrowsecurity from pg_class where oid = v_sig::regclass) then raise exception '6. % sin RLS', v_sig; end if;
    if exists (select 1 from pg_policy where polrelid = v_sig::regclass) then raise exception '6. % tiene políticas', v_sig; end if;
    foreach v_txt in array array['authenticated', 'anon'] loop
      if has_table_privilege(v_txt, v_sig, 'select') or has_table_privilege(v_txt, v_sig, 'insert')
         or has_table_privilege(v_txt, v_sig, 'update') or has_table_privilege(v_txt, v_sig, 'delete') then
        raise exception '6. % tiene permisos para %', v_sig, v_txt;
      end if;
    end loop;
    perform pg_temp.espera_fallo('6. el médico lee ' || v_sig, 'authenticated', v_g1,
      format('select count(*)::text::jsonb from %s', v_sig), '42501', 'permission denied');
  end loop;

  select count(*) into v_antes from public.rx_precios;
  perform pg_temp.espera_fallo('6. el médico cambia un precio', 'authenticated', v_g1,
    'with u as (update public.rx_precios set precio_usd = 0.01 returning 1) select count(*)::text::jsonb from u', '42501', 'permission denied');
  perform pg_temp.espera_fallo('6. el médico borra una farmacia', 'authenticated', v_g1,
    'with u as (delete from public.rx_farmacias returning 1) select count(*)::text::jsonb from u', '42501', 'permission denied');
  if (select count(*) from public.rx_precios) <> v_antes then raise exception '6. cambiaron los precios'; end if;

  -- Lista cerrada: esto es todo lo de RX que cada rol puede ejecutar.
  v_lista := array(
    select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'rx\_%' and has_function_privilege('authenticated', p.oid, 'execute')
    order by 1
  );
  if v_lista <> array(select unnest(array[
    'rx_adjuntar_pdf(uuid,text)', 'rx_clinica_activa()', 'rx_emitir(uuid,jsonb,jsonb,text)', 'rx_guardar_imagen(text,text)',
    'rx_guardar_perfil(jsonb)', 'rx_listar(text,integer)', 'rx_mi_perfil()', 'rx_pdf_adjunto(text)',
    'rx_precios_publicos(text)', 'rx_preparar_envio(uuid,text)'
  ]) order by 1) then
    raise exception '6. authenticated ejecuta de más o de menos: %', v_lista;
  end if;
  v_lista := array(
    select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'rx\_%' and has_function_privilege('anon', p.oid, 'execute')
  );
  if v_lista <> array['rx_precios_publicos(text)'] then raise exception '6. anon ejecuta de más: %', v_lista; end if;

  -- El médico no recibe el enlace por ningún lado.
  perform pg_temp.como(v_g1, format('select public.rx_adjuntar_pdf(%L::uuid, %L)', v_r1, v_m1 || '/recipes/' || v_r1 || '.pdf'));
  foreach v_txt in array array[
    'select public.rx_listar()', 'select public.rx_mi_perfil()',
    format('select public.rx_preparar_envio(%L::uuid, %L)', v_r1, 'paciente@example.com'),
    format('select public.rx_adjuntar_pdf(%L::uuid, %L)', v_r1, v_m1 || '/recipes/' || v_r1 || '.pdf')
  ] loop
    v_res := pg_temp.como(v_g1, v_txt);
    if position(v_token in v_res::text) > 0 or v_res::text ~* '(token_precios|hay_precios|zzfarmacia)' then
      raise exception '6. el médico recibe el enlace por %: %', v_txt, v_res;
    end if;
  end loop;

  -- Lo que emita el médico no puede traer farmacias ni precios: se guardan cuatro claves.
  v_r1 := gen_random_uuid();
  perform pg_temp.como(v_g1, format(
    'select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, %L)', v_r1, '{"nombre": "Otro"}',
    '[{"medicamento": "Zzamoxi 500 mg", "farmacia": "Zzfarmacia Dos", "precio": 0.01}]', ''));
  if (select medicamentos -> 0 from public.rx_recipes where id = v_r1) ?| array['farmacia', 'precio'] then raise exception '6. se guardó lo que no debía'; end if;

  -- La secretaria tampoco entra.
  perform pg_temp.espera_fallo('6. la secretaria', 'authenticated', v_c1,
    format('select public.rx_preparar_envio(%L::uuid, %L)', v_r1, 'a@example.com'), '42501');

  -- La service_role sí carga: es la que usaría un panel de administración.
  foreach v_sig in array array[
    'public.rx_cargar_precios(text, text, jsonb)', 'public.rx_agregar_farmacia(text)',
    'public.rx_datos_precios_envio(uuid)', 'public.rx_recalcular_tokens()'
  ] loop
    if not has_function_privilege('service_role', v_sig, 'execute') then raise exception '6. la service_role debía poder: %', v_sig; end if;
  end loop;
end;
$$;

set constraints all immediate;

rollback;
