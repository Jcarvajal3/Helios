-- ============================================================================
-- Ronda — Aviso de saldo devuelto
--
-- Va en su propia migración porque `alter type ... add value` no puede usarse
-- en la misma transacción que lo añade: la siguiente migración
-- (20260824121000_group_entry_ticket) emite avisos de este tipo desde
-- `close_group`, así que el valor tiene que existir ya commiteado.
--
-- Por qué hace falta el aviso: con el ticket de entrada, entrar a un grupo
-- RETIENE saldo. Cuando el grupo se cierra, ese saldo reaparece solo. Sin un
-- aviso, el usuario ve su disponible subir sin explicación — y lo contrario
-- (verlo bajar al entrar) ya se lo explicó la pantalla de aceptación.
-- ============================================================================

alter type public.notification_type add value if not exists 'group_released';
