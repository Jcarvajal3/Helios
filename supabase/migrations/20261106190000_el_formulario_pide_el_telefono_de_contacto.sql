-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El formulario pide el teléfono de contacto
--
-- Javier, 2026-11-06: algunos médicos no quieren publicar su número personal.
-- El formulario de la capacitación (/afiliacion y /agenda) pide además un
-- teléfono de contacto, opcional, que es el que sale en el directorio. En
-- blanco, sale el personal, como hasta hoy.
--
--   · `doctor_leads.contact_phone` y `contact_phone_at`. `phone` sigue siendo
--     el personal: con él se cruza el lead con su clínica y lo llama el equipo.
--   · `helios_directorio_fichas()`: el WhatsApp base de una clínica pasa a ser
--     el teléfono de contacto de su lead o, si no hay, `merchants.phone`. Lo
--     que el equipo escriba en la ficha del directorio sigue mandando.
--   · Solo vale el que se dejó ANTES de crearse la clínica. El formulario es
--     público y reconoce al médico por su nombre: si valiera siempre, cualquiera
--     podría cambiar el número al que escriben los pacientes de un médico ya
--     publicado. Al crear la clínica el equipo ya lo visitó; después de eso, el
--     número queda en su ficha de la Agenda y lo pasa el equipo a mano.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.doctor_leads
  add column contact_phone text,
  add column contact_phone_at timestamptz;

comment on column public.doctor_leads.contact_phone is
  'El teléfono que el médico quiere enseñar en el directorio (E.164). Null: el personal.';
comment on column public.doctor_leads.contact_phone_at is
  'Cuándo lo dejó. El directorio solo lo usa si es de antes de crearse la clínica.';

