-- ============================================================================
-- Helios — El super admin cambia el rol del equipo (20261102210000)
--
--   bash supabase/tests/run.sh rol_del_equipo_smoke
--
-- Se comprueba que:
--   1. El super admin cambia el rol de otro (operador → capacitador) y queda
--      en la bitácora con el rol de antes, el de ahora y el motivo.
--   2. Hace super admin a alguien y luego le quita ese rol.
--   3. Un operador y un capacitador no cambian roles (42501).
--   4. Nadie se cambia el rol a sí mismo.
--   5. El equipo no se queda sin super admin: con los demás degradados, el
--      último no puede degradarse.
--   6. No se cambia el rol de alguien revocado, ni al que ya tiene, ni de
--      quien no es del equipo.
--
-- No manda nada: solo toca `platform_admins` y la bitácora.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_otro    uuid := gen_random_uuid();
  v_op      uuid := gen_random_uuid();
  v_cap     uuid := gen_random_uuid();
  v_fuera   uuid := gen_random_uuid();
  v_det     jsonb;
  v_fallo   boolean;
begin
  v_admin := pg_temp.prueba_admin();
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'equipo-' || u || '@prueba.helios.test', now(), now()
    from unnest(array[v_otro, v_op, v_cap, v_fuera]) u;
  insert into public.platform_admins (user_id, role, full_name, is_active) values
    (v_otro, 'operador', 'Otro de Prueba', true),
    (v_op, 'operador', 'Operador de Prueba', true),
    (v_cap, 'capacitador', 'Capacitador de Prueba', true),
    (v_fuera, 'agenda', 'Revocado de Prueba', false);

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- --- 1. Cambia el rol de otro y queda en la bitácora --------------------
  perform public.admin_set_platform_admin_role(v_op, 'capacitador', '  Pasa a capacitar  ');
  reset role;
  if (select role from public.platform_admins where user_id = v_op) <> 'capacitador' then
    raise exception '1. el rol no cambió';
  end if;
  select detail into v_det from audit.admin_actions
   where actor = v_admin and action = 'platform_admin.set_role' and target_id = v_op;
  if v_det is null then raise exception '1. el cambio no quedó en la bitácora'; end if;
  if v_det ->> 'from' <> 'operador' or v_det ->> 'role' <> 'capacitador'
     or v_det ->> 'note' <> 'Pasa a capacitar' then
    raise exception '1. la bitácora dice otra cosa: %', v_det;
  end if;
  set local role authenticated;

  -- --- 2. Lo hace super admin y se lo quita -------------------------------
  perform public.admin_set_platform_admin_role(v_otro, 'super_admin', 'Responsable de caja');
  perform public.admin_set_platform_admin_role(v_otro, 'operador');
  reset role;
  if (select role from public.platform_admins where user_id = v_otro) <> 'operador' then
    raise exception '2. no volvió a operador';
  end if;
  if (select count(*) from audit.admin_actions
       where action = 'platform_admin.set_role' and target_id = v_otro) <> 2 then
    raise exception '2. faltan cambios en la bitácora';
  end if;
  set local role authenticated;

  -- --- 3. Un operador y un capacitador, no --------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_otro::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_set_platform_admin_role(v_op, 'agenda');
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. un operador cambió un rol'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_cap::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_set_platform_admin_role(v_cap, 'super_admin');
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. un capacitador se hizo super admin'; end if;

  -- --- 4. Nadie se cambia a sí mismo --------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_set_platform_admin_role(v_admin, 'operador');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '4. el super admin se cambió el rol a sí mismo'; end if;

  -- --- 5. El equipo no se queda sin super admin ---------------------------
  -- Los demás super admin (los reales también: se deshace con el rollback)
  -- pasan a operador uno a uno por la RPC; el último que queda es v_admin.
  reset role;
  v_det := (select coalesce(jsonb_agg(user_id), '[]') from public.platform_admins
             where role = 'super_admin' and is_active and user_id <> v_admin);
  set local role authenticated;
  perform public.admin_set_platform_admin_role((u #>> '{}')::uuid, 'operador')
    from jsonb_array_elements(v_det) u;
  v_fallo := false;
  begin
    perform public.admin_set_platform_admin_role(v_admin, 'operador');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '5. el último super admin dejó de serlo'; end if;
  reset role;
  if (select count(*) from public.platform_admins where role = 'super_admin' and is_active) <> 1 then
    raise exception '5. el equipo no tiene exactamente un super admin';
  end if;
  set local role authenticated;

  -- --- 6. Revocado, mismo rol, o de fuera del equipo ----------------------
  v_fallo := false;
  begin
    perform public.admin_set_platform_admin_role(v_fuera, 'operador');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '6. cambió el rol de alguien revocado'; end if;

  v_fallo := false;
  begin
    perform public.admin_set_platform_admin_role(v_op, 'capacitador');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '6. aceptó el mismo rol'; end if;

  v_fallo := false;
  begin
    perform public.admin_set_platform_admin_role(gen_random_uuid(), 'operador');
  exception when sqlstate 'P0002' then v_fallo := true;
  end;
  if not v_fallo then raise exception '6. cambió el rol de alguien que no es del equipo'; end if;

  reset role;
  raise notice '=== ROL DEL EQUIPO: TODO OK ===';
end $$;

rollback;
