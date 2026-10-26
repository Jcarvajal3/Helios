-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — Cuándo usa Helios cada persona del personal (panel y bot)
--
-- Superadmin › Seguimiento enseñaba «Último acceso al panel» con
-- `auth.users.last_sign_in_at`, que solo cambia al INICIAR SESIÓN: quien deja
-- la sesión abierta y entra todos los días seguía «sin entrar» desde el día
-- que puso su contraseña. Y el bot no dejaba rastro por persona.
--
--   1. `staff_activity_days`: un día de uso por persona, clínica y canal
--      (`panel` | `bot`), con la primera y la última vez y cuántas veces.
--   2. `helios_staff_seen_in_panel(p_merchant_id)`: el panel la llama al
--      abrirse, al volver a la pestaña y al navegar (como mucho cada 5 min).
--   3. `helios_whatsapp_inbound` anota `bot` cada mensaje del personal.
--   4. La historia se rellena con lo que ya había: las sesiones y los tokens
--      de Supabase (se renuevan mientras el panel está abierto), los inicios
--      de sesión, las órdenes registradas en el panel y los mensajes del
--      personal al bot.
--   5. `admin_followups_board()` trae por persona `last_panel_at`,
--      `last_bot_at` y `active_days_30d`.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. Los días de uso
-- ---------------------------------------------------------------------------

create table public.staff_activity_days (
  user_id       uuid not null references auth.users (id),
  merchant_id   uuid not null references public.merchants (id),
  channel       text not null check (channel in ('panel', 'bot')),
  business_date date not null,
  first_at      timestamptz not null,
  last_at       timestamptz not null,
  hits          integer not null default 1 check (hits >= 1),
  primary key (user_id, merchant_id, channel, business_date)
);

comment on table public.staff_activity_days is
  'Cada día que una persona del personal usó Helios, por canal: panel (lo abrió o navegó en él) o bot (le escribió). Primera y última vez del día y cuántas veces se anotó.';

-- Se toca solo por las funciones de abajo, que son security definer.
alter table public.staff_activity_days enable row level security;
revoke all on table public.staff_activity_days from public, anon, authenticated;

