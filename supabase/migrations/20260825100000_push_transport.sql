-- ============================================================================
-- Ronda — Transporte push
--
-- `20260822160000_notifications.sql` dejó el CONTENIDO construido —qué se
-- avisa, a quién y con qué texto— y escribió en su cabecera que el transporte
-- iría aparte: "cuando existan las credenciales, un worker lee de esta misma
-- tabla y despacha". Esto es ese worker.
--
-- Cierra el 🔴 de docs/00-BASES §3.13: el aviso del cargo de grupo, que
-- docs/05 §2 llama "el control" frente a la autorización permanente. Un aviso
-- que solo se ve al abrir la app no interrumpe a nadie, y quien acaba de
-- recibir una parte de una cuenta ajena no tiene ningún motivo para abrir
-- Ronda justo en ese momento.
--
-- ---------------------------------------------------------------------------
-- 1. Dentro de Postgres, no en una Edge Function
-- ---------------------------------------------------------------------------
-- Mismo criterio que la ingesta de la tasa (`20260824100000`) y que el resto
-- del cron de dinero (docs/01 §7): la extensión `http` y `pg_cron` ya están
-- aquí, y una función serverless habría metido un runtime más, un secreto de
-- service role fuera de la base y un despliegue aparte.
--
-- El plan que docs/01 §7 dibujaba —`pgmq` + Edge Function— no se sigue: pgmq
-- no se llegó a usar en ninguna parte del proyecto y esta cola es una tabla
-- con cuatro estados. Una tabla se consulta, se corrige a mano y se audita.
--
-- ---------------------------------------------------------------------------
-- 2. Por qué una BANDEJA DE SALIDA y no una llamada desde el trigger
-- ---------------------------------------------------------------------------
-- Los avisos nacen dentro de transacciones de dinero: confirmar un consumo,
-- conciliar un pago, el barrido de mora. Llamar a `http` ahí dentro pondría a
-- una venta a esperar a que un servidor de Expo conteste —y a fallar si no
-- contesta—. El camino del dinero no puede depender de la red de nadie.
--
-- Así que el trigger solo ESCRIBE una fila por dispositivo (barato,
-- transaccional) y el cron despacha unos segundos después. Si Expo está caído,
-- lo que queda es un aviso sin entregar, no una compra perdida.
--
-- ---------------------------------------------------------------------------
-- 3. Expo y no FCM directamente
-- ---------------------------------------------------------------------------
-- La app es Expo y el token que da el teléfono es un `ExponentPushToken`.
-- Hablar con FCM directamente exigiría firmar un JWT de cuenta de servicio
-- dentro de Postgres (RS256, rotación de clave incluida); Expo pide una
-- cabecera opcional y un POST con JSON. Las credenciales de FCM siguen
-- haciendo falta, pero viven en EAS, que es donde ya vive todo lo demás de la
-- build.
--
-- ⚠️ Nada de esto entrega un solo aviso hasta que el proyecto tenga subida la
-- clave de cuenta de servicio de FCM V1 y salga una build nueva con
-- `expo-notifications`. Hasta entonces la cola no tiene tokens a los que
-- escribir, y todo lo demás sigue funcionando exactamente igual que hoy.
-- ============================================================================

create extension if not exists http    with schema extensions;
create extension if not exists pg_cron with schema extensions;

-- ---------------------------------------------------------------------------
-- 1. Los tokens
-- ---------------------------------------------------------------------------
-- Un token es de un DISPOSITIVO, no de una persona: identifica la instalación
-- de la app en ese teléfono. Por eso la clave primaria es el token y no el par
-- (usuario, dispositivo) — si el teléfono cambia de dueño, la fila cambia de
-- `user_id` y no se duplica. Ver `register_push_token`, que es donde ese caso
-- se trata con el cuidado que merece en una app de dinero.

create table if not exists public.push_tokens (
  token           text primary key,
  user_id         uuid not null references auth.users (id) on delete cascade,
  -- El mismo hash que `register_device`, para poder cruzar un token con el
  -- aparato que el usuario ve en Perfil → Seguridad.
  device_hash     text,
  platform        text not null default 'android'
                  check (platform in ('android', 'ios', 'web')),
  created_at      timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),
  -- Un token deja de servir por tres motivos: el usuario cerró sesión,
  -- desinstaló la app (Expo lo dice con `DeviceNotRegistered`) o el sistema se
  -- lo cambió. No se borra: saber que un teléfono dejó de recibir avisos es
  -- parte de entender por qué alguien "no se enteró".
  disabled_at     timestamptz,
  disabled_reason text
);

