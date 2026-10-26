-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — La tarjeta del directorio enseña la red social del médico
--
-- Javier (2026-10-26): si el médico tiene red social, va en su tarjeta de
-- `/directorio`. Es un dato más de la tarjeta, como los de 20261026190000:
-- por defecto el de la ficha (`merchants.social_network` y `social_user`, los
-- que pide el alta desde 20261023130000) y el equipo lo puede corregir.
--
--   1. `directory_listings.social_network` y `social_user`: null = el de la
--      ficha. La red, de `helios_redes_sociales()`.
--   2. `helios_directorio_fichas()` y `helios_directorio()` cambian de forma
--      (dos columnas más): se borran y se vuelven a crear.
--   3. `admin_directorio()` las trae en `listing` y `base`, y
--      `admin_directorio_guardar()` acepta `social_network` y `social_user`.
--      Al final, si hay usuario tiene que haber red (la de la tarjeta o la de
--      la ficha).
--
-- El enlace (instagram.com/…, tiktok.com/@…) lo arma el panel a partir de la
-- red y el usuario, que el médico escribe como quiere («@draperez»,
-- «draperez» o el enlace entero).
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. Las columnas
-- ---------------------------------------------------------------------------

alter table public.directory_listings
  add column social_network text
    check (social_network is null or social_network = any (public.helios_redes_sociales())),
  add column social_user text
    check (social_user is null or char_length(social_user) between 1 and 150);

-- ---------------------------------------------------------------------------
-- 2. Lo que se enseña de cada clínica, y la página
-- ---------------------------------------------------------------------------

drop function public.helios_directorio();
drop function public.helios_directorio_fichas();

/**
 * Cada clínica con los datos de su ficha, los del directorio que mandan sobre
 * ellos y si se puede publicar. La usan la página y la pestaña: así las dos
 * leen exactamente lo mismo. No se expone.
 */
