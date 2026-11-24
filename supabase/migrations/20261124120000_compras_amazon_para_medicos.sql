-- ============================================================================
-- Helios — Compras Amazon para Médicos (2026-11-24)
--
-- Servicio de compras asistidas en Amazon EE. UU. para médicos y personal de
-- clínicas aliadas:
--
--  1. Extensión retrocompatible de `helios_whatsapp_payload` para mensajes
--     interactivos de tipo `carousel` (2..10 tarjetas) y `list` dentro de la
--     ventana de 24 h, más `helios_whatsapp_carousel`.
--  2. Tablas aditivas con RLS habilitado y sin acceso directo a `anon` ni
--     `authenticated`:
--       · `purchase_settings` (tarifas, impuestos, fletes, proveedor y estado)
--       · `amazon_catalog_cache` (caché de búsquedas y fichas de producto)
--       · `purchase_requests` (solicitudes de compra y trazabilidad logística)
--       · `purchase_payment_reports` (reportes de pago en bolívares)
--       · `purchase_request_events` (bitácora append-only por solicitud)
--       · `purchase_simulator_messages` (chat aislado del simulador interno)
--  3. Motores internos de cálculo en `numeric(18,4)`/`numeric(18,2)`, bloque
--     de pago reutilizando `helios_payment_accounts_block()` (sin titular),
--     notificación aislada (`simulador` nunca toca `outbound_messages`) y
--     registro/conciliación de pagos con doble control (`payment_four_eyes`)
--     y margen de monto (`helios_monto_cuadra`).
--  4. RPCs del bot (`service_role`) y del panel de administración
--     (`authenticated`, verificando `is_platform_admin()` o
--     `helios_assert_super_admin()` + `audit.log`).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. WhatsApp Cloud API: carrusel y lista (retrocompatible)
-- ---------------------------------------------------------------------------

/**
 * 🔁 Extendida (20261005000400). Construye el cuerpo para POST /messages de la
 * Cloud API a partir de una fila de `outbound_messages`, o null si no se puede
 * enviar por la API:
 *
 *   · ventana abierta y `kind = 'carousel'` (2..10 cards) → `interactive` carousel;
 *   · ventana abierta y `kind = 'list'` (con secciones)   → `interactive` list;
 *   · ventana abierta, sin botones                        → texto (`rendered_text`);
 *   · ventana abierta, con botones (<= 1024 chars)        → `interactive` button;
 *   · ventana cerrada (o texto > 1024 con botones)        → plantilla de Meta si tiene `name`;
 *   · si no                                               → null (cola manual).
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
  v_cards       jsonb;
  v_sections    jsonb;
  v_list_button text;
  v_interactive jsonb;
  v_comp        jsonb;
begin
  -- Carrusel interactivo (2..10 tarjetas) dentro de ventana abierta
  if v_open and v_kind = 'carousel' then
    v_cards := v_wa -> 'cards';
    if v_cards is not null
       and jsonb_typeof(v_cards) = 'array'
       and jsonb_array_length(v_cards) between 2 and 10 then
      return jsonb_build_object(
        'messaging_product', 'whatsapp',
        'recipient_type', 'individual',
        'to', v_to,
        'type', 'interactive',
        'interactive', jsonb_build_object(
          'type', 'carousel',
          'body', jsonb_build_object('text', left(p_msg.rendered_text, 1024)),
          'action', jsonb_build_object('cards', v_cards)
        )
      );
    end if;
  end if;

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

/**
 * Encola un carrusel interactivo de WhatsApp (2..10 tarjetas) a una persona
 * del personal dentro de su ventana de 24 h.
 */
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
  v_phone text := public.helios_wa_e164(p_to);
  v_id    uuid;
begin
  if v_phone is null
     or nullif(btrim(coalesce(p_body, '')), '') is null
     or p_staff_user_id is null then
    raise exception 'Mensaje de carrusel incompleto' using errcode = '22023';
  end if;

  if p_cards is null
     or jsonb_typeof(p_cards) <> 'array'
     or jsonb_array_length(p_cards) not between 2 and 10 then
    raise exception 'El carrusel de WhatsApp requiere entre 2 y 10 tarjetas' using errcode = '22023';
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

