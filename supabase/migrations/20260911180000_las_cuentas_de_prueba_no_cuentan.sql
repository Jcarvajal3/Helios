-- ============================================================================
-- Ronda — Las cuentas de prueba dejan de contar
--
-- "RONDA DEMO", los perfiles "Sin nombre 5841411…" y los RIF J-12345677/78
-- están mezclados con la operación real: cuentan en la mora, en las cosechas,
-- en los rankings por comercio y en las colas de trabajo. Mientras eso siga
-- así, **ninguna cifra del panel es del todo cierta** — y todo lo que se
-- decide se decide con esas cifras.
--
-- Lo que hace esta migración: una bandera que solo pone y quita el super
-- admin, y que excluye esas cuentas de todos los números y de todas las colas,
-- pero **las deja ver en listas y búsquedas** con su etiqueta. Sus consumos y
-- pagos siguen escribiéndose en el libro y en la bitácora: una prueba tiene
-- que dejar rastro, solo que no puede contaminar la contabilidad.
--
-- ---------------------------------------------------------------------------
-- Por qué la bandera se denormaliza
-- ---------------------------------------------------------------------------
-- `profiles.is_test` y `merchants.is_test` son la verdad. Pero casi todas las
-- métricas agregan sobre `charges` e `installments` sin tocar ninguna de las
-- dos, y meter dos joins en cada una de ellas por una bandera que cambia una
-- vez al año es pagar en cada consulta lo que se puede pagar una vez al
-- marcar.
--
-- Así que `charges.is_test` e `installments.is_test` se copian al insertar,
-- con trigger, y `helios_resync_test_flags()` las recalcula cuando alguien
-- cambia la bandera de origen. Un consumo es de prueba si lo es **la persona o
-- el local**: probar con un usuario real en el comercio DEMO tampoco debe
-- ensuciar nada.
--
-- ---------------------------------------------------------------------------
-- Y por qué el libro NO lleva columna
-- ---------------------------------------------------------------------------
-- Los asientos los escriben ocho funciones distintas y cada una tendría que
-- acordarse de marcar. En vez de eso, `ledger.balance_by_type` descarta la
-- transacción entera cuando **alguna de sus patas** pertenece a una parte de
-- prueba. Se corrige sola al cambiar la bandera, no hay backfill que olvidar,
-- y el asiento sigue estando ahí para quien quiera auditarlo.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La bandera
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column if not exists is_test boolean not null default false;

alter table public.merchants
  add column if not exists is_test boolean not null default false;

alter table public.charges
  add column if not exists is_test boolean not null default false;

alter table public.installments
  add column if not exists is_test boolean not null default false;

comment on column public.profiles.is_test is
  'Cuenta de prueba: no cuenta en ninguna cifra ni en ninguna cola, no recibe promociones, y si aparece en listas es con su etiqueta. Solo la pone y la quita un super admin.';

comment on column public.merchants.is_test is
  'Comercio de prueba. Todo lo que se venda en el queda fuera de las cifras, tambien si quien consume es una persona real.';

comment on column public.charges.is_test is
  'Copia de la bandera de la persona o del local, al insertar. Denormalizada a proposito: las metricas agregan aqui sin tocar profiles ni merchants.';

comment on column public.installments.is_test is
  'Copia de charges.is_test. La mora y la cartera agregan sobre installments sin pasar por charges.';

create index if not exists charges_is_test_idx on public.charges (is_test) where is_test;
create index if not exists installments_is_test_idx on public.installments (is_test) where is_test;

-- ---------------------------------------------------------------------------
-- 2. Los dos predicados
-- ---------------------------------------------------------------------------
-- `stable` para que el planificador no los llame una vez por fila cuando el
-- argumento no cambia.

