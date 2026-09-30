-- ============================================================================
-- Ronda — Los locales en la semana (Métricas › Locales)
--
-- La pestaña Locales de Métricas contesta tres preguntas sobre una semana
-- (lunes a domingo del día operativo) y, si se elige uno, sobre un local:
--
--   1. ¿Dónde se consumió y cuánto? Consumo, consumos, personas, ticket,
--      quién estrenaba el local, frente a la semana anterior A LA MISMA
--      ALTURA (un jueves se compara con los cuatro primeros días de la
--      anterior, no con una semana entera).
--   2. ¿Cómo paga su gente? Las cuotas que vencían esa semana y se juzgaron,
--      lo vencido de su gente al cierre de la semana y, por cohorte de
--      consumo, la cuota 1 y la 2.
--   3. ¿Cuánto se le transfiere el lunes? Lo que el cierre del lunes
--      siguiente le paga por las cuotas que vencieron en la semana.
--
-- Todo sale del esquema `metricas` (20260927500000). Esta migración añade
-- una sola definición nueva, la de «lo que se le transfiere a un local en un
-- cierre» (`metricas.locales_cierre`), porque nadie la tenía por semana, y la
-- RPC de la pestaña, `admin_metricas_locales`.
--
-- Reglas que se cumplen en toda la respuesta:
--   * Consumo = financed (sin el servicio de Ronda). Nunca se le suma el fee.
--   * Lo vencido es payable (son cuotas) y va SIEMPRE con su desglose
--     financed + fee.
--   * Personas desde las cuotas (`metricas.cuotas.user_id`), nunca
--     `charges.user_id`. En «Todos», una persona que fue a dos locales cuenta
--     una vez: el total no es la suma de las filas.
--   * Sin cuentas ni locales de prueba.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Lo que se le transfiere a un local en un cierre de caja
-- ---------------------------------------------------------------------------
-- Cada lunes a las 10:00 Ronda le paga a cada local las liquidaciones que
-- vencieron la semana que acaba de cerrar (20260902120000): las de
-- `helios_settlement_run_for(vencimiento) = ese lunes`. Es la misma cuenta que
-- «Pagos a locales» (`admin_settlement_runs`, `admin_run_payables`).
--
-- Mientras la semana no ha terminado, las liquidaciones de los días que
-- faltan todavía no existen: el cron las crea el día que vence cada cuota. Lo
-- que falta se prevé con la misma aritmética que `helios_settlement_outlook`
-- (el tramo de cada cuota con las condiciones del día de la venta y el techo
-- del neto del consumo), restringida a los vencimientos anteriores al cierre.
-- Si se cambia la previsión del outlook, se cambia aquí también: la batería
-- `metricas_coherencia_locales.sql` comprueba que den lo mismo.
--
-- Aparte va lo ATRASADO: liquidaciones de cierres anteriores que siguen sin
-- transferirse. No es de esta semana, pero ese lunes también se paga; es el
-- `overdue_usd` del outlook, y lo pendiente + lo previsto + lo atrasado es el
-- «toca pagar este lunes» de Caja (`next_run_usd`). Solo tiene sentido para
-- un cierre que no ha llegado: del pasado no se sabe qué se debía entonces.

drop function if exists metricas.locales_cierre(date);

