-- ============================================================================
-- Ronda — Métricas › Semana › Resumen: lo facturado, su fee y lo que se cobra,
-- noche a noche y local a local
--
-- La sub-pestaña Resumen de Semana contesta cinco cosas de la semana elegida
-- (lunes a domingo, día operativo), de todos los locales o de uno:
--
--   Total facturado      el consumo en los locales, SIN el fee (financed).
--   Service fee + IVA    el fee de esos consumos (payable − financed).
--   Total a cobrar       facturado + service fee + IVA (payable). Solo se
--                        enseña con sus dos sumandos al lado: es un desglose,
--                        no un total suelto.
--   Consumos             consumos confirmados.
--   Usuarios             personas con cuota en esos consumos (en un grupo,
--                        cada una), nunca quien abrió la cuenta.
--
-- cada una frente a la semana anterior a la misma altura y con las ocho
-- últimas semanas para la chispa; y la tabla de consumos por noche y local.
--
-- Qué se añade:
--   · `metricas.semana_resumen_tramo(desde, hasta, local)`: las cifras de un
--     tramo de días. La RPC la llama para cada semana de la chispa (la
--     elegida es la última) y para la anterior a la misma altura, así que la
--     tarjeta, la chispa y la comparación no pueden contarse de dos maneras.
--     No escribe ninguna definición: lee de `metricas.consumos` (consumo, fee,
--     consumos), `metricas.cuotas` (personas) y `metricas.personas_por_local`
--     (nuevas en un local), todas de 20260927500000.
--   · `public.admin_metricas_semana_resumen(p_semana, p_merchant_id)`.
--
-- Cuadra con (lo comprueba supabase/tests/metricas_coherencia_semana_resumen.sql):
--   · `admin_metricas_semanas`: consumo, consumos, personas, ticket y service
--     fee sin IVA de la misma semana y local, y la comparación;
--   · `admin_nights`: cada noche y local (consumos, consumo, personas, nuevas);
--   · `admin_metricas_locales`: las nuevas de la fila de todos;
--   · `admin_metricas_cohortes`: el total a cobrar de la semana es el
--     `a_cobrar` de su cohorte (cuota 1 + cuota 2), con las mismas partes.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las cifras de un tramo de días
-- ---------------------------------------------------------------------------
-- Devuelve {financed_usd, fee_usd, payable_usd, servicio_usd, iva_usd,
-- consumos, ticket_medio_usd, personas, nuevas}:
--   financed_usd  consumo sin fee;  fee_usd = payable − financed (con IVA);
--   servicio_usd  el fee sin IVA (ingreso de Ronda);  iva_usd = fee − servicio;
--   personas      distintas en el tramo: quien vino dos noches cuenta una vez;
--   nuevas        personas cuya primera cuota en un local (en ESE local, con
--                 p_merchant_id) cae en el tramo; quien estrenó dos locales
--                 cuenta una vez.
-- Siempre financed + fee = payable y servicio + iva = fee.

