-- ============================================================================
-- Ronda — El panel del comercio: órdenes, recurrencia y el estado de las cuotas
--
-- Cuatro cosas, y la primera explica a las otras tres.
--
-- ---------------------------------------------------------------------------
-- 1. UNA ORDEN ES UN COBRO, aunque la paguen cinco personas
-- ---------------------------------------------------------------------------
-- Lo que el local llamaba "consumos" pasa a llamarse **órdenes**, y la unidad
-- queda dicha de una vez: una fila de `charges` es una orden. Un cobro de grupo
-- lo pagan hasta cinco personas y genera cinco deudas (una por integrante, con
-- sus dos cuotas cada una), pero el local hizo UNA venta, sacó UN QR y sirvió
-- UNA mesa. Contar cinco ahí le partiría el ticket promedio por cinco.
--
-- ---------------------------------------------------------------------------
-- 2. El ticket promedio se calculaba en dos sitios y con dos reglas
-- ---------------------------------------------------------------------------
-- Métricas lo pedía a `merchant_overview` (venta del comercio ÷ cobros) y el
-- historial lo hacía en el navegador con OTRA cifra (`merchant_net_usd`, que
-- es lo que se le PAGA, no lo que vendió) y sobre las 500 filas que le cupieron
-- a la consulta. Hoy las dos reglas dan lo mismo porque la comisión al comercio
-- es 0 y el rango cabe entero; el día que alguien pacte una comisión, o que un
-- local pida tres meses, las dos pantallas se contradicen.
--
-- Se arregla por donde se arreglan estas cosas aquí: la cuenta baja a una
-- función (`helios_avg_ticket_usd`), las dos pantallas la piden y ninguna
-- divide nada por su cuenta.
--
-- ---------------------------------------------------------------------------
-- 3. Recurrencia a 30 días
-- ---------------------------------------------------------------------------
-- Cuántas veces vuelve la gente a este local, contando **una visita por cada
-- persona que asumió parte de un cobro confirmado**. En un cobro de grupo eso
-- son cinco visitas y una sola orden — y las dos cifras son correctas, porque
-- responden a preguntas distintas: la orden es la venta, la visita es alguien
-- que volvió a entrar por la puerta.
--
-- Sale en cubos (1, 2, 3, 4 o más) y no como un promedio: "mis clientes vienen
-- 1,8 veces" no se puede accionar; "tengo 12 clientes que vinieron 4 veces o
-- más y me dejaron $840" sí.
--
-- Devuelve SOLO agregados. El comercio sigue sin poder ver quién es su cliente
-- (docs/00-BASES §3.11), y esto no abre esa puerta por el lado de las métricas.
--
-- ---------------------------------------------------------------------------
-- 4. El estado de las cuotas en el historial
-- ---------------------------------------------------------------------------
-- `installments` no la puede leer el comercio —su RLS es del dueño de la deuda
-- y del admin—, así que el historial pasa a servirse por RPC en vez de por
-- tabla. Cada orden vuelve con el estado de su cuota 1 y de su cuota 2:
--
--     pagado    todas las partes de esa cuota están saldadas
--     en mora   alguna sigue pendiente y su fecha ya pasó
--     pendiente el resto
--
-- **En un cobro de grupo el estado es el PEOR de los integrantes**, no una
-- media: si uno de cinco está en mora, esa cuota está en mora. Un semáforo que
-- se pone verde porque cuatro de cinco pagaron no avisa de nada.
--
-- Ojo con lo que este dato NO significa: la mora del cliente no toca lo que
-- Ronda le liquida al local (docs/05 §3, y así se dice en Liquidaciones). Es
-- información sobre su clientela, no sobre su dinero.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El ticket promedio, en un solo sitio
-- ---------------------------------------------------------------------------
/**
 * Venta del comercio ÷ número de ÓRDENES.
 *
 * El divisor son cobros, no deudores: una cuenta repartida entre cinco es una
 * orden. Y el dividendo es la venta del comercio (base + IVA), no lo que debe
 * el consumidor ni lo que se le acaba pagando al local — ver
 * `helios_merchant_sale_usd` y docs/00-BASES §2.11.
 *
 * Existe como función y no como una división suelta porque estaba escrita en
 * dos pantallas con dos dividendos distintos, que es exactamente el problema
 * que vino a resolver.
 */
create or replace function public.helios_avg_ticket_usd(
  p_sale_usd numeric,
  p_orders   integer
)
returns numeric
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$
  -- Sin órdenes el promedio es 0, no una división por cero.
  select case when coalesce(p_orders, 0) = 0
              then 0::numeric
              else round(coalesce(p_sale_usd, 0) / p_orders, 2) end;
$fn$;

comment on function public.helios_avg_ticket_usd(numeric, integer) is
  'Ticket promedio del comercio: su venta dividida entre el numero de ORDENES. Un cobro de grupo es una orden, no una por integrante.';

