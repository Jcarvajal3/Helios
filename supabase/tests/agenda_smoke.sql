-- ============================================================================
-- Helios — La agenda de médicos por afiliar (20261022200000)
--
--   bash supabase/tests/run.sh agenda_smoke
--
-- Se comprueba que:
--   1. Alguien de fuera del equipo no lee la agenda ni apunta (42501).
--   2. Apuntar normaliza el teléfono, valida y rechaza un teléfono repetido.
--   3. Las gestiones siguen el árbol del equipo (mensaje, llamada, visita;
--      20261022210000): el estado sale del resultado, la visita pide fecha y
--      se pospone, se realiza o se cancela, volver atrás antes de la visita la
--      anula, y todo queda en la historia y en audit.admin_actions.
--   4. Cuando el médico llena el formulario de afiliación, su lead pasa solo a
--      afiliado (por teléfono o por nombre, con o sin «Dra.»), y al aprobarse
--      la solicitud queda enlazado con su clínica.
--   5. Apuntar a alguien que ya es cliente lo deja afiliado de entrada.
--   6. Borrar quita el lead y su historia y deja la bitácora.
--
-- No manda nada: no llama a `helios_dispatch_*`.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_extrano uuid := gen_random_uuid();
  v_hoy     date := public.helios_business_date(now());
  v_manana  timestamptz := ((public.helios_business_date(now()) + 1)::timestamp + time '10:30') at time zone 'America/Caracas';
  v_res     jsonb;
  v_j       jsonb;
  v_l       jsonb;
  v_ana     uuid;
  v_luis    uuid;
  v_eva     uuid;
  v_app     uuid;
  v_m       uuid;
  v_n       integer;
  v_fallo   boolean;
  v_lead    public.doctor_leads%rowtype;
  v_datos   jsonb := jsonb_build_object(
    'owner_name', 'Ana María Pérez Agenda',
    'owner_document', 'V12345601',
    'tax_id', '',
    'specialty', 'Odontología',
    'clinic_name', 'Consultorio Dental Agenda',
    'address', 'Av. Principal, Torre Médica, piso 3',
    'phone', '0414 700 0001',
    'email', 'ana.agenda@example.com',
    'account_holder', 'Ana María Pérez Agenda',
    'holder_document', 'V12345601',
    'bank', 'Banesco',
    'account_number', '0134 0000 0000 0000 0001');
