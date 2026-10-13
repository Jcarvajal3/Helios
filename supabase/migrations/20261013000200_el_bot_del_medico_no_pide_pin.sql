-- ============================================================================
-- Helios — El bot del médico no pide PIN (2026-10-13)
--
-- Decisión de Javier: el bot de WhatsApp ya no usa PIN. Basta con escribir
-- desde un número registrado por el equipo (`staff_whatsapp_numbers`), y la
-- orden no es deuda hasta que el paciente responde «Sí» desde su propio
-- WhatsApp: esa sigue siendo la defensa.
--
--   · `bot_create_charge` pierde `p_pin` (la Edge Function se despliega con
--     esta migración).
--   · Fuera `bot_set_pin`, `helios_bot_check_pin`, `admin_reset_staff_pin`
--     y la tabla `staff_pins` (hashes que ya no sirven).
--   · `helios_staff_whatsapp_row` deja de devolver `has_pin` y `pin_locked`.
--   · `helios_whatsapp_inbound` ya no guarda como «[PIN]» los 4 dígitos que
--     escribe el personal.
--   · El correo de bienvenida del personal ya no habla del PIN.
--
-- `helios_pin_aceptable` se queda: es de la app de Ronda (20260825150000),
-- no del bot. Las líneas viejas de la bitácora (`staff.pin_reset`) quedan.
-- ============================================================================

-- 1. La orden desde el bot, sin PIN ------------------------------------------

drop function public.bot_create_charge(text, text, jsonb, numeric, text, text, text, text);

create function public.bot_create_charge(
  p_phone            text,
  p_patient          jsonb,
  p_amount           numeric,
  p_concept          text,
  p_beneficiary_name text,
  p_idempotency_key  text,
  p_currency         text default 'USD'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
begin
  perform public.helios_bot_as(v_n.user_id);
  return jsonb_build_object('ok', true, 'charge',
    public.create_patient_charge(v_n.merchant_id, null, p_patient, p_amount,
                                 p_concept, p_beneficiary_name, p_idempotency_key, p_currency));
end;
$$;

revoke all on function public.bot_create_charge(text, jsonb, numeric, text, text, text, text) from public, anon, authenticated;
grant execute on function public.bot_create_charge(text, jsonb, numeric, text, text, text, text) to service_role;

-- 2. Fuera el PIN -------------------------------------------------------------

drop function public.bot_set_pin(text, text);
drop function public.helios_bot_check_pin(uuid, text);
drop function public.admin_reset_staff_pin(uuid, text);

CREATE OR REPLACE FUNCTION public.helios_staff_whatsapp_row(p_n staff_whatsapp_numbers)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'id', p_n.id,
    'phone_e164', p_n.phone_e164,
    'user_id', p_n.user_id,
    'staff_name', public.helios_staff_name(p_n.user_id),
    'role', (select mu.role::text from public.merchant_users mu
              where mu.user_id = p_n.user_id and mu.merchant_id = p_n.merchant_id and mu.is_active
              order by (mu.role = 'gerente') desc limit 1),
    'merchant_id', p_n.merchant_id,
    'merchant_name', (select m.name from public.merchants m where m.id = p_n.merchant_id),
    'last_inbound_at', (select c.last_inbound_at from public.whatsapp_contacts c where c.phone_e164 = p_n.phone_e164),
    'created_at', p_n.created_at,
    'created_by_name', public.helios_staff_name(p_n.created_by),
    'revoked_at', p_n.revoked_at,
    'revoked_by_name', case when p_n.revoked_by is not null then public.helios_staff_name(p_n.revoked_by) end,
    'revoke_reason', p_n.revoke_reason
  );
$function$;

-- Lo que escribe el personal ya no se tacha como «[PIN]» al guardarlo.
CREATE OR REPLACE FUNCTION public.helios_whatsapp_inbound(p_message_id text, p_from text, p_type text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_phone   text := public.helios_wa_e164(p_from);
  v_staff   public.staff_whatsapp_numbers%rowtype;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_pend    uuid[];
  v_profile uuid;
begin
  if nullif(btrim(coalesce(p_message_id, '')), '') is null or v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'peticion_invalida');
  end if;

  select n.* into v_staff
  from public.staff_whatsapp_numbers n
  join public.merchant_users mu
    on mu.user_id = n.user_id and mu.merchant_id = n.merchant_id and mu.is_active
   and mu.role in ('gerente', 'cajero')
  where n.phone_e164 = v_phone and n.revoked_at is null
  limit 1;

  insert into public.whatsapp_inbound (wa_message_id, from_phone, type, payload)
  values (p_message_id, v_phone, p_type, v_payload)
  on conflict (wa_message_id) do nothing;

  if not found then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;

  select array_agg(c.id order by c.created_at), min(p.id::text)::uuid
    into v_pend, v_profile
  from public.charges c
  join public.profiles p on p.id = c.user_id
  where c.status = 'pending' and c.expires_at > now()
    and regexp_replace(coalesce(p.phone_e164, ''), '\D', '', 'g') = regexp_replace(v_phone, '\D', '', 'g');

  if v_profile is null then
    select p.id into v_profile from public.profiles p
    where p.phone_e164 = v_phone order by p.created_at desc limit 1;
  end if;

  insert into public.whatsapp_contacts (phone_e164, last_inbound_at, profile_id, staff_user_id, updated_at)
  values (v_phone, now(), v_profile, v_staff.user_id, now())
  on conflict (phone_e164) do update
    set last_inbound_at = now(),
        profile_id = coalesce(excluded.profile_id, whatsapp_contacts.profile_id),
        staff_user_id = excluded.staff_user_id,
        updated_at = now();

  return jsonb_build_object(
    'ok', true,
    'duplicate', false,
    'phone_e164', v_phone,
    'staff', case when v_staff.id is not null then public.helios_staff_whatsapp_row(v_staff) end,
    'pending_charge_id', case when cardinality(v_pend) = 1 then v_pend[1] end
  );
end;
$function$;

drop table public.staff_pins;

-- 3. El correo de bienvenida, sin el PIN -------------------------------------

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
      E'También puedes hacerlo por WhatsApp, sin entrar al panel. Escríbele «hola» al bot de Helios%s desde tu número %s. Te guía paso a paso.',
      case when v_helios is not null then format(' (+%s, %s)', v_helios, v_wa) else '' end,
      '0' || substr(v_bot_tel, 4));
    v_bot_html := format(
      '<p style="margin:0 0 12px">También puedes hacerlo <b>por WhatsApp</b>, sin entrar al panel. Escríbele «hola» al bot de Helios desde tu número <b>%s</b>. Te guía paso a paso.</p>%s',
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

do $$
begin
  if exists (select 1 from pg_proc where proname in ('bot_set_pin', 'helios_bot_check_pin', 'admin_reset_staff_pin')) then
    raise exception 'Quedó una función del PIN';
  end if;
  if pg_get_functiondef('public.helios_staff_welcome_email(uuid, uuid, text)'::regprocedure) ilike '%PIN%' then
    raise exception 'El correo de bienvenida todavía habla del PIN';
  end if;
end
$$;
