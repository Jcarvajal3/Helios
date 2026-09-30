-- La ficha de una persona lee su caso de cobranza, no la cartera entera.
--
-- La cabecera de la ficha pedía admin_collections (la cartera de todo el
-- mundo) para quedarse con una fila. La consulta de las filas pasa a una
-- función interna, helios_collection_rows, que sirve a las dos:
-- admin_collections la llama para todos y admin_collection_case para una
-- persona. El cuerpo es el vivo de dev; solo cambian el filtro por persona y la
-- fila «al día» (bucket al_dia), que solo sale cuando se pide una persona.
-- admin_collections devuelve lo mismo que antes, ahora con el orden estable
-- entre empates.

create or replace function public.helios_collection_rows(
  p_today   date,
  p_horizon integer,
  p_user    uuid default null
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_demotion  integer := public.helios_mora_demotion_days();
  v_expulsion integer := public.helios_mora_expulsion_days();
begin
  return query
  select to_jsonb(q)
  from (
    with pending as (
      select
        i.user_id as uid,
        i.amount_usd,
        i.due_date,
        m.name as merchant_name
      from public.installments i
      join public.charges ch on ch.id = i.charge_id
      join public.merchants m on m.id = ch.merchant_id
      where i.status = 'pending'
        and not i.is_test
        and i.due_date <= p_today + p_horizon
        and (p_user is null or i.user_id = p_user)
    ),
    grouped as (
      select
        uid,
        sum(amount_usd) as open_usd,
        sum(amount_usd) filter (where due_date < p_today) as overdue_usd,
        sum(amount_usd) filter (where due_date >= p_today) as upcoming_usd,
        max(p_today - due_date) as days_late,
        min(due_date) as next_due,
        count(*)::integer as cnt,
        array_agg(distinct merchant_name) as merchant_names
      from pending
      group by 1
    ),
    -- Con una persona pedida que no tiene nada pendiente en el horizonte, su
    -- fila sale igual, al día: la ficha la necesita aunque la cartera no.
    base as (
      select * from grouped
      union all
      select p_user, 0::numeric, null::numeric, null::numeric, null::integer,
             null::date, 0::integer, array[]::text[]
      where p_user is not null
        and not exists (select 1 from grouped)
    )
    select
      g.uid as user_id,
      p.full_name,
      p.phone_e164,
      p.status::text as status,
      p.level,
      -- `>= v_demotion` y `> v_expulsion` son los de `recompute_profile_mora_state`.
      case
        when g.cnt = 0 then 'al_dia'
        when g.days_late > v_expulsion then 'expulsion'
        when g.days_late >= v_demotion then 'baja_nivel'
        when g.days_late >= 1 then 'congelado'
        when g.days_late = 0  then 'vence_hoy'
        else 'por_vencer'
      end as bucket,
      g.open_usd::numeric as open_usd,
      coalesce(g.overdue_usd, 0)::numeric as overdue_usd,
      coalesce(g.upcoming_usd, 0)::numeric as upcoming_usd,
      greatest(g.days_late, 0)::integer as days_overdue,
      g.next_due as next_due_date,
      g.cnt as installment_count,
      g.merchant_names as merchants,
      (
        select max(pr.created_at) from public.payment_reports pr
        where pr.user_id = g.uid and pr.status = 'reconciled'
      ) as last_payment_at,
      c.contacted_at as last_contact_at,
      c.channel::text as last_contact_channel,
      c.actor_name as last_contact_by,
      c.note as last_contact_note,
      -- La promesa es la de la última gestión que traía una, no la de la
      -- última gestión a secas: un «no contesta» de hoy no borra lo que la
      -- persona prometió ayer.
      pm.promise_date,
      -- Si se habló con esta persona DESPUÉS de que se le venciera lo más viejo.
      exists (
        select 1 from public.collection_contacts cs
        where cs.user_id = g.uid
          and public.helios_business_date(cs.contacted_at) >= g.next_due
      ) as contacted_since_due,
      -- Resultado y próxima acción de la ÚLTIMA gestión; estado de la promesa
      -- de `promise_date`.
      c.outcome as last_contact_outcome,
      c.next_action_on as last_contact_next_action_on,
      public.helios_promise_status(g.uid, pm.contacted_at, pm.promise_date, p_today)
        as promise_status
    from base g
    join public.profiles p on p.id = g.uid
    left join lateral (
      select cc.contacted_at, cc.channel, cc.note, cc.outcome, cc.next_action_on,
             coalesce(pa.full_name, 'Alguien del equipo') as actor_name
      from public.collection_contacts cc
      left join public.platform_admins pa on pa.user_id = cc.actor
      where cc.user_id = g.uid
      order by cc.contacted_at desc
      limit 1
    ) c on true
    left join lateral (
      select cp.promise_date, cp.contacted_at
      from public.collection_contacts cp
      where cp.user_id = g.uid and cp.promise_date is not null
      order by cp.contacted_at desc
      limit 1
    ) pm on true
    -- La cartera ya sale sin pruebas por sus cuotas; una persona pedida a
    -- mano, también.
    where p_user is null or not p.is_test
  ) q;
end;
$$;

comment on function public.helios_collection_rows(date, integer, uuid) is
  'Las filas de la cartera de cobranza (admin_collections), o la de una persona (admin_collection_case), con la misma cuenta. Interna: sin permiso para authenticated.';

revoke all on function public.helios_collection_rows(date, integer, uuid) from public, anon, authenticated;
grant execute on function public.helios_collection_rows(date, integer, uuid) to service_role;

CREATE OR REPLACE FUNCTION public.admin_collections(p_horizon_days integer DEFAULT 3)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today     date := public.helios_business_date(now());
  v_horizon   integer := greatest(least(coalesce(p_horizon_days, 3), 30), 0);
  v_demotion  integer := public.helios_mora_demotion_days();
  v_expulsion integer := public.helios_mora_expulsion_days();
  v_rows      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- El vencimiento más antiguo primero ES el mayor atraso primero (`days_late`
  -- es `hoy - min(due_date)`), y además ordena a los que aún no vencen. El
  -- desempate por persona hace el orden estable entre llamadas.
  select coalesce(
           jsonb_agg(r order by (r ->> 'next_due_date')::date, (r ->> 'open_usd')::numeric desc, r ->> 'user_id'),
           '[]'::jsonb
         )
    into v_rows
  from public.helios_collection_rows(v_today, v_horizon) r;

  return jsonb_build_object(
    'demotion_days', v_demotion,
    'expulsion_days', v_expulsion,
    'rows', v_rows
  );
end;
$function$;

comment on function public.admin_collections(integer) is
  'Cola de cobranza por persona, con su tramo, lo que debe y la ultima gestion. Los umbrales viajan fuera de las filas para que una cola vacia siga sabiendo etiquetar sus tramos.';
revoke all on function public.admin_collections(integer) from public, anon;
grant execute on function public.admin_collections(integer) to authenticated, service_role;

create or replace function public.admin_collection_case(
  p_user         uuid,
  p_horizon_days integer default 3
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today   date    := public.helios_business_date(now());
  v_horizon integer := greatest(least(coalesce(p_horizon_days, 3), 30), 0);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_user is null then
    return null;
  end if;

  return (select r from public.helios_collection_rows(v_today, v_horizon, p_user) r limit 1);
end;
$$;

comment on function public.admin_collection_case(uuid, integer) is
  'La fila de admin_collections de una persona, con la misma forma. Si no debe nada en el horizonte sale igual, con bucket al_dia y los importes en cero. Null si no existe o es de prueba.';

revoke all on function public.admin_collection_case(uuid, integer) from public, anon;
grant execute on function public.admin_collection_case(uuid, integer) to authenticated, service_role;
