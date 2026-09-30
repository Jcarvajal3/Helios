-- ============================================================================
-- Ronda — Prueba de humo de la edición de comercios
--
-- docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--   -v ON_ERROR_STOP=1 -f supabase/tests/edit_merchants_smoke.sql
--
-- Las dos barandas que importan: los porcentajes tienen que sumar 100 —si no,
-- el libro se descuadra en silencio— y no se puede cerrar un comercio al que
-- todavía se le debe dinero.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_super    uuid := gen_random_uuid();
  v_operador uuid := gen_random_uuid();
  v_cajero   uuid := gen_random_uuid();
  v_ana      uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_charge   uuid;
  v_failed   boolean;
  v_detail   jsonb;
  v_status   public.merchant_status;
  v_pct      numeric;
begin
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_super,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000091', now(), now(), now()),
    (v_operador, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000092', now(), now(), now()),
    (v_cajero,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000093', now(), now(), now()),
    (v_ana,      '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000094', now(), now(), now());

  update public.profiles set status = 'active', level = 3 where id = v_ana;

  insert into public.platform_admins (user_id, role, full_name) values
    (v_super, 'super_admin', 'Jefa'),
    (v_operador, 'operador', 'Operador');

  insert into public.merchants (name) values ('Bar Editable') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_merchant, v_branch, 'cajero');

  -- Helios: aquí iba el PIN de la prueba (`set_user_pin` y el pepper de
  -- Vault). Sin app no hay PIN: la deuda la crea `pg_temp.prueba_cobro`.

  -- --- 1. Un operador no renegocia condiciones ---------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_operador::text, 'role', 'authenticated')::text, true);

  v_failed := false;
  begin
    perform public.admin_set_settlement_terms(v_merchant, 40::numeric, 20::numeric, 20::numeric, 'scheduled'::public.settlement_policy);
  exception when others then
    v_failed := true;
    raise notice 'TEST EDIT 1 OK — un operador no renegocia: %', sqlerrm;
  end;
  if not v_failed then
    raise exception 'Un operador no debía poder cambiar las condiciones';
  end if;

  -- --- 2. Porcentajes que no suman 100 se rechazan con el motivo ---------
  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated')::text, true);

  v_failed := false;
  begin
    -- 🔁 La aritmética cambió con la facturación por cuenta de terceros
    -- (20260827100000): los tramos reparten el NETO del comercio y la comisión
    -- ya no entra en esa suma. El check vivo es `upfront + per_installment*2 =
    -- 100`, así que lo que hay que rechazar aquí es 40 + 25×2 = 90.
    perform public.admin_set_settlement_terms(v_merchant, 40::numeric, 25::numeric, 20::numeric, 'scheduled'::public.settlement_policy);
  exception when others then
    v_failed := true;
    raise notice 'TEST EDIT 2 OK — porcentajes que no cuadran rebotan: %', sqlerrm;
  end;
  if not v_failed then
    raise exception 'Unos tramos que no cubren el neto entero no debían aceptarse';
  end if;

  -- --- 3. Renegociación válida: 40 de adelanto y 30 en cada cuota --------
  -- 40 + 30×2 = 100: los tres tramos cubren el neto entero. La comisión (20)
  -- es cosa aparte y no entra en esa suma.
  perform public.admin_set_settlement_terms(v_merchant, 40::numeric, 30::numeric, 20::numeric, 'on_collection'::public.settlement_policy);

  reset role;
  select upfront_pct into v_pct from public.merchant_settlement_terms
  where merchant_id = v_merchant;
  if v_pct <> 40.00 then
    raise exception 'El adelanto debía quedar en 40, quedó en %', v_pct;
  end if;
  raise notice 'TEST EDIT 3 OK — condiciones renegociadas a 40/30/30 por cobranza';

  -- --- 4. Pausar quita el comercio de la app -----------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated')::text, true);
  perform public.admin_set_merchant_status(v_merchant, 'paused'::public.merchant_status, 'internet caído');

  reset role;
  select status into v_status from public.merchants where id = v_merchant;
  if v_status <> 'paused' then
    raise exception 'El comercio debía quedar pausado, está en %', v_status;
  end if;
  raise notice 'TEST EDIT 4 OK — comercio pausado';

  -- --- 5. No se cierra un comercio al que se le debe ---------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated')::text, true);
  perform public.admin_set_merchant_status(v_merchant, 'active'::public.merchant_status, null);

  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  v_charge := (pg_temp.prueba_cobro(v_ana, v_merchant, v_branch, v_cajero, 50.00, 'edit-1', 'Consumo')->>'charge_id')::uuid;

  perform set_config('request.jwt.claims', json_build_object('sub', v_super::text, 'role', 'authenticated')::text, true);

  v_failed := false;
  begin
    perform public.admin_set_merchant_status(v_merchant, 'terminated'::public.merchant_status, 'cierra el local');
  exception when others then
    v_failed := true;
    raise notice 'TEST EDIT 5 OK — no se cierra con deuda viva: %', sqlerrm;
  end;
  if not v_failed then
    raise exception 'No debía poder cerrarse un comercio al que se le debe dinero';
  end if;

  -- --- 6. El detalle trae condiciones, personal y lo pendiente ------------
  v_detail := public.admin_merchant_detail(v_merchant);

  if (v_detail->'terms'->>'upfront_pct')::numeric <> 40.00 then
    raise exception 'El detalle debía traer las condiciones nuevas: %', v_detail;
  end if;
  if jsonb_array_length(v_detail->'staff') <> 1 then
    raise exception 'El detalle debía traer 1 persona de personal: %', v_detail;
  end if;
  if (v_detail->>'pending_usd')::numeric <= 0 then
    raise exception 'El detalle debía traer lo pendiente de pagar: %', v_detail;
  end if;
  raise notice 'TEST EDIT 6 OK — detalle: adelanto %, % persona(s), $% pendiente',
    v_detail->'terms'->>'upfront_pct',
    jsonb_array_length(v_detail->'staff'),
    v_detail->>'pending_usd';

  -- --- 7. Quitar personal lo desactiva, no lo borra ----------------------
  -- `admin_remove_merchant_staff` ya no existe en Ronda: lo sustituyó
  -- `merchant_staff_remove` (20260917210000, el personal lo lleva el gerente),
  -- que también acepta al super admin.
  perform public.merchant_staff_remove(v_merchant, v_cajero);

  reset role;
  if exists (
    select 1 from public.merchant_users
    where merchant_id = v_merchant and user_id = v_cajero and is_active
  ) then
    raise exception 'El cajero debía quedar desactivado';
  end if;
  if not exists (
    select 1 from public.merchant_users
    where merchant_id = v_merchant and user_id = v_cajero
  ) then
    raise exception 'La fila debía conservarse para no perder el historial de quién cobró';
  end if;
  raise notice 'TEST EDIT 7 OK — personal desactivado, fila conservada';

  raise notice '=== TODOS LOS TESTS DE EDICIÓN DE COMERCIOS PASARON ===';
end $$;

set constraints all immediate;

rollback;
