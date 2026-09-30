-- ============================================================================
-- Ronda — Un local pausado no cobra, y lo que se le debe incluye lo que falta
--
-- Dos agujeros que la pantalla de un comercio daba por tapados y no lo
-- estaban. Los dos se ven al terminar un local desde el super admin.
--
-- ---------------------------------------------------------------------------
-- 1. «Bloquea cobros nuevos» no bloqueaba nada
-- ---------------------------------------------------------------------------
-- Pausar y terminar solo escribían `merchants.status`. Eso esconde el local en
-- la app, porque la policy `merchants_read_active` deja pasar los activos y
-- nada más — pero `request_charge` es `security definer` y ninguna policy la
-- mira, y el permiso para facturar se comprobaba únicamente contra
-- `merchant_users`. Resultado: el personal de un local terminado entraba a su
-- panel y seguía generando cobros, con sus QR, sus cuotas y sus liquidaciones.
--
-- ---------------------------------------------------------------------------
-- 2. La deuda con el local no veía las liquidaciones a medias
-- ---------------------------------------------------------------------------
-- `admin_merchant_detail` (la cifra «Le debes X» de la ficha) y
-- `admin_set_merchant_status` (el candado que impide terminar debiendo)
-- contaban lo mismo y lo contaban mal: `sum(amount_usd)` de las `pending`, sin
-- las `partial` y sin restar lo ya transferido. Desde que un pago a un local
-- puede ser parcial (20260911191000), la liquidación que queda a medias es
-- `partial` con su resto, y ese resto se volvía invisible para las dos.
--
-- Es el mismo fallo de familia que 20260918100000 arregló en
-- `admin_merchant_settlements`: el pendiente de verdad es
-- `amount_usd - paid_usd` sobre `('pending','partial')`, como en
-- `helios_settlement_outlook`, y en ningún sitio debería escribirse de otra
-- manera.
--
-- Lo demás de las tres funciones es copia literal de su última versión.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Cobrar exige estar activo
-- ---------------------------------------------------------------------------
-- Copiada de 20260909100000_el_precio_se_pacta_en_euros.sql salvo el bloque
-- marcado NUEVO.

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
-- 2. El candado de «Terminar»
-- ---------------------------------------------------------------------------
-- Copiada de 20260909100000_el_precio_se_pacta_en_euros.sql salvo el bloque
-- marcado NUEVO.

create or replace function public.admin_set_merchant_status(
  p_merchant_id uuid,
  p_status      public.merchant_status,
  p_note        text default null
)
returns public.merchants
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_row   public.merchants%rowtype;
  v_owed  numeric(18,4);
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede cambiar el estado de un comercio'
      using errcode = '42501';
  end if;

  -- Terminar un comercio al que todavía se le debe dinero es casi siempre un
  -- error: lo pendiente hay que pagarlo igual. Se bloquea y se dice cuánto.
  if p_status = 'terminated' then
    -- NUEVO (2026-09-18): las parciales cuentan, y cuenta lo que FALTA.
    --
    -- Sumaba el importe entero de las `pending` y se olvidaba de las
    -- `partial`, que existen desde 20260911191000 y son justo las que llevan
    -- un resto por transferir. Con una liquidación a medias como única deuda,
    -- esto daba cero y dejaba terminar un comercio al que todavía se le debe
    -- dinero —dinero que sigue vivo y sigue saliendo en el cierre del lunes,
    -- porque `helios_settlement_outlook` sí las cuenta—.
    select coalesce(sum(amount_usd - paid_usd), 0) into v_owed
    from public.settlements
    where merchant_id = p_merchant_id and status in ('pending', 'partial');

    if v_owed > 0 then
      -- Con dos decimales y no los cuatro de la columna: este texto se lee tal
      -- cual en el panel, y «le debes €6.0000» parece un error de la pantalla.
      raise exception 'No puedes terminar este comercio: le debes €%. Págale primero.',
        to_char(v_owed, 'FM999999990.00')
        using errcode = '22023';
    end if;
  end if;

  update public.merchants
    set status = p_status, updated_at = now()
  where id = p_merchant_id
  returning * into v_row;

  if not found then
    raise exception 'Comercio no encontrado' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.status_changed', p_merchant_id,
    jsonb_build_object('status', p_status, 'note', p_note));

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. La misma cuenta en la ficha del comercio
-- ---------------------------------------------------------------------------
-- Copiada de 20260825170000_merchant_social_and_logo.sql salvo el bloque
-- marcado NUEVO.

create or replace function public.admin_merchant_detail(p_merchant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_merchant public.merchants%rowtype;
  v_terms    public.merchant_settlement_terms%rowtype;
  v_staff    jsonb;
  v_owed     numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_merchant from public.merchants where id = p_merchant_id;
  if not found then
    raise exception 'Comercio no encontrado' using errcode = 'P0002';
  end if;

  select * into v_terms from public.merchant_settlement_terms
  where merchant_id = p_merchant_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', mu.user_id,
    'name', coalesce(p.full_name, au.raw_user_meta_data ->> 'full_name'),
    'email', au.email,
    'phone', p.phone_e164,
    'role', mu.role,
    'branch', b.name
  ) order by mu.created_at), '[]'::jsonb) into v_staff
  from public.merchant_users mu
  join auth.users au on au.id = mu.user_id
  left join public.profiles p on p.id = mu.user_id
  left join public.merchant_branches b on b.id = mu.branch_id
  where mu.merchant_id = p_merchant_id and mu.is_active;

  -- NUEVO (2026-09-18): la misma cuenta que el guardia de `terminated`, y por
  -- el mismo motivo. Es la cifra que la ficha enseña como «Le debes X» y la
  -- que decide si el botón de Terminar está vivo: si las dos no cuentan igual,
  -- la pantalla dice una cosa y el servidor hace otra.
  select coalesce(sum(amount_usd - paid_usd), 0) into v_owed
  from public.settlements
  where merchant_id = p_merchant_id and status in ('pending', 'partial');

  return jsonb_build_object(
    'profile', jsonb_build_object(
      'category', v_merchant.category,
      'city', v_merchant.city,
      'handle', v_merchant.handle,
      'logo_url', v_merchant.logo_url,
      'social_url', v_merchant.social_url,
      'tax_id', v_merchant.tax_id
    ),
    'terms', jsonb_build_object(
      'upfront_pct', v_terms.upfront_pct,
      'per_installment_pct', v_terms.per_installment_pct,
      'commission_pct', v_terms.commission_pct,
      'policy', v_terms.policy
    ),
    'staff', v_staff,
    'pending_usd', v_owed
  );
end;
$$;

comment on function public.request_charge(uuid, uuid, jsonb, text) is
  'Crea un cobro pendiente. Exige personal activo del comercio Y que el comercio este activo: un local pausado o terminado no factura.';

-- Los privilegios sobreviven a un `create or replace`, pero se repiten aquí
-- como en el resto del repo: una función que se relee entera tiene que poder
-- leerse entera, permisos incluidos.
revoke all on function public.request_charge(uuid, uuid, jsonb, text) from public, anon;
grant execute on function public.request_charge(uuid, uuid, jsonb, text) to authenticated;

revoke all on function public.admin_set_merchant_status(uuid, public.merchant_status, text)
  from public, anon;
grant execute on function public.admin_set_merchant_status(uuid, public.merchant_status, text)
  to authenticated;

revoke all on function public.admin_merchant_detail(uuid) from public, anon;
grant execute on function public.admin_merchant_detail(uuid) to authenticated;
