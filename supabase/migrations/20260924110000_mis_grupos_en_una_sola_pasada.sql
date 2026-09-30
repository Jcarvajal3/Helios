-- ============================================================================
-- Ronda — Mis grupos, en una sola pasada por grupo
--
-- `my_groups` es la RPC autenticada que más CPU gasta en producción: la app
-- la repregunta con la pantalla de Grupos delante. Y por cada grupo llamaba
-- TRES veces a `group_participants` —para la lista de miembros, para el bote
-- (dentro de `group_pot_usd`) y para el mínimo de la cuenta—, y cada llamada
-- recalcula para cada miembro `available_usd` (mora, bloqueos, deuda viva) y
-- `can_take_debt`. Encima, el saldo propio se calculaba dos veces más.
--
-- Ahora `group_participants` corre UNA vez por grupo (`parts`, materializado)
-- y de esa misma fila salen los miembros, el bote y el mínimo; el saldo
-- propio, una vez por llamada. La respuesta es la misma, clave a clave.
--
-- El bote repite aquí la regla de `group_pot_usd` —reparten los que pueden
-- endeudarse y llegan al mínimo por persona— en vez de llamarla, porque
-- llamarla es volver a correr `group_participants`. Las dos tienen que
-- cambiar juntas; `group_detail` sigue usando `group_pot_usd`.
-- ============================================================================

create or replace function public.my_groups()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_user      uuid := auth.uid();
  v_available numeric;
  v_rows      jsonb;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- Sin grupos abiertos, la respuesta vacía de siempre y sin calcular el
  -- saldo, que es lo más caro: es el caso de casi todo el mundo. El filtro es
  -- el mismo que el de `mine`, abajo.
  if not exists (
    select 1
    from public.group_members m
    join public.groups g on g.id = m.group_id
    where m.user_id = v_user and m.left_at is null
      and public.helios_group_is_open(g.business_date, g.created_at)
  ) then
    return '[]'::jsonb;
  end if;

  v_available := public.available_usd(v_user);

  with mine as (
    select g.id, g.name, g.invite_code, g.created_at, g.created_by, g.business_date,
           m.cap_usd, m.spent_usd
    from public.groups g
    join public.group_members m
      on m.group_id = g.id and m.user_id = v_user and m.left_at is null
    where public.helios_group_is_open(g.business_date, g.created_at)
  ),
  -- Una sola vez por grupo. `materialized` para que el planificador no la
  -- vuelva a expandir en cada sitio donde se lee.
  parts as materialized (
    select g.id as group_id, p.*
    from mine g
    cross join lateral public.group_participants(g.id) p
  ),
  per_group as (
    select
      group_id,
      jsonb_agg(jsonb_build_object(
        'user_id',       user_id,
        'name',          name,
        'is_me',         user_id = v_user,
        'cap_usd',       cap_usd,
        'spent_usd',     spent_usd,
        'capacity_usd',  capacity_usd,
        'can_take_debt', can_take_debt
      ) order by user_id) as members,
      -- La regla de `group_pot_usd`: reparten los que pueden endeudarse y
      -- llegan al mínimo por persona.
      coalesce(sum(capacity_usd) filter (
        where can_take_debt and capacity_usd >= public.min_share_usd()), 0) as pot_usd,
      count(*) filter (
        where can_take_debt and capacity_usd >= public.min_share_usd()) as sharers
    from parts
    group by group_id
  )
  select coalesce(jsonb_agg(x order by x->>'created_at'), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'group_id',    g.id,
      'name',        g.name,
      'invite_code', g.invite_code,
      'created_at',  g.created_at,
      'created_by_me', g.created_by = v_user,
      'closes_at',   public.helios_group_closes_at(g.business_date),
      -- null hasta el primer pago: entonces `closes_at` es la hora a la que
      -- cerraría si se pagara ahora, no una hora a la que vaya a cerrar, y el
      -- cierre de verdad es `expires_at` (cuatro semanas sin pagos).
      'business_date', g.business_date,
      'expires_at',    public.helios_group_expires_at(g.created_at),
      'members',       coalesce(pg.members, '[]'::jsonb),
      'my_cap_usd',    g.cap_usd,
      'my_spent_usd',  g.spent_usd,
      'my_left_usd',   greatest(least(g.cap_usd - g.spent_usd, v_available), 0),
      'my_max_cap_usd', g.spent_usd + v_available,
      -- Lo que el grupo puede poner entre todos: la suma de lo que puede cada
      -- quien de los que reparten.
      'pot_usd',       coalesce(pg.pot_usd, 0),
      -- N × $2,50, con N los que REPARTEN: por debajo de eso la cuenta no se
      -- puede dividir entre tantos. Se dice ANTES de escanear; descubrirlo con
      -- el QR ya leído es enterarse de pie en la caja.
      'min_charge_usd', coalesce(pg.sharers, 0) * public.min_share_usd(),
      'min_share_usd', public.min_share_usd()
    ) as x
    from mine g
    left join per_group pg on pg.group_id = g.id
  ) s;

  return v_rows;
end;
$$;
