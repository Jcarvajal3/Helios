-- ============================================================================
-- Helios — El personal recibe su bienvenida por correo
--
-- Al crear una cuenta del personal de una clínica, el panel le manda a esa
-- persona un correo con sus datos de acceso: el enlace del panel, su correo y
-- su contraseña, y cómo hacer lo mismo por WhatsApp con el bot. Siempre sale
-- una copia oculta (bcc) a `platform_contact.staff_welcome_copy`
-- (javier@conhelios.com).
--
-- Por qué NO va por la cola (`outbound_messages`):
--   · la cola guarda el texto y el HTML exactos que se mandan, y aquí va una
--     contraseña: quedaría en claro en una tabla para siempre;
--   · la cola es de pacientes (`profile_id` obligatorio) y el personal no
--     tiene fila en `profiles`.
-- Así que sale al momento, desde la RPC, por `helios_resend_request` (la
-- misma costura que sustituyen las suites), y en la base solo queda la línea
-- de bitácora, sin la contraseña.
--
-- `merchant_staff_send_welcome(p_merchant_id, p_user_id, p_password)`:
--   · la llama quien puede gestionar el personal (el equipo o el gerente),
--     justo después de `merchant_staff_add`;
--   · comprueba que la contraseña ES la de la cuenta (contra su hash): el
--     correo nunca lleva una contraseña que no sirve;
--   · no lanza si el correo no sale: la cuenta ya existe. Devuelve
--     `{status: 'enviado' | 'sin_configurar' | 'fallido', error?}` y el panel
--     lo dice.
-- Va en una RPC aparte y no dentro de `merchant_staff_add` para que las
-- suites que crean personal no manden correos de verdad.
-- ============================================================================

alter table public.platform_contact
  add column staff_welcome_copy text default 'javier@conhelios.com'
    check (staff_welcome_copy is null or public.helios_valid_email(staff_welcome_copy));

comment on column public.platform_contact.staff_welcome_copy is
  'Copia oculta (bcc) de cada correo de bienvenida al personal de una clínica. Null = sin copia.';

update public.platform_contact set staff_welcome_copy = 'javier@conhelios.com' where id;

/**
 * El correo de bienvenida de una persona del personal: `{subject, text, html}`.
 * Interna. `p_password` solo pasa por aquí para pintarse; no se guarda.
 */
