-- ============================================================================
-- Ronda — Un comercio nuevo nace con las condiciones del piloto
--
-- Las condiciones de la casa son adelanto 0 %, 50 % del neto al vencer cada
-- cuota y comisión 0 (docs/00 §2.5; la comisión es 0 desde
-- 20260830140000_el_iva_lo_pone_el_comercio). Las dos bases las tienen en
-- todas sus filas, pero NINGÚN comercio dado de alta hoy las recibiría:
--
--   * `merchant_terms` se creó en 20260911206000 con los defaults de agosto
--     (30 / 35 / 10), anteriores a los dos cambios de condiciones.
--   * `bootstrap_merchant()` inserta la fila del alta sin fijar valores, y
--     `admin_create_merchant` no los corrige después. El local nacía con un
--     10 % de comisión y un 30 % de adelanto, y cada cobro suyo llevaba
--     `merchant_fee_usd` > 0 sin que nadie lo hubiera negociado.
--   * `request_charge` caía a un 10 % si no encontraba condiciones.
--
-- No pasó en ningún local real: desde 20260911206000 no se ha dado de alta
-- ninguno (comprobado en dev y en producción el 2026-09-23). Esta migración
-- no toca filas: ni `merchant_terms` ni cobros ya confirmados.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Los defaults de la tabla
-- ---------------------------------------------------------------------------
-- Cubren cualquier insert que no pase por el alta (SQL a mano, seed).
-- Adelanto y cuota cambian en la misma sentencia: `merchant_terms_splits_net`
-- exige que sumen 100 y se comprueba fila a fila, no sobre el default.
alter table public.merchant_terms
  alter column upfront_pct         set default 0,
  alter column per_installment_pct set default 50.00,
  alter column commission_pct      set default 0;

-- ---------------------------------------------------------------------------
-- 2. El alta escribe las condiciones que da
-- ---------------------------------------------------------------------------
-- Explícitas y no por default: quien lee el alta ve con qué nace un local sin
-- ir a buscar la definición de la tabla. Renegociar sigue siendo
-- `admin_set_settlement_terms` desde la ficha del comercio.
create or replace function public.bootstrap_merchant()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.merchant_branches (merchant_id, name, is_default)
  values (new.id, 'Principal', true);

  -- Vigentes desde hoy: un comercio no puede tener condiciones anteriores a
  -- su propia alta.
  insert into public.merchant_terms
    (merchant_id, upfront_pct, per_installment_pct, commission_pct, effective_from, note)
  values
    (new.id, 0, 50.00, 0, public.helios_business_date(now()), 'Condiciones del piloto al dar de alta');

  return new;
end;
$$;

revoke all on function public.bootstrap_merchant() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Sacar un cobro sin condiciones no inventa una comisión
-- ---------------------------------------------------------------------------
-- Copia literal de la definición viva (20260922220000_lo_que_el_personal_ve_de_un_cobro,
-- igual en dev y en producción el 2026-09-23). Solo cambia el fallback del
-- `coalesce` de la comisión, marcado NUEVO (2026-09-23). La firma no cambia,
-- así que `create or replace` conserva los permisos.
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
  v_status  public.merchant_status;
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

  -- NUEVO (2026-09-18): un local pausado o terminado no cobra.
  --
  -- «Pausar lo saca de la app y bloquea cobros nuevos», decía el panel. La
  -- primera mitad era verdad —la policy `merchants_read_active` lo esconde de
  -- la app—, la segunda no existía en ninguna parte: esta función es
  -- `security definer`, así que ninguna policy la toca, y el permiso se
  -- comprobaba solo contra `merchant_users`, que no mira el estado del local.
  -- Un comercio terminado seguía facturando desde su panel como el primer día,
  -- y sus QR se escaneaban con normalidad.
  --
  -- Va aquí y no en `confirm_charge`: se corta al crear el cobro, no cuando el
  -- cliente ya ha consumido y está delante del QR intentando pagar.
  select status into v_status from public.merchants where id = p_merchant_id;

  if v_status is null then
    raise exception 'Comercio no encontrado' using errcode = 'P0002';
  end if;

  if v_status <> 'active' then
    raise exception 'Este local no puede cobrar: está %',
      case v_status when 'paused' then 'pausado' else 'terminado' end
      using errcode = '22023';
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

    -- NUEVO (2026-09-18): toda línea es un producto de la carta.
    --
    -- Aquí vivía la línea libre: sin `product_id`, el nombre y el PRECIO los
    -- ponía quien llamaba. Se quitó del panel el mismo día, y esto es el
    -- cierre por dentro, que es el que cuenta: la pantalla se puede volver a
    -- desplegar, pero la regla —un cobro es lo que el cliente se llevó, y cada
    -- cosa que se llevó está en la carta— tiene que valer también para quien
    -- llame la RPC a mano.
    --
    -- Y de paso deja de haber dos fuentes para el precio. Con la línea libre,
    -- el importe de una línea podía ser cualquiera, así que un cobro no se
    -- podía contrastar contra el catálogo ni auditar hacia atrás. Ahora el
    -- precio sale SIEMPRE de `products`, y `unit_price_usd` del item se
    -- ignora: lo que manda es la carta del local en el momento del cobro.
    if nullif(v_item->>'product_id', '') is null then
      raise exception 'Cada línea del cobro tiene que ser un producto de tu carta'
        using errcode = '22023';
    end if;

    select p.name, p.price_usd into v_name, v_price
    from public.products p
    where p.id = (v_item->>'product_id')::uuid
      and p.merchant_id = p_merchant_id
      and p.is_active;

    if not found then
      raise exception 'Un producto del pedido ya no está en tu carta; quítalo y vuelve a intentar'
        using errcode = '22023';
    end if;

    /**
     * NUEVO: nada de milésimas, venga de la carta o de una línea libre.
     *
     * `base_usd` nace redondeado a dos decimales pero las líneas se guardan
     * tal cual llegan, así que un precio con tres decimales hace que el
     * comprobante enseñe unas líneas que no suman su propio total. Se corta en
     * la entrada, que es donde se puede decir cuál es la línea mala.
     *
     * Se compara contra el valor redondeado y NO con `scale()`: `v_price` está
     * declarada `numeric(18,4)`, y sobre una variable con typmod `scale()`
     * devuelve siempre el de la DECLARACIÓN (4), no el del valor — así que la
     * comprobación rechazaba absolutamente todos los cobros.
     */
    if v_price <> round(v_price, 2) then
      raise exception 'El precio de "%" tiene más de dos decimales', v_name
        using errcode = '22023';
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
    raise exception 'El monto mínimo por cobro es €5.00' using errcode = '22023';
  end if;

  select * into v_terms from public.merchant_settlement_terms where merchant_id = p_merchant_id;
  -- NUEVO (2026-09-23): sin condiciones, comisión 0, que es la del piloto. Con
  -- el 10 % de antes un local sin fila cobraba una comisión que nadie pactó.
  v_b := public.helios_charge_breakdown(v_base, coalesce(v_terms.commission_pct, 0));

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
    -- NUEVO (2026-09-22): lo que el personal puede ver del cobro, no la fila entera.
    return public.helios_charge_for_staff(v_row.id);
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

  -- NUEVO (2026-09-22): lo que el personal puede ver del cobro, no la fila entera.
  return public.helios_charge_for_staff(v_row.id);
end;
$$;
