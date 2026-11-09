-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — La prueba A/B del directorio: `/consultas`, con inicial de $15
--
-- Javier (2026-11-09), contrato en docs/06-PRUEBA-AB-DEL-DIRECTORIO.md. Dos
-- directorios conviven y se comparan en el superadmin:
--
--   A. `/directorio` (y sus especialidades y fichas): el de siempre.
--   B. `/consultas`: «¡Consultas médicas por solo $15 de inicial!», solo con
--      los médicos cuya consulta vale más de $15 y como mucho $60 (una en
--      euros, por su equivalente en dólares con la tasa cruzada BCV del día).
--      El botón lleva al WhatsApp de Helios con el código y la marca de B.
--
-- La inicial es solo texto de la página: el cobro no cambia.
--
--   1. Cada clic (`directory_contact_clicks.variant`) y cada interesado
--      (`directory_leads.variant`) dicen de qué variante vienen. Lo que ya
--      existía queda en 'a'.
--   2. `helios_directorio_contacto` recibe `p_variante` (cambia la firma: se
--      borra la de 3 argumentos y se crea la de 4; llamarla con 3 sigue
--      valiendo).
--   3. Las visitas: `directory_page_views` y `helios_directorio_visita`. Hasta
--      hoy solo se apuntaban los clics.
--   4. `bot_directorio_interesado` recibe `p_variante` y la guarda al crear el
--      interesado; el webhook desplegado (sin ella) sigue funcionando.
--   5. La regla de B: `helios_consultas_tope_usd()` (60),
--      `helios_consultas_inicial_usd()` (15), el precio en dólares
--      (`helios_directorio_precio_usd`) y `helios_consultas_entra`.
--   6. `helios_directorio_consultas()`: la página de B, con las columnas de
--      `helios_directorio()` más `consultation_price_usd`, en su orden sorteado.
--   7. `admin_directorio_ab(p_desde, p_hasta)`: las cifras de la prueba.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. La variante de cada clic y de cada interesado
-- ---------------------------------------------------------------------------

alter table public.directory_contact_clicks
  add column variant text not null default 'a' check (variant in ('a', 'b'));

comment on column public.directory_contact_clicks.variant is
  'Prueba A/B del directorio (docs/06): a = /directorio y sus fichas, b = /consultas. Los clics de antes del 2026-11-09 son a.';

alter table public.directory_leads
  add column variant text not null default 'a' check (variant in ('a', 'b'));

comment on column public.directory_leads.variant is
  'Prueba A/B del directorio (docs/06): la variante del primer mensaje (código DIR-XXXX-B = b). No cambia si la persona vuelve a escribir desde la otra.';

-- ---------------------------------------------------------------------------
-- 2. El clic al WhatsApp, con su variante
-- ---------------------------------------------------------------------------

drop function public.helios_directorio_contacto(uuid, text, jsonb);

/**
 * Lo de 20261030120000 (todo igual) más `p_variante`: 'b' si el toque fue en
 * `/consultas`; cualquier otra cosa (o nada) cuenta como 'a'. Los límites del
 * doble toque (30 s) y de 30 clics al día no miran la variante.
 */
