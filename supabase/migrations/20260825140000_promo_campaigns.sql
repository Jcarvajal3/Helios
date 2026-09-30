-- ============================================================================
-- Ronda — Promociones desde el super admin
--
-- Mandar un push a todo el mundo es la acción de mayor alcance que existe en
-- el panel: llega a la pantalla de bloqueo de cada usuario, no se puede
-- deshacer y no hay "reenviar corregido". Este archivo la construye tratándola
-- como lo que es — una operación de riesgo, no un formulario de contacto.
--
-- ---------------------------------------------------------------------------
-- 1. La promoción es un AVISO, no un push suelto
-- ---------------------------------------------------------------------------
-- Se escribe en `public.notifications` como cualquier otro, y de ahí el
-- transporte ya construido (`20260825100000`) la encola y la despacha. Tres
-- consecuencias, las tres buenas:
--
--   · Quien tenga los avisos apagados la ve igual al abrir la app.
--   · Se puede medir: cuántas salieron, cuántas llegaron, cuántas fallaron.
--   · No hay un segundo camino de envío que mantener.
--
-- ---------------------------------------------------------------------------
-- 2. Una sola definición de "a quién"
-- ---------------------------------------------------------------------------
-- El público lo calcula `promo_audience()`, y la usan **tanto la vista previa
-- como el envío**. Es la única forma de que el número que el panel enseña
-- antes de mandar sea el mismo que se manda. Dos consultas parecidas en dos
-- sitios es exactamente cómo se acaba avisando a 900 personas después de leer
-- "esto llega a 300".
--
-- ---------------------------------------------------------------------------
-- 3. Canal propio
-- ---------------------------------------------------------------------------
-- La publicidad va por `promociones`, separada de `grupos`, `cuotas` y
-- `cuenta`. Quien se harte de las promos las apaga desde los ajustes de
-- Android sin perder el aviso de que le acaban de cargar una cuenta ajena.
-- Meterlas en un canal compartido haría que la primera promo pesada apagara
-- de paso el control antiabuso de docs/05 §2.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las campañas
-- ---------------------------------------------------------------------------

create table if not exists public.promo_campaigns (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  body        text not null,
  audience    text not null,
  level       integer,
  -- A dónde lleva al tocarla. Null = a Inicio.
  href        text,
  -- Cuántos avisos se escribieron y a cuántos dispositivos salió. Se guardan
  -- en el momento del envío porque son la foto de ese instante: mañana habrá
  -- más usuarios y menos teléfonos con la app.
  recipients  integer not null default 0,
  devices     integer not null default 0,
  sent_by     uuid not null references auth.users (id),
  created_at  timestamptz not null default now()
);

comment on table public.promo_campaigns is
  'Envíos promocionales del super admin. Una fila por envío, con la foto de su alcance.';

create index if not exists promo_campaigns_recent_idx
  on public.promo_campaigns (created_at desc);

alter table public.promo_campaigns enable row level security;
-- Sin políticas: se lee por admin_promo_history(), que comprueba el rol.

-- El aviso sabe de qué campaña vino. Sirve para medir cada envío sin tener que
-- adivinar por el texto, que es lo único que había antes.
alter table public.notifications
  add column if not exists campaign_id uuid references public.promo_campaigns (id) on delete set null;

create index if not exists notifications_campaign_idx
  on public.notifications (campaign_id) where campaign_id is not null;

-- ---------------------------------------------------------------------------
-- 2. El público
-- ---------------------------------------------------------------------------

/**
 * Quién entra en una promoción.
 *
 * `expelled` queda fuera SIEMPRE: es una cuenta cerrada por más de 30 días de
 * mora, y mandarle publicidad a quien acabamos de echar es la clase de detalle
 * que termina en captura de pantalla.
 *
 * Los cuatro públicos:
 *
 *   all      todo el que tenga cuenta viva, incluidos los que están al día
 *            con la cuota vencida (`frozen`) — a ese le interesa saber que hay
 *            una promo tanto como al resto.
 *   active   solo cuentas operativas. El público conservador.
 *   level    un nivel concreto, para premiar o para empujar al siguiente.
 *   dormant  activos que llevan 30 días sin consumir. El de reactivación, que
 *            es el que de verdad justifica tener esto.
 */
