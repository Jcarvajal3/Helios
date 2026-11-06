-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El teléfono de contacto va en el alta de la clínica
--
-- Javier, 2026-11-06: corrige 20261106190000, que lo puso donde no era. El
-- campo va en el formulario de afiliación del superadmin (Clínicas › alta, y la
-- revisión de una solicitud), no en las páginas públicas /afiliacion y /agenda.
-- Algunos médicos no quieren publicar su número personal; en blanco, el
-- directorio enseña el personal (`merchants.phone`), como hasta hoy.
--
--   · `merchants.contact_phone` (E.164). Lo que el equipo escriba en la ficha
--     del directorio sigue mandando sobre él.
--   · `helios_crear_clinica` lo acepta en `p.contact_phone`, y lo reciben el
--     alta y la aprobación de una solicitud. `helios_solicitar_afiliacion` no.
--   · `helios_agendar_capacitacion` y `admin_doctor_leads` vuelven a como
--     estaban en 20261105120000, y `doctor_leads` pierde `contact_phone` y
--     `contact_phone_at`: al aplicar esto estaban vacías en todas las filas.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.merchants add column contact_phone text;

comment on column public.merchants.contact_phone is
  'El teléfono que el médico quiere enseñar en el directorio (E.164). Null: el personal, `phone`.';

/**
 * Las páginas públicas /agenda (QR) y /afiliacion (web), anon: agendan la
 * capacitación presencial del médico. `p`: `name`, `phone`, `specialty`,
 * `address`, `training_at` (con su desfase, `2026-10-30T10:00:00-04:00`, de
 * mañana a 90 días), `origin` (`web`; si no, es `qr`) y el campo trampa
 * `sitio_web`. Devuelve `{ok: true}`. `22023` con un dato que no vale; `54000`
 * si llegan demasiadas en una hora.
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
      left(format('Agendó su capacitación presencial %s: %s. Dejó: %s · %s · %s · %s.',
                  v_por, v_cita, v_nombre, public.helios_format_ve_phone(v_tel), v_esp, v_dir), 2000),
      null
    );
    return jsonb_build_object('ok', true);
  end if;

  insert into public.doctor_leads
    (name, specialty, phone, address, source, status,
     meeting_at, meeting_mode, meeting_place, training_at, training_requested_at, training_requested_via)
  values (
    v_nombre, left(v_esp, 80), v_tel, left(v_dir, 300), v_via, 'reunion',
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
-- El tablero: `qr_at` y `web_at`
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

-- ---------------------------------------------------------------------------
-- El directorio
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.helios_directorio_fichas()
 RETURNS TABLE(merchant_id uuid, clinic_name text, status merchant_status, is_test boolean, is_visible boolean, published_at timestamp with time zone, updated_at timestamp with time zone, base_name text, base_specialty text, base_specialty_key text, base_address text, base_city text, base_whatsapp text, base_social_network text, base_social_user text, name text, specialty text, specialty_key text, address text, city text, whatsapp text, social_network text, social_user text, consultation_price_cur numeric, consultation_currency text, blocked_reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
         l.consultation_price_cur,
         coalesce(l.consultation_currency, 'USD'),
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
             -- El teléfono de contacto del alta y, si no hay, el personal.
             coalesce(m.contact_phone, public.helios_normalize_ve_phone(m.phone)) as whatsapp,
             -- La red y el usuario van juntos: sin usuario, no hay red.
             case when nullif(btrim(coalesce(m.social_user, '')), '') is not null then m.social_network end as social_network,
             case when m.social_network is not null then nullif(btrim(coalesce(m.social_user, '')), '') end as social_user
    ) b;
$function$;

revoke all on function public.helios_directorio_fichas() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- El alta
-- ---------------------------------------------------------------------------

create or replace function public.helios_crear_clinica(p jsonb, p_actor uuid)
returns uuid
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  d      jsonb := public.helios_datos_de_alta(p);
  v_id   uuid;
  v_logo text := nullif(btrim(coalesce(p->>'logo_url', '')), '');
  v_cto_raw text := nullif(btrim(coalesce(p->>'contact_phone', '')), '');
  v_cto  text := public.helios_normalize_ve_phone(nullif(btrim(coalesce(p->>'contact_phone', '')), ''));
begin
  if v_cto_raw is not null and v_cto is null then
    raise exception 'El teléfono de contacto no parece venezolano: 0212 5551234 o 0414 1234567.' using errcode = '22023';
  end if;

  if d->>'tax_id' is not null and exists (select 1 from public.merchants where tax_id = d->>'tax_id') then
    raise exception 'Ya hay una clínica dada de alta con el RIF %', d->>'tax_id' using errcode = '23505';
  end if;

  insert into public.merchants
    (name, tax_id, category, logo_url, specialty, mpps_number, phone, contact_phone, email, address,
     owner_name, owner_document, college_number, doctor_title, social_network, social_user)
  values (
    d->>'clinic_name', d->>'tax_id', public.helios_categoria_por_especialidad(d->>'specialty'), v_logo,
    d->>'specialty', d->>'mpps_number', d->>'phone', v_cto, d->>'email', d->>'address',
    d->>'owner_name', d->>'owner_document', d->>'college_number', d->>'doctor_title',
    d->>'social_network', d->>'social_user'
  )
  returning id into v_id;

  insert into public.merchant_payout_accounts
    (merchant_id, account_holder, holder_document, bank, account_number,
     pago_movil_phone, pago_movil_bank, updated_by)
  values (
    v_id, d->>'account_holder', d->>'holder_document', d->>'bank', d->>'account_number',
    d->>'pago_movil_phone', d->>'pago_movil_bank', p_actor
  );

  perform audit.log(p_actor, 'merchant.created', v_id, jsonb_build_object(
    'name', d->>'clinic_name', 'tax_id', d->>'tax_id', 'specialty', d->>'specialty',
    'owner_name', d->>'owner_name', 'owner_document', d->>'owner_document',
    'doctor_title', d->>'doctor_title',
    'mpps_number', d->>'mpps_number', 'college_number', d->>'college_number',
    'social_network', d->>'social_network', 'social_user', d->>'social_user',
    'contact_phone', v_cto));

  perform audit.log(p_actor, 'merchant.payout_account_set', v_id, jsonb_build_object(
    'antes', null,
    'despues', (select to_jsonb(a) - 'updated_by' - 'updated_at'
                from public.merchant_payout_accounts a where a.merchant_id = v_id)));

  return v_id;
end;
$$;

revoke all on function public.helios_crear_clinica(jsonb, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Lo que ya no se usa (ninguna función lo lee después de lo de arriba)
-- ---------------------------------------------------------------------------

alter table public.doctor_leads
  drop column contact_phone,
  drop column contact_phone_at;
