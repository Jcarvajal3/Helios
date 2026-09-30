-- ============================================================================
-- Métricas › Gente: el crecimiento se mira por semanas y por local
-- ============================================================================
--
-- La pestaña Gente de Métricas reúne lo que era Crecimiento (Gente, Uso,
-- Grupos y las cohortes de registro, que pasan a llamarse Retención). En vez
-- de su rango de fechas propio usa la semana global de Métricas y una
-- «ventana» que acaba en ella (esta semana, 4 semanas, 12 semanas o desde el
-- inicio), y el local global.
--
-- Qué cambia en las cinco RPC de Crecimiento:
--
-- 1. Todas ganan `p_merchant_id uuid default null` (CONTRATOS §6). Sin él
--    contestan lo mismo que antes, con las mismas claves. Con él:
--    - lo que es de la gente que consumió en ese local se parte (consumo,
--      personas, grupos que gastaron allí, su retención, su perfil);
--    - lo que es del padrón (registros, verificados, el embudo de alta, los
--      estados de las cuentas, los grupos creados) no se parte y la clave vale
--      `null`: la pantalla pinta «No se parte por local», nunca un cero.
-- 2. Leen de `metricas.*` (una cifra, una definición): personas desde las
--    cuotas, registros desde `metricas.personas`, consumo desde
--    `metricas.cuotas` y `metricas.consumos`.
-- 3. La ventana pasa por `metricas.gente_ventana`, que recorta el «desde» al
--    primer día con actividad (así «desde el inicio» no pinta semanas vacías
--    de antes de que existiera Ronda) y da la ventana anterior A LA MISMA
--    ALTURA: se corre en semanas enteras, así una semana a medias se compara
--    con los mismos días de la semana anterior (lunes a sábado con lunes a
--    sábado) y no con los seis días de justo antes.
--
-- «Primer consumo» con un local elegido es «nuevo en el local»: su primera
-- cuota en ESE local cae en la ventana (CONTRATOS §2, `personas_por_local`).
-- Y la Retención con un local sigue a la gente desde su primera visita al
-- local, no desde su registro, que no es de ningún local (`base` en la
-- respuesta dice cuál de las dos es).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La ventana de Gente
-- ---------------------------------------------------------------------------

create or replace function metricas.gente_primer_dia()
returns date
language sql
stable
as $$
  -- `least` ignora los nulos: sin registros, el primer consumo; sin nada, nulo.
  select least(
    (select min(p.registro_dia) from metricas.personas p),
    (select min(k.business_date) from metricas.consumos k)
  );
$$;

comment on function metricas.gente_primer_dia() is
  'El primer día operativo con actividad (un registro o un consumo). Nulo sin datos. Es el «desde el inicio» de Métricas › Gente.';

create or replace function metricas.gente_ventana(p_from date, p_to date)
returns table (desde date, hasta date, dias integer, prev_desde date, prev_hasta date)
language sql
stable
as $$
  with pedido as (
    select
      case
        when p_from is null then null
        -- Nunca antes del primer día con actividad, ni después del «hasta».
        else least(
          greatest(p_from, coalesce(metricas.gente_primer_dia(), p_from)),
          least(coalesce(p_to, metricas.hoy()), metricas.hoy())
        )
      end as desde
  ),
  w as (
    select g.desde, g.hasta, g.dias
    from pedido p
    cross join lateral public.helios_growth_window(p.desde, p_to) g
  )
  select
    w.desde,
    w.hasta,
    w.dias,
    -- La anterior, en semanas enteras hacia atrás y del mismo largo: la misma
    -- altura de la semana.
    w.desde - 7 * ceil(w.dias / 7.0)::integer,
    w.desde - 7 * ceil(w.dias / 7.0)::integer + w.dias - 1
  from w;
$$;

comment on function metricas.gente_ventana(date, date) is
  'La ventana de Métricas › Gente: la de helios_growth_window con el «desde» recortado al primer día con actividad, y la ventana anterior del mismo largo corrida en semanas enteras (a la misma altura de la semana).';

