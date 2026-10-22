-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — Lo que puede hacer el rol de la agenda
--
-- El rol `agenda` (20261022220000) solo entra a superadmin › Agenda.
--
-- 1. `is_platform_admin()` deja fuera al rol `agenda`. Es la guardia de
--    todas las RPC del superadmin y de las RLS, así que con este cambio el
--    rol nuevo no lee ni escribe nada más: ni pacientes, ni pagos, ni
--    clínicas, ni la bitácora. Lo que no se nombra, no se puede.
-- 2. `helios_puede_usar_la_agenda()`: la misma comprobación (cuenta activa y,
--    si se exige, segundo factor) para los tres roles. La usan solo las RPC
--    de la agenda.
-- 3. Las RPC de la agenda pasan a `helios_puede_usar_la_agenda()`. Sus
--    cuerpos no cambian (salen tal cual de la base, con esa sola
--    sustitución).
-- 4. `admin_agenda_team()`: el equipo activo, para elegir quién gestiona a
--    cada médico; `admin_platform_team()` (con la actividad de cada uno) sigue
--    siendo solo del superadmin.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1 y 2. Quién es del equipo
-- ---------------------------------------------------------------------------

/**
 * Si quien llama es del equipo de Helios con una sesión que vale: una cuenta
 * activa con uno de esos roles y, si el panel exige el segundo factor, una
 * sesión `aal2`. La comparten `is_platform_admin()` y
 * `helios_puede_usar_la_agenda()`, para que el segundo factor se compruebe
 * igual en las dos.
 */
create or replace function public.helios_es_del_equipo(p_roles public.platform_role[])
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_req  boolean;
  v_aal  text;
begin
  if v_user is null then
    return false;
  end if;

  if not exists (
    select 1 from public.platform_admins
    where user_id = v_user and is_active and role = any (p_roles)
  ) then
    return false;
  end if;

  select require_mfa into v_req from public.platform_security where id;

  if not coalesce(v_req, false) then
    return true;
  end if;

  -- El nivel de la sesión, tal y como lo pone Supabase en el token. `aal2`
  -- quiere decir que pasó por el segundo factor en ESTA sesión: una abierta
  -- antes de activarlo sigue siendo `aal1`, y tiene que dejar de valer.
  v_aal := coalesce(
    current_setting('request.jwt.claims', true)::jsonb ->> 'aal',
    'aal1'
  );

  return v_aal = 'aal2';
exception when others then
  -- Un token sin `claims` legibles —una llamada desde el propio servidor, por
  -- ejemplo— no puede dar acceso por accidente cuando la exigencia está
  -- encendida.
  return false;
end;
$$;

revoke all on function public.helios_es_del_equipo(public.platform_role[]) from public, anon, authenticated;

/** El superadmin: super admins y operadores. El rol de la agenda, no. */
create or replace function public.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.helios_es_del_equipo(array['super_admin', 'operador']::public.platform_role[]);
$$;

/** La agenda: los tres roles. */
create or replace function public.helios_puede_usar_la_agenda()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.helios_es_del_equipo(array['super_admin', 'operador', 'agenda']::public.platform_role[]);
$$;

comment on function public.helios_puede_usar_la_agenda() is
  'Agenda: si quien llama puede usarla (super admin, operador o el rol agenda), con el segundo factor si se exige.';

revoke all on function public.helios_puede_usar_la_agenda() from public, anon;
grant execute on function public.helios_puede_usar_la_agenda() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. El equipo, para la agenda
-- ---------------------------------------------------------------------------

create or replace function public.admin_agenda_team()
returns table (user_id uuid, name text, role text)
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
  select pa.user_id, coalesce(nullif(btrim(pa.full_name), ''), au.email)::text, pa.role::text
    from public.platform_admins pa
    join auth.users au on au.id = pa.user_id
   where pa.is_active
   order by 2;
end;
$$;

comment on function public.admin_agenda_team() is
  'Agenda: el equipo activo (nombre y rol), para elegir quién gestiona a cada médico.';

revoke all on function public.admin_agenda_team() from public, anon;
grant execute on function public.admin_agenda_team() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Las RPC de la agenda, con su guardia nueva
-- ---------------------------------------------------------------------------

-- admin_delete_doctor_lead(uuid)
CREATE OR REPLACE FUNCTION public.admin_delete_doctor_lead(p_lead_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_lead  public.doctor_leads%rowtype;
begin
  if not public.helios_puede_usar_la_agenda() then
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
$function$;

-- admin_doctor_lead_activities(uuid)
CREATE OR REPLACE FUNCTION public.admin_doctor_lead_activities(p_lead_id uuid)
 RETURNS TABLE(id uuid, created_at timestamp with time zone, kind text, result text, channel text, status_from text, status_to text, meeting_at timestamp with time zone, note text, actor_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.helios_puede_usar_la_agenda() then
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
$function$;

-- admin_doctor_leads()
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
$function$;

-- admin_log_doctor_lead_contact(uuid,text,text,text,timestamp with time zone,text,text,date)
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
$function$;

-- admin_save_doctor_lead(uuid,jsonb)
CREATE OR REPLACE FUNCTION public.admin_save_doctor_lead(p_lead_id uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  if not public.helios_puede_usar_la_agenda() then
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
$function$;

