-- ============================================================================
-- Ronda — Las ventas del local son del gerente
--
-- El cajero tenía «Ventas» en su barra: la lista de todo lo vendido en el
-- local, con los importes de cada orden y los totales del periodo. Quien está
-- en la barra necesita cobrar; lo que factura el negocio es del dueño.
-- Decisión de Javier, 2026-09-18.
--
-- El panel ya le esconde la pestaña, pero eso solo tapa la puerta: las rutas
-- `/transacciones` y `/transacciones/<id>` se escriben a mano, y las tres RPC
-- que las alimentan pedían únicamente ser «personal del comercio» —cualquier
-- rol—. Sin este cambio, quitar la pestaña habría sido pintura.
--
-- El corte es `my_merchant_id_as_gerente()`, el mismo que ya usan las métricas
-- y el que reparte por rol los campos de la orden. Nada más cambia en las tres
-- funciones: el resto es copia literal de su última versión.
--
-- Lo que el cajero conserva: cobrar, y su propia cuenta.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La lista de ventas
-- ---------------------------------------------------------------------------
-- Copiada de 20260902160000_el_historial_siempre_dice_la_fecha.sql salvo el
-- bloque marcado NUEVO.

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
  -- NUEVO (2026-09-18): las ventas del local son del gerente.
  --
  -- Pedía «personal del comercio» y con eso entraba el cajero, que hasta hoy
  -- tenía la pestaña Ventas en su barra. Quitarle la pestaña sin tocar esto
  -- habría sido pintura: la URL seguía abriendo la pantalla y la RPC seguía
  -- contestando con todo lo vendido en el local.
  if public.my_merchant_id_as_gerente() is null then
    raise exception 'Las ventas del local las ve el gerente' using errcode = '42501';
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

-- ---------------------------------------------------------------------------
-- 2. Los totales del periodo
-- ---------------------------------------------------------------------------
-- Copiada de 20260830250000_ordenes_recurrencia_y_el_estado_de_las_cuotas.sql
-- salvo el bloque marcado NUEVO. Va con la lista: separar el candado de los
-- totales del de las filas deja la mitad de la pantalla abierta.

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
  -- NUEVO (2026-09-18): las ventas del local son del gerente.
  --
  -- Pedía «personal del comercio» y con eso entraba el cajero, que hasta hoy
  -- tenía la pestaña Ventas en su barra. Quitarle la pestaña sin tocar esto
  -- habría sido pintura: la URL seguía abriendo la pantalla y la RPC seguía
  -- contestando con todo lo vendido en el local.
  if public.my_merchant_id_as_gerente() is null then
    raise exception 'Las ventas del local las ve el gerente' using errcode = '42501';
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

-- ---------------------------------------------------------------------------
-- 3. La página de una orden
-- ---------------------------------------------------------------------------
-- Copiada de 20260917150000_la_orden_del_comercio_tiene_su_pagina.sql salvo el
-- bloque marcado NUEVO. El reparto de campos por rol de dentro se queda como
-- está: hoy solo entra el gerente, pero si mañana se vuelve a abrir, la regla
-- de qué ve cada uno sigue escrita donde estaba.

