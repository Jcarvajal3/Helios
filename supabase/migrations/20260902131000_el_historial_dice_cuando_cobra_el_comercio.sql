-- ============================================================================
-- Ronda — El historial del comercio dice CUÁNDO COBRA, no cómo va la deuda
--
-- Hasta hoy, las dos últimas columnas del historial de ventas enseñaban el
-- estado de cada cuota: Pendiente / En mora / Pagado. Es información del
-- cliente con Ronda, y en la pantalla de un local se lee como lo contrario de
-- lo que significa: **un "En mora" rojo sobre una venta propia parece decir
-- "esto no te lo van a pagar"**, cuando la liquidación no depende de que el
-- cliente pague (docs/05 §3). La pantalla llevaba una nota debajo desactivando
-- esa lectura, que es la señal de que la columna estaba contestando la pregunta
-- equivocada.
--
-- La pregunta que sí trae el dueño es **cuándo entra ese dinero**, y desde el
-- cierre semanal (20260902120000) tiene una respuesta exacta y con fecha:
--
--     cuota que vence el viernes 4  →  se cobra en el cierre del LUNES 7
--
-- Es `helios_settlement_run_for(due_date)`: el primer lunes estrictamente
-- posterior al vencimiento. Se calcula aquí y no en el panel a propósito — el
-- calendario del cierre vive en una sola función, y el día que se mueva no
-- puede quedarse una pantalla con el de antes.
--
-- ---------------------------------------------------------------------------
-- El caso que obliga a devolver NULL
-- ---------------------------------------------------------------------------
-- Las ventas del 30-ago al 2-sep se liquidaron enteras el día del cobro
-- (`upfront_pct = 100`), pero sus cuotas siguen venciendo y siguen saliendo en
-- este historial. Ponerles una fecha de cierre sería prometer por segunda vez
-- un dinero ya entregado. Para esas, `cuota_N_run` viene en null y la pantalla
-- dice "con la venta".
--
-- La condición es la misma que el techo del cron: si el adelanto ya cubre el
-- neto del consumo, no hay tramo por cuota que cobrar. Y se comprueba antes si
-- el tramo EXISTE, porque un tramo ya encolado manda sobre cualquier deducción.
-- ============================================================================

-- Cambia la lista de columnas, así que no basta un `create or replace`.
drop function if exists public.merchant_transactions(date, date, integer);

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
  cuota_1_due       date,
  /** El lunes en que el comercio cobra esa cuota. Null si ya la cobró con la venta. */
  cuota_1_run       date,
  cuota_2_due       date,
  cuota_2_run       date
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
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
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale,
           -- El neto contra el que se liquida, que es el que usa el cron. Con
           -- comisión cero coincide con la venta; se lee de su columna igual,
           -- porque la comisión es negociable y el día que alguien pacte una,
           -- las dos cifras vuelven a separarse.
           coalesce(c.merchant_net_usd, c.amount_usd) as net
    from public.charges c
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status = 'confirmed'
      and c.business_date between p_from and p_to
    order by c.business_date desc, c.confirmed_at desc
    limit v_limit
  ),
  -- Una fila por cuota de la orden. En un cobro de grupo hay una cuota POR
  -- PERSONA venciendo el mismo día, y todas hablan de la misma venta: al
  -- comercio se le paga por consumo y fecha, no por deudor, así que la fecha
  -- de cobro es una sola por muchos que se repartieran la cuenta.
  cuotas as (
    select i.charge_id     as cid,
           i.sequence      as seq,
           min(i.due_date) as due
    from public.installments i
    join mias m on m.id = i.charge_id
    group by i.charge_id, i.sequence
  ),
  adelantos as (
    select s.charge_id as cid, sum(s.amount_usd) as usd
    from public.settlements s
    join mias m on m.id = s.charge_id
    where s.reason = 'advance'
    group by s.charge_id
  ),
  cobros as (
    select k.cid,
           k.seq,
           k.due,
           case
             -- Única excepción: el adelanto ya cubrió el neto del consumo y no
             -- hay tramo encolado para esta fecha. Es la venta liquidada entera
             -- el día del cobro; no queda nada que cobrar por esta cuota. El
             -- tramo encolado se comprueba primero porque manda sobre cualquier
             -- deducción: si existe, se cobra, y se cobra en su cierre.
             when coalesce(a.usd, 0) >= m.net
              and not exists (
                    select 1 from public.settlements s
                    where s.charge_id = k.cid
                      and s.reason = 'scheduled_installment'
                      and s.business_date = k.due
                  )
               then null
             else public.helios_settlement_run_for(k.due)
           end as run
    from cuotas k
    join mias m on m.id = k.cid
    left join adelantos a on a.cid = k.cid
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
         c1.due,
         c1.run,
         c2.due,
         c2.run
  from mias m
  left join quienes q on q.cid = m.id
  left join cobros c1 on c1.cid = m.id and c1.seq = 1
  left join cobros c2 on c2.cid = m.id and c2.seq = 2
  order by m.bdate desc, m.conf desc;
end;
$$;

comment on function public.merchant_transactions(date, date, integer) is
  'Historial de ordenes del comercio por dia operativo, con el lunes de cierre en que cobra cada cuota. No expone quien es el cliente ni como va su deuda.';

revoke all on function public.merchant_transactions(date, date, integer) from public, anon;
grant execute on function public.merchant_transactions(date, date, integer) to authenticated;
