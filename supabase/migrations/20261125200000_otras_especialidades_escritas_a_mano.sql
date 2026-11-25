-- ============================================================================
-- Helios — Otras especialidades escritas a mano
--
-- Las otras especialidades de un médico (20261110120000) salían solo de la
-- lista cerrada del filtro. Hay médicos cuya segunda especialidad no está en
-- ella (hepatología pediátrica, medicina del dolor…), y hoy no hay dónde
-- ponerla. Ahora se pueden escribir a mano:
--
--   1. `directory_listings.other_specialty_names`: hasta tres nombres escritos
--      a mano, de 2 a 60 caracteres. Solo se leen en la tarjeta («Psiquiatría ·
--      Medicina interna · Hepatología pediátrica»): no tienen filtro ni
--      página propia, porque no son una clave de la lista cerrada.
--   2. `helios_directorio_fichas()`, `helios_directorio()`,
--      `helios_directorio_medico()` y `helios_directorio_consultas()` traen
--      `other_specialty_names` (al final). Cambia su tipo de salida: se borran
--      y se vuelven a crear con sus permisos. `helios_directorio()` parte de
--      la definición vigente (20261117210000: el sorteo en logaritmos).
--   3. `admin_directorio()` las enseña en la tarjeta (la ficha de la clínica
--      no tiene).
--   4. `admin_medico_especialidades()` las trae y
--      `admin_medico_especialidades_guardar()` acepta `p_nombres`: una lista,
--      o null para no tocarlas (así el panel de antes, que solo manda las
--      claves, sigue funcionando). Las claves y los nombres, juntos, no pasan
--      de tres además de la principal.
--
-- `admin_directorio_guardar` no cambia: no menciona la columna nueva, así que
-- no la toca.
-- ============================================================================

-- ── 1. La columna ───────────────────────────────────────────────────────────

-- Cada nombre: sin espacios de más, de 2 a 60 caracteres y sin `<`, `>` ni
-- caracteres de control (se leen en la tarjeta y en el HTML de la ficha).
create function public.helios_directorio_nombres_validos(p_nombres text[])
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select coalesce(bool_and(
           n = btrim(n)
           and char_length(n) between 2 and 60
           and n !~ '[<>[:cntrl:]]'
         ), true)
    from unnest(p_nombres) as u(n);
$$;

revoke all on function public.helios_directorio_nombres_validos(text[]) from public, anon, authenticated;

alter table public.directory_listings
  add column other_specialty_names text[] not null default '{}'
    check (
      cardinality(other_specialty_names) <= 3
      and not (null = any (other_specialty_names))
      and public.helios_directorio_nombres_validos(other_specialty_names)
    );

comment on column public.directory_listings.other_specialty_names is
  'Otras especialidades escritas a mano, las que no están en la lista cerrada (hasta tres, de 2 a 60 caracteres): se leen en la tarjeta, sin filtro ni página propia.';

-- ── 2. Las lecturas ─────────────────────────────────────────────────────────

drop function public.helios_directorio_consultas();
drop function public.helios_directorio_medico(text);
drop function public.helios_directorio();
drop function public.helios_directorio_fichas();

