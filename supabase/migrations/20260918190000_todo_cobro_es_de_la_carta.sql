-- ============================================================================
-- Ronda — Todo cobro es de la carta
--
-- `request_charge` aceptaba dos clases de línea: un producto del catálogo, o
-- una línea libre con el nombre y el precio que mandara quien llamaba. La
-- segunda era la que alimentaba el botón «Cobrar un monto libre» del panel,
-- que se quitó hoy. Esto es el cierre por dentro.
--
-- Por qué se cierra ahora y no «cuando haga falta»: todavía no hay pagos
-- reales, así que no hay ni una tablet cobrando de la que dependa esto. Cada
-- semana que pasara, la línea libre dejaría más cargos sin producto detrás, y
-- eso es lo que después no se puede arreglar — un cargo viejo no se reescribe.
-- Decisión de Javier, 2026-09-18.
--
-- Lo que cambia de verdad, más allá de un botón menos:
--
--   * **Un cobro se puede contrastar con la carta.** Cada línea apunta a un
--     producto, así que se puede saber qué se vendió, cuántas veces y a qué
--     precio, sin adivinar por el texto que alguien tecleó.
--   * **El precio deja de tener dos fuentes.** Sale siempre de `products`;
--     el `unit_price_usd` que venga en el item se ignora. Antes, quien
--     llamara a la RPC podía fijar el importe de una línea a lo que quisiera.
--
-- Los cargos viejos con líneas sueltas se quedan como están: son consumos que
-- ocurrieron y tienen cuotas colgando. El candado de la tabla es `not valid`
-- justamente por eso — vale para todo lo que venga, no reescribe lo que pasó.
--
-- El resto de la función es copia literal de 20260918140000.
-- ============================================================================

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

-- ---------------------------------------------------------------------------
-- El candado en la tabla, no solo en la RPC
-- ---------------------------------------------------------------------------
-- La regla vale para cualquier camino, no solo para `request_charge`: nada de
-- lo que inserte en `charge_items` —hoy o dentro de un año— puede dejar una
-- línea sin producto.
--
-- `not valid` no significa apagado: lo que entre a partir de ahora se
-- comprueba igual. Significa que no se revisan las filas que ya están, y esas
-- son 18 líneas de las pruebas del piloto que no se van a reescribir.
alter table public.charge_items
  drop constraint if exists charge_items_product_required;

alter table public.charge_items
  add constraint charge_items_product_required
  check (product_id is not null) not valid;

comment on constraint charge_items_product_required on public.charge_items is
  'Toda linea de un cobro es un producto de la carta. not valid: las lineas libres de antes del 2026-09-18 se conservan tal cual.';

comment on function public.request_charge(uuid, uuid, jsonb, text) is
  'Crea un cobro pendiente. Exige personal activo, comercio activo y que cada linea sea un producto activo de la carta; el precio sale del catalogo.';

revoke all on function public.request_charge(uuid, uuid, jsonb, text) from public, anon;
grant execute on function public.request_charge(uuid, uuid, jsonb, text) to authenticated;
