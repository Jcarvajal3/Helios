-- ============================================================================
-- Helios — Las clínicas pueden ser de cosmetología
--
-- Helios cubre medicina, odontología y cosmetología (Javier, 2026-10-06). La
-- categoría de la clínica ya tenía `clinica`, `consultorio`, `odontologia`,
-- `laboratorio` e `imagenes` (20261002000400); falta `cosmetologia`.
--
-- Va sola: un valor de enum recién añadido no se puede usar en el mismo
-- fichero (ver `supabase/poda/aplicar.mjs`).
-- ============================================================================

alter type public.merchant_category add value if not exists 'cosmetologia';
