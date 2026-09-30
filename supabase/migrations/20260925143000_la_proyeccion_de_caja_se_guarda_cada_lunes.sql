-- ============================================================================
-- Ronda — La proyección de caja se guarda cada lunes
--
-- `admin_cash_forecast` calcula al vuelo lo que va a entrar y salir las
-- próximas semanas, pero no guarda nada: pasada la semana no hay forma de
-- saber qué se había proyectado para ella, y una proyección que nunca se
-- compara con lo que pasó no se puede corregir.
--
-- Qué se añade:
--   · `cash_forecast_snapshots`: una foto por semana (el lunes), con la
--     proyección de las 8 semanas siguientes tal como se veía ese día. RLS
--     cerrada: solo se lee por la función de abajo;
--   · `helios_snapshot_cash_forecast()`, que toma la foto, y un trabajo de
--     pg_cron que la llama cada lunes a las 10:30 de Caracas, detrás del
--     barrido de las 10:00 (mora a las 10:05, cierre a las 10:10);
--   · `admin_forecast_vs_actual(p_weeks)`: por semana, lo proyectado frente a
--     lo que pasó según el libro (cobrado, pagado a locales y caja al final).
--
-- Para que la foto y la pantalla calculen igual, la proyección pasa a una
-- función interna, `helios_cash_forecast`, que usan `admin_cash_forecast` (con
-- la misma salida de antes) y la foto. La foto no se toma al aplicar: la
-- primera es la del próximo lunes.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- La proyección, en un solo sitio
-- ---------------------------------------------------------------------------
-- Las semanas van de `p_first_week` en adelante, `p_rows` lunes. Lo que vence a
-- los usuarios cuenta desde `p_today` hasta `p_due_until`; lo que se le debe a
-- los locales cae en el lunes de su cierre, y lo atrasado en la primera
-- semana. Devuelve `cash_now_usd`, `on_time_factor`, `grace_days` y `rows`.

create or replace function public.helios_cash_forecast(
  p_today      date,
  p_first_week date,
  p_rows       integer,
  p_due_until  date
)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $fn$
declare
  v_grace   integer := public.helios_on_time_grace_days();
  v_on_time numeric;
  v_cash    numeric;
  v_rows    jsonb;
begin
  -- El cobro a tiempo de los últimos 90 días, que es el multiplicador. Sin
  -- historia suficiente se usa 1: es preferible una proyección optimista y
  -- señalada como tal que un número sacado de cuatro cuotas.
  select case
    when count(*) filter (where i.due_date <= p_today and i.written_off_at is null) >= 20
    then round(
      count(*) filter (
        where i.status = 'paid' and i.paid_at is not null
          and public.helios_business_date(i.paid_at) <= i.due_date + v_grace
      )::numeric
      / nullif(count(*) filter (
        where i.due_date <= p_today and i.written_off_at is null), 0), 4)
    else null
  end
  into v_on_time
  from public.installments i
  where not i.is_test
    and i.due_date between p_today - 90 and p_today;

  v_cash := ledger.balance_by_type('cash');

  select coalesce(jsonb_agg(to_jsonb(q) order by q.week_start), '[]'::jsonb)
  into v_rows
  from (
    select
      s.semana                                   as week_start,
      s.semana + 6                               as week_end,
      coalesce(e.bruto, 0)                       as expected_gross_usd,
      round(coalesce(e.bruto, 0) * coalesce(v_on_time, 1), 2) as expected_in_usd,
      coalesce(o.usd, 0)                         as expected_out_usd,
      round(coalesce(e.bruto, 0) * coalesce(v_on_time, 1) - coalesce(o.usd, 0), 2) as net_usd
    from (
      select generate_series(
        p_first_week,
        p_first_week + ((greatest(p_rows, 1) - 1) * 7),
        interval '7 days'
      )::date as semana
    ) s
    left join (
      -- Lo que vence a los usuarios cada semana.
      select
        (date_trunc('week', i.due_date::timestamp))::date as semana,
        sum(i.amount_usd) as bruto
      from public.installments i
      where i.status = 'pending'
        and i.written_off_at is null
        and not i.is_test
        and i.due_date between p_today and p_due_until
      group by 1
    ) e on e.semana = s.semana
    left join (
      -- Lo que sale a los locales, por el lunes en que le toca a cada
      -- liquidación. Lo atrasado cae en la primera semana: sigue teniendo que
      -- salir.
      select
        greatest(public.helios_settlement_run_for(st.due_date), p_first_week) as semana,
        sum(st.amount_usd - st.paid_usd) as usd
      from public.settlements st
      join public.merchants m on m.id = st.merchant_id
      where st.status in ('pending', 'partial')
        and not m.is_test
      group by 1
    ) o on o.semana = s.semana
  ) q;

  return jsonb_build_object(
    'cash_now_usd', v_cash,
    'on_time_factor', v_on_time,
    'grace_days', v_grace,
    'rows', v_rows
  );