create or replace function metricas.semana_resumen_tramo(
  p_desde       date,
  p_hasta       date,
  p_merchant_id uuid default null
)
returns jsonb
language sql
stable
as $$
  with
  consumo as (
    select count(*)::integer                  as consumos,
           coalesce(sum(k.financed_usd), 0)   as financed,
           coalesce(sum(k.fee_usd), 0)        as fee,
           coalesce(sum(k.payable_usd), 0)    as payable,
           coalesce(sum(k.servicio_usd), 0)   as servicio,
           coalesce(sum(k.iva_usd), 0)        as iva
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
  estrenos as (
    select count(distinct pl.user_id)::integer as nuevas
    from metricas.personas_por_local pl
    where pl.primer_dia between p_desde and p_hasta
      and (p_merchant_id is null or pl.merchant_id = p_merchant_id)
  )
  select jsonb_build_object(
    'financed_usd',     c.financed,
    'fee_usd',          c.fee,
    'payable_usd',      c.payable,
    'servicio_usd',     c.servicio,
    'iva_usd',          c.iva,
    'consumos',         c.consumos,
    'ticket_medio_usd', case when c.consumos > 0 then round(c.financed / c.consumos, 2) end,
    'personas',         p.personas,
    'nuevas',           e.nuevas
  )
  from consumo c, quienes p, estrenos e;
$$;

comment on function metricas.semana_resumen_tramo(date, date, uuid) is
  'Métricas › Semana › Resumen: las cifras de un tramo de días operativos (de todos los locales o de uno). financed_usd = consumo sin fee; fee_usd = payable − financed (con IVA); payable_usd = lo que se cobra (solo con sus dos partes); servicio_usd = fee sin IVA; iva_usd = fee − servicio; consumos; ticket_medio_usd (sin fee); personas por sus cuotas; nuevas = personas cuya primera cuota en un local cae en el tramo (contadas una vez). Lee de metricas.consumos, metricas.cuotas y metricas.personas_por_local.';

revoke all on function metricas.semana_resumen_tramo(date, date, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. La RPC
-- ---------------------------------------------------------------------------
-- `p_semana`: cualquier día de la semana elegida; se lleva a su lunes y una
-- semana futura se queda en la de hoy. La semana en curso cuenta hasta hoy y
-- se compara con los MISMOS días de la anterior («a la misma altura»).
--
-- Devuelve:
--   hoy, local,
--   semana      {desde, hasta, en_curso}       la elegida (lunes y domingo)
--   hasta, dias                                el último día contado y cuántos
--   anterior    {desde, hasta, dias, misma_altura}
--   cifras      tramo(lunes, hasta)            la semana elegida
--   comparacion tramo(anterior)                la anterior a la misma altura
--   semanas     [{desde, hasta, hasta_dato, dias, en_curso, …tramo}]
--               las 8 últimas, de la más vieja a la elegida (la chispa)
--   noches      [{business_date, merchant_id, nombre, consumos, personas,
--                 nuevas, financed_usd, fee_usd, payable_usd, ticket_medio_usd}]
--               una fila por noche y local con consumos, de la más reciente
--               a la más vieja y, en cada noche, de más a menos consumo.
-- La fila de totales de la tabla es `cifras`: sus personas y sus nuevas van
-- recontadas (no son la suma de las filas).

create or replace function public.admin_metricas_semana_resumen(
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
  v_hoy      date    := metricas.hoy();
  v_chispa   integer := 8;
  v_lunes    date;
  v_hasta    date;
  v_dias     integer;
  v_cifras   jsonb;
  v_semanas  jsonb;
  v_noches   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- La semana elegida: nunca una futura.
  v_lunes := metricas.lunes(least(coalesce(p_semana, v_hoy), v_hoy));
  -- Su último día con datos, y cuántos lleva.
  v_hasta := least(v_lunes + 6, v_hoy);
  v_dias  := v_hasta - v_lunes + 1;

  v_cifras := metricas.semana_resumen_tramo(v_lunes, v_hasta, p_merchant_id);

  -- La chispa: las siete anteriores enteras y, al final, la elegida.
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'desde',      s.lunes,
             'hasta',      s.lunes + 6,
             'hasta_dato', s.lunes + 6,
             'dias',       7,
             'en_curso',   false
           ) || metricas.semana_resumen_tramo(s.lunes, s.lunes + 6, p_merchant_id)
           order by s.lunes), '[]'::jsonb)
         || jsonb_build_array(
              jsonb_build_object(
                'desde',      v_lunes,
                'hasta',      v_lunes + 6,
                'hasta_dato', v_hasta,
                'dias',       v_dias,
                'en_curso',   v_lunes + 6 >= v_hoy
              ) || v_cifras)
  into v_semanas
  from (
    select generate_series(v_lunes - 7 * (v_chispa - 1), v_lunes - 7, interval '7 days')::date as lunes
  ) s;

  -- Las noches: una fila por día operativo y local con consumos.
  with
  por_noche as (
    select k.business_date as d, k.merchant_id as mid,
           count(*)::integer    as consumos,
           sum(k.financed_usd)  as financed,
           sum(k.fee_usd)       as fee,
           sum(k.payable_usd)   as payable
    from metricas.consumos k
    where k.business_date between v_lunes and v_hasta
      and (p_merchant_id is null or k.merchant_id = p_merchant_id)
    group by k.business_date, k.merchant_id
  ),
  -- La gente de cada noche: todos los que tienen cuota, no quien abrió.
  gente as (
    select distinct q.business_date as d, q.merchant_id as mid, q.user_id as uid
    from metricas.cuotas q
    where q.business_date between v_lunes and v_hasta
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ),
  -- Nueva = su primera cuota en ESE local es de esa noche (toda su historia).
  por_gente as (
    select g.d, g.mid,
           count(*)::integer                                      as personas,
           (count(*) filter (where pl.primer_dia = g.d))::integer as nuevas
    from gente g
    join metricas.personas_por_local pl on pl.user_id = g.uid and pl.merchant_id = g.mid
    group by g.d, g.mid
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'business_date',    n.d,
             'merchant_id',      n.mid,
             'nombre',           m.name,
             'consumos',         n.consumos,
             'personas',         coalesce(pg.personas, 0),
             'nuevas',           coalesce(pg.nuevas, 0),
             'financed_usd',     n.financed,
             'fee_usd',          n.fee,
             'payable_usd',      n.payable,
             'ticket_medio_usd', round(n.financed / n.consumos, 2)
           )
           order by n.d desc, n.financed desc, m.name), '[]'::jsonb)
  into v_noches
  from por_noche n
  join public.merchants m on m.id = n.mid
  left join por_gente pg on pg.d = n.d and pg.mid = n.mid;

  return jsonb_build_object(
    'hoy',         v_hoy,
    'local',       p_merchant_id,
    'semana',      jsonb_build_object(
                     'desde',    v_lunes,
                     'hasta',    v_lunes + 6,
                     'en_curso', v_lunes + 6 >= v_hoy
                   ),
    'hasta',       v_hasta,
    'dias',        v_dias,
    'anterior',    jsonb_build_object(
                     'desde',        v_lunes - 7,
                     'hasta',        v_lunes - 7 + v_dias - 1,
                     'dias',         v_dias,
                     -- En curso = a la misma altura, también el domingo: su
                     -- noche acaba el lunes a las 10:00 (el criterio de
                     -- admin_metricas_semanas y admin_metricas_locales).
                     'misma_altura', v_lunes + 6 >= v_hoy
                   ),
    'cifras',      v_cifras,
    'comparacion', metricas.semana_resumen_tramo(v_lunes - 7, v_lunes - 7 + v_dias - 1, p_merchant_id),
    'semanas',     v_semanas,
    'noches',      v_noches
  );
end;
$$;

comment on function public.admin_metricas_semana_resumen(date, uuid) is
  'Métricas › Semana › Resumen: de la semana de p_semana (lunes a domingo, día operativo; la en curso hasta hoy), de todos los locales o de uno, el total facturado (financed_usd, sin fee), el service fee con su IVA (fee_usd), el total a cobrar (payable_usd, solo con sus dos partes), los consumos y las personas que consumieron (por sus cuotas); la anterior a la misma altura; las 8 últimas semanas para la chispa; y una fila por noche y local con consumos, personas, nuevas en el local, las tres cifras de dinero y el ticket medio sin fee. Lee de metricas.* (metricas.semana_resumen_tramo).';

revoke all on function public.admin_metricas_semana_resumen(date, uuid) from public, anon;
grant execute on function public.admin_metricas_semana_resumen(date, uuid) to authenticated;
