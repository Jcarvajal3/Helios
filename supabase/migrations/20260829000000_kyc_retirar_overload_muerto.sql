-- ============================================================================
-- Ronda — Retirar el `kyc_attach_didit_session` de tres argumentos
--
-- La versión de 20260828140000 recibía (verification_id, user_id, session_id).
-- La de 20260828154500 añadió el enlace de la sesión y, al ser una firma
-- distinta, no reemplazó a la anterior: `create or replace` reemplaza por
-- firma, no por nombre. Quedaron las dos.
--
-- Convivir no rompe nada hoy —la función de borde llama con los cuatro
-- argumentos con nombre, así que PostgREST resuelve sin ambigüedad a la
-- correcta— pero la vieja sigue siendo `security definer`, sigue concedida a
-- `service_role`, y hace algo sutilmente distinto: guarda la sesión SIN el
-- enlace. Quien la llamara por error no vería ningún fallo; simplemente la
-- persona que abandonara la verificación se quedaría otra vez sin el botón de
-- "Continuar", y el motivo estaría a tres migraciones de distancia.
--
-- Una puerta de servicio que ya no lleva a ninguna parte se tapia.
-- ============================================================================

drop function if exists public.kyc_attach_didit_session(uuid, uuid, text);
