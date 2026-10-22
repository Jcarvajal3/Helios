-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El rol de la agenda
--
-- Un tercer rol del equipo, además de `super_admin` y `operador`: `agenda`.
-- Quien lo tiene solo entra a superadmin › Agenda (apuntar médicos, anotar
-- gestiones y agendar visitas) y a nada más del panel.
--
-- Va solo en este archivo: un valor de enum recién añadido no se puede usar
-- en la misma transacción. Los permisos van en 20261022220100.
-- ═══════════════════════════════════════════════════════════════════════════

alter type public.platform_role add value if not exists 'agenda';