revoke all on function public.helios_whatsapp_carousel(text, text, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.helios_whatsapp_carousel(text, text, jsonb, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Tablas del módulo de Compras Amazon (RLS + sin acceso directo)
-- ---------------------------------------------------------------------------

create table public.purchase_settings (
  id                   boolean primary key default true check (id),
  tax_usa_pct          numeric(5,2) not null default 7.00 check (tax_usa_pct between 0 and 30),
  service_fee_pct      numeric(5,2) not null default 10.00 check (service_fee_pct between 0 and 50),
  air_rate_per_lb_usd  numeric(18,4) not null default 6.5000 check (air_rate_per_lb_usd >= 0),
  air_min_usd          numeric(18,4) not null default 15.0000 check (air_min_usd >= 0),
  sea_rate_per_ft3_usd numeric(18,4) not null default 28.0000 check (sea_rate_per_ft3_usd >= 0),
  sea_min_usd          numeric(18,4) not null default 35.0000 check (sea_min_usd >= 0),
  fallback_weight_lb   numeric(10,3) not null default 1.500 check (fallback_weight_lb > 0),
  quote_ttl_hours      integer not null default 24 check (quote_ttl_hours between 1 and 168),
  catalog_provider     text not null default 'mock' check (catalog_provider in ('mock', 'rainforest', 'oxylabs', 'rapidapi')),
  is_enabled           boolean not null default true,
  updated_at           timestamptz not null default now(),
  updated_by           uuid references auth.users(id)
);

comment on table public.purchase_settings is
  'Configuración única de tarifas, fletes, vigencia de cotización y proveedor de catálogo para Compras Amazon.';

insert into public.purchase_settings (id) values (true) on conflict (id) do nothing;

alter table public.purchase_settings enable row level security;
revoke all on public.purchase_settings from anon, authenticated;

create table public.amazon_catalog_cache (
  cache_key  text primary key,
  kind       text not null check (kind in ('search', 'product')),
  provider   text not null,
  payload    jsonb not null,
  fetched_at timestamptz not null default now(),
  expires_at timestamptz not null
);

comment on table public.amazon_catalog_cache is
  'Caché temporal de búsquedas y fichas de producto de Amazon consultadas por el bot.';

create index amazon_catalog_cache_expires_idx
  on public.amazon_catalog_cache (expires_at);

alter table public.amazon_catalog_cache enable row level security;
revoke all on public.amazon_catalog_cache from anon, authenticated;

create table public.purchase_requests (
  id                   uuid primary key default gen_random_uuid(),
  request_number       integer generated by default as identity (start with 1001) unique not null,
  merchant_id          uuid not null references public.merchants(id),
  requested_by         uuid references auth.users(id),
  phone_e164           text not null,
  channel              text not null default 'whatsapp' check (channel in ('whatsapp', 'simulador')),
  asin                 text not null,
  product_title        text not null,
  product_url          text,
  image_url            text,
  variant_label        text,
  quantity             integer not null default 1 check (quantity between 1 and 50),
  category             text,
  weight_lb            numeric(10,3),
  volumetric_weight_lb numeric(10,3),
  volume_ft3           numeric(10,4),
  weight_estimated     boolean not null default false,
  restricted_flag      boolean not null default false,
  restricted_reason    text,
  shipping_method      text not null default 'aereo' check (shipping_method in ('aereo', 'maritimo')),
  unit_price_usd       numeric(18,4) not null check (unit_price_usd > 0),
  subtotal_usd         numeric(18,4) not null,
  tax_usa_usd          numeric(18,4) not null,
  shipping_usd         numeric(18,4) not null,
  service_fee_usd      numeric(18,4) not null,
  total_usd            numeric(18,4) not null check (total_usd > 0),
  quoted_fx_rate       numeric(18,6) not null,
  quoted_ves           numeric(18,2) not null,
  quote_expires_at     timestamptz not null,
  status               text not null default 'esperando_pago' check (status in (
    'revision_aduanal', 'esperando_pago', 'pago_reportado', 'pagado',
    'comprado_amazon', 'en_almacen_usa', 'en_transito', 'en_aduana',
    'listo_entrega', 'entregado', 'cancelado'
  )),
  amazon_order_id      text,
  us_tracking_number   text,
  delivery_address     text,
  internal_notes       text,
  cancel_reason        text,
  paid_at              timestamptz,
  purchased_at         timestamptz,
  delivered_at         timestamptz,
  cancelled_at         timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

comment on table public.purchase_requests is
  'Solicitudes de compra en Amazon hechas por médicos (WhatsApp o simulador interno) con su cotización y ciclo logístico.';

create index purchase_requests_status_created_idx
  on public.purchase_requests (status, created_at desc);
create index purchase_requests_phone_created_idx
  on public.purchase_requests (phone_e164, created_at desc);
create index purchase_requests_merchant_created_idx
  on public.purchase_requests (merchant_id, created_at desc);

alter table public.purchase_requests enable row level security;
revoke all on public.purchase_requests from anon, authenticated;

create table public.purchase_payment_reports (
  id                  uuid primary key default gen_random_uuid(),
  request_id          uuid not null references public.purchase_requests(id) on delete cascade,
  method              text not null check (method in ('pago_movil', 'transferencia')),
  bank                text not null,
  reference           text not null,
  payer_phone         text,
  paid_on             date not null,
  fx_rate             numeric(18,6) not null,
  expected_ves        numeric(18,2) not null,
  declared_amount_ves numeric(18,2) not null check (declared_amount_ves > 0),
  receipt_path        text check (
    receipt_path is null or (
      receipt_path like 'compras/%'
      and receipt_path not like '%..%'
      and position('\' in receipt_path) = 0
      and length(receipt_path) <= 500
    )
  ),
  status              text not null default 'reported' check (status in (
    'reported', 'in_review', 'reconciled', 'rejected', 'duplicate'
  )),
  registered_by       uuid references auth.users(id),
  reviewed_by         uuid references auth.users(id),
  reviewed_at         timestamptz,
  rejection_note      text,
  note                text,
  wa_message_id       text,
  created_at          timestamptz not null default now()
);

comment on table public.purchase_payment_reports is
  'Reportes de pago en bolívares asociados a solicitudes de compra en Amazon. Capturas en el bucket payment-receipts bajo compras/.';

create index purchase_payment_reports_status_created_idx
  on public.purchase_payment_reports (status, created_at desc);
create index purchase_payment_reports_request_created_idx
  on public.purchase_payment_reports (request_id, created_at desc);
create index purchase_payment_reports_bank_ref_idx
  on public.purchase_payment_reports (lower(bank), reference);

alter table public.purchase_payment_reports enable row level security;
revoke all on public.purchase_payment_reports from anon, authenticated;

create table public.purchase_request_events (
  id         uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.purchase_requests(id) on delete cascade,
  actor      uuid references auth.users(id),
  kind       text not null,
  title      text not null,
  detail     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

comment on table public.purchase_request_events is
  'Línea de tiempo append-only de eventos de cada solicitud de compra en Amazon.';

create index purchase_request_events_request_created_idx
  on public.purchase_request_events (request_id, created_at asc);

create or replace function public.helios_block_purchase_event_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
begin
  raise exception 'purchase_request_events es append-only: % no está permitido', tg_op
    using errcode = '42501';
end;
$$;

revoke all on function public.helios_block_purchase_event_mutation() from public, anon, authenticated;

create trigger purchase_request_events_no_update
  before update on public.purchase_request_events
  for each row execute function public.helios_block_purchase_event_mutation();

create trigger purchase_request_events_no_delete
  before delete on public.purchase_request_events
  for each row execute function public.helios_block_purchase_event_mutation();

alter table public.purchase_request_events enable row level security;
revoke all on public.purchase_request_events from anon, authenticated;

create table public.purchase_simulator_messages (
  id         uuid primary key default gen_random_uuid(),
  phone_e164 text not null,
  direction  text not null check (direction in ('in', 'out')),
  kind       text not null default 'text' check (kind in ('text', 'buttons', 'carousel', 'list', 'image')),
  body       text not null default '',
  payload    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

comment on table public.purchase_simulator_messages is
  'Mensajes del simulador interno de Compras Amazon. Totalmente aislado de outbound_messages.';

create index purchase_simulator_messages_phone_created_idx
  on public.purchase_simulator_messages (phone_e164, created_at asc);

alter table public.purchase_simulator_messages enable row level security;
revoke all on public.purchase_simulator_messages from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Helpers internos (sin acceso desde API)
-- ---------------------------------------------------------------------------

/**
 * Calcula el desglose exacto en USD y VES de una compra en Amazon usando
 * `purchase_settings` y la tasa BCV vigente (`helios_fx_rate('USD')`).
 */
create or replace function public.helios_purchase_calculate(
  p_unit_price_usd       numeric,
  p_quantity             integer,
  p_shipping_method      text,
  p_weight_lb            numeric,
  p_volumetric_weight_lb numeric,
  p_volume_ft3           numeric
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_cfg              public.purchase_settings%rowtype;
  v_method           text := lower(btrim(coalesce(p_shipping_method, 'aereo')));
  v_qty              integer := coalesce(p_quantity, 1);
  v_fx               numeric(18,6);
  v_subtotal         numeric(18,4);
  v_tax              numeric(18,4);
  v_shipping         numeric(18,4);
  v_service          numeric(18,4);
  v_total            numeric(18,4);
  v_quoted_ves       numeric(18,2);
  v_billable_lb      numeric(10,3) := null;
  v_billable_ft3     numeric(10,4) := null;
  v_weight_estimated boolean := false;
  v_unit_lb          numeric(10,3);
  v_unit_vol_lb      numeric(10,3);
  v_unit_ft3         numeric(10,4);
begin
  if p_unit_price_usd is null or p_unit_price_usd <= 0 then
    raise exception 'El precio unitario debe ser mayor que cero' using errcode = '22023';
  end if;
  if v_qty < 1 or v_qty > 50 then
    raise exception 'La cantidad debe estar entre 1 y 50 unidades' using errcode = '22023';
  end if;
  if v_method not in ('aereo', 'maritimo') then
    raise exception 'El método de envío debe ser aéreo (aereo) o marítimo (maritimo)' using errcode = '22023';
  end if;

  select * into v_cfg from public.purchase_settings where id;
  if not found then
    raise exception 'No existe configuración de compras Amazon' using errcode = 'P0002';
  end if;

  v_fx := public.helios_fx_rate('USD');
  if v_fx is null or v_fx <= 0 then
    raise exception 'No hay tasa BCV vigente del dólar: carga la tasa antes de cotizar' using errcode = 'P0002';
  end if;

  v_subtotal := round(p_unit_price_usd * v_qty, 2)::numeric(18,4);
  v_tax := round(v_subtotal * v_cfg.tax_usa_pct / 100.0, 2)::numeric(18,4);

  if v_method = 'aereo' then
    v_unit_lb := case when p_weight_lb is not null and p_weight_lb > 0 then p_weight_lb else null end;
    v_unit_vol_lb := case when p_volumetric_weight_lb is not null and p_volumetric_weight_lb > 0 then p_volumetric_weight_lb else 0 end;
    if v_unit_lb is null and v_unit_vol_lb = 0 then
      v_weight_estimated := true;
    end if;
    v_billable_lb := round(greatest(coalesce(v_unit_lb, v_cfg.fallback_weight_lb), v_unit_vol_lb) * v_qty, 3);
    v_shipping := greatest(v_cfg.air_min_usd, round(v_billable_lb * v_cfg.air_rate_per_lb_usd, 2))::numeric(18,4);
  else
    v_unit_ft3 := case when p_volume_ft3 is not null and p_volume_ft3 > 0 then p_volume_ft3 else null end;
    if v_unit_ft3 is null then
      v_weight_estimated := true;
    end if;
    v_billable_ft3 := round(greatest(coalesce(v_unit_ft3, 0.5), 0.1) * v_qty, 4);
    v_shipping := greatest(v_cfg.sea_min_usd, round(v_billable_ft3 * v_cfg.sea_rate_per_ft3_usd, 2))::numeric(18,4);
  end if;

  v_service := round(v_subtotal * v_cfg.service_fee_pct / 100.0, 2)::numeric(18,4);
  v_total := (v_subtotal + v_tax + v_shipping + v_service)::numeric(18,4);
  v_quoted_ves := round(v_total * v_fx, 2)::numeric(18,2);

  return jsonb_build_object(
    'unit_price_usd', round(p_unit_price_usd, 4)::numeric(18,4),
    'quantity', v_qty,
    'shipping_method', v_method,
    'subtotal_usd', v_subtotal,
    'tax_usa_pct', v_cfg.tax_usa_pct,
    'tax_usa_usd', v_tax,
    'shipping_usd', v_shipping,
    'service_fee_pct', v_cfg.service_fee_pct,
    'service_fee_usd', v_service,
    'total_usd', v_total,
    'quoted_fx_rate', v_fx,
    'quoted_ves', v_quoted_ves,
    'billable_lb', v_billable_lb,
    'billable_ft3', v_billable_ft3,
    'weight_estimated', v_weight_estimated,
    'quote_ttl_hours', v_cfg.quote_ttl_hours
  );
end;
$$;

/**
 * Bloque de datos de pago en bolívares reutilizando exactamente las cuentas de
 * cobro activas de Helios (`helios_payment_accounts_block`, sin titular).
 */
create or replace function public.helios_purchase_payment_block(
  p_total_usd numeric,
  p_as_of     date default null
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_fx  numeric(18,6) := public.helios_fx_rate('USD', p_as_of);
  v_ves numeric(18,2);
begin
  if p_total_usd is null or p_total_usd <= 0 then
    raise exception 'Monto total inválido para generar bloque de pago' using errcode = '22023';
  end if;
  if v_fx is null or v_fx <= 0 then
    raise exception 'No hay tasa BCV vigente del dólar' using errcode = 'P0002';
  end if;

  v_ves := round(p_total_usd * v_fx, 2)::numeric(18,2);

  return concat_ws(
    E'\n\n',
    format(
      E'💳 *Datos para pagar tu compra*\nTotal: *$%s* · *%s* (tasa BCV: Bs %s)',
      public.helios_money_text(p_total_usd),
      public.helios_ves_text(v_ves),
      translate(to_char(round(v_fx, 4), 'FM999,999,990.0000'), ',.', '.,')
    ),
    public.helios_payment_accounts_block(),
    'Al realizar el pago, envíanos el comprobante o indícanos banco y número de referencia por este chat.'
  );
end;
$$;

/**
 * Envía una notificación al médico según el canal de la solicitud:
 *   · `simulador` → escribe en `purchase_simulator_messages` y JAMÁS toca `outbound_messages`.
 *   · `whatsapp`  → si la ventana de 24 h está abierta y hay `requested_by`, encola por
 *                   `helios_whatsapp_text` dentro de un bloque protegido para nunca abortar.
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
  v_btns jsonb := coalesce(p_buttons, '[]'::jsonb);
  v_kind text;
begin
  if nullif(btrim(coalesce(p_text, '')), '') is null then
    return;
  end if;

  if p_request.channel = 'simulador' then
    v_kind := case
      when jsonb_typeof(v_btns) = 'array' and jsonb_array_length(v_btns) > 0 then 'buttons'
      else 'text'
    end;
    insert into public.purchase_simulator_messages (
      phone_e164, direction, kind, body, payload
    ) values (
      p_request.phone_e164, 'out', v_kind, p_text,
      jsonb_build_object(
        'buttons', v_btns,
        'request_id', p_request.id,
        'request_number', p_request.request_number
      )
    );
    return;
  end if;

  if p_request.channel = 'whatsapp'
     and p_request.requested_by is not null
     and public.helios_whatsapp_window_open(p_request.phone_e164) then
    begin
      perform public.helios_whatsapp_text(
        p_request.phone_e164,
        p_text,
        p_request.requested_by,
        v_btns
      );
    exception when others then
      null;
    end;
  end if;
end;
$$;

/** ¿`p_actor` puede aprobar el pago de compra `p_report_id` con el doble control? */
create or replace function public.helios_can_approve_purchase_payment(
  p_report_id uuid,
  p_actor     uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select not (
    public.helios_payment_four_eyes()
    and exists (
      select 1 from public.purchase_payment_reports r
      where r.id = p_report_id and r.registered_by = p_actor
    )
    and not exists (
      select 1 from public.platform_admins a
      where a.user_id = p_actor and a.is_active and a.role = 'super_admin'
    )
  );
$$;

/** Núcleo compartido para registrar un pago de compra (bot, admin o simulador). */
create or replace function public.helios_purchase_register_payment_core(
  p_request_id    uuid,
  p_method        text,
  p_bank          text,
  p_reference     text,
  p_paid_on       date,
  p_amount_ves    numeric,
  p_receipt_path  text,
  p_payer_phone   text,
  p_note          text,
  p_actor         uuid,
  p_wa_message_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_req          public.purchase_requests%rowtype;
  v_today        date := public.helios_business_date(now());
  v_method       text := lower(btrim(coalesce(p_method, '')));
  v_bank         text := nullif(btrim(coalesce(p_bank, '')), '');
  v_ref          text := nullif(btrim(coalesce(p_reference, '')), '');
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
begin
  select * into v_req
  from public.purchase_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Solicitud de compra no encontrada' using errcode = 'P0002';
  end if;

  if v_req.status <> 'esperando_pago' then
    raise exception 'Esta solicitud no está esperando pago (estado actual: %)', v_req.status
      using errcode = '22023';
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

  if v_bank is null then
    raise exception 'Falta el banco del pago' using errcode = '22023';
  end if;

  if v_ref is null or length(v_ref) < 4 or length(v_ref) > 40 then
    raise exception 'La referencia debe tener entre 4 y 40 caracteres'
      using errcode = '22023';
  end if;

  if p_paid_on is null then
    raise exception 'Falta la fecha del pago' using errcode = '22023';
  end if;
  if p_paid_on > v_today then
    raise exception 'La fecha del pago no puede ser posterior a hoy' using errcode = '22023';
  end if;
  if p_paid_on < v_today - 120 then
    raise exception 'La fecha del pago es de hace más de 120 días: revísala' using errcode = '22023';
  end if;

  if p_amount_ves is null or p_amount_ves <= 0 then
    raise exception 'El monto en bolívares debe ser mayor que cero' using errcode = '22023';
  end if;
  if p_amount_ves <> round(p_amount_ves, 2) then
    raise exception 'El monto en bolívares admite como mucho 2 decimales' using errcode = '22023';
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

  v_dup := exists (
    select 1 from public.purchase_payment_reports r
    where lower(r.bank) = lower(v_bank)
      and r.reference = v_ref
      and r.status not in ('rejected', 'duplicate')
  );
  v_status := case when v_dup then 'in_review' else 'reported' end;

  insert into public.purchase_payment_reports (
    request_id, method, bank, reference, payer_phone,
    paid_on, fx_rate, expected_ves, declared_amount_ves,
    receipt_path, status, registered_by, rejection_note, note, wa_message_id
  ) values (
    v_req.id, v_method, v_bank, v_ref, v_payer_phone,
    p_paid_on, v_fx_rate, v_expected_ves, p_amount_ves,
    v_path, v_status, p_actor,
    case when v_dup then 'Referencia repetida: revisar contra el estado de cuenta antes de aprobar.' end,
    v_note, v_wa_msg
  )
  returning * into v_rep;

  update public.purchase_requests
     set status = 'pago_reportado', updated_at = now()
   where id = v_req.id;

  v_cuadra := public.helios_monto_cuadra(p_amount_ves, v_expected_ves);

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
      'monto_cuadra', v_cuadra,
      'duplicate_reference', v_dup,
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
        'status', v_status,
        'receipt_path', v_path,
        'note', v_note
      )
    );
  end if;

  return jsonb_build_object(
    'report_id', v_rep.id,
    'request_id', v_req.id,
    'request_number', v_req.request_number,
    'status', v_rep.status,
    'fx_rate', v_fx_rate,
    'expected_ves', v_expected_ves,
    'declared_amount_ves', p_amount_ves,
    'diferencia_ves', round(p_amount_ves - v_expected_ves, 2),
    'monto_cuadra', v_cuadra
  );
end;
$$;

/** Ficha resumida de una solicitud de compra. */
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
    'diferencia_ves', round(r.declared_amount_ves - r.expected_ves, 2),
    'monto_cuadra', public.helios_monto_cuadra(r.declared_amount_ves, r.expected_ves),
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
    'reference_collisions', (
      select count(*)::integer from public.purchase_payment_reports r2
      where r2.id <> r.id
        and lower(r2.bank) = lower(r.bank)
        and r2.reference = r.reference
        and r2.status not in ('rejected', 'duplicate')
    ),
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

revoke all on function public.helios_purchase_calculate(numeric, integer, text, numeric, numeric, numeric) from public, anon, authenticated;
revoke all on function public.helios_purchase_payment_block(numeric, date) from public, anon, authenticated;
revoke all on function public.helios_purchase_notify(public.purchase_requests, text, jsonb) from public, anon, authenticated;
revoke all on function public.helios_can_approve_purchase_payment(uuid, uuid) from public, anon, authenticated;
revoke all on function public.helios_purchase_register_payment_core(uuid, text, text, text, date, numeric, text, text, text, uuid, text) from public, anon, authenticated;
revoke all on function public.helios_purchase_request_summary(uuid) from public, anon, authenticated;
revoke all on function public.helios_purchase_payment_item(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. RPCs del Bot (`service_role`, revocadas a public/anon/authenticated)
-- ---------------------------------------------------------------------------

create or replace function public.bot_compra_config()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'is_enabled', s.is_enabled,
    'catalog_provider', s.catalog_provider,
    'tax_usa_pct', s.tax_usa_pct,
    'service_fee_pct', s.service_fee_pct,
    'air_rate_per_lb_usd', s.air_rate_per_lb_usd,
    'air_min_usd', s.air_min_usd,
    'sea_rate_per_ft3_usd', s.sea_rate_per_ft3_usd,
    'sea_min_usd', s.sea_min_usd,
    'fallback_weight_lb', s.fallback_weight_lb,
    'quote_ttl_hours', s.quote_ttl_hours,
    'fx_rate_usd', public.helios_fx_rate('USD'),
    'accounts_block', public.helios_payment_accounts_block()
  )
  from public.purchase_settings s
  where s.id;
$$;

create or replace function public.bot_compra_cache_get(p_key text)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select c.payload
  from public.amazon_catalog_cache c
  where c.cache_key = p_key
    and c.expires_at > now();
$$;

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
  v_key  text := nullif(btrim(coalesce(p_key, '')), '');
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_prov text := nullif(btrim(coalesce(p_provider, '')), '');
  v_ttl  integer := least(greatest(coalesce(p_ttl_minutes, 60), 1), 10080);
begin
  if v_key is null or v_kind not in ('search', 'product') or v_prov is null or p_payload is null then
    raise exception 'Entrada de caché inválida' using errcode = '22023';
  end if;

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
  p_channel              text default 'whatsapp'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cfg     public.purchase_settings%rowtype;
  v_n       public.staff_whatsapp_numbers%rowtype;
  v_channel text := lower(btrim(coalesce(p_channel, 'whatsapp')));
  v_asin    text := upper(nullif(btrim(coalesce(p_asin, '')), ''));
  v_title   text := nullif(btrim(coalesce(p_product_title, '')), '');
  v_calc    jsonb;
  v_status  text;
  v_req     public.purchase_requests%rowtype;
  v_block   text;
begin
  select * into v_cfg from public.purchase_settings where id;
  if not found or not v_cfg.is_enabled then
    raise exception 'El servicio de compras Amazon no está habilitado en este momento'
      using errcode = '22023';
  end if;

  if v_channel not in ('whatsapp', 'simulador') then
    raise exception 'Canal no válido: whatsapp o simulador' using errcode = '22023';
  end if;
  if v_asin is null then
    raise exception 'Falta el código ASIN del producto' using errcode = '22023';
  end if;
  if v_title is null then
    raise exception 'Falta el nombre del producto' using errcode = '22023';
  end if;

  v_n := public.helios_bot_number(p_phone);

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
    total_usd, quoted_fx_rate, quoted_ves, quote_expires_at, status
  ) values (
    v_n.merchant_id, v_n.user_id, v_n.phone_e164, v_channel,
    v_asin, left(v_title, 400), nullif(btrim(coalesce(p_product_url, '')), ''),
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
    v_status
  )
  returning * into v_req;

  insert into public.purchase_request_events (request_id, actor, kind, title, detail)
  values (
    v_req.id,
    v_n.user_id,
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

  if v_req.status = 'esperando_pago' then
    v_block := public.helios_purchase_payment_block(v_req.total_usd);
  end if;

  return jsonb_build_object(
    'request_id', v_req.id,
    'request_number', v_req.request_number,
    'status', v_req.status,
    'channel', v_req.channel,
    'asin', v_req.asin,
    'product_title', v_req.product_title,
    'quantity', v_req.quantity,
    'shipping_method', v_req.shipping_method,
    'unit_price_usd', v_req.unit_price_usd,
    'subtotal_usd', v_req.subtotal_usd,
    'tax_usa_usd', v_req.tax_usa_usd,
    'shipping_usd', v_req.shipping_usd,
    'service_fee_usd', v_req.service_fee_usd,
    'total_usd', v_req.total_usd,
    'quoted_fx_rate', v_req.quoted_fx_rate,
    'quoted_ves', v_req.quoted_ves,
    'quote_expires_at', v_req.quote_expires_at,
    'weight_estimated', v_req.weight_estimated,
    'restricted_flag', v_req.restricted_flag,
    'restricted_reason', v_req.restricted_reason,
    'payment_block', v_block
  );
end;
$$;

create or replace function public.bot_compra_mis_solicitudes(
  p_phone text,
  p_limit integer default 8
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_n   public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_lim integer := least(greatest(coalesce(p_limit, 8), 1), 30);
begin
  return coalesce((
    select jsonb_agg(public.helios_purchase_request_summary(r.id) order by r.created_at desc)
    from (
      select id, created_at from public.purchase_requests
      where phone_e164 = v_n.phone_e164
      order by created_at desc
      limit v_lim
    ) r
  ), '[]'::jsonb);
end;
$$;

create or replace function public.bot_compra_pendiente_de_pago(p_phone text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_n   public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_req public.purchase_requests%rowtype;
  v_fx  numeric(18,6);
begin
  select * into v_req
  from public.purchase_requests
  where phone_e164 = v_n.phone_e164
    and status = 'esperando_pago'
  order by created_at desc
  limit 1;

  if not found then
    return null;
  end if;

  v_fx := public.helios_fx_rate('USD');

  return jsonb_build_object(
    'request_id', v_req.id,
    'request_number', v_req.request_number,
    'product_title', v_req.product_title,
    'asin', v_req.asin,
    'quantity', v_req.quantity,
    'total_usd', v_req.total_usd,
    'quoted_fx_rate', v_req.quoted_fx_rate,
    'quoted_ves', v_req.quoted_ves,
    'today_fx_rate', v_fx,
    'today_ves', case when v_fx is not null then round(v_req.total_usd * v_fx, 2) end,
    'quote_expires_at', v_req.quote_expires_at,
    'payment_block', public.helios_purchase_payment_block(v_req.total_usd)
  );
end;
$$;

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
  p_note          text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_n      public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_req    public.purchase_requests%rowtype;
  v_today  date := public.helios_business_date(now());
  v_fx     numeric(18,6);
  v_amount numeric(18,2);
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select * into v_req
  from public.purchase_requests
  where id = p_request_id;

  if not found then
    raise exception 'Solicitud de compra no encontrada' using errcode = 'P0002';
  end if;

  if v_req.phone_e164 <> v_n.phone_e164 or v_req.merchant_id <> v_n.merchant_id then
    raise exception 'Esa solicitud no corresponde a este número' using errcode = '42501';
  end if;

  if p_amount_ves is null then
    v_fx := public.helios_fx_rate('USD', v_today);
    if v_fx is null or v_fx <= 0 then
      raise exception 'No hay tasa BCV vigente para hoy' using errcode = 'P0002';
    end if;
    v_amount := round(v_req.total_usd * v_fx, 2)::numeric(18,2);
    v_note := concat_ws(' · ',
      'Monto no indicado por el médico; se cargó el esperado del día para verificar contra el comprobante.',
      v_note
    );
  else
    v_amount := p_amount_ves;
  end if;

  return public.helios_purchase_register_payment_core(
    p_request_id,
    p_method,
    p_bank,
    p_reference,
    v_today,
    v_amount,
    p_receipt_path,
    p_payer_phone,
    v_note,
    null,
    p_wa_message_id
  );
end;
$$;

revoke all on function public.bot_compra_config() from public, anon, authenticated;
revoke all on function public.bot_compra_cache_get(text) from public, anon, authenticated;
revoke all on function public.bot_compra_cache_set(text, text, text, jsonb, integer) from public, anon, authenticated;
revoke all on function public.bot_compra_crear(text, text, text, text, text, text, integer, text, numeric, numeric, numeric, boolean, boolean, text, text, numeric, text) from public, anon, authenticated;
revoke all on function public.bot_compra_mis_solicitudes(text, integer) from public, anon, authenticated;
revoke all on function public.bot_compra_pendiente_de_pago(text) from public, anon, authenticated;
revoke all on function public.bot_compra_reportar_pago(text, uuid, text, text, text, text, numeric, text, text, text) from public, anon, authenticated;

grant execute on function public.bot_compra_config() to service_role;
grant execute on function public.bot_compra_cache_get(text) to service_role;
grant execute on function public.bot_compra_cache_set(text, text, text, jsonb, integer) to service_role;
grant execute on function public.bot_compra_crear(text, text, text, text, text, text, integer, text, numeric, numeric, numeric, boolean, boolean, text, text, numeric, text) to service_role;
grant execute on function public.bot_compra_mis_solicitudes(text, integer) to service_role;
grant execute on function public.bot_compra_pendiente_de_pago(text) to service_role;
grant execute on function public.bot_compra_reportar_pago(text, uuid, text, text, text, text, numeric, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 5. RPCs de Administración (`authenticated`, verificando plataforma/superadmin)
-- ---------------------------------------------------------------------------

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
  v_lim    integer := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
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
          v_search is null
          or pr.request_number::text ilike '%' || v_search || '%'
          or pr.asin ilike '%' || v_search || '%'
          or pr.product_title ilike '%' || v_search || '%'
          or pr.phone_e164 ilike '%' || v_search || '%'
          or m.name ilike '%' || v_search || '%'
          or coalesce(pr.amazon_order_id, '') ilike '%' || v_search || '%'
          or coalesce(pr.us_tracking_number, '') ilike '%' || v_search || '%'
        )
      order by pr.created_at desc
      limit v_lim
    ) r
  ), '[]'::jsonb);
end;
$$;

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
      when v_req.status in ('esperando_pago', 'revision_aduanal')
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

create or replace function public.admin_purchase_counts()
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
      'total', count(*)::integer,
      'active', (count(*) filter (where status not in ('entregado', 'cancelado')))::integer,
      'revision_aduanal', (count(*) filter (where status = 'revision_aduanal'))::integer,
      'esperando_pago', (count(*) filter (where status = 'esperando_pago'))::integer,
      'pago_reportado', (count(*) filter (where status = 'pago_reportado'))::integer,
      'pagado', (count(*) filter (where status = 'pagado'))::integer,
      'comprado_amazon', (count(*) filter (where status = 'comprado_amazon'))::integer,
      'en_almacen_usa', (count(*) filter (where status = 'en_almacen_usa'))::integer,
      'en_transito', (count(*) filter (where status = 'en_transito'))::integer,
      'en_aduana', (count(*) filter (where status = 'en_aduana'))::integer,
      'listo_entrega', (count(*) filter (where status = 'listo_entrega'))::integer,
      'entregado', (count(*) filter (where status = 'entregado'))::integer,
      'cancelado', (count(*) filter (where status = 'cancelado'))::integer,
      'whatsapp_count', (count(*) filter (where channel = 'whatsapp'))::integer,
      'simulador_count', (count(*) filter (where channel = 'simulador'))::integer,
      'payments_pending', (
        select count(*)::integer
        from public.purchase_payment_reports
        where status in ('reported', 'in_review')
      )
    )
    from public.purchase_requests
  );
end;
$$;

create or replace function public.admin_purchase_payment_queue(
  p_statuses text[] default array['reported', 'in_review']
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_statuses text[] := case
    when p_statuses is null or cardinality(p_statuses) = 0
    then array['reported', 'in_review']
    else p_statuses
  end;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(
      public.helios_purchase_payment_item(r.id)
      order by (r.status = 'in_review') desc, r.created_at asc
    )
    from public.purchase_payment_reports r
    where r.status = any(v_statuses)
  ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_purchase_payment_preview(
  p_request_id uuid,
  p_paid_on    date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_req  public.purchase_requests%rowtype;
  v_date date := coalesce(p_paid_on, public.helios_business_date(now()));
  v_fx   numeric(18,6);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_req from public.purchase_requests where id = p_request_id;
  if not found then
    raise exception 'Solicitud de compra no encontrada' using errcode = 'P0002';
  end if;

  v_fx := public.helios_fx_rate('USD', v_date);
  if v_fx is null or v_fx <= 0 then
    raise exception 'No hay tasa BCV vigente para la fecha %', v_date using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'request_id', v_req.id,
    'request_number', v_req.request_number,
    'status', v_req.status,
    'product_title', v_req.product_title,
    'total_usd', v_req.total_usd,
    'paid_on', v_date,
    'fx_rate', v_fx,
    'expected_ves', round(v_req.total_usd * v_fx, 2)::numeric(18,2),
    'quoted_fx_rate', v_req.quoted_fx_rate,
    'quoted_ves', v_req.quoted_ves,
    'has_open_payment', exists (
      select 1 from public.purchase_payment_reports r
      where r.request_id = v_req.id and r.status in ('reported', 'in_review')
    )
  );
end;
$$;

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

  return public.helios_purchase_register_payment_core(
    p_request_id,
    p_method,
    p_bank,
    p_reference,
    p_paid_on,
    p_amount_ves,
    p_receipt_path,
    p_payer_phone,
    p_note,
    auth.uid(),
    null
  );
end;
$$;

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

  select * into v_rep
  from public.purchase_payment_reports
  where id = p_report_id
  for update;

  if not found then
    raise exception 'Reporte de pago no encontrado' using errcode = 'P0002';
  end if;

  if v_rep.status not in ('reported', 'in_review') then
    raise exception 'Este pago ya fue resuelto (%)', v_rep.status using errcode = '22023';
  end if;

  if p_approve and not public.helios_can_approve_purchase_payment(v_rep.id, v_actor) then
    raise exception 'Tú registraste este pago: con el doble control encendido lo aprueba otra persona del equipo'
      using errcode = '42501';
  end if;

  select * into v_req
  from public.purchase_requests
  where id = v_rep.request_id
  for update;

  if p_approve then
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
        '✅ Confirmamos el pago de tu solicitud #%s (%s) por %s. Ya pasamos tu pedido al equipo para gestionar la compra en Amazon.',
        v_req.request_number,
        v_req.product_title,
        public.helios_ves_text(v_rep.declared_amount_ves)
      )
    );
  else
    update public.purchase_payment_reports
       set status = 'rejected',
           reviewed_by = v_actor,
           reviewed_at = now(),
           rejection_note = v_nota
     where id = v_rep.id
    returning * into v_rep;

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

    perform public.helios_purchase_notify(
      v_req,
      format(
        '⚠️ No pudimos confirmar el pago reportado para tu solicitud #%s (%s). Motivo: %s. Puedes volver a enviar tu comprobante por este chat.',
        v_req.request_number,
        v_req.product_title,
        v_nota
      )
    );
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
  v_actor uuid := auth.uid();
  v_nota  text := nullif(btrim(coalesce(p_note, '')), '');
  v_rep   public.purchase_payment_reports%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_nota is null or length(v_nota) < 3 then
    raise exception 'Indica el motivo para enviar el pago a revisión' using errcode = '22023';
  end if;

  select * into v_rep
  from public.purchase_payment_reports
  where id = p_report_id
  for update;

  if not found then
    raise exception 'Reporte de pago no encontrado' using errcode = 'P0002';
  end if;

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

  select * into v_rep
  from public.purchase_payment_reports
  where id = p_report_id
  for update;

  if not found then
    raise exception 'Reporte de pago no encontrado' using errcode = 'P0002';
  end if;

  if v_rep.status not in ('reported', 'in_review') then
    raise exception 'Este pago ya fue resuelto (%)', v_rep.status using errcode = '22023';
  end if;

  update public.purchase_payment_reports
     set status = 'duplicate',
         reviewed_by = v_actor,
         reviewed_at = now(),
         rejection_note = 'Duplicado: ' || v_nota
   where id = v_rep.id
  returning * into v_rep;

  select * into v_req
  from public.purchase_requests
  where id = v_rep.request_id
  for update;

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
           quote_expires_at = now() + make_interval(hours => coalesce(v_cfg.quote_ttl_hours, 24)),
           internal_notes = coalesce(concat_ws(E'\n', nullif(internal_notes, ''), v_nota), internal_notes),
           updated_at = now()
     where id = v_req.id
    returning * into v_req;

    insert into public.purchase_request_events (request_id, actor, kind, title, detail)
    values (
      v_req.id, v_actor, 'customs_approved', 'Revisión aduanal aprobada',
      jsonb_build_object('note', v_nota, 'quoted_fx_rate', v_fx, 'quoted_ves', v_ves)
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
        E'✅ Aprobamos la revisión aduanal de tu solicitud #%s (%s). Ya puedes realizar el pago:\n\n%s',
        v_req.request_number,
        v_req.product_title,
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
        '❌ No pudimos aprobar la importación de tu solicitud #%s (%s). Motivo: %s',
        v_req.request_number,
        v_req.product_title,
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
  v_msg      text;
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
      'note', v_nota
    )
  );

  perform audit.log(v_actor, 'purchase.status_advanced', v_req.id, jsonb_build_object(
    'request_number', v_req.request_number,
    'from_status', v_from,
    'to_status', v_target,
    'amazon_order_id', v_req.amazon_order_id,
    'us_tracking_number', v_req.us_tracking_number,
    'note', v_nota
  ));

  v_msg := case v_target
    when 'comprado_amazon' then format(
      '🛒 Ya compramos tu pedido #%s (%s) en Amazon%s. Te avisaremos apenas llegue a nuestro almacén en EE. UU.',
      v_req.request_number,
      v_req.product_title,
      case when v_req.amazon_order_id is not null then ' (orden ' || v_req.amazon_order_id || ')' else '' end
    )
    when 'en_almacen_usa' then format(
      '📦 Tu pedido #%s (%s) llegó a nuestro almacén en EE. UU.%s Pronto saldrá hacia Venezuela.',
      v_req.request_number,
      v_req.product_title,
      case when v_req.us_tracking_number is not null then ' (guía ' || v_req.us_tracking_number || ').' else '.' end
    )
    when 'en_transito' then format(
      '%s Tu pedido #%s (%s) ya está en tránsito hacia Venezuela.',
      case when v_req.shipping_method = 'maritimo' then '🚢' else '✈️' end,
      v_req.request_number,
      v_req.product_title
    )
    when 'en_aduana' then format(
      '🛃 Tu pedido #%s (%s) llegó a Venezuela y está en proceso de aduana.',
      v_req.request_number,
      v_req.product_title
    )
    when 'listo_entrega' then format(
      '🎉 ¡Tu pedido #%s (%s) ya está listo para entrega! Te contactaremos para coordinar el despacho.',
      v_req.request_number,
      v_req.product_title
    )
    when 'entregado' then format(
      '✅ Pedido #%s (%s) entregado. ¡Gracias por usar el servicio de compras de Helios!',
      v_req.request_number,
      v_req.product_title
    )
    when 'cancelado' then format(
      '❌ Tu solicitud #%s (%s) fue cancelada. Motivo: %s',
      v_req.request_number,
      v_req.product_title,
      v_nota
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
    'us_tracking_number', v_req.us_tracking_number
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
  p_is_enabled           boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('editar la configuración de compras Amazon');
  v_prov   text := lower(btrim(coalesce(p_catalog_provider, '')));
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
  if v_prov not in ('mock', 'rainforest', 'oxylabs', 'rapidapi') then
    raise exception 'Proveedor de catálogo no válido: mock, rainforest, oxylabs o rapidapi'
      using errcode = '22023';
  end if;
  if p_is_enabled is null then
    raise exception 'Indica si el servicio está habilitado' using errcode = '22023';
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
-- 6. RPCs del Simulador interno (`authenticated`, `is_platform_admin()`)
-- ---------------------------------------------------------------------------

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
    where m.status = 'active'
  ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_purchase_sim_messages(p_phone text)
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
    select jsonb_agg(jsonb_build_object(
      'id', m.id,
      'phone_e164', m.phone_e164,
      'direction', m.direction,
      'kind', m.kind,
      'body', m.body,
      'payload', m.payload,
      'created_at', m.created_at
    ) order by m.created_at asc, m.id asc)
    from public.purchase_simulator_messages m
    where m.phone_e164 = v_phone
  ), '[]'::jsonb);
end;
$$;

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
set search_path = public, pg_temp
as $$
declare
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

  return to_jsonb(v_row);
end;
$$;

create or replace function public.admin_purchase_sim_reset(p_phone text)
returns void
language plpgsql
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

  delete from public.purchase_simulator_messages where phone_e164 = v_phone;
end;
$$;

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
  v_actor   uuid := auth.uid();
  v_cfg     public.purchase_settings%rowtype;
  v_phone   text := coalesce(public.helios_wa_e164(p_phone), nullif(btrim(coalesce(p_phone, '')), ''));
  v_asin    text := upper(nullif(btrim(coalesce(p_asin, '')), ''));
  v_title   text := nullif(btrim(coalesce(p_product_title, '')), '');
  v_staff   uuid;
  v_calc    jsonb;
  v_status  text;
  v_req     public.purchase_requests%rowtype;
  v_block   text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_cfg from public.purchase_settings where id;
  if not found or not v_cfg.is_enabled then
    raise exception 'El servicio de compras Amazon no está habilitado en este momento'
      using errcode = '22023';
  end if;

  if p_merchant_id is null or not exists (select 1 from public.merchants where id = p_merchant_id) then
    raise exception 'Clínica o comercio no encontrado' using errcode = 'P0002';
  end if;
  if v_phone is null then
    raise exception 'Falta el número de teléfono del simulador' using errcode = '22023';
  end if;
  if v_asin is null then
    raise exception 'Falta el código ASIN del producto' using errcode = '22023';
  end if;
  if v_title is null then
    raise exception 'Falta el nombre del producto' using errcode = '22023';
  end if;

  select n.user_id into v_staff
  from public.staff_whatsapp_numbers n
  where n.merchant_id = p_merchant_id and n.phone_e164 = v_phone and n.revoked_at is null
  limit 1;

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
    total_usd, quoted_fx_rate, quoted_ves, quote_expires_at, status
  ) values (
    p_merchant_id, coalesce(v_staff, v_actor), v_phone, 'simulador',
    v_asin, left(v_title, 400), nullif(btrim(coalesce(p_product_url, '')), ''),
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
    v_status
  )
  returning * into v_req;

  insert into public.purchase_request_events (request_id, actor, kind, title, detail)
  values (
    v_req.id,
    v_actor,
    'created',
    case when v_req.restricted_flag
         then 'Solicitud creada desde simulador (revisión aduanal)'
         else 'Solicitud creada desde simulador' end,
    jsonb_build_object(
      'channel', 'simulador',
      'asin', v_req.asin,
      'quantity', v_req.quantity,
      'shipping_method', v_req.shipping_method,
      'total_usd', v_req.total_usd,
      'quoted_ves', v_req.quoted_ves,
      'restricted_flag', v_req.restricted_flag,
      'restricted_reason', v_req.restricted_reason
    )
  );

  perform audit.log(v_actor, 'purchase.sim_created', v_req.id, jsonb_build_object(
    'request_number', v_req.request_number,
    'merchant_id', p_merchant_id,
    'phone_e164', v_phone,
    'asin', v_req.asin,
    'total_usd', v_req.total_usd
  ));

  if v_req.status = 'esperando_pago' then
    v_block := public.helios_purchase_payment_block(v_req.total_usd);
  end if;

  return jsonb_build_object(
    'request_id', v_req.id,
    'request_number', v_req.request_number,
    'status', v_req.status,
    'channel', v_req.channel,
    'asin', v_req.asin,
    'product_title', v_req.product_title,
    'quantity', v_req.quantity,
    'shipping_method', v_req.shipping_method,
    'unit_price_usd', v_req.unit_price_usd,
    'subtotal_usd', v_req.subtotal_usd,
    'tax_usa_usd', v_req.tax_usa_usd,
    'shipping_usd', v_req.shipping_usd,
    'service_fee_usd', v_req.service_fee_usd,
    'total_usd', v_req.total_usd,
    'quoted_fx_rate', v_req.quoted_fx_rate,
    'quoted_ves', v_req.quoted_ves,
    'quote_expires_at', v_req.quote_expires_at,
    'weight_estimated', v_req.weight_estimated,
    'restricted_flag', v_req.restricted_flag,
    'restricted_reason', v_req.restricted_reason,
    'payment_block', v_block
  );
end;
$$;

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
  v_actor  uuid := auth.uid();
  v_req    public.purchase_requests%rowtype;
  v_today  date := public.helios_business_date(now());
  v_fx     numeric(18,6);
  v_amount numeric(18,2);
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_res    jsonb;
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

  if p_amount_ves is null then
    v_fx := public.helios_fx_rate('USD', v_today);
    if v_fx is null or v_fx <= 0 then
      raise exception 'No hay tasa BCV vigente para hoy' using errcode = 'P0002';
    end if;
    v_amount := round(v_req.total_usd * v_fx, 2)::numeric(18,2);
    v_note := concat_ws(' · ',
      'Monto no indicado en el simulador; se cargó el esperado del día para verificar contra el comprobante.',
      v_note
    );
  else
    v_amount := p_amount_ves;
  end if;

  -- `p_actor = null` para que `registered_by` quede nulo como un reporte del médico.
  v_res := public.helios_purchase_register_payment_core(
    p_request_id,
    p_method,
    p_bank,
    p_reference,
    v_today,
    v_amount,
    p_receipt_path,
    p_payer_phone,
    v_note,
    null,
    null
  );

  perform audit.log(v_actor, 'purchase_payment.sim_reported', (v_res ->> 'report_id')::uuid, jsonb_build_object(
    'request_id', p_request_id,
    'request_number', v_req.request_number,
    'reference', p_reference,
    'declared_amount_ves', v_amount
  ));

  return v_res;
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
    select jsonb_agg(public.helios_purchase_request_summary(r.id) order by r.created_at desc)
    from (
      select id, created_at from public.purchase_requests
      where phone_e164 = v_phone
        and channel = 'simulador'
      order by created_at desc
      limit 30
    ) r
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Permisos explícitos de las RPCs de administración y simulador
-- ---------------------------------------------------------------------------

revoke all on function public.admin_purchase_list(text[], text, text, integer) from public, anon;
revoke all on function public.admin_purchase_detail(uuid) from public, anon;
revoke all on function public.admin_purchase_counts() from public, anon;
revoke all on function public.admin_purchase_payment_queue(text[]) from public, anon;
revoke all on function public.admin_purchase_payment_preview(uuid, date) from public, anon;
revoke all on function public.admin_purchase_register_payment(uuid, text, text, text, date, numeric, text, text, text) from public, anon;
revoke all on function public.admin_purchase_reconcile_payment(uuid, boolean, text) from public, anon;
revoke all on function public.admin_purchase_flag_payment(uuid, text) from public, anon;
revoke all on function public.admin_purchase_mark_payment_duplicate(uuid, text) from public, anon;
revoke all on function public.admin_purchase_approve_customs(uuid, boolean, text) from public, anon;
revoke all on function public.admin_purchase_advance_status(uuid, text, text, text, text) from public, anon;
revoke all on function public.admin_purchase_settings_get() from public, anon;
revoke all on function public.admin_purchase_settings_set(numeric, numeric, numeric, numeric, numeric, numeric, numeric, integer, text, boolean) from public, anon;
revoke all on function public.admin_purchase_sim_merchants() from public, anon;
revoke all on function public.admin_purchase_sim_messages(text) from public, anon;
revoke all on function public.admin_purchase_sim_append(text, text, text, text, jsonb) from public, anon;
revoke all on function public.admin_purchase_sim_reset(text) from public, anon;
revoke all on function public.admin_purchase_sim_create(uuid, text, text, text, text, text, text, integer, text, numeric, numeric, numeric, boolean, boolean, text, text, numeric) from public, anon;
revoke all on function public.admin_purchase_sim_report_payment(uuid, text, text, text, text, numeric, text, text) from public, anon;
revoke all on function public.admin_purchase_sim_requests(text) from public, anon;

grant execute on function public.admin_purchase_list(text[], text, text, integer) to authenticated;
grant execute on function public.admin_purchase_detail(uuid) to authenticated;
grant execute on function public.admin_purchase_counts() to authenticated;
grant execute on function public.admin_purchase_payment_queue(text[]) to authenticated;
grant execute on function public.admin_purchase_payment_preview(uuid, date) to authenticated;
grant execute on function public.admin_purchase_register_payment(uuid, text, text, text, date, numeric, text, text, text) to authenticated;
grant execute on function public.admin_purchase_reconcile_payment(uuid, boolean, text) to authenticated;
grant execute on function public.admin_purchase_flag_payment(uuid, text) to authenticated;
grant execute on function public.admin_purchase_mark_payment_duplicate(uuid, text) to authenticated;
grant execute on function public.admin_purchase_approve_customs(uuid, boolean, text) to authenticated;
grant execute on function public.admin_purchase_advance_status(uuid, text, text, text, text) to authenticated;
grant execute on function public.admin_purchase_settings_get() to authenticated;
grant execute on function public.admin_purchase_settings_set(numeric, numeric, numeric, numeric, numeric, numeric, numeric, integer, text, boolean) to authenticated;
grant execute on function public.admin_purchase_sim_merchants() to authenticated;
grant execute on function public.admin_purchase_sim_messages(text) to authenticated;
grant execute on function public.admin_purchase_sim_append(text, text, text, text, jsonb) to authenticated;
grant execute on function public.admin_purchase_sim_reset(text) to authenticated;
grant execute on function public.admin_purchase_sim_create(uuid, text, text, text, text, text, text, integer, text, numeric, numeric, numeric, boolean, boolean, text, text, numeric) to authenticated;
grant execute on function public.admin_purchase_sim_report_payment(uuid, text, text, text, text, numeric, text, text) to authenticated;
grant execute on function public.admin_purchase_sim_requests(text) to authenticated;
