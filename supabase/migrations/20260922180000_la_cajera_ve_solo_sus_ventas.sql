-- ===========================================================================
-- La cajera ve solo sus ventas
-- ===========================================================================
-- Decisión de Javier (2026-09-22): en Ventas, quien no es gerente ve lo que
-- cobró ÉL — la lista, las cifras de arriba y la ficha de cada orden — y no
-- las del local entero. El gerente sigue viéndolo todo.
--
-- Deroga el «entre dos cajeras y un total del local, cualquiera puede restar;
-- se asume» de 20260921160000: ya no hay total del local que restar.
--
-- La regla es la de `merchant_sales_by_staff`, en una línea y fila a fila:
--
--   c.merchant_id = my_merchant_id_as_gerente()  or  c.requested_by = auth.uid()
--
-- Con `my_merchant_id_as_gerente()` nulo la primera comparación da null, así
-- que quien no es gerente cae siempre en la segunda.
--
-- Va en la base y no en el panel: esconderlo solo en pantalla dejaría las
-- ventas del local a un `rpc()` de distancia desde la consola del navegador.
--
-- Compatible hacia atrás: ninguna firma cambia y `merchant_transactions_summary`
-- solo gana la clave `scope`. Un panel sin actualizar sigue funcionando, con
-- las cifras ya recortadas.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. La lista de ventas
-- ---------------------------------------------------------------------------
-- Copia de 20260921160000 con el filtro marcado NUEVO. La firma no cambia, así
-- que basta `create or replace` y los permisos siguen puestos.
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
  /** El nombre de quien compró, y nada más de esa persona (20260919120000). */
  customer_name     text,
  /**
   * QUIÉN DEL LOCAL SACÓ ESTE COBRO.
   *
   * Sale de `charges.requested_by`, que se escribe en `request_charge`. Es la
   * cuenta que generó el QR, no quien lo escaneó: en un cobro de grupo la
   * venta es de esta persona por mucho que la cuenta se reparta entre cinco.
   *
   * Null cuando quien mira no puede saberlo: para un cajero, en las ventas de
   * sus compañeros. La suya sí la ve — reconocer el propio trabajo en la lista
   * es la mitad del asunto.
   */
  staff_name        text,
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
  v_limit      integer := greatest(least(coalesce(p_limit, 500), 500), 1);
  v_gerente_de uuid    := public.my_merchant_id_as_gerente();
  v_me         uuid    := auth.uid();
begin
  return query
  with mias as (
    select c.id,
           c.order_number as num,
           c.business_date as bdate,
           c.confirmed_at as conf,
           c.amount_usd as charged,
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale,
           c.user_id as quien,
           c.merchant_id as local,
           c.requested_by as cobro
    from public.charges c
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status = 'confirmed'
      and c.business_date between p_from and p_to
      -- NUEVO: el gerente de ESE comercio ve todas; cualquier otro, solo las
      -- que cobró él.
      and (c.merchant_id = v_gerente_de or c.requested_by = v_me)
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
         p.full_name,
         -- La misma regla que el resumen, fila a fila: el gerente de ese local
         -- lo ve siempre; los demás, solo en lo que cobraron ellos.
         case when m.local = v_gerente_de or m.cobro = v_me
              then public.helios_staff_name(m.cobro) end,
         c1.due,
         c1.run,
         c2.due,
         c2.run
  from mias m
  left join public.profiles p on p.id = m.quien
  left join quienes q on q.cid = m.id
  left join cuotas c1 on c1.cid = m.id and c1.seq = 1
  left join cuotas c2 on c2.cid = m.id and c2.seq = 2
  order by m.bdate desc, m.conf desc;
end;
$$;

revoke all on function public.merchant_transactions(date, date, integer) from public, anon;
grant execute on function public.merchant_transactions(date, date, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Las cifras de arriba
-- ---------------------------------------------------------------------------
-- Copia de 20260919120000 con el filtro y `scope`. `scope` lo lee el panel
-- para rotular las cifras: con 'self' son las de quien mira, no las del local.
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
  v_gerente_de uuid    := public.my_merchant_id_as_gerente();
  v_me         uuid    := auth.uid();
  v_orders     integer := 0;
  v_sale       numeric := 0;
  v_charged    numeric := 0;
  v_days       integer := 0;
begin
  select
    count(*)::integer,
    coalesce(sum(public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd)), 0),
    coalesce(sum(c.amount_usd), 0),
    count(distinct c.business_date)::integer
  into v_orders, v_sale, v_charged, v_days
  from public.charges c
  where c.merchant_id in (select public.my_merchant_ids())
    and c.status = 'confirmed'
    and c.business_date between p_from and p_to
    -- NUEVO
    and (c.merchant_id = v_gerente_de or c.requested_by = v_me);

  return jsonb_build_object(
    'scope',          case when v_gerente_de is null then 'self' else 'gerente' end,
    'order_count',    v_orders,
    'sale_usd',       round(v_sale, 2),
    'charged_usd',    round(v_charged, 2),
    'avg_ticket_usd', public.helios_avg_ticket_usd(v_sale, v_orders),
    'active_days',    v_days
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. La ficha de una orden
-- ---------------------------------------------------------------------------
-- Copia de 20260921160000 con el guarda marcado NUEVO. Sin él, la cajera no
-- vería las órdenes ajenas en la lista pero podría abrirlas por URL.
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
  select * into v_charge from public.charges where id = p_charge_id;

  -- El mismo error exista o no la orden: con dos mensajes distintos, probar
  -- identificadores a ciegas diría cuáles son de otro local.
  if not found or v_charge.merchant_id not in (select public.my_merchant_ids()) then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  v_gerente := public.my_merchant_id_as_gerente() = v_charge.merchant_id;

  -- NUEVO: quien no es gerente solo abre las órdenes que cobró. El mismo
  -- error que una orden que no existe, por lo mismo de arriba.
  if not coalesce(v_gerente, false) and v_charge.requested_by is distinct from auth.uid() then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'charge_id', c.id,
    'order_number', c.order_number,
    'status', c.status::text,
    'business_date', c.business_date,
    'created_at', c.created_at,
    'confirmed_at', c.confirmed_at,
    'void_reason', c.void_reason,
    'is_test', c.is_test,
    -- EL NOMBRE DE QUIEN COMPRÓ, y nada más de esa persona. Sin tapar por
    -- rol: el cajero es justo quien la atendió. Null mientras nadie haya
    -- escaneado el QR.
    'customer_name', p.full_name,
    -- QUIÉN LA COBRÓ. El gerente lo ve siempre; el cajero, en las suyas.
    'staff_name', case when v_gerente or c.requested_by = auth.uid()
                       then public.helios_staff_name(c.requested_by) end,
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
  left join public.profiles p on p.id = c.user_id
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
