-- ============================================================================
-- Helios — Prueba de humo del archivo de pago masivo
--
--   bash supabase/tests/run.sh pago_masivo_smoke
--
-- `admin_bulk_payout_sheet` solo lee. Lo que se vigila: que solo la lea el
-- equipo, que lo de cada clínica sea lo mismo que «Sale hoy» en la lista de
-- pagos (`helios_settlement_outlook.next_run_usd`) y que la cuenta a debitar
-- sugerida sea la cuenta de cobro activa de transferencia.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin  uuid := gen_random_uuid();
  v_otro   uuid := gen_random_uuid();
  v_hoja   jsonb;
  v_fila   jsonb;
  v_sale   numeric;
  v_failed boolean;
begin
  -- --- Fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000091', now(), now(), now()),
    (v_otro,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000092', now(), now(), now());

  insert into public.platform_admins (user_id, role, full_name) values (v_admin, 'operador', 'Caja');

  insert into public.payment_destinations
    (method, bank_name, rif, holder_name, account_number, is_active, sort_order)
  values ('transferencia', 'Banco de Prueba', 'J123456789', 'Quarto Latam, C.A.',
          '01910000000000000001', true, 1);

  -- --- 1. Alguien de fuera no la lee -------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_otro::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  v_failed := false;
  begin
    perform public.admin_bulk_payout_sheet();
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'PAGO MASIVO 1: alguien que no es del equipo leyó el pago masivo';
  end if;

  -- --- 2. El equipo sí ---------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  v_hoja := public.admin_bulk_payout_sheet();
  reset role;

  if v_hoja->'debit_account'->>'account_number' is distinct from '01910000000000000001' then
    raise exception 'PAGO MASIVO 2: la cuenta a debitar sugerida es %, no la de cobro', v_hoja->'debit_account';
  end if;

  if (v_hoja->>'today_date')::date <> public.helios_business_date(now()) then
    raise exception 'PAGO MASIVO 2: el día es %, no el operativo', v_hoja->>'today_date';
  end if;

  -- --- 3. Lo de cada clínica es «Sale hoy» -------------------------------
  for v_fila in select * from jsonb_array_elements(v_hoja->'merchants') loop
    select o.next_run_usd into v_sale
    from public.helios_settlement_outlook((v_fila->>'merchant_id')::uuid) o;

    if abs((v_fila->>'pending_usd')::numeric - v_sale) > 0.005 then
      raise exception 'PAGO MASIVO 3: % sale por % y la lista dice %',
        v_fila->>'merchant_name', v_fila->>'pending_usd', v_sale;
    end if;

    if abs((v_fila->>'pending_usd_part')::numeric + (v_fila->>'pending_eur')::numeric) < 0.005 then
      raise exception 'PAGO MASIVO 3: % no trae lo pendiente por moneda', v_fila->>'merchant_name';
    end if;

    if v_fila->>'pending_ves' is not null
       and (v_fila->>'pending_eur')::numeric = 0
       and (v_hoja->>'fx_rate_usd') is not null
       and (v_fila->>'pending_ves')::numeric
           <> round((v_fila->>'pending_usd_part')::numeric * (v_hoja->>'fx_rate_usd')::numeric, 2) then
      raise exception 'PAGO MASIVO 3: los bolívares de % no son su parte en dólares a la BCV',
        v_fila->>'merchant_name';
    end if;
  end loop;

  raise notice 'PAGO MASIVO OK — % clínicas', jsonb_array_length(v_hoja->'merchants');
end;
$$;

set constraints all immediate;
rollback;
