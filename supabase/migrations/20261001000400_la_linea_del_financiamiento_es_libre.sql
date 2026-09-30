-- ============================================================================
-- Helios — La línea del financiamiento es libre
--
-- Complemento de la poda (20261001000000): la encontraron las suites al crear
-- deuda sin catálogo.
--
-- Ronda obligaba a que toda línea de un cobro fuera un producto de la carta
-- (20260918190000_todo_cobro_es_de_la_carta: `charge_items_product_required`,
-- `check (product_id is not null) not valid`). Helios no tiene carta (D-H4):
-- la secretaria teclea un monto libre y un concepto, y `charge_items` guarda
-- UNA línea con `product_id` nulo y `name` = concepto (docs/00 §4.4, H8). Con
-- este check, ningún financiamiento se podría registrar.
-- ============================================================================

alter table public.charge_items drop constraint charge_items_product_required;