comment on table public.push_tokens is
  'Tokens de Expo por dispositivo. Los escribe la app con register_push_token().';

create index if not exists push_tokens_active_idx
  on public.push_tokens (user_id) where disabled_at is null;

alter table public.push_tokens enable row level security;
-- Sin políticas: la app entra por las dos RPC de abajo. Un token es la
-- dirección postal de un teléfono; que un cliente pudiera listarlos o escribir
-- el de otro sería regalar el buzón.

-- ---------------------------------------------------------------------------
-- 2. La bandeja de salida
-- ---------------------------------------------------------------------------

do $enum$
begin
  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'push_status' and n.nspname = 'public'
  ) then
    create type public.push_status as enum (
      'pending',    -- en cola
      'sent',       -- Expo lo aceptó y dio un ticket
      'delivered',  -- el acuse dice que llegó al dispositivo
      'failed'
    );
  end if;
end;
$enum$;

create table if not exists public.push_deliveries (
  id              bigint generated always as identity primary key,
  notification_id uuid not null references public.notifications (id) on delete cascade,
  token           text not null references public.push_tokens (token) on delete cascade,
  status          public.push_status not null default 'pending',
  attempts        integer not null default 0,
  -- El identificador que devuelve Expo al aceptar el mensaje. Con él se pide
  -- el acuse 15 minutos después: aceptar no es entregar.
  ticket_id       text,
  error           text,
  created_at      timestamptz not null default now(),
  sent_at         timestamptz,
  -- Cuándo dejó de estar en juego, se supiera el desenlace o no. Sin esta
  -- marca, un envío sin acuse se volvería a pedir para siempre.
  settled_at      timestamptz,
  unique (notification_id, token)
);

comment on table public.push_deliveries is
  'Cola de envíos push, una fila por aviso y dispositivo. La drena dispatch_push_queue().';

create index if not exists push_deliveries_pending_idx
  on public.push_deliveries (id) where status = 'pending';

create index if not exists push_deliveries_receipts_idx
  on public.push_deliveries (sent_at) where status = 'sent' and settled_at is null;

alter table public.push_deliveries enable row level security;
-- Sin políticas: es cocina del servidor.

-- ---------------------------------------------------------------------------
-- 3. Alta y baja de un token
-- ---------------------------------------------------------------------------

/**
 * Registra el token de este dispositivo para el usuario autenticado.
 *
 * Idempotente: la app la llama en cada arranque, porque el sistema puede rotar
 * el token cuando le parezca y un token muerto no avisa de que lo está.
 */
