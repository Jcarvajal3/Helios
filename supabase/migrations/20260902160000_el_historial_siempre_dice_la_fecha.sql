-- ============================================================================
-- Ronda — El historial del comercio siempre dice la fecha, sin excepciones
--
-- 20260902131000 devolvía `cuota_N_run` en null para las ventas del 30-ago al
-- 2-sep, que se liquidaron enteras el día del cobro (`upfront_pct = 100`): la
-- idea era no prometer por segunda vez un dinero ya entregado, y la pantalla
-- ponía "Con la venta" en vez de una fecha.
--
-- **En pantalla no se entendía.** Una columna que a veces trae una fecha y a
-- veces una frase obliga al dueño a aprenderse un caso de borde de tres días
-- para leer su propio historial, y con las dos cuotas en "Con la venta" la
-- tabla no contestaba la única pregunta que venía a hacer. La excepción costaba
-- más de lo que evitaba.
--
-- Ahora la columna dice **siempre** el lunes de cierre que corresponde a esa
-- cuota, que es una función pura de su vencimiento y no depende de nada más:
--
--     cuota que vence el viernes 4  →  cierre del LUNES 7
--
-- ⚠️ **Consecuencia asumida:** las ventas de esos tres días de agosto enseñan
-- una fecha de cobro como cualquier otra, aunque su dinero ya entró con la
-- venta. Son consumos de desarrollo, anteriores al cierre semanal, y no vale la
-- pena arrastrar una rama en el RPC y una frase rara en la tabla por ellos.
-- ============================================================================

-- La lista de columnas no cambia —solo el cuerpo del `case`— así que un
-- `create or replace` basta y no hace falta volver a otorgar permisos.

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
  /** El lunes de cierre en que el comercio cobra esa cuota. */
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
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale
    from public.charges c
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status = 'confirmed'
      and c.business_date between p_from and p_to
    order by c.business_date desc, c.confirmed_at desc
    limit v_limit
  ),
  -- Una fila por cuota de la orden, con el lunes en que se cobra.
  --
  -- En un cobro de grupo la cuota es una POR PERSONA pero todas vencen el mismo
  -- día y hablan de la misma venta: al comercio se le paga por consumo y fecha,
  -- no por deudor, así que la fecha de cobro es una sola por muchos que se
  -- repartieran la cuenta.
  cuotas as (
    select i.charge_id                                            as cid,
           i.sequence                                             as seq,
           min(i.due_date)                                        as due,
           public.helios_settlement_run_for(min(i.due_date))       as run
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
         c1.due,
         c1.run,
         c2.due,
         c2.run
  from mias m
  left join quienes q on q.cid = m.id
  left join cuotas c1 on c1.cid = m.id and c1.seq = 1
  left join cuotas c2 on c2.cid = m.id and c2.seq = 2
  order by m.bdate desc, m.conf desc;
end;
$$;

comment on function public.merchant_transactions(date, date, integer) is
  'Historial de ordenes del comercio por dia operativo, con el lunes de cierre en que cobra cada cuota. No expone quien es el cliente ni como va su deuda.';
