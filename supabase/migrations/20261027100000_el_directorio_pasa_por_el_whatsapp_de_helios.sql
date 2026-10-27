-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El directorio pasa por el WhatsApp de Helios (docs/04)
--
-- Hasta hoy el botón «Escribir por WhatsApp» de cada tarjeta de `/directorio`
-- abría el chat directo con el médico: Helios contaba el clic, pero no sabía
-- quién escribió ni si terminó siendo paciente. Ahora el botón abre el chat
-- con el número de Helios y un mensaje ya escrito con el código del médico
-- («(Código DIR-7K2P)»). El bot reconoce el código, guarda el teléfono de
-- quien escribe y le contesta con el contacto del médico. Si ese teléfono
-- tiene después una orden confirmada con ese médico, es un paciente
-- convertido (Javier, 2026-10-27: «solo el contacto»; el número del paciente
-- no se le pasa al médico, Helios lo guarda solo para medir).
--
--   1. `directory_listings.lead_code`: el código de cada tarjeta, `DIR-` + 4
--      caracteres sin los que se confunden (0/O, 1/I/L). Nace con la fila y
--      no cambia al editar la tarjeta.
--   2. `helios_directorio()` añade `lead_code` al final y
--      `helios_directorio_whatsapp()` da el número de Helios: con los dos, la
--      página arma el enlace (si falta uno, vuelve al enlace directo).
--   3. `directory_leads`: un interesado por médico y teléfono. Solo por RPC.
--   4. `bot_directorio_interesado(...)`: lo llama el webhook (service_role).
--   5. La conversión, una sola regla (`helios_directorio_conversion`): una
--      orden de ese médico, confirmada, no de prueba, creada en o después del
--      primer mensaje, cuyo paciente tiene el mismo teléfono (los 10 últimos
--      dígitos, `phone_national_key`).
--   6. `admin_directorio()` añade los interesados y los convertidos (sin
--      quitar nada) y `admin_directorio_interesados(...)` los lista.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. El código de cada tarjeta
-- ---------------------------------------------------------------------------

/**
 * Un código nuevo y libre: `DIR-` + 4 de `23456789ABCDEFGHJKMNPQRSTUVWXYZ`
 * (31 caracteres: 923.521 códigos). Es el valor por defecto de
 * `directory_listings.lead_code`; la restricción `unique` es la última
 * palabra si dos altas a la vez sacaran el mismo.
 */
create or replace function public.helios_directorio_codigo_nuevo()
returns text
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_letras constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  v_codigo text;
  v_intento integer := 0;
begin
  loop
    v_intento := v_intento + 1;
    select 'DIR-' || string_agg(substr(v_letras, 1 + floor(random() * length(v_letras))::int, 1), '')
      into v_codigo
      from generate_series(1, 4);
    exit when not exists (select 1 from public.directory_listings l where l.lead_code = v_codigo);
    if v_intento >= 100 then
      raise exception 'No quedan códigos libres para el directorio' using errcode = 'P0001';
    end if;
  end loop;
  return v_codigo;
end;
$$;

revoke all on function public.helios_directorio_codigo_nuevo() from public, anon, authenticated;

alter table public.directory_listings add column lead_code text;

-- Las tarjetas que ya existen, una a una (así cada código ve los anteriores).
do $$
declare
  v_id uuid;
begin
  for v_id in select merchant_id from public.directory_listings where lead_code is null order by merchant_id loop
    update public.directory_listings
       set lead_code = public.helios_directorio_codigo_nuevo()
     where merchant_id = v_id;
  end loop;
end;
$$;

alter table public.directory_listings
  alter column lead_code set default public.helios_directorio_codigo_nuevo(),
  alter column lead_code set not null,
  add constraint directory_listings_lead_code_key unique (lead_code),
  add constraint directory_listings_lead_code_check check (lead_code ~ '^DIR-[2-9A-HJKMNP-Z]{4}$');

comment on column public.directory_listings.lead_code is
  'Código de la tarjeta (DIR-XXXX) que lleva el mensaje al WhatsApp de Helios. Nace con la fila y no cambia al editarla.';

-- ---------------------------------------------------------------------------
-- 2. La página: el código de cada tarjeta y el número de Helios
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
  lead_code      text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select f.merchant_id, f.name, f.specialty, f.specialty_key, f.address, f.city, f.whatsapp,
         f.social_network, f.social_user, l.lead_code
    from public.helios_directorio_fichas() f
    join public.directory_listings l on l.merchant_id = f.merchant_id
   where f.is_visible and f.blocked_reason is null
   -- Por el nombre, sin el título delante: «Dra. Ana» va con las A.
   order by lower(regexp_replace(f.name, '^(dra|dr|lcda|lcdo|licda|licdo|lda|ldo)\.?\s+', '', 'i'));
