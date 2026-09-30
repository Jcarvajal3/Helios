-- ============================================================================
-- Ronda — Facturación por cuenta de terceros: IVA y los dos fees
--
-- Implementa el memo de SC Moreno, Díaz y Asociados del 26-ago-2026, opción 1
-- (Art. 10 de la LIVA). Ronda actúa como **mandatario** del comercio: factura
-- al consumidor por cuenta de aquel y reconoce como ingreso propio solo sus
-- comisiones.
--
-- ---------------------------------------------------------------------------
-- El desglose, con la base que teclea el cajero en 100
-- ---------------------------------------------------------------------------
--     base imponible de los productos ........ 100,00   ← lo que teclea
--     + fee al consumidor (10%) ...............  10,00
--     + IVA de la venta (16%) .................  16,00
--     + IVA del fee (16%) .....................   1,60
--     ─────────────────────────────────────────────────
--     LO QUE VE Y DEBE EL USUARIO ............ 127,60   → dos cuotas de 63,80
--
--     venta del comercio con IVA .............. 116,00
--     − servicio tecnológico (10% + IVA) ......  11,60
--     ─────────────────────────────────────────────────
--     NETO AL COMERCIO ....................... 104,40   → 30% / 35% / 35%
--                                                          31,32 · 36,54 · 36,54
--
--     ingreso propio de Ronda .................  20,00   (los dos fees)
--     IVA que Ronda declara ...................   3,20
--
--     104,40 + 20,00 + 3,20 = 127,60 ✓
--
-- La identidad se cumple SIEMPRE, con cualquier redondeo, porque los fees y
-- sus IVA salen de las mismas dos cifras a los dos lados de la resta.
--
-- ---------------------------------------------------------------------------
-- Por qué `amount_usd` pasa a ser el total del consumidor
-- ---------------------------------------------------------------------------
-- Porque es lo que el usuario debe, y `amount_usd` es la cifra sobre la que
-- gira todo lo suyo: el bloque de crédito, las dos cuotas, el mínimo por
-- persona y el reparto de la mesa. Cambiarla de sitio habría obligado a tocar
-- los seis caminos de cobro; dejándola donde está, lo único que cambia es
-- **contra qué se liquida al comercio** — que ahora es `merchant_net_usd`.
--
-- El desglose se guarda en columnas y no se recalcula al vuelo: los
-- porcentajes son parámetros y van a cambiar, y una factura tiene que poder
-- reimprimirse dentro de dos años con los números con los que se emitió.
--
-- ---------------------------------------------------------------------------
-- Lo que el usuario ve
-- ---------------------------------------------------------------------------
-- **Un solo precio.** El fee se acordó con el comercio y va dentro del precio
-- como si fuera parte del producto: en la app no hay ninguna línea de
-- comisión. En la FACTURA sí aparece separado —es lo que hace que esos 20 sean
-- ingreso de Ronda y no del comercio, y es obligación legal—, pero eso es el
-- documento fiscal, no la pantalla.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Los parámetros
-- ---------------------------------------------------------------------------

/** Alícuota general del IVA en Venezuela. */
create or replace function public.helios_vat_pct()
returns numeric
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 16.00::numeric $fn$;

comment on function public.helios_vat_pct() is
  'Alícuota del IVA aplicada a la venta y a los fees. Ver docs/00-BASES §2.11.';

revoke all on function public.helios_vat_pct() from public, anon;
grant execute on function public.helios_vat_pct() to authenticated;

/**
 * Fee que Ronda cobra al consumidor, como % de la base de los productos.
 *
 * Es global y no por comercio, a diferencia del fee del comercio: lo que paga
 * el usuario por financiar no puede depender del local, o el mismo consumo
 * costaría distinto según dónde se haga y eso es imposible de explicar.
 */
create or replace function public.helios_consumer_fee_pct()
returns numeric
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 10.00::numeric $fn$;

comment on function public.helios_consumer_fee_pct() is
  'Fee al consumidor por comprar a cuotas, como % de la base. Va DENTRO del precio que ve el usuario.';

