-- ============================================================================
-- Métricas › Caja: los movimientos de la semana, la proyección y el local
-- ============================================================================
--
-- La pestaña Caja de Métricas reúne Dinero (Balance, Proyección y banco), el
-- capital comprometido del Resumen y lo que se movió en la semana global:
-- lo que entró de cuotas (con su desglose), lo que salió a los locales y el
-- servicio de Ronda ganado frente al cobrado.
--
-- Dos definiciones nuevas en `metricas`, para que la semana, la pestaña
-- General y esta digan lo mismo:
--
-- - `metricas.caja_al(p_dia)`: el dinero en caja según el libro al cierre de
--   un día operativo. Con `p_dia` = hoy es `ledger.balance_by_type('cash')`,
--   el «Dinero en caja» del Balance.
-- - `metricas.caja_movimientos(p_desde, p_hasta, p_merchant_id)`: lo que se
--   movió entre dos días operativos: lo cobrado de cuotas (payable, con su
--   consumo y su servicio e IVA), la parte de servicio sin IVA que había
--   dentro, los cargos por atraso cobrados, lo transferido a los locales, el
--   consumo y el servicio ganado de los consumos de esos días, y lo que dice
--   el libro de caja (solo sin local).
-- - `metricas.caja_proyeccion(...)`: lo que vence y lo que sale a los locales
--   por semana, de todos o de uno. Sin local es exactamente lo que calcula
--   `helios_cash_forecast` (la batería de coherencia lo comprueba), con el
--   desglose de lo que vence.
--
-- Cuándo cuenta cada cosa:
-- - Una cuota cobrada, el día en que se APROBÓ su pago (`pagada_dia`), que es
--   el día en que el libro apunta el cobro.
-- - Un cargo por atraso cobrado, el de su pago (`pagado_dia`).
-- - Una transferencia a un local, su día operativo (`merchant_payouts.business_date`),
--   el mismo del asiento.
-- - El servicio ganado, el día del consumo; el cobrado, el del pago de la
--   cuota que lo lleva dentro (su parte proporcional del servicio sin IVA).
--
-- Y `p_merchant_id uuid default null` (CONTRATOS §6) en `admin_cash_position`,
-- `admin_cash_forecast` y `admin_merchant_payables`. Sin él contestan lo mismo
-- que antes (más claves nuevas con el desglose del fee). Con él, lo del local
-- se parte (lo que deben por sus consumos, lo que se le debe y se le
-- transfirió) y la caja no, que es de todo Ronda: esas claves valen null.
--
-- Un arreglo de paso: `admin_cash_position.written_off` salía NEGATIVO en
-- cuanto había un castigo, porque cambiaba el signo de una cuenta de saldo
-- deudor (`charge_off_user_debt` carga la provisión al debe). Ahora es el
-- saldo de la provisión tal cual. En producción todavía no hay castigos, así
-- que no ha llegado a verse; en dev (con la semilla) salía −€92,90.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El libro de caja y la caja al cierre de un día
-- ---------------------------------------------------------------------------
-- Los asientos de caja que cuentan: los mismos que suma
-- `ledger.balance_by_type('cash')`, sin las transacciones que tocan una cuenta
-- de una persona o un local de prueba. Las transacciones de prueba se juntan
-- una sola vez y se descartan de golpe: la forma de `balance_by_type` (un
-- `not exists` con dos funciones por fila) tarda lo mismo en cada llamada, y
-- la semana de Caja la necesita nueve veces.

create or replace view metricas.libro_de_caja as
with prueba as (
  select distinct e.transaction_id
  from ledger.entries e
  join ledger.accounts a on a.id = e.account_id
  where a.owner_id in (
    select p.id from public.profiles p where p.is_test
    union all
    select m.id from public.merchants m where m.is_test
  )
)
select
  t.id              as transaction_id,
  t.business_date   as business_date,
  t.type::text      as tipo,
  e.debit           as debit,
  e.credit          as credit
