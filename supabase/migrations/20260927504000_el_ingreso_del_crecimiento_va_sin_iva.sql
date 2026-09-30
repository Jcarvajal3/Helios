-- ============================================================================
-- Ronda — El ingreso de Crecimiento va sin IVA
--
-- `admin_growth_overview.spend.revenue_usd` se anuncia (en el panel y en el
-- asistente) como el ingreso de Ronda, y sumaba cuota menos consumo: el
-- servicio CON su IVA. El IVA no es de Ronda, se cobra y se remite; el
-- ingreso es el servicio sin IVA, el mismo `service_fee_usd` del resumen
-- semanal y de la economía por consumo.
--
-- Ahora revenue_usd es el servicio sin IVA de los consumos de la ventana; lo
-- que valía antes queda en `fee_usd` (servicio + IVA), con su nombre. Todo lo
-- demás lee de `metricas` (20260927500000) y vale lo mismo que antes:
-- registros, verificados, primera compra, personas con cuota, consumos y
-- consumo sin servicio.
-- ============================================================================

create or replace function public.admin_growth_overview(p_from date default null, p_to date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today     date := metricas.hoy();
  v_from      date;
  v_to        date;
  v_days      integer;
  v_prev_from date;
  v_prev_to   date;
  v_result    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select w.desde, w.hasta, w.dias into v_from, v_to, v_days
  from public.helios_growth_window(p_from, p_to) w;

  -- La ventana anterior es la de al lado, del mismo largo.
  v_prev_from := v_from - v_days;
  v_prev_to   := v_from - 1;

  with
  -- Los registros: perfil real con el teléfono confirmado.
  gente as (
    select p.user_id, p.registro_dia as dia, p.verificado_dia, p.primer_consumo_dia, p.estado
    from metricas.personas p
  ),
  -- Una fila por (persona, cuota): el grano correcto para todo lo que se
  -- pregunta por persona.
  consumo as (
    select q.user_id, q.charge_id, q.business_date as dia, q.financed_usd as fin
    from metricas.cuotas q
  ),
  -- Una fila por consumo, para el servicio (el ingreso de Ronda).
  cargo as (
    select k.business_date as dia, k.servicio_usd, k.fee_usd
    from metricas.consumos k
  )
  select jsonb_build_object(
    'business_date', v_today,
    -- El rango QUE SE USÓ, no el que se pidió.
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,

    'registered', jsonb_build_object(
      'count',    (select count(*) from gente where dia between v_from and v_to),
      'previous', (select count(*) from gente where dia between v_prev_from and v_prev_to)
    ),

    'verified', jsonb_build_object(
      'count',    (select count(*) from gente where verificado_dia between v_from and v_to),
      'previous', (select count(*) from gente where verificado_dia between v_prev_from and v_prev_to)
    ),

    -- Activación: primer consumo de su vida dentro de la ventana.
    'activated', jsonb_build_object(
      'count',    (select count(*) from gente where primer_consumo_dia between v_from and v_to),
      'previous', (select count(*) from gente where primer_consumo_dia between v_prev_from and v_prev_to)
    ),

    'active_users', jsonb_build_object(
      'count',    (select count(distinct user_id) from consumo where dia between v_from and v_to),
      'previous', (select count(distinct user_id) from consumo where dia between v_prev_from and v_prev_to)
    ),

    'orders', jsonb_build_object(
      'count',    (select count(distinct charge_id) from consumo where dia between v_from and v_to),
      'previous', (select count(distinct charge_id) from consumo where dia between v_prev_from and v_prev_to)
    ),

    'spend', jsonb_build_object(
      'financed_usd', (select coalesce(sum(fin), 0) from consumo where dia between v_from and v_to),
      'previous_usd', (select coalesce(sum(fin), 0) from consumo where dia between v_prev_from and v_prev_to),
      -- El ingreso de Ronda: el servicio SIN IVA. Va aparte y nunca sumado al
      -- gasto.
      'revenue_usd',  (select coalesce(sum(servicio_usd), 0) from cargo where dia between v_from and v_to),
      -- El servicio con su IVA (lo que va dentro de las cuotas además del
      -- consumo). Tampoco se suma al gasto.
      'fee_usd',      (select coalesce(sum(fee_usd), 0) from cargo where dia between v_from and v_to),
      'per_user_usd', (
        select case when count(distinct user_id) > 0
               then round(sum(fin) / count(distinct user_id), 2) else 0 end
        from consumo where dia between v_from and v_to
      ),
      'per_order_usd', (
        select case when count(distinct charge_id) > 0
               then round(sum(fin) / count(distinct charge_id), 2) else 0 end
        from consumo where dia between v_from and v_to
      ),
      'orders_per_user', (
        select case when count(distinct user_id) > 0
               then round(count(distinct charge_id)::numeric / count(distinct user_id), 2) else 0 end
        from consumo where dia between v_from and v_to
      )
    ),

    -- Lo acumulado: la foto del padrón entero, no sigue la ventana.
    'totals', jsonb_build_object(
      'registered',  (select count(*) from gente),
      'onboarded',   (select count(*) from gente where estado not in ('pending_kyc', 'pending_pin')),
      'ever_bought', (select count(*) from gente where primer_consumo_dia is not null),
      'buyers_pct',  (
        select case when count(*) > 0
               then round(100.0 * count(*) filter (where primer_consumo_dia is not null) / count(*), 1)
               else 0 end
        from gente
      )
    ),

    -- La serie diaria, en un solo viaje para los cuatro gráficos.
    'series', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.day)
      from (
        select (v_from + g.k)                    as day,
               coalesce(r.n, 0)::int             as registered,
               coalesce(vf.n, 0)::int            as verified,
               coalesce(a.n, 0)::int             as activated,
               coalesce(co.usuarios, 0)::int     as active_users,
               coalesce(co.ordenes, 0)::int      as orders,
               coalesce(co.financiado, 0)        as financed_usd
        from generate_series(0, v_days - 1) as g(k)
        left join (
          select dia, count(*) as n from gente
          where dia between v_from and v_to group by 1
        ) r on r.dia = v_from + g.k
        left join (
          select verificado_dia as dia, count(*) as n from gente
          where verificado_dia between v_from and v_to group by 1
        ) vf on vf.dia = v_from + g.k
        left join (
          select primer_consumo_dia as dia, count(*) as n from gente
          where primer_consumo_dia between v_from and v_to group by 1
        ) a on a.dia = v_from + g.k
        left join (
          select dia,
                 count(distinct user_id)   as usuarios,
                 count(distinct charge_id) as ordenes,
                 sum(fin)                  as financiado
          from consumo
          where dia between v_from and v_to group by 1
        ) co on co.dia = v_from + g.k
      ) s
    ), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.admin_growth_overview(date, date) is
  'Crecimiento en un periodo y el anterior del mismo largo: registros, verificados, primera compra, personas con cuota, consumos, consumo sin servicio, el ingreso de Helios (servicio sin IVA) aparte, lo acumulado y la serie diaria. Lee de metricas.';

revoke all on function public.admin_growth_overview(date, date) from public, anon;
grant execute on function public.admin_growth_overview(date, date) to authenticated;
