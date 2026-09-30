-- ============================================================================
-- Ronda — Métricas › Semana: la semana en curso se compara con la anterior
-- HASTA EL MISMO MOMENTO (agente AUD-SEMANA-GLOBAL, 27-09)
--
-- El fallo. «A la misma altura» comparaba los mismos DÍAS operativos: la
-- semana en curso, con su último día a medias, contra los mismos días de la
-- anterior ENTEROS. En un negocio de noche el día operativo (de 10:00 a
-- 10:00) casi no tiene consumo hasta la tarde, así que la anterior llevaba
-- una noche entera de más. En dev (semilla), el sábado 26 a las 15:00 el
-- consumo salía un 29 % por DEBAJO de la anterior (€724,50 frente a
-- €1.015,50) cuando a la misma hora iba un 17 % por ENCIMA (frente a
-- €617,50). El signo del cambio se daba la vuelta.
--
-- El arreglo. Si la semana elegida está en curso, la anterior cuenta sus
-- flujos solo hasta `now() − 7 días` (`p_corte`):
--   · consumo, consumos, ticket, service fee, locales: `confirmed_at`;
--   · usuarios y nuevos (en Ronda o en el local): la cuota de un consumo
--     confirmado antes del corte;
--   · cargos por atraso: `late_fees.created_at`;
--   · dado por perdido: `written_off_at`;
--   · registros: `solicitudes.verificado_en`; solicitaron: `solicito_en`;
--   · transferido a locales: `merchant_payouts.created_at`.
-- En prod y en dev el día operativo de cada uno de esos instantes es su
-- `business_date` (comprobado): el corte no mueve nada de los días
-- anteriores, solo recorta el último.
--
-- Lo que NO cambia:
--   · Lo que vencía y el cobro a tiempo van por FECHA de vencimiento y ya se
--     juzgaban en los mismos días.
--   · Las fotos (vencido, por vencer, mora, caja) siguen al cierre del día
--     equivalente de la anterior (`cartera_al` y `caja_al` van por días).
--     En dev la diferencia con la foto exacta es de menos de medio punto de
--     mora; se documenta en la ayuda.
--   · Las columnas de la tabla (la anterior entera) y las semanas cerradas.
--
-- Qué se toca (copiadas de su ÚLTIMA migración, con reemplazos exactos; las
-- genera <scratchpad AUD-SEMANA-GLOBAL>/aud/gen_660.cjs):
--   metricas.semana_periodo            (20260927591000) + p_corte
--   public.admin_metricas_semanas      (20260927520000) comparacion.corte
--   metricas.semana_resumen_tramo      (20260927640000) + p_corte
--   public.admin_metricas_semana_resumen (20260927640000) anterior.corte
-- Ninguna clave JSON se quita; se añade `corte` (timestamptz o null).
-- Las dos funciones de `metricas` cambian de firma: se borra la vieja
-- antes (las llaman funciones plpgsql, que no dejan dependencia).
--
-- Idempotente.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las cifras de un tramo de Semana › Rendimiento, con su corte
-- ---------------------------------------------------------------------------

drop function if exists metricas.semana_periodo(date, date, uuid, date);

