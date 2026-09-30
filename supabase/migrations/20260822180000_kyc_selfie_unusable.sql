-- ============================================================================
-- Ronda — Motivo de rechazo: selfie inservible
--
-- Hasta ahora, una selfie que no se podía cotejar (media cara dentro del
-- encuadre, perfil, foto movida, rostro diminuto) no tenía cómo rechazarse:
-- o se colaba entera al cotejo facial y salía de ahí con un puntaje que no
-- medía identidad, o se rechazaba como 'liveness_failed', que le dice al
-- usuario que sospechamos de él en vez de pedirle que repita la foto.
--
-- Va en su propio archivo porque Postgres no deja usar un valor de enum en la
-- misma transacción en que se añade.
-- ============================================================================

alter type kyc.rejection_reason add value if not exists 'selfie_unusable';
