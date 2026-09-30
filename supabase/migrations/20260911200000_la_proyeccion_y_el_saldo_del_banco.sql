-- ============================================================================
-- Ronda — La proyección de caja, y el saldo del banco a mano
--
-- ---------------------------------------------------------------------------
-- 1. Saber el viernes que el lunes no cubre
-- ---------------------------------------------------------------------------
-- El semáforo de Hoy dice si la caja cubre **el cierre que viene**. Eso llega
-- tarde: cuando se pone rojo, quedan horas. La proyección mira cuatro semanas
-- por delante y enseña, para cada una, lo que se espera cobrar y lo que hay que
-- transferir.
--
-- Lo que entra va **ajustado por el cobro a tiempo histórico**, no por lo que
-- vence. Contar como ingreso el 100 % de lo que vence es la forma más rápida de
-- creer que un lunes cubre cuando no va a cubrir: si históricamente entra el
-- 85 %, la proyección tiene que decir 85 %.
--
-- Y las dos cifras van también en bruto, para que se vea qué parte del hueco es
-- calendario y qué parte es el descuento por cobro.
--
-- ---------------------------------------------------------------------------
-- 2. El libro no es el banco
-- ---------------------------------------------------------------------------
-- La caja del panel es la del **libro**: todo lo que se registró. El banco tiene
-- otro número, y la diferencia entre los dos es exactamente lo que no se
-- registró — un pago que nadie concilió, una comisión bancaria, una
-- transferencia hecha y no anotada.
--
-- Esa diferencia no se descubre sola. Hay que escribir el saldo real cada
-- lunes y compararlo. Es el control más barato que existe contra la
-- contabilidad que se va despegando de la realidad un céntimo por semana.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La proyección
-- ---------------------------------------------------------------------------

create or replace function public.admin_cash_forecast(p_weeks integer default 4)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today   date := public.helios_business_date(now());
  v_weeks   integer := greatest(least(coalesce(p_weeks, 4), 12), 1);
  v_grace   integer := public.helios_on_time_grace_days();
  v_hasta   date;
  v_on_time numeric;
  v_cash    numeric;
  v_rows    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_hasta := v_today + (v_weeks * 7);

  -- El cobro a tiempo de los últimos 90 días, que es el multiplicador. Sin
  -- historia suficiente se usa 1: es preferible una proyección optimista y
  -- señalada como tal que un número sacado de cuatro cuotas.
  select case
    when count(*) filter (where i.due_date <= v_today and i.written_off_at is null) >= 20
    then round(
      count(*) filter (
        where i.status = 'paid' and i.paid_at is not null
          and public.helios_business_date(i.paid_at) <= i.due_date + v_grace
      )::numeric
      / nullif(count(*) filter (
        where i.due_date <= v_today and i.written_off_at is null), 0), 4)
    else null
  end
  into v_on_time
  from public.installments i
  where not i.is_test
    and i.due_date between v_today - 90 and v_today;

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
        -- Las semanas arrancan el lunes del cierre, no hoy: es el calendario
        -- con el que sale el dinero.
        public.helios_next_settlement_run(now()) - 7,
        public.helios_next_settlement_run(now()) + ((v_weeks - 1) * 7),
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
        and i.due_date between v_today and v_hasta
      group by 1
    ) e on e.semana = s.semana
    left join (
      -- Lo que sale a los locales, por el lunes en que le toca a cada
      -- liquidación. Lo atrasado cae en la primera semana: sigue teniendo que
      -- salir.
      select
        greatest(
          public.helios_settlement_run_for(st.due_date),
          public.helios_next_settlement_run(now()) - 7
        ) as semana,
        sum(st.amount_usd - st.paid_usd) as usd
      from public.settlements st
      join public.merchants m on m.id = st.merchant_id
      where st.status in ('pending', 'partial')
        and not m.is_test
      group by 1
    ) o on o.semana = s.semana
  ) q;

  return jsonb_build_object(
    'business_date', v_today,
    'cash_now_usd', v_cash,
    'weeks', v_weeks,
    -- Null cuando no hay historia suficiente. La pantalla tiene que poder
    -- decir "sin ajustar" en vez de enseñar un 100 % que parece un dato.
    'on_time_factor', v_on_time,
    'grace_days', v_grace,
    'rows', v_rows
  );
end;
$$;

comment on function public.admin_cash_forecast(integer) is
  'Cuatro semanas por delante: lo que se espera cobrar —ajustado por el cobro a tiempo historico— y lo que hay que transferir. Las liquidaciones ya generadas; las que el cron todavia no ha encolado no entran.';

