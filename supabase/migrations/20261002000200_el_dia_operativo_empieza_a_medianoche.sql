-- ============================================================================
-- Helios — El día operativo empieza a MEDIANOCHE (H2, docs/00 §4.4)
--
-- En Ronda el día operativo iba de 10:00 a 10:00 de Caracas: una noche de
-- rumba que cruzaba la medianoche contaba como un solo día. Una consulta
-- médica no cruza la noche, así que en Helios el día operativo es el día del
-- calendario de Caracas:
--
--   helios_business_date(ts) = (ts at time zone 'America/Caracas')::date
--
-- Se cambian las dos funciones canónicas y las copias que llevaban el desfase
-- escrito a mano (búsqueda exhaustiva en prosrc y vistas de «10 hours»,
-- «interval '10», «- 10», «10:00», «% 24»):
--
--   · helios_business_date, helios_business_day_end (las canónicas);
--   · metricas.dia_operativo, asistente.dia_operativo,
--     asistente.dia_operativo_actual (copias de la canónica para sus esquemas);
--   · helios_promise_status (fin del día prometido) y
--     admin_reconciliation_health (rango de instantes): ahora llaman a
--     helios_business_day_end en vez de repetir la cuenta;
--   · merchant_hourly_profile: las horas van de 0 a 23, no de 10 a 9.
--
-- Todo lo demás (mora, vencimientos, liquidaciones, métricas por semana,
-- `admin_collection_flow`, `admin_metricas_semanas`,
-- `admin_metricas_semana_resumen`…) lee `business_date` o llama a la canónica,
-- así que pasa a medianoche sin tocarlo. En esas tres quedan COMENTARIOS que
-- hablan de «la noche que acaba el lunes a las 10:00»: son prosa, no lógica.
--
-- Lo que NO cambia, a propósito:
--   · La hora de los crons: tasa 10:00 → mora 10:05 → liquidaciones 10:10, y
--     el cierre de liquidaciones de los lunes a las 10:00. El BCV publica por
--     la mañana; a esas horas el día operativo y el de calendario coinciden.
--   · La forma de las RPC de métricas: las claves `noches`, `mejor_noche`,
--     `avg_nights`… se quedan (el panel las lee). Ahora cuentan DÍAS con
--     actividad; el panel las rotula como días.
--   · No se añade `business_day_offset_hours` (docs/00 §4.4 lo proponía «por
--     si hiciera falta»): la canónica es IMMUTABLE y leer un parámetro la haría
--     STABLE en cientos de consultas. Si algún día hace falta, se cambia esta
--     función y nada más.
--   · No hay índices, defaults ni checks que dependan de estas funciones
--     (comprobado en pg_index, pg_attrdef y pg_constraint), así que cambiar una
--     función IMMUTABLE no deja nada indexado con el valor viejo. La base no
--     tiene datos de operación todavía.
-- ============================================================================

create or replace function public.helios_business_date(p_ts timestamptz)
returns date
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select (p_ts at time zone 'America/Caracas')::date;
$$;

comment on function public.helios_business_date(timestamptz) is
  'Día operativo de Helios: el día del calendario de Caracas (empieza a medianoche). En Ronda empezaba a las 10:00.';

create or replace function public.helios_business_day_end(p_business_date date)
returns timestamptz
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select (p_business_date + 1)::timestamp at time zone 'America/Caracas';
$$;

comment on function public.helios_business_day_end(date) is
  'Instante en que termina el día operativo: la medianoche de Caracas del día siguiente.';

create or replace function metricas.dia_operativo(p_ts timestamptz)
returns date
language sql
immutable
parallel safe
as $$
  select (p_ts at time zone 'America/Caracas')::date;
$$;

create or replace function asistente.dia_operativo(p_ts timestamptz)
returns date
language sql
immutable
set search_path = pg_catalog
as $$ select (p_ts at time zone 'America/Caracas')::date $$;

create or replace function asistente.dia_operativo_actual()
returns date
language sql
stable
set search_path = pg_catalog
as $$ select (now() at time zone 'America/Caracas')::date $$;

-- ---------------------------------------------------------------------------
-- Las que repetían la cuenta a mano. Copiadas de la base (pg_get_functiondef,
-- 2026-09-30) con solo el trozo del desfase cambiado.
-- ---------------------------------------------------------------------------

-- ── public.helios_promise_status
CREATE OR REPLACE FUNCTION public.helios_promise_status(p_user uuid, p_contacted_at timestamp with time zone, p_promise_date date, p_today date)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case
    when p_promise_date is null then null
    when exists (
      select 1 from public.payment_reports pr
      where pr.user_id = p_user
        and pr.status not in ('rejected', 'duplicate')
        and pr.created_at >= p_contacted_at
        -- El final del día operativo prometido: la medianoche de Caracas
        -- (Helios, H2). Escrito como instante para que use el índice
        -- (user_id, created_at).
        and pr.created_at < public.helios_business_day_end(p_promise_date)
    ) then 'cumplida'
    when p_promise_date > p_today then 'pendiente'
    when p_promise_date = p_today then 'vence_hoy'
    else 'rota'
  end
$function$
;

-- ── public.admin_reconciliation_health
CREATE OR REPLACE FUNCTION public.admin_reconciliation_health(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_to      date := coalesce(p_to, public.helios_business_date(now()));
  v_from    date := coalesce(p_from, coalesce(p_to, public.helios_business_date(now())) - 29);
  v_from_ts timestamptz;
  v_to_ts   timestamptz;
  v_result  jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_to < v_from then
    raise exception 'El rango de fechas está al revés' using errcode = '22023';
  end if;

  -- El día operativo empieza a medianoche (Helios, H2).
  v_from_ts := public.helios_business_day_end(v_from - 1);
  v_to_ts   := public.helios_business_day_end(v_to);

  with base as (
    select r.id, r.status::text as status, r.method, r.reference,
           r.created_at, r.reviewed_at, q.amount_ves, r.statement_line_id
    from public.payment_reports r
    join public.payment_quotes q on q.id = r.quote_id
    join public.profiles p on p.id = r.user_id
    where r.status in ('reconciled', 'rejected', 'duplicate')
      and r.reviewed_at >= v_from_ts
      and r.reviewed_at <  v_to_ts
      and not p.is_test
  ),
  res as (
    select
      b.*,
      exists (
        select 1 from public.bank_statement_lines l where l.report_id = b.id
      ) as from_deposit,
      -- Aprobado con un movimiento del extracto ligado: el que se miró al
      -- aprobar, no el que coincide hoy.
      b.statement_line_id is not null as linked,
      -- El criterio de `statement_matches` de la cola, tal cual. Solo para
      -- los rechazados: uno que encaja merece otra mirada.
      exists (
        select 1 from public.bank_statement_lines l
        where b.reference is not null
          and l.reference like '%' || b.reference
          and abs(l.amount_ves - b.amount_ves) <= 1.00
          and l.moved_on between (b.created_at::date - 5) and (b.created_at::date + 5)
      ) as matched,
      -- Los métodos que salen en el extracto del banco en bolívares. Zelle,
      -- USDT y efectivo no pueden tener coincidencia por construcción.
      b.method in ('pago_movil', 'transferencia') as in_statement,
      (extract(epoch from (b.reviewed_at - b.created_at)) / 60.0)::double precision as minutes
    from base b
  ),
  metodos(method, ord) as (
    values ('pago_movil', 1), ('transferencia', 2), ('zelle', 3), ('usdt', 4), ('efectivo', 5)
  ),
  cola as (
    select r.status::text as status, q.amount_usd,
           now() - r.created_at as age, r.created_at
    from public.payment_reports r
    join public.payment_quotes q on q.id = r.quote_id
    join public.profiles p on p.id = r.user_id
    where r.status in ('reported', 'in_review')
      and not p.is_test
  )
  select jsonb_build_object(
    'from', v_from,
    'to', v_to,
    'resolved', (
      select jsonb_build_object(
        'total',         count(*)::integer,
        'approved',      (count(*) filter (where status = 'reconciled'))::integer,
        'rejected',      (count(*) filter (where status = 'rejected'))::integer,
        'duplicate',     (count(*) filter (where status = 'duplicate'))::integer,
        -- Aprobados que nacieron de asignar un abono: respaldados por
        -- construcción, fuera de la tasa.
        'approved_from_deposit', (count(*) filter (where status = 'reconciled' and from_deposit))::integer,
        -- La tasa de respaldo: aprobados por métodos que salen en el extracto.
        'approved_in_statement_methods',
          (count(*) filter (where status = 'reconciled' and in_statement and not from_deposit))::integer,
        'approved_matched',
          (count(*) filter (where status = 'reconciled' and in_statement and not from_deposit and linked))::integer,
        'match_pct', case
          when count(*) filter (where status = 'reconciled' and in_statement and not from_deposit) > 0
          then round(100.0 * count(*) filter (where status = 'reconciled' and in_statement and not from_deposit and linked)
                     / count(*) filter (where status = 'reconciled' and in_statement and not from_deposit), 1)
        end,
        -- Rechazados que SÍ tienen un movimiento que encaja: merecen otra mirada.
        'rejected_matched', (count(*) filter (where status = 'rejected' and matched))::integer
      )
      from res
    ),
    'by_method', (
      select jsonb_agg(jsonb_build_object(
               'method', x.method,
               'approved', x.approved,
               'approved_matched', x.approved_matched,
               'rejected', x.rejected
             ) order by x.ord)
      from (
        select m.method, m.ord,
               (count(r.*) filter (where r.status = 'reconciled' and not r.from_deposit))::integer as approved,
               (count(r.*) filter (where r.status = 'reconciled' and not r.from_deposit and r.linked))::integer as approved_matched,
               (count(r.*) filter (where r.status = 'rejected'))::integer as rejected
        from metodos m
        left join res r on r.method = m.method
        group by m.method, m.ord
      ) x
    ),
    -- Minutos desde el reporte hasta la decisión. Sin los nacidos de un abono.
    'resolution_minutes', (
      select jsonb_build_object(
        'all', jsonb_build_object(
          'count', count(*)::integer,
          'median', round(percentile_cont(0.5) within group (order by minutes)::numeric, 1),
          'p90',    round(percentile_cont(0.9) within group (order by minutes)::numeric, 1)
        ),
        'approved', jsonb_build_object(
          'count', (count(*) filter (where status = 'reconciled'))::integer,
          'median', round((percentile_cont(0.5) within group (order by minutes)
                           filter (where status = 'reconciled'))::numeric, 1),
          'p90',    round((percentile_cont(0.9) within group (order by minutes)
                           filter (where status = 'reconciled'))::numeric, 1)
        ),
        'rejected', jsonb_build_object(
          'count', (count(*) filter (where status = 'rejected'))::integer,
          'median', round((percentile_cont(0.5) within group (order by minutes)
                           filter (where status = 'rejected'))::numeric, 1),
          'p90',    round((percentile_cont(0.9) within group (order by minutes)
                           filter (where status = 'rejected'))::numeric, 1)
        )
      )
      from res
      where not from_deposit
    ),
    -- La cola de ahora, por lo que lleva esperando. PAYABLE.
    'queue', (
      select jsonb_build_object(
        'count', count(*)::integer,
        'usd', coalesce(sum(amount_usd), 0),
        'in_review', (count(*) filter (where status = 'in_review'))::integer,
        'oldest_created_at', min(created_at),
        'under_24h', jsonb_build_object(
          'count', (count(*) filter (where age < interval '24 hours'))::integer,
          'usd', coalesce(sum(amount_usd) filter (where age < interval '24 hours'), 0)),
        'from_1_to_3_days', jsonb_build_object(
          'count', (count(*) filter (where age >= interval '24 hours' and age <= interval '72 hours'))::integer,
          'usd', coalesce(sum(amount_usd) filter (where age >= interval '24 hours' and age <= interval '72 hours'), 0)),
        'over_3_days', jsonb_build_object(
          'count', (count(*) filter (where age > interval '72 hours'))::integer,
          'usd', coalesce(sum(amount_usd) filter (where age > interval '72 hours'), 0))
      )
      from cola
    ),
    -- Hasta dónde llega el extracto importado.
    'statement', (
      select jsonb_build_object(
        'last_moved_on', max(l.moved_on),
        'last_imported_at', max(l.imported_at)
      )
      from public.bank_statement_lines l
    )
  )
  into v_result;

  return v_result;
end;
$function$
;

-- ── public.merchant_hourly_profile
CREATE OR REPLACE FUNCTION public.merchant_hourly_profile(p_days integer DEFAULT 30)
 RETURNS TABLE(hour_of_day smallint, sold_usd numeric, charge_count integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_today    date;
  v_days     integer := greatest(least(coalesce(p_days, 30), 365), 1);
begin
  if v_merchant is null then
    raise exception 'Solo el gerente del comercio' using errcode = '42501';
  end if;

  v_today := public.helios_business_date(now());

  return query
  with hours as (
    -- 0, 1, ... 23 — el día operativo empieza a medianoche (Helios, H2).
    select g::smallint as h, g as sort_key
    from generate_series(0, 23) g
  )
  select
    hours.h,
    coalesce(c.sold, 0)::numeric,
    coalesce(c.cnt, 0)::integer
  from hours
  left join (
    select
      extract(hour from ch.confirmed_at at time zone 'America/Caracas')::smallint as h,
      sum(public.helios_merchant_sale_usd(ch.base_usd, ch.vat_usd, ch.amount_usd)) as sold,
      count(*)::integer as cnt
    from public.charges ch
    where ch.merchant_id = v_merchant
      and ch.status = 'confirmed'
      and ch.confirmed_at is not null
      and ch.business_date between v_today - (v_days - 1) and v_today
    group by 1
  ) c on c.h = hours.h
  order by hours.sort_key;
end;
$function$
;