create or replace function metricas.locales_cierre(p_cierre date)
returns table (
  merchant_id      uuid,
  generado_usd     numeric,
  transferido_usd  numeric,
  pendiente_usd    numeric,
  previsto_usd     numeric,
  atrasado_usd     numeric
)
language sql
stable
as $$
  with
  cal as (
    select metricas.hoy() as hoy
  ),
  -- Lo que ya se generó para ese cierre.
  generado as (
    select s.merchant_id                                                         as mid,
           sum(s.amount_usd)                                                     as generado,
           sum(s.paid_usd)                                                       as transferido,
           coalesce(sum(s.amount_usd - s.paid_usd)
                    filter (where s.status in ('pending', 'partial')), 0)        as pendiente
    from public.settlements s
    where public.helios_settlement_run_for(coalesce(s.due_date, s.business_date)) = p_cierre
    group by s.merchant_id
  ),
  -- Lo que el cron generará de aquí al cierre (solo si el cierre no ha
  -- llegado). Copia de la parte «u» de `helios_settlement_outlook`: el tramo
  -- se calcula sobre TODOS los vencimientos futuros del consumo (el techo del
  -- neto se reparte en orden) y después se quedan los de antes del cierre.
  previsto as (
    select f.mid, sum(f.amount_usd) as previsto
    from (
      select d.mid,
             d.due_date,
             greatest(0, least(
               d.tranche,
               d.room - coalesce(sum(d.tranche) over (
                 partition by d.charge_id order by d.due_date
                 rows between unbounded preceding and 1 preceding
               ), 0)
             )) as amount_usd
      from (
        select distinct
          c.id                                                                  as charge_id,
          c.merchant_id                                                         as mid,
          i.due_date,
          round(coalesce(c.merchant_net_usd, c.amount_usd) * t.per_installment_pct / 100, 4) as tranche,
          coalesce(c.merchant_net_usd, c.amount_usd) - coalesce((
            select sum(s2.amount_usd)
            from public.settlements s2
            where s2.charge_id = c.id
          ), 0)                                                                 as room
        from public.installments i
        join public.charges c on c.id = i.charge_id
        cross join cal
        cross join lateral public.helios_terms_at(c.merchant_id, coalesce(c.business_date, cal.hoy)) t
        where t.policy = 'scheduled'
          and i.due_date >= cal.hoy
          and p_cierre > cal.hoy
          and not exists (
            select 1 from public.settlements s3
            where s3.charge_id = c.id
              and s3.reason = 'scheduled_installment'
              and s3.business_date = i.due_date
          )
      ) d
    ) f
    where f.amount_usd > 0
      and f.due_date < p_cierre
    group by f.mid
  ),
  -- Lo de cierres anteriores que sigue sin transferirse, como el outlook.
  atrasado as (
    select s.merchant_id as mid, sum(s.amount_usd - s.paid_usd) as atrasado
    from public.settlements s
    cross join cal
    where p_cierre > cal.hoy
      and s.status in ('pending', 'partial')
      and public.helios_settlement_run_for(s.due_date) < p_cierre
    group by s.merchant_id
  ),
  ids as (
    select g.mid from generado g
    union select p.mid from previsto p
    union select a.mid from atrasado a
  )
  select
    i.mid,
    coalesce(g.generado, 0)::numeric,
    coalesce(g.transferido, 0)::numeric,
    coalesce(g.pendiente, 0)::numeric,
    coalesce(p.previsto, 0)::numeric,
    coalesce(a.atrasado, 0)::numeric
  from ids i
  left join generado g on g.mid = i.mid
  left join previsto p on p.mid = i.mid
  left join atrasado a on a.mid = i.mid;
$$;

comment on function metricas.locales_cierre(date) is
  'Lo que el cierre de caja del lunes p_cierre le transfiere a cada local: generado_usd (liquidaciones ya creadas con helios_settlement_run_for(vencimiento) = p_cierre, como Pagos a locales), transferido_usd y pendiente_usd de ellas, y previsto_usd (lo que el cron creará antes del cierre, con la aritmética de helios_settlement_outlook; 0 si el cierre ya pasó). Se le transfiere = generado + previsto. Aparte, atrasado_usd: lo de cierres anteriores sin transferir (el overdue_usd del outlook; 0 si el cierre ya pasó). Incluye locales de prueba: quien lo lee los quita.';