create function public.helios_directorio_contacto(
  p_merchant_id uuid,
  p_visitante   text default null,
  p_origen      jsonb default null,
  p_variante    text default 'a'
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_visitante text := case when p_visitante ~ '^[A-Za-z0-9-]{8,64}$' then p_visitante end;
  v_variante  text := case when lower(btrim(coalesce(p_variante, ''))) = 'b' then 'b' else 'a' end;
  v_uid       uuid := auth.uid();
  v_origen    text := 'publico';
  v_o         jsonb := case when jsonb_typeof(p_origen) = 'object' then p_origen else '{}'::jsonb end;
  v_fuente    text := lower(v_o ->> 'fuente');
  v_dominio   text := lower(v_o ->> 'dominio');
  v_entrada   text := v_o ->> 'entrada';
  v_pagina    text := v_o ->> 'pagina';
begin
  if not exists (
    select 1 from public.helios_directorio_fichas() f
     where f.merchant_id = p_merchant_id and f.is_visible and f.blocked_reason is null
  ) then
    return false;
  end if;

  if v_visitante is not null then
    if exists (
      select 1 from public.directory_contact_clicks c
       where c.visitor_id = v_visitante and c.merchant_id = p_merchant_id
         and c.created_at > now() - interval '30 seconds'
    ) then
      return false;
    end if;
    if (select count(*) from public.directory_contact_clicks c
         where c.visitor_id = v_visitante and c.created_at > now() - interval '1 day') >= 30 then
      return false;
    end if;
  end if;

  if v_uid is not null then
    if exists (select 1 from public.platform_admins pa where pa.user_id = v_uid) then
      v_origen := 'equipo';
    elsif exists (select 1 from public.merchant_users mu where mu.user_id = v_uid and mu.is_active) then
      v_origen := 'clinica';
    end if;
  end if;

  insert into public.directory_contact_clicks (
    merchant_id, visitor_id, origin, variant,
    source, referrer_host, landing_path, page_path, utm_source, utm_medium, utm_campaign
  )
  values (
    p_merchant_id, v_visitante, v_origen, v_variante,
    case when v_fuente ~ '^[a-z0-9.-]{1,40}$' then v_fuente end,
    case when v_dominio ~ '^[a-z0-9.-]{1,100}$' then v_dominio end,
    case when v_entrada ~ '^/' and char_length(v_entrada) <= 200 then v_entrada end,
    case when v_pagina ~ '^/' and char_length(v_pagina) <= 200 then v_pagina end,
    nullif(left(btrim(v_o ->> 'utm_source'), 100), ''),
    nullif(left(btrim(v_o ->> 'utm_medium'), 100), ''),
    nullif(left(btrim(v_o ->> 'utm_campaign'), 100), '')
  );

  return true;
end;
$$;

comment on function public.helios_directorio_contacto(uuid, text, jsonb, text) is
  'Directorio de médicos: apunta un toque al botón de WhatsApp de una tarjeta publicada, con el origen de la visita (fuente, dominio, página de entrada y del clic, utm) y la variante de la prueba A/B (b = /consultas; lo demás, a). Pública; descarta el doble toque (30 s) y más de 30 clics de un navegador al día.';

revoke all on function public.helios_directorio_contacto(uuid, text, jsonb, text) from public;
grant execute on function public.helios_directorio_contacto(uuid, text, jsonb, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Las visitas
-- ---------------------------------------------------------------------------

create table public.directory_page_views (
  id            uuid primary key default gen_random_uuid(),
  variant       text not null check (variant in ('a', 'b')),
  -- El identificador aleatorio del navegador que ya usa el directorio.
  visitor_id    text check (visitor_id is null or visitor_id ~ '^[A-Za-z0-9-]{8,64}$'),
  -- La misma regla que los clics: el equipo y el personal de las clínicas no cuentan.
  origin        text not null default 'publico' check (origin in ('publico', 'equipo', 'clinica')),
  source        text check (source is null or source ~ '^[a-z0-9.-]{1,40}$'),
  referrer_host text check (referrer_host is null or referrer_host ~ '^[a-z0-9.-]{1,100}$'),
  landing_path  text check (landing_path is null or (landing_path ~ '^/' and char_length(landing_path) <= 200)),
  page_path     text check (page_path is null or (page_path ~ '^/' and char_length(page_path) <= 200)),
  utm_source    text check (utm_source is null or char_length(utm_source) <= 100),
  utm_medium    text check (utm_medium is null or char_length(utm_medium) <= 100),
  utm_campaign  text check (utm_campaign is null or char_length(utm_campaign) <= 100),
  created_at    timestamptz not null default now()
);

comment on table public.directory_page_views is
  'Prueba A/B del directorio (docs/06): cada vez que alguien abre /directorio, /directorio/<especialidad> o /medico/<slug> (a) o /consultas (b). Nada de la persona: ni IP ni navegador, solo el identificador aleatorio del directorio. Solo por RPC (helios_directorio_visita, admin_directorio_ab).';

create index directory_page_views_variant_created_idx on public.directory_page_views (variant, created_at);
create index directory_page_views_visitor_created_idx on public.directory_page_views (visitor_id, created_at);

-- Se tocan solo por las RPC de abajo, que son security definer.
alter table public.directory_page_views enable row level security;
revoke all on table public.directory_page_views from public, anon, authenticated;

/**
 * Apunta una visita a una página del directorio. `p_variante`: 'a' o 'b' (sin
 * distinguir mayúsculas); otra cosa no se apunta. `p_origen`, como en
 * `helios_directorio_contacto` (cada dato malformado se descarta). Devuelve
 * `false` y no apunta nada si el mismo navegador ya abrió esa misma página
 * (misma variante y `pagina`) en los últimos 30 minutos, o si ya lleva 200
 * visitas en las últimas 24 horas. Sin visitante no hay forma de descartar:
 * se apunta.
 */
create or replace function public.helios_directorio_visita(
  p_variante  text,
  p_visitante text default null,
  p_origen    jsonb default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_variante  text := lower(btrim(coalesce(p_variante, '')));
  v_visitante text := case when p_visitante ~ '^[A-Za-z0-9-]{8,64}$' then p_visitante end;
  v_uid       uuid := auth.uid();
  v_origen    text := 'publico';
  v_o         jsonb := case when jsonb_typeof(p_origen) = 'object' then p_origen else '{}'::jsonb end;
  v_fuente    text := lower(v_o ->> 'fuente');
  v_dominio   text := lower(v_o ->> 'dominio');
  v_entrada   text := v_o ->> 'entrada';
  v_pagina    text := v_o ->> 'pagina';
begin
  if v_variante not in ('a', 'b') then
    return false;
  end if;

  v_fuente  := case when v_fuente ~ '^[a-z0-9.-]{1,40}$' then v_fuente end;
  v_dominio := case when v_dominio ~ '^[a-z0-9.-]{1,100}$' then v_dominio end;
  v_entrada := case when v_entrada ~ '^/' and char_length(v_entrada) <= 200 then v_entrada end;
  v_pagina  := case when v_pagina ~ '^/' and char_length(v_pagina) <= 200 then v_pagina end;

  if v_visitante is not null then
    if exists (
      select 1 from public.directory_page_views v
       where v.visitor_id = v_visitante
         and v.variant = v_variante
         and v.page_path is not distinct from v_pagina
         and v.created_at > now() - interval '30 minutes'
    ) then
      return false;
    end if;
    if (select count(*) from public.directory_page_views v
         where v.visitor_id = v_visitante and v.created_at > now() - interval '1 day') >= 200 then
      return false;
    end if;
  end if;

  if v_uid is not null then
    if exists (select 1 from public.platform_admins pa where pa.user_id = v_uid) then
      v_origen := 'equipo';
    elsif exists (select 1 from public.merchant_users mu where mu.user_id = v_uid and mu.is_active) then
      v_origen := 'clinica';
    end if;
  end if;

  insert into public.directory_page_views (
    variant, visitor_id, origin,
    source, referrer_host, landing_path, page_path, utm_source, utm_medium, utm_campaign
  )
  values (
    v_variante, v_visitante, v_origen,
    v_fuente, v_dominio, v_entrada, v_pagina,
    nullif(left(btrim(v_o ->> 'utm_source'), 100), ''),
    nullif(left(btrim(v_o ->> 'utm_medium'), 100), ''),
    nullif(left(btrim(v_o ->> 'utm_campaign'), 100), '')
  );

  return true;
end;
$$;

comment on function public.helios_directorio_visita(text, text, jsonb) is
  'Prueba A/B del directorio: apunta una visita a una página de la variante a (/directorio, sus especialidades y fichas) o b (/consultas), con el origen como los clics. Pública; descarta la misma página del mismo navegador en 30 minutos y más de 200 visitas de un navegador al día.';

revoke all on function public.helios_directorio_visita(text, text, jsonb) from public;
grant execute on function public.helios_directorio_visita(text, text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. El bot, con la variante
-- ---------------------------------------------------------------------------

drop function public.bot_directorio_interesado(text, text, text);

/**
 * Lo de 20261027100000 (todo igual) más `p_variante`: 'b' si el mensaje
 * traía el código con la marca de B (`DIR-7K2P-B`); cualquier otra cosa (o
 * nada, como el webhook de antes) es 'a'. Se guarda solo al crear el
 * interesado: si ese teléfono ya había escrito por ese médico, conserva la
 * suya. Devuelve además `variante`: la guardada.
 */
create function public.bot_directorio_interesado(
  p_phone      text,
  p_code       text,
  p_message_id text,
  p_variante   text default 'a'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tel      text := public.helios_wa_e164(p_phone);
  v_codigo   text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_mid      text := nullif(btrim(coalesce(p_message_id, '')), '');
  v_variante text := case when lower(btrim(coalesce(p_variante, ''))) = 'b' then 'b' else 'a' end;
  v_merchant uuid;
  v_f        record;
  v_id       uuid;
  v_mensajes integer;
  v_nuevo    boolean;
  v_guardada text;
begin
  if v_tel is null then
    raise exception 'Teléfono inválido: %', p_phone using errcode = '22023';
  end if;

  select l.merchant_id into v_merchant from public.directory_listings l where l.lead_code = v_codigo;
  if v_merchant is null then
    return jsonb_build_object('ok', false, 'motivo', 'codigo_desconocido');
  end if;

  select * into v_f from public.helios_directorio_fichas() f where f.merchant_id = v_merchant;
  if v_f.merchant_id is null or not v_f.is_visible or v_f.blocked_reason is not null then
    return jsonb_build_object('ok', false, 'motivo', 'no_publicado');
  end if;

  insert into public.directory_leads as d (merchant_id, phone_e164, first_message_id, variant)
  values (v_merchant, v_tel, v_mid, v_variante)
  on conflict (merchant_id, phone_e164) do update set
    messages = d.messages + case when excluded.first_message_id = d.first_message_id then 0 else 1 end,
    last_at = now()
  returning d.id, d.messages, (d.xmax = 0), d.variant into v_id, v_mensajes, v_nuevo, v_guardada;

  return jsonb_build_object(
    'ok', true,
    'nuevo', v_nuevo,
    'lead_id', v_id,
    'messages', v_mensajes,
    'merchant_id', v_merchant,
    'name', v_f.name,
    'specialty', v_f.specialty,
    'address', v_f.address,
    'city', v_f.city,
    'whatsapp', v_f.whatsapp,
    'variante', v_guardada
  );
end;
$$;

comment on function public.bot_directorio_interesado(text, text, text, text) is
  'Directorio de médicos: el webhook guarda (o pone al día) a quien escribió con el código DIR-XXXX de una tarjeta publicada, con la variante de la prueba A/B (b si traía -B; se guarda al crearlo), y recibe el contacto del médico. Solo service_role.';

revoke all on function public.bot_directorio_interesado(text, text, text, text) from public, anon, authenticated;
grant execute on function public.bot_directorio_interesado(text, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 5. La regla de B
-- ---------------------------------------------------------------------------

/** El tope de la consulta para salir en `/consultas`, en dólares: $60 (incluido). */
create or replace function public.helios_consultas_tope_usd()
returns numeric
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$ select 60::numeric $$;

/** La inicial que anuncia `/consultas`, en dólares: $15. Solo texto: el cobro no cambia. */
create or replace function public.helios_consultas_inicial_usd()
returns numeric
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$ select 15::numeric $$;

comment on function public.helios_consultas_tope_usd() is
  'Prueba A/B del directorio: una consulta sale en /consultas si vale como mucho esto, en dólares (60).';
comment on function public.helios_consultas_inicial_usd() is
  'Prueba A/B del directorio: la inicial que anuncia /consultas, en dólares (15). Solo texto; además la consulta tiene que valer más que esto.';

revoke all on function public.helios_consultas_tope_usd() from public;
revoke all on function public.helios_consultas_inicial_usd() from public;
grant execute on function public.helios_consultas_tope_usd() to anon, authenticated;
grant execute on function public.helios_consultas_inicial_usd() to anon, authenticated;

/**
 * El precio de la tarjeta en dólares, a dos decimales: en dólares, tal cual;
 * en euros, por la tasa cruzada BCV de hoy (`BCV_EUR / BCV`, la última con
 * `effective_date` ≤ hoy en Caracas, redondeada a 6 decimales: el mismo
 * cálculo que `helios_usd_per_unit`, pero sin lanzar). Null sin precio, sin
 * tasa o con otra moneda. No se expone.
 */
create or replace function public.helios_directorio_precio_usd(p_precio numeric, p_moneda text)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_usd numeric;
  v_eur numeric;
begin
  if p_precio is null then
    return null;
  end if;

  case upper(coalesce(p_moneda, 'USD'))
    when 'USD' then
      return round(p_precio, 2);
    when 'EUR' then
      v_usd := public.helios_fx_rate('USD');
      v_eur := public.helios_fx_rate('EUR');
      if v_usd is null or v_usd <= 0 or v_eur is null or v_eur <= 0 then
        return null;
      end if;
      return round(p_precio * round(v_eur / v_usd, 6), 2);
    else
      return null;
  end case;
end;
$$;

revoke all on function public.helios_directorio_precio_usd(numeric, text) from public, anon, authenticated;

/** ¿Una consulta de este precio (en dólares) sale en `/consultas`? Más de $15 y como mucho $60. */
create or replace function public.helios_consultas_entra(p_precio_usd numeric)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(p_precio_usd > public.helios_consultas_inicial_usd()
                  and p_precio_usd <= public.helios_consultas_tope_usd(), false);
$$;

revoke all on function public.helios_consultas_entra(numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. La página de B
-- ---------------------------------------------------------------------------

/**
 * Los médicos de `helios_directorio()` que entran en `/consultas`, con las
 * mismas columnas en el mismo orden y `consultation_price_usd` al final, en
 * el orden sorteado de esa llamada (se filtra sin reordenar). Sin precio, o
 * en euros sin tasa del euro, no entra.
 */
create or replace function public.helios_directorio_consultas()
returns table (
  merchant_id            uuid,
  name                   text,
  specialty              text,
  specialty_key          text,
  address                text,
  city                   text,
  whatsapp               text,
  social_network         text,
  social_user            text,
  lead_code              text,
  slug                   text,
  updated_at             timestamptz,
  consultation_price_cur numeric,
  consultation_currency  text,
  consultation_price_usd numeric
)
language sql
volatile
security definer
set search_path = public, pg_temp
as $$
  select d.merchant_id, d.name, d.specialty, d.specialty_key, d.address, d.city, d.whatsapp,
         d.social_network, d.social_user, d.lead_code, d.slug, d.updated_at,
         d.consultation_price_cur, d.consultation_currency, x.usd
    from public.helios_directorio() with ordinality as d(
           merchant_id, name, specialty, specialty_key, address, city, whatsapp,
           social_network, social_user, lead_code, slug, updated_at,
           consultation_price_cur, consultation_currency, n)
    cross join lateral (
      select public.helios_directorio_precio_usd(d.consultation_price_cur, d.consultation_currency) as usd
    ) x
   where public.helios_consultas_entra(x.usd)
   order by d.n;
$$;

comment on function public.helios_directorio_consultas() is
  'Prueba A/B del directorio: los médicos publicados cuya consulta vale más de $15 y como mucho $60 (en euros, por la tasa cruzada BCV de hoy), con las columnas de helios_directorio() más consultation_price_usd, en su mismo orden sorteado. Es la página /consultas. Pública.';

revoke all on function public.helios_directorio_consultas() from public;
grant execute on function public.helios_directorio_consultas() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Las cifras de la prueba, para el superadmin
-- ---------------------------------------------------------------------------

/**
 * La prueba A/B entre `p_desde` y `p_hasta` (días de Caracas, los dos
 * incluidos; como mucho 366 días; sin `p_hasta`, hoy; sin `p_desde`, los 7
 * días que acaban en `p_hasta`). Solo lo público (`origin = 'publico'`).
 *
 *   · `variantes`: por variante, las visitas, los visitantes distintos
 *     (`coalesce(visitor_id, id)`), los clics, los visitantes distintos con
 *     algún clic de esa variante en el rango, los interesados (por su primer
 *     mensaje) y, de esos, los convertidos (`helios_directorio_conversion`).
 *   · `dias`: todos los días del rango, también los vacíos.
 *   · `medicos`: los que entran hoy en B y cualquiera con un clic o un
 *     interesado de B en el rango, el de más clics primero.
 *   · `excluidos`: las visitas y los clics del equipo y de las clínicas.
 *   · `visitas_desde`: el día de la primera visita apuntada (o null).
 */
create or replace function public.admin_directorio_ab(p_desde date, p_hasta date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hasta date := coalesce(p_hasta, public.helios_business_date(now()));
  v_desde date := coalesce(p_desde, coalesce(p_hasta, public.helios_business_date(now())) - 6);
  v_ini   timestamptz;
  v_fin   timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;
  if v_desde > v_hasta then
    raise exception 'El rango empieza después de terminar' using errcode = '22023';
  end if;
  if v_hasta - v_desde + 1 > 366 then
    raise exception 'El rango no puede pasar de 366 días' using errcode = '22023';
  end if;

  v_ini := v_desde::timestamp at time zone 'America/Caracas';
  v_fin := (v_hasta + 1)::timestamp at time zone 'America/Caracas';

  return (
    with vis as (
      select v.variant, public.helios_business_date(v.created_at) as dia,
             coalesce(v.visitor_id, v.id::text) as quien
        from public.directory_page_views v
       where v.origin = 'publico' and v.created_at >= v_ini and v.created_at < v_fin
    ),
    cli as (
      select c.variant, c.merchant_id, public.helios_business_date(c.created_at) as dia,
             coalesce(c.visitor_id, 'clic-' || c.id::text) as quien
        from public.directory_contact_clicks c
       where c.origin = 'publico' and c.created_at >= v_ini and c.created_at < v_fin
    ),
    lea as (
      select l.variant, l.merchant_id, (cv.charge_id is not null) as convertido
        from public.directory_leads l
        left join lateral public.helios_directorio_conversion(l.merchant_id, l.phone_e164, l.first_at) cv on true
       where l.first_at >= v_ini and l.first_at < v_fin
    ),
    var as (
      select * from (values ('a', '/directorio', 1), ('b', '/consultas', 2)) x(variante, ruta, orden)
    ),
    dias as (
      select s.dia::date as dia from generate_series(v_desde, v_hasta, interval '1 day') s(dia)
    ),
    med as (
      select f.merchant_id, f.name as medico, f.consultation_price_cur, f.consultation_currency,
             (f.is_visible and f.blocked_reason is null
              and public.helios_consultas_entra(
                    public.helios_directorio_precio_usd(f.consultation_price_cur, f.consultation_currency))) as en_b,
             (select count(*) from cli where cli.merchant_id = f.merchant_id and cli.variant = 'a') as clics_a,
             (select count(*) from cli where cli.merchant_id = f.merchant_id and cli.variant = 'b') as clics_b,
             (select count(*) from lea where lea.merchant_id = f.merchant_id and lea.variant = 'b') as interesados_b,
             (select count(*) from lea where lea.merchant_id = f.merchant_id and lea.variant = 'b'
                                         and lea.convertido) as convertidos_b
        from public.helios_directorio_fichas() f
    )
    select jsonb_build_object(
      'desde', v_desde,
      'hasta', v_hasta,
      'variantes', (
        select jsonb_agg(jsonb_build_object(
                 'variante', var.variante,
                 'ruta', var.ruta,
                 'visitas', (select count(*) from vis where vis.variant = var.variante),
                 'visitantes', (select count(distinct vis.quien) from vis where vis.variant = var.variante),
                 'clics', (select count(*) from cli where cli.variant = var.variante),
                 'visitantes_con_clic', (select count(distinct cli.quien) from cli where cli.variant = var.variante),
                 'interesados', (select count(*) from lea where lea.variant = var.variante),
                 'convertidos', (select count(*) from lea where lea.variant = var.variante and lea.convertido)
               ) order by var.orden)
          from var
      ),
      'dias', (
        select jsonb_agg(jsonb_build_object(
                 'dia', dias.dia,
                 'a', jsonb_build_object(
                   'visitantes', (select count(distinct vis.quien) from vis where vis.dia = dias.dia and vis.variant = 'a'),
                   'visitantes_con_clic', (select count(distinct cli.quien) from cli where cli.dia = dias.dia and cli.variant = 'a'),
                   'clics', (select count(*) from cli where cli.dia = dias.dia and cli.variant = 'a')),
                 'b', jsonb_build_object(
                   'visitantes', (select count(distinct vis.quien) from vis where vis.dia = dias.dia and vis.variant = 'b'),
                   'visitantes_con_clic', (select count(distinct cli.quien) from cli where cli.dia = dias.dia and cli.variant = 'b'),
                   'clics', (select count(*) from cli where cli.dia = dias.dia and cli.variant = 'b'))
               ) order by dias.dia)
          from dias
      ),
      'medicos', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'merchant_id', med.merchant_id,
                 'medico', med.medico,
                 'precio_cur', trim_scale(med.consultation_price_cur),
                 'moneda', med.consultation_currency,
                 'en_b', med.en_b,
                 'clics_a', med.clics_a,
                 'clics_b', med.clics_b,
                 'interesados_b', med.interesados_b,
                 'convertidos_b', med.convertidos_b
               ) order by med.clics_a + med.clics_b desc, med.medico, med.merchant_id)
          from med
         where med.en_b or med.clics_a + med.clics_b > 0 or med.interesados_b > 0
      ), '[]'::jsonb),
      'excluidos', jsonb_build_object(
        'visitas_equipo', (
          select count(*) from public.directory_page_views v
           where v.origin <> 'publico' and v.created_at >= v_ini and v.created_at < v_fin),
        'clics_equipo', (
          select count(*) from public.directory_contact_clicks c
           where c.origin <> 'publico' and c.created_at >= v_ini and c.created_at < v_fin)
      ),
      'visitas_desde', (select min(public.helios_business_date(v.created_at)) from public.directory_page_views v)
    )
  );
end;
$$;

comment on function public.admin_directorio_ab(date, date) is
  'Prueba A/B del directorio (docs/06): entre dos días de Caracas (incluidos, hasta 366), por variante (a = /directorio, b = /consultas) las visitas, visitantes, clics, visitantes con clic, interesados y convertidos; la serie diaria; los médicos de B y los que tuvieron clics; lo excluido del equipo y el primer día con visitas. Solo lo público. Los dos roles.';

revoke all on function public.admin_directorio_ab(date, date) from public, anon;
grant execute on function public.admin_directorio_ab(date, date) to authenticated;