revoke all on function public.helios_consumer_fee_pct() from public, anon;
grant execute on function public.helios_consumer_fee_pct() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El desglose, en un solo sitio
-- ---------------------------------------------------------------------------
/**
 * Todo lo que se deriva de la base imponible de un consumo.
 *
 * Un único sitio que sepa hacer esta cuenta. Estaba a punto de haber tres —el
 * cobro, la factura y el panel del comercio— y tres sitios que redondean por
 * su cuenta son tres respuestas distintas para la misma venta.
 *
 * El fee del comercio entra por parámetro porque es negociable local a local
 * (`merchant_settlement_terms.commission_pct`); el del consumidor y el IVA
 * salen de sus funciones porque son iguales para todos.
 *
 * Redondeo a DOS decimales y no a cuatro: esto son cifras de factura, y una
 * factura no lleva milésimas. El resto del sistema guarda `numeric(18,4)` por
 * la aritmética interna, pero lo que se imprime nace ya redondeado.
 */
create or replace function public.helios_charge_breakdown(
  p_base_usd          numeric,
  p_merchant_fee_pct  numeric
)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_vat_pct  numeric := public.helios_vat_pct();
  v_cfee_pct numeric := public.helios_consumer_fee_pct();
  v_base     numeric(18,4) := round(p_base_usd, 2);
  v_vat      numeric(18,4);
  v_cfee     numeric(18,4);
  v_cfee_vat numeric(18,4);
  v_mfee     numeric(18,4);
  v_mfee_vat numeric(18,4);
begin
  v_vat      := round(v_base * v_vat_pct / 100, 2);
  v_cfee     := round(v_base * v_cfee_pct / 100, 2);
  v_cfee_vat := round(v_cfee * v_vat_pct / 100, 2);
  v_mfee     := round(v_base * p_merchant_fee_pct / 100, 2);
  v_mfee_vat := round(v_mfee * v_vat_pct / 100, 2);

  return jsonb_build_object(
    'base_usd',             v_base,
    'vat_pct',              v_vat_pct,
    'vat_usd',              v_vat,
    'consumer_fee_pct',     v_cfee_pct,
    'consumer_fee_usd',     v_cfee,
    'consumer_fee_vat_usd', v_cfee_vat,
    -- Lo que debe el usuario. Es lo único que se le enseña.
    'consumer_total_usd',   v_base + v_vat + v_cfee + v_cfee_vat,
    -- La venta del comercio, que es lo que va en la factura por cuenta de
    -- terceros y lo que el comercio declara como suyo.
    'merchant_gross_usd',   v_base + v_vat,
    'merchant_fee_pct',     p_merchant_fee_pct,
    'merchant_fee_usd',     v_mfee,
    'merchant_fee_vat_usd', v_mfee_vat,
    -- Sobre esto se calculan el adelanto y las dos liquidaciones.
    'merchant_net_usd',     v_base + v_vat - v_mfee - v_mfee_vat,
    -- Ingreso propio de Ronda: base imponible de IAE y LOCTI.
    'revenue_usd',          v_cfee + v_mfee,
    -- IVA que Ronda declara como débito fiscal. NO es ingreso.
    'vat_payable_usd',      v_cfee_vat + v_mfee_vat
  );
end;
$$;