$$;

comment on function public.helios_directorio() is
  'Directorio de médicos: las clínicas publicadas (visibles, activas, no de prueba y con WhatsApp) con lo que enseña su tarjeta, red social y código (DIR-XXXX) incluidos. Pública.';

revoke all on function public.helios_directorio() from public;
grant execute on function public.helios_directorio() to anon, authenticated;

/**
 * El WhatsApp de Helios (Ajustes › Contacto), en E.164, o null si no está
 * configurado. Es el número al que escribe el paciente desde una tarjeta.
 */
create or replace function public.helios_directorio_whatsapp()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select (select pc.whatsapp_number from public.platform_contact pc where pc.id);
$$;

comment on function public.helios_directorio_whatsapp() is
  'Directorio de médicos: el WhatsApp de Helios (E.164) al que lleva el botón de cada tarjeta, o null. Pública.';

revoke all on function public.helios_directorio_whatsapp() from public;
grant execute on function public.helios_directorio_whatsapp() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Los interesados
-- ---------------------------------------------------------------------------

create table public.directory_leads (
  id               uuid primary key default gen_random_uuid(),
  merchant_id      uuid not null references public.merchants (id) on delete cascade,
  -- De quien escribió, como lo da WhatsApp (`helios_wa_e164`).
  phone_e164       text not null check (phone_e164 ~ '^\+[0-9]{8,15}$'),
  -- El wamid del primer mensaje.
  first_message_id text,
  messages         integer not null default 1 check (messages >= 1),
  first_at         timestamptz not null default now(),
  last_at          timestamptz not null default now(),
  constraint directory_leads_merchant_phone_key unique (merchant_id, phone_e164)
);

comment on table public.directory_leads is
  'Directorio de médicos: quien escribió al WhatsApp de Helios con el código de una tarjeta. Uno por médico y teléfono; escribir otra vez suma messages. El teléfono no se le pasa al médico: es para medir.';

create index directory_leads_first_at_idx on public.directory_leads (first_at desc);
create index directory_leads_merchant_first_at_idx on public.directory_leads (merchant_id, first_at desc);

-- El perfil con el mismo teléfono (los 10 últimos dígitos), sin recorrer la
-- tabla entera por cada interesado.
create index if not exists profiles_phone_national_key_idx
  on public.profiles (public.phone_national_key(phone_e164));

-- Se tocan solo por las RPC de abajo, que son security definer.
alter table public.directory_leads enable row level security;
revoke all on table public.directory_leads from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. El bot
-- ---------------------------------------------------------------------------

/**
 * Alguien escribió al WhatsApp de Helios con el código de una tarjeta.
 *
 * Código desconocido o tarjeta que ya no sale: `{ ok: false, motivo }` y no se
 * guarda nada. Si no, guarda el interesado (o, si ese teléfono ya había
 * escrito por ese médico, suma un mensaje y pone al día `last_at`) y devuelve
 * lo que enseña la tarjeta, para que el bot conteste con el contacto. El
 * mismo wamid otra vez (un reintento del proveedor) no suma.
 */
create or replace function public.bot_directorio_interesado(
  p_phone      text,
  p_code       text,
  p_message_id text
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
  v_merchant uuid;
  v_f        record;
  v_id       uuid;
  v_mensajes integer;
  v_nuevo    boolean;
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

  insert into public.directory_leads as d (merchant_id, phone_e164, first_message_id)
  values (v_merchant, v_tel, v_mid)
  on conflict (merchant_id, phone_e164) do update set
    messages = d.messages + case when excluded.first_message_id = d.first_message_id then 0 else 1 end,
    last_at = now()
  returning d.id, d.messages, (d.xmax = 0) into v_id, v_mensajes, v_nuevo;

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
    'whatsapp', v_f.whatsapp
  );
end;
$$;

comment on function public.bot_directorio_interesado(text, text, text) is
  'Directorio de médicos: el webhook guarda (o pone al día) a quien escribió con el código DIR-XXXX de una tarjeta publicada y recibe el contacto del médico. Solo service_role.';

