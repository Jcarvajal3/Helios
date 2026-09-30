-- ============================================================================
-- Ronda — El tipo para "llegaste al primer nivel"
--
-- Sola y de una línea por la misma razón que `20260830210000` y que
-- `20260822170000`: **un valor nuevo de un enum y su primer uso no caben en la
-- misma transacción**, y Supabase corre cada archivo de migración dentro de
-- una. El uso va en la siguiente.
--
-- Por qué un motivo propio y no `promotion`. Subir de nivel 1 a 2 es haber
-- pagado; pasar de 0 a 1 es haber verificado la identidad. Son dos hechos
-- distintos con dos causas distintas, y `level_changes` existe justamente para
-- poder contestar seis meses después por qué cambió el nivel de alguien.
-- Meterlos en el mismo cajón obligaría a mirar `detail` para distinguirlos.
-- ============================================================================

alter type public.level_change_reason add value if not exists 'kyc_approved';
