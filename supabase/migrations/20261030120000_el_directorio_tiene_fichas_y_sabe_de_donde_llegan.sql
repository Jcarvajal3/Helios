-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El directorio tiene una ficha por médico y sabe de dónde llegan
--
-- Javier (2026-10-30): el directorio sale en Google. Para competir con los
-- directorios médicos («Los 20 ginecólogos en Caracas…») cada médico tiene su
-- página (`/medico/<enlace>`) y cada especialidad la suya
-- (`/directorio/<especialidad>`), y para saber qué buscador trae pacientes,
-- cada clic al WhatsApp guarda de dónde vino la visita.
--
--   1. `directory_listings.slug`: el enlace de la ficha («dra-ana-lara»).
--      Nace la primera vez que el médico sale publicado y NO cambia después
--      (aunque cambie el nombre): un enlace que Google ya conoce no se rompe.
--      Único; si dos se llaman igual, el segundo lleva «-2».
--   2. `helios_directorio()` devuelve también `slug` y `updated_at` (la fecha
--      del sitemap). Cambian las columnas, así que se borra y se crea.
--   3. `helios_directorio_medico(p_slug)`: un médico publicado por su enlace,
--      con las mismas columnas. Nada si no existe o ya no sale.
--   4. `directory_contact_clicks` guarda el origen de la visita: la fuente
--      («google», «chatgpt», «instagram», «directo»…, la decide el panel),
--      el dominio que la mandó, la página por la que entró, la página donde
--      tocó el botón y las `utm_*`. Nada de la persona: ni IP ni navegador.
--      `helios_directorio_contacto` recibe todo eso en `p_origen` (jsonb) y
--      descarta lo que no tenga la forma esperada.
--   5. `admin_directorio_origenes(p_dias)`: los clics públicos por fuente,
--      por página de entrada y por página del clic. Solo el equipo.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. El enlace de cada ficha
-- ---------------------------------------------------------------------------

alter table public.directory_listings
  add column slug text check (slug is null or (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) <= 90));

create unique index directory_listings_slug_key on public.directory_listings (slug) where slug is not null;

comment on column public.directory_listings.slug is
  'El enlace de la ficha pública (/medico/<slug>). Nace al publicarse por primera vez y no cambia: los buscadores ya lo conocen.';

