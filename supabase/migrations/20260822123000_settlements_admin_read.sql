-- ============================================================================
-- Ronda — El super admin tiene que poder leer las liquidaciones
--
-- Hueco de 20260822100000: se añadieron políticas de lectura para el admin
-- sobre payment_reports, installments, charges, profiles y demás, pero NO
-- sobre `settlements` ni sobre las tablas de pagos al comercio.
--
-- Síntoma: la pantalla "Pagos a comercios" decía "No le debes nada a nadie"
-- con $36 devengados en la base. La vista `merchant_payables` es
-- `security_invoker`, así que hereda las RLS de quien pregunta: sin política,
-- el admin veía cero filas.
--
-- Es el peor tipo de fallo de permisos: no da error, da un resultado vacío
-- que parece una respuesta legítima. Si esto llega a producción, alguien
-- concluye que no hay que pagarle a nadie.
-- ============================================================================

create policy "settlements_read_admin"
  on public.settlements for select to authenticated
  using (public.is_platform_admin());

-- `merchant_payouts` y sus items ya tienen política de admin desde
-- 20260822120000; se comprueba aquí que no falte ninguna otra tabla que
-- alimente las vistas del panel.
create policy "payment_destinations_read_admin"
  on public.payment_destinations for select to authenticated
  using (public.is_platform_admin());
