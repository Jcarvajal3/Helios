-- ============================================================================
-- Helios — Compras Amazon: limpieza (2026-11-25)
--
--  1. «La más reciente» determinista: varias solicitudes pueden compartir el
--     mismo `created_at` (misma transacción, o dos mensajes del médico en el
--     mismo instante), y `order by created_at desc limit 1` elegía una al
--     azar. Se añade un desempate estable (`request_number` / `id`) a toda
--     búsqueda o listado de compras que ordene por fecha.
--  2. Se retira el carrusel de WhatsApp: el carrusel interactivo sin plantilla
--     exige un `type` por tarjeta y solo existe `cta_url`, que no puede
--     seleccionar un producto. El bot ya no lo llama; el flujo usa la lista.
--  3. El simulador deja de aceptar `carousel`.
--  4. Limpieza de datos: tres carruseles que 360dialog rechazó quedaron
--     atascados en la cola manual del equipo (el médico ya recibió la lista).
--  5. Teléfonos del piloto robustos: se normalizan al guardar y al comparar
--     (el administrador escribió +5804149783031 —con el 0 del troncal— y
--     nunca coincidía con +584149783031), y el panel ve quién está registrado.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 5a. Teléfono venezolano del piloto, con el 0 del troncal tolerado
--     `helios_normalize_ve_phone` acepta 04XX…, 4XX… y +584XX…, pero no
--     +5804XX… (13 dígitos). Aquí se quita ese 0 antes de delegar en ella.
-- ---------------------------------------------------------------------------

create or replace function public.helios_purchase_pilot_phone(p_phone text)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if v_digits ~ '^580[0-9]{10}$' then
    v_digits := '58' || substr(v_digits, 4);
  end if;
  return public.helios_normalize_ve_phone(v_digits);
end;
$$;

revoke all on function public.helios_purchase_pilot_phone(text) from public, anon, authenticated;

-- Lo ya guardado se normaliza; lo que no sea un teléfono venezolano válido se descarta.
update public.purchase_settings
   set pilot_phones = coalesce((
         select array_agg(distinct x.n order by x.n)
         from unnest(purchase_settings.pilot_phones) as p
         cross join lateral (select public.helios_purchase_pilot_phone(p) as n) x
         where x.n is not null
       ), '{}'::text[])
 where id;

-- ---------------------------------------------------------------------------
-- 2. Fuera el carrusel de WhatsApp
-- ---------------------------------------------------------------------------

drop function if exists public.helios_whatsapp_carousel(text, text, jsonb, uuid);

/**
 * Construye el cuerpo para POST /messages de la Cloud API a partir de una fila
 * de `outbound_messages`, o null si no se puede enviar por la API:
 *
 *   · ventana abierta y `kind = 'list'` (con secciones)   → `interactive` list;
 *   · ventana abierta, sin botones                        → texto (`rendered_text`);
 *   · ventana abierta, con botones (<= 1024 chars)        → `interactive` button;
 *   · ventana cerrada (o texto > 1024 con botones)        → plantilla de Meta si tiene `name`;
 *   · si no                                               → null (cola manual).
 *
 * Ya no existe el `kind = 'carousel'`: una fila vieja de ese tipo cae en las
 * ramas de siempre (texto con su `rendered_text`).
 */
create or replace function public.helios_whatsapp_payload(p_msg public.outbound_messages)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_to          text := regexp_replace(coalesce(p_msg.recipient, ''), '\D', '', 'g');
  v_wa          jsonb := coalesce(p_msg.wa_template, '{}'::jsonb);
  v_kind        text := nullif(btrim(coalesce(v_wa ->> 'kind', '')), '');
  v_buttons     jsonb := coalesce(v_wa -> 'buttons', '[]'::jsonb);
  v_open        boolean := public.helios_whatsapp_window_open(p_msg.recipient);
  v_sections    jsonb;
  v_list_button text;
  v_interactive jsonb;
  v_comp        jsonb;
