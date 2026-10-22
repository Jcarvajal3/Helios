-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — La agenda de médicos por afiliar (superadmin › Agenda)
--
-- El equipo sale a buscar médicos: los apunta con su teléfono y su
-- dirección, los llama, les escribe y les agenda una reunión. Hasta hoy eso
-- vivía en una hoja de cálculo. Ahora:
--
--   1. `doctor_leads`: cada médico por afiliar, con su estado (sin contactar,
--      contactado, respondió, no respondió, reunión agendada, afiliado o
--      descartado), su próxima reunión y cuándo volver a llamar.
--   2. `doctor_lead_activities`: la historia de cada uno, como las gestiones
--      de cobranza: cada contacto, cada cambio de estado y la afiliación.
--      Solo se añade.
--   3. El cruce con la afiliación: cuando un médico llena el formulario de
--      la portada (`merchant_applications`) o el equipo da de alta una clínica
--      (`merchants`), los leads que coinciden por teléfono, correo o nombre
--      pasan solos a «afiliado». Y al apuntar un lead que ya es cliente, igual.
--      El cruce nunca rompe la afiliación: si falla, deja un aviso y sigue.
--   4. Las RPC del panel: el tablero, la historia, guardar, anotar una
--      gestión y borrar. Cualquiera del equipo, como el seguimiento; todo
--      queda en `audit.admin_actions`.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. Los leads
-- ---------------------------------------------------------------------------

/**
 * La clave con la que se compara un nombre: sin tildes, sin mayúsculas, sin
 * «Dr.» ni «Dra.» delante y sin signos. «Dra. María  Pérez» y «maria perez»
 * dan lo mismo.
 */
