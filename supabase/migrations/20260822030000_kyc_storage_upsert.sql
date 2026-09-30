-- ============================================================================
-- Ronda — Permitir reintentar la subida de capturas de KYC
--
-- El cliente sube con `upsert: true` para que reintentar una verificación
-- sobrescriba la captura anterior en vez de fallar. Pero un upsert sobre un
-- objeto que ya existe necesita política de UPDATE, y solo existía la de
-- INSERT: el primer intento funcionaba y el segundo moría con un error de
-- política que el cliente reportaba como "revisa tu conexión".
--
-- Se mantiene la restricción importante: el usuario sigue confinado a su
-- propia carpeta, y sigue sin poder LEER ni BORRAR nada.
-- ============================================================================

create policy "kyc_update_own_folder"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- Sin políticas de SELECT ni DELETE a propósito: las capturas siguen siendo
-- de un solo sentido. Leerlas y borrarlas es exclusivo del servicio de KYC,
-- que corre con service role.
