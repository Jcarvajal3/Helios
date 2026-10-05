-- ============================================================================
-- Helios — El WhatsApp sale por la API (docs/00 §15.2, docs/01 §4.1 y §5.3)
--
-- El TRANSPORTE del canal `whatsapp` de `outbound_messages`, con el mismo
-- patrón que el correo (20261004000100): `pg_cron` + la extensión `http`,
-- dentro de la base, sin runtime aparte. El proveedor es 360dialog (la Cloud
-- API de Meta detrás de un proxy), con un solo número en coexistencia.
--
-- 1. Las claves, de Vault: `d360_api_key` y `d360_base_url`
--    (sandbox: https://waba-sandbox.360dialog.io/v1; producción:
--    https://waba-v2.360dialog.io). Nunca en una tabla legible.
-- 2. `helios_d360_request(...)`: la ÚNICA función que sale a la red. Una
--    suite la sustituye dentro de su transacción y prueba el despacho sin
--    mandar un solo WhatsApp de verdad.
-- 3. `whatsapp_contacts`: cuándo escribió cada número por última vez. Decide
--    la ventana de 24 h de Meta:
--      · dentro → el texto completo (`rendered_text`), o con botones de
--        respuesta si la plantilla los tiene (la pregunta al paciente);
--      · fuera → la plantilla aprobada en Meta, con sus variables;
--      · fuera y sin plantilla aprobada → a la cola manual («Avisos de hoy»).
-- 4. Al encolar, cada mensaje `whatsapp` guarda su plantilla de Meta ya
--    resuelta (`wa_template`: nombre, idioma, variables y botones), igual que
--    guarda el texto: es lo que se mandó.
-- 5. `helios_dispatch_whatsapp_batch(p_limit)`: cada 10 segundos (el paciente
--    está en el consultorio esperando la pregunta). 2xx → `enviado` con el id
--    de WhatsApp en `provider_id`. 401/403 → la configuración está mal: espera
--    15 minutos sin gastar intento y corta el lote. 429/5xx/sin respuesta →
--    reintento con espera creciente. Un teléfono sin WhatsApp → `fallido` (la
--    clínica lo ve). Lo demás que la API no puede mandar pero una persona sí
--    → a la cola manual, con el motivo. Sin claves en Vault no llama a nadie y
--    todo cae a la cola manual.
-- 6. `helios_whatsapp_status(...)`: los estados de entrega que trae el
--    webhook (sent, delivered, read, failed). Solo avanzan; un `failed` gana.
-- 7. `helios_config_status` dice si la API está lista y si es el sandbox.
--
-- Para encender la API (nada de esto lo hace una migración):
--   select vault.create_secret('<clave>', 'd360_api_key', '360dialog');
--   select vault.create_secret('https://waba-sandbox.360dialog.io/v1', 'd360_base_url', '360dialog');
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Lo que se guarda
-- ---------------------------------------------------------------------------

alter table public.notification_templates
  add column wa_buttons jsonb not null default '[]'::jsonb
    check (jsonb_typeof(wa_buttons) = 'array');

comment on column public.notification_templates.wa_buttons is
  'Botones de respuesta rápida, en orden: [{id, title}]. El id admite variables ({charge_id}) y es lo que vuelve en el webhook; el título (máx. 20) es el de la plantilla de Meta.';

update public.notification_templates
   set wa_buttons = jsonb_build_array(
         jsonb_build_object('id', 'confirmar:{charge_id}', 'title', 'Sí, acepto'),
         jsonb_build_object('id', 'rechazar:{charge_id}',  'title', 'No'))
 where key = 'confirmar_financiamiento';

alter table public.outbound_messages
  add column wa_template jsonb;

comment on column public.outbound_messages.wa_template is
  'WhatsApp: la plantilla de Meta ya resuelta al encolar ({name, language, params[], buttons[{id, title}]}), o null si solo puede salir como texto libre.';
comment on column public.outbound_messages.provider_id is
  'Correo: el id de Resend. WhatsApp: el id del mensaje (wamid).';
comment on column public.outbound_messages.last_event is
  'Correo: sent | delivered | delivery_delayed | bounced | complained | opened | clicked (Resend). WhatsApp: sent | delivered | read | failed.';

create index outbound_messages_wa_id_idx on public.outbound_messages (provider_id)
  where channel = 'whatsapp' and provider_id is not null;

create table public.whatsapp_contacts (
  phone_e164      text primary key check (phone_e164 ~ '^\+[0-9]{8,15}$'),
  last_inbound_at timestamptz,
  profile_id      uuid references public.profiles(id),
  staff_user_id   uuid references auth.users(id),
  updated_at      timestamptz not null default now()
);

comment on table public.whatsapp_contacts is
  'Cada número que habla con el WhatsApp de Helios: cuándo escribió por última vez (la ventana de 24 h de Meta). La escribe el webhook.';

alter table public.whatsapp_contacts enable row level security;
revoke all on public.whatsapp_contacts from anon, authenticated;
grant select on public.whatsapp_contacts to authenticated;
create policy whatsapp_contacts_read_admin on public.whatsapp_contacts
  for select to authenticated
  using ((select public.is_platform_admin()));

/** Un teléfono en E.164 (`+584141234567`) a partir de lo que mande WhatsApp (`584141234567`). */
create or replace function public.helios_wa_e164(p_phone text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case when d ~ '^[0-9]{8,15}$' then '+' || d end
  from (select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') as d) x;
$$;

/** ¿Escribió este número en las últimas 24 h? (con 10 minutos de margen). */
create or replace function public.helios_whatsapp_window_open(p_phone text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select c.last_inbound_at > now() - interval '23 hours 50 minutes'
    from public.whatsapp_contacts c
    where c.phone_e164 = public.helios_wa_e164(p_phone)
  ), false);
$$;

revoke all on function public.helios_wa_e164(text)               from public, anon, authenticated;
revoke all on function public.helios_whatsapp_window_open(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Encolar guarda la plantilla de Meta resuelta
-- ---------------------------------------------------------------------------

/**
 * 🔁 Reescrita (20261005000300). Para el canal `whatsapp`, además del texto,
 * guarda en `wa_template` la plantilla de Meta con sus variables y los ids de
 * sus botones ya rellenados. Añade la variable `{charge_id}`. El resto es
 * igual.
 */
create or replace function public.helios_enqueue_message(
  p_template_key text,
  p_profile_id   uuid,
  p_charge_id    uuid,
  p_channel      text,
  p_vars         jsonb default '{}'::jsonb,
  p_due_date     date  default null,
  p_dedupe_key   text  default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tpl       public.notification_templates%rowtype;
  v_p         public.profiles%rowtype;
  v_vars      jsonb;
  v_vars_html jsonb;
  v_subject   text;
  v_text      text;
  v_html      text;
  v_recipient text;
  v_status    text := 'pendiente';
  v_error     text;
  v_id        uuid;
  v_wa        jsonb;
  v_params    jsonb;
  v_buttons   jsonb;
begin
  if p_channel is null or p_channel not in ('email', 'whatsapp_manual', 'whatsapp') then
    raise exception 'Canal no válido: %', coalesce(p_channel, 'null') using errcode = '22023';
  end if;

  if p_dedupe_key is not null then
    select id into v_id from public.outbound_messages where dedupe_key = p_dedupe_key;
    if found then
      return v_id;
    end if;
  end if;

  select * into v_tpl from public.notification_templates where key = p_template_key;
  if not found then
    raise exception 'No existe la plantilla %', p_template_key using errcode = 'P0002';
  end if;

  if not (p_channel = any (v_tpl.channels)) then
    raise exception 'La plantilla % no sale por %', p_template_key, p_channel using errcode = '22023';
  end if;

  select * into v_p from public.profiles where id = p_profile_id;
  if not found then
    raise exception 'Paciente no encontrado' using errcode = 'P0002';
  end if;

  v_vars := public.helios_message_builtins(p_profile_id)
            || case when p_charge_id is not null
                    then jsonb_build_object('charge_id', p_charge_id::text) else '{}'::jsonb end
            || coalesce(p_vars, '{}'::jsonb);

  -- Todas como texto, para `render_notification_text` (->>).
  select coalesce(jsonb_object_agg(k,
           case when k like '%\_html' then v
                else public.helios_html_escape(v) end), '{}'::jsonb)
    into v_vars_html
  from jsonb_each_text(v_vars) as e(k, v);

  v_subject := coalesce(public.render_notification_text(v_tpl.title, v_vars),
                        public.render_notification_text(v_tpl.default_title, v_vars));
  v_text    := coalesce(public.render_notification_text(v_tpl.body, v_vars),
                        public.render_notification_text(v_tpl.default_body, v_vars));

  if v_subject is null or v_text is null then
    raise exception 'Faltan variables para la plantilla %: tiene %, se pasaron %',
      p_template_key,
      array_to_string(public.notification_markers(v_tpl.default_title || ' ' || v_tpl.default_body), ', '),
      (select string_agg(k, ', ') from jsonb_object_keys(v_vars) k)
      using errcode = '22023';
  end if;

  if p_channel = 'email' then
    v_html := coalesce(public.render_notification_text(v_tpl.html, v_vars_html),
                       public.render_notification_text(v_tpl.default_html, v_vars_html));
    if v_html is null and coalesce(v_tpl.html, v_tpl.default_html) is not null then
      raise exception 'Faltan variables para el HTML de la plantilla %', p_template_key
        using errcode = '22023';
    end if;
    v_recipient := v_p.email;
  else
    v_recipient := v_p.phone_e164;
  end if;

  if p_channel = 'whatsapp' then
    -- Las variables de Meta no admiten saltos de línea, tabuladores ni más de
    -- cuatro espacios seguidos: se aplanan.
    select coalesce(jsonb_agg(
             regexp_replace(regexp_replace(coalesce(v_vars ->> k, ''), '[\r\n\t]+', ' ', 'g'), ' {2,}', ' ', 'g')
             order by i), '[]'::jsonb)
      into v_params
    from unnest(v_tpl.wa_template_params) with ordinality as u(k, i);

    if exists (select 1 from unnest(v_tpl.wa_template_params) k where not (v_vars ? k)) then
      raise exception 'Faltan variables para la plantilla de WhatsApp %', p_template_key using errcode = '22023';
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
             'id', public.render_notification_text(b ->> 'id', v_vars),
             'title', left(b ->> 'title', 20)) order by i), '[]'::jsonb)
      into v_buttons
    from jsonb_array_elements(v_tpl.wa_buttons) with ordinality as e(b, i);

    if exists (select 1 from jsonb_array_elements(v_buttons) b where b ->> 'id' is null) then
      raise exception 'Faltan variables para los botones de %', p_template_key using errcode = '22023';
    end if;

    v_wa := jsonb_build_object(
      'name', v_tpl.wa_template_name,
      'language', v_tpl.wa_template_lang,
      'params', v_params,
      'buttons', v_buttons
    );
  end if;

  if not v_tpl.enabled then
    v_status := 'omitido';
    v_error  := 'La plantilla está apagada';
  elsif v_recipient is null then
    v_status := 'omitido';
    v_error  := case when p_channel = 'email' then 'El paciente no tiene correo'
                     else 'El paciente no tiene teléfono' end;
  elsif p_channel = 'email' and v_p.email_invalid_at is not null then
    v_status := 'omitido';
    v_error  := 'El correo del paciente rebotó';
  end if;

  insert into public.outbound_messages (
    channel, template_key, profile_id, charge_id, installment_due_date,
    recipient, subject, rendered_text, html, status, last_error,
    next_attempt_at, dedupe_key, wa_template
  ) values (
    p_channel, p_template_key, p_profile_id, p_charge_id, p_due_date,
    v_recipient, v_subject, v_text, v_html, v_status, v_error,
    case when v_status = 'pendiente' and p_channel in ('email', 'whatsapp') then now() end,
    p_dedupe_key, v_wa
  )
  on conflict (dedupe_key) do nothing
  returning id into v_id;

  if v_id is null then
    -- Otra transacción encoló la misma clave entre la comprobación y el INSERT.
    select id into v_id from public.outbound_messages where dedupe_key = p_dedupe_key;
  end if;

  return v_id;
end;
$$;

revoke all on function public.helios_enqueue_message(text, uuid, uuid, text, jsonb, date, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Las claves y la única salida a la red
-- ---------------------------------------------------------------------------

/** Un secreto de Vault por nombre, o null si no existe (o Vault no se deja leer). */
create or replace function public.helios_vault_secret(p_name text)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v text;
begin
  begin
    select nullif(btrim(decrypted_secret), '') into v
    from vault.decrypted_secrets
    where name = p_name
    limit 1;
  exception when others then
    v := null;
  end;
  return v;
end;
$$;

revoke all on function public.helios_vault_secret(text) from public, anon, authenticated;

/**
 * Una llamada a la API de 360dialog. Devuelve `{status, body}` con el código
 * HTTP y el cuerpo en texto. Si la red falla (timeout, DNS…) LANZA: el
 * llamador lo trata como «sin respuesta» y reintenta.
 *
 * Es la costura de las pruebas: una suite la reemplaza dentro de su
 * transacción por una que no sale a la red.
 */
create or replace function public.helios_d360_request(
  p_method   text,
  p_path     text,
  p_api_key  text,
  p_base_url text,
  p_body     jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_status  integer;
  v_content text;
begin
  if p_api_key is null or p_base_url is null then
    raise exception 'Falta la configuración de 360dialog' using errcode = '22023';
  end if;

  -- Sin tope, un servidor que acepta la conexión y no contesta cuelga el cron.
  begin
    perform extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '4000');
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  exception when others then
    null;
  end;

  select r.status, r.content into v_status, v_content
  from extensions.http((
    upper(p_method),
    rtrim(p_base_url, '/') || p_path,
    array[
      extensions.http_header('D360-API-KEY', p_api_key),
      extensions.http_header('Accept', 'application/json'),
      extensions.http_header('Accept-Encoding', 'identity')
    ],
    case when p_body is not null then 'application/json' end,
    case when p_body is not null then p_body::text end
  )::extensions.http_request) as r;

  return jsonb_build_object('status', v_status, 'body', v_content);
end;
$$;

revoke all on function public.helios_d360_request(text, text, text, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. El cuerpo de cada mensaje
-- ---------------------------------------------------------------------------

/**
 * El cuerpo para POST /messages (formato de la Cloud API) de un mensaje de la
 * cola, o null si la API no lo puede mandar:
 *
 *   · ventana abierta, sin botones → texto (`rendered_text`);
 *   · ventana abierta, con botones → `interactive` de botones (el cuerpo
 *     admite 1024 caracteres; si no cabe, la plantilla);
 *   · ventana cerrada → la plantilla de Meta, si tiene nombre;
 *   · si no → null (a la cola manual).
 */
create or replace function public.helios_whatsapp_payload(p_msg public.outbound_messages)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_to      text := regexp_replace(coalesce(p_msg.recipient, ''), '\D', '', 'g');
  v_wa      jsonb := coalesce(p_msg.wa_template, '{}'::jsonb);
  v_buttons jsonb := coalesce(v_wa -> 'buttons', '[]'::jsonb);
  v_open    boolean := public.helios_whatsapp_window_open(p_msg.recipient);
  v_comp    jsonb;
begin
  if v_open and jsonb_array_length(v_buttons) = 0 then
    return jsonb_build_object(
      'messaging_product', 'whatsapp', 'recipient_type', 'individual', 'to', v_to,
      'type', 'text',
      'text', jsonb_build_object('body', left(p_msg.rendered_text, 4096), 'preview_url', false));
  end if;

  if v_open and length(p_msg.rendered_text) <= 1024 then
    return jsonb_build_object(
      'messaging_product', 'whatsapp', 'recipient_type', 'individual', 'to', v_to,
      'type', 'interactive',
      'interactive', jsonb_build_object(
        'type', 'button',
        'body', jsonb_build_object('text', p_msg.rendered_text),
        'action', jsonb_build_object('buttons', (
          select jsonb_agg(jsonb_build_object(
                   'type', 'reply',
                   'reply', jsonb_build_object('id', b ->> 'id', 'title', b ->> 'title'))
                 order by i)
          from jsonb_array_elements(v_buttons) with ordinality as e(b, i)))));
  end if;

  if nullif(v_wa ->> 'name', '') is null then
    return null;
  end if;

  v_comp := jsonb_build_array(jsonb_build_object(
    'type', 'body',
    'parameters', coalesce((
      select jsonb_agg(jsonb_build_object('type', 'text', 'text', p) order by i)
      from jsonb_array_elements_text(coalesce(v_wa -> 'params', '[]'::jsonb)) with ordinality as e(p, i)
    ), '[]'::jsonb)));

  v_comp := v_comp || coalesce((
    select jsonb_agg(jsonb_build_object(
             'type', 'button', 'sub_type', 'quick_reply', 'index', (i - 1)::text,
             'parameters', jsonb_build_array(jsonb_build_object('type', 'payload', 'payload', b ->> 'id')))
           order by i)
    from jsonb_array_elements(v_buttons) with ordinality as e(b, i)
  ), '[]'::jsonb);

  return jsonb_build_object(
    'messaging_product', 'whatsapp', 'recipient_type', 'individual', 'to', v_to,
    'type', 'template',
    'template', jsonb_build_object(
      'name', v_wa ->> 'name',
      'language', jsonb_build_object('code', coalesce(v_wa ->> 'language', 'es')),
      'components', v_comp));
end;
$$;

revoke all on function public.helios_whatsapp_payload(public.outbound_messages) from public, anon, authenticated;

/** Pasa un mensaje a la cola manual («Avisos de hoy»), con el motivo. */
create or replace function public.helios_whatsapp_to_manual(p_id uuid, p_reason text)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.outbound_messages
     set channel = 'whatsapp_manual', next_attempt_at = null,
         last_error = left('Pasó a la cola manual: ' || p_reason, 300)
   where id = p_id and status = 'pendiente';
$$;

revoke all on function public.helios_whatsapp_to_manual(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. El despacho
-- ---------------------------------------------------------------------------

/**
 * Manda a 360dialog hasta `p_limit` WhatsApp pendientes. La llama el cron
 * cada 10 segundos. Devuelve `{ok, skipped?, claimed, sent, failed, retry,
 * manual}`.
 */
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

    v_status := null;
    v_body   := null;
    v_err    := null;
    v_json   := null;
    v_code   := null;
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
    'retry', v_retry, 'manual', v_manual
  );
end;
$$;

comment on function public.helios_dispatch_whatsapp_batch(integer) is
  'Manda a 360dialog un lote de WhatsApp pendientes de outbound_messages. La llama el cron cada 10 s; sin claves, todo pasa a la cola manual.';

revoke all on function public.helios_dispatch_whatsapp_batch(integer) from public, anon, authenticated;

select cron.schedule('helios_whatsapp_dispatch', '10 seconds',
                     $c$ select public.helios_dispatch_whatsapp_batch(); $c$);

-- ---------------------------------------------------------------------------
-- 6. Los estados de entrega (los trae el webhook)
-- ---------------------------------------------------------------------------

/**
 * Un estado de entrega de WhatsApp (docs/01 §5.2): `sent`, `delivered`,
 * `read` o `failed`. Solo avanza (sent < delivered < read); un `failed` gana
 * y deja el mensaje `fallido` con el motivo. Devuelve si encontró el mensaje.
 * Solo para `service_role`.
 */
create or replace function public.helios_whatsapp_status(
  p_wa_message_id text,
  p_status        text,
  p_error         jsonb default null,
  p_at            timestamptz default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_m     public.outbound_messages%rowtype;
  v_rank  integer;
  v_now   integer;
begin
  select * into v_m from public.outbound_messages
  where provider_id = p_wa_message_id and channel = 'whatsapp'
  for update;
  if not found then
    return false;
  end if;

  if p_status = 'failed' then
    update public.outbound_messages
       set status = 'fallido', last_event = 'failed', last_event_at = coalesce(p_at, now()),
           last_error = left(coalesce(
             format('WhatsApp no lo entregó (%s): %s', p_error ->> 'code',
                    coalesce(p_error ->> 'title', p_error ->> 'message', p_error -> 'error_data' ->> 'details', '')),
             'WhatsApp no lo entregó'), 300)
     where id = v_m.id;
    return true;
  end if;

  v_rank := case p_status when 'sent' then 1 when 'delivered' then 2 when 'read' then 3 end;
  v_now  := case v_m.last_event when 'sent' then 1 when 'delivered' then 2 when 'read' then 3
                                when 'failed' then 9 else 0 end;
  if v_rank is null or v_rank <= v_now then
    return true;
  end if;

  update public.outbound_messages
     set last_event = p_status, last_event_at = coalesce(p_at, now())
   where id = v_m.id;
  return true;
end;
$$;

revoke all on function public.helios_whatsapp_status(text, text, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.helios_whatsapp_status(text, text, jsonb, timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- 7. La configuración
-- ---------------------------------------------------------------------------

/** 🔁 (20261002000600) Añade `whatsapp_api` y `whatsapp_sandbox`. */
create or replace function public.helios_config_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v public.platform_contact%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v from public.platform_contact where id;

  return jsonb_build_object(
    'whatsapp',         v.whatsapp_number is not null,
    'cuentas_de_cobro', (select count(*)::integer from public.payment_destinations where is_active),
    'resend',           exists (select 1 from vault.secrets s where s.name = 'resend_api_key'),
    'remitente',        v.sender_email is not null and v.sender_name is not null,
    'whatsapp_api',     public.helios_whatsapp_api_ready(),
    'whatsapp_sandbox', coalesce(public.helios_vault_secret('d360_base_url') like '%sandbox%', false)
  );
end;
$$;

revoke all on function public.helios_config_status() from public, anon;
grant execute on function public.helios_config_status() to authenticated;
