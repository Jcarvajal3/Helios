-- ============================================================================
-- Helios — Se conectan las plantillas `_v2` del paciente (2026-10-20)
--
-- Javier avisó el 2026-10-20 que Meta aprobó las cinco plantillas de
-- docs/00 §15.8. Desde aquí, fuera de la ventana de 24 h, la pregunta y los
-- recordatorios salen con los textos nuevos: nombran al médico, los
-- bolívares van junto al Pago Móvil y los recordatorios traen los botones
-- «Ya pagué» y «Hablar con alguien» (que atiende el bot del paciente:
-- `paciente:ya_pague`, `paciente:ayuda`).
--
--   confirmar_financiamiento → helios_confirmar_pago_en_cuotas_v2 (10 variables;
--                              los botones Sí/No de siempre)
--   cuota_en_3_dias          → helios_cuota_en_3_dias_v2
--   cuota_manana             → helios_cuota_vence_manana_v2
--   cuota_hoy                → helios_cuota_vence_hoy_v2 (ya en `es`)
--   cuota_vencida_d1         → helios_cuota_vencida (nueva)
--
-- Los mensajes que ya estaban en la cola guardaron su plantilla al
-- encolarse (`outbound_messages.wa_template`) y salen con la vieja, que sigue
-- aprobada.
--
-- Con los botones, un recordatorio con la ventana abierta sale como mensaje
-- con botones si cabe en 1024 caracteres; si no, con su plantilla.
-- ============================================================================

update public.notification_templates
   set wa_template_name = 'helios_confirmar_pago_en_cuotas_v2',
       wa_template_lang = 'es',
       wa_template_params = array['nombre', 'medico', 'monto_consulta', 'servicio_pct', 'cargo_servicio',
                                  'iva_pct', 'iva_cargo_servicio', 'total', 'cuotas_detalle', 'moneda']
 where key = 'confirmar_financiamiento';

update public.notification_templates t
   set wa_template_name = v.nombre,
       wa_template_lang = 'es',
       wa_template_params = array['nombre', 'monto', 'medico', 'fecha', 'monto_bs', 'moneda',
                                  'pago_movil_banco', 'pago_movil_telefono', 'pago_movil_rif', 'pago_movil_titular'],
       wa_buttons = '[{"id":"paciente:ya_pague","title":"Ya pagué"},{"id":"paciente:ayuda","title":"Hablar con alguien"}]'::jsonb
  from (values ('cuota_en_3_dias',  'helios_cuota_en_3_dias_v2'),
               ('cuota_manana',     'helios_cuota_vence_manana_v2'),
               ('cuota_hoy',        'helios_cuota_vence_hoy_v2'),
               ('cuota_vencida_d1', 'helios_cuota_vencida')) as v(key, nombre)
 where t.key = v.key;
