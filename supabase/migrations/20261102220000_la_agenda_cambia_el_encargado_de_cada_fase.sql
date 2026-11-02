-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — La agenda cambia el encargado de cada fase
--
-- El encargado de un médico solo se cambiaba desde «Editar datos», y solo el
-- de la fase en que está (`assigned_to`). Ahora la ficha cambia el de
-- cualquiera de las tres: el de Visita se puede dejar puesto mientras el
-- médico aún va por Mensaje, y al llegar a Visita lo hereda
-- (`helios_lead_fase`, 20261028170000).
--
-- `admin_set_doctor_lead_owner(p_lead_id, p_stage, p_user_id)`: `p_user_id`
-- null deja la fase sin encargado. Si la fase es la actual, también cambia
-- `assigned_to` («Gestionado por»). Lo puede usar quien usa la agenda.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.admin_set_doctor_lead_owner(p_lead_id uuid, p_stage text, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_lead  public.doctor_leads%rowtype;
  v_antes uuid;
begin
  if not public.helios_puede_usar_la_agenda() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_stage is null or p_stage not in ('mensaje', 'llamada', 'visita') then
    raise exception 'Fase desconocida: %', p_stage using errcode = '22023';
  end if;

  if p_user_id is not null and not exists (
    select 1 from public.platform_admins where user_id = p_user_id and is_active
  ) then
    raise exception 'El encargado tiene que ser alguien del equipo.' using errcode = '22023';
  end if;

  select * into v_lead from public.doctor_leads where id = p_lead_id for update;
  if not found then
    raise exception 'Ese médico ya no está en la agenda.' using errcode = 'P0002';
  end if;

  v_antes := case p_stage
    when 'mensaje' then v_lead.message_owner
    when 'llamada' then v_lead.call_owner
    else v_lead.visit_owner
  end;

  if v_antes is not distinct from p_user_id then
    return jsonb_build_object('id', v_lead.id, 'changed', false);
  end if;

  -- En la fase actual va también `assigned_to`: el disparador vuelve a poner
  -- el encargado de la fase actual a partir de él.
  update public.doctor_leads
     set message_owner = case when p_stage = 'mensaje' then p_user_id else message_owner end,
         call_owner    = case when p_stage = 'llamada' then p_user_id else call_owner end,
         visit_owner   = case when p_stage = 'visita'  then p_user_id else visit_owner end,
         assigned_to   = case when p_stage = stage then p_user_id else assigned_to end,
         updated_at    = now()
   where id = p_lead_id;

  perform audit.log(v_actor, 'doctor_lead.assigned', p_lead_id, jsonb_build_object(
    'stage', p_stage, 'from', v_antes, 'to', p_user_id));

  return jsonb_build_object('id', v_lead.id, 'changed', true);
end;
$$;

comment on function public.admin_set_doctor_lead_owner(uuid, text, uuid) is
  'Agenda: cambia el encargado de una fase de un médico (null = sin encargado); en la fase actual, también «Gestionado por».';

revoke all on function public.admin_set_doctor_lead_owner(uuid, text, uuid) from public, anon;
grant execute on function public.admin_set_doctor_lead_owner(uuid, text, uuid) to authenticated;
