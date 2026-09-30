-- ===========================================================================
-- El local se lleva sus ventas a contabilidad
-- ===========================================================================
-- El panel del local enseña las ventas en pantalla, y hasta ahí llega: para
-- declarar, para cuadrar con el banco o para que un auditor las revise, hay
-- que poder SACARLAS. Hoy la única salida es copiar la tabla a mano, que
-- además solo trae siete de las veintitantas cifras que tiene una venta.
--
-- ---------------------------------------------------------------------------
-- Qué lleva y por qué
-- ---------------------------------------------------------------------------
-- Una venta de Ronda tiene TRES partes que en contabilidad no son la misma
-- cosa y que en pantalla se resumen en dos columnas:
--
--   1. LA VENTA DEL LOCAL — su base imponible y su IVA. Es lo que el local
--      declara como ingreso. Es lo único suyo.
--   2. EL FEE DEL CONSUMIDOR — lo que Ronda le cobra al cliente por financiar,
--      con su IVA. NO es ingreso del local, pero viaja dentro de lo que el
--      cliente pagó, así que sin él la cuenta del cliente no cuadra.
--   3. LA COMISIÓN DEL LOCAL — lo que Ronda le factura al local, con su IVA.
--      Es un GASTO del local y le llega como factura de Ronda: tiene que poder
--      cruzarla contra estas filas.
--
-- Y las tres, en euros y en bolívares a la tasa BCV DEL DÍA DE LA VENTA —no la
-- de hoy—, porque los libros en Venezuela se llevan en bolívares y la tasa de
-- hoy convertiría una venta de marzo a precio de septiembre.
--
-- ---------------------------------------------------------------------------
-- Dos granos, dos funciones
-- ---------------------------------------------------------------------------
-- `merchant_sales_export`       una fila por ORDEN. Es el libro de ventas.
-- `merchant_sales_export_items` una fila por PRODUCTO vendido. Es el detalle
--                               que pide quien cruza contra inventario.
--
-- Mezclarlos en una sola tabla obligaría a repetir el importe de la orden en
-- cada línea, y entonces sumar la columna daría de más. Un CSV cuya columna
-- de dinero no se puede sumar no sirve para contabilidad.
--
-- ---------------------------------------------------------------------------
-- Solo el gerente
-- ---------------------------------------------------------------------------
-- La pantalla de Ventas la ve también el cajero, pero esto lleva la comisión
-- que Ronda le cobra al local y lo que se le ha liquidado: es la misma clase
-- de dato que Métricas y Liquidaciones, que ya son del gerente.
--
-- ---------------------------------------------------------------------------
-- No se recorta en silencio
-- ---------------------------------------------------------------------------
-- `merchant_transactions` corta en 500 filas porque es una pantalla. Aquí no:
-- un libro de ventas incompleto que no dice que lo está es peor que no tener
-- libro. Si el rango no cabe, revienta pidiendo un rango más corto.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. El guarda y el tope, compartidos por las dos
-- ---------------------------------------------------------------------------
create or replace function public.helios_assert_sales_export(
  p_from  date,
  p_to    date,
  p_count bigint,
  p_max   integer
)
returns void
language plpgsql
immutable
as $$
begin
  if p_from is null or p_to is null then
    raise exception 'Hacen falta las dos fechas del rango' using errcode = '22023';
  end if;

  if p_from > p_to then
    raise exception 'El rango está al revés: «desde» es posterior a «hasta»'
      using errcode = '22023';
  end if;

  if p_count > p_max then
    raise exception
      'El rango tiene % filas y el tope de una descarga es %. Pide un rango más corto —por meses suele bastar.',
      p_count, p_max
      using errcode = '22023';
  end if;
end;
$$;

revoke all on function public.helios_assert_sales_export(date, date, bigint, integer)
  from public, anon;