create or replace function public.helios_staff_welcome_email(p_merchant_id uuid, p_user_id uuid, p_password text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_email    text;
  v_nombre   text;
  v_rol      public.merchant_role;
  v_clinica  text;
  v_bot_tel  text;
  v_helios   text;
  v_wa       text;
  v_panel    text := 'https://conhelios.com/login';
  v_rol_txt  text;
  v_bot_txt  text;
  v_bot_html text;
  e          text;  -- escapado para HTML
begin
  select au.email, nullif(btrim(au.raw_user_meta_data->>'full_name'), '')
    into v_email, v_nombre
  from auth.users au where au.id = p_user_id;

  select mu.role into v_rol
  from public.merchant_users mu
  where mu.merchant_id = p_merchant_id and mu.user_id = p_user_id and mu.is_active
  order by mu.created_at limit 1;

  select m.name into v_clinica from public.merchants m where m.id = p_merchant_id;

  select w.phone_e164 into v_bot_tel
  from public.staff_whatsapp_numbers w
  where w.user_id = p_user_id and w.merchant_id = p_merchant_id and w.revoked_at is null
  order by w.created_at desc limit 1;

  select nullif(regexp_replace(coalesce(c.whatsapp_number, ''), '\D', '', 'g'), '')
    into v_helios
  from public.platform_contact c where c.id;

  v_rol_txt := case v_rol when 'gerente' then 'administrador' else 'secretaria' end;
  v_wa := case when v_helios is not null then 'https://wa.me/' || v_helios end;

  -- El bot: con número registrado, cómo empezar; sin él, cómo pedirlo.
  if v_bot_tel is not null then
    v_bot_txt := format(
      E'También puedes hacerlo por WhatsApp, sin entrar al panel. Escríbele «hola» al bot de Helios%s desde tu número %s. La primera vez te pedirá crear un PIN de 4 números: te lo pedirá cada vez que registres un pago en cuotas.',
      case when v_helios is not null then format(' (+%s, %s)', v_helios, v_wa) else '' end,
      '0' || substr(v_bot_tel, 4));
    v_bot_html := format(
      '<p style="margin:0 0 12px">También puedes hacerlo <b>por WhatsApp</b>, sin entrar al panel. Escríbele «hola» al bot de Helios desde tu número <b>%s</b>. La primera vez te pedirá crear un PIN de 4 números: te lo pedirá cada vez que registres un pago en cuotas.</p>%s',
      '0' || substr(v_bot_tel, 4),
      case when v_wa is not null then format(
        '<p style="margin:0 0 20px"><a href="%s" style="display:inline-block;background:#045EF3;color:#ffffff;text-decoration:none;font-weight:600;padding:10px 18px;border-radius:999px">Abrir el bot en WhatsApp</a></p>', v_wa)
      else '' end);
  else
    v_bot_txt := 'También puedes hacer el mismo proceso por WhatsApp con el bot de Helios. Para usarlo, pide al equipo de Helios que registre tu número de WhatsApp.';
    v_bot_html := '<p style="margin:0 0 20px">También puedes hacer el mismo proceso <b>por WhatsApp</b> con el bot de Helios. Para usarlo, pide al equipo de Helios que registre tu número de WhatsApp.</p>';
  end if;

  e := public.helios_html_escape(p_password);

  return jsonb_build_object(
    'to', v_email,
    'subject', format('Tu acceso a Helios · %s', v_clinica),
    'text', format(
      E'Hola%s:\n\nYa tienes acceso a Helios como %s de %s. Desde el panel registras los pagos en cuotas de tus pacientes y consultas los que ya registraste.\n\nEntra en %s con:\n  Correo: %s\n  Contraseña: %s\n\n%s\n\nGuarda estos datos en un lugar seguro y no los compartas: cada pago en cuotas queda registrado a tu nombre.\n\nEl equipo de Helios',
      coalesce(', ' || v_nombre, ''), v_rol_txt, v_clinica, v_panel, v_email, p_password, v_bot_txt),
    'html', format(
      '<!doctype html><html lang="es"><body style="margin:0;padding:0;background:#F4F6FA">'
      '<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" style="background:#F4F6FA"><tr><td align="center" style="padding:24px 12px">'
      '<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border:1px solid #E3E8F1;border-radius:16px;font-family:''Source Sans 3'',''Segoe UI'',Arial,sans-serif;color:#050F2C;font-size:15px;line-height:1.5">'
      '<tr><td style="padding:24px 28px 8px"><img src="https://conhelios.com/correo/logo-helios.png" width="120" height="49" alt="Helios" style="display:block;border:0;color:#002770;font-weight:700;font-size:22px"></td></tr>'
      '<tr><td style="padding:8px 28px 28px">'
      '<h1 style="margin:0 0 12px;font-family:Outfit,''Segoe UI'',Arial,sans-serif;font-size:22px;color:#002770">Hola%s</h1>'
      '<p style="margin:0 0 12px">Ya tienes acceso a Helios como <b>%s</b> de <b>%s</b>. Desde el panel registras los pagos en cuotas de tus pacientes y consultas los que ya registraste.</p>'
      '<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" style="background:#E8F3FF;border-radius:12px;margin:8px 0 16px"><tr><td style="padding:14px 18px">'
      '<p style="margin:0;color:#46526F;font-size:13px">Correo</p><p style="margin:0 0 8px;font-family:Consolas,Menlo,monospace;font-size:15px">%s</p>'
      '<p style="margin:0;color:#46526F;font-size:13px">Contraseña</p><p style="margin:0;font-family:Consolas,Menlo,monospace;font-size:15px;letter-spacing:.5px">%s</p>'
      '</td></tr></table>'
      '<p style="margin:0 0 20px"><a href="%s" style="display:inline-block;background:#002770;color:#ffffff;text-decoration:none;font-weight:600;padding:10px 18px;border-radius:999px">Entrar al panel</a></p>'
      '%s'
      '<p style="margin:0;color:#6B7690;font-size:13px">Guarda estos datos en un lugar seguro y no los compartas: cada pago en cuotas queda registrado a tu nombre.</p>'
      '</td></tr></table>'
      '<p style="margin:16px 0 0;color:#6B7690;font-size:12px;font-family:Arial,sans-serif">El equipo de Helios</p>'
      '</td></tr></table></body></html>',
      coalesce(', ' || public.helios_html_escape(v_nombre), ''),
      v_rol_txt,
      public.helios_html_escape(v_clinica),
      public.helios_html_escape(v_email),
      e,
      v_panel,
      v_bot_html)
  );
end;
$$;

revoke all on function public.helios_staff_welcome_email(uuid, uuid, text) from public, anon, authenticated;

/**
 * Manda el correo de bienvenida a una persona del personal (ver arriba).
 * Devuelve `{status, error?}`; solo lanza por permisos o por una contraseña
 * que no es la de la cuenta.
 */
create or replace function public.merchant_staff_send_welcome(p_merchant_id uuid, p_user_id uuid, p_password text)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, extensions, pg_temp
as $$
declare
  v_actor   uuid := auth.uid();
  v_hash    text;
  v_key     text;
  v_from    text;
  v_copia   text;
  v_correo  jsonb;
  v_body    jsonb;
  v_resp    jsonb;
  v_status  text;
  v_error   text;
begin
  perform public.helios_assert_staff_manager(p_merchant_id, p_user_id);

  if not exists (select 1 from public.merchant_users
                 where merchant_id = p_merchant_id and user_id = p_user_id and is_active) then
    raise exception 'Esa persona no es personal de esta clínica' using errcode = 'P0002';
  end if;

  select encrypted_password into v_hash from auth.users where id = p_user_id;
  if v_hash is null or p_password is null or extensions.crypt(p_password, v_hash) <> v_hash then
    raise exception 'Esa no es la contraseña de la cuenta' using errcode = '22023';
  end if;

  v_correo := public.helios_staff_welcome_email(p_merchant_id, p_user_id, p_password);
  v_key    := public.helios_resend_api_key();
  v_from   := public.helios_email_sender();
  select nullif(btrim(staff_welcome_copy), '') into v_copia from public.platform_contact where id;

  if v_correo->>'to' is null then
    v_status := 'fallido';
    v_error  := 'La cuenta no tiene correo';
  elsif v_key is null or v_from is null then
    v_status := 'sin_configurar';
  else
    v_body := jsonb_build_object(
      'from', v_from,
      'to', jsonb_build_array(v_correo->>'to'),
      'subject', v_correo->>'subject',
      'text', v_correo->>'text',
      'html', v_correo->>'html');
    if v_copia is not null and lower(v_copia) <> lower(v_correo->>'to') then
      v_body := v_body || jsonb_build_object('bcc', jsonb_build_array(v_copia));
    end if;

    begin
      v_resp := public.helios_resend_request('POST', '/emails', v_key, v_body, gen_random_uuid()::text);
      if (v_resp->>'status')::int between 200 and 299 then
        v_status := 'enviado';
      else
        v_status := 'fallido';
        v_error  := format('Resend respondió %s', v_resp->>'status');
      end if;
    exception when others then
      v_status := 'fallido';
      v_error  := 'Sin respuesta del servicio de correo';
    end;
  end if;

  perform audit.log(v_actor, 'merchant.staff_welcome_sent', p_merchant_id, jsonb_build_object(
    'user_id', p_user_id, 'email', v_correo->>'to', 'copia', v_copia, 'status', v_status, 'error', v_error));

  return jsonb_build_object('status', v_status, 'error', v_error);
end;
$$;

revoke all on function public.merchant_staff_send_welcome(uuid, uuid, text) from public, anon;
grant execute on function public.merchant_staff_send_welcome(uuid, uuid, text) to authenticated;
