-- ============================================================================
-- Helios — El QR agenda la capacitación (20261026233000)
--
--   bash supabase/tests/run.sh agenda_qr_smoke
--
-- Se comprueba que:
--   1. `helios_agendar_capacitacion` la puede llamar anon y valida lo mismo
--      que la página: nombre, teléfono venezolano, especialidad, dirección y
--      la capacitación de mañana a 90 días (22023).
--   2. Un médico que no estaba nace en la agenda con origen `qr`, la visita a
--      esa hora, presencial, en su consultorio, y su historia.
--   3. Uno que ya estaba (mismo teléfono) no se duplica: su lead pasa a la
--      visita, conserva sus datos y la historia dice lo que dejó.
--   4. El campo trampa no escribe nada.
--   5. El tablero devuelve la capacitación en `application_training_at`.
--
-- No manda nada: no llama a `helios_dispatch_*`.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin  uuid;
  v_capa   timestamptz := ((public.helios_business_date(now()) + 3)::timestamp + time '09:00') at time zone 'America/Caracas';
  v_hoy    timestamptz := ((public.helios_business_date(now()))::timestamp + time '18:00') at time zone 'America/Caracas';
  v_lejos  timestamptz := ((public.helios_business_date(now()) + 91)::timestamp + time '09:00') at time zone 'America/Caracas';
  v_datos  jsonb;
  v_viejo  uuid;
  v_lead   public.doctor_leads%rowtype;
  v_n      integer;
  v_fallo  boolean;
  v_j      jsonb;
begin
  v_datos := jsonb_build_object(
    'name', 'Dra. Carla QR Prueba',
    'phone', '0414 700 0901',
    'specialty', 'Pediatría',
    'address', 'Av. Miranda, Torre QR, piso 3',
    'training_at', v_capa::text);

  -- Un lead que el equipo ya tenía, con otro teléfono del QR.
  insert into public.doctor_leads (name, clinic_name, phone, source, status)
  values ('Luis QR Prueba', 'Consultorio de Luis', '+584147000902', 'referido', 'contactado')
  returning id into v_viejo;

  -- =========================================================================
  -- 1. Lo que no vale
  -- =========================================================================
  set local role anon;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);

  foreach v_j in array array[
    v_datos || '{"name": "Al"}',
    v_datos || '{"phone": "123"}',
    v_datos || '{"specialty": " "}',
    v_datos || '{"address": "Av"}',
    v_datos - 'training_at',
    v_datos || jsonb_build_object('training_at', v_hoy::text),
    v_datos || jsonb_build_object('training_at', v_lejos::text),
    v_datos || '{"training_at": "mañana"}'
  ] loop
    v_fallo := false;
    begin
      perform public.helios_agendar_capacitacion(v_j);
    exception when sqlstate '22023' then
      v_fallo := true;
    end;
    if not v_fallo then raise exception '1. aceptó %', v_j; end if;
  end loop;

  -- =========================================================================
  -- 4. El campo trampa
  -- =========================================================================
  perform public.helios_agendar_capacitacion(v_datos || '{"sitio_web": "spam.com"}');

  -- =========================================================================
  -- 2. Un médico nuevo
  -- =========================================================================
  perform public.helios_agendar_capacitacion(v_datos);
  -- 3. Luis, que ya estaba, por su teléfono.
  perform public.helios_agendar_capacitacion(v_datos || jsonb_build_object(
    'name', 'Luis Alberto QR', 'phone', '0414-700-0902', 'specialty', 'Odontología',
    'address', 'Calle Real de Sabana Grande'));
  reset role;

  select count(*) into v_n from public.doctor_leads where phone = '+584147000901';
  if v_n <> 1 then raise exception '2/4. Carla está % veces', v_n; end if;

  select * into v_lead from public.doctor_leads where phone = '+584147000901';
  if v_lead.source <> 'qr' or v_lead.status <> 'reunion' or v_lead.meeting_at <> v_capa
     or v_lead.meeting_mode <> 'presencial' or v_lead.meeting_place <> 'Av. Miranda, Torre QR, piso 3'
     or v_lead.training_at <> v_capa or v_lead.specialty <> 'Pediatría'
     or v_lead.name <> 'Dra. Carla QR Prueba' then
    raise exception '2. Carla quedó mal: %', row_to_json(v_lead);
  end if;
  if not exists (select 1 from public.doctor_lead_activities
                  where lead_id = v_lead.id and kind = 'creado' and status_to = 'reunion'
                    and meeting_at = v_capa and note like 'Agendó su capacitación presencial con el QR%') then
    raise exception '2. Carla no tiene su historia';
  end if;

  select count(*) into v_n from public.doctor_leads where phone = '+584147000902';
  if v_n <> 1 then raise exception '3. Luis está % veces', v_n; end if;
  select * into v_lead from public.doctor_leads where id = v_viejo;
  if v_lead.name <> 'Luis QR Prueba' or v_lead.source <> 'referido' or v_lead.status <> 'reunion'
     or v_lead.meeting_at <> v_capa or v_lead.meeting_place <> 'Calle Real de Sabana Grande'
     or v_lead.specialty <> 'Odontología' or v_lead.clinic_name <> 'Consultorio de Luis' then
    raise exception '3. Luis quedó mal: %', row_to_json(v_lead);
  end if;
  if not exists (select 1 from public.doctor_lead_activities
                  where lead_id = v_viejo and kind = 'gestion' and result = 'visita_agendada'
                    and status_from = 'contactado' and status_to = 'reunion'
                    and note like '%Luis Alberto QR%Odontología%') then
    raise exception '3. la historia de Luis no dice lo que dejó';
  end if;

  -- =========================================================================
  -- 5. El tablero
  -- =========================================================================
  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  select e into v_j from jsonb_array_elements(public.admin_doctor_leads()) e
   where e->>'id' = v_viejo::text;
  reset role;
  if (v_j->>'application_training_at')::timestamptz is distinct from v_capa then
    raise exception '5. el tablero no trae la capacitación: %', v_j;
  end if;
end;
$$;

rollback;
