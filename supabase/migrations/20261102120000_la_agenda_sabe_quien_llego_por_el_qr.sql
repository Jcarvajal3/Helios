-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — La Agenda sabe quién llegó por el QR
--
-- Javier, 2026-11-02: los médicos que escanearon el QR y pidieron su
-- capacitación en /agenda tienen prioridad, y el superadmin tiene que
-- distinguirlos y poder filtrarlos. helios_agendar_capacitacion ya guarda
-- cuándo lo pidieron (doctor_leads.training_requested_at, también en uno que
-- ya estaba en la agenda); admin_doctor_leads() lo devuelve en qr_at.
-- ═══════════════════════════════════════════════════════════════════════════

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
             -- Cuándo pidió su capacitación por el QR (/agenda); null si nunca.
             'qr_at', l.training_requested_at,
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
