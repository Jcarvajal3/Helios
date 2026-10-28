-- ============================================================================
-- Helios — La agenda por fases y «Asignarme médicos» (20261028150000)
--
--   bash supabase/tests/run.sh agenda_fases_smoke
--
-- Se comprueba que:
--   1. La fase sale del estado: mensaje (por contactar, mensaje enviado),
--      llamada (interesado = por llamar), visita (visita agendada, afiliado),
--      y «no contestó» / «no interesado» se quedan en la fase en que pasan.
--   2. Una visita cancelada vuelve a Llamada; una realizada lo deja afiliado.
--   3. El tablero devuelve la fase.
--   4. «Asignarme médicos» solo toma los que no tienen a nadie y siguen
--      abiertos, no toca a los de otra persona, respeta el tope y queda en la
--      bitácora. Fuera del equipo, no.
--
-- No manda nada: no llama a `helios_dispatch_*`.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_otro    uuid;
  v_extrano uuid := gen_random_uuid();
  v_manana  timestamptz := ((public.helios_business_date(now()) + 1)::timestamp + time '10:30') at time zone 'America/Caracas';
  v_a       uuid;
  v_b       uuid;
  v_libre   uuid;
  v_cerrado uuid;
  v_ajeno   uuid;
  v_n       integer;
  v_fase    text;
  v_l       jsonb;
  v_fallo   boolean;
