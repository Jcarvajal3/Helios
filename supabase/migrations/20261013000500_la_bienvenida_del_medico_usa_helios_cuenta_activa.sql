-- ============================================================================
-- Helios — La bienvenida del médico usa `helios_cuenta_activa`
--
-- La plantilla de Meta de la bienvenida al médico aprobado (Javier,
-- 2026-10-13) es `helios_cuenta_activa`:
--
--   ¡Hola, {{1}}! 👋 Te damos la bienvenida a Helios 💙
--
--   Tu cuenta en {{2}} ya está activa ✅ Te enviamos tus datos de acceso al
--   panel a {{3}}.
--
--   Si lo prefieres, también puedes registrar los pagos en cuotas de tus
--   pacientes desde este mismo chat, sin entrar al panel. Toca «Empezar» y te
--   guío paso a paso 🙌
--
--   Cualquier duda, escríbenos por aquí. ¡Estamos para ayudarte!
--
-- {{1}} el nombre del médico, {{2}} la clínica, {{3}} el correo de su
-- usuario. Idioma `es`, como `helios_confirmar_pago_en_cuotas`.
--
-- Cambia:
--   1. `bienvenida_medico` se conecta a la plantilla, con sus tres variables.
--   2. `admin_send_staff_whatsapp_welcome`: el texto libre (ventana de 24 h
--      abierta) es el mismo de la plantilla, con un botón «Empezar». Con la
--      plantilla no se manda el componente del botón: si Meta la tiene con
--      un botón de respuesta rápida, al tocarlo llega el texto «Empezar»; si
--      no lo tiene, no falla. El bot ya entiende «empezar» como «hola»: abre
--      el menú con el saludo.
-- ============================================================================

update public.notification_templates
   set wa_template_name   = 'helios_cuenta_activa',
       wa_template_lang   = 'es',
       wa_template_params = array['nombre', 'clinica', 'correo'],
       variables          = array['nombre', 'clinica', 'correo'],
       required_variables = array['nombre', 'clinica', 'correo']
 where key = 'bienvenida_medico';

/** Como en 20261013000400, con el texto de `helios_cuenta_activa` y el botón «Empezar». */
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
    E'¡Hola, %s! 👋 Te damos la bienvenida a Helios 💙\n\n'
    'Tu cuenta en %s ya está activa ✅ Te enviamos tus datos de acceso al panel a %s.\n\n'
    'Si lo prefieres, también puedes registrar los pagos en cuotas de tus pacientes desde este mismo chat, sin entrar al panel. Toca «Empezar» y te guío paso a paso 🙌\n\n'
    'Cualquier duda, escríbenos por aquí. ¡Estamos para ayudarte!',
    v_nombre, v_clinica, v_correo);

  if public.helios_whatsapp_window_open(v_phone) then
    v_via := 'texto';
    insert into public.outbound_messages (
      channel, template_key, profile_id, recipient_staff_id, recipient,
      subject, rendered_text, status, next_attempt_at, wa_template, dedupe_key
    ) values (
      'whatsapp', 'bienvenida_medico', null, p_user_id, v_phone,
      'Helios', v_texto, 'pendiente', now(),
      jsonb_build_object('name', null, 'language', 'es', 'params', '[]'::jsonb,
                         'buttons', jsonb_build_array(jsonb_build_object('id', 'menu:empezar', 'title', 'Empezar'))),
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
