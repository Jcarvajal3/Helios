-- ============================================================================
-- Helios — La clínica ve completos los datos del paciente que ya conoce
--
-- Antes (D-H6, 2026-09-30), la consulta de cédula enseñaba a la clínica el
-- nombre, el teléfono y el correo enmascarados («J*** P***»,
-- «0414-***-**67»). Ahora van completos (Javier, 2026-10-21): la secretaria
-- se los lee al paciente para confirmar que es él, y con asteriscos no hay
-- nada que confirmar.
--
-- Lo demás de la privacidad entre clínicas no cambia: ni la deuda, ni las
-- cuotas, ni la mora, ni las clínicas anteriores, ni el motivo de «no
-- disponible». Tampoco el límite diario de consultas por persona.
--
-- Claves nuevas: `nombre`, `telefono` («0414-1234567») y `email`. Las
-- `_enmascarado` se quedan mientras el panel y el bot desplegados las lean;
-- se quitan cuando ambos lean las nuevas.
-- ============================================================================

create or replace function public.helios_patient_eligibility(p_merchant_id uuid, p_document text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff  uuid := auth.uid();
  v_key    text;
  v_n      integer;
  v_p      public.profiles%rowtype;
  v_limit  numeric(18,4);
  v_avail  numeric(18,4);
  v_min    numeric := public.helios_min_charge_usd();
  v_out    jsonb;
  v_result text;
  v_nombre text;
begin
  if v_staff is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if public.helios_staff_role_in(p_merchant_id) is null then
    raise exception 'No tienes permiso para consultar en esta clínica' using errcode = '42501';
  end if;

  perform public.helios_assert_merchant_operating(p_merchant_id);

  v_key := public.helios_document_key(p_document);

  -- El límite por persona y día. Serializado por persona: dos pestañas a la
  -- vez no se cuelan las dos por la última plaza. Pasado el límite, error (y
  -- nada queda anotado: el error deshace la transacción). La alerta
  -- `consultas_de_cedula_excesivas` mira cuántas hay.
  perform pg_advisory_xact_lock(hashtextextended('helios_eligibility:' || v_staff::text, 0));

  select count(*) into v_n
  from public.eligibility_lookups
  where staff_user_id = v_staff
    and created_at >= public.helios_business_day_start();

  if v_n >= public.helios_eligibility_lookups_per_staff_day() then
    raise exception 'Llegaste al límite de consultas de hoy. Inténtalo mañana.' using errcode = '22023';
  end if;

  select * into v_p from public.profiles where document_key = v_key;

  if not found then
    v_result := 'nuevo';
    v_out := jsonb_build_object(
      'estado', 'nuevo',
      'min_charge_usd', v_min,
      'limite_usd', (select l.monthly_limit_usd from public.levels l where l.level = 1)
    );
  else
    select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_p.level;
    v_avail := greatest(coalesce(v_limit, 0) - public.helios_credit_used_usd(v_p.id), 0);

    if v_p.status = 'active'
       and not v_p.is_blacklisted
       and public.can_take_debt(v_p.id)
       and v_avail >= v_min then
      v_result := 'disponible';
      v_nombre := nullif(btrim(coalesce(nullif(btrim(v_p.full_name), ''),
                                        concat_ws(' ', v_p.first_name, v_p.last_name))), '');
      v_out := jsonb_build_object(
        'estado', 'disponible',
        'disponible_usd', trunc(v_avail, 2),
        'min_charge_usd', v_min,
        'nombre', v_nombre,
        'telefono', coalesce(public.helios_format_ve_phone(v_p.phone_e164), v_p.phone_e164),
        'email', nullif(btrim(v_p.email), ''),
        'nombre_enmascarado', public.helios_mask_name(v_nombre),
        'telefono_enmascarado', public.helios_mask_phone(v_p.phone_e164),
        'email_enmascarado', public.helios_mask_email(v_p.email)
      );
    else
      -- Mora, lista negra, bloqueo, expulsión o cupo agotado: no se dice cuál.
      v_result := 'no_disponible';
      v_out := jsonb_build_object(
        'estado', 'no_disponible',
        'mensaje', public.helios_not_available_message(),
        'whatsapp_helios', (select pc.whatsapp_number from public.platform_contact pc where pc.id)
      );
    end if;
  end if;

  insert into public.eligibility_lookups (staff_user_id, merchant_id, document_key, result)
  values (v_staff, p_merchant_id, v_key, v_result);

  return v_out;
end;
$$;

revoke all on function public.helios_patient_eligibility(uuid, text) from public, anon;
grant execute on function public.helios_patient_eligibility(uuid, text) to authenticated;