grant execute on function public.helios_assert_sales_export(date, date, bigint, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El libro de ventas: una fila por orden
-- ---------------------------------------------------------------------------
create or replace function public.merchant_sales_export(
  p_from date,
  p_to   date
)
returns table (
  -- Identificación
  order_number        bigint,
  charge_id           uuid,
  business_date       date,
  confirmed_at        timestamptz,
  branch_name         text,
  cashier             text,
  status              text,
  void_reason         text,

  -- Lo que se vendió
  group_name          text,
  payer_count         integer,
  item_count          integer,

  -- La venta del local, en euros
  base_eur            numeric,
  vat_pct             numeric,
  vat_eur             numeric,
  sale_eur            numeric,

  -- El fee que Ronda le cobra al CLIENTE (no es ingreso del local)
  consumer_fee_pct    numeric,
  consumer_fee_eur    numeric,
  consumer_fee_vat_eur numeric,
  charged_to_customer_eur numeric,

  -- La comisión que Ronda le factura al LOCAL (gasto del local)
  merchant_fee_pct    numeric,
  merchant_fee_eur    numeric,
  merchant_fee_vat_eur numeric,
  net_to_merchant_eur numeric,

  -- Lo mismo en bolívares, a la tasa del día de la venta
  fx_rate             numeric,
  sale_ves            numeric,
  charged_to_customer_ves numeric,
  net_to_merchant_ves numeric,

  -- Cuándo cobra el local
  cuota_1_due         date,
  cuota_1_run         date,
  cuota_2_due         date,
  cuota_2_run         date,
  settled_eur         numeric,
  paid_eur            numeric,

  is_test             boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_max      integer := 20000;
  v_count    bigint;
begin
  if v_merchant is null then
    raise exception 'Solo el gerente del local puede descargar sus ventas'
      using errcode = '42501';
  end if;

  select count(*) into v_count
  from public.charges c
  where c.merchant_id = v_merchant
    and c.business_date between p_from and p_to
    and c.status in ('confirmed', 'reverted');

  perform public.helios_assert_sales_export(p_from, p_to, v_count, v_max);

  return query
  with ventas as (
    -- Confirmadas Y revertidas. Una venta deshecha no puede DESAPARECER del
    -- libro: se anotó, movió dinero y se anuló, y eso es justo lo que un
    -- auditor viene a ver. Las `pending` y las `voided` no entran: un QR que
    -- nadie escaneó nunca llegó a ser una venta.
    select c.*,
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale,
           public.current_fx_rate('BCV', c.business_date) as rate
    from public.charges c
    where c.merchant_id = v_merchant
      and c.business_date between p_from and p_to
      and c.status in ('confirmed', 'reverted')
  ),
  cuotas as (
    select i.charge_id as cid,
           i.sequence  as seq,
           min(i.due_date) as due,
           public.helios_settlement_run_for(min(i.due_date)) as run
    from public.installments i
    join ventas v on v.id = i.charge_id
    group by i.charge_id, i.sequence
  ),
  deudores as (
    select i.charge_id as cid, count(distinct i.user_id)::integer as n
    from public.installments i
    join ventas v on v.id = i.charge_id
    group by i.charge_id
  ),
  lineas as (
    select ci.charge_id as cid, count(*)::integer as n
    from public.charge_items ci
    join ventas v on v.id = ci.charge_id
    group by ci.charge_id
  ),
  liquidado as (
    select s.charge_id as cid,
           sum(s.amount_usd) as programado,
           sum(coalesce(s.paid_usd, 0)) as pagado
    from public.settlements s
    join ventas v on v.id = s.charge_id
    group by s.charge_id
  )
  select
    v.order_number,
    v.id,
    v.business_date,
    v.confirmed_at,
    b.name,
    -- Quién tecleó el cobro. El nombre del perfil si lo hay, y si no el
    -- correo de la cuenta del panel: entre las dos siempre hay algo.
    coalesce(p.full_name, au.raw_user_meta_data ->> 'full_name', au.email),
    v.status::text,
    v.void_reason,

    v.group_name,
    coalesce(d.n, 1),
    coalesce(l.n, 0),

    round(coalesce(v.base_usd, 0), 2),
    coalesce(v.vat_pct, 0),
    round(coalesce(v.vat_usd, 0), 2),
    round(v.sale, 2),

    coalesce(v.consumer_fee_pct, 0),
    round(coalesce(v.consumer_fee_usd, 0), 2),
    round(coalesce(v.consumer_fee_vat_usd, 0), 2),
    round(v.amount_usd, 2),

    coalesce(v.merchant_fee_pct, 0),
    round(coalesce(v.merchant_fee_usd, 0), 2),
    round(coalesce(v.merchant_fee_vat_usd, 0), 2),
    round(coalesce(v.merchant_net_usd, v.sale), 2),

    v.rate,
    round(v.sale * v.rate, 2),
    round(v.amount_usd * v.rate, 2),
    round(coalesce(v.merchant_net_usd, v.sale) * v.rate, 2),

    c1.due, c1.run,
    c2.due, c2.run,
    round(coalesce(s.programado, 0), 2),
    round(coalesce(s.pagado, 0), 2),

    v.is_test
  from ventas v
  left join public.merchant_branches b on b.id = v.branch_id
  left join auth.users au on au.id = v.requested_by
  left join public.profiles p on p.id = v.requested_by
  left join deudores d on d.cid = v.id
  left join lineas l on l.cid = v.id
  left join liquidado s on s.cid = v.id
  left join cuotas c1 on c1.cid = v.id and c1.seq = 1
  left join cuotas c2 on c2.cid = v.id and c2.seq = 2
  -- Ascendente, al revés que la pantalla: un libro se lee del primer día al
  -- último, y así la hoja de cálculo ya viene en orden cronológico.
  order by v.business_date, v.confirmed_at, v.order_number;
end;
$$;

comment on function public.merchant_sales_export(date, date) is
  'Libro de ventas del local: una fila por orden, con el desglose fiscal en euros y en bolivares a la tasa del dia. Solo el gerente.';

revoke all on function public.merchant_sales_export(date, date) from public, anon;
grant execute on function public.merchant_sales_export(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El detalle: una fila por producto vendido
-- ---------------------------------------------------------------------------
-- Los importes de la LÍNEA son los del catálogo, con IVA dentro y sin el fee
-- del consumidor: es lo que el local le puso de precio. La suma de las líneas
-- de una orden da su venta, no lo que pagó el cliente.
create or replace function public.merchant_sales_export_items(
  p_from date,
  p_to   date
)
returns table (
  order_number   bigint,
  charge_id      uuid,
  business_date  date,
  confirmed_at   timestamptz,
  branch_name    text,
  status         text,
  line_no        smallint,
  product_id     uuid,
  product_name   text,
  quantity       integer,
  unit_price_eur numeric,
  line_total_eur numeric,
  fx_rate        numeric,
  line_total_ves numeric
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_max      integer := 50000;
  v_count    bigint;
begin
  if v_merchant is null then
    raise exception 'Solo el gerente del local puede descargar sus ventas'
      using errcode = '42501';
  end if;

  select count(*) into v_count
  from public.charge_items ci
  join public.charges c on c.id = ci.charge_id
  where c.merchant_id = v_merchant
    and c.business_date between p_from and p_to
    and c.status in ('confirmed', 'reverted');

  perform public.helios_assert_sales_export(p_from, p_to, v_count, v_max);

  return query
  select
    c.order_number,
    c.id,
    c.business_date,
    c.confirmed_at,
    b.name,
    c.status::text,
    ci.position,
    ci.product_id,
    ci.name,
    ci.quantity,
    round(ci.unit_price_usd, 2),
    round(ci.line_total_usd, 2),
    r.rate,
    round(ci.line_total_usd * r.rate, 2)
  from public.charge_items ci
  join public.charges c on c.id = ci.charge_id
  left join public.merchant_branches b on b.id = c.branch_id
  left join lateral (
    select public.current_fx_rate('BCV', c.business_date) as rate
  ) r on true
  where c.merchant_id = v_merchant
    and c.business_date between p_from and p_to
    and c.status in ('confirmed', 'reverted')
  order by c.business_date, c.confirmed_at, c.order_number, ci.position;
end;
$$;

comment on function public.merchant_sales_export_items(date, date) is
  'Detalle de lo vendido: una fila por producto de cada orden. Solo el gerente.';

revoke all on function public.merchant_sales_export_items(date, date) from public, anon;
grant execute on function public.merchant_sales_export_items(date, date) to authenticated;
