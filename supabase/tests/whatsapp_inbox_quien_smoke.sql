-- ============================================================================
-- Helios — El inbox distingue médicos y pacientes (20261021230000)
--
-- `admin_whatsapp_inbox_contacts` dice quién es cada chat del Inbox:
--
--   1. Alguien que no es del equipo no pasa (42501).
--   2. Un número del bot es «medico», con su nombre, rol y clínica.
--   3. Un teléfono de paciente es «paciente», con su perfil.
--   4. Si el número del bot es también de un paciente, gana médico.
--   5. Un número revocado ya no es médico (si tiene perfil, es paciente).
--   6. Un número que nadie conoce no viene; un wa_id raro, tampoco.
--   7. Más de 200 de una vez, no (22023).
--
-- No llama al Inbox: la RPC no tiene red.
-- ============================================================================
begin;
-- @ayudas

do $$
declare
  v_admin   uuid;
  v_extrano uuid := gen_random_uuid();
  v_gerente uuid := gen_random_uuid();
  v_ana     uuid := gen_random_uuid();
  v_pac     uuid := gen_random_uuid();
  v_doble   uuid := gen_random_uuid();
  v_ex      uuid := gen_random_uuid();
  v_m       uuid;
  v_br      uuid;
  v_j       jsonb;
  v_fallo   boolean;
begin
  update public.platform_maintenance set is_active = false;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values
    (v_gerente, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'quien-gerente@prueba.helios.test', now(), now(), '{"full_name":"Gabriela Gerente"}'),
    (v_ana, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'quien-ana@prueba.helios.test', now(), now(), '{"full_name":"Ana Secretaria"}');

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_m := (public.admin_create_merchant('Clínica Quién', null, 'J-610000077', 'clinica')).id;
  reset role;

  select id into v_br from public.merchant_branches where merchant_id = v_m and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_gerente, v_m, v_br, 'gerente'),
    (v_ana, v_m, v_br, 'cajero');
  insert into public.staff_whatsapp_numbers (phone_e164, user_id, merchant_id, created_by, revoked_at)
  values ('+584149997701', v_gerente, v_m, v_admin, null),
         ('+584149997702', v_ana, v_m, v_admin, null),
         ('+584149997704', v_ana, v_m, v_admin, now());
  insert into public.profiles (id, phone_e164, first_name, full_name) values
    (v_pac, '+584149997703', 'Luis', 'Luis Paciente'),
    (v_doble, '+584149997702', 'Ana', 'Ana También Paciente'),
    (v_ex, '+584149997704', 'Ex', 'Ex Secretaria');

  -- 1. Alguien de fuera del equipo.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_extrano::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_whatsapp_inbox_contacts(array['584149997701']);
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '1. alguien de fuera del equipo supo quién es un chat'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_whatsapp_inbox_contacts(
    array['584149997701', '584149997702', '584149997703', '584149997704', '584149997799', 'US.abc']);

  -- 2. El médico.
  if v_j -> '584149997701' ->> 'tipo' is distinct from 'medico'
     or v_j -> '584149997701' ->> 'nombre' is distinct from 'Gabriela Gerente'
     or v_j -> '584149997701' ->> 'rol' is distinct from 'gerente'
     or v_j -> '584149997701' ->> 'clinica' is distinct from 'Clínica Quién'
     or (v_j -> '584149997701' ->> 'merchant_id')::uuid is distinct from v_m then
    raise exception '2. el médico no salió bien: %', v_j -> '584149997701';
  end if;

  -- 3. El paciente.
  if v_j -> '584149997703' ->> 'tipo' is distinct from 'paciente'
     or v_j -> '584149997703' ->> 'nombre' is distinct from 'Luis Paciente'
     or (v_j -> '584149997703' ->> 'profile_id')::uuid is distinct from v_pac then
    raise exception '3. el paciente no salió bien: %', v_j -> '584149997703';
  end if;

  -- 4. Las dos cosas: gana médico.
  if v_j -> '584149997702' ->> 'tipo' is distinct from 'medico'
     or v_j -> '584149997702' ->> 'rol' is distinct from 'cajero' then
    raise exception '4. el número del bot que también es de un paciente: %', v_j -> '584149997702';
  end if;

  -- 5. Revocado.
  if v_j -> '584149997704' ->> 'tipo' is distinct from 'paciente' then
    raise exception '5. un número revocado sigue siendo médico: %', v_j -> '584149997704';
  end if;

  -- 6. Nadie y raro.
  if v_j ? '584149997799' or v_j ? 'US.abc' then
    raise exception '6. vino un chat que nadie conoce: %', v_j;
  end if;
  if public.admin_whatsapp_inbox_contacts(array[]::text[]) <> '{}'::jsonb
     or public.admin_whatsapp_inbox_contacts(null) <> '{}'::jsonb then
    raise exception '6. sin chats no devuelve un objeto vacío';
  end if;

  -- 7. Demasiados.
  v_fallo := false;
  begin
    perform public.admin_whatsapp_inbox_contacts(array(select '58414' || g from generate_series(1, 201) g));
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '7. aceptó más de 200 chats de una vez'; end if;
  reset role;
end;
$$;

rollback;