from ledger.entries e
join ledger.accounts a on a.id = e.account_id and a.account_type = 'cash'
join ledger.transactions t on t.id = e.transaction_id
where t.id not in (select transaction_id from prueba);

comment on view metricas.libro_de_caja is
  'Una fila por asiento de caja que cuenta: los de ledger.balance_by_type(''cash''), sin las transacciones que tocan una cuenta de prueba. tipo = installment_payment (cobro de cuotas y cargos), merchant_settlement (transferencia a un local) u otro.';

create or replace function metricas.caja_al(p_dia date)
returns numeric
language sql
stable
as $$
  select coalesce(sum(l.debit) - sum(l.credit), 0)
  from metricas.libro_de_caja l
  where l.business_date <= p_dia;
$$;

comment on function metricas.caja_al(date) is
  'Dinero en caja según el libro al cierre del día operativo p_dia (asientos con business_date <= p_dia, sin los que tocan cuentas de prueba). Con p_dia = hoy es ledger.balance_by_type(''cash''): el «Dinero en caja» del Balance. No es de ningún local.';

-- ---------------------------------------------------------------------------
-- 2. Lo que se movió entre dos días
-- ---------------------------------------------------------------------------

create or replace function metricas.caja_movimientos(
  p_desde       date,
  p_hasta       date,
  p_merchant_id uuid default null
)
returns table (
  cuotas_cobradas        integer,
  personas_que_pagaron   integer,
  cobrado_payable_usd    numeric,
  cobrado_financed_usd   numeric,
  cobrado_fee_usd        numeric,
  cobrado_servicio_usd   numeric,
  cargos_cobrados        integer,
  cargos_cobrados_usd    numeric,
  transferencias         integer,
  transferido_usd        numeric,
  consumos               integer,
  consumo_usd            numeric,
  servicio_ganado_usd    numeric,
  cargos_devengados_usd  numeric,
  libro_cobrado_usd      numeric,
  libro_transferido_usd  numeric,
  libro_otros_usd        numeric
)
language sql
stable
as $$
  with
  -- Las cuotas cuyo pago se aprobó en esos días, con la parte de servicio
  -- SIN IVA que llevaban dentro: la de su consumo, en proporción a su fee.
  cobradas as (
    select q.user_id, q.payable_usd, q.financed_usd, q.fee_usd,
           q.fee_usd * coalesce(k.servicio_usd / nullif(k.fee_usd, 0), 0) as servicio
    from metricas.cuotas q
    join metricas.consumos k on k.charge_id = q.charge_id
    where q.status = 'paid'
      and q.pagada_dia between p_desde and p_hasta
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ),
  cargos as (
    select c.amount_usd, c.status, c.business_date, c.pagado_dia
    from metricas.cargos_por_atraso c
    where p_merchant_id is null or c.merchant_id = p_merchant_id
  ),
  pagos as (
    select mp.amount_usd
    from public.merchant_payouts mp
    join public.merchants m on m.id = mp.merchant_id
    where not m.is_test
      and mp.business_date between p_desde and p_hasta
      and (p_merchant_id is null or mp.merchant_id = p_merchant_id)
  ),
  ventas as (
    select k.financed_usd, k.servicio_usd
    from metricas.consumos k
    where k.business_date between p_desde and p_hasta
      and (p_merchant_id is null or k.merchant_id = p_merchant_id)
  ),
  -- El libro de caja no sabe de locales: solo sin local.
  libro as (
    select l.tipo, l.debit, l.credit
    from metricas.libro_de_caja l
    where p_merchant_id is null
      and l.business_date between p_desde and p_hasta
  )
  select
    (select count(*) from cobradas)::integer,
    (select count(distinct user_id) from cobradas)::integer,
    (select coalesce(sum(payable_usd), 0) from cobradas),
    (select coalesce(sum(financed_usd), 0) from cobradas),
    (select coalesce(sum(fee_usd), 0) from cobradas),
    (select round(coalesce(sum(servicio), 0), 4) from cobradas),
    (select count(*) from cargos where status = 'paid' and pagado_dia between p_desde and p_hasta)::integer,
    (select coalesce(sum(amount_usd), 0) from cargos where status = 'paid' and pagado_dia between p_desde and p_hasta),
    (select count(*) from pagos)::integer,
    (select coalesce(sum(amount_usd), 0) from pagos),
    (select count(*) from ventas)::integer,
    (select coalesce(sum(financed_usd), 0) from ventas),
    (select coalesce(sum(servicio_usd), 0) from ventas),
    (select coalesce(sum(amount_usd), 0) from cargos where business_date between p_desde and p_hasta),
    case when p_merchant_id is null then
      (select coalesce(sum(debit), 0) from libro where tipo = 'installment_payment') end,
    case when p_merchant_id is null then
      (select coalesce(sum(credit), 0) from libro where tipo = 'merchant_settlement') end,
    case when p_merchant_id is null then
      (select coalesce(sum(debit - credit), 0) from libro
       where tipo not in ('installment_payment', 'merchant_settlement')) end;
