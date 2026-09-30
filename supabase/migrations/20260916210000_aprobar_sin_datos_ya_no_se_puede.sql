-- ============================================================================
-- Ronda — Una verificación aprobada SIEMPRE activa el perfil
--
-- El agujero, tal como se vio el 2026-09-16: una persona con el perfil en
-- `pending_kyc` entraba por OTP y la app la mandaba directo a aceptar los
-- términos, sin pasar por Didit y sin un solo dato de identidad.
--
-- La causa: una verificación en `approved` cuyo perfil nunca se activó.
-- `advance_profile` se niega a activar sin `data_confirmed_at` —y hace bien—,
-- pero nada impedía APROBAR sin él. Quedaban dos verdades contradictorias en
-- la base: la verificación decía "aprobada" y el perfil "sin verificar". Y la
-- app decide por la verificación: `approved` sin nada que confirmar es "ya
-- está", y de ahí a los términos.
--
-- Hay más de una puerta por la que se llegaba a eso, y ninguna es rara:
--
--   · "Aprobar de todos modos" en el panel (super admin) sobre un expediente
--     que Didit nunca terminó: `kyc.review` → `approved`, sin datos. Deja
--     rastro en `audit.admin_actions`.
--   · `kyc.review(...)` o `kyc.apply_status(id, 'approved')` a mano desde el
--     editor SQL, que es como se ha dado de alta a cuentas de prueba. No pasan
--     por `admin_review_kyc`, así que no dejan rastro. (`kyc.record_decision`,
--     el motor propio, ya exigía cédula para aprobar.)
--   · Un UPDATE suelto sobre `kyc.verifications`.
--
-- ---------------------------------------------------------------------------
-- La regla
-- ---------------------------------------------------------------------------
-- **No se aprueba sin datos, por ninguna puerta.** Vive en `kyc.apply_status`,
-- que es el embudo: `review`, `record_decision`, `record_didit_decision` y
-- `confirm_kyc_data` pasan todas por ahí. Aprobar exige que haya algo que la
-- persona pueda dar por bueno: o ya lo confirmó (`data_confirmed_at`), o hay
-- un documento extraído que la app le va a enseñar para confirmar. Sin lo uno
-- ni lo otro no hay identidad, y aprobar sería dar de alta a alguien sin una
-- sola prueba — justo lo que el KYC existe para evitar. Lo que toca con un
-- expediente vacío existe desde 20260911199000: pedir una verificación nueva.
--
-- Con eso, `approved` implica "hay datos", "hay datos" implica que la app
-- confirma o `advance_profile` activa, y las dos verdades vuelven a ser una.
--
-- El UPDATE suelto no lo para ninguna función. Para ese, y para cualquier
-- migración futura que vuelva a separarlas, `my_account_state` deja de fiarse
-- solo de la verificación: aprobada con el perfil todavía en `pending_kyc` se
-- le cuenta a la app como "en revisión". La persona ve "estamos revisando",
-- no la puerta abierta. Y vale para las builds ya instaladas: es el servidor.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. `kyc.apply_status`: aprobar exige datos de identidad
-- ---------------------------------------------------------------------------
-- Igual que 20260826220000 salvo por la comprobación de arriba del todo.

