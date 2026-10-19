-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El inbox de WhatsApp en el superadmin
--
-- El equipo lee y contesta las conversaciones del número de Helios desde el
-- superadmin, a través del Inbox de 360dialog (Inbox API). La pieza que habla
-- con el Inbox es la Edge Function `whatsapp-inbox`: guarda el token del
-- Inbox (secreto D360_INBOX_TOKEN) y el navegador nunca lo ve.
--
-- La función corre cada petición con el JWT de quien la hace. Para leer le
-- basta `is_platform_admin()` (con el segundo factor, si está exigido). Para
-- escribir —contestar a un chat, marcarlo resuelto— llama antes a esta RPC,
-- que comprueba lo mismo y deja la acción en `audit.admin_actions`. Si la
-- bitácora no se escribe, el mensaje no sale.
-- ═══════════════════════════════════════════════════════════════════════════

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

  return v_actor;
end;
$$;

comment on function public.admin_whatsapp_inbox_log(text, text, jsonb) is
  'Autoriza (is_platform_admin, con MFA) y anota en audit.admin_actions una escritura del inbox de WhatsApp. La llama la Edge Function whatsapp-inbox antes de mandar nada al Inbox de 360dialog.';

revoke all on function public.admin_whatsapp_inbox_log(text, text, jsonb) from public, anon;
grant execute on function public.admin_whatsapp_inbox_log(text, text, jsonb) to authenticated;
