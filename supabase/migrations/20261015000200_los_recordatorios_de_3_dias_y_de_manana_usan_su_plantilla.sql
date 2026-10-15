-- ============================================================================
-- Helios — Los recordatorios de 3 días y de mañana usan su plantilla (2026-10-15)
--
-- 20261015000100 dejó sin conectar `helios_cuota_en_3_dias` y
-- `helios_cuota_vence_manana` porque su texto aprobado dice «Paga a tiempo
-- para subir de nivel y aumentar tu limite de credito!» («crédito» y la
-- promesa de que el límite crece no van en lo externo). Javier las conecta
-- como EXCEPCIÓN consciente: él incluyó esa frase a petición del CEO
-- (2026-10-15). La regla sigue valiendo para todo lo demás.
--
-- Variables (las de 20261013000700, en este orden): nombre, fecha, cuota,
-- orden, clínica, moneda y cuentas de cobro.
-- ============================================================================

update public.notification_templates
   set wa_template_name = 'helios_cuota_en_3_dias', wa_template_lang = 'es'
 where key = 'cuota_en_3_dias';

update public.notification_templates
   set wa_template_name = 'helios_cuota_vence_manana', wa_template_lang = 'es'
 where key = 'cuota_manana';