revoke all on function public.bot_directorio_interesado(text, text, text) from public, anon, authenticated;
grant execute on function public.bot_directorio_interesado(text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 5. La conversión
-- ---------------------------------------------------------------------------

/**
 * La orden que convierte a un interesado: la primera de ese médico,
 * confirmada, no de prueba, creada en o después de su primer mensaje, cuyo
 * paciente tiene el mismo teléfono (los 10 últimos dígitos). Ninguna fila si
 * no se convirtió. Es LA regla: la usan todas las cifras. No se expone.
 */
create or replace function public.helios_directorio_conversion(
  p_merchant_id uuid,
  p_phone       text,
  p_desde       timestamptz
)
returns table (
  charge_id    uuid,
  order_number bigint,
  created_at   timestamptz,
  profile_id   uuid
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select c.id, c.order_number, c.created_at, c.user_id
    from public.charges c
    join public.profiles p on p.id = c.user_id
   where c.merchant_id = p_merchant_id
     and c.status = 'confirmed'
     and not c.is_test
     and c.created_at >= p_desde
     and public.phone_national_key(p.phone_e164) = public.phone_national_key(p_phone)
   order by c.created_at, c.order_number
   limit 1;
$$;

revoke all on function public.helios_directorio_conversion(uuid, text, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. La pestaña del superadmin
-- ---------------------------------------------------------------------------

/**
 * Lo de 20261026230000 (todo igual) más los interesados: en `totales`,
 * `interesados_30d`, `interesados_total`, `convertidos_30d` (de los
 * interesados de los últimos 30 días, los que ya se convirtieron) y
 * `convertidos_total`; en cada médico, `interesados: { total, d30,
 * convertidos, ultimo }` (`ultimo`: el último mensaje de cualquiera de ellos).
 * Los 30 días son días operativos con hoy, por el primer mensaje.
 */
create or replace function public.admin_directorio()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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
$$;

comment on function public.admin_directorio() is
  'Directorio de médicos: cada clínica con su tarjeta, los datos de su ficha, sus clics de contacto y sus interesados (los que escribieron al WhatsApp de Helios con su código, y cuántos ya tuvieron una orden), y el total del directorio por día.';

revoke all on function public.admin_directorio() from public, anon;
grant execute on function public.admin_directorio() to authenticated;

/**
 * Los interesados, el más reciente primero (por su primer mensaje); de un
 * médico si se pide. `paciente`: el perfil con ese teléfono, si existe (el
 * de la orden que lo convirtió, si la hay). `conversion`: esa orden. Tope de
 * 1.000 filas.
 */
create or replace function public.admin_directorio_interesados(
  p_merchant_id uuid default null,
  p_limit       integer default 200
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limite integer := least(greatest(coalesce(p_limit, 200), 1), 1000);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'lead_id', x.id,
             'merchant_id', x.merchant_id,
             -- El nombre de la tarjeta (el propio, o el de la ficha).
             'medico', coalesce(dl.display_name, public.helios_doctor_name(x.merchant_id)),
             'phone', x.phone_e164,
             'first_at', x.first_at,
             'last_at', x.last_at,
             'messages', x.messages,
             'paciente', case when pa.id is not null then
                           jsonb_build_object('profile_id', pa.id, 'nombre', pa.nombre) end,
             'conversion', case when cv.charge_id is not null then
                             jsonb_build_object('charge_id', cv.charge_id, 'order_number', cv.order_number,
                                                'created_at', cv.created_at) end
           ) order by x.first_at desc, x.last_at desc, x.id)
      from (
        select l.*
          from public.directory_leads l
         where p_merchant_id is null or l.merchant_id = p_merchant_id
         order by l.first_at desc, l.last_at desc, l.id
         limit v_limite
      ) x
      left join public.directory_listings dl on dl.merchant_id = x.merchant_id
      left join lateral public.helios_directorio_conversion(x.merchant_id, x.phone_e164, x.first_at) cv on true
      left join lateral (
        select p.id,
               coalesce(nullif(btrim(p.full_name), ''),
                        nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), '')) as nombre
          from public.profiles p
         where public.phone_national_key(p.phone_e164) = public.phone_national_key(x.phone_e164)
         order by (p.id = cv.profile_id) desc nulls last, p.is_test, p.created_at desc
         limit 1
      ) pa on true
  ), '[]'::jsonb);
end;
$$;

comment on function public.admin_directorio_interesados(uuid, integer) is
  'Directorio de médicos: los interesados (teléfono, fechas, mensajes), el más reciente primero, con el paciente de ese teléfono y la orden que lo convirtió, si los hay. Los dos roles.';

revoke all on function public.admin_directorio_interesados(uuid, integer) from public, anon;
grant execute on function public.admin_directorio_interesados(uuid, integer) to authenticated;
