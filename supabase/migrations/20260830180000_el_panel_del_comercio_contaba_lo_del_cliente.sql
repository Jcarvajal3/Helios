-- ============================================================================
-- Ronda — El panel del comercio contaba el dinero del cliente como si fuera suyo
--
-- EL FALLO
--
-- `merchant_overview`, `merchant_daily_series` y `merchant_hourly_profile`
-- sumaban `charges.amount_usd`. Esa columna dejó de ser la venta del comercio
-- el 27 de agosto: desde la facturación por cuenta de terceros es LO QUE DEBE EL
-- CONSUMIDOR, con el fee de Ronda y su IVA dentro (docs/00-BASES §2.11).
--
-- Al local se le enseñaban entonces sus ingresos inflados un 27,6 %, y desde
-- 20260830140000 un 11,6 %. Justo en la pantalla que va a comparar contra su
-- caja. Y "Tu parte" era todavía peor:
--
--     net_usd = sold * (100 − commission_pct) / 100
--
-- Con la comisión ya en 0, esa fórmula devuelve el total del consumidor entero
-- y afirma que al comercio le entran $111,60 de un consumo de $100.
--
-- Estaba anotado como pendiente en docs/00-BASES §2.11 desde que se creó el
-- problema; se arregla ahora porque el cambio de modelo lo pone delante.
--
-- EL ARREGLO
--
-- Dos cifras distintas y las dos correctas, en vez de una mal:
--
--     "Vendido"  → la venta del comercio con su IVA dentro (base + IVA)
--     "Tu parte" → lo que se le paga (`merchant_net_usd`)
--
-- Hoy coinciden, porque no hay comisión. Se mantienen separadas porque la
-- comisión sigue siendo negociable comercio a comercio, y el día que alguien
-- pacte una, las dos cifras vuelven a ser distintas sin tocar nada.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La regla, en un solo sitio
-- ---------------------------------------------------------------------------
/**
 * La venta del comercio a partir de las columnas del cobro.
 *
 * Existe para que las tres métricas no repitan el `coalesce` cada una por su
 * cuenta: la última vez que esta cuenta vivió en tres sitios acabaron dando tres
 * respuestas distintas, que es lo que motivó `helios_charge_breakdown`.
 *
 * El `coalesce` cubre los cobros anteriores al desglose, donde `amount_usd` SÍ
 * era la venta y las columnas nuevas están en null.
 */
create or replace function public.helios_merchant_sale_usd(
  p_base_usd   numeric,
  p_vat_usd    numeric,
  p_amount_usd numeric
)
returns numeric
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$
  select coalesce(p_base_usd + p_vat_usd, p_amount_usd);
$fn$;

comment on function public.helios_merchant_sale_usd(numeric, numeric, numeric) is
  'La venta del comercio con su IVA dentro. NO es charges.amount_usd, que es lo que debe el consumidor. Ver docs/00-BASES 2.11.';