create or replace function public.merchant_charge_detail(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_charge  public.charges%rowtype;
  v_gerente boolean;
  v_out     jsonb;
begin
  -- NUEVO (2026-09-18): la página de una orden es parte de Ventas, y Ventas
  -- es del gerente. Va ANTES de leer nada: así un cajero no puede ni probar
  -- identificadores para saber cuáles existen.
  if public.my_merchant_id_as_gerente() is null then
    raise exception 'Las ventas del local las ve el gerente' using errcode = '42501';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;

  -- El mismo error exista o no la orden: con dos mensajes distintos, probar
  -- identificadores a ciegas diría cuáles son de otro local.
  if not found or v_charge.merchant_id not in (select public.my_merchant_ids()) then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  v_gerente := public.my_merchant_id_as_gerente() = v_charge.merchant_id;

  select jsonb_build_object(
    'charge_id', c.id,
    'order_number', c.order_number,
    'status', c.status::text,
    'business_date', c.business_date,
    'created_at', c.created_at,
    'confirmed_at', c.confirmed_at,
    'void_reason', c.void_reason,
    'is_test', c.is_test,
    -- TU VENTA: la del comercio con su IVA dentro. No es `amount_usd`, que
    -- desde la facturación por cuenta de terceros es lo que debe el
    -- consumidor (docs/00-BASES §2.11).
    'merchant_sale_usd', public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd),
    'base_usd', c.base_usd,
    'vat_usd', c.vat_usd,
    -- LO QUE PAGA EL CLIENTE, con el servicio de Ronda y su IVA dentro.
    'amount_usd', c.amount_usd,
    'consumer_fee_usd', c.consumer_fee_usd,
    'consumer_fee_vat_usd', c.consumer_fee_vat_usd,
    -- Lo que se le paga al local, y lo que Ronda le cobra a él. Del gerente.
    'merchant_fee_usd', case when v_gerente then c.merchant_fee_usd end,
    'merchant_fee_vat_usd', case when v_gerente then c.merchant_fee_vat_usd end,
    'merchant_net_usd', case when v_gerente then c.merchant_net_usd end,
    'is_gerente', v_gerente,
    'branch', case when b.id is null then null else jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address
    ) end
  )
  into v_out
  from public.charges c
  left join public.merchant_branches b on b.id = c.branch_id
  where c.id = p_charge_id;

  -- Qué se vendió, en el orden en que lo tecleó el cajero.
  v_out := v_out || jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', ci.name,
      'quantity', ci.quantity,
      'unit_price_usd', ci.unit_price_usd,
      'line_total_usd', ci.line_total_usd
    ) order by ci.position, ci.created_at)
    from public.charge_items ci where ci.charge_id = p_charge_id
  ), '[]'::jsonb));

  -- Entre cuántos se repartió la cuenta. Sigue siendo UNA orden y UNA venta:
  -- se dice porque explica el «entre 4» del que habla el cliente, no porque
  -- cambie nada de lo que el local cobra.
  v_out := v_out || jsonb_build_object('payer_count', (
    select count(distinct i.user_id)::integer
    from public.installments i where i.charge_id = p_charge_id
  ));

  /**
   * CUÁNDO SE LE PAGA AL LOCAL CADA MITAD.
   *
   * La fecha es el lunes de cierre que corresponde al vencimiento, y la
   * calcula `helios_settlement_run_for`: el calendario del cierre vive en un
   * solo sitio y no repartido entre las pantallas que lo pintan.
   *
   * El importe viene de `settlements` **cuando ya existe la fila**, que es al
   * vencer la cuota (`run_scheduled_settlements`). Antes de eso se manda en
   * null en vez de estimarlo: el reparto por tramos y el residuo del último
   * los decide esa función, y una segunda copia de esa aritmética aquí sería
   * la tercera cifra para la misma pregunta.
   *
   * En un cobro de grupo hay una cuota POR PERSONA venciendo el mismo día y
   * todas hablan de la misma venta —al comercio se le paga por consumo y
   * fecha, no por deudor—, así que se agrupa por `sequence` y sale una fila
   * por mitad, no por integrante.
   */
  v_out := v_out || jsonb_build_object('payouts', coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', x.kind,
      'sequence', x.seq,
      'due_date', x.due,
      'run_date', public.helios_settlement_run_for(x.due),
      'amount_usd', case when v_gerente then x.amount end,
      'paid_usd', case when v_gerente then x.paid end,
      'status', case when v_gerente then x.status end
    ) order by x.due, x.seq nulls first)
    from (
      -- El adelanto al vender, si el local lo tiene pactado.
      select 'advance'::text    as kind,
             null::smallint     as seq,
             s.due_date         as due,
             s.amount_usd       as amount,
             s.paid_usd         as paid,
             s.status::text     as status
      from public.settlements s
      where s.charge_id = p_charge_id and s.reason = 'advance'

      union all

      select 'installment',
             m.seq,
             m.due,
             s.amount_usd,
             s.paid_usd,
             s.status::text
      from (
        select i.sequence as seq, min(i.due_date) as due
        from public.installments i
        where i.charge_id = p_charge_id
        group by i.sequence
      ) m
      left join public.settlements s
        on s.charge_id = p_charge_id
       and s.reason = 'scheduled_installment'
       and s.business_date = m.due
    ) x
  ), '[]'::jsonb));

  return v_out;
end;
$$;

-- Los privilegios sobreviven a un `create or replace`; se repiten como en el
-- resto del repo.
revoke all on function public.merchant_transactions(date, date, integer) from public, anon;
grant execute on function public.merchant_transactions(date, date, integer) to authenticated;

revoke all on function public.merchant_transactions_summary(date, date) from public, anon;
grant execute on function public.merchant_transactions_summary(date, date) to authenticated;

revoke all on function public.merchant_charge_detail(uuid) from public, anon;
grant execute on function public.merchant_charge_detail(uuid) to authenticated;
