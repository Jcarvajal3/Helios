-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — La capacitación presencial entra a la agenda, y «afiliado» es
-- tener los accesos
--
-- Javier, 2026-10-23:
--
--   1. La solicitud de la portada pide, si el médico quiere, el día y la
--      hora de su capacitación presencial (`merchant_applications.training_at`).
--      De mañana en adelante y como mucho a 90 días.
--   2. Toda solicitud entra a la agenda como lead. Si ya había un lead de ese
--      médico (mismo teléfono, correo o nombre), se enlaza; si no, nace uno
--      con origen `formulario`. Con capacitación, el lead queda con la visita
--      agendada a esa hora (presencial, en su consultorio) y sale en el
--      calendario; sin ella, queda por contactar.
--   3. «Afiliado» deja de ponerse al llegar la solicitud o al nacer la
--      clínica: se pone cuando la clínica del lead tiene sus accesos (un
--      usuario activo en `merchant_users`). Al aprobar, el lead queda
--      enlazado con su clínica y la historia dice que falta darle los
--      accesos; al crearlos, pasa solo a «afiliado». Marcarlo a mano sigue
--      igual.
--   4. El tablero devuelve `application_training_at` (la capacitación que
--      pidió) y `merchant_has_access`.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. La capacitación en la solicitud
-- ---------------------------------------------------------------------------

alter table public.merchant_applications add column training_at timestamptz;

comment on column public.merchant_applications.training_at is
  'El día y la hora que pidió el médico para su capacitación presencial (opcional). Pasa a su lead de la agenda.';

alter table public.doctor_leads drop constraint doctor_leads_source_check;
alter table public.doctor_leads add constraint doctor_leads_source_check check (source in
  ('referido', 'redes', 'visita', 'evento', 'base_de_datos', 'otro', 'formulario'));

/**
 * La solicitud de afiliación de la portada (anon), ver 20261023130000. Ahora
 * guarda también la capacitación presencial, si la pidió: `training_at` con
 * su desfase (`2026-10-30T10:00:00-04:00`), de mañana a 90 días.
 */
create or replace function public.helios_solicitar_afiliacion(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d      jsonb;
  v_hdrs jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_ip   text := nullif(btrim(split_part(coalesce(v_hdrs->>'x-forwarded-for', v_hdrs->>'x-real-ip', ''), ',', 1)), '');
  v_cap_raw text := nullif(btrim(coalesce(p->>'training_at', '')), '');
  v_cap  timestamptz;
  v_hoy  date := public.helios_business_date(now());
begin
  if nullif(btrim(coalesce(p->>'sitio_web', '')), '') is not null then
    return jsonb_build_object('ok', true);
  end if;

  if nullif(regexp_replace(coalesce(p->>'account_number', ''), '\D', '', 'g'), '') is null then
    raise exception 'Pon los datos de la transferencia: banco y número de cuenta.' using errcode = '22023';
  end if;
  d := public.helios_datos_de_alta(p - 'pago_movil_bank' - 'pago_movil_phone');

  if v_cap_raw is not null then
    begin
      v_cap := v_cap_raw::timestamptz;
    exception when others then
      raise exception 'La fecha de la capacitación no es válida.' using errcode = '22023';
    end;
    if (v_cap at time zone 'America/Caracas')::date <= v_hoy then
      raise exception 'La capacitación tiene que ser de mañana en adelante.' using errcode = '22023';
    end if;
    if (v_cap at time zone 'America/Caracas')::date > v_hoy + 90 then
      raise exception 'La capacitación tiene que ser en los próximos 90 días.' using errcode = '22023';
    end if;
  end if;

  if (select count(*) from public.merchant_applications
      where created_at > now() - interval '1 hour') >= 60 then
    raise exception 'Estamos recibiendo muchas solicitudes. Inténtalo de nuevo en un rato.'
      using errcode = '54000';
  end if;

  if v_ip is not null and (select count(*) from public.merchant_applications
      where ip = v_ip and created_at > now() - interval '1 day') >= 5 then
    raise exception 'Ya recibimos varias solicitudes desde esta conexión. Te escribiremos pronto.'
      using errcode = '54000';
  end if;

  if exists (select 1 from public.merchant_applications
             where status = 'pending'
               and (owner_document = d->>'owner_document' or email = d->>'email' or phone = d->>'phone')) then
    raise exception 'Ya tenemos una solicitud tuya en revisión. Te escribiremos pronto.'
      using errcode = '23505';
  end if;

  insert into public.merchant_applications
    (owner_name, owner_document, tax_id, specialty, college_number, mpps_number,
     clinic_name, address, phone, email, social_network, social_user,
     account_holder, holder_document, bank, account_number,
     training_at, ip, user_agent)
  values (
    d->>'owner_name', d->>'owner_document', d->>'tax_id', d->>'specialty', d->>'college_number', d->>'mpps_number',
    d->>'clinic_name', d->>'address', d->>'phone', d->>'email', d->>'social_network', d->>'social_user',
    d->>'account_holder', d->>'holder_document', d->>'bank', d->>'account_number',
    v_cap, v_ip, left(v_hdrs->>'user-agent', 300)
  );

  return jsonb_build_object('ok', true);
end;
$$;

/** Las solicitudes, las más nuevas primero. `p_status` null = todas. Solo el equipo. */
create or replace function public.admin_merchant_applications(p_status text default 'pending')
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
      'id',               a.id,
      'status',           a.status,
      'owner_name',       a.owner_name,
      'owner_document',   a.owner_document,
      'tax_id',           a.tax_id,
      'specialty',        a.specialty,
      'college_number',   a.college_number,
      'mpps_number',      a.mpps_number,
      'clinic_name',      a.clinic_name,
      'address',          a.address,
      'phone',            a.phone,
      'email',            a.email,
      'social_network',   a.social_network,
      'social_user',      a.social_user,
      'account_holder',   a.account_holder,
      'holder_document',  a.holder_document,
      'bank',             a.bank,
      'account_number',   a.account_number,
      'pago_movil_bank',  a.pago_movil_bank,
      'pago_movil_phone', a.pago_movil_phone,
      'training_at',      a.training_at,
      'created_at',       a.created_at,
      'merchant_id',      a.merchant_id,
      'reviewed_at',      a.reviewed_at,
      'reviewed_by_name', (select full_name from public.platform_admins where user_id = a.reviewed_by),
      'reject_reason',    a.reject_reason
    ) order by a.created_at desc)
    from public.merchant_applications a
    where p_status is null or a.status = p_status
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. «Afiliado» es tener los accesos
-- ---------------------------------------------------------------------------