create function public.helios_directorio_fichas()
 RETURNS TABLE(merchant_id uuid, clinic_name text, status merchant_status, is_test boolean, is_visible boolean, published_at timestamp with time zone, updated_at timestamp with time zone, base_name text, base_specialty text, base_specialty_key text, base_address text, base_city text, base_whatsapp text, base_social_network text, base_social_user text, name text, specialty text, specialty_key text, address text, city text, whatsapp text, social_network text, social_user text, consultation_price_cur numeric, consultation_currency text, blocked_reason text, other_specialty_keys text[], other_specialty_names text[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
         l.consultation_price_cur,
         coalesce(l.consultation_currency, 'USD'),
         case
           when m.status = 'terminated' then 'terminada'
           when m.status = 'paused' then 'pausada'
           when m.is_test then 'prueba'
           when coalesce(l.whatsapp, b.whatsapp) is null then 'sin_whatsapp'
         end,
         -- Las otras, en el orden en que se eligieron y sin la principal: si
         -- la principal cambia a una de ellas, no sale dos veces.
         array(select k
                 from unnest(coalesce(l.other_specialty_keys, '{}'::text[])) with ordinality as u(k, n)
                where k is distinct from coalesce(l.specialty_key, b.specialty_key)
                order by n),
         coalesce(l.other_specialty_names, '{}'::text[])
    from public.merchants m
    left join public.directory_listings l on l.merchant_id = m.id
    cross join lateral (
      select public.helios_doctor_name(m.id) as name,
             public.helios_directorio_texto(m.specialty) as specialty,
             public.helios_directorio_especialidad_sugerida(m.specialty, m.category) as specialty_key,
             nullif(btrim(coalesce(m.address, '')), '') as address,
             nullif(btrim(coalesce(m.city, '')), '') as city,
             -- El teléfono de contacto del alta y, si no hay, el personal.
             coalesce(m.contact_phone, public.helios_normalize_ve_phone(m.phone)) as whatsapp,
             -- La red y el usuario van juntos: sin usuario, no hay red.
             case when nullif(btrim(coalesce(m.social_user, '')), '') is not null then m.social_network end as social_network,
             case when m.social_network is not null then nullif(btrim(coalesce(m.social_user, '')), '') end as social_user
    ) b;
$function$;

revoke all on function public.helios_directorio_fichas() from public, anon, authenticated;

create function public.helios_directorio()
 RETURNS TABLE(merchant_id uuid, name text, specialty text, specialty_key text, address text, city text, whatsapp text, social_network text, social_user text, lead_code text, slug text, updated_at timestamp with time zone, consultation_price_cur numeric, consultation_currency text, other_specialty_keys text[], other_specialty_names text[])
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select f.merchant_id, f.name, f.specialty, f.specialty_key, f.address, f.city, f.whatsapp,
         f.social_network, f.social_user, l.lead_code, l.slug, l.updated_at, f.consultation_price_cur, f.consultation_currency,
         f.other_specialty_keys, f.other_specialty_names
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
   -- En logaritmos (20261117210000), para que muchos clics no desborden el cálculo.
   order by (1 + coalesce(k.clics, 0)) * ln(greatest(random(), 1e-300)) desc;
$function$;

comment on function public.helios_directorio() is
  'Directorio de médicos: las clínicas publicadas (visibles, activas, no de prueba y con WhatsApp) con lo que enseña su tarjeta, red social, código (DIR-XXXX), enlace de su ficha, fecha del último cambio, precio de la consulta con su moneda y las otras especialidades en las que sale (other_specialty_keys, sin la principal; y las escritas a mano, other_specialty_names), en un orden sorteado en cada llamada que favorece a quien tiene menos clics públicos en 7 días. Pública.';
revoke all on function public.helios_directorio() from public;
grant execute on function public.helios_directorio() to anon, authenticated;

create function public.helios_directorio_medico(p_slug text)
 RETURNS TABLE(merchant_id uuid, name text, specialty text, specialty_key text, address text, city text, whatsapp text, social_network text, social_user text, lead_code text, slug text, updated_at timestamp with time zone, consultation_price_cur numeric, consultation_currency text, other_specialty_keys text[], other_specialty_names text[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select f.merchant_id, f.name, f.specialty, f.specialty_key, f.address, f.city, f.whatsapp,
         f.social_network, f.social_user, l.lead_code, l.slug, l.updated_at, f.consultation_price_cur, f.consultation_currency,
         f.other_specialty_keys, f.other_specialty_names
    from public.directory_listings l
    join public.helios_directorio_fichas() f on f.merchant_id = l.merchant_id
   where l.slug = lower(btrim(coalesce(p_slug, '')))
     and f.is_visible and f.blocked_reason is null;
$function$;

comment on function public.helios_directorio_medico(text) is
  'Directorio de médicos: un médico publicado por el enlace de su ficha (/medico/<slug>), con las columnas de helios_directorio(). Nada si no existe o ya no sale. Pública.';
revoke all on function public.helios_directorio_medico(text) from public;
grant execute on function public.helios_directorio_medico(text) to anon, authenticated;

create function public.helios_directorio_consultas()
 RETURNS TABLE(merchant_id uuid, name text, specialty text, specialty_key text, address text, city text, whatsapp text, social_network text, social_user text, lead_code text, slug text, updated_at timestamp with time zone, consultation_price_cur numeric, consultation_currency text, consultation_price_usd numeric, other_specialty_keys text[], other_specialty_names text[])
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select d.merchant_id, d.name, d.specialty, d.specialty_key, d.address, d.city, d.whatsapp,
         d.social_network, d.social_user, d.lead_code, d.slug, d.updated_at,
         d.consultation_price_cur, d.consultation_currency, x.usd, d.other_specialty_keys, d.other_specialty_names
    from public.helios_directorio() with ordinality as d(
           merchant_id, name, specialty, specialty_key, address, city, whatsapp,
           social_network, social_user, lead_code, slug, updated_at,
           consultation_price_cur, consultation_currency, other_specialty_keys, other_specialty_names, n)
    cross join lateral (
      select public.helios_directorio_precio_usd(d.consultation_price_cur, d.consultation_currency) as usd
    ) x
   where public.helios_consultas_entra(x.usd)
   order by d.n;
$function$;

comment on function public.helios_directorio_consultas() is
  'Prueba A/B del directorio: los médicos publicados cuya consulta vale más de $15 y como mucho $60 (en euros, por la tasa cruzada BCV de hoy), con las columnas de helios_directorio() más consultation_price_usd, en su mismo orden sorteado. Es la página /consultas. Pública.';
revoke all on function public.helios_directorio_consultas() from public;
grant execute on function public.helios_directorio_consultas() to anon, authenticated;


-- ── 3. El superadmin ────────────────────────────────────────────────────────

create or replace function public.admin_directorio()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_hoy      date := public.helios_business_date(now());
  v_desde    date := public.helios_business_date(now()) - 29;
  v_desde_ts timestamptz := ((public.helios_business_date(now()) - 29)::timestamp at time zone 'America/Caracas');
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
    ) || (
      -- Los del equipo y los del personal de las clínicas: no cuentan, pero se
      -- dice cuántos hubo para que una prueba no parezca un fallo.
      select jsonb_build_object(
        'clics_internos_30d', count(*),
        'ultimo_interno', max(c.created_at)
      )
      from public.directory_contact_clicks c
      where c.origin <> 'publico'
        and c.created_at >= v_desde_ts
    ) || (
      -- Los que escribieron al WhatsApp de Helios con un código, y los que
      -- después tuvieron una orden con ese médico.
      select jsonb_build_object(
        'interesados_total', count(*),
        'interesados_30d', count(*) filter (where l.first_at >= v_desde_ts),
        'convertidos_total', count(cv.charge_id),
        'convertidos_30d', count(cv.charge_id) filter (where l.first_at >= v_desde_ts)
      )
      from public.directory_leads l
      left join lateral public.helios_directorio_conversion(l.merchant_id, l.phone_e164, l.first_at) cv on true
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
                 'social_network', f.social_network, 'social_user', f.social_user,
                 'consultation_price_cur', f.consultation_price_cur,
                 'consultation_currency', f.consultation_currency,
                 'other_specialty_keys', to_jsonb(f.other_specialty_keys),
                 'other_specialty_names', to_jsonb(f.other_specialty_names)),
               'base', jsonb_build_object(
                 'name', f.base_name, 'specialty', f.base_specialty, 'specialty_key', f.base_specialty_key,
                 'address', f.base_address, 'city', f.base_city, 'whatsapp', f.base_whatsapp,
                 'social_network', f.base_social_network, 'social_user', f.base_social_user,
                 -- La ficha de la clínica no tiene otras: solo existen aquí.
                 'other_specialty_keys', '[]'::jsonb,
                 'other_specialty_names', '[]'::jsonb),
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
                          and c.created_at >= v_desde_ts
                        group by 1
                     ) p on p.dia = s.dia
                 )
               ),
               'interesados', jsonb_build_object(
                 'total', coalesce(li.total, 0),
                 'd30', coalesce(li.d30, 0),
                 'convertidos', coalesce(li.convertidos, 0),
                 'ultimo', li.ultimo
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
        left join lateral (
          select count(*) as total,
                 count(*) filter (where l.first_at >= v_desde_ts) as d30,
                 count(cv.charge_id) as convertidos,
                 max(l.last_at) as ultimo
            from public.directory_leads l
            left join lateral public.helios_directorio_conversion(l.merchant_id, l.phone_e164, l.first_at) cv on true
           where l.merchant_id = f.merchant_id
        ) li on true
    ), '[]'::jsonb)
  );