create or replace function metricas.semana_periodo(
  p_desde         date,
  p_hasta         date,
  p_merchant_id   uuid default null,
  p_juzgado_hasta date default null,
  p_corte         timestamptz default null
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
        and (p_corte is null or k.confirmed_at <= p_corte)
    ),
    quienes as (
      -- Las personas salen de las cuotas: en un grupo, todas las que pagan.
      select count(distinct q.user_id)::integer as personas
      from metricas.cuotas q
      where q.business_date between p_desde and p_hasta
        and (p_merchant_id is null or q.merchant_id = p_merchant_id)
        and (p_corte is null or exists (
              select 1 from metricas.consumos k
              where k.charge_id = q.charge_id and k.confirmed_at <= p_corte))
    ),
    atraso as (
      select coalesce(sum(a.amount_usd), 0) as usd, count(*)::integer as cargos
      from metricas.cargos_por_atraso a
      where a.business_date between p_desde and p_hasta
        and (p_merchant_id is null or a.merchant_id = p_merchant_id)
        -- El instante en que se cargó: la vista no lo trae.
        and (p_corte is null or exists (
              select 1 from public.late_fees lf
              where lf.id = a.late_fee_id and lf.created_at <= p_corte))
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
        and (p_corte is null or q.written_off_at <= p_corte)
        and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    ),
    padron as (
      -- Los registros (personas verificadas, por el día en que se aprobó su
      -- verificación) son del padrón, no de un local. `verificados` es la
      -- misma cifra y se queda por quien ya la lee.
      -- Con p_corte, solo lo que ya había pasado en ese instante: la
      -- verificación aprobada antes (`solicitudes.verificado_en`, el mismo
      -- instante que da el día de registro) y el primer consumo confirmado
      -- antes.
      select
        count(*) filter (where p.registro_dia between p_desde and p_hasta
                           and p.a_tiempo_del_corte)::integer                          as registros,
        count(*) filter (where p.verificado_dia between p_desde and p_hasta
                           and p.a_tiempo_del_corte)::integer                          as verificados,
        count(*) filter (where p.primer_consumo_dia between p_desde and p_hasta
                           and p.consumio_antes_del_corte)::integer                    as primer_consumo
      from (
        select pe.registro_dia, pe.verificado_dia, pe.primer_consumo_dia,
               (p_corte is null or s.verificado_en <= p_corte) as a_tiempo_del_corte,
               (p_corte is null or exists (
                  select 1 from metricas.cuotas q
                  join metricas.consumos k on k.charge_id = q.charge_id
                  where q.user_id = pe.user_id and k.confirmed_at <= p_corte)) as consumio_antes_del_corte
        from metricas.personas pe
        left join metricas.solicitudes s on p_corte is not null and s.user_id = pe.user_id
        where p_merchant_id is null
      ) p
    ),
    solicitudes as (
      -- Quien pidió el código en el tramo, se verificara o no: la boca del
      -- embudo. No es un registro. Tampoco es de ningún local.
      select count(*)::integer as solicitaron
      from metricas.solicitudes s
      where p_merchant_id is null
        and s.solicito_dia between p_desde and p_hasta
        and (p_corte is null or s.solicito_en <= p_corte)
    ),
    nuevos_en_el_local as (
      select count(*)::integer as primer_consumo
      from metricas.personas_por_local l
      where p_merchant_id is not null
        and l.merchant_id = p_merchant_id
        and l.primer_dia between p_desde and p_hasta
        and (p_corte is null or exists (
              select 1 from metricas.cuotas q
              join metricas.consumos k on k.charge_id = q.charge_id
              where q.user_id = l.user_id and q.merchant_id = l.merchant_id
                and k.confirmed_at <= p_corte))
    ),
    movimientos as (
      -- Con p_corte, sin los pagos a locales apuntados después de ese
      -- instante: el mismo conjunto que cuenta caja_movimientos (locales que
      -- no son de prueba, por su día operativo), menos los que aún no
      -- estaban.
      select m.transferido_usd - t.usd as transferido_usd,
             m.transferencias - t.n    as transferencias
      from metricas.caja_movimientos(p_desde, p_hasta, p_merchant_id) m
      cross join (
        select coalesce(sum(mp.amount_usd), 0) as usd, count(*)::integer as n
        from public.merchant_payouts mp
        join public.merchants me on me.id = mp.merchant_id
        where p_corte is not null
          and mp.created_at > p_corte
          and not me.is_test
          and mp.business_date between p_desde and p_hasta
          and (p_merchant_id is null or mp.merchant_id = p_merchant_id)
      ) t
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
        'solicitaron',    case when p_merchant_id is null then so.solicitaron end,
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
    -- Las tres dan siempre una fila (son recuentos); solo se lee la que
    -- toca. La que no toca no recorre nada: su `where` es falso de entrada.
    cross join padron g
    cross join solicitudes so
    cross join nuevos_en_el_local n
  );
end;
$$;

comment on function metricas.semana_periodo(date, date, uuid, date, timestamptz) is
  'Todas las cifras de Métricas › Semana para los días operativos p_desde..p_hasta (p_hasta <= hoy), de todos los locales o de uno: consumo, ingreso de Helios, cobro (lo que vencía y el cobro a tiempo de lo juzgado hasta p_juzgado_hasta), riesgo al cierre de p_hasta, gente (solicitaron el código, registros = personas verificadas por el día de su verificación, primer consumo) y caja. Con p_corte, los flujos solo cuentan lo ocurrido hasta ese instante (la anterior a la misma altura de una semana en curso); las fotos siguen al cierre de p_hasta. Lee de metricas.* (la caja, de metricas.caja_al y caja_movimientos); lo que no se parte por local vale null.';

revoke all on function metricas.semana_periodo(date, date, uuid, date, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. La RPC de Semana › Rendimiento: la anterior hasta el mismo momento
-- ---------------------------------------------------------------------------

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
  v_corte        timestamptz;
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
  -- La semana en curso se compara con la anterior HASTA EL MISMO MOMENTO:
  -- lo que había pasado hace exactamente siete días. Con días enteros, un
  -- sábado a las 15:00 comparaba de lunes a viernes contra de lunes a
  -- sábado con su noche entera. Las fotos (vencido, mora, caja) siguen al
  -- cierre del día equivalente. Una semana cerrada, contra la anterior entera.
  v_corte := case when v_lunes + 6 >= v_hoy then now() - interval '7 days' end;

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
              'juzgado_hasta', case when v_juzgado_comp >= v_lunes - 7 then v_juzgado_comp end,
              -- El instante hasta el que cuentan sus flujos; null: la anterior entera.
              'corte',         v_corte
            ) || metricas.semana_periodo(v_lunes - 7, v_lunes - 7 + v_dias - 1, p_merchant_id, v_juzgado_comp, v_corte);

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
  'Métricas › Semana: las cifras de p_semanas semanas (lunes a domingo, día operativo) que acaban en la de p_hasta, de todos los locales o de uno, y la semana anterior a la elegida para compararla: si la elegida está en curso, hasta el mismo momento (comparacion.corte = now() − 7 días; las fotos, al cierre del día equivalente); si no, entera. Consumo, ingreso de Helios, cobro, riesgo al cierre, gente y caja, todo desde metricas.* (metricas.semana_periodo). Todo payable_usd va con financed_usd y fee_usd; lo que no se parte por local vale null.';

