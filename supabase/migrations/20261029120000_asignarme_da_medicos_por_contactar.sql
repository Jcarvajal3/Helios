-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — «Asignarme médicos» da médicos por contactar, a cualquiera
--
-- Javier, 2026-10-29: cualquiera del equipo puede escribir a médicos, así que
-- «Asignarme 20» no mira las fases de quien lo pulsa (20261028170000): le da
-- hasta 20 médicos al azar que nadie ha contactado todavía (`nuevo`, en
-- Mensaje) y que no tienen encargado. Los de Llamada y Visita no se piden:
-- llegan solos con el reparto de cada fase.
-- ═══════════════════════════════════════════════════════════════════════════

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
       and status = 'nuevo'
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
  'Agenda: le asigna a quien llama hasta p_cantidad médicos al azar por contactar (nuevo) y sin encargado. Devuelve cuántos.';
