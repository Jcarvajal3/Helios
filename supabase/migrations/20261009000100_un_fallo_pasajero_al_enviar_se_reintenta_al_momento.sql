-- ============================================================================
-- Helios — Un fallo pasajero al enviar un WhatsApp se reintenta al momento (2026-10-09)
--
-- El bot manda a veces dos mensajes seguidos (la introducción y el
-- formulario). En producción, ~1 de cada 10 envíos fallaba al primer intento
-- con un error pasajero, y el despacho lo dejaba para dentro de 20 s: el
-- segundo mensaje llegaba ~23 s después del primero.
--
-- Ahora, si el fallo es pasajero y rápido (sin respuesta por la conexión, un
-- 429 o un 5xx, en menos de 5 s), se reintenta una vez al momento (medio
-- segundo después), dentro del mismo intento. Si vuelve a fallar, sigue como
-- antes (más tarde, y al rendirse a la cola manual). Un timeout no se repite
-- al momento: pudo haber llegado.
--
-- El resultado trae `errores` (la causa de cada fallo pasajero) para el log
-- del webhook. Lo demás de la función, idéntico a su última definición
-- (20261005000400).
-- ============================================================================

create or replace function public.helios_dispatch_whatsapp_batch(p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_attempts constant integer := 5;
  v_key     text := public.helios_vault_secret('d360_api_key');
  v_base    text := public.helios_vault_secret('d360_base_url');
  v_start   timestamptz := clock_timestamp();
  v_msg     public.outbound_messages%rowtype;
  v_payload jsonb;
  v_res     jsonb;
  v_status  integer;
  v_body    text;
  v_json    jsonb;
  v_code    integer;
  v_err     text;
  v_wamid   text;
  v_att     integer;
  v_claimed integer := 0;
  v_sent    integer := 0;
  v_failed  integer := 0;
  v_retry   integer := 0;
  v_manual  integer := 0;
  v_t0      timestamptz;
  v_errores jsonb := '[]'::jsonb;
begin
  -- Sin la API, lo que haya pendiente lo manda una persona.
  if v_key is null or v_base is null then
    with x as (
      update public.outbound_messages
         set channel = 'whatsapp_manual', next_attempt_at = null,
             last_error = 'Pasó a la cola manual: la API de WhatsApp no está configurada'
       where channel = 'whatsapp' and status = 'pendiente'
      returning id
    )
    select count(*) into v_manual from x;
    return jsonb_build_object('ok', true, 'skipped', 'sin_clave', 'manual', v_manual);
  end if;

  for v_msg in
    select o.*
    from public.outbound_messages o
    where o.channel = 'whatsapp'
      and o.status = 'pendiente'
      and coalesce(o.next_attempt_at, o.created_at) <= now()
    order by coalesce(o.next_attempt_at, o.created_at), o.created_at
    limit least(greatest(coalesce(p_limit, 20), 1), 100)
    for update skip locked
  loop
    exit when clock_timestamp() - v_start > interval '8 seconds';
    v_claimed := v_claimed + 1;

    if regexp_replace(coalesce(v_msg.recipient, ''), '\D', '', 'g') !~ '^[0-9]{8,15}$' then
      update public.outbound_messages
         set status = 'omitido', last_error = 'Sin un teléfono válido'
       where id = v_msg.id;
      continue;
    end if;

    v_payload := public.helios_whatsapp_payload(v_msg);
    if v_payload is null then
      perform public.helios_whatsapp_to_manual(v_msg.id,
        'fuera de la ventana de 24 h y sin plantilla aprobada');
      v_manual := v_manual + 1;
      continue;
    end if;

    -- Un fallo pasajero y rápido (la conexión, un 429, un 5xx) se reintenta
    -- al momento, una vez: esperar al cron eran ~20 s entre dos mensajes
    -- seguidos del bot. Un timeout no (ya tardó y pudo haber llegado).
    for v_try in 1..2 loop
      v_status := null;
      v_body   := null;
      v_err    := null;
      v_json   := null;
      v_code   := null;
      v_t0     := clock_timestamp();
      begin
        v_res    := public.helios_d360_request('POST', '/messages', v_key, v_base, v_payload);
        v_status := (v_res ->> 'status')::integer;
        v_body   := v_res ->> 'body';
      exception when others then
        v_err := left(sqlerrm, 300);
      end;

      begin
        v_json := v_body::jsonb;
        v_code := (v_json -> 'error' ->> 'code')::integer;
      exception when others then
        v_json := null;
      end;

      exit when not (v_status is null or v_status = 429 or v_status >= 500);
      -- Para el log del webhook: la causa de cada fallo pasajero.
      v_errores := v_errores || jsonb_build_object(
        'id', v_msg.id, 'intento', v_try,
        'error', coalesce(v_err, format('HTTP %s: %s', v_status, left(coalesce(v_body, ''), 200))));
      exit when v_try = 2 or clock_timestamp() - v_t0 > interval '5 seconds';
      perform pg_sleep(0.5);
    end loop;

    v_att := v_msg.attempts + 1;

    if v_status between 200 and 299 then
      v_wamid := v_json -> 'messages' -> 0 ->> 'id';
      update public.outbound_messages
         set status = 'enviado', provider_id = v_wamid, sent_at = now(),
             last_event = 'sent', last_event_at = now(),
             attempts = v_att, next_attempt_at = null, last_error = null
       where id = v_msg.id;
      v_sent := v_sent + 1;

    elsif v_status in (401, 403) then
      -- La configuración, no el mensaje: se espera sin gastar intento y se
      -- corta el lote (los demás fallarían igual).
      update public.outbound_messages
         set next_attempt_at = now() + interval '15 minutes',
             last_error = left(format('360dialog rechazó la configuración (HTTP %s): %s', v_status, coalesce(v_body, '')), 300)
       where id = v_msg.id;
      v_retry := v_retry + 1;
      exit;

    elsif v_code in (131026, 131021) then
      -- El teléfono no tiene WhatsApp o no se le puede escribir: ni la API ni
      -- una persona pueden. La clínica lo ve como «No se pudo enviar».
      update public.outbound_messages
         set status = 'fallido', attempts = v_att, next_attempt_at = null,
             last_event = 'failed', last_event_at = now(),
             last_error = left(format('No se le puede escribir a este teléfono (%s): %s', v_code,
                                      coalesce(v_json -> 'error' ->> 'message', v_body, '')), 300)
       where id = v_msg.id;
      v_failed := v_failed + 1;

    elsif v_status between 400 and 499 and v_status <> 429 then
      -- Plantilla sin aprobar, ventana cerrada, parámetros… La API no puede;
      -- una persona sí.
      perform public.helios_whatsapp_to_manual(v_msg.id,
        format('la API respondió %s%s: %s', v_status,
               case when v_code is not null then ' (' || v_code || ')' else '' end,
               coalesce(v_json -> 'error' ->> 'message', v_body, '')));
      v_manual := v_manual + 1;

    else
      -- 429, 5xx o sin respuesta: más tarde. Al rendirse, a la cola manual.
      v_err := coalesce(v_err, format('HTTP %s: %s', v_status, left(coalesce(v_body, ''), 250)));
      if v_att >= c_max_attempts then
        update public.outbound_messages set attempts = v_att where id = v_msg.id;
        perform public.helios_whatsapp_to_manual(v_msg.id,
          format('sin respuesta de 360dialog tras %s intentos. Último: %s', v_att, v_err));
        v_manual := v_manual + 1;
      else
        update public.outbound_messages
           set attempts = v_att,
               next_attempt_at = now() + interval '20 seconds' * power(2, v_att - 1),
               last_error = left(v_err, 300)
         where id = v_msg.id;
        v_retry := v_retry + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true, 'claimed', v_claimed, 'sent', v_sent, 'failed', v_failed,
    'retry', v_retry, 'manual', v_manual, 'errores', v_errores
  );
end;
$$;
