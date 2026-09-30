-- ===========================================================================
-- Lo que el personal ve de un cobro
-- ===========================================================================
-- Primera de dos. Esta solo AÑADE y se puede aplicar en cualquier momento: el
-- panel desplegado hoy sigue funcionando igual. La segunda
-- (20260922221000_el_personal_ya_no_lee_la_tabla_de_cobros) quita las
-- políticas por las que el personal lee `charges` y `charge_items`, y va
-- DESPUÉS de desplegar el panel que usa las RPC de aquí.
--
-- Comprobado en dev y en producción el 2026-09-22: con
-- `charges_read_merchant_staff` (20260822054000) cualquier persona activa del
-- local lee la fila ENTERA de cada venta, y `authenticated` tiene SELECT sobre
-- todas las columnas. Desde la consola del navegador salen:
--
--   * el `user_id` de quien compró —un identificador estable de la persona—,
--     y `group_id` y `group_name`;
--   * `merchant_fee_usd`, `merchant_fee_vat_usd` y `merchant_net_usd`, que
--     `merchant_charge_detail` le da solo al gerente;
--   * todas las ventas del local, aunque 20260922180000 le enseñe a la cajera
--     solo las suyas.
--
-- Con la misma forma hay tres caminos más:
--
--   * `charge_items_read_merchant_staff` da las líneas de todas las ventas del
--     local. Y depende de la anterior: su subconsulta sobre `charges` pasa por
--     la RLS de quien pregunta, así que quitar solo la de `charges` deja la
--     pantalla del QR sin líneas y el rescate sin carrito que devolver.
--   * `request_charge` devuelve la fila entera: en la respuesta de cada cobro
--     que saca, el cajero recibe la comisión pactada del local
--     (`merchant_fee_pct`) y lo que se le paga.
--   * `cancel_pending_charge` también, y la devuelve tal cual cuando el cobro
--     ya no está pendiente. Sobre uno que se anuló después de pagado, eso
--     incluye el `user_id` de quien pagó.
--
-- La regla que queda es la de las RPC de Ventas: el personal ve un cobro si lo
-- sacó él o si es el gerente del local, y el dinero del local solo lo ve el
-- gerente. Ninguna de estas funciones devuelve nada que identifique a quien
-- compró.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. La fila que se le devuelve al personal
-- ---------------------------------------------------------------------------
-- Es una lista de lo que SÍ sale, no de lo que se tapa: una columna nueva de
-- `charges` no le llega al local hasta que alguien la añada aquí a propósito.
--
-- No salen nunca quién compró (`user_id`) ni su grupo (`group_id`,
-- `group_name`), quién del local sacó o anuló el cobro (`requested_by`,
-- `voided_by`) ni la clave de idempotencia. El dinero del local
-- (`merchant_fee_*`, `merchant_net_usd`) sale solo para el gerente, igual que
-- en `merchant_charge_detail`.
--
-- Devuelve `public.charges` para que `request_charge` y `cancel_pending_charge`
-- no cambien de firma: el panel lee las mismas claves y las pruebas siguen
-- sacando `(public.request_charge(...)).id`. Lo que no sale llega en null.
--
-- Recibe el id y no la fila: PostgREST toma una función cuyo único argumento
-- es del tipo de una tabla por campo o relación calculada de esa tabla.
--
-- Sin grant a `authenticated`: solo la llaman esas dos RPC.
create or replace function public.helios_charge_for_staff(p_charge_id uuid)
returns public.charges
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_charge public.charges%rowtype;
  v_out    public.charges;
begin
  select * into v_charge from public.charges where id = p_charge_id;

  v_out.id                   := v_charge.id;
  v_out.order_number         := v_charge.order_number;
  v_out.merchant_id          := v_charge.merchant_id;
  v_out.branch_id            := v_charge.branch_id;
  v_out.status               := v_charge.status;
  v_out.is_test              := v_charge.is_test;
  v_out.business_date        := v_charge.business_date;
  v_out.created_at           := v_charge.created_at;
  v_out.expires_at           := v_charge.expires_at;
  v_out.confirmed_at         := v_charge.confirmed_at;
  v_out.voided_at            := v_charge.voided_at;
  v_out.void_reason          := v_charge.void_reason;
  -- Lo que la pantalla del QR les enseña a la vez al cliente y al local.
  v_out.amount_usd           := v_charge.amount_usd;
  v_out.base_usd             := v_charge.base_usd;
  v_out.vat_pct              := v_charge.vat_pct;
  v_out.vat_usd              := v_charge.vat_usd;
  v_out.consumer_fee_pct     := v_charge.consumer_fee_pct;
  v_out.consumer_fee_usd     := v_charge.consumer_fee_usd;
  v_out.consumer_fee_vat_usd := v_charge.consumer_fee_vat_usd;

  if public.my_merchant_id_as_gerente() = v_charge.merchant_id then
    v_out.merchant_fee_pct     := v_charge.merchant_fee_pct;
    v_out.merchant_fee_usd     := v_charge.merchant_fee_usd;
    v_out.merchant_fee_vat_usd := v_charge.merchant_fee_vat_usd;
    v_out.merchant_net_usd     := v_charge.merchant_net_usd;
  end if;

  return v_out;
end;
$$;

