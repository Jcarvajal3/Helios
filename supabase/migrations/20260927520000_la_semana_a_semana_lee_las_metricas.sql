-- ============================================================================
-- Ronda — Métricas › Semana: la semana a semana lee las métricas
--
-- La pestaña Semana es una tabla: una columna por semana (8, 12 o 26) y una
-- fila por cifra, agrupadas en Consumo, Ingreso de Ronda, Cobro, Riesgo,
-- Gente y Caja, con la semana elegida al final y su cambio frente a la
-- anterior. Encima, cinco cifras con su chispa y una frase. Todo sale de
-- `admin_metricas_semanas`.
--
-- Qué se añade:
--   · `metricas.semana_periodo(desde, hasta, local, juzgado_hasta)`: TODAS
--     las cifras de un tramo de días, en un solo sitio. La RPC la llama una
--     vez por semana y otra para la semana anterior «a la misma altura», así
--     que la columna y la comparación no pueden contarse de dos maneras. No
--     escribe ninguna definición; lee de:
--       - `metricas.consumos`, `cuotas`, `cuotas_al`, `cartera_al`,
--         `personas`, `personas_por_local` (20260927500000) y
--         `cargos_por_atraso` (20260927505000);
--       - `metricas.caja_al` y `metricas.caja_movimientos` (20260927572000,
--         de Métricas › Caja): la caja del libro al cierre y lo transferido a
--         los locales son los de la pestaña Caja, no una copia.
--     Es plpgsql y no sql a propósito: así sus referencias se resuelven al
--     llamarla y no al crearla, y esta migración no depende del orden en que
--     se aplique la de Caja (que va después por número).
--   · `public.admin_metricas_semanas(p_hasta, p_semanas, p_merchant_id)`.
--
-- Las reglas de las cifras:
--   * Semana = lunes a domingo del día operativo. La semana en curso solo
--     cuenta hasta hoy y se compara con los MISMOS días de la anterior
--     («a la misma altura»), nunca con la anterior entera. Lo que es foto (lo
--     vencido, la mora, la caja) se toma al cierre del día equivalente.
--   * Cobrado a tiempo: de las cuotas que vencían en el tramo, las que tienen
--     el plazo cerrado (vencimiento + gracia < hoy), qué parte se pagó a
--     tiempo. Es la definición de `metricas.cuotas` y de
--     `admin_on_time_collection`, agrupada por el día de vencimiento. En la
--     comparación se juzgan solo los mismos días de la semana que en la
--     elegida: si de esta solo se sabe de lunes a jueves, de la anterior
--     también.
--   * Dinero: cada importe que se paga (`payable_usd`) va con `financed_usd` y
--     `fee_usd`. El consumo va sin servicio, el servicio sin IVA y los cargos
--     por atraso aparte; nunca se suman.
--   * Con un local: registros, verificados y la caja no son de ningún local y
--     valen null. Lo transferido sí se parte (lo que se le pagó a ESE local).
--     El primer consumo pasa a ser «nuevo en el local» (su primera cuota en
--     ese local), como en Métricas › Gente. Los cargos por atraso anteriores
--     al 2026-09-02 no tienen cuota ni local y solo salen sin local.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las cifras de un tramo de días
-- ---------------------------------------------------------------------------
-- `p_desde`–`p_hasta`: los días operativos del tramo (una semana, o sus
-- primeros días si está en curso). `p_hasta` no pasa de hoy: lo que es foto
-- se toma al cierre de `p_hasta`, y hoy es «ahora».
-- `p_juzgado_hasta`: el último día de vencimiento cuyo cobro a tiempo se
-- juzga. Sin él, todo el tramo; en cualquier caso solo las cuotas con el
-- plazo cerrado HOY (su veredicto ya no cambia).

