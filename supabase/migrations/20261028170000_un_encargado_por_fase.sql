-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — Un encargado por fase, con reparto automático
--
-- Javier, 2026-10-28: un médico lo trabajan varias personas, una por fase
-- (Lis y Alejandro escriben, Juan Vicente llama, Carlos visita), aunque no
-- es excluyente.
--
-- 1. `agenda_phase_members`: quién trabaja cada fase. Una persona puede estar
--    en varias. Lo cambia un super admin (`admin_set_agenda_phases`).
-- 2. `doctor_leads` guarda un encargado por fase: `message_owner`,
--    `call_owner` y `visit_owner`. `assigned_to` sigue siendo el encargado de
--    la fase en que está (lo que el panel llama «Gestionado por» y lo que
--    filtra «Mis médicos»), y su columna de fase se mantiene igual a él.
-- 3. El reparto: al entrar en una fase, el médico vuelve a quien ya la llevó
--    o, si nadie, pasa a alguien del equipo de esa fase, el que menos médicos
--    abiertos lleva en ella (a igualdad, al azar). Mensaje no reparte: sus
--    médicos se toman con «Asignarme». Sin equipo en esa fase, sigue con quien
--    lo llevaba. Los afiliados y los «no interesado» no se reparten. Lo hace
--    `helios_lead_fase()`, el mismo disparador que pone la fase.
-- 4. «Asignarme médicos» toma solo de las fases en que trabaja quien lo pide
--    (de todas, si no está en ninguna).
-- 5. `admin_agenda_team()` dice las fases de cada persona;
--    `admin_agenda_activity_by_person()` cuenta lo que hizo cada una (por
--    quien anotó cada gestión, no por quién lleva hoy al médico); y
--    `admin_doctor_leads()` devuelve los tres encargados.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. Quién trabaja cada fase
-- ---------------------------------------------------------------------------

create table public.agenda_phase_members (
  user_id    uuid not null references auth.users (id) on delete cascade,
  stage      text not null check (stage in ('mensaje', 'llamada', 'visita')),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  primary key (user_id, stage)
);

comment on table public.agenda_phase_members is
  'Agenda: quién trabaja cada fase (mensaje, llamada, visita). Una persona puede estar en varias. Decide el reparto automático.';

alter table public.agenda_phase_members enable row level security;
revoke all on table public.agenda_phase_members from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Un encargado por fase
-- ---------------------------------------------------------------------------

alter table public.doctor_leads
  add column message_owner uuid references auth.users (id),
  add column call_owner    uuid references auth.users (id),
  add column visit_owner   uuid references auth.users (id);

comment on column public.doctor_leads.message_owner is 'Agenda: quién lo llevó (o lleva) en Mensaje.';
comment on column public.doctor_leads.call_owner    is 'Agenda: quién lo llevó (o lleva) en Llamada.';
comment on column public.doctor_leads.visit_owner   is 'Agenda: quién lo llevó (o lleva) en Visita.';

-- Los que ya están: quien lo lleva es el encargado de su fase actual.
update public.doctor_leads set
  message_owner = case when stage = 'mensaje' then assigned_to end,
  call_owner    = case when stage = 'llamada' then assigned_to end,
  visit_owner   = case when stage = 'visita'  then assigned_to end
where assigned_to is not null;