revoke all on function public.helios_charge_breakdown(numeric, numeric) from public, anon;
grant execute on function public.helios_charge_breakdown(numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El desglose, guardado en el cobro
-- ---------------------------------------------------------------------------

alter table public.charges
  add column if not exists base_usd             numeric(18,4),
  add column if not exists vat_pct              numeric(5,2),
  add column if not exists vat_usd              numeric(18,4),
  add column if not exists consumer_fee_pct     numeric(5,2),
  add column if not exists consumer_fee_usd     numeric(18,4),
  add column if not exists consumer_fee_vat_usd numeric(18,4),
  add column if not exists merchant_fee_pct     numeric(5,2),
  add column if not exists merchant_fee_usd     numeric(18,4),
  add column if not exists merchant_fee_vat_usd numeric(18,4),
  add column if not exists merchant_net_usd     numeric(18,4);

comment on column public.charges.amount_usd is
  'Lo que DEBE EL CONSUMIDOR: base + IVA + fee + IVA del fee. Es la cifra que se le enseña, la que se parte en dos cuotas y la que se reparte en una mesa.';
comment on column public.charges.base_usd is
  'Base imponible de los productos: lo que teclea el cajero, sin IVA ni fees.';
comment on column public.charges.merchant_net_usd is
  'Lo que se le paga al comercio: su venta con IVA menos el servicio tecnológico con IVA. Sobre esto van el 30% del adelanto y las dos liquidaciones.';

/**
 * Los cobros anteriores al modelo se quedan como se cobraron.
 *
 * Antes no había IVA ni fee al consumidor: `amount_usd` ERA la base, y al
 * comercio se le liquidaba `amount − comisión`. Rellenar así deja a los
 * cobros viejos coherentes con lo que de verdad se les hizo, que es lo único
 * que permite que `run_scheduled_settlements` trate a todos igual sin
 * preguntarse de qué época son.
 */
update public.charges c
set base_usd             = c.amount_usd,
    vat_pct              = 0,
    vat_usd              = 0,
    consumer_fee_pct     = 0,
    consumer_fee_usd     = 0,
    consumer_fee_vat_usd = 0,
    merchant_fee_pct     = coalesce(t.commission_pct, 20),
    merchant_fee_usd     = round(c.amount_usd * coalesce(t.commission_pct, 20) / 100, 4),
    merchant_fee_vat_usd = 0,
    merchant_net_usd     = c.amount_usd - round(c.amount_usd * coalesce(t.commission_pct, 20) / 100, 4)
from public.merchant_settlement_terms t
where t.merchant_id = c.merchant_id
  and c.merchant_net_usd is null;

-- ---------------------------------------------------------------------------
-- 4. Las condiciones del comercio cambian de base
-- ---------------------------------------------------------------------------
/**
 * Antes los tres porcentajes eran del bruto y sumaban 100 con la comisión.
 * Ahora son dos cosas distintas:
 *
 *   · `commission_pct` (10%) es el **servicio tecnológico**, sobre la base.
 *   · `upfront_pct` (30%) y `per_installment_pct` (35%) reparten el **neto**,
 *     y por eso ellos solos suman 100.
 *
 * Mezclarlos en una sola restricción era lo que ataba la comisión al reparto:
 * bajarle la comisión a un comercio obligaba a subirle el adelanto, que no
 * tiene nada que ver.
 */
alter table public.merchant_settlement_terms
  drop constraint if exists settlement_adds_up;

-- Las filas primero, la restricción después.
--
-- Las condiciones que ya existen cumplen la invariante VIEJA —los tres
-- porcentajes sumaban 100 con la comisión dentro— y por definición no cumplen
-- la nueva, donde el adelanto y las cuotas suman 100 entre ellos solos. Poner
-- la restricción antes del `update` aborta la migración en cuanto haya un
-- comercio dado de alta; contra una base vacía pasa sin ruido, que es
-- exactamente lo que la dejó llegar hasta aquí sin que nadie lo notara.
--
-- Los comercios que ya existen pasan al esquema nuevo: 30/35/35 del neto y un
-- 10% de servicio tecnológico, que es lo que dice el memo. Se acota a los que
-- estaban en los valores por defecto de antes A PROPÓSITO — a un comercio con
-- condiciones negociadas no se le inventan otras aquí. Si quedara alguno así,
-- la restricción de abajo detiene la migración y esa conversión se decide a
-- mano: son los términos de un contrato, no un dato derivable.
update public.merchant_settlement_terms
set upfront_pct = 30.00, per_installment_pct = 35.00, commission_pct = 10.00
where upfront_pct = 30.00 and per_installment_pct = 25.00 and commission_pct = 20.00;

alter table public.merchant_settlement_terms
  add constraint settlement_splits_net check (
    upfront_pct + (per_installment_pct * 2) = 100.00
  );

comment on constraint settlement_splits_net on public.merchant_settlement_terms is
  'El adelanto y las dos liquidaciones reparten el NETO del comercio, así que suman 100 entre ellos. La comisión va aparte: es un % de la base, no un trozo del reparto.';

alter table public.merchant_settlement_terms
  alter column per_installment_pct set default 35.00,
  alter column commission_pct set default 10.00;

-- ---------------------------------------------------------------------------
-- 5. El cobro nace con su desglose
-- ---------------------------------------------------------------------------
/**
 * `request_charge` con IVA y fees.
 *
 * El cajero sigue tecleando y cobrando exactamente igual: mete productos y le
 * sale un QR. Lo que cambia es que el total del QR ya no es la suma de las
 * líneas — es la suma de las líneas **más el IVA y el fee**, porque eso es lo
 * que el consumidor debe.
 *
 * El mínimo de $5 se sigue comprobando sobre la BASE y no sobre el total: es
 * una regla sobre lo que vende el comercio, no sobre lo que factura Ronda, y
 * moverla al total la habría relajado en silencio a $3,92 de consumo real.
 */
create or replace function public.request_charge(
  p_merchant_id     uuid,
  p_branch_id       uuid,
  p_items           jsonb,
  p_idempotency_key text
)
returns public.charges
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff   uuid := auth.uid();
  v_row     public.charges%rowtype;
  v_allowed boolean;
  v_item    jsonb;
  v_lines   jsonb := '[]'::jsonb;
  v_qty     integer;
  v_name    text;
  v_price   numeric(18,4);
  v_base    numeric(18,4);
  v_terms   public.merchant_settlement_terms%rowtype;
  v_b       jsonb;
begin
  if v_staff is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select exists (
    select 1 from public.merchant_users
    where user_id = v_staff
      and merchant_id = p_merchant_id
      and is_active
      and (branch_id is null or branch_id = p_branch_id)
  ) into v_allowed;

  if not v_allowed then
    raise exception 'No autorizado a cobrar en este comercio/sucursal' using errcode = '42501';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El cobro no tiene productos' using errcode = '22023';
  end if;

  if jsonb_array_length(p_items) > 100 then
    raise exception 'Demasiadas líneas en un mismo cobro' using errcode = '22023';
  end if;

  -- --- Resolver cada línea contra el catálogo ---------------------------
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_qty := coalesce((v_item->>'quantity')::integer, 1);

    if v_qty < 1 or v_qty > 999 then
      raise exception 'Cantidad no válida: %', v_qty using errcode = '22023';
    end if;

    if nullif(v_item->>'product_id', '') is not null then
      select p.name, p.price_usd into v_name, v_price
      from public.products p
      where p.id = (v_item->>'product_id')::uuid
        and p.merchant_id = p_merchant_id
        and p.is_active;

      if not found then
        raise exception 'Un producto del pedido ya no está en tu carta; quítalo y vuelve a intentar'
          using errcode = '22023';
      end if;
    else
      v_name  := coalesce(nullif(btrim(v_item->>'name'), ''), 'Consumo');
      v_price := (v_item->>'unit_price_usd')::numeric;

      if v_price is null or v_price < 0 then
        raise exception 'Precio no válido en una línea del cobro' using errcode = '22023';
      end if;
    end if;

    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'product_id',     nullif(v_item->>'product_id', ''),
      'name',           v_name,
      'unit_price_usd', v_price,
      'quantity',       v_qty
    ));
  end loop;

  select sum(round((l->>'unit_price_usd')::numeric * (l->>'quantity')::integer, 4))
  into v_base
  from jsonb_array_elements(v_lines) l;

  -- El mínimo se comprueba sobre la BASE que acaba de calcular la base de
  -- datos, no sobre uno que venga de fuera ni sobre el total con impuestos.
  if v_base < 5.00 then
    raise exception 'El monto mínimo por cobro es $5.00' using errcode = '22023';
  end if;

  select * into v_terms from public.merchant_settlement_terms where merchant_id = p_merchant_id;
  v_b := public.helios_charge_breakdown(v_base, coalesce(v_terms.commission_pct, 10));

  -- Idempotente: si ya existe un cobro con esta clave (reintento de red del
  -- cajero), se devuelve el mismo en vez de generar un segundo QR vivo.
  insert into public.charges (
    merchant_id, branch_id, requested_by, idempotency_key,
    amount_usd,
    base_usd, vat_pct, vat_usd,
    consumer_fee_pct, consumer_fee_usd, consumer_fee_vat_usd,
    merchant_fee_pct, merchant_fee_usd, merchant_fee_vat_usd, merchant_net_usd
  )
  values (
    p_merchant_id, p_branch_id, v_staff, p_idempotency_key,
    (v_b->>'consumer_total_usd')::numeric,
    (v_b->>'base_usd')::numeric,
    (v_b->>'vat_pct')::numeric,
    (v_b->>'vat_usd')::numeric,
    (v_b->>'consumer_fee_pct')::numeric,
    (v_b->>'consumer_fee_usd')::numeric,
    (v_b->>'consumer_fee_vat_usd')::numeric,
    (v_b->>'merchant_fee_pct')::numeric,
    (v_b->>'merchant_fee_usd')::numeric,
    (v_b->>'merchant_fee_vat_usd')::numeric,
    (v_b->>'merchant_net_usd')::numeric
  )
  on conflict (idempotency_key) do nothing
  returning * into v_row;

  if v_row.id is null then
    -- Ya existía: NO se vuelven a insertar las líneas, o el reintento
    -- duplicaría el detalle de un cobro que ya está en pantalla.
    select * into v_row from public.charges where idempotency_key = p_idempotency_key;
    return v_row;
  end if;

  insert into public.charge_items
    (charge_id, product_id, name, unit_price_usd, quantity, position)
  select
    v_row.id,
    (l->>'product_id')::uuid,
    l->>'name',
    (l->>'unit_price_usd')::numeric,
    (l->>'quantity')::integer,
    (ord - 1)::smallint
  from jsonb_array_elements(v_lines) with ordinality as t(l, ord);

  return v_row;
