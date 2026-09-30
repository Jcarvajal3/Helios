-- ============================================================================
-- Ronda — Retención y cifrado de las capturas de KYC
--
-- Política acordada:
--   * Selfie: se borra a las 72 horas. Su único uso es el cotejo facial, y una
--     vez hecho queda el embedding, que no es reversible a una cara.
--   * Cédula: se conserva cifrada, porque se necesita en casos de cobranza.
--
-- El cifrado lo aplica el servicio de KYC con AES-256-GCM y una clave maestra
-- que vive fuera de esta base. Así, filtrar la clave de servicio de Supabase
-- no basta para leer las cédulas: hacen falta dos secretos de dos sistemas.
-- ============================================================================

-- Bucket de archivo: cédulas cifradas. Nadie escribe aquí desde el cliente.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'kyc-archive',
  'kyc-archive',
  false,
  8388608,
  array['application/octet-stream']
)
on conflict (id) do update set public = false;

-- Sin políticas para `authenticated`: el bucket es exclusivo del servicio.

alter table kyc.verifications
  add column if not exists document_archive_path text,
  add column if not exists document_archived_at   timestamptz,
  add column if not exists selfie_deleted_at      timestamptz;

comment on column kyc.verifications.document_archive_path is
  'Ruta de la cédula cifrada en el bucket kyc-archive. La original se borra.';
comment on column kyc.verifications.selfie_deleted_at is
  'Cuándo se eliminó la selfie. El embedding sobrevive para detectar duplicados.';

-- ---------------------------------------------------------------------------

create or replace function kyc.mark_document_archived(
  p_verification_id uuid,
  p_archive_path    text
)
returns void
language sql
security definer
set search_path = kyc, pg_temp
as $$
  update kyc.verifications
    set document_archive_path = p_archive_path,
        document_archived_at  = now(),
        -- La ruta original deja de ser válida: el archivo en claro se borra
        -- del bucket de trabajo en cuanto se archiva el cifrado.
        document_path         = null,
        updated_at            = now()
  where id = p_verification_id;
$$;

create or replace function kyc.mark_selfie_deleted(p_verification_id uuid)
returns void
language sql
security definer
set search_path = kyc, pg_temp
as $$
  update kyc.verifications
    set selfie_deleted_at = now(),
        selfie_path       = null,
        updated_at        = now()
  where id = p_verification_id;
$$;

-- Selfies que ya cumplieron su retención de 72 horas.
--
-- Solo entran verificaciones ya resueltas: borrar la selfie de una que sigue
-- en revisión manual dejaría al revisor sin nada que mirar.
create or replace function kyc.selfies_due_for_deletion(p_limit int default 100)
returns table (verification_id uuid, selfie_path text)
language sql
security definer
set search_path = kyc, pg_temp
as $$
  select id, selfie_path
  from kyc.verifications
  where selfie_path is not null
    and selfie_deleted_at is null
    and status in ('approved', 'rejected')
    and updated_at < now() - interval '72 hours'
  order by updated_at
  limit p_limit;
$$;

revoke all on function kyc.mark_document_archived(uuid, text) from public, anon, authenticated;
revoke all on function kyc.mark_selfie_deleted(uuid) from public, anon, authenticated;
revoke all on function kyc.selfies_due_for_deletion(int) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Vista de cumplimiento
-- ---------------------------------------------------------------------------
-- Para responder "¿estamos cumpliendo nuestra política de retención?" sin
-- tener que escribir una consulta a mano cada vez.

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
  count(*) filter (
    where document_path is not null and document_archive_path is null
  )                                                        as cedulas_sin_cifrar
from kyc.verifications;
