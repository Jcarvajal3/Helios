-- ============================================================================
-- Ronda — El barrido de verificaciones atascadas corre en la base
--
-- `kyc.expire_stuck()` (20260826230000) es lo único que saca de `processing`
-- una sesión de Didit que nunca terminó: tras 24 horas sin movimiento la pasa
-- a `manual_review`, y así llega a la cola de Verificaciones, donde se le pide
-- a la persona una verificación nueva. Sin el barrido la sesión se queda en
-- `processing` para siempre: la persona sigue viendo "Verificando tu
-- identidad" y el panel no la enseña en ninguna cola.
--
-- Hasta ahora la llamaba el ciclo horario de retención de Ronda-kyc, el
-- servicio propio de antes de Didit (`RetentionJob.run_once`). En producción
-- ese servicio sigue encendido —`pg_stat_statements` lo ve llamarla una vez
-- por hora desde agosto— pero ya no hace nada más que sirva: `claim_pending`
-- solo reclama expedientes con fotos subidas, que en el flujo de Didit no
-- existen, y no queda ninguna selfie ni cédula que borrar. La cola dependía de
-- un servicio que se da por apagado. Con este trabajo, apagarlo ya no rompe
-- nada.
--
-- Mientras los dos convivan, el barrido pasa dos veces por hora sin efecto
-- doble: el UPDATE solo encuentra filas que siguen en `processing`, así que el
-- segundo no mueve ninguna ni escribe en la bitácora.
--
-- Permisos: la función es SECURITY DEFINER, su dueño es `postgres` y es el
-- único rol con EXECUTE (`revoke all ... from public, anon, authenticated`), así
-- que ningún rol de la API puede llamarla. pg_cron ejecuta cada trabajo con el
-- rol que lo programó, que al aplicar una migración es `postgres`, como el de
-- todos los trabajos que ya hay en `cron.job`. No hay que conceder nada.
--
-- `cron.schedule` con un nombre que ya existe reemplaza el trabajo, así que
-- volver a correr esta migración no lo duplica. El minuto 35 no lo usa ningún
-- otro trabajo.
-- ============================================================================

select cron.schedule(
  'helios_kyc_expire_stuck',
  '35 * * * *',
  $cron$ select kyc.expire_stuck(); $cron$
);
