-- ============================================================================
-- Ronda — Corrige kyc.review(): la revisión manual nunca funcionó
--
-- Bug preexistente de 20260821234000_kyc_decision.sql, detectado al conectar
-- la cola del super admin.
--
-- `kyc.review()` llamaba a `kyc.apply_status()` pasando literales sin tipar
-- en dos parámetros que son ENUM (`kyc.verification_status` y
-- `kyc.rejection_reason`). PL/pgSQL los toma como `text` y no encuentra
-- ninguna función que encaje:
--
--   ERROR: function kyc.apply_status(uuid, text, text, text, jsonb) does not exist
--
-- Es un error de RESOLUCIÓN, no de ejecución: falla siempre, en la primera
-- llamada, sin importar los datos. Es decir, **aprobar o rechazar una
-- verificación a mano nunca ha llegado a funcionar**. No se había notado
-- porque no existía todavía ninguna pantalla que lo llamara.
--
-- El linter de Supabase (`supabase db lint`) ya lo reportaba.
-- ============================================================================

create or replace function kyc.review(
  p_verification_id uuid,
  p_approve         boolean,
  p_reviewer        uuid,
  p_note            text default null
)
returns jsonb
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $$
declare
  v_status kyc.verification_status;
  v_reason kyc.rejection_reason;
begin
  -- Los tipos se resuelven en variables declaradas en vez de dentro de la
  -- llamada: así el error, si algún día vuelve, salta al compilar la función
  -- y no en producción.
  v_status := case when p_approve then 'approved' else 'rejected' end;
  v_reason := case when p_approve then null else 'manual_rejection' end;

  update kyc.verifications
    set reviewed_by = p_reviewer,
        rejection_detail = coalesce(p_note, rejection_detail)
  where id = p_verification_id;

  if not found then
    raise exception 'Verificación no encontrada' using errcode = 'P0002';
  end if;

  return kyc.apply_status(
    p_verification_id,
    v_status,
    v_reason,
    p_reviewer::text,
    jsonb_build_object('note', p_note)
  );
end;
$$;

revoke all on function kyc.review(uuid, boolean, uuid, text) from public, anon, authenticated;
