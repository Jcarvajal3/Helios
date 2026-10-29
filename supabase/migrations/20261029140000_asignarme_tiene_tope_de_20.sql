-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — «Asignarme médicos» tiene un tope de 20 por contactar
--
-- Javier, 2026-10-29: Alejandro pulsó «Asignarme 20» cuatro veces en tres
-- segundos y se quedó con 80. Nadie tiene más de 20 médicos por contactar
-- (`nuevo`) a su cargo por esta vía: el botón completa hasta 20 y, con 20 o
-- más, no da ninguno y dice por qué. Un candado por persona
-- (`pg_advisory_xact_lock`) hace que dos clics a la vez se esperen y el
-- segundo ya cuente los del primero.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.admin_assign_me_doctor_leads(p_cantidad integer default 20)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tope  constant integer := 20;
  v_actor uuid := auth.uid();
  v_tengo integer;
  v_ids   uuid[];
begin
  if not public.helios_puede_usar_la_agenda() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;
  if p_cantidad is null or p_cantidad < 1 or p_cantidad > 100 then
    raise exception 'Pide entre 1 y 100 médicos.' using errcode = '22023';
  end if;

  -- Dos clics a la vez: el segundo espera al primero y cuenta lo que tomó.
  perform pg_advisory_xact_lock(hashtext('agenda-asignarme:' || v_actor::text));

  select count(*) into v_tengo
    from public.doctor_leads
   where assigned_to = v_actor and status = 'nuevo';
  if v_tengo >= v_tope then
    raise exception 'Ya tienes % médicos por contactar. Escríbeles antes de pedir más.', v_tengo
      using errcode = '22023';
  end if;

  with elegidos as (
    select id
      from public.doctor_leads
     where assigned_to is null
       and status = 'nuevo'
     order by random()
     limit least(p_cantidad, v_tope - v_tengo)
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
      'had', v_tengo,
      'lead_ids', to_jsonb(v_ids)
    ));
  end if;

  return coalesce(array_length(v_ids, 1), 0);
end;
$$;

comment on function public.admin_assign_me_doctor_leads(integer) is
  'Agenda: le asigna a quien llama médicos al azar por contactar y sin encargado, hasta tener 20 por contactar (22023 si ya los tiene). Devuelve cuántos.';