end;
$$;

revoke all on function public.request_charge(uuid, uuid, jsonb, text) from public, anon;
grant execute on function public.request_charge(uuid, uuid, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Al comercio se le liquida sobre SU neto, no sobre lo que paga el usuario
-- ---------------------------------------------------------------------------
/**
 * Es el cambio que evita el error más caro posible: con `amount_usd` incluyendo
 * ahora el IVA y los dos fees, seguir liquidando un porcentaje de esa cifra le
 * pagaría al comercio una parte de la comisión de Ronda y del IVA del fisco.
 */
create or replace function public.run_scheduled_settlements(p_business_date date)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_charge record;
  v_terms  public.merchant_settlement_terms%rowtype;
  v_amount numeric(18,4);
  v_count  integer := 0;
begin
  -- Un consumo por vuelta, no una cuota por vuelta: en un consumo de mesa hay
  -- una cuota por integrante venciendo el mismo día y todas hablan de la misma
  -- venta (ver 20260827080000).
  for v_charge in
    select distinct c.id as charge_id, c.merchant_id,
           coalesce(c.merchant_net_usd, c.amount_usd) as net_usd
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.due_date = p_business_date
  loop
    select * into v_terms from public.merchant_settlement_terms
    where merchant_id = v_charge.merchant_id;

    if v_terms.policy <> 'scheduled' then
      continue;
    end if;

    if exists (
      select 1 from public.settlements
      where charge_id = v_charge.charge_id
        and reason = 'scheduled_installment'
        and business_date = p_business_date
    ) then
      continue;
    end if;

    v_amount := round(v_charge.net_usd * v_terms.per_installment_pct / 100, 4);

    insert into public.settlements
      (merchant_id, charge_id, installment_id, reason, amount_usd, business_date, due_date, status)
    values
      (v_charge.merchant_id, v_charge.charge_id, null, 'scheduled_installment',
       v_amount, p_business_date, p_business_date, 'pending');

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.run_scheduled_settlements(date) from public, anon, authenticated;