-- ---------------------------------------------------------------------------
-- 2. El tablero: registros, primeros consumos, gente que consumió, consumo
-- ---------------------------------------------------------------------------

drop function if exists public.admin_growth_overview(date, date);

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
  -- Los registros: perfil real con el teléfono confirmado. Son del padrón y
  -- no de un local: con local, sus claves valen null.
  gente as (
    select p.user_id, p.registro_dia as dia, p.verificado_dia, p.primer_consumo_dia, p.estado
    from metricas.personas p
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

    'verified', case when v_local then null else jsonb_build_object(
      'count',    (select count(*) from gente where verificado_dia between v_from and v_to),
      'previous', (select count(*) from gente where verificado_dia between v_prev_from and v_prev_to)
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
      'buyers_pct',  null
    ) else jsonb_build_object(
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
  'Métricas › Gente: registros, verificados, primeros consumos (con local: nuevos en el local), personas que consumieron, consumos y consumo (sin servicio) de la ventana, con la ventana anterior a la misma altura. Lee de metricas.*. Con p_merchant_id, lo del padrón vale null.';

-- ---------------------------------------------------------------------------
-- 3. El embudo de alta
-- ---------------------------------------------------------------------------
-- Es del registro, que no es de ningún local: con p_merchant_id no se parte y
-- los escalones valen null.

drop function if exists public.admin_growth_funnel(date, date);

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
  -- Todo el que llegó a pedir un código en la ventana, haya confirmado o no.
  -- Es el escalón cero y el único sitio donde se cuenta a quien no confirmó:
  -- el hueco entre este escalón y el siguiente avisa de que los SMS no llegan.
  pidieron as (
    select p.id as user_id
    from public.profiles p
    where not p.is_test
      and public.helios_business_date(p.created_at) between v_from and v_to
  ),
  cohorte as (
    select p.user_id, p.registro_dia as dia, p.estado as status, p.verificado
    from metricas.personas p
    where p.registro_dia between v_from and v_to
  ),
  -- Verificado tiene dos caminos: la verificación aprobada de Didit y el atajo
  -- del super admin, que activa el perfil sin dejar fila en `kyc`. Con solo
  -- el primero, cada aprobación a mano aparecería como una caída.
  verificado as (
    select c.user_id, (c.verificado or c.status <> 'pending_kyc') as ok
    from cohorte c
  ),
  compras as (
    select q.user_id,
           count(distinct q.charge_id)::int as ordenes,
           min(q.business_date)             as primer_dia
    from metricas.cuotas q
    join cohorte c on c.user_id = q.user_id
    group by 1
  ),
  -- Días entre registrarse y estrenar. La mediana y no la media: un solo
  -- rezagado que estrena a los 90 días le sube la media a todo el mundo.
  demora as (
    select (cp.primer_dia - c.dia) as dias
    from compras cp
    join cohorte c on c.user_id = cp.user_id
  )
  select jsonb_build_object(
    'business_date', v_today,
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,
    'merchant_id',   null,
    'steps', jsonb_build_array(
      jsonb_build_object('key', 'pidieron', 'label', 'Pidieron el código por SMS',
        'users', (select count(*) from pidieron)),
      jsonb_build_object('key', 'registrados', 'label', 'Confirmaron el teléfono',
        'users', (select count(*) from cohorte)),
      jsonb_build_object('key', 'verificados', 'label', 'Verificaron su identidad',
        'users', (select count(*) from verificado where ok)),
      jsonb_build_object('key', 'listos', 'label', 'Terminaron de darse de alta',
        'users', (select count(*) from cohorte where status not in ('pending_kyc', 'pending_pin'))),
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
  'Métricas › Gente: el embudo de la gente que se registró en la ventana (pidió el código, confirmó, verificó, terminó el alta, consumió, repitió). Es del registro: con p_merchant_id los escalones valen null.';

-- ---------------------------------------------------------------------------
-- 4. El uso: cuánto gasta cada persona y cómo se reparte
-- ---------------------------------------------------------------------------

drop function if exists public.admin_user_behavior(date, date);

create or replace function public.admin_user_behavior(
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
  v_local  boolean := p_merchant_id is not null;
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

  with
  consumo as (
    select q.user_id, q.charge_id, q.business_date as dia, q.financed_usd as fin
    from metricas.cuotas q
    where q.business_date between v_from and v_to
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ),
  -- Una fila por persona activa en la ventana.
  porpersona as (
    select user_id,
           sum(fin)                          as gasto,
           count(distinct charge_id)::int    as ordenes,
           count(distinct dia)::int          as noches
    from consumo
    group by 1
  ),
  -- Tramos fijos y en euros, no percentiles.
  tramos(orden, label, lo, hi) as (
    values (1, 'Hasta €25',   0::numeric,   25::numeric),
           (2, '€25 a €50',   25::numeric,  50::numeric),
           (3, '€50 a €100',  50::numeric,  100::numeric),
           (4, '€100 a €200', 100::numeric, 200::numeric),
           (5, 'Más de €200', 200::numeric, 1e9::numeric)
  ),
  -- El decil 1 es el 10 % que más gasta.
  ranking as (
    select user_id, gasto, ntile(10) over (order by gasto desc) as decil
    from porpersona
  )
  select jsonb_build_object(
    'business_date', v_today,
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,
    'merchant_id',   p_merchant_id,
    'active_users',  (select count(*) from porpersona),

    'per_user', jsonb_build_object(
      'avg_financed_usd', (select coalesce(round(avg(gasto), 2), 0) from porpersona),
      'p50_financed_usd', (select coalesce(percentile_cont(0.5) within group (order by gasto), 0)::numeric(18,2) from porpersona),
      'p90_financed_usd', (select coalesce(percentile_cont(0.9) within group (order by gasto), 0)::numeric(18,2) from porpersona),
      'avg_orders',       (select coalesce(round(avg(ordenes), 2), 0) from porpersona),
      'p50_orders',       (select coalesce(percentile_disc(0.5) within group (order by ordenes), 0)::int from porpersona),
      'avg_nights',       (select coalesce(round(avg(noches), 2), 0) from porpersona)
    ),

    'spend_buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',   t.orden,
        'label', t.label,
        'users', (select count(*) from porpersona pp where pp.gasto > t.lo and pp.gasto <= t.hi)
      ) order by t.orden)
      from tramos t
    ), '[]'::jsonb),

    'order_buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',   x.n,
        'label', case when x.n >= 5 then '5 o más' else x.n::text end,
        'users', (select count(*) from porpersona pp
                  where (x.n < 5 and pp.ordenes = x.n) or (x.n = 5 and pp.ordenes >= 5))
      ) order by x.n)
      from generate_series(1, 5) x(n)
    ), '[]'::jsonb),

    'concentration', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',          b.key,
        'label',        b.label,
        'users',        (select count(*) from ranking r where r.decil between b.lo and b.hi),
        'financed_usd', (select coalesce(sum(r.gasto), 0) from ranking r where r.decil between b.lo and b.hi)
      ) order by b.orden)
      from (values (1, 'top10',  'El 10 % que más gasta', 1, 1),
                   (2, 'next40', 'El 40 % siguiente',     2, 5),
                   (3, 'rest50', 'La mitad de abajo',     6, 10))
           as b(orden, key, label, lo, hi)
    ), '[]'::jsonb),

    -- El padrón por nivel, con lo que movió cada nivel en la ventana. Con
    -- local, cuánta gente hay en cada nivel es del padrón: `users` vale null.
    'levels', coalesce((
      select jsonb_agg(to_jsonb(q) order by q.level)
      from (
        select s.nivel                                                    as level,
               case when v_local then null else count(*)::int end          as users,
               count(*) filter (where pp.user_id is not null)::int         as active_users,
               coalesce(sum(pp.gasto), 0)                                  as financed_usd
        from metricas.personas s
        left join porpersona pp on pp.user_id = s.user_id
        group by s.nivel
      ) q
    ), '[]'::jsonb),

    -- El padrón por estado: no se parte por local.
    'statuses', case when v_local then null else coalesce((
      select jsonb_agg(to_jsonb(q) order by q.users desc)
      from (
        select s.estado as status, count(*)::int as users
        from metricas.personas s
        group by s.estado
      ) q
    ), '[]'::jsonb) end
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.admin_user_behavior(date, date, uuid) is
  'Métricas › Gente › Uso: gasto por persona (mediana y media, sin servicio), tramos, concentración, niveles y estados. Personas desde las cuotas. Con p_merchant_id, lo del padrón (personas por nivel, estados) vale null.';

