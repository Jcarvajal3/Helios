-- ============================================================================
-- Ronda — La curva de cada cosecha
--
-- `admin_credit_cohorts` da de cada mes su foto de hoy: cuánto está vencido y
-- cuánto se dio por perdido. Una foto no deja comparar un mes con otro,
-- porque cada uno tiene una edad distinta: julio lleva diez semanas de
-- escalera y septiembre dos. La curva pone a todas las cosechas en la misma
-- regla: qué parte de lo financiado estaba vencida, y qué parte perdida, a la
-- semana 2, a la 3, a la 4 de haberse consumido.
--
-- ── La edad es la de cada consumo ───────────────────────────────────────────
-- La semana k de un consumo es su día operativo + 7·k: una cosecha de un mes
-- entero mezcla consumos del día 1 y del 30, y medirlos desde el principio de
-- mes le daría a los del 30 un mes de ventaja. Cada celda cuenta solo los
-- consumos que ya cumplieron esa edad (`reached_financed_usd`), así que no
-- hay celdas en el futuro; `complete` dice si ya la cumplieron todos.
--
-- ── Qué es vencido y qué es perdido ─────────────────────────────────────────
-- Igual que en `admin_credit_cohorts`, movido en el tiempo: vencido = había
-- pasado su día, no estaba pagado y no se había dado por perdido; perdido =
-- dado por perdido antes de ese día. Las dos sobre lo financiado (sin fee).
-- ============================================================================

create or replace function public.admin_cohort_curves(p_months integer default 6)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date    := public.helios_business_date(now());
  v_months integer := greatest(least(coalesce(p_months, 6), 24), 1);
  v_from   date;
  v_max    integer;
  v_rows   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := (date_trunc('month', v_today::timestamp)
             - ((v_months - 1) * interval '1 month'))::date;
  v_max  := greatest((v_today - v_from) / 7, 1);

  with
  cuota as (
    select
      c.id                                                          as charge_id,
      c.business_date                                               as dia,
      to_char(date_trunc('month', c.business_date::timestamp), 'YYYY-MM') as mes,
      i.financed_usd,
      i.due_date,
      i.status,
      i.paid_at,
      i.written_off_at
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.status = 'confirmed'
      and not c.is_test
      and not i.is_test
      and c.business_date >= v_from
  ),
  cosecha as (
    select
      q.mes,
      sum(q.financed_usd)                 as financiado,
      count(distinct q.charge_id)::integer as consumos,
      min(q.dia)                          as primero,
      max(q.dia)                          as ultimo
    from cuota q
    group by q.mes
  ),
  -- Cada cuota en cada edad que ya cumplió. En el corte de hoy manda el
  -- estado de ahora: un pago de esta mañana ya cuenta.
  punto as (
    select
      q.mes,
      e.k,
      q.financed_usd,
      q.due_date < q.dia + 7 * e.k                                   as vencida_ya,
      q.status = 'paid' and (q.paid_at is null
        or public.helios_business_date(q.paid_at) < q.dia + 7 * e.k
        or q.dia + 7 * e.k >= v_today)                               as pagada,
      q.written_off_at is not null and (
        public.helios_business_date(q.written_off_at) < q.dia + 7 * e.k
        or q.dia + 7 * e.k >= v_today)                               as perdida
    from cuota q
    cross join generate_series(1, v_max) as e(k)
    where q.dia + 7 * e.k <= v_today
  ),
  celda as (
    select
      p.mes,
      p.k,
      sum(p.financed_usd)                                                         as alcanzado,
      coalesce(sum(p.financed_usd) filter (where p.vencida_ya and not p.pagada and not p.perdida), 0) as vencido,
      coalesce(sum(p.financed_usd) filter (where p.perdida), 0)                   as perdido
    from punto p
    group by p.mes, p.k
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'month',         co.mes,
      'financed_usd',  co.financiado,
      'charge_count',  co.consumos,
      'first_day',     co.primero,
      'last_day',      co.ultimo,
      'curve', coalesce((
        select jsonb_agg(jsonb_build_object(
            'week',                     ce.k,
            'reached_financed_usd',     ce.alcanzado,
            'overdue_financed_usd',     ce.vencido,
            'overdue_pct',              round(100 * ce.vencido / nullif(ce.alcanzado, 0), 2),
            'written_off_financed_usd', ce.perdido,
            'written_off_pct',          round(100 * ce.perdido / nullif(ce.alcanzado, 0), 2),
            'complete',                 co.ultimo + 7 * ce.k <= v_today
          ) order by ce.k)
        from celda ce
        where ce.mes = co.mes
      ), '[]'::jsonb)
    ) order by co.mes desc), '[]'::jsonb)
  into v_rows
  from cosecha co;

  return jsonb_build_object(
    'business_date', v_today,
    'months',        v_months,
    'from',          v_from,
    'max_week',      v_max,
    'rows',          v_rows
  );
end;
$$;

comment on function public.admin_cohort_curves(integer) is
  'Por mes de consumo y semana de edad de cada consumo: parte de lo financiado vencida y dada por perdida en ese momento. Solo edades ya cumplidas; sin cuentas de prueba.';

revoke all on function public.admin_cohort_curves(integer) from public, anon;
grant execute on function public.admin_cohort_curves(integer) to authenticated;