revoke all on function public.admin_metricas_semanas(date, integer, uuid) from public, anon;
grant execute on function public.admin_metricas_semanas(date, integer, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Las cifras de un tramo de Semana › Resumen, con su corte
-- ---------------------------------------------------------------------------

drop function if exists metricas.semana_resumen_tramo(date, date, uuid);

create or replace function metricas.semana_resumen_tramo(
  p_desde       date,
  p_hasta       date,
  p_merchant_id uuid default null,
  p_corte       timestamptz default null
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
      and (p_corte is null or k.confirmed_at <= p_corte)
  ),
  quienes as (
    -- Las personas salen de las cuotas: en un grupo, todas las que pagan.
    select count(distinct q.user_id)::integer as personas
    from metricas.cuotas q
    where q.business_date between p_desde and p_hasta
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
      and (p_corte is null or exists (
            select 1 from metricas.consumos k
            where k.charge_id = q.charge_id and k.confirmed_at <= p_corte))
  ),
  estrenos as (
    select count(distinct pl.user_id)::integer as nuevas
    from metricas.personas_por_local pl
    where pl.primer_dia between p_desde and p_hasta
      and (p_merchant_id is null or pl.merchant_id = p_merchant_id)
      and (p_corte is null or exists (
            select 1 from metricas.cuotas q
            join metricas.consumos k on k.charge_id = q.charge_id
            where q.user_id = pl.user_id and q.merchant_id = pl.merchant_id
              and k.confirmed_at <= p_corte))
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

comment on function metricas.semana_resumen_tramo(date, date, uuid, timestamptz) is
  'Métricas › Semana › Resumen: las cifras de un tramo de días operativos (de todos los locales o de uno). financed_usd = consumo sin fee; fee_usd = payable − financed (con IVA); payable_usd = lo que se cobra (solo con sus dos partes); servicio_usd = fee sin IVA; iva_usd = fee − servicio; consumos; ticket_medio_usd (sin fee); personas por sus cuotas; nuevas = personas cuya primera cuota en un local cae en el tramo (contadas una vez). Con p_corte, solo los consumos confirmados hasta ese instante. Lee de metricas.consumos, metricas.cuotas y metricas.personas_por_local.';

revoke all on function metricas.semana_resumen_tramo(date, date, uuid, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. La RPC de Semana › Resumen: la anterior hasta el mismo momento
-- ---------------------------------------------------------------------------

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
  v_corte    timestamptz;
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
  -- La semana en curso se compara con la anterior HASTA EL MISMO MOMENTO:
  -- lo que había pasado hace exactamente siete días (el criterio de
  -- admin_metricas_semanas). Una semana cerrada, contra la anterior entera.
  v_corte := case when v_lunes + 6 >= v_hoy then now() - interval '7 days' end;

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
                     'misma_altura', v_lunes + 6 >= v_hoy,
                     -- El instante hasta el que cuenta; null: la anterior entera.
                     'corte',        v_corte
                   ),
    'cifras',      v_cifras,
    'comparacion', metricas.semana_resumen_tramo(v_lunes - 7, v_lunes - 7 + v_dias - 1, p_merchant_id, v_corte),
    'semanas',     v_semanas,
    'noches',      v_noches
  );
end;
$$;

comment on function public.admin_metricas_semana_resumen(date, uuid) is
  'Métricas › Semana › Resumen: de la semana de p_semana (lunes a domingo, día operativo; la en curso hasta hoy), de todos los locales o de uno, el total facturado (financed_usd, sin fee), el service fee con su IVA (fee_usd), el total a cobrar (payable_usd, solo con sus dos partes), los consumos y las personas que consumieron (por sus cuotas); la anterior, hasta el mismo momento si la elegida está en curso (anterior.corte = now() − 7 días) o entera si no; las 8 últimas semanas para la chispa; y una fila por noche y local con consumos, personas, nuevas en el local, las tres cifras de dinero y el ticket medio sin fee. Lee de metricas.* (metricas.semana_resumen_tramo).';

revoke all on function public.admin_metricas_semana_resumen(date, uuid) from public, anon;
grant execute on function public.admin_metricas_semana_resumen(date, uuid) to authenticated;
