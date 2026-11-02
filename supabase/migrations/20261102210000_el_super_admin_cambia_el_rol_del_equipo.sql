-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El super admin cambia el rol de los demás del equipo
--
-- Hasta ahora el rol de alguien del equipo (`platform_admins`) solo se elegía
-- al darle acceso o al devolvérselo. `admin_set_platform_admin_role` lo
-- cambia a una persona con acceso activo, desde Ajustes › Equipo.
--
-- - Solo un super admin (con el segundo factor si se exige):
--   `helios_assert_super_admin()`.
-- - Nadie se cambia el rol a sí mismo.
-- - El equipo nunca se queda sin un super admin activo. Como quien cambia es
--   un super admin y no puede tocarse a sí mismo, hoy no puede pasar; la
--   comprobación se queda por si mañana cambia la primera regla.
-- - Queda en la bitácora: `platform_admin.set_role`, con el rol de antes, el
--   de ahora y el motivo.
--
-- No toca al personal de las clínicas (`merchant_users`): eso es de cada
-- clínica.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.admin_set_platform_admin_role(
  p_user_id uuid,
  p_role    public.platform_role,
  p_note    text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('cambiar el rol del equipo');
  v_antes  public.platform_role;
  v_activo boolean;
begin
  if p_role is null then
    raise exception 'Falta el rol' using errcode = '22023';
  end if;

  if p_user_id = v_actor then
    raise exception 'No puedes cambiarte el rol a ti mismo' using errcode = '22023';
  end if;

  -- Los super admin activos, bloqueados: dos cambios a la vez no pueden
  -- dejar cada uno al otro como el último.
  perform 1 from public.platform_admins
   where role = 'super_admin' and is_active
   for update;

  select role, is_active into v_antes, v_activo
    from public.platform_admins
   where user_id = p_user_id
   for update;

  if v_antes is null then
    raise exception 'Esa persona no es del equipo' using errcode = 'P0002';
  end if;

  if not v_activo then
    raise exception 'Esa persona no tiene acceso al panel: devuélveselo con el rol que quieras'
      using errcode = '22023';
  end if;

  if v_antes = p_role then
    raise exception 'Esa persona ya tiene ese rol' using errcode = '22023';
  end if;

  if v_antes = 'super_admin' and not exists (
    select 1 from public.platform_admins
     where role = 'super_admin' and is_active and user_id <> p_user_id
  ) then
    raise exception 'El equipo no puede quedarse sin un super admin' using errcode = '22023';
  end if;

  update public.platform_admins set role = p_role where user_id = p_user_id;

  perform audit.log(v_actor, 'platform_admin.set_role', p_user_id, jsonb_build_object(
    'from', v_antes,
    'role', p_role,
    'note', nullif(trim(p_note), '')
  ));
end;
$$;

comment on function public.admin_set_platform_admin_role(uuid, public.platform_role, text) is
  'Cambia el rol de alguien del equipo con acceso activo. Solo un super admin, nunca el suyo, y sin dejar al equipo sin super admin. Bitácora: platform_admin.set_role.';

revoke all on function public.admin_set_platform_admin_role(uuid, public.platform_role, text) from public, anon;
grant execute on function public.admin_set_platform_admin_role(uuid, public.platform_role, text) to authenticated;
