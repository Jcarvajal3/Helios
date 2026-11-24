-- ============================================================================
-- Helios — Compras Amazon: correcciones de la revisión (2026-11-24)
--
-- Sobre 20261124120000_compras_amazon_para_medicos.sql (que NO se edita: puede
-- estar aplicada). Todo va con `create or replace`, `alter ... if not exists`
-- y `drop function if exists` cuando cambia una firma (con su re-grant).
--
--  1. Habilitación y piloto: el módulo nace APAGADO; solo `rainforest` puede
--     abrirse a todos; el catálogo falso (`mock`) nunca. `pilot_phones` deja
--     probar con números concretos. `bot_compra_habilitada`.
--  2. Proveedor: solo `mock` y `rainforest` (se van `oxylabs` y `rapidapi`).
--  3. C2 (crítico): aprobar un pago exige que la solicitud esté en
--     `pago_reportado`; cancelar cierra los reportes abiertos; el orden de
--     bloqueo es siempre solicitud → reporte.
--  4. I1: la cotización vencida se aplica (el bot no puede reportar pago sobre
--     una cotización vencida; el administrador sí, y queda marcado).
--  5. I2: el monto del pago por el bot NO se autocompleta con el esperado:
--     `declared_amount_ves` es nulo si el médico no lo dijo.
--  6. I3: idempotencia de `bot_compra_crear` (clave) y de
--     `bot_compra_reportar_pago` (`wa_message_id`).
--  7. I4: referencias normalizadas, serializadas con un candado y cruzadas con
--     los pagos de los pacientes (`payment_reports`).
--  8. I7: `helios_purchase_notify` nunca descarta en silencio.
--  9. I8: el simulador usa actor real (cuatro ojos), audita todo y se cuenta
--     aparte. Sesión del simulador (`purchase_simulator_sessions`), para correr
--     EL MISMO bot.
-- 10. M1/M2/M4/M7/M8 y el carrusel validado (§5.9).
--
-- Reglas de la casa: security definer + `set search_path`, grants explícitos,
-- `audit.log` en toda acción de admin, USD numeric(18,4), VES numeric(18,2),
-- tasa numeric(18,6). Nada de «préstamo/financiamiento/crédito/fee» hacia el
-- médico, y los bolívares solo dentro del bloque de pago.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Funciones puras que usan las columnas nuevas (van primero)
-- ---------------------------------------------------------------------------

/**
 * La referencia de un pago en forma comparable: sin espacios ni signos, en
 * mayúsculas y sin ceros a la izquierda (el banco la muestra a veces con
 * ceros: «00119-4314348» y «1194314348» son el mismo pago). Nula si no queda
 * nada. Solo la usan funciones de la base y una columna generada.
 */
create or replace function public.helios_purchase_ref_norm(p_ref text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select nullif(
    regexp_replace(
      upper(regexp_replace(coalesce(p_ref, ''), '[^[:alnum:]]', '', 'g')),
      '^0+', ''
    ),
    ''
  );
$$;

/** Largo de un arreglo JSON (0 si no es un arreglo): evita errores en validaciones. */
create or replace function public.helios_purchase_json_len(p_json jsonb)
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case when jsonb_typeof(p_json) = 'array' then jsonb_array_length(p_json) else 0 end;
$$;

revoke all on function public.helios_purchase_ref_norm(text) from public, anon, authenticated;
revoke all on function public.helios_purchase_json_len(jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Configuración: apagado por defecto, piloto y proveedores válidos
-- ---------------------------------------------------------------------------

alter table public.purchase_settings
  drop constraint if exists purchase_settings_catalog_provider_check;

update public.purchase_settings
   set catalog_provider = 'mock'
 where catalog_provider not in ('mock', 'rainforest');

alter table public.purchase_settings
  add constraint purchase_settings_catalog_provider_check
  check (catalog_provider in ('mock', 'rainforest'));

alter table public.purchase_settings
  alter column is_enabled set default false;

-- Quien tenga el catálogo falso no puede estar abierto: se apaga ahora, antes
-- de que el constraint nuevo lo impida.
update public.purchase_settings
   set is_enabled = false
 where catalog_provider = 'mock';

alter table public.purchase_settings
  add column if not exists pilot_phones text[] not null default '{}';

comment on column public.purchase_settings.pilot_phones is
  'Teléfonos E.164 (+58...) que pueden usar Compras Amazon aunque is_enabled sea false (piloto).';

alter table public.purchase_settings
  drop constraint if exists purchase_settings_no_mock_abierto;

alter table public.purchase_settings
  add constraint purchase_settings_no_mock_abierto
  check (not (is_enabled and catalog_provider = 'mock'));

-- ---------------------------------------------------------------------------
-- 2. Tablas: idempotencia, monto declarado opcional, restricciones y sesión
-- ---------------------------------------------------------------------------

alter table public.purchase_requests
  add column if not exists idempotency_key text;

comment on column public.purchase_requests.idempotency_key is
  'Clave de idempotencia de la creación (el wa_message_id que confirmó, o un uuid por turno en el simulador). Un reintento devuelve la misma solicitud.';

create unique index if not exists purchase_requests_idempotency_key_uidx
  on public.purchase_requests (idempotency_key)
  where idempotency_key is not null;

-- M2: el número de solicitud lo da siempre la secuencia.
alter table public.purchase_requests
  alter column request_number set generated always;

-- I2: sin monto declarado no se inventa uno (antes se copiaba el esperado y
-- «el monto cuadra» era siempre verdadero).
alter table public.purchase_payment_reports
  alter column declared_amount_ves drop not null;

alter table public.purchase_payment_reports
  add column if not exists reference_norm text
  generated always as (public.helios_purchase_ref_norm(reference)) stored;

create index if not exists purchase_payment_reports_ref_norm_idx
  on public.purchase_payment_reports (reference_norm);

-- Los cruces de referencia contra pagos de pacientes no recorren la tabla entera.
create index if not exists payment_reports_ref_norm_purchase_idx
  on public.payment_reports (public.helios_purchase_ref_norm(reference))
  where reference is not null;

-- I3: un mismo mensaje de WhatsApp no registra dos pagos.
create unique index if not exists purchase_payment_reports_wa_message_uidx
  on public.purchase_payment_reports (wa_message_id)
  where wa_message_id is not null;

-- M1: ni una solicitud con pagos ni su bitácora se borran en cascada.
alter table public.purchase_payment_reports
  drop constraint if exists purchase_payment_reports_request_id_fkey;
alter table public.purchase_payment_reports
  add constraint purchase_payment_reports_request_id_fkey
  foreign key (request_id) references public.purchase_requests(id) on delete restrict;

alter table public.purchase_request_events
  drop constraint if exists purchase_request_events_request_id_fkey;
alter table public.purchase_request_events
  add constraint purchase_request_events_request_id_fkey
  foreign key (request_id) references public.purchase_requests(id) on delete restrict;

-- La sesión del simulador: la misma idea que `whatsapp_sessions`, sin atarla a
-- una persona del personal (el simulador la escribe la Edge Function).
create table if not exists public.purchase_simulator_sessions (
  phone_e164 text primary key,
  state      text not null,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

comment on table public.purchase_simulator_sessions is
  'Paso de la conversación del simulador de Compras Amazon (el mismo bot real, con otro transporte). Solo lo toca la Edge Function (service_role).';

alter table public.purchase_simulator_sessions enable row level security;
revoke all on public.purchase_simulator_sessions from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Ayudas internas (sin acceso desde la API)
-- ---------------------------------------------------------------------------

/**
 * Cuántos reportes de pago comparten esa referencia normalizada y siguen
 * vivos (ni rechazados ni duplicados): los de compras (menos `p_exclude_report`)
 * y los de los pacientes (`payment_reports`). No se mira el banco: el mismo
 * pago escrito con otro nombre de banco no debe escaparse; un falso positivo
 * solo manda el pago a revisión manual.
 */
create or replace function public.helios_purchase_reference_collisions(
  p_ref_norm       text,
  p_exclude_report uuid default null
)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case when p_ref_norm is null then 0 else (
    (select count(*) from public.purchase_payment_reports r
      where r.reference_norm = p_ref_norm
        and r.status not in ('rejected', 'duplicate')
        and (p_exclude_report is null or r.id <> p_exclude_report))
    +
    (select count(*) from public.payment_reports pr
      where pr.reference is not null
        and public.helios_purchase_ref_norm(pr.reference) = p_ref_norm
        and pr.status not in ('rejected', 'duplicate'))
  )::integer end;
$$;

/** «24/11/2026 a las 15:30», hora de Caracas, para los mensajes al médico. */
create or replace function public.helios_purchase_when_text(p_at timestamptz)
returns text
language sql
stable
set search_path = pg_catalog, pg_temp
as $$
  select to_char(p_at at time zone 'America/Caracas', 'DD/MM/YYYY "a las" HH24:MI');
$$;

/** «#C-1024 (Estetoscopio Littmann Classic…)»: cómo se nombra la solicitud al médico. */
create or replace function public.helios_purchase_ref_text(p_req public.purchase_requests)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select '#C-' || p_req.request_number
      || ' (' || left(p_req.product_title, 32)
      || case when length(p_req.product_title) > 32 then '…' else '' end || ')';
$$;

/**
 * Avisa al médico según el canal de la solicitud. NUNCA descarta en silencio:
 *   · `simulador` → `purchase_simulator_messages` con la forma canónica
 *                   (texto, o botones `{buttons:[{id,title}]}`); jamás toca
 *                   `outbound_messages`.
 *   · `whatsapp`  → con la ventana de 24 h abierta, `helios_whatsapp_text`; con
 *                   la ventana cerrada se encola igual en `outbound_messages`
 *                   (canal `whatsapp`, sin plantilla): el despachador no puede
 *                   mandarlo por la API y lo pasa solo a la cola manual
 *                   («Avisos de hoy»), con el motivo. Cualquier fallo queda en
 *                   un `raise warning` y NO tumba la acción de admin.
 */
create or replace function public.helios_purchase_notify(
  p_request public.purchase_requests,
  p_text    text,
  p_buttons jsonb default '[]'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_buttons      constant integer := 3;    -- límite de WhatsApp
  c_button_title_max constant integer := 20;   -- límite de WhatsApp
  c_button_id_max    constant integer := 256;  -- límite de WhatsApp
  c_text_max         constant integer := 4096;
  v_text text := nullif(btrim(coalesce(p_text, '')), '');
  v_btns jsonb;
begin
  if v_text is null then
    return;
  end if;

  v_btns := coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', left(b ->> 'id', c_button_id_max),
             'title', left(b ->> 'title', c_button_title_max)
           ) order by i)
    from jsonb_array_elements(
           case when jsonb_typeof(coalesce(p_buttons, '[]'::jsonb)) = 'array'
                then coalesce(p_buttons, '[]'::jsonb) else '[]'::jsonb end
         ) with ordinality as e(b, i)
    where i <= c_max_buttons
      and nullif(btrim(coalesce(b ->> 'id', '')), '') is not null
      and nullif(btrim(coalesce(b ->> 'title', '')), '') is not null
  ), '[]'::jsonb);

  if p_request.channel = 'simulador' then
    insert into public.purchase_simulator_messages (phone_e164, direction, kind, body, payload)
    values (
      p_request.phone_e164, 'out',
      case when jsonb_array_length(v_btns) > 0 then 'buttons' else 'text' end,
      v_text,
      case when jsonb_array_length(v_btns) > 0
           then jsonb_build_object('buttons', v_btns) else '{}'::jsonb end
    );
    return;
  end if;

  if p_request.requested_by is null then
    raise warning 'helios_purchase_notify: la solicitud #C-% no tiene persona del personal; el aviso no salió',
      p_request.request_number;
    return;
  end if;

  begin
    if public.helios_whatsapp_window_open(p_request.phone_e164) then
      perform public.helios_whatsapp_text(
        p_request.phone_e164, v_text, p_request.requested_by, v_btns
      );
    else
      insert into public.outbound_messages (
        channel, template_key, profile_id, recipient_staff_id, recipient,
        subject, rendered_text, status, next_attempt_at, wa_template
      ) values (
        'whatsapp', 'bot_respuesta', null, p_request.requested_by, p_request.phone_e164,
        'Helios', left(v_text, c_text_max), 'pendiente', now(),
        jsonb_build_object('name', null, 'language', 'es', 'params', '[]'::jsonb, 'buttons', v_btns)
      );
    end if;
  exception when others then
    raise warning 'helios_purchase_notify (solicitud #C-%): %', p_request.request_number, sqlerrm;
  end;
end;
$$;

/**
 * Cierra los reportes de pago abiertos de una solicitud (o solo `p_only_report`)
 * como `rejected` o `duplicate`, con quién, cuándo y por qué. Devuelve cuántos
 * cerró. QUIEN LLAMA ya tiene bloqueada la solicitud (orden: solicitud →
 * reporte); aquí no se bloquea nada más.
 */
