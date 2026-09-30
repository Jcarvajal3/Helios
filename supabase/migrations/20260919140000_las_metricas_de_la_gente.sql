-- ============================================================================
-- Ronda — Las métricas de la gente
--
-- El panel sabía contar dinero y no sabía contar personas. Cartera dice cuánto
-- hay en la calle y cuánto vuelve; Dinero dice cuánto hay en el banco. Ninguna
-- de las dos contesta las preguntas con las que se decide un producto:
-- ¿entra gente? ¿la que entra llega a comprar? ¿vuelve? ¿cuánto gasta cada
-- quien? ¿los grupos sirven para algo?
--
-- Cinco funciones, una por pregunta:
--
--   admin_growth_overview   ¿cuánta gente entra y qué hace? (+ serie diaria)
--   admin_growth_funnel     ¿dónde se cae la gente entre registrarse y comprar?
--   admin_user_cohorts      la que entró el lunes, ¿seguía aquí el lunes siguiente?
--   admin_user_behavior     ¿cómo se reparte el gasto entre la gente?
--   admin_group_metrics     ¿los grupos mueven volumen o son un adorno?
--
-- ── Tres decisiones que atraviesan todo el archivo ──────────────────────────
--
-- 1. **Lo de cada persona sale de `installments`, nunca de `charges`.**
--    Un consumo de grupo es UN cargo con `user_id` = quien lo abrió y una
--    cuota por integrante. Contar el gasto por `charges.user_id` le carga la
--    noche entera al que puso la cuenta y deja a los otros tres en cero: datos
--    verosímiles y falsos, que es la peor clase. Quien participó sale de las
--    cuotas.
--
-- 2. **El gasto es `financed`, sin el fee dentro.** `financed_usd` es el
--    consumo —lo que se bebió— y `amount_usd` lleva encima el servicio de
--    Ronda y su IVA. Con base 100 son 100,00 y 123,20. Mezclarlas en una
--    columna es el bug que ya se pagó una vez en las pantallas de grupo. Aquí
--    el gasto de la gente va en `financed_usd` y lo que gana Ronda va aparte,
--    en su propia cifra.
--
-- 3. **El día es el operativo, también para los registros.** `helios_business_date`
--    corta a las 10 AM, no a medianoche. Quien se registra a las 2 de la
--    mañana en la barra pertenece a la noche del viernes, que es cuando
--    efectivamente entró — y es la misma noche en la que va a aparecer su
--    primer consumo. Contarlo en sábado partiría en dos días la misma sesión y
--    ninguna cohorte cuadraría con su propia activación.
--
-- Y la de siempre: `not is_test` en todo. Las cuentas y los locales de prueba
-- no cuentan en ninguna cifra (20260911180000).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Los dos ladrillos de las cohortes
-- ---------------------------------------------------------------------------
-- Separados en funciones porque el mismo CASE aparecería seis veces dentro de
-- `admin_user_cohorts` —al agrupar, al calcular el periodo, al recortar la
-- fila— y seis copias de una regla es una regla que en la séptima edición se
-- aplica mal en una de ellas.

/**
 * El cubo al que pertenece un día: él mismo, su lunes, o su día 1.
 *
 * `immutable` y sobre `timestamp` (no `timestamptz`): `date_trunc` con zona
 * depende de la variable `TimeZone` de la sesión y por eso solo es `stable`.
 * Con ella, el mismo día caería en semanas distintas según con qué zona se
 * conecte quien pregunte — y una rejilla de cohortes que cambia de forma según
 * el cliente no se puede comparar consigo misma.
 */
create or replace function public.helios_cohort_bucket(p_day date, p_grain text)
returns date
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case p_grain
    when 'day'   then p_day
    when 'month' then date_trunc('month', p_day::timestamp)::date
    else              date_trunc('week',  p_day::timestamp)::date
  end;
$$;

comment on function public.helios_cohort_bucket(date, text) is
  'Agrupa un día operativo en su cubo de cohorte: día, semana (lunes) o mes.';

