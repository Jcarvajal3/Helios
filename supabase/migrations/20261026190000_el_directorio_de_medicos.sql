-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El directorio de médicos (`/directorio` y superadmin › Directorio)
--
-- Una página pública, sin enlace desde la portada (se llega escribiendo o
-- compartiendo la URL), donde un paciente busca un médico afiliado por
-- nombre o especialidad y le escribe por WhatsApp. El equipo decide desde el
-- superadmin quién sale y con qué datos, y ve cuántos contactos recibe cada
-- médico.
--
--   1. `directory_listings`: una fila por clínica que el equipo tocó. Si sale
--      o no (`is_visible`, apagado por defecto: nadie se publica sin que el
--      equipo lo decida) y los datos que se enseñan. Cada dato es opcional:
--      null quiere decir «el de la ficha de la clínica» (el nombre del
--      titular con su título, su especialidad, su dirección, su ciudad y el
--      teléfono del alta), así que una corrección en la ficha llega sola.
--   2. `directory_contact_clicks`: cada toque al botón de WhatsApp de una
--      tarjeta. Solo se añade. Guarda un identificador anónimo del navegador
--      (para contar visitantes, nunca para saber quién es) y si el clic vino
--      del equipo o del personal de una clínica: esos no cuentan.
--   3. `helios_directorio()`: lo que lee la página (anon). Solo las clínicas
--      visibles que se pueden publicar: activas, no de prueba y con WhatsApp.
--   4. `helios_directorio_contacto(...)`: apunta un clic (anon). Calla ante
--      una clínica que no está publicada y descarta el doble toque y el
--      exceso de un mismo navegador.
--   5. `admin_directorio()` y `admin_directorio_guardar(...)`: la pestaña del
--      superadmin. Los dos roles (`is_platform_admin()`), con bitácora.
--
-- La especialidad del filtro y del icono sale de una lista cerrada
-- (`specialty_key`); si el equipo no la elige, se deduce del texto libre del
-- alta (`helios_directorio_especialidad_sugerida`).
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. Las especialidades del filtro
-- ---------------------------------------------------------------------------

/**
 * Las claves que entiende el panel (cada una con su nombre y su icono en
 * `features/directorio/especialidades.ts`). Añadir una es tocar las dos.
 */
create or replace function public.helios_directorio_especialidades()
returns text[]
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select array[
    'medicina_general', 'medicina_interna', 'pediatria', 'ginecologia',
    'traumatologia', 'cardiologia', 'dermatologia', 'oftalmologia',
    'otorrinolaringologia', 'urologia', 'gastroenterologia', 'coloproctologia',
    'neurologia', 'psicologia', 'nutricion', 'endocrinologia', 'neumologia',
    'oncologia', 'fisioterapia', 'enfermeria', 'odontologia', 'cosmetologia',
    'otra'
  ]::text[];
$$;

/**
 * La especialidad del filtro a partir del texto libre del alta («Traumotología,
 * cirugía cadera, rodilla y pelvis», «UROLOGO», «pediatria, vacunacion»). Lo
 * más concreto primero: un «internista y gastroenterólogo» es de
 * gastroenterología. Sin texto, la categoría de la clínica.
 */
create or replace function public.helios_directorio_especialidad_sugerida(
  p_specialty text,
  p_category  public.merchant_category default null
)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case
    when t = '' then
      case p_category::text
        when 'odontologia'  then 'odontologia'
        when 'cosmetologia' then 'cosmetologia'
        else 'medicina_general'
      end
    when t ~ 'odont|dental|dentist|ortodon|endodon|periodon|maxilofac|bucal' then 'odontologia'
    when t ~ 'cosmet|estetic'                       then 'cosmetologia'
    when t ~ 'dermat'                               then 'dermatologia'
    when t ~ 'pediat|neonat|vacun'                  then 'pediatria'
    when t ~ 'ginec|obstet|pelvic'                  then 'ginecologia'
    when t ~ 'traum|ortoped|cadera|rodilla'         then 'traumatologia'
    when t ~ 'cardio'                               then 'cardiologia'
    when t ~ 'oftalm|optomet|ocular'                then 'oftalmologia'
    when t ~ 'otorrino'                             then 'otorrinolaringologia'
    when t ~ 'urolog|urolo'                         then 'urologia'
    when t ~ 'gastro'                               then 'gastroenterologia'
    when t ~ 'procto'                               then 'coloproctologia'
    when t ~ 'neurol'                               then 'neurologia'
    when t ~ 'psico|psiqui'                         then 'psicologia'
    when t ~ 'nutri'                                then 'nutricion'
    when t ~ 'endocrin|diabet'                      then 'endocrinologia'
    when t ~ 'neumo|pulmon'                         then 'neumologia'
    when t ~ 'oncolog'                              then 'oncologia'
    when t ~ 'fisiot|fisiatr|rehabilit'             then 'fisioterapia'
    when t ~ 'enferm'                               then 'enfermeria'
    when t ~ 'intern'                               then 'medicina_interna'
    when t ~ 'general|familiar'                     then 'medicina_general'
    else 'otra'
  end
  from (select translate(lower(btrim(coalesce(p_specialty, ''))), 'áéíóúü', 'aeiouu') as t) x;
