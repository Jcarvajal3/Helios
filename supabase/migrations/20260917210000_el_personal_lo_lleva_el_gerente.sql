-- ===========================================================================
-- El personal del local: editable, y lo lleva su gerente
-- ===========================================================================
-- Hasta ahora el personal solo se podía DAR DE ALTA y DAR DE BAJA, y solo
-- desde el super admin. Faltaban las dos cosas que se piden todas las
-- semanas:
--
--   · Cambiar el rol. Un cajero que asciende a gerente no tenía camino: la
--     única forma era darlo de baja y volver a crearlo, y eso falla porque
--     `admin_create_auth_account` rechaza un correo que ya existe. Así que en
--     la práctica no se podía.
--   · Resetear la contraseña. Es la llamada número uno a soporte y la única
--     salida era que el equipo de Ronda entrara a la base.
--
-- Y sobre todo faltaba QUIÉN. Contratar un mesonero un viernes por la noche
-- no puede depender de que alguien de Ronda esté despierto: lo hace el
-- gerente del local, que es quien contrata.
--
-- ---------------------------------------------------------------------------
-- Una sola familia de funciones para los dos paneles
-- ---------------------------------------------------------------------------
-- Se sustituyen `admin_add_merchant_staff` y `admin_remove_merchant_staff` por
-- `merchant_staff_*`, con el permiso resuelto en UN sitio
-- (`can_manage_merchant_staff`). La alternativa era duplicar cada función en
-- versión «admin» y versión «gerente», y dos puertas al mismo cuarto con dos
-- cerraduras distintas es exactamente como se cuela alguien: se arregla una y
-- se olvida la otra.
--
-- ---------------------------------------------------------------------------
-- Los tres candados
-- ---------------------------------------------------------------------------
--   1. El gerente solo alcanza SU comercio. Sale de
--      `my_merchant_ids_with_role`, que ya filtra por rol y por actividad.
--   2. Nadie se toca a sí mismo. Un gerente no puede cambiarse el rol ni
--      darse de baja: si lo hiciera, el local se quedaría sin nadie que
--      pueda gestionar su propio personal y habría que llamar a Ronda.
--      Cambiarse el NOMBRE sí, que no abre ninguna puerta.
--   3. Un gerente no toca la cuenta de alguien del equipo de Ronda. No
--      debería pasar nunca —un super admin no es personal de un bar— pero si
--      alguien lo fuera, resetearle la contraseña desde el panel de un local
--      sería una escalada de privilegios servida en bandeja.
--
-- Lo que NO se hace: cerrar las sesiones abiertas al dar de baja. No hace
-- falta y sería un falso remedio — cada petición comprueba `is_active` contra
-- `merchant_users`, así que un JWT viejo ya no cobra nada. Tocar
-- `auth.sessions` a mano sería asumir la forma interna de GoTrue para no
-- ganar nada.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Quién puede gestionar el personal de un comercio
-- ---------------------------------------------------------------------------
create or replace function public.can_manage_merchant_staff(p_merchant_id uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select
    public.is_platform_admin()
    or p_merchant_id in (
      select public.my_merchant_ids_with_role(array['gerente']::public.merchant_role[])
    );
$$;

comment on function public.can_manage_merchant_staff(uuid) is
  'El equipo de Helios, o el gerente activo de ESE comercio. Es el unico sitio donde vive la regla.';

revoke all on function public.can_manage_merchant_staff(uuid) from public, anon;
grant execute on function public.can_manage_merchant_staff(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. La sucursal que le toca a un rol
-- ---------------------------------------------------------------------------
-- Un cajero siempre trabaja en una sucursal concreta: lo exige el check
-- `cajero_requires_branch`. Gerente e inventario van con alcance de comercio
-- entero. Estaba copiado en dos funciones y ahora vive una vez.
create or replace function public.helios_branch_for_role(
  p_merchant_id uuid,
  p_role        public.merchant_role,
  p_branch_id   uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_branch uuid;
begin
  if p_role <> 'cajero' then
    return null;
  end if;

  v_branch := p_branch_id;

  if v_branch is null then
    select id into v_branch from public.merchant_branches
    where merchant_id = p_merchant_id and is_default
    limit 1;
  end if;

  -- Sin esto el insert revienta contra el check `cajero_requires_branch` con
  -- un error de constraint que no le dice nada a nadie. Un comercio sin
  -- sucursal por defecto es una anomalía de datos —`bootstrap_merchant` crea
  -- una— pero si aparece, que se lea.
  if v_branch is null then
    raise exception 'Este comercio no tiene sucursal por defecto: un cajero necesita una'
      using errcode = '22023';
  end if;

  return v_branch;
end;
$$;

revoke all on function public.helios_branch_for_role(uuid, public.merchant_role, uuid)
  from public, anon;
grant execute on function public.helios_branch_for_role(uuid, public.merchant_role, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El guarda común, en plpgsql, para poder reventar con el motivo
-- ---------------------------------------------------------------------------
create or replace function public.helios_assert_staff_manager(
  p_merchant_id uuid,
  p_user_id     uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if not public.can_manage_merchant_staff(p_merchant_id) then
    raise exception 'Solo el equipo de Helios o el gerente del local pueden gestionar su personal'
      using errcode = '42501';
  end if;

  if p_user_id is null then
    return;
  end if;

  -- Candado 3: un gerente no toca a alguien del equipo de Ronda.
  if not public.is_platform_admin()
     and exists (
       select 1 from public.platform_admins
       where user_id = p_user_id and is_active
     ) then
    raise exception 'Esa cuenta es del equipo de Helios: solo ellos pueden cambiarla'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function public.helios_assert_staff_manager(uuid, uuid) from public, anon;
grant execute on function public.helios_assert_staff_manager(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. La lista
-- ---------------------------------------------------------------------------
-- El nombre sale con `coalesce`: las cuentas del panel se crean sin fila en
-- `profiles` —solo con el metadato de auth— y las antiguas, creadas buscando
-- por telefono, sí la tienen. Sin el coalesce, media plantilla sale «Sin
-- nombre» segun el ano en que se dio de alta.
create or replace function public.merchant_staff_list(p_merchant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_rows jsonb;
begin
  perform public.helios_assert_staff_manager(p_merchant_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id',    mu.user_id,
    'name',       coalesce(p.full_name, au.raw_user_meta_data ->> 'full_name'),
    'email',      au.email,
    'phone',      p.phone_e164,
    'role',       mu.role,
    'branch_id',  mu.branch_id,
    'branch',     b.name,
    'created_at', mu.created_at,
    -- Para que la pantalla pueda apagar «cambiar mi rol» y «darme de baja»
    -- en vez de dejar que el servidor lo rechace despues de pulsar.
    'is_self',    mu.user_id = auth.uid()
  ) order by mu.created_at), '[]'::jsonb) into v_rows
  from public.merchant_users mu
  join auth.users au on au.id = mu.user_id
  left join public.profiles p on p.id = mu.user_id
  left join public.merchant_branches b on b.id = mu.branch_id
  where mu.merchant_id = p_merchant_id and mu.is_active;

  return jsonb_build_object('rows', v_rows);
end;
$$;

revoke all on function public.merchant_staff_list(uuid) from public, anon;
grant execute on function public.merchant_staff_list(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Alta
-- ---------------------------------------------------------------------------
create or replace function public.merchant_staff_add(
  p_merchant_id uuid,
  p_email       text,
  p_password    text,
  p_full_name   text,
  p_role        public.merchant_role,
  p_branch_id   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_user   uuid;
  v_branch uuid;
begin
  perform public.helios_assert_staff_manager(p_merchant_id);

  v_user   := public.admin_create_auth_account(p_email, p_password, p_full_name);
  v_branch := public.helios_branch_for_role(p_merchant_id, p_role, p_branch_id);

  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_user, p_merchant_id, v_branch, p_role)
  on conflict (user_id, merchant_id, branch_id) do update
    set role = excluded.role, is_active = true;

  perform audit.log(v_actor, 'merchant.staff_added', p_merchant_id,
    jsonb_build_object(
      'user_id', v_user,
      'email',   lower(trim(p_email)),
      'role',    p_role
    ));

  return jsonb_build_object('ok', true, 'user_id', v_user, 'branch_id', v_branch);
end;
$$;

revoke all on function public.merchant_staff_add(uuid, text, text, text, public.merchant_role, uuid)
  from public, anon;
grant execute on function public.merchant_staff_add(uuid, text, text, text, public.merchant_role, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Editar: nombre y rol
-- ---------------------------------------------------------------------------
-- UNA fila activa por persona y comercio. El modelo admite varias —un cajero
-- puede estar en dos sucursales— pero el panel presenta «una persona, un rol
-- en este local», y si la edicion dejara filas sueltas, la misma persona
-- saldria dos veces en la lista con dos roles distintos. Asi que se apagan
-- todas y se enciende la que toca.
create or replace function public.merchant_staff_update(
  p_merchant_id uuid,
  p_user_id     uuid,
  p_full_name   text,
  p_role        public.merchant_role,
  p_branch_id   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_antes  public.merchant_role;
  v_nombre text := nullif(trim(coalesce(p_full_name, '')), '');
  v_branch uuid;
begin
  perform public.helios_assert_staff_manager(p_merchant_id, p_user_id);

  select role into v_antes
  from public.merchant_users
  where merchant_id = p_merchant_id and user_id = p_user_id and is_active
  order by created_at
  limit 1;

  if v_antes is null then
    raise exception 'Esa persona no es personal de este comercio' using errcode = 'P0002';
  end if;

  -- Candado 2: cambiarse el propio rol deja al local sin quien gestione su
  -- personal. El nombre sí se puede cambiar.
  if p_user_id = v_actor and p_role is distinct from v_antes then
    raise exception 'No puedes cambiarte el rol a ti mismo. Que lo haga otro gerente o el equipo de Helios.'
      using errcode = '42501';
  end if;

  if v_nombre is not null then
    update auth.users
      set raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
                               || jsonb_build_object('full_name', v_nombre),
          updated_at = now()
    where id = p_user_id;

    -- Solo si ya existe: una cuenta de panel no tiene fila en `profiles` y
    -- crearla aqui la metería en el padrón de consumidores, que es otra cosa.
    update public.profiles set full_name = v_nombre where id = p_user_id;
  end if;

  if p_role is distinct from v_antes or p_branch_id is not null then
    v_branch := public.helios_branch_for_role(p_merchant_id, p_role, p_branch_id);

    update public.merchant_users
      set is_active = false
    where merchant_id = p_merchant_id and user_id = p_user_id;

    insert into public.merchant_users (user_id, merchant_id, branch_id, role)
    values (p_user_id, p_merchant_id, v_branch, p_role)
    on conflict (user_id, merchant_id, branch_id) do update
      set role = excluded.role, is_active = true;
  end if;

  perform audit.log(v_actor, 'merchant.staff_updated', p_merchant_id,
    jsonb_build_object(
      'user_id', p_user_id,
      'name',    v_nombre,
      'before',  v_antes,
      'after',   p_role
    ));

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.merchant_staff_update(uuid, uuid, text, public.merchant_role, uuid)
  from public, anon;
grant execute on function public.merchant_staff_update(uuid, uuid, text, public.merchant_role, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Contraseña nueva
-- ---------------------------------------------------------------------------
-- La contraseña NO viaja a la bitácora. Ni entera ni recortada: una bitácora
-- es un registro que se lee, se exporta y se enseña, y ahí dentro no puede
-- haber nunca una credencial.
create or replace function public.merchant_staff_set_password(
  p_merchant_id uuid,
  p_user_id     uuid,
  p_password    text
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  perform public.helios_assert_staff_manager(p_merchant_id, p_user_id);

  if not exists (
    select 1 from public.merchant_users
    where merchant_id = p_merchant_id and user_id = p_user_id and is_active
  ) then
    raise exception 'Esa persona no es personal de este comercio' using errcode = 'P0002';
  end if;

  if p_password is null or length(p_password) < 8 then
    raise exception 'La contraseña debe tener al menos 8 caracteres' using errcode = '22023';
  end if;

  update auth.users
    set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
        updated_at = now()
  where id = p_user_id;

  perform audit.log(v_actor, 'merchant.staff_password_reset', p_merchant_id,
    jsonb_build_object('user_id', p_user_id));

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.merchant_staff_set_password(uuid, uuid, text) from public, anon;
grant execute on function public.merchant_staff_set_password(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Baja
-- ---------------------------------------------------------------------------
create or replace function public.merchant_staff_remove(
  p_merchant_id uuid,
  p_user_id     uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  perform public.helios_assert_staff_manager(p_merchant_id, p_user_id);

  if p_user_id = v_actor then
    raise exception 'No puedes darte de baja a ti mismo. Que lo haga otro gerente o el equipo de Helios.'
      using errcode = '42501';
  end if;

  -- Se desactiva en vez de borrar: los cobros que generó esa persona apuntan
  -- a su fila, y borrarla dejaría el historial sin saber quién cobró.
  update public.merchant_users
    set is_active = false
  where merchant_id = p_merchant_id and user_id = p_user_id;

  if not found then
    raise exception 'Esa persona no es personal de este comercio' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.staff_removed', p_merchant_id,
    jsonb_build_object('user_id', p_user_id));

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.merchant_staff_remove(uuid, uuid) from public, anon;
grant execute on function public.merchant_staff_remove(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Fuera las dos de antes
-- ---------------------------------------------------------------------------
-- Hacían lo mismo con otro permiso. Dejarlas vivas sería dejar la puerta
-- vieja abierta al lado de la nueva.
drop function if exists public.admin_add_merchant_staff(uuid, text, text, text, public.merchant_role, uuid);
drop function if exists public.admin_remove_merchant_staff(uuid, uuid);
