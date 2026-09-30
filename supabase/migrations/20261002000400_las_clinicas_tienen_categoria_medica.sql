-- ============================================================================
-- Helios — Las clínicas tienen categoría médica (H8, parte 1)
--
-- `merchant_category` era de la noche (discoteca, conciertos, otros). Se
-- añaden las categorías de Helios. Van solas en su migración porque un valor
-- de enum recién añadido no se puede usar en la misma transacción
-- (supabase/README.md); la 20261002000500 ya las usa.
--
-- Los valores de la noche se quedan (quitar valores de un enum no compensa,
-- docs/00 §4.2) pero el panel no los ofrece.
-- ============================================================================

alter type public.merchant_category add value if not exists 'clinica';
alter type public.merchant_category add value if not exists 'consultorio';
alter type public.merchant_category add value if not exists 'odontologia';
alter type public.merchant_category add value if not exists 'laboratorio';
alter type public.merchant_category add value if not exists 'imagenes';
