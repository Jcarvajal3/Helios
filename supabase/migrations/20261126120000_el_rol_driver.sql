-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El rol driver (Helios Lab, docs/09)
--
-- Un sexto rol del equipo: `driver`. Quien lo tiene solo ve la ruta del día
-- de Helios Lab en su teléfono y marca las paradas. Los permisos van en
-- 20261126120100.
--
-- Va solo en este archivo: un valor de enum recién añadido no se puede usar
-- en la misma transacción.
-- ═══════════════════════════════════════════════════════════════════════════

alter type public.platform_role add value if not exists 'driver';