/** «Dra. María de Lourdes Asbati» → «dra-maria-de-lourdes-asbati». */
create or replace function public.helios_directorio_slug_base(p_name text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select btrim(left(btrim(regexp_replace(
           translate(lower(coalesce(p_name, '')),
                     'áàäâãåéèëêíìïîóòöôõúùüûñç', 'aaaaaaeeeeiiiiooooouuuunc'),
           '[^a-z0-9]+', '-', 'g'), '-'), 80), '-');
$$;

/** El enlace libre para un médico: la base, o la base con «-2», «-3»… */
create or replace function public.helios_directorio_slug_nuevo(p_name text, p_merchant_id uuid)
returns text
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_base  text := coalesce(nullif(public.helios_directorio_slug_base(p_name), ''), 'medico');
  v_slug  text := v_base;
  v_n     integer := 1;
begin
  while exists (
    select 1 from public.directory_listings l
     where l.slug = v_slug and l.merchant_id <> p_merchant_id
  ) loop
    v_n := v_n + 1;
    v_slug := v_base || '-' || v_n;
  end loop;
  return v_slug;
end;
$$;

revoke all on function public.helios_directorio_slug_base(text) from public, anon, authenticated;
revoke all on function public.helios_directorio_slug_nuevo(text, uuid) from public, anon, authenticated;

/** Al publicarse por primera vez, el médico recibe su enlace. */
create or replace function public.helios_directorio_pone_slug()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.is_visible and new.slug is null then
    new.slug := public.helios_directorio_slug_nuevo(
      coalesce(new.display_name, public.helios_doctor_name(new.merchant_id)),
      new.merchant_id
    );
  end if;
  return new;
end;
$$;

revoke all on function public.helios_directorio_pone_slug() from public, anon, authenticated;

create trigger directory_listings_pone_slug
  before insert or update of is_visible on public.directory_listings
  for each row execute function public.helios_directorio_pone_slug();

-- Los que ya están publicados, en el orden en que se publicaron (el primero
-- se queda el enlace sin número). Solo se escribe `slug`: ni `updated_at`
-- ni la bitácora, porque no cambia nada de lo que se ve.
do $$
declare
  v_l record;
begin
  for v_l in
    select l.merchant_id, f.name
      from public.directory_listings l
      join public.helios_directorio_fichas() f on f.merchant_id = l.merchant_id
     where l.is_visible and l.slug is null
     order by l.published_at nulls last, l.merchant_id
  loop
    update public.directory_listings
       set slug = public.helios_directorio_slug_nuevo(v_l.name, v_l.merchant_id)
     where merchant_id = v_l.merchant_id;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2 y 3. La página pública y la ficha
-- ---------------------------------------------------------------------------

drop function public.helios_directorio();

create function public.helios_directorio()
returns table (
  merchant_id    uuid,
  name           text,
  specialty      text,
  specialty_key  text,
  address        text,
  city           text,
  whatsapp       text,
  social_network text,
  social_user    text,
  lead_code      text,
  slug           text,
  updated_at     timestamptz
)
language sql
volatile
security definer
set search_path = public, pg_temp
as $$
  select f.merchant_id, f.name, f.specialty, f.specialty_key, f.address, f.city, f.whatsapp,
         f.social_network, f.social_user, l.lead_code, l.slug, l.updated_at
    from public.helios_directorio_fichas() f
    join public.directory_listings l on l.merchant_id = f.merchant_id
    left join lateral (
      select count(*) as clics
        from public.directory_contact_clicks c
       where c.merchant_id = f.merchant_id
         and c.origin = 'publico'
         and c.created_at > now() - interval '7 days'
    ) k on true
   where f.is_visible and f.blocked_reason is null
   -- El sorteo ponderado de 20261029100000: menos clics, más probable salir arriba.
   order by power(random(), 1 + coalesce(k.clics, 0)) desc;
$$;

comment on function public.helios_directorio() is
  'Directorio de médicos: las clínicas publicadas (visibles, activas, no de prueba y con WhatsApp) con lo que enseña su tarjeta, red social, código (DIR-XXXX), enlace de su ficha y fecha del último cambio, en un orden sorteado en cada llamada que favorece a quien tiene menos clics públicos en 7 días. Pública.';

revoke all on function public.helios_directorio() from public;
grant execute on function public.helios_directorio() to anon, authenticated;

create or replace function public.helios_directorio_medico(p_slug text)
returns table (
  merchant_id    uuid,
  name           text,
  specialty      text,
  specialty_key  text,
  address        text,
  city           text,
  whatsapp       text,
  social_network text,
  social_user    text,
  lead_code      text,
  slug           text,
  updated_at     timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select f.merchant_id, f.name, f.specialty, f.specialty_key, f.address, f.city, f.whatsapp,
         f.social_network, f.social_user, l.lead_code, l.slug, l.updated_at
    from public.directory_listings l
    join public.helios_directorio_fichas() f on f.merchant_id = l.merchant_id
   where l.slug = lower(btrim(coalesce(p_slug, '')))
     and f.is_visible and f.blocked_reason is null;
$$;

comment on function public.helios_directorio_medico(text) is
  'Directorio de médicos: un médico publicado por el enlace de su ficha (/medico/<slug>), con las columnas de helios_directorio(). Nada si no existe o ya no sale. Pública.';

revoke all on function public.helios_directorio_medico(text) from public;
grant execute on function public.helios_directorio_medico(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. De dónde llega cada clic
-- ---------------------------------------------------------------------------

alter table public.directory_contact_clicks
  add column source        text check (source is null or source ~ '^[a-z0-9.-]{1,40}$'),
  add column referrer_host text check (referrer_host is null or referrer_host ~ '^[a-z0-9.-]{1,100}$'),
  add column landing_path  text check (landing_path is null or (landing_path ~ '^/' and char_length(landing_path) <= 200)),
  add column page_path     text check (page_path is null or (page_path ~ '^/' and char_length(page_path) <= 200)),
  add column utm_source    text check (utm_source is null or char_length(utm_source) <= 100),
  add column utm_medium    text check (utm_medium is null or char_length(utm_medium) <= 100),
  add column utm_campaign  text check (utm_campaign is null or char_length(utm_campaign) <= 100);

comment on column public.directory_contact_clicks.source is
  'De dónde vino la visita: google, bing, chatgpt, perplexity, instagram, directo… (lo clasifica el panel). Null en los clics de antes del 2026-10-30.';

drop function public.helios_directorio_contacto(uuid, text);

/**
 * Lo de 20261026190000 (todo igual) más el origen de la visita en
 * `p_origen`: `{ fuente, dominio, entrada, pagina, utm_source, utm_medium,
 * utm_campaign }`. Cada dato que no tenga la forma esperada se descarta (no
 * se rechaza el clic): es pública y no se fía de nadie.
 */
create function public.helios_directorio_contacto(
  p_merchant_id uuid,
  p_visitante   text default null,
  p_origen      jsonb default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_visitante text := case when p_visitante ~ '^[A-Za-z0-9-]{8,64}$' then p_visitante end;
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
    merchant_id, visitor_id, origin,
    source, referrer_host, landing_path, page_path, utm_source, utm_medium, utm_campaign
  )
  values (
    p_merchant_id, v_visitante, v_origen,
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

comment on function public.helios_directorio_contacto(uuid, text, jsonb) is
  'Directorio de médicos: apunta un toque al botón de WhatsApp de una tarjeta publicada, con el origen de la visita (fuente, dominio, página de entrada y del clic, utm). Pública; descarta el doble toque (30 s) y más de 30 clics de un navegador al día.';

revoke all on function public.helios_directorio_contacto(uuid, text, jsonb) from public;
grant execute on function public.helios_directorio_contacto(uuid, text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Los orígenes, para el superadmin
-- ---------------------------------------------------------------------------

/**
 * Los clics públicos de los últimos `p_dias` días operativos (con hoy), por
 * fuente, por página de entrada y por página del clic. Los clics de antes del
 * 2026-10-30 no tienen origen: van como «sin_dato».
 */
create or replace function public.admin_directorio_origenes(p_dias integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_dias  integer := least(greatest(coalesce(p_dias, 30), 1), 365);
  v_desde timestamptz := ((public.helios_business_date(now()) - (v_dias - 1))::timestamp at time zone 'America/Caracas');
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'dias', v_dias,
    'por_fuente', coalesce((
      select jsonb_agg(jsonb_build_object('fuente', x.fuente, 'clics', x.clics, 'visitantes', x.visitantes)
                       order by x.clics desc, x.fuente)
        from (
          select coalesce(c.source, 'sin_dato') as fuente, count(*) as clics,
                 count(distinct c.visitor_id) as visitantes
            from public.directory_contact_clicks c
           where c.origin = 'publico' and c.created_at >= v_desde
           group by 1
        ) x
    ), '[]'::jsonb),
    'por_entrada', coalesce((
      select jsonb_agg(jsonb_build_object('pagina', x.pagina, 'clics', x.clics) order by x.clics desc, x.pagina)
        from (
          select coalesce(c.landing_path, 'sin_dato') as pagina, count(*) as clics
            from public.directory_contact_clicks c
           where c.origin = 'publico' and c.created_at >= v_desde
           group by 1
           order by 2 desc
           limit 20
        ) x
    ), '[]'::jsonb),
    'por_pagina', coalesce((
      select jsonb_agg(jsonb_build_object('pagina', x.pagina, 'clics', x.clics) order by x.clics desc, x.pagina)
        from (
          select coalesce(c.page_path, 'sin_dato') as pagina, count(*) as clics
            from public.directory_contact_clicks c
           where c.origin = 'publico' and c.created_at >= v_desde
           group by 1
           order by 2 desc
           limit 20
        ) x
    ), '[]'::jsonb)
  );
end;
$$;

comment on function public.admin_directorio_origenes(integer) is
  'Directorio de médicos: los clics públicos al WhatsApp de los últimos p_dias días por fuente (google, chatgpt, instagram, directo…), por página de entrada y por página del clic. Solo el equipo de Helios.';

revoke all on function public.admin_directorio_origenes(integer) from public, anon;
grant execute on function public.admin_directorio_origenes(integer) to authenticated;
