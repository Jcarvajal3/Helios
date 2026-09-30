-- ============================================================================
-- Ronda — El KYC propio se va
--
-- La verificación de identidad es Didit y nada más. El servicio propio
-- (Ronda-kyc, en Fly.io) se destruyó el 2026-09-23 y no vuelve. Esta migración
-- quita lo que solo existía para él:
--
--   · las funciones de su ciclo —reclamar expedientes, registrar su veredicto,
--     archivar la cédula, borrar la selfie, auditar el descifrado—, que solo
--     llamaba ese servicio;
--   · las dos RPC del flujo de fotos de la app (`submit_kyc_verification`,
--     `my_kyc_status`), que la app dejó de llamar al pasar a Didit;
--   · `kyc.face_embeddings`, vacía, y con ella la extensión `vector`, que no
--     usa ninguna otra columna;
--   · las políticas del bucket `kyc-documents`: nadie sube ni lee ahí. Los
--     archivos y los buckets se borran desde el panel de Supabase, porque
--     Storage no deja borrarlos por SQL.
--
-- Lo que usa Didit se queda como está: `start_kyc_verification`,
-- `confirm_kyc_data`, `kyc_*`, `admin_*`, el barrido `expire_stuck` y
-- `apply_status`. Esta última se redefine idéntica, sin el UPDATE a
-- `face_embeddings`; ese UPDATE corría en cada cambio de estado y revienta en
-- cuanto la tabla no existe.
--
-- Las columnas de `kyc.verifications` que llenaba el servicio (puntuaciones,
-- rutas de las fotos) se quedan: son el historial de las verificaciones viejas
-- y las leen las fichas del super admin.
-- ============================================================================

create or replace function kyc.apply_status(
  p_verification_id uuid,
  p_status kyc.verification_status,
  p_reason kyc.rejection_reason default null,
  p_actor text default 'system',
  p_signals jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $function$
declare
  v_row kyc.verifications%rowtype;
begin
  select * into v_row from kyc.verifications
  where id = p_verification_id for update;

  if not found then
    raise exception 'Verificación no encontrada' using errcode = 'P0002';
  end if;

  -- Sin datos no hay identidad que aprobar. `data_confirmed_at` lo sella Didit
  -- en todo estado terminal y lo sellaba la persona al confirmar en el flujo
  -- propio; `extracted_document` es lo que ese flujo le enseñaba para
  -- confirmar. Con cualquiera de los dos, aprobar acaba en un perfil activo.
  -- Sin ninguno, acababa en una verificación aprobada con el perfil sin
  -- verificar — y la app entraba por la verificación.
  if p_status = 'approved'
     and v_row.data_confirmed_at is null
     and v_row.extracted_document is null then
    raise exception
      'No se puede aprobar una verificación sin datos de identidad. Pide una verificación nueva.'
      using errcode = '22023';
  end if;

  update kyc.verifications
    set status           = p_status,
        rejection_reason = p_reason,
        reviewed_at      = case when p_actor <> 'system' then now() else reviewed_at end,
        claimed_at       = case when p_status = 'processing' then claimed_at else null end,
        updated_at       = now()
  where id = p_verification_id;

  insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
  values (p_verification_id, v_row.status, p_status, p_actor, p_signals);

  -- Aprobar ya no escribe nada en el perfil: eso pasa cuando la persona
  -- confirma. Si confirmó antes que llegara el veredicto —el caso de la
  -- revisión manual—, esta llamada es la que lo activa.
  if p_status = 'approved' then
    perform kyc.advance_profile(p_verification_id);
  end if;

  return jsonb_build_object('ok', true, 'status', p_status);
end;
$function$;

drop function if exists kyc.claim_pending(integer);
drop function if exists kyc.record_decision(
  uuid, numeric, numeric, numeric, boolean, text, text, date,
  kyc.rejection_reason, text, text, jsonb
);
drop function if exists kyc.mark_document_archived(uuid, text);
drop function if exists kyc.mark_selfie_deleted(uuid);
drop function if exists kyc.selfies_due_for_deletion(integer);
drop function if exists kyc.log_document_decrypt(uuid, uuid);

drop function if exists public.submit_kyc_verification(uuid, text, text);
drop function if exists public.my_kyc_status();

drop table if exists kyc.face_embeddings;
drop extension if exists vector;

drop policy if exists kyc_upload_own_folder on storage.objects;
drop policy if exists kyc_update_own_folder on storage.objects;
drop policy if exists kyc_read_own_folder on storage.objects;
drop policy if exists kyc_read_admin on storage.objects;
