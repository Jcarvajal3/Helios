-- ============================================================================
-- Helios — La comisión de la secretaria tiene cuenta en el libro (H5, parte 1)
--
-- Por cada financiamiento confirmado, quien lo registró gana una comisión
-- (docs/00 §6) que Helios le paga a la clínica en la transferencia de los
-- lunes. En el libro:
--
--   Dr commission_expense (Helios, sin dueño)  /  Cr merchant_payable (clínica)
--
-- con su propia clase de asiento (`staff_commission`) y su propio motivo de
-- liquidación (`staff_commission`), para que la transferencia se pueda partir
-- en «consultas» y «comisiones del personal».
--
-- Solo los valores de enum, en su propia migración: un valor recién añadido
-- con `alter type … add value` no se puede usar en la misma transacción.
-- ============================================================================

alter type ledger.account_type     add value if not exists 'commission_expense';
alter type ledger.transaction_type add value if not exists 'staff_commission';
alter type public.settlement_reason add value if not exists 'staff_commission';
