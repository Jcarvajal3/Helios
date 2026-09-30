-- ============================================================================
-- Ronda — Tipos de aviso para la lista de espera del piloto
--
-- Van en su propio archivo por la misma razón que los Bits y el cargo por
-- mora: un valor nuevo de un enum no se puede usar en la transacción que lo
-- crea, y cada migración corre en la suya. La bóveda y la lista de espera
-- (20260909151000) los usan al avisar.
--
--   waitlist_joined    → "tu saldo está en lista de espera"
--   waitlist_released  → "ya puedes usar tu saldo"
--
-- Son parte de una funcionalidad TEMPORAL (ver la migración siguiente). Un
-- valor de enum no se puede quitar, pero un tipo sin avisos que lo usen no
-- estorba a nadie.
-- ============================================================================

alter type public.notification_type add value if not exists 'waitlist_joined';
alter type public.notification_type add value if not exists 'waitlist_released';
