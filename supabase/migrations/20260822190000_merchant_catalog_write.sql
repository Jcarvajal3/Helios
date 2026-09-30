-- ============================================================================
-- Ronda — El comercio puede gestionar su propio catálogo
--
-- `public.products` y `public.product_categories` existen desde
-- 20260821223000, pero nacieron **solo de lectura**: aquella migración cerró
-- con "sin políticas de escritura" pensando en que el super admin (service
-- role) daría de alta los productos. Eso no se sostiene: el catálogo lo
-- mueve el local todos los días (cambia un precio, se acaba un trago), y el
-- rol `inventario` existe justo para eso — "gestiona el catálogo; no ve
-- dinero" (docs/06 §106).
--
-- Quién puede escribir: `gerente` e `inventario` del comercio dueño de la
-- fila. El `cajero` no, ni siquiera sobre su propia sucursal: cobra, no
-- fija precios.
--
-- El panel nunca usa el service role, así que la barrera real es RLS —
-- estas políticas SON el permiso, no un adorno de la UI.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- A qué comercios pertenece el usuario CON alguno de estos roles
-- ---------------------------------------------------------------------------
-- `my_merchant_ids()` no sirve aquí: devuelve el comercio sea cual sea el
-- rol, así que un cajero pasaría el filtro. Se necesita la versión que
-- discrimina por rol.

create or replace function public.my_merchant_ids_with_role(
  p_roles public.merchant_role[]
)
returns setof uuid
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select merchant_id
  from public.merchant_users
  where user_id = auth.uid()
    and is_active
    and role = any (p_roles);
$$;

revoke all on function public.my_merchant_ids_with_role(public.merchant_role[])
  from public, anon;
grant execute on function public.my_merchant_ids_with_role(public.merchant_role[])
  to authenticated;

-- ---------------------------------------------------------------------------
-- Categorías
-- ---------------------------------------------------------------------------

create policy "categories_write_catalog_staff"
  on public.product_categories for insert to authenticated
  with check (
    merchant_id in (
      select public.my_merchant_ids_with_role(array['gerente', 'inventario']::public.merchant_role[])
    )
  );

create policy "categories_update_catalog_staff"
  on public.product_categories for update to authenticated
  using (
    merchant_id in (
      select public.my_merchant_ids_with_role(array['gerente', 'inventario']::public.merchant_role[])
    )
  )
  -- Sin este `with check`, un UPDATE podría mover la fila a OTRO comercio:
  -- `using` solo decide qué filas se pueden tocar, no en qué se pueden
  -- convertir.
  with check (
    merchant_id in (
      select public.my_merchant_ids_with_role(array['gerente', 'inventario']::public.merchant_role[])
    )
  );

create policy "categories_delete_catalog_staff"
  on public.product_categories for delete to authenticated
  using (
    merchant_id in (
      select public.my_merchant_ids_with_role(array['gerente', 'inventario']::public.merchant_role[])
    )
  );

-- ---------------------------------------------------------------------------
-- Productos
-- ---------------------------------------------------------------------------

create policy "products_write_catalog_staff"
  on public.products for insert to authenticated
  with check (
    merchant_id in (
      select public.my_merchant_ids_with_role(array['gerente', 'inventario']::public.merchant_role[])
    )
  );

create policy "products_update_catalog_staff"
  on public.products for update to authenticated
  using (
    merchant_id in (
      select public.my_merchant_ids_with_role(array['gerente', 'inventario']::public.merchant_role[])
    )
  )
  with check (
    merchant_id in (
      select public.my_merchant_ids_with_role(array['gerente', 'inventario']::public.merchant_role[])
    )
  );

create policy "products_delete_catalog_staff"
  on public.products for delete to authenticated
  using (
    merchant_id in (
      select public.my_merchant_ids_with_role(array['gerente', 'inventario']::public.merchant_role[])
    )
  );

-- Sin el GRANT, Postgres rechaza el INSERT antes de mirar la política: RLS
-- filtra filas, pero el permiso de tabla se evalúa primero. Es el mismo
-- fallo silencioso que arregló 20260822060000 para el SELECT.
grant insert, update, delete on public.products, public.product_categories
  to authenticated;

-- ---------------------------------------------------------------------------
-- El gerente ve el desglose de lo que le pagaron
-- ---------------------------------------------------------------------------
-- `merchant_payouts` ya lo lee el gerente (20260822120000), pero sus items
-- no: sin esto la pantalla de Liquidaciones puede decir "te transfirieron
-- $36" y no qué liquidaciones cubría esa transferencia, que es justo lo que
-- el local necesita para cuadrar.

create policy "payout_items_read_merchant"
  on public.merchant_payout_items for select to authenticated
  using (
    payout_id in (
      select id from public.merchant_payouts
      where merchant_id in (
        select public.my_merchant_ids_with_role(array['gerente']::public.merchant_role[])
      )
    )
  );