revoke all on function metricas.locales_cierre(date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. La pestaña Locales
-- ---------------------------------------------------------------------------
-- admin_metricas_locales(p_semana, p_merchant_id) → jsonb
--
--   semana      {desde, hasta, en_curso}: la semana usada (lunes y domingo).
--   hoy         el día operativo de hoy.
--   hasta       el último día contado (hoy si la semana está en curso).
--   dias        días operativos contados.
--   anterior    {desde, hasta, misma_altura}: contra qué se compara.
--   cierre      {lunes, pasado}: el cierre de caja que paga la semana.
--   gracia_dias los días de gracia de «a tiempo».
--   local       el local pedido, o null.
--   locales     una fila por local (o solo el pedido): ver abajo.
--   totales     la misma fila para todos los locales juntos (con o sin local
--               pedido: da la parte de cada uno). Las personas y las nuevas
--               son distintas, no la suma de las filas.
--   series      {semanas: 12 lunes hasta la elegida, locales: [{merchant_id,
--               nombre, primer_consumo, consumo_usd[], consumos[],
--               personas[], nuevas[]}]}. La última semana va a medias si
--               está en curso.
--   cohortes    {semanas: 8 lunes hasta la elegida, locales: [{merchant_id,
--               nombre, semanas: [{semana, cuota_1, cuota_2}]}]}: las cuotas
--               de lo consumido en cada semana, con su estado de hoy.
--
-- Fila de un local:
--   merchant_id, nombre, estado, ciudad,
--   consumo_usd (financed), consumos, ticket_medio_usd (null sin consumos),
--   consumo_anterior_usd, consumos_anteriores (a la misma altura),
--   personas, nuevas (su primera cuota en ESE local es de esta semana),
--   noches, consumos_en_grupo, mejor_noche {fecha, consumo_usd} | null,
--   parte_pct (de todo el consumo de la semana; null sin consumo),
--   a_tiempo {vencen, juzgadas, a_tiempo, pct}: las cuotas de su gente que
--     vencían en la semana; juzgadas = con el plazo cerrado; pct null sin
--     juzgadas,
--   vencido {payable_usd, financed_usd, fee_usd, cuotas, personas}: lo
--     vencido de su gente al cierre de la semana (hoy si está en curso),
--   transferencia {generado_usd, transferido_usd, pendiente_usd,
--     previsto_usd, atrasado_usd}: el cierre del lunes siguiente. Se le
--     transfiere = generado + previsto; ese lunes se le paga además lo
--     atrasado de cierres anteriores (solo si el cierre no ha llegado).
--
-- Cuota de una cohorte: {cuotas, juzgadas, a_tiempo_juzgadas, pct_a_tiempo,
--   a_tiempo, tarde, vencidas, por_vencer, perdidas, vencido {payable_usd,
--   financed_usd, fee_usd}}.

create or replace function public.admin_metricas_locales(
  p_semana      date default null,
  p_merchant_id uuid default null
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
  v_lunes        date;
  v_domingo      date;
  v_hasta        date;
  v_en_curso     boolean;
  v_ant_desde    date;
  v_ant_hasta    date;
  v_cierre       date;
  v_serie_desde  date;
  v_coh_desde    date;
  v_out          jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- La semana pedida, llevada a su lunes. Nunca una futura: la de hoy.
  v_lunes       := least(metricas.lunes(coalesce(p_semana, v_hoy)), metricas.lunes(v_hoy));
  v_domingo     := v_lunes + 6;
  v_hasta       := least(v_domingo, v_hoy);
  v_en_curso    := v_domingo >= v_hoy;
  -- A la misma altura: los mismos días de la semana anterior.
  v_ant_desde   := v_lunes - 7;
  v_ant_hasta   := v_hasta - 7;
  -- El cierre de caja que paga lo que vence en la semana.
  v_cierre      := v_domingo + 1;
  v_serie_desde := v_lunes - 7 * 11;
  v_coh_desde   := v_lunes - 7 * 7;

  with
  m as (
    select mm.id, mm.name, mm.status::text as estado, mm.city
    from public.merchants mm
    where not mm.is_test
      and (p_merchant_id is null or mm.id = p_merchant_id)
  ),
  -- Las cuotas que hacen falta, leídas una vez: las de lo consumido desde la
  -- primera semana de la serie (incluye las que vencen esta semana).
  cq as (
    select q.merchant_id, q.user_id, q.business_date, q.semana, q.sequence,
           q.due_date, q.estado_hoy, q.plazo_cerrado,
           q.payable_usd, q.financed_usd, q.fee_usd
    from metricas.cuotas q
    where q.business_date between v_serie_desde and v_hasta
  ),
  ppl as (
    select pl.user_id, pl.merchant_id, pl.primer_semana
    from metricas.personas_por_local pl
  ),

  -- ── La semana, local a local ─────────────────────────────────────────────
  sem as (
    select k.merchant_id                                  as mid,
           count(*)::integer                              as consumos,
           sum(k.financed_usd)                            as consumo,
           count(distinct k.business_date)::integer       as noches,
           (count(*) filter (where k.es_grupo))::integer  as en_grupo
    from metricas.consumos k
    where k.business_date between v_lunes and v_hasta
    group by k.merchant_id
  ),
  ant as (
    select k.merchant_id as mid, count(*)::integer as consumos, sum(k.financed_usd) as consumo
    from metricas.consumos k
    where k.business_date between v_ant_desde and v_ant_hasta
    group by k.merchant_id
  ),
  gente as (
    select distinct c.merchant_id as mid, c.user_id as uid
    from cq c
    where c.business_date between v_lunes and v_hasta
  ),
  por_gente as (
    select g.mid,
           count(*)::integer                                              as personas,
           (count(*) filter (where p.primer_semana = v_lunes))::integer   as nuevas
    from gente g
    join ppl p on p.user_id = g.uid and p.merchant_id = g.mid
    group by g.mid
  ),
  por_noche as (
    select k.merchant_id as mid, k.business_date as d, sum(k.financed_usd) as consumo
    from metricas.consumos k
    where k.business_date between v_lunes and v_hasta
    group by k.merchant_id, k.business_date
  ),
  mejor as (
    select distinct on (n.mid) n.mid, n.d, n.consumo
    from por_noche n
    order by n.mid, n.consumo desc, n.d desc
  ),
  -- Las cuotas que vencían en la semana y si se cobraron a tiempo. Solo se
  -- juzgan las que ya cerraron su plazo (vencimiento + gracia < hoy).
  vencen as (
    select c.merchant_id as mid,
           count(*)::integer                                                          as vencen,
           (count(*) filter (where c.plazo_cerrado))::integer                         as juzgadas,
           (count(*) filter (where c.plazo_cerrado and c.estado_hoy = 'a_tiempo'))::integer as a_tiempo
    from cq c
    where c.due_date between v_lunes and v_domingo
    group by c.merchant_id
  ),
  -- Lo vencido de su gente al cierre de la semana: el estado canónico
  -- (`estado_hoy = 'vencida'` de `cuotas_al`), como `metricas.cartera_al`.
  cartera as (
    select q.merchant_id as mid,
           sum(q.payable_usd)  filter (where q.estado_hoy = 'vencida')                as payable,
           sum(q.financed_usd) filter (where q.estado_hoy = 'vencida')                as financed,
           sum(q.fee_usd)      filter (where q.estado_hoy = 'vencida')                as fee,
           (count(*) filter (where q.estado_hoy = 'vencida'))::integer                as cuotas,
           (count(distinct q.user_id) filter (where q.estado_hoy = 'vencida'))::integer as personas
    from metricas.cuotas_al(v_domingo) q
    group by q.merchant_id
  ),
  cierre as (
    select lc.merchant_id as mid, lc.generado_usd, lc.transferido_usd, lc.pendiente_usd, lc.previsto_usd,
           lc.atrasado_usd
    from metricas.locales_cierre(v_cierre) lc
  ),
  por_local as (
    select m.id                                 as mid,
           m.name                               as nombre,
           m.estado,
           m.city                               as ciudad,
           coalesce(s.consumo, 0)::numeric      as consumo,
           coalesce(s.consumos, 0)              as consumos,
           coalesce(a.consumo, 0)::numeric      as consumo_ant,
           coalesce(a.consumos, 0)              as consumos_ant,
           coalesce(pg.personas, 0)             as personas,
           coalesce(pg.nuevas, 0)               as nuevas,
           coalesce(s.noches, 0)                as noches,
           coalesce(s.en_grupo, 0)              as en_grupo,
           mj.d                                 as mejor_dia,
           mj.consumo                           as mejor_consumo,
           coalesce(v.vencen, 0)                as vencen,
           coalesce(v.juzgadas, 0)              as juzgadas,
           coalesce(v.a_tiempo, 0)              as a_tiempo,
           coalesce(ca.payable, 0)::numeric     as venc_payable,
           coalesce(ca.financed, 0)::numeric    as venc_financed,
           coalesce(ca.fee, 0)::numeric         as venc_fee,
           coalesce(ca.cuotas, 0)               as venc_cuotas,
           coalesce(ca.personas, 0)             as venc_personas,
           coalesce(ci.generado_usd, 0)         as generado,
           coalesce(ci.transferido_usd, 0)      as transferido,
           coalesce(ci.pendiente_usd, 0)        as pendiente,
           coalesce(ci.previsto_usd, 0)         as previsto,
           coalesce(ci.atrasado_usd, 0)         as atrasado
    from m
    left join sem       s  on s.mid  = m.id
    left join ant       a  on a.mid  = m.id
    left join por_gente pg on pg.mid = m.id
    left join mejor     mj on mj.mid = m.id
    left join vencen    v  on v.mid  = m.id
    left join cartera   ca on ca.mid = m.id
    left join cierre    ci on ci.mid = m.id
    -- Salen los activos (vender cero es un dato) y todo local con algo que
    -- contar esta semana: así la suma de las filas es el total.
    where p_merchant_id is not null
       or m.estado = 'active'
       or coalesce(s.consumos, 0) > 0
       or coalesce(a.consumos, 0) > 0
       or coalesce(v.vencen, 0) > 0
       or coalesce(ca.cuotas, 0) > 0
       or coalesce(ci.generado_usd, 0) > 0
       or coalesce(ci.previsto_usd, 0) > 0
       or coalesce(ci.atrasado_usd, 0) > 0
  ),

  -- ── Todos los locales juntos ─────────────────────────────────────────────
  -- Recontado y no sumado: las personas y las nuevas son distintas.
  todos as (
    select
      (select coalesce(sum(k.financed_usd), 0) from metricas.consumos k
        where k.business_date between v_lunes and v_hasta)::numeric                    as consumo,
      (select count(*) from metricas.consumos k
        where k.business_date between v_lunes and v_hasta)::integer                    as consumos,
      (select coalesce(sum(k.financed_usd), 0) from metricas.consumos k
        where k.business_date between v_ant_desde and v_ant_hasta)::numeric            as consumo_ant,
      (select count(*) from metricas.consumos k
        where k.business_date between v_ant_desde and v_ant_hasta)::integer            as consumos_ant,
      (select count(distinct g.uid) from gente g)::integer                             as personas,
      (select count(distinct g.uid) from gente g
        join ppl p on p.user_id = g.uid and p.merchant_id = g.mid
        where p.primer_semana = v_lunes)::integer                                      as nuevas,
      (select count(distinct k.business_date) from metricas.consumos k
        where k.business_date between v_lunes and v_hasta)::integer                    as noches,
      (select count(*) from metricas.consumos k
        where k.business_date between v_lunes and v_hasta and k.es_grupo)::integer     as en_grupo,
      (select coalesce(sum(v.vencen), 0) from vencen v)::integer                       as vencen,
      (select coalesce(sum(v.juzgadas), 0) from vencen v)::integer                     as juzgadas,
      (select coalesce(sum(v.a_tiempo), 0) from vencen v)::integer                     as a_tiempo
  ),
  todos_noche as (
    select k.business_date as d, sum(k.financed_usd) as consumo
    from metricas.consumos k
    where k.business_date between v_lunes and v_hasta
    group by k.business_date
    order by sum(k.financed_usd) desc, k.business_date desc
    limit 1
  ),
  todos_cartera as (
    select * from metricas.cartera_al(v_domingo, null)
  ),
  todos_cierre as (
    select coalesce(sum(ci.generado_usd), 0)    as generado,
           coalesce(sum(ci.transferido_usd), 0) as transferido,
           coalesce(sum(ci.pendiente_usd), 0)   as pendiente,
           coalesce(sum(ci.previsto_usd), 0)    as previsto,
           coalesce(sum(ci.atrasado_usd), 0)    as atrasado
    from cierre ci
    join public.merchants mm on mm.id = ci.mid and not mm.is_test
  ),
  filas as (
    select 0 as orden, pl.* from por_local pl
    union all
    select 1, null::uuid, 'Todos los locales', null::text, null::text,
           t.consumo, t.consumos, t.consumo_ant, t.consumos_ant, t.personas, t.nuevas,
           t.noches, t.en_grupo, tn.d, tn.consumo,
           t.vencen, t.juzgadas, t.a_tiempo,
           tc.vencido_payable_usd, tc.vencido_financed_usd, tc.vencido_fee_usd,
           tc.cuotas_vencidas, tc.personas_vencidas,
           tx.generado, tx.transferido, tx.pendiente, tx.previsto, tx.atrasado
    from todos t
    cross join todos_cartera tc
    cross join todos_cierre tx
    left join todos_noche tn on true
  ),
  como_json as (
    select f.orden, f.mid, f.consumo, f.nombre,
      jsonb_build_object(
        'merchant_id',          f.mid,
        'nombre',               f.nombre,
        'estado',               f.estado,
        'ciudad',               f.ciudad,
        'consumo_usd',          f.consumo,
        'consumos',             f.consumos,
        'ticket_medio_usd',     case when f.consumos > 0 then round(f.consumo / f.consumos, 2) end,
        'consumo_anterior_usd', f.consumo_ant,
        'consumos_anteriores',  f.consumos_ant,
        'personas',             f.personas,
        'nuevas',               f.nuevas,
        'noches',               f.noches,
        'consumos_en_grupo',    f.en_grupo,
        'mejor_noche',          case when f.mejor_dia is not null
                                  then jsonb_build_object('fecha', f.mejor_dia, 'consumo_usd', f.mejor_consumo) end,
        'parte_pct',            case when t.consumo > 0 then round(100 * f.consumo / t.consumo, 2) end,
        'a_tiempo', jsonb_build_object(
          'vencen',   f.vencen,
          'juzgadas', f.juzgadas,
          'a_tiempo', f.a_tiempo,
          'pct',      case when f.juzgadas > 0 then round(100.0 * f.a_tiempo / f.juzgadas, 1) end
        ),
        'vencido', jsonb_build_object(
          'payable_usd',  f.venc_payable,
          'financed_usd', f.venc_financed,
          'fee_usd',      f.venc_fee,
          'cuotas',       f.venc_cuotas,
          'personas',     f.venc_personas
        ),
        'transferencia', jsonb_build_object(
          'generado_usd',    f.generado,
          'transferido_usd', f.transferido,
          'pendiente_usd',   f.pendiente,
          'previsto_usd',    f.previsto,
          'atrasado_usd',    f.atrasado
        )
      ) as j
    from filas f
    cross join todos t
  ),

  -- ── Doce semanas, local a local ──────────────────────────────────────────
  semanas as (
    select generate_series(v_serie_desde, v_lunes, interval '7 days')::date as s
  ),
  serie_k as (
    select k.merchant_id as mid, k.semana as s, sum(k.financed_usd) as consumo, count(*)::integer as consumos
    from metricas.consumos k
    where k.business_date between v_serie_desde and v_hasta
    group by k.merchant_id, k.semana
  ),
  serie_p as (
    select c.merchant_id as mid, c.semana as s, count(distinct c.user_id)::integer as personas
    from cq c
    group by c.merchant_id, c.semana
  ),
  serie_n as (
    select p.merchant_id as mid, p.primer_semana as s, count(*)::integer as nuevas
    from ppl p
    where p.primer_semana between v_serie_desde and v_lunes
    group by p.merchant_id, p.primer_semana
  ),
  primer as (
    select k.merchant_id as mid, min(k.business_date) as d
    from metricas.consumos k
    group by k.merchant_id
  ),
  serie_locales as (
    select m.id as mid, m.name as nombre,
           coalesce((select sum(sk.consumo) from serie_k sk where sk.mid = m.id), 0) as consumo
    from m
    where p_merchant_id is not null
       or exists (select 1 from serie_k sk where sk.mid = m.id)
  ),

  -- ── Cohortes de consumo, local a local ───────────────────────────────────
  coh_semanas as (
    select generate_series(v_coh_desde, v_lunes, interval '7 days')::date as s
  ),
  coh as (
    select c.merchant_id as mid, c.semana as s, c.sequence as n,
           jsonb_build_object(
             'cuotas',            count(*),
             'juzgadas',          count(*) filter (where c.plazo_cerrado),
             'a_tiempo_juzgadas', count(*) filter (where c.plazo_cerrado and c.estado_hoy = 'a_tiempo'),
             'pct_a_tiempo',      case when count(*) filter (where c.plazo_cerrado) > 0
                                    then round(100.0 * count(*) filter (where c.plazo_cerrado and c.estado_hoy = 'a_tiempo')
                                               / count(*) filter (where c.plazo_cerrado), 1) end,
             'a_tiempo',          count(*) filter (where c.estado_hoy = 'a_tiempo'),
             'tarde',             count(*) filter (where c.estado_hoy = 'tarde'),
             'vencidas',          count(*) filter (where c.estado_hoy = 'vencida'),
             'por_vencer',        count(*) filter (where c.estado_hoy = 'por_vencer'),
             'perdidas',          count(*) filter (where c.estado_hoy = 'perdida'),
             'vencido', jsonb_build_object(
               'payable_usd',  coalesce(sum(c.payable_usd)  filter (where c.estado_hoy = 'vencida'), 0),
               'financed_usd', coalesce(sum(c.financed_usd) filter (where c.estado_hoy = 'vencida'), 0),
               'fee_usd',      coalesce(sum(c.fee_usd)      filter (where c.estado_hoy = 'vencida'), 0)
             )
           ) as j
    from cq c
    where c.semana between v_coh_desde and v_lunes
    group by c.merchant_id, c.semana, c.sequence
  ),
  coh_locales as (
    select m.id as mid, m.name as nombre,
           coalesce((select sum(sk.consumo) from serie_k sk
                     where sk.mid = m.id and sk.s between v_coh_desde and v_lunes), 0) as consumo
    from m
    where p_merchant_id is not null
       or exists (select 1 from coh where coh.mid = m.id)
  )

  select jsonb_build_object(
    'semana',      jsonb_build_object('desde', v_lunes, 'hasta', v_domingo, 'en_curso', v_en_curso),
    'hoy',         v_hoy,
    'hasta',       v_hasta,
    'dias',        v_hasta - v_lunes + 1,
    'anterior',    jsonb_build_object('desde', v_ant_desde, 'hasta', v_ant_hasta, 'misma_altura', v_en_curso),
    'cierre',      jsonb_build_object('lunes', v_cierre, 'pasado', v_cierre <= v_hoy),
    'gracia_dias', v_gracia,
    'local',       p_merchant_id,
    'locales',     coalesce((
                     select jsonb_agg(cj.j order by cj.consumo desc, cj.nombre)
                     from como_json cj where cj.orden = 0
                   ), '[]'::jsonb),
    'totales',     (select cj.j from como_json cj where cj.orden = 1),
    'series', jsonb_build_object(
      'semanas', (select jsonb_agg(w.s order by w.s) from semanas w),
      'locales', coalesce((
        select jsonb_agg(jsonb_build_object(
          'merchant_id',    sl.mid,
          'nombre',         sl.nombre,
          'primer_consumo', pr.d,
          'consumo_usd',    (select jsonb_agg(coalesce(sk.consumo, 0) order by w.s)
                             from semanas w left join serie_k sk on sk.mid = sl.mid and sk.s = w.s),
          'consumos',       (select jsonb_agg(coalesce(sk.consumos, 0) order by w.s)
                             from semanas w left join serie_k sk on sk.mid = sl.mid and sk.s = w.s),
          'personas',       (select jsonb_agg(coalesce(sp.personas, 0) order by w.s)
                             from semanas w left join serie_p sp on sp.mid = sl.mid and sp.s = w.s),
          'nuevas',         (select jsonb_agg(coalesce(sn.nuevas, 0) order by w.s)
                             from semanas w left join serie_n sn on sn.mid = sl.mid and sn.s = w.s)
        ) order by sl.consumo desc, sl.nombre)
        from serie_locales sl
        left join primer pr on pr.mid = sl.mid
      ), '[]'::jsonb)
    ),
    'cohortes', jsonb_build_object(
      'semanas', (select jsonb_agg(w.s order by w.s) from coh_semanas w),
      'locales', coalesce((
        select jsonb_agg(jsonb_build_object(
          'merchant_id', cl.mid,
          'nombre',      cl.nombre,
          'semanas',     (select jsonb_agg(jsonb_build_object(
                                   'semana',  w.s,
                                   'cuota_1', c1.j,
                                   'cuota_2', c2.j
                                 ) order by w.s)
                          from coh_semanas w
                          left join coh c1 on c1.mid = cl.mid and c1.s = w.s and c1.n = 1
                          left join coh c2 on c2.mid = cl.mid and c2.s = w.s and c2.n = 2)
        ) order by cl.consumo desc, cl.nombre)
        from coh_locales cl
      ), '[]'::jsonb)
    )
  )
  into v_out;

  return v_out;
end;
$$;

comment on function public.admin_metricas_locales(date, uuid) is
  'Métricas › Locales. Una semana (lunes a domingo del día operativo; nunca futura) de todos los locales o de uno: por local, consumo sin servicio, consumos, ticket, personas con cuota, nuevas en ese local, frente a la semana anterior a la misma altura, cuotas que vencían en la semana y a tiempo (plazo cerrado), lo vencido de su gente al cierre con su desglose, y lo que le transfiere el cierre del lunes siguiente (metricas.locales_cierre); los totales recontados; la serie de 12 semanas y las cohortes de 8 con la cuota 1 y la 2. Lee de metricas.';

revoke all on function public.admin_metricas_locales(date, uuid) from public, anon;
grant execute on function public.admin_metricas_locales(date, uuid) to authenticated;
