-- ============================================================================
-- Helios — Prueba de humo de los datos de alta para el contrato
-- (20261014000300_los_datos_de_alta_se_exportan_para_el_contrato)
--
-- 1. anon y un usuario cualquiera no leen los datos de alta.
-- 2. Un operador (personal de Helios) sí: todas las clínicas o una sola.
-- 3. La fila de una clínica nacida de la portada trae la clínica, su
--    titular, su cuenta de pago y las fechas de la solicitud.
-- 4. Una clínica sin cuenta de pago ni solicitud sale con esos campos en null.
-- 5. Una clínica que no existe da error.
-- 6. `merchant_directory` trae el titular.
--
-- No envía nada: la aprobación no se ejerce aquí (la bienvenida por WhatsApp
-- sale de ella), la solicitud se escribe aprobada directamente.
-- ============================================================================

begin;

do $$
declare
  v_operador uuid := gen_random_uuid();
  v_random   uuid := gen_random_uuid();
  v_con      uuid;
  v_sin      uuid;
  v_res      jsonb;
  v_fila     jsonb;
  v_failed   boolean;
begin
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_operador, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000191', now(), now(), now()),
    (v_random,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000192', now(), now(), now());
  insert into public.platform_admins (user_id, role, full_name) values (v_operador, 'operador', 'Operador');

  -- Una clínica completa, como queda al aprobar una solicitud de la portada.
  insert into public.merchants
    (name, legal_name, tax_id, status, category, city, specialty, mpps_number, phone, email, address,
     owner_name, owner_document, college_number, is_test)
  values
    ('Consultorio Prueba Contrato', 'Consultorio Prueba Contrato C.A.', 'J509876543', 'active', 'odontologia',
     'Caracas', 'Odontología', '98765', '+582125551234', 'contrato.prueba@example.com',
     'Av. Principal, Torre Médica, piso 3', 'Ana María Pérez', 'V12345678', 'COV-1234', true)
  returning id into v_con;

  insert into public.merchant_payout_accounts
    (merchant_id, bank, account_holder, holder_document, account_number)
  values (v_con, 'Banesco', 'Ana María Pérez', 'V12345678', '01340000000000000001');

  insert into public.merchant_applications
    (owner_name, owner_document, specialty, clinic_name, address, phone, email,
     account_holder, holder_document, bank, account_number,
     status, merchant_id, reviewed_at, created_at)
  values ('Ana María Pérez', 'V12345678', 'Odontología', 'Consultorio Prueba Contrato',
          'Av. Principal, Torre Médica, piso 3', '+582125551234', 'contrato.prueba@example.com',
          'Ana María Pérez', 'V12345678', 'Banesco', '01340000000000000001',
          'approved', v_con, '2026-10-10 15:00-04', '2026-10-09 09:30-04');

  -- Una clínica a medio dar de alta: sin titular, sin cuenta, sin solicitud.
  insert into public.merchants (name, status, is_test)
  values ('Clínica Prueba Sin Datos', 'active', true)
  returning id into v_sin;

  -- --- 1. Quién no lee ----------------------------------------------------
  set local role anon;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  v_failed := false;
  begin
    perform public.admin_merchant_contract_data();
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'anon no debía leer los datos de alta'; end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_random::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_failed := false;
  begin
    perform public.admin_merchant_contract_data(v_con);
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'Un usuario cualquiera no debía leer los datos de alta'; end if;

  -- --- 2. El personal de Helios lee ---------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_operador::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  v_res := public.admin_merchant_contract_data();
  if jsonb_typeof(v_res) <> 'array'
     or (select count(*) from jsonb_array_elements(v_res) e
         where e->>'merchant_id' in (v_con::text, v_sin::text)) <> 2 then
    raise exception 'Sin argumento debían venir todas las clínicas, con las dos de prueba';
  end if;

  v_res := public.admin_merchant_contract_data(v_con);
  if jsonb_array_length(v_res) <> 1 then
    raise exception 'Con una clínica debía venir solo esa: %', v_res;
  end if;

  -- --- 3. La fila completa -----------------------------------------------
  v_fila := v_res->0;
  if v_fila->>'merchant_id' <> v_con::text
     or v_fila->>'name' <> 'Ana María Pérez'
     -- 20261029190000: el nombre es el del titular; el de alta, el consultorio.
     or v_fila->>'consultorio' is distinct from 'Consultorio Prueba Contrato'
     or v_fila->>'legal_name' <> 'Consultorio Prueba Contrato C.A.'
     or v_fila->>'tax_id' <> 'J509876543'
     or v_fila->>'category' <> 'odontologia'
     or v_fila->>'specialty' <> 'Odontología'
     or v_fila->>'mpps_number' <> '98765'
     or v_fila->>'phone' <> '+582125551234'
     or v_fila->>'email' <> 'contrato.prueba@example.com'
     or v_fila->>'address' <> 'Av. Principal, Torre Médica, piso 3'
     or v_fila->>'city' <> 'Caracas'
     or v_fila->>'status' <> 'active'
     or (v_fila->>'is_test')::boolean is not true
     or v_fila->>'created_at' is null then
    raise exception 'Los datos de la clínica no cuadran: %', v_fila;
  end if;
  if v_fila->>'owner_name' <> 'Ana María Pérez'
     or v_fila->>'owner_document' <> 'V12345678'
     or v_fila->>'college_number' <> 'COV-1234' then
    raise exception 'Los datos del titular no cuadran: %', v_fila;
  end if;
  if v_fila->>'bank' <> 'Banesco'
     or v_fila->>'account_holder' <> 'Ana María Pérez'
     or v_fila->>'holder_document' <> 'V12345678'
     or v_fila->>'account_number' <> '01340000000000000001'
     or v_fila->'pago_movil_phone' <> 'null'::jsonb then
    raise exception 'La cuenta de pago no cuadra: %', v_fila;
  end if;
  if (v_fila->>'applied_at')::timestamptz <> '2026-10-09 09:30-04'::timestamptz
     or (v_fila->>'approved_at')::timestamptz <> '2026-10-10 15:00-04'::timestamptz then
    raise exception 'Las fechas de la solicitud no cuadran: %', v_fila;
  end if;

  -- --- 4. Sin cuenta ni solicitud ------------------------------------------
  v_fila := public.admin_merchant_contract_data(v_sin)->0;
  if v_fila->>'name' <> 'Clínica Prueba Sin Datos'
     or v_fila->'owner_name' <> 'null'::jsonb
     or v_fila->'bank' <> 'null'::jsonb
     or v_fila->'account_number' <> 'null'::jsonb
     or v_fila->'applied_at' <> 'null'::jsonb then
    raise exception 'Lo que falta debía salir en null: %', v_fila;
  end if;

  -- --- 5. Una que no existe -----------------------------------------------
  v_failed := false;
  begin
    perform public.admin_merchant_contract_data(gen_random_uuid());
  exception when no_data_found then v_failed := true;
  end;
  if not v_failed then raise exception 'Una clínica que no existe debía dar error'; end if;

  -- --- 6. La lista trae el titular ----------------------------------------
  reset role;
  if (select owner_name from public.merchant_directory where id = v_con) is distinct from 'Ana María Pérez'
     or (select owner_name from public.merchant_directory where id = v_sin) is not null then
    raise exception 'merchant_directory debía traer el titular';
  end if;

  raise notice 'DATOS DE CONTRATO OK';
end;
$$;

set constraints all immediate;
rollback;