create or replace function public.promo_audience(
  p_audience text,
  p_level    integer default null
)
returns table (user_id uuid)
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select p.id
  from public.profiles p
  where p.status <> 'expelled'
    and case p_audience
      when 'all'    then true
      when 'active' then p.status = 'active'
      when 'level'  then p.level = p_level
      when 'dormant' then
        p.status = 'active'
        and not exists (
          select 1 from public.charges c
          where c.user_id = p.id
            and c.status = 'confirmed'
            and c.confirmed_at > now() - interval '30 days'
        )
      else false
    end;
$fn$;

comment on function public.promo_audience(text, integer) is
  'Los destinatarios de una promoción. La misma que usa la vista previa y el envío.';

revoke all on function public.promo_audience(text, integer) from public, anon, authenticated;

/** Cuánta gente y cuántos teléfonos. Lo que el panel enseña ANTES de mandar. */
create or replace function public.admin_promo_preview(
  p_audience text,
  p_level    integer default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo para el equipo de Helios' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'audience', p_audience,
    'level', p_level,
    'people', (select count(*) from public.promo_audience(p_audience, p_level)),
    -- Los demás la verán al abrir la app, no en el teléfono. Enseñar los dos
    -- números evita la conclusión equivocada de que "no llegó a nadie".
    'devices', (
      select count(*)
      from public.promo_audience(p_audience, p_level) a
      join public.push_tokens t on t.user_id = a.user_id and t.disabled_at is null
    )
  );
end;
$fn$;