create function public.helios_directorio_fichas()
returns table (
  merchant_id         uuid,
  clinic_name         text,
  status              public.merchant_status,
  is_test             boolean,
  is_visible          boolean,
  published_at        timestamptz,
  updated_at          timestamptz,
  -- De la ficha.
  base_name           text,
  base_specialty      text,
  base_specialty_key  text,
  base_address        text,
  base_city           text,
  base_whatsapp       text,
  base_social_network text,
  base_social_user    text,
  -- Lo que se enseña.
  name                text,
  specialty           text,
  specialty_key       text,
  address             text,
  city                text,
  whatsapp            text,
  social_network      text,
  social_user         text,
  -- Null si se puede publicar; si no, por qué.
  blocked_reason      text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.id, m.name, m.status, m.is_test,
         coalesce(l.is_visible, false), l.published_at, l.updated_at,
         b.name, b.specialty, b.specialty_key, b.address, b.city, b.whatsapp,
         b.social_network, b.social_user,
         coalesce(l.display_name, b.name),
         coalesce(l.specialty, b.specialty),
         coalesce(l.specialty_key, b.specialty_key),
         coalesce(l.address, b.address),
         coalesce(l.city, b.city),
         coalesce(l.whatsapp, b.whatsapp),
         coalesce(l.social_network, b.social_network),
         coalesce(l.social_user, b.social_user),
         case
           when m.status = 'terminated' then 'terminada'
           when m.status = 'paused' then 'pausada'
           when m.is_test then 'prueba'
           when coalesce(l.whatsapp, b.whatsapp) is null then 'sin_whatsapp'
         end
    from public.merchants m
    left join public.directory_listings l on l.merchant_id = m.id
    cross join lateral (
      select public.helios_doctor_name(m.id) as name,
             public.helios_directorio_texto(m.specialty) as specialty,
             public.helios_directorio_especialidad_sugerida(m.specialty, m.category) as specialty_key,
             nullif(btrim(coalesce(m.address, '')), '') as address,
             nullif(btrim(coalesce(m.city, '')), '') as city,
             public.helios_normalize_ve_phone(m.phone) as whatsapp,
             -- La red y el usuario van juntos: sin usuario, no hay red.
             case when nullif(btrim(coalesce(m.social_user, '')), '') is not null then m.social_network end as social_network,
             case when m.social_network is not null then nullif(btrim(coalesce(m.social_user, '')), '') end as social_user
    ) b;
$$;

revoke all on function public.helios_directorio_fichas() from public, anon, authenticated;

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
  social_user    text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select f.merchant_id, f.name, f.specialty, f.specialty_key, f.address, f.city, f.whatsapp,
         f.social_network, f.social_user
    from public.helios_directorio_fichas() f
   where f.is_visible and f.blocked_reason is null
   -- Por el nombre, sin el título delante: «Dra. Ana» va con las A.
   order by lower(regexp_replace(f.name, '^(dra|dr|lcda|lcdo|licda|licdo|lda|ldo)\.?\s+', '', 'i'));
$$;

comment on function public.helios_directorio() is
  'Directorio de médicos: las clínicas publicadas (visibles, activas, no de prueba y con WhatsApp) con lo que enseña su tarjeta, red social incluida. Pública.';

revoke all on function public.helios_directorio() from public;
grant execute on function public.helios_directorio() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. La pestaña del superadmin
-- ---------------------------------------------------------------------------

create or replace function public.admin_directorio()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy   date := public.helios_business_date(now());
  v_desde date := public.helios_business_date(now()) - 29;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'hoy', v_hoy,
    'desde', v_desde,
    'totales', (
      select jsonb_build_object(
        'clics_total', count(*),
        'clics_7d', count(*) filter (where d.dia > v_hoy - 7),
        'clics_30d', count(*) filter (where d.dia >= v_desde),
        'clics_30d_anteriores', count(*) filter (where d.dia between v_desde - 30 and v_desde - 1),
        'visitantes_30d', count(distinct c.visitor_id) filter (where d.dia >= v_desde),
        'medicos_contactados_30d', count(distinct c.merchant_id) filter (where d.dia >= v_desde)
      )
      from public.directory_contact_clicks c
      cross join lateral (select public.helios_business_date(c.created_at) as dia) d
      where c.origin = 'publico'
    ),
    'por_dia', (
      select jsonb_agg(jsonb_build_object(
               'dia', s.dia,
               'clics', coalesce(x.clics, 0),
               'visitantes', coalesce(x.visitantes, 0)
             ) order by s.dia)
        from (select generate_series(v_desde, v_hoy, interval '1 day')::date as dia) s
        left join lateral (
          select count(*) as clics, count(distinct c.visitor_id) as visitantes
            from public.directory_contact_clicks c
           where c.origin = 'publico'
             and c.created_at >= (s.dia::timestamp at time zone 'America/Caracas')
             and c.created_at <  ((s.dia + 1)::timestamp at time zone 'America/Caracas')
        ) x on true
    ),
    'medicos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'merchant_id', f.merchant_id,
               'clinic_name', f.clinic_name,
               'status', f.status,
               'is_test', f.is_test,
               'is_visible', f.is_visible,
               'blocked_reason', f.blocked_reason,
               'published_at', f.published_at,
               'updated_at', f.updated_at,
               'listing', jsonb_build_object(
                 'name', f.name, 'specialty', f.specialty, 'specialty_key', f.specialty_key,
                 'address', f.address, 'city', f.city, 'whatsapp', f.whatsapp,
                 'social_network', f.social_network, 'social_user', f.social_user),
               'base', jsonb_build_object(
                 'name', f.base_name, 'specialty', f.base_specialty, 'specialty_key', f.base_specialty_key,
                 'address', f.base_address, 'city', f.base_city, 'whatsapp', f.base_whatsapp,
                 'social_network', f.base_social_network, 'social_user', f.base_social_user),
               'clics', jsonb_build_object(
                 'total', coalesce(k.total, 0),
                 'd7', coalesce(k.d7, 0),
                 'd30', coalesce(k.d30, 0),
                 'visitantes_30d', coalesce(k.visitantes_30d, 0),
                 'ultimo', k.ultimo,
                 'por_dia', (
                   select jsonb_agg(coalesce(p.n, 0) order by s.dia)
                     from (select generate_series(v_desde, v_hoy, interval '1 day')::date as dia) s
                     left join (
                       select public.helios_business_date(c.created_at) as dia, count(*) as n
                         from public.directory_contact_clicks c
                        where c.merchant_id = f.merchant_id and c.origin = 'publico'
                          and c.created_at >= (v_desde::timestamp at time zone 'America/Caracas')
                        group by 1
                     ) p on p.dia = s.dia
                 )
               )
             ) order by f.is_visible desc, coalesce(k.d30, 0) desc, f.name)
        from public.helios_directorio_fichas() f
        left join lateral (
          select count(*) as total,
                 count(*) filter (where d.dia > v_hoy - 7) as d7,
                 count(*) filter (where d.dia >= v_desde) as d30,
                 count(distinct c.visitor_id) filter (where d.dia >= v_desde) as visitantes_30d,
                 max(c.created_at) as ultimo
            from public.directory_contact_clicks c
            cross join lateral (select public.helios_business_date(c.created_at) as dia) d
           where c.merchant_id = f.merchant_id and c.origin = 'publico'
        ) k on true
    ), '[]'::jsonb)
  );
