-- ============================================================================
-- Helios — Se conectan los recordatorios sin el titular de la cuenta
-- (2026-10-26; docs/00 §15.9)
--
-- Javier avisó el 2026-10-26 que Meta aprobó las plantillas sin la línea
-- «Titular». Leídas en vivo de 360dialog ese día: las cuatro en `es`, con 9
-- variables y los botones «Ya pagué» · «Hablar con alguien», pero Meta
-- clasificó dos como MARKETING (cuestan más y pueden no entregarse). Javier
-- decidió conectar solo las dos UTILITY mientras corrige las otras:
--
--   cuota_en_3_dias  → helios_cuota_en_3_dias_v3   (UTILITY)
--   cuota_vencida_d1 → helios_cuota_vencida_v2     (UTILITY)
--
-- `cuota_manana` y `cuota_hoy` siguen con sus `_v2` (UTILITY), que todavía
-- dicen «Titular: {{10}}»: por eso `pago_movil_titular` sigue en
-- `helios_message_builtins` y en sus parámetros.
-- ============================================================================

update public.notification_templates t
   set wa_template_name = v.nombre,
       wa_template_lang = 'es',
       wa_template_params = array['nombre', 'monto', 'medico', 'fecha', 'monto_bs', 'moneda',
                                  'pago_movil_banco', 'pago_movil_telefono', 'pago_movil_rif']
  from (values ('cuota_en_3_dias',  'helios_cuota_en_3_dias_v3'),
               ('cuota_vencida_d1', 'helios_cuota_vencida_v2')) as v(key, nombre)
 where t.key = v.key;
