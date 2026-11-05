-- ============================================================================
-- RX — Los récipes digitales (20261105200000)
--
--   bash supabase/tests/run.sh rx_smoke
--
-- Todo con un merchant y usuarios de prueba, dentro de la transacción. No llama
-- a nada que salga por HTTP: `rx-enviar` manda el correo, no la base.
--
--   1. El perfil: todas las claves, '' en vez de null, sin crear la fila.
--   2. Las correcciones pisan los datos y al vaciarlas vuelve el de Helios.
--   3. La secretaria y quien no es de ninguna clínica reciben 42501.
--   4. La ruta de imagen debe ser de su clínica y de su tipo.
--   5. Sin firma no se emite. El número sube, por clínica. Reemitir no gasta.
--   6. Las validaciones de rx_emitir, y solo se guardan las cuatro claves.
--   7. Otra clínica no ve, ni adjunta, ni envía, ni reemite.
--   8. El PDF, el envío y la búsqueda.
--   9. El tope diario, y lo de ayer no cuenta.
--  10. anon no ejecuta; authenticated no lee las tablas ni marca el resultado.
--  11. El bucket: privado y cada clínica en su carpeta.
-- ============================================================================

begin;
-- @ayudas

-- Corre `p_sql` con ese rol y esas claims; devuelve lo que devuelva la consulta.
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

-- Corre `p_sql` y devuelve «sqlstate: mensaje» si falla, o null si no falló.
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
    -- El bloque se deshizo: el rol ya volvió al de antes.
    return sqlstate || ': ' || sqlerrm;
  end;
end;
$$;

-- Comprueba que `p_sql` falla con ese código y, si se da, ese mensaje.
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

create function pg_temp.sql_emitir(p_id uuid, p_nombre text default 'Pedro Pérez', p_doc text default 'V12345678')
returns text
language sql
as $$
  select format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, %L)',
    p_id,
    jsonb_build_object('nombre', p_nombre, 'documento', p_doc, 'edad', '40', 'correo', 'pedro@example.com'),
    jsonb_build_array(jsonb_build_object('medicamento', 'Amoxicilina 500 mg', 'presentacion', 'Cápsulas', 'cantidad', '1 caja', 'indicacion', '1 cada 8 horas')),
    'Reposo');
$$;

