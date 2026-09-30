-- ============================================================================
-- Ronda — Los valores de enum que necesita el segundo lote
--
-- Un valor nuevo de un enum **no se puede usar en la misma transacción que lo
-- añade**, y cada migración corre en la suya. Así que van todos juntos aquí y
-- las funciones que los usan, en los archivos siguientes. Es el mismo reparto
-- que ya hicieron la lista de espera, el bloqueo manual y el cargo condonado.
--
--   partial              una liquidación que se pagó a medias. Hoy un pago a
--                        un local es todo o nada, y eso obliga a mentir
--                        —marcar como pagado lo que no se pagó entero— o a no
--                        registrar nada.
--
--   reverted             un consumo confirmado que se deshizo. Es la válvula
--                        para el cajero que teclea €500 en vez de €50.
--
--   needs_retry          la verificación no se pudo evaluar y hay que
--                        repetirla. No es un rechazo: nadie ha dicho que la
--                        persona no sea quien dice, solo que el expediente
--                        llegó vacío.
--
--   kyc_retry_requested  el aviso que acompaña a lo anterior.
-- ============================================================================

alter type public.settlement_status add value if not exists 'partial';

alter type public.charge_status add value if not exists 'reverted';

alter type kyc.rejection_reason add value if not exists 'needs_retry';

alter type public.notification_type add value if not exists 'kyc_retry_requested';
