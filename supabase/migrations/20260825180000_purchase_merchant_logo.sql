-- ============================================================================
-- Ronda — El historial enseña el logo del comercio
--
-- `my_purchases` devolvía el nombre del local pero no su logo, así que el
-- Historial de Perfil pintaba un disco con la inicial aunque el comercio
-- tuviera imagen cargada. La inicial se queda como respaldo —hay comercios
-- sin logo, y una URL puede romperse— pero deja de ser lo primero.
--
-- Por qué aquí y no con un embed de PostgREST como hace Inicio: `my_purchases`
-- es `security definer` y lee `merchants` sin pasar por RLS. Un embed sí pasa,
-- y `merchants_read_active` solo deja ver los **activos** — el logo de un
-- local pausado desaparecería del historial de quien le compró el mes pasado,
-- que es justo cuando más falta hace reconocerlo.
-- ============================================================================

create or replace function public.my_purchases(p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $fn$
declare
  v_user uuid := auth.uid();
  v_rows jsonb;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.confirmed_at desc), '[]'::jsonb)
    into v_rows
  from (
    select
      c.id                                   as charge_id,
      c.order_number,
      m.name                                 as merchant_name,
      m.logo_url                             as merchant_logo_url,
      b.name                                 as branch_name,
      c.business_date,
      c.confirmed_at,
      c.status::text                         as status,
      c.amount_usd                           as total_usd,
      mine.my_usd,
      mine.paid_usd,
      mine.pending_usd,
      mine.installments,
      -- El grupo puede haberse cerrado o renombrado después; lo que importa
      -- para el historial es si el consumo se repartió, y entre cuántos.
      (c.group_id is not null)               as is_group,
      g.name                                 as group_name,
      split.people                           as split_between,
      (c.user_id = v_user)                   as i_started_it,
      items.lines                            as items
    from public.charges c
    join public.merchants m on m.id = c.merchant_id
    left join public.merchant_branches b on b.id = c.branch_id
    left join public.groups g on g.id = c.group_id
    join lateral (
      select
        sum(i.amount_usd)                                                  as my_usd,
        coalesce(sum(i.amount_usd) filter (where i.status = 'paid'), 0)     as paid_usd,
        coalesce(sum(i.amount_usd) filter (where i.status = 'pending'), 0)  as pending_usd,
        jsonb_agg(
          jsonb_build_object(
            'id', i.id,
            'sequence', i.sequence,
            'amount_usd', i.amount_usd,
            'due_date', i.due_date,
            'status', i.status,
            'paid_at', i.paid_at
          ) order by i.sequence
        ) as installments
      from public.installments i
      where i.charge_id = c.id and i.user_id = v_user
    ) mine on mine.my_usd is not null
    join lateral (
      select count(distinct i2.user_id) as people
      from public.installments i2
      where i2.charge_id = c.id
    ) split on true
    left join lateral (
      select jsonb_agg(
        jsonb_build_object(
          'name', ci.name,
          'quantity', ci.quantity,
          'unit_price_usd', ci.unit_price_usd,
          'line_total_usd', ci.line_total_usd
        ) order by ci.position, ci.created_at
      ) as lines
      from public.charge_items ci
      where ci.charge_id = c.id
    ) items on true
    order by c.confirmed_at desc
    limit p_limit
  ) q;

  return v_rows;
end;
$fn$;

revoke all on function public.my_purchases(integer) from public, anon;
grant execute on function public.my_purchases(integer) to authenticated;
