-- ============================================================================
-- Ronda — Los logos de los locales también piden el segundo factor
--
-- 20260925131000 hizo que toda escritura del super admin pase por
-- `is_platform_admin()`, que exige una sesión `aal2` cuando
-- `platform_security.require_mfa` está encendida. Quedaron fuera las tres
-- políticas de Storage del bucket `merchant-logos` (subir, cambiar y borrar),
-- que miraban el rol en `platform_admins` a mano: con la exigencia encendida,
-- una sesión `aal1` de super admin podía cambiar el logo de un local.
--
-- Ahora las tres piden las dos cosas: `is_platform_admin()` (sesión válida,
-- con el segundo factor si hace falta) y el rol de super admin. Una política no
-- puede usar `helios_assert_super_admin`, que lanza un error en vez de devolver
-- falso. El `(select …)` hace que cada comprobación se evalúe una vez por
-- consulta y no una por fila, como en `merchant_receipts_admin`.
--
-- Con la exigencia apagada (hoy) la subida del logo funciona igual que antes.
-- ============================================================================

drop policy if exists "merchant_logos_write_super_admin" on storage.objects;
create policy "merchant_logos_write_super_admin"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'merchant-logos'
    and (select public.is_platform_admin())
    and exists (
      select 1 from public.platform_admins
      where user_id = (select auth.uid()) and is_active and role = 'super_admin'
    )
  );

drop policy if exists "merchant_logos_update_super_admin" on storage.objects;
create policy "merchant_logos_update_super_admin"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'merchant-logos'
    and (select public.is_platform_admin())
    and exists (
      select 1 from public.platform_admins
      where user_id = (select auth.uid()) and is_active and role = 'super_admin'
    )
  );

drop policy if exists "merchant_logos_delete_super_admin" on storage.objects;
create policy "merchant_logos_delete_super_admin"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'merchant-logos'
    and (select public.is_platform_admin())
    and exists (
      select 1 from public.platform_admins
      where user_id = (select auth.uid()) and is_active and role = 'super_admin'
    )
  );