end;
$function$;


-- ── 4. El perfil del médico (super admin y capacitador) ─────────────────────

create or replace function public.admin_medico_especialidades(p_merchant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_f record;
begin
  perform public.helios_assert_puede_afiliar('ver las especialidades de un médico');

  select f.specialty_key, f.other_specialty_keys, f.other_specialty_names into v_f
    from public.helios_directorio_fichas() f
   where f.merchant_id = p_merchant_id;
  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'specialty_key', v_f.specialty_key,
    'other_specialty_keys', to_jsonb(v_f.other_specialty_keys),
    'other_specialty_names', to_jsonb(v_f.other_specialty_names));
end;
$function$;

comment on function public.admin_medico_especialidades(uuid) is
  'Perfil del médico: su especialidad principal del directorio (specialty_key), las otras de la lista cerrada (other_specialty_keys, sin la principal) y las escritas a mano (other_specialty_names). Super admin o capacitador.';

-- La de dos parámetros (20261125100000) se reemplaza por una con `p_nombres`
-- opcional: una llamada de antes, con solo las claves, sigue valiendo.
drop function public.admin_medico_especialidades_guardar(uuid, jsonb);

create function public.admin_medico_especialidades_guardar(p_merchant_id uuid, p_otras jsonb, p_nombres jsonb default null)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor         uuid := public.helios_assert_puede_afiliar('cambiar las especialidades de un médico');
  v_f             record;
  v_antes         text[];
  v_antes_nombres text[];
  v_otras         text[] := '{}';
  v_nombres       text[];
  v_valor         text;