revoke all on function public.admin_cash_forecast(integer) from public, anon;
grant execute on function public.admin_cash_forecast(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El saldo real del banco
-- ---------------------------------------------------------------------------

create table if not exists public.bank_balance_checks (
  id          uuid primary key default gen_random_uuid(),
  -- Un saldo por día: dos lecturas del mismo día se pisan, que es lo correcto
  -- —la segunda corrige a la primera— y evita una lista con duplicados.
  checked_on  date not null unique,
  balance_ves numeric(18,2),
  balance_usd numeric(18,4) not null,
  fx_rate     numeric(18,6),
  -- La caja del libro ese día, congelada al anotar. Se guarda en vez de
  -- recalcularla porque el libro cambia hacia atrás cuando alguien registra
  -- tarde, y entonces la diferencia de aquel lunes dejaría de ser la que se
  -- vio aquel lunes.
  ledger_usd  numeric(18,4) not null,
  note        text,
  recorded_by uuid references auth.users (id),
  created_at  timestamptz not null default now()
);

comment on table public.bank_balance_checks is
  'El saldo real de la cuenta bancaria, anotado a mano. La diferencia con la caja del libro es exactamente lo que no se registro: un pago sin conciliar, una comision, una transferencia no anotada.';

alter table public.bank_balance_checks enable row level security;
revoke all on table public.bank_balance_checks from public, anon, authenticated;

create or replace function public.admin_record_bank_balance(
  p_balance_ves numeric default null,
  p_balance_usd numeric default null,
  p_checked_on  date default null,
  p_note        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_day    date;
  v_fx     numeric;
  v_usd    numeric(18,4);
  v_ledger numeric(18,4);
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede anotar el saldo del banco'
      using errcode = '42501';
  end if;

  if p_balance_ves is null and p_balance_usd is null then
    raise exception 'Escribe el saldo, en bolívares o en euros' using errcode = '22023';
  end if;

  v_day := coalesce(p_checked_on, public.helios_business_date(now()));

  if v_day > public.helios_business_date(now()) then
    raise exception 'No se puede anotar el saldo de un día que no ha pasado'
      using errcode = '22023';
  end if;

  v_fx := public.current_fx_rate('BCV', v_day);

  if p_balance_usd is not null then
    v_usd := p_balance_usd;
  elsif v_fx is null then
    raise exception 'No hay tasa para ese día: escribe el saldo en euros'
      using errcode = '22023';
  else
    v_usd := round(p_balance_ves / v_fx, 4);
  end if;

  -- La caja del libro a esa fecha: todo lo que movió caja hasta ese día
  -- operativo, incluido.
  select coalesce(sum(e.debit) - sum(e.credit), 0)
  into v_ledger
  from ledger.entries e
  join ledger.accounts a on a.id = e.account_id
  join ledger.transactions t on t.id = e.transaction_id
  where a.account_type = 'cash'
    and t.business_date <= v_day;

  insert into public.bank_balance_checks
    (checked_on, balance_ves, balance_usd, fx_rate, ledger_usd, note, recorded_by)
  values (v_day, p_balance_ves, v_usd, v_fx, v_ledger,
          nullif(trim(coalesce(p_note, '')), ''), v_actor)
  on conflict (checked_on) do update
    set balance_ves = excluded.balance_ves,
        balance_usd = excluded.balance_usd,
        fx_rate     = excluded.fx_rate,
        ledger_usd  = excluded.ledger_usd,
        note        = excluded.note,
        recorded_by = excluded.recorded_by,
        created_at  = now();

  perform audit.log(v_actor, 'bank_balance.recorded', null, jsonb_build_object(
    'checked_on', v_day,
    'balance_usd', v_usd,
    'ledger_usd', v_ledger,
    'difference_usd', round(v_usd - v_ledger, 4),
    'note', p_note
  ));

  return jsonb_build_object(
    'ok', true,
    'checked_on', v_day,
    'balance_usd', v_usd,
    'ledger_usd', v_ledger,
    'difference_usd', round(v_usd - v_ledger, 4)
  );
end;
$$;

comment on function public.admin_record_bank_balance(numeric, numeric, date, text) is
  'Anota el saldo real del banco de un dia y lo compara con la caja del libro. Guarda la caja congelada: el libro cambia hacia atras cuando alguien registra tarde, y la diferencia de aquel lunes tiene que seguir siendo la que se vio aquel lunes.';

revoke all on function public.admin_record_bank_balance(numeric, numeric, date, text) from public, anon;
grant execute on function public.admin_record_bank_balance(numeric, numeric, date, text) to authenticated;

create or replace function public.admin_bank_balance_history(p_limit integer default 26)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.checked_on desc), '[]'::jsonb)
  into v_rows
  from (
    select
      b.checked_on,
      b.balance_ves,
      b.balance_usd,
      b.fx_rate,
      b.ledger_usd,
      round(b.balance_usd - b.ledger_usd, 4) as difference_usd,
      b.note,
      coalesce(pa.full_name, 'Alguien del equipo') as recorded_by_name,
      b.created_at
    from public.bank_balance_checks b
    left join public.platform_admins pa on pa.user_id = b.recorded_by
    order by b.checked_on desc
    limit least(coalesce(p_limit, 26), 200)
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_bank_balance_history(integer) from public, anon;
grant execute on function public.admin_bank_balance_history(integer) to authenticated;
