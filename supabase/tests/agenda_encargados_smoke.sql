-- ============================================================================
-- Helios — Un encargado por fase, con reparto automático (20261028170000)
--
--   bash supabase/tests/run.sh agenda_encargados_smoke
--
-- Se comprueba que:
--   1. Solo un super admin cambia el equipo de cada fase, y queda en la
--      bitácora; el equipo de la agenda dice las fases de cada uno.
--   2. Al pasar a Llamada, el médico pasa a alguien del equipo de Llamada (el
--      que menos lleva), y a Visita, a alguien del de Visita; quien lo llevó
--      en Mensaje se queda apuntado.
--   3. Si vuelve a una fase, vuelve a quien ya la llevó.
--   4. Cambiar el encargado a mano mueve también el de su fase.
--   5. Sin equipo en una fase, sigue con quien lo llevaba.
--   6. «Asignarme médicos» da médicos por contactar, no los de otras fases
--      (20261029120000).
--   7. Lo que hizo cada persona se cuenta por quien anotó la gestión.
--
-- No manda nada: no llama a `helios_dispatch_*`.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_jefe    uuid;
  v_lis     uuid;
  v_juan    uuid;
  v_juan2   uuid;
  v_carlos  uuid;
  v_manana  timestamptz := ((public.helios_business_date(now()) + 1)::timestamp + time '10:30') at time zone 'America/Caracas';
  v_a       uuid;
  v_b       uuid;
  v_l       public.doctor_leads%rowtype;
  v_fallo   boolean;
  v_n       integer;