begin
  select f.clinic_name, f.specialty_key, f.other_specialty_keys, f.other_specialty_names into v_f
    from public.helios_directorio_fichas() f
   where f.merchant_id = p_merchant_id;
  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;
  v_antes := v_f.other_specialty_keys;
  v_antes_nombres := v_f.other_specialty_names;

  if p_otras is null or jsonb_typeof(p_otras) <> 'array' then
    raise exception 'Las otras especialidades van en una lista' using errcode = '22023';
  end if;

  -- Sin repetir y sin la principal, que ya cuenta; en el orden en que llegan.
  for v_valor in
    select btrim(e.v)
      from jsonb_array_elements_text(p_otras) with ordinality as e(v, n)
     order by e.n
  loop
    if not (v_valor = any (public.helios_directorio_especialidades())) or v_valor = 'otra' then
      raise exception 'Especialidad desconocida: %', v_valor using errcode = '22023';
    end if;
    if not (v_valor = any (v_otras)) and v_valor is distinct from v_f.specialty_key then
      v_otras := v_otras || v_valor;
    end if;
  end loop;

  -- Los nombres escritos a mano: null = los de hoy. Sin espacios de más y sin
  -- repetir (sin mayúsculas ni tildes: «Hepatología» y «hepatologia» son uno).
  if p_nombres is null or jsonb_typeof(p_nombres) = 'null' then
    v_nombres := v_antes_nombres;
  elsif jsonb_typeof(p_nombres) <> 'array' then
    raise exception 'Las especialidades escritas a mano van en una lista' using errcode = '22023';
  else
    v_nombres := '{}';
    for v_valor in
      select regexp_replace(btrim(e.v), '\s+', ' ', 'g')
        from jsonb_array_elements_text(p_nombres) with ordinality as e(v, n)
       order by e.n
    loop
      if char_length(v_valor) not between 2 and 60 then
        raise exception 'Cada especialidad escrita debe tener entre 2 y 60 caracteres' using errcode = '22023';
      end if;
      if v_valor ~ '[<>[:cntrl:]]' then
        raise exception 'La especialidad "%" tiene caracteres que no se admiten', v_valor using errcode = '22023';
      end if;
      if not exists (
           select 1 from unnest(v_nombres) x
            where translate(lower(x), 'áéíóúüñ', 'aeiouun') = translate(lower(v_valor), 'áéíóúüñ', 'aeiouun')) then
        v_nombres := v_nombres || v_valor;
      end if;
    end loop;
  end if;

  if cardinality(v_otras) + cardinality(v_nombres) > 3 then
    raise exception 'Como mucho tres especialidades además de la principal' using errcode = '22023';
  end if;

  -- Un médico sin tarjeta la recibe oculta: elegir especialidades no lo publica.
  insert into public.directory_listings as d
    (merchant_id, is_visible, consultation_currency, other_specialty_keys, other_specialty_names, updated_by, updated_at)
  values
    (p_merchant_id, false, 'USD', v_otras, v_nombres, v_actor, now())
  on conflict (merchant_id) do update set
    other_specialty_keys = excluded.other_specialty_keys,
    other_specialty_names = excluded.other_specialty_names,
    updated_by = excluded.updated_by,
    updated_at = excluded.updated_at;

  perform audit.log(v_actor, 'directory.listing.update', p_merchant_id, jsonb_build_object(
    'merchant_name', v_f.clinic_name,
    'cambios', jsonb_build_object('other_specialty_keys', to_jsonb(v_otras), 'other_specialty_names', to_jsonb(v_nombres)),
    'antes', jsonb_build_object('other_specialty_keys', to_jsonb(v_antes), 'other_specialty_names', to_jsonb(v_antes_nombres)),
    'despues', jsonb_build_object('other_specialty_keys', to_jsonb(v_otras), 'other_specialty_names', to_jsonb(v_nombres))
  ));
end;
$function$;

comment on function public.admin_medico_especialidades_guardar(uuid, jsonb, jsonb) is
  'Perfil del médico: reemplaza las otras especialidades de la lista cerrada (p_otras: hasta tres claves, sin repetir, sin «otra» y sin la principal) y las escritas a mano (p_nombres: de 2 a 60 caracteres cada una, sin repetir; null = no tocarlas). Entre las dos, como mucho tres. No toca nada más de la tarjeta; si no tiene, la crea oculta. Super admin o capacitador; queda en audit.admin_actions.';
revoke all on function public.admin_medico_especialidades_guardar(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.admin_medico_especialidades_guardar(uuid, jsonb, jsonb) to authenticated;
