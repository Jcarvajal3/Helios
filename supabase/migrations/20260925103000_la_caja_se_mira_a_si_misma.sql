-- ============================================================================
-- Ronda — La caja se mira a sí misma
--
-- Caja aprueba pagos y limpia el extracto, pero no tenía forma de saber si lo
-- hace bien: qué abonos se descartaron y por qué, cuánto tarda un pago en
-- resolverse, qué parte de lo aprobado tiene respaldo en el banco y cuánto
-- lleva esperando la cola.
--
--   admin_discarded_deposits      los abonos del extracto descartados, con
--                                 quién, cuándo y el motivo
--   admin_reconciliation_health   respaldo en el extracto, tiempo hasta
--                                 resolver y la cola viva por antigüedad
--
-- ── Lo que la base NO guarda, dicho en vez de inventado ──────────────────────
-- * «Tenía coincidencia en el extracto» se calcula HOY, contra el extracto que
--   esté importado ahora, con el mismo criterio que la cola (referencia por el
--   final, monto ±1 Bs y fecha ±5 días). La base no guarda qué movimiento vio
--   el operador al aprobar (no hay `statement_line_id` en `payment_reports`),
--   así que no se puede saber si aprobó CON respaldo o si el respaldo llegó
--   después. `statement` dice hasta qué fecha está importado, para que un «sin
--   coincidencia» reciente se lea como «aún no importado».
-- * El tiempo hasta resolver sí se guarda: `reviewed_at`, que `reconcile_payment`
--   pone al aprobar y al rechazar. Marcar «en revisión» no lo toca, así que el
--   tiempo es hasta la decisión final, no hasta el primer vistazo.
-- * Los pagos que nacen de asignar un abono del extracto (`admin_assign_deposit`)
--   se crean y se aprueban en el mismo instante: se cuentan aparte y quedan
--   fuera de los tiempos, o hundirían la mediana a cero.
--
-- Los montos de la cola son PAYABLE (lo que la persona dice haber pagado, con
-- el fee dentro). Las cuentas de prueba no cuentan.
-- ============================================================================

create index if not exists bank_statement_lines_discarded_idx
  on public.bank_statement_lines (resolved_at desc)
  where status = 'descartado';

-- Para saber si un pago nació de un abono asignado sin recorrer el extracto.
create index if not exists bank_statement_lines_report_idx
  on public.bank_statement_lines (report_id)
  where report_id is not null;

-- Para leer los pagos resueltos de un rango sin recorrer la tabla.
create index if not exists payment_reports_reviewed_idx
  on public.payment_reports (reviewed_at)
  where reviewed_at is not null;

-- ---------------------------------------------------------------------------
-- 1. Los abonos descartados
-- ---------------------------------------------------------------------------
-- Descartar un abono es decir «este dinero no es de ningún usuario». Si alguien
-- se equivoca, un pago real se queda sin aplicar y la persona sigue en mora:
-- esta lista es la que permite revisarlo.
create or replace function public.admin_discarded_deposits(p_limit integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.discarded_at desc nulls last), '[]'::jsonb)
    into v_rows
  from (
    select
      l.id,
      l.bank,
      l.moved_on,
      l.reference,
      l.amount_ves,
      l.description,
      -- En euros a la tasa de ESE día, como en `admin_unmatched_deposits`.
      (
        select round(l.amount_ves / r.rate, 2)
        from public.exchange_rates r
        where r.effective_date <= l.moved_on
        order by r.effective_date desc
        limit 1
      ) as amount_usd,
      l.imported_at,
      coalesce(pi.full_name, 'Alguien del equipo') as imported_by_name,
      l.resolved_at as discarded_at,
      l.resolved_by as discarded_by,
      coalesce(pa.full_name, 'Alguien del equipo') as discarded_by_name,
      l.resolution_note as reason
    from public.bank_statement_lines l
    left join public.platform_admins pa on pa.user_id = l.resolved_by
    left join public.platform_admins pi on pi.user_id = l.imported_by
    where l.status = 'descartado'
    order by l.resolved_at desc nulls last
    limit least(greatest(coalesce(p_limit, 100), 1), 500)
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_discarded_deposits(integer) from public, anon;
grant execute on function public.admin_discarded_deposits(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. La salud de la conciliación
-- ---------------------------------------------------------------------------
-- El rango (días operativos) acota los pagos RESUELTOS por `reviewed_at`. La
-- cola viva no depende del rango: es la de ahora.
create or replace function public.admin_reconciliation_health(
  p_from date default null,
  p_to   date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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

  v_from_ts := (v_from::timestamp + interval '10 hours') at time zone 'America/Caracas';
  v_to_ts   := ((v_to + 1)::timestamp + interval '10 hours') at time zone 'America/Caracas';

  with base as (
    select r.id, r.status::text as status, r.method, r.reference,
           r.created_at, r.reviewed_at, q.amount_ves
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
      -- El criterio de `statement_matches` de la cola, tal cual.
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
          (count(*) filter (where status = 'reconciled' and in_statement and not from_deposit and matched))::integer,
        'match_pct', case
          when count(*) filter (where status = 'reconciled' and in_statement and not from_deposit) > 0
          then round(100.0 * count(*) filter (where status = 'reconciled' and in_statement and not from_deposit and matched)
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
               (count(r.*) filter (where r.status = 'reconciled' and not r.from_deposit and r.matched))::integer as approved_matched,
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
$$;

revoke all on function public.admin_reconciliation_health(date, date) from public, anon;
grant execute on function public.admin_reconciliation_health(date, date) to authenticated;
