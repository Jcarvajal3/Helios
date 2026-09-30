-- ============================================================================
-- Ronda — Arreglar el reintento de subida de capturas de KYC
--
-- Síntoma: la app fallaba con "No pudimos enviar tus fotos" en TODA subida.
--
-- Causa: el cliente sube con `upsert: true`, y para resolver un upsert la API
-- de Storage necesita primero consultar si el objeto ya existe. Sin política
-- de SELECT esa consulta falla, y el error sale como violación de RLS —
-- confuso, porque la política de INSERT era correcta. Verificado: la misma
-- subida sin la cabecera `x-upsert` devolvía 200.
--
-- Decisión: se añade SELECT acotado a la carpeta del propio usuario.
--
-- Esto relaja la propiedad de "un solo sentido" que había impuesto antes, y el
-- intercambio vale la pena: lo único que gana el usuario es poder releer una
-- foto que él mismo acaba de tomar y que ya tiene en su teléfono. Lo que
-- importaba de verdad —que nadie pueda ver las capturas de OTRA persona— sigue
-- intacto, porque el filtro por carpeta no cambia.
--
-- DELETE sigue sin política: borrar es exclusivo del servicio de KYC, que es
-- quien aplica la retención de 72 horas.
-- ============================================================================

create policy "kyc_read_own_folder"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
