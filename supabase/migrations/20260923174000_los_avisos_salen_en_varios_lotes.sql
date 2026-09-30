-- ============================================================================
-- Ronda — Los avisos salen en varios lotes por pasada, y los urgentes primero
--
-- `dispatch_push_queue` reclama como mucho 100 avisos, hace UN POST a Expo y
-- termina; pg_cron la llama cada 15 segundos. Techo: 400 avisos por minuto.
-- Un lote tarda ~321 ms de media en producción, así que el despachador pasa
-- más del 85 % de cada ventana sin hacer nada mientras la cola espera. Una
-- promo a toda la base, o los recordatorios de las 19:00 de una noche con
-- miles de cuotas, tardarían decenas de minutos en salir, y un "tu grupo pagó"
-- metido detrás esperaría con ellos.
--
-- Qué cambia:
--
--   · `dispatch_push_queue_loop()`, un PROCEDURE, repite lote tras lote dentro
--     de la misma pasada hasta vaciar la cola o gastar 10 segundos. Con lotes
--     de ~0,3 s son del orden de 4.000-12.000 avisos por minuto; Expo admite
--     600 por segundo.
--
--   · Cada lote se confirma por separado (`commit` después de cada uno). Es la
--     razón de que sea un procedure llamado con `call` y no una función: una
--     función corre entera en una transacción, y un error en el quinto lote
--     desharía los `sent` de los cuatro anteriores —que Expo ya entregó— y el
--     siguiente tic los mandaría otra vez. Por lo mismo NO puede ser SECURITY
--     DEFINER ni llevar `set search_path`: Postgres no deja hacer `commit`
--     dentro de ninguna de las dos. Corre como `postgres`, que es quien lanza
--     el trabajo de pg_cron, y ningún rol de la API puede llamarla.
--
--   · La pasada se corta en cuanto un lote no sale bien (red caída, 429 o 5xx
--     de Expo, un 4xx): insistir en el mismo tic solo gastaría intentos. El
--     siguiente tic, a los 15 segundos, sigue donde se quedó.
--
--   · Prioridad. Cada entrega lleva la de su tipo de aviso, y el reparto se
--     hace por prioridad y después por orden de llegada:
--       0  lo que pasa ahora: cobros de grupo, pagos, mora, cuenta, KYC…
--       1  recordatorios de cuota, nivel y Bits;
--       2  promos.
--     Un tipo nuevo cae en 0 si nadie lo clasifica: es mejor que un aviso
--     cualquiera adelante a una promo que un cobro espere detrás de ella.
--
--   · Lo pendiente de un token ya desactivado se cierra al empezar cada lote.
--     Esas filas no se pueden reclamar nunca (el reparto exige token vivo),
--     `purge_push_queue` no las borra porque no están cerradas, y con la
--     pasada en bucle se recorrerían en cada lote.
--
-- La correspondencia aviso → ticket sigue igual: se reclama por prioridad,
-- pero los mensajes se arman y se emparejan por `id`, que es lo que alinea el
-- array que se manda con el que Expo devuelve.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La prioridad de cada entrega
-- ---------------------------------------------------------------------------
create or replace function public.push_priority(p_type public.notification_type)
returns smallint
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when p_type = 'promo' then 2
    when p_type in ('installment_due', 'level_up', 'bits_earned') then 1
    else 0
  end::smallint;
$$;

alter table public.push_deliveries
  add column if not exists priority smallint not null default 0;

comment on column public.push_deliveries.priority is
  '0 transaccional, 1 recordatorio, 2 promo (push_priority). El despachador reparte por (priority, id).';

-- Lo que esté en cola al aplicar esto, con su prioridad de verdad.
update public.push_deliveries d
   set priority = public.push_priority(n.type)
  from public.notifications n
 where n.id = d.notification_id
   and d.status = 'pending';

create index if not exists push_deliveries_pending_priority_idx
  on public.push_deliveries (priority, id)
  where status = 'pending';

-- El de solo `id` ya no lo usa el reparto, y el nuevo cubre los mismos
-- recorridos de "lo pendiente".
drop index if exists public.push_deliveries_pending_idx;

-- Cada aviso nuevo entra en la cola con la prioridad de su tipo.
create or replace function public.enqueue_push()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.push_deliveries (notification_id, token, priority)
  select new.id, t.token, public.push_priority(new.type)
  from public.push_tokens t
  where t.user_id = new.user_id
    and t.disabled_at is null
  on conflict (notification_id, token) do nothing;

  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Un lote: igual que en 20260825100000_push_transport.sql salvo el orden
--    del reparto y el cierre de lo pendiente de tokens muertos.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dispatch_push_queue(p_batch integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c_endpoint     constant text    := 'https://exp.host/--/api/v2/push/send';
  -- Cinco intentos a 15 segundos cubren un corte de red de un minuto largo.
  -- Más allá, lo que falla no es la red: es que algo está mal y hay que verlo.
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
    -- Falló la red. El lote se queda en `pending` con un intento más gastado:
    -- lo reintenta el cron dentro de 15 segundos.
    return jsonb_build_object(
      'ok', false, 'claimed', array_length(v_ids, 1), 'error', left(sqlerrm, 300)
    );
  end;

  if v_status is distinct from 200 then
    -- 429 y 5xx son "vuelve luego": se dejan en cola. Un 4xx es culpa nuestra
    -- —mensaje mal formado, token de acceso inválido— y reintentarlo cinco
    -- veces solo retrasa el momento de enterarse.
    if v_status in (429, 500, 502, 503, 504) then
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
-- 3. La pasada: lote tras lote, cada uno confirmado por separado
-- ---------------------------------------------------------------------------
create or replace procedure public.dispatch_push_queue_loop(p_budget interval default interval '10 seconds')
language plpgsql
as $$
declare
  v_started timestamptz := clock_timestamp();
  v_result  jsonb;
begin
  loop
    v_result := public.dispatch_push_queue(100);
    -- Lo mandado queda escrito antes de pedir el siguiente lote.
    commit;

    exit when not coalesce((v_result ->> 'ok')::boolean, false)
           or coalesce((v_result ->> 'claimed')::int, 0) < 100
           or clock_timestamp() - v_started >= p_budget;
  end loop;
end;
$$;

revoke all on procedure public.dispatch_push_queue_loop(interval) from public, anon, authenticated;

-- El mismo trabajo, el mismo ritmo; ahora cada tic es una pasada entera.
-- pg_cron no arranca un tic mientras el anterior sigue corriendo.
select cron.alter_job(
  job_id  := (select jobid from cron.job where jobname = 'helios_push_dispatch'),
  command := 'call public.dispatch_push_queue_loop()'
);