-- ---------------------------------------------------------------------------
-- 5. Los grupos
-- ---------------------------------------------------------------------------

drop function if exists public.admin_group_metrics(date, date);

create or replace function public.admin_group_metrics(
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
  v_local  boolean := p_merchant_id is not null;
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

  with
  -- Un grupo es de prueba si lo es quien lo creó.
  grupos as (
    select g.id, g.name, g.created_at, g.business_date,
           public.helios_business_date(g.created_at) as dia,
           g.created_by, p.full_name as created_by_name
    from public.groups g
    join public.profiles p on p.id = g.created_by and not p.is_test
  ),
  miembros as (
    select gm.group_id, count(*)::int as n
    from public.group_members gm
    join grupos g on g.id = gm.group_id
    where gm.status <> 'left'
    group by 1
  ),
  -- Los consumos de la ventana (del local, si lo hay). `payers` sale de las
  -- cuotas: entre cuánta gente se repartió la cuenta de verdad.
  cargos as (
    select k.charge_id as id, k.group_id, k.business_date as dia,
           k.financed_usd as fin, k.personas as payers
    from metricas.consumos k
    where k.business_date between v_from and v_to
      and (p_merchant_id is null or k.merchant_id = p_merchant_id)
  )
  select jsonb_build_object(
    'business_date', v_today,
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,
    'merchant_id',   p_merchant_id,

    -- Un grupo no es de ningún local: lo que cuenta grupos creados no se
    -- parte. Los que gastaron sí: gastaron en ese local.
    'groups', jsonb_build_object(
      'total',       case when v_local then null else (select count(*) from grupos) end,
      'created',     case when v_local then null else (select count(*) from grupos where dia between v_from and v_to) end,
      'open',        case when v_local then null else (select count(*) from grupos where public.helios_group_is_open(business_date, created_at)) end,
      'with_spend',  (select count(distinct group_id) from cargos where group_id is not null),
      'avg_members', case when v_local then null else (select coalesce(round(avg(n), 1), 0) from miembros) end
    ),

    'split', jsonb_build_object(
      'group_charges',  (select count(*) from cargos where group_id is not null),
      'solo_charges',   (select count(*) from cargos where group_id is null),
      'group_financed', (select coalesce(sum(fin), 0) from cargos where group_id is not null),
      'solo_financed',  (select coalesce(sum(fin), 0) from cargos where group_id is null),
      'group_avg_usd',  (select coalesce(round(avg(fin), 2), 0) from cargos where group_id is not null),
      'solo_avg_usd',   (select coalesce(round(avg(fin), 2), 0) from cargos where group_id is null),
      'avg_payers',     (select coalesce(round(avg(payers), 2), 0) from cargos where group_id is not null)
    ),

    'series', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.day)
      from (
        select (v_from + k)                                            as day,
               case when v_local then null else coalesce(gc.n, 0)::int end as groups_created,
               coalesce(ca.n, 0)::int                                  as group_charges,
               coalesce(ca.f, 0)                                       as group_financed_usd
        from generate_series(0, v_days - 1) as g(k)
        left join (
          select dia, count(*) as n from grupos
          where dia between v_from and v_to group by 1
        ) gc on gc.dia = v_from + k
        left join (
          select dia, count(*) as n, sum(fin) as f from cargos
          where group_id is not null group by 1
        ) ca on ca.dia = v_from + k
      ) s
    ), '[]'::jsonb),

    'top', coalesce((
      select jsonb_agg(jsonb_build_object(
        'group_id',        t.id,
        'name',            t.name,
        'created_by',      t.created_by,
        'created_by_name', t.created_by_name,
        'members',         coalesce(m.n, 0),
        'charges',         t.cuentas,
        'financed_usd',    t.financiado
      ) order by t.financiado desc, t.cuentas desc, t.name, t.id)
      from (
        select g.id, g.name, g.created_by, g.created_by_name,
               count(ca.id)::int         as cuentas,
               coalesce(sum(ca.fin), 0)  as financiado
        from grupos g
        join cargos ca on ca.group_id = g.id
        group by g.id, g.name, g.created_by, g.created_by_name
        order by financiado desc, cuentas desc, g.name, g.id
        limit 10
      ) t
      left join miembros m on m.group_id = t.id
    ), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.admin_group_metrics(date, date, uuid) is
  'Métricas › Gente › Grupos: grupos que gastaron, consumo de grupo frente a individual (sin servicio) y los que más mueven. Con p_merchant_id, lo que cuenta grupos creados vale null.';

-- ---------------------------------------------------------------------------
-- 6. La retención (las cohortes de registro)
-- ---------------------------------------------------------------------------
-- Sin local, la cohorte es la gente que se registró junta. Con local, el
-- registro no es de ningún local: la cohorte es la gente que llegó junta a
-- ESE local (su primera cuota allí) y sus celdas, lo que volvió a consumir
-- allí. `base` dice cuál de las dos es.

drop function if exists public.admin_user_cohorts(text, integer);

create or replace function public.admin_user_cohorts(
  p_grain       text    default 'week',
  p_periods     integer default 8,
  p_merchant_id uuid    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today    date := metricas.hoy();
  v_local    boolean := p_merchant_id is not null;
  -- Lista blanca y no el texto crudo.
  v_grain    text := case lower(coalesce(p_grain, 'week'))
                       when 'day' then 'day' when 'month' then 'month' else 'week' end;
  v_periods  integer := greatest(least(coalesce(p_periods, 8), 24), 1);
  v_ahora    date;
  v_primero  date;
  v_result   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_ahora := public.helios_cohort_bucket(v_today, v_grain);

  v_primero := case v_grain
    when 'day'   then v_ahora - (v_periods - 1)
    when 'month' then (v_ahora - ((v_periods - 1) * interval '1 month'))::date
    else              v_ahora - (7 * (v_periods - 1))
  end;

  with
  gente as (
    select p.user_id, public.helios_cohort_bucket(p.registro_dia, v_grain) as inicio
    from metricas.personas p
    where not v_local
    union all
    select l.user_id, public.helios_cohort_bucket(l.primer_dia, v_grain)
    from metricas.personas_por_local l
    where v_local and l.merchant_id = p_merchant_id
  ),
  cohortes as (
    select inicio,
           count(*)::int as size,
           least(public.helios_cohort_period(inicio, v_ahora, v_grain), v_periods - 1) as max_k
    from gente
    where inicio between v_primero and v_ahora
    group by 1
  ),
  consumo as (
    select q.user_id,
           public.helios_cohort_bucket(q.business_date, v_grain) as cubo,
           q.charge_id,
           q.financed_usd as fin
    from metricas.cuotas q
    where p_merchant_id is null or q.merchant_id = p_merchant_id
  ),
  celdas as (
    select g.inicio,
           public.helios_cohort_period(g.inicio, co.cubo, v_grain) as k,
           count(distinct co.user_id)::int   as active,
           count(distinct co.charge_id)::int as orders,
           sum(co.fin)                       as financed
    from gente g
    join consumo co on co.user_id = g.user_id
    where g.inicio between v_primero and v_ahora
      and co.cubo >= g.inicio
    group by 1, 2
  ),
  primer_k as (
    select g.inicio,
           co.user_id,
           min(public.helios_cohort_period(g.inicio, co.cubo, v_grain)) as k0
    from gente g
    join consumo co on co.user_id = g.user_id
    where g.inicio between v_primero and v_ahora
      and co.cubo >= g.inicio
    group by 1, 2
  )
  select jsonb_build_object(
    'business_date', v_today,
    'grain',         v_grain,
    'periods',       v_periods,
    'current_start', v_ahora,
    'merchant_id',   p_merchant_id,
    -- De dónde sale cada cohorte: el día del registro o el de la primera
    -- visita al local.
    'base',          case when v_local then 'primera_visita' else 'registro' end,

    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'start',      c.inicio,
        'size',       c.size,
        'max_period', c.max_k,
        'ever_active', (
          select count(*)::int from primer_k pk where pk.inicio = c.inicio
        ),
        'ever_financed_usd', (
          select coalesce(sum(ce.financed), 0) from celdas ce where ce.inicio = c.inicio
        ),
        'cells', coalesce((
          select jsonb_agg(jsonb_build_object(
            'k',            x.k,
            'active',       coalesce(ce.active, 0),
            'orders',       coalesce(ce.orders, 0),
            'financed_usd', coalesce(ce.financed, 0),
            'cum_active', (
              select count(*)::int from primer_k pk
              where pk.inicio = c.inicio and pk.k0 <= x.k
            ),
            'cum_financed_usd', (
              select coalesce(sum(ce2.financed), 0) from celdas ce2
              where ce2.inicio = c.inicio and ce2.k <= x.k
            )
          ) order by x.k)
          from generate_series(0, c.max_k) x(k)
          left join celdas ce on ce.inicio = c.inicio and ce.k = x.k
        ), '[]'::jsonb)
      ) order by c.inicio desc)
      from cohortes c
    ), '[]'::jsonb),

    'totals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'k',    x.k,
        'size', (select coalesce(sum(c.size), 0)::int from cohortes c where c.max_k >= x.k),
        'active', (
          select coalesce(sum(ce.active), 0)::int
          from celdas ce join cohortes c on c.inicio = ce.inicio
          where ce.k = x.k and c.max_k >= x.k
        ),
        'financed_usd', (
          select coalesce(sum(ce.financed), 0)
          from celdas ce join cohortes c on c.inicio = ce.inicio
          where ce.k = x.k and c.max_k >= x.k
        )
      ) order by x.k)
      from generate_series(0, v_periods - 1) x(k)
    ), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.admin_user_cohorts(text, integer, uuid) is
  'Métricas › Gente › Retención: cohortes de la gente que se registró junta (o, con p_merchant_id, que llegó junta a ese local) y cuánta volvió a consumir en cada periodo. Personas desde las cuotas; consumo sin servicio.';

-- ---------------------------------------------------------------------------
-- 7. Permisos
-- ---------------------------------------------------------------------------

revoke all on function metricas.gente_primer_dia() from public, anon, authenticated;
revoke all on function metricas.gente_ventana(date, date) from public, anon, authenticated;

revoke all on function public.admin_growth_overview(date, date, uuid) from public, anon;
revoke all on function public.admin_growth_funnel(date, date, uuid) from public, anon;
revoke all on function public.admin_user_behavior(date, date, uuid) from public, anon;
revoke all on function public.admin_group_metrics(date, date, uuid) from public, anon;
revoke all on function public.admin_user_cohorts(text, integer, uuid) from public, anon;

grant execute on function public.admin_growth_overview(date, date, uuid) to authenticated;
grant execute on function public.admin_growth_funnel(date, date, uuid) to authenticated;
grant execute on function public.admin_user_behavior(date, date, uuid) to authenticated;
grant execute on function public.admin_group_metrics(date, date, uuid) to authenticated;
grant execute on function public.admin_user_cohorts(text, integer, uuid) to authenticated;
