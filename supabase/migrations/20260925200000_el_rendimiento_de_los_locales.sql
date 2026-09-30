-- ============================================================================
-- Ronda — El rendimiento de los locales
--
-- El perfil de la gente dice cómo es quien consume; esta lectura dice cómo le
-- va a cada local en un periodo: quién vendió más, con cuánta gente, cuánta
-- de esa gente era nueva y cómo va frente al periodo anterior del mismo largo.
-- La pinta la pestaña «Rendimiento» de Directorio › Locales.
--
-- ── De dónde sale cada cifra ────────────────────────────────────────────────
-- Consumo: coalesce(base_usd, amount_usd) de los cargos confirmados, SIN el
--   servicio de Ronda (la misma regla que admin_nights y la ficha del local).
--   Nunca un total con el fee sumado.
-- Consumos: cargos confirmados. Un consumo de grupo es UN cargo.
-- Personas: de las cuotas (installments.user_id), no de charges.user_id: en un
--   consumo de grupo hay una cuota por integrante y todas son clientela.
-- Nuevas: personas cuyo primer consumo en ESTE local cae dentro del periodo;
--   se mira contra toda su historia con el local.
-- Noches: días operativos (10 AM a 10 AM) con al menos un consumo.
--
-- Las cuentas de prueba (locales, cargos y cuotas) no cuentan en nada. Salen
-- también los locales activos que no vendieron: vender cero es un dato.
-- ============================================================================

create or replace function public.admin_merchant_performance(
  p_desde date default null,
  p_hasta date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_hasta  date := least(coalesce(p_hasta, v_today), v_today);
  v_desde  date := coalesce(p_desde, v_hasta - 29);
  v_dias   integer;
  v_ant_desde date;
  v_ant_hasta date;
  v_out    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_desde > v_hasta then
    raise exception 'El periodo empieza después de terminar' using errcode = '22023';
  end if;
  if v_hasta - v_desde > 365 then
    raise exception 'El periodo no puede pasar de un año' using errcode = '22023';
  end if;

  v_dias      := v_hasta - v_desde + 1;
  v_ant_hasta := v_desde - 1;
  v_ant_desde := v_desde - v_dias;

  with
  cargos as (
    select c.id, c.merchant_id, c.business_date as noche, c.group_id,
           coalesce(c.base_usd, c.amount_usd) as consumo
    from public.charges c
    join public.merchants m on m.id = c.merchant_id
    where c.status = 'confirmed'
      and not c.is_test
      and not m.is_test
      and c.business_date between v_ant_desde and v_hasta
  ),
  actual as (
    select * from cargos where noche >= v_desde
  ),
  anterior as (
    select merchant_id, sum(consumo) as consumo, count(*) as consumos
    from cargos where noche <= v_ant_hasta
    group by merchant_id
  ),
  -- La gente de cada local en el periodo, desde las cuotas.
  gente as (
    select distinct a.merchant_id, i.user_id
    from actual a
    join public.installments i on i.charge_id = a.id
    where not i.is_test
  ),
  -- El primer consumo de cada persona en cada local, en toda la historia.
  primera_vez as (
    select c.merchant_id, i.user_id, min(c.business_date) as primera
    from public.charges c
    join public.installments i on i.charge_id = c.id
    where c.status = 'confirmed'
      and not c.is_test
      and not i.is_test
      and (c.merchant_id, i.user_id) in (select merchant_id, user_id from gente)
    group by c.merchant_id, i.user_id
  ),
  por_gente as (
    select g.merchant_id,
           count(*)                                         as personas,
           count(*) filter (where p.primera >= v_desde)     as nuevas
    from gente g
    join primera_vez p using (merchant_id, user_id)
    group by g.merchant_id
  ),
  por_noche as (
    select merchant_id, noche, sum(consumo) as consumo
    from actual
    group by merchant_id, noche
  ),
  mejor_noche as (
    select distinct on (merchant_id) merchant_id, noche, consumo
    from por_noche
    order by merchant_id, consumo desc, noche desc
  ),
  por_local as (
    select a.merchant_id,
           sum(a.consumo)                               as consumo,
           count(*)                                     as consumos,
           count(*) filter (where a.group_id is not null) as en_grupo,
           count(distinct a.noche)                      as noches
    from actual a
    group by a.merchant_id
  ),
  locales as (
    select m.id, m.name, m.status::text as status, m.city
    from public.merchants m
    where not m.is_test
      and (m.status = 'active'
           or m.id in (select merchant_id from cargos))
  ),
  total as (
    select coalesce(sum(consumo), 0) as consumo, count(*) as consumos
    from actual
  )
  select jsonb_build_object(
    'business_date', v_today,
    'desde', v_desde,
    'hasta', v_hasta,
    'dias', v_dias,
    'anterior', jsonb_build_object('desde', v_ant_desde, 'hasta', v_ant_hasta),
    'totales', jsonb_build_object(
      'consumo_usd', (select consumo from total),
      'consumos',    (select consumos from total),
      'personas',    (select count(distinct user_id) from gente),
      'consumo_anterior_usd', coalesce((select sum(consumo) from anterior), 0),
      'consumos_anteriores',  coalesce((select sum(consumos) from anterior), 0)
    ),
    'locales', coalesce((
      select jsonb_agg(jsonb_build_object(
        'merchant_id', l.id,
        'nombre', l.name,
        'estado', l.status,
        'ciudad', l.city,
        'consumo_usd', coalesce(pl.consumo, 0),
        'consumos', coalesce(pl.consumos, 0),
        'ticket_medio_usd', case when pl.consumos > 0 then round(pl.consumo / pl.consumos, 2) end,
        'personas', coalesce(pg.personas, 0),
        'nuevas', coalesce(pg.nuevas, 0),
        'noches', coalesce(pl.noches, 0),
        'consumos_en_grupo', coalesce(pl.en_grupo, 0),
        'mejor_noche', case when mn.noche is not null
          then jsonb_build_object('fecha', mn.noche, 'consumo_usd', mn.consumo) end,
        'consumo_anterior_usd', coalesce(an.consumo, 0),
        'consumos_anteriores', coalesce(an.consumos, 0)
      ) order by coalesce(pl.consumo, 0) desc, l.name)
      from locales l
      left join por_local  pl on pl.merchant_id = l.id
      left join por_gente  pg on pg.merchant_id = l.id
      left join mejor_noche mn on mn.merchant_id = l.id
      left join anterior   an on an.merchant_id = l.id
    ), '[]'::jsonb)
  )
  into v_out;

  return v_out;
end;
$$;

revoke all on function public.admin_merchant_performance(date, date) from public, anon;
grant execute on function public.admin_merchant_performance(date, date) to authenticated;

comment on function public.admin_merchant_performance(date, date) is
  'Rendimiento de cada local en un periodo (consumo sin el fee, consumos, personas, nuevas, noches, grupos, mejor noche) y frente al periodo anterior del mismo largo. Solo super admin.';