$$;

comment on function metricas.caja_movimientos(date, date, uuid) is
  'Lo que se movió entre dos días operativos, de todos los locales o de uno. Cobrado: cuotas con el pago aprobado esos días (payable = financed + fee) y su servicio sin IVA proporcional. Cargos por atraso cobrados (aparte). Transferido a los locales (merchant_payouts.business_date). Consumo (financed) y servicio ganado (sin IVA) de los consumos de esos días. Libro de caja (installment_payment, merchant_settlement, resto) solo sin local.';

-- ---------------------------------------------------------------------------
-- 3. Lo que vence y lo que sale, semana a semana
-- ---------------------------------------------------------------------------

create or replace function metricas.caja_proyeccion(
  p_hoy         date,
  p_primera     date,
  p_semanas     integer,
  p_hasta       date,
  p_merchant_id uuid default null
)
returns table (
  week_start          date,
  vence_payable_usd   numeric,
  vence_financed_usd  numeric,
  vence_fee_usd       numeric,
  sale_usd            numeric
)
language sql
stable
as $$
  select
    s.semana,
    coalesce(v.payable, 0),
    coalesce(v.financed, 0),
    coalesce(v.payable, 0) - coalesce(v.financed, 0),
    coalesce(o.usd, 0)
  from (
    select generate_series(
      p_primera,
      p_primera + ((greatest(p_semanas, 1) - 1) * 7),
      interval '7 days'
    )::date as semana
  ) s
  left join (
    -- Lo que vence a los usuarios cada semana: cuotas por vencer (sin pagar,
    -- no perdidas, con vencimiento de hoy en adelante).
    select date_trunc('week', q.due_date::timestamp)::date as semana,
           sum(q.payable_usd)  as payable,
           sum(q.financed_usd) as financed
    from metricas.cuotas q
    where q.estado_hoy = 'por_vencer'
      and q.due_date between p_hoy and p_hasta
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    group by 1
  ) v on v.semana = s.semana
  left join (
    -- Lo que sale a los locales, por el lunes en que le toca a cada
    -- liquidación. Lo atrasado cae en la primera semana.
    select greatest(public.helios_settlement_run_for(st.due_date), p_primera) as semana,
           sum(st.amount_usd - st.paid_usd) as usd
    from public.settlements st
    join public.merchants m on m.id = st.merchant_id
    where st.status in ('pending', 'partial')
      and not m.is_test
      and (p_merchant_id is null or st.merchant_id = p_merchant_id)
    group by 1
  ) o on o.semana = s.semana;
$$;

comment on function metricas.caja_proyeccion(date, date, integer, date, uuid) is
  'Por semana (lunes del cierre): las cuotas que vencen (payable, con financed y fee) y las liquidaciones que salen a los locales, de todos o de uno. Sin local, lo mismo que las filas de helios_cash_forecast.';

-- ---------------------------------------------------------------------------
-- 4. La foto de la caja: admin_cash_position
-- ---------------------------------------------------------------------------

drop function if exists public.admin_cash_position();

