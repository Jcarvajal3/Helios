-- ═══════════════════════════════════════════════════════════════════════════
-- Ronda — La garantía de un local tiene su cuenta en el libro
--
-- Los €10.000 que Ronda depositó en La Quinta el 19-09 nunca pasaron por el
-- libro: para la contabilidad no salieron de caja, y al local se le seguía
-- debiendo cada venta como si nadie le hubiera adelantado nada. Hacen falta
-- una cuenta y dos tipos de asiento:
--
--   · `merchant_prepaid` — lo que Ronda le adelantó a un local y todavía no
--     se ha gastado en liquidaciones. Saldo deudor, como la caja: es dinero de
--     Ronda que está en manos del local.
--   · `vault_deposit`    — el depósito: sale de caja y entra en la garantía.
--   · `vault_settlement` — una liquidación que cubre la garantía: baja lo que
--     se le debe al local y baja la garantía. La caja no se mueve.
--
-- Va sola porque un valor de enum nuevo no se puede usar en la misma
-- transacción que lo crea; la migración siguiente (20260929101000) los usa.
-- ═══════════════════════════════════════════════════════════════════════════

alter type ledger.account_type add value if not exists 'merchant_prepaid';
alter type ledger.transaction_type add value if not exists 'vault_deposit';
alter type ledger.transaction_type add value if not exists 'vault_settlement';