create or replace function public.register_push_token(
  p_token       text,
  p_device_hash text default null,
  p_platform    text default 'android'
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_user  uuid := auth.uid();
  v_owner uuid;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- Forma exacta de un token de Expo. No es paranoia de más: lo que entre aquí
  -- se manda tal cual a un servidor ajeno, y un campo de texto libre que el
  -- servidor reenvía es justo por donde se cuelan las sorpresas.
  if p_token is null or p_token !~ '^Expo(nent)?PushToken\[[A-Za-z0-9_\-]+\]$' then
    raise exception 'Token push no válido' using errcode = '22023';
  end if;

  select user_id into v_owner from public.push_tokens where token = p_token;

  -- El teléfono cambió de manos —o alguien prestó el suyo para que otro
  -- entrara—. Lo que quedara en cola para el dueño anterior NO puede salir a
  -- esta pantalla: son cifras, nombres y cuentas de otra persona.
  if v_owner is not null and v_owner <> v_user then
    update public.push_deliveries
       set status = 'failed',
           error = 'El dispositivo cambió de usuario',
           settled_at = now()
     where token = p_token and status = 'pending';
  end if;

  insert into public.push_tokens as t (token, user_id, device_hash, platform)
  values (p_token, v_user, p_device_hash, coalesce(p_platform, 'android'))
  on conflict (token) do update
    set user_id         = excluded.user_id,
        device_hash     = coalesce(excluded.device_hash, t.device_hash),
        platform        = excluded.platform,
        last_seen_at    = now(),
        -- Volver a registrarlo lo resucita: si se desactivó por un
        -- `DeviceNotRegistered` de hace un mes y hoy el teléfono lo vuelve a
        -- pedir, es que la app está instalada otra vez.
        disabled_at     = null,
        disabled_reason = null;
end;
$fn$;

comment on function public.register_push_token(text, text, text) is
  'Alta idempotente del token de Expo del dispositivo actual.';

revoke all on function public.register_push_token(text, text, text) from public, anon;
grant execute on function public.register_push_token(text, text, text) to authenticated;

/** Baja del token al cerrar sesión. La app la llama ANTES del signOut. */
create or replace function public.disable_push_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  update public.push_tokens
     set disabled_at = now(), disabled_reason = 'Sesión cerrada'
   where token = p_token and user_id = v_user;

  -- Lo que siguiera en cola muere con la sesión: quien cierra sesión en un
  -- teléfono prestado no quiere que a los diez segundos aparezca ahí su cuota.
  update public.push_deliveries d
     set status = 'failed', error = 'Sesión cerrada', settled_at = now()
    from public.push_tokens t
   where t.token = d.token
     and d.token = p_token
     and t.user_id = v_user
     and d.status = 'pending';
end;
$fn$;

comment on function public.disable_push_token(text) is
  'Baja del token al cerrar sesión, y cancela lo que tuviera en cola.';

revoke all on function public.disable_push_token(text) from public, anon;
grant execute on function public.disable_push_token(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. El sobre
-- ---------------------------------------------------------------------------
-- Aparte de la función que despacha para poder mirarlo sin salir a la red, que
-- es donde se ve si un aviso va por el canal que le toca.
--
-- Los CANALES de Android son además la respuesta al ⬜ de docs/00 §3.13
-- ("¿puede el usuario desactivar notificaciones?"): el sistema deja apagar
-- cada canal por separado desde los ajustes del teléfono, con la granularidad
-- ya hecha y sin pantalla propia que mantener. Por eso son tres y no uno —
-- alguien puede querer silenciar los recordatorios de cuota y seguir
-- enterándose de que le acaban de cargar una cuenta de grupo.
--
-- El `case` va sobre el TEXTO del enum a propósito: un tipo de aviso nuevo no
-- puede hacer fallar el despacho de todos los demás. Cae en 'cuenta'.

create or replace function public.push_envelope(
  p_token           text,
  p_type            public.notification_type,
  p_title           text,
  p_body            text,
  p_data            jsonb,
  p_notification_id uuid
)
returns jsonb
language sql
immutable
set search_path = public, pg_temp
as $fn$
  select jsonb_build_object(
    'to',    p_token,
    'title', p_title,
    'body',  p_body,
    -- El tipo y el id viajan dentro para que, al tocar el aviso, la app sepa a
    -- qué pantalla ir sin volver a preguntar al servidor.
    'data',  coalesce(p_data, '{}'::jsonb)
             || jsonb_build_object('type', p_type::text, 'notification_id', p_notification_id),
    'sound', 'default',
    'channelId', case p_type::text
                   when 'group_charge'        then 'grupos'
                   when 'group_released'      then 'grupos'
                   when 'payment_reconciled'  then 'cuotas'
                   when 'payment_rejected'    then 'cuotas'
                   when 'installment_due'     then 'cuotas'
                   else 'cuenta'
                 end,
    -- 'high' despierta la pantalla; 'normal' espera a que el teléfono salga de
    -- reposo. El recordatorio de cuota a dos días es lo único que puede
    -- esperar: todo lo demás informa de algo que acaba de pasar con el dinero
    -- de quien lo recibe.
    'priority', case p_type::text
                  when 'installment_due' then 'normal'
                  else 'high'
                end,
    -- Un día. Pasado ese tiempo el aviso ya no informa de nada que el usuario
    -- no haya visto por su cuenta al abrir la app, y llegar tarde confunde.
    'ttl', 86400
  );
$fn$;

comment on function public.push_envelope(text, public.notification_type, text, text, jsonb, uuid) is
  'Mensaje para la API de Expo a partir de un aviso. Decide canal y prioridad.';

revoke all on function public.push_envelope(text, public.notification_type, text, text, jsonb, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Encolar
-- ---------------------------------------------------------------------------
-- Una fila por dispositivo activo. Si el usuario no tiene ninguno —no dio
-- permiso, o todavía no hay build con push— no se encola nada y el aviso vive
-- solo en la bandeja de la app, exactamente como hasta hoy.

create or replace function public.enqueue_push()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  insert into public.push_deliveries (notification_id, token)
  select new.id, t.token
  from public.push_tokens t
  where t.user_id = new.user_id
    and t.disabled_at is null
  on conflict (notification_id, token) do nothing;

  return null;
end;
$fn$;

revoke all on function public.enqueue_push() from public, anon, authenticated;

drop trigger if exists notifications_enqueue_push on public.notifications;
create trigger notifications_enqueue_push
  after insert on public.notifications
  for each row execute function public.enqueue_push();

-- ---------------------------------------------------------------------------
-- 6. Despachar
-- ---------------------------------------------------------------------------
-- Un lote de 100 —el máximo que acepta Expo en una petición— cada 15 segundos.
-- Da 400 avisos por minuto, muy por debajo del límite del servicio (600 por
-- segundo) y de sobra para el pico real: una mesa de ocho son siete avisos.
--
-- El token de acceso de Expo es OPCIONAL y vive en Vault, igual que el pepper
-- del PIN. Solo hace falta si en el panel de Expo se activa "push security";
-- sin él, la API acepta igual los envíos de este proyecto.
--
--   select vault.create_secret('<token>', 'expo_access_token', 'Push de Expo');

create or replace function public.dispatch_push_queue(p_batch integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
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

  -- Reclamar el lote. `skip locked` para que dos ejecuciones solapadas —el
  -- cron y una llamada a mano— no manden el mismo aviso dos veces.
  with claimed as (
    select d.id
    from public.push_deliveries d
    join public.push_tokens t on t.token = d.token
    where d.status = 'pending'
      and t.disabled_at is null
    order by d.id
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
$fn$;

comment on function public.dispatch_push_queue(integer) is
  'Manda a Expo un lote de la cola de push. La llama el cron cada pocos segundos.';

revoke all on function public.dispatch_push_queue(integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Acuses
-- ---------------------------------------------------------------------------
-- Que Expo acepte un mensaje no quiere decir que llegara: el ticket solo dice
-- "lo tengo". El desenlace real está en el acuse, que la propia documentación
-- pide consultar unos 15 minutos después y que caduca a las 24 horas.
--
-- Sin este paso, un token muerto que falla en FCM —y no en Expo— se quedaría
-- activo para siempre, y "no me llegó nada" no tendría dónde comprobarse.

create or replace function public.check_push_receipts()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  c_endpoint constant text := 'https://exp.host/--/api/v2/push/getReceipts';
  v_secret   text;
  v_headers  extensions.http_header[];
  v_tickets  text[];
  v_status   integer;
  v_body     text;
  v_response jsonb;
  v_settled  integer := 0;
  v_expired  integer;
begin
  -- Lo que lleva más de un día sin acuse ya no lo va a tener: Expo los borra.
  -- Se cierra sin mentir —no se marca 'delivered'— y se anota por qué.
  update public.push_deliveries
     set settled_at = now(),
         error = coalesce(error, 'Expo ya no guardaba el acuse (24 h)')
   where status = 'sent' and settled_at is null
     and sent_at < now() - interval '24 hours';
  get diagnostics v_expired = row_count;

  select array_agg(ticket_id) into v_tickets
  from (
    select ticket_id
    from public.push_deliveries
    where status = 'sent' and settled_at is null and ticket_id is not null
      and sent_at < now() - interval '15 minutes'
    order by sent_at
    limit 1000
  ) q;

  if v_tickets is null then
    return jsonb_build_object('ok', true, 'checked', 0, 'expired', v_expired);
  end if;

  begin
    select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'expo_access_token' limit 1;
  exception when others then
    v_secret := null;
  end;

  v_headers := array[
    extensions.http_header('Accept', 'application/json'),
    extensions.http_header('Accept-Encoding', 'identity')
  ];
  if v_secret is not null then
    v_headers := v_headers || extensions.http_header('Authorization', 'Bearer ' || v_secret);
  end if;

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
      jsonb_build_object('ids', to_jsonb(v_tickets))::text
    )::extensions.http_request) as r;
  exception when others then
    return jsonb_build_object('ok', false, 'checked', 0, 'expired', v_expired,
                              'error', left(sqlerrm, 300));
  end;

  if v_status is distinct from 200 then
    return jsonb_build_object('ok', false, 'checked', 0, 'expired', v_expired,
                              'http_status', v_status);
  end if;

  begin
    v_response := v_body::jsonb;
  exception when others then
    return jsonb_build_object('ok', false, 'checked', 0, 'expired', v_expired,
                              'error', 'Respuesta de Expo ilegible');
  end;

  -- Los acuses vienen como objeto, con el ticket de clave. Los que todavía no
  -- están listos simplemente no aparecen: se vuelven a pedir en el siguiente
  -- barrido.
  update public.push_deliveries d
     set status     = case when r.value ->> 'status' = 'ok' then 'delivered' else 'failed' end::public.push_status,
         error      = case
                        when r.value ->> 'status' = 'ok' then null
                        else left(concat_ws(': ', r.value #>> '{details,error}',
                                                  r.value ->> 'message'), 300)
                      end,
         settled_at = now()
    from jsonb_each(v_response -> 'data') as r
   where d.ticket_id = r.key
     and d.status = 'sent';
  get diagnostics v_settled = row_count;

  update public.push_tokens t
     set disabled_at = now(), disabled_reason = 'DeviceNotRegistered'
   where t.disabled_at is null
     and t.token in (
       select d.token from public.push_deliveries d
       where d.ticket_id = any(v_tickets)
         and d.status = 'failed'
         and d.error like 'DeviceNotRegistered%'
     );

  return jsonb_build_object(
    'ok', true, 'checked', array_length(v_tickets, 1),
    'settled', v_settled, 'expired', v_expired
  );
end;
$fn$;

comment on function public.check_push_receipts() is
  'Pide a Expo el acuse de lo enviado hace más de 15 minutos y cierra la cola.';

revoke all on function public.check_push_receipts() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. Limpieza
-- ---------------------------------------------------------------------------
-- La cola no es un historial: lo que hay que poder consultar es el AVISO, y
-- ese vive en `notifications`. Aquí solo se guarda lo justo para depurar una
-- entrega reciente.

create or replace function public.purge_push_queue()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_count integer;
begin
  delete from public.push_deliveries
   where settled_at is not null and settled_at < now() - interval '30 days';
  get diagnostics v_count = row_count;

  -- Un token desactivado hace tres meses no se va a resucitar: si la app
  -- vuelve, trae token nuevo y `register_push_token` lo da de alta.
  delete from public.push_tokens
   where disabled_at is not null and disabled_at < now() - interval '90 days';

  return v_count;
end;
$fn$;

revoke all on function public.purge_push_queue() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 9. Salud, para el panel
-- ---------------------------------------------------------------------------
-- "No me llegó nada" es la queja que va a llegar, y sin esto la única
-- respuesta posible es un encogimiento de hombros.

create or replace function public.push_health()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $fn$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo para administradores' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'tokens_active',   (select count(*) from public.push_tokens where disabled_at is null),
    'tokens_disabled', (select count(*) from public.push_tokens where disabled_at is not null),
    'queue', (
      select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
      from (
        select status::text as status, count(*) as n
        from public.push_deliveries
        where created_at > now() - interval '7 days'
        group by status
      ) q
    ),
    'last_errors', (
      select coalesce(jsonb_agg(jsonb_build_object('error', error, 'at', settled_at)
                                order by settled_at desc), '[]'::jsonb)
      from (
        select error, settled_at from public.push_deliveries
        where status = 'failed' and error is not null
        order by settled_at desc limit 10
      ) e
    )
  );
end;
$fn$;

comment on function public.push_health() is
  'Estado del transporte push para el super admin: tokens, cola y últimos errores.';

revoke all on function public.push_health() from public, anon;
grant execute on function public.push_health() to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Cron
-- ---------------------------------------------------------------------------
-- Cada 15 segundos, no cada minuto: el cargo de grupo llega mientras el cajero
-- todavía tiene la cuenta delante, y el minuto entero de espera se nota justo
-- en el aviso que más importa. pg_cron acepta intervalos por debajo del minuto
-- desde la 1.5; si esta base fuera más vieja, se cae al minuto y sigue
-- funcionando igual.

do $cron$
begin
  begin
    perform cron.unschedule('helios_push_dispatch');
  exception when others then
    null;
  end;

  begin
    perform cron.schedule('helios_push_dispatch', '15 seconds',
                          $c$ select public.dispatch_push_queue(); $c$);
  exception when others then
    perform cron.schedule('helios_push_dispatch', '* * * * *',
                          $c$ select public.dispatch_push_queue(); $c$);
  end;
end;
$cron$;

select cron.schedule(
  'helios_push_receipts',
  '*/15 * * * *',
  $cron$ select public.check_push_receipts(); $cron$
);

-- 10:20 AM Caracas, detrás del resto del barrido diario.
select cron.schedule(
  'helios_push_purge',
  '20 14 * * *',
  $cron$ select public.purge_push_queue(); $cron$
);
