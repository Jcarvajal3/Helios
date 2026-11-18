-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El rol cobranza
--
-- Un quinto rol del equipo: `cobranza`. Quien lo tiene entra solo a
-- superadmin › Por cobrar. Los permisos van en 20261118120100.
--
-- Va solo en este archivo: un valor de enum recién añadido no se puede usar
-- en la misma transacción.
-- ═══════════════════════════════════════════════════════════════════════════

alter type public.platform_role add value if not exists 'cobranza';
