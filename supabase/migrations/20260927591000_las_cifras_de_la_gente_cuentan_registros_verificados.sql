-- ============================================================================
-- Ronda — Las cifras de la gente cuentan registros verificados
--
-- Segunda mitad de «un registro es una persona verificada»
-- (20260927590000). Allí se redefinen `metricas.personas` (solo los
-- registros, por el día en que se aprobó la verificación) y se crea
-- `metricas.solicitudes` (todo el que pidió el código). Aquí, las RPC que
-- enseñan registros ganan la cifra de quien pidió el código y el embudo de
-- Gente empieza en ella. Ninguna firma cambia y no se quita ninguna clave:
-- lo que Inicio y las demás pantallas ya leen sigue ahí.
--
--   metricas.semana_periodo  gente.solicitaron (Métricas › Semana).
--   admin_growth_overview    requested {count, previous}, series[].requested,
--                            totals.requested y totals.phone_confirmed.
--   admin_growth_funnel      la cohorte es quien pidió el código en la
--                            ventana; los escalones, hasta dónde llegó.
--   admin_metricas_general   gente.solicitaron y gente.telefono_confirmado;
--                            «desde» = metricas.gente_primer_dia().
--   admin_overview           users.unconfirmed_phone desde
--                            metricas.solicitudes, y requested_otp,
--                            requested_otp_in_window, phone_confirmed y
--                            not_verified.
--
-- Las funciones salen COPIADAS de su última migración y solo cambia lo que
-- dice cada sección: se generan con un script que exige que cada trozo
-- cambiado aparezca una sola vez.
--
-- Con un local, nada de esto se parte (el registro y la solicitud no son de
-- ningún local) y las claves nuevas valen null, como los registros.
--
-- Idempotente: create or replace con las mismas firmas.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Semana: una fila más en Gente, «Solicitaron el código»
-- ---------------------------------------------------------------------------
-- Copia exacta de 20260927520000 salvo el padrón: `gente` gana
-- `solicitaron` (null con local). `registros` y `verificados` ya cuentan
-- registros verificados por el día de su verificación (metricas.personas).

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
      -- Los registros (personas verificadas, por el día en que se aprobó su
      -- verificación) son del padrón, no de un local. `verificados` es la
      -- misma cifra y se queda por quien ya la lee.
      select
        count(*) filter (where p.registro_dia between p_desde and p_hasta)::integer   as registros,
        count(*) filter (where p.verificado_dia between p_desde and p_hasta)::integer as verificados,
        count(*) filter (where p.primer_consumo_dia between p_desde and p_hasta)::integer
                                                                                      as primer_consumo
      from metricas.personas p
      where p_merchant_id is null
    ),
    solicitudes as (
      -- Quien pidió el código en el tramo, se verificara o no: la boca del
      -- embudo. No es un registro. Tampoco es de ningún local.
      select count(*)::integer as solicitaron
      from metricas.solicitudes s
      where p_merchant_id is null
        and s.solicito_dia between p_desde and p_hasta
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


comment on function metricas.semana_periodo(date, date, uuid, date) is
  'Todas las cifras de Métricas › Semana para los días operativos p_desde..p_hasta (p_hasta <= hoy), de todos los locales o de uno: consumo, ingreso de Helios, cobro (lo que vencía y el cobro a tiempo de lo juzgado hasta p_juzgado_hasta), riesgo al cierre de p_hasta, gente (solicitaron el código, registros = personas verificadas por el día de su verificación, primer consumo) y caja. Lee de metricas.* (la caja, de metricas.caja_al y caja_movimientos); lo que no se parte por local vale null.';

revoke all on function metricas.semana_periodo(date, date, uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Gente › Resumen: los registros y quien pidió el código
-- ---------------------------------------------------------------------------
-- Copia exacta de 20260927570000 salvo: la clave nueva `requested` (con su
-- `previous` y su columna en `series`) y, en `totals`, `requested` y
-- `phone_confirmed`. Todas valen null con local. `registered` y `verified`
-- son la misma cifra.

create or replace function public.admin_growth_overview(
  p_from        date default null,
  p_to          date default null,
  p_merchant_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today     date := metricas.hoy();
  v_local     boolean := p_merchant_id is not null;
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

  select w.desde, w.hasta, w.dias, w.prev_desde, w.prev_hasta
    into v_from, v_to, v_days, v_prev_from, v_prev_to
  from metricas.gente_ventana(p_from, p_to) w;

  with
  -- Los registros: personas con la verificación de identidad aprobada, por
  -- el día en que se aprobó (metricas.personas). Son del padrón y no de un
  -- local: con local, sus claves valen null.
  gente as (
    select p.user_id, p.registro_dia as dia, p.verificado_dia, p.primer_consumo_dia, p.estado
    from metricas.personas p
  ),
  -- Quien pidió el código, se verificara o no: la boca del embudo. No es un
  -- registro. Tampoco es de ningún local.
  pidieron as (
    select s.user_id, s.solicito_dia as dia, s.etapa
    from metricas.solicitudes s
  ),
  -- Cuándo llegó cada persona: su primer consumo en Ronda o, con un local,
  -- su primera cuota en ese local («nuevo en el local»).
  llegada as (
    select p.user_id, p.primer_consumo_dia as dia
    from metricas.personas p
    where not v_local and p.primer_consumo_dia is not null
    union all
    select l.user_id, l.primer_dia
    from metricas.personas_por_local l
    where v_local and l.merchant_id = p_merchant_id
  ),
  -- Una fila por (persona, cuota): el grano correcto para todo lo que se
  -- pregunta por persona.
  consumo as (
    select q.user_id, q.charge_id, q.business_date as dia, q.financed_usd as fin
    from metricas.cuotas q
    where p_merchant_id is null or q.merchant_id = p_merchant_id
  ),
  -- Una fila por consumo, para el servicio (el ingreso de Ronda).
  cargo as (
    select k.business_date as dia, k.servicio_usd, k.fee_usd
    from metricas.consumos k
    where p_merchant_id is null or k.merchant_id = p_merchant_id
  )
  select jsonb_build_object(
    'business_date', v_today,
    -- El rango QUE SE USÓ, no el que se pidió.
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,
    -- Contra qué se comparan los «previous»: la ventana anterior a la misma
    -- altura de la semana.
    'previous_from', v_prev_from,
    'previous_to',   v_prev_to,
    'merchant_id',   p_merchant_id,

    'registered', case when v_local then null else jsonb_build_object(
      'count',    (select count(*) from gente where dia between v_from and v_to),
      'previous', (select count(*) from gente where dia between v_prev_from and v_prev_to)
    ) end,

    -- Todo registro está verificado: es la misma cifra que `registered`.
    'verified', case when v_local then null else jsonb_build_object(
      'count',    (select count(*) from gente where verificado_dia between v_from and v_to),
      'previous', (select count(*) from gente where verificado_dia between v_prev_from and v_prev_to)
    ) end,

    -- Pidieron el código en la ventana, se verificaran o no.
    'requested', case when v_local then null else jsonb_build_object(
      'count',    (select count(*) from pidieron where dia between v_from and v_to),
      'previous', (select count(*) from pidieron where dia between v_prev_from and v_prev_to)
    ) end,

    -- Sin local, el primer consumo de su vida; con local, la primera cuota
    -- en ese local.
    'activated', jsonb_build_object(
      'count',    (select count(*) from llegada where dia between v_from and v_to),
      'previous', (select count(*) from llegada where dia between v_prev_from and v_prev_to)
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
      -- consumo.
      'revenue_usd',  (select coalesce(sum(servicio_usd), 0) from cargo where dia between v_from and v_to),
      -- El servicio con su IVA. Tampoco se suma al consumo.
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

    -- Lo acumulado: la foto del padrón entero, no sigue la ventana. Con local,
    -- solo se sabe cuánta gente ha consumido alguna vez en él.
    'totals', case when v_local then jsonb_build_object(
      'registered',  null,
      'onboarded',   null,
      'ever_bought', (select count(*) from metricas.personas_por_local l where l.merchant_id = p_merchant_id),
      'buyers_pct',  null,
      'requested',       null,
      'phone_confirmed', null
    ) else jsonb_build_object(
      -- Todos los que pidieron el código y los que además lo metieron: la
      -- boca del embudo entero. Los registros son una parte de ellos.
      'requested',       (select count(*) from pidieron),
      'phone_confirmed', (select count(*) from pidieron where etapa <> 'solicito_el_codigo'),
      'registered',  (select count(*) from gente),
      'onboarded',   (select count(*) from gente where estado not in ('pending_kyc', 'pending_pin')),
      'ever_bought', (select count(*) from gente where primer_consumo_dia is not null),
      'buyers_pct',  (
        select case when count(*) > 0
               then round(100.0 * count(*) filter (where primer_consumo_dia is not null) / count(*), 1)
               else 0 end
        from gente
      )
    ) end,

    -- La serie diaria, en un solo viaje para los gráficos.
    'series', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.day)
      from (
        select (v_from + g.k)                                            as day,
               case when v_local then null else coalesce(r.n, 0)::int end  as registered,
               case when v_local then null else coalesce(vf.n, 0)::int end as verified,
               case when v_local then null else coalesce(rq.n, 0)::int end as requested,
               coalesce(a.n, 0)::int                                     as activated,
               coalesce(co.usuarios, 0)::int                             as active_users,
               coalesce(co.ordenes, 0)::int                              as orders,
               coalesce(co.financiado, 0)                                as financed_usd
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
          select dia, count(*) as n from pidieron
          where dia between v_from and v_to group by 1
        ) rq on rq.dia = v_from + g.k
        left join (
          select dia, count(*) as n from llegada
          where dia between v_from and v_to group by 1
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


comment on function public.admin_growth_overview(date, date, uuid) is
  'Métricas › Gente: registros (personas verificadas, por el día en que se aprobó su verificación; verified es la misma cifra), quien pidió el código (requested), primeros consumos (con local: nuevos en el local), personas que consumieron, consumos y consumo (sin servicio) de la ventana, con la ventana anterior a la misma altura. Lee de metricas.*. Con p_merchant_id, lo del padrón vale null.';

revoke all on function public.admin_growth_overview(date, date, uuid) from public, anon;
grant execute on function public.admin_growth_overview(date, date, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El embudo empieza en «Solicitaron el código»
-- ---------------------------------------------------------------------------
-- La cohorte es la gente que PIDIÓ EL CÓDIGO en la ventana, se verificara o
-- no, y cada escalón es la parte de esa misma gente que llegó hasta él. Así
-- cada escalón está dentro del anterior por construcción:
--
--   pidieron     Solicitaron el código           toda la cohorte
--   confirmaron  Confirmaron el teléfono         etapa <> 'solicito_el_codigo'
--   registrados  Se registraron (identidad       etapa = 'verificado': son
--                verificada)                     registros (metricas.personas)
--   listos       Terminaron de darse de alta     registros con PIN (su estado
--                                                ya no es pending_kyc ni
--                                                pending_pin)
--   compraron    Consumieron al menos una vez
--   repitieron   Volvieron a consumir            dos consumos o más
--
-- Las claves cambian de sentido respecto a 20260927570000: `registrados` era
-- «Confirmaron el teléfono» y pasa a ser el registro (verificado); lo del
-- teléfono va en `confirmaron`, y `verificados` desaparece porque es el
-- registro. El panel pinta los escalones tal como llegan (clave, rótulo,
-- personas).
--
-- Registrarse ya no tiene dos caminos: el atajo del super admin que activa un
-- perfil sin fila aprobada en `kyc` no es un registro (hoy no hay ningún caso
-- ni en dev ni en producción).
--
-- La cohorte es por el día en que se pidió el código; la cifra «Registros»
-- de Semana y de Gente › Resumen es por el día en que se aprobó la
-- verificación. Casi siempre es el mismo día (en la barra, minutos antes de
-- consumir); cuando no, «Registros» de una semana y el escalón `registrados`
-- del embudo de esa semana difieren en quien pidió el código una semana y se
-- verificó otra. Desde el inicio coinciden siempre.
--
-- La demora hasta el primer consumo se mide desde el día de registro (la
-- verificación), no desde la solicitud.

create or replace function public.admin_growth_funnel(
  p_from        date default null,
  p_to          date default null,
  p_merchant_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date := metricas.hoy();
  v_from   date;
  v_to     date;
  v_days   integer;
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select w.desde, w.hasta, w.dias into v_from, v_to, v_days
  from metricas.gente_ventana(p_from, p_to) w;

  if p_merchant_id is not null then
    return jsonb_build_object(
      'business_date',     v_today,
      'from',              v_from,
      'to',                v_to,
      'window_days',       v_days,
      'merchant_id',       p_merchant_id,
      'steps',             null,
      'p50_days_to_first', null,
      'p90_days_to_first', null,
      'same_day_pct',      null
    );
  end if;

  with
  -- Todo el que pidió el código en la ventana, se verificara o no. El hueco
  -- entre este escalón y el siguiente avisa de que los SMS no llegan.
  cohorte as (
    select s.user_id, s.etapa
    from metricas.solicitudes s
    where s.solicito_dia between v_from and v_to
  ),
  -- Los registros de la cohorte, con su día de registro y su estado de hoy.
  registros as (
    select p.user_id, p.registro_dia as dia, p.estado as status
    from metricas.personas p
    join cohorte c on c.user_id = p.user_id
  ),
  compras as (
    select q.user_id,
           count(distinct q.charge_id)::int as ordenes,
           min(q.business_date)             as primer_dia
    from metricas.cuotas q
    join registros r on r.user_id = q.user_id
    group by 1
  ),
  -- Días entre registrarse y estrenar. La mediana y no la media: un solo
  -- rezagado que estrena a los 90 días le sube la media a todo el mundo.
  demora as (
    select (cp.primer_dia - r.dia) as dias
    from compras cp
    join registros r on r.user_id = cp.user_id
  )
  select jsonb_build_object(
    'business_date', v_today,
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,
    'merchant_id',   null,
    'steps', jsonb_build_array(
      jsonb_build_object('key', 'pidieron', 'label', 'Solicitaron el código',
        'users', (select count(*) from cohorte)),
      jsonb_build_object('key', 'confirmaron', 'label', 'Confirmaron el teléfono',
        'users', (select count(*) from cohorte where etapa <> 'solicito_el_codigo')),
      jsonb_build_object('key', 'registrados', 'label', 'Se registraron (identidad verificada)',
        'users', (select count(*) from registros)),
      jsonb_build_object('key', 'listos', 'label', 'Terminaron de darse de alta',
        'users', (select count(*) from registros where status not in ('pending_kyc', 'pending_pin'))),
      jsonb_build_object('key', 'compraron', 'label', 'Consumieron al menos una vez',
        'users', (select count(*) from compras)),
      jsonb_build_object('key', 'repitieron', 'label', 'Volvieron a consumir',
        'users', (select count(*) from compras where ordenes >= 2))
    ),
    'p50_days_to_first', (
      select coalesce(percentile_disc(0.5) within group (order by dias), 0)::int from demora
    ),
    'p90_days_to_first', (
      select coalesce(percentile_disc(0.9) within group (order by dias), 0)::int from demora
    ),
    -- Cuántos de los que compraron lo hicieron la misma noche del registro.
    'same_day_pct', (
      select case when (select count(*) from demora) > 0
             then round(100.0 * (select count(*) from demora where dias = 0)
                              / (select count(*) from demora), 1)
             else 0 end
    )
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.admin_growth_funnel(date, date, uuid) is
  'Métricas › Gente: el embudo de la gente que pidió el código en la ventana (solicitaron el código, confirmaron el teléfono, se registraron = identidad verificada, terminaron el alta, consumieron, repitieron). Cada escalón está dentro del anterior. Es del registro: con p_merchant_id los escalones valen null.';

revoke all on function public.admin_growth_funnel(date, date, uuid) from public, anon;
grant execute on function public.admin_growth_funnel(date, date, uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. General: quien pidió el código, y el mismo «desde» que Gente
-- ---------------------------------------------------------------------------
-- Copia exacta de 20260927510000 salvo: `gente` gana `solicitaron` y
-- `telefono_confirmado` (null con local), y `desde` es
-- `metricas.gente_primer_dia()` (la primera solicitud del código o el
-- primer consumo). `registros` y `verificados` son la misma cifra.

create or replace function public.admin_metricas_general(p_merchant_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy        date    := metricas.hoy();
  -- «Activos» es haber consumido en los últimos 30 días operativos, hoy
  -- incluido: la misma ventana que `admin_overview(30)`.
  v_ventana    integer := 30;
  v_gracia     integer := public.helios_on_time_grace_days();
  -- Lo que tarda un consumo en tener su impago definitivo: la última cuota
  -- vence y recorre la escalera entera (la «temporada» de las cosechas).
  v_temporada  integer := 2 * public.helios_installment_interval_days()
                        + public.helios_mora_expulsion_days();
  v_todos      boolean := p_merchant_id is null;
  v_desde      date;
  v_k          record;
  v_q          record;
  v_p          record;
  v_s          record;
  v_c          record;
  v_l          record;
  v_cartera    record;
  v_repiten    integer;
  v_caja       numeric;
  v_curva      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- ── Los consumos ──────────────────────────────────────────────────────────
  select
    coalesce(sum(k.financed_usd), 0)                                   as financed,
    count(*)::integer                                                  as consumos,
    coalesce(sum(k.servicio_usd), 0)                                   as servicio,
    coalesce(sum(k.iva_usd), 0)                                        as iva,
    min(k.business_date)                                               as primero,
    count(distinct k.merchant_id)::integer                             as locales,
    (count(distinct k.merchant_id) filter (
       where k.business_date between v_hoy - (v_ventana - 1) and v_hoy))::integer as locales_ventana,
    -- El impago con el que Ronda ni gana ni pierde, como en admin_overview:
    -- servicio ÷ (neto transferido al local + servicio). El IVA no entra.
    case when coalesce(sum(k.neto_local_usd + k.servicio_usd), 0) > 0
         then round(100 * sum(k.servicio_usd) / sum(k.neto_local_usd + k.servicio_usd), 2)
    end                                                                as empate,
    -- El consumo cuya cosecha ya terminó su ciclo de cobro.
    coalesce(sum(k.financed_usd) filter (where k.business_date + v_temporada <= v_hoy), 0) as maduro
  into v_k
  from metricas.consumos k
  where v_todos or k.merchant_id = p_merchant_id;

  -- ── Las cuotas: las personas, lo cobrado, lo perdido y el cobro a tiempo ──
  select
    count(distinct q.user_id)::integer                                 as personas,
    (count(distinct q.user_id) filter (
       where q.business_date between v_hoy - (v_ventana - 1) and v_hoy))::integer as activos,
    coalesce(sum(q.payable_usd)  filter (where q.status = 'paid'), 0)  as cobrado_payable,
    coalesce(sum(q.financed_usd) filter (where q.status = 'paid'), 0)  as cobrado_financed,
    coalesce(sum(q.fee_usd)      filter (where q.status = 'paid'), 0)  as cobrado_fee,
    (count(*) filter (where q.status = 'paid'))::integer               as cobrado_cuotas,
    coalesce(sum(q.financed_usd), 0)                                   as financiado,
    (count(distinct q.user_id) filter (where q.estado_hoy = 'perdida'))::integer as perdido_personas,
    (count(distinct q.user_id) filter (where q.estado_hoy in ('vencida', 'por_vencer')))::integer as deben_personas,
    (count(*) filter (where q.estado_hoy in ('vencida', 'por_vencer')))::integer as vivas_cuotas,
    (count(*) filter (where q.plazo_cerrado and q.sequence = 1))::integer as juzgadas_1,
    (count(*) filter (where q.plazo_cerrado and q.sequence = 1 and q.estado_hoy = 'a_tiempo'))::integer as a_tiempo_1,
    (count(*) filter (where q.plazo_cerrado and q.sequence = 2))::integer as juzgadas_2,
    (count(*) filter (where q.plazo_cerrado and q.sequence = 2 and q.estado_hoy = 'a_tiempo'))::integer as a_tiempo_2
  into v_q
  from metricas.cuotas q
  where v_todos or q.merchant_id = p_merchant_id;

  -- Repiten: personas con cuota en dos noches distintas o más (en ese local,
  -- si hay local: son sus `personas_por_local.noches`).
  select count(*)::integer into v_repiten
  from (
    select q.user_id
    from metricas.cuotas q
    where v_todos or q.merchant_id = p_merchant_id
    group by q.user_id
    having count(distinct q.business_date) >= 2
  ) r;

  -- ── La cartera de hoy: por cobrar, vencido, perdido y la mora ────────────
  select * into v_cartera from metricas.cartera_al(v_hoy, p_merchant_id);

  -- ── Los cargos por atraso: ingreso aparte, sin IVA ────────────────────────
  select
    coalesce(sum(a.amount_usd), 0)                                     as devengado,
    coalesce(sum(a.amount_usd) filter (where a.status = 'paid'), 0)    as cobrado,
    count(*)::integer                                                  as cargos
  into v_c
  from metricas.cargos_por_atraso a
  where v_todos or a.merchant_id = p_merchant_id;

  -- ── Lo que se les debe a los locales, como en Pagos a locales ────────────
  -- La lista de `admin_merchant_payables` y la suma sin los locales de
  -- prueba, que es lo que pinta Caja (`payablesTotals`).
  select
    coalesce(sum((x->>'total_pending_usd')::numeric), 0)               as total,
    coalesce(sum((x->>'overdue_usd')::numeric), 0)                     as atrasado,
    (count(*) filter (where (x->>'total_pending_usd')::numeric > 0))::integer as locales
  into v_l
  from jsonb_array_elements(coalesce(public.admin_merchant_payables(), '[]'::jsonb)) x
  where coalesce((x->>'is_test')::boolean, false) = false
    and (v_todos or (x->>'merchant_id')::uuid = p_merchant_id);

  -- ── Lo que no es de ningún local ──────────────────────────────────────────
  -- Con local la consulta no lee nada (`where v_todos`) y sus cifras salen
  -- como null más abajo; se hace igual para que `v_p` siempre tenga forma.
  select
    count(*)::integer                                                  as registros,
    (count(*) filter (where p.verificado))::integer                    as verificados,
    (count(*) filter (where p.primer_consumo_dia is not null))::integer as han_comprado
  into v_p
  from metricas.personas p
  where v_todos;

  -- Quien pidió el código, se verificara o no (la boca del embudo), y quien
  -- además lo metió. No son registros; tampoco son de ningún local.
  select
    count(*)::integer                                                  as solicitaron,
    (count(*) filter (where s.etapa <> 'solicito_el_codigo'))::integer as telefono_confirmado
  into v_s
  from metricas.solicitudes s
  where v_todos;

  if v_todos then
    -- La caja del libro, la misma que Caja y el Resumen.
    v_caja := (public.admin_cash_position() ->> 'cash')::numeric;
    -- La primera solicitud del código o el primer consumo: el mismo «desde el
    -- inicio» que Métricas › Gente.
    v_desde := metricas.gente_primer_dia();
  else
    v_desde := v_k.primero;
  end if;

  -- ── La curva: semana a semana y su acumulado ─────────────────────────────
  if v_desde is null then
    v_curva := '[]'::jsonb;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
             'semana',            c.semana,
             'registros',         case when v_todos then c.registros end,
             'registros_acum',    case when v_todos then c.registros_acum end,
             'consumos',          c.consumos,
             'financed_usd',      c.financed,
             'financed_acum_usd', c.financed_acum
           ) order by c.semana), '[]'::jsonb)
    into v_curva
    from (
      select
        s.semana,
        coalesce(r.n, 0)                                               as registros,
        sum(coalesce(r.n, 0)) over (order by s.semana)                 as registros_acum,
        coalesce(k.n, 0)                                               as consumos,
        coalesce(k.f, 0)                                               as financed,
        sum(coalesce(k.f, 0)) over (order by s.semana)                 as financed_acum
      from generate_series(metricas.lunes(v_desde), metricas.lunes(v_hoy), interval '7 days') g(d)
      cross join lateral (select g.d::date as semana) s
      left join (
        select p.registro_semana as semana, count(*)::integer as n
        from metricas.personas p
        where v_todos
        group by 1
      ) r on r.semana = s.semana
      left join (
        select k.semana, count(*)::integer as n, sum(k.financed_usd) as f
        from metricas.consumos k
        where v_todos or k.merchant_id = p_merchant_id
        group by 1
      ) k on k.semana = s.semana
    ) c;
  end if;

  return jsonb_build_object(
    'hoy',   v_hoy,
    'desde', v_desde,
    'local', p_merchant_id,
    'ventana_dias',   v_ventana,
    'gracia_dias',    v_gracia,
    'temporada_dias', v_temporada,

    'gente', jsonb_build_object(
      'solicitaron',         case when v_todos then v_s.solicitaron end,
      'telefono_confirmado', case when v_todos then v_s.telefono_confirmado end,
      -- Registros = personas verificadas; `verificados` es la misma cifra.
      'registros',        case when v_todos then v_p.registros end,
      'verificados',      case when v_todos then v_p.verificados end,
      'han_comprado',     case when v_todos then v_p.han_comprado end,
      'han_comprado_pct', case when v_todos and v_p.registros > 0
                               then round(100.0 * v_p.han_comprado / v_p.registros, 1) end,
      'activos',          v_q.activos,
      'repiten',          v_repiten
    ),

    'consumo', jsonb_build_object(
      'financed_usd',    v_k.financed,
      'consumos',        v_k.consumos,
      'ticket_usd',      case when v_k.consumos > 0 then round(v_k.financed / v_k.consumos, 2) end,
      'personas',        v_q.personas,
      'locales',         case when v_todos then v_k.locales end,
      'locales_activos', case when v_todos then v_k.locales_ventana end
    ),

    'dinero', jsonb_build_object(
      'por_cobrar', jsonb_build_object(
        'payable_usd',  v_cartera.vencido_payable_usd  + v_cartera.por_vencer_payable_usd,
        'financed_usd', v_cartera.vencido_financed_usd + v_cartera.por_vencer_financed_usd,
        'fee_usd',      v_cartera.vencido_fee_usd      + v_cartera.por_vencer_fee_usd,
        'cuotas',       v_q.vivas_cuotas,
        'personas',     v_q.deben_personas
      ),
      'vencido', jsonb_build_object(
        'payable_usd',  v_cartera.vencido_payable_usd,
        'financed_usd', v_cartera.vencido_financed_usd,
        'fee_usd',      v_cartera.vencido_fee_usd,
        'cuotas',       v_cartera.cuotas_vencidas,
        'personas',     v_cartera.personas_vencidas
      ),
      'cobrado', jsonb_build_object(
        'payable_usd',  v_q.cobrado_payable,
        'financed_usd', v_q.cobrado_financed,
        'fee_usd',      v_q.cobrado_fee,
        'cuotas',       v_q.cobrado_cuotas
      ),
      -- Lo que Ronda ha ganado, cada cosa en su cifra.
      'servicio_usd', v_k.servicio,
      'cargos_por_atraso', jsonb_build_object(
        'devengado_usd', v_c.devengado,
        'cobrado_usd',   v_c.cobrado,
        'cargos',        v_c.cargos
      ),
      'perdido', jsonb_build_object(
        'payable_usd',  v_cartera.perdido_payable_usd,
        'financed_usd', v_cartera.perdido_financed_usd,
        'fee_usd',      v_cartera.perdido_fee_usd,
        'personas',     v_q.perdido_personas
      ),
      'caja_usd', case when v_todos then v_caja end,
      'por_pagar_locales', jsonb_build_object(
        'total_usd',    v_l.total,
        'atrasado_usd', v_l.atrasado,
        'locales',      v_l.locales
      )
    ),

    'riesgo', jsonb_build_object(
      'mora_pct',    v_cartera.mora_pct,
      -- Consumo perdido y sin pagar sobre todo el consumo, como el impago de
      -- admin_overview. Nulo sin consumo.
      'impago_pct',  case when v_q.financiado > 0
                          then round(100 * v_cartera.perdido_financed_usd / v_q.financiado, 2) end,
      'empate_pct',  v_k.empate,
      'a_tiempo', jsonb_build_array(
        jsonb_build_object(
          'cuota', 1, 'juzgadas', v_q.juzgadas_1, 'a_tiempo', v_q.a_tiempo_1,
          'pct', case when v_q.juzgadas_1 > 0 then round(100.0 * v_q.a_tiempo_1 / v_q.juzgadas_1, 1) end
        ),
        jsonb_build_object(
          'cuota', 2, 'juzgadas', v_q.juzgadas_2, 'a_tiempo', v_q.a_tiempo_2,
          'pct', case when v_q.juzgadas_2 > 0 then round(100.0 * v_q.a_tiempo_2 / v_q.juzgadas_2, 1) end
        )
      )
    ),

    -- Por cada 100 € de consumo: los tres sumandos del margen, cada uno con
    -- su signo, y el consumo cuya cosecha ya está cerrada.
    'por_cada_100', jsonb_build_object(
      'financed_usd',        v_k.financed,
      'consumos',            v_k.consumos,
      'financed_maduro_usd', v_k.maduro,
      'servicio_usd',        v_k.servicio,
      'cargos_usd',          v_c.devengado,
      'perdido_usd',         v_cartera.perdido_financed_usd,
      'por_100', case when v_k.financed > 0 then jsonb_build_object(
        'servicio_usd', round(100 * v_k.servicio / v_k.financed, 2),
        'cargos_usd',   round(100 * v_c.devengado / v_k.financed, 2),
        'perdido_usd',  round(100 * v_cartera.perdido_financed_usd / v_k.financed, 2),
        'margen_usd',   round(100 * (v_k.servicio + v_c.devengado - v_cartera.perdido_financed_usd)
                              / v_k.financed, 2)
      ) end
    ),

    'curva', v_curva
  );
end;
$$;


comment on function public.admin_metricas_general(uuid) is
  'Métricas › General: lo global del negocio desde el primer día (gente: quien pidió el código, quien lo metió, registros = personas verificadas, han comprado, activos, repiten; consumo, dinero, riesgo, por cada 100 € y la curva semanal acumulada), de todos los locales o de uno. Lee de metricas.*, de admin_cash_position (caja) y de admin_merchant_payables (por pagar a locales). Todo payable_usd va con financed_usd y fee_usd; lo que no se parte por local vale null.';

revoke all on function public.admin_metricas_general(uuid) from public, anon;
grant execute on function public.admin_metricas_general(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. admin_overview: `users` cuenta registros y dice quién pidió el código
-- ---------------------------------------------------------------------------
-- Copia exacta de 20260927551000 salvo el bloque `users`. `total`,
-- `new_in_window` y los estados ya cuentan registros verificados.
-- `unconfirmed_phone` mantiene su significado (pidieron el código y no lo
-- metieron), ahora desde metricas.solicitudes: con la definición nueva, «no
-- estar en metricas.personas» también incluiría a quien metió el código sin
-- verificarse. Claves nuevas: `requested_otp`, `requested_otp_in_window`,
-- `phone_confirmed` y `not_verified`. No se quita ninguna.

create or replace function public.admin_overview(
  p_days        integer default 30,
  p_merchant_id uuid    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today     date    := metricas.hoy();
  v_days      integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_from      date;
  v_prev_from date;
  v_count     integer;
  v_openers   integer;
  v_fin       numeric;
  v_prev_fin  numeric;
  v_people    integer;
  v_cartera   record;
  v_impago    record;
  v_result    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from      := v_today - (v_days - 1);
  v_prev_from := v_from - v_days;

  -- El consumo de la ventana y de la anterior, sin el servicio de Ronda.
  select coalesce(sum(k.financed_usd) filter (where k.business_date >= v_from), 0),
         coalesce(sum(k.financed_usd) filter (where k.business_date <  v_from), 0),
         (count(*) filter (where k.business_date >= v_from))::integer,
         (count(distinct k.abrio_user_id) filter (where k.business_date >= v_from))::integer
    into v_fin, v_prev_fin, v_count, v_openers
  from metricas.consumos k
  where k.business_date between v_prev_from and v_today
    and (p_merchant_id is null or k.merchant_id = p_merchant_id);

  -- La gente: todos los que tienen cuota, no quien abrió la cuenta.
  select count(distinct q.user_id)::integer into v_people
  from metricas.cuotas q
  where q.business_date between v_from and v_today
    and (p_merchant_id is null or q.merchant_id = p_merchant_id);

  v_result := jsonb_build_object(
    'business_date', v_today,
    'window_days',   v_days,
    'merchant_id',   p_merchant_id,
    'volume', jsonb_build_object(
      'financed_usd',   v_fin,
      'previous_usd',   v_prev_fin,
      'charge_count',   v_count,
      'active_users',   v_people,
      'avg_ticket_usd', case when v_count > 0 then round(v_fin / v_count, 2) else 0 end,
      'financed_volume_usd',          v_fin,
      'previous_financed_volume_usd', v_prev_fin,
      'financed_change_pct', case when v_prev_fin > 0
        then round(100 * (v_fin - v_prev_fin) / v_prev_fin, 1) else null end,
      'avg_ticket_financed_usd', case when v_count > 0 then round(v_fin / v_count, 2) else null end,
      'active_people',   v_people,
      -- Quien abrió la cuenta. En un consumo de grupo pagan más.
      'account_openers', v_openers
    )
  );

  -- La mora. Sobre lo que todavía se puede cobrar: lo dado por perdido tiene
  -- su cifra aparte.
  select * into v_cartera from metricas.cartera_al(v_today, p_merchant_id);

  v_result := v_result || jsonb_build_object('arrears', (
    select jsonb_build_object(
      'open_usd',             v_cartera.vencido_payable_usd + v_cartera.por_vencer_payable_usd,
      'open_financed_usd',    v_cartera.vencido_financed_usd + v_cartera.por_vencer_financed_usd,
      'open_fee_usd',         v_cartera.vencido_fee_usd + v_cartera.por_vencer_fee_usd,
      'overdue_usd',          v_cartera.vencido_payable_usd,
      'overdue_financed_usd', v_cartera.vencido_financed_usd,
      'overdue_fee_usd',      v_cartera.vencido_fee_usd,
      'overdue_users',        v_cartera.personas_vencidas,
      'due_today_usd',        coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'por_vencer' and q.due_date = v_today), 0),
      'rate_pct',             coalesce(v_cartera.mora_pct, 0),
      'demotion_days',        public.helios_mora_demotion_days(),
      'expulsion_days',       public.helios_mora_expulsion_days(),
      'bucket_frozen_usd',    coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'vencida'
                                   and q.dias_atraso <= public.helios_mora_demotion_days()), 0),
      'bucket_demotion_usd',  coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'vencida'
                                   and q.dias_atraso >  public.helios_mora_demotion_days()
                                   and q.dias_atraso <= public.helios_mora_expulsion_days()), 0),
      'bucket_expulsion_usd', coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'vencida'
                                   and q.dias_atraso >  public.helios_mora_expulsion_days()), 0)
    )
    from metricas.cuotas q
    where q.estado_hoy in ('vencida', 'por_vencer')
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ));

  -- Impago: lo dado por perdido, en consumo, sobre TODO lo financiado en la
  -- historia (lo que se pierde hoy nació hace meses). La tasa y el punto de
  -- empate salen de metricas.cobranza_impago, la misma función que Cobranza.
  select * into v_impago from metricas.cobranza_impago(p_merchant_id);

  v_result := v_result || jsonb_build_object('bad_debt', (
    select jsonb_build_object(
      'written_off_usd',          v_impago.perdido_financed_usd,
      'written_off_users',        v_impago.personas_perdidas,
      'financed_usd',             v_impago.financiado_usd,
      'window_usd',               coalesce(sum(q.financed_usd) filter (
                                     where q.estado_hoy = 'perdida'
                                       and public.helios_business_date(q.written_off_at) between v_from and v_today), 0),
      'rate_pct',                 coalesce(v_impago.impago_pct, 0),
      'written_off_financed_usd', v_impago.perdido_financed_usd,
      'lifetime_financed_usd',    v_impago.financiado_usd,
      'window_financed_usd',      coalesce(sum(q.financed_usd) filter (
                                     where q.estado_hoy = 'perdida'
                                       and public.helios_business_date(q.written_off_at) between v_from and v_today), 0),
      'rate_financed_pct',        v_impago.impago_pct,
      'written_off_debt_usd',     v_impago.perdido_payable_usd,
      'written_off_fee_usd',      v_impago.perdido_fee_usd,
      'break_even_pct',           v_impago.empate_pct
    )
    from metricas.cuotas q
    where q.estado_hoy = 'perdida'
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ));

  -- Los registros (personas verificadas) por estado y, aparte, quien pidió
  -- el código sin llegar a registrarse. Nada de esto es de un local.
  v_result := v_result || jsonb_build_object('users', case when p_merchant_id is null then (
    select jsonb_build_object(
      'total',         count(*),
      'pending_kyc',   count(*) filter (where p.estado in ('pending_kyc', 'pending_pin')),
      'active',        count(*) filter (where p.estado = 'active'),
      'frozen',        count(*) filter (where p.estado = 'frozen'),
      'suspended',     count(*) filter (where p.estado = 'suspended'),
      'expelled',      count(*) filter (where p.estado = 'expelled'),
      'blacklisted',   count(*) filter (where pr.is_blacklisted),
      'new_in_window', count(*) filter (where p.registro_dia between v_from and v_today),
      -- Pidieron el código y nunca lo metieron.
      'unconfirmed_phone', (
        select count(*) from metricas.solicitudes s where s.etapa = 'solicito_el_codigo'
      ),
      -- Todos los que pidieron el código, se verificaran o no, y los de la
      -- ventana. Los registros (`total`) son una parte de ellos.
      'requested_otp', (select count(*) from metricas.solicitudes s),
      'requested_otp_in_window', (
        select count(*) from metricas.solicitudes s
        where s.solicito_dia between v_from and v_today
      ),
      -- Metieron el código (estén o no verificados).
      'phone_confirmed', (
        select count(*) from metricas.solicitudes s where s.etapa <> 'solicito_el_codigo'
      ),
      -- Pidieron el código y no son registros.
      'not_verified', (
        select count(*) from metricas.solicitudes s where s.etapa <> 'verificado'
      )
    )
    from metricas.personas p
    join public.profiles pr on pr.id = p.user_id
  ) end);

  -- Embudo de KYC: tampoco es de un local.
  v_result := v_result || jsonb_build_object('kyc', case when p_merchant_id is null then (
    select jsonb_build_object(
      'pending_review', count(*) filter (where v.status = 'manual_review'),
      'processing',     count(*) filter (where v.status = 'processing'),
      'approved',       count(*) filter (where v.status = 'approved'),
      'rejected',       count(*) filter (where v.status = 'rejected'),
      'approval_rate_pct', case
        when count(*) filter (where v.status in ('approved', 'rejected')) > 0
        then round(100.0 * count(*) filter (where v.status = 'approved')
                        / count(*) filter (where v.status in ('approved', 'rejected')), 1)
        else null end,
      'oldest_pending_hours', coalesce(round(extract(epoch from
        (now() - min(v.created_at) filter (where v.status = 'manual_review'))) / 3600.0, 1), 0)
    )
    from kyc.verifications v
    where not public.helios_is_test_user(v.user_id)
  ) end);

  -- Colas de trabajo. Lo que se le debe al local sí se parte; los pagos por
  -- revisar son de personas, no de locales.
  v_result := v_result || jsonb_build_object('queues', jsonb_build_object(
    'payments_to_reconcile', case when p_merchant_id is null then (
      select count(*) from public.payment_reports r
      where r.status in ('reported', 'in_review')
        and not public.helios_is_test_user(r.user_id)
    ) end,
    'merchant_payouts_due', (
      select coalesce(sum(s.amount_usd - s.paid_usd), 0) from public.settlements s
      where s.status in ('pending', 'partial') and s.due_date <= v_today
        and not public.helios_is_test_merchant(s.merchant_id)
        and (p_merchant_id is null or s.merchant_id = p_merchant_id)
    ),
    'merchant_payouts_pending', (
      select coalesce(sum(s.amount_usd - s.paid_usd), 0) from public.settlements s
      where s.status in ('pending', 'partial')
        and not public.helios_is_test_merchant(s.merchant_id)
        and (p_merchant_id is null or s.merchant_id = p_merchant_id)
    )
  ));

  v_result := v_result || jsonb_build_object('merchants', case when p_merchant_id is null then (
    select jsonb_build_object(
      'total',      count(*),
      'active',     count(*) filter (where m.status = 'active'),
      'paused',     count(*) filter (where m.status = 'paused'),
      'terminated', count(*) filter (where m.status = 'terminated'),
      'selling_in_window', (
        select count(distinct k.merchant_id) from metricas.consumos k
        where k.business_date between v_from and v_today
      )
    )
    from public.merchants m
    where not m.is_test
  ) end);

  -- Tasa BCV: vale igual para cualquier local.
  v_result := v_result || jsonb_build_object('fx', (
    select jsonb_build_object(
      'rate',           e.rate,
      'effective_date', e.effective_date,
      'fetched_at',     e.fetched_at,
      'age_hours',      round(extract(epoch from (now() - e.fetched_at)) / 3600.0, 1),
      'stale',          (now() - e.fetched_at) > interval '48 hours'
    )
    from public.exchange_rates e
    order by e.effective_date desc limit 1
  ));

  -- La caja es de Ronda, no de un local.
  v_result := v_result || jsonb_build_object('cash',
    case when p_merchant_id is null then public.admin_cash_position() end);

  return v_result;
end;
$$;


comment on function public.admin_overview(integer, uuid) is
  'El pulso del negocio: consumo de la ventana y la anterior (sin servicio), personas con cuota, la mora canónica con sus tramos, el impago en consumo con su punto de empate (metricas.cobranza_impago), los registros (personas verificadas) por estado y quien pidió el código sin registrarse, KYC, colas, locales, tasa BCV y caja. Con p_merchant_id: consumo, mora, impago y lo debido al local de ese local; users, kyc, merchants, cash y payments_to_reconcile valen null (no se parten). Lee de metricas.';

revoke all on function public.admin_overview(integer, uuid) from public, anon;
grant execute on function public.admin_overview(integer, uuid) to authenticated, service_role;
