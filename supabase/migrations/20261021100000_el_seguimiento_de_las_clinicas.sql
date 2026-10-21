-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El seguimiento de las clínicas (superadmin › Seguimiento)
--
-- El equipo llama a los médicos y a sus secretarias para saber cómo les va
-- con Helios, pedirles su opinión y resolverles dudas. Hasta hoy eso no
-- quedaba en ningún sitio: quién llamó, a quién, qué dijeron y cuándo volver.
--
--   1. `merchant_followups`: cada contacto con una clínica, con quién se
--      habló, por dónde, de qué y cuándo volver a llamar. Solo se añade: una
--      nota no se edita ni se borra (si algo cambió, se anota otra).
--   2. `admin_followups_board()`: el tablero. Cada clínica con su médico, su
--      teléfono, todo su personal (con el número de WhatsApp con el que usa el
--      bot y cuántas órdenes registró cada uno) y su último contacto.
--   3. `admin_merchant_followups(p_merchant_id)`: la historia de una clínica.
--   4. `admin_log_merchant_followup(...)`: anotar un contacto. Lo puede hacer
--      cualquiera del equipo, como una gestión de cobranza, y queda en
--      `audit.admin_actions`.
--
-- Las órdenes que cuenta son las de `charges.requested_by`: quien la registró,
-- desde el panel o desde el bot. Sin las de pacientes de prueba.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. Los contactos
-- ---------------------------------------------------------------------------

create table public.merchant_followups (
  id              uuid primary key default gen_random_uuid(),
  merchant_id     uuid not null references public.merchants (id),
  -- Con quién se habló, si es alguien del personal. Null: con el consultorio,
  -- a su teléfono de contacto.
  contact_user_id uuid references auth.users (id),
  channel         text not null check (channel in ('llamada', 'whatsapp', 'visita', 'correo')),
  topic           text not null check (topic in ('seguimiento', 'opinion', 'soporte', 'capacitacion')),
  note            text not null check (char_length(btrim(note)) between 3 and 2000),
  -- Cuándo volver a llamar. Manda la del último contacto: una nota nueva sin
  -- fecha quiere decir que no hay nada pendiente.
  next_contact_on date,
  actor           uuid not null references auth.users (id),
  created_at      timestamptz not null default now()
);

comment on table public.merchant_followups is
  'Seguimiento de las clínicas: cada contacto del equipo con una clínica (con quién, por dónde, de qué, qué se habló y cuándo volver). Solo se añade.';

create index merchant_followups_merchant_idx
  on public.merchant_followups (merchant_id, created_at desc);

-- Se toca solo por las RPC de abajo, que son security definer.
alter table public.merchant_followups enable row level security;
revoke all on table public.merchant_followups from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. El tablero
-- ---------------------------------------------------------------------------

create or replace function public.admin_followups_board()
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

  return coalesce((
    select jsonb_agg(c.fila order by c.nombre)
    from (
      select m.name as nombre, jsonb_build_object(
        'merchant_id', m.id,
        'name', m.name,
        'status', m.status,
        'is_test', m.is_test,
        'city', m.city,
        'specialty', m.specialty,
        'phone', m.phone,
        'email', m.email,
        'owner_name', m.owner_name,
        'doctor_name', public.helios_doctor_name(m.id),
        'created_at', m.created_at,
        -- Las de la clínica entera, cualquiera que las registrara.
        'orders_confirmed', coalesce(o.confirmadas, 0),
        'orders_30d', coalesce(o.de_30_dias, 0),
        'last_order_at', o.ultima,
        'staff', coalesce(p.personal, '[]'::jsonb),
        'followups_count', coalesce(f.cuantos, 0),
        'last_followup', f.ultimo,
        'next_contact_on', f.volver
      ) as fila
      from public.merchants m
      left join lateral (
        select count(*) filter (where ch.status = 'confirmed') as confirmadas,
               count(*) filter (where ch.status = 'confirmed' and ch.business_date >= v_desde) as de_30_dias,
               max(ch.created_at) as ultima
          from public.charges ch
         where ch.merchant_id = m.id and not ch.is_test
      ) o on true
      left join lateral (
        select jsonb_agg(jsonb_build_object(
                 'user_id', mu.user_id,
                 'name', coalesce(nullif(btrim(au.raw_user_meta_data ->> 'full_name'), ''), au.email),
                 'email', au.email,
                 -- El número con el que usa el bot; las cuentas antiguas
                 -- pueden tener uno en auth.
                 'phone', coalesce(w.phone_e164, au.phone),
                 'role', mu.role,
                 'branch', b.name,
                 'joined_at', mu.created_at,
                 'last_sign_in_at', au.last_sign_in_at,
                 'orders_registered', coalesce(u.registradas, 0),
                 'orders_confirmed', coalesce(u.confirmadas, 0),
                 'orders_30d', coalesce(u.de_30_dias, 0),
                 'orders_whatsapp', coalesce(u.por_whatsapp, 0),
                 'last_order_at', u.ultima
               ) order by coalesce(u.confirmadas, 0) desc, mu.created_at) as personal
          from public.merchant_users mu
          join auth.users au on au.id = mu.user_id
          left join public.merchant_branches b on b.id = mu.branch_id
          left join public.staff_whatsapp_numbers w
            on w.user_id = mu.user_id and w.merchant_id = m.id and w.revoked_at is null
          left join lateral (
            select count(*) as registradas,
                   count(*) filter (where ch.status = 'confirmed') as confirmadas,
                   count(*) filter (where ch.status = 'confirmed' and ch.business_date >= v_desde) as de_30_dias,
                   count(*) filter (where ch.status = 'confirmed' and ch.channel = 'whatsapp') as por_whatsapp,
                   max(ch.created_at) as ultima
              from public.charges ch
             where ch.merchant_id = m.id and ch.requested_by = mu.user_id and not ch.is_test
          ) u on true
         where mu.merchant_id = m.id and mu.is_active
      ) p on true
      left join lateral (
        select count(*) as cuantos,
               (array_agg(jsonb_build_object(
                  'created_at', fu.created_at,
                  'channel', fu.channel,
                  'topic', fu.topic,
                  'note', fu.note,
                  'actor_name', coalesce(pa.full_name, aa.email),
                  'contact_name', coalesce(nullif(btrim(ac.raw_user_meta_data ->> 'full_name'), ''), ac.email)
                ) order by fu.created_at desc))[1] as ultimo,
               (array_agg(fu.next_contact_on order by fu.created_at desc))[1] as volver
          from public.merchant_followups fu
          left join public.platform_admins pa on pa.user_id = fu.actor
          left join auth.users aa on aa.id = fu.actor
          left join auth.users ac on ac.id = fu.contact_user_id
         where fu.merchant_id = m.id
      ) f on true
    ) c
  ), '[]'::jsonb);