revoke all on function public.helios_merchant_sale_usd(numeric, numeric, numeric) from public, anon;
grant execute on function public.helios_merchant_sale_usd(numeric, numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El resumen
-- ---------------------------------------------------------------------------
create or replace function public.merchant_overview(p_days integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_merchant    uuid := public.my_merchant_id_as_gerente();
  v_today       date;
  v_days        integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_from        date;
  v_prev_from   date;
  v_terms       public.merchant_settlement_terms%rowtype;
  v_sold        numeric := 0;
  v_net         numeric := 0;
  v_count       integer := 0;
  v_prev_sold   numeric := 0;
  v_prev_count  integer := 0;
  v_active_days integer := 0;
  v_best_date   date;
  v_best_usd    numeric := 0;
begin
  if v_merchant is null then
    raise exception 'Solo el gerente del comercio' using errcode = '42501';
  end if;

  v_today     := public.helios_business_date(now());
  v_from      := v_today - (v_days - 1);
  v_prev_from := v_from - v_days;

  select * into v_terms
  from public.merchant_settlement_terms where merchant_id = v_merchant;

  -- NUEVO: la venta del comercio y su neto, en la misma pasada. Antes el neto
  -- se derivaba del bruto con una regla de tres sobre la comisión; ahora sale
  -- guardado del propio cobro, que es donde se calculó al emitirlo.
  select
    coalesce(sum(public.helios_merchant_sale_usd(base_usd, vat_usd, amount_usd)), 0),
    coalesce(sum(coalesce(merchant_net_usd, amount_usd)), 0),
    count(*)::integer,
    count(distinct business_date)::integer
  into v_sold, v_net, v_count, v_active_days
  from public.charges
  where merchant_id = v_merchant
    and status = 'confirmed'
    and business_date between v_from and v_today;

  select
    coalesce(sum(public.helios_merchant_sale_usd(base_usd, vat_usd, amount_usd)), 0),
    count(*)::integer
  into v_prev_sold, v_prev_count
  from public.charges
  where merchant_id = v_merchant
    and status = 'confirmed'
    and business_date between v_prev_from and v_from - 1;

  select business_date,
         sum(public.helios_merchant_sale_usd(base_usd, vat_usd, amount_usd))
  into v_best_date, v_best_usd
  from public.charges
  where merchant_id = v_merchant
    and status = 'confirmed'
    and business_date between v_from and v_today
  group by business_date
  order by 2 desc, 1 desc
  limit 1;

  return jsonb_build_object(
    'business_date', v_today,
    'window_days',   v_days,
    'sold_usd',      v_sold,
    'charge_count',  v_count,
    -- Sin ventas el ticket promedio es 0, no una división por cero.
    'avg_ticket_usd', case when v_count = 0 then 0 else round(v_sold / v_count, 2) end,
    'active_days',   v_active_days,
    'previous_sold_usd',    v_prev_sold,
    'previous_charge_count', v_prev_count,
    'commission_pct', v_terms.commission_pct,
    -- Lo que le queda al local. Hoy es igual que lo vendido porque no hay
    -- comisión; se sigue devolviendo aparte porque la comisión es negociable y
    -- el día que alguien pacte una, las dos cifras vuelven a separarse.
    'net_usd', round(v_net, 2),
    'best_date', v_best_date,
    'best_usd', coalesce(v_best_usd, 0)
  );
end;
$$;

revoke all on function public.merchant_overview(integer) from public, anon;
grant execute on function public.merchant_overview(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. La serie diaria
-- ---------------------------------------------------------------------------
create or replace function public.merchant_daily_series(p_days integer default 30)
returns table (
  business_date date,
  sold_usd      numeric,
  charge_count  integer
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
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
  with days as (
    select generate_series(v_today - (v_days - 1), v_today, interval '1 day')::date as d
  )
  select
    days.d,
    coalesce(c.sold, 0)::numeric,
    coalesce(c.cnt, 0)::integer
  from days
  left join (
    select ch.business_date as d,
           sum(public.helios_merchant_sale_usd(ch.base_usd, ch.vat_usd, ch.amount_usd)) as sold,
           count(*)::integer as cnt
    from public.charges ch
    where ch.merchant_id = v_merchant and ch.status = 'confirmed'
    group by 1
  ) c on c.d = days.d
  order by days.d;
end;
$$;

revoke all on function public.merchant_daily_series(integer) from public, anon;
grant execute on function public.merchant_daily_series(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. El perfil por hora
-- ---------------------------------------------------------------------------
create or replace function public.merchant_hourly_profile(p_days integer default 30)
returns table (
  hour_of_day  smallint,
  sold_usd     numeric,
  charge_count integer
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
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
    -- 10, 11, ... 23, 0, 1, ... 9 — el día operativo en orden.
    select ((10 + g) % 24)::smallint as h, g as sort_key
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
$$;

revoke all on function public.merchant_hourly_profile(integer) from public, anon;
grant execute on function public.merchant_hourly_profile(integer) to authenticated;
