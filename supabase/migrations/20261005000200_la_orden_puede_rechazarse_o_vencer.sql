-- ============================================================================
-- Helios — La orden puede rechazarse o vencer (docs/00 §5.1, docs/01 §1.3.1)
--
-- Con la confirmación del paciente, una orden `pending` termina de tres
-- maneras: el paciente dice Sí (`confirmed`), dice No (`declined`) o no
-- contesta a tiempo (`expired`). Los dos estados nuevos van en su propia
-- migración: un valor de enum recién añadido no se puede usar en el mismo
-- archivo (supabase/poda/aplicar.mjs).
-- ============================================================================

alter type public.charge_status add value if not exists 'declined';
alter type public.charge_status add value if not exists 'expired';
