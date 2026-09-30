-- ============================================================================
-- Ronda — Cron de dinero
--
-- docs/01-ARQUITECTURA.md §7: el cierre de ciclo corre con pg_cron, dentro
-- de Postgres, transaccional — sin riesgo de timeout de una función
-- serverless en un cierre masivo.
--
-- Los dos jobs corren TODOS los días a las 10:05 AM America/Caracas (justo
-- después de que cambia el día operativo). No hace falta acotar
-- run_scheduled_settlements a los días 15/último: como las cuotas solo
-- vencen esos días (docs/00-BASES §2.2), en cualquier otro día el barrido
-- simplemente no encuentra nada que liquidar. Acotar el cron por fecha solo
-- añadía una segunda fuente de verdad para "qué día es día de pago",
-- duplicando la regla que ya vive en helios_installment_due_dates().
--
-- Si el proyecto de Supabase no tiene pg_cron habilitado, esta migración
-- falla de forma ruidosa y visible — mejor eso que un cron silenciosamente
-- ausente. Las funciones siguen siendo invocables a mano por el super admin
-- aunque el cron no llegue a programarse.
-- ============================================================================

create extension if not exists pg_cron with schema extensions;

-- Caracas es UTC-4 todo el año (sin horario de verano): 10:05 AM local = 14:05 UTC.
select cron.schedule(
  'helios_process_mora',
  '5 14 * * *',
  $$ select public.process_mora(); $$
);

select cron.schedule(
  'helios_scheduled_settlements',
  '10 14 * * *',
  $$ select public.run_scheduled_settlements(public.helios_business_date(now())); $$
);
