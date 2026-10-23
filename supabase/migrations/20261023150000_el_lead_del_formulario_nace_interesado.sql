-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El lead que nace del formulario sin capacitación, interesado
--
-- Javier, 2026-10-23: quien llena el formulario de afiliación ya mostró
-- interés. El lead que nace de una solicitud sin capacitación queda
-- `respondio` («Interesado»), no `nuevo` («Sin contactar»), igual que un
-- lead que ya estaba. Con capacitación sigue igual (`reunion`).
--
-- Solo cambia `helios_leads_al_llegar_la_solicitud` (ver 20261023140000).
-- No había leads de formulario en `nuevo` que corregir.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.helios_leads_al_llegar_la_solicitud()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r        record;
  v_id     uuid;
  v_hay    boolean := false;
  v_cita   text := to_char(new.training_at at time zone 'America/Caracas', 'DD/MM/YYYY HH24:MI');
  v_lugar  text := left(new.address, 300);
  v_estado text := case when new.training_at is not null then 'reunion' else 'respondio' end;
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
        v_lugar, 'formulario', v_estado,
        new.training_at,
        case when new.training_at is not null then 'presencial' end,
        case when new.training_at is not null then v_lugar end,
        new.id, null
      )
      returning id into v_id;

      insert into public.doctor_lead_activities (lead_id, kind, status_to, meeting_at, note, actor)
      values (
        v_id, 'creado', v_estado, new.training_at,
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