begin
  v_admin := pg_temp.prueba_admin();

  -- =========================================================================
  -- 1. Fuera del equipo
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_extrano::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_doctor_leads();
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '1. alguien de fuera del equipo leyó la agenda'; end if;

  v_fallo := false;
  begin
    perform public.admin_save_doctor_lead(null, '{"name":"Dr. Intruso Pérez"}');
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then raise exception '1. alguien de fuera del equipo apuntó un médico'; end if;

  -- El admin sí, con el rol de la API.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform public.admin_doctor_leads();

  -- Desde aquí, como dueño de la transacción (para leer las tablas) y con los
  -- claims del admin.
  reset role;

  -- =========================================================================
  -- 2. Apuntar
  -- =========================================================================
  v_res := public.admin_save_doctor_lead(null, jsonb_build_object(
    'name', '  Dra.  Ana María   Pérez Agenda ', 'phone', '0414-700-0001',
    'address', 'Torre Médica, Caracas', 'source', 'referido', 'assigned_to', v_admin));
  v_ana := (v_res ->> 'id')::uuid;
  select * into v_lead from public.doctor_leads where id = v_ana;
  if v_lead.phone <> '+584147000001' or v_lead.name <> 'Dra. Ana María Pérez Agenda'
     or v_lead.status <> 'nuevo' or v_lead.name_key <> 'ana maria perez agenda' then
    raise exception '2. el lead no quedó normalizado: %', row_to_json(v_lead);
  end if;

  v_luis := (public.admin_save_doctor_lead(null, jsonb_build_object(
    'name', 'Dr. Luis Gómez Agenda', 'phone', '0212 555 0002', 'email', 'luis.agenda@example.com')) ->> 'id')::uuid;
  v_eva := (public.admin_save_doctor_lead(null, jsonb_build_object(
    'name', 'Eva Rojas Agenda', 'phone', '04147000003')) ->> 'id')::uuid;

  v_fallo := false;
  begin
    perform public.admin_save_doctor_lead(null, '{"name":"Otro Médico","phone":"+58 414 700 0001"}');
  exception when sqlstate '23505' then v_fallo := true;
  end;
  if not v_fallo then raise exception '2. aceptó un teléfono repetido'; end if;

  v_fallo := false;
  begin
    perform public.admin_save_doctor_lead(null, '{"name":"Otro Médico","phone":"123"}');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '2. aceptó un teléfono que no es venezolano'; end if;

  v_fallo := false;
  begin
    perform public.admin_save_doctor_lead(null, '{"name":"  "}');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '2. aceptó un médico sin nombre'; end if;

  v_fallo := false;
  begin
    perform public.admin_save_doctor_lead(null, jsonb_build_object('name', 'Otro Médico', 'assigned_to', v_extrano));
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '2. aceptó un responsable que no es del equipo'; end if;

  -- Corregir no choca consigo mismo.
  perform public.admin_save_doctor_lead(v_luis, jsonb_build_object(
    'name', 'Dr. Luis Gómez Agenda', 'phone', '0212 555 0002', 'email', 'luis.agenda@example.com',
    'city', 'Valencia'));
  if (select city from public.doctor_leads where id = v_luis) <> 'Valencia' then
    raise exception '2. no se guardó la corrección';
  end if;

  v_j := public.admin_doctor_leads();
  select e into v_l from jsonb_array_elements(v_j) e where e ->> 'id' = v_ana::text;
  if v_l is null or v_l ->> 'assigned_name' <> 'Admin de prueba' or (v_l ->> 'activities_count')::int <> 1 then
    raise exception '2. el tablero no trae el lead como se apuntó: %', v_l;
  end if;

  -- =========================================================================
  -- 3. Gestiones (el árbol: mensaje, llamada, visita)
  -- =========================================================================
  v_fallo := false;
  begin
    perform public.admin_log_doctor_lead_contact(v_ana, 'reunion', 'llamada');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó un resultado desconocido'; end if;

  v_fallo := false;
  begin
    perform public.admin_log_doctor_lead_contact(v_ana, 'visita_agendada', 'visita', 'Quiere conocernos');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. agendó una visita sin fecha'; end if;

  v_fallo := false;
  begin
    perform public.admin_log_doctor_lead_contact(v_ana, 'visita_agendada', 'visita', null, now() - interval '2 days');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. agendó una visita en el pasado'; end if;

  v_fallo := false;
  begin
    perform public.admin_log_doctor_lead_contact(v_ana, 'visita_realizada', 'visita');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. dio por realizada una visita que no estaba agendada'; end if;

  v_fallo := false;
  begin
    perform public.admin_log_doctor_lead_contact(v_ana, 'nota');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó una nota vacía'; end if;

  v_fallo := false;
  begin
    perform public.admin_log_doctor_lead_contact(v_ana, 'no_contesto', 'llamada', null, null, null, null, v_hoy - 1);
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó volver a llamar ayer'; end if;

  v_fallo := false;
  begin
    perform public.admin_log_doctor_lead_contact(v_ana, 'no_contesto', 'llamada', null, v_manana);
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. aceptó una fecha de visita en una llamada'; end if;

  -- Llamada: no contestó y ocupado; mensaje: contestó, interesado.
  perform public.admin_log_doctor_lead_contact(v_luis, 'no_contesto', 'llamada', null, null, null, null, v_hoy + 2);
  select * into v_lead from public.doctor_leads where id = v_luis;
  if v_lead.status <> 'no_respondio' or v_lead.next_contact_on <> v_hoy + 2 then
    raise exception '3. «no contestó» no dejó el lead en no respondió: %', row_to_json(v_lead);
  end if;
  perform public.admin_log_doctor_lead_contact(v_luis, 'ocupado', 'llamada');
  perform public.admin_log_doctor_lead_contact(v_luis, 'interesado', 'mensaje', 'Quiere saber más');
  if (select status from public.doctor_leads where id = v_luis) <> 'respondio' then
    raise exception '3. «interesado» no dejó el lead en respondió';
  end if;

  -- Visita: agendada, una nota, pospuesta y realizada.
  perform public.admin_log_doctor_lead_contact(
    v_luis, 'visita_agendada', 'visita', 'Nos vemos en su consultorio', v_manana, 'presencial', 'Torre Médica, piso 3');
  select * into v_lead from public.doctor_leads where id = v_luis;
  if v_lead.status <> 'reunion' or v_lead.meeting_at <> v_manana or v_lead.meeting_place <> 'Torre Médica, piso 3'
     or v_lead.next_contact_on is not null then
    raise exception '3. la visita no quedó agendada: %', row_to_json(v_lead);
  end if;

  perform public.admin_log_doctor_lead_contact(v_luis, 'nota', null, 'Confirmó la hora');
  select * into v_lead from public.doctor_leads where id = v_luis;
  if v_lead.meeting_at <> v_manana or v_lead.status <> 'reunion' then
    raise exception '3. una nota cambió la visita: %', row_to_json(v_lead);
  end if;

  v_fallo := false;
  begin
    perform public.admin_log_doctor_lead_contact(v_luis, 'visita_pospuesta', 'visita', null, v_manana);
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then raise exception '3. pospuso la visita a la misma hora'; end if;

  perform public.admin_log_doctor_lead_contact(v_luis, 'visita_pospuesta', 'visita', null, v_manana + interval '1 day');
  select * into v_lead from public.doctor_leads where id = v_luis;
  if v_lead.meeting_at <> v_manana + interval '1 day' or v_lead.meeting_place <> 'Torre Médica, piso 3' then
    raise exception '3. la visita no se pospuso: %', row_to_json(v_lead);
  end if;
  if not exists (
    select 1 from public.admin_doctor_lead_activities(v_luis) h
     where h.result = 'visita_pospuesta' and h.note like '(Antes era el %'
  ) then
    raise exception '3. la historia no dice cuándo era la visita pospuesta';
  end if;

  perform public.admin_log_doctor_lead_contact(v_luis, 'visita_realizada', 'visita', 'Le gustó');
  select * into v_lead from public.doctor_leads where id = v_luis;
  if v_lead.status <> 'visitado' or v_lead.meeting_at <> v_manana + interval '1 day' then
    raise exception '3. la visita realizada no quedó: %', row_to_json(v_lead);
  end if;

  -- Otra visita, cancelada: vuelve a interesado y sin visita.
  perform public.admin_log_doctor_lead_contact(v_luis, 'visita_agendada', 'visita', null, v_manana);
  perform public.admin_log_doctor_lead_contact(v_luis, 'visita_cancelada', 'visita', 'Se enfermó');
  select * into v_lead from public.doctor_leads where id = v_luis;
  if v_lead.status <> 'respondio' or v_lead.meeting_at is not null then
    raise exception '3. la visita cancelada no se quitó: %', row_to_json(v_lead);
  end if;

  -- Y otra: «no interesado» antes de la visita la anula.
  perform public.admin_log_doctor_lead_contact(v_luis, 'visita_agendada', 'visita', null, v_manana);
  perform public.admin_log_doctor_lead_contact(v_luis, 'no_interesado', 'llamada', 'Ya trabaja con otra empresa');
  select * into v_lead from public.doctor_leads where id = v_luis;
  if v_lead.status <> 'descartado' or v_lead.meeting_at is not null or v_lead.meeting_place is not null then
    raise exception '3. la visita no se anuló al quedar no interesado: %', row_to_json(v_lead);
  end if;

  select count(*) into v_n from public.admin_doctor_lead_activities(v_luis);
  if v_n <> 12 then raise exception '3. la historia de Luis debía tener 12 líneas, tiene %', v_n; end if;
  if not exists (
    select 1 from public.admin_doctor_lead_activities(v_luis) h
     where h.result = 'no_interesado' and h.status_to = 'descartado'
       and h.note like 'Ya trabaja con otra empresa (Se anuló la visita del %'
  ) then
    raise exception '3. la historia no dice que se anuló la visita';
  end if;
  select count(*) into v_n from audit.admin_actions
   where target_id = v_luis and action = 'doctor_lead.contact';
  if v_n <> 11 then raise exception '3. la bitácora debía tener 11 gestiones de Luis, tiene %', v_n; end if;

  v_j := public.admin_doctor_leads();
  select e into v_l from jsonb_array_elements(v_j) e where e ->> 'id' = v_luis::text;
  if v_l -> 'last_activity' ->> 'result' <> 'no_interesado' then
    raise exception '3. el tablero no trae el resultado de la última gestión: %', v_l -> 'last_activity';
  end if;

  perform public.admin_log_doctor_lead_contact(v_ana, 'interesado', 'mensaje', 'Le interesa');

  -- =========================================================================
  -- 4. El formulario de afiliación
  -- =========================================================================
  reset role;
  set local role anon;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.headers', '{"x-forwarded-for":"203.0.113.77","user-agent":"agenda"}', true);
  v_res := public.helios_solicitar_afiliacion(v_datos);
  -- Eva llena el formulario con otro teléfono: se la reconoce por el nombre.
  perform set_config('request.headers', '{"x-forwarded-for":"203.0.113.78","user-agent":"agenda"}', true);
  perform public.helios_solicitar_afiliacion(v_datos || jsonb_build_object(
    'owner_name', 'Dra. Eva Rojas Agenda', 'owner_document', 'V12345602', 'holder_document', 'V12345602',
    'account_holder', 'Eva Rojas Agenda', 'clinic_name', 'Consultorio Eva Agenda',
    'phone', '0212 555 9999', 'email', 'eva.agenda@example.com'));
  reset role;

  select id into v_app from public.merchant_applications where email = 'ana.agenda@example.com';
  select * into v_lead from public.doctor_leads where id = v_ana;
  if v_lead.status <> 'convertido' or v_lead.merchant_application_id <> v_app
     or v_lead.converted_via <> 'formulario' or v_lead.match_reason <> 'telefono' then
    raise exception '4. Ana no quedó afiliada por el formulario: %', row_to_json(v_lead);
  end if;
  select * into v_lead from public.doctor_leads where id = v_eva;
  if v_lead.status <> 'convertido' or v_lead.match_reason <> 'nombre' then
    raise exception '4. Eva no se reconoció por el nombre: %', row_to_json(v_lead);
  end if;
  -- Luis no llenó nada.
  if (select status from public.doctor_leads where id = v_luis) <> 'descartado' then
    raise exception '4. Luis cambió de estado sin llenar el formulario';
  end if;
  if not exists (
    select 1 from public.doctor_lead_activities
     where lead_id = v_ana and kind = 'conversion' and actor is null
       and note = 'Llenó el formulario de afiliación. Se reconoció por su teléfono.'
  ) then
    raise exception '4. la historia de Ana no cuenta la afiliación';
  end if;

  -- Se aprueba: el lead queda con su clínica.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_res := public.admin_approve_merchant_application(v_app);
  select merchant_id into v_m from public.merchant_applications where id = v_app;
  if (select merchant_id from public.doctor_leads where id = v_ana) is distinct from v_m then
    raise exception '4. el lead de Ana no quedó enlazado con su clínica';
  end if;
  select count(*) into v_n from public.doctor_lead_activities where lead_id = v_ana and kind = 'conversion';
  if v_n <> 2 then raise exception '4. Ana debía tener 2 líneas de afiliación (solicitud y alta), tiene %', v_n; end if;

  -- =========================================================================
  -- 5. Ya era cliente
  -- =========================================================================
  v_res := public.admin_save_doctor_lead(null, jsonb_build_object(
    'name', 'Secretaria de Ana', 'email', 'ANA.AGENDA@example.com', 'phone', '0414 700 0099'));
  if v_res ->> 'status' <> 'convertido' or v_res ->> 'merchant_name' is null then
    raise exception '5. un lead que ya es cliente no salió afiliado: %', v_res;
  end if;
  if (select converted_via from public.doctor_leads where id = (v_res ->> 'id')::uuid) <> 'agenda' then
    raise exception '5. la afiliación debía venir de la agenda';
  end if;

  -- =========================================================================
  -- 6. Borrar
  -- =========================================================================
  perform public.admin_delete_doctor_lead(v_luis);
  if exists (select 1 from public.doctor_leads where id = v_luis)
     or exists (select 1 from public.doctor_lead_activities where lead_id = v_luis) then
    raise exception '6. el lead o su historia siguen ahí';
  end if;
  if not exists (
    select 1 from audit.admin_actions
     where target_id = v_luis and action = 'doctor_lead.deleted' and detail ->> 'lead_name' = 'Dr. Luis Gómez Agenda'
  ) then
    raise exception '6. el borrado no quedó en la bitácora';
  end if;

  v_fallo := false;
  begin
    perform public.admin_delete_doctor_lead(v_luis);
  exception when sqlstate 'P0002' then v_fallo := true;
  end;
  if not v_fallo then raise exception '6. borró dos veces lo mismo'; end if;
end;
$$;

rollback;