$$;

/**
 * El texto libre del alta, presentable: sin espacios ni comas sueltas al
 * final y con mayúscula inicial. Lo que llegó todo en mayúsculas
 * («UROLOGO») se baja a minúsculas. Las tildes que faltan no se inventan: eso
 * lo corrige el equipo en la pestaña.
 */
create or replace function public.helios_directorio_texto(p_text text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case
    when t = '' then null
    when t = upper(t) then upper(left(t, 1)) || lower(substr(t, 2))
    else upper(left(t, 1)) || substr(t, 2)
  end
  from (select regexp_replace(btrim(coalesce(p_text, '')), '[\s,;.\-/]+$', '') as t) x;
$$;

revoke all on function public.helios_directorio_especialidades() from public, anon, authenticated;
revoke all on function public.helios_directorio_especialidad_sugerida(text, public.merchant_category) from public, anon, authenticated;
revoke all on function public.helios_directorio_texto(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Las tablas
-- ---------------------------------------------------------------------------

create table public.directory_listings (
  merchant_id   uuid primary key references public.merchants (id) on delete cascade,
  is_visible    boolean not null default false,
  -- Null: el de la ficha de la clínica.
  display_name  text check (display_name is null or char_length(display_name) between 3 and 120),
  specialty     text check (specialty is null or char_length(specialty) between 2 and 120),
  specialty_key text check (specialty_key is null or specialty_key = any (public.helios_directorio_especialidades())),
  address       text check (address is null or char_length(address) between 3 and 300),
  city          text check (city is null or char_length(city) between 2 and 80),
  whatsapp      text check (whatsapp is null or whatsapp ~ '^\+58[0-9]{10}$'),
  -- La última vez que se encendió.
  published_at  timestamptz,
  updated_by    uuid references auth.users (id),
  updated_at    timestamptz not null default now()
);

comment on table public.directory_listings is
  'Directorio de médicos: si una clínica sale en /directorio y con qué datos. Cada dato null es el de la ficha de la clínica.';

create table public.directory_contact_clicks (
  id          bigint generated always as identity primary key,
  merchant_id uuid not null references public.merchants (id) on delete cascade,
  -- Un identificador aleatorio que el navegador guarda: cuenta visitantes
  -- distintos, no dice quién es nadie.
  visitor_id  text check (visitor_id is null or visitor_id ~ '^[A-Za-z0-9-]{8,64}$'),
  -- Los del equipo y los del personal de una clínica se guardan, pero no
  -- cuentan en las cifras.
  origin      text not null default 'publico' check (origin in ('publico', 'equipo', 'clinica')),
  created_at  timestamptz not null default now()
);

comment on table public.directory_contact_clicks is
  'Directorio de médicos: cada toque al botón de WhatsApp de una tarjeta. Solo se añade.';

create index directory_contact_clicks_merchant_idx
  on public.directory_contact_clicks (merchant_id, created_at desc);
create index directory_contact_clicks_visitor_idx
  on public.directory_contact_clicks (visitor_id, created_at desc)
  where visitor_id is not null;

-- Se tocan solo por las RPC de abajo, que son security definer.
alter table public.directory_listings enable row level security;
alter table public.directory_contact_clicks enable row level security;
revoke all on table public.directory_listings from public, anon, authenticated;
revoke all on table public.directory_contact_clicks from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Lo que se enseña de cada clínica
-- ---------------------------------------------------------------------------

/**
 * Cada clínica con los datos de su ficha, los del directorio que mandan sobre
 * ellos y si se puede publicar. La usan la página y la pestaña: así las dos
 * leen exactamente lo mismo. No se expone.
 */
create or replace function public.helios_directorio_fichas()
returns table (
  merchant_id       uuid,
  clinic_name       text,
  status            public.merchant_status,
  is_test           boolean,
  is_visible        boolean,
  published_at      timestamptz,
  updated_at        timestamptz,
  -- De la ficha.
  base_name         text,
  base_specialty    text,
  base_specialty_key text,
  base_address      text,
  base_city         text,
  base_whatsapp     text,
  -- Lo que se enseña.
  name              text,
  specialty         text,
  specialty_key     text,
  address           text,
  city              text,
  whatsapp          text,
  -- Null si se puede publicar; si no, por qué.
  blocked_reason    text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.id, m.name, m.status, m.is_test,
         coalesce(l.is_visible, false), l.published_at, l.updated_at,
         b.name, b.specialty, b.specialty_key, b.address, b.city, b.whatsapp,
         coalesce(l.display_name, b.name),
         coalesce(l.specialty, b.specialty),
         coalesce(l.specialty_key, b.specialty_key),
         coalesce(l.address, b.address),
         coalesce(l.city, b.city),
         coalesce(l.whatsapp, b.whatsapp),
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
             public.helios_normalize_ve_phone(m.phone) as whatsapp
    ) b;
$$;

revoke all on function public.helios_directorio_fichas() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. La página pública
-- ---------------------------------------------------------------------------

create or replace function public.helios_directorio()
returns table (
  merchant_id   uuid,
  name          text,
  specialty     text,
  specialty_key text,
  address       text,
  city          text,
  whatsapp      text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select f.merchant_id, f.name, f.specialty, f.specialty_key, f.address, f.city, f.whatsapp
    from public.helios_directorio_fichas() f
   where f.is_visible and f.blocked_reason is null
   -- Por el nombre, sin el título delante: «Dra. Ana» va con las A.
   order by lower(regexp_replace(f.name, '^(dra|dr|lcda|lcdo|licda|licdo|lda|ldo)\.?\s+', '', 'i'));
$$;

comment on function public.helios_directorio() is
  'Directorio de médicos: las clínicas publicadas (visibles, activas, no de prueba y con WhatsApp) con lo que enseña su tarjeta. Pública.';

revoke all on function public.helios_directorio() from public;
grant execute on function public.helios_directorio() to anon, authenticated;

/**
 * Apunta un toque al botón de WhatsApp. Devuelve si contó.
 *
 * Es pública, así que no se fía de nadie: una clínica que no está publicada
 * no dice nada (ni que existe), el mismo navegador sobre el mismo médico en
 * menos de 30 segundos es un doble toque, y más de 30 clics de un navegador
 * en un día no son un paciente. Lo descartado no se guarda.
 */
create or replace function public.helios_directorio_contacto(
  p_merchant_id uuid,
  p_visitante   text default null
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

  insert into public.directory_contact_clicks (merchant_id, visitor_id, origin)
  values (p_merchant_id, v_visitante, v_origen);

  return true;
end;
$$;

comment on function public.helios_directorio_contacto(uuid, text) is
  'Directorio de médicos: apunta un toque al botón de WhatsApp de una tarjeta publicada. Pública; descarta el doble toque (30 s) y más de 30 clics de un navegador al día.';

revoke all on function public.helios_directorio_contacto(uuid, text) from public;
grant execute on function public.helios_directorio_contacto(uuid, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. La pestaña del superadmin
-- ---------------------------------------------------------------------------

/**
 * Todas las clínicas con lo que enseñaría su tarjeta, lo de su ficha y sus
 * clics de contacto, y el total del directorio día a día. Solo cuentan los
 * clics públicos. Las ventanas son de días operativos con hoy: 7 días son
 * hoy y los seis anteriores.
 */
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
                 'address', f.address, 'city', f.city, 'whatsapp', f.whatsapp),
               'base', jsonb_build_object(
                 'name', f.base_name, 'specialty', f.base_specialty, 'specialty_key', f.base_specialty_key,
                 'address', f.base_address, 'city', f.base_city, 'whatsapp', f.base_whatsapp),
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

comment on function public.admin_directorio() is
  'Directorio de médicos: cada clínica con su tarjeta, los datos de su ficha y sus clics de contacto (7 y 30 días, total, visitantes, día a día), y el total del directorio por día.';

revoke all on function public.admin_directorio() from public, anon;
grant execute on function public.admin_directorio() to authenticated;

/**
 * Cambia la tarjeta de una clínica. `p_cambios` lleva solo lo que cambia:
 * `visible` (boolean) y los datos `name`, `specialty`, `specialty_key`,
 * `address`, `city`, `whatsapp`. Un dato vacío, o igual al de la ficha,
 * vuelve a ser el de la ficha. No se publica una clínica que no se puede
 * publicar (terminada, pausada, de prueba o sin WhatsApp).
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
    if v_clave not in ('visible', 'name', 'specialty', 'specialty_key', 'address', 'city', 'whatsapp') then
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
     published_at, updated_by, updated_at)
  values
    (p_merchant_id, v_l.is_visible, v_l.display_name, v_l.specialty, v_l.specialty_key, v_l.address,
     v_l.city, v_l.whatsapp, v_l.published_at, v_l.updated_by, v_l.updated_at)
  on conflict (merchant_id) do update set
    is_visible = excluded.is_visible,
    display_name = excluded.display_name,
    specialty = excluded.specialty,
    specialty_key = excluded.specialty_key,
    address = excluded.address,
    city = excluded.city,
    whatsapp = excluded.whatsapp,
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

comment on function public.admin_directorio_guardar(uuid, jsonb) is
  'Directorio de médicos: publica u oculta una clínica y corrige los datos de su tarjeta (vacío o igual a la ficha = el de la ficha). Los dos roles; queda en audit.admin_actions.';

revoke all on function public.admin_directorio_guardar(uuid, jsonb) from public, anon;
grant execute on function public.admin_directorio_guardar(uuid, jsonb) to authenticated;