create or replace function kyc.apply_status(
  p_verification_id uuid,
  p_status          kyc.verification_status,
  p_reason          kyc.rejection_reason default null,
  p_actor           text default 'system',
  p_signals         jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $$
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

  -- Solo 'approved' activa; cualquier otro estado desactiva. Escribirlo así
  -- —y no enumerando los rechazos— cubre también las transiciones de vuelta:
  -- una verificación ya aprobada que un operador baja a revisión deja de
  -- reservar esa cara mientras se decide.
  update kyc.face_embeddings
    set active = (p_status = 'approved')
  where verification_id = p_verification_id;

  -- Aprobar ya no escribe nada en el perfil: eso pasa cuando la persona
  -- confirma. Si confirmó antes que llegara el veredicto —el caso de la
  -- revisión manual—, esta llamada es la que lo activa.
  if p_status = 'approved' then
    perform kyc.advance_profile(p_verification_id);
  end if;

  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Lo que ya quedó partido se cierra, y la persona repite la verificación
-- ---------------------------------------------------------------------------
-- Hoy no hay ninguna fila así en producción (la que hubo se borró con su
-- cuenta), pero la migración tiene que dejar la base coherente con la regla
-- esté donde esté. El cierre es el mismo que hace
-- `admin_request_new_verification`: `rejected` con motivo `needs_retry`, que
-- es lo que desbloquea abrir otra sin decirle a nadie que fue rechazado.

do $$
declare
  v_row kyc.verifications%rowtype;
begin
  for v_row in
    select v.*
    from kyc.verifications v
    join public.profiles p on p.id = v.user_id
    where v.status = 'approved'
      and v.data_confirmed_at is null
      and v.extracted_document is null
      and p.status = 'pending_kyc'
  loop
    update kyc.verifications
       set status           = 'rejected',
           rejection_reason = 'needs_retry',
           rejection_detail = 'Se aprobó sin datos de identidad. Hay que repetir la verificación.',
           updated_at       = now()
     where id = v_row.id;

    insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
    values (v_row.id, 'approved', 'rejected', 'system',
            jsonb_build_object('reason', 'needs_retry', 'migration', '20260916210000'));

    perform public.notify(
      v_row.user_id,
      'kyc_retry_requested',
      'Vuelve a verificar tu identidad',
      'No pudimos completar tu verificación. Abre Helios y vuelve a intentarlo: son dos minutos.'
    );
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. `my_account_state`: la app no entra por una verificación que no activó
-- ---------------------------------------------------------------------------
-- Igual que 20260822210000 salvo por el `status` del bloque `kyc`: aprobada
-- pero con el perfil todavía en `pending_kyc` se cuenta como `manual_review`.
-- Es la pantalla honesta —alguien tiene que mirar por qué no activó— y es la
-- que no deja pasar. La fila no se toca: esto es lo que se le dice a la app,
-- no lo que hay en la base.
--
-- La excepción es el flujo propio a medias: aprobada, con documento extraído
-- y todavía sin confirmar. Ahí el perfil sigue en `pending_kyc` A PROPÓSITO
-- hasta que la persona confirme, y la app la lleva a confirmar
-- (`needs_confirmation`). Esa sí se cuenta como `approved`.

create or replace function public.my_account_state()
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, pg_temp
stable
as $$
declare
  v_user       uuid := auth.uid();
  v_kyc        kyc.verifications%rowtype;
  v_prof       public.profiles%rowtype;
  v_kyc_status text;
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

  v_kyc_status := case
    when v_kyc.status = 'approved'
     and v_prof.status = 'pending_kyc'
     and v_kyc.extracted_document is null then 'manual_review'
    else v_kyc.status::text
  end;

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
        'status', v_kyc_status,
        'rejection_reason', v_kyc.rejection_reason,
        -- Los datos extraídos solo se devuelven cuando hay algo que confirmar.
        -- Nunca devolvemos los puntajes: le darían a un atacante una señal
        -- para calibrar sus intentos.
        'extracted', case
          when v_kyc.extracted_document is not null then
            jsonb_build_object(
              'full_name', v_kyc.extracted_name,
              'first_name', v_kyc.extracted_first_name,
              'last_name', v_kyc.extracted_last_name,
              'document_number', v_kyc.extracted_document,
              'birth_date', v_kyc.extracted_birth
            )
          else null
        end,
        -- La pregunta no es "¿en qué estado está la verificación?" sino "¿ya
        -- confirmó el usuario sus datos?". Confirmar es un paso del registro,
        -- no una consecuencia del veredicto: lo hace todo el mundo.
        'needs_confirmation', (
          v_kyc.extracted_document is not null
          and v_kyc.data_confirmed_at is null
        )
      )
    end
  );
end;
$$;
revoke all on function public.my_account_state() from public, anon;
grant execute on function public.my_account_state() to authenticated;
