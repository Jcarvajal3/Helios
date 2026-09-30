-- ============================================================================
-- Ronda — Estado de cuenta unificado
--
-- La app necesita saber en qué punto del registro está el usuario para decidir
-- a qué pantalla mandarlo. Antes eran tres llamadas (KYC, PIN, términos); esto
-- lo resuelve en una, que en una red móvil venezolana se nota.
--
-- El orden del registro es: OTP → PIN → KYC → términos → dentro.
-- El PIN va antes del KYC a propósito: si el usuario abandona la verificación,
-- puede volver a entrar sin repetir el OTP.
-- ============================================================================

create or replace function public.my_account_state()
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, pg_temp
stable
as $$
declare
  v_user  uuid := auth.uid();
  v_kyc   kyc.verifications%rowtype;
  v_prof  public.profiles%rowtype;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_prof from public.profiles where id = v_user;

  select * into v_kyc
  from kyc.verifications
  where user_id = v_user
  order by created_at desc
  limit 1;

  return jsonb_build_object(
    'has_pin', exists (select 1 from public.user_pins where user_id = v_user),
    'terms_accepted', exists (
      select 1 from public.terms_acceptances where user_id = v_user
    ),
    'profile', jsonb_build_object(
      'status', v_prof.status,
      'level', v_prof.level,
      'full_name', v_prof.full_name
    ),
    'kyc', case when v_kyc.id is null then
      jsonb_build_object('status', 'none')
    else
      jsonb_build_object(
        'id', v_kyc.id,
        'status', v_kyc.status,
        'rejection_reason', v_kyc.rejection_reason,
        -- Los datos extraídos solo se devuelven cuando hay algo que confirmar.
        -- Nunca devolvemos los puntajes: le darían a un atacante una señal
        -- para calibrar sus intentos.
        'extracted', case
          when v_kyc.extracted_document is not null then
            jsonb_build_object(
              'full_name', v_kyc.extracted_name,
              'document_number', v_kyc.extracted_document,
              'birth_date', v_kyc.extracted_birth
            )
          else null
        end,
        -- true cuando el OCR ya dio resultado pero el usuario aún no lo ha
        -- confirmado contra su perfil.
        'needs_confirmation', (
          v_kyc.status in ('processing', 'manual_review')
          and v_kyc.extracted_document is not null
          and v_prof.document_number is null
        )
      )
    end
  );
end;
$$;

revoke all on function public.my_account_state() from public, anon;
grant execute on function public.my_account_state() to authenticated;
