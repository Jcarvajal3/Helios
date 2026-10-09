-- ============================================================================
-- Helios — La bienvenida del personal no dice el rol
--
-- «Ya tienes acceso a Helios como administrador de Consultorio DEMO» pasa a
-- «Ya tienes acceso a Helios en Consultorio DEMO» (Javier, 2026-10-09): el
-- rol (`gerente` / `cajero`) es interno y no se le dice a nadie de la
-- clínica. Lo demás de `helios_staff_welcome_email` queda igual que en
-- 20261009000300.
-- ============================================================================

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
  v_clinica  text;
  v_bot_tel  text;
  v_helios   text;
  v_wa       text;
  v_panel    text := 'https://conhelios.com/login';
  v_bot_txt  text;
  v_bot_html text;
  e          text;  -- escapado para HTML
begin
  select au.email, nullif(btrim(au.raw_user_meta_data->>'full_name'), '')
    into v_email, v_nombre
  from auth.users au where au.id = p_user_id;

  select m.name into v_clinica from public.merchants m where m.id = p_merchant_id;

  select w.phone_e164 into v_bot_tel
  from public.staff_whatsapp_numbers w
  where w.user_id = p_user_id and w.merchant_id = p_merchant_id and w.revoked_at is null
  order by w.created_at desc limit 1;

  select nullif(regexp_replace(coalesce(c.whatsapp_number, ''), '\D', '', 'g'), '')
    into v_helios
  from public.platform_contact c where c.id;

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
      E'Hola%s:\n\nYa tienes acceso a Helios en %s. Desde el panel registras los pagos en cuotas de tus pacientes y consultas los que ya registraste.\n\nEntra en %s con:\n  Correo: %s\n  Contraseña: %s\n\n%s\n\nGuarda estos datos en un lugar seguro y no los compartas: cada pago en cuotas queda registrado a tu nombre.\n\nEl equipo de Helios',
      coalesce(', ' || v_nombre, ''), v_clinica, v_panel, v_email, p_password, v_bot_txt),
    'html', format(
      '<!doctype html><html lang="es"><body style="margin:0;padding:0;background:#F4F6FA">'
      '<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" style="background:#F4F6FA"><tr><td align="center" style="padding:24px 12px">'
      '<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border:1px solid #E3E8F1;border-radius:16px;font-family:''Source Sans 3'',''Segoe UI'',Arial,sans-serif;color:#050F2C;font-size:15px;line-height:1.5">'
      '<tr><td style="padding:24px 28px 8px"><img src="https://conhelios.com/correo/logo-helios.png" width="120" height="49" alt="Helios" style="display:block;border:0;color:#002770;font-weight:700;font-size:22px"></td></tr>'
      '<tr><td style="padding:8px 28px 28px">'
      '<h1 style="margin:0 0 12px;font-family:Outfit,''Segoe UI'',Arial,sans-serif;font-size:22px;color:#002770">Hola%s</h1>'
      '<p style="margin:0 0 12px">Ya tienes acceso a Helios en <b>%s</b>. Desde el panel registras los pagos en cuotas de tus pacientes y consultas los que ya registraste.</p>'
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
      public.helios_html_escape(v_clinica),
      public.helios_html_escape(v_email),
      e,
      v_panel,
      v_bot_html)
  );
end;
$$;

revoke all on function public.helios_staff_welcome_email(uuid, uuid, text) from public, anon, authenticated;
