-- ============================================================================
-- Ronda — La bitácora llega al primer día
--
-- La consulta traía las últimas cien líneas del filtro y ahí se acababa. El
-- panel recortaba por fecha sobre esas, así que «qué se hizo el lunes pasado»
-- funcionaba solo si en medio no había pasado mucho, y «qué se le hizo a esta
-- cuenta en agosto» no funcionaba nunca.
--
-- Una bitácora que no se puede recorrer entera no sirve de prueba de nada, que
-- es para lo único que existe.
--
-- Se añade el rango de días —en día operativo, como todo lo demás— y la
-- paginación: sin un desplazamiento, subir el límite a diez mil líneas para
-- poder llegar al principio sería la otra forma de no poder recorrerla.
-- ============================================================================

drop function if exists public.admin_audit_log(text, uuid, uuid, integer);

create or replace function public.admin_audit_log(
  p_action text default null,
  p_actor  uuid default null,
  p_target uuid default null,
  p_limit  integer default 100,
  p_from   date default null,
  p_to     date default null,
  p_offset integer default 0
)
returns table (
  id          bigint,
  actor       uuid,
  actor_name  text,
  action      text,
  target_id   uuid,
  detail      jsonb,
  created_at  timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  with filtradas as (
    select a.id, a.actor, a.action, a.target_id, a.detail, a.created_at
    from audit.admin_actions a
    where (p_action is null or a.action = p_action)
      and (p_actor is null or a.actor = p_actor)
      and (p_target is null or a.target_id = p_target)
      -- Por día operativo, como el resto del panel: un evento de la 1 a. m.
      -- pertenece a la noche anterior, y filtrar por fecha de calendario
      -- dejaría fuera justo lo que pasó de madrugada.
      and (p_from is null or public.helios_business_date(a.created_at) >= p_from)
      and (p_to is null or public.helios_business_date(a.created_at) <= p_to)
  )
  select
    f.id, f.actor, pa.full_name, f.action, f.target_id, f.detail, f.created_at,
    -- Cuántas hay en total con este filtro. Viaja en cada fila porque es lo
    -- que deja decir "1 a 100 de 3.412" sin una segunda consulta.
    count(*) over () as total_count
  from filtradas f
  left join public.platform_admins pa on pa.user_id = f.actor
  order by f.created_at desc, f.id desc
  limit least(coalesce(p_limit, 100), 500)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

comment on function public.admin_audit_log(text, uuid, uuid, integer, date, date, integer) is
  'La bitacora, con rango de dias operativos y paginacion. Sin limite de antiguedad: se puede llegar al primer dia.';

revoke all on function public.admin_audit_log(text, uuid, uuid, integer, date, date, integer)
  from public, anon;
grant execute on function public.admin_audit_log(text, uuid, uuid, integer, date, date, integer)
  to authenticated;

-- El índice que hace barato el filtro por sujeto, que es el de la ficha de una
-- persona y el que más se va a usar.
create index if not exists admin_actions_target_idx
  on audit.admin_actions (target_id, created_at desc) where target_id is not null;
