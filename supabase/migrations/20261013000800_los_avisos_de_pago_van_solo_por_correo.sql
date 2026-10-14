-- ============================================================================
-- Helios — Los avisos de pago van solo por correo (2026-10-13)
--
-- Decidido por Javier el 2026-10-13, para ahorrar en WhatsApp: «Pago
-- confirmado» (`pago_recibido`) y «No pudimos confirmar el pago»
-- (`pago_rechazado`) dejan el WhatsApp y salen solo por correo. Los
-- recordatorios de cuota siguen por los dos canales (20261013000700).
--
-- `notify_payment_result` ya encola un mensaje por cada canal de la
-- plantilla, así que basta con cambiar `channels`. Un paciente sin correo (o
-- con un correo que rebotó) no recibe ninguno de los dos avisos.
-- Sus plantillas de Meta (docs/00 §15.7) ya no hacen falta.
-- ============================================================================

update public.notification_templates
   set channels = array['email'],
       wa_template_params = '{}'::text[],
       wa_template_name = null,
       help = 'Solo por correo desde el 2026-10-13 (para ahorrar en WhatsApp). Sin correo, el paciente no lo recibe.'
 where key in ('pago_recibido', 'pago_rechazado');
