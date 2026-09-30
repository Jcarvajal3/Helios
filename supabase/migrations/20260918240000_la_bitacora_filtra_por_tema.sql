-- ============================================================================
-- Ronda — La bitácora se filtra por tema, no por un código suelto
--
-- «Pagos de usuarios» no enseñaba nada, con once pagos aceptados en la base.
--
-- El filtro mandaba `payment.reconcile` y lo que se guarda es
-- `payment.reconciled` al aceptar y `payment.rejected` al rechazar. La consulta
-- compara con igualdad exacta, así que devolvía cero filas y la pantalla decía
-- «Nada con estos filtros», que es indistinguible de «no ha pasado nada». Lo
-- mismo en «Verificaciones»: mandaba `kyc.review`, y lo que existe es
-- `kyc.approved` y `kyc.rejected`.
--
-- Poner la letra que falta no arregla el fondo. Un tema casi nunca es un
-- código: «pagos de usuarios» son el aceptado, el rechazado y el que se dejó en
-- revisión; «verificaciones» son la aprobada, la rechazada y la que se pidió
-- repetir. Mientras el parámetro sea un texto suelto, cada tema con dos verbos
-- vuelve a estar roto, y roto en silencio, que en una bitácora es lo peor que
-- puede pasar: una tabla vacía parece una respuesta.
--
-- El parámetro pasa a ser una lista. El panel manda los códigos de cada tema
-- —incluidos los que se renombraron por el camino, para que las líneas de
-- agosto no desaparezcan— y aquí se filtra con `= any`.
--
-- `p_action` se queda: el panel que hay desplegado sigue llamando con un texto
-- suelto hasta que se suba el nuevo, y la bitácora no se puede quedar sin leer
-- ni diez minutos. Los dos conviven; el que venga nulo no filtra.
-- ============================================================================

-- La lista es un parámetro nuevo y `create or replace` no puede añadirlo: hay
-- que soltar la función entera y volver a crearla.
drop function if exists public.admin_audit_log(text, uuid, uuid, integer, date, date, integer);

create or replace function public.admin_audit_log(
  p_action  text    default null,
  p_actor   uuid    default null,
  p_target  uuid    default null,
  p_limit   integer default 100,
  p_from    date    default null,
  p_to      date    default null,
  p_offset  integer default 0,
  p_actions text[]  default null
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
      -- El tema, en lista. Una lista vacía es un tema mal armado en el panel,
      -- no una orden de no enseñar nada: se trata como si no hubiera filtro,
      -- que es lo único que deja ver el fallo en vez de esconderlo.
      and (p_actions is null or cardinality(p_actions) = 0 or a.action = any (p_actions))
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

comment on function public.admin_audit_log(text, uuid, uuid, integer, date, date, integer, text[]) is
  'La bitacora. Filtra por lista de acciones (un tema son varios codigos), por quien, por sujeto y por rango de dias operativos.';

revoke all on function public.admin_audit_log(text, uuid, uuid, integer, date, date, integer, text[])
  from public, anon;
grant execute on function public.admin_audit_log(text, uuid, uuid, integer, date, date, integer, text[])
  to authenticated;

-- El filtro por tema recorre la tabla entera por `action`. Hoy son cientos de
-- filas y da igual; el índice es para cuando sean cientos de miles, que es el
-- día en que nadie se acuerda de que había que ponerlo.
create index if not exists admin_actions_action_idx
  on audit.admin_actions (action, created_at desc);