/** El nombre de alguien del equipo: el de la tabla del equipo o, si no, su correo. */
create or replace function public.helios_nombre_del_equipo(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(nullif(btrim(pa.full_name), ''), u.email)::text
    from auth.users u
    left join public.platform_admins pa on pa.user_id = u.id
   where u.id = p_user_id;
$$;

revoke all on function public.helios_nombre_del_equipo(uuid) from public, anon, authenticated;

/**
 * A quién le toca un médico que entra en esa fase: alguien activo del equipo
 * de la fase, el que menos médicos abiertos lleva en ella; a igualdad, al
 * azar. Null si la fase no tiene equipo.
 */
create or replace function public.helios_encargado_para(p_stage text)
returns uuid
language sql
volatile
security definer
set search_path = public, pg_temp
as $$
  select m.user_id
    from public.agenda_phase_members m
    join public.platform_admins pa on pa.user_id = m.user_id and pa.is_active
   where m.stage = p_stage
   order by (
     select count(*) from public.doctor_leads l
      where l.assigned_to = m.user_id and l.stage = p_stage
        and l.status not in ('convertido', 'descartado')
   ), random()
   limit 1;
$$;

revoke all on function public.helios_encargado_para(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. La fase y el reparto, en el mismo disparador
-- ---------------------------------------------------------------------------

/**
 * La fase sale del estado («no contestó» y «no interesado» se quedan en la
 * suya). Al entrar en una fase, el encargado es quien ya la llevó o, si
 * nadie, alguien del equipo de esa fase (`helios_encargado_para`); en Mensaje
 * no se reparte. Y el encargado de la fase actual queda en su columna.
 */
create or replace function public.helios_lead_fase()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_previo uuid;
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

  if (tg_op = 'INSERT' or new.stage is distinct from old.stage)
     and new.status not in ('convertido', 'descartado') then
    v_previo := case new.stage
      when 'mensaje' then new.message_owner
      when 'llamada' then new.call_owner
      else new.visit_owner
    end;
    if v_previo is not null then
      new.assigned_to := v_previo;
    elsif new.stage <> 'mensaje' then
      new.assigned_to := coalesce(public.helios_encargado_para(new.stage), new.assigned_to);
    end if;
  end if;

  if new.assigned_to is not null then
    case new.stage
      when 'mensaje' then new.message_owner := new.assigned_to;
      when 'llamada' then new.call_owner := new.assigned_to;
      else new.visit_owner := new.assigned_to;
    end case;
  end if;

  return new;
end;
$$;

revoke all on function public.helios_lead_fase() from public, anon, authenticated;

-- Ahora también al cambiar el encargado a mano, para que su columna lo siga.
drop trigger doctor_leads_fase on public.doctor_leads;
create trigger doctor_leads_fase
  before insert or update of status, assigned_to on public.doctor_leads
  for each row execute function public.helios_lead_fase();

-- ---------------------------------------------------------------------------
-- 4. «Asignarme médicos», de mis fases
-- ---------------------------------------------------------------------------

create or replace function public.admin_assign_me_doctor_leads(p_cantidad integer default 20)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_fases text[];
  v_ids   uuid[];
begin
  if not public.helios_puede_usar_la_agenda() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;
  if p_cantidad is null or p_cantidad < 1 or p_cantidad > 100 then
    raise exception 'Pide entre 1 y 100 médicos.' using errcode = '22023';
  end if;

  -- Las fases en que trabaja; sin ninguna, de todas.
  select coalesce(array_agg(stage), '{}') into v_fases
    from public.agenda_phase_members where user_id = v_actor;

  with elegidos as (
    select id
      from public.doctor_leads
     where assigned_to is null
       and status not in ('convertido', 'descartado')
       and (cardinality(v_fases) = 0 or stage = any (v_fases))
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
      'stages', to_jsonb(v_fases),
      'lead_ids', to_jsonb(v_ids)
    ));
  end if;

  return coalesce(array_length(v_ids, 1), 0);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. El equipo, sus fases y lo que hizo cada uno
-- ---------------------------------------------------------------------------

drop function public.admin_agenda_team();

create function public.admin_agenda_team()
returns table (user_id uuid, name text, role text, stages text[])
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.helios_puede_usar_la_agenda() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  select pa.user_id, coalesce(nullif(btrim(pa.full_name), ''), au.email)::text, pa.role::text,
         coalesce((
           select array_agg(m.stage order by array_position(array['mensaje', 'llamada', 'visita'], m.stage))
             from public.agenda_phase_members m where m.user_id = pa.user_id
         ), '{}')
    from public.platform_admins pa
    join auth.users au on au.id = pa.user_id
   where pa.is_active
   order by 2;
end;
$$;

comment on function public.admin_agenda_team() is
  'Agenda: el equipo activo (nombre, rol y las fases en que trabaja), para elegir encargados y repartir.';

revoke all on function public.admin_agenda_team() from public, anon;
grant execute on function public.admin_agenda_team() to authenticated;

/** Cambia las fases en que trabaja alguien del equipo (super admin). */
create or replace function public.admin_set_agenda_phases(p_user_id uuid, p_stages text[])
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('cambiar el equipo de cada fase');
  v_fases  text[] := coalesce(p_stages, '{}');
begin
  if not exists (select 1 from public.platform_admins where user_id = p_user_id and is_active) then
    raise exception 'Esa persona no es del equipo.' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(v_fases) s where s not in ('mensaje', 'llamada', 'visita')) then
    raise exception 'Fase desconocida.' using errcode = '22023';
  end if;

  delete from public.agenda_phase_members where user_id = p_user_id and not (stage = any (v_fases));
  insert into public.agenda_phase_members (user_id, stage, created_by)
  select p_user_id, s, v_actor from unnest(v_fases) s
  on conflict do nothing;

  perform audit.log(v_actor, 'agenda.phase_members', p_user_id, jsonb_build_object(
    'name', public.helios_nombre_del_equipo(p_user_id),
    'stages', to_jsonb(v_fases)
  ));
