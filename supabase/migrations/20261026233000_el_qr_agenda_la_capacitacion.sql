-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El QR agenda la capacitación del médico
--
-- Javier, 2026-10-26: el QR impreso (`conhelios.com/qr`) deja de llevar a la
-- afiliación y lleva a `/agenda`, una página corta, de un solo paso, donde
-- el médico deja su nombre, su teléfono, su especialidad, la dirección de su
-- consultorio y el día y la hora de su capacitación presencial. Todo entra a
-- Superadmin › Agenda:
--
--   · Si ya está en la agenda (mismo teléfono o mismo nombre), su lead queda
--     con la visita a esa hora, presencial, en su consultorio. Solo se
--     completan los datos que le faltaban; lo que escribió va en la historia.
--   · Si no, nace un lead de origen `qr` con esa visita.
--   · `doctor_leads.training_at` guarda la capacitación que pidió, y el
--     tablero la devuelve en `application_training_at` (antes solo la del
--     formulario): el calendario la enseña como «Capacitación».
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.doctor_leads
  add column training_at timestamptz,
  add column training_requested_at timestamptz;

comment on column public.doctor_leads.training_at is
  'La capacitación presencial que pidió el propio médico desde el QR (`helios_agendar_capacitacion`).';
comment on column public.doctor_leads.training_requested_at is
  'Cuándo la pidió por última vez (frena el abuso de la página pública).';

alter table public.doctor_leads drop constraint doctor_leads_source_check;
alter table public.doctor_leads add constraint doctor_leads_source_check check (source in
  ('referido', 'redes', 'visita', 'evento', 'base_de_datos', 'otro', 'formulario', 'qr'));

/**
 * La página del QR (anon): agenda la capacitación presencial del médico.
 * `p`: `name`, `phone`, `specialty`, `address`, `training_at` (con su
 * desfase, `2026-10-30T10:00:00-04:00`, de mañana a 90 días) y el campo
 * trampa `sitio_web`. Devuelve `{ok: true}`. `22023` con un dato que no
 * vale; `54000` si llegan demasiadas en una hora.
 */
create or replace function public.helios_agendar_capacitacion(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_nombre  text := nullif(btrim(regexp_replace(coalesce(p->>'name', ''), '\s+', ' ', 'g')), '');
  v_esp     text := nullif(btrim(regexp_replace(coalesce(p->>'specialty', ''), '\s+', ' ', 'g')), '');
  v_dir     text := nullif(btrim(regexp_replace(coalesce(p->>'address', ''), '\s+', ' ', 'g')), '');
  v_tel     text := public.helios_normalize_ve_phone(nullif(btrim(coalesce(p->>'phone', '')), ''));
  v_cap_raw text := nullif(btrim(coalesce(p->>'training_at', '')), '');
  v_cap     timestamptz;
  v_hoy     date := public.helios_business_date(now());
  v_cita    text;
  v_lead    public.doctor_leads%rowtype;
  v_id      uuid;
begin
  if nullif(btrim(coalesce(p->>'sitio_web', '')), '') is not null then
    return jsonb_build_object('ok', true);
  end if;

  if v_nombre is null or char_length(v_nombre) < 3 or char_length(v_nombre) > 120 then
    raise exception 'Escribe tu nombre y apellido.' using errcode = '22023';
  end if;
  if v_tel is null then
    raise exception 'El teléfono no parece venezolano: 0212 5551234 o 0414 1234567.' using errcode = '22023';
  end if;
  if v_esp is null or char_length(v_esp) > 80 then
    raise exception 'Escribe tu especialidad.' using errcode = '22023';
  end if;
  if v_dir is null or char_length(v_dir) < 5 or char_length(v_dir) > 300 then
    raise exception 'Escribe la dirección de tu consultorio.' using errcode = '22023';
  end if;

  if v_cap_raw is null then
    raise exception 'Elige el día y la hora de la capacitación.' using errcode = '22023';
  end if;
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

  if (select count(*) from public.doctor_leads
      where training_requested_at > now() - interval '1 hour') >= 40 then
    raise exception 'Estamos recibiendo muchas solicitudes. Inténtalo de nuevo en un rato.'
      using errcode = '54000';
  end if;

  v_cita := to_char(v_cap at time zone 'America/Caracas', 'DD/MM/YYYY HH24:MI');

  -- ¿Ya está en la agenda? Primero por teléfono, luego por nombre.
  select l.* into v_lead
    from public.helios_leads_que_coinciden(v_tel, null, v_nombre) c
    join public.doctor_leads l on l.id = c.lead_id
   order by (c.reason = 'telefono') desc, l.created_at desc
   limit 1
   for update of l;

  if found then
    update public.doctor_leads set
      phone                 = coalesce(phone, v_tel),
      specialty             = coalesce(specialty, left(v_esp, 80)),
      address               = coalesce(address, left(v_dir, 300)),
      training_at           = v_cap,
      training_requested_at = now(),
      -- Un cliente ya afiliado conserva su estado: la capacitación queda en
      -- su historia.
      status          = case when status = 'convertido' then status else 'reunion' end,
      meeting_at      = case when status = 'convertido' then meeting_at else v_cap end,
      meeting_mode    = case when status = 'convertido' then meeting_mode else 'presencial' end,
      meeting_place   = case when status = 'convertido' then meeting_place else left(v_dir, 300) end,
      next_contact_on = case when status = 'convertido' then next_contact_on else null end,
      updated_at      = now()
    where id = v_lead.id;

    insert into public.doctor_lead_activities
      (lead_id, kind, result, status_from, status_to, meeting_at, note, actor)
    values (
      v_lead.id, 'gestion', 'visita_agendada', v_lead.status,
      case when v_lead.status = 'convertido' then 'convertido' else 'reunion' end,
      v_cap,
      left(format('Agendó su capacitación presencial con el QR: %s. Dejó: %s · %s · %s · %s.',
                  v_cita, v_nombre, public.helios_format_ve_phone(v_tel), v_esp, v_dir), 2000),
      null
    );
    return jsonb_build_object('ok', true);
  end if;

  insert into public.doctor_leads
    (name, specialty, phone, address, source, status,
     meeting_at, meeting_mode, meeting_place, training_at, training_requested_at)
  values (
    v_nombre, left(v_esp, 80), v_tel, left(v_dir, 300), 'qr', 'reunion',
    v_cap, 'presencial', left(v_dir, 300), v_cap, now()
  )
  returning id into v_id;

  insert into public.doctor_lead_activities (lead_id, kind, status_to, meeting_at, note, actor)
  values (v_id, 'creado', 'reunion', v_cap,
          format('Agendó su capacitación presencial con el QR: %s.', v_cita), null);

  -- ¿Ya es cliente o pidió la afiliación? Que salga enlazado.
  begin
    perform public.helios_cruzar_lead(v_id);
  exception when others then
    raise warning 'Agenda: no se pudo cruzar el lead % del QR: %', v_id, sqlerrm;
  end;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.helios_agendar_capacitacion(jsonb) from public;
grant execute on function public.helios_agendar_capacitacion(jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- El tablero: la capacitación que pidió, por el QR o por el formulario
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
$$;
