-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — La gestión de la agenda sigue el árbol del equipo
--
-- El equipo anota cada gestión así:
--
--   Mensaje  → mensaje enviado · contestó (interesado / no interesado) · no contestó
--   Llamada  → contestó (interesado / no interesado) · no contestó · teléfono ocupado
--   Visita   → agendada con su fecha, y después: realizada · pospuesta (otra fecha) · cancelada
--
-- 1. Cada gestión guarda su resultado (`doctor_lead_activities.result`) y el
--    canal «mensaje» se suma a los que había.
-- 2. El lead gana el estado `visitado` (visita realizada).
-- 3. `admin_log_doctor_lead_contact` recibe el resultado en vez del estado, y
--    el estado sale de él:
--      mensaje_enviado → contactado        interesado      → respondio
--      no_contesto     → no_respondio      no_interesado   → descartado
--      ocupado         → no_respondio      visita_agendada → reunion
--      visita_pospuesta → reunion          visita_realizada → visitado
--      visita_cancelada → respondio        afiliado        → convertido
--      nota            → el que tenía
-- 4. El tablero y la historia devuelven el resultado.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1 y 2. Los catálogos
-- ---------------------------------------------------------------------------

alter table public.doctor_leads drop constraint doctor_leads_status_check;
alter table public.doctor_leads add constraint doctor_leads_status_check check (status in
  ('nuevo', 'contactado', 'respondio', 'no_respondio', 'reunion', 'visitado', 'convertido', 'descartado'));

alter table public.doctor_lead_activities drop constraint doctor_lead_activities_channel_check;
alter table public.doctor_lead_activities add constraint doctor_lead_activities_channel_check check (channel in
  ('mensaje', 'llamada', 'whatsapp', 'visita', 'correo', 'redes'));

alter table public.doctor_lead_activities
  add column result text check (result in (
    'mensaje_enviado', 'interesado', 'no_interesado', 'no_contesto', 'ocupado',
    'visita_agendada', 'visita_realizada', 'visita_pospuesta', 'visita_cancelada',
    'afiliado', 'nota'));

comment on column public.doctor_lead_activities.result is
  'Qué pasó en la gestión (el árbol del equipo). Null en las líneas de antes del 2026-10-22 y en las del sistema.';

-- ---------------------------------------------------------------------------
-- 3. Anotar una gestión
-- ---------------------------------------------------------------------------

drop function public.admin_log_doctor_lead_contact(uuid, text, text, text, timestamptz, text, text, date);

/**
 * Anota una gestión con su resultado. El estado del lead sale del resultado
 * (ver la cabecera).
 *
 * - `visita_agendada` y `visita_pospuesta` piden la fecha y la hora nuevas.
 * - `visita_realizada`, `visita_pospuesta` y `visita_cancelada` piden que
 *   tenga una visita agendada.
 * - Pasar a un estado de antes de la visita mientras hay una por venir la
 *   anula (lo dice la nota); `visita_cancelada` la quita siempre.
 * - `nota` pide la nota.
 * - `p_next_contact_on` es cuándo volver a llamar; manda la de la última
 *   gestión, y se borra al afiliar o al quedar «no interesado».
 */
