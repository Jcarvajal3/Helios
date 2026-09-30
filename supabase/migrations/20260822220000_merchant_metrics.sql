-- ============================================================================
-- Ronda — Métricas del comercio
--
-- Las mismas dos reglas que el tablero del super admin (20260822200000), por
-- las mismas razones:
--
--   1. **El cálculo vive en la base, no en el panel.** Si el panel sumara los
--      `charges` por su cuenta, el día en que cambie la comisión o el corte
--      del día operativo el local vería un número y Ronda otro — y ninguno de
--      los dos sabría cuál está mal.
--
--   2. **Toda fecha pasa por el día operativo** (10 AM a 10 AM, docs/06 §1).
--      Un `date_trunc('day', ...)` partiría cada noche en dos y le diría al
--      dueño de un bar que vende la mitad de lo que vende.
--
-- Quién puede llamarlas: solo el `gerente`. No es una decisión nueva de esta
-- migración — ya lo era: `merchant_settlement_terms` (la comisión) solo la
-- lee el gerente desde 20260821223000, porque es información de negocio del
-- dueño y no del cajero que está en la barra.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- De qué comercio es gerente quien pregunta
-- ---------------------------------------------------------------------------
-- Las RPC NO reciben `p_merchant_id`. Recibirlo obligaría a comprobar en cada
-- una que el comercio pedido es el suyo, y basta olvidarlo en una para que un
-- gerente lea la facturación del local de al lado. Resolverlo desde la sesión
-- hace que ese fallo no se pueda escribir.

create or replace function public.my_merchant_id_as_gerente()
returns uuid
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select merchant_id
  from public.merchant_users
  where user_id = auth.uid() and is_active and role = 'gerente'
  limit 1;
$$;

revoke all on function public.my_merchant_id_as_gerente() from public, anon;
grant execute on function public.my_merchant_id_as_gerente() to authenticated;

-- ---------------------------------------------------------------------------
-- 1. Resumen del periodo
-- ---------------------------------------------------------------------------
-- La pregunta que responde: *¿cómo va el negocio comparado con antes?*
--
-- El periodo anterior son los mismos días inmediatamente antes, no "el mes
-- pasado": así 7 días se comparan contra los 7 anteriores y la cifra de al
-- lado significa siempre lo mismo.

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

  select
    coalesce(sum(amount_usd), 0),
    count(*)::integer,
    count(distinct business_date)::integer
  into v_sold, v_count, v_active_days
  from public.charges
  where merchant_id = v_merchant
    and status = 'confirmed'
    and business_date between v_from and v_today;

  select coalesce(sum(amount_usd), 0), count(*)::integer
  into v_prev_sold, v_prev_count
  from public.charges
  where merchant_id = v_merchant
    and status = 'confirmed'
    and business_date between v_prev_from and v_from - 1;

  select business_date, sum(amount_usd)
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
    -- Lo que le queda al local después de la comisión de Ronda. Es el número
    -- que le importa: "vendí $1.000" y "cobro $800" no son lo mismo, y
    -- enseñar solo el bruto invita a olvidar que la comisión existe.
    'net_usd', round(v_sold * (100 - v_terms.commission_pct) / 100, 2),
    'best_date', v_best_date,
    'best_usd', coalesce(v_best_usd, 0)
  );
end;
$$;

revoke all on function public.merchant_overview(integer) from public, anon;
grant execute on function public.merchant_overview(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Serie diaria
-- ---------------------------------------------------------------------------
-- Con `generate_series` para que los días sin ventas salgan en cero en vez de
-- desaparecer: una barra ausente y una barra a cero cuentan cosas distintas —
-- "cerramos el lunes" no es lo mismo que "el lunes no vino nadie".

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
    select ch.business_date as d, sum(ch.amount_usd) as sold, count(*)::integer as cnt
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
-- 3. Perfil por hora
-- ---------------------------------------------------------------------------
-- Para qué sirve: decidir a qué hora poner más gente en la barra. En un local
-- de noche es la métrica que se mira antes que ninguna otra.
--
-- La hora sale de `confirmed_at` en hora de Caracas, y las 24 horas se rotan
-- para empezar a las 10 AM: así la noche sale entera y seguida en el gráfico
-- en vez de partida entre el extremo derecho y el izquierdo.

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
      sum(ch.amount_usd) as sold,
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