begin
  v_jefe := pg_temp.prueba_admin();
  v_lis := pg_temp.prueba_admin();
  v_juan := pg_temp.prueba_admin();
  v_juan2 := pg_temp.prueba_admin();
  v_carlos := pg_temp.prueba_admin();
  -- Lis no es super admin: no puede cambiar los equipos.
  update public.platform_admins set role = 'agenda' where user_id = v_lis;
  -- Que los equipos reales no se metan en el reparto de la prueba.
  delete from public.agenda_phase_members;

  -- =========================================================================
  -- 1. El equipo de cada fase
  -- =========================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_lis::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_set_agenda_phases(v_lis, array['mensaje']);
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '1. alguien que no es super admin cambió los equipos'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_jefe::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_set_agenda_phases(v_lis, array['reunion']);
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '1. aceptó una fase desconocida'; end if;

  perform public.admin_set_agenda_phases(v_lis, array['mensaje']);
  perform public.admin_set_agenda_phases(v_juan, array['llamada']);
  perform public.admin_set_agenda_phases(v_juan2, array['llamada']);
  perform public.admin_set_agenda_phases(v_carlos, array['visita', 'mensaje']);
  perform public.admin_set_agenda_phases(v_carlos, array['visita']);
  if (select stages from public.admin_agenda_team() t where t.user_id = v_carlos) <> array['visita'] then
    raise exception '1. el equipo no dice las fases de Carlos';
  end if;
  if not exists (
    select 1 from audit.admin_actions where action = 'agenda.phase_members' and target_id = v_carlos
  ) then
    raise exception '1. el cambio de equipo no quedó en la bitácora';
  end if;

  -- =========================================================================
  -- 2. El reparto al pasar de fase
  -- =========================================================================
  v_a := (public.admin_save_doctor_lead(null, jsonb_build_object(
    'name', 'Dra. Encargada Uno', 'phone', '04147200001', 'assigned_to', v_lis)) ->> 'id')::uuid;
  v_b := (public.admin_save_doctor_lead(null, jsonb_build_object(
    'name', 'Dr. Encargado Dos', 'phone', '04147200002', 'assigned_to', v_lis)) ->> 'id')::uuid;
  select * into v_l from public.doctor_leads where id = v_a;
  if v_l.message_owner is distinct from v_lis then raise exception '2. Lis debía quedar en Mensaje: %', row_to_json(v_l); end if;

  -- El primero, a Juan o a Juan 2; el segundo, al que no lo recibió (menos lleva).
  perform public.admin_log_doctor_lead_contact(v_b, 'interesado', 'mensaje');
  select * into v_l from public.doctor_leads where id = v_b;
  if v_l.assigned_to not in (v_juan, v_juan2) or v_l.call_owner is distinct from v_l.assigned_to
     or v_l.message_owner is distinct from v_lis then
    raise exception '2. el interesado no pasó al equipo de Llamada: %', row_to_json(v_l);
  end if;
  perform public.admin_log_doctor_lead_contact(v_a, 'interesado', 'mensaje');
  if (select assigned_to from public.doctor_leads where id = v_a)
     = (select assigned_to from public.doctor_leads where id = v_b) then
    raise exception '2. el reparto no le dio el segundo al que menos llevaba';
  end if;

  perform public.admin_log_doctor_lead_contact(v_a, 'visita_agendada', 'llamada', null, v_manana);
  select * into v_l from public.doctor_leads where id = v_a;
  if v_l.assigned_to is distinct from v_carlos or v_l.visit_owner is distinct from v_carlos
     or v_l.call_owner is null or v_l.message_owner is distinct from v_lis then
    raise exception '2. la visita no pasó a Carlos con la historia de encargados: %', row_to_json(v_l);
  end if;

  -- =========================================================================
  -- 3. Si vuelve a una fase, vuelve a quien la llevó
  -- =========================================================================
  perform public.admin_log_doctor_lead_contact(v_a, 'visita_cancelada', 'visita');
  select * into v_l from public.doctor_leads where id = v_a;
  if v_l.stage <> 'llamada' or v_l.assigned_to is distinct from v_l.call_owner then
    raise exception '3. la visita cancelada no volvió a quien lo llamaba: %', row_to_json(v_l);
  end if;

  -- =========================================================================
  -- 4. A mano
  -- =========================================================================
  perform public.admin_save_doctor_lead(v_a, jsonb_build_object(
    'name', 'Dra. Encargada Uno', 'phone', '04147200001', 'assigned_to', v_jefe));
  select * into v_l from public.doctor_leads where id = v_a;
  if v_l.call_owner is distinct from v_jefe or v_l.message_owner is distinct from v_lis then
    raise exception '4. cambiar el encargado a mano no movió el de su fase: %', row_to_json(v_l);
  end if;

  -- =========================================================================
  -- 5. Sin equipo en la fase, sigue con quien lo llevaba
  -- =========================================================================
  perform public.admin_set_agenda_phases(v_carlos, array[]::text[]);
  perform public.admin_log_doctor_lead_contact(v_a, 'visita_agendada', 'llamada', null, v_manana);
  -- Ya tuvo a Carlos en Visita: vuelve a él aunque no esté en el equipo.
  if (select assigned_to from public.doctor_leads where id = v_a) is distinct from v_carlos then
    raise exception '5. la visita debía volver a quien ya la llevó';
  end if;
  perform public.admin_log_doctor_lead_contact(v_b, 'visita_agendada', 'llamada', null, v_manana);
  select * into v_l from public.doctor_leads where id = v_b;
  if v_l.assigned_to not in (v_juan, v_juan2) or v_l.visit_owner is distinct from v_l.assigned_to then
    raise exception '5. sin equipo en Visita debía seguir con quien lo llamaba: %', row_to_json(v_l);
  end if;

  -- =========================================================================
  -- 6. «Asignarme médicos»: solo por contactar
  -- =========================================================================
  update public.doctor_leads set assigned_to = null where id = v_b;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_lis::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_n := public.admin_assign_me_doctor_leads(20);
  if (select assigned_to from public.doctor_leads where id = v_b) is not null then
    raise exception '6. Lis (de Mensaje) se llevó un médico de Visita';
  end if;
  if exists (
    select 1 from public.doctor_leads where assigned_to = v_lis and status <> 'nuevo'
       and id not in (v_a, v_b) and updated_at >= now() - interval '1 minute'
       and stage <> 'mensaje'
  ) then
    raise exception '6. a Lis le tocaron médicos que no son por contactar';
  end if;

  -- =========================================================================
  -- 7. Lo que hizo cada persona
  -- =========================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_jefe::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  select count(*) into v_n from public.admin_agenda_activity_by_person() p
   where p.user_id = v_jefe and p.interesados = 2 and p.visitas_agendadas = 3 and p.mensajes = 2;
  if v_n <> 1 then
    raise exception '7. lo hecho no se cuenta por quien lo anotó: %',
      (select json_agg(p) from public.admin_agenda_activity_by_person() p where p.user_id = v_jefe);
  end if;
end;
$$;

rollback;
