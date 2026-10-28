-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — Ana Lara y Eleazar Wacher llevan su título
--
-- Javier (2026-10-28): el mensaje del botón de WhatsApp del directorio tiene
-- que llamar al médico con su título («Hola, Dra. …»), y estos dos eran los
-- únicos publicados sin título en su ficha (se dieron de alta antes de que el
-- alta lo pidiera, 20261028120000). Los títulos los dio Javier.
--
-- El título vive en la ficha de la clínica (`merchants.doctor_title`): de ahí
-- lo toman la tarjeta del directorio, su mensaje y los mensajes al paciente
-- (`helios_doctor_name`, `helios_doctor_ref`). Solo se pone si todavía no
-- tienen uno, para no pisar un cambio hecho a mano.
-- ═══════════════════════════════════════════════════════════════════════════

update public.merchants
   set doctor_title = 'Dra.', updated_at = now()
 where id = '515adcb8-b90e-4f59-92bc-58d15d9be244'   -- Ana Lara, Grupo Médico 708
   and doctor_title is null;

update public.merchants
   set doctor_title = 'Dr.', updated_at = now()
 where id = '80c9daff-8cd8-40e4-9a7c-25c477839629'   -- Eleazar Wacher, Hospital de Clínicas Caracas
   and doctor_title is null;
