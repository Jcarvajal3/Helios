-- ============================================================================
-- Ronda — Descifrar una cédula deja rastro, o no se descifra
--
-- `POST /documents/{id}/decrypt` es el único camino para recuperar un
-- documento de identidad en claro. Su propio comentario en el servicio decía
-- que cada uso "debería quedar registrado en la bitácora de auditoría del
-- super admin". No se registraba en ningún sitio: ni en `audit.admin_actions`,
-- ni en `kyc.decision_log`, ni siquiera en el log del contenedor.
--
-- Y como el endpoint se protege con un token compartido, aunque se hubiera
-- registrado no habría habido un actor: solo "alguien que tenía el token".
--
-- Esta función arregla las dos cosas a la vez, porque separadas no sirven:
-- exige un operador real y activo, y deja la anotación. Si el operador no
-- vale, lanza — y el servicio no descifra. Sin identidad no hay descifrado.
-- ============================================================================

create or replace function kyc.log_document_decrypt(
  p_verification_id uuid,
  p_operator        uuid
)
returns void
language plpgsql
security definer
set search_path = kyc, public, audit, pg_temp
as $$
begin
  if p_operator is null then
    raise exception 'Falta identificar al operador' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.platform_admins
    where user_id = p_operator and is_active
  ) then
    raise exception 'Operador no autorizado' using errcode = '42501';
  end if;

  if not exists (
    select 1 from kyc.verifications where id = p_verification_id
  ) then
    raise exception 'Verificación no encontrada' using errcode = 'P0002';
  end if;

  perform audit.log(
    p_operator,
    'kyc.document_decrypted',
    p_verification_id,
    jsonb_build_object('via', 'kyc-service')
  );
end;
$$;

revoke all on function kyc.log_document_decrypt(uuid, uuid)
  from public, anon, authenticated;
