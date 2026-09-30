-- ============================================================================
-- Ronda — Pedir una verificación nueva
--
-- Una sesión de Didit que se queda a medias no se desatasca sola. El expediente
-- se queda en `processing` para siempre: la persona no puede abrir otro —la
-- comprobación de sesión abierta se lo impide— y el panel solo puede aprobarlo
-- o rechazarlo, que son las dos cosas que no hay que hacer con un expediente
-- del que no se sabe nada.
--
-- Hoy se resuelve aprobando a ciegas o dejando a la persona fuera. Las dos son
-- malas: la primera da de alta a alguien sin una sola prueba de identidad, la
-- segunda pierde al cliente sin decirle por qué.
--
-- ---------------------------------------------------------------------------
-- Por qué el panel NO genera el enlace
-- ---------------------------------------------------------------------------
-- La especificación dice «genera un nuevo enlace de Didit y se lo envía al
-- usuario». Con el SDK nativo eso no se puede hacer desde aquí: la sesión se
-- crea con la clave de Didit, que vive en el servidor y no puede salir de él,
-- y el flujo entero —cédula, selfie, vivacidad— ocurre **dentro de la app de
-- la persona**. Un enlace generado por el panel abriría el flujo web, que es
-- justo el que se dejó de usar.
--
-- Lo que sí hace falta, y es lo que hace esto: **cerrar el expediente atascado
-- para que deje de bloquear**, y avisar a la persona de que lo intente otra
-- vez. Al abrir la app, su verificación arranca sola y nace una sesión nueva
-- en su teléfono. Que le llegue además un WhatsApp lo hace el operador desde
-- Cobranza, con los datos delante.
--
-- ---------------------------------------------------------------------------
-- `needs_retry` no es un rechazo
-- ---------------------------------------------------------------------------
-- El estado es `rejected` porque es el único que desbloquea abrir otra, pero
-- el motivo lo distingue: nadie ha dicho que la persona no sea quien dice, solo
-- que el expediente llegó vacío. El aviso que recibe lo dice con esas palabras
-- — «no pudimos completar tu verificación», no «te rechazamos» — porque es la
-- diferencia entre volver a intentarlo y borrar la app.
-- ============================================================================

create or replace function public.admin_request_new_verification(
  p_user_id uuid,
  p_note    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_ver   kyc.verifications%rowtype;
  v_name  text;
begin
  -- Pedir que alguien repita su verificación es trabajo del operador: no
  -- decide sobre la identidad de nadie, solo desatasca.
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select full_name into v_name from public.profiles where id = p_user_id;
  if not found then
    raise exception 'No existe esa persona' using errcode = '22023';
  end if;

  select * into v_ver
  from kyc.verifications
  where user_id = p_user_id
    and status in ('pending', 'processing', 'manual_review')
  order by created_at desc
  limit 1
  for update;

  if not found then
    -- Sin expediente abierto no hay nada que desatascar: la persona ya puede
    -- abrir uno cuando quiera, y decir lo contrario sería mentir.
    raise exception 'Esta persona no tiene ninguna verificación abierta'
      using errcode = '22023';
  end if;

  update kyc.verifications
  set status           = 'rejected',
      rejection_reason = 'needs_retry',
      rejection_detail = coalesce(
        nullif(trim(coalesce(p_note, '')), ''),
        'No pudimos completar la verificación. Hay que repetirla.'
      ),
      reviewed_by      = v_actor,
      reviewed_at      = now(),
      updated_at       = now()
  where id = v_ver.id;

  insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
  values (
    v_ver.id, v_ver.status, 'rejected', v_actor::text,
    jsonb_build_object('reason', 'needs_retry', 'note', p_note)
  );

  -- El aviso dice qué hacer, no que se le rechazó. La diferencia entre volver
  -- a intentarlo y borrar la app está en esta frase.
  perform public.notify(
    p_user_id,
    'kyc_retry_requested',
    'Vuelve a verificar tu identidad',
    'No pudimos completar tu verificación. Abre Helios y vuelve a intentarlo: son dos minutos.'
  );

  perform audit.log(v_actor, 'kyc.retry_requested', p_user_id, jsonb_build_object(
    'verification_id', v_ver.id,
    'full_name', v_name,
    'from_status', v_ver.status,
    'waited_hours', round(extract(epoch from (now() - v_ver.created_at)) / 3600.0, 1),
    'note', p_note
  ));

  return jsonb_build_object(
    'ok', true,
    'verification_id', v_ver.id,
    'previous_status', v_ver.status
  );
end;
$$;

comment on function public.admin_request_new_verification(uuid, text) is
  'Cierra el expediente de identidad atascado para que la persona pueda abrir otro, y le avisa. NO genera el enlace de Didit: con el SDK nativo la sesion nace en su telefono.';

revoke all on function public.admin_request_new_verification(uuid, text) from public, anon;
grant execute on function public.admin_request_new_verification(uuid, text) to authenticated;