end;
$$;

comment on function public.admin_followups_board() is
  'Seguimiento: cada clínica con su médico, su teléfono, su personal (número del bot y órdenes de cada uno) y su último contacto con el equipo.';

revoke all on function public.admin_followups_board() from public, anon;
grant execute on function public.admin_followups_board() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. La historia de una clínica
-- ---------------------------------------------------------------------------

create or replace function public.admin_merchant_followups(
  p_merchant_id uuid,
  p_limit       integer default 50
)
returns table (
  id              uuid,
  created_at      timestamptz,
  channel         text,
  topic           text,
  note            text,
  next_contact_on date,
  contact_user_id uuid,
  contact_name    text,
  actor_name      text
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
  select fu.id, fu.created_at, fu.channel, fu.topic, fu.note, fu.next_contact_on,
         fu.contact_user_id,
         coalesce(nullif(btrim(ac.raw_user_meta_data ->> 'full_name'), ''), ac.email)::text,
         coalesce(pa.full_name, aa.email)::text
    from public.merchant_followups fu
    left join public.platform_admins pa on pa.user_id = fu.actor
    left join auth.users aa on aa.id = fu.actor
    left join auth.users ac on ac.id = fu.contact_user_id
   where fu.merchant_id = p_merchant_id
   order by fu.created_at desc
   limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;

comment on function public.admin_merchant_followups(uuid, integer) is
  'Seguimiento: los contactos del equipo con una clínica, del más reciente al más viejo.';

revoke all on function public.admin_merchant_followups(uuid, integer) from public, anon;
grant execute on function public.admin_merchant_followups(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Anotar un contacto
-- ---------------------------------------------------------------------------

create or replace function public.admin_log_merchant_followup(
  p_merchant_id     uuid,
  p_channel         text,
  p_topic           text,
  p_note            text,
  p_contact_user_id uuid default null,
  p_next_contact_on date default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_name  text;
  v_note  text := btrim(coalesce(p_note, ''));
  v_id    uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select name into v_name from public.merchants where id = p_merchant_id;
  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  if p_channel is null or p_channel not in ('llamada', 'whatsapp', 'visita', 'correo') then
    raise exception 'Canal desconocido: %', coalesce(p_channel, '(vacío)') using errcode = '22023';
  end if;
  if p_topic is null or p_topic not in ('seguimiento', 'opinion', 'soporte', 'capacitacion') then
    raise exception 'Motivo desconocido: %', coalesce(p_topic, '(vacío)') using errcode = '22023';
  end if;
  if char_length(v_note) < 3 then
    raise exception 'Escribe qué se habló' using errcode = '22023';
  end if;
  if char_length(v_note) > 2000 then
    raise exception 'La nota no puede pasar de 2000 caracteres' using errcode = '22023';
  end if;

  -- Con quién se habló tiene que ser de esa clínica (aunque ya no esté).
  if p_contact_user_id is not null and not exists (
    select 1 from public.merchant_users
     where merchant_id = p_merchant_id and user_id = p_contact_user_id
  ) then
    raise exception 'Esa persona no es del personal de la clínica' using errcode = '22023';
  end if;

  -- Volver a llamar ayer no es un plan, es una errata.
  if p_next_contact_on is not null and p_next_contact_on < public.helios_business_date(now()) then
    raise exception 'La fecha para volver a llamar ya pasó' using errcode = '22023';
  end if;

  insert into public.merchant_followups
    (merchant_id, contact_user_id, channel, topic, note, next_contact_on, actor)
  values
    (p_merchant_id, p_contact_user_id, p_channel, p_topic, v_note, p_next_contact_on, v_actor)
  returning id into v_id;

  perform audit.log(v_actor, 'merchant.followup', p_merchant_id, jsonb_build_object(
    'followup_id', v_id,
    'merchant_name', v_name,
    'contact_user_id', p_contact_user_id,
    'channel', p_channel,
    'topic', p_topic,
    'next_contact_on', p_next_contact_on,
    'note', v_note
  ));

  return v_id;
end;
$$;

comment on function public.admin_log_merchant_followup(uuid, text, text, text, uuid, date) is
  'Seguimiento: anota un contacto del equipo con una clínica. Cualquiera del equipo; queda en audit.admin_actions.';

revoke all on function public.admin_log_merchant_followup(uuid, text, text, text, uuid, date) from public, anon;
grant execute on function public.admin_log_merchant_followup(uuid, text, text, text, uuid, date) to authenticated;