create or replace function public.admin_cash_position(p_merchant_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_local       boolean := p_merchant_id is not null;
  v_cash        numeric(18,4);
  v_receivable  numeric(18,4);
  v_payable     numeric(18,4);
  v_revenue     numeric(18,4);
  v_written_off numeric(18,4);
  v_fx          numeric(18,4);
  v_overdue     numeric(18,4);
  v_principal   numeric(18,4);
  v_fee_paid    numeric(18,4);
  v_cartera     record;
  v_serv        record;
  v_today       date := public.helios_business_date(now());
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- Lo del libro es de todo Ronda: sin local.
  if not v_local then
    v_cash        :=  ledger.balance_by_type('cash');
    v_receivable  :=  ledger.balance_by_type('user_receivable');
    v_payable     := -ledger.balance_by_type('merchant_payable');
    v_revenue     := -ledger.balance_by_type('platform_revenue');
    -- La provisión es una cuenta de saldo DEUDOR: `charge_off_user_debt`
    -- la carga al debe. Su saldo, tal cual, es lo dado por perdido (con
    -- el signo cambiado salía negativo en cuanto había un castigo).
    v_written_off :=  ledger.balance_by_type('bad_debt_provision');
    v_fx          :=  ledger.balance_by_type('fx_difference');
  else
    -- Lo que se le debe a ESE local: lo devengado sin transferir más lo que
    -- el cierre encolará (la «Por pagar» de Pagos a locales).
    select o.total_pending_usd into v_payable
    from public.helios_settlement_outlook(p_merchant_id) o;
  end if;

  -- Cuánto de lo que se debe ya está vencido: sin lo perdido ni lo de prueba.
  select coalesce(sum(i.amount_usd), 0) into v_overdue
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where i.status = 'pending'
    and i.written_off_at is null
    and not i.is_test
    and i.due_date < v_today
    and (p_merchant_id is null or c.merchant_id = p_merchant_id);

  -- El consumo que sigue fuera. Lo que se pierde entero si no vuelve.
  select coalesce(sum(i.financed_usd), 0) into v_principal
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where i.status = 'pending'
    and i.written_off_at is null
    and not i.is_test
    and (p_merchant_id is null or c.merchant_id = p_merchant_id);

  -- El servicio con su IVA que ya se cobró: una cuota pagada trae su fee entero.
  select coalesce(sum(i.amount_usd - i.financed_usd), 0) into v_fee_paid
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where i.status = 'paid'
    and not i.is_test
    and (p_merchant_id is null or c.merchant_id = p_merchant_id);

  -- La cartera de hoy, la canónica (la misma de General y de Cobranza): lo
  -- vivo (vencido + por vencer) y lo dado por perdido, con su desglose. Lo
  -- vivo más los cargos pendientes suma lo que el libro llama `user_receivable`,
  -- y lo perdido más los cargos castigados, su provisión: la batería de
  -- coherencia lo comprueba.
  select * into v_cartera
  from metricas.cartera_al(v_today, p_merchant_id);

  -- El servicio de Ronda sin IVA, ganado y cobrado, desde el primer día; y los
  -- cargos por atraso, aparte.
  select m.servicio_ganado_usd, m.cobrado_servicio_usd,
         m.cargos_devengados_usd, m.cargos_cobrados_usd
    into v_serv
  from metricas.caja_movimientos('2000-01-01'::date, v_today, p_merchant_id) m;

  return jsonb_build_object(
    'business_date', v_today,
    'merchant_id', p_merchant_id,
    'cash', v_cash,
    'user_receivable', v_receivable,
    'overdue_receivable', v_overdue,
    'principal_outstanding', v_principal,
    'merchant_payable', v_payable,
    'platform_revenue', v_revenue,
    'commission_collected', v_fee_paid,
    'written_off', v_written_off,
    'fx_difference', v_fx,
    -- Todo lo que está comprometido y todavía no ha vuelto a caja.
    'committed', case when v_local then null else v_receivable + v_payable end,
    -- Lo que queda libre para seguir financiando. Puede salir negativo, y con
    -- liquidación por fecha eso es lo normal.
    'free_capital', case when v_local then null else v_cash - v_payable end,
    -- El desglose de lo que se debe (regla del fee): nunca el total solo.
    'receivable', jsonb_build_object(
      'payable_usd',   v_cartera.vencido_payable_usd + v_cartera.por_vencer_payable_usd,
      'financed_usd',  v_cartera.vencido_financed_usd + v_cartera.por_vencer_financed_usd,
      'fee_usd',       v_cartera.vencido_fee_usd + v_cartera.por_vencer_fee_usd,
      'late_fees_usd', (
        select coalesce(sum(c.amount_usd), 0) from metricas.cargos_por_atraso c
        where c.status = 'pending'
          and (p_merchant_id is null or c.merchant_id = p_merchant_id)
      )
    ),
    'overdue', jsonb_build_object(
      'payable_usd',  v_cartera.vencido_payable_usd,
      'financed_usd', v_cartera.vencido_financed_usd,
      'fee_usd',      v_cartera.vencido_fee_usd
    ),
    'lost', jsonb_build_object(
      'payable_usd',   v_cartera.perdido_payable_usd,
      'financed_usd',  v_cartera.perdido_financed_usd,
      'fee_usd',       v_cartera.perdido_fee_usd,
      'late_fees_usd', (
        select coalesce(sum(c.amount_usd), 0) from metricas.cargos_por_atraso c
        where c.status = 'written_off'
          and (p_merchant_id is null or c.merchant_id = p_merchant_id)
      )
    ),
    -- El ingreso de Ronda: servicio sin IVA ganado (al confirmar el consumo) y
    -- cobrado (dentro de las cuotas pagadas); los cargos por atraso aparte.
    'service', jsonb_build_object(
      'earned_usd',              round(v_serv.servicio_ganado_usd, 2),
      'collected_usd',           round(v_serv.cobrado_servicio_usd, 2),
      'late_fees_earned_usd',    v_serv.cargos_devengados_usd,
      'late_fees_collected_usd', v_serv.cargos_cobrados_usd
    )
  );
end;
$$;

comment on function public.admin_cash_position(uuid) is
  'La foto del dinero hoy. Sin local: el libro (caja, por cobrar, por pagar, ingreso, provisión de lo perdido) y lo que sale de las cuotas. Con p_merchant_id: lo que deben por los consumos de ese local y lo que se le debe; lo del libro vale null. receivable, overdue y lost llevan el desglose financed + fee (y los cargos por atraso aparte); service, el servicio sin IVA ganado y cobrado.';

-- ---------------------------------------------------------------------------
-- 5. La proyección: admin_cash_forecast
-- ---------------------------------------------------------------------------

drop function if exists public.admin_cash_forecast(integer);

create or replace function public.admin_cash_forecast(
  p_weeks       integer default 4,
  p_merchant_id uuid    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_weeks  integer := greatest(least(coalesce(p_weeks, 4), 12), 1);
  v_next   date;
  v_f      jsonb;
  v_factor numeric;
  v_rows   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- Las semanas arrancan el lunes del cierre, no hoy: es el calendario con el
  -- que sale el dinero.
  v_next := public.helios_next_settlement_run(now());
  -- La caja de hoy, el cobro a tiempo que multiplica y la gracia salen de la
  -- proyección de siempre (la que se guarda cada lunes).
  v_f := public.helios_cash_forecast(v_today, v_next - 7, v_weeks + 1, v_today + (v_weeks * 7));
  v_factor := (v_f ->> 'on_time_factor')::numeric;

  select coalesce(jsonb_agg(jsonb_build_object(
    'week_start',                p.week_start,
    'week_end',                  p.week_start + 6,
    'expected_gross_usd',        p.vence_payable_usd,
    'expected_gross_financed_usd', p.vence_financed_usd,
    'expected_gross_fee_usd',    p.vence_fee_usd,
    'expected_in_usd',           round(p.vence_payable_usd * coalesce(v_factor, 1), 2),
    'expected_in_financed_usd',  round(p.vence_financed_usd * coalesce(v_factor, 1), 2),
    'expected_in_fee_usd',       round(p.vence_payable_usd * coalesce(v_factor, 1), 2)
                                   - round(p.vence_financed_usd * coalesce(v_factor, 1), 2),
    'expected_out_usd',          p.sale_usd,
    'net_usd',                   round(p.vence_payable_usd * coalesce(v_factor, 1) - p.sale_usd, 2)
  ) order by p.week_start), '[]'::jsonb)
  into v_rows
  from metricas.caja_proyeccion(v_today, v_next - 7, v_weeks + 1, v_today + (v_weeks * 7), p_merchant_id) p;

  return jsonb_build_object(
    'business_date', v_today,
    'merchant_id', p_merchant_id,
    -- La caja es de todo Ronda: con local no hay caja de partida.
    'cash_now_usd', case when p_merchant_id is null then v_f -> 'cash_now_usd' end,
    'weeks', v_weeks,
    -- Null cuando no hay historia suficiente. Es el de toda la cartera,
    -- también con un local: el de uno solo tendría muy pocas cuotas.
    'on_time_factor', v_f -> 'on_time_factor',
    'grace_days', v_f -> 'grace_days',
    'rows', v_rows
  );
end;
$$;

comment on function public.admin_cash_forecast(integer, uuid) is
  'La proyección de caja por semana: lo que vence (payable con financed y fee), lo que se espera cobrar con el cobro a tiempo histórico, lo que sale a los locales y el neto. Con p_merchant_id, lo de ese local y sin caja de partida.';

-- ---------------------------------------------------------------------------
-- 6. Lo que se les debe a los locales: admin_merchant_payables
-- ---------------------------------------------------------------------------

drop function if exists public.admin_merchant_payables();

create or replace function public.admin_merchant_payables(p_merchant_id uuid default null)
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

  select coalesce(jsonb_agg(to_jsonb(q) order by q.total_pending_usd desc), '[]'::jsonb)
  into v_rows
  from (
    select
      m.id     as merchant_id,
      m.name   as merchant_name,
      m.tax_id,
      -- El local de prueba entra, marcado: lo que no puede es SUMAR en las
      -- cifras del negocio, y eso lo decide quien pinta.
      m.is_test,
      o.*
    from public.merchants m
    cross join lateral public.helios_settlement_outlook(m.id) o
    where (o.accrued_usd > 0 or o.upcoming_usd > 0)
      and (p_merchant_id is null or m.id = p_merchant_id)
  ) q;

  return v_rows;
end;
$$;

comment on function public.admin_merchant_payables(uuid) is
  'Lo que se les debe a los locales (devengado sin transferir y lo que el cierre encolará), uno por fila, con los de prueba marcados. Con p_merchant_id, solo ese local.';

-- ---------------------------------------------------------------------------
-- 7. La pestaña Caja: admin_metricas_caja
-- ---------------------------------------------------------------------------

create or replace function public.admin_metricas_caja(
  p_semana      date default null,
  p_merchant_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy        date := metricas.hoy();
  v_local      boolean := p_merchant_id is not null;
  v_lunes      date;
  v_domingo    date;
  v_hasta      date;
  v_dias       integer;
  v_prev_desde date;
  v_prev_hasta date;
  v_mov        jsonb;
  v_ant        jsonb;
  v_semanas    jsonb;
  v_locales    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- La semana elegida, llevada a su lunes; nunca una futura.
  v_lunes   := least(metricas.lunes(coalesce(p_semana, v_hoy)), metricas.lunes(v_hoy));
  v_domingo := v_lunes + 6;
  -- Lo que va de semana: hasta hoy si está en curso.
  v_hasta   := least(v_domingo, v_hoy);
  v_dias    := v_hasta - v_lunes + 1;
  -- La anterior, a la misma altura: los mismos días de la semana.
  v_prev_desde := v_lunes - 7;
  v_prev_hasta := v_lunes - 7 + v_dias - 1;

  select to_jsonb(m) into v_mov
  from metricas.caja_movimientos(v_lunes, v_hasta, p_merchant_id) m;

  select to_jsonb(m) into v_ant
  from metricas.caja_movimientos(v_prev_desde, v_prev_hasta, p_merchant_id) m;

  -- Ocho semanas hasta la elegida, para las chispas y lo proyectado frente a
  -- lo real. `vencia` es todo lo que vencía esa semana (pagado o no).
  select coalesce(jsonb_agg(jsonb_build_object(
    'lunes',                 w.lunes,
    'domingo',               w.lunes + 6,
    'en_curso',              w.lunes + 6 >= v_hoy,
    'cobrado', jsonb_build_object(
      'payable_usd',  m.cobrado_payable_usd,
      'financed_usd', m.cobrado_financed_usd,
      'fee_usd',      m.cobrado_fee_usd
    ),
    'cargos_cobrados_usd',   m.cargos_cobrados_usd,
    'transferido_usd',       m.transferido_usd,
    'servicio_ganado_usd',   round(m.servicio_ganado_usd, 2),
    'servicio_cobrado_usd',  round(m.cobrado_servicio_usd, 2),
    'caja_al_cierre_usd',    case when v_local then null else metricas.caja_al(least(w.lunes + 6, v_hoy)) end,
    'vencia', (
      select jsonb_build_object(
        'payable_usd',  coalesce(sum(q.payable_usd), 0),
        'financed_usd', coalesce(sum(q.financed_usd), 0),
        'fee_usd',      coalesce(sum(q.fee_usd), 0)
      )
      from metricas.cuotas q
      where q.due_date between w.lunes and w.lunes + 6
        and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    )
  ) order by w.lunes), '[]'::jsonb)
  into v_semanas
  from (
    select (v_lunes - 7 * g.k)::date as lunes
    from generate_series(0, 7) g(k)
  ) w
  cross join lateral metricas.caja_movimientos(w.lunes, least(w.lunes + 6, v_hoy), p_merchant_id) m;

  -- Lo que se les debe hoy a los locales (o a ese local), como en Pagos a
  -- locales: sin los locales de prueba.
  select jsonb_build_object(
    'total_usd',         coalesce(sum(o.total_pending_usd), 0),
    'atrasado_usd',      coalesce(sum(o.overdue_usd), 0),
    'este_cierre_usd',   coalesce(sum(o.next_run_usd), 0),
    'fecha_cierre',      max(o.next_run_date),
    'locales_atrasados', count(*) filter (where o.overdue_usd > 0),
    'ultimo_pago_dia',   case when v_local then max(o.last_payout_on) end,
    'ultimo_pago_usd',   case when v_local then max(o.last_payout_usd) end
  )
  into v_locales
  from public.merchants m
  cross join lateral public.helios_settlement_outlook(m.id) o
  where not m.is_test
    and (p_merchant_id is null or m.id = p_merchant_id);

  return jsonb_build_object(
    'hoy',          v_hoy,
    'semana',       jsonb_build_object('desde', v_lunes, 'hasta', v_domingo, 'en_curso', v_domingo >= v_hoy),
    'dias',         v_dias,
    'anterior',     jsonb_build_object('desde', v_prev_desde, 'hasta', v_prev_hasta),
    'merchant_id',  p_merchant_id,
    'movimientos',  jsonb_build_object(
      'cobrado', jsonb_build_object(
        'payable_usd',  v_mov -> 'cobrado_payable_usd',
        'financed_usd', v_mov -> 'cobrado_financed_usd',
        'fee_usd',      v_mov -> 'cobrado_fee_usd',
        'cuotas',       v_mov -> 'cuotas_cobradas',
        'personas',     v_mov -> 'personas_que_pagaron'
      ),
      'servicio_cobrado_usd',  round((v_mov ->> 'cobrado_servicio_usd')::numeric, 2),
      'cargos_cobrados',       jsonb_build_object('usd', v_mov -> 'cargos_cobrados_usd', 'n', v_mov -> 'cargos_cobrados'),
      'transferido',           jsonb_build_object('usd', v_mov -> 'transferido_usd', 'n', v_mov -> 'transferencias'),
      'consumo',               jsonb_build_object('financed_usd', v_mov -> 'consumo_usd', 'consumos', v_mov -> 'consumos'),
      'servicio_ganado_usd',   round((v_mov ->> 'servicio_ganado_usd')::numeric, 2),
      'cargos_devengados_usd', v_mov -> 'cargos_devengados_usd',
      'libro', case when v_local then null else jsonb_build_object(
        'cobrado_usd',     v_mov -> 'libro_cobrado_usd',
        'transferido_usd', v_mov -> 'libro_transferido_usd',
        'otros_usd',       v_mov -> 'libro_otros_usd'
      ) end
    ),
    'movimientos_anterior', jsonb_build_object(
      'cobrado', jsonb_build_object(
        'payable_usd',  v_ant -> 'cobrado_payable_usd',
        'financed_usd', v_ant -> 'cobrado_financed_usd',
        'fee_usd',      v_ant -> 'cobrado_fee_usd',
        'cuotas',       v_ant -> 'cuotas_cobradas',
        'personas',     v_ant -> 'personas_que_pagaron'
      ),
      'servicio_cobrado_usd',  round((v_ant ->> 'cobrado_servicio_usd')::numeric, 2),
      'cargos_cobrados',       jsonb_build_object('usd', v_ant -> 'cargos_cobrados_usd', 'n', v_ant -> 'cargos_cobrados'),
      'transferido',           jsonb_build_object('usd', v_ant -> 'transferido_usd', 'n', v_ant -> 'transferencias'),
      'consumo',               jsonb_build_object('financed_usd', v_ant -> 'consumo_usd', 'consumos', v_ant -> 'consumos'),
      'servicio_ganado_usd',   round((v_ant ->> 'servicio_ganado_usd')::numeric, 2),
      'cargos_devengados_usd', v_ant -> 'cargos_devengados_usd'
    ),
    -- La caja es de todo Ronda: con local, null.
    'caja', case when v_local then null else jsonb_build_object(
      'al_inicio_usd',          metricas.caja_al(v_lunes - 1),
      'al_cierre_usd',          metricas.caja_al(v_hasta),
      'al_cierre_anterior_usd', metricas.caja_al(v_prev_hasta)
    ) end,
    'por_pagar_locales', v_locales,
    'semanas',      v_semanas
  );
end;
$$;

comment on function public.admin_metricas_caja(date, uuid) is
  'Métricas › Caja: lo que se movió en la semana (cobrado de cuotas con desglose, cargos por atraso, transferido a los locales, servicio sin IVA ganado y cobrado), lo mismo de la semana anterior a la misma altura, la caja del libro al cierre (sin local), lo que se debe hoy a los locales y ocho semanas para las chispas. Lee de metricas.caja_movimientos y metricas.caja_al.';

-- ---------------------------------------------------------------------------
-- 8. Permisos
-- ---------------------------------------------------------------------------

revoke all on metricas.libro_de_caja from public, anon, authenticated;
revoke all on function metricas.caja_al(date) from public, anon, authenticated;
revoke all on function metricas.caja_movimientos(date, date, uuid) from public, anon, authenticated;
revoke all on function metricas.caja_proyeccion(date, date, integer, date, uuid) from public, anon, authenticated;

revoke all on function public.admin_cash_position(uuid) from public, anon;
revoke all on function public.admin_cash_forecast(integer, uuid) from public, anon;
revoke all on function public.admin_merchant_payables(uuid) from public, anon;
revoke all on function public.admin_metricas_caja(date, uuid) from public, anon;

grant execute on function public.admin_cash_position(uuid) to authenticated;
grant execute on function public.admin_cash_forecast(integer, uuid) to authenticated;
grant execute on function public.admin_merchant_payables(uuid) to authenticated;
grant execute on function public.admin_metricas_caja(date, uuid) to authenticated;
