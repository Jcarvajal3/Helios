-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El rol capacitador
--
-- Un cuarto rol del equipo: `capacitador`. Quien lo tiene entra a
-- superadmin › Agenda y a superadmin › Clínicas: ve las clínicas y el perfil
-- de cada médico (solo lectura), da de alta médicos y aprueba o rechaza las
-- solicitudes de afiliación.
--
-- Va solo en este archivo: un valor de enum recién añadido no se puede usar
-- en la misma transacción. Los permisos van en 20261102130100.
-- ═══════════════════════════════════════════════════════════════════════════

alter type public.platform_role add value if not exists 'capacitador';
