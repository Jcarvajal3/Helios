-- ============================================================================
-- Helios — El bot se calla cuando escribe una persona (2026-11-20)
--
-- El bot hablaba por encima del equipo: alguien contestaba a mano y, al
-- siguiente mensaje del paciente, el bot le soltaba el menú. Ahora, cuando
-- una persona del equipo le escribe a un número, el bot se calla 8 h en ese
-- chat (lo mismo que con «Hablar con alguien», `whatsapp_contacts.human_until`):
--
--   · desde la app WhatsApp Business (coexistencia): Meta manda un eco
--     (`smb_message_echoes`) y el webhook llama a `helios_whatsapp_human_wrote`;
--   · desde el Inbox del superadmin: `admin_whatsapp_inbox_log` con
--     `whatsapp_inbox.message_sent` hace lo mismo (idéntica a la de
--     20261019120000 salvo ese bloque).
--
-- `bot_humano_atiende` se lo dice al bot del médico, que entonces no contesta
-- «No entendí» (sus pasos de una orden siguen funcionando).
--
-- Las 8 h se cuentan desde el último mensaje a mano: nunca acortan un
-- silencio más largo que ya hubiera.
-- ============================================================================

/** Una persona del equipo le escribió a ese número: el bot se calla 8 h. */
create or replace function public.helios_whatsapp_human_wrote(
  p_phone         text,
  p_wa_message_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text := public.helios_wa_e164(p_phone);
begin
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'telefono_invalido');
  end if;

  -- Un mensaje que mandó la API (el bot, un recordatorio) no es de una
  -- persona: si Meta llegara a mandar su eco, no calla nada.
  if p_wa_message_id is not null and exists (
    select 1 from public.outbound_messages
    where provider_id = p_wa_message_id and channel = 'whatsapp'
  ) then
    return jsonb_build_object('ok', true, 'ignored', 'es_de_la_api');
  end if;

  insert into public.whatsapp_contacts (phone_e164, updated_at) values (v_phone, now())
  on conflict (phone_e164) do nothing;

  update public.whatsapp_contacts
     set human_until = greatest(coalesce(human_until, now()), now() + interval '8 hours'),
         updated_at = now()
   where phone_e164 = v_phone;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.helios_whatsapp_human_wrote(text, text) from public, anon, authenticated;
grant execute on function public.helios_whatsapp_human_wrote(text, text) to service_role;

comment on function public.helios_whatsapp_human_wrote(text, text) is
  'Una persona del equipo le escribió a mano a ese número (eco de la app WhatsApp Business o el Inbox del superadmin): el bot se calla 8 h en ese chat (whatsapp_contacts.human_until). Ignora los wamid que mandó la API.';

/** ¿Lo atiende una persona ahora mismo? Para el bot del médico. */
create or replace function public.bot_humano_atiende(p_phone text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select human_until > now()
    from public.whatsapp_contacts
    where phone_e164 = public.helios_wa_e164(p_phone)
  ), false)
$$;

revoke all on function public.bot_humano_atiende(text) from public, anon, authenticated;
grant execute on function public.bot_humano_atiende(text) to service_role;

-- El Inbox del superadmin: al enviar, también se calla el bot.
create or replace function public.admin_whatsapp_inbox_log(
  p_action text,
  p_wa_id  text,
  p_detail jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- Solo las acciones que la Edge Function sabe hacer: la bitácora no es un
  -- cajón donde cualquiera del equipo escriba lo que quiera.
  if p_action is null or p_action not in (
    'whatsapp_inbox.message_sent',
    'whatsapp_inbox.chat_resolved'
  ) then
    raise exception 'Acción del inbox desconocida: %', coalesce(p_action, '(vacía)')
      using errcode = '22023';
  end if;

  if p_wa_id is null or length(btrim(p_wa_id)) = 0 or length(p_wa_id) > 200 then
    raise exception 'Falta el chat (wa_id)' using errcode = '22023';
  end if;

  perform audit.log(
    v_actor,
    p_action,
    null,
    jsonb_build_object('wa_id', p_wa_id) || coalesce(p_detail, '{}'::jsonb)
  );

  -- Una persona contesta: el bot se calla en ese chat (2026-11-20).
  if p_action = 'whatsapp_inbox.message_sent' then
    perform public.helios_whatsapp_human_wrote(p_wa_id, null);
  end if;

  return v_actor;
end;
$$;

revoke all on function public.admin_whatsapp_inbox_log(text, text, jsonb) from public, anon;
grant execute on function public.admin_whatsapp_inbox_log(text, text, jsonb) to authenticated;
