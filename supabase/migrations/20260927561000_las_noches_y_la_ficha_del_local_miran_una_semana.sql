-- ============================================================================
-- Ronda — Las noches y las cifras de un local miran una semana
--
-- Métricas › Locales, con un local elegido, enseña sus noches de la semana y
-- su cartera al cierre de esa semana. Las dos lecturas ya existen y ya cuentan
-- a la gente por sus cuotas (20260927501000); lo que les faltaba es poder
-- mirar una semana concreta en vez de «los últimos N días hasta hoy».
--
--   admin_nights(p_days, p_merchant_id, p_semana)
--       Con p_semana: las noches del lunes de esa semana al domingo (o a hoy,
--       si está en curso). Sin él, como siempre: los últimos p_days días.
--
--   admin_merchant_stats(p_merchant_id, p_days, p_semana)
--       Con p_semana: lo vendido es el de esa semana y la cartera, el punto de
--       empate y la mora son los de su gente AL CIERRE de esa semana
--       (`metricas.cuotas_al`, `metricas.cartera_al`); si la semana está en
--       curso, los de ahora. Sin él, como siempre. Claves nuevas: `semana`
--       ({desde, hasta, en_curso}, solo con p_semana) y
--       `portfolio.dia_de_referencia`.
--
-- Parten de la versión de CIMIENTOS (20260927501000). Las firmas cambian (un
-- parámetro más, con valor por defecto), así que se borra la vieja antes: las
-- llamadas de siempre, con nombre, siguen funcionando igual.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las noches
-- ---------------------------------------------------------------------------

drop function if exists public.admin_nights(integer, uuid);