do $$
declare
  v_g1   uuid := gen_random_uuid();
  v_c1   uuid := gen_random_uuid();
  v_g2   uuid := gen_random_uuid();
  v_nadie uuid := gen_random_uuid();
  v_m1   uuid;
  v_m2   uuid;
  v_b1   uuid;
  v_b2   uuid;
  v_r1   uuid := gen_random_uuid();
  v_r2   uuid := gen_random_uuid();
  v_r3   uuid := gen_random_uuid();
  v_res  jsonb;
  v_n    integer;
  v_txt  text;
  v_sig  text;
  v_clave text;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'rx-' || u || '@prueba.helios.test', now(), now()
  from unnest(array[v_g1, v_c1, v_g2, v_nadie]) u;

  insert into public.merchants (name, tax_id, owner_name, doctor_title, specialty, owner_document, mpps_number,
                                phone, email, address, city, logo_url)
  values ('Consultorio Rx Uno', 'J-509876611', 'Ana Rx Prueba', 'Dra.', 'Dermatología', 'V11222333', 'MPPS-111',
          '02125550001', 'ana.rx@example.com', 'Av. Prueba 1', 'Caracas', 'https://example.com/logo.png')
  returning id into v_m1;
  insert into public.merchants (name, tax_id, owner_name, doctor_title, specialty, email)
  values ('Consultorio Rx Dos', 'J-509876622', 'Beto Rx Prueba', 'Dr.', 'Odontología', 'beto.rx@example.com')
  returning id into v_m2;
  select id into v_b1 from public.merchant_branches where merchant_id = v_m1 and is_default;
  select id into v_b2 from public.merchant_branches where merchant_id = v_m2 and is_default;

  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_g1, v_m1, v_b1, 'gerente'),
    (v_c1, v_m1, v_b1, 'cajero'),
    (v_g2, v_m2, v_b2, 'gerente');

  -- --- 1. El perfil ---------------------------------------------------------
  v_res := pg_temp.como(v_g1, 'select public.rx_mi_perfil()');
  foreach v_clave in array array['merchant_id', 'nombre', 'especialidad', 'cedula', 'mpps', 'colegio', 'telefono',
                                 'correo', 'direccion', 'ciudad', 'consultorio', 'logo_helios_url', 'firma_path', 'logo_path'] loop
    if not (v_res ? v_clave) or jsonb_typeof(v_res -> v_clave) <> 'string' then
      raise exception '1. falta la clave % (o no es texto): %', v_clave, v_res;
    end if;
  end loop;
  if v_res ->> 'nombre' <> 'Dra. Ana Rx Prueba' then raise exception '1. el nombre: %', v_res; end if;
  if v_res ->> 'cedula' <> 'V11222333' or v_res ->> 'mpps' <> 'MPPS-111' then raise exception '1. los datos: %', v_res; end if;
  if v_res ->> 'colegio' <> '' or v_res ->> 'firma_path' <> '' then raise exception '1. null debía ser vacío: %', v_res; end if;
  if v_res ->> 'consultorio' <> 'Consultorio Rx Uno' then raise exception '1. el consultorio: %', v_res; end if;
  if v_res ->> 'logo_helios_url' <> 'https://example.com/logo.png' then raise exception '1. el logo: %', v_res; end if;
  if exists (select 1 from public.rx_perfiles where merchant_id = v_m1) then
    raise exception '1. rx_mi_perfil no debía crear la fila';
  end if;

  -- --- 2. Las correcciones ---------------------------------------------------
  v_res := pg_temp.como(v_g1, $q$select public.rx_guardar_perfil('{"mpps": "  999  ", "nombre": "Otro Nombre", "colegio": "CM-5"}')$q$);
  if v_res ->> 'mpps' <> '999' or v_res ->> 'colegio' <> 'CM-5' then raise exception '2. no pisó: %', v_res; end if;
  if v_res ->> 'nombre' <> 'Dra. Ana Rx Prueba' then raise exception '2. el nombre no se edita: %', v_res; end if;

  -- La clave que no viene se queda; la vacía vuelve al dato de Helios.
  v_res := pg_temp.como(v_g1, $q$select public.rx_guardar_perfil('{"mpps": ""}')$q$);
  if v_res ->> 'mpps' <> 'MPPS-111' then raise exception '2. al vaciar debía volver el de Helios: %', v_res; end if;
  if v_res ->> 'colegio' <> 'CM-5' then raise exception '2. la que no viene se queda: %', v_res; end if;

  -- Lo mismo que ya dice Helios no es una corrección.
  perform pg_temp.como(v_g1, $q$select public.rx_guardar_perfil('{"especialidad": "Dermatología", "correo": "ANA.RX@example.com"}')$q$);
  if (select especialidad is not null or correo is not null from public.rx_perfiles where merchant_id = v_m1) then
    raise exception '2. copiar el dato de Helios no debía guardarse como corrección';
  end if;

  perform pg_temp.espera_fallo('2. correo inválido', 'authenticated', v_g1,
    $q$select public.rx_guardar_perfil('{"correo": "no-es-correo"}')$q$, '22023', 'correo');
  perform pg_temp.espera_fallo('2. tope de longitud', 'authenticated', v_g1,
    format('select public.rx_guardar_perfil(%L)', jsonb_build_object('ciudad', repeat('x', 121))), '22023', 'ciudad');
  perform pg_temp.espera_fallo('2. no es un objeto', 'authenticated', v_g1,
    $q$select public.rx_guardar_perfil('[]')$q$, '22023');

  -- --- 3. La secretaria y quien no es de ninguna clínica ---------------------
  foreach v_sig in array array[
    'select public.rx_mi_perfil()',
    $q$select public.rx_guardar_perfil('{}')$q$,
    $q$select public.rx_guardar_imagen('firma', null)$q$,
    format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, null)', v_r3, '{}', '[]'),
    format('select public.rx_adjuntar_pdf(%L::uuid, %L)', v_r3, 'x'),
    'select public.rx_listar()',
    format('select public.rx_preparar_envio(%L::uuid, %L)', v_r3, 'a@example.com')
  ] loop
    perform pg_temp.espera_fallo('3. secretaria: ' || v_sig, 'authenticated', v_c1, v_sig, '42501', 'médico titular');
    perform pg_temp.espera_fallo('3. sin clínica: ' || v_sig, 'authenticated', v_nadie, v_sig, '42501', 'médico titular');
  end loop;

  -- --- 4. La ruta de la imagen -------------------------------------------------
  perform pg_temp.espera_fallo('4. ruta de otra clínica', 'authenticated', v_g1,
    format('select public.rx_guardar_imagen(%L, %L)', 'firma', v_m2 || '/firma/a.png'), '22023', 'Esa ruta');
  perform pg_temp.espera_fallo('4. carpeta de otro tipo', 'authenticated', v_g1,
    format('select public.rx_guardar_imagen(%L, %L)', 'firma', v_m1 || '/logo/a.png'), '22023', 'Esa ruta');
  perform pg_temp.espera_fallo('4. subir de carpeta', 'authenticated', v_g1,
    format('select public.rx_guardar_imagen(%L, %L)', 'firma', v_m1 || '/firma/../../' || v_m2 || '/firma/a.png'), '22023', 'Esa ruta');
  perform pg_temp.espera_fallo('4. tipo desconocido', 'authenticated', v_g1,
    format('select public.rx_guardar_imagen(%L, %L)', 'otro', v_m1 || '/otro/a.png'), '22023');

  -- --- 5. Emitir -----------------------------------------------------------------
  perform pg_temp.espera_fallo('5. sin firma', 'authenticated', v_g1, pg_temp.sql_emitir(v_r1), '22023', 'Sube tu firma');
  if exists (select 1 from public.rx_recipes where merchant_id = v_m1) then
    raise exception '5. sin firma no debía quedar récipe';
  end if;

  v_res := pg_temp.como(v_g1, format('select public.rx_guardar_imagen(%L, %L)', 'firma', v_m1 || '/firma/a.png'));
  if v_res ->> 'firma_path' <> v_m1 || '/firma/a.png' then raise exception '5. la firma: %', v_res; end if;
  v_res := pg_temp.como(v_g1, format('select public.rx_guardar_imagen(%L, %L)', 'logo', v_m1 || '/logo/a.png'));
  if v_res ->> 'logo_path' <> v_m1 || '/logo/a.png' or v_res ->> 'firma_path' = '' then raise exception '5. el logo: %', v_res; end if;
  v_res := pg_temp.como(v_g1, format('select public.rx_guardar_imagen(%L, null)', 'logo'));
  if v_res ->> 'logo_path' <> '' then raise exception '5. null debía quitar el logo: %', v_res; end if;

  v_res := pg_temp.como(v_g1, pg_temp.sql_emitir(v_r1));
  if (v_res ->> 'numero')::int <> 1 then raise exception '5. el primero es el 1: %', v_res; end if;
  if v_res ->> 'id' <> v_r1::text then raise exception '5. el id: %', v_res; end if;
  if v_res ->> 'fecha' <> ((now() at time zone 'America/Caracas')::date)::text then raise exception '5. la fecha: %', v_res; end if;
  if v_res -> 'paciente' ->> 'nombre' <> 'Pedro Pérez' or v_res ->> 'pdf_path' <> '' or v_res -> 'ultimo_envio' <> 'null'::jsonb then
    raise exception '5. la forma del récipe: %', v_res;
  end if;
  if (select creado_por from public.rx_recipes where id = v_r1) <> v_g1 then raise exception '5. creado_por'; end if;

  -- Reemitir con el mismo id no gasta número, aunque ya no haya firma.
  perform pg_temp.como(v_g1, format('select public.rx_guardar_imagen(%L, null)', 'firma'));
  v_res := pg_temp.como(v_g1, pg_temp.sql_emitir(v_r1, 'Otro Nombre'));
  if (v_res ->> 'numero')::int <> 1 or v_res -> 'paciente' ->> 'nombre' <> 'Pedro Pérez' then
    raise exception '5. reemitir debía devolver el mismo: %', v_res;
  end if;
  if (select ultimo_numero from public.rx_perfiles where merchant_id = v_m1) <> 1 then
    raise exception '5. reemitir no debía gastar número';
  end if;
  perform pg_temp.como(v_g1, format('select public.rx_guardar_imagen(%L, %L)', 'firma', v_m1 || '/firma/a.png'));

  v_res := pg_temp.como(v_g1, pg_temp.sql_emitir(v_r2, 'María_Gómez 100%', 'V87654321'));
  if (v_res ->> 'numero')::int <> 2 then raise exception '5. el segundo es el 2: %', v_res; end if;

  -- El correlativo es por clínica.
  perform pg_temp.como(v_g2, format('select public.rx_guardar_imagen(%L, %L)', 'firma', v_m2 || '/firma/b.png'));
  v_res := pg_temp.como(v_g2, pg_temp.sql_emitir(v_r3));
  if (v_res ->> 'numero')::int <> 1 then raise exception '5. cada clínica empieza en 1: %', v_res; end if;

  -- --- 6. Las validaciones --------------------------------------------------------
  v_n := (select ultimo_numero from public.rx_perfiles where merchant_id = v_m1);
  perform pg_temp.espera_fallo('6. sin nombre', 'authenticated', v_g1,
    format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, null)', gen_random_uuid(), '{"nombre": "  "}', '[{"medicamento": "A"}]'),
    '22023', 'nombre del paciente');
  perform pg_temp.espera_fallo('6. nombre largo', 'authenticated', v_g1,
    format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, null)', gen_random_uuid(),
           jsonb_build_object('nombre', repeat('x', 121)), '[{"medicamento": "A"}]'), '22023', 'nombre del paciente');
  perform pg_temp.espera_fallo('6. documento largo', 'authenticated', v_g1,
    format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, null)', gen_random_uuid(),
           jsonb_build_object('nombre', 'P', 'documento', repeat('1', 21)), '[{"medicamento": "A"}]'), '22023', 'documento');
  perform pg_temp.espera_fallo('6. correo inválido', 'authenticated', v_g1,
    format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, null)', gen_random_uuid(),
           '{"nombre": "P", "correo": "malo"}', '[{"medicamento": "A"}]'), '22023', 'correo');
  perform pg_temp.espera_fallo('6. sin medicamentos', 'authenticated', v_g1,
    format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, null)', gen_random_uuid(), '{"nombre": "P"}', '[]'), '22023', 'al menos un');
  perform pg_temp.espera_fallo('6. 21 medicamentos', 'authenticated', v_g1,
    format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, null)', gen_random_uuid(), '{"nombre": "P"}',
           (select jsonb_agg(jsonb_build_object('medicamento', 'M' || g)) from generate_series(1, 21) g)), '22023', '20');
  perform pg_temp.espera_fallo('6. renglón sin medicamento', 'authenticated', v_g1,
    format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, null)', gen_random_uuid(), '{"nombre": "P"}', '[{"cantidad": "1"}]'), '22023', 'Cada renglón');
  perform pg_temp.espera_fallo('6. renglón que no es objeto', 'authenticated', v_g1,
    format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, null)', gen_random_uuid(), '{"nombre": "P"}', '["A"]'), '22023');
  perform pg_temp.espera_fallo('6. indicación larga', 'authenticated', v_g1,
    format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, null)', gen_random_uuid(), '{"nombre": "P"}',
           jsonb_build_array(jsonb_build_object('medicamento', 'A', 'indicacion', repeat('x', 501)))), '22023', 'indicación');
  perform pg_temp.espera_fallo('6. indicaciones largas', 'authenticated', v_g1,
    format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, %L)', gen_random_uuid(), '{"nombre": "P"}', '[{"medicamento": "A"}]', repeat('x', 2001)),
    '22023', 'indicaciones');
  if (select ultimo_numero from public.rx_perfiles where merchant_id = v_m1) <> v_n then
    raise exception '6. un récipe rechazado no debía gastar número';
  end if;

  -- Solo las cuatro claves, sin espacios en los bordes y sin null.
  v_res := pg_temp.como(v_g1, format('select public.rx_emitir(%L::uuid, %L::jsonb, %L::jsonb, null)', gen_random_uuid(),
    '{"nombre": "  Luz  ", "documento": ""}', '[{"medicamento": "  Ibuprofeno  ", "extra": "<x>", "cantidad": null}]'));
  if v_res -> 'medicamentos' <> '[{"medicamento": "Ibuprofeno", "presentacion": "", "cantidad": "", "indicacion": ""}]'::jsonb then
    raise exception '6. los renglones: %', v_res;
  end if;
  if v_res -> 'paciente' ->> 'nombre' <> 'Luz' or v_res -> 'paciente' ->> 'documento' <> '' or v_res ->> 'indicaciones' <> '' then
    raise exception '6. el paciente: %', v_res;
  end if;

  -- --- 7. Otra clínica ---------------------------------------------------------------
  perform pg_temp.espera_fallo('7. reemitir el de otra', 'authenticated', v_g2, pg_temp.sql_emitir(v_r1), '22023', 'No se pudo emitir');
  perform pg_temp.espera_fallo('7. adjuntar al de otra', 'authenticated', v_g2,
    format('select public.rx_adjuntar_pdf(%L::uuid, %L)', v_r1, v_m2 || '/recipes/' || v_r1 || '.pdf'), 'P0002');
  perform pg_temp.espera_fallo('7. enviar el de otra', 'authenticated', v_g2,
    format('select public.rx_preparar_envio(%L::uuid, %L)', v_r1, 'a@example.com'), 'P0002');
  v_res := pg_temp.como(v_g2, 'select public.rx_listar()');
  if jsonb_array_length(v_res) <> 1 or v_res -> 0 ->> 'id' <> v_r3::text then
    raise exception '7. la otra clínica ve récipes ajenos: %', v_res;
  end if;
  v_res := pg_temp.como(v_g2, format('select public.rx_listar(%L)', 'Luz'));
  if jsonb_array_length(v_res) <> 0 then raise exception '7. la búsqueda cruza clínicas: %', v_res; end if;

  -- --- 8. El PDF, el envío y la búsqueda ----------------------------------------------
  perform pg_temp.espera_fallo('8. enviar sin PDF', 'authenticated', v_g1,
    format('select public.rx_preparar_envio(%L::uuid, %L)', v_r1, 'a@example.com'), '22023', 'PDF');
  perform pg_temp.espera_fallo('8. ruta del PDF de otro récipe', 'authenticated', v_g1,
    format('select public.rx_adjuntar_pdf(%L::uuid, %L)', v_r1, v_m1 || '/recipes/' || v_r2 || '.pdf'), '22023', 'Esa ruta');
  perform pg_temp.espera_fallo('8. ruta del PDF de otra clínica', 'authenticated', v_g1,
    format('select public.rx_adjuntar_pdf(%L::uuid, %L)', v_r1, v_m2 || '/recipes/' || v_r1 || '.pdf'), '22023', 'Esa ruta');

  v_res := pg_temp.como(v_g1, format('select public.rx_adjuntar_pdf(%L::uuid, %L)', v_r1, v_m1 || '/recipes/' || v_r1 || '.pdf'));
  if v_res ->> 'pdf_path' <> v_m1 || '/recipes/' || v_r1 || '.pdf' then raise exception '8. el PDF: %', v_res; end if;

  perform pg_temp.espera_fallo('8. correo inválido', 'authenticated', v_g1,
    format('select public.rx_preparar_envio(%L::uuid, %L)', v_r1, 'malo'), '22023', 'correo');

  v_res := pg_temp.como(v_g1, format('select public.rx_preparar_envio(%L::uuid, %L)', v_r1, ' Pedro@Example.com '));
  if v_res ->> 'correo' <> 'pedro@example.com' or (v_res ->> 'numero')::int <> 1
     or v_res ->> 'paciente_nombre' <> 'Pedro Pérez' or v_res ->> 'doctor_nombre' <> 'Dra. Ana Rx Prueba'
     or v_res ->> 'doctor_correo' <> 'ana.rx@example.com'
     or v_res ->> 'pdf_path' <> v_m1 || '/recipes/' || v_r1 || '.pdf' or v_res ->> 'envio_id' is null then
    raise exception '8. los datos del envío: %', v_res;
  end if;
  if (select estado || creado_por::text from public.rx_envios where id = (v_res ->> 'envio_id')::uuid) <> 'pendiente' || v_g1::text then
    raise exception '8. el envío debía quedar pendiente y a su nombre';
  end if;

  -- El correo corregido manda.
  perform pg_temp.como(v_g1, $q$select public.rx_guardar_perfil('{"correo": "corregido@example.com"}')$q$);
  v_res := pg_temp.como(v_g1, format('select public.rx_preparar_envio(%L::uuid, %L)', v_r1, 'pedro@example.com'));
  if v_res ->> 'doctor_correo' <> 'corregido@example.com' then raise exception '8. el correo corregido: %', v_res; end if;

  -- La service_role marca el resultado; `rx_listar` trae el último envío.
  set local role service_role;
  perform public.rx_resultado_envio((v_res ->> 'envio_id')::uuid, 'enviado', 'prov-1', null);
  reset role;
  if (select estado || provider_id from public.rx_envios where id = (v_res ->> 'envio_id')::uuid) <> 'enviadoprov-1' then
    raise exception '8. el resultado no se guardó';
  end if;
  perform pg_temp.espera_fallo('8. estado desconocido', 'service_role', null,
    format('select public.rx_resultado_envio(%L::uuid, %L, null, null)::text::jsonb', v_res ->> 'envio_id', 'otro'), '22023');
  perform pg_temp.espera_fallo('8. envío inexistente', 'service_role', null,
    format('select public.rx_resultado_envio(%L::uuid, %L, null, null)::text::jsonb', gen_random_uuid(), 'fallido'), 'P0002');

  -- Los del primero se quedan con un solo envío para ver el más reciente.
  delete from public.rx_envios where recipe_id = v_r1 and id <> (v_res ->> 'envio_id')::uuid;
  v_res := pg_temp.como(v_g1, format('select public.rx_listar(%L)', 'pedro'));
  if jsonb_array_length(v_res) <> 1 or v_res -> 0 ->> 'id' <> v_r1::text
     or v_res -> 0 -> 'ultimo_envio' ->> 'estado' <> 'enviado'
     or v_res -> 0 -> 'ultimo_envio' ->> 'correo' <> 'pedro@example.com'
     or v_res -> 0 -> 'ultimo_envio' ->> 'at' is null then
    raise exception '8. buscar por nombre, sin distinguir mayúsculas: %', v_res;
  end if;

  v_res := pg_temp.como(v_g1, format('select public.rx_listar(%L)', '87654'));
  if jsonb_array_length(v_res) <> 1 or v_res -> 0 ->> 'id' <> v_r2::text then raise exception '8. buscar por documento: %', v_res; end if;
  v_res := pg_temp.como(v_g1, format('select public.rx_listar(%L)', '000002'));
  if jsonb_array_length(v_res) <> 1 or (v_res -> 0 ->> 'numero')::int <> 2 then raise exception '8. buscar por número: %', v_res; end if;
  -- % y _ se buscan tal cual.
  v_res := pg_temp.como(v_g1, format('select public.rx_listar(%L)', '%'));
  if jsonb_array_length(v_res) <> 1 or v_res -> 0 ->> 'id' <> v_r2::text then raise exception '8. el %% no se escapó: %', v_res; end if;
  v_res := pg_temp.como(v_g1, format('select public.rx_listar(%L)', '_'));
  if jsonb_array_length(v_res) <> 1 or v_res -> 0 ->> 'id' <> v_r2::text then raise exception '8. el _ no se escapó: %', v_res; end if;

  -- Del más nuevo al más viejo, con el límite acotado.
  v_res := pg_temp.como(v_g1, 'select public.rx_listar(null, 0)');
  if jsonb_array_length(v_res) <> 1 then raise exception '8. el límite mínimo es 1: %', v_res; end if;
  v_res := pg_temp.como(v_g1, 'select public.rx_listar(null, 100000)');
  if jsonb_array_length(v_res) <> 3 or (v_res -> 0 ->> 'numero')::int <> 3 or (v_res -> 2 ->> 'numero')::int <> 1 then
    raise exception '8. el orden: %', v_res;
  end if;

  -- --- 9. El tope diario ------------------------------------------------------------------
  delete from public.rx_envios where merchant_id = v_m1;
  insert into public.rx_envios (recipe_id, merchant_id, correo, estado)
  select v_r1, v_m1, 'x@example.com', 'fallido' from generate_series(1, 59);
  perform pg_temp.como(v_g1, format('select public.rx_preparar_envio(%L::uuid, %L)', v_r1, 'pedro@example.com'));
  perform pg_temp.espera_fallo('9. el envío 61', 'authenticated', v_g1,
    format('select public.rx_preparar_envio(%L::uuid, %L)', v_r1, 'pedro@example.com'), '54000', 'tope de envíos');
  if (select count(*) from public.rx_envios where merchant_id = v_m1) <> 60 then
    raise exception '9. el envío rechazado no debía quedar anotado';
  end if;
  -- El tope de una clínica no toca a la otra.
  perform pg_temp.como(v_g2, format('select public.rx_adjuntar_pdf(%L::uuid, %L)', v_r3, v_m2 || '/recipes/' || v_r3 || '.pdf'));
  perform pg_temp.como(v_g2, format('select public.rx_preparar_envio(%L::uuid, %L)', v_r3, 'pedro@example.com'));
  -- Lo de ayer (en Caracas) no cuenta.
  update public.rx_envios set created_at = now() - interval '1 day'
   where id in (select id from public.rx_envios where merchant_id = v_m1 limit 1);
  perform pg_temp.como(v_g1, format('select public.rx_preparar_envio(%L::uuid, %L)', v_r1, 'pedro@example.com'));

  -- --- 10. Los permisos ---------------------------------------------------------------------
  foreach v_sig in array array[
    'public.rx_mi_perfil()', 'public.rx_guardar_perfil(jsonb)', 'public.rx_guardar_imagen(text, text)',
    'public.rx_emitir(uuid, jsonb, jsonb, text)', 'public.rx_adjuntar_pdf(uuid, text)',
    'public.rx_listar(text, integer)', 'public.rx_preparar_envio(uuid, text)'
  ] loop
    if has_function_privilege('anon', v_sig, 'execute') then raise exception '10. anon ejecuta %', v_sig; end if;
    if has_function_privilege('public', v_sig, 'execute') then raise exception '10. public ejecuta %', v_sig; end if;
    if not has_function_privilege('authenticated', v_sig, 'execute') then raise exception '10. authenticated no ejecuta %', v_sig; end if;
    if not (select prosecdef from pg_proc where oid = v_sig::regprocedure) then raise exception '10. % no es security definer', v_sig; end if;
  end loop;
  foreach v_sig in array array[
    'public.rx_resultado_envio(uuid, text, text, text)', 'public.rx_clinica()', 'public.rx_texto(jsonb, text, text, integer)',
    'public.rx_perfil_json(uuid)', 'public.rx_recipe_json(public.rx_recipes)'
  ] loop
    if has_function_privilege('anon', v_sig, 'execute') or has_function_privilege('authenticated', v_sig, 'execute') then
      raise exception '10. % debía estar cerrada', v_sig;
    end if;
  end loop;
  if not has_function_privilege('service_role', 'public.rx_resultado_envio(uuid, text, text, text)', 'execute') then
    raise exception '10. la service_role debía poder marcar el resultado';
  end if;

  -- De verdad, no solo en el catálogo.
  perform pg_temp.espera_fallo('10. anon: rx_mi_perfil', 'anon', null, 'select public.rx_mi_perfil()', '42501', 'permission denied');
  perform pg_temp.espera_fallo('10. anon: rx_listar', 'anon', null, 'select public.rx_listar()', '42501', 'permission denied');
  perform pg_temp.espera_fallo('10. authenticated: rx_resultado_envio', 'authenticated', v_g1,
    format('select public.rx_resultado_envio(%L::uuid, %L, null, null)::text::jsonb', gen_random_uuid(), 'enviado'), '42501', 'permission denied');

  foreach v_sig in array array['public.rx_perfiles', 'public.rx_recipes', 'public.rx_envios'] loop
    if not (select relrowsecurity from pg_class where oid = v_sig::regclass) then raise exception '10. % sin RLS', v_sig; end if;
    if exists (select 1 from pg_policy where polrelid = v_sig::regclass) then raise exception '10. % tiene políticas', v_sig; end if;
    if has_table_privilege('authenticated', v_sig, 'select') or has_table_privilege('anon', v_sig, 'select')
       or has_table_privilege('authenticated', v_sig, 'insert') or has_table_privilege('authenticated', v_sig, 'update') then
      raise exception '10. % tiene permisos para la API', v_sig;
    end if;
    perform pg_temp.espera_fallo('10. authenticated lee ' || v_sig, 'authenticated', v_g1,
      format('select count(*)::text::jsonb from %s', v_sig), '42501', 'permission denied');
    perform pg_temp.espera_fallo('10. anon lee ' || v_sig, 'anon', null,
      format('select count(*)::text::jsonb from %s', v_sig), '42501', 'permission denied');
  end loop;

  -- --- 11. El bucket --------------------------------------------------------------------------
  if not exists (select 1 from storage.buckets
                  where id = 'rx' and not public and file_size_limit = 5242880
                    and allowed_mime_types @> array['image/png', 'image/jpeg', 'application/pdf']
                    and cardinality(allowed_mime_types) = 3) then
    raise exception '11. el bucket no está como debe';
  end if;

  v_res := pg_temp.como(v_g1, format(
    'with i as (insert into storage.objects (bucket_id, name) values (%L, %L) returning 1) select count(*)::text::jsonb from i',
    'rx', v_m1 || '/recipes/prueba.pdf'));
  if v_res <> '1'::jsonb then raise exception '11. el médico debía poder subir a su carpeta'; end if;

  perform pg_temp.espera_fallo('11. subir a la carpeta de otra clínica', 'authenticated', v_g1,
    format('with i as (insert into storage.objects (bucket_id, name) values (%L, %L) returning 1) select count(*)::text::jsonb from i',
           'rx', v_m2 || '/recipes/prueba.pdf'), '42501');
  perform pg_temp.espera_fallo('11. la secretaria no sube', 'authenticated', v_c1,
    format('with i as (insert into storage.objects (bucket_id, name) values (%L, %L) returning 1) select count(*)::text::jsonb from i',
           'rx', v_m1 || '/recipes/prueba2.pdf'), '42501');

  v_txt := format('select count(*)::text::jsonb from storage.objects where bucket_id = %L', 'rx');
  if pg_temp.como(v_g1, v_txt) <> '1'::jsonb then raise exception '11. el médico debía ver su archivo'; end if;
  if pg_temp.como(v_g2, v_txt) <> '0'::jsonb then raise exception '11. otra clínica ve el archivo'; end if;
  if pg_temp.como(v_c1, v_txt) <> '0'::jsonb then raise exception '11. la secretaria ve el archivo'; end if;

  -- --- 12. Lo que dejó la revisión de seguridad ---------------------------------------------
  -- Solo las tres subcarpetas de RX.
  perform pg_temp.espera_fallo('12. una carpeta inventada', 'authenticated', v_g1,
    format('with i as (insert into storage.objects (bucket_id, name) values (%L, %L) returning 1) select count(*)::text::jsonb from i',
           'rx', v_m1 || '/lo-que-sea/x.pdf'), '42501');

  -- Quien no tiene clínica no rompe las consultas a los otros buckets.
  v_res := pg_temp.como(v_nadie, format('select count(*)::text::jsonb from storage.objects where bucket_id = %L', 'merchant-logos'));
  if v_res is null then raise exception '12. las políticas de RX estorban a los otros buckets'; end if;
  if pg_temp.como(v_nadie, 'select to_jsonb(public.rx_clinica_activa() is null)') <> 'true'::jsonb then
    raise exception '12. sin clínica debía dar null';
  end if;
  if has_function_privilege('anon', 'public.rx_clinica_activa()', 'execute')
     or has_function_privilege('anon', 'public.rx_pdf_adjunto(text)', 'execute') then
    raise exception '12. anon no debía ejecutar los ayudantes de las políticas';
  end if;

  -- El PDF de un récipe adjuntado no se reemplaza; un archivo suelto, sí.
  insert into storage.objects (bucket_id, name) values ('rx', v_m1 || '/recipes/' || v_r1 || '.pdf');
  v_res := pg_temp.como(v_g1, format(
    'with u as (update storage.objects set metadata = %L::jsonb where bucket_id = %L and name = %L returning 1) select count(*)::text::jsonb from u',
    '{}', 'rx', v_m1 || '/recipes/' || v_r1 || '.pdf'));
  if v_res <> '0'::jsonb then raise exception '12. el PDF adjuntado no debía poder cambiarse'; end if;
  v_res := pg_temp.como(v_g1, format(
    'with u as (update storage.objects set metadata = %L::jsonb where bucket_id = %L and name = %L returning 1) select count(*)::text::jsonb from u',
    '{}', 'rx', v_m1 || '/recipes/prueba.pdf'));
  if v_res <> '1'::jsonb then raise exception '12. un PDF sin adjuntar debía poder reintentarse'; end if;
  if not public.rx_pdf_adjunto(v_m1 || '/recipes/' || v_r1 || '.pdf') or public.rx_pdf_adjunto(v_m1 || '/recipes/prueba.pdf') then
    raise exception '12. rx_pdf_adjunto';
  end if;

  -- El nombre del paciente no lleva enlaces.
  perform pg_temp.espera_fallo('12. un enlace en el nombre', 'authenticated', v_g1,
    pg_temp.sql_emitir(gen_random_uuid(), 'Gana dinero https://malo.example'), '22023', 'enlace');

  -- El tope por destinatario y el tope global.
  delete from public.rx_envios where merchant_id = v_m1;
  insert into public.rx_envios (recipe_id, merchant_id, correo, estado)
  select v_r1, v_m1, 'y@example.com', 'enviado' from generate_series(1, 5);
  perform pg_temp.espera_fallo('12. el sexto a la misma dirección', 'authenticated', v_g1,
    format('select public.rx_preparar_envio(%L::uuid, %L)', v_r1, 'Y@example.com'), '54000', 'esa dirección');
  perform pg_temp.como(v_g1, format('select public.rx_preparar_envio(%L::uuid, %L)', v_r1, 'otra@example.com'));

  insert into public.rx_envios (recipe_id, merchant_id, correo, estado)
  select v_r3, v_m2, 'z' || g || '@example.com', 'enviado' from generate_series(1, 500) g;
  perform pg_temp.espera_fallo('12. el tope global', 'authenticated', v_g1,
    format('select public.rx_preparar_envio(%L::uuid, %L)', v_r1, 'una-mas@example.com'), '54000', 'más correos');

  -- Una clínica pausada o terminada se queda fuera, también en el bucket.
  update public.merchants set status = 'paused' where id = v_m1;
  perform pg_temp.espera_fallo('12. clínica pausada', 'authenticated', v_g1, 'select public.rx_mi_perfil()', '42501', 'médico titular');
  if pg_temp.como(v_g1, v_txt) <> '0'::jsonb then raise exception '12. una clínica pausada ve sus archivos'; end if;
  update public.merchants set status = 'terminated' where id = v_m1;
  perform pg_temp.espera_fallo('12. clínica terminada', 'authenticated', v_g1, 'select public.rx_listar()', '42501', 'médico titular');
end;
$$;

set constraints all immediate;

rollback;
