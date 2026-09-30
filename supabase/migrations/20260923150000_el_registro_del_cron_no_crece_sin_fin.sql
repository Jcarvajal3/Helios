-- ============================================================================
-- Ronda — El registro de pg_cron no crece sin fin
--
-- pg_cron escribe una fila en `cron.job_run_details` por cada ejecución y no
-- borra ninguna. El despachador de push corre cada 15 segundos: son 5.760
-- filas al día solo de ese trabajo, y a 2026-09-23 el registro ocupaba 29 de
-- los 50 MB de la base de producción (175.000 filas, el 97 % del despachador).
-- En el plan Free la base pasa a solo lectura a los 500 MB.
--
-- Qué se guarda:
--   · los trabajos frecuentes (cada N segundos o `*/N`), 3 días;
--   · todo lo demás —mora, liquidaciones, niveles, recordatorios, tasa—, 90
--     días, que es lo que hace falta para responder "¿corrió la mora el día X?";
--   · un fallo, 90 días aunque sea de un trabajo frecuente.
--
-- La fecha es `end_time` y, si la corrida nunca terminó, `start_time`: una
-- corrida sin fin también caduca.
--
-- El borrado libera el espacio para reutilizarlo, pero el fichero no encoge:
-- `VACUUM FULL` exige ser dueño de la tabla, y su dueño es `supabase_admin`.
-- Lo que importa es que deja de crecer.
--
-- Permisos: pg_cron ejecuta el trabajo como `postgres`, que tiene DELETE sobre
-- `cron.job_run_details`. La función no es SECURITY DEFINER y ningún rol de la
-- API puede ejecutarla.
-- ============================================================================

create or replace function public.purge_cron_log()
returns integer
language plpgsql
set search_path = public, pg_temp
as $fn$
declare
  v_count integer;
begin
  delete from cron.job_run_details d
   where coalesce(d.end_time, d.start_time) < now() - interval '90 days'
      or (coalesce(d.end_time, d.start_time) < now() - interval '3 days'
          and d.status = 'succeeded'
          and exists (
            select 1 from cron.job j
             where j.jobid = d.jobid
               and (j.schedule like '%second%' or j.schedule like '*/%')
          ));
  get diagnostics v_count = row_count;
  return v_count;
end;
$fn$;

comment on function public.purge_cron_log() is
  'Borra el registro de pg_cron: 3 días de los trabajos frecuentes, 90 del resto y de los fallos.';

revoke all on function public.purge_cron_log() from public, anon, authenticated;

-- 10:40 AM Caracas: detrás del barrido diario (10:00-10:20) y con los bares
-- cerrados. El minuto 40 de las 14 UTC no lo usa ningún otro trabajo.
select cron.schedule(
  'helios_cron_log_purge',
  '40 14 * * *',
  $cron$ select public.purge_cron_log(); $cron$
);

-- La primera limpieza no espera a mañana.
select public.purge_cron_log();
