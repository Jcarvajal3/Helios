-- ============================================================================
-- Helios — El aviso de la orden llega también al administrador (2026-10-15)
--
-- Prueba de Javier: registró la orden #2647 en el panel con la cuenta
-- «admin» (gerente de Consultorio DEMO, sin número del bot activo) y su
-- número, registrado para la cuenta «Javier» (gerente de la misma clínica),
-- no recibió el «aceptó»: `helios_notify_staff_of_charge` (20261015000100)
-- solo avisaba a quien registró la orden. Lo mismo pasaría cuando la
-- secretaria registra en el panel: casi nunca tiene número del bot y el
-- médico no se enteraba.
--
-- Desde aquí el aviso (aceptada, rechazada y vencida) va a:
--   1. quien registró la orden, y
--   2. los administradores (`gerente`) activos de la clínica,
-- cada uno una sola vez y solo si tiene un número del bot activo en esa
-- clínica. Las reglas de cada envío no cambian: con la ventana de 24 h
-- abierta, texto; cerrada, solo «aceptó» y con la plantilla de
-- `aviso_al_medico`. Un envío que falla no frena a los demás ni tumba la
-- confirmación del paciente. Privacidad: el administrador ya ve todas las
-- órdenes de su clínica.
-- ============================================================================

create or replace function public.helios_notify_staff_of_charge(p_charge_id uuid, p_kind text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c         public.charges%rowtype;
  v_quien     text;
  v_consulta  text;
  v_texto     text;
  v_plantilla text;
  v_dest      record;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found then
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

  select nullif(btrim(t.wa_template_name), '') into v_plantilla
  from public.notification_templates t where t.key = 'aviso_al_medico' and t.enabled;

  -- Quien la registró y los administradores de la clínica, con número del bot.
  for v_dest in
    select distinct on (n.phone_e164) n.user_id, n.phone_e164
    from public.staff_whatsapp_numbers n
    where n.merchant_id = v_c.merchant_id
      and n.revoked_at is null
      and (n.user_id = v_c.requested_by
           or exists (select 1 from public.merchant_users mu
                      where mu.user_id = n.user_id and mu.merchant_id = v_c.merchant_id
                        and mu.is_active and mu.role = 'gerente'))
    order by n.phone_e164, (n.user_id = v_c.requested_by) desc
  loop
    begin
      if public.helios_whatsapp_window_open(v_dest.phone_e164) then
        perform public.helios_whatsapp_text(v_dest.phone_e164, v_texto, v_dest.user_id);
      elsif p_kind = 'aceptada' and v_plantilla is not null then
        -- Ventana cerrada: solo «aceptó», con la plantilla aprobada.
        insert into public.outbound_messages (
          channel, template_key, profile_id, recipient_staff_id, recipient, charge_id,
          subject, rendered_text, status, next_attempt_at, wa_template
        ) values (
          'whatsapp', 'aviso_al_medico', null, v_dest.user_id, v_dest.phone_e164, v_c.id,
          'Helios', v_texto, 'pendiente', now(),
          jsonb_build_object('name', v_plantilla, 'language', 'es',
            'params', jsonb_build_array(v_quien, v_c.order_number::text, v_consulta),
            'buttons', '[]'::jsonb)
        );
      end if;
    exception when others then
      -- Un aviso que no sale no frena a los demás.
      null;
    end;
  end loop;
exception when others then
  -- Un aviso que no sale no puede tumbar la confirmación del paciente.
  null;
end;
$$;

revoke all on function public.helios_notify_staff_of_charge(uuid, text) from public, anon, authenticated;
