-- ============================================================================
-- Helios — El inbox de WhatsApp del superadmin (20261019120000)
--
-- `admin_whatsapp_inbox_log` es lo que la Edge Function `whatsapp-inbox`
-- llama antes de contestar o resolver un chat. Aquí se comprueba que:
--
--   1. Alguien que no es del equipo no pasa (42501): sin bitácora no sale nada.
--   2. Una acción que la función no conoce, tampoco (22023).
--   3. Sin chat (wa_id), tampoco.
--   4. Un admin deja la acción en audit.admin_actions con el wa_id en el detalle.
--
-- No llama al Inbox: la RPC no tiene red.
-- ============================================================================
begin;
-- @ayudas

do $$
declare
  v_admin uuid := pg_temp.prueba_admin();
  v_extrano uuid := gen_random_uuid();
  v_fallo boolean;
  v_actor uuid;
  v_fila audit.admin_actions;
begin
  -- 1. Alguien de fuera del equipo.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_extrano::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_whatsapp_inbox_log('whatsapp_inbox.message_sent', '584141234567', '{}');
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '1. alguien de fuera del equipo anotó en la bitácora del inbox'; end if;

  -- Desde aquí, el admin (con el segundo factor).
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- 2. Una acción desconocida.
  v_fallo := false;
  begin
    perform public.admin_whatsapp_inbox_log('payment.reconciled', '584141234567', '{}');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '2. la bitácora del inbox aceptó una acción ajena'; end if;

  -- 3. Sin chat.
  v_fallo := false;
  begin
    perform public.admin_whatsapp_inbox_log('whatsapp_inbox.chat_resolved', '  ', '{}');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. la bitácora del inbox aceptó una acción sin chat'; end if;

  -- 4. Lo bueno.
  v_actor := public.admin_whatsapp_inbox_log('whatsapp_inbox.message_sent', '584141234567', '{"caracteres": 12}');
  if v_actor is distinct from v_admin then raise exception '4. devolvió otro actor: %', v_actor; end if;

  reset role;
  select * into v_fila
    from audit.admin_actions
   where actor = v_admin and action = 'whatsapp_inbox.message_sent'
   order by created_at desc limit 1;
  if v_fila.actor is null then raise exception '4. la acción no quedó en audit.admin_actions'; end if;
  if v_fila.detail ->> 'wa_id' is distinct from '584141234567' or (v_fila.detail ->> 'caracteres')::int <> 12 then
    raise exception '4. el detalle no lleva el chat y los caracteres: %', v_fila.detail;
  end if;
end;
$$;

rollback;
