-- ============================================================================
-- Helios — El webhook despierta al lector (docs/03)
--
-- 20261021200000 dejó `helios_lector_despertar` solo para el cron. El webhook
-- de WhatsApp también la llama, con la service_role, al encolar una captura:
-- así el lector la lee al momento y no al minuto siguiente.
-- ============================================================================

grant execute on function public.helios_lector_despertar() to service_role;
