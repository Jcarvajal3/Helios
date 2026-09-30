-- ============================================================================
-- Ronda — Los cobros de un grupo tienen índice
--
-- `charges` tiene nueve índices y ninguno por `group_id`, y lo filtran por él
-- `group_detail` (que la app sondea con la pantalla abierta), `join_group`,
-- `find_group_by_code`, `confirm_charge_as_group`, `helios_group_open_charges`,
-- el archivo de grupos y el panel. Sin índice, cada una de esas llamadas
-- recorre la tabla entera de cobros para quedarse con los tres o cuatro de un
-- grupo: hoy son 35 filas y no se nota; con cientos de miles, es el tiempo de
-- cada sondeo.
--
-- `confirmed_at` va detrás porque esas consultas piden los cobros de un grupo
-- en orden de la noche. Parcial en `group_id is not null`: los consumos
-- sueltos, que son la mayoría, no entran.
--
-- Sin `concurrently`: dentro de la transacción de una migración falla, y con
-- el tamaño de la tabla se crea en milisegundos.
-- ============================================================================

create index if not exists charges_group_confirmed_idx
  on public.charges (group_id, confirmed_at)
  where group_id is not null;