create or replace function public.helios_purchase_close_reports(
  p_request_id  uuid,
  p_status      text,
  p_actor       uuid,
  p_note        text,
  p_only_report uuid default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n integer;
begin
  if p_status not in ('rejected', 'duplicate') then
    raise exception 'Estado de cierre no válido: rejected o duplicate' using errcode = '22023';
  end if;

  update public.purchase_payment_reports
     set status = p_status,
         reviewed_by = p_actor,
         reviewed_at = now(),
         rejection_note = p_note
   where request_id = p_request_id
     and status in ('reported', 'in_review')
     and (p_only_report is null or id = p_only_report);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

/**
 * La cotización de una solicitud como la ve el bot al crearla o repetirla.
 * El bloque de pago solo sale si espera pago y la cotización sigue vigente.
 * `total_cambio`: el total del servidor difiere (> $0,01) del que el médico vio.
 */
create or replace function public.helios_purchase_quote_json(
  p_req               public.purchase_requests,
  p_session_total_usd numeric default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  c_total_tolerance constant numeric := 0.01;
  v_vencida boolean := p_req.status = 'esperando_pago' and p_req.quote_expires_at <= now();
  v_block   text;
begin
  if p_req.status = 'esperando_pago' and not v_vencida
     and public.helios_fx_rate('USD') is not null then
    v_block := public.helios_purchase_payment_block(p_req.total_usd);
  end if;

  return jsonb_build_object(
    'request_id', p_req.id,
    'request_number', p_req.request_number,
    'status', p_req.status,
    'channel', p_req.channel,
    'asin', p_req.asin,
    'product_title', p_req.product_title,
    'quantity', p_req.quantity,
    'shipping_method', p_req.shipping_method,
    'unit_price_usd', p_req.unit_price_usd,
    'subtotal_usd', p_req.subtotal_usd,
    'tax_usa_usd', p_req.tax_usa_usd,
    'shipping_usd', p_req.shipping_usd,
    'service_fee_usd', p_req.service_fee_usd,
    'total_usd', p_req.total_usd,
    'quoted_fx_rate', p_req.quoted_fx_rate,
    'quoted_ves', p_req.quoted_ves,
    'quote_expires_at', p_req.quote_expires_at,
    'vencida', v_vencida,
    'weight_estimated', p_req.weight_estimated,
    'restricted_flag', p_req.restricted_flag,
    'restricted_reason', p_req.restricted_reason,
    'total_cambio', p_session_total_usd is not null
                    and abs(p_req.total_usd - p_session_total_usd) > c_total_tolerance,
    'payment_block', v_block
  );
end;
$$;

/**
 * M7: el núcleo de crear una solicitud, compartido por `bot_compra_crear` y
 * `admin_purchase_sim_create`. Con `p_idempotency_key`, repetir la llamada
 * devuelve la misma solicitud sin crear otra (también si dos llamadas corren a
 * la vez: el índice único decide).
 */
create or replace function public.helios_purchase_create_core(
  p_merchant_id          uuid,
  p_requested_by         uuid,
  p_phone                text,
  p_channel              text,
  p_actor                uuid,
  p_asin                 text,
  p_product_title        text,
  p_product_url          text,
  p_image_url            text,
  p_variant_label        text,
  p_quantity             integer,
  p_category             text,
  p_weight_lb            numeric,
  p_volumetric_weight_lb numeric,
  p_volume_ft3           numeric,
  p_weight_estimated     boolean,
  p_restricted_flag      boolean,
  p_restricted_reason    text,
  p_shipping_method      text,
  p_unit_price_usd       numeric,
  p_idempotency_key      text,
  p_session_total_usd    numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_key_max constant integer := 200;
  c_title_max constant integer := 400;
  v_channel text := lower(btrim(coalesce(p_channel, 'whatsapp')));
  v_asin    text := upper(nullif(btrim(coalesce(p_asin, '')), ''));
  v_title   text := nullif(btrim(coalesce(p_product_title, '')), '');
  v_key     text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_calc    jsonb;
  v_status  text;
  v_req     public.purchase_requests%rowtype;
begin
  if v_channel not in ('whatsapp', 'simulador') then
    raise exception 'Canal no válido: whatsapp o simulador' using errcode = '22023';
  end if;
  if v_asin is null then
    raise exception 'Falta el código ASIN del producto' using errcode = '22023';
  end if;
  if v_title is null then
    raise exception 'Falta el nombre del producto' using errcode = '22023';
  end if;
  if v_key is not null and length(v_key) > c_key_max then
    raise exception 'La clave de idempotencia es demasiado larga' using errcode = '22023';
  end if;

  -- Repetición: la misma clave devuelve la misma solicitud (solo del mismo número).
  if v_key is not null then
    select * into v_req from public.purchase_requests where idempotency_key = v_key;
    if found then
      if v_req.phone_e164 <> p_phone then
        raise exception 'Esa clave de idempotencia ya la usó otro número' using errcode = '42501';
      end if;
      return public.helios_purchase_quote_json(v_req, p_session_total_usd);
    end if;
  end if;

  v_calc := public.helios_purchase_calculate(
    p_unit_price_usd, p_quantity, p_shipping_method,
    p_weight_lb, p_volumetric_weight_lb, p_volume_ft3
  );

  v_status := case when coalesce(p_restricted_flag, false) then 'revision_aduanal' else 'esperando_pago' end;

  insert into public.purchase_requests (
    merchant_id, requested_by, phone_e164, channel,
    asin, product_title, product_url, image_url, variant_label,
    quantity, category, weight_lb, volumetric_weight_lb, volume_ft3,
    weight_estimated, restricted_flag, restricted_reason, shipping_method,
    unit_price_usd, subtotal_usd, tax_usa_usd, shipping_usd, service_fee_usd,
    total_usd, quoted_fx_rate, quoted_ves, quote_expires_at, status, idempotency_key
  ) values (
    p_merchant_id, p_requested_by, p_phone, v_channel,
    v_asin, left(v_title, c_title_max), nullif(btrim(coalesce(p_product_url, '')), ''),
    nullif(btrim(coalesce(p_image_url, '')), ''), nullif(btrim(coalesce(p_variant_label, '')), ''),
    (v_calc ->> 'quantity')::integer,
    nullif(btrim(coalesce(p_category, '')), ''),
    p_weight_lb, p_volumetric_weight_lb, p_volume_ft3,
    coalesce(p_weight_estimated, false) or coalesce((v_calc ->> 'weight_estimated')::boolean, false),
    coalesce(p_restricted_flag, false),
    nullif(btrim(coalesce(p_restricted_reason, '')), ''),
    v_calc ->> 'shipping_method',
    (v_calc ->> 'unit_price_usd')::numeric(18,4),
    (v_calc ->> 'subtotal_usd')::numeric(18,4),
    (v_calc ->> 'tax_usa_usd')::numeric(18,4),
    (v_calc ->> 'shipping_usd')::numeric(18,4),
    (v_calc ->> 'service_fee_usd')::numeric(18,4),
    (v_calc ->> 'total_usd')::numeric(18,4),
    (v_calc ->> 'quoted_fx_rate')::numeric(18,6),
    (v_calc ->> 'quoted_ves')::numeric(18,2),
    now() + make_interval(hours => (v_calc ->> 'quote_ttl_hours')::integer),
    v_status, v_key
  )
  on conflict (idempotency_key) where idempotency_key is not null do nothing
  returning * into v_req;

  if not found then
    -- Perdió la carrera contra otra llamada con la misma clave: devuelve la ganadora.
    select * into v_req from public.purchase_requests where idempotency_key = v_key;
    return public.helios_purchase_quote_json(v_req, p_session_total_usd);
  end if;

  insert into public.purchase_request_events (request_id, actor, kind, title, detail)
  values (
    v_req.id,
    p_actor,
    'created',
    case when v_req.restricted_flag
         then 'Solicitud creada (pendiente de revisión aduanal)'
         else 'Solicitud creada' end,
    jsonb_build_object(
      'channel', v_req.channel,
      'asin', v_req.asin,
      'quantity', v_req.quantity,
      'shipping_method', v_req.shipping_method,
      'total_usd', v_req.total_usd,
      'quoted_ves', v_req.quoted_ves,
      'restricted_flag', v_req.restricted_flag,
      'restricted_reason', v_req.restricted_reason
    )
  );

  return public.helios_purchase_quote_json(v_req, p_session_total_usd);
end;
$$;

/** El resultado de un reporte de pago (el mismo para el alta y para la repetición). */
create or replace function public.helios_purchase_payment_result(
  p_rep           public.purchase_payment_reports,
  p_req           public.purchase_requests,
  p_ya_registrado boolean default false
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'report_id', p_rep.id,
    'request_id', p_req.id,
    'request_number', p_req.request_number,
    'status', p_rep.status,
    'fx_rate', p_rep.fx_rate,
    'expected_ves', p_rep.expected_ves,
    'declared_amount_ves', p_rep.declared_amount_ves,
    'diferencia_ves', case when p_rep.declared_amount_ves is not null
                           then round(p_rep.declared_amount_ves - p_rep.expected_ves, 2) end,
    'monto_declarado', p_rep.declared_amount_ves is not null,
    'monto_cuadra', case when p_rep.declared_amount_ves is not null
                         then public.helios_monto_cuadra(p_rep.declared_amount_ves, p_rep.expected_ves) end,
    'cotizacion_vencida', p_req.status = 'esperando_pago' and p_req.quote_expires_at <= now(),
    'ya_registrado', p_ya_registrado
  );
$$;

/**
 * Núcleo compartido para registrar un pago de compra (bot, admin o simulador).
 *
 *  · Bloquea la solicitud PRIMERO (orden solicitud → reporte en todo el módulo).
 *  · Idempotente por `p_wa_message_id`: el mismo mensaje devuelve el mismo
 *    reporte con `ya_registrado: true`.
 *  · `p_enforce_quote_ttl`: el bot no puede pagar una cotización vencida
 *    (`cotizacion_vencida`, P0001); el administrador sí (decisión humana) y el
 *    resultado lo marca.
 *  · `p_amount_ves` nulo → el monto declarado queda NULO (no se inventa).
 *  · Referencia normalizada, serializada con un candado por referencia y
 *    cruzada con los pagos de los pacientes.
 */
drop function if exists public.helios_purchase_register_payment_core(uuid, text, text, text, date, numeric, text, text, text, uuid, text);

create or replace function public.helios_purchase_register_payment_core(
  p_request_id          uuid,
  p_method              text,
  p_bank                text,
  p_reference           text,
  p_paid_on             date,
  p_amount_ves          numeric,
  p_receipt_path        text,
  p_payer_phone         text,
  p_note                text,
  p_actor               uuid,
  p_wa_message_id       text,
  p_enforce_quote_ttl   boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  c_max_days_back constant integer := 120;
  c_ref_min_len   constant integer := 4;
  c_ref_max_len   constant integer := 40;
  c_bank_max_len  constant integer := 80;
  v_req          public.purchase_requests%rowtype;
  v_today        date := public.helios_business_date(now());
  v_method       text := lower(btrim(coalesce(p_method, '')));
  v_bank         text := nullif(btrim(coalesce(p_bank, '')), '');
  v_ref          text := nullif(btrim(coalesce(p_reference, '')), '');
  v_ref_norm     text;
  v_path         text := nullif(btrim(coalesce(p_receipt_path, '')), '');
  v_payer_phone  text := nullif(btrim(coalesce(p_payer_phone, '')), '');
  v_note         text := nullif(btrim(coalesce(p_note, '')), '');
  v_wa_msg       text := nullif(btrim(coalesce(p_wa_message_id, '')), '');
  v_fx_rate      numeric(18,6);
  v_expected_ves numeric(18,2);
  v_dup          boolean;
  v_status       text;
  v_rep          public.purchase_payment_reports%rowtype;
  v_cuadra       boolean;
  v_vencida      boolean;
begin
  select * into v_req
  from public.purchase_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Solicitud de compra no encontrada' using errcode = 'P0002';
  end if;

  -- Repetición del mismo mensaje: devuelve el reporte que ya existe.
  if v_wa_msg is not null then
    select * into v_rep from public.purchase_payment_reports where wa_message_id = v_wa_msg;
    if found then
      if v_rep.request_id <> v_req.id then
        raise exception 'Ese mensaje ya se usó para otra solicitud' using errcode = '42501';
      end if;
      return public.helios_purchase_payment_result(v_rep, v_req, true);
    end if;
  end if;

  if v_req.status <> 'esperando_pago' then
    raise exception 'Esta solicitud no está esperando pago (estado actual: %)', v_req.status
      using errcode = '22023';
  end if;

  v_vencida := v_req.quote_expires_at <= now();
  if v_vencida and coalesce(p_enforce_quote_ttl, true) then
    raise exception 'cotizacion_vencida: la cotización de #C-% venció; pide una cotización nueva antes de pagar',
      v_req.request_number
      using errcode = 'P0001';
  end if;

  if exists (
    select 1 from public.purchase_payment_reports r
    where r.request_id = v_req.id
      and r.status in ('reported', 'in_review')
  ) then
    raise exception 'Esta solicitud ya tiene un pago reportado pendiente de revisión'
      using errcode = '22023';
  end if;

  if v_method not in ('pago_movil', 'transferencia') then
    raise exception 'Método de pago no válido: pago_movil o transferencia'
      using errcode = '22023';
  end if;

  if v_bank is null or length(v_bank) > c_bank_max_len then
    raise exception 'Falta el banco del pago' using errcode = '22023';
  end if;

  v_ref_norm := public.helios_purchase_ref_norm(v_ref);
  if v_ref is null or length(v_ref) > c_ref_max_len
     or v_ref_norm is null or length(v_ref_norm) < c_ref_min_len then
    raise exception 'La referencia debe tener entre % y % caracteres', c_ref_min_len, c_ref_max_len
      using errcode = '22023';
  end if;

  if p_paid_on is null then
    raise exception 'Falta la fecha del pago' using errcode = '22023';
  end if;
  if p_paid_on > v_today then
    raise exception 'La fecha del pago no puede ser posterior a hoy' using errcode = '22023';
  end if;
  if p_paid_on < v_today - c_max_days_back then
    raise exception 'La fecha del pago es de hace más de % días: revísala', c_max_days_back
      using errcode = '22023';
  end if;

  if p_amount_ves is not null then
    if p_amount_ves <= 0 then
      raise exception 'El monto en bolívares debe ser mayor que cero' using errcode = '22023';
    end if;
    if p_amount_ves <> round(p_amount_ves, 2) then
      raise exception 'El monto en bolívares admite como mucho 2 decimales' using errcode = '22023';
    end if;
  end if;

  if v_path is not null and (
    v_path not like 'compras/%'
    or v_path like '%..%'
    or position('\' in v_path) > 0
    or length(v_path) > 500
  ) then
    raise exception 'Ruta de captura no válida: debe iniciar con compras/ y no contener ..'
      using errcode = '22023';
  end if;

  v_fx_rate := public.helios_fx_rate('USD', p_paid_on);
  if v_fx_rate is null or v_fx_rate <= 0 then
    raise exception 'No hay tasa BCV vigente para la fecha %', p_paid_on
      using errcode = 'P0002';
  end if;

  v_expected_ves := round(v_req.total_usd * v_fx_rate, 2)::numeric(18,2);

  -- Dos reportes con la misma referencia a la vez se serializan aquí: el
  -- segundo ve al primero y cae en revisión (el candado se suelta al terminar).
  perform pg_advisory_xact_lock(hashtextextended('compras_ref:' || v_ref_norm, 0));
  v_dup := public.helios_purchase_reference_collisions(v_ref_norm) > 0;
  v_status := case when v_dup then 'in_review' else 'reported' end;

  insert into public.purchase_payment_reports (
    request_id, method, bank, reference, payer_phone,
    paid_on, fx_rate, expected_ves, declared_amount_ves,
    receipt_path, status, registered_by, rejection_note, note, wa_message_id
  ) values (
    v_req.id, v_method, v_bank, v_ref, v_payer_phone,
    p_paid_on, v_fx_rate, v_expected_ves, p_amount_ves,
    v_path, v_status, p_actor,
    case when v_dup then 'Referencia repetida (otra compra o un pago de paciente): revisar contra el estado de cuenta antes de aprobar.' end,
    v_note, v_wa_msg
  )
  returning * into v_rep;

  update public.purchase_requests
     set status = 'pago_reportado', updated_at = now()
   where id = v_req.id;

  v_cuadra := case when p_amount_ves is not null
                   then public.helios_monto_cuadra(p_amount_ves, v_expected_ves) end;

  insert into public.purchase_request_events (request_id, actor, kind, title, detail)
  values (
    v_req.id,
    p_actor,
    'payment_reported',
    case when v_dup then 'Pago reportado (referencia repetida, en revisión)' else 'Pago reportado' end,
    jsonb_build_object(
      'report_id', v_rep.id,
      'method', v_method,
      'bank', v_bank,
      'reference', v_ref,
      'paid_on', p_paid_on,
      'fx_rate', v_fx_rate,
      'expected_ves', v_expected_ves,
      'declared_amount_ves', p_amount_ves,
      'monto_declarado', p_amount_ves is not null,
      'monto_cuadra', v_cuadra,
      'duplicate_reference', v_dup,
      'cotizacion_vencida', v_vencida,
      'status', v_status
    )
  );

  if p_actor is not null then
    perform audit.log(
      p_actor,
      'purchase_payment.registered',
      v_rep.id,
      jsonb_build_object(
        'request_id', v_req.id,
        'request_number', v_req.request_number,
        'method', v_method,
        'bank', v_bank,
        'reference', v_ref,
        'paid_on', p_paid_on,
        'fx_rate', v_fx_rate,
        'expected_ves', v_expected_ves,
        'declared_amount_ves', p_amount_ves,
        'monto_cuadra', v_cuadra,
        'cotizacion_vencida', v_vencida,
        'status', v_status,
        'receipt_path', v_path,
        'note', v_note
      )
    );
  end if;

  return public.helios_purchase_payment_result(v_rep, v_req, false);
end;
$$;

/** Ficha resumida de una solicitud de compra (panel de administración). */
create or replace function public.helios_purchase_request_summary(p_request_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', pr.id,
    'request_number', pr.request_number,
    'merchant_id', pr.merchant_id,
    'merchant_name', m.name,
    'requested_by', pr.requested_by,
    'staff_name', case when pr.requested_by is not null then public.helios_staff_name(pr.requested_by) end,
    'phone_e164', pr.phone_e164,
    'channel', pr.channel,
    'asin', pr.asin,
    'product_title', pr.product_title,
    'product_url', pr.product_url,
    'image_url', pr.image_url,
    'variant_label', pr.variant_label,
    'quantity', pr.quantity,
    'category', pr.category,
    'weight_lb', pr.weight_lb,
    'volumetric_weight_lb', pr.volumetric_weight_lb,
    'volume_ft3', pr.volume_ft3,
    'weight_estimated', pr.weight_estimated,
    'restricted_flag', pr.restricted_flag,
    'restricted_reason', pr.restricted_reason,
    'shipping_method', pr.shipping_method,
    'unit_price_usd', pr.unit_price_usd,
    'subtotal_usd', pr.subtotal_usd,
    'tax_usa_usd', pr.tax_usa_usd,
    'shipping_usd', pr.shipping_usd,
    'service_fee_usd', pr.service_fee_usd,
    'total_usd', pr.total_usd,
    'quoted_fx_rate', pr.quoted_fx_rate,
    'quoted_ves', pr.quoted_ves,
    'quote_expires_at', pr.quote_expires_at,
    'vencida', (pr.status = 'esperando_pago' and pr.quote_expires_at <= now()),
    'status', pr.status,
    'amazon_order_id', pr.amazon_order_id,
    'us_tracking_number', pr.us_tracking_number,
    'delivery_address', pr.delivery_address,
    'internal_notes', pr.internal_notes,
    'cancel_reason', pr.cancel_reason,
    'paid_at', pr.paid_at,
    'purchased_at', pr.purchased_at,
    'delivered_at', pr.delivered_at,
    'cancelled_at', pr.cancelled_at,
    'created_at', pr.created_at,
    'updated_at', pr.updated_at,
    'payment_count', (select count(*)::integer from public.purchase_payment_reports r where r.request_id = pr.id),
    'open_payment_report_id', (
      select r.id from public.purchase_payment_reports r
      where r.request_id = pr.id and r.status in ('reported', 'in_review')
      order by r.created_at desc limit 1
    ),
    'open_payment_status', (
      select r.status from public.purchase_payment_reports r
      where r.request_id = pr.id and r.status in ('reported', 'in_review')
      order by r.created_at desc limit 1
    )
  )
  from public.purchase_requests pr
  join public.merchants m on m.id = pr.merchant_id
  where pr.id = p_request_id;
$$;

/** Ficha completa de un reporte de pago de compra para la cola y el detalle. */
create or replace function public.helios_purchase_payment_item(p_report_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'report_id', r.id,
    'request_id', r.request_id,
    'request_number', req.request_number,
    'request_status', req.status,
    'channel', req.channel,
    'merchant_id', req.merchant_id,
    'merchant_name', m.name,
    'phone_e164', req.phone_e164,
    'staff_name', case when req.requested_by is not null then public.helios_staff_name(req.requested_by) end,
    'asin', req.asin,
    'product_title', req.product_title,
    'total_usd', req.total_usd,
    'status', r.status,
    'method', r.method,
    'bank', r.bank,
    'reference', r.reference,
    'payer_phone', r.payer_phone,
    'paid_on', r.paid_on,
    'fx_rate', r.fx_rate,
    'expected_ves', r.expected_ves,
    'declared_amount_ves', r.declared_amount_ves,
    'monto_declarado', r.declared_amount_ves is not null,
    'cotizacion_vencida', (req.status = 'esperando_pago' and req.quote_expires_at <= now()),
    'diferencia_ves', case when r.declared_amount_ves is not null
                           then round(r.declared_amount_ves - r.expected_ves, 2) end,
    'monto_cuadra', case when r.declared_amount_ves is not null
                         then public.helios_monto_cuadra(r.declared_amount_ves, r.expected_ves) end,
    'receipt_path', r.receipt_path,
    'receipt', case when r.receipt_path is not null then
      jsonb_build_object('bucket', 'payment-receipts', 'path', r.receipt_path) end,
    'registered_by', r.registered_by,
    'registered_by_name', case when r.registered_by is not null
      then coalesce(ra.full_name, 'Alguien del equipo') end,
    'reviewed_by', r.reviewed_by,
    'reviewed_by_name', case when r.reviewed_by is not null
      then coalesce(pa.full_name, 'Alguien del equipo') end,
    'reviewed_at', r.reviewed_at,
    'rejection_note', r.rejection_note,
    'note', r.note,
    'wa_message_id', r.wa_message_id,
    'created_at', r.created_at,
    'reference_collisions', public.helios_purchase_reference_collisions(r.reference_norm, r.id),
    'four_eyes', public.helios_payment_four_eyes(),
    'can_approve', public.helios_can_approve_purchase_payment(r.id, auth.uid())
  )
  from public.purchase_payment_reports r
  join public.purchase_requests req on req.id = r.request_id
  join public.merchants m on m.id = req.merchant_id
  left join public.platform_admins ra on ra.user_id = r.registered_by
  left join public.platform_admins pa on pa.user_id = r.reviewed_by
  where r.id = p_report_id;
$$;

/** Proyección MÍNIMA de una solicitud para el médico (sin notas internas ni dirección). */
create or replace function public.helios_purchase_bot_view(p_req public.purchase_requests)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'request_id', p_req.id,
    'request_number', p_req.request_number,
    'product_title', p_req.product_title,
    'quantity', p_req.quantity,
    'status', p_req.status,
    'shipping_method', p_req.shipping_method,
    'total_usd', p_req.total_usd,
    'quote_expires_at', p_req.quote_expires_at,
    'vencida', (p_req.status = 'esperando_pago' and p_req.quote_expires_at <= now()),
    'us_tracking_number', p_req.us_tracking_number,
    'created_at', p_req.created_at
  );
$$;

/** Conteos por estado de un canal (todos los estados, con ceros). */
create or replace function public.helios_purchase_counts_for(p_channel text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_statuses constant text[] := array[
    'revision_aduanal', 'esperando_pago', 'pago_reportado', 'pagado',
    'comprado_amazon', 'en_almacen_usa', 'en_transito', 'en_aduana',
    'listo_entrega', 'entregado', 'cancelado'
  ];
  v_by    jsonb;
  v_total integer;
begin
  select coalesce(jsonb_object_agg(s.status, coalesce(c.n, 0)), '{}'::jsonb)
    into v_by
  from unnest(v_statuses) as s(status)
  left join (
    select status, count(*)::integer as n
    from public.purchase_requests
    where channel = p_channel
    group by status
  ) c on c.status = s.status;

  select count(*)::integer into v_total from public.purchase_requests where channel = p_channel;

  return v_by || jsonb_build_object(
    'total', v_total,
    'active', v_total - coalesce((v_by ->> 'entregado')::integer, 0) - coalesce((v_by ->> 'cancelado')::integer, 0),
    'payments_pending', (
      select count(*)::integer
      from public.purchase_payment_reports r
      join public.purchase_requests q on q.id = r.request_id
      where q.channel = p_channel and r.status in ('reported', 'in_review')
    )
  );
end;
$$;

revoke all on function public.helios_purchase_reference_collisions(text, uuid) from public, anon, authenticated;
revoke all on function public.helios_purchase_when_text(timestamptz) from public, anon, authenticated;
revoke all on function public.helios_purchase_ref_text(public.purchase_requests) from public, anon, authenticated;
revoke all on function public.helios_purchase_notify(public.purchase_requests, text, jsonb) from public, anon, authenticated;
revoke all on function public.helios_purchase_close_reports(uuid, text, uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.helios_purchase_quote_json(public.purchase_requests, numeric) from public, anon, authenticated;
revoke all on function public.helios_purchase_create_core(uuid, uuid, text, text, uuid, text, text, text, text, text, integer, text, numeric, numeric, numeric, boolean, boolean, text, text, numeric, text, numeric) from public, anon, authenticated;
revoke all on function public.helios_purchase_payment_result(public.purchase_payment_reports, public.purchase_requests, boolean) from public, anon, authenticated;
revoke all on function public.helios_purchase_register_payment_core(uuid, text, text, text, date, numeric, text, text, text, uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.helios_purchase_request_summary(uuid) from public, anon, authenticated;
revoke all on function public.helios_purchase_payment_item(uuid) from public, anon, authenticated;
revoke all on function public.helios_purchase_bot_view(public.purchase_requests) from public, anon, authenticated;
revoke all on function public.helios_purchase_counts_for(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Aviso interno: «un médico pide hablar con una persona»
--    (el mismo mecanismo que `inicial_pendiente`: internal_alert_recipients +
--    la cola de correo, con su plantilla que solo permite apagarlo)
-- ---------------------------------------------------------------------------

insert into public.notification_templates (
  key, label, trigger_label, help, variables, required_variables,
  default_title, default_body, enabled, editable, can_disable, sort_order, channels
) values (
  'alerta_compras_persona',
  'Aviso interno: un médico de Compras Amazon pide hablar con una persona',
  'Cuando el médico toca «Hablar con alguien» en Compras Amazon',
  'Correo interno al equipo (internal_alert_recipients, tema compras_persona). El texto lo arma la base; aquí solo se puede apagar.',
  array['medico', 'solicitud'],
  array['medico', 'solicitud'],
  'Compras Amazon: {medico} pide hablar con una persona',
  '{medico} pidió hablar con una persona ({solicitud}).',
  true, false, true, 18, array['email']
)
on conflict (key) do nothing;

-- A quién avisar: los mismos correos que ya reciben las iniciales pendientes.
insert into public.internal_alert_recipients (topic, email)
select 'compras_persona', r.email
from public.internal_alert_recipients r
where r.topic = 'inicial_pendiente'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 5. RPCs del bot (service_role)
-- ---------------------------------------------------------------------------

/** ¿Puede este número usar Compras Amazon? Abierto a todos, o en el piloto. */
create or replace function public.bot_compra_habilitada(p_phone text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_s     public.purchase_settings%rowtype;
  v_phone text := public.helios_wa_e164(p_phone);
  v_pilot boolean;
begin
  select * into v_s from public.purchase_settings where id;
  if not found then
    return jsonb_build_object('habilitada', false, 'proveedor', 'mock', 'piloto', false);
  end if;

  v_pilot := v_phone is not null and v_phone = any(v_s.pilot_phones);

  return jsonb_build_object(
    'habilitada', v_s.is_enabled or v_pilot,
    'proveedor', v_s.catalog_provider,
    'piloto', v_pilot
  );
end;
$$;

/** M8: la caché vencida se purga de paso, sin un job aparte. */
create or replace function public.bot_compra_cache_set(
  p_key         text,
  p_kind        text,
  p_provider    text,
  p_payload     jsonb,
  p_ttl_minutes integer default 60
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_purge_batch constant integer := 200;
  v_key  text := nullif(btrim(coalesce(p_key, '')), '');
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_prov text := nullif(btrim(coalesce(p_provider, '')), '');
  v_ttl  integer := least(greatest(coalesce(p_ttl_minutes, 60), 1), 10080);
begin
  if v_key is null or v_kind not in ('search', 'product') or v_prov is null or p_payload is null then
    raise exception 'Entrada de caché inválida' using errcode = '22023';
  end if;

  delete from public.amazon_catalog_cache
  where cache_key in (
    select cache_key from public.amazon_catalog_cache
    where expires_at <= now()
    limit c_purge_batch
  );

  insert into public.amazon_catalog_cache (cache_key, kind, provider, payload, fetched_at, expires_at)
  values (v_key, v_kind, v_prov, p_payload, now(), now() + make_interval(mins => v_ttl))
  on conflict (cache_key) do update
    set kind = excluded.kind,
        provider = excluded.provider,
        payload = excluded.payload,
        fetched_at = excluded.fetched_at,
        expires_at = excluded.expires_at;
end;
$$;

drop function if exists public.bot_compra_crear(text, text, text, text, text, text, integer, text, numeric, numeric, numeric, boolean, boolean, text, text, numeric, text);

create or replace function public.bot_compra_crear(
  p_phone                text,
  p_asin                 text,
  p_product_title        text,
  p_product_url          text default null,
  p_image_url            text default null,
  p_variant_label        text default null,
  p_quantity             integer default 1,
  p_category             text default null,
  p_weight_lb            numeric default null,
  p_volumetric_weight_lb numeric default null,
  p_volume_ft3           numeric default null,
  p_weight_estimated     boolean default false,
  p_restricted_flag      boolean default false,
  p_restricted_reason    text default null,
  p_shipping_method      text default 'aereo',
  p_unit_price_usd       numeric default 0,
  p_channel              text default 'whatsapp',
  p_idempotency_key      text default null,
  p_session_total_usd    numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n       public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_channel text := lower(btrim(coalesce(p_channel, 'whatsapp')));
begin
  if v_channel not in ('whatsapp', 'simulador') then
    raise exception 'Canal no válido: whatsapp o simulador' using errcode = '22023';
  end if;

  -- El simulador es interno (lo autoriza la Edge Function con el JWT de un
  -- administrador) y debe poder probarse con el servicio apagado.
  if v_channel = 'whatsapp'
     and not coalesce((public.bot_compra_habilitada(v_n.phone_e164) ->> 'habilitada')::boolean, false) then
    raise exception 'El servicio de compras Amazon no está habilitado en este momento'
      using errcode = '22023';
  end if;

  return public.helios_purchase_create_core(
    v_n.merchant_id, v_n.user_id, v_n.phone_e164, v_channel, v_n.user_id,
    p_asin, p_product_title, p_product_url, p_image_url, p_variant_label,
    p_quantity, p_category, p_weight_lb, p_volumetric_weight_lb, p_volume_ft3,
    p_weight_estimated, p_restricted_flag, p_restricted_reason, p_shipping_method,
    p_unit_price_usd, p_idempotency_key, p_session_total_usd
  );
end;
$$;

/** M4: solo lo que el médico necesita ver. Solo las del canal indicado (el simulador no se mezcla con las reales). */
drop function if exists public.bot_compra_mis_solicitudes(text, integer);

create or replace function public.bot_compra_mis_solicitudes(
  p_phone   text,
  p_limit   integer default 8,
  p_channel text default 'whatsapp'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_limit constant integer := 30;
  v_n   public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_lim integer := least(greatest(coalesce(p_limit, 8), 1), c_max_limit);
begin
  if lower(btrim(coalesce(p_channel, ''))) not in ('whatsapp', 'simulador') then
    raise exception 'Canal no válido: whatsapp o simulador' using errcode = '22023';
  end if;
  return coalesce((
    select jsonb_agg(q.v order by q.ca desc)
    from (
      select public.helios_purchase_bot_view(pr) as v, pr.created_at as ca
      from public.purchase_requests pr
      where pr.phone_e164 = v_n.phone_e164
        and pr.channel = lower(btrim(p_channel))
      order by pr.created_at desc
      limit v_lim
    ) q
  ), '[]'::jsonb);
end;
$$;

/** La solicitud más reciente del canal que espera pago (con la cotización vencida o no). */
drop function if exists public.bot_compra_pendiente_de_pago(text);

create or replace function public.bot_compra_pendiente_de_pago(
  p_phone   text,
  p_channel text default 'whatsapp'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_n       public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_req     public.purchase_requests%rowtype;
  v_fx      numeric(18,6);
  v_vencida boolean;
begin
  if lower(btrim(coalesce(p_channel, ''))) not in ('whatsapp', 'simulador') then
    raise exception 'Canal no válido: whatsapp o simulador' using errcode = '22023';
  end if;

  select * into v_req
  from public.purchase_requests
  where phone_e164 = v_n.phone_e164
    and channel = lower(btrim(p_channel))
    and status = 'esperando_pago'
  order by created_at desc
  limit 1;

  if not found then
    return null;
  end if;

  v_vencida := v_req.quote_expires_at <= now();
  v_fx := public.helios_fx_rate('USD');

  return jsonb_build_object(
    'request_id', v_req.id,
    'request_number', v_req.request_number,
    'status', v_req.status,
    'vencida', v_vencida,
    'product_title', v_req.product_title,
    'asin', v_req.asin,
    'quantity', v_req.quantity,
    'total_usd', v_req.total_usd,
    'quoted_fx_rate', v_req.quoted_fx_rate,
    'quoted_ves', v_req.quoted_ves,
    'today_fx_rate', v_fx,
    'today_ves', case when v_fx is not null then round(v_req.total_usd * v_fx, 2) end,
    'quote_expires_at', v_req.quote_expires_at,
    'payment_block', case
      when not v_vencida and v_fx is not null
      then public.helios_purchase_payment_block(v_req.total_usd)
    end
  );
end;
$$;

/** La solicitud del médico, con su bloque de pago (si procede) y su línea de tiempo pública. */
drop function if exists public.bot_compra_detalle(text, uuid);

create or replace function public.bot_compra_detalle(
  p_phone      text,
  p_request_id uuid,
  p_channel    text default 'whatsapp'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  c_events_shown constant integer := 5;
  v_n   public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_req public.purchase_requests%rowtype;
begin
  if lower(btrim(coalesce(p_channel, ''))) not in ('whatsapp', 'simulador') then
    raise exception 'Canal no válido: whatsapp o simulador' using errcode = '22023';
  end if;
  select * into v_req from public.purchase_requests where id = p_request_id;
  if not found then
    raise exception 'Solicitud de compra no encontrada' using errcode = 'P0002';
  end if;
  if v_req.phone_e164 <> v_n.phone_e164 or v_req.merchant_id <> v_n.merchant_id then
    raise exception 'Esa solicitud no corresponde a este número' using errcode = '42501';
  end if;
  if v_req.channel <> lower(btrim(p_channel)) then
    raise exception 'Esa solicitud no corresponde a este canal' using errcode = '42501';
  end if;

  return public.helios_purchase_bot_view(v_req) || jsonb_build_object(
    'payment_block', case
      when v_req.status = 'esperando_pago'
       and v_req.quote_expires_at > now()
       and public.helios_fx_rate('USD') is not null
      then public.helios_purchase_payment_block(v_req.total_usd)
    end,
    -- Solo eventos que el médico puede ver: sin notas internas ni los
    -- movimientos de revisión del equipo (payment_flagged, payment_duplicate).
    'eventos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', e.kind,
               'created_at', e.created_at,
               'to_status', e.detail ->> 'to_status'
             ) order by e.created_at desc)
      from (
        select ev.kind, ev.created_at, ev.detail
        from public.purchase_request_events ev
        where ev.request_id = v_req.id
          and ev.kind in (
            'created', 'payment_reported', 'payment_reconciled', 'payment_rejected',
            'customs_approved', 'customs_rejected', 'status_changed', 'requoted',
            'cancelled_by_user'
          )
        order by ev.created_at desc
        limit c_events_shown
      ) e
    ), '[]'::jsonb)
  );
end;
$$;

/**
 * Reporte de pago del médico. Idempotente por `p_wa_message_id`. Si no dice el
 * monto, queda SIN monto declarado (`monto_cuadra: null`, `monto_declarado:
 * false`): el administrador lo verifica contra el comprobante. Si la
 * cotización venció, lanza `cotizacion_vencida` (P0001).
 */
drop function if exists public.bot_compra_reportar_pago(text, uuid, text, text, text, text, numeric, text, text, text);

create or replace function public.bot_compra_reportar_pago(
  p_phone         text,
  p_request_id    uuid,
  p_method        text,
  p_bank          text,
  p_reference     text,
  p_payer_phone   text default null,
  p_amount_ves    numeric default null,
  p_receipt_path  text default null,
  p_wa_message_id text default null,
  p_note          text default null,
  p_channel       text default 'whatsapp'
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_n   public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_req public.purchase_requests%rowtype;
begin
  if lower(btrim(coalesce(p_channel, ''))) not in ('whatsapp', 'simulador') then
    raise exception 'Canal no válido: whatsapp o simulador' using errcode = '22023';
  end if;
  select * into v_req from public.purchase_requests where id = p_request_id;
  if not found then
    raise exception 'Solicitud de compra no encontrada' using errcode = 'P0002';
  end if;

  if v_req.phone_e164 <> v_n.phone_e164 or v_req.merchant_id <> v_n.merchant_id then
    raise exception 'Esa solicitud no corresponde a este número' using errcode = '42501';
  end if;
  if v_req.channel <> lower(btrim(p_channel)) then
    raise exception 'Esa solicitud no corresponde a este canal' using errcode = '42501';
  end if;

  return public.helios_purchase_register_payment_core(
    p_request_id, p_method, p_bank, p_reference,
    public.helios_business_date(now()),
    p_amount_ves, p_receipt_path, p_payer_phone, p_note,
    null, p_wa_message_id, true
  );
end;
$$;

/** El médico cancela su solicitud mientras no tenga pago (o esté en revisión aduanal). */
drop function if exists public.bot_compra_cancelar(text, uuid);

create or replace function public.bot_compra_cancelar(
  p_phone      text,
  p_request_id uuid,
  p_channel    text default 'whatsapp'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n    public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_req  public.purchase_requests%rowtype;
  v_from text;
begin
  if lower(btrim(coalesce(p_channel, ''))) not in ('whatsapp', 'simulador') then
    raise exception 'Canal no válido: whatsapp o simulador' using errcode = '22023';
  end if;
  select * into v_req from public.purchase_requests where id = p_request_id for update;
  if not found then
    raise exception 'Solicitud de compra no encontrada' using errcode = 'P0002';
  end if;
  if v_req.phone_e164 <> v_n.phone_e164 or v_req.merchant_id <> v_n.merchant_id then
    raise exception 'Esa solicitud no corresponde a este número' using errcode = '42501';
  end if;
  if v_req.channel <> lower(btrim(p_channel)) then
    raise exception 'Esa solicitud no corresponde a este canal' using errcode = '42501';
  end if;

  v_from := v_req.status;
  if v_req.status not in ('esperando_pago', 'revision_aduanal') then
    raise exception 'Solo se puede cancelar una solicitud que aún no tiene pago (estado actual: %)', v_req.status
      using errcode = '22023';
  end if;

  if exists (
    select 1 from public.purchase_payment_reports r
    where r.request_id = v_req.id and r.status in ('reported', 'in_review')
  ) then
    raise exception 'Esta solicitud tiene un pago reportado en revisión: no se puede cancelar'
      using errcode = '22023';
  end if;

  update public.purchase_requests
     set status = 'cancelado',
         cancel_reason = 'Cancelada por el médico',
         cancelled_at = now(),
         updated_at = now()
   where id = v_req.id
  returning * into v_req;

  insert into public.purchase_request_events (request_id, actor, kind, title, detail)
  values (
    v_req.id, v_n.user_id, 'cancelled_by_user', 'Cancelada por el médico',
    jsonb_build_object('from_status', v_from, 'to_status', 'cancelado')
  );

  return public.helios_purchase_bot_view(v_req) || jsonb_build_object('ok', true);
end;
$$;

/** Recotiza una solicitud que espera pago con las tarifas y la tasa de hoy. */
drop function if exists public.bot_compra_recotizar(text, uuid);

create or replace function public.bot_compra_recotizar(
  p_phone      text,
  p_request_id uuid,
  p_channel    text default 'whatsapp'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n    public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_req  public.purchase_requests%rowtype;
  v_calc jsonb;
  v_prev numeric(18,4);
begin
  if lower(btrim(coalesce(p_channel, ''))) not in ('whatsapp', 'simulador') then
    raise exception 'Canal no válido: whatsapp o simulador' using errcode = '22023';
  end if;
  select * into v_req from public.purchase_requests where id = p_request_id for update;
  if not found then
    raise exception 'Solicitud de compra no encontrada' using errcode = 'P0002';
  end if;
  if v_req.phone_e164 <> v_n.phone_e164 or v_req.merchant_id <> v_n.merchant_id then
    raise exception 'Esa solicitud no corresponde a este número' using errcode = '42501';
  end if;
  if v_req.channel <> lower(btrim(p_channel)) then
    raise exception 'Esa solicitud no corresponde a este canal' using errcode = '42501';
  end if;
  if v_req.status <> 'esperando_pago' then
    raise exception 'Solo se puede recotizar una solicitud que espera pago (estado actual: %)', v_req.status
      using errcode = '22023';
  end if;

  v_prev := v_req.total_usd;
  v_calc := public.helios_purchase_calculate(
    v_req.unit_price_usd, v_req.quantity, v_req.shipping_method,
    v_req.weight_lb, v_req.volumetric_weight_lb, v_req.volume_ft3
  );

  update public.purchase_requests
     set subtotal_usd = (v_calc ->> 'subtotal_usd')::numeric(18,4),
         tax_usa_usd = (v_calc ->> 'tax_usa_usd')::numeric(18,4),
         shipping_usd = (v_calc ->> 'shipping_usd')::numeric(18,4),
         service_fee_usd = (v_calc ->> 'service_fee_usd')::numeric(18,4),
         total_usd = (v_calc ->> 'total_usd')::numeric(18,4),
         quoted_fx_rate = (v_calc ->> 'quoted_fx_rate')::numeric(18,6),
         quoted_ves = (v_calc ->> 'quoted_ves')::numeric(18,2),
         quote_expires_at = now() + make_interval(hours => (v_calc ->> 'quote_ttl_hours')::integer),
         weight_estimated = weight_estimated or coalesce((v_calc ->> 'weight_estimated')::boolean, false),
         updated_at = now()
   where id = v_req.id
  returning * into v_req;

  insert into public.purchase_request_events (request_id, actor, kind, title, detail)
  values (
    v_req.id, v_n.user_id, 'requoted', 'Cotización renovada',
    jsonb_build_object(
      'total_anterior_usd', v_prev,
      'total_usd', v_req.total_usd,
      'quoted_fx_rate', v_req.quoted_fx_rate,
      'quote_expires_at', v_req.quote_expires_at
    )
  );

  return jsonb_build_object(
    'request_id', v_req.id,
    'request_number', v_req.request_number,
    'total_usd', v_req.total_usd,
    'total_anterior_usd', v_prev,
    'quoted_ves', v_req.quoted_ves,
    'quote_expires_at', v_req.quote_expires_at,
    'payment_block', public.helios_purchase_payment_block(v_req.total_usd)
  );
end;
$$;

/**
 * El médico pide hablar con una persona. Deja un evento en la solicitud (si
 * la hay) y avisa al equipo POR CORREO INTERNO, el mismo mecanismo de
 * `inicial_pendiente` (`internal_alert_recipients`, tema `compras_persona`, por
 * la cola de correo). Un mismo número no repite el aviso en 10 minutos.
 */
create or replace function public.bot_compra_pedir_persona(
  p_phone      text,
  p_request_id uuid default null,
  p_texto      text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_dedupe_window_seconds constant integer := 600;
  c_text_max              constant integer := 500;
  v_n       public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_req     public.purchase_requests%rowtype;
  v_texto   text := left(nullif(btrim(coalesce(p_texto, '')), ''), c_text_max);
  v_on      boolean;
  v_medico  text := coalesce(public.helios_doctor_ref(v_n.merchant_id), 'un médico');
  v_sol     text := 'sin solicitud';
  v_subject text;
  v_text    text;
  v_html    text;
  v_url     text := 'https://conhelios.com/admin/compras';
  v_to      text;
  v_bucket  bigint := floor(extract(epoch from now()) / c_dedupe_window_seconds)::bigint;
begin
  if p_request_id is not null then
    select * into v_req from public.purchase_requests where id = p_request_id;
    if not found then
      raise exception 'Solicitud de compra no encontrada' using errcode = 'P0002';
    end if;
    if v_req.phone_e164 <> v_n.phone_e164 or v_req.merchant_id <> v_n.merchant_id then
      raise exception 'Esa solicitud no corresponde a este número' using errcode = '42501';
    end if;
    v_sol := '#C-' || v_req.request_number;
    v_url := v_url || '/' || v_req.id::text;

    insert into public.purchase_request_events (request_id, actor, kind, title, detail)
    values (
      v_req.id, v_n.user_id, 'human_requested', 'El médico pidió hablar con una persona',
      jsonb_build_object('texto', v_texto)
    );
  end if;

  select enabled into v_on from public.notification_templates where key = 'alerta_compras_persona';
  if not coalesce(v_on, false) then
    return;
  end if;

  v_subject := format('Compras Amazon: %s pide hablar con una persona', v_medico);
  v_text := format(E'Un médico pidió hablar con una persona en Compras Amazon.\n\nMédico: %s\nTeléfono: %s\nSolicitud: %s\nMensaje: %s\n\nVer en el panel: %s\n',
                   v_medico, v_n.phone_e164, v_sol, coalesce(v_texto, '(sin mensaje)'), v_url);
  v_html := format('<div style="font-family:Arial,sans-serif;font-size:15px;color:#0a1428;max-width:480px">'
                   '<p style="font-size:17px;margin:0 0 12px"><b>Un médico pidió hablar con una persona</b></p>'
                   '<table style="border-collapse:collapse;font-size:15px">'
                   '<tr><td style="padding:3px 14px 3px 0;color:#5b6478">Médico</td><td>%s</td></tr>'
                   '<tr><td style="padding:3px 14px 3px 0;color:#5b6478">Teléfono</td><td>%s</td></tr>'
                   '<tr><td style="padding:3px 14px 3px 0;color:#5b6478">Solicitud</td><td><b>%s</b></td></tr>'
                   '<tr><td style="padding:3px 14px 3px 0;color:#5b6478">Mensaje</td><td>%s</td></tr>'
                   '</table>'
                   '<p><a href="%s" style="color:#1a6dff">Ver en el panel</a></p></div>',
                   replace(replace(replace(v_medico, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'),
                   v_n.phone_e164, v_sol,
                   replace(replace(replace(coalesce(v_texto, '(sin mensaje)'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'),
                   v_url);

  for v_to in
    select r.email from public.internal_alert_recipients r
    where r.topic = 'compras_persona' and public.helios_valid_email(r.email)
    order by r.email
  loop
    begin
      -- `recipient_staff_id` (el médico) cumple el constraint de destinatario de
      -- la cola; el correo sale a `recipient`, que es el del equipo.
      insert into public.outbound_messages (
        channel, template_key, profile_id, recipient_staff_id, recipient, subject,
        rendered_text, html, status, next_attempt_at, dedupe_key
      ) values (
        'email', 'alerta_compras_persona', null, v_n.user_id, v_to, v_subject,
        v_text, v_html, 'pendiente', now(),
        'alerta_compras_persona:' || v_n.phone_e164 || ':' || v_to || ':' || v_bucket::text
      )
      on conflict (dedupe_key) do nothing;
    exception when others then
      raise warning 'bot_compra_pedir_persona (aviso a %): %', v_to, sqlerrm;
    end;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. RPCs de administración (authenticated)
-- ---------------------------------------------------------------------------

/** M8: los comodines (% y _) de la búsqueda son literales, no comodines. */
create or replace function public.admin_purchase_list(
  p_statuses text[] default null,
  p_channel  text default null,
  p_search   text default null,
  p_limit    integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_chan   text := nullif(lower(btrim(coalesce(p_channel, ''))), '');
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_pat    text;
  v_lim    integer := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_search is not null then
    v_pat := '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  return coalesce((
    select jsonb_agg(public.helios_purchase_request_summary(r.id) order by r.created_at desc)
    from (
      select pr.id, pr.created_at
      from public.purchase_requests pr
      join public.merchants m on m.id = pr.merchant_id
      where (p_statuses is null or cardinality(p_statuses) = 0 or pr.status = any(p_statuses))
        and (v_chan is null or pr.channel = v_chan)
        and (
          v_pat is null
          or pr.request_number::text ilike v_pat escape '\'
          or pr.asin ilike v_pat escape '\'
          or pr.product_title ilike v_pat escape '\'
          or pr.phone_e164 ilike v_pat escape '\'
          or m.name ilike v_pat escape '\'
          or coalesce(pr.amazon_order_id, '') ilike v_pat escape '\'
          or coalesce(pr.us_tracking_number, '') ilike v_pat escape '\'
        )
      order by pr.created_at desc
      limit v_lim
    ) r
  ), '[]'::jsonb);
end;
$$;

/** El bloque de pago solo sale si la solicitud espera pago (nunca en revisión aduanal). */
create or replace function public.admin_purchase_detail(p_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_req public.purchase_requests%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_req from public.purchase_requests where id = p_request_id;
  if not found then
    raise exception 'Solicitud de compra no encontrada' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'request', public.helios_purchase_request_summary(v_req.id),
    'bcv_rate_today', public.helios_fx_rate('USD'),
    'payment_block', case
      when v_req.status = 'esperando_pago'
       and public.helios_fx_rate('USD') is not null
      then public.helios_purchase_payment_block(v_req.total_usd)
    end,
    'payments', coalesce((
      select jsonb_agg(public.helios_purchase_payment_item(r.id) order by r.created_at desc)
      from public.purchase_payment_reports r
      where r.request_id = v_req.id
    ), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id,
        'actor', e.actor,
        'actor_name', case when e.actor is not null then
          coalesce(
            (select pa.full_name from public.platform_admins pa where pa.user_id = e.actor),
            public.helios_staff_name(e.actor)
          ) end,
        'kind', e.kind,
        'title', e.title,
        'detail', e.detail,
        'created_at', e.created_at
      ) order by e.created_at asc, e.id asc)
      from public.purchase_request_events e
      where e.request_id = v_req.id
    ), '[]'::jsonb)
  );
end;
$$;

/**
 * Conteos por estado. Las claves de siempre cuentan SOLO las solicitudes
 * reales (canal whatsapp); las del simulador van aparte, en `simulador`
 * (con los mismos estados), y `simulador_count` se conserva.
 */
create or replace function public.admin_purchase_counts()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_real jsonb;
  v_sim  jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_real := public.helios_purchase_counts_for('whatsapp');
  v_sim  := public.helios_purchase_counts_for('simulador');

  return v_real || jsonb_build_object(
    'whatsapp_count', (v_real ->> 'total')::integer,
    'simulador_count', (v_sim ->> 'total')::integer,
    'simulador', v_sim
  );
end;
$$;

drop function if exists public.admin_purchase_payment_queue(text[]);

create or replace function public.admin_purchase_payment_queue(
  p_statuses text[] default array['reported', 'in_review'],
  p_limit    integer default 200
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_limit constant integer := 500;
  v_statuses text[] := case
    when p_statuses is null or cardinality(p_statuses) = 0
    then array['reported', 'in_review']
    else p_statuses
  end;
  v_lim integer := least(greatest(coalesce(p_limit, 200), 1), c_max_limit);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(public.helios_purchase_payment_item(q.id) order by q.in_review desc, q.created_at asc)
    from (
      select r.id, (r.status = 'in_review') as in_review, r.created_at
      from public.purchase_payment_reports r
      where r.status = any(v_statuses)
      order by (r.status = 'in_review') desc, r.created_at asc
      limit v_lim
    ) q
  ), '[]'::jsonb);
end;
$$;

/** Pago manual del administrador: sí puede sobre una cotización vencida (queda marcado). */
create or replace function public.admin_purchase_register_payment(
  p_request_id   uuid,
  p_method       text,
  p_bank         text,
  p_reference    text,
  p_paid_on      date,
  p_amount_ves   numeric,
  p_receipt_path text default null,
  p_payer_phone  text default null,
  p_note         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_amount_ves is null then
    raise exception 'Indica el monto en bolívares del pago' using errcode = '22023';
  end if;

  return public.helios_purchase_register_payment_core(
    p_request_id, p_method, p_bank, p_reference, p_paid_on,
    p_amount_ves, p_receipt_path, p_payer_phone, p_note,
    auth.uid(), null, false
  );
end;
$$;

/**
 * Aprobar o rechazar un reporte de pago.
 *
 *  · Orden de bloqueo: SOLICITUD y luego reporte (igual que flag, duplicado y
 *    cancelar).
 *  · Aprobar exige que la solicitud esté en `pago_reportado`: una solicitud
 *    cancelada (o ya pagada) no puede resucitar.
 */
create or replace function public.admin_purchase_reconcile_payment(
  p_report_id uuid,
  p_approve   boolean,
  p_note      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor      uuid := auth.uid();
  v_nota       text := nullif(btrim(coalesce(p_note, '')), '');
  v_req_id     uuid;
  v_rep        public.purchase_payment_reports%rowtype;
  v_req        public.purchase_requests%rowtype;
  v_other_open boolean;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_approve is null then
    raise exception 'Indica si el pago se aprueba o se rechaza' using errcode = '22023';
  end if;

  if not p_approve and v_nota is null then
    raise exception 'Rechazar un pago requiere motivo' using errcode = '22023';
  end if;

  select r.request_id into v_req_id
  from public.purchase_payment_reports r
  where r.id = p_report_id;

  if not found then
    raise exception 'Reporte de pago no encontrado' using errcode = 'P0002';
  end if;

  select * into v_req from public.purchase_requests where id = v_req_id for update;
  select * into v_rep from public.purchase_payment_reports where id = p_report_id for update;

  if v_rep.status not in ('reported', 'in_review') then
    raise exception 'Este pago ya fue resuelto (%)', v_rep.status using errcode = '22023';
  end if;

  if p_approve then
    if v_req.status <> 'pago_reportado' then
      raise exception 'No se puede aprobar: la solicitud #C-% está en estado % y no espera confirmación de pago',
        v_req.request_number, v_req.status
        using errcode = '22023';
    end if;

    if not public.helios_can_approve_purchase_payment(v_rep.id, v_actor) then
      raise exception 'Tú registraste este pago: con el doble control encendido lo aprueba otra persona del equipo'
        using errcode = '42501';
    end if;

    update public.purchase_payment_reports
       set status = 'reconciled',
           reviewed_by = v_actor,
           reviewed_at = now(),
           rejection_note = null
     where id = v_rep.id
    returning * into v_rep;

    update public.purchase_requests
       set status = 'pagado',
           paid_at = coalesce(paid_at, now()),
           updated_at = now()
     where id = v_req.id
    returning * into v_req;

    insert into public.purchase_request_events (request_id, actor, kind, title, detail)
    values (
      v_req.id, v_actor, 'payment_reconciled', 'Pago aprobado',
      jsonb_build_object(
        'report_id', v_rep.id,
        'reference', v_rep.reference,
        'bank', v_rep.bank,
        'declared_amount_ves', v_rep.declared_amount_ves,
        'expected_ves', v_rep.expected_ves,
        'note', v_nota
      )
    );

    perform audit.log(v_actor, 'purchase_payment.reconciled', v_rep.id, jsonb_build_object(
      'request_id', v_req.id,
      'request_number', v_req.request_number,
      'reference', v_rep.reference,
      'bank', v_rep.bank,
      'declared_amount_ves', v_rep.declared_amount_ves,
      'note', v_nota
    ));

    perform public.helios_purchase_notify(
      v_req,
      format(
        'Confirmamos tu pago de #C-%s. Ya lo estamos comprando en Amazon y te aviso en cada paso.',
        v_req.request_number
      )
    );
  else
    perform public.helios_purchase_close_reports(v_req.id, 'rejected', v_actor, v_nota, v_rep.id);
    select * into v_rep from public.purchase_payment_reports where id = v_rep.id;

    v_other_open := exists (
      select 1 from public.purchase_payment_reports r2
      where r2.request_id = v_req.id
        and r2.id <> v_rep.id
        and r2.status in ('reported', 'in_review')
    );

    if not v_other_open and v_req.status = 'pago_reportado' then
      update public.purchase_requests
         set status = 'esperando_pago',
             updated_at = now()
       where id = v_req.id
      returning * into v_req;
    end if;

    insert into public.purchase_request_events (request_id, actor, kind, title, detail)
    values (
      v_req.id, v_actor, 'payment_rejected', 'Pago rechazado',
      jsonb_build_object(
        'report_id', v_rep.id,
        'reference', v_rep.reference,
        'bank', v_rep.bank,
        'reason', v_nota
      )
    );

    perform audit.log(v_actor, 'purchase_payment.rejected', v_rep.id, jsonb_build_object(
      'request_id', v_req.id,
      'request_number', v_req.request_number,
      'reference', v_rep.reference,
      'reason', v_nota
    ));

    -- Solo se avisa si la solicitud volvió a esperar pago: en una cancelada o
    -- ya pagada un «vuelve a enviar tu comprobante» confundiría.
    if v_req.status = 'esperando_pago' then
      perform public.helios_purchase_notify(
        v_req,
        format(
          E'No pudimos confirmar tu pago de #C-%s ⚠️\nMotivo: %s\nDebías pagar el equivalente a $%s en bolívares, al cambio BCV del día de tu pago.\n¿Cómo seguimos?',
          v_req.request_number,
          v_nota,
          public.helios_money_text(v_req.total_usd)
        ),
        jsonb_build_array(
          jsonb_build_object('id', 'compra:reenviar:' || v_req.id::text, 'title', 'Enviar comprobante'),
          jsonb_build_object('id', 'compra:persona', 'title', 'Hablar con alguien'),
          jsonb_build_object('id', 'compra:mis', 'title', 'Mis compras')
        )
      );
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'report_id', v_rep.id,
    'request_id', v_req.id,
    'request_number', v_req.request_number,
    'report_status', v_rep.status,
    'request_status', v_req.status
  );
end;
$$;

create or replace function public.admin_purchase_flag_payment(
  p_report_id uuid,
  p_note      text
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_nota   text := nullif(btrim(coalesce(p_note, '')), '');
  v_req_id uuid;
  v_rep    public.purchase_payment_reports%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_nota is null or length(v_nota) < 3 then
    raise exception 'Indica el motivo para enviar el pago a revisión' using errcode = '22023';
  end if;

  select r.request_id into v_req_id
  from public.purchase_payment_reports r
  where r.id = p_report_id;

  if not found then
    raise exception 'Reporte de pago no encontrado' using errcode = 'P0002';
  end if;

  -- Solicitud primero, reporte después.
  perform 1 from public.purchase_requests where id = v_req_id for update;
  select * into v_rep from public.purchase_payment_reports where id = p_report_id for update;

  if v_rep.status not in ('reported', 'in_review') then
    raise exception 'Este pago ya fue resuelto (%)', v_rep.status using errcode = '22023';
  end if;

  update public.purchase_payment_reports
     set status = 'in_review',
         rejection_note = v_nota
   where id = v_rep.id
  returning * into v_rep;

  insert into public.purchase_request_events (request_id, actor, kind, title, detail)
  values (
    v_rep.request_id, v_actor, 'payment_flagged', 'Pago marcado en revisión',
    jsonb_build_object('report_id', v_rep.id, 'note', v_nota)
  );

  perform audit.log(v_actor, 'purchase_payment.flagged', v_rep.id, jsonb_build_object(
    'request_id', v_rep.request_id,
    'note', v_nota
  ));

  return jsonb_build_object(
    'ok', true,
    'report_id', v_rep.id,
    'request_id', v_rep.request_id,
    'status', v_rep.status
  );
end;
$$;

create or replace function public.admin_purchase_mark_payment_duplicate(
  p_report_id uuid,
  p_note      text
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor      uuid := auth.uid();
  v_nota       text := nullif(btrim(coalesce(p_note, '')), '');
  v_req_id     uuid;
  v_rep        public.purchase_payment_reports%rowtype;
  v_req        public.purchase_requests%rowtype;
  v_other_open boolean;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_nota is null or length(v_nota) < 3 then
    raise exception 'Marcar un pago como duplicado requiere un motivo de al menos 3 caracteres'
      using errcode = '22023';
  end if;

  select r.request_id into v_req_id
  from public.purchase_payment_reports r
  where r.id = p_report_id;

  if not found then
    raise exception 'Reporte de pago no encontrado' using errcode = 'P0002';
  end if;

  -- Solicitud primero, reporte después (el orden de todo el módulo).
  select * into v_req from public.purchase_requests where id = v_req_id for update;
  select * into v_rep from public.purchase_payment_reports where id = p_report_id for update;

  if v_rep.status not in ('reported', 'in_review') then
    raise exception 'Este pago ya fue resuelto (%)', v_rep.status using errcode = '22023';
  end if;

  perform public.helios_purchase_close_reports(v_req.id, 'duplicate', v_actor, 'Duplicado: ' || v_nota, v_rep.id);
  select * into v_rep from public.purchase_payment_reports where id = v_rep.id;

  v_other_open := exists (
    select 1 from public.purchase_payment_reports r2
    where r2.request_id = v_req.id
      and r2.id <> v_rep.id
      and r2.status in ('reported', 'in_review')
  );

  if not v_other_open and v_req.status = 'pago_reportado' then
    update public.purchase_requests
       set status = 'esperando_pago',
           updated_at = now()
     where id = v_req.id
    returning * into v_req;
  end if;

  insert into public.purchase_request_events (request_id, actor, kind, title, detail)
  values (
    v_req.id, v_actor, 'payment_duplicate', 'Pago cerrado como duplicado',
    jsonb_build_object(
      'report_id', v_rep.id,
      'reference', v_rep.reference,
      'note', v_nota,
      'request_status', v_req.status
    )
  );

  perform audit.log(v_actor, 'purchase_payment.marked_duplicate', v_rep.id, jsonb_build_object(
    'request_id', v_req.id,
    'request_number', v_req.request_number,
    'reference', v_rep.reference,
    'note', v_nota,
    'request_status', v_req.status
  ));

  -- Sin aviso al médico: igual que admin_mark_payment_duplicate.
  return jsonb_build_object(
    'ok', true,
    'report_id', v_rep.id,
    'request_id', v_req.id,
    'status', 'duplicate',
    'request_status', v_req.status
  );
end;
$$;

create or replace function public.admin_purchase_approve_customs(
  p_request_id uuid,
  p_approve    boolean,
  p_note       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_nota  text := nullif(btrim(coalesce(p_note, '')), '');
  v_req   public.purchase_requests%rowtype;
  v_cfg   public.purchase_settings%rowtype;
  v_fx    numeric(18,6);
  v_ves   numeric(18,2);
  v_block text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_approve is null then
    raise exception 'Indica si la revisión aduanal se aprueba o rechaza' using errcode = '22023';
  end if;

  select * into v_req
  from public.purchase_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Solicitud de compra no encontrada' using errcode = 'P0002';
  end if;

  if v_req.status <> 'revision_aduanal' then
    raise exception 'Esta solicitud no está en revisión aduanal (estado actual: %)', v_req.status
      using errcode = '22023';
  end if;

  if p_approve then
    select * into v_cfg from public.purchase_settings where id;
    v_fx := public.helios_fx_rate('USD');
    if v_fx is null or v_fx <= 0 then
      raise exception 'No hay tasa BCV vigente del dólar' using errcode = 'P0002';
    end if;
    v_ves := round(v_req.total_usd * v_fx, 2)::numeric(18,2);

    update public.purchase_requests
       set status = 'esperando_pago',
           quoted_fx_rate = v_fx,
           quoted_ves = v_ves,
           quote_expires_at = now() + make_interval(hours => v_cfg.quote_ttl_hours),
           internal_notes = coalesce(concat_ws(E'\n', nullif(internal_notes, ''), v_nota), internal_notes),
           updated_at = now()
     where id = v_req.id
    returning * into v_req;

    insert into public.purchase_request_events (request_id, actor, kind, title, detail)
    values (
      v_req.id, v_actor, 'customs_approved', 'Revisión aduanal aprobada',
      jsonb_build_object('note', v_nota, 'quoted_fx_rate', v_fx, 'quoted_ves', v_ves,
                         'quote_expires_at', v_req.quote_expires_at)
    );

    perform audit.log(v_actor, 'purchase.customs_approved', v_req.id, jsonb_build_object(
      'request_number', v_req.request_number,
      'note', v_nota,
      'quoted_fx_rate', v_fx,
      'quoted_ves', v_ves
    ));

    v_block := public.helios_purchase_payment_block(v_req.total_usd);
    perform public.helios_purchase_notify(
      v_req,
      format(
        E'Aprobamos la importación de %s. Tu cotización vale hasta el %s.\n\n%s',
        public.helios_purchase_ref_text(v_req),
        public.helios_purchase_when_text(v_req.quote_expires_at),
        v_block
      )
    );
  else
    if v_nota is null then
      raise exception 'Rechazar la revisión aduanal requiere indicar el motivo' using errcode = '22023';
    end if;

    update public.purchase_requests
       set status = 'cancelado',
           cancel_reason = v_nota,
           cancelled_at = now(),
           updated_at = now()
     where id = v_req.id
    returning * into v_req;

    insert into public.purchase_request_events (request_id, actor, kind, title, detail)
    values (
      v_req.id, v_actor, 'customs_rejected', 'Revisión aduanal rechazada',
      jsonb_build_object('reason', v_nota)
    );

    perform audit.log(v_actor, 'purchase.customs_rejected', v_req.id, jsonb_build_object(
      'request_number', v_req.request_number,
      'reason', v_nota
    ));

    perform public.helios_purchase_notify(
      v_req,
      format(
        'No pudimos aprobar la importación de %s. Motivo: %s',
        public.helios_purchase_ref_text(v_req),
        v_nota
      )
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'request_id', v_req.id,
    'request_number', v_req.request_number,
    'status', v_req.status,
    'payment_block', v_block
  );
end;
$$;

/**
 * Avance logístico. Cancelar cierra, en la misma transacción, los reportes de
 * pago abiertos (como `rejected`, con nota) para que una solicitud cancelada no
 * pueda resucitar al aprobar un pago viejo, y avisa al médico.
 */
create or replace function public.admin_purchase_advance_status(
  p_request_id         uuid,
  p_status             text,
  p_amazon_order_id    text default null,
  p_us_tracking_number text default null,
  p_note               text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor    uuid := auth.uid();
  v_target   text := lower(btrim(coalesce(p_status, '')));
  v_order_id text := nullif(btrim(coalesce(p_amazon_order_id, '')), '');
  v_tracking text := nullif(btrim(coalesce(p_us_tracking_number, '')), '');
  v_nota     text := nullif(btrim(coalesce(p_note, '')), '');
  v_req      public.purchase_requests%rowtype;
  v_from     text;
  v_allowed  boolean := false;
  v_closed   integer := 0;
  v_msg      text;
  v_ref      text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_target not in (
    'comprado_amazon', 'en_almacen_usa', 'en_transito',
    'en_aduana', 'listo_entrega', 'entregado', 'cancelado'
  ) then
    raise exception 'Estado destino no válido para avance logístico: %', v_target
      using errcode = '22023';
  end if;

  select * into v_req
  from public.purchase_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Solicitud de compra no encontrada' using errcode = 'P0002';
  end if;

  v_from := v_req.status;

  if v_from in ('entregado', 'cancelado') then
    raise exception 'La solicitud ya está en estado final (%)', v_from using errcode = '22023';
  end if;

  if v_target = 'cancelado' then
    if v_nota is null then
      raise exception 'Cancelar una solicitud requiere indicar el motivo' using errcode = '22023';
    end if;
    v_allowed := true;
  else
    v_allowed := (
      (v_from = 'pagado'          and v_target = 'comprado_amazon')
      or (v_from = 'comprado_amazon' and v_target = 'en_almacen_usa')
      or (v_from = 'en_almacen_usa'  and v_target = 'en_transito')
      or (v_from = 'en_transito'     and v_target in ('en_aduana', 'listo_entrega'))
      or (v_from = 'en_aduana'       and v_target = 'listo_entrega')
      or (v_from = 'listo_entrega'   and v_target = 'entregado')
    );
  end if;

  if not v_allowed then
    raise exception 'Transición no permitida de % a %', v_from, v_target
      using errcode = '22023';
  end if;

  -- Cancelar: los pagos reportados sin resolver se cierran YA (la solicitud
  -- ya está bloqueada: orden solicitud → reporte).
  if v_target = 'cancelado' then
    v_closed := public.helios_purchase_close_reports(
      v_req.id, 'rejected', v_actor, 'Solicitud cancelada: ' || v_nota
    );
  end if;

  update public.purchase_requests
     set status = v_target,
         amazon_order_id = coalesce(v_order_id, amazon_order_id),
         us_tracking_number = coalesce(v_tracking, us_tracking_number),
         internal_notes = case
           when v_nota is not null and v_target <> 'cancelado'
           then concat_ws(E'\n', nullif(internal_notes, ''), v_nota)
           else internal_notes
         end,
         cancel_reason = case when v_target = 'cancelado' then v_nota else cancel_reason end,
         purchased_at = case when v_target = 'comprado_amazon' then coalesce(purchased_at, now()) else purchased_at end,
         delivered_at = case when v_target = 'entregado' then coalesce(delivered_at, now()) else delivered_at end,
         cancelled_at = case when v_target = 'cancelado' then coalesce(cancelled_at, now()) else cancelled_at end,
         updated_at = now()
   where id = v_req.id
  returning * into v_req;

  if v_closed > 0 then
    insert into public.purchase_request_events (request_id, actor, kind, title, detail)
    values (
      v_req.id, v_actor, 'payment_rejected', 'Pago reportado cerrado por la cancelación',
      jsonb_build_object('closed_reports', v_closed, 'reason', v_nota)
    );
  end if;

  insert into public.purchase_request_events (request_id, actor, kind, title, detail)
  values (
    v_req.id,
    v_actor,
    'status_changed',
    case v_target
      when 'comprado_amazon' then 'Comprado en Amazon'
      when 'en_almacen_usa'  then 'Recibido en almacén EE. UU.'
      when 'en_transito'     then 'En tránsito hacia Venezuela'
      when 'en_aduana'       then 'En aduana en Venezuela'
      when 'listo_entrega'   then 'Listo para entrega'
      when 'entregado'       then 'Entregado'
      when 'cancelado'       then 'Solicitud cancelada'
    end,
    jsonb_build_object(
      'from_status', v_from,
      'to_status', v_target,
      'amazon_order_id', v_req.amazon_order_id,
      'us_tracking_number', v_req.us_tracking_number,
      'note', v_nota,
      'closed_reports', v_closed
    )
  );

  perform audit.log(v_actor, 'purchase.status_advanced', v_req.id, jsonb_build_object(
    'request_number', v_req.request_number,
    'from_status', v_from,
    'to_status', v_target,
    'amazon_order_id', v_req.amazon_order_id,
    'us_tracking_number', v_req.us_tracking_number,
    'note', v_nota,
    'closed_reports', v_closed
  ));

  v_ref := public.helios_purchase_ref_text(v_req);
  v_msg := case v_target
    when 'comprado_amazon' then format(
      'Ya compramos %s en Amazon%s. Te aviso cuando llegue a nuestro almacén en EE. UU.',
      v_ref,
      case when v_req.amazon_order_id is not null then ' (orden ' || v_req.amazon_order_id || ')' else '' end
    )
    when 'en_almacen_usa' then format(
      '%s llegó a nuestro almacén en EE. UU.%s Pronto sale hacia Venezuela.',
      v_ref,
      case when v_req.us_tracking_number is not null then ' (guía ' || v_req.us_tracking_number || ').' else '.' end
    )
    when 'en_transito' then format(
      '%s va en camino a Venezuela %s Te aviso cuando llegue a aduana.',
      v_ref,
      case when v_req.shipping_method = 'maritimo' then '🚢.' else '✈️.' end
    )
    when 'en_aduana' then format(
      '%s llegó a Venezuela y está en aduana. Te aviso apenas esté listo.',
      v_ref
    )
    when 'listo_entrega' then format(
      '¡%s está listo para entrega! 🎉 Escríbenos por este chat para coordinar cómo lo recibes.',
      v_ref
    )
    when 'entregado' then format(
      '%s entregado. ¡Gracias por comprar con Helios!',
      v_ref
    )
    when 'cancelado' then format(
      E'Tu solicitud %s fue cancelada. Motivo: %s%s',
      v_ref,
      v_nota,
      case when v_closed > 0 or v_req.paid_at is not null
           then E'\nSi ya habías pagado, te contactamos para resolverlo.' else '' end
    )
  end;

  perform public.helios_purchase_notify(v_req, v_msg);

  return jsonb_build_object(
    'ok', true,
    'request_id', v_req.id,
    'request_number', v_req.request_number,
    'from_status', v_from,
    'status', v_req.status,
    'amazon_order_id', v_req.amazon_order_id,
    'us_tracking_number', v_req.us_tracking_number,
    'closed_reports', v_closed
  );
end;
$$;

create or replace function public.admin_purchase_settings_get()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return (
    select jsonb_build_object(
      'tax_usa_pct', s.tax_usa_pct,
      'service_fee_pct', s.service_fee_pct,
      'air_rate_per_lb_usd', s.air_rate_per_lb_usd,
      'air_min_usd', s.air_min_usd,
      'sea_rate_per_ft3_usd', s.sea_rate_per_ft3_usd,
      'sea_min_usd', s.sea_min_usd,
      'fallback_weight_lb', s.fallback_weight_lb,
      'quote_ttl_hours', s.quote_ttl_hours,
      'catalog_provider', s.catalog_provider,
      'is_enabled', s.is_enabled,
      'pilot_phones', to_jsonb(s.pilot_phones),
      'updated_at', s.updated_at,
      'updated_by', s.updated_by,
      'updated_by_name', case when s.updated_by is not null then
        (select pa.full_name from public.platform_admins pa where pa.user_id = s.updated_by) end,
      'fx_rate_usd', public.helios_fx_rate('USD')
    )
    from public.purchase_settings s
    where s.id
  );
end;
$$;

drop function if exists public.admin_purchase_settings_set(numeric, numeric, numeric, numeric, numeric, numeric, numeric, integer, text, boolean);

create or replace function public.admin_purchase_settings_set(
  p_tax_usa_pct          numeric,
  p_service_fee_pct      numeric,
  p_air_rate_per_lb_usd  numeric,
  p_air_min_usd          numeric,
  p_sea_rate_per_ft3_usd numeric,
  p_sea_min_usd          numeric,
  p_fallback_weight_lb   numeric,
  p_quote_ttl_hours      integer,
  p_catalog_provider     text,
  p_is_enabled           boolean,
  p_pilot_phones         text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('editar la configuración de compras Amazon');
  v_prov   text := lower(btrim(coalesce(p_catalog_provider, '')));
  v_pilot  text[];
  v_phone  text;
  v_before public.purchase_settings%rowtype;
  v_after  public.purchase_settings%rowtype;
begin
  if p_tax_usa_pct is null or p_tax_usa_pct < 0 or p_tax_usa_pct > 30 then
    raise exception 'El impuesto de EE. UU. debe estar entre 0 y 30%%' using errcode = '22023';
  end if;
  if p_service_fee_pct is null or p_service_fee_pct < 0 or p_service_fee_pct > 50 then
    raise exception 'La comisión de gestión debe estar entre 0 y 50%%' using errcode = '22023';
  end if;
  if p_air_rate_per_lb_usd is null or p_air_rate_per_lb_usd < 0
     or p_air_min_usd is null or p_air_min_usd < 0
     or p_sea_rate_per_ft3_usd is null or p_sea_rate_per_ft3_usd < 0
     or p_sea_min_usd is null or p_sea_min_usd < 0 then
    raise exception 'Las tarifas y mínimos de flete no pueden ser negativos' using errcode = '22023';
  end if;
  if p_fallback_weight_lb is null or p_fallback_weight_lb <= 0 then
    raise exception 'El peso de respaldo debe ser mayor que cero' using errcode = '22023';
  end if;
  if p_quote_ttl_hours is null or p_quote_ttl_hours < 1 or p_quote_ttl_hours > 168 then
    raise exception 'La vigencia de la cotización debe estar entre 1 y 168 horas' using errcode = '22023';
  end if;
  if v_prov not in ('mock', 'rainforest') then
    raise exception 'Proveedor de catálogo no válido: mock o rainforest'
      using errcode = '22023';
  end if;
  if p_is_enabled is null then
    raise exception 'Indica si el servicio está habilitado' using errcode = '22023';
  end if;
  if p_is_enabled and v_prov = 'mock' then
    raise exception 'El catálogo de prueba (mock) no se puede abrir a todos los médicos: usa rainforest o déjalo apagado y prueba con el piloto'
      using errcode = '22023';
  end if;

  if p_pilot_phones is not null then
    foreach v_phone in array p_pilot_phones loop
      if v_phone is null or btrim(v_phone) !~ '^\+[1-9][0-9]{7,14}$' then
        raise exception 'Teléfono del piloto no válido (usa el formato +584141234567): %', coalesce(v_phone, 'vacío')
          using errcode = '22023';
      end if;
    end loop;
    select coalesce(array_agg(distinct btrim(x) order by btrim(x)), '{}'::text[])
      into v_pilot
    from unnest(p_pilot_phones) as x;
  end if;

  select * into v_before from public.purchase_settings where id for update;

  update public.purchase_settings
     set tax_usa_pct = round(p_tax_usa_pct, 2),
         service_fee_pct = round(p_service_fee_pct, 2),
         air_rate_per_lb_usd = round(p_air_rate_per_lb_usd, 4),
         air_min_usd = round(p_air_min_usd, 4),
         sea_rate_per_ft3_usd = round(p_sea_rate_per_ft3_usd, 4),
         sea_min_usd = round(p_sea_min_usd, 4),
         fallback_weight_lb = round(p_fallback_weight_lb, 3),
         quote_ttl_hours = p_quote_ttl_hours,
         catalog_provider = v_prov,
         is_enabled = p_is_enabled,
         pilot_phones = coalesce(v_pilot, pilot_phones),
         updated_at = now(),
         updated_by = v_actor
   where id
  returning * into v_after;

  perform audit.log(v_actor, 'purchase_settings.updated', null, jsonb_build_object(
    'before', to_jsonb(v_before),
    'after', to_jsonb(v_after)
  ));

  return public.admin_purchase_settings_get();
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Simulador interno
-- ---------------------------------------------------------------------------

/** Autoriza a la Edge Function del simulador: solo un administrador de la plataforma. */
create or replace function public.admin_purchase_sim_autorizar()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;
  return auth.uid();
end;
$$;

/**
 * Los médicos activos, con el personal que tiene WhatsApp registrado. Además
 * del arreglo `staff_numbers`, cada médico trae `user_id`, `phone_e164` y
 * `staff_name` del número preferido (gerente primero, luego el más reciente),
 * que es el que el simulador usa por defecto.
 */
create or replace function public.admin_purchase_sim_merchants()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'merchant_id', m.id,
      'merchant_name', m.name,
      'status', m.status::text,
      'user_id', s.user_id,
      'phone_e164', s.phone_e164,
      'staff_name', case when s.user_id is not null then public.helios_staff_name(s.user_id) end,
      'staff_numbers', coalesce((
        select jsonb_agg(jsonb_build_object(
          'user_id', n.user_id,
          'staff_name', public.helios_staff_name(n.user_id),
          'phone_e164', n.phone_e164,
          'role', (
            select mu.role::text from public.merchant_users mu
            where mu.user_id = n.user_id and mu.merchant_id = n.merchant_id and mu.is_active
            order by (mu.role = 'gerente') desc limit 1
          )
        ) order by n.created_at desc)
        from public.staff_whatsapp_numbers n
        where n.merchant_id = m.id and n.revoked_at is null
      ), '[]'::jsonb)
    ) order by m.name asc)
    from public.merchants m
    left join lateral (
      select n.user_id, n.phone_e164
      from public.staff_whatsapp_numbers n
      where n.merchant_id = m.id and n.revoked_at is null
      order by exists (
        select 1 from public.merchant_users mu
        where mu.user_id = n.user_id and mu.merchant_id = n.merchant_id
          and mu.is_active and mu.role = 'gerente'
      ) desc, n.created_at desc
      limit 1
    ) s on true
    where m.status = 'active'
  ), '[]'::jsonb);
end;
$$;

/** I8: el simulador también deja rastro en la bitácora de admin. */
create or replace function public.admin_purchase_sim_append(
  p_phone     text,
  p_direction text,
  p_kind      text,
  p_body      text,
  p_payload   jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_phone text := coalesce(public.helios_wa_e164(p_phone), nullif(btrim(coalesce(p_phone, '')), ''));
  v_dir   text := lower(btrim(coalesce(p_direction, '')));
  v_kind  text := lower(btrim(coalesce(p_kind, 'text')));
  v_row   public.purchase_simulator_messages%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;
  if v_phone is null then
    raise exception 'Falta el número de teléfono del simulador' using errcode = '22023';
  end if;
  if v_dir not in ('in', 'out') then
    raise exception 'Dirección no válida: in u out' using errcode = '22023';
  end if;
  if v_kind not in ('text', 'buttons', 'carousel', 'list', 'image') then
    raise exception 'Tipo de mensaje no válido' using errcode = '22023';
  end if;

  insert into public.purchase_simulator_messages (phone_e164, direction, kind, body, payload)
  values (v_phone, v_dir, v_kind, coalesce(p_body, ''), coalesce(p_payload, '{}'::jsonb))
  returning * into v_row;

  perform audit.log(v_actor, 'purchase.sim_message_appended', v_row.id, jsonb_build_object(
    'phone_e164', v_phone,
    'direction', v_dir,
    'kind', v_kind
  ));

  return to_jsonb(v_row);
end;
$$;

/** Reinicia el simulador de un número: borra sus mensajes Y su sesión, y lo audita. */
create or replace function public.admin_purchase_sim_reset(p_phone text)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_phone text := coalesce(public.helios_wa_e164(p_phone), nullif(btrim(coalesce(p_phone, '')), ''));
  v_msgs  integer;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;
  if v_phone is null then
    raise exception 'Falta el número de teléfono del simulador' using errcode = '22023';
  end if;

  delete from public.purchase_simulator_messages where phone_e164 = v_phone;
  get diagnostics v_msgs = row_count;
  delete from public.purchase_simulator_sessions where phone_e164 = v_phone;

  perform audit.log(v_actor, 'purchase.sim_reset', null, jsonb_build_object(
    'phone_e164', v_phone,
    'messages_deleted', v_msgs
  ));
end;
$$;

/** Crea una solicitud de prueba desde el panel (no exige el servicio encendido). */
create or replace function public.admin_purchase_sim_create(
  p_merchant_id          uuid,
  p_phone                text,
  p_asin                 text,
  p_product_title        text,
  p_product_url          text default null,
  p_image_url            text default null,
  p_variant_label        text default null,
  p_quantity             integer default 1,
  p_category             text default null,
  p_weight_lb            numeric default null,
  p_volumetric_weight_lb numeric default null,
  p_volume_ft3           numeric default null,
  p_weight_estimated     boolean default false,
  p_restricted_flag      boolean default false,
  p_restricted_reason    text default null,
  p_shipping_method      text default 'aereo',
  p_unit_price_usd       numeric default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_phone text := coalesce(public.helios_wa_e164(p_phone), nullif(btrim(coalesce(p_phone, '')), ''));
  v_staff uuid;
  v_res   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_merchant_id is null or not exists (select 1 from public.merchants where id = p_merchant_id) then
    raise exception 'Clínica o comercio no encontrado' using errcode = 'P0002';
  end if;
  if v_phone is null then
    raise exception 'Falta el número de teléfono del simulador' using errcode = '22023';
  end if;

  select n.user_id into v_staff
  from public.staff_whatsapp_numbers n
  where n.merchant_id = p_merchant_id and n.phone_e164 = v_phone and n.revoked_at is null
  limit 1;

  v_res := public.helios_purchase_create_core(
    p_merchant_id, coalesce(v_staff, v_actor), v_phone, 'simulador', v_actor,
    p_asin, p_product_title, p_product_url, p_image_url, p_variant_label,
    p_quantity, p_category, p_weight_lb, p_volumetric_weight_lb, p_volume_ft3,
    p_weight_estimated, p_restricted_flag, p_restricted_reason, p_shipping_method,
    p_unit_price_usd, null, null
  );

  perform audit.log(v_actor, 'purchase.sim_created', (v_res ->> 'request_id')::uuid, jsonb_build_object(
    'request_number', (v_res ->> 'request_number')::integer,
    'merchant_id', p_merchant_id,
    'phone_e164', v_phone,
    'asin', v_res ->> 'asin',
    'total_usd', (v_res ->> 'total_usd')::numeric
  ));

  return v_res;
end;
$$;

/**
 * Reporta un pago de una solicitud del simulador como lo haría el médico, pero
 * con el ADMINISTRADOR como actor (`registered_by`): así el doble control
 * (`payment_four_eyes`) se aplica igual que con un pago real. Sin monto no se
 * inventa uno.
 */
create or replace function public.admin_purchase_sim_report_payment(
  p_request_id   uuid,
  p_method       text,
  p_bank         text,
  p_reference    text,
  p_payer_phone  text default null,
  p_amount_ves   numeric default null,
  p_receipt_path text default null,
  p_note         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_req   public.purchase_requests%rowtype;
  v_res   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_req from public.purchase_requests where id = p_request_id;
  if not found then
    raise exception 'Solicitud de compra no encontrada' using errcode = 'P0002';
  end if;
  if v_req.channel <> 'simulador' then
    raise exception 'Esta acción solo aplica a solicitudes del simulador' using errcode = '22023';
  end if;

  v_res := public.helios_purchase_register_payment_core(
    p_request_id, p_method, p_bank, p_reference,
    public.helios_business_date(now()),
    p_amount_ves, p_receipt_path, p_payer_phone, p_note,
    v_actor, null, true
  );

  perform audit.log(v_actor, 'purchase_payment.sim_reported', (v_res ->> 'report_id')::uuid, jsonb_build_object(
    'request_id', p_request_id,
    'request_number', v_req.request_number,
    'reference', p_reference,
    'declared_amount_ves', p_amount_ves
  ));

  return v_res;
end;
$$;

/** La sesión del simulador, con la MISMA vida que la del bot real (`bot_session_minutes`). */
create or replace function public.sim_compra_sesion(p_phone text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text := coalesce(public.helios_wa_e164(p_phone), nullif(btrim(coalesce(p_phone, '')), ''));
  v_s     public.purchase_simulator_sessions%rowtype;
begin
  if v_phone is null then
    raise exception 'Falta el número de teléfono del simulador' using errcode = '22023';
  end if;

  select * into v_s from public.purchase_simulator_sessions where phone_e164 = v_phone;
  if not found
     or v_s.updated_at < now() - make_interval(mins => public.helios_parameter('bot_session_minutes', 30)::integer) then
    return jsonb_build_object('state', 'menu', 'data', '{}'::jsonb, 'nueva', true);
  end if;
  return jsonb_build_object('state', v_s.state, 'data', v_s.data, 'nueva', false);
end;
$$;

create or replace function public.sim_compra_sesion_guardar(p_phone text, p_state text, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text := coalesce(public.helios_wa_e164(p_phone), nullif(btrim(coalesce(p_phone, '')), ''));
begin
  if v_phone is null then
    raise exception 'Falta el número de teléfono del simulador' using errcode = '22023';
  end if;

  insert into public.purchase_simulator_sessions (phone_e164, state, data, updated_at)
  values (v_phone, coalesce(nullif(btrim(coalesce(p_state, '')), ''), 'menu'), coalesce(p_data, '{}'::jsonb), now())
  on conflict (phone_e164) do update
    set state = excluded.state, data = excluded.data, updated_at = now();
end;
$$;

/**
 * Reinicia el simulador de un número desde la Edge Function (service_role):
 * borra sus mensajes y su sesión y deja constancia en `audit.admin_actions`
 * con el administrador que la Edge Function ya autorizó
 * (`admin_purchase_sim_autorizar` devuelve su uid).
 */
drop function if exists public.sim_compra_reiniciar(text);
create or replace function public.sim_compra_reiniciar(p_phone text, p_actor uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text := coalesce(public.helios_wa_e164(p_phone), nullif(btrim(coalesce(p_phone, '')), ''));
begin
  if v_phone is null then
    raise exception 'Falta el número de teléfono del simulador' using errcode = '22023';
  end if;
  if p_actor is null then
    raise exception 'Falta el administrador que reinicia el simulador' using errcode = '22023';
  end if;
  delete from public.purchase_simulator_messages where phone_e164 = v_phone;
  delete from public.purchase_simulator_sessions where phone_e164 = v_phone;
  perform audit.log(p_actor, 'purchase.sim_reset', null,
    jsonb_build_object('phone', v_phone, 'via', 'edge_function'));
end;
$$;

/**
 * La Edge Function escribe aquí los mensajes del simulador (entrantes y
 * salientes) con la forma canónica del payload:
 *   text → {} · buttons → {buttons:[{id,title}]} (1–3) ·
 *   carousel → {cards:[...]} (2–10) · list → {button, sections:[...]} ·
 *   image → {receipt_path}.
 */
create or replace function public.sim_compra_mensaje(
  p_phone     text,
  p_direction text,
  p_kind      text,
  p_body      text,
  p_payload   jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone   text := coalesce(public.helios_wa_e164(p_phone), nullif(btrim(coalesce(p_phone, '')), ''));
  v_dir     text := lower(btrim(coalesce(p_direction, '')));
  v_kind    text := lower(btrim(coalesce(p_kind, 'text')));
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_id      uuid;
begin
  if v_phone is null then
    raise exception 'Falta el número de teléfono del simulador' using errcode = '22023';
  end if;
  if v_dir not in ('in', 'out') then
    raise exception 'Dirección no válida: in u out' using errcode = '22023';
  end if;
  if v_kind not in ('text', 'buttons', 'carousel', 'list', 'image') then
    raise exception 'Tipo de mensaje no válido' using errcode = '22023';
  end if;
  if jsonb_typeof(v_payload) <> 'object' then
    raise exception 'El payload del mensaje debe ser un objeto' using errcode = '22023';
  end if;

  if v_kind = 'buttons'
     and public.helios_purchase_json_len(v_payload -> 'buttons') not between 1 and 3 then
    raise exception 'Un mensaje con botones lleva entre 1 y 3 botones' using errcode = '22023';
  end if;
  if v_kind = 'carousel'
     and public.helios_purchase_json_len(v_payload -> 'cards') not between 2 and 10 then
    raise exception 'Un carrusel lleva entre 2 y 10 tarjetas' using errcode = '22023';
  end if;
  if v_kind = 'list'
     and public.helios_purchase_json_len(v_payload -> 'sections') < 1 then
    raise exception 'Una lista lleva al menos una sección' using errcode = '22023';
  end if;
  if v_kind = 'image'
     and nullif(btrim(coalesce(v_payload ->> 'receipt_path', '')), '') is null then
    raise exception 'Una imagen del simulador lleva receipt_path' using errcode = '22023';
  end if;

  insert into public.purchase_simulator_messages (phone_e164, direction, kind, body, payload)
  values (v_phone, v_dir, v_kind, coalesce(p_body, ''), v_payload)
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Carrusel de WhatsApp: tarjetas validadas por su estructura (§5.9)
--    El literal de `type` de cada tarjeta NO se fija aquí: lo fija el bot
--    según la documentación de Meta. Una tarjeta rota se rechaza en vez de
--    mandarse rota.
-- ---------------------------------------------------------------------------

create or replace function public.helios_whatsapp_carousel(
  p_to            text,
  p_body          text,
  p_cards         jsonb,
  p_staff_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_card_body_max constant integer := 160;
  v_phone text := public.helios_wa_e164(p_to);
  v_id    uuid;
  v_card  jsonb;
  v_i     integer := 0;
begin
  if v_phone is null
     or nullif(btrim(coalesce(p_body, '')), '') is null
     or p_staff_user_id is null then
    raise exception 'Mensaje de carrusel incompleto' using errcode = '22023';
  end if;

  if public.helios_purchase_json_len(p_cards) not between 2 and 10 then
    raise exception 'El carrusel de WhatsApp requiere entre 2 y 10 tarjetas' using errcode = '22023';
  end if;

  for v_card in select value from jsonb_array_elements(p_cards) loop
    v_i := v_i + 1;
    if jsonb_typeof(v_card) is distinct from 'object'
       or nullif(btrim(coalesce(v_card #>> '{header,image,link}', '')), '') is null then
      raise exception 'La tarjeta % del carrusel no tiene imagen (header.image.link)', v_i
        using errcode = '22023';
    end if;
    if length(coalesce(v_card #>> '{body,text}', '')) > c_card_body_max then
      raise exception 'El texto de la tarjeta % supera los % caracteres', v_i, c_card_body_max
        using errcode = '22023';
    end if;
    if jsonb_typeof(v_card -> 'action') is distinct from 'object' then
      raise exception 'La tarjeta % del carrusel no tiene acción (action)', v_i
        using errcode = '22023';
    end if;
  end loop;

  if not public.helios_whatsapp_window_open(v_phone) then
    raise exception 'La ventana de 24 h de ese número está cerrada' using errcode = '22023';
  end if;

  insert into public.outbound_messages (
    channel, template_key, profile_id, recipient_staff_id, recipient,
    subject, rendered_text, status, next_attempt_at, wa_template
  ) values (
    'whatsapp', 'bot_respuesta', null, p_staff_user_id, v_phone,
    'Helios', left(p_body, 1024), 'pendiente', now(),
    jsonb_build_object(
      'kind', 'carousel',
      'name', null,
      'language', 'es',
      'params', '[]'::jsonb,
      'buttons', '[]'::jsonb,
      'cards', p_cards
    )
  )
  returning id into v_id;

  return v_id;
end;
$$;

/**
 * Encola una lista interactiva de WhatsApp (1..10 filas en total) a una
 * persona del personal dentro de su ventana de 24 h. Guarda en `wa_template`
 * {kind:'list', button, sections:[{title, rows:[{id,title,description}]}]},
 * que es lo que lee `helios_whatsapp_payload`. Igual que el carrusel, una
 * lista fuera de los límites de Meta se rechaza en vez de mandarse rota.
 */
create or replace function public.helios_whatsapp_list(
  p_to            text,
  p_body          text,
  p_button        text,
  p_sections      jsonb,
  p_staff_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text := public.helios_wa_e164(p_to);
  v_id    uuid;
  v_sec   jsonb;
  v_row   jsonb;
  v_rows  jsonb;
  v_total integer := 0;
  v_n     integer;
begin
  if v_phone is null
     or nullif(btrim(coalesce(p_body, '')), '') is null
     or nullif(btrim(coalesce(p_button, '')), '') is null
     or p_staff_user_id is null then
    raise exception 'Mensaje de lista incompleto' using errcode = '22023';
  end if;
  if length(btrim(p_button)) > 20 then
    raise exception 'El botón de la lista supera los 20 caracteres' using errcode = '22023';
  end if;
  if public.helios_purchase_json_len(p_sections) not between 1 and 10 then
    raise exception 'La lista de WhatsApp requiere entre 1 y 10 secciones' using errcode = '22023';
  end if;

  for v_sec in select value from jsonb_array_elements(p_sections) loop
    if jsonb_typeof(v_sec) is distinct from 'object' then
      raise exception 'Una sección de la lista no es válida' using errcode = '22023';
    end if;
    if length(coalesce(v_sec ->> 'title', '')) > 24 then
      raise exception 'El título de una sección supera los 24 caracteres' using errcode = '22023';
    end if;
    v_rows := v_sec -> 'rows';
    v_n := public.helios_purchase_json_len(v_rows);
    if v_n < 1 then
      raise exception 'Cada sección de la lista necesita al menos una fila' using errcode = '22023';
    end if;
    v_total := v_total + v_n;
    for v_row in select value from jsonb_array_elements(v_rows) loop
      if jsonb_typeof(v_row) is distinct from 'object'
         or nullif(btrim(coalesce(v_row ->> 'id', '')), '') is null
         or nullif(btrim(coalesce(v_row ->> 'title', '')), '') is null then
        raise exception 'Una fila de la lista necesita id y título' using errcode = '22023';
      end if;
      if length(v_row ->> 'id') > 200 then
        raise exception 'El id de una fila supera los 200 caracteres' using errcode = '22023';
      end if;
      if length(v_row ->> 'title') > 24 then
        raise exception 'El título de una fila supera los 24 caracteres' using errcode = '22023';
      end if;
      if length(coalesce(v_row ->> 'description', '')) > 72 then
        raise exception 'La descripción de una fila supera los 72 caracteres' using errcode = '22023';
      end if;
    end loop;
  end loop;
  if v_total not between 1 and 10 then
    raise exception 'La lista de WhatsApp admite hasta 10 filas en total' using errcode = '22023';
  end if;

  if not public.helios_whatsapp_window_open(v_phone) then
    raise exception 'La ventana de 24 h de ese número está cerrada' using errcode = '22023';
  end if;

  insert into public.outbound_messages (
    channel, template_key, profile_id, recipient_staff_id, recipient,
    subject, rendered_text, status, next_attempt_at, wa_template
  ) values (
    'whatsapp', 'bot_respuesta', null, p_staff_user_id, v_phone,
    'Helios', left(p_body, 1024), 'pendiente', now(),
    jsonb_build_object(
      'kind', 'list',
      'name', null,
      'language', 'es',
      'params', '[]'::jsonb,
      'buttons', '[]'::jsonb,
      'button', btrim(p_button),
      'sections', p_sections
    )
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8b. «Avisos de hoy» lista también los avisos al personal (sin paciente)
--     La cola unía `profiles` con join interno: un aviso con
--     `recipient_staff_id` y sin `profile_id` (el de compras al médico fuera
--     de la ventana de 24 h, que el despachador pasa a `whatsapp_manual`)
--     nunca aparecía. Misma firma y mismas columnas; la diferencia es el
--     `left join profiles` y que, sin paciente, `patient_name` es el nombre
--     de la persona del personal. Para los avisos a pacientes no cambia nada.
-- ---------------------------------------------------------------------------

create or replace function public.admin_outbound_queue(
  p_day     date default null,
  p_channel text default 'whatsapp_manual'
)
returns table (
  id             uuid,
  channel        text,
  template_key   text,
  template_label text,
  profile_id     uuid,
  patient_name   text,
  phone_e164     text,
  charge_id      uuid,
  order_number   bigint,
  due_date       date,
  rendered_text  text,
  status         text,
  created_at     timestamptz,
  sent_at        timestamptz,
  sent_by_name   text,
  whatsapp_url   text,
  recipient      text,
  last_error     text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := public.helios_business_date(now());
  v_day   date;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_day := coalesce(p_day, v_today);

  return query
  select
    o.id, o.channel, o.template_key, t.label,
    o.profile_id,
    case when o.profile_id is null and o.recipient_staff_id is not null
         then public.helios_staff_name(o.recipient_staff_id)
         else coalesce(nullif(btrim(p.full_name), ''), btrim(concat_ws(' ', p.first_name, p.last_name)))
    end,
    coalesce(case when o.channel = 'whatsapp_manual' then o.recipient end, p.phone_e164),
    o.charge_id, c.order_number, o.installment_due_date,
    o.rendered_text, o.status, o.created_at, o.sent_at,
    case when o.sent_by is not null then coalesce(pa.full_name, 'Alguien del equipo') end,
    case when o.channel = 'whatsapp_manual'
         then public.helios_whatsapp_url(coalesce(o.recipient, p.phone_e164), o.rendered_text) end,
    o.recipient, o.last_error
  from public.outbound_messages o
  join public.notification_templates t on t.key = o.template_key
  left join public.profiles p on p.id = o.profile_id
  left join public.charges c on c.id = o.charge_id
  left join public.platform_admins pa on pa.user_id = o.sent_by
  where (p_channel is null or o.channel = p_channel)
    and (
      public.helios_business_date(o.created_at) = v_day
      or (v_day = v_today and o.status = 'pendiente'
          and public.helios_business_date(o.created_at) < v_day)
    )
  order by t.sort_order, o.created_at, o.id;
end;
$$;

revoke all on function public.admin_outbound_queue(date, text) from public, anon;
grant execute on function public.admin_outbound_queue(date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Permisos explícitos
-- ---------------------------------------------------------------------------

revoke all on function public.helios_whatsapp_carousel(text, text, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.helios_whatsapp_carousel(text, text, jsonb, uuid) to service_role;

-- Bot (service_role)
revoke all on function public.bot_compra_habilitada(text) from public, anon, authenticated;
revoke all on function public.bot_compra_cache_set(text, text, text, jsonb, integer) from public, anon, authenticated;
revoke all on function public.bot_compra_crear(text, text, text, text, text, text, integer, text, numeric, numeric, numeric, boolean, boolean, text, text, numeric, text, text, numeric) from public, anon, authenticated;
revoke all on function public.bot_compra_mis_solicitudes(text, integer, text) from public, anon, authenticated;
revoke all on function public.bot_compra_pendiente_de_pago(text, text) from public, anon, authenticated;
revoke all on function public.bot_compra_detalle(text, uuid, text) from public, anon, authenticated;
revoke all on function public.bot_compra_reportar_pago(text, uuid, text, text, text, text, numeric, text, text, text, text) from public, anon, authenticated;
revoke all on function public.bot_compra_cancelar(text, uuid, text) from public, anon, authenticated;
revoke all on function public.bot_compra_recotizar(text, uuid, text) from public, anon, authenticated;
revoke all on function public.bot_compra_pedir_persona(text, uuid, text) from public, anon, authenticated;
revoke all on function public.sim_compra_sesion(text) from public, anon, authenticated;
revoke all on function public.sim_compra_sesion_guardar(text, text, jsonb) from public, anon, authenticated;
revoke all on function public.sim_compra_mensaje(text, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.sim_compra_reiniciar(text, uuid) from public, anon, authenticated;
grant execute on function public.sim_compra_reiniciar(text, uuid) to service_role;
revoke all on function public.helios_whatsapp_list(text, text, text, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.helios_whatsapp_list(text, text, text, jsonb, uuid) to service_role;

grant execute on function public.bot_compra_habilitada(text) to service_role;
grant execute on function public.bot_compra_cache_set(text, text, text, jsonb, integer) to service_role;
grant execute on function public.bot_compra_crear(text, text, text, text, text, text, integer, text, numeric, numeric, numeric, boolean, boolean, text, text, numeric, text, text, numeric) to service_role;
grant execute on function public.bot_compra_mis_solicitudes(text, integer, text) to service_role;
grant execute on function public.bot_compra_pendiente_de_pago(text, text) to service_role;
grant execute on function public.bot_compra_detalle(text, uuid, text) to service_role;
grant execute on function public.bot_compra_reportar_pago(text, uuid, text, text, text, text, numeric, text, text, text, text) to service_role;
grant execute on function public.bot_compra_cancelar(text, uuid, text) to service_role;
grant execute on function public.bot_compra_recotizar(text, uuid, text) to service_role;
grant execute on function public.bot_compra_pedir_persona(text, uuid, text) to service_role;
grant execute on function public.sim_compra_sesion(text) to service_role;
grant execute on function public.sim_compra_sesion_guardar(text, text, jsonb) to service_role;
grant execute on function public.sim_compra_mensaje(text, text, text, text, jsonb) to service_role;

-- Administración (authenticated; cada una verifica is_platform_admin() / super admin)
revoke all on function public.admin_purchase_list(text[], text, text, integer) from public, anon;
revoke all on function public.admin_purchase_detail(uuid) from public, anon;
revoke all on function public.admin_purchase_counts() from public, anon;
revoke all on function public.admin_purchase_payment_queue(text[], integer) from public, anon;
revoke all on function public.admin_purchase_register_payment(uuid, text, text, text, date, numeric, text, text, text) from public, anon;
revoke all on function public.admin_purchase_reconcile_payment(uuid, boolean, text) from public, anon;
revoke all on function public.admin_purchase_flag_payment(uuid, text) from public, anon;
revoke all on function public.admin_purchase_mark_payment_duplicate(uuid, text) from public, anon;
revoke all on function public.admin_purchase_approve_customs(uuid, boolean, text) from public, anon;
revoke all on function public.admin_purchase_advance_status(uuid, text, text, text, text) from public, anon;
revoke all on function public.admin_purchase_settings_get() from public, anon;
revoke all on function public.admin_purchase_settings_set(numeric, numeric, numeric, numeric, numeric, numeric, numeric, integer, text, boolean, text[]) from public, anon;
revoke all on function public.admin_purchase_sim_autorizar() from public, anon;
revoke all on function public.admin_purchase_sim_merchants() from public, anon;
revoke all on function public.admin_purchase_sim_append(text, text, text, text, jsonb) from public, anon;
revoke all on function public.admin_purchase_sim_reset(text) from public, anon;
revoke all on function public.admin_purchase_sim_create(uuid, text, text, text, text, text, text, integer, text, numeric, numeric, numeric, boolean, boolean, text, text, numeric) from public, anon;
revoke all on function public.admin_purchase_sim_report_payment(uuid, text, text, text, text, numeric, text, text) from public, anon;

grant execute on function public.admin_purchase_list(text[], text, text, integer) to authenticated;
grant execute on function public.admin_purchase_detail(uuid) to authenticated;
grant execute on function public.admin_purchase_counts() to authenticated;
grant execute on function public.admin_purchase_payment_queue(text[], integer) to authenticated;
grant execute on function public.admin_purchase_register_payment(uuid, text, text, text, date, numeric, text, text, text) to authenticated;
grant execute on function public.admin_purchase_reconcile_payment(uuid, boolean, text) to authenticated;
grant execute on function public.admin_purchase_flag_payment(uuid, text) to authenticated;
grant execute on function public.admin_purchase_mark_payment_duplicate(uuid, text) to authenticated;
grant execute on function public.admin_purchase_approve_customs(uuid, boolean, text) to authenticated;
grant execute on function public.admin_purchase_advance_status(uuid, text, text, text, text) to authenticated;
grant execute on function public.admin_purchase_settings_get() to authenticated;
grant execute on function public.admin_purchase_settings_set(numeric, numeric, numeric, numeric, numeric, numeric, numeric, integer, text, boolean, text[]) to authenticated;
grant execute on function public.admin_purchase_sim_autorizar() to authenticated;
grant execute on function public.admin_purchase_sim_merchants() to authenticated;
grant execute on function public.admin_purchase_sim_append(text, text, text, text, jsonb) to authenticated;
grant execute on function public.admin_purchase_sim_reset(text) to authenticated;
grant execute on function public.admin_purchase_sim_create(uuid, text, text, text, text, text, text, integer, text, numeric, numeric, numeric, boolean, boolean, text, text, numeric) to authenticated;
grant execute on function public.admin_purchase_sim_report_payment(uuid, text, text, text, text, numeric, text, text) to authenticated;
-- admin_purchase_payment_preview, admin_purchase_sim_messages y admin_purchase_sim_requests
-- no cambian: conservan sus permisos de la migración original.
