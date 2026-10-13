-- ============================================================================
-- Helios — El médico se entera aunque registre en el panel (2026-10-13)
--
-- Reporte de Javier: cuando el paciente acepta, al médico no le llegaba el
-- «✅ … aceptó» si la orden se había registrado desde el panel.
-- `helios_notify_staff_of_charge` (20261007000400) salía sin hacer nada si
-- `charges.channel <> 'whatsapp'`: el aviso solo existía para el bot. La
-- orden #1314 (panel, 2026-10-13) lo muestra: el médico tenía número del bot y
-- la ventana abierta, y no recibió nada.
--
-- Desde aquí:
--   · el aviso va a quien registró la orden (`requested_by`) si tiene un
--     número del bot activo en esa clínica, venga la orden del panel o del
--     bot;
--   · con su ventana de 24 h abierta, como texto (igual que antes);
--   · con la ventana cerrada, solo «aceptó», y solo con la plantilla de Meta
--     `aviso_al_medico` conectada (`wa_template_name`, null hasta que Meta la
--     apruebe: hasta entonces, como antes, no se le escribe). Rechazada y
--     vencida, fuera de la ventana, quedan en el panel.
--
-- Variables de la plantilla: {{1}} el paciente («José P.»), {{2}} el número
-- de orden, {{3}} la consulta en su moneda («$100», «€80»).
-- ============================================================================

insert into public.notification_templates
  (key, type, channels, label, trigger_label, help, variables, required_variables,
   default_title, default_body, enabled, editable, can_disable, sort_order,
   wa_template_name, wa_template_lang, wa_template_params)
values (
  'aviso_al_medico', null, '{whatsapp}', 'Aviso al médico: el paciente aceptó',
  'El paciente responde Sí y el médico no ha escrito al bot en 24 h',
  'Con la ventana de 24 h cerrada, el aviso de que el paciente aceptó sale con la plantilla de Meta. Dentro de la ventana sale como texto del bot.',
  array['nombre', 'orden', 'monto_consulta'], array['nombre', 'orden', 'monto_consulta'],
  'Helios', '{texto}', true, false, false, 910,
  null, 'es', array['nombre', 'orden', 'monto_consulta']
)
on conflict (key) do nothing;

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
    when 'aceptada' then format('✅ %s aceptó. Orden #%s confirmada: consulta de %s.',
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