create or replace function public.helios_lead_name_key(p_name text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select nullif(btrim(regexp_replace(
           regexp_replace(
             translate(lower(btrim(coalesce(p_name, ''))), 'áéíóúüñàèìòùäëïö', 'aeiouunaeiouaeio'),
             '^(doctora|doctor|dra|dr)\.?\s+', ''),
           '[^a-z0-9]+', ' ', 'g')), '');
$$;

revoke all on function public.helios_lead_name_key(text) from public, anon, authenticated;

create table public.doctor_leads (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (char_length(btrim(name)) between 3 and 120),
  -- Solo para comparar con la afiliación (`helios_lead_name_key`).
  name_key        text generated always as (public.helios_lead_name_key(name)) stored,
  clinic_name     text check (clinic_name is null or char_length(clinic_name) <= 120),
  specialty       text check (specialty is null or char_length(specialty) <= 80),
  -- E.164 venezolano (`helios_normalize_ve_phone`).
  phone           text,
  email           text,
  address         text check (address is null or char_length(address) <= 300),
  city            text check (city is null or char_length(city) <= 80),
  source          text check (source in ('referido', 'redes', 'visita', 'evento', 'base_de_datos', 'otro')),
  notes           text check (notes is null or char_length(notes) <= 2000),
  status          text not null default 'nuevo'
                  check (status in ('nuevo', 'contactado', 'respondio', 'no_respondio', 'reunion', 'convertido', 'descartado')),
  -- La reunión: la próxima, o la última si ya pasó.
  meeting_at      timestamptz,
  meeting_mode    text check (meeting_mode in ('presencial', 'videollamada', 'llamada')),
  meeting_place   text check (meeting_place is null or char_length(meeting_place) <= 300),
  -- Cuándo volver a llamar. Manda la de la última gestión.
  next_contact_on date,
  -- Quién del equipo lo lleva.
  assigned_to     uuid references auth.users (id),
  -- La afiliación, cuando llega.
  merchant_application_id uuid references public.merchant_applications (id) on delete set null,
  merchant_id     uuid references public.merchants (id) on delete set null,
  converted_at    timestamptz,
  -- 'formulario' (llenó el de la portada), 'alta' (el equipo creó la
  -- clínica), 'agenda' (ya era cliente al apuntarlo) o 'manual'.
  converted_via   text check (converted_via in ('formulario', 'alta', 'agenda', 'manual')),
  -- Por qué dato se reconoció: 'telefono', 'correo' o 'nombre'.
  match_reason    text check (match_reason in ('telefono', 'correo', 'nombre')),
  created_by      uuid references auth.users (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

comment on table public.doctor_leads is
  'Agenda: los médicos por afiliar que el equipo contacta, con su estado, su reunión y su afiliación cuando llega.';

create index doctor_leads_phone_idx on public.doctor_leads (phone) where phone is not null;
create index doctor_leads_email_idx on public.doctor_leads (lower(email)) where email is not null;
create index doctor_leads_name_key_idx on public.doctor_leads (name_key);
create index doctor_leads_meeting_idx on public.doctor_leads (meeting_at) where meeting_at is not null;

create table public.doctor_lead_activities (
  id          uuid primary key default gen_random_uuid(),
  lead_id     uuid not null references public.doctor_leads (id) on delete cascade,
  -- 'creado' (se apuntó), 'gestion' (un contacto o un cambio de estado) o
  -- 'conversion' (llegó su afiliación; la anota el sistema).
  kind        text not null check (kind in ('creado', 'gestion', 'conversion')),
  channel     text check (channel in ('llamada', 'whatsapp', 'visita', 'correo', 'redes')),
  status_from text,
  status_to   text,
  meeting_at  timestamptz,
  note        text check (note is null or char_length(note) <= 2000),
  -- Null: lo hizo el sistema.
  actor       uuid references auth.users (id),
  created_at  timestamptz not null default now()
);

comment on table public.doctor_lead_activities is
  'Agenda: la historia de cada médico por afiliar (contactos, cambios de estado y afiliación). Solo se añade.';

create index doctor_lead_activities_lead_idx on public.doctor_lead_activities (lead_id, created_at desc);

-- Se tocan solo por las funciones de abajo, que son security definer.
alter table public.doctor_leads enable row level security;
alter table public.doctor_lead_activities enable row level security;
revoke all on table public.doctor_leads from public, anon, authenticated;
revoke all on table public.doctor_lead_activities from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. El cruce con la afiliación
-- ---------------------------------------------------------------------------

/**
 * Marca un lead como afiliado y lo enlaza con su solicitud o su clínica. No
 * pisa un enlace que ya tenga; la historia se anota solo si algo cambió.
 */
create or replace function public.helios_marcar_lead_afiliado(
  p_lead_id        uuid,
  p_application_id uuid,
  p_merchant_id    uuid,
  p_via            text,
  p_reason         text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_lead   public.doctor_leads%rowtype;
  v_nota   text;
  v_nombre text;
begin
  select * into v_lead from public.doctor_leads where id = p_lead_id for update;
  if not found then
    return;
  end if;

  -- Nada nuevo: ya era afiliado y ya tenía esos enlaces.
  if v_lead.status = 'convertido'
     and (p_application_id is null or v_lead.merchant_application_id is not null)
     and (p_merchant_id is null or v_lead.merchant_id is not null) then
    return;
  end if;

  update public.doctor_leads set
    merchant_application_id = coalesce(merchant_application_id, p_application_id),
    merchant_id             = coalesce(merchant_id, p_merchant_id),
    status                  = 'convertido',
    converted_at            = coalesce(converted_at, now()),
    converted_via           = coalesce(converted_via, p_via),
    match_reason            = coalesce(match_reason, p_reason),
    next_contact_on         = null,
    updated_at              = now()
  where id = p_lead_id;

  if p_merchant_id is not null and v_lead.merchant_id is null then
    select name into v_nombre from public.merchants where id = p_merchant_id;
    v_nota := format('Quedó dada de alta su clínica: %s.', coalesce(v_nombre, 'sin nombre'));
  elsif p_application_id is not null and v_lead.merchant_application_id is null then
    v_nota := 'Llenó el formulario de afiliación.';
  else
    v_nota := 'Ya es cliente de Helios.';
  end if;

  if p_reason is not null then
    v_nota := v_nota || ' Se reconoció por su ' || case p_reason
      when 'telefono' then 'teléfono'
      when 'correo' then 'correo'
      else 'nombre'
    end || '.';
  end if;

  insert into public.doctor_lead_activities (lead_id, kind, status_from, status_to, note, actor)
  values (p_lead_id, 'conversion', v_lead.status, 'convertido', v_nota, null);
end;
$$;

/**
 * Los leads que son ese médico: el mismo teléfono, el mismo correo o el
 * mismo nombre (de al menos dos palabras: un nombre suelto se repite mucho).
 */
create or replace function public.helios_leads_que_coinciden(p_phone text, p_email text, p_name text)
returns table (lead_id uuid, reason text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with dato as (
    select public.helios_normalize_ve_phone(p_phone) as tel,
           nullif(lower(btrim(coalesce(p_email, ''))), '') as correo,
           public.helios_lead_name_key(p_name) as nombre
  )
  select l.id,
         case
           when d.tel is not null and l.phone = d.tel then 'telefono'
           when d.correo is not null and lower(l.email) = d.correo then 'correo'
           else 'nombre'
         end
    from public.doctor_leads l
   cross join dato d
   where (d.tel is not null and l.phone = d.tel)
      or (d.correo is not null and lower(l.email) = d.correo)
      or (d.nombre is not null and position(' ' in d.nombre) > 0 and l.name_key = d.nombre);
$$;

/**
 * Llegó una solicitud de la portada, o nació una clínica: los leads que son
 * ese médico pasan a afiliado. Un lead ya enlazado con otra clínica no se
 * toca: es otro consultorio del mismo médico.
 */
create or replace function public.helios_cruzar_afiliacion_con_leads(
  p_phone          text,
  p_email          text,
  p_name           text,
  p_application_id uuid,
  p_merchant_id    uuid,
  p_via            text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
begin
  for r in
    select c.lead_id, c.reason
      from public.helios_leads_que_coinciden(p_phone, p_email, p_name) c
      join public.doctor_leads l on l.id = c.lead_id
     where l.merchant_id is null
        or l.merchant_id = p_merchant_id
  loop
    perform public.helios_marcar_lead_afiliado(r.lead_id, p_application_id, p_merchant_id, p_via, r.reason);
  end loop;
end;
$$;

/**
 * Al revés: un lead recién apuntado (o corregido) que ya es cliente. Mira
 * las clínicas reales y las solicitudes que no se rechazaron.
 */
create or replace function public.helios_cruzar_lead(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_lead   public.doctor_leads%rowtype;
  v_m      uuid;
  v_m_por  text;
  v_app    uuid;
  v_app_m  uuid;
  v_app_por text;
begin
  select * into v_lead from public.doctor_leads where id = p_lead_id;
  if not found or v_lead.status = 'convertido' then
    return;
  end if;

  select m.id,
         case
           when v_lead.phone is not null and public.helios_normalize_ve_phone(m.phone) = v_lead.phone then 'telefono'
           when v_lead.email is not null and lower(m.email) = lower(v_lead.email) then 'correo'
           else 'nombre'
         end
    into v_m, v_m_por
    from public.merchants m
   where not m.is_test
     and ((v_lead.phone is not null and public.helios_normalize_ve_phone(m.phone) = v_lead.phone)
       or (v_lead.email is not null and lower(m.email) = lower(v_lead.email))
       or (position(' ' in coalesce(v_lead.name_key, '')) > 0
           and public.helios_lead_name_key(m.owner_name) = v_lead.name_key))
   order by m.created_at desc
   limit 1;

  select a.id, a.merchant_id,
         case
           when v_lead.phone is not null and public.helios_normalize_ve_phone(a.phone) = v_lead.phone then 'telefono'
           when v_lead.email is not null and lower(a.email) = lower(v_lead.email) then 'correo'
           else 'nombre'
         end
    into v_app, v_app_m, v_app_por
    from public.merchant_applications a
   where a.status <> 'rejected'
     and ((v_lead.phone is not null and public.helios_normalize_ve_phone(a.phone) = v_lead.phone)
       or (v_lead.email is not null and lower(a.email) = lower(v_lead.email))
       or (position(' ' in coalesce(v_lead.name_key, '')) > 0
           and public.helios_lead_name_key(a.owner_name) = v_lead.name_key))
   order by a.created_at desc
   limit 1;

  if v_m is null and v_app is null then
    return;
  end if;

  perform public.helios_marcar_lead_afiliado(
    p_lead_id, v_app, coalesce(v_m, v_app_m), 'agenda', coalesce(v_m_por, v_app_por));
end;
$$;

revoke all on function public.helios_marcar_lead_afiliado(uuid, uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.helios_leads_que_coinciden(text, text, text) from public, anon, authenticated;
revoke all on function public.helios_cruzar_afiliacion_con_leads(text, text, text, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.helios_cruzar_lead(uuid) from public, anon, authenticated;

-- Los disparadores. Lo de la agenda nunca tumba una afiliación: si el cruce
-- falla, se avisa y la solicitud o el alta siguen.

create or replace function public.helios_leads_al_llegar_la_solicitud()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  begin
    perform public.helios_cruzar_afiliacion_con_leads(
      new.phone, new.email, new.owner_name, new.id, new.merchant_id, 'formulario');
  exception when others then
    raise warning 'Agenda: no se pudo cruzar la solicitud % con los leads: %', new.id, sqlerrm;
  end;
  return null;
end;
$$;

create or replace function public.helios_leads_al_aprobar_la_solicitud()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
begin
  begin
    for r in
      select id from public.doctor_leads
       where merchant_application_id = new.id and merchant_id is null
    loop
      perform public.helios_marcar_lead_afiliado(r.id, new.id, new.merchant_id, 'formulario', null);
    end loop;
  exception when others then
    raise warning 'Agenda: no se pudo enlazar la clínica de la solicitud %: %', new.id, sqlerrm;
  end;
  return null;
end;
$$;

create or replace function public.helios_leads_al_nacer_la_clinica()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.is_test then
    return null;
  end if;
  begin
    perform public.helios_cruzar_afiliacion_con_leads(
      new.phone, new.email, new.owner_name, null, new.id, 'alta');
  exception when others then
    raise warning 'Agenda: no se pudo cruzar la clínica % con los leads: %', new.id, sqlerrm;
  end;
  return null;
end;
$$;

revoke all on function public.helios_leads_al_llegar_la_solicitud() from public, anon, authenticated;
revoke all on function public.helios_leads_al_aprobar_la_solicitud() from public, anon, authenticated;
revoke all on function public.helios_leads_al_nacer_la_clinica() from public, anon, authenticated;

create trigger doctor_leads_al_llegar_la_solicitud
  after insert on public.merchant_applications
  for each row execute function public.helios_leads_al_llegar_la_solicitud();

create trigger doctor_leads_al_aprobar_la_solicitud
  after update of merchant_id on public.merchant_applications
  for each row when (new.merchant_id is not null and old.merchant_id is distinct from new.merchant_id)
  execute function public.helios_leads_al_aprobar_la_solicitud();

create trigger doctor_leads_al_nacer_la_clinica
  after insert on public.merchants
  for each row execute function public.helios_leads_al_nacer_la_clinica();

-- ---------------------------------------------------------------------------
-- 3. El tablero
-- ---------------------------------------------------------------------------

create or replace function public.admin_doctor_leads()
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
             'id', l.id,
             'name', l.name,
             'clinic_name', l.clinic_name,
             'specialty', l.specialty,
             'phone', l.phone,
             'email', l.email,
             'address', l.address,
             'city', l.city,
             'source', l.source,
             'notes', l.notes,
             'status', l.status,
             'meeting_at', l.meeting_at,
             'meeting_mode', l.meeting_mode,
             'meeting_place', l.meeting_place,
             'next_contact_on', l.next_contact_on,
             'assigned_to', l.assigned_to,
             'assigned_name', coalesce(pa.full_name, au.email),
             'converted_at', l.converted_at,
             'converted_via', l.converted_via,
             'match_reason', l.match_reason,
             'application_id', l.merchant_application_id,
             'application_status', ma.status,
             'merchant_id', l.merchant_id,
             'merchant_name', m.name,
             'created_at', l.created_at,
             'updated_at', l.updated_at,
             'activities_count', coalesce(a.cuantas, 0),
             'last_activity', a.ultima
           ) order by l.created_at desc)
      from public.doctor_leads l
      left join public.platform_admins pa on pa.user_id = l.assigned_to
      left join auth.users au on au.id = l.assigned_to
      left join public.merchant_applications ma on ma.id = l.merchant_application_id
      left join public.merchants m on m.id = l.merchant_id
      left join lateral (
        select count(*) as cuantas,
               (array_agg(jsonb_build_object(
                  'created_at', ac.created_at,
                  'kind', ac.kind,
                  'channel', ac.channel,
                  'status_to', ac.status_to,
                  'note', ac.note,
                  'actor_name', coalesce(pb.full_name, ub.email)
                ) order by ac.created_at desc))[1] as ultima
          from public.doctor_lead_activities ac
          left join public.platform_admins pb on pb.user_id = ac.actor
          left join auth.users ub on ub.id = ac.actor
         where ac.lead_id = l.id
      ) a on true
  ), '[]'::jsonb);
end;
$$;

comment on function public.admin_doctor_leads() is
  'Agenda: los médicos por afiliar con su estado, su reunión, quién los lleva, su afiliación y su última gestión.';

revoke all on function public.admin_doctor_leads() from public, anon;
grant execute on function public.admin_doctor_leads() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. La historia de un lead
-- ---------------------------------------------------------------------------

create or replace function public.admin_doctor_lead_activities(p_lead_id uuid)
returns table (
  id          uuid,
  created_at  timestamptz,
  kind        text,
  channel     text,
  status_from text,
  status_to   text,
  meeting_at  timestamptz,
  note        text,
  actor_name  text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  select ac.id, ac.created_at, ac.kind, ac.channel, ac.status_from, ac.status_to, ac.meeting_at, ac.note,
         coalesce(pa.full_name, au.email)::text
    from public.doctor_lead_activities ac
    left join public.platform_admins pa on pa.user_id = ac.actor
    left join auth.users au on au.id = ac.actor
   where ac.lead_id = p_lead_id
   order by ac.created_at desc
   limit 200;
end;
$$;

comment on function public.admin_doctor_lead_activities(uuid) is
  'Agenda: la historia de un médico por afiliar, de lo más reciente a lo más viejo.';

revoke all on function public.admin_doctor_lead_activities(uuid) from public, anon;
grant execute on function public.admin_doctor_lead_activities(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Apuntar o corregir un lead
-- ---------------------------------------------------------------------------

/**
 * Crea un lead (`p_lead_id` null) o corrige sus datos. `p` trae `name`,
 * `clinic_name`, `specialty`, `phone`, `email`, `address`, `city`, `source`,
 * `notes` y `assigned_to`; lo que no llega queda vacío. Devuelve
 * `{ id, status, merchant_name }`: si el médico ya era cliente, sale
 * afiliado y con el nombre de su clínica.
 */
create or replace function public.admin_save_doctor_lead(p_lead_id uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor   uuid := auth.uid();
  v_nombre  text := nullif(btrim(regexp_replace(coalesce(p->>'name', ''), '\s+', ' ', 'g')), '');
  v_clinica text := nullif(btrim(regexp_replace(coalesce(p->>'clinic_name', ''), '\s+', ' ', 'g')), '');
  v_esp     text := nullif(btrim(coalesce(p->>'specialty', '')), '');
  v_tel_raw text := nullif(btrim(coalesce(p->>'phone', '')), '');
  v_tel     text;
  v_correo  text := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  v_dir     text := nullif(btrim(coalesce(p->>'address', '')), '');
  v_ciudad  text := nullif(btrim(coalesce(p->>'city', '')), '');
  v_origen  text := nullif(btrim(coalesce(p->>'source', '')), '');
  v_notas   text := nullif(btrim(coalesce(p->>'notes', '')), '');
  v_resp    uuid := nullif(p->>'assigned_to', '')::uuid;
  v_otro    text;
  v_id      uuid;
  v_status  text;
  v_clinica_de text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_nombre is null or char_length(v_nombre) < 3 or char_length(v_nombre) > 120 then
    raise exception 'Escribe el nombre del médico.' using errcode = '22023';
  end if;
  if v_clinica is not null and char_length(v_clinica) > 120 then
    raise exception 'El nombre del consultorio es demasiado largo.' using errcode = '22023';
  end if;
  if v_esp is not null and char_length(v_esp) > 80 then
    raise exception 'La especialidad es demasiado larga.' using errcode = '22023';
  end if;
  if v_tel_raw is not null then
    v_tel := public.helios_normalize_ve_phone(v_tel_raw);
    if v_tel is null then
      raise exception 'El teléfono no parece venezolano: 0212 5551234 o 0414 1234567.' using errcode = '22023';
    end if;
  end if;
  if v_correo is not null and not public.helios_valid_email(v_correo) then
    raise exception 'El correo no parece un correo.' using errcode = '22023';
  end if;
  if v_dir is not null and char_length(v_dir) > 300 then
    raise exception 'La dirección es demasiado larga.' using errcode = '22023';
  end if;
  if v_ciudad is not null and char_length(v_ciudad) > 80 then
    raise exception 'La ciudad es demasiado larga.' using errcode = '22023';
  end if;
  if v_origen is not null and v_origen not in ('referido', 'redes', 'visita', 'evento', 'base_de_datos', 'otro') then
    raise exception 'Origen desconocido: %', v_origen using errcode = '22023';
  end if;
  if v_notas is not null and char_length(v_notas) > 2000 then
    raise exception 'Las notas no pueden pasar de 2000 caracteres.' using errcode = '22023';
  end if;
  if v_resp is not null and not exists (
    select 1 from public.platform_admins where user_id = v_resp and is_active
  ) then
    raise exception 'El responsable tiene que ser alguien del equipo.' using errcode = '22023';
  end if;

  -- El mismo médico dos veces es la misma llamada hecha dos veces.
  select l.name into v_otro
    from public.doctor_leads l
   where l.id is distinct from p_lead_id
     and ((v_tel is not null and l.phone = v_tel) or (v_correo is not null and lower(l.email) = v_correo))
   limit 1;
  if found then
    raise exception 'Ya hay un médico en la agenda con ese teléfono o correo: %.', v_otro using errcode = '23505';
  end if;

  if p_lead_id is null then
    insert into public.doctor_leads
      (name, clinic_name, specialty, phone, email, address, city, source, notes, assigned_to, created_by)
    values
      (v_nombre, v_clinica, v_esp, v_tel, v_correo, v_dir, v_ciudad, v_origen, v_notas, v_resp, v_actor)
    returning id into v_id;

    insert into public.doctor_lead_activities (lead_id, kind, status_to, actor)
    values (v_id, 'creado', 'nuevo', v_actor);

    perform audit.log(v_actor, 'doctor_lead.created', v_id, jsonb_build_object(
      'lead_name', v_nombre, 'clinic_name', v_clinica, 'phone', v_tel, 'source', v_origen));
  else
    update public.doctor_leads set
      name = v_nombre, clinic_name = v_clinica, specialty = v_esp, phone = v_tel, email = v_correo,
      address = v_dir, city = v_ciudad, source = v_origen, notes = v_notas, assigned_to = v_resp,
      updated_at = now()
    where id = p_lead_id
    returning id into v_id;
    if v_id is null then
      raise exception 'Ese médico ya no está en la agenda.' using errcode = 'P0002';
    end if;

    perform audit.log(v_actor, 'doctor_lead.updated', v_id, jsonb_build_object(
      'lead_name', v_nombre, 'clinic_name', v_clinica, 'phone', v_tel, 'source', v_origen,
      'assigned_to', v_resp));
  end if;

  -- ¿Ya es cliente? Con un dato nuevo puede que ahora sí se reconozca.
  perform public.helios_cruzar_lead(v_id);

  select l.status, m.name into v_status, v_clinica_de
    from public.doctor_leads l
    left join public.merchants m on m.id = l.merchant_id
   where l.id = v_id;

  return jsonb_build_object('id', v_id, 'status', v_status, 'merchant_name', v_clinica_de);
end;
$$;

comment on function public.admin_save_doctor_lead(uuid, jsonb) is
  'Agenda: apunta un médico por afiliar o corrige sus datos. Rechaza un teléfono o correo repetido y lo marca afiliado si ya es cliente.';

revoke all on function public.admin_save_doctor_lead(uuid, jsonb) from public, anon;
grant execute on function public.admin_save_doctor_lead(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Anotar una gestión
-- ---------------------------------------------------------------------------

/**
 * Un contacto con el médico o un cambio de estado, como una gestión de
 * cobranza. `p_status` es el estado en que queda (puede ser el mismo).
 *
 * - «Reunión agendada» pide la fecha y la hora, si no tenía ya una.
 * - Pasar de «reunión agendada» a otro estado antes de la reunión la anula.
 * - `p_next_contact_on` es cuándo volver a llamar; manda el de la última
 *   gestión (sin fecha: nada pendiente).
 */
create or replace function public.admin_log_doctor_lead_contact(
  p_lead_id         uuid,
  p_status          text,
  p_channel         text default null,
  p_note            text default null,
  p_meeting_at      timestamptz default null,
  p_meeting_mode    text default null,
  p_meeting_place   text default null,
  p_next_contact_on date default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor   uuid := auth.uid();
  v_lead    public.doctor_leads%rowtype;
  v_note    text := nullif(btrim(coalesce(p_note, '')), '');
  v_lugar   text := nullif(btrim(coalesce(p_meeting_place, '')), '');
  v_hoy     date := public.helios_business_date(now());
  v_reunion timestamptz;
  v_modo    text;
  v_id      uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_lead from public.doctor_leads where id = p_lead_id for update;
  if not found then
    raise exception 'Ese médico ya no está en la agenda.' using errcode = 'P0002';
  end if;

  if p_status is null or p_status not in
     ('nuevo', 'contactado', 'respondio', 'no_respondio', 'reunion', 'convertido', 'descartado') then
    raise exception 'Estado desconocido: %', coalesce(p_status, '(vacío)') using errcode = '22023';
  end if;
  if p_channel is not null and p_channel not in ('llamada', 'whatsapp', 'visita', 'correo', 'redes') then
    raise exception 'Canal desconocido: %', p_channel using errcode = '22023';
  end if;
  if v_note is not null and char_length(v_note) > 2000 then
    raise exception 'La nota no puede pasar de 2000 caracteres.' using errcode = '22023';
  end if;
  if p_meeting_mode is not null and p_meeting_mode not in ('presencial', 'videollamada', 'llamada') then
    raise exception 'Tipo de reunión desconocido: %', p_meeting_mode using errcode = '22023';
  end if;
  if v_lugar is not null and char_length(v_lugar) > 300 then
    raise exception 'El lugar de la reunión es demasiado largo.' using errcode = '22023';
  end if;
  if p_next_contact_on is not null and p_next_contact_on < v_hoy then
    raise exception 'La fecha para volver a llamar ya pasó.' using errcode = '22023';
  end if;
  if p_meeting_at is not null and (p_meeting_at at time zone 'America/Caracas')::date < v_hoy then
    raise exception 'La fecha de la reunión ya pasó.' using errcode = '22023';
  end if;

  -- Sin nada que anotar no hay gestión.
  if p_status = v_lead.status and v_note is null and p_channel is null
     and p_meeting_at is null and p_next_contact_on is not distinct from v_lead.next_contact_on then
    raise exception 'Cuenta qué pasó o cambia el estado.' using errcode = '22023';
  end if;

  v_reunion := v_lead.meeting_at;
  v_modo := v_lead.meeting_mode;
  if p_status = 'reunion' then
    if p_meeting_at is not null then
      v_reunion := p_meeting_at;
      v_modo := coalesce(p_meeting_mode, v_modo, 'presencial');
    elsif v_lead.status <> 'reunion' or v_lead.meeting_at is null or v_lead.meeting_at < now() then
      raise exception 'Pon la fecha y la hora de la reunión.' using errcode = '22023';
    elsif p_meeting_mode is not null then
      v_modo := p_meeting_mode;
    end if;
  elsif v_lead.status = 'reunion' and v_lead.meeting_at > now() then
    -- Se sale de «reunión agendada» antes de la reunión: se anula.
    v_reunion := null;
    v_modo := null;
    v_note := coalesce(v_note || ' ', '') || '(Se anuló la reunión del '
      || to_char(v_lead.meeting_at at time zone 'America/Caracas', 'DD/MM/YYYY HH24:MI') || '.)';
  end if;

  update public.doctor_leads set
    status          = p_status,
    meeting_at      = v_reunion,
    meeting_mode    = v_modo,
    meeting_place   = case
                        when v_reunion is null then null
                        when p_status = 'reunion' and (p_meeting_at is not null or v_lugar is not null) then v_lugar
                        else meeting_place
                      end,
    next_contact_on = case when p_status in ('convertido', 'descartado') then null else p_next_contact_on end,
    converted_at    = case
                        when p_status = 'convertido' then coalesce(converted_at, now())
                        else null
                      end,
    converted_via   = case
                        when p_status = 'convertido' then coalesce(converted_via, 'manual')
                        else null
                      end,
    match_reason    = case when p_status = 'convertido' then match_reason else null end,
    updated_at      = now()
  where id = p_lead_id;

  insert into public.doctor_lead_activities
    (lead_id, kind, channel, status_from, status_to, meeting_at, note, actor)
  values
    (p_lead_id, 'gestion', p_channel, v_lead.status, p_status,
     case when p_status = 'reunion' then v_reunion end, v_note, v_actor)
  returning id into v_id;

  perform audit.log(v_actor, 'doctor_lead.contact', p_lead_id, jsonb_build_object(
    'activity_id', v_id,
    'lead_name', v_lead.name,
    'status_from', v_lead.status,
    'status_to', p_status,
    'channel', p_channel,
    'meeting_at', case when p_status = 'reunion' then v_reunion end,
    'next_contact_on', p_next_contact_on,
    'note', v_note
  ));

  return v_id;
end;
$$;

comment on function public.admin_log_doctor_lead_contact(uuid, text, text, text, timestamptz, text, text, date) is
  'Agenda: anota una gestión con un médico por afiliar (contacto, estado, reunión y cuándo volver). Queda en audit.admin_actions.';

revoke all on function public.admin_log_doctor_lead_contact(uuid, text, text, text, timestamptz, text, text, date) from public, anon;
grant execute on function public.admin_log_doctor_lead_contact(uuid, text, text, text, timestamptz, text, text, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Borrar un lead
-- ---------------------------------------------------------------------------

/** Borra el lead y su historia. La bitácora guarda sus datos. */
create or replace function public.admin_delete_doctor_lead(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_lead  public.doctor_leads%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  delete from public.doctor_leads where id = p_lead_id returning * into v_lead;
  if v_lead.id is null then
    raise exception 'Ese médico ya no está en la agenda.' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'doctor_lead.deleted', p_lead_id, jsonb_build_object(
    'lead_name', v_lead.name,
    'clinic_name', v_lead.clinic_name,
    'phone', v_lead.phone,
    'email', v_lead.email,
    'address', v_lead.address,
    'status', v_lead.status
  ));
end;
$$;

comment on function public.admin_delete_doctor_lead(uuid) is
  'Agenda: borra un médico por afiliar y su historia. Queda en audit.admin_actions con sus datos.';

revoke all on function public.admin_delete_doctor_lead(uuid) from public, anon;
grant execute on function public.admin_delete_doctor_lead(uuid) to authenticated;
