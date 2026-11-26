-- ============================================================================
-- Helios — Helios Lab (20261126120000 … 20261126120400)
--
--   bash supabase/tests/run.sh lab_smoke
--
-- Se comprueba que:
--   1. `helios_lab_habilitado` sigue el modo (apagado / prueba / todos) y quien
--      no es personal de la clínica no entra (42501).
--   2. `lab_precios`: base + Cargo Helios + comisión del médico; solo el
--      gerente cambia su comisión.
--   3. `lab_muestra_registrar`: copia los montos, cobra en bolívares a la tasa
--      BCV de hoy, es idempotente, rechaza la referencia repetida, el WhatsApp
--      inválido y la captura de otra clínica, y escribe el `uso` del kit.
--   4. El lector: `lector_lab_tomar` / `lector_lab_leido` (lo que lee el modelo
--      tal cual) deja el pago en `cuadra` o `para_revisar`; `lector_lab_fallo`
--      reintenta.
--   5. El equipo confirma los pagos cuadrados y rechaza los dudosos.
--   6. `admin_lab_ruta_armar` arma consultorio + laboratorio; el driver
--      completa las paradas (muestras, kits `entrega`, pedidos) y es
--      idempotente; la ruta se cierra sola.
--   7. Correcciones a mano del estado, por pagar y ganancia.
--   8. `lab_kit_movimientos` es append-only y el driver no lee el resumen.
--
-- No manda nada: `helios_lector_despertar` se sustituye por un no-op dentro de
-- la transacción (la extensión `http` no se deshace con el rollback).
-- ============================================================================

begin;

-- @ayudas

-- Nada de HTTP en la prueba: el despertador del lector no hace nada.
create or replace function public.helios_lector_despertar()
returns boolean language sql as $$ select false $$;

do $$
declare
  v_super   uuid := pg_temp.prueba_admin();
  v_op      uuid := gen_random_uuid();
  v_driver  uuid := gen_random_uuid();
  v_doc     uuid := gen_random_uuid();
  v_caj     uuid := gen_random_uuid();
  v_fuera   uuid := gen_random_uuid();
  v_doc2    uuid := gen_random_uuid();  -- gerente de OTRA clínica
  v_br      uuid;
  v_mt      uuid;  -- clínica de prueba (is_test)
  v_mr      uuid;  -- clínica real
  v_bt      uuid;
  v_lab     uuid;
  v_ex      uuid;
  v_hoy     date := public.helios_business_date(now());
  v_state   text;
  v_j       jsonb;
  v_n       integer;
  v_m1      uuid;
  v_m2      uuid;
  v_m3      uuid;
  v_l1      uuid;
  v_ruta    jsonb;
  v_par_c   uuid;
  v_par_l   uuid;
  v_ped     jsonb;
  v_bool    boolean;
  v_clave   text := 'lab-' || gen_random_uuid();
  v_path1   text;
  v_path2   text;
  v_path3   text;
  v_row     record;