/**
 * Las páginas públicas /agenda (QR) y /afiliacion (web), anon: agendan la
 * capacitación presencial del médico. `p`: `name`, `phone`, `contact_phone`
 * (opcional), `specialty`, `address`, `training_at` (con su desfase,
 * `2026-10-30T10:00:00-04:00`, de mañana a 90 días), `origin` (`web`; si no,
 * es `qr`) y el campo trampa `sitio_web`. Devuelve `{ok: true}`. `22023` con un
 * dato que no vale; `54000` si llegan demasiadas en una hora.
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
  v_cto_raw text := nullif(btrim(coalesce(p->>'contact_phone', '')), '');
  v_cto     text := public.helios_normalize_ve_phone(nullif(btrim(coalesce(p->>'contact_phone', '')), ''));
  v_cap_raw text := nullif(btrim(coalesce(p->>'training_at', '')), '');
  v_via     text := case when p->>'origin' = 'web' then 'web' else 'qr' end;
  v_por     text := case when p->>'origin' = 'web' then 'desde la web' else 'con el QR' end;
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
  if v_cto_raw is not null and v_cto is null then
    raise exception 'El teléfono de contacto no parece venezolano: 0212 5551234 o 0414 1234567.' using errcode = '22023';
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
      phone                  = coalesce(phone, v_tel),
      contact_phone          = coalesce(v_cto, contact_phone),
      contact_phone_at       = case when v_cto is not null then now() else contact_phone_at end,
      specialty              = coalesce(specialty, left(v_esp, 80)),
      address                = coalesce(address, left(v_dir, 300)),
      training_at            = v_cap,
      training_requested_at  = now(),
      training_requested_via = v_via,
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
      left(format('Agendó su capacitación presencial %s: %s. Dejó: %s · %s · %s · %s%s.',
                  v_por, v_cita, v_nombre, public.helios_format_ve_phone(v_tel), v_esp, v_dir,
                  case when v_cto is not null
                       then ' · contacto para el directorio: ' || public.helios_format_ve_phone(v_cto)
                       else '' end), 2000),
      null
    );
    return jsonb_build_object('ok', true);
  end if;

  insert into public.doctor_leads
    (name, specialty, phone, contact_phone, contact_phone_at, address, source, status,
     meeting_at, meeting_mode, meeting_place, training_at, training_requested_at, training_requested_via)
  values (
    v_nombre, left(v_esp, 80), v_tel, v_cto, case when v_cto is not null then now() end,
    left(v_dir, 300), v_via, 'reunion',
    v_cap, 'presencial', left(v_dir, 300), v_cap, now(), v_via
  )
  returning id into v_id;

  insert into public.doctor_lead_activities (lead_id, kind, status_to, meeting_at, note, actor)
  values (v_id, 'creado', 'reunion', v_cap,
          format('Agendó su capacitación presencial %s: %s.', v_por, v_cita), null);

  -- ¿Ya es cliente o pidió la afiliación? Que salga enlazado.
  begin
    perform public.helios_cruzar_lead(v_id);
  exception when others then
    raise warning 'Agenda: no se pudo cruzar el lead % (%): %', v_id, v_via, sqlerrm;
  end;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.helios_agendar_capacitacion(jsonb) from public;
grant execute on function public.helios_agendar_capacitacion(jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- El directorio: el teléfono de contacto, antes que el de la clínica
-- ---------------------------------------------------------------------------

create or replace function public.helios_directorio_fichas()
returns table (
  merchant_id            uuid,
  clinic_name            text,
  status                 public.merchant_status,
  is_test                boolean,
  is_visible             boolean,
  published_at           timestamptz,
  updated_at             timestamptz,
  -- De la ficha.
  base_name              text,
  base_specialty         text,
  base_specialty_key     text,
  base_address           text,
  base_city              text,
  base_whatsapp          text,
  base_social_network    text,
  base_social_user       text,
  -- Lo que se enseña.
  name                   text,
  specialty              text,
  specialty_key          text,
  address                text,
  city                   text,
  whatsapp               text,
  social_network         text,
  social_user            text,
  -- Solo del directorio: la ficha no lo tiene.
  consultation_price_usd numeric(18,4),
  -- Null si se puede publicar; si no, por qué.
  blocked_reason         text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.id, m.name, m.status, m.is_test,
         coalesce(l.is_visible, false), l.published_at, l.updated_at,
         b.name, b.specialty, b.specialty_key, b.address, b.city, b.whatsapp,
         b.social_network, b.social_user,
         coalesce(l.display_name, b.name),
         coalesce(l.specialty, b.specialty),
         coalesce(l.specialty_key, b.specialty_key),
         coalesce(l.address, b.address),
         coalesce(l.city, b.city),
         coalesce(l.whatsapp, b.whatsapp),
         coalesce(l.social_network, b.social_network),
         coalesce(l.social_user, b.social_user),
         l.consultation_price_usd,
         case
           when m.status = 'terminated' then 'terminada'
           when m.status = 'paused' then 'pausada'
           when m.is_test then 'prueba'
           when coalesce(l.whatsapp, b.whatsapp) is null then 'sin_whatsapp'
         end
    from public.merchants m
    left join public.directory_listings l on l.merchant_id = m.id
    cross join lateral (
      select public.helios_doctor_name(m.id) as name,
             public.helios_directorio_texto(m.specialty) as specialty,
             public.helios_directorio_especialidad_sugerida(m.specialty, m.category) as specialty_key,
             nullif(btrim(coalesce(m.address, '')), '') as address,
             nullif(btrim(coalesce(m.city, '')), '') as city,
             -- El de contacto que dejó antes de crearse su clínica (20261106190000).
             coalesce(
               (select dl.contact_phone
                  from public.doctor_leads dl
                 where dl.merchant_id = m.id
                   and dl.contact_phone is not null
                   and dl.contact_phone_at <= m.created_at
                 order by dl.contact_phone_at desc
                 limit 1),
               public.helios_normalize_ve_phone(m.phone)
             ) as whatsapp,
             -- La red y el usuario van juntos: sin usuario, no hay red.
             case when nullif(btrim(coalesce(m.social_user, '')), '') is not null then m.social_network end as social_network,
             case when m.social_network is not null then nullif(btrim(coalesce(m.social_user, '')), '') end as social_user
    ) b;
$$;

revoke all on function public.helios_directorio_fichas() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- El tablero: `contact_phone`
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
             'contact_phone', l.contact_phone,
             'email', l.email,
             'address', l.address,
             'city', l.city,
             'source', l.source,
             'notes', l.notes,
             'status', l.status,
             'stage', l.stage,
             -- Cuándo pidió su capacitación, y por dónde; null si nunca.
             'qr_at', case when l.training_requested_via = 'qr' then l.training_requested_at end,
             'web_at', case when l.training_requested_via = 'web' then l.training_requested_at end,
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