create or replace function public.admin_nights(
  p_days        integer default 14,
  p_merchant_id uuid    default null,
  p_semana      date    default null
)
returns table (
  business_date  date,
  merchant_id    uuid,
  merchant_name  text,
  charge_count   integer,
  financed_usd   numeric,
  avg_ticket_usd numeric,
  distinct_users integer,
  new_users      integer,
  repeat_users   integer,
  first_sale_at  timestamptz,
  last_sale_at   timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date    := metricas.hoy();
  v_days  integer := greatest(least(coalesce(p_days, 14), 180), 1);
  v_from  date;
  v_to    date;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_semana is not null then
    -- Una semana: de su lunes a su domingo, sin pasar de hoy. Una semana
    -- futura no tiene noches.
    v_from := metricas.lunes(p_semana);
    v_to   := least(v_from + 6, v_today);
  else
    v_from := v_today - (v_days - 1);
    v_to   := v_today;
  end if;

  return query
  with
  por_noche as (
    select k.business_date as d, k.merchant_id as mid,
           count(*)::integer    as consumos,
           sum(k.financed_usd)  as consumo,
           min(k.confirmed_at)  as primera,
           max(k.confirmed_at)  as ultima
    from metricas.consumos k
    where k.business_date between v_from and v_to
      and (p_merchant_id is null or k.merchant_id = p_merchant_id)
    group by k.business_date, k.merchant_id
  ),
  -- La gente de cada noche: todos los que tienen cuota, no quien abrió.
  gente as (
    select distinct q.business_date as d, q.merchant_id as mid, q.user_id as uid
    from metricas.cuotas q
    where q.business_date between v_from and v_to
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ),
  -- Nueva = su primera cuota en ESE local es de esa noche. Se mira toda su
  -- historia con el local, no la ventana.
  por_gente as (
    select g.d, g.mid,
           count(*)::integer                                      as personas,
           (count(*) filter (where pl.primer_dia = g.d))::integer as nuevas
    from gente g
    join metricas.personas_por_local pl on pl.user_id = g.uid and pl.merchant_id = g.mid
    group by g.d, g.mid
  )
  select
    n.d,
    n.mid,
    m.name,
    n.consumos,
    n.consumo::numeric,
    round(n.consumo / n.consumos, 2),
    coalesce(pg.personas, 0),
    coalesce(pg.nuevas, 0),
    coalesce(pg.personas - pg.nuevas, 0),
    n.primera,
    n.ultima
  from por_noche n
  join public.merchants m on m.id = n.mid
  left join por_gente pg on pg.d = n.d and pg.mid = n.mid
  order by n.d desc, n.consumo desc;
end;
$$;

comment on function public.admin_nights(integer, uuid, date) is
  'Una fila por noche (día operativo) y local: consumos, consumo sin servicio, ticket medio, personas con cuota (distinct_users), las que estrenaban el local (new_users) y las que repetían (repeat_users). Los últimos p_days días o, con p_semana, esa semana de lunes a domingo (hasta hoy). Lee de metricas.';

revoke all on function public.admin_nights(integer, uuid, date) from public, anon;
grant execute on function public.admin_nights(integer, uuid, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Las cifras de un local
-- ---------------------------------------------------------------------------

drop function if exists public.admin_merchant_stats(uuid, integer);

create or replace function public.admin_merchant_stats(
  p_merchant_id uuid,
  p_days        integer default 30,
  p_semana      date    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date    := metricas.hoy();
  v_days  integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_from  date;
  v_to    date;
  -- El día al cierre del cual se mira la cartera: hoy, o el domingo de la
  -- semana pedida (si ya cerró).
  v_corte date;
  v_terms public.merchant_settlement_terms%rowtype;
  v_out   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_semana is not null then
    v_from  := least(metricas.lunes(p_semana), metricas.lunes(v_today));
    v_to    := least(v_from + 6, v_today);
    v_days  := v_to - v_from + 1;
    v_corte := v_from + 6;
  else
    v_from  := v_today - (v_days - 1);
    v_to    := v_today;
    v_corte := v_today;
  end if;

  select * into v_terms
  from public.merchant_settlement_terms where merchant_id = p_merchant_id;

  -- Lo vendido en la ventana.
  select jsonb_build_object(
    'window_days',    v_days,
    'charge_count',   count(*)::integer,
    'financed_usd',   coalesce(sum(k.financed_usd), 0),
    -- Personas con cuota en sus consumos de la ventana, no quien abrió.
    'distinct_users', (
      select count(distinct q.user_id)::integer
      from metricas.cuotas q
      where q.merchant_id = p_merchant_id
        and q.business_date between v_from and v_to
    ),
    'avg_ticket_usd', case
      when count(*) > 0 then round(sum(k.financed_usd) / count(*), 2) else 0 end
  )
  into v_out
  from metricas.consumos k
  where k.merchant_id = p_merchant_id
    and k.business_date between v_from and v_to;

  if p_semana is not null then
    v_out := v_out || jsonb_build_object('semana', jsonb_build_object(
      'desde', v_from, 'hasta', v_from + 6, 'en_curso', v_from + 6 >= v_today));
  end if;

  -- Su cartera al cierre de v_corte (hoy si no se pidió semana): con treinta
  -- días casi nunca hay cuotas vencidas suficientes para decir nada, así que
  -- es de toda su historia hasta ese día.
  v_out := v_out || jsonb_build_object('portfolio', (
    select jsonb_build_object(
      'dia_de_referencia',    coalesce(max(q.dia_de_referencia),
                                       case when v_corte < v_today then v_corte + 1 else v_today end),
      'billed_usd',           coalesce(sum(q.payable_usd), 0),
      'paid_usd',             coalesce(sum(q.payable_usd) filter (where q.status = 'paid'), 0),
      'overdue_usd',          coalesce(sum(q.payable_usd) filter (where q.estado_hoy = 'vencida'), 0),
      'overdue_financed_usd', coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'vencida'), 0),
      'overdue_fee_usd',      coalesce(sum(q.fee_usd) filter (where q.estado_hoy = 'vencida'), 0),
      'open_usd',             coalesce(sum(q.payable_usd) filter (where q.estado_hoy in ('vencida', 'por_vencer')), 0),
      'open_financed_usd',    coalesce(sum(q.financed_usd) filter (where q.estado_hoy in ('vencida', 'por_vencer')), 0),
      'open_fee_usd',         coalesce(sum(q.fee_usd) filter (where q.estado_hoy in ('vencida', 'por_vencer')), 0),
      'written_off_usd',      coalesce(sum(q.payable_usd) filter (where q.estado_hoy = 'perdida'), 0),
      -- LA mora: la misma cuenta y los mismos umbrales que la de toda la
      -- cartera, restringida a los consumos de este local.
      'arrears_pct',          coalesce((select c.mora_pct from metricas.cartera_al(v_corte, p_merchant_id) c), 0),
      -- El impago, en consumo sobre consumo.
      'bad_debt_pct', case
        when coalesce(sum(q.financed_usd), 0) > 0
        then round(100 * coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'perdida'), 0)
                       / sum(q.financed_usd), 2)
        else 0 end,
      -- Cobro a tiempo sobre las cuotas cuyo plazo ya cerró. Null y no cero
      -- cuando no hay ninguna: un 0 % sin denominador es una alarma inventada.
      'on_time_pct', case
        when count(*) filter (where q.plazo_cerrado) > 0
        then round(100.0 * count(*) filter (where q.plazo_cerrado and q.estado_hoy = 'a_tiempo')
                         / count(*) filter (where q.plazo_cerrado), 1)
        else null end,
      'due_count',            (count(*) filter (where q.plazo_cerrado))::integer,
      'on_time_count',        (count(*) filter (where q.plazo_cerrado and q.estado_hoy = 'a_tiempo'))::integer,
      'overdue_count',        (count(*) filter (where q.estado_hoy = 'vencida'))::integer
    )
    from metricas.cuotas_al(v_corte) q
    where q.merchant_id = p_merchant_id
  ));

  -- El punto de empate de ESTE local, con sus condiciones, con lo vendido
  -- hasta el corte.
  v_out := v_out || jsonb_build_object('break_even', (
    select jsonb_build_object(
      'policy', coalesce(v_terms.policy::text, 'scheduled'),
      'fee_usd', coalesce(sum(k.servicio_usd), 0),
      'at_risk_usd', coalesce(sum(
        case
          -- Por cobranza al local no se le adelanta nada: lo único que se
          -- pierde en un impago es el servicio que no se cobró.
          when v_terms.policy = 'on_collection' then 0
          else k.neto_local_usd
        end
      ), 0),
      'break_even_pct', case
        when coalesce(sum(
          k.servicio_usd +
          case when v_terms.policy = 'on_collection' then 0 else k.neto_local_usd end
        ), 0) > 0
        then round(100 * sum(k.servicio_usd) / sum(
          k.servicio_usd +
          case when v_terms.policy = 'on_collection' then 0 else k.neto_local_usd end
        ), 2)
        else null end
    )
    from metricas.consumos k
    where k.merchant_id = p_merchant_id
      and k.business_date <= v_corte
  ));

  return v_out;
end;
$$;

comment on function public.admin_merchant_stats(uuid, integer, date) is
  'La ficha de un local: lo vendido en la ventana (los últimos p_days días o, con p_semana, esa semana hasta hoy: consumo sin servicio, consumos, personas con cuota, ticket), su cartera de toda la historia al cierre de hoy o de esa semana (mora canónica, lo vivo y lo vencido con su desglose, impago en consumo, cobro a tiempo sobre plazos cerrados) y su punto de empate. Lee de metricas.';

revoke all on function public.admin_merchant_stats(uuid, integer, date) from public, anon;
grant execute on function public.admin_merchant_stats(uuid, integer, date) to authenticated;