begin
  -- ── Preparación ──────────────────────────────────────────────────────────
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'lab-' || u || '@prueba.helios.test', now(), now(), now()
    from unnest(array[v_op, v_driver, v_doc, v_caj, v_fuera, v_doc2]) u;
  insert into public.platform_admins (user_id, role, full_name, is_active) values
    (v_op, 'operador', 'Operador Lab', true),
    (v_driver, 'driver', 'Driver Lab', true);

  insert into public.merchants (name, is_test) values ('Dra. Lab Prueba', true) returning id into v_mt;
  insert into public.merchants (name, is_test) values ('Dr. Lab Real', false) returning id into v_mr;
  select id into v_bt from public.merchant_branches where merchant_id = v_mt and is_default;
  update public.merchant_branches set address = 'Av. Prueba, Caracas' where id = v_bt;
  select id into v_br from public.merchant_branches where merchant_id = v_mr and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values (v_doc2, v_mr, v_br, 'gerente');
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_doc, v_mt, v_bt, 'gerente'),
    (v_caj, v_mt, v_bt, 'cajero');

  insert into public.exchange_rates (source, rate, effective_date)
  values ('BCV', 50.000000, v_hoy)
  on conflict (source, effective_date) do update set rate = excluded.rate;

  insert into public.lab_laboratorios (nombre, direccion, telefono) values ('Laboratorio de Prueba', 'Calle Lab', '+582125550000')
  returning id into v_lab;
  insert into public.lab_examenes (codigo, nombre, kit_tipo) values ('PRUEBA-HEM', 'Hematología de prueba', 'sangre')
  returning id into v_ex;
  insert into public.lab_precios (laboratorio_id, examen_id, base_usd) values (v_lab, v_ex, 20);

  -- Siembra: Lab nace apagado con cargo 15.
  if (select modo from public.lab_ajustes where id) <> 'apagado' then
    raise exception '0. Lab no nace apagado';
  end if;

  set local role authenticated;

  -- ── 1. habilitado por modo ───────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_doc::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  if (public.lab_mi_acceso(v_mt) ->> 'habilitado')::boolean then
    raise exception '1. apagado: no debe estar habilitado';
  end if;
  v_state := null;
  begin perform public.lab_precios(v_mt);
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '42501' then raise exception '1. apagado: lab_precios debe dar 42501, dio %', v_state; end if;

  -- El driver no cambia los ajustes; el super admin sí.
  perform set_config('request.jwt.claims', json_build_object('sub', v_driver::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_state := null;
  begin perform public.admin_lab_ajustes_set('prueba', 15);
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '42501' then raise exception '1. el driver no cambia ajustes (%)', v_state; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_lab_ajustes_set('prueba', 15);
  perform set_config('request.jwt.claims', json_build_object('sub', v_doc::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  if not (public.lab_mi_acceso(v_mt) ->> 'habilitado')::boolean then
    raise exception '1. prueba: la clínica de prueba debe estar habilitada';
  end if;
  if public.lab_mi_acceso(v_mt) ->> 'rol' <> 'gerente' then raise exception '1. rol del gerente'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_fuera::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  if (public.lab_mi_acceso(v_mt) ->> 'habilitado')::boolean then
    raise exception '1. quien no es personal no entra';
  end if;
  v_state := null;
  begin perform public.lab_mis_kits(v_mt);
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '42501' then raise exception '1. un ajeno debe dar 42501, dio %', v_state; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  reset role;
  if public.helios_lab_habilitado(v_mr) then raise exception '1. prueba: la clínica real no debe estar habilitada'; end if;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_lab_ajustes_set('todos', 15);
  reset role;
  if not public.helios_lab_habilitado(v_mr) then raise exception '1. todos: la clínica real debe estar habilitada'; end if;
  set local role authenticated;

  -- ── 2. precios y comisión ────────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_caj::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_state := null;
  begin perform public.lab_comision_set(v_mt, v_ex, 5);
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '42501' then raise exception '2. el cajero no fija comisión (%)', v_state; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_doc::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.lab_comision_set(v_mt, v_ex, 5);
  select * into v_row from public.lab_precios(v_mt) where examen_id = v_ex;
  if v_row.base_usd <> 20 or v_row.cargo_helios_usd <> 15 or v_row.comision_usd <> 5 or v_row.precio_usd <> 40 then
    raise exception '2. precios: % / % / % / %', v_row.base_usd, v_row.cargo_helios_usd, v_row.comision_usd, v_row.precio_usd;
  end if;
  v_j := public.lab_muestra_cotizar(v_mt, v_ex, v_lab);
  if (v_j ->> 'precio_usd')::numeric <> 40 or (v_j ->> 'monto_ves')::numeric <> 2000 or (v_j ->> 'tasa_bcv')::numeric <> 50 then
    raise exception '2. cotización: %', v_j;
  end if;

  -- ── 3. registrar ─────────────────────────────────────────────────────────
  v_path1 := v_mt || '/' || gen_random_uuid() || '.jpg';
  v_path2 := v_mt || '/' || gen_random_uuid() || '.png';
  v_path3 := v_mt || '/' || gen_random_uuid() || '.jpg';

  v_j := public.lab_muestra_registrar(v_mt, v_ex, v_lab, 'Paciente Uno', '0414-5551111', null,
                                      '00012345678', 'BNC', v_path1, v_clave);
  v_m1 := (v_j ->> 'id')::uuid;
  if (v_j ->> 'precio_usd')::numeric <> 40 or (v_j ->> 'monto_ves')::numeric <> 2000
     or v_j ->> 'pago_estado' <> 'por_leer' or (v_j ->> 'kits_restantes')::integer <> -1
     or v_j ->> 'codigo' !~ '^L-[0-9]{6}$' then
    raise exception '3. registrar: %', v_j;
  end if;
  -- Idempotente.
  v_j := public.lab_muestra_registrar(v_mt, v_ex, v_lab, 'Paciente Uno', '0414-5551111', null,
                                      '00012345678', 'BNC', v_path1, v_clave);
  if (v_j ->> 'id')::uuid <> v_m1 then raise exception '3. la misma clave debe dar la misma muestra'; end if;

  -- Referencia repetida con otra clave (aunque cambien los ceros de adelante... no: otra cadena de dígitos).
  v_state := null;
  begin perform public.lab_muestra_registrar(v_mt, v_ex, v_lab, 'Otro', '+584145552222', null,
                                             '00012345678', 'BNC', null, 'otra-' || v_clave);
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '23505' then raise exception '3. referencia repetida debe dar 23505, dio %', v_state; end if;
  -- WhatsApp inválido.
  v_state := null;
  begin perform public.lab_muestra_registrar(v_mt, v_ex, v_lab, 'Otro', '12345', null,
                                             '99887766', 'BNC', null, 'wa-' || v_clave);
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '22023' then raise exception '3. whatsapp inválido debe dar 22023, dio %', v_state; end if;
  -- Captura de otra clínica.
  v_state := null;
  begin perform public.lab_muestra_registrar(v_mt, v_ex, v_lab, 'Otro', '+584145552222', null,
                                             '99887766', 'BNC', v_mr || '/x.jpg', 'ruta-' || v_clave);
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '22023' then raise exception '3. captura ajena debe dar 22023, dio %', v_state; end if;

  v_j := public.lab_muestra_registrar(v_mt, v_ex, v_lab, 'Paciente Dos', '+584145552222', 'dos@correo.test',
                                      '55443322', 'Mercantil', v_path2, 'dos-' || v_clave);
  v_m2 := (v_j ->> 'id')::uuid;
  -- Sin captura: nace para_revisar.
  v_j := public.lab_muestra_registrar(v_mt, v_ex, v_lab, 'Paciente Tres', '+584145553333', null,
                                      '77665544', null, null, 'tres-' || v_clave);
  v_m3 := (v_j ->> 'id')::uuid;
  if v_j ->> 'pago_estado' <> 'para_revisar' then raise exception '3. sin captura debe nacer para_revisar'; end if;

  reset role;
  select count(*) into v_n from public.lab_kit_movimientos where tipo = 'uso' and merchant_id = v_mt and kit_tipo = 'sangre';
  if v_n <> 3 then raise exception '3. debe haber 3 usos de kit, hay %', v_n; end if;
  select count(*) into v_n from public.lab_comprobante_lecturas where status = 'pendiente' and muestra_id in (v_m1, v_m2);
  if v_n <> 2 then raise exception '3. debe haber 2 lecturas pendientes, hay %', v_n; end if;
  if (select mime from public.lab_comprobante_lecturas where muestra_id = v_m2) <> 'image/png' then
    raise exception '3. el mime sale de la extensión';
  end if;

  -- ── 4. el lector ─────────────────────────────────────────────────────────
  select count(*) into v_n from public.lector_lab_tomar(10);
  if v_n <> 2 then raise exception '4. lector_lab_tomar debe tomar 2, tomó %', v_n; end if;
  select id into v_l1 from public.lab_comprobante_lecturas where muestra_id = v_m1;
  -- m1: cuadra (referencia con ceros de adelante, monto en formato venezolano).
  v_j := public.lector_lab_leido(v_l1, jsonb_build_object(
    'es_comprobante', true, 'estado', 'exitosa', 'metodo', 'pago_movil', 'referencia', '0012345678',
    'monto_texto', 'Bs. 2.000,00', 'fecha', to_char(v_hoy, 'YYYY-MM-DD')));
  if (v_j ->> 'cuadra')::boolean is not true then raise exception '4. m1 debía cuadrar: %', v_j; end if;
  if (select pago_estado from public.lab_muestras where id = v_m1) <> 'cuadra' then raise exception '4. m1 pago_estado'; end if;
  -- m2: el monto no cuadra.
  v_j := public.lector_lab_leido((select id from public.lab_comprobante_lecturas where muestra_id = v_m2), jsonb_build_object(
    'es_comprobante', true, 'estado', 'exitosa', 'referencia', '55443322', 'monto_texto', '1.000,00'));
  if (v_j ->> 'cuadra')::boolean is not false then raise exception '4. m2 no debía cuadrar: %', v_j; end if;
  if (select pago_estado from public.lab_muestras where id = v_m2) <> 'para_revisar' then raise exception '4. m2 pago_estado'; end if;
  -- Leer dos veces no repite.
  v_j := public.lector_lab_leido(v_l1, '{}'::jsonb);
  if (v_j ->> 'ok')::boolean then raise exception '4. una lectura ya hecha no se vuelve a leer'; end if;
  -- Fallo: una lectura nueva se reintenta.
  insert into public.lab_comprobante_lecturas (muestra_id, storage_path, status, attempts)
  values (v_m3, v_mt || '/falla.jpg', 'leyendo', 1) returning id into v_l1;
  if public.lector_lab_fallo(v_l1, 'prueba') <> 'pendiente' then raise exception '4. el primer fallo se reintenta'; end if;
  update public.lab_comprobante_lecturas set status = 'leyendo', attempts = 3 where id = v_l1;
  if public.lector_lab_fallo(v_l1, 'prueba') <> 'fallida' then raise exception '4. el tercer fallo cierra'; end if;
  if public.helios_lab_monto_de_texto('5.442,41') <> 5442.41 or public.helios_lab_monto_de_texto('1250.50') <> 1250.50
     or public.helios_lab_monto_de_texto('Bs 100') <> 100 then
    raise exception '4. helios_lab_monto_de_texto';
  end if;

  -- ── 5. el equipo confirma y rechaza ──────────────────────────────────────
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_lab_pagos_confirmar_cuadrados(array[v_m1, v_m2]);
  if (v_j ->> 'confirmados')::integer <> 1 then raise exception '5. solo m1 estaba cuadrada: %', v_j; end if;
  perform public.admin_lab_pago_revisar(v_m2, false, 'La referencia no aparece');
  perform public.admin_lab_pago_revisar(v_m3, true, null);
  reset role;
  if (select pago_estado from public.lab_muestras where id = v_m1) <> 'verificado'
     or (select pago_estado from public.lab_muestras where id = v_m2) <> 'rechazado'
     or (select pago_estado from public.lab_muestras where id = v_m3) <> 'verificado' then
    raise exception '5. estados de pago';
  end if;

  -- ── 6. la ruta ───────────────────────────────────────────────────────────
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_caj::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_ped := public.lab_kits_pedir(v_mt, 'orina', 3, 'urgente');
  v_state := null;
  begin perform public.lab_ruta_del_dia(v_hoy);
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '42501' then raise exception '6. el cajero no lee la ruta (%)', v_state; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_ruta := public.admin_lab_ruta_armar(v_hoy);
  if jsonb_array_length(v_ruta -> 'paradas') <> 2
     or v_ruta -> 'paradas' -> 0 ->> 'tipo' <> 'consultorio'
     or v_ruta -> 'paradas' -> 1 ->> 'tipo' <> 'laboratorio' then
    raise exception '6. la ruta debe tener consultorio y laboratorio: %', v_ruta;
  end if;
  v_par_c := (v_ruta -> 'paradas' -> 0 ->> 'id')::uuid;
  v_par_l := (v_ruta -> 'paradas' -> 1 ->> 'id')::uuid;
  if jsonb_array_length(v_ruta -> 'paradas' -> 0 -> 'muestras') <> 3 then raise exception '6. el consultorio retira 3 muestras'; end if;
  if v_ruta -> 'paradas' -> 0 ->> 'direccion' <> 'Av. Prueba, Caracas' then raise exception '6. dirección del consultorio'; end if;
  -- Kits: sangre bajo el mínimo (-3 < 5 → faltan 8); orina: el pedido (3) o el mínimo (5), el mayor.
  if not exists (select 1 from jsonb_array_elements(v_ruta -> 'paradas' -> 0 -> 'kits_a_dejar') k
                  where k ->> 'kit_tipo' = 'sangre' and (k ->> 'cantidad')::integer = 8)
     or not exists (select 1 from jsonb_array_elements(v_ruta -> 'paradas' -> 0 -> 'kits_a_dejar') k
                     where k ->> 'kit_tipo' = 'orina' and (k ->> 'cantidad')::integer = 5) then
    raise exception '6. kits a dejar: %', v_ruta -> 'paradas' -> 0 -> 'kits_a_dejar';
  end if;
  -- Reordenar y volver.
  perform public.admin_lab_parada_mover(v_par_l, 1);
  if (public.lab_ruta_del_dia(v_hoy) -> 'paradas' -> 0 ->> 'id')::uuid <> v_par_l then raise exception '6. mover'; end if;
  perform public.admin_lab_parada_mover(v_par_l, 2);
  -- Ajustar kits: sangre 5.
  perform public.admin_lab_parada_kits(v_par_c, 'sangre', 5);
  perform public.admin_lab_parada_kits(v_par_c, 'biopsia', 0);  -- el mínimo de biopsia también la pedía
  perform public.admin_lab_ruta_iniciar(v_hoy);

  -- El driver ve y completa.
  perform set_config('request.jwt.claims', json_build_object('sub', v_driver::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  if public.lab_ruta_del_dia(v_hoy) -> 'ruta' ->> 'estado' <> 'en_curso' then raise exception '6. la ruta debe estar en curso'; end if;
  v_j := public.lab_parada_completar(v_par_c, 'Retiradas');
  if (v_j ->> 'muestras')::integer <> 3 or (v_j ->> 'kits')::integer <> 10 then raise exception '6. completar consultorio: %', v_j; end if;
  v_j := public.lab_parada_completar(v_par_c, null);
  if (v_j ->> 'ya_completada')::boolean is not true then raise exception '6. completar dos veces debe ser idempotente'; end if;
  reset role;
  select count(*) into v_n from public.lab_kit_movimientos where tipo = 'entrega' and parada_id = v_par_c;
  if v_n <> 2 then raise exception '6. debe haber 2 entregas (sangre y orina), hay %', v_n; end if;
  if public.helios_lab_stock_medico(v_mt, 'sangre') <> 2 then raise exception '6. stock sangre del médico: %', public.helios_lab_stock_medico(v_mt, 'sangre'); end if;
  if (select estado from public.lab_kit_pedidos where id = (v_ped ->> 'id')::uuid) <> 'entregado' then raise exception '6. pedido entregado'; end if;
  if (select count(*) from public.lab_muestras where id in (v_m1, v_m2, v_m3) and estado = 'retirada') <> 3 then raise exception '6. muestras retiradas'; end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_driver::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.lab_parada_completar(v_par_l, null);
  if (v_j ->> 'muestras')::integer <> 3 or v_j ->> 'ruta_estado' <> 'cerrada' then raise exception '6. completar laboratorio: %', v_j; end if;
  v_state := null;
  begin perform public.admin_lab_resumen();
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '42501' then raise exception '8. el driver no lee el resumen (%)', v_state; end if;
  v_state := null;
  begin perform public.admin_lab_muestras();
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '42501' then raise exception '8. el driver no lee las muestras (%)', v_state; end if;
  reset role;
  if (select count(*) from public.lab_muestras where id in (v_m1, v_m2, v_m3) and estado = 'en_laboratorio') <> 3 then
    raise exception '6. muestras en laboratorio';
  end if;

  -- ── 7. correcciones, por pagar y ganancia ────────────────────────────────
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_lab_muestra_estado(v_m1, 'resultado_recibido', null, null);
  v_state := null;
  begin perform public.admin_lab_muestra_estado(v_m1, 'resultado_entregado', null, null);
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '22023' then raise exception '7. entregar sin canal debe dar 22023, dio %', v_state; end if;
  perform public.admin_lab_muestra_estado(v_m1, 'resultado_entregado', 'correo', null);
  v_j := public.admin_lab_muestra(v_m1);
  if v_j -> 'muestra' ->> 'estado' <> 'resultado_entregado' or v_j -> 'muestra' ->> 'resultado_canal' <> 'correo'
     or jsonb_array_length(v_j -> 'historia') < 2 or v_j -> 'lectura' is null then
    raise exception '7. detalle de la muestra: %', v_j;
  end if;

  -- Una entrada de kits es idempotente por clave.
  select k.stock_helios into v_n from public.admin_lab_kits() k where k.tipo = 'biopsia';
  perform public.admin_lab_kit_movimiento('entrada', 'biopsia', 7, null, 'prueba', 'kit-' || v_clave);
  perform public.admin_lab_kit_movimiento('entrada', 'biopsia', 7, null, 'prueba', 'kit-' || v_clave);
  if (select k.stock_helios from public.admin_lab_kits() k where k.tipo = 'biopsia') <> v_n + 7 then
    raise exception '7. la entrada de kits con la misma clave debe contar una vez';
  end if;
  v_state := null;
  begin perform public.admin_lab_kit_movimiento(null, 'biopsia', 7, null, 'prueba', 'kit-nulo-' || v_clave);
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '22023' then raise exception '7. tipo nulo debe dar 22023, dio %', v_state; end if;

  v_j := public.admin_lab_ganancia(v_hoy, v_hoy);
  if (v_j -> 'totales' ->> 'muestras')::integer <> 2 or (v_j -> 'totales' ->> 'cargo_helios_usd')::numeric <> 30
     or (v_j -> 'totales' ->> 'cobrado_usd')::numeric <> 80 then
    raise exception '7. ganancia: %', v_j;
  end if;
  v_j := public.admin_lab_por_pagar();
  if not exists (select 1 from jsonb_array_elements(v_j -> 'medicos') x
                  where (x ->> 'merchant_id')::uuid = v_mt and (x ->> 'comision_usd')::numeric = 10) then
    raise exception '7. por pagar: %', v_j;
  end if;
  v_state := null;
  begin perform public.admin_lab_marcar_pagado('comision', array[v_m1], 'REF-1');
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '42501' then raise exception '7. el operador no marca pagos (%)', v_state; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_lab_marcar_pagado('comision', array[v_m1, v_m3], 'REF-1');
  if (v_j ->> 'marcadas')::integer <> 2 then raise exception '7. marcadas: %', v_j; end if;
  v_j := public.admin_lab_resumen();
  if (v_j -> 'muestras_por_estado' ->> 'resultado_entregado')::integer <> 1 then raise exception '7. resumen: %', v_j; end if;
  reset role;
  if (select count(*) from audit.admin_actions where action like 'lab.%') < 8 then
    raise exception '7. las acciones del equipo deben quedar en la bitácora';
  end if;

  -- Anular: solo antes del retiro.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_doc::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_state := null;
  begin perform public.lab_muestra_anular(v_mt, v_m2, 'Se equivocó');
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '22023' then raise exception '7. no se anula una muestra retirada (%)', v_state; end if;
  v_j := public.lab_muestra_registrar(v_mt, v_ex, v_lab, 'Paciente Cuatro', '+584145554444', null,
                                      '11223344', null, null, 'cuatro-' || v_clave);
  perform public.lab_muestra_anular(v_mt, (v_j ->> 'id')::uuid, 'Se equivocó');
  -- Anulada, su referencia queda libre.
  perform public.lab_muestra_registrar(v_mt, v_ex, v_lab, 'Paciente Cinco', '+584145555555', null,
                                       '11223344', null, null, 'cinco-' || v_clave);

  -- Otra clínica (con Lab habilitado) no ve ni toca lo de la primera.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_doc2::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  if (select count(*) from public.lab_mis_muestras(v_mr)) <> 0 then raise exception '8. otra clínica ve muestras ajenas'; end if;
  if (select comision_usd from public.lab_precios(v_mr) where examen_id = v_ex) <> 0 then
    raise exception '8. otra clínica ve la comisión de la primera';
  end if;
  v_state := null;
  begin perform public.lab_muestra_anular(v_mr, v_m1, 'ajena');
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from 'P0002' then raise exception '8. anular una muestra ajena debe dar P0002, dio %', v_state; end if;
  v_state := null;
  begin perform public.lab_mis_muestras(v_mt);
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '42501' then raise exception '8. leer las muestras de otra clínica debe dar 42501, dio %', v_state; end if;

  -- ── 8. el libro de kits es append-only ───────────────────────────────────
  reset role;
  v_state := null;
  begin update public.lab_kit_movimientos set cantidad = 99 where tipo = 'uso';
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '55000' then raise exception '8. update de movimientos debe fallar (%)', v_state; end if;
  v_state := null;
  begin delete from public.lab_kit_movimientos where tipo = 'uso';
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '55000' then raise exception '8. delete de movimientos debe fallar (%)', v_state; end if;

  -- Las tablas no se leen directo.
  set local role authenticated;
  v_state := null;
  begin perform 1 from public.lab_muestras limit 1;
  exception when others then get stacked diagnostics v_state = returned_sqlstate; end;
  if v_state is distinct from '42501' then raise exception '8. lab_muestras no se lee directo (%)', v_state; end if;
  reset role;
end $$;

set constraints all immediate;

rollback;
