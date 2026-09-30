-- ============================================================================
-- Ronda — Tipos de aviso de la mesa
--
-- Van SOLOS en esta migración por lo mismo que 'bits_earned' (20260825200000):
-- Postgres deja añadir un valor a un enum dentro de una transacción, pero **no
-- deja usarlo hasta que esa transacción termina**. El CLI corre cada archivo en
-- su propia transacción, así que quien los escribe vive en el archivo
-- siguiente.
--
--   tab_charge  → te tocó una parte de un consumo de la mesa
--   tab_joined  → alguien entró a tu mesa
-- ============================================================================

alter type public.notification_type add value if not exists 'tab_charge';
alter type public.notification_type add value if not exists 'tab_joined';