create or replace function public.admin_log_doctor_lead_contact(
  p_lead_id         uuid,
  p_result          text,
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
  v_status  text;
  v_reunion timestamptz;
  v_modo    text;
  v_sitio   text;
  v_de_la_linea timestamptz;
  v_id      uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_lead from public.doctor_leads where id = p_lead_id for update;
  if not found then
    raise exception 'Ese médico ya no está en la agenda.' using errcode = 'P0002';
  end if;

  v_status := case p_result
    when 'mensaje_enviado'  then 'contactado'
    when 'interesado'       then 'respondio'
    when 'no_interesado'    then 'descartado'
    when 'no_contesto'      then 'no_respondio'
    when 'ocupado'          then 'no_respondio'
    when 'visita_agendada'  then 'reunion'
    when 'visita_pospuesta' then 'reunion'
    when 'visita_realizada' then 'visitado'
    when 'visita_cancelada' then 'respondio'
    when 'afiliado'         then 'convertido'
    when 'nota'             then v_lead.status
  end;
  if v_status is null then
    raise exception 'Resultado desconocido: %', coalesce(p_result, '(vacío)') using errcode = '22023';
  end if;

  if p_channel is not null and p_channel not in ('mensaje', 'llamada', 'whatsapp', 'visita', 'correo', 'redes') then
    raise exception 'Canal desconocido: %', p_channel using errcode = '22023';
  end if;
  if v_note is not null and char_length(v_note) > 2000 then
    raise exception 'La nota no puede pasar de 2000 caracteres.' using errcode = '22023';
  end if;
  if p_result = 'nota' and v_note is null then
    raise exception 'Escribe la nota.' using errcode = '22023';
  end if;
  if p_meeting_mode is not null and p_meeting_mode not in ('presencial', 'videollamada', 'llamada') then
    raise exception 'Tipo de visita desconocido: %', p_meeting_mode using errcode = '22023';
  end if;
  if v_lugar is not null and char_length(v_lugar) > 300 then
    raise exception 'El lugar de la visita es demasiado largo.' using errcode = '22023';
  end if;
  if p_next_contact_on is not null and p_next_contact_on < v_hoy then
    raise exception 'La fecha para volver a llamar ya pasó.' using errcode = '22023';
  end if;

  if p_result in ('visita_realizada', 'visita_pospuesta', 'visita_cancelada')
     and (v_lead.status <> 'reunion' or v_lead.meeting_at is null) then
    raise exception 'No tiene una visita agendada.' using errcode = '22023';
  end if;
  if p_result in ('visita_agendada', 'visita_pospuesta') then
    if p_meeting_at is null then
      raise exception 'Pon la fecha y la hora de la visita.' using errcode = '22023';
    end if;
    if (p_meeting_at at time zone 'America/Caracas')::date < v_hoy then
      raise exception 'La fecha de la visita ya pasó.' using errcode = '22023';
    end if;
    if p_result = 'visita_pospuesta' and p_meeting_at = v_lead.meeting_at then
      raise exception 'Pon la nueva fecha de la visita.' using errcode = '22023';
    end if;
  elsif p_meeting_at is not null then
    raise exception 'Solo se pone fecha al agendar o posponer una visita.' using errcode = '22023';
  end if;

  v_reunion := v_lead.meeting_at;
  v_modo := v_lead.meeting_mode;
  v_sitio := v_lead.meeting_place;
  v_de_la_linea := null;

  if p_result = 'visita_agendada' then
    v_reunion := p_meeting_at;
    v_modo := coalesce(p_meeting_mode, 'presencial');
    v_sitio := v_lugar;
    v_de_la_linea := p_meeting_at;
  elsif p_result = 'visita_pospuesta' then
    v_reunion := p_meeting_at;
    v_modo := coalesce(p_meeting_mode, v_modo, 'presencial');
    v_sitio := coalesce(v_lugar, v_sitio);
    v_de_la_linea := p_meeting_at;
    v_note := coalesce(v_note || ' ', '') || '(Antes era el '
      || to_char(v_lead.meeting_at at time zone 'America/Caracas', 'DD/MM/YYYY HH24:MI') || '.)';
  elsif p_result = 'visita_realizada' then
    v_de_la_linea := v_lead.meeting_at;
  elsif p_result = 'visita_cancelada' then
    v_de_la_linea := v_lead.meeting_at;
    v_reunion := null;
    v_modo := null;
    v_sitio := null;
  elsif v_lead.status = 'reunion' and v_lead.meeting_at > now()
        and v_status in ('nuevo', 'contactado', 'respondio', 'no_respondio', 'descartado') then
    -- Se vuelve a antes de la visita sin haberla hecho: se anula.
    v_reunion := null;
    v_modo := null;
    v_sitio := null;
    v_note := coalesce(v_note || ' ', '') || '(Se anuló la visita del '
      || to_char(v_lead.meeting_at at time zone 'America/Caracas', 'DD/MM/YYYY HH24:MI') || '.)';
  end if;

  update public.doctor_leads set
    status          = v_status,
    meeting_at      = v_reunion,
    meeting_mode    = v_modo,
    meeting_place   = v_sitio,
    next_contact_on = case when v_status in ('convertido', 'descartado') then null else p_next_contact_on end,
    converted_at    = case when v_status = 'convertido' then coalesce(converted_at, now()) end,
    converted_via   = case when v_status = 'convertido' then coalesce(converted_via, 'manual') end,
    match_reason    = case when v_status = 'convertido' then match_reason end,
    updated_at      = now()
  where id = p_lead_id;

  insert into public.doctor_lead_activities
    (lead_id, kind, result, channel, status_from, status_to, meeting_at, note, actor)
  values
    (p_lead_id, 'gestion', p_result, p_channel, v_lead.status, v_status, v_de_la_linea, v_note, v_actor)
  returning id into v_id;

  perform audit.log(v_actor, 'doctor_lead.contact', p_lead_id, jsonb_build_object(
    'activity_id', v_id,
    'lead_name', v_lead.name,
    'result', p_result,
    'status_from', v_lead.status,
    'status_to', v_status,
    'channel', p_channel,
    'meeting_at', v_de_la_linea,
    'next_contact_on', p_next_contact_on,
    'note', v_note
  ));

  return v_id;
end;
$$;

comment on function public.admin_log_doctor_lead_contact(uuid, text, text, text, timestamptz, text, text, date) is
  'Agenda: anota una gestión con su resultado (mensaje, llamada o visita); el estado del lead sale del resultado. Queda en audit.admin_actions.';

revoke all on function public.admin_log_doctor_lead_contact(uuid, text, text, text, timestamptz, text, text, date) from public, anon;
grant execute on function public.admin_log_doctor_lead_contact(uuid, text, text, text, timestamptz, text, text, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. El tablero y la historia, con el resultado
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
                  'result', ac.result,
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

drop function public.admin_doctor_lead_activities(uuid);

create function public.admin_doctor_lead_activities(p_lead_id uuid)
returns table (
  id          uuid,
  created_at  timestamptz,
  kind        text,
  result      text,
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
  select ac.id, ac.created_at, ac.kind, ac.result, ac.channel, ac.status_from, ac.status_to, ac.meeting_at, ac.note,
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
  'Agenda: la historia de un médico por afiliar, con el resultado de cada gestión, de lo más reciente a lo más viejo.';

revoke all on function public.admin_doctor_lead_activities(uuid) from public, anon;
grant execute on function public.admin_doctor_lead_activities(uuid) to authenticated;