end;
$$;

comment on function public.admin_set_agenda_phases(uuid, text[]) is
  'Agenda: las fases en que trabaja alguien del equipo. Super admin; queda en audit.admin_actions.';

revoke all on function public.admin_set_agenda_phases(uuid, text[]) from public, anon;
grant execute on function public.admin_set_agenda_phases(uuid, text[]) to authenticated;

/**
 * Lo que hizo cada persona, por quien anotó cada gestión: mensajes (las
 * gestiones de Mensaje), interesados que consiguió, llamadas, visitas que
 * agendó y visitas realizadas (cada una, un afiliado). Desde `p_desde` (día
 * de Caracas) o de siempre.
 */
create or replace function public.admin_agenda_activity_by_person(p_desde date default null)
returns table (
  user_id            uuid,
  name               text,
  gestiones          integer,
  mensajes           integer,
  interesados        integer,
  llamadas           integer,
  visitas_agendadas  integer,
  visitas_realizadas integer,
  ultima             timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.helios_puede_usar_la_agenda() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  select a.actor,
         public.helios_nombre_del_equipo(a.actor),
         count(*)::integer,
         count(*) filter (where a.channel = 'mensaje')::integer,
         count(*) filter (where a.result = 'interesado')::integer,
         count(*) filter (where a.channel = 'llamada')::integer,
         count(*) filter (where a.result = 'visita_agendada')::integer,
         count(*) filter (where a.result = 'visita_realizada')::integer,
         max(a.created_at)
    from public.doctor_lead_activities a
   where a.kind = 'gestion'
     and a.actor is not null
     and (p_desde is null or (a.created_at at time zone 'America/Caracas')::date >= p_desde)
   group by a.actor
   order by 8 desc, 3 desc, 2;
end;
$$;

comment on function public.admin_agenda_activity_by_person(date) is
  'Agenda: lo que hizo cada persona (mensajes, interesados, llamadas, visitas agendadas y realizadas), por quien anotó cada gestión.';

revoke all on function public.admin_agenda_activity_by_person(date) from public, anon;
grant execute on function public.admin_agenda_activity_by_person(date) to authenticated;

-- ---------------------------------------------------------------------------
-- El tablero, con los tres encargados
-- ---------------------------------------------------------------------------

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
             'owners', jsonb_build_object(
               'mensaje', l.message_owner, 'llamada', l.call_owner, 'visita', l.visit_owner),
             'owner_names', jsonb_build_object(
               'mensaje', public.helios_nombre_del_equipo(l.message_owner),
               'llamada', public.helios_nombre_del_equipo(l.call_owner),
               'visita', public.helios_nombre_del_equipo(l.visit_owner)),
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
