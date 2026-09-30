-- ============================================================================
-- Ronda — Los acuses de push se leen todos, y un fallo de Expo espera antes
--         de reintentar
--
-- Dos límites que quedaron del transporte de push de agosto, ahora que los
-- avisos salen por lotes (20260923174000):
--
--   · `check_push_receipts` pide a Expo como mucho 1.000 acuses por pasada y
--     pg_cron la corre cada 15 minutos: 96.000 al día. El despachador ya manda
--     miles por minuto, así que lo enviado se quedaría sin confirmar y, a las
--     24 horas, Expo borra los acuses (se cierran como "Expo ya no guardaba el
--     acuse" sin saber si llegaron ni qué tokens ya no existen).
--     Ahora `check_push_receipts_loop()` repite la consulta dentro de la misma
--     pasada, con un `commit` por lote, hasta 30 segundos. Se para cuando un
--     lote viene incompleto (ya no queda nada viejo por mirar) o cuando no
--     cierra ninguno: los acuses que Expo aún no tiene se quedan delante y se
--     vuelven a pedir, así que un lote sin ninguno cerrado quiere decir que
--     los de delante no están listos y seguir sería pedir los mismos. Expo
--     admite 1.000 identificadores por petición.
--
--   · Un error de Expo o de la red dejaba el lote en cola y el siguiente tic,
--     15 segundos después, lo volvía a intentar: cinco intentos en poco más
--     de un minuto y el aviso se daba por perdido. Expo pide lo contrario,
--     esperar cada vez más ante un 429, un 5xx o un fallo de red. Ahora cada
--     entrega guarda cuándo puede volver a salir (`next_attempt_at`): 15 s,
--     1 min, 4 min y 16 min tras el primer, segundo, tercer y cuarto fallo.
--     El quinto sigue siendo el último, pero ahora cubre ~21 minutos de caída
--     y no uno.
--
-- Mismo procedure con `commit` que el despachador, y por lo mismo: sin
-- SECURITY DEFINER ni `set search_path`, corre como `postgres` desde pg_cron y
-- ningún rol de la API puede llamarlo.
-- ============================================================================

alter table public.push_deliveries
  add column if not exists next_attempt_at timestamptz;

comment on column public.push_deliveries.next_attempt_at is
  'Antes de esta hora el despachador no vuelve a intentarlo (espera creciente tras un fallo de Expo o de la red). Null: cuando toque.';

-- ---------------------------------------------------------------------------
-- 1. Un lote: igual que en 20260923174000 salvo que respeta la espera de cada
--    entrega y, si Expo o la red fallan, la alarga.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dispatch_push_queue(p_batch integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c_endpoint     constant text    := 'https://exp.host/--/api/v2/push/send';
  -- Cinco intentos con espera creciente (15 s, 1 min, 4 min, 16 min) cubren
  -- unos 21 minutos de caída de Expo o de la red. Más allá, lo que falla no
  -- es la red: es que algo está mal y hay que verlo.
  c_max_attempts constant integer := 5;
  v_secret   text;
  v_headers  extensions.http_header[];
  v_ids      bigint[];
  v_messages jsonb;
  v_status   integer;
  v_body     text;
  v_response jsonb;
  v_sent     integer := 0;
  v_failed   integer := 0;
begin
  -- Lo que agotó los intentos deja de dar vueltas.
  update public.push_deliveries
     set status = 'failed',
         error = coalesce(error, format('Sin respuesta de Expo tras %s intentos', c_max_attempts)),
         settled_at = now()
   where status = 'pending' and attempts >= c_max_attempts;

  -- Lo que espera a un token ya desactivado no se va a poder reclamar nunca:
  -- se cierra aquí para que no se recorra en cada lote ni se quede para
  -- siempre sin fecha de cierre, que es lo que mira `purge_push_queue`.
  update public.push_deliveries d
     set status = 'cancelled',
         error = coalesce(d.error, 'El dispositivo se dio de baja antes del envío'),
         settled_at = now()
    from public.push_tokens t
   where t.token = d.token
     and d.status = 'pending'
     and t.disabled_at is not null;

  -- Reclamar el lote. `skip locked` para que dos ejecuciones solapadas —el
  -- cron y una llamada a mano— no manden el mismo aviso dos veces. Primero
  -- lo urgente (`priority`), y dentro de cada nivel por orden de llegada.
  with claimed as (
    select d.id
    from public.push_deliveries d
    join public.push_tokens t on t.token = d.token
    where d.status = 'pending'
      and t.disabled_at is null
      -- La espera tras un fallo de Expo o de la red: ver `next_attempt_at`.
      and (d.next_attempt_at is null or d.next_attempt_at <= now())
    order by d.priority, d.id
    limit least(greatest(coalesce(p_batch, 100), 1), 100)
    for update of d skip locked
  ),
  bumped as (
    update public.push_deliveries d
       set attempts = d.attempts + 1
      from claimed c
     where d.id = c.id
    returning d.id
  )
  select array_agg(id order by id) into v_ids from bumped;

  if v_ids is null then
    return jsonb_build_object('ok', true, 'claimed', 0);
  end if;

  -- El orden de los mensajes ES el orden de las respuestas: Expo contesta un
  -- array paralelo al que recibe. Los dos `order by d.id` son lo que sostiene
  -- esa correspondencia, y perderla sería atribuirle a un aviso el ticket de
  -- otro.
  select jsonb_agg(
           public.push_envelope(d.token, n.type, n.title, n.body, n.data, n.id)
           order by d.id
         )
    into v_messages
  from public.push_deliveries d
  join public.notifications n on n.id = d.notification_id
  where d.id = any(v_ids);

  begin
    select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'expo_access_token' limit 1;
  exception when others then
    v_secret := null;
  end;

  v_headers := array[
    extensions.http_header('Accept', 'application/json'),
    -- Sin gzip: la extensión `http` no lo descomprime y la respuesta llegaría
    -- como binario ilegible.
    extensions.http_header('Accept-Encoding', 'identity')
  ];
  if v_secret is not null then
    v_headers := v_headers || extensions.http_header('Authorization', 'Bearer ' || v_secret);
  end if;

  -- Sin tope de tiempo, un servidor que acepta la conexión y no contesta deja
  -- colgado al worker del cron y con él a toda la cola.
  begin
    perform extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '4000');
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  exception when others then
    null;
  end;

  begin
    select r.status, r.content into v_status, v_body
    from extensions.http((
      'POST',
      c_endpoint,
      v_headers,
      'application/json',
      v_messages::text
    )::extensions.http_request) as r;
  exception when others then
    -- Falló la red. El lote se queda en `pending` con un intento más gastado
    -- y no vuelve a salir hasta que pase su espera.
    update public.push_deliveries
       set next_attempt_at = now() + interval '15 seconds' * power(4, greatest(attempts - 1, 0))
     where id = any(v_ids);
    return jsonb_build_object(
      'ok', false, 'claimed', array_length(v_ids, 1), 'error', left(sqlerrm, 300)
    );
  end;

  if v_status is distinct from 200 then
    -- 429 y 5xx son "vuelve luego": se dejan en cola. Un 4xx es culpa nuestra
    -- —mensaje mal formado, token de acceso inválido— y reintentarlo cinco
    -- veces solo retrasa el momento de enterarse.
    if v_status in (429, 500, 502, 503, 504) then
    update public.push_deliveries
       set next_attempt_at = now() + interval '15 seconds' * power(4, greatest(attempts - 1, 0))
     where id = any(v_ids);
      return jsonb_build_object(
        'ok', false, 'claimed', array_length(v_ids, 1), 'http_status', v_status
      );
    end if;

    update public.push_deliveries
       set status = 'failed',
           error = left(format('HTTP %s: %s', v_status, coalesce(v_body, '')), 300),
           settled_at = now()
     where id = any(v_ids);

    return jsonb_build_object(
      'ok', false, 'claimed', array_length(v_ids, 1), 'http_status', v_status,
      'body', left(coalesce(v_body, ''), 300)
    );
  end if;

  begin
    v_response := v_body::jsonb;
  exception when others then
    return jsonb_build_object('ok', false, 'claimed', array_length(v_ids, 1),
                              'error', 'Respuesta de Expo ilegible');
  end;

  if v_response -> 'data' is null then
    update public.push_deliveries
       set status = 'failed',
           error = left(coalesce(v_response #>> '{errors,0,message}',
                                 'Expo no devolvió tickets'), 300),
           settled_at = now()
     where id = any(v_ids);

    return jsonb_build_object('ok', false, 'claimed', array_length(v_ids, 1),
                              'error', v_response -> 'errors');
  end if;

  with ticket as (
    select ord, elem
    from jsonb_array_elements(v_response -> 'data') with ordinality as t(elem, ord)
  ),
  pairs as (
    select ids.id, t.elem
    from unnest(v_ids) with ordinality as ids(id, ord)
    join ticket t on t.ord = ids.ord
  )
  update public.push_deliveries d
     set status     = case when p.elem ->> 'status' = 'ok' then 'sent' else 'failed' end::public.push_status,
         ticket_id  = p.elem ->> 'id',
         error      = case
                        when p.elem ->> 'status' = 'ok' then null
                        else left(concat_ws(': ', p.elem #>> '{details,error}',
                                                  p.elem ->> 'message'), 300)
                      end,
         sent_at    = case when p.elem ->> 'status' = 'ok' then now() else d.sent_at end,
         settled_at = case when p.elem ->> 'status' = 'ok' then null else now() end
    from pairs p
   where d.id = p.id;

  -- Un token que Expo no reconoce es una app desinstalada. Seguir mandándole
  -- avisos es gastar cola para siempre.
  update public.push_tokens t
     set disabled_at = now(), disabled_reason = 'DeviceNotRegistered'
   where t.disabled_at is null
     and t.token in (
       select d.token from public.push_deliveries d
       where d.id = any(v_ids)
         and d.status = 'failed'
         and d.error like 'DeviceNotRegistered%'
     );

  select count(*) filter (where status = 'sent'),
         count(*) filter (where status = 'failed')
    into v_sent, v_failed
  from public.push_deliveries where id = any(v_ids);

  return jsonb_build_object(
    'ok', true, 'claimed', array_length(v_ids, 1), 'sent', v_sent, 'failed', v_failed
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 2. Los acuses: lote tras lote, cada uno confirmado por separado
-- ---------------------------------------------------------------------------
create or replace procedure public.check_push_receipts_loop(p_budget interval default interval '30 seconds')
language plpgsql
as $$
declare
  v_started timestamptz := clock_timestamp();
  v_result  jsonb;
begin
  loop
    v_result := public.check_push_receipts();
    commit;

    exit when not coalesce((v_result ->> 'ok')::boolean, false)
           or coalesce((v_result ->> 'checked')::int, 0) < 1000
           or coalesce((v_result ->> 'settled')::int, 0) = 0
           or clock_timestamp() - v_started >= p_budget;
  end loop;
end;
$$;

revoke all on procedure public.check_push_receipts_loop(interval) from public, anon, authenticated;

select cron.alter_job(
  job_id  := (select jobid from cron.job where jobname = 'helios_push_receipts'),
  command := 'call public.check_push_receipts_loop()'
);
