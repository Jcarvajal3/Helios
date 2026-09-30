-- ============================================================================
-- Ronda — Motivo de rechazo: lo rechazó el proveedor
--
-- La verificación de identidad pasa a hacerla Didit de punta a punta. Cuando
-- rechaza, el motivo concreto viene en sus avisos (documento caducado, poca
-- similitud facial, etc.), pero ninguno de los valores que teníamos describe
-- honestamente lo ocurrido: 'face_mismatch' o 'liveness_failed' afirmarían qué
-- comprobación falló, y esa decisión ya no la tomamos nosotros.
--
-- El detalle real se guarda en `rejection_detail` y en `decision_log`; este
-- valor solo dice de dónde viene el veredicto.
--
-- Va en su propio archivo porque Postgres no deja usar un valor de enum en la
-- misma transacción en que se añade.
-- ============================================================================

alter type kyc.rejection_reason add value if not exists 'provider_declined';