/** Si la clínica ya tiene sus accesos: alguien activo en su personal. */
create or replace function public.helios_clinica_tiene_accesos(p_merchant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.merchant_users where merchant_id = p_merchant_id and is_active)
$$;

revoke all on function public.helios_clinica_tiene_accesos(uuid) from public, anon, authenticated;

/**
 * Enlaza un lead con su solicitud o su clínica, y lo marca afiliado si esa
 * clínica ya tiene sus accesos (antes: siempre). La solicitud enlazada se
 * cambia solo si la de antes se rechazó (volvió a pedirla). No pisa la
 * clínica que ya tenga; la historia se anota solo si algo cambió.
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
  v_lead     public.doctor_leads%rowtype;
  v_app      uuid;
  v_merchant uuid;
  v_accesos  boolean;
  v_status   text;
  v_nota     text;
  v_nombre   text;
begin
  select * into v_lead from public.doctor_leads where id = p_lead_id for update;
  if not found then
    return;
  end if;

  v_app := case
    when p_application_id is not null
         and (v_lead.merchant_application_id is null
              or exists (select 1 from public.merchant_applications
                          where id = v_lead.merchant_application_id and status = 'rejected'))
      then p_application_id
    else v_lead.merchant_application_id
  end;
  v_merchant := coalesce(v_lead.merchant_id, p_merchant_id);
  v_accesos := v_merchant is not null and public.helios_clinica_tiene_accesos(v_merchant);
  v_status := case when v_accesos then 'convertido' else v_lead.status end;

  -- Nada nuevo: los mismos enlaces y el mismo estado.
  if v_app is not distinct from v_lead.merchant_application_id
     and v_merchant is not distinct from v_lead.merchant_id
     and v_status = v_lead.status then
    return;
  end if;

  update public.doctor_leads set
    merchant_application_id = v_app,
    merchant_id             = v_merchant,
    status                  = v_status,
    converted_at            = case when v_accesos then coalesce(converted_at, now()) else converted_at end,
    converted_via           = case when v_accesos then coalesce(converted_via, p_via) else converted_via end,
    match_reason            = coalesce(match_reason, p_reason),
    next_contact_on         = case when v_accesos then null else next_contact_on end,
    updated_at              = now()
  where id = p_lead_id;

  select name into v_nombre from public.merchants where id = v_merchant;

  if v_accesos and v_lead.status <> 'convertido' then
    v_nota := format('Ya tiene sus accesos a Helios: %s.', coalesce(v_nombre, 'su clínica'));
  elsif v_merchant is distinct from v_lead.merchant_id then
    v_nota := format('Quedó dada de alta su clínica: %s. Falta darle sus accesos.', coalesce(v_nombre, 'sin nombre'));
  elsif v_app is distinct from v_lead.merchant_application_id then
    v_nota := 'Llenó el formulario de afiliación.';
  else
    v_nota := 'Ya es cliente de Helios.';
  end if;

  if p_reason is not null and v_lead.match_reason is null then
    v_nota := v_nota || ' Se reconoció por su ' || case p_reason
      when 'telefono' then 'teléfono'
      when 'correo' then 'correo'
      else 'nombre'
    end || '.';
  end if;

  insert into public.doctor_lead_activities (lead_id, kind, status_from, status_to, note, actor)
  values (p_lead_id, 'conversion', v_lead.status, v_status, v_nota, null);
end;
$$;

revoke all on function public.helios_marcar_lead_afiliado(uuid, uuid, uuid, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Toda solicitud entra a la agenda
-- ---------------------------------------------------------------------------

/**
 * Llegó una solicitud de la portada: se enlaza con los leads de ese médico o
 * nace uno. Con capacitación, el lead queda con la visita a esa hora; sin
 * ella, el que no estaba en una visita queda «interesado» (llenó el
 * formulario). Nunca tumba la solicitud.
 */
