-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — La agenda por fases: Mensaje › Llamada › Visita
--
-- Javier, 2026-10-28: la Agenda se trabaja en tres fases, y cada persona
-- trabaja los médicos que tiene asignados.
--
--   Mensaje: por contactar, mensaje enviado, no contestó, no interesado. De
--            aquí sale el «Interesado».
--   Llamada: por llamar (el interesado), no contestó, no interesado. De aquí
--            sale la visita agendada.
--   Visita:  visita agendada, y después «Visita realizada · Afiliado»: en la
--            visita se le capacita, así que se da por afiliado.
--
-- 1. `doctor_leads.stage` (`mensaje | llamada | visita`): la fase. La pone un
--    disparador a partir del estado, así que la mantienen solos todos los que
--    lo cambian (la ficha, el formulario de afiliación, el QR, los accesos):
--      nuevo, contactado → mensaje      respondio → llamada
--      reunion, convertido → visita
--      no_respondio, descartado → la fase en que estaba (no contestó o no
--      le interesó en esa fase).
--    Los que ya hay se rellenan: un «no contestó» o «no interesado» que ya
--    había sido interesado o tuvo una llamada queda en Llamada.
-- 2. «Visita realizada» y «Afiliado» son lo mismo: `visita_realizada` deja
--    el lead `convertido` (`converted_via = 'visita'`). El estado `visitado`
--    desaparece (los que hubiera pasan a afiliado).
-- 3. `admin_doctor_leads()` devuelve `stage`.
-- 4. `admin_assign_me_doctor_leads(p_cantidad)`: le asigna a quien llama
--    hasta `p_cantidad` (20 por defecto) médicos al azar que no tengan a
--    nadie y sigan abiertos (ni afiliados ni «no interesado»). Dos personas a
--    la vez no se llevan el mismo (`skip locked`). Queda en la bitácora
--    (`doctor_lead.assigned`).
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. La fase
-- ---------------------------------------------------------------------------

alter table public.doctor_leads
  add column stage text not null default 'mensaje' check (stage in ('mensaje', 'llamada', 'visita'));

comment on column public.doctor_leads.stage is
  'Agenda: la fase (mensaje, llamada o visita). La pone helios_lead_fase() a partir del estado.';

-- 2. Visita realizada es afiliado: los `visitado` que hubiera pasan a afiliado.
alter table public.doctor_leads drop constraint doctor_leads_converted_via_check;
alter table public.doctor_leads add constraint doctor_leads_converted_via_check check (converted_via in
  ('formulario', 'alta', 'agenda', 'manual', 'visita'));

update public.doctor_leads
   set status        = 'convertido',
       converted_via = coalesce(converted_via, 'visita'),
       converted_at  = coalesce(converted_at, updated_at),
       next_contact_on = null
 where status = 'visitado';

alter table public.doctor_leads drop constraint doctor_leads_status_check;
alter table public.doctor_leads add constraint doctor_leads_status_check check (status in
  ('nuevo', 'contactado', 'respondio', 'no_respondio', 'reunion', 'convertido', 'descartado'));

-- La fase de los que ya están.
update public.doctor_leads l
   set stage = case
     when l.status in ('reunion', 'convertido') then 'visita'
     when l.status = 'respondio' then 'llamada'
     when l.status in ('no_respondio', 'descartado') and exists (
       select 1 from public.doctor_lead_activities a
        where a.lead_id = l.id
          and (a.status_from = 'respondio' or a.status_to = 'respondio'
               or a.channel = 'llamada' or a.result = 'interesado')
     ) then 'llamada'
     else 'mensaje'
   end;

create index doctor_leads_stage_idx on public.doctor_leads (stage, status);
create index doctor_leads_assigned_idx on public.doctor_leads (assigned_to);

/** La fase sale del estado; «no contestó» y «no interesado» se quedan en la suya. */
create or replace function public.helios_lead_fase()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    new.stage := case
      when new.status in ('nuevo', 'contactado') then 'mensaje'
      when new.status = 'respondio' then 'llamada'
      when new.status in ('reunion', 'convertido') then 'visita'
      when tg_op = 'UPDATE' then old.stage
      else coalesce(new.stage, 'mensaje')
    end;
  end if;
  return new;
end;
$$;

revoke all on function public.helios_lead_fase() from public, anon, authenticated;

create trigger doctor_leads_fase
  before insert or update of status on public.doctor_leads
  for each row execute function public.helios_lead_fase();

-- ---------------------------------------------------------------------------
-- 4. Asignarme médicos
-- ---------------------------------------------------------------------------

create or replace function public.admin_assign_me_doctor_leads(p_cantidad integer default 20)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_ids   uuid[];
begin
  if not public.helios_puede_usar_la_agenda() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;
  if p_cantidad is null or p_cantidad < 1 or p_cantidad > 100 then
    raise exception 'Pide entre 1 y 100 médicos.' using errcode = '22023';
  end if;

  with elegidos as (
    select id
      from public.doctor_leads
     where assigned_to is null
       and status not in ('convertido', 'descartado')
     order by random()
     limit p_cantidad
     for update skip locked
  ), asignados as (
    update public.doctor_leads l
       set assigned_to = v_actor, updated_at = now()
      from elegidos e
     where l.id = e.id
    returning l.id
  )
  select array_agg(id) into v_ids from asignados;

  if v_ids is not null then
    perform audit.log(v_actor, 'doctor_lead.assigned', v_actor, jsonb_build_object(
      'count', array_length(v_ids, 1),
      'lead_ids', to_jsonb(v_ids)
    ));
  end if;

  return coalesce(array_length(v_ids, 1), 0);
end;
$$;

comment on function public.admin_assign_me_doctor_leads(integer) is
  'Agenda: le asigna a quien llama hasta p_cantidad médicos al azar, sin asignar y abiertos. Devuelve cuántos.';

revoke all on function public.admin_assign_me_doctor_leads(integer) from public, anon;
grant execute on function public.admin_assign_me_doctor_leads(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2 y 3. Anotar una gestión (visita realizada = afiliado) y el tablero (fase)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_log_doctor_lead_contact(p_lead_id uuid, p_result text, p_channel text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_meeting_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_meeting_mode text DEFAULT NULL::text, p_meeting_place text DEFAULT NULL::text, p_next_contact_on date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  if not public.helios_puede_usar_la_agenda() then
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
    when 'visita_realizada' then 'convertido'
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
    converted_via   = case when v_status = 'convertido' then coalesce(converted_via,
                        case when p_result = 'visita_realizada' then 'visita' else 'manual' end) end,
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
$function$;

CREATE OR REPLACE FUNCTION public.admin_doctor_leads()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.helios_puede_usar_la_agenda() then
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
             'stage', l.stage,
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
             'application_training_at', coalesce(l.training_at, ma.training_at),
             'merchant_id', l.merchant_id,
             'merchant_name', m.name,
             'merchant_has_access', l.merchant_id is not null and public.helios_clinica_tiene_accesos(l.merchant_id),
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
$function$;
