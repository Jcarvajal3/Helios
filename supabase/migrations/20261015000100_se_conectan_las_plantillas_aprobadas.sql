-- ============================================================================
-- Helios — Se conectan las plantillas aprobadas por Meta (2026-10-15)
--
-- Leídas en vivo de 360dialog (GET /v1/configs/templates) el 2026-10-15:
--
--   · `helios_paciente_acepto` (Utility, `es`): «¡Buenas noticias! {{1}}
--     aceptó su pago en cuotas. La orden #{{2}} por una consulta de {{3}} ya
--     está confirmada ✅». Va en `aviso_al_medico` (20261013000300), con las
--     mismas variables: paciente, orden, consulta. El aviso dentro de la
--     ventana de 24 h (texto libre) pasa a decir lo mismo.
--   · `helios_cuota_vence_hoy` (Utility): Meta la aprobó con idioma `en`
--     (el texto es en español). Se manda con ese código o Meta no la
--     encuentra (132001). Variables: nombre, cuota, orden, clínica, moneda y
--     cuentas de cobro (las de `cuota_hoy`, 20261013000700).
--
-- NO se conectan `helios_cuota_en_3_dias` ni `helios_cuota_vence_manana`:
-- su texto aprobado dice «Paga a tiempo para subir de nivel y aumentar tu
-- limite de credito!», y en lo externo no se dice «crédito» ni que el límite
-- crece (los niveles están apagados; CLAUDE.md). Hasta que Javier apruebe una
-- versión corregida, fuera de la ventana siguen cayendo a la cola manual.
--
-- `helios_cuenta_activa` (bienvenida_medico) y
-- `helios_confirmar_pago_en_cuotas` ya estaban conectadas.
-- ============================================================================

update public.notification_templates
   set wa_template_name = 'helios_paciente_acepto', wa_template_lang = 'es'
 where key = 'aviso_al_medico';

update public.notification_templates
   set wa_template_name = 'helios_cuota_vence_hoy', wa_template_lang = 'en'
 where key = 'cuota_hoy';

create or replace function public.helios_notify_staff_of_charge(p_charge_id uuid, p_kind text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c         public.charges%rowtype;
  v_phone     text;
  v_quien     text;
  v_consulta  text;
  v_texto     text;
  v_plantilla text;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found or v_c.requested_by is null then
    return;
  end if;

  -- Del panel o del bot: a quien la registró, si tiene número del bot.
  select n.phone_e164 into v_phone from public.staff_whatsapp_numbers n
  where n.user_id = v_c.requested_by and n.merchant_id = v_c.merchant_id and n.revoked_at is null;
  if v_phone is null then
    return;
  end if;

  select concat_ws(' ', nullif(btrim(p.first_name), ''),
                   case when nullif(btrim(p.last_name), '') is not null then left(btrim(p.last_name), 1) || '.' end)
    into v_quien
  from public.profiles p where p.id = v_c.user_id;
  v_quien := coalesce(nullif(v_quien, ''), 'El paciente');
  v_consulta := public.helios_money_cur_text(coalesce(v_c.base_cur, v_c.amount_cur), v_c.currency);

  v_texto := case p_kind
    when 'aceptada' then format(E'¡Buenas noticias! %s aceptó su pago en cuotas.\n\nLa orden #%s por una consulta de %s ya está confirmada ✅',
                                v_quien, v_c.order_number, v_consulta)
    when 'rechazada' then case v_c.decline_reason
      when 'no_disponible' then format('La orden #%s de %s no se pudo confirmar. %s',
                                       v_c.order_number, v_quien, public.helios_not_available_message())
      else format('❌ %s no aceptó la orden #%s. No se creó ninguna deuda.', v_quien, v_c.order_number) end
    when 'vencida' then format('⌛ La orden #%s de %s venció sin respuesta. Escribe «reenviar %s» para enviársela otra vez.',
                               v_c.order_number, v_quien, v_c.order_number)
  end;
  if v_texto is null then
    return;
  end if;

  if public.helios_whatsapp_window_open(v_phone) then
    perform public.helios_whatsapp_text(v_phone, v_texto, v_c.requested_by);
    return;
  end if;

  -- Ventana cerrada: solo «aceptó», con la plantilla aprobada.
  select nullif(btrim(t.wa_template_name), '') into v_plantilla
  from public.notification_templates t where t.key = 'aviso_al_medico' and t.enabled;
  if p_kind <> 'aceptada' or v_plantilla is null then
    return;
  end if;

  insert into public.outbound_messages (
    channel, template_key, profile_id, recipient_staff_id, recipient, charge_id,
    subject, rendered_text, status, next_attempt_at, wa_template
  ) values (
    'whatsapp', 'aviso_al_medico', null, v_c.requested_by, v_phone, v_c.id,
    'Helios', v_texto, 'pendiente', now(),
    jsonb_build_object('name', v_plantilla, 'language', 'es',
      'params', jsonb_build_array(v_quien, v_c.order_number::text, v_consulta),
      'buttons', '[]'::jsonb)
  );
exception when others then
  -- Un aviso que no sale no puede tumbar la confirmación del paciente.
  null;
end;
$$;

revoke all on function public.helios_notify_staff_of_charge(uuid, text) from public, anon, authenticated;