begin
  v_admin := pg_temp.prueba_admin();
  v_otro := pg_temp.prueba_admin();
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- =========================================================================
  -- 1. La fase sale del estado
  -- =========================================================================
  v_a := (public.admin_save_doctor_lead(null, '{"name":"Dra. Fase Mensaje","phone":"04147100001"}') ->> 'id')::uuid;
  select stage into v_fase from public.doctor_leads where id = v_a;
  if v_fase <> 'mensaje' then raise exception '1. un médico nuevo debía estar en Mensaje: %', v_fase; end if;

  perform public.admin_log_doctor_lead_contact(v_a, 'mensaje_enviado', 'mensaje');
  perform public.admin_log_doctor_lead_contact(v_a, 'no_contesto', 'mensaje');
  select stage into v_fase from public.doctor_leads where id = v_a;
  if v_fase <> 'mensaje' then raise exception '1. «no contestó» al mensaje debía seguir en Mensaje: %', v_fase; end if;

  perform public.admin_log_doctor_lead_contact(v_a, 'interesado', 'mensaje');
  select stage into v_fase from public.doctor_leads where id = v_a;
  if v_fase <> 'llamada' then raise exception '1. el interesado debía pasar a Llamada: %', v_fase; end if;

  perform public.admin_log_doctor_lead_contact(v_a, 'no_contesto', 'llamada');
  select stage into v_fase from public.doctor_leads where id = v_a;
  if v_fase <> 'llamada' then raise exception '1. «no contestó» a la llamada debía seguir en Llamada: %', v_fase; end if;

  perform public.admin_log_doctor_lead_contact(v_a, 'visita_agendada', 'llamada', null, v_manana);
  select stage into v_fase from public.doctor_leads where id = v_a;
  if v_fase <> 'visita' then raise exception '1. la visita agendada debía pasar a Visita: %', v_fase; end if;

  -- «No interesado» en Mensaje se queda en Mensaje.
  v_b := (public.admin_save_doctor_lead(null, '{"name":"Dr. Fase Descartado","phone":"04147100002"}') ->> 'id')::uuid;
  perform public.admin_log_doctor_lead_contact(v_b, 'no_interesado', 'mensaje');
  select stage into v_fase from public.doctor_leads where id = v_b;
  if v_fase <> 'mensaje' then raise exception '1. «no interesado» al mensaje debía seguir en Mensaje: %', v_fase; end if;

  -- =========================================================================
  -- 2. Cancelada vuelve a Llamada; realizada es afiliado
  -- =========================================================================
  perform public.admin_log_doctor_lead_contact(v_a, 'visita_cancelada', 'visita');
  if (select stage from public.doctor_leads where id = v_a) <> 'llamada'
     or (select status from public.doctor_leads where id = v_a) <> 'respondio' then
    raise exception '2. la visita cancelada debía volver a Llamada como por llamar';
  end if;

  perform public.admin_log_doctor_lead_contact(v_a, 'visita_agendada', 'llamada', null, v_manana);
  perform public.admin_log_doctor_lead_contact(v_a, 'visita_realizada', 'visita', 'Capacitado');
  if (select status from public.doctor_leads where id = v_a) <> 'convertido'
     or (select converted_via from public.doctor_leads where id = v_a) <> 'visita'
     or (select stage from public.doctor_leads where id = v_a) <> 'visita' then
    raise exception '2. la visita realizada debía dejarlo afiliado en Visita: %',
      (select row_to_json(l) from public.doctor_leads l where id = v_a);
  end if;

  -- =========================================================================
  -- 3. El tablero devuelve la fase
  -- =========================================================================
  select e into v_l from jsonb_array_elements(public.admin_doctor_leads()) e where e ->> 'id' = v_b::text;
  if v_l ->> 'stage' <> 'mensaje' then raise exception '3. el tablero no trae la fase: %', v_l; end if;

  -- =========================================================================
  -- 4. Asignarme médicos
  -- =========================================================================
  -- Uno libre y abierto, uno libre pero afiliado, y uno de otra persona.
  v_libre := (public.admin_save_doctor_lead(null, '{"name":"Dr. Fase Libre","phone":"04147100003"}') ->> 'id')::uuid;
  v_cerrado := (public.admin_save_doctor_lead(null, '{"name":"Dra. Fase Cerrada","phone":"04147100004"}') ->> 'id')::uuid;
  perform public.admin_log_doctor_lead_contact(v_cerrado, 'afiliado', null);
  v_ajeno := (public.admin_save_doctor_lead(null, jsonb_build_object(
    'name', 'Dr. Fase Ajeno', 'phone', '04147100005', 'assigned_to', v_otro)) ->> 'id')::uuid;

  v_fallo := false;
  begin
    perform public.admin_assign_me_doctor_leads(0);
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '4. aceptó pedir cero médicos'; end if;

  -- El tope: uno solo.
  v_n := public.admin_assign_me_doctor_leads(1);
  if v_n <> 1 then raise exception '4. con tope 1 debía asignar 1, asignó %', v_n; end if;

  -- El resto de los libres y abiertos (los reales también, dentro de esta
  -- transacción que se deshace).
  perform public.admin_assign_me_doctor_leads(100);
  if (select assigned_to from public.doctor_leads where id = v_libre) is distinct from v_admin then
    raise exception '4. el médico libre y abierto no quedó asignado';
  end if;
  if (select assigned_to from public.doctor_leads where id = v_cerrado) is not null then
    raise exception '4. se asignó un médico ya afiliado';
  end if;
  if (select assigned_to from public.doctor_leads where id = v_ajeno) is distinct from v_otro then
    raise exception '4. se le quitó el médico a otra persona';
  end if;
  if exists (
    select 1 from public.doctor_leads where assigned_to is null and status not in ('convertido', 'descartado')
  ) then
    raise exception '4. quedaron médicos abiertos sin asignar';
  end if;
  if public.admin_assign_me_doctor_leads(20) <> 0 then
    raise exception '4. sin médicos libres debía asignar 0';
  end if;
  if not exists (
    select 1 from audit.admin_actions where actor = v_admin and action = 'doctor_lead.assigned'
  ) then
    raise exception '4. la asignación no quedó en la bitácora';
  end if;

  -- Fuera del equipo, no.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_extrano::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_assign_me_doctor_leads(20);
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '4. alguien de fuera del equipo se asignó médicos'; end if;
end;
$$;

rollback;
