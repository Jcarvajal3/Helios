-- ============================================================================
-- Ronda — Campos de comercio para Buscar / Filtrar
--
-- La pantalla de Búsqueda del Figma (nodo 20:3182) filtra comercios por
-- categoría y ciudad, y los muestra con un handle tipo "@nombre" y un logo.
-- Ninguno de los cuatro existía en `merchants` (solo name/legal_name/tax_id/
-- status) — se agregan aquí. La lectura ya la cubre la policy existente
-- `merchants_read_active`, así que no hace falta una RPC nueva.
-- ============================================================================

create type public.merchant_category as enum ('discoteca', 'conciertos', 'otros');

alter table public.merchants
  add column category public.merchant_category,
  add column city text,
  add column handle text,
  -- Sin imágenes en el catálogo de productos (docs/00-BASES, 2026-08-21),
  -- pero esto es el logo del comercio para las tarjetas de Búsqueda, no una
  -- foto de producto. Nullable: sin logo, la UI cae a un placeholder con la
  -- inicial del nombre.
  add column logo_url text;
