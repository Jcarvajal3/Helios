-- ============================================================================
-- Helios — Se conectan las plantillas de los avisos con cuotas vencidas
-- (2026-11-02; docs/00 §15.10)
--
-- Javier avisó el 2026-11-02 que Meta aprobó las plantillas de los casos 1 y
-- 2 (20261029110000, 20261029170000). Leídas en vivo de 360dialog ese día:
-- las dos UTILITY, en `es`, con el texto corregido y los botones «Ya pagué» ·
-- «Hablar con alguien».
--
--   cuota_con_vencidas → helios_cuota_con_vencidas (13 variables): 3 días
--                        antes, mañana y hoy, si debe otra cuota
--   cuotas_vencidas    → helios_cuotas_vencidas    (14 variables): cuota
--                        vencida, si ya debía otra
--
-- Las variables y los botones ya estaban puestos en sus filas: desde aquí,
-- fuera de la ventana de 24 h, esos avisos dicen lo vencido.
-- ============================================================================

update public.notification_templates
   set wa_template_name = 'helios_cuota_con_vencidas', wa_template_lang = 'es'
 where key = 'cuota_con_vencidas';

update public.notification_templates
   set wa_template_name = 'helios_cuotas_vencidas', wa_template_lang = 'es'
 where key = 'cuotas_vencidas';
