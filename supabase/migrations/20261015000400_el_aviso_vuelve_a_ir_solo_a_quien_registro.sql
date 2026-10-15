-- ============================================================================
-- Helios — El aviso de la orden vuelve a ir solo a quien la registró (2026-10-15)
--
-- Revierte 20261015000300, que se hizo sin que Javier lo pidiera: el aviso
-- (aceptada, rechazada y vencida) va SOLO a quien registró la orden, desde
-- el panel o desde el bot, si tiene número del bot activo en esa clínica. No
-- a los administradores. La función queda idéntica a 20261015000100.
-- ============================================================================

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
