-- ============================================================================
-- Helios — La pregunta al paciente usa la plantilla aprobada (docs/00 §15.5.2)
--
-- Meta aprobó `helios_confirmar_pago_en_cuotas` (Utility, `es`, 13 variables,
-- botones de respuesta rápida «Sí, acepto» · «No»), leída de 360dialog el
-- 2026-10-08. Desde 20261006002000 `confirmar_financiamiento` no tenía
-- plantilla y, fuera de la ventana de 24 h, la pregunta caía a la cola
-- manual. Desde aquí sale sola con la plantilla.
--
-- El orden de las variables es el del texto aprobado:
--   {{1}} nombre · {{2}} clínica · {{3}} y {{4}} la consulta (Meta no deja
--   repetir una variable) · {{5}} % comisión · {{6}} comisión · {{7}} % IVA ·
--   {{8}} IVA · {{9}} total · {{10}} total en Bs · {{11}} cuota ·
--   {{12}} fechas · {{13}} moneda («dólar» / «euro»).
-- Las produce `helios_enqueue_confirmation` (20261007000400). Los botones se
-- identifican por su posición: 0 = confirmar, 1 = rechazar.
-- ============================================================================

update public.notification_templates
   set wa_template_name = 'helios_confirmar_pago_en_cuotas',
       wa_template_lang = 'es',
       wa_template_params = array['nombre', 'clinica', 'monto_consulta', 'monto_consulta', 'servicio_pct',
                                  'cargo_servicio', 'iva_pct', 'iva_cargo_servicio', 'total', 'total_bs',
                                  'cuotas_monto', 'cuotas_fechas', 'moneda']
 where key = 'confirmar_financiamiento';
