-- ============================================================================
-- Ronda — Los dos valores de enum que necesita el cargo por mora
--
-- Van SOLOS en esta migración por lo de siempre: Postgres deja añadir un valor
-- a un enum dentro de una transacción, pero **no deja usarlo hasta que esa
-- transacción termina**. El CLI corre cada archivo en la suya, así que quien
-- los usa vive en el archivo siguiente (20260830170000).
--
-- Mismo motivo por el que `vat_payable` viajó solo en 20260827090000.
-- ============================================================================

-- El asiento del cargo: Dr user_receivable / Cr platform_revenue. No es un
-- consumo ni un ajuste manual, y meterlo en 'charge' lo haría aparecer como
-- venta en todas las métricas de volumen.
alter type ledger.transaction_type add value if not exists 'late_fee';

-- El aviso al usuario. La deuda de alguien no puede crecer en silencio: ya hay
-- un aviso para el congelamiento del día 1 ('account_frozen'), pero ese no
-- habla de dinero.
alter type public.notification_type add value if not exists 'late_fee_charged';