create or replace function metricas.semana_periodo(
  p_desde         date,
  p_hasta         date,
  p_merchant_id   uuid default null,
  p_juzgado_hasta date default null
)
returns jsonb
language plpgsql
stable
as $$
begin
  return (
    with
    consumo as (
      select count(*)::integer                      as consumos,
             coalesce(sum(k.financed_usd), 0)       as financed,
             coalesce(sum(k.servicio_usd), 0)       as servicio,
             count(distinct k.merchant_id)::integer as locales
      from metricas.consumos k
      where k.business_date between p_desde and p_hasta
        and (p_merchant_id is null or k.merchant_id = p_merchant_id)
    ),
    quienes as (
      -- Las personas salen de las cuotas: en un grupo, todas las que pagan.
      select count(distinct q.user_id)::integer as personas
      from metricas.cuotas q
      where q.business_date between p_desde and p_hasta
        and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    ),
    atraso as (
      select coalesce(sum(a.amount_usd), 0) as usd, count(*)::integer as cargos
      from metricas.cargos_por_atraso a
      where a.business_date between p_desde and p_hasta
        and (p_merchant_id is null or a.merchant_id = p_merchant_id)
    ),
    juicio as (
      select least(p_hasta, coalesce(p_juzgado_hasta, p_hasta)) as hasta
    ),
    vencian as (
      -- Las cuotas que vencían en el tramo, con su estado de hoy: el
      -- veredicto a tiempo / tarde ya no cambia una vez cerrado el plazo.
      select
        coalesce(sum(q.payable_usd), 0)  as payable,
        coalesce(sum(q.financed_usd), 0) as financed,
        coalesce(sum(q.fee_usd), 0)      as fee,
        count(*)::integer                as cuotas,
        count(*) filter (where q.due_date <= j.hasta and q.plazo_cerrado)::integer   as juzgadas,
        count(*) filter (where q.due_date <= j.hasta and q.plazo_cerrado
                           and q.estado_hoy = 'a_tiempo')::integer                   as a_tiempo,
        count(*) filter (where q.sequence = 1 and q.due_date <= j.hasta
                           and q.plazo_cerrado)::integer                             as juzgadas_1,
        count(*) filter (where q.sequence = 1 and q.due_date <= j.hasta and q.plazo_cerrado
                           and q.estado_hoy = 'a_tiempo')::integer                   as a_tiempo_1,
        count(*) filter (where q.sequence = 2 and q.due_date <= j.hasta
                           and q.plazo_cerrado)::integer                             as juzgadas_2,
        count(*) filter (where q.sequence = 2 and q.due_date <= j.hasta and q.plazo_cerrado
                           and q.estado_hoy = 'a_tiempo')::integer                   as a_tiempo_2
      from metricas.cuotas q
      cross join juicio j
      where q.due_date between p_desde and p_hasta
        and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    ),
    cartera as (
      -- La foto al cierre de `p_hasta`: la mora canónica.
      select * from metricas.cartera_al(p_hasta, p_merchant_id)
    ),
    perdido as (
      -- Lo que se dio por perdido dentro del tramo y seguía sin pagar al cierre.
      select coalesce(sum(q.payable_usd), 0)  as payable,
             coalesce(sum(q.financed_usd), 0) as financed,
             coalesce(sum(q.fee_usd), 0)      as fee,
             count(*)::integer                as cuotas
      from metricas.cuotas_al(p_hasta) q
      where q.estado_hoy = 'perdida'
        and public.helios_business_date(q.written_off_at) between p_desde and p_hasta
        and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    ),
    padron as (
      -- Registros y verificados son del padrón, no de un local.
      select
        count(*) filter (where p.registro_dia between p_desde and p_hasta)::integer   as registros,
        count(*) filter (where p.verificado_dia between p_desde and p_hasta)::integer as verificados,
        count(*) filter (where p.primer_consumo_dia between p_desde and p_hasta)::integer
                                                                                      as primer_consumo
      from metricas.personas p
      where p_merchant_id is null
    ),
    nuevos_en_el_local as (
      select count(*)::integer as primer_consumo
      from metricas.personas_por_local l
      where p_merchant_id is not null
        and l.merchant_id = p_merchant_id
        and l.primer_dia between p_desde and p_hasta
    ),
    movimientos as (
      select m.transferido_usd, m.transferencias
      from metricas.caja_movimientos(p_desde, p_hasta, p_merchant_id) m
    )
    select jsonb_build_object(
      'consumo', jsonb_build_object(
        'financed_usd',     c.financed,
        'consumos',         c.consumos,
        'ticket_medio_usd', round(c.financed / nullif(c.consumos, 0), 2),
        'personas',         w.personas,
        'locales',          c.locales
      ),
      'ingreso', jsonb_build_object(
        'servicio_usd',          c.servicio,
        'cargos_por_atraso_usd', a.usd,
        'cargos_por_atraso',     a.cargos
      ),
      'cobro', jsonb_build_object(
        'vencian', jsonb_build_object(
          'payable_usd',  v.payable,
          'financed_usd', v.financed,
          'fee_usd',      v.fee,
          'cuotas',       v.cuotas
        ),
        'juzgado_hasta', case when j.hasta >= p_desde then j.hasta end,
        'a_tiempo', jsonb_build_object(
          'juzgadas', v.juzgadas,
          'a_tiempo', v.a_tiempo,
          'pct',      round(100.0 * v.a_tiempo / nullif(v.juzgadas, 0), 2)
        ),
        'cuota_1', jsonb_build_object(
          'juzgadas', v.juzgadas_1,
          'a_tiempo', v.a_tiempo_1,
          'pct',      round(100.0 * v.a_tiempo_1 / nullif(v.juzgadas_1, 0), 2)
        ),
        'cuota_2', jsonb_build_object(
          'juzgadas', v.juzgadas_2,
          'a_tiempo', v.a_tiempo_2,
          'pct',      round(100.0 * v.a_tiempo_2 / nullif(v.juzgadas_2, 0), 2)
        )
      ),
      'riesgo', jsonb_build_object(
        'al_cierre_de', p_hasta,
        'vencido', jsonb_build_object(
          'payable_usd',  k.vencido_payable_usd,
          'financed_usd', k.vencido_financed_usd,
          'fee_usd',      k.vencido_fee_usd,
          'cuotas',       k.cuotas_vencidas,
          'personas',     k.personas_vencidas
        ),
        'por_vencer', jsonb_build_object(
          'payable_usd',  k.por_vencer_payable_usd,
          'financed_usd', k.por_vencer_financed_usd,
          'fee_usd',      k.por_vencer_fee_usd
        ),
        'mora_pct', k.mora_pct,
        'perdido', jsonb_build_object(
          'payable_usd',  pe.payable,
          'financed_usd', pe.financed,
          'fee_usd',      pe.fee,
          'cuotas',       pe.cuotas
        )
      ),
      'gente', jsonb_build_object(
        'registros',      case when p_merchant_id is null then g.registros end,
        'verificados',    case when p_merchant_id is null then g.verificados end,
        'primer_consumo', case when p_merchant_id is null then g.primer_consumo else n.primer_consumo end
      ),
      'caja', jsonb_build_object(
        'transferido_a_locales_usd', mv.transferido_usd,
        'pagos_a_locales',           mv.transferencias,
        'en_caja_usd',               case when p_merchant_id is null then metricas.caja_al(p_hasta) end
      )
    )
    from consumo c
    cross join quienes w
    cross join atraso a
    cross join juicio j
    cross join vencian v
    cross join cartera k
    cross join perdido pe
    cross join movimientos mv
    -- Las dos dan siempre una fila (son recuentos); solo se lee la que toca.
    -- La que no toca no recorre nada: su `where` es falso de entrada.
    cross join padron g
    cross join nuevos_en_el_local n
  );