begin
  -- Lista interactiva dentro de ventana abierta
  if v_open and v_kind = 'list' then
    v_sections := coalesce(v_wa -> 'sections', v_wa -> 'action' -> 'sections');
    if v_sections is not null
       and jsonb_typeof(v_sections) = 'array'
       and jsonb_array_length(v_sections) >= 1 then
      v_list_button := left(
        coalesce(
          nullif(btrim(v_wa ->> 'button'), ''),
          nullif(btrim(v_wa -> 'action' ->> 'button'), ''),
          'Ver opciones'
        ),
        20
      );
      v_interactive := jsonb_build_object(
        'type', 'list',
        'body', jsonb_build_object('text', left(p_msg.rendered_text, 1024)),
        'action', jsonb_build_object(
          'button', v_list_button,
          'sections', v_sections
        )
      );
      if nullif(btrim(coalesce(v_wa ->> 'header', '')), '') is not null then
        v_interactive := v_interactive || jsonb_build_object(
          'header', jsonb_build_object('type', 'text', 'text', left(btrim(v_wa ->> 'header'), 60))
        );
      end if;
      if nullif(btrim(coalesce(v_wa ->> 'footer', '')), '') is not null then
        v_interactive := v_interactive || jsonb_build_object(
          'footer', jsonb_build_object('text', left(btrim(v_wa ->> 'footer'), 60))
        );
      end if;
      return jsonb_build_object(
        'messaging_product', 'whatsapp',
        'recipient_type', 'individual',
        'to', v_to,
        'type', 'interactive',
        'interactive', v_interactive
      );
    end if;
  end if;

  -- Lógica existente intacta: texto, botones interactivos y plantilla
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

-- ---------------------------------------------------------------------------
-- 3. Simulador: sin `carousel`
--    En producción no hay filas de ese tipo, así que la restricción se aprieta
--    sin tocar datos. El nombre es el que Postgres le puso a la inline.
-- ---------------------------------------------------------------------------

alter table public.purchase_simulator_messages
  drop constraint if exists purchase_simulator_messages_kind_check;
alter table public.purchase_simulator_messages
  add constraint purchase_simulator_messages_kind_check
  check (kind in ('text', 'buttons', 'list', 'image'));

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
  if v_kind not in ('text', 'buttons', 'list', 'image') then
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

/**
 * La Edge Function escribe aquí los mensajes del simulador (entrantes y
 * salientes) con la forma canónica del payload:
 *   text → {} · buttons → {buttons:[{id,title}]} (1–3) ·
 *   list → {button, sections:[...]} · image → {receipt_path}.
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
  if v_kind not in ('text', 'buttons', 'list', 'image') then
    raise exception 'Tipo de mensaje no válido' using errcode = '22023';
  end if;
  if jsonb_typeof(v_payload) <> 'object' then
    raise exception 'El payload del mensaje debe ser un objeto' using errcode = '22023';
  end if;

  if v_kind = 'buttons'
     and public.helios_purchase_json_len(v_payload -> 'buttons') not between 1 and 3 then
    raise exception 'Un mensaje con botones lleva entre 1 y 3 botones' using errcode = '22023';
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
-- 4. Los tres carruseles atascados en la cola manual
--    360dialog los rechazó y el médico ya recibió la versión en lista: no hay
--    nada que reenviar a mano. Se acota estrictamente por las tres condiciones.
-- ---------------------------------------------------------------------------

update public.outbound_messages
   set status = 'omitido',
       last_error = concat_ws(' · ', nullif(btrim(coalesce(last_error, '')), ''),
         'Carrusel retirado: el médico ya recibió la versión en lista; no hay que reenviarlo')
 where wa_template ->> 'kind' = 'carousel'
   and channel = 'whatsapp_manual'
   and status = 'pendiente';

-- ---------------------------------------------------------------------------
-- 1. «La más reciente» con desempate estable
-- ---------------------------------------------------------------------------

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
      order by r.created_at desc, r.id desc limit 1
    ),
    'open_payment_status', (
      select r.status from public.purchase_payment_reports r
      where r.request_id = pr.id and r.status in ('reported', 'in_review')
      order by r.created_at desc, r.id desc limit 1
    )
  )
  from public.purchase_requests pr
  join public.merchants m on m.id = pr.merchant_id
  where pr.id = p_request_id;
$$;

/** M4: solo lo que el médico necesita ver. Solo las del canal indicado (el simulador no se mezcla con las reales). */
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
    select jsonb_agg(q.v order by q.ca desc, q.rn desc)
    from (
      select public.helios_purchase_bot_view(pr) as v, pr.created_at as ca, pr.request_number as rn
      from public.purchase_requests pr
      where pr.phone_e164 = v_n.phone_e164
        and pr.channel = lower(btrim(p_channel))
      order by pr.created_at desc, pr.request_number desc
      limit v_lim
    ) q
  ), '[]'::jsonb);
