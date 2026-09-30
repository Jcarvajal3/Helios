-- ============================================================================
-- Devolver un acceso al panel
-- ============================================================================
--
-- Revocar era un botón de un solo clic y sin vuelta atrás: `platform_admins`
-- tenía `admin_set_platform_admin` para dar de alta y
-- `admin_revoke_platform_admin` para quitar, pero nada para volver a poner en
-- pie una fila ya revocada. Y el alta no servía de camino de vuelta, porque
-- crea la cuenta de Auth: contra un correo que ya existe falla, así que quien
-- se equivocaba de fila se quedaba sin forma de arreglarlo desde el panel.
--
-- La fila revocada no se borra —`is_active = false`, la persona conserva su
-- cuenta, su historial y su rol—, así que devolver el acceso es exactamente
-- volver a ponerla en true. Lo que faltaba era la función que lo hiciera con
-- las mismas reglas que las otras dos: solo un super_admin activo, y queda en
-- la bitácora.
--
-- El rol es opcional: sin él vuelve con el que tenía. Se acepta cambiarlo
-- porque la alternativa —restaurar y luego no poder tocar el rol— deja el
-- mismo callejón sin salida en otra forma.
-- ============================================================================

create or replace function public.admin_restore_platform_admin(
  p_user_id uuid,
  p_role    public.platform_role default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_role  public.platform_role;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super_admin puede devolver accesos' using errcode = '42501';
  end if;

  select role into v_role from public.platform_admins where user_id = p_user_id;

  if v_role is null then
    raise exception 'Esa persona nunca tuvo acceso al panel' using errcode = '22023';
  end if;

  update public.platform_admins
     set is_active = true,
         role      = coalesce(p_role, role)
   where user_id = p_user_id;

  perform audit.log(v_actor, 'platform_admin.restore', p_user_id, jsonb_build_object(
    'role', coalesce(p_role, v_role)
  ));
end;
$$;

revoke all on function public.admin_restore_platform_admin(uuid, public.platform_role)
  from public, anon;
grant execute on function public.admin_restore_platform_admin(uuid, public.platform_role)
  to authenticated;
