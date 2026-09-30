-- ============================================================================
-- Ronda — Tipos de aviso para el bloqueo manual de una cuenta
--
-- Van en su propio archivo por lo de siempre: un valor nuevo de un enum no se
-- puede usar en la transacción que lo crea. Los usa 20260909160000.
--
-- No se reutiliza `account_frozen`: ese lo dispara el motor de mora al congelar
-- por una cuota vencida, y su plantilla habla de eso. Un bloqueo del equipo no
-- es una mora, y decirle a alguien "tienes una cuota vencida" cuando lo que
-- pasó es que se le sancionó a mano es mentirle y además dejarlo sin saber a
-- quién reclamar.
-- ============================================================================

alter type public.notification_type add value if not exists 'account_blocked';
alter type public.notification_type add value if not exists 'account_unblocked';