end;
$fn$;

comment on function public.helios_cash_forecast(date, date, integer, date) is
  'La proyección de caja por semanas (interna). La usan admin_cash_forecast y la foto de los lunes.';

revoke all on function public.helios_cash_forecast(date, date, integer, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- La pantalla: misma firma y misma salida que antes
-- ---------------------------------------------------------------------------

create or replace function public.admin_cash_forecast(p_weeks integer default 4)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_today date := public.helios_business_date(now());
  v_weeks integer := greatest(least(coalesce(p_weeks, 4), 12), 1);
  v_next  date;
  v_f     jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- Las semanas arrancan el lunes del cierre, no hoy: es el calendario con el
  -- que sale el dinero.
  v_next := public.helios_next_settlement_run(now());
  v_f := public.helios_cash_forecast(v_today, v_next - 7, v_weeks + 1, v_today + (v_weeks * 7));

  return jsonb_build_object(
    'business_date', v_today,
    'cash_now_usd', v_f -> 'cash_now_usd',
    'weeks', v_weeks,
    -- Null cuando no hay historia suficiente. La pantalla tiene que poder
    -- decir "sin ajustar" en vez de enseñar un 100 % que parece un dato.
    'on_time_factor', v_f -> 'on_time_factor',
    'grace_days', v_f -> 'grace_days',
    'rows', v_f -> 'rows'
  );
end;
$fn$;

-- ---------------------------------------------------------------------------
-- La foto de los lunes
-- ---------------------------------------------------------------------------

create table if not exists public.cash_forecast_snapshots (
  -- El lunes de la semana en que se tomó: la primera semana de la foto.
  week_start    date primary key,
  horizon_weeks integer not null check (horizon_weeks between 1 and 12),
  -- Lo que devolvía `helios_cash_forecast` ese día, más `business_date`.
  projected     jsonb not null,
  created_at    timestamptz not null default now()
);

comment on table public.cash_forecast_snapshots is
  'Una foto por semana de la proyección de caja, tomada el lunes, para compararla con lo que pasó (admin_forecast_vs_actual).';

alter table public.cash_forecast_snapshots enable row level security;
revoke all on table public.cash_forecast_snapshots from public, anon, authenticated;

-- Las 8 semanas que empiezan el lunes de hoy. Solo una foto por semana: si el
-- trabajo corre dos veces, o alguien la llama a mano, se queda la primera,
-- que es la que se tomó antes de ver la semana. Devuelve si la tomó.
create or replace function public.helios_snapshot_cash_forecast()
returns boolean
language plpgsql
set search_path = public, pg_temp
as $fn$
declare
  v_today  date := public.helios_business_date(now());
  v_lunes  date;
  v_semanas constant integer := 8;
  v_f      jsonb;
  v_n      integer;
begin
  v_lunes := v_today - (extract(isodow from v_today)::integer - 1);
  v_f := public.helios_cash_forecast(v_today, v_lunes, v_semanas, v_lunes + (v_semanas * 7) - 1);

  insert into public.cash_forecast_snapshots (week_start, horizon_weeks, projected)
  values (v_lunes, v_semanas, v_f || jsonb_build_object('business_date', v_today))
  on conflict (week_start) do nothing;

  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$fn$;

comment on function public.helios_snapshot_cash_forecast() is
  'Guarda la proyección de caja de las 8 semanas que empiezan este lunes. La llama pg_cron cada lunes a las 10:30 de Caracas.';

revoke all on function public.helios_snapshot_cash_forecast() from public, anon, authenticated;

-- 14:30 UTC es las 10:30 de Caracas, y el lunes UTC es el lunes de Caracas a
-- esa hora. El minuto 30 de las 14 no lo usa ningún otro trabajo.
select cron.schedule(
  'helios_cash_forecast_snapshot',
  '30 14 * * 1',
  $cron$ select public.helios_snapshot_cash_forecast(); $cron$
);

-- ---------------------------------------------------------------------------
-- Lo proyectado frente a lo que pasó
-- ---------------------------------------------------------------------------
-- Una fila por semana (lunes a domingo, en días operativos) de las `p_weeks`
-- últimas, la de hoy incluida, que tenga proyección. La proyección de cada
-- semana es la de la foto más reciente tomada ese lunes o antes (`lead_weeks`
-- dice cuántas semanas antes). Lo que pasó sale del libro, con el mismo
-- criterio que `ledger.balance_by_type`: sin los asientos de prueba.
--   · collected_usd: lo que entró por pagos de cuotas (PAYABLE, con el
--     servicio y los cargos por atraso dentro);
--   · paid_to_merchants_usd: lo que salió en transferencias a locales;
--   · other_cash_usd: cualquier otro movimiento de caja, neto;
--   · actual_cash_end_usd: la caja del libro al terminar la semana (o hoy).
-- Sin fotos, `rows` va vacío.

create or replace function public.admin_forecast_vs_actual(p_weeks integer default 8)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_today   date := public.helios_business_date(now());
  v_weeks   integer := greatest(least(coalesce(p_weeks, 8), 26), 1);
  v_lunes   date;
  v_fotos   integer;
  v_primera date;
  v_proxima date;
  v_rows    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_lunes := v_today - (extract(isodow from v_today)::integer - 1);

  select count(*), min(week_start) into v_fotos, v_primera
  from public.cash_forecast_snapshots;

  -- La próxima foto: hoy si es lunes y todavía no se tomó; si no, el lunes
  -- que viene.
  v_proxima := case
    when v_today = v_lunes
      and not exists (select 1 from public.cash_forecast_snapshots where week_start = v_lunes)
    then v_lunes
    else v_lunes + 7
  end;

  with semanas as (
    select s::date as week_start, s::date + 6 as week_end
    from generate_series(v_lunes - (v_weeks - 1) * 7, v_lunes, interval '7 days') s
  ),
  proyectado as (
    select distinct on (w.week_start)
      w.week_start,
      f.week_start as snapshot_week,
      x.fila,
      (f.projected ->> 'cash_now_usd')::numeric + (
        select coalesce(sum((y ->> 'net_usd')::numeric), 0)
        from jsonb_array_elements(f.projected -> 'rows') y
        where (y ->> 'week_start')::date <= w.week_start
      ) as cash_end
    from semanas w
    join public.cash_forecast_snapshots f on f.week_start <= w.week_start
    cross join lateral (
      select y as fila
      from jsonb_array_elements(f.projected -> 'rows') y
      where (y ->> 'week_start')::date = w.week_start
    ) x
    order by w.week_start, f.week_start desc
  ),
  caja as (
    select t.business_date, t.type::text as tipo, e.debit, e.credit
    from ledger.entries e
    join ledger.accounts a on a.id = e.account_id
    join ledger.transactions t on t.id = e.transaction_id
    where a.account_type = 'cash'
      and t.business_date <= v_lunes + 6
      and not exists (
        select 1
        from ledger.entries e2
        join ledger.accounts a2 on a2.id = e2.account_id
        where e2.transaction_id = e.transaction_id
          and a2.owner_id is not null
          and (public.helios_is_test_user(a2.owner_id) or public.helios_is_test_merchant(a2.owner_id))
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'week_start', p.week_start,
      'week_end', w.week_end,
      'complete', w.week_end < v_today,
      'snapshot_week', p.snapshot_week,
      'lead_weeks', (p.week_start - p.snapshot_week) / 7,
      'projected_gross_usd', (p.fila ->> 'expected_gross_usd')::numeric,
      'projected_in_usd', (p.fila ->> 'expected_in_usd')::numeric,
      'projected_out_usd', (p.fila ->> 'expected_out_usd')::numeric,
      'projected_net_usd', (p.fila ->> 'net_usd')::numeric,
      'projected_cash_end_usd', round(p.cash_end, 2),
      'collected_usd', r.collected,
      'paid_to_merchants_usd', r.paid_out,
      'other_cash_usd', r.other_net,
      'actual_net_usd', r.collected - r.paid_out + r.other_net,
      'actual_cash_end_usd', r.cash_end
    ) order by p.week_start), '[]'::jsonb)
  into v_rows
  from proyectado p
  join semanas w on w.week_start = p.week_start
  cross join lateral (
    select
      coalesce(sum(c.debit) filter (
        where c.tipo = 'installment_payment' and c.business_date >= w.week_start), 0) as collected,
      coalesce(sum(c.credit) filter (
        where c.tipo = 'merchant_settlement' and c.business_date >= w.week_start), 0) as paid_out,
      coalesce(sum(c.debit - c.credit) filter (
        where c.tipo not in ('installment_payment', 'merchant_settlement')
          and c.business_date >= w.week_start), 0) as other_net,
      coalesce(sum(c.debit - c.credit), 0) as cash_end
    from caja c
    where c.business_date <= w.week_end
  ) r;

  return jsonb_build_object(
    'business_date', v_today,
    'weeks_requested', v_weeks,
    'snapshots', v_fotos,
    'first_snapshot_week', v_primera,
    'next_snapshot_on', v_proxima,
    'rows', v_rows
  );
end;
$fn$;

comment on function public.admin_forecast_vs_actual(integer) is
  'Por semana, la proyección de caja guardada el lunes frente a lo que pasó según el libro. Vacío hasta la primera foto.';

revoke all on function public.admin_forecast_vs_actual(integer) from public, anon;
grant execute on function public.admin_forecast_vs_actual(integer) to authenticated;