revoke all on function public.helios_charge_for_staff(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. El sondeo de la pantalla del QR
-- ---------------------------------------------------------------------------
-- Lo que `fetchChargeStatus` pregunta cada dos segundos mientras el QR está en
-- pantalla, y lo primero que mira el rescate al recargar. Son las columnas que
-- el panel leía de la tabla, ni una más.
--
-- Un cobro que no se puede ver no da error: no devuelve fila, que es lo que el
-- panel recibía de la RLS y ya sabe tratar.
create or replace function public.merchant_charge_status(p_charge_id uuid)
returns table (
  id                   uuid,
  order_number         bigint,
  status               public.charge_status,
  /** LO QUE PAGA EL CLIENTE: el producto más el fee del servicio y su IVA. */
  amount_usd           numeric,
  base_usd             numeric,
  consumer_fee_usd     numeric,
  consumer_fee_vat_usd numeric,
  created_at           timestamptz,
  confirmed_at         timestamptz,
  expires_at           timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select c.id,
         c.order_number,
         c.status,
         c.amount_usd,
         c.base_usd,
         c.consumer_fee_usd,
         c.consumer_fee_vat_usd,
         c.created_at,
         c.confirmed_at,
         c.expires_at
  from public.charges c
  where c.id = p_charge_id
    and c.merchant_id in (select public.my_merchant_ids())
    -- La regla de las RPC de Ventas: el gerente de ESE local los ve todos;
    -- cualquier otro, solo los que sacó él.
    and (c.merchant_id = public.my_merchant_id_as_gerente() or c.requested_by = auth.uid());
$$;

revoke all on function public.merchant_charge_status(uuid) from public, anon;
grant execute on function public.merchant_charge_status(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Las líneas del cobro
-- ---------------------------------------------------------------------------
-- Lo que pinta el comprobante de la pantalla del QR y lo que el rescate
-- devuelve al carrito. La misma regla que el sondeo y las columnas que el
-- panel leía de `charge_items`; `position` sale para que siga ordenando por
-- ella.
create or replace function public.merchant_charge_items(p_charge_id uuid)
returns table (
  id             uuid,
  product_id     uuid,
  name           text,
  quantity       integer,
  unit_price_usd numeric,
  line_total_usd numeric,
  -- Entre comillas: como nombre de parámetro, `position` es palabra reservada.
  "position"     smallint
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select ci.id,
         ci.product_id,
         ci.name,
         ci.quantity,
         ci.unit_price_usd,
         ci.line_total_usd,
         ci.position
  from public.charge_items ci
  join public.charges c on c.id = ci.charge_id
  where ci.charge_id = p_charge_id
    and c.merchant_id in (select public.my_merchant_ids())
    and (c.merchant_id = public.my_merchant_id_as_gerente() or c.requested_by = auth.uid())
  order by ci.position, ci.created_at;
$$;

revoke all on function public.merchant_charge_items(uuid) from public, anon;
grant execute on function public.merchant_charge_items(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Sacar un cobro
-- ---------------------------------------------------------------------------
-- Copia literal de la definición viva (20260918190000_todo_cobro_es_de_la_carta,
-- igual en dev y en producción el 2026-09-22). Solo cambian los dos `return`,
-- marcados NUEVO (2026-09-22). La firma no cambia, así que `create or replace`
-- conserva los permisos.
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

-- ---------------------------------------------------------------------------
-- 5. Descartar un QR
-- ---------------------------------------------------------------------------
-- Copia literal de la definición viva (20260822260000_cancel_pending_charge,
-- igual en dev y en producción el 2026-09-22), con los dos `return` cambiados
-- igual que arriba. El segundo es el que importa: devuelve tal cual un cobro
-- que ya no está pendiente, y cualquiera del local puede pedirlo por su id.
create or replace function public.cancel_pending_charge(p_charge_id uuid)
returns public.charges
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff   uuid := auth.uid();
  v_charge  public.charges%rowtype;
  v_allowed boolean;
begin
  if v_staff is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- FOR UPDATE serializa contra `confirm_charge`: o gana el cliente que está
  -- confirmando, o gana el cajero que cancela, pero no los dos.
  select * into v_charge from public.charges where id = p_charge_id for update;

  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  select exists (
    select 1 from public.merchant_users
    where user_id = v_staff
      and merchant_id = v_charge.merchant_id
      and is_active
      and (branch_id is null or branch_id = v_charge.branch_id)
  ) into v_allowed;

  if not v_allowed then
    raise exception 'No autorizado sobre este cobro' using errcode = '42501';
  end if;

  if v_charge.status = 'confirmed' then
    raise exception 'Este cobro ya fue pagado: no se puede cancelar'
      using errcode = '22023';
  end if;

  if v_charge.status <> 'pending' then
    -- Cancelar dos veces no es un error que merezca asustar a nadie.
    -- NUEVO (2026-09-22): lo que el personal puede ver del cobro, no la fila entera.
    return public.helios_charge_for_staff(v_charge.id);
  end if;

  update public.charges
    set status      = 'voided',
        void_reason = 'Descartado por el comercio antes de escanearse',
        voided_by   = v_staff,
        voided_at   = now()
  where id = p_charge_id
  returning * into v_charge;

  -- NUEVO (2026-09-22): lo que el personal puede ver del cobro, no la fila entera.
  return public.helios_charge_for_staff(v_charge.id);
end;
$$;
