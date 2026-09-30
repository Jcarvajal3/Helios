-- ============================================================================
-- Helios — Prueba de humo del alta de comercios (portada de Ronda:
-- admin_kyc_merchants_smoke, sin la mitad del KYC)
--
-- docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--   -v ON_ERROR_STOP=1 -f supabase/tests/admin_kyc_merchants_smoke.sql
--
-- Lo importante aquí es la separación de poderes: un `operador` revisa
-- identidades pero NO puede firmar comercios; un usuario cualquiera no puede
-- ni lo uno ni lo otro.
-- ============================================================================

begin;

do $$
declare
  v_super    uuid := gen_random_uuid();
  v_operador uuid := gen_random_uuid();
  v_random   uuid := gen_random_uuid();
  v_pending  uuid := gen_random_uuid();
  v_verif    uuid;
  v_queue    jsonb;
  v_merchant uuid;
  v_failed   boolean;
  v_status   public.profile_status;
  v_staff    integer;
  v_result   jsonb;
  v_staff_user uuid;
begin
  -- --- Fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_super,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000051', now(), now(), now()),
    (v_operador, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000052', now(), now(), now()),
    (v_random,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000053', now(), now(), now()),
    (v_pending,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000054', now(), now(), now());

  insert into public.platform_admins (user_id, role, full_name) values
    (v_super,    'super_admin', 'Jefa'),
    (v_operador, 'operador',    'Operador');

  -- Helios: aquí iban las pruebas de la cola de KYC (TEST KYC 1-5: la cola,
  -- los puntajes, los permisos, el motivo de rechazo y la aprobación). El KYC
  -- se podó (20261001000000_la_poda_de_la_app); quedan las de comercios.

  -- --- 6. Un operador NO puede firmar comercios --------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_operador::text, 'role', 'authenticated')::text, true);

  v_failed := false;
  begin
    perform public.admin_create_merchant('Bar Prohibido', null, null);
  exception when others then
    v_failed := true;
    raise notice 'TEST COMERCIO 1 OK — un operador no firma locales: %', sqlerrm;
  end;
  if not v_failed then
    raise exception 'Un operador no debía poder crear comercios';
  end if;

  -- --- 7. El super admin sí, y nace configurado --------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated')::text, true);

  select id into v_merchant
  from public.admin_create_merchant('Disco Nueva', 'Inversiones Nueva C.A.', 'J-987654321');

  reset role;
  if not exists (
    select 1 from public.merchant_branches
    where merchant_id = v_merchant and is_default and name = 'Principal'
  ) then
    raise exception 'El comercio debía nacer con su sucursal Principal';
  end if;
  /**
   * Nace con condiciones de liquidación, y sus tramos cubren el neto ENTERO.
   *
   * 🔁 Antes esto exigía "30/25/25/20" literal. Esos números eran del modelo
   * anterior a la facturación por cuenta de terceros (20260827100000), que
   * cambió tanto los tramos como la comisión: hoy los valores por defecto son
   * otros, y clavarlos aquí volvería a romper la prueba en el próximo ajuste
   * de negocio.
   *
   * Lo que NO puede cambiar es la invariante: el adelanto más los dos tramos
   * suman el 100 % del neto. Si no sumaran, al comercio se le quedaría
   * debiendo un resto para siempre — que es justo el descuadre que arregló
   * 20260829050000.
   */
  if not exists (
    select 1 from public.merchant_settlement_terms
    where merchant_id = v_merchant
      and upfront_pct + per_installment_pct * 2 = 100
      and commission_pct >= 0
  ) then
    raise exception 'El comercio debía nacer con condiciones que cubran el neto entero: %',
      (select row_to_json(t) from public.merchant_settlement_terms t
       where t.merchant_id = v_merchant);
  end if;
  raise notice 'TEST COMERCIO 2 OK — creado con sucursal y condiciones que suman el 100%% del neto';

  -- --- 8. Alta de personal: se CREA la cuenta, no se busca ---------------
  -- Cambió con 20260822230000: el personal del local entra al panel con
  -- correo y contraseña, así que darlo de alta es crear su cuenta. Antes se
  -- vinculaba un teléfono que ya existía, y por eso esta prueba comprobaba
  -- formatos de teléfono — un modelo que ya no existe.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated')::text, true);

  -- `admin_add_merchant_staff` ya no existe en Ronda: lo sustituyó
  -- `merchant_staff_add` (20260917210000), con la misma firma.
  v_result := public.merchant_staff_add(
    v_merchant, 'Cajero@Bar.Test', 'clave-larga-1', 'Cajero de Prueba', 'cajero', null
  );
  v_staff_user := (v_result->>'user_id')::uuid;

  reset role;
  select count(*) into v_staff
  from public.merchant_users
  where merchant_id = v_merchant and user_id = v_staff_user and role = 'cajero'
    and branch_id is not null;

  if v_staff <> 1 then
    raise exception 'El cajero debía quedar vinculado a la sucursal principal, filas: %', v_staff;
  end if;

  -- El correo se guarda normalizado: el super admin lo teclea como se lo
  -- dictan, y "Cajero@Bar.Test" tiene que poder entrar escribiendo minúsculas.
  if not exists (
    select 1 from auth.users
    where id = v_staff_user and email = 'cajero@bar.test' and email_confirmed_at is not null
  ) then
    raise exception 'La cuenta debía nacer con el correo en minúsculas y confirmada';
  end if;
  raise notice 'TEST COMERCIO 3 OK — cajero creado con cuenta de correo y sucursal principal';

  -- --- 8-bis. El mismo correo no crea una segunda cuenta -----------------
  -- Es el equivalente de hoy a lo que probaba la versión anterior: la misma
  -- persona escrita de otra forma tiene que resolver a la misma cuenta. Con
  -- correos, resolver significa RECHAZAR el duplicado — crear dos cuentas para
  -- el mismo correo dejaría al local con un acceso fantasma.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated')::text, true);

  v_failed := false;
  begin
    perform public.merchant_staff_add(
      v_merchant, '  CAJERO@bar.test ', 'otra-clave-1', 'Otro Nombre', 'gerente', null
    );
  exception when others then
    v_failed := true;
    raise notice 'TEST COMERCIO 3-bis OK — correo repetido (con mayúsculas y espacios) rechazado: %', sqlerrm;
  end;
  if not v_failed then
    raise exception 'El mismo correo, escrito distinto, no debía crear una segunda cuenta';
  end if;

  -- --- 9. Correo inválido y clave corta se rechazan ----------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated')::text, true);

  v_failed := false;
  begin
    perform public.merchant_staff_add(
      v_merchant, 'esto no es un correo', 'clave-larga-1', 'Nadie', 'cajero', null
    );
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'No debía aceptarse un correo inválido';
  end if;

  v_failed := false;
  begin
    perform public.merchant_staff_add(
      v_merchant, 'otro@bar.test', 'corta', 'Nadie', 'cajero', null
    );
  exception when others then
    v_failed := true;
    raise notice 'TEST COMERCIO 4 OK — correo inválido y contraseña corta rechazados: %', sqlerrm;
  end;
  if not v_failed then
    raise exception 'No debía aceptarse una contraseña de menos de 8 caracteres';
  end if;

  raise notice '=== TODOS LOS TESTS DE KYC Y COMERCIOS PASARON ===';
end $$;

set constraints all immediate;

rollback;