create or replace function public.helios_is_test_user(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select coalesce((select is_test from public.profiles where id = p_user), false);
$fn$;

create or replace function public.helios_is_test_merchant(p_merchant uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select coalesce((select is_test from public.merchants where id = p_merchant), false);
$fn$;

revoke all on function public.helios_is_test_user(uuid) from public, anon;
revoke all on function public.helios_is_test_merchant(uuid) from public, anon;
grant execute on function public.helios_is_test_user(uuid) to authenticated;
grant execute on function public.helios_is_test_merchant(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. La bandera se copia al nacer
-- ---------------------------------------------------------------------------

create or replace function public.helios_mark_test_charge()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  new.is_test := public.helios_is_test_user(new.user_id)
              or public.helios_is_test_merchant(new.merchant_id);
  return new;
end;
$fn$;

drop trigger if exists charges_mark_test on public.charges;
create trigger charges_mark_test
  before insert on public.charges
  for each row execute function public.helios_mark_test_charge();

create or replace function public.helios_mark_test_installment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  select c.is_test into new.is_test
  from public.charges c where c.id = new.charge_id;
  new.is_test := coalesce(new.is_test, false);
  return new;
end;
$fn$;

drop trigger if exists installments_mark_test on public.installments;
create trigger installments_mark_test
  before insert on public.installments
  for each row execute function public.helios_mark_test_installment();

-- ---------------------------------------------------------------------------
-- 4. Y se recalcula cuando alguien la cambia
-- ---------------------------------------------------------------------------

create or replace function public.helios_resync_test_flags()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  update public.charges c
  set is_test = exists (
        select 1 from public.profiles p where p.id = c.user_id and p.is_test
      ) or exists (
        select 1 from public.merchants m where m.id = c.merchant_id and m.is_test
      )
  where c.is_test is distinct from (
        exists (select 1 from public.profiles p where p.id = c.user_id and p.is_test)
     or exists (select 1 from public.merchants m where m.id = c.merchant_id and m.is_test)
  );

  update public.installments i
  set is_test = c.is_test
  from public.charges c
  where c.id = i.charge_id
    and i.is_test is distinct from c.is_test;
end;
$fn$;

revoke all on function public.helios_resync_test_flags() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. El libro: una transacción con una pata de prueba no suma
-- ---------------------------------------------------------------------------
-- El asiento se queda escrito —una prueba tiene que dejar rastro— pero deja de
-- entrar en Caja, en «por pagar a locales», en la comisión y en lo castigado.

create or replace function ledger.balance_by_type(p_type ledger.account_type)
returns numeric
language sql
stable
set search_path = ledger, public, pg_temp
as $fn$
  select coalesce(sum(e.debit) - sum(e.credit), 0)
  from ledger.entries e
  join ledger.accounts a on a.id = e.account_id
  where a.account_type = p_type
    and not exists (
      select 1
      from ledger.entries e2
      join ledger.accounts a2 on a2.id = e2.account_id
      where e2.transaction_id = e.transaction_id
        and a2.owner_id is not null
        and (
          public.helios_is_test_user(a2.owner_id)
          or public.helios_is_test_merchant(a2.owner_id)
        )
    );
$fn$;

revoke all on function ledger.balance_by_type(ledger.account_type)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Las promociones no llegan a una cuenta de prueba
-- ---------------------------------------------------------------------------

create or replace function public.promo_audience(
  p_audience text,
  p_level    integer default null
)
returns table (user_id uuid)
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select p.id
  from public.profiles p
  where p.status <> 'expelled'
    and not p.is_test
    and case p_audience
      when 'all'    then true
      when 'active' then p.status = 'active'
      when 'level'  then p.level = p_level
      when 'dormant' then
        p.status = 'active'
        and not exists (
          select 1 from public.charges c
          where c.user_id = p.id
            and c.status = 'confirmed'
            and c.confirmed_at > now() - interval '30 days'
        )
      else false
    end;
$fn$;

revoke all on function public.promo_audience(text, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Las cifras y las colas, con el filtro puesto
-- ---------------------------------------------------------------------------
-- Cuerpos idénticos a los de su última migración salvo el filtro. Se copian
-- enteros porque `create or replace` no sabe parchear media función.

create or replace function public.admin_overview(p_days integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today     date := public.helios_business_date(now());
  v_from      date;
  v_prev_from date;
  v_days      integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_volume    numeric(18,4);
  v_prev_vol  numeric(18,4);
  v_count     integer;
  v_users     integer;
  v_result    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from      := v_today - (v_days - 1);
  v_prev_from := v_from - v_days;

  -- Volumen financiado de la ventana y de la ventana anterior, para poder
  -- decir "sube o baja" y no solo un número suelto.
  select coalesce(sum(amount_usd), 0), count(*), count(distinct user_id)
    into v_volume, v_count, v_users
  from public.charges
  where status = 'confirmed' and not is_test
    and business_date between v_from and v_today;

  select coalesce(sum(amount_usd), 0) into v_prev_vol
  from public.charges
  where status = 'confirmed' and not is_test
    and business_date between v_prev_from and v_from - 1;

  v_result := jsonb_build_object(
    'business_date', v_today,
    'window_days', v_days,
    'volume', jsonb_build_object(
      'financed_usd', v_volume,
      'previous_usd', v_prev_vol,
      'charge_count', v_count,
      'active_users', v_users,
      'avg_ticket_usd', case when v_count > 0 then round(v_volume / v_count, 2) else 0 end
    )
  );

  -- Mora. Es *el* número del negocio: docs/00-BASES §1.2 — "con 10% de mora
  -- $8 de pérdida por cada $100 se lleva el 40% de la comisión".
  -- Se mide sobre la exposición viva, no sobre el volumen histórico: lo que
  -- importa es qué porcentaje de lo que está hoy en la calle no va a volver.
  --
  -- 🔁 Y desde el 2026-09-02, **solo lo que todavía se puede cobrar**. El
  -- `written_off_at is null` es lo que cambia. Antes la
  -- deuda castigada seguía contando aquí —`status` sigue en 'pending' aunque se
  -- haya dado por perdida— y este porcentaje no podía bajar nunca: sumaba
  -- cartera muerta a un numerador que se suponía cobrable. Lo perdido tiene su
  -- propia cifra más abajo, y las dos juntas son la cartera vencida entera.
  v_result := v_result || jsonb_build_object('arrears', (
    select jsonb_build_object(
      'open_usd', coalesce(sum(amount_usd), 0),
      'overdue_usd', coalesce(sum(amount_usd) filter (where due_date < v_today), 0),
      'overdue_users', count(distinct user_id) filter (where due_date < v_today),
      'due_today_usd', coalesce(sum(amount_usd) filter (where due_date = v_today), 0),
      'rate_pct', case
        when coalesce(sum(amount_usd), 0) > 0
        then round(100 * coalesce(sum(amount_usd) filter (where due_date < v_today), 0)
                       / sum(amount_usd), 2)
        else 0 end,
      -- Tramos de la escalera de consecuencias (docs/06 §3), leídos de los
      -- PARÁMETROS y no de números escritos aquí: la escalera ya se alargó una
      -- vez (15/30 → 30/60) y estos tramos se quedaron cortando por donde ya no
      -- pasaba nada. Las claves tampoco llevan el número dentro, por lo mismo.
      'demotion_days', public.helios_mora_demotion_days(),
      'expulsion_days', public.helios_mora_expulsion_days(),
      'bucket_frozen_usd', coalesce(sum(amount_usd)
        filter (where due_date < v_today
                  and due_date >= v_today - public.helios_mora_demotion_days()), 0),
      'bucket_demotion_usd', coalesce(sum(amount_usd)
        filter (where due_date < v_today - public.helios_mora_demotion_days()
                  and due_date >= v_today - public.helios_mora_expulsion_days()), 0),
      'bucket_expulsion_usd', coalesce(sum(amount_usd)
        filter (where due_date < v_today - public.helios_mora_expulsion_days()), 0)
    )
    from public.installments
    where status = 'pending' and written_off_at is null and not is_test
  ));

  -- Impago: lo que ya se dio por perdido.
  --
  -- La tasa va sobre TODO lo financiado en la historia y no sobre la ventana:
  -- lo que se castiga hoy nació hace dos o tres meses, así que dividirlo entre
  -- las ventas de los últimos 30 días daría un número que se mueve con el
  -- volumen y no con la calidad del crédito. El desglose comparable —cosecha a
  -- cosecha— lo da `admin_credit_cohorts`; esto es el acumulado del negocio.
  v_result := v_result || jsonb_build_object('bad_debt', (
    select jsonb_build_object(
      'written_off_usd', coalesce(sum(amount_usd) filter (where written_off_at is not null), 0),
      'written_off_users', count(distinct user_id) filter (where written_off_at is not null),
      'financed_usd', coalesce(sum(amount_usd), 0),
      'window_usd', coalesce(sum(amount_usd) filter (
        where written_off_at is not null
          and public.helios_business_date(written_off_at) between v_from and v_today), 0),
      'rate_pct', case
        when coalesce(sum(amount_usd), 0) > 0
        then round(100 * coalesce(sum(amount_usd) filter (where written_off_at is not null), 0)
                       / sum(amount_usd), 2)
        else 0 end,
      -- El umbral en el que el impago se come el negocio entero, calculado y
      -- no escrito a mano: el fee ya subió del 10% al 20% este mismo mes.
      --
      -- Ronda gana el fee y, cuando alguien no paga, pierde el neto que ya le
      -- transfirió al comercio (docs/05 §3). Con una tasa de impago `d`:
      --
      --     gana  fee × (1 − d)      pierde  neto × d
      --     empatan en   d = fee / (fee + neto)
      --
      -- Con base 100 y fee del 20% eso es 20/120 ≈ 16,7%. El IVA no entra por
      -- ninguno de los dos lados: se cobra al usuario y se remite, no es de
      -- Ronda ni cuando se paga ni cuando no. Y como `d` sale de una fracción
      -- uniforme de la cartera, se compara directo con `rate_pct`.
      'break_even_pct', (
        select case
          when coalesce(sum(coalesce(c.merchant_net_usd, c.amount_usd)
                          + coalesce(c.consumer_fee_usd, 0)), 0) > 0
          then round(100 * sum(coalesce(c.consumer_fee_usd, 0))
                         / sum(coalesce(c.merchant_net_usd, c.amount_usd)
                             + coalesce(c.consumer_fee_usd, 0)), 2)
          else null end
        from public.charges c where c.status = 'confirmed' and not c.is_test
      )
    )
    from public.installments
    where not is_test
  ));

  -- Cartera de usuarios por estado. `frozen`/`suspended`/`expelled` son la
  -- salida del motor de mora, así que esta línea es su marcador.
  v_result := v_result || jsonb_build_object('users', (
    select jsonb_build_object(
      'total', count(*),
      'pending_kyc', count(*) filter (where status in ('pending_kyc', 'pending_pin')),
      'active', count(*) filter (where status = 'active'),
      'frozen', count(*) filter (where status = 'frozen'),
      'suspended', count(*) filter (where status = 'suspended'),
      'expelled', count(*) filter (where status = 'expelled'),
      'blacklisted', count(*) filter (where is_blacklisted),
      'new_in_window', count(*) filter (where created_at >= v_from)
    )
    from public.profiles
    where not is_test
  ));

  -- Embudo de KYC. La tasa de aprobación y el tamaño de la cola manual son
  -- las dos cifras que deciden si hace falta más gente revisando
  -- (docs/00-BASES §3.3: el SLA de revisión manual sigue sin definirse).
  v_result := v_result || jsonb_build_object('kyc', (
    select jsonb_build_object(
      'pending_review', count(*) filter (where status = 'manual_review'),
      'processing', count(*) filter (where status = 'processing'),
      'approved', count(*) filter (where status = 'approved'),
      'rejected', count(*) filter (where status = 'rejected'),
      'approval_rate_pct', case
        when count(*) filter (where status in ('approved', 'rejected')) > 0
        then round(100.0 * count(*) filter (where status = 'approved')
                        / count(*) filter (where status in ('approved', 'rejected')), 1)
        else null end,
      'oldest_pending_hours', coalesce(round(extract(epoch from
        (now() - min(created_at) filter (where status = 'manual_review'))) / 3600.0, 1), 0)
    )
    from kyc.verifications v
    where not public.helios_is_test_user(v.user_id)
  ));

  -- Colas de trabajo. Lo que hay pendiente de que una persona lo toque.
  v_result := v_result || jsonb_build_object('queues', jsonb_build_object(
    'payments_to_reconcile', (
      select count(*) from public.payment_reports
      where status in ('reported', 'in_review')
        and not public.helios_is_test_user(user_id)
    ),
    'merchant_payouts_due', (
      select coalesce(sum(amount_usd), 0) from public.settlements
      where status = 'pending' and due_date <= v_today
        and not public.helios_is_test_merchant(merchant_id)
    ),
    'merchant_payouts_pending', (
      select coalesce(sum(amount_usd), 0) from public.settlements
      where status = 'pending'
        and not public.helios_is_test_merchant(merchant_id)
    )
  ));

  -- Comercios.
  v_result := v_result || jsonb_build_object('merchants', (
    select jsonb_build_object(
      'total', count(*),
      'active', count(*) filter (where status = 'active'),
      'paused', count(*) filter (where status = 'paused'),
      'terminated', count(*) filter (where status = 'terminated'),
      'selling_in_window', (
        select count(distinct merchant_id) from public.charges
        where status = 'confirmed' and not is_test
          and business_date between v_from and v_today
      )
    )
    from public.merchants
    where not is_test
  ));

  -- Tasa BCV. docs/05 §1 la exige como alerta: si lleva más de 48 h sin
  -- actualizarse en día hábil, el scraper se rompió y estás cobrando a una
  -- tasa vieja. El aviso vale más aquí que en un log que nadie lee.
  v_result := v_result || jsonb_build_object('fx', (
    select jsonb_build_object(
      'rate', rate,
      'effective_date', effective_date,
      'fetched_at', fetched_at,
      'age_hours', round(extract(epoch from (now() - fetched_at)) / 3600.0, 1),
      'stale', (now() - fetched_at) > interval '48 hours'
    )
    from public.exchange_rates
    order by effective_date desc limit 1
  ));

  v_result := v_result || jsonb_build_object('cash', public.admin_cash_position());

  return v_result;
end;
$$;

revoke all on function public.admin_overview(integer) from public, anon;
grant execute on function public.admin_overview(integer) to authenticated;

create or replace function public.admin_credit_cohorts(p_months integer default 6)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_months integer := greatest(least(coalesce(p_months, 6), 24), 1);
  v_from   date;
  -- Cuántos días tarda una cosecha en tener su número definitivo: lo que tarda
  -- la última cuota en vencer, más la escalera entera.
  v_season integer := 2 * public.helios_installment_interval_days()
                    + public.helios_mora_expulsion_days();
  v_rows   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := (date_trunc('month', v_today::timestamp)
             - ((v_months - 1) * interval '1 month'))::date;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.month desc), '[]'::jsonb)
  into v_rows
  from (
    select
      to_char(date_trunc('month', c.business_date::timestamp), 'YYYY-MM') as month,
      count(distinct c.id)::integer                                       as charge_count,
      count(distinct c.user_id)::integer                                  as user_count,
      sum(i.amount_usd)                                                   as financed_usd,
      sum(i.amount_usd) filter (where i.status = 'paid')                  as paid_usd,
      -- Vencido y todavía cobrable. Es la mora de esa cosecha, hoy.
      sum(i.amount_usd) filter (
        where i.status = 'pending' and i.written_off_at is null
          and i.due_date < v_today)                                       as overdue_usd,
      -- Vivo y sin vencer: ni cobrado ni problema, todavía.
      sum(i.amount_usd) filter (
        where i.status = 'pending' and i.written_off_at is null
          and i.due_date >= v_today)                                      as current_usd,
      sum(i.amount_usd) filter (where i.written_off_at is not null)       as written_off_usd,
      round(100 * sum(i.amount_usd) filter (
        where i.status = 'pending' and i.written_off_at is null
          and i.due_date < v_today) / nullif(sum(i.amount_usd), 0), 2)    as overdue_pct,
      round(100 * sum(i.amount_usd) filter (where i.written_off_at is not null)
                / nullif(sum(i.amount_usd), 0), 2)                        as written_off_pct,
      -- Una cosecha joven da 0% de impago por construcción, no por mérito: su
      -- última cuota todavía no ha tenido tiempo de recorrer la escalera. La
      -- pantalla tiene que poder decirlo en vez de dejar leer un cero limpio.
      (max(c.business_date) + v_season) <= v_today                        as matured
    from public.charges c
    join public.installments i on i.charge_id = c.id
    where c.status = 'confirmed'
      and not c.is_test
      and c.business_date >= v_from
    group by 1
  ) q;

  return jsonb_build_object(
    'business_date',  v_today,
    'months',         v_months,
    'season_days',    v_season,
    'expulsion_days', public.helios_mora_expulsion_days(),
    'rows',           v_rows
  );
end;
$$;

revoke all on function public.admin_credit_cohorts(integer) from public, anon;
grant execute on function public.admin_credit_cohorts(integer) to authenticated;

create or replace function public.admin_merchant_risk(p_days integer default 90)
returns table (
  merchant_id      uuid,
  merchant_name    text,
  status           text,
  charge_count     integer,
  financed_usd     numeric,
  distinct_users   integer,
  repeat_ratio     numeric,
  overdue_usd      numeric,
  arrears_pct      numeric,
  volume_share_pct numeric,
  pending_payout_usd numeric
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today date := public.helios_business_date(now());
  v_from  date;
  v_total numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := v_today - (greatest(least(coalesce(p_days, 90), 365), 1) - 1);

  -- Alias explícito: esta función declara OUT parameters llamados `status` y
  -- `financed_usd`, y sin calificar la columna Postgres no sabe si `status`
  -- es la de la tabla o la variable.
  select coalesce(sum(c0.amount_usd), 0) into v_total
  from public.charges c0
  where c0.status = 'confirmed' and not c0.is_test
    and c0.business_date between v_from and v_today;

  return query
  with per_merchant as (
    select
      ch.merchant_id as mid,
      count(*)::integer as cnt,
      sum(ch.amount_usd) as financed,
      count(distinct ch.user_id)::integer as users
    from public.charges ch
    where ch.status = 'confirmed' and not ch.is_test
      and ch.business_date between v_from and v_today
    group by 1
  ),
  arrears as (
    -- La mora se imputa al comercio que originó el consumo. Es la métrica que
    -- docs/05 §3 llama "de primera línea" y la que dispararía el holdback.
    select
      ch.merchant_id as mid,
      sum(i.amount_usd) filter (where i.status = 'pending' and i.due_date < v_today) as overdue,
      sum(i.amount_usd) as billed
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    where ch.business_date between v_from and v_today
      and not ch.is_test
    group by 1
  ),
  payables as (
    select s.merchant_id as mid, sum(s.amount_usd) as pending
    from public.settlements s
    where s.status = 'pending'
      and not public.helios_is_test_merchant(s.merchant_id)
    group by 1
  )
  select
    m.id,
    m.name,
    m.status::text,
    coalesce(pm.cnt, 0),
    coalesce(pm.financed, 0)::numeric,
    coalesce(pm.users, 0),
    case when coalesce(pm.users, 0) > 0
         then round(pm.cnt::numeric / pm.users, 2) else 0 end,
    coalesce(a.overdue, 0)::numeric,
    case when coalesce(a.billed, 0) > 0
         then round(100 * coalesce(a.overdue, 0) / a.billed, 2) else 0 end,
    case when v_total > 0
         then round(100 * coalesce(pm.financed, 0) / v_total, 2) else 0 end,
    coalesce(p.pending, 0)::numeric
  from public.merchants m
  left join per_merchant pm on pm.mid = m.id
  left join arrears a on a.mid = m.id
  left join payables p on p.mid = m.id
  where not m.is_test
  order by coalesce(pm.financed, 0) desc;
end;
$$;

revoke all on function public.admin_merchant_risk(integer) from public, anon;
grant execute on function public.admin_merchant_risk(integer) to authenticated;

create or replace function public.admin_daily_series(p_days integer default 30)
returns table (
  business_date date,
  financed_usd  numeric,
  charge_count  integer,
  collected_usd numeric,
  settled_usd   numeric
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today date := public.helios_business_date(now());
  v_days  integer := greatest(least(coalesce(p_days, 30), 365), 1);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  with days as (
    select generate_series(v_today - (v_days - 1), v_today, interval '1 day')::date as d
  )
  select
    days.d,
    coalesce(c.financed, 0)::numeric,
    coalesce(c.cnt, 0)::integer,
    coalesce(p.collected, 0)::numeric,
    coalesce(s.settled, 0)::numeric
  from days
  left join (
    select ch.business_date as d, sum(ch.amount_usd) as financed, count(*)::integer as cnt
    from public.charges ch
    where ch.status = 'confirmed' and not ch.is_test
    group by 1
  ) c on c.d = days.d
  left join (
    -- Cobrado de verdad: cuotas conciliadas, por día operativo del cobro.
    select public.helios_business_date(i.paid_at) as d, sum(i.amount_usd) as collected
    from public.installments i
    where i.status = 'paid' and i.paid_at is not null and not i.is_test
    group by 1
  ) p on p.d = days.d
  left join (
    -- Salido de caja hacia comercios.
    select mp.business_date as d, sum(mp.amount_usd) as settled
    from public.merchant_payouts mp
    where not public.helios_is_test_merchant(mp.merchant_id)
    group by 1
  ) s on s.d = days.d
  order by days.d;
end;
$$;

revoke all on function public.admin_daily_series(integer) from public, anon;
grant execute on function public.admin_daily_series(integer) to authenticated;

create or replace function public.admin_merchant_payables()
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.total_pending_usd desc), '[]'::jsonb)
  into v_rows
  from (
    select
      m.id     as merchant_id,
      m.name   as merchant_name,
      m.tax_id,
      o.*
    from public.merchants m
    cross join lateral public.helios_settlement_outlook(m.id) o
    where not m.is_test
      and (o.accrued_usd > 0 or o.upcoming_usd > 0)
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_merchant_payables() from public, anon;
grant execute on function public.admin_merchant_payables() to authenticated;

create or replace function public.admin_collections(p_horizon_days integer default 3)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today     date := public.helios_business_date(now());
  v_horizon   integer := greatest(least(coalesce(p_horizon_days, 3), 30), 0);
  -- NUEVO: los umbrales salen de los parámetros, como en el motor de mora.
  v_demotion  integer := public.helios_mora_demotion_days();
  v_expulsion integer := public.helios_mora_expulsion_days();
  v_rows      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- El orden es el de siempre —el más atrasado arriba, y a igual atraso el que
  -- más debe— escrito sobre `next_due_date` porque es el mismo dato:
  -- `days_late` es `max(hoy - due_date)`, o sea `hoy - min(due_date)`, así que
  -- el vencimiento más antiguo primero ES el mayor atraso primero, y además
  -- ordena entre sí a los que aún no vencen, que `days_overdue` aplana a cero.
  -- Hay que decirlo dentro del `jsonb_agg`: el orden de una subconsulta no se
  -- hereda al agregarla.
  select coalesce(
           jsonb_agg(to_jsonb(q) order by q.next_due_date, q.open_usd desc),
           '[]'::jsonb
         )
    into v_rows
  from (
    with pending as (
      select
        i.user_id as uid,
        i.amount_usd,
        i.due_date,
        m.name as merchant_name
      from public.installments i
      join public.charges ch on ch.id = i.charge_id
      join public.merchants m on m.id = ch.merchant_id
      where i.status = 'pending'
        and not i.is_test
        and i.due_date <= v_today + v_horizon
    ),
    grouped as (
      select
        uid,
        sum(amount_usd) as open_usd,
        sum(amount_usd) filter (where due_date < v_today) as overdue_usd,
        sum(amount_usd) filter (where due_date >= v_today) as upcoming_usd,
        max(v_today - due_date) as days_late,
        min(due_date) as next_due,
        count(*)::integer as cnt,
        array_agg(distinct merchant_name) as merchant_names
      from pending
      group by 1
    )
    select
      g.uid as user_id,
      p.full_name,
      p.phone_e164,
      p.status::text as status,
      p.level,
      -- ── NUEVO: los umbrales, y los operadores del motor ──────────────────
      -- `>= v_demotion` y `> v_expulsion` son los de
      -- `recompute_profile_mora_state` y los de docs/00-BASES §2.4. Aquí ponía
      -- `> 30` / `> 15`: ni los días eran esos, ni el corte era ese.
      --
      -- El tramo es la consecuencia NUEVA, y se suma a las anteriores: quien
      -- cae en 'baja_nivel' sigue con el saldo cerrado, ahora como bloqueado.
      case
        when g.days_late > v_expulsion then 'expulsion'
        when g.days_late >= v_demotion then 'baja_nivel'
        when g.days_late >= 1 then 'congelado'
        when g.days_late = 0  then 'vence_hoy'
        else 'por_vencer'
      end as bucket,
      -- ─────────────────────────────────────────────────────────────────────
      g.open_usd::numeric as open_usd,
      coalesce(g.overdue_usd, 0)::numeric as overdue_usd,
      coalesce(g.upcoming_usd, 0)::numeric as upcoming_usd,
      greatest(g.days_late, 0)::integer as days_overdue,
      g.next_due as next_due_date,
      g.cnt as installment_count,
      g.merchant_names as merchants,
      (
        select max(pr.created_at) from public.payment_reports pr
        where pr.user_id = g.uid and pr.status = 'reconciled'
      ) as last_payment_at
    from grouped g
    join public.profiles p on p.id = g.uid
  ) q;

  -- NUEVO: los umbrales viajan con la cola, no dentro del panel. Van fuera de
  -- las filas para que una cola vacía siga sabiendo etiquetar sus tramos.
  return jsonb_build_object(
    'demotion_days', v_demotion,
    'expulsion_days', v_expulsion,
    'rows', v_rows
  );
end;
$$;

revoke all on function public.admin_collections(integer) from public, anon;
grant execute on function public.admin_collections(integer) to authenticated;

create or replace function public.admin_kyc_queue()
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, storage, pg_temp
stable
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at), '[]'::jsonb)
    into v_rows
  from (
    select
      v.id,
      v.user_id,
      p.phone_e164,
      v.extracted_name,
      v.extracted_document,
      v.extracted_birth,

      -- NUEVO: lo que el revisor no podía ver. Va de la mano con el motivo,
      -- porque la marca sola no dice si fue por mora de una cuota o por algo
      -- peor.
      p.is_blacklisted,
      p.blacklist_reason,

      -- Los puntajes se redondean a un semáforo. El revisor necesita saber si
      -- la señal es buena o dudosa, no el número exacto.
      --
      -- Los cortes son los mismos de siempre (0,75 y 0,55) leídos en la escala
      -- de cada proveedor. Didit los manda de 0 a 100 y se guardan tal cual,
      -- sin convertir: reescalarlos invitaría a compararlos con los umbrales
      -- del motor propio, que estaban calibrados contra OTRO modelo y no
      -- significan lo mismo aquí.
      case
        when coalesce(v.face_match_score * 100, d.face_match_score) is null then 'sin_dato'
        when coalesce(v.face_match_score * 100, d.face_match_score) >= 75 then 'alta'
        when coalesce(v.face_match_score * 100, d.face_match_score) >= 55 then 'media'
        else 'baja'
      end as face_match,
      case
        when coalesce(v.liveness_score * 100, d.liveness_score) is null then 'sin_dato'
        when coalesce(v.liveness_score * 100, d.liveness_score) >= 75 then 'alta'
        when coalesce(v.liveness_score * 100, d.liveness_score) >= 55 then 'media'
        else 'baja'
      end as liveness,

      v.registry_matched,
      v.rejection_detail,
      v.document_path,
      v.selfie_path,

      -- De dónde salió el veredicto. El panel lo usa para no enseñar dos
      -- marcos de foto vacíos en un expediente que nunca tuvo fotos.
      case when d.verification_id is not null then 'didit' else 'propio' end as provider,

      -- Lo único que explica una duda con palabras. Didit los manda como lista
      -- y se pasan enteros: el `rejection_detail` solo se queda con los tres
      -- primeros, y el cuarto puede ser justo el que importa.
      coalesce(d.warnings, '[]'::jsonb) as warnings,
      d.document_type,
      d.issuing_state,
      d.liveness_method,

      v.created_at,
      extract(epoch from (now() - v.created_at))::bigint as waiting_seconds
    from kyc.verifications v
    join public.profiles p on p.id = v.user_id

    -- El último veredicto de Didit para este expediente.
    --
    -- Se reconoce por `warnings`: es la única clave que añade el webhook de la
    -- decisión. El renglón que escribe `attach_didit_session` al abrir la
    -- sesión también lleva `provider: didit`, pero no trae señal ninguna, así
    -- que filtrar por el proveedor traería el renglón vacío la mitad de las
    -- veces.
    left join lateral (
      select
        l.verification_id,
        (l.signals ->> 'face_match_score')::numeric as face_match_score,
        (l.signals ->> 'liveness_score')::numeric   as liveness_score,
        l.signals ->> 'liveness_method'             as liveness_method,
        l.signals ->> 'document_type'               as document_type,
        l.signals ->> 'issuing_state'               as issuing_state,
        l.signals -> 'warnings'                     as warnings
      from kyc.decision_log l
      where l.verification_id = v.id
        and l.signals ? 'warnings'
      order by l.created_at desc
      limit 1
    ) d on true

    where v.status = 'manual_review'
      and not p.is_test
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_kyc_queue() from public, anon;
grant execute on function public.admin_kyc_queue() to authenticated;

create or replace function public.admin_payment_queue(
  p_statuses text[] default array['reported', 'in_review']
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(item order by created_at), '[]'::jsonb)
    into v_result
  from (
    select
      r.created_at,
      jsonb_build_object(
        'report_id',      r.id,
        'status',         r.status::text,
        'created_at',     r.created_at,
        'method',         r.method,
        'bank',           r.bank,
        'reference',      r.reference,
        'payer_document', r.payer_document,
        'payer_phone',    r.payer_phone,
        'rejection_note', r.rejection_note,

        -- El dinero. `installments_usd` es lo que suman las cuotas; el resto
        -- del importe son cargos por mora, y el operador tiene que poder
        -- cuadrar las dos cifras sin restar de cabeza.
        'amount_usd',        q.amount_usd,
        'amount_ves',        q.amount_ves,
        'fx_rate',           q.fx_rate,
        'installment_count', q.installment_count,
        'installments_usd',  q.amount_usd - q.late_fee_usd,
        'late_fee_usd',      q.late_fee_usd,

        'user', jsonb_build_object(
          'user_id',         p.id,
          'full_name',       p.full_name,
          'phone_e164',      p.phone_e164,
          'document_number', p.document_number,
          'status',          p.status::text,
          'level',           p.level
        ),

        -- Cuántos OTROS reportes no rechazados comparten banco + referencia.
        -- Con referencias de 6 dígitos esto es sospecha, no prueba (docs/00
        -- §3.7).
        'reference_collisions', (
          select count(*) - 1 from public.payment_reports r2
          where r2.bank = r.bank and r2.reference = r.reference
            and r2.reference is not null and r2.status <> 'rejected'
        ),
        -- Movimientos del estado de cuenta importado que encajan: referencia,
        -- monto y fecha, las tres a la vez.
        'statement_matches', (
          select count(*) from public.bank_statement_lines l
          where r.reference is not null
            and l.reference like '%' || r.reference
            and abs(l.amount_ves - q.amount_ves) <= 1.00
            and l.moved_on between (r.created_at::date - 5) and (r.created_at::date + 5)
        ),

        -- Las compras que toca este pago, cada una con las cuotas que salda.
        'purchases', coalesce((
          select jsonb_agg(purchase order by business_date nulls last, order_number nulls last)
          from (
            select
              ch.business_date,
              ch.order_number,
              jsonb_build_object(
                'charge_id',         ch.id,
                'order_number',      ch.order_number,
                'merchant_id',       m.id,
                'merchant_name',     m.name,
                'branch_name',       b.name,
                'charge_amount_usd', ch.amount_usd,
                'charge_status',     ch.status::text,
                'business_date',     ch.business_date,
                'confirmed_at',      ch.confirmed_at,
                -- Un consumo de grupo son N cargos hermanos. Sin decirlo, tres
                -- cuotas de $8,33 del mismo sitio parecen un error de dedo.
                'is_group',          ch.group_id is not null,
                'group_name',        ch.group_name,
                -- El denominador del "cuota 2 de 2". Se cuenta sobre las de
                -- ESTE usuario: en un consumo de grupo el cargo tiene cuotas
                -- de varios.
                'installments_total', (
                  select count(*) from public.installments t
                  where t.charge_id = ch.id and t.user_id = r.user_id
                ),
                'installments', jsonb_agg(jsonb_build_object(
                  'installment_id', ins.id,
                  'sequence',       ins.sequence,
                  -- El congelado al cotizar. Es la cifra contra la que concilia
                  -- el servidor; si difiere del de la cuota, el pago no se
                  -- concilia y aquí se ve por qué.
                  'quoted_usd',     qi.amount_usd,
                  'amount_usd',     ins.amount_usd,
                  'due_date',       ins.due_date,
                  'status',         ins.status::text,
                  'days_overdue',   greatest(v_today - ins.due_date, 0),
                  -- Intentos anteriores sobre esta misma cuota: un rechazo y un
                  -- segundo reporte es normal, pero el operador tiene que
                  -- saberlo antes de aprobar.
                  'other_reports', (
                    select count(*)
                    from public.payment_quote_items qi2
                    join public.payment_reports r2 on r2.quote_id = qi2.quote_id
                    where qi2.installment_id = ins.id and r2.id <> r.id
                  )
                ) order by ins.sequence)
              ) as purchase
            from public.payment_quote_items qi
            join public.installments ins on ins.id = qi.installment_id
            join public.charges ch on ch.id = ins.charge_id
            join public.merchants m on m.id = ch.merchant_id
            join public.merchant_branches b on b.id = ch.branch_id
            where qi.quote_id = q.id
            group by ch.id, m.id, b.id
          ) g
        ), '[]'::jsonb),

        -- Los cargos por mora, con la cuota que los disparó. Sin esto el
        -- importe no cuadra con ninguna suma de cuotas y un pago correcto se
        -- marca como sospechoso.
        'late_fees', coalesce((
          select jsonb_agg(jsonb_build_object(
            'late_fee_id',    f.id,
            'amount_usd',     fl.amount_usd,
            'days_late',      f.days_late,
            'business_date',  f.business_date,
            'installment_id', f.installment_id,
            'sequence',       ins.sequence,
            'order_number',   ch.order_number,
            'merchant_name',  m.name,
            -- Un cargo HUÉRFANO es el de una cuota que ya se pagó (o el del
            -- modelo por episodio, sin cuota). Viaja con este pago aunque su
            -- cuota no esté aquí — y esa es justo la pregunta que se hace el
            -- operador al ver un cargo suelto.
            'orphan', f.installment_id is null or not exists (
              select 1 from public.payment_quote_items qi3
              where qi3.quote_id = q.id and qi3.installment_id = f.installment_id
            )
          ) order by f.business_date, f.created_at)
          from public.payment_quote_late_fees fl
          join public.late_fees f on f.id = fl.late_fee_id
          left join public.installments ins on ins.id = f.installment_id
          left join public.charges ch on ch.id = ins.charge_id
          left join public.merchants m on m.id = ch.merchant_id
          where fl.quote_id = q.id
        ), '[]'::jsonb)
      ) as item
    from public.payment_reports r
    join public.payment_quotes q on q.id = r.quote_id
    join public.profiles p on p.id = r.user_id
    where r.status::text = any(p_statuses)
      and not p.is_test
  ) s;

  return v_result;
end;
$$;

revoke all on function public.admin_payment_queue(text[]) from public, anon;
grant execute on function public.admin_payment_queue(text[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Las dos listas dicen si la fila es de prueba
-- ---------------------------------------------------------------------------
-- Aquí NO se filtra: una cuenta de prueba tiene que poder buscarse y abrirse.
-- Lo que cambia es que la pantalla ya puede ponerle su etiqueta.

drop function if exists public.admin_user_directory(text, text, integer);

create or replace function public.admin_user_directory(
  p_search text default null,
  p_status text default null,
  p_limit  integer default 50
)
returns table (
  user_id        uuid,
  full_name      text,
  phone_e164     text,
  document_number text,
  status         text,
  level          smallint,
  level_limit_usd numeric,
  is_blacklisted boolean,
  is_test        boolean,
  created_at     timestamptz,
  open_debt_usd  numeric,
  overdue_usd    numeric,
  days_overdue   integer,
  charge_count   integer,
  last_charge_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_needle text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_needle := nullif(trim(coalesce(p_search, '')), '');

  return query
  select
    p.id,
    p.full_name,
    p.phone_e164,
    p.document_number,
    p.status::text,
    p.level,
    l.monthly_limit_usd,
    p.is_blacklisted,
    p.is_test,
    p.created_at,
    coalesce(d.open_debt, 0)::numeric,
    coalesce(d.overdue, 0)::numeric,
    coalesce(d.days_late, 0)::integer,
    coalesce(c.cnt, 0)::integer,
    c.last_at
  from public.profiles p
  join public.levels l on l.level = p.level
  left join (
    select
      i.user_id as uid,
      sum(i.amount_usd) as open_debt,
      sum(i.amount_usd) filter (where i.due_date < v_today) as overdue,
      max(v_today - i.due_date) filter (where i.due_date < v_today) as days_late
    from public.installments i
    where i.status = 'pending'
    group by 1
  ) d on d.uid = p.id
  left join (
    select ch.user_id as uid, count(*)::integer as cnt, max(ch.confirmed_at) as last_at
    from public.charges ch
    where ch.status = 'confirmed'
    group by 1
  ) c on c.uid = p.id
  where
    (p_status is null or p.status::text = p_status)
    and (
      v_needle is null
      or p.phone_e164 ilike '%' || v_needle || '%'
      or p.full_name ilike '%' || v_needle || '%'
      or p.document_number ilike '%' || v_needle || '%'
    )
  -- Primero quien más atrasado está: esta lista se abre para cobrar, no para
  -- navegar el padrón.
  order by coalesce(d.days_late, 0) desc, coalesce(d.open_debt, 0) desc, p.created_at desc
  limit least(coalesce(p_limit, 50), 200);
end;
$$;

revoke all on function public.admin_user_directory(text, text, integer) from public, anon;
grant execute on function public.admin_user_directory(text, text, integer) to authenticated;

drop function if exists public.admin_charges(text, uuid, text, date, date, integer);

create or replace function public.admin_charges(
  p_search      text default null,
  p_merchant_id uuid default null,
  p_status      text default null,
  p_from        date default null,
  p_to          date default null,
  p_limit       integer default 100
)
returns table (
  charge_id      uuid,
  amount_usd     numeric,
  status         text,
  business_date  date,
  created_at     timestamptz,
  confirmed_at   timestamptz,
  void_reason    text,
  user_id        uuid,
  full_name      text,
  phone_e164     text,
  user_status    text,
  merchant_id    uuid,
  merchant_name  text,
  branch_name    text,
  is_group       boolean,
  is_test        boolean,
  installments_paid integer,
  installments_total integer
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_needle text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_needle := nullif(trim(coalesce(p_search, '')), '');

  return query
  select
    ch.id,
    ch.amount_usd,
    ch.status::text,
    ch.business_date,
    ch.created_at,
    ch.confirmed_at,
    ch.void_reason,
    ch.user_id,
    p.full_name,
    p.phone_e164,
    p.status::text,
    m.id,
    m.name,
    b.name,
    -- Un consumo de grupo genera N cargos hermanos con el mismo grupo detrás.
    -- Marcarlo evita que alguien lea ocho filas de $12,50 como ocho consumos
    -- sueltos de una noche rara.
    ch.group_id is not null,
    ch.is_test,
    coalesce(i.paid, 0)::integer,
    coalesce(i.total, 0)::integer
  from public.charges ch
  left join public.profiles p on p.id = ch.user_id
  join public.merchants m on m.id = ch.merchant_id
  join public.merchant_branches b on b.id = ch.branch_id
  left join (
    -- `ins.` explícito: el OUT parameter de esta función también se llama
    -- `charge_id` y sin calificar la columna Postgres no sabe a cuál se
    -- refiere.
    select ins.charge_id as cid,
           count(*) filter (where ins.status = 'paid')::integer as paid,
           count(*)::integer as total
    from public.installments ins group by 1
  ) i on i.cid = ch.id
  where
    (p_merchant_id is null or ch.merchant_id = p_merchant_id)
    and (p_status is null or ch.status::text = p_status)
    and (p_from is null or ch.business_date >= p_from)
    and (p_to is null or ch.business_date <= p_to)
    and (
      v_needle is null
      or p.phone_e164 ilike '%' || v_needle || '%'
      or p.full_name ilike '%' || v_needle || '%'
      or p.document_number ilike '%' || v_needle || '%'
      or m.name ilike '%' || v_needle || '%'
    )
  order by ch.created_at desc
  limit least(coalesce(p_limit, 100), 500);
end;
$$;

revoke all on function public.admin_charges(text, uuid, text, date, date, integer) from public, anon;
grant execute on function public.admin_charges(text, uuid, text, date, date, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Marcar y desmarcar
-- ---------------------------------------------------------------------------

create or replace function public.admin_set_test_account(
  p_kind text,
  p_id   uuid,
  p_flag boolean,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor  uuid := auth.uid();
  v_before boolean;
  v_name   text;
begin
  -- Marcar una cuenta como de prueba la saca de todas las cifras: es una
  -- palanca del super admin, no del operador.
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede marcar cuentas de prueba'
      using errcode = '42501';
  end if;

  if p_kind = 'user' then
    select is_test, full_name into v_before, v_name
    from public.profiles where id = p_id for update;

    if not found then
      raise exception 'No existe esa persona' using errcode = '22023';
    end if;

    update public.profiles set is_test = p_flag, updated_at = now() where id = p_id;

  elsif p_kind = 'merchant' then
    select is_test, name into v_before, v_name
    from public.merchants where id = p_id for update;

    if not found then
      raise exception 'No existe ese comercio' using errcode = '22023';
    end if;

    update public.merchants set is_test = p_flag, updated_at = now() where id = p_id;

  else
    raise exception 'Tipo de cuenta desconocido: %', p_kind using errcode = '22023';
  end if;

  -- Lo ya vendido cambia de lado con la bandera: si no, marcar hoy dejaría
  -- todos los consumos de ayer contando como reales para siempre.
  perform public.helios_resync_test_flags();

  perform audit.log(v_actor, 'account.set_test', p_id, jsonb_build_object(
    'kind', p_kind,
    'name', v_name,
    'from_is_test', v_before,
    'to_is_test', p_flag,
    'note', p_note
  ));
end;
$fn$;

comment on function public.admin_set_test_account(text, uuid, boolean, text) is
  'Marca o desmarca una persona o un comercio como cuenta de prueba, y recalcula las banderas de sus consumos y cuotas. Solo super admin.';

revoke all on function public.admin_set_test_account(text, uuid, boolean, text) from public, anon;
grant execute on function public.admin_set_test_account(text, uuid, boolean, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Marcar lo que ya estaba mezclado, y el comercio DEMO
-- ---------------------------------------------------------------------------
-- Los RIF de relleno y los nombres de demo con los que se probó el piloto.
-- Se marcan por patrón y no por id porque los ids son distintos en dev y en
-- producción.

update public.merchants
set is_test = true
where not is_test
  and (
    upper(coalesce(name, '')) like '%DEMO%'
    or upper(coalesce(name, '')) like '%PRUEBA%'
    or upper(coalesce(name, '')) like '%TEST%'
    or regexp_replace(coalesce(tax_id, ''), '[^0-9]', '', 'g') in ('12345677', '12345678')
  );

-- El comercio DEMO, si no existe ya uno. Nace activo y de prueba: se puede
-- facturar en el, mirar el panel del local y ver el QR sin que nada de eso
-- toque la contabilidad.
do $do$
declare
  v_id uuid;
begin
  if not exists (select 1 from public.merchants where tax_id = 'J-000000001') then
    insert into public.merchants (name, legal_name, tax_id, status, is_test, category, city, handle)
    values ('HELIOS DEMO', 'Helios Demo C.A.', 'J-000000001', 'active', true, 'otros', 'Caracas', 'HeliosDemo')
    returning id into v_id;

    -- `bootstrap_merchant()` (trigger `on_merchant_created`) ya insertó la
    -- sucursal por defecto ("Principal") al crear el comercio de arriba:
    -- aquí solo se renombra, no se inserta una segunda.
    update public.merchant_branches
    set name = 'HELIOS DEMO', is_active = true
    where merchant_id = v_id and is_default;

    -- Las condiciones de hoy: nada de adelanto y la mitad en cada cuota.
    insert into public.merchant_settlement_terms
      (merchant_id, upfront_pct, per_installment_pct, commission_pct, policy)
    values (v_id, 0, 50, 0, 'scheduled')
    on conflict (merchant_id) do nothing;
  end if;
end
$do$;

-- Y las personas con las que se probó: sin nombre, sin cédula y sin haber
-- pasado nunca por una verificación aprobada.
update public.profiles
set is_test = true
where not is_test
  and full_name is null
  and document_number is null
  and status in ('pending_kyc', 'pending_pin')
  and not exists (
    select 1 from public.charges c where c.user_id = profiles.id and c.status = 'confirmed'
  );

-- Con las banderas puestas, lo ya vendido se recoloca.
select public.helios_resync_test_flags();

-- ---------------------------------------------------------------------------
-- 11. La ficha dice si la cuenta es de prueba
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260908160000 salvo la clave nueva. Sin ella, la
-- ficha sería el único sitio del panel donde no se ve, que es justo donde se
-- pone y se quita la bandera.

create or replace function public.admin_user_detail(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_result jsonb;
  v_block  public.user_credit_blocks%rowtype;
  v_limit  numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'user_id', p.id,
    'full_name', p.full_name,
    'phone_e164', p.phone_e164,
    'document_number', p.document_number,
    'birth_date', p.birth_date,
    'status', p.status,
    'level', p.level,
    'is_blacklisted', p.is_blacklisted,
    'blacklist_reason', p.blacklist_reason,
    'is_test', p.is_test,
    'created_at', p.created_at
  ), l.monthly_limit_usd
  into v_result, v_limit
  from public.profiles p
  join public.levels l on l.level = p.level
  where p.id = p_user_id;

  if v_result is null then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  -- El bloque de crédito abierto explica el disponible. Es la pregunta #1 de
  -- soporte: "pagué una cuota, ¿por qué sigo en cero?" (docs/00-BASES §2.2).
  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user_id and closed_at is null;

  v_result := v_result || jsonb_build_object('credit', jsonb_build_object(
    'level_limit_usd', v_limit,
    'block_charged_usd', coalesce(v_block.charged_usd, 0),
    'block_paid_usd', coalesce(v_block.paid_usd, 0),
    'available_usd', greatest(v_limit - (coalesce(v_block.charged_usd, 0)
                                       - coalesce(v_block.paid_usd, 0)), 0),
    'to_unlock_usd', coalesce(v_block.charged_usd, 0) - coalesce(v_block.paid_usd, 0),
    'block_opened_at', v_block.opened_at
  ));

  v_result := v_result || jsonb_build_object('debt', (
    select jsonb_build_object(
      'open_usd', coalesce(sum(amount_usd) filter (where status = 'pending'), 0),
      'overdue_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and due_date < v_today), 0),
      'paid_usd', coalesce(sum(amount_usd) filter (where status = 'paid'), 0),
      'days_overdue', coalesce(max(v_today - due_date)
        filter (where status = 'pending' and due_date < v_today), 0)
    )
    from public.installments where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'charge_id', i.charge_id,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      'due_date', i.due_date,
      'status', i.status,
      'paid_at', i.paid_at,
      'merchant_name', m.name,
      'days_overdue', greatest(v_today - i.due_date, 0)
    ) order by i.due_date, i.sequence)
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    join public.merchants m on m.id = ch.merchant_id
    where i.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('charges', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ch.id,
      'amount_usd', ch.amount_usd,
      'status', ch.status,
      'business_date', ch.business_date,
      'confirmed_at', ch.confirmed_at,
      'merchant_name', m.name,
      'branch_name', b.name,
      'void_reason', ch.void_reason
    ) order by ch.created_at desc)
    from public.charges ch
    join public.merchants m on m.id = ch.merchant_id
    join public.merchant_branches b on b.id = ch.branch_id
    where ch.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('payments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'status', pr.status,
      'bank', pr.bank,
      'reference', pr.reference,
      'method', pr.method,
      'amount_usd', q.amount_usd,
      'amount_ves', q.amount_ves,
      'rejection_note', pr.rejection_note,
      'created_at', pr.created_at
    ) order by pr.created_at desc)
    from public.payment_reports pr
    join public.payment_quotes q on q.id = pr.quote_id
    where pr.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('level_changes', coalesce((
    select jsonb_agg(jsonb_build_object(
      'from_level', lc.from_level,
      'to_level', lc.to_level,
      'reason', lc.reason,
      'note', lc.note,
      'actor', lc.actor,
      'created_at', lc.created_at
    ) order by lc.created_at desc)
    from public.level_changes lc
    where lc.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('kyc', (
    select jsonb_build_object(
      'status', v.status,
      'rejection_reason', v.rejection_reason,
      'rejection_detail', v.rejection_detail,
      'reviewed_at', v.reviewed_at,
      'created_at', v.created_at
    )
    from kyc.verifications v
    where v.user_id = p_user_id
    order by v.created_at desc limit 1
  ));

  -- Bits. El saldo va con SUS MOVIMIENTOS y no solo con la cifra: la pregunta
  -- que llega a soporte no es cuántos tiene, es de dónde salieron.
  v_result := v_result || jsonb_build_object('bits', (
    select jsonb_build_object(
      'balance', coalesce(sum(amount), 0),
      'awarded_count', count(*) filter (where amount > 0),
      'last_award_at', max(created_at) filter (where amount > 0)
    )
    from public.bits_entries where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('bits_entries', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', e.id,
      'amount', e.amount,
      'reason', e.reason,
      'created_at', e.created_at,
      -- De qué cuota salió. `business_date` es el día de la COMPRA, que con la
      -- escalera es la mitad de la explicación: los Bits son la distancia
      -- entre esa fecha y el día en que se pagó.
      'business_date', ch.business_date,
      'due_date', i.due_date,
      'paid_at', i.paid_at,
      'merchant_name', m.name
    ) order by e.created_at desc)
    from public.bits_entries e
    left join public.installments i on i.id = e.installment_id
    left join public.charges ch on ch.id = i.charge_id
    left join public.merchants m on m.id = ch.merchant_id
    where e.user_id = p_user_id
  ), '[]'::jsonb));

  return v_result;
end;
$$;

revoke all on function public.admin_user_detail(uuid) from public, anon;
grant execute on function public.admin_user_detail(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 12. La lista de comercios dice cuál es de prueba
-- ---------------------------------------------------------------------------
-- La vista se recrea entera porque `create or replace view` no sabe añadir una
-- columna en medio; el resto es idéntico a 20260825170000. Los consumos que
-- cuenta `sales_count` siguen siendo todos: es la actividad del local, no una
-- cifra de negocio, y en un comercio de prueba es justo lo que se quiere ver.

drop view if exists public.merchant_directory;

create view public.merchant_directory
with (security_invoker = true)
as
select
  m.id,
  m.name,
  m.legal_name,
  m.tax_id,
  m.status,
  m.created_at,
  (select count(*) from public.merchant_users mu
     where mu.merchant_id = m.id and mu.is_active) as staff_count,
  (select count(*) from public.charges c
     where c.merchant_id = m.id and c.status = 'confirmed') as sales_count,
  m.category,
  m.city,
  m.handle,
  m.logo_url,
  m.social_url,
  m.is_test
from public.merchants m;

grant select on public.merchant_directory to authenticated;
