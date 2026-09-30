-- ============================================================================
-- Ronda — Un registro es un teléfono confirmado
--
-- La tarjeta «Se registraron» contaba de más, y no por poco: el día que se
-- escribió esto, 6 de 56 perfiles de producción —un 11 %— eran números que
-- pidieron un código por SMS y nunca lo metieron. Ninguno había entrado jamás.
--
-- ---------------------------------------------------------------------------
-- Por qué pasa
-- ---------------------------------------------------------------------------
-- Supabase crea la fila de `auth.users` cuando se PIDE el código, no cuando
-- se acierta: `signInWithOtp` la inserta con `phone_confirmed_at` en null y
-- manda el SMS. Y `profiles` cuelga de un trigger sobre `auth.users`
-- (`handle_new_user`, 20260821210000), así que el perfil nace en ese mismo
-- instante.
--
-- O sea que un número inventado, un dedo torcido al teclear o alguien que se
-- arrepiente a mitad ya eran «un registro». Y no era solo una cifra inflada:
-- esa gente entra en el denominador de la activación, del embudo y de todas
-- las cohortes, así que hundía los porcentajes de todo lo demás.
--
-- ---------------------------------------------------------------------------
-- Dónde SÍ hay que seguir contándolos
-- ---------------------------------------------------------------------------
-- En el primer escalón del embudo, y en ninguna otra parte. El hueco entre
-- «pidieron el código» y «confirmaron el teléfono» es la única señal que hay
-- de que los SMS no están llegando —y en Venezuela eso pasa—. Esconderlo del
-- todo cambiaría un número inflado por un problema invisible.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Qué cuenta como registro, en un solo sitio
-- ---------------------------------------------------------------------------
-- Una vista y no un predicado por fila: son cinco consultas que necesitan la
-- misma definición, y con cinco copias del `join` la sexta se escribe sin él.
--
-- Sin `security_invoker`, así que corre con los permisos de su dueño y puede
-- mirar `auth.users`. Se le quita el acceso a todo el mundo: las únicas que
-- la leen son las funciones `security definer` de las métricas.

create or replace view public.helios_signups as
  select p.id                                     as user_id,
         public.helios_business_date(p.created_at) as dia,
         p.status,
         p.level
  from public.profiles p
  join auth.users u on u.id = p.id
  where not p.is_test
    and u.phone_confirmed_at is not null;

comment on view public.helios_signups is
  'Quien cuenta como registro: perfil real (no de prueba) con el telefono confirmado de verdad. Pedir el codigo y no meterlo no es registrarse.';

revoke all on public.helios_signups from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Las cuatro funciones que contaban personas
-- ---------------------------------------------------------------------------
-- Los cuerpos salen enteros de 20260919140000 y solo cambia de dónde sale la
-- gente. `admin_group_metrics` no entra: ahí los perfiles solo se miran para
-- descartar los de prueba de quien creó un grupo, y para crear un grupo hay
-- que haber entrado — o sea, haber confirmado el teléfono.

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
  -- Toda la gente real, con el día operativo en que se registró. Sale de la
  -- vista y no de `profiles`: un perfil existe desde que se PIDE el código,
  -- y quien nunca lo metió no es un registro. Ver `helios_signups`.
  gente as (
    select s.user_id, s.dia, s.status, s.level
    from public.helios_signups s
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
  -- Todo el que llegó a pedir un código en la ventana, haya confirmado o no.
  -- Es el escalón cero y el único sitio del archivo donde se cuenta a quien no
  -- confirmó: aquí SÍ interesa, porque el hueco entre este escalón y el
  -- siguiente es lo que avisa de que los SMS no están llegando.
  pidieron as (
    select p.id as user_id
    from public.profiles p
    where not p.is_test
      and public.helios_business_date(p.created_at) between v_from and v_to
  ),
  cohorte as (
    select s.user_id, s.dia, s.status
    from public.helios_signups s
    where s.dia between v_from and v_to
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
    select s.user_id,
           public.helios_cohort_bucket(s.dia, v_grain) as inicio
    from public.helios_signups s
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
        select s.level                                              as level,
               count(*)::int                                        as users,
               count(*) filter (where pp.user_id is not null)::int   as active_users,
               coalesce(sum(pp.gasto), 0)                            as financed_usd
        from public.helios_signups s
        left join porpersona pp on pp.user_id = s.user_id
        group by s.level
      ) q
    ), '[]'::jsonb),

    -- El padrón por estado. Congelados y suspendidos son mora; expulsados son
    -- la fuga definitiva.
    'statuses', coalesce((
      select jsonb_agg(to_jsonb(q) order by q.users desc)
      from (
        select s.status::text as status, count(*)::int as users
        from public.helios_signups s
        group by s.status
      ) q
    ), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

-- Los permisos sobreviven a un `create or replace`, pero repetirlos deja la
-- migración completa por sí sola: aplicarla sobre una base a medias no deja
-- una función sin `grant`.
revoke all on function public.admin_growth_overview(date, date) from public, anon;
revoke all on function public.admin_growth_funnel(date, date)   from public, anon;
revoke all on function public.admin_user_cohorts(text, integer)  from public, anon;
revoke all on function public.admin_user_behavior(date, date)    from public, anon;

grant execute on function public.admin_growth_overview(date, date) to authenticated;
grant execute on function public.admin_growth_funnel(date, date)   to authenticated;
grant execute on function public.admin_user_cohorts(text, integer)  to authenticated;
grant execute on function public.admin_user_behavior(date, date)    to authenticated;