revoke all on function public.admin_promo_preview(text, integer) from public, anon;
grant execute on function public.admin_promo_preview(text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El envío
-- ---------------------------------------------------------------------------

/**
 * Manda una promoción. **Solo super admin.**
 *
 * No es que un operador no sea de fiar: es que esta acción no se puede
 * deshacer y llega a todo el mundo a la vez. Conciliar un pago se corrige;
 * un push mal escrito en 4.000 teléfonos, no.
 *
 * `p_href` se valida contra una lista blanca. Es la única parte de todo esto
 * que acaba dentro de un `router.push()` del teléfono, y una ruta que venga
 * escrita a mano desde un formulario no puede mandar a la app a donde sea.
 */
create or replace function public.admin_send_promo(
  p_title    text,
  p_body     text,
  p_audience text,
  p_level    integer default null,
  p_href     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor    uuid := auth.uid();
  v_title    text := trim(coalesce(p_title, ''));
  v_body     text := trim(coalesce(p_body, ''));
  v_campaign public.promo_campaigns%rowtype;
  v_people   integer;
  v_devices  integer;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede mandar promociones'
      using errcode = '42501';
  end if;

  -- Los límites son de la bandeja del sistema, no nuestros: Android corta el
  -- título sobre los 65 caracteres y el cuerpo sobre los 240 cuando el aviso
  -- está plegado. Dejar escribir más es dejar mandar una frase que nadie va a
  -- leer entera.
  if length(v_title) = 0 or length(v_title) > 65 then
    raise exception 'El título va entre 1 y 65 caracteres' using errcode = '22023';
  end if;

  if length(v_body) = 0 or length(v_body) > 240 then
    raise exception 'El texto va entre 1 y 240 caracteres' using errcode = '22023';
  end if;

  if p_audience not in ('all', 'active', 'level', 'dormant') then
    raise exception 'Público desconocido: %', p_audience using errcode = '22023';
  end if;

  if p_audience = 'level' and (p_level is null or p_level not between 1 and 5) then
    raise exception 'Ese público necesita un nivel del 1 al 5' using errcode = '22023';
  end if;

  if p_href is not null and p_href not in (
    '/(app)', '/(app)/buscar', '/(app)/grupos', '/(app)/pagos', '/(app)/niveles'
  ) then
    raise exception 'Destino no permitido: %', p_href using errcode = '22023';
  end if;

  -- El doble clic del que manda. Sin esto, dos toques seguidos son dos avisos
  -- idénticos en la pantalla de todo el mundo, y el segundo ya no se puede
  -- recoger.
  if exists (
    select 1 from public.promo_campaigns
    where title = v_title and body = v_body
      and created_at > now() - interval '10 minutes'
  ) then
    raise exception 'Esa misma promoción se mandó hace menos de 10 minutos'
      using errcode = '23505';
  end if;

  insert into public.promo_campaigns (title, body, audience, level, href, sent_by)
  values (v_title, v_body, p_audience, p_level, p_href, v_actor)
  returning * into v_campaign;

  -- Un solo INSERT para todos: el trigger de push se dispara fila a fila y
  -- deja la cola lista. Nada sale a la red desde aquí — el envío real lo hace
  -- el cron unos segundos después, así que el panel no se queda colgado
  -- esperando a Expo con 4.000 mensajes por delante.
  with nuevos as (
    insert into public.notifications (user_id, type, title, body, data, campaign_id)
    select a.user_id, 'promo', v_title, v_body,
           jsonb_strip_nulls(jsonb_build_object('campaign_id', v_campaign.id, 'href', p_href)),
           v_campaign.id
    from public.promo_audience(p_audience, p_level) a
    returning 1
  )
  select count(*) into v_people from nuevos;

  select count(*) into v_devices
  from public.push_deliveries d
  join public.notifications n on n.id = d.notification_id
  where n.campaign_id = v_campaign.id;

  update public.promo_campaigns
     set recipients = v_people, devices = v_devices
   where id = v_campaign.id;

  perform audit.log(v_actor, 'promo.send', v_campaign.id,
    jsonb_build_object('title', v_title, 'audience', p_audience,
                       'level', p_level, 'people', v_people, 'devices', v_devices));

  return jsonb_build_object(
    'campaign_id', v_campaign.id,
    'people', v_people,
    'devices', v_devices
  );
end;
$fn$;

comment on function public.admin_send_promo(text, text, text, integer, text) is
  'Manda una promoción a un público. Solo super admin; queda en la bitácora.';

revoke all on function public.admin_send_promo(text, text, text, integer, text)
  from public, anon;
grant execute on function public.admin_send_promo(text, text, text, integer, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Qué pasó con lo mandado
-- ---------------------------------------------------------------------------
-- Sin esto, "mandé la promo" y "la promo llegó" son la misma frase. Y no lo
-- son: entre las dos están los teléfonos sin la app, los avisos apagados y
-- los tokens muertos.

create or replace function public.admin_promo_history(p_limit integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo para el equipo de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc), '[]'::jsonb)
    into v_rows
  from (
    select c.id, c.title, c.body, c.audience, c.level, c.href,
           c.recipients, c.devices, c.created_at,
           coalesce(a.full_name, 'Desconocido') as sent_by,
           (select count(*) from public.notifications n
             where n.campaign_id = c.id and n.read_at is not null) as opened,
           (select count(*) from public.push_deliveries d
              join public.notifications n on n.id = d.notification_id
             where n.campaign_id = c.id and d.status = 'delivered') as delivered,
           (select count(*) from public.push_deliveries d
              join public.notifications n on n.id = d.notification_id
             where n.campaign_id = c.id and d.status = 'failed') as failed
    from public.promo_campaigns c
    left join public.platform_admins a on a.user_id = c.sent_by
    order by c.created_at desc
    limit greatest(coalesce(p_limit, 30), 1)
  ) q;

  return v_rows;
end;
$fn$;

revoke all on function public.admin_promo_history(integer) from public, anon;
grant execute on function public.admin_promo_history(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. El sobre, con el canal nuevo
-- ---------------------------------------------------------------------------
-- Igual que en `20260825100000` más la línea de 'promo'. La prioridad es
-- 'normal' y no se discute: una promoción no enciende la pantalla de nadie.

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
    'data',  coalesce(p_data, '{}'::jsonb)
             || jsonb_build_object('type', p_type::text, 'notification_id', p_notification_id),
    'sound', case when p_type::text = 'promo' then null else 'default' end,
    'channelId', case p_type::text
                   when 'group_charge'        then 'grupos'
                   when 'group_released'      then 'grupos'
                   when 'payment_reconciled'  then 'cuotas'
                   when 'payment_rejected'    then 'cuotas'
                   when 'installment_due'     then 'cuotas'
                   when 'promo'               then 'promociones'
                   else 'cuenta'
                 end,
    'priority', case p_type::text
                  when 'installment_due' then 'normal'
                  when 'promo'           then 'normal'
                  else 'high'
                end,
    'ttl', 86400
  );
$fn$;

revoke all on function public.push_envelope(text, public.notification_type, text, text, jsonb, uuid)
  from public, anon, authenticated;
