-- ============================================================================
-- Ronda — La confirmación de datos ocurre dentro de Didit
--
-- Corrige la migración anterior, que solo sellaba `data_confirmed_at` al
-- aprobar. El efecto secundario: una verificación que Didit dejaba EN REVISIÓN
-- llegaba con `extracted_document` relleno y sin fecha de confirmación, y
-- `my_account_state` calcula `needs_confirmation` justo con esas dos cosas —
-- así que la app mandaba a la persona a una pantalla de confirmación que ya no
-- existe en este flujo.
--
-- El sello correcto es cualquier estado terminal, no solo la aprobación,
-- porque describe algo que ya pasó: la persona vio sus datos y los aceptó
-- DENTRO del flujo de Didit. Eso es cierto tanto si el veredicto fue aprobar
-- como revisar o rechazar.
--
-- Y hace falta para el camino de revisión manual: cuando un operador aprueba
-- desde el panel, `advance_profile` exige `data_confirmed_at` para activar la
-- cuenta. Sin este cambio, aprobar a mano no activaba a nadie.
-- ============================================================================

create or replace function kyc.record_didit_decision(
  p_session_id text,
  p_status     text,
  p_document   text default null,
  p_first_name text default null,
  p_last_name  text default null,
  p_full_name  text default null,
  p_birth_date date default null,
  p_detail     text default null,
  p_signals    jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $$
declare
  v_row    kyc.verifications%rowtype;
  v_status kyc.verification_status;
  v_reason kyc.rejection_reason;
  v_full   text;
  v_age    int;
  v_note   text;
begin
  select * into v_row from kyc.verifications
  where didit_session_id = p_session_id for update;

  if not found then
    raise exception 'Sesión de Didit desconocida: %', p_session_id
      using errcode = 'P0002';
  end if;

  -- Los webhooks se reentregan. Volver a aplicar un estado ya alcanzado
  -- duplicaría renglones en la bitácora y volvería a tocar el perfil.
  if v_row.status in ('approved', 'rejected') then
    return jsonb_build_object('ok', true, 'status', v_row.status, 'ignored', 'already_resolved');
  end if;

  v_full := nullif(
    btrim(regexp_replace(
      coalesce(
        nullif(btrim(coalesce(p_first_name, '') || ' ' || coalesce(p_last_name, '')), ''),
        p_full_name,
        ''
      ),
      '\s+', ' ', 'g'
    )),
    ''
  );

  v_age := case
    when coalesce(p_birth_date, v_row.extracted_birth) is null then null
    else extract(year from age(current_date, coalesce(p_birth_date, v_row.extracted_birth)))::int
  end;

  -- --- Traducción del veredicto ------------------------------------------
  case p_status
    when 'Approved' then
      v_status := 'approved';

    when 'Declined' then
      v_status := 'rejected';
      v_reason := 'provider_declined';
      v_note   := p_detail;

    when 'In Review' then
      v_status := 'manual_review';
      v_note   := coalesce(p_detail, 'Didit la dejó en revisión.');

    when 'Abandoned' then
      v_status := 'rejected';
      v_reason := 'provider_declined';
      v_note   := 'La verificación se abandonó sin terminar.';

    when 'Expired' then
      v_status := 'rejected';
      v_reason := 'provider_declined';
      v_note   := 'La sesión de verificación caducó.';

    when 'Kyc Expired' then
      v_status := 'rejected';
      v_reason := 'provider_declined';
      v_note   := 'La sesión de verificación caducó.';

    else
      -- 'In Progress', 'Not Started', 'Resubmitted', 'Awaiting User': la
      -- persona sigue dentro del flujo. NO se guardan datos extraídos todavía:
      -- rellenar `extracted_document` antes de tener veredicto es lo que
      -- disparaba `needs_confirmation` y desviaba a la pantalla equivocada.
      insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
      values (v_row.id, v_row.status, v_row.status, 'system',
              coalesce(p_signals, '{}'::jsonb) || jsonb_build_object('didit_status', p_status));

      return jsonb_build_object('ok', true, 'status', v_row.status, 'pending', true);
  end case;

  -- --- Datos del documento, ya con veredicto ------------------------------
  --
  -- `data_confirmed_at` se sella en todo estado terminal, no solo al aprobar:
  -- describe que la persona vio y aceptó sus datos dentro de Didit, que es
  -- cierto en los tres casos. Y es lo que permite que, si un operador aprueba
  -- después desde el panel, `advance_profile` active la cuenta.
  update kyc.verifications
     set extracted_name       = coalesce(v_full, extracted_name),
         extracted_first_name = coalesce(nullif(btrim(coalesce(p_first_name, '')), ''), extracted_first_name),
         extracted_last_name  = coalesce(nullif(btrim(coalesce(p_last_name, '')), ''), extracted_last_name),
         extracted_document   = coalesce(nullif(btrim(coalesce(p_document, '')), ''), extracted_document),
         extracted_birth      = coalesce(p_birth_date, extracted_birth),
         confirmed_name       = coalesce(v_full, confirmed_name),
         confirmed_first_name = coalesce(nullif(btrim(coalesce(p_first_name, '')), ''), confirmed_first_name),
         confirmed_last_name  = coalesce(nullif(btrim(coalesce(p_last_name, '')), ''), confirmed_last_name),
         confirmed_document   = coalesce(nullif(btrim(coalesce(p_document, '')), ''), confirmed_document),
         confirmed_birth      = coalesce(p_birth_date, confirmed_birth),
         data_confirmed_at    = coalesce(data_confirmed_at, now()),
         updated_at           = now()
   where id = v_row.id;

  -- --- Reglas de negocio, solo hacia abajo --------------------------------
  if v_status = 'approved' then
    if v_age is not null and v_age < 18 then
      v_status := 'rejected';
      v_reason := 'underage';
      v_note   := format('La fecha de nacimiento del documento da %s años.', v_age);

    elsif exists (
      select 1 from public.profiles
      where document_number = nullif(btrim(coalesce(p_document, '')), '')
        and id <> v_row.user_id
    ) then
      -- Didit verifica a la persona que tiene delante; no sabe qué cuentas
      -- existen ya en Ronda con esa cédula.
      v_status := 'manual_review';
      v_reason := null;
      v_note   := 'Esa cédula ya está registrada en otra cuenta.';
    end if;
  end if;

  if v_note is not null then
    update kyc.verifications
       set rejection_detail = v_note
     where id = v_row.id;
  end if;

  -- El actor es 'system' y no 'didit' a propósito: `apply_status` sella
  -- `reviewed_at` con cualquier actor distinto de 'system', y esto es una
  -- decisión automática, no la revisión de una persona. Que venga de Didit se
  -- registra en las señales, donde no falsea la bitácora.
  return kyc.apply_status(
    v_row.id,
    v_status,
    v_reason,
    'system',
    coalesce(p_signals, '{}'::jsonb) || jsonb_build_object(
      'provider', 'didit',
      'didit_status', p_status,
      'ocr_age', v_age,
      'review_note', v_note
    )
  );
end;
$$;

revoke all on function kyc.record_didit_decision(
  text, text, text, text, text, text, date, text, jsonb
) from public, anon, authenticated;
