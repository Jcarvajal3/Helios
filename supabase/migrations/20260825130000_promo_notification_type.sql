-- ============================================================================
-- Ronda — Un tipo de aviso para las promociones
--
-- Va SOLO en esta migración, y es a propósito: Postgres deja añadir un valor a
-- un enum dentro de una transacción, pero **no deja usarlo hasta que esa
-- transacción termina**. El CLI de Supabase corre cada archivo en su propia
-- transacción, así que todo lo que necesita escribir 'promo' —la campaña, el
-- canal, el reparto— tiene que vivir en el archivo siguiente.
--
-- Partirlo cuesta un archivo de tres líneas. No partirlo cuesta un despliegue
-- que falla a mitad, con la mitad de las funciones creadas.
-- ============================================================================

alter type public.notification_type add value if not exists 'promo';
