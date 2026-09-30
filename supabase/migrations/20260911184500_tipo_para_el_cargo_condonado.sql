-- ============================================================================
-- Ronda — El aviso de "te quitamos el cargo"
--
-- Un valor nuevo de un enum no se puede usar en la misma transacción que lo
-- añade, y cada migración corre en la suya. Por eso el tipo va solo en este
-- archivo y la función que lo usa, en el siguiente — el mismo reparto que ya
-- hicieron la lista de espera y el bloqueo manual.
--
-- El aviso existe porque la deuda de alguien no puede bajar en silencio, igual
-- que no sube en silencio: cuando el motor cobra los €2 se avisa, y cuando se
-- le quitan también.
-- ============================================================================

alter type public.notification_type add value if not exists 'late_fee_waived';