end;
$$;

/** La solicitud más reciente del canal que espera pago (con la cotización vencida o no). */
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
  order by created_at desc, request_number desc
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
             ) order by e.created_at desc, e.id desc)
      from (
        select ev.id, ev.kind, ev.created_at, ev.detail
        from public.purchase_request_events ev
        where ev.request_id = v_req.id
          and ev.kind in (
            'created', 'payment_reported', 'payment_reconciled', 'payment_rejected',
            'customs_approved', 'customs_rejected', 'status_changed', 'requoted',
            'cancelled_by_user'
          )
        order by ev.created_at desc, ev.id desc
        limit c_events_shown
      ) e
    ), '[]'::jsonb)
  );
end;
$$;

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
    select jsonb_agg(public.helios_purchase_request_summary(r.id) order by r.created_at desc, r.request_number desc)
    from (
      select pr.id, pr.created_at, pr.request_number
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
      order by pr.created_at desc, pr.request_number desc
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
      select jsonb_agg(public.helios_purchase_payment_item(r.id) order by r.created_at desc, r.id desc)
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
    select jsonb_agg(public.helios_purchase_payment_item(q.id) order by q.in_review desc, q.created_at asc, q.id asc)
    from (
      select r.id, (r.status = 'in_review') as in_review, r.created_at
      from public.purchase_payment_reports r
      where r.status = any(v_statuses)
      order by (r.status = 'in_review') desc, r.created_at asc, r.id asc
      limit v_lim
    ) q
  ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_purchase_sim_requests(p_phone text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text := coalesce(public.helios_wa_e164(p_phone), nullif(btrim(coalesce(p_phone, '')), ''));
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;
  if v_phone is null then
    raise exception 'Falta el número de teléfono del simulador' using errcode = '22023';
  end if;

  return coalesce((
    select jsonb_agg(public.helios_purchase_request_summary(r.id) order by r.created_at desc, r.request_number desc)
    from (
      select id, created_at, request_number from public.purchase_requests
      where phone_e164 = v_phone
        and channel = 'simulador'
      order by created_at desc, request_number desc
      limit 30
    ) r
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5b. Piloto: se compara y se guarda normalizado; el panel ve quién está registrado
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
  v_phone text := coalesce(public.helios_purchase_pilot_phone(p_phone), public.helios_wa_e164(p_phone));
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
      -- Para cada número del piloto: ¿hay alguien del personal con ese
      -- WhatsApp activo? Sin eso el número «está» pero el bot no lo reconoce.
      'pilot_status', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'phone', p.phone,
                 'registrado', n.user_id is not null,
                 'nombre', case when n.user_id is not null then public.helios_staff_name(n.user_id) end
               ) order by p.phone)
        from unnest(s.pilot_phones) as p(phone)
        left join public.staff_whatsapp_numbers n
               on n.phone_e164 = p.phone and n.revoked_at is null
      ), '[]'::jsonb),
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
  v_norm   text;
  v_list   text[] := '{}';
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

  -- Cada teléfono del piloto se normaliza (04141234567, +5804141234567 y
  -- 0414-123-4567 son el mismo número) y se deduplica; uno que no sea
  -- venezolano válido se rechaza en vez de guardarse sin coincidir nunca.
  if p_pilot_phones is not null then
    foreach v_phone in array p_pilot_phones loop
      v_norm := public.helios_purchase_pilot_phone(v_phone);
      if v_norm is null then
        raise exception 'telefono_piloto_invalido: %', coalesce(nullif(btrim(v_phone), ''), 'vacío')
          using errcode = '22023';
      end if;
      v_list := v_list || v_norm;
    end loop;
    select coalesce(array_agg(distinct x order by x), '{}'::text[])
      into v_pilot
    from unnest(v_list) as x;
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
