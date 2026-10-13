-- ============================================================================
-- Helios — Al aprobar al médico le llega su bienvenida por WhatsApp
--
-- Al aprobar una solicitud de afiliación, el panel crea el usuario principal
-- (administrador) con el correo de la solicitud, registra su teléfono para el
-- bot y le manda los accesos por correo (`merchant_staff_send_welcome`). Esto
-- añade la otra mitad: el WhatsApp de bienvenida.
--
-- `admin_send_staff_whatsapp_welcome(p_merchant_id, p_user_id)` (super admin):
--   · sin número del bot activo en esa clínica → `sin_numero`;
--   · con la ventana de 24 h abierta (el médico le escribió a Helios hace
--     poco) → texto libre, con el enlace del panel y cómo usar el bot;
--   · con la ventana cerrada → la plantilla de Meta conectada en
--     `notification_templates.bienvenida_medico` (`wa_template_name`). Nace
--     en null, como `aviso_al_medico`: hasta que Meta la apruebe y se
--     conecte, devuelve `sin_plantilla` y no se encola nada.
--   · una sola vez por persona y clínica (`dedupe_key`): repetir devuelve
--     `ya_enviado`.
-- La cola la despacha el cron de siempre. El mensaje no lleva la contraseña
-- (esa va solo en el correo).
--
-- Las variables de la plantilla salen de `wa_template_params`, por nombre:
-- `nombre` (el del médico), `clinica` y `correo`. La propuesta del plan
-- (§15.7, `helios_bienvenida_medico_afiliado`) usa solo {{1}} = nombre.
-- ============================================================================

insert into public.notification_templates
  (key, type, channels, label, trigger_label, help, variables, required_variables,
   default_title, default_body, enabled, editable, can_disable, sort_order,
   wa_template_name, wa_template_lang, wa_template_params)
values (
  'bienvenida_medico', null, '{whatsapp}', 'Bienvenida al médico aprobado',
  'Un super admin aprueba la solicitud de afiliación',
  'Con la ventana de 24 h abierta sale como texto con el enlace del panel. Con la ventana cerrada sale con la plantilla de Meta; sin plantilla conectada, no se manda.',
  array['nombre', 'clinica', 'correo'], array['nombre'],
  'Helios', '{texto}', true, false, false, 920,
  null, 'es', array['nombre']
)
on conflict (key) do nothing;

/**
 * El WhatsApp de bienvenida a una persona del personal (el médico recién
 * aprobado). Devuelve `{status: 'en_cola' | 'sin_numero' | 'sin_plantilla' |
 * 'ya_enviado', via?: 'texto' | 'plantilla', phone?}`. Solo super admin.
 */
create or replace function public.admin_send_staff_whatsapp_welcome(p_merchant_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor   uuid := public.helios_assert_super_admin('mandar la bienvenida por WhatsApp');
  v_phone   text;
  v_nombre  text;
  v_correo  text;
  v_clinica text;
  v_t       public.notification_templates%rowtype;
  v_texto   text;
  v_params  jsonb;
  v_via     text;
  v_dedupe  text := format('bienvenida_medico:%s:%s', p_merchant_id, p_user_id);
  v_id      uuid;
begin
  if not exists (select 1 from public.merchant_users
                 where merchant_id = p_merchant_id and user_id = p_user_id and is_active) then
    raise exception 'Esa persona no es personal de esta clínica' using errcode = 'P0002';
  end if;

  select n.phone_e164 into v_phone from public.staff_whatsapp_numbers n
  where n.user_id = p_user_id and n.merchant_id = p_merchant_id and n.revoked_at is null;
  if v_phone is null then
    return jsonb_build_object('status', 'sin_numero');
  end if;

  if exists (select 1 from public.outbound_messages where dedupe_key = v_dedupe) then
    return jsonb_build_object('status', 'ya_enviado', 'phone', v_phone);
  end if;

  select coalesce(nullif(btrim(au.raw_user_meta_data->>'full_name'), ''), 'doctor'), au.email
    into v_nombre, v_correo
  from auth.users au where au.id = p_user_id;
  select m.name into v_clinica from public.merchants m where m.id = p_merchant_id;

  v_texto := format(
    E'👋 Hola, %s. Te damos la bienvenida a Helios 💙\n\n%s ya está activo. Te enviamos a %s tus datos para entrar al panel: https://conhelios.com/login\n\nTambién puedes registrar los pagos en cuotas por aquí, en este mismo chat: escribe «hola» cuando quieras.',
    v_nombre, v_clinica, v_correo);

  if public.helios_whatsapp_window_open(v_phone) then
    v_via := 'texto';
    insert into public.outbound_messages (
      channel, template_key, profile_id, recipient_staff_id, recipient,
      subject, rendered_text, status, next_attempt_at, wa_template, dedupe_key
    ) values (
      'whatsapp', 'bienvenida_medico', null, p_user_id, v_phone,
      'Helios', v_texto, 'pendiente', now(),
      jsonb_build_object('name', null, 'language', 'es', 'params', '[]'::jsonb, 'buttons', '[]'::jsonb),
      v_dedupe
    ) returning id into v_id;
  else
    select * into v_t from public.notification_templates where key = 'bienvenida_medico' and enabled;
    if nullif(btrim(v_t.wa_template_name), '') is null then
      return jsonb_build_object('status', 'sin_plantilla', 'phone', v_phone);
    end if;

    select coalesce(jsonb_agg(case p
             when 'nombre'  then v_nombre
             when 'clinica' then v_clinica
             when 'correo'  then v_correo
             else '' end order by i), '[]'::jsonb)
      into v_params
    from unnest(coalesce(v_t.wa_template_params, array['nombre'])) with ordinality as x(p, i);

    v_via := 'plantilla';
    insert into public.outbound_messages (
      channel, template_key, profile_id, recipient_staff_id, recipient,
      subject, rendered_text, status, next_attempt_at, wa_template, dedupe_key
    ) values (
      'whatsapp', 'bienvenida_medico', null, p_user_id, v_phone,
      'Helios', v_texto, 'pendiente', now(),
      jsonb_build_object('name', btrim(v_t.wa_template_name), 'language', coalesce(v_t.wa_template_lang, 'es'),
                         'params', v_params, 'buttons', '[]'::jsonb),
      v_dedupe
    ) returning id into v_id;
  end if;

  perform audit.log(v_actor, 'merchant.staff_whatsapp_welcome', p_merchant_id, jsonb_build_object(
    'user_id', p_user_id, 'phone_e164', v_phone, 'via', v_via, 'message_id', v_id));

  return jsonb_build_object('status', 'en_cola', 'via', v_via, 'phone', v_phone);
end;
$$;

revoke all on function public.admin_send_staff_whatsapp_welcome(uuid, uuid) from public, anon;
grant execute on function public.admin_send_staff_whatsapp_welcome(uuid, uuid) to authenticated;
