-- ============================================================================
-- Ronda — Que ningún expediente se quede abierto para siempre
--
-- `kyc.selfies_due_for_deletion` exige `status in ('approved','rejected')`, así
-- que la política de 72 horas solo corre para lo que se resolvió. Todo lo que
-- se quedó a medias conserva selfie y cédula indefinidamente:
--
--   · 'processing' eterno — el trabajo envenenado que nadie recogía.
--   · 'pending' abandonado con las capturas ya subidas: el usuario cerró la
--     app entre subir las fotos y confirmar sus datos.
--   · 'manual_review' que nadie atiende. Aquí la excepción es deliberada
--     mientras la revisión ocurre, pero sin tope de edad se vuelve permanente.
--
-- Resolver estos casos no es solo higiene de datos: al pasar a un estado
-- terminal, el reloj de retención arranca solo y la selfie se borra sin que
-- nadie tenga que acordarse.
--
-- Esta función es idempotente y barata; la llama el servicio en su ciclo
-- horario de retención.
-- ============================================================================

create or replace function kyc.expire_stuck()
returns jsonb
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $$
declare
  v_processing int := 0;
  v_pending    int := 0;
begin
  -- Una verificación tarda segundos. Un día en 'processing' significa que
  -- nadie va a terminarla: la ve una persona, que además es la señal de que
  -- algo va mal en el servicio.
  with atascadas as (
    update kyc.verifications
       set status           = 'manual_review',
           rejection_detail = 'Se quedó procesando más de 24 horas.',
           claimed_at       = null,
           updated_at       = now()
     where status = 'processing'
       and updated_at < now() - interval '24 hours'
    returning id
  )
  insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
  select id, 'processing', 'manual_review', 'system',
         jsonb_build_object('reason', 'stuck_processing')
    from atascadas;

  get diagnostics v_processing = row_count;

  -- Un 'pending' con capturas subidas es alguien que abandonó a mitad. Se
  -- expira para que la retención pueda llevarse sus fotos; si vuelve, la app
  -- le abre una verificación nueva.
  with abandonadas as (
    update kyc.verifications
       set status           = 'rejected',
           rejection_reason = 'manual_rejection',
           rejection_detail = 'Caducó sin completar la verificación.',
           updated_at       = now()
     where status = 'pending'
       and document_path is not null
       and selfie_path is not null
       and created_at < now() - interval '7 days'
    returning id
  )
  insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
  select id, 'pending', 'rejected', 'system',
         jsonb_build_object('reason', 'abandoned')
    from abandonadas;

  get diagnostics v_pending = row_count;

  return jsonb_build_object(
    'stuck_processing', v_processing,
    'abandoned_pending', v_pending
  );
end;
$$;

revoke all on function kyc.expire_stuck() from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- Que la vista de cumplimiento sirva de alarma
-- ---------------------------------------------------------------------------
--
-- `cedulas_sin_cifrar` contaba toda fila con documento y sin archivo cifrado,
-- lo que incluye la cola normal de pendientes. Mezclaba backlog con fallo, así
-- que el número nunca era cero y no se podía alertar sobre él. Filtrando por
-- verificaciones YA RESUELTAS, cualquier valor distinto de cero es un
-- archivado que falló de verdad.
--
-- Se añade además la cuenta de expedientes viejos sin resolver, que es lo que
-- `expire_stuck` debería mantener a raya.

-- Las cinco columnas originales se conservan en su sitio y con su nombre:
-- `create or replace view` no admite quitar ni reordenar, solo añadir al
-- final. Lo único que cambia es la definición de `cedulas_sin_cifrar`.
create or replace view kyc.retention_status as
select
  count(*) filter (where selfie_path is not null)          as selfies_en_disco,
  count(*) filter (where selfie_deleted_at is not null)    as selfies_borradas,
  count(*) filter (
    where selfie_path is not null
      and selfie_deleted_at is null
      and status in ('approved', 'rejected')
      and updated_at < now() - interval '72 hours'
  )                                                        as selfies_vencidas,
  count(*) filter (where document_archive_path is not null) as cedulas_cifradas,
  -- Antes contaba toda fila con documento y sin cifrar, lo que incluía la cola
  -- normal de pendientes: el número nunca era cero y no servía de alarma.
  -- Limitado a verificaciones YA RESUELTAS, cualquier valor distinto de cero
  -- es un archivado que falló de verdad.
  count(*) filter (
    where status in ('approved', 'rejected', 'manual_review')
      and document_path is not null
      and document_archive_path is null
  )                                                        as cedulas_sin_cifrar,
  count(*) filter (
    where status = 'processing'
      and updated_at < now() - interval '24 hours'
  )                                                        as procesando_atascadas,
  count(*) filter (
    where status = 'manual_review'
      and updated_at < now() - interval '7 days'
  )                                                        as revision_estancada
from kyc.verifications;
