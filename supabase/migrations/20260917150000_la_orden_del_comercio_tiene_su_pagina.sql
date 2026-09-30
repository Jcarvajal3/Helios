-- ============================================================================
-- Ronda — Una orden del comercio se puede abrir
--
-- El historial del local es una tabla de siete columnas y punto final: el
-- número de orden está ahí, pero lo que se vendió —las líneas que el propio
-- cajero tecleó— no se podía consultar después de cerrar la pantalla del QR.
-- La llamada que llega es «¿qué incluía la orden 1043?», y hoy se contesta
-- abriendo la caja registradora del local, no el panel de Ronda.
--
-- ---------------------------------------------------------------------------
-- Lo que SÍ ve el comercio, y lo que no
-- ---------------------------------------------------------------------------
-- Su venta, lo que se le cobró al cliente, las líneas y cuándo se le paga cada
-- mitad. **No** las cuotas del cliente: cómo va esa deuda es asunto entre el
-- cliente y Ronda (docs/05 §3), y un «en mora» en la pantalla de un local se
-- lee como «esto no me lo van a pagar» cuando es al revés. Tampoco quién es el
-- cliente, ni cuánto puso cada integrante de una cuenta repartida.
--
-- ---------------------------------------------------------------------------
-- El dinero del local es del gerente
-- ---------------------------------------------------------------------------
-- La misma línea que ya traza la RLS de `settlements` y que
-- `SECTIONS_BY_ROLE` copia en el panel: el cajero ve la venta y las fechas de
-- cobro —las tiene ya en la lista—, y los importes de liquidación y lo que se
-- le paga al local solo el gerente. Se decide aquí y no en el navegador.
--
-- Solo lectura. No toca ni un dato.
-- ============================================================================

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

comment on function public.merchant_charge_detail(uuid) is
  'La ficha de una orden para el local: su venta, lo cobrado al cliente, las lineas y cuando se le paga cada mitad. No expone las cuotas del cliente, ni quien es, ni el reparto de una cuenta de grupo. Los importes de liquidacion solo al gerente.';

revoke all on function public.merchant_charge_detail(uuid) from public, anon;
grant execute on function public.merchant_charge_detail(uuid) to authenticated;