end;
$$;

comment on function metricas.semana_periodo(date, date, uuid, date) is
  'Todas las cifras de Métricas › Semana para los días operativos p_desde..p_hasta (p_hasta <= hoy), de todos los locales o de uno: consumo, ingreso de Helios, cobro (lo que vencía y el cobro a tiempo de lo juzgado hasta p_juzgado_hasta), riesgo al cierre de p_hasta, gente y caja. Lee de metricas.* (la caja, de metricas.caja_al y caja_movimientos); lo que no se parte por local vale null.';

revoke all on function metricas.semana_periodo(date, date, uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. La RPC de la pestaña
-- ---------------------------------------------------------------------------
-- `p_hasta`: cualquier día de la semana elegida (se lleva a su lunes; una
-- futura es la en curso). `p_semanas`: cuántas columnas, de 1 a 52, la
-- elegida la última. `p_merchant_id`: un local, o null para todos.
--
-- Devuelve:
--   hoy, gracia_dias, semanas_pedidas, local,
--   semana      {desde, hasta, en_curso}        la elegida
--   filas       [{desde, hasta, hasta_dato, dias, en_curso, consumo, ingreso,
--                 cobro, riesgo, gente, caja}]   de la más vieja a la elegida
--   comparacion {desde, hasta, dias, misma_altura, juzgado_hasta, …cifras}
--               la semana anterior a la elegida: entera si la elegida ya
--               cerró; sus primeros `dias` días si está en curso.

create or replace function public.admin_metricas_semanas(
  p_hasta       date    default null,
  p_semanas     integer default 8,
  p_merchant_id uuid    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy          date    := metricas.hoy();
  v_gracia       integer := public.helios_on_time_grace_days();
  v_n            integer := greatest(least(coalesce(p_semanas, 8), 52), 1);
  v_lunes        date;
  v_desde        date;
  v_hasta        date;
  v_dias         integer;
  v_juzgado      date;
  v_juzgado_comp date;
  v_filas        jsonb;
  v_comp         jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- La semana elegida: nunca una futura.
  v_lunes := metricas.lunes(least(coalesce(p_hasta, v_hoy), v_hoy));
  v_desde := v_lunes - 7 * (v_n - 1);
  -- Su último día con datos, y cuántos lleva.
  v_hasta := least(v_lunes + 6, v_hoy);
  v_dias  := v_hasta - v_lunes + 1;
  -- El último vencimiento con el plazo cerrado hoy.
  v_juzgado := v_hoy - v_gracia - 1;
  -- En la anterior se juzgan los mismos días de la semana que en la elegida.
  v_juzgado_comp := least(v_hasta, v_juzgado) - 7;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'desde',      s.lunes,
             'hasta',      s.lunes + 6,
             'hasta_dato', least(s.lunes + 6, v_hoy),
             'dias',       least(s.lunes + 6, v_hoy) - s.lunes + 1,
             'en_curso',   s.lunes + 6 >= v_hoy
           ) || metricas.semana_periodo(s.lunes, least(s.lunes + 6, v_hoy), p_merchant_id, v_juzgado)
           order by s.lunes), '[]'::jsonb)
  into v_filas
  from (
    select generate_series(v_desde, v_lunes, interval '7 days')::date as lunes
  ) s;

  v_comp := jsonb_build_object(
              'desde',         v_lunes - 7,
              'hasta',         v_lunes - 7 + v_dias - 1,
              'dias',          v_dias,
              -- En curso = a la misma altura, también el domingo: tiene sus
              -- siete días, pero su noche acaba el lunes a las 10:00 (el
              -- mismo criterio que admin_metricas_locales).
              'misma_altura',  v_lunes + 6 >= v_hoy,
              'juzgado_hasta', case when v_juzgado_comp >= v_lunes - 7 then v_juzgado_comp end
            ) || metricas.semana_periodo(v_lunes - 7, v_lunes - 7 + v_dias - 1, p_merchant_id, v_juzgado_comp);

  return jsonb_build_object(
    'hoy',             v_hoy,
    'gracia_dias',     v_gracia,
    'semanas_pedidas', v_n,
    'local',           p_merchant_id,
    'semana',          jsonb_build_object(
                         'desde',    v_lunes,
                         'hasta',    v_lunes + 6,
                         'en_curso', v_lunes + 6 >= v_hoy
                       ),
    'filas',           v_filas,
    'comparacion',     v_comp
  );
end;
$$;

comment on function public.admin_metricas_semanas(date, integer, uuid) is
  'Métricas › Semana: las cifras de p_semanas semanas (lunes a domingo, día operativo) que acaban en la de p_hasta, de todos los locales o de uno, y la semana anterior a la elegida para compararla (a la misma altura si la elegida está en curso). Consumo, ingreso de Helios, cobro, riesgo al cierre, gente y caja, todo desde metricas.* (metricas.semana_periodo). Todo payable_usd va con financed_usd y fee_usd; lo que no se parte por local vale null.';

revoke all on function public.admin_metricas_semanas(date, integer, uuid) from public, anon;
grant execute on function public.admin_metricas_semanas(date, integer, uuid) to authenticated;