/** Anota un uso. Interna: la llaman el panel (vía la RPC de abajo) y el bot. */
create or replace function public.helios_note_staff_activity(
  p_user_id     uuid,
  p_merchant_id uuid,
  p_channel     text,
  p_at          timestamptz default now()
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.staff_activity_days
    (user_id, merchant_id, channel, business_date, first_at, last_at)
  values
    (p_user_id, p_merchant_id, p_channel, public.helios_business_date(p_at), p_at, p_at)
  on conflict (user_id, merchant_id, channel, business_date) do update
    set first_at = least(staff_activity_days.first_at, excluded.first_at),
        last_at  = greatest(staff_activity_days.last_at, excluded.last_at),
        hits     = staff_activity_days.hits + 1;
$$;

revoke all on function public.helios_note_staff_activity(uuid, uuid, text, timestamptz)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. El panel
-- ---------------------------------------------------------------------------

-- Solo cuenta a quien es personal activo de esa clínica: un admin de Helios
-- o una cuenta dada de baja no se anotan (y no es un error: el panel no se
-- rompe por no poder anotar).
create or replace function public.helios_staff_seen_in_panel(p_merchant_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or not exists (
    select 1 from public.merchant_users
     where user_id = v_uid and merchant_id = p_merchant_id and is_active
       and role in ('gerente', 'cajero')
  ) then
    return false;
  end if;

  perform public.helios_note_staff_activity(v_uid, p_merchant_id, 'panel');
  return true;
end;
$$;

comment on function public.helios_staff_seen_in_panel(uuid) is
  'El panel de la clínica avisa de que esta persona lo está usando (al abrirlo, al volver a la pestaña, al navegar). false si no es personal activo de esa clínica.';

revoke all on function public.helios_staff_seen_in_panel(uuid) from public, anon;
grant execute on function public.helios_staff_seen_in_panel(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El bot: cada mensaje del personal es un uso
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.helios_whatsapp_inbound(p_message_id text, p_from text, p_type text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_phone   text := public.helios_wa_e164(p_from);
  v_staff   public.staff_whatsapp_numbers%rowtype;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_pend    uuid[];
  v_profile uuid;
begin
  if nullif(btrim(coalesce(p_message_id, '')), '') is null or v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'peticion_invalida');
  end if;

  select n.* into v_staff
  from public.staff_whatsapp_numbers n
  join public.merchant_users mu
    on mu.user_id = n.user_id and mu.merchant_id = n.merchant_id and mu.is_active
   and mu.role in ('gerente', 'cajero')
  where n.phone_e164 = v_phone and n.revoked_at is null
  limit 1;

  insert into public.whatsapp_inbound (wa_message_id, from_phone, type, payload)
  values (p_message_id, v_phone, p_type, v_payload)
  on conflict (wa_message_id) do nothing;

  if not found then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;

  -- El personal usó el bot. Anotarlo nunca tumba el mensaje.
  if v_staff.id is not null then
    begin
      perform public.helios_note_staff_activity(v_staff.user_id, v_staff.merchant_id, 'bot');
    exception when others then
      raise warning 'helios_whatsapp_inbound: no se pudo anotar el uso del bot: %', sqlerrm;
    end;
  end if;

  select array_agg(c.id order by c.created_at), min(p.id::text)::uuid
    into v_pend, v_profile
  from public.charges c
  join public.profiles p on p.id = c.user_id
  where c.status = 'pending' and c.expires_at > now()
    and regexp_replace(coalesce(p.phone_e164, ''), '\D', '', 'g') = regexp_replace(v_phone, '\D', '', 'g');

  if v_profile is null then
    select p.id into v_profile from public.profiles p
    where p.phone_e164 = v_phone order by p.created_at desc limit 1;
  end if;

  insert into public.whatsapp_contacts (phone_e164, last_inbound_at, profile_id, staff_user_id, updated_at)
  values (v_phone, now(), v_profile, v_staff.user_id, now())
  on conflict (phone_e164) do update
    set last_inbound_at = now(),
        profile_id = coalesce(excluded.profile_id, whatsapp_contacts.profile_id),
        staff_user_id = excluded.staff_user_id,
        updated_at = now();

  return jsonb_build_object(
    'ok', true,
    'duplicate', false,
    'phone_e164', v_phone,
    'staff', case when v_staff.id is not null then public.helios_staff_whatsapp_row(v_staff) end,
    'pending_charge_id', case when cardinality(v_pend) = 1 then v_pend[1] end
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 4. La historia
-- ---------------------------------------------------------------------------

-- El panel: cada sesión de Supabase y cada token renovado (el panel los
-- renueva mientras está abierto), los inicios de sesión y las órdenes
-- registradas desde el panel. Se le atribuye a la clínica de la que la
-- persona ya era personal en ese momento.
with eventos (user_id, at) as (
  select s.user_id, s.created_at from auth.sessions s
  union all
  select s.user_id, s.updated_at from auth.sessions s where s.updated_at is not null
  union all
  select s.user_id, s.refreshed_at at time zone 'UTC' from auth.sessions s where s.refreshed_at is not null
  union all
  select r.user_id::uuid, r.created_at from auth.refresh_tokens r
   where r.user_id ~ '^[0-9a-f-]{36}$' and r.created_at is not null
  union all
  select r.user_id::uuid, r.updated_at from auth.refresh_tokens r
   where r.user_id ~ '^[0-9a-f-]{36}$' and r.updated_at is not null
  union all
  select u.id, u.last_sign_in_at from auth.users u where u.last_sign_in_at is not null
  union all
  select ch.requested_by, ch.created_at from public.charges ch
   where ch.channel = 'panel' and ch.requested_by is not null
),
del_personal as (
  select mu.user_id, mu.merchant_id, e.at
    from eventos e
    join public.merchant_users mu
      on mu.user_id = e.user_id and mu.role in ('gerente', 'cajero')
     -- La cuenta y su primera sesión nacen casi a la vez.
     and e.at >= mu.created_at - interval '5 minutes'
)
insert into public.staff_activity_days
  (user_id, merchant_id, channel, business_date, first_at, last_at, hits)
select user_id, merchant_id, 'panel', public.helios_business_date(at), min(at), max(at), count(*)
  from del_personal
 group by user_id, merchant_id, public.helios_business_date(at)
on conflict (user_id, merchant_id, channel, business_date) do update
  set first_at = least(staff_activity_days.first_at, excluded.first_at),
      last_at  = greatest(staff_activity_days.last_at, excluded.last_at),
      hits     = staff_activity_days.hits + excluded.hits;

-- El bot: cada mensaje que llegó desde el número del personal mientras ese
-- número era suyo.
insert into public.staff_activity_days
  (user_id, merchant_id, channel, business_date, first_at, last_at, hits)
select n.user_id, n.merchant_id, 'bot', public.helios_business_date(wi.received_at),
       min(wi.received_at), max(wi.received_at), count(*)
  from public.whatsapp_inbound wi
  join public.staff_whatsapp_numbers n
    on n.phone_e164 = wi.from_phone
   and wi.received_at >= n.created_at
   and (n.revoked_at is null or wi.received_at < n.revoked_at)
  join public.merchant_users mu
    on mu.user_id = n.user_id and mu.merchant_id = n.merchant_id and mu.role in ('gerente', 'cajero')
 group by n.user_id, n.merchant_id, public.helios_business_date(wi.received_at)
on conflict (user_id, merchant_id, channel, business_date) do update
  set first_at = least(staff_activity_days.first_at, excluded.first_at),
      last_at  = greatest(staff_activity_days.last_at, excluded.last_at),
      hits     = staff_activity_days.hits + excluded.hits;

-- ---------------------------------------------------------------------------
-- 5. El tablero, con el uso de cada persona
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
                 -- El uso de verdad: cuándo abrió el panel o le escribió al
                 -- bot por última vez, y cuántos días lo usó en 30.
                 'last_panel_at', a.panel,
                 'last_bot_at', a.bot,
                 'active_days_30d', coalesce(a.dias_30, 0),
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
            select max(d.last_at) filter (where d.channel = 'panel') as panel,
                   max(d.last_at) filter (where d.channel = 'bot') as bot,
                   count(distinct d.business_date) filter (where d.business_date >= v_desde) as dias_30
              from public.staff_activity_days d
             where d.user_id = mu.user_id and d.merchant_id = m.id
          ) a on true
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
  'Seguimiento: cada clínica con su médico, su teléfono, su personal (número del bot, órdenes y uso del panel y del bot de cada uno) y su último contacto con el equipo.';