/**
 * Cuántos cubos hay entre dos cubos. Es el número de columna de la rejilla.
 *
 * Las dos fechas tienen que venir YA agrupadas por `helios_cohort_bucket`: en
 * semanas la resta se divide entre 7 y eso solo da un entero exacto si las dos
 * caen en lunes.
 */
create or replace function public.helios_cohort_period(p_from date, p_to date, p_grain text)
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case p_grain
    when 'day'   then (p_to - p_from)
    when 'month' then (12 * (extract(year  from p_to)::int - extract(year  from p_from)::int)
                          + (extract(month from p_to)::int - extract(month from p_from)::int))
    else              ((p_to - p_from) / 7)
  end;
$$;

comment on function public.helios_cohort_period(date, date, text) is
  'Distancia en cubos entre dos cubos de cohorte. Ambos argumentos ya agrupados.';

revoke all on function public.helios_cohort_bucket(date, text) from public, anon;
revoke all on function public.helios_cohort_period(date, date, text) from public, anon;
grant execute on function public.helios_cohort_bucket(date, text) to authenticated;
grant execute on function public.helios_cohort_period(date, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 0 bis. El rango de las cuatro ventanas
-- ---------------------------------------------------------------------------
-- Las cuatro funciones de abajo miran un periodo, y las cuatro tienen que
-- decidir lo mismo: qué pasa si falta un extremo, si el «hasta» es mañana, si
-- viene al revés o si alguien pide diez años. Cuatro copias de esas reglas son
-- cuatro sitios donde una se queda sin actualizar.

create or replace function public.helios_growth_window(
  p_from date default null,
  p_to   date default null
)
returns table (desde date, hasta date, dias integer)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy  date := public.helios_business_date(now());
  v_to   date;
  v_from date;
begin
  -- Nunca más allá de hoy. Un «hasta» en el futuro no añade un solo dato:
  -- ensancha el eje con días vacíos que se leen como días sin ventas.
  v_to   := least(coalesce(p_to, v_hoy), v_hoy);
  -- Sin «desde», los treinta días que acaban en el «hasta» elegido.
  v_from := coalesce(p_from, v_to - 29);

  if v_from > v_to then
    raise exception 'El «desde» (%) es posterior al «hasta» (%)', v_from, v_to
      using errcode = '22023';
  end if;

  -- El tope no es por rendimiento: la serie diaria devuelve un punto por día y
  -- un gráfico de mil barras no es un gráfico. La pantalla ya no deja pedir
  -- más; esto es el respaldo por si se llama desde otro sitio.
  if (v_to - v_from) + 1 > 366 then
    raise exception 'El periodo no puede pasar de 366 días' using errcode = '22023';
  end if;

  return query select v_from, v_to, ((v_to - v_from) + 1)::integer;
end;
$$;

comment on function public.helios_growth_window(date, date) is
  'Normaliza el rango de las metricas: recorta al dia de hoy, rellena el extremo que falte y rechaza lo imposible.';

revoke all on function public.helios_growth_window(date, date) from public, anon;
grant execute on function public.helios_growth_window(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 1. El tablero: cuánta gente entra y qué hace
-- ---------------------------------------------------------------------------

create or replace function public.admin_growth_overview(
  p_from date default null,
  p_to   date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today     date := public.helios_business_date(now());
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

  -- La ventana anterior es la de al lado, del mismo largo, y no el mismo
  -- periodo del mes pasado: con siete días eso compararía un fin de semana
  -- contra un martes.
  v_prev_from := v_from - v_days;
  v_prev_to   := v_from - 1;

  with
  -- Toda la gente real, con el día operativo en que se registró.
  gente as (
    select p.id                                           as user_id,
           public.helios_business_date(p.created_at)       as dia,
           p.status,
           p.level
    from public.profiles p
    where not p.is_test
  ),
  -- Una fila por (persona, cuota). Es el grano correcto para todo lo que se
  -- pregunta por persona: en un consumo de grupo hay una pareja de cuotas por
  -- integrante, y sumarlas da exactamente lo que le tocó a cada quien.
  consumo as (
    select i.user_id,
           c.id                                           as charge_id,
           c.business_date                                as dia,
           coalesce(i.financed_usd, i.amount_usd)         as fin,
           i.amount_usd - coalesce(i.financed_usd, i.amount_usd) as fee
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.status = 'confirmed'
      and not i.is_test
      and c.business_date is not null
  ),
  -- El día en que cada persona compró por primera vez. Es *la* fecha de
  -- activación: registrarse no es usar el producto.
  primer as (
    select user_id, min(dia) as dia
    from consumo
    group by 1
  ),
  -- El día en que se aprobó su verificación.
  verificado as (
    select v.user_id,
           min(public.helios_business_date(coalesce(v.reviewed_at, v.created_at))) as dia
    from kyc.verifications v
    join public.profiles p on p.id = v.user_id and not p.is_test
    where v.status = 'approved'
    group by 1
  )
  select jsonb_build_object(
    'business_date', v_today,
    -- El rango QUE SE USÓ, no el que se pidió: la pantalla lo pinta, y si el
    -- servidor recortó el «hasta» a hoy hay que verlo ahí y no descubrirlo
    -- comparando barras.
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,

    'registered', jsonb_build_object(
      'count',    (select count(*) from gente where dia between v_from and v_to),
      'previous', (select count(*) from gente where dia between v_prev_from and v_prev_to)
    ),

    'verified', jsonb_build_object(
      'count',    (select count(*) from verificado where dia between v_from and v_to),
      'previous', (select count(*) from verificado where dia between v_prev_from and v_prev_to)
    ),

    -- Activación: primer consumo de su vida, caído dentro de la ventana. No es
    -- "gente nueva que compró": alguien registrado en marzo que estrena hoy
    -- también activa hoy, y eso es una activación igual de real.
    'activated', jsonb_build_object(
      'count',    (select count(*) from primer where dia between v_from and v_to),
      'previous', (select count(*) from primer where dia between v_prev_from and v_prev_to)
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
      -- Lo que se lleva Ronda de ese mismo consumo. Va aparte y nunca sumado
      -- al gasto: el total con el fee dentro no se enseña.
      'revenue_usd',  (select coalesce(sum(fee), 0) from consumo where dia between v_from and v_to),
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

    -- Lo acumulado. No sigue la ventana: es la foto del padrón entero, y es la
    -- que dice si el producto tiene diez usuarios o diez mil.
    'totals', jsonb_build_object(
      'registered',   (select count(*) from gente),
      'onboarded',    (select count(*) from gente where status not in ('pending_kyc', 'pending_pin')),
      'ever_bought',  (select count(*) from primer),
      'buyers_pct',   (
        select case when (select count(*) from gente) > 0
               then round(100.0 * (select count(*) from primer) / (select count(*) from gente), 1)
               else 0 end
      )
    ),

    -- La serie diaria. Un solo viaje para los cuatro gráficos de la pantalla:
    -- pedirla cuatro veces sería cuatro escaneos de la misma tabla.
    'series', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.day)
      from (
        select (v_from + k)                      as day,
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
        ) r on r.dia = v_from + k
        left join (
          select dia, count(*) as n from verificado
          where dia between v_from and v_to group by 1
        ) vf on vf.dia = v_from + k
        left join (
          select dia, count(*) as n from primer
          where dia between v_from and v_to group by 1
        ) a on a.dia = v_from + k
        left join (
          select dia,
                 count(distinct user_id)   as usuarios,
                 count(distinct charge_id) as ordenes,
                 sum(fin)                  as financiado
          from consumo
          where dia between v_from and v_to group by 1
        ) co on co.dia = v_from + k
      ) s
    ), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.admin_growth_overview(date, date) is
  'Adquisicion y uso de la ventana, con su ventana anterior para comparar, y la serie diaria. Solo personal de Helios.';

-- La firma vieja se elimina: con las dos vivas, PostgREST resuelve por el
-- conjunto de argumentos y una llamada con `p_days` seguiría contestando con
-- una ventana que ya nadie pide.
drop function if exists public.admin_growth_overview(integer);

revoke all on function public.admin_growth_overview(date, date) from public, anon;
grant execute on function public.admin_growth_overview(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El embudo: dónde se cae la gente
-- ---------------------------------------------------------------------------
-- Cinco escalones, y cada uno es un subconjunto del anterior. La pregunta que
-- contesta no es "cuántos hay en cada estado hoy" —eso ya lo dice Personas—
-- sino "de los que entraron en esta ventana, hasta dónde llegaron".
--
-- Ojo con la ventana corta: quien se registró anoche no ha tenido tiempo de
-- comprar, así que sale como caída. La función devuelve `p50_days_to_first`
-- para que la pantalla pueda decir cuánto tarda de verdad y avisar cuando la
-- ventana es más corta que ese plazo.

create or replace function public.admin_growth_funnel(
  p_from date default null,
  p_to   date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_from   date;
  v_to     date;
  v_days   integer;
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select w.desde, w.hasta, w.dias into v_from, v_to, v_days
  from public.helios_growth_window(p_from, p_to) w;

  with
  cohorte as (
    select p.id                                     as user_id,
           public.helios_business_date(p.created_at) as dia,
           p.status
    from public.profiles p
    where not p.is_test
      and public.helios_business_date(p.created_at) between v_from and v_to
  ),
  -- Verificado tiene dos caminos: la verificación aprobada de Didit, y el
  -- atajo del super admin, que activa el perfil sin dejar fila en `kyc`. Con
  -- solo el primero, cada aprobación a mano aparecería como una caída.
  verificado as (
    select c.user_id,
           (exists (
              select 1 from kyc.verifications v
              where v.user_id = c.user_id and v.status = 'approved'
            ) or c.status <> 'pending_kyc') as ok
    from cohorte c
  ),
  consumo as (
    select i.user_id, c.id as charge_id, c.business_date as dia,
           coalesce(i.financed_usd, i.amount_usd) as fin
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.status = 'confirmed' and not i.is_test and c.business_date is not null
  ),
  compras as (
    select co.user_id,
           count(distinct co.charge_id)::int as ordenes,
           min(co.dia)                       as primer_dia
    from consumo co
    join cohorte c on c.user_id = co.user_id
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
    -- El rango QUE SE USÓ, no el que se pidió: la pantalla lo pinta, y si el
    -- servidor recortó el «hasta» a hoy hay que verlo ahí y no descubrirlo
    -- comparando barras.
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,
    'steps', jsonb_build_array(
      jsonb_build_object('key', 'registrados', 'label', 'Se registraron',
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
    -- Cuántos de los que compraron lo hicieron la misma noche en que se
    -- registraron. Es el número que dice si el producto se entiende en la
    -- barra o hace falta volver a casa a pensarlo.
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

comment on function public.admin_growth_funnel(date, date) is
  'De los registrados en la ventana, hasta que escalon llegaron, y cuanto tardan en estrenar. Solo personal de Helios.';

-- La firma vieja se elimina: con las dos vivas, PostgREST resuelve por el
-- conjunto de argumentos y una llamada con `p_days` seguiría contestando con
-- una ventana que ya nadie pide.
drop function if exists public.admin_growth_funnel(integer);

revoke all on function public.admin_growth_funnel(date, date) from public, anon;
grant execute on function public.admin_growth_funnel(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Las cohortes: la que entró el lunes, ¿seguía aquí el lunes siguiente?
-- ---------------------------------------------------------------------------
-- La rejilla clásica de retención. Cada fila es la gente que se registró en un
-- cubo —un día, una semana, un mes— y cada columna es cuántos de ESOS mismos
-- consumieron N cubos después.
--
-- Dos cosas que decide esta función y que son la diferencia entre una rejilla
-- útil y una que miente:
--
--   · **El triángulo se corta.** Una cohorte de anteayer no tiene semana 3:
--     no ha pasado. Devolver 0 ahí pinta un desplome que no existe, así que
--     cada fila trae `max_period` y no se emite ni una celda más allá.
--   · **La media de la columna N solo divide entre quien llegó a N.** Si la
--     mitad de las cohortes son demasiado jóvenes para tener columna 4,
--     meterlas en el denominador hunde esa columna por aritmética.

create or replace function public.admin_user_cohorts(
  p_grain   text default 'week',
  p_periods integer default 8
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today    date := public.helios_business_date(now());
  -- Lista blanca y no el texto crudo: este parámetro entra en un `case` y en
  -- una resta de fechas, y lo que no esté aquí se trata como semana.
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
    select p.id as user_id,
           public.helios_cohort_bucket(
             public.helios_business_date(p.created_at), v_grain) as inicio
    from public.profiles p
    where not p.is_test
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
    select i.user_id,
           public.helios_cohort_bucket(c.business_date, v_grain) as cubo,
           c.id                                   as charge_id,
           coalesce(i.financed_usd, i.amount_usd) as fin
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.status = 'confirmed' and not i.is_test and c.business_date is not null
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
      -- Nadie consume antes de existir, pero un reloj torcido o un backfill sí
      -- podrían colar una fila con cubo anterior, y eso sería una columna −1.
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

    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'start',      c.inicio,
        'size',       c.size,
        'max_period', c.max_k,
        -- Cuánta gente de la cohorte ha consumido ALGUNA VEZ, y cuánto lleva
        -- gastado. Es la primera frase de la pantalla —«de las 23 que
        -- entraron, 12 han llegado a consumir»— y no se puede sacar de las
        -- celdas: son personas distintas contadas una sola vez.
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
            -- El acumulado hasta este periodo. La curva que sube y nunca baja:
            -- cuánta de la cohorte ya había estrenado, y cuánto llevaba
            -- gastado en total.
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

    -- El renglón de abajo: todas las cohortes juntas. `size` es el denominador
    -- honrado de esa columna — solo la gente de cohortes que ya llegaron ahí.
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

comment on function public.admin_user_cohorts(text, integer) is
  'Rejilla de retencion: por cubo de registro, cuantos consumieron N cubos despues. Triangulo recortado en el presente. Solo personal de Helios.';

revoke all on function public.admin_user_cohorts(text, integer) from public, anon;
grant execute on function public.admin_user_cohorts(text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. El reparto: cómo se distribuye el gasto entre la gente
-- ---------------------------------------------------------------------------
-- Una media esconde la forma. "€38 por usuario" se lee igual si son cuarenta
-- personas gastando €38 que si son treinta y nueve gastando €4 y una gastando
-- €1.400. Esto devuelve la forma: el histograma, la concentración y la
-- recurrencia.

create or replace function public.admin_user_behavior(
  p_from date default null,
  p_to   date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_from   date;
  v_to     date;
  v_days   integer;
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select w.desde, w.hasta, w.dias into v_from, v_to, v_days
  from public.helios_growth_window(p_from, p_to) w;

  with
  consumo as (
    select i.user_id, c.id as charge_id, c.business_date as dia,
           coalesce(i.financed_usd, i.amount_usd) as fin
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.status = 'confirmed' and not i.is_test
      and c.business_date between v_from and v_to
  ),
  -- Una fila por persona activa en la ventana. Es la tabla sobre la que se
  -- contesta todo lo de abajo.
  porpersona as (
    select user_id,
           sum(fin)                          as gasto,
           count(distinct charge_id)::int    as ordenes,
           count(distinct dia)::int          as noches
    from consumo
    group by 1
  ),
  -- Los tramos son fijos y en euros, no percentiles: una barra que dice
  -- "hasta €25" se entiende sin explicación, y "el segundo quintil" no. El
  -- precio de ser fijos es que con la ventana de 90 días la gente se corre
  -- hacia la derecha; la pantalla lo dice.
  tramos(orden, label, lo, hi) as (
    values (1, 'Hasta €25',   0::numeric,   25::numeric),
           (2, '€25 a €50',   25::numeric,  50::numeric),
           (3, '€50 a €100',  50::numeric,  100::numeric),
           (4, '€100 a €200', 100::numeric, 200::numeric),
           (5, 'Más de €200', 200::numeric, 1e9::numeric)
  ),
  -- El ranking, para la concentración. `ntile(10)` sobre el gasto ordenado de
  -- mayor a menor: el decil 1 es el 10% que más gasta.
  ranking as (
    select user_id, gasto, ntile(10) over (order by gasto desc) as decil
    from porpersona
  )
  select jsonb_build_object(
    'business_date', v_today,
    -- El rango QUE SE USÓ, no el que se pidió: la pantalla lo pinta, y si el
    -- servidor recortó el «hasta» a hoy hay que verlo ahí y no descubrirlo
    -- comparando barras.
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,
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

    -- Cuántas órdenes hizo cada quien. Se corta en «5 o más»: a partir de ahí
    -- la cola es larga y plana y cada barra sería de una persona.
    'order_buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',   x.n,
        'label', case when x.n >= 5 then '5 o más' else x.n::text end,
        'users', (select count(*) from porpersona pp
                  where (x.n < 5 and pp.ordenes = x.n) or (x.n = 5 and pp.ordenes >= 5))
      ) order by x.n)
      from generate_series(1, 5) x(n)
    ), '[]'::jsonb),

    -- Los tres bloques que se leen de un vistazo: el 10% de arriba, el 40%
    -- siguiente y la mitad de abajo. Si el primero se lleva el 70%, el negocio
    -- depende de un puñado de personas y eso cambia todas las decisiones.
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

    -- El padrón por nivel, con lo que movió cada nivel dentro de la ventana.
    -- Dice si la escalera sirve: un nivel 3 que gasta lo mismo que un nivel 1
    -- es un cupo que nadie está usando.
    'levels', coalesce((
      select jsonb_agg(to_jsonb(q) order by q.level)
      from (
        select p.level                                              as level,
               count(*)::int                                        as users,
               count(*) filter (where pp.user_id is not null)::int   as active_users,
               coalesce(sum(pp.gasto), 0)                            as financed_usd
        from public.profiles p
        left join porpersona pp on pp.user_id = p.id
        where not p.is_test
        group by p.level
      ) q
    ), '[]'::jsonb),

    -- El padrón por estado. Congelados y suspendidos son mora; expulsados son
    -- la fuga definitiva.
    'statuses', coalesce((
      select jsonb_agg(to_jsonb(q) order by q.users desc)
      from (
        select p.status::text as status, count(*)::int as users
        from public.profiles p
        where not p.is_test
        group by p.status
      ) q
    ), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.admin_user_behavior(date, date) is
  'Forma del gasto: histograma por persona, ordenes por persona, concentracion, niveles y estados. Solo personal de Helios.';

-- La firma vieja se elimina: con las dos vivas, PostgREST resuelve por el
-- conjunto de argumentos y una llamada con `p_days` seguiría contestando con
-- una ventana que ya nadie pide.
drop function if exists public.admin_user_behavior(integer);

revoke all on function public.admin_user_behavior(date, date) from public, anon;
grant execute on function public.admin_user_behavior(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Los grupos: ¿mueven volumen o son un adorno?
-- ---------------------------------------------------------------------------

create or replace function public.admin_group_metrics(
  p_from date default null,
  p_to   date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_from   date;
  v_to     date;
  v_days   integer;
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select w.desde, w.hasta, w.dias into v_from, v_to, v_days
  from public.helios_growth_window(p_from, p_to) w;

  with
  -- Un grupo es de prueba si lo es quien lo creó: no hay bandera propia y no
  -- hace falta, porque un grupo sin cargos no entra en ninguna cifra de aquí.
  grupos as (
    select g.id, g.name, g.created_at, g.status,
           public.helios_business_date(g.created_at) as dia
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
  -- Los cargos de la ventana, marcados con si fueron de grupo. `payers` sale
  -- de las cuotas: es entre cuánta gente se repartió esa cuenta de verdad, no
  -- cuánta gente hay apuntada en el grupo.
  cargos as (
    select c.id, c.group_id, c.business_date as dia,
           coalesce(c.base_usd, c.amount_usd) as fin,
           (select count(distinct i.user_id)
            from public.installments i where i.charge_id = c.id)::int as payers
    from public.charges c
    where c.status = 'confirmed' and not c.is_test
      and c.business_date between v_from and v_to
  )
  select jsonb_build_object(
    'business_date', v_today,
    -- El rango QUE SE USÓ, no el que se pidió: la pantalla lo pinta, y si el
    -- servidor recortó el «hasta» a hoy hay que verlo ahí y no descubrirlo
    -- comparando barras.
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,

    'groups', jsonb_build_object(
      'total',     (select count(*) from grupos),
      'created',   (select count(*) from grupos where dia between v_from and v_to),
      'open',      (select count(*) from grupos where status = 'active'),
      -- Grupos que pusieron al menos una cuenta en la ventana. Un grupo creado
      -- y nunca usado es el fracaso silencioso de esta función.
      'with_spend', (select count(distinct group_id) from cargos where group_id is not null),
      'avg_members', (select coalesce(round(avg(n), 1), 0) from miembros)
    ),

    -- Grupo contra individual, en las dos monedas que importan: cuántas
    -- cuentas y cuánto dinero.
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
        select (v_from + k)              as day,
               coalesce(gc.n, 0)::int    as groups_created,
               coalesce(ca.n, 0)::int    as group_charges,
               coalesce(ca.f, 0)         as group_financed_usd
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
        'group_id',     t.id,
        'name',         t.name,
        'members',      coalesce(m.n, 0),
        'charges',      t.cuentas,
        'financed_usd', t.financiado
      ) order by t.financiado desc)
      from (
        select g.id, g.name,
               count(ca.id)::int         as cuentas,
               coalesce(sum(ca.fin), 0)  as financiado
        from grupos g
        join cargos ca on ca.group_id = g.id
        group by g.id, g.name
        order by 4 desc
        limit 10
      ) t
      left join miembros m on m.group_id = t.id
    ), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.admin_group_metrics(date, date) is
  'Adopcion de grupos: cuantos hay, cuantos gastan, grupo contra individual y el top 10. Solo personal de Helios.';

-- La firma vieja se elimina: con las dos vivas, PostgREST resuelve por el
-- conjunto de argumentos y una llamada con `p_days` seguiría contestando con
-- una ventana que ya nadie pide.
drop function if exists public.admin_group_metrics(integer);

revoke all on function public.admin_group_metrics(date, date) from public, anon;
grant execute on function public.admin_group_metrics(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Ningún índice nuevo, y por qué
-- ---------------------------------------------------------------------------
-- La tentación era indexar `public.helios_business_date(created_at)` sobre
-- `profiles`, que es por donde agrupan las cinco funciones. Dos motivos para
-- no hacerlo:
--
--   · Un índice de expresión obliga a que la función sea inmutable, y
--     `helios_business_date` lo está DECLARADO pero por dentro hace
--     `at time zone 'America/Caracas'`, que depende de la base de datos de
--     zonas horarias. Si una actualización del sistema corrige una regla
--     histórica de Venezuela —ya pasó en 2007 y en 2016—, el índice queda
--     apuntando a días que la función ya no devuelve, y una consulta que use
--     el índice contesta distinto que la misma consulta sin él. Un índice
--     que miente es peor que no tenerlo.
--   · No hace falta. `profiles` son cientos de filas y `charges` miles; el
--     escaneo completo de las cinco es de milisegundos. El camino de vuelta
--     de las cuotas al cargo ya lo cubre el índice único de
--     `(charge_id, sequence)`.
--
-- Si algún día esto pesa, lo que toca no es el índice de expresión: es una
-- columna `business_date` materializada en `profiles`, como ya la tiene
-- `charges`.
