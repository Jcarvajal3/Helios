-- ============================================================================
-- Ronda — Un tipo de aviso para los Bits ganados
--
-- Va SOLO en esta migración por lo mismo que 'promo' (20260825130000):
-- Postgres deja añadir un valor a un enum dentro de una transacción, pero **no
-- deja usarlo hasta que esa transacción termina**. El CLI corre cada archivo en
-- su propia transacción, así que el trigger que escribe 'bits_earned' vive en
-- el archivo siguiente.
-- ============================================================================

alter type public.notification_type add value if not exists 'bits_earned';
