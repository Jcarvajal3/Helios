-- ============================================================================
-- Helios — Fuera la foto de la proyección de los lunes
--
-- Heredado de Ronda: cada lunes a las 10:30 se guardaba la proyección de caja
-- de las 8 semanas siguientes (`cash_forecast_snapshots`) para compararla
-- después con lo que pasó («Proyectado frente a real»). Era la lógica del
-- cierre de los lunes de Ronda. En Helios a la clínica se le paga el día
-- siguiente al vencimiento de cada cuota (días 8 y 15 de cada orden), no los
-- lunes (Javier, 2026-10-21: «NO debe funcionar como Ronda, donde se paga
-- todo los lunes»), y el panel ya no enseña esa comparación.
--
-- Solo se quita el cron. La tabla (con las fotos que ya hay) y sus dos
-- funciones (`helios_snapshot_cash_forecast`, `admin_forecast_vs_actual`) se
-- quedan sin uso: no se borra ningún dato.
-- ============================================================================

select cron.unschedule('helios_cash_forecast_snapshot')
where exists (select 1 from cron.job where jobname = 'helios_cash_forecast_snapshot');