end;
$$;

/**
 * Cambia la tarjeta de una clínica (ver 20261026190000). Además de `visible`,
 * `name`, `specialty`, `specialty_key`, `address`, `city` y `whatsapp`,
 * acepta `social_network` y `social_user`. Vacío o igual al de la ficha =
 * el de la ficha. Con usuario tiene que haber red.
 */
create or replace function public.admin_directorio_guardar(
  p_merchant_id uuid,
  p_cambios     jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_f      record;
  v_antes  public.directory_listings;
  v_l      public.directory_listings;
  v_valor  text;
  v_clave  text;
  v_motivo text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_f from public.helios_directorio_fichas() f where f.merchant_id = p_merchant_id;
  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  if p_cambios is null or jsonb_typeof(p_cambios) <> 'object' then
    raise exception 'No hay nada que guardar' using errcode = '22023';
  end if;
  for v_clave in select jsonb_object_keys(p_cambios) loop
    if v_clave not in ('visible', 'name', 'specialty', 'specialty_key', 'address', 'city', 'whatsapp',
                       'social_network', 'social_user') then
      raise exception 'Dato desconocido: %', v_clave using errcode = '22023';
    end if;
  end loop;

  select * into v_antes from public.directory_listings where merchant_id = p_merchant_id;
  if v_antes.merchant_id is null then
    v_l.merchant_id := p_merchant_id;
    v_l.is_visible := false;
  else
    v_l := v_antes;
  end if;

  if p_cambios ? 'name' then
    v_valor := nullif(regexp_replace(btrim(coalesce(p_cambios ->> 'name', '')), '\s+', ' ', 'g'), '');
    if v_valor is not null and char_length(v_valor) not between 3 and 120 then
      raise exception 'El nombre debe tener entre 3 y 120 caracteres' using errcode = '22023';
    end if;
    v_l.display_name := nullif(v_valor, v_f.base_name);
  end if;

  if p_cambios ? 'specialty' then
    v_valor := nullif(regexp_replace(btrim(coalesce(p_cambios ->> 'specialty', '')), '\s+', ' ', 'g'), '');
    if v_valor is not null and char_length(v_valor) not between 2 and 120 then
      raise exception 'La especialidad debe tener entre 2 y 120 caracteres' using errcode = '22023';
    end if;
    v_l.specialty := nullif(v_valor, v_f.base_specialty);
  end if;

  if p_cambios ? 'specialty_key' then
    v_valor := nullif(btrim(coalesce(p_cambios ->> 'specialty_key', '')), '');
    if v_valor is not null and not (v_valor = any (public.helios_directorio_especialidades())) then
      raise exception 'Especialidad desconocida: %', v_valor using errcode = '22023';
    end if;
    v_l.specialty_key := nullif(v_valor, v_f.base_specialty_key);
  end if;

  if p_cambios ? 'address' then
    v_valor := nullif(regexp_replace(btrim(coalesce(p_cambios ->> 'address', '')), '\s+', ' ', 'g'), '');
    if v_valor is not null and char_length(v_valor) not between 3 and 300 then
      raise exception 'La dirección debe tener entre 3 y 300 caracteres' using errcode = '22023';
    end if;
    v_l.address := nullif(v_valor, v_f.base_address);
  end if;

  if p_cambios ? 'city' then
    v_valor := nullif(regexp_replace(btrim(coalesce(p_cambios ->> 'city', '')), '\s+', ' ', 'g'), '');
    if v_valor is not null and char_length(v_valor) not between 2 and 80 then
      raise exception 'La ciudad debe tener entre 2 y 80 caracteres' using errcode = '22023';
    end if;
    v_l.city := nullif(v_valor, v_f.base_city);
  end if;

  if p_cambios ? 'whatsapp' then
    v_valor := nullif(btrim(coalesce(p_cambios ->> 'whatsapp', '')), '');
    if v_valor is not null then
      v_valor := public.helios_normalize_ve_phone(v_valor);
      if v_valor is null then
        raise exception 'El WhatsApp debe ser un número venezolano, como 0414-1234567' using errcode = '22023';
      end if;
    end if;
    v_l.whatsapp := nullif(v_valor, v_f.base_whatsapp);
  end if;

  if p_cambios ? 'social_network' then
    v_valor := nullif(lower(btrim(coalesce(p_cambios ->> 'social_network', ''))), '');
    if v_valor is not null and not (v_valor = any (public.helios_redes_sociales())) then
      raise exception 'Red social desconocida: %', v_valor using errcode = '22023';
    end if;
    v_l.social_network := nullif(v_valor, v_f.base_social_network);
  end if;

  if p_cambios ? 'social_user' then
    v_valor := nullif(regexp_replace(btrim(coalesce(p_cambios ->> 'social_user', '')), '\s+', ' ', 'g'), '');
    if v_valor is not null and char_length(v_valor) > 150 then
      raise exception 'El usuario de la red social no puede pasar de 150 caracteres' using errcode = '22023';
    end if;
    v_l.social_user := nullif(v_valor, v_f.base_social_user);
  end if;

  -- Un usuario sin red no se sabe adónde lleva.
  if coalesce(v_l.social_user, v_f.base_social_user) is not null
     and coalesce(v_l.social_network, v_f.base_social_network) is null then
    raise exception 'Elige qué red social es' using errcode = '22023';
  end if;

  if p_cambios ? 'visible' then
    if jsonb_typeof(p_cambios -> 'visible') <> 'boolean' then
      raise exception 'visible debe ser verdadero o falso' using errcode = '22023';
    end if;
    v_l.is_visible := (p_cambios ->> 'visible')::boolean;
  end if;

  -- Lo que impide publicar se mira con los datos ya cambiados: un WhatsApp
  -- nuevo puede ser justo lo que faltaba.
  if v_l.is_visible then
    v_motivo := case
      when v_f.status = 'terminated' then 'la clínica está terminada'
      when v_f.status = 'paused' then 'la clínica está pausada'
      when v_f.is_test then 'es una clínica de prueba'
      when coalesce(v_l.whatsapp, v_f.base_whatsapp) is null then 'no tiene WhatsApp'
    end;
    if v_motivo is not null then
      raise exception 'No se puede publicar: %', v_motivo using errcode = '22023';
    end if;
    if not coalesce(v_antes.is_visible, false) then
      v_l.published_at := now();
    end if;
  end if;

  v_l.updated_by := v_actor;
  v_l.updated_at := now();

  insert into public.directory_listings as d
    (merchant_id, is_visible, display_name, specialty, specialty_key, address, city, whatsapp,
     social_network, social_user, published_at, updated_by, updated_at)
  values
    (p_merchant_id, v_l.is_visible, v_l.display_name, v_l.specialty, v_l.specialty_key, v_l.address,
     v_l.city, v_l.whatsapp, v_l.social_network, v_l.social_user, v_l.published_at, v_l.updated_by,
     v_l.updated_at)
  on conflict (merchant_id) do update set
    is_visible = excluded.is_visible,
    display_name = excluded.display_name,
    specialty = excluded.specialty,
    specialty_key = excluded.specialty_key,
    address = excluded.address,
    city = excluded.city,
    whatsapp = excluded.whatsapp,
    social_network = excluded.social_network,
    social_user = excluded.social_user,
    published_at = excluded.published_at,
    updated_by = excluded.updated_by,
    updated_at = excluded.updated_at;

  perform audit.log(v_actor, 'directory.listing.update', p_merchant_id, jsonb_build_object(
    'merchant_name', v_f.clinic_name,
    'cambios', p_cambios,
    'antes', case when v_antes.merchant_id is null then null else to_jsonb(v_antes) - 'merchant_id' - 'updated_by' end,
    'despues', to_jsonb(v_l) - 'merchant_id' - 'updated_by'
  ));
end;
$$;