revoke all on function public.helios_avg_ticket_usd(numeric, integer) from public, anon;
grant execute on function public.helios_avg_ticket_usd(numeric, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El resumen de Métricas pasa por el mismo sitio
-- ---------------------------------------------------------------------------
-- Idéntica a la de 20260830180000 salvo el `avg_ticket_usd`, que ya no hace la
-- división aquí. Se reescribe entera porque `create or replace` sustituye el
-- cuerpo completo.

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
    -- `charge_count` conserva el nombre —lo leen el panel y el cliente ya
    -- desplegado— pero la pantalla lo llama "Nro. de órdenes". Es lo que
    -- siempre fue: un cobro, aunque lo pagaran cinco.
    'charge_count',  v_count,
    'avg_ticket_usd', public.helios_avg_ticket_usd(v_sold, v_count),
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
-- 3. El historial, con el estado de cada cuota
-- ---------------------------------------------------------------------------
-- El rango va por **día operativo** (10 AM a 10 AM, docs/00-BASES §2.2) y no
-- por `confirmed_at`: filtrar por la hora real partiría cada madrugada en dos y
-- haría que este panel y el de Ronda no cuadraran nunca.
--
-- El personal del comercio ve el historial —cajero y gerente, docs/06 §106—,
-- así que el guardia es `my_merchant_ids()` y no la variante de gerente. Va
-- SECURITY DEFINER solo por `installments`, que el comercio no puede leer; de
-- ahí no sale ni un `user_id`, solo cuántos pagaron y en qué van.

create or replace function public.merchant_transactions(
  p_from  date,
  p_to    date,
  p_limit integer default 500
)
returns table (
  charge_id         uuid,
  order_number      bigint,
  business_date     date,
  confirmed_at      timestamptz,
  /** Lo que se le cobró al cliente: la venta más el fee del servicio y su IVA. */
  amount_usd        numeric,
  /** La venta del comercio, con su IVA dentro. Es "tu venta" en pantalla. */
  merchant_sale_usd numeric,
  /** Entre cuántas personas se repartió la cuenta. 1 en un cobro normal. */
  payer_count       integer,
  cuota_1_status    text,
  cuota_1_due       date,
  cuota_2_status    text,
  cuota_2_due       date
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today date := public.helios_business_date(now());
  -- El tope existe porque el rango es abierto: un gerente puede pedir un año
  -- desde la tablet y esta pantalla no pagina. Los totales NO salen de aquí
  -- —los da `merchant_transactions_summary` sobre el rango entero— para que
  -- recortar la lista no recorte también las cifras.
  v_limit integer := greatest(least(coalesce(p_limit, 500), 500), 1);
begin
  if not exists (select 1 from public.my_merchant_ids()) then
    raise exception 'Solo el personal del comercio' using errcode = '42501';
  end if;

  return query
  with mias as (
    select c.id,
           c.order_number as num,
           c.business_date as bdate,
           c.confirmed_at as conf,
           c.amount_usd as charged,
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale
    from public.charges c
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status = 'confirmed'
      and c.business_date between p_from and p_to
    order by c.business_date desc, c.confirmed_at desc
    limit v_limit
  ),
  -- El estado de una cuota es el PEOR de sus partes: con cinco deudores, que
  -- cuatro hayan pagado no quita que la cuota siga sin cobrarse entera.
  cuotas as (
    select i.charge_id as cid,
           i.sequence as seq,
           min(i.due_date) as due,
           case
             when count(*) filter (
                    where i.status = 'pending' and i.due_date < v_today) > 0
               then 'overdue'
             when count(*) filter (where i.status = 'pending') > 0
               then 'pending'
             else 'paid'
           end as state
    from public.installments i
    join mias m on m.id = i.charge_id
    group by i.charge_id, i.sequence
  ),
  quienes as (
    select i.charge_id as cid, count(distinct i.user_id)::integer as n
    from public.installments i
    join mias m on m.id = i.charge_id
    group by i.charge_id
  )
  select m.id,
         m.num,
         m.bdate,
         m.conf,
         m.charged,
         m.sale,
         coalesce(q.n, 1),
         c1.state,
         c1.due,
         c2.state,
         c2.due
  from mias m
  left join quienes q on q.cid = m.id
  left join cuotas c1 on c1.cid = m.id and c1.seq = 1
  left join cuotas c2 on c2.cid = m.id and c2.seq = 2
  order by m.bdate desc, m.conf desc;
end;
$$;

comment on function public.merchant_transactions(date, date, integer) is
  'Historial de ordenes del comercio por dia operativo, con el estado agregado de cada cuota. No expone quien es el cliente.';

revoke all on function public.merchant_transactions(date, date, integer) from public, anon;
grant execute on function public.merchant_transactions(date, date, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Los totales del rango, sobre el rango ENTERO
-- ---------------------------------------------------------------------------
-- Aparte de la lista a propósito. Sumar en el navegador lo que cupo en la
-- consulta hacía que un rango con más de 500 órdenes enseñara un total y un
-- ticket promedio de solo las últimas 500, sin que la cifra dijera nada.

create or replace function public.merchant_transactions_summary(
  p_from date,
  p_to   date
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_orders  integer := 0;
  v_sale    numeric := 0;
  v_charged numeric := 0;
  v_days    integer := 0;
begin
  if not exists (select 1 from public.my_merchant_ids()) then
    raise exception 'Solo el personal del comercio' using errcode = '42501';
  end if;

  select
    count(*)::integer,
    coalesce(sum(public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd)), 0),
    coalesce(sum(c.amount_usd), 0),
    count(distinct c.business_date)::integer
  into v_orders, v_sale, v_charged, v_days
  from public.charges c
  where c.merchant_id in (select public.my_merchant_ids())
    and c.status = 'confirmed'
    and c.business_date between p_from and p_to;

  return jsonb_build_object(
    'order_count',    v_orders,
    'sale_usd',       round(v_sale, 2),
    'charged_usd',    round(v_charged, 2),
    'avg_ticket_usd', public.helios_avg_ticket_usd(v_sale, v_orders),
    'active_days',    v_days
  );
end;
$$;

comment on function public.merchant_transactions_summary(date, date) is
  'Totales del historial sobre el rango entero, sin el tope de filas de la lista.';

revoke all on function public.merchant_transactions_summary(date, date) from public, anon;
grant execute on function public.merchant_transactions_summary(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Recurrencia
-- ---------------------------------------------------------------------------
-- La cuenta, en tres pasos:
--
--   lineas      lo que cada persona asumió de cada cobro
--   visitas     una fila por persona y orden, con la parte de la venta que le
--               corresponde (repartida por `financed_usd`, que es exactamente
--               la porción de la base que se llevó cada uno)
--   por_persona cuántas veces vino cada quien y cuánto dejó
--
-- Y el resultado se agrupa en cubos de 1, 2, 3 y "4 o más". Los cuatro salen
-- siempre, aunque estén vacíos: una pantalla con un filtro de tres botones no
-- puede quedarse sin respuesta para uno de ellos.

create or replace function public.merchant_recurrence(p_days integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_today    date;
  v_days     integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_from     date;
  v_result   jsonb;
begin
  if v_merchant is null then
    raise exception 'Solo el gerente del comercio' using errcode = '42501';
  end if;

  v_today := public.helios_business_date(now());
  v_from  := v_today - (v_days - 1);

  with lineas as (
    select c.id as cid,
           i.user_id as uid,
           sum(i.financed_usd) as mio,
           max(public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd)) as venta
    from public.charges c
    join public.installments i on i.charge_id = c.id
    where c.merchant_id = v_merchant
      and c.status = 'confirmed'
      and c.business_date between v_from and v_today
    group by c.id, i.user_id
  ),
  visitas as (
    select l.cid,
           l.uid,
           l.venta * l.mio / nullif(sum(l.mio) over (partition by l.cid), 0) as sale_usd
    from lineas l
  ),
  por_persona as (
    select v.uid,
           count(*)::integer as veces,
           coalesce(sum(v.sale_usd), 0) as sale_usd
    from visitas v
    group by v.uid
  ),
  totales as (
    select count(*)::integer as customers,
           coalesce(sum(p.veces), 0)::integer as visits,
           (count(*) filter (where p.veces >= 2))::integer as returning_customers,
           coalesce(sum(p.sale_usd), 0) as sale_usd,
           coalesce(sum(p.sale_usd) filter (where p.veces >= 2), 0) as returning_sale_usd
    from por_persona p
  ),
  cubos as (
    -- 4 es el techo del cubo, no de las visitas: quien vino nueve veces cae en
    -- "4 o más" y sus nueve visitas se cuentan enteras.
    select least(p.veces, 4) as times,
           count(*)::integer as customers,
           sum(p.veces)::integer as visits,
           coalesce(sum(p.sale_usd), 0) as sale_usd
    from por_persona p
    group by 1
  ),
  escala as (
    select g.times,
           coalesce(b.customers, 0) as customers,
           coalesce(b.visits, 0) as visits,
           round(coalesce(b.sale_usd, 0), 2) as sale_usd
    from (select generate_series(1, 4) as times) g
    left join cubos b on b.times = g.times
  )
  select jsonb_build_object(
    'business_date',       v_today,
    'window_days',         v_days,
    'customers',           t.customers,
    'visits',              t.visits,
    'returning_customers', t.returning_customers,
    'returning_pct',       case when t.customers = 0 then 0
                                else round(100.0 * t.returning_customers / t.customers, 1) end,
    'sale_usd',            round(t.sale_usd, 2),
    'returning_sale_usd',  round(t.returning_sale_usd, 2),
    'buckets', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'times',     e.times,
               'customers', e.customers,
               'visits',    e.visits,
               'sale_usd',  e.sale_usd
             ) order by e.times), '[]'::jsonb)
      from escala e
    )
  )
  into v_result
  from totales t;

  return v_result;
end;
$$;

comment on function public.merchant_recurrence(integer) is
  'Cuantas veces vuelve la clientela del comercio en una ventana de dias. Una visita = una persona que asumio parte de un cobro confirmado. Solo agregados: no dice quien.';

revoke all on function public.merchant_recurrence(integer) from public, anon;
grant execute on function public.merchant_recurrence(integer) to authenticated;