create or replace function public.helios_leads_al_llegar_la_solicitud()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r       record;
  v_id    uuid;
  v_hay   boolean := false;
  v_cita  text := to_char(new.training_at at time zone 'America/Caracas', 'DD/MM/YYYY HH24:MI');
  v_lugar text := left(new.address, 300);
begin
  begin
    for r in
      select c.lead_id, c.reason
        from public.helios_leads_que_coinciden(new.phone, new.email, new.owner_name) c
        join public.doctor_leads l on l.id = c.lead_id
       where l.merchant_id is null
          or l.merchant_id = new.merchant_id
    loop
      v_hay := true;
      perform public.helios_marcar_lead_afiliado(r.lead_id, new.id, new.merchant_id, 'formulario', r.reason);

      -- La capacitación que pidió, o al menos «interesado».
      if new.training_at is not null then
        insert into public.doctor_lead_activities
          (lead_id, kind, result, status_from, status_to, meeting_at, note, actor)
        select l.id, 'gestion', 'visita_agendada', l.status, 'reunion', new.training_at,
               format('Pidió su capacitación presencial en el formulario: %s.', v_cita), null
          from public.doctor_leads l
         where l.id = r.lead_id and l.status <> 'convertido';

        update public.doctor_leads set
          status = 'reunion', meeting_at = new.training_at, meeting_mode = 'presencial',
          meeting_place = coalesce(v_lugar, meeting_place), next_contact_on = null, updated_at = now()
        where id = r.lead_id and status <> 'convertido';
      else
        update public.doctor_leads set status = 'respondio', updated_at = now()
        where id = r.lead_id and status in ('nuevo', 'contactado', 'no_respondio', 'descartado');
      end if;
    end loop;

    if not v_hay then
      insert into public.doctor_leads
        (name, clinic_name, specialty, phone, email, address, source, status,
         meeting_at, meeting_mode, meeting_place, merchant_application_id, match_reason)
      values (
        left(new.owner_name, 120), left(new.clinic_name, 120), left(new.specialty, 80), new.phone, new.email,
        v_lugar, 'formulario',
        case when new.training_at is not null then 'reunion' else 'nuevo' end,
        new.training_at,
        case when new.training_at is not null then 'presencial' end,
        case when new.training_at is not null then v_lugar end,
        new.id, null
      )
      returning id into v_id;

      insert into public.doctor_lead_activities (lead_id, kind, status_to, meeting_at, note, actor)
      values (
        v_id, 'creado',
        case when new.training_at is not null then 'reunion' else 'nuevo' end,
        new.training_at,
        case
          when new.training_at is not null
            then format('Llenó el formulario de afiliación y pidió su capacitación presencial: %s.', v_cita)
          else 'Llenó el formulario de afiliación.'
        end,
        null
      );
    end if;
  exception when others then
    raise warning 'Agenda: no se pudo cruzar la solicitud % con los leads: %', new.id, sqlerrm;
  end;
  return null;
end;
$$;

revoke all on function public.helios_leads_al_llegar_la_solicitud() from public, anon, authenticated;

/**
 * La clínica recibe sus accesos (alguien activo en su personal): sus leads,
 * los enlazados con ella o con la solicitud de la que nació, pasan a
 * afiliado.
 */
create or replace function public.helios_leads_al_dar_accesos()
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
      select l.id,
             case when l.merchant_application_id is not null then 'formulario' else 'alta' end as via
        from public.doctor_leads l
       where l.status <> 'convertido'
         and (l.merchant_id = new.merchant_id
              or (l.merchant_id is null and l.merchant_application_id in (
                    select a.id from public.merchant_applications a where a.merchant_id = new.merchant_id)))
    loop
      perform public.helios_marcar_lead_afiliado(r.id, null, new.merchant_id, r.via, null);
    end loop;
  exception when others then
    raise warning 'Agenda: no se pudo marcar afiliados los leads de la clínica %: %', new.merchant_id, sqlerrm;
  end;
  return null;
end;
$$;

revoke all on function public.helios_leads_al_dar_accesos() from public, anon, authenticated;

create trigger doctor_leads_al_dar_accesos
  after insert or update of is_active on public.merchant_users
  for each row when (new.is_active)
  execute function public.helios_leads_al_dar_accesos();

-- ---------------------------------------------------------------------------
-- 4. El tablero, con la capacitación y los accesos
-- ---------------------------------------------------------------------------

create or replace function public.admin_doctor_leads()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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
             'application_training_at', ma.training_at,
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
$$;
