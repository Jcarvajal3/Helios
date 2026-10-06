-- ============================================================================
-- Helios — Prueba de humo del bot del paciente (20261006000100)
--
--   bash supabase/tests/run.sh paciente_bot_smoke
--
--  1. Los montos al estilo venezolano.
--  2. El contexto de un número: el paciente, el menú reciente (2 h) y la
--     persona que atiende (24 h; 0 la despierta).
--  3. El resumen: financiamientos activos, cuotas pendientes con el cargo por
--     atraso y si están vencidas, tasa, cuentas y pago en revisión.
--  4. Un teléfono de dos pacientes: nadie elegido hasta que se identifica.
--  5. Los mensajes del bot del paciente: solo con la ventana abierta, y
--     también a quien escribe sin ser paciente.
--  6. Solo el webhook (service_role).
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_cajero  uuid := gen_random_uuid();
  v_m       uuid;
  v_bdate   date := public.helios_business_date(now());
  v_pac     jsonb;
  v_charge  uuid;
  v_profile uuid;
  v_otro    uuid;
  v_tel     text := '584147770001';
  v_j       jsonb;
  v_failed  boolean;
  v_msg     uuid;
begin
  update public.platform_maintenance set is_active = false;
  insert into public.business_parameters (key, value, effective_from, note)
  values ('patient_confirmation_required', 0, v_bdate, 'prueba')
  on conflict (key, effective_from) do update set value = 0;

  -- =========================================================================
  -- 1. Los montos
  -- =========================================================================
  if public.helios_money_text(100) <> '100' or public.helios_money_text(1.92) <> '1,92'
     or public.helios_money_text(1250.5) <> '1.250,50' or public.helios_money_text(99.999) <> '100'
     or public.helios_pct_text(12.5) <> '12,5' or public.helios_pct_text(16) <> '16' then
    raise exception 'Los montos al estilo venezolano';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'pb-cajero@prueba.helios.test', now(), now(), '{"full_name":"Ana Secretaria"}');

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_m := (public.admin_create_merchant('Clínica Paciente Bot', null, 'J-400000051', 'clinica')).id;
  reset role;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_m, (select id from public.merchant_branches where merchant_id = v_m and is_default), 'cajero');

  v_pac := jsonb_build_object(
    'document', 'V60000001', 'first_name', 'Javier', 'last_name', 'Pérez',
    'birth_date', (v_bdate - interval '30 years')::date, 'sex', 'M',
    'phone', '04147770001', 'email', 'javier@gmail.com',
    'state', 'Miranda', 'city', 'Caracas', 'address', 'Los Palos Grandes',
    'reference_name', 'María Pérez', 'reference_phone', '02125551234', 'reference_relationship', 'Madre');

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V60000001');
  v_charge := ((public.create_patient_charge(v_m, null, v_pac, 100, null, null, 'pb-key-1'))->>'id')::uuid;
  reset role;
  select user_id into v_profile from public.charges where id = v_charge;

  -- =========================================================================
  -- 2. El contexto
  -- =========================================================================
  v_j := public.bot_paciente_contexto(v_tel);
  if jsonb_array_length(v_j->'perfiles') <> 1 or v_j->'perfiles'->0->>'nombre' <> 'Javier'
     or v_j->'perfiles'->0->>'documento' <> 'V60000001'
     or (v_j->>'humano')::boolean or (v_j->>'menu_reciente')::boolean then
    raise exception 'El contexto de un paciente: %', v_j;
  end if;

  perform public.bot_paciente_guardar(v_tel, p_menu => true);
  if not ((public.bot_paciente_contexto(v_tel))->>'menu_reciente')::boolean then
    raise exception 'Acaba de ver el menú';
  end if;
  update public.whatsapp_contacts set bot_menu_at = now() - interval '3 hours' where phone_e164 = '+' || v_tel;
  if ((public.bot_paciente_contexto(v_tel))->>'menu_reciente')::boolean then
    raise exception 'Pasadas 2 horas, el menú puede volver a salir';
  end if;

  perform public.bot_paciente_guardar(v_tel, p_humano_horas => 24);
  if not ((public.bot_paciente_contexto(v_tel))->>'humano')::boolean then
    raise exception 'Lo atiende una persona durante 24 h';
  end if;
  perform public.bot_paciente_guardar(v_tel, p_humano_horas => 0);
  if ((public.bot_paciente_contexto(v_tel))->>'humano')::boolean then
    raise exception 'Con 0 horas, el bot vuelve';
  end if;

  -- =========================================================================
  -- 3. El resumen
  -- =========================================================================
  v_j := public.bot_paciente_resumen(v_profile);
  if v_j->>'nombre' <> 'Javier' or jsonb_array_length(v_j->'financiamientos') <> 1
     or (v_j->'financiamientos'->0->>'consulta')::numeric <> 100
     or jsonb_array_length(v_j->'financiamientos'->0->'cuotas') <> 2
     or (v_j->'financiamientos'->0->'cuotas'->0->>'monto')::numeric <> 61.60
     or (v_j->'financiamientos'->0->'cuotas'->0->>'vencida')::boolean
     or v_j->>'cuentas_de_cobro' is null or (v_j->>'pago_en_revision')::boolean then
    raise exception 'El resumen del paciente: %', v_j;
  end if;

  update public.installments set due_date = v_bdate - 5 where charge_id = v_charge and sequence = 1;
  insert into public.late_fees (user_id, credit_block_id, amount_usd, days_late, business_date, status, installment_id)
  select v_profile, (select id from public.user_credit_blocks where user_id = v_profile limit 1), 2, 5, v_bdate, 'pending', i.id
  from public.installments i where i.charge_id = v_charge and i.sequence = 1;

  v_j := public.bot_paciente_resumen(v_profile);
  if not (v_j->'financiamientos'->0->'cuotas'->0->>'vencida')::boolean
     or (v_j->'financiamientos'->0->'cuotas'->0->>'cargo_atraso')::numeric <> 2 then
    raise exception 'Una cuota vencida con su cargo: %', v_j;
  end if;

  -- =========================================================================
  -- 4. Un teléfono de dos pacientes
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V60000002');
  perform public.create_patient_charge(v_m, null,
    v_pac || jsonb_build_object('document', 'V60000002', 'first_name', 'Luisa', 'email', 'luisa@gmail.com'),
    20, null, null, 'pb-key-2');
  reset role;
  select id into v_otro from public.profiles where document_key = 'V60000002';

  v_j := public.bot_paciente_contexto(v_tel);
  if jsonb_array_length(v_j->'perfiles') <> 2 or v_j->>'elegido' is not null then
    raise exception 'Con dos pacientes, nadie elegido: %', v_j;
  end if;
  perform public.bot_paciente_guardar(v_tel, p_estado => 'cedula');
  if (public.bot_paciente_contexto(v_tel))->>'estado' <> 'cedula' then
    raise exception 'Esperando la cédula';
  end if;
  perform public.bot_paciente_guardar(v_tel, p_estado => '', p_profile_id => v_otro);
  v_j := public.bot_paciente_contexto(v_tel);
  if v_j->>'elegido' <> v_otro::text or v_j->>'estado' is not null then
    raise exception 'Identificada por su cédula: %', v_j;
  end if;

  -- =========================================================================
  -- 5. Los mensajes del bot del paciente
  -- =========================================================================
  delete from public.whatsapp_contacts where phone_e164 = '+584147779999';
  v_failed := false;
  begin
    perform public.helios_whatsapp_patient_text('584147779999', 'hola', null);
  exception when others then v_failed := true; end;
  if not v_failed then
    raise exception 'Fuera de la ventana, el bot no escribe';
  end if;

  insert into public.whatsapp_contacts (phone_e164, last_inbound_at) values ('+584147779999', now());
  v_msg := public.helios_whatsapp_patient_text('584147779999', 'Gracias por escribirnos', null,
             '[{"id":"paciente:pagar","title":"Pagar cuota"}]');
  if not exists (select 1 from public.outbound_messages
                  where id = v_msg and template_key = 'bot_paciente' and profile_id is null
                    and channel = 'whatsapp' and wa_template->'buttons'->0->>'id' = 'paciente:pagar') then
    raise exception 'El mensaje a alguien que no es paciente debía encolarse';
  end if;
  if jsonb_array_length((public.bot_paciente_contexto('584147779999'))->'perfiles') <> 0 then
    raise exception 'Un número sin pacientes';
  end if;

  -- =========================================================================
  -- 6. Solo el webhook
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.bot_paciente_resumen(v_profile);
  exception when insufficient_privilege then v_failed := true; end;
  reset role;
  if not v_failed then
    raise exception 'La clínica no lee el resumen del paciente';
  end if;
end;
$$;

set constraints all immediate;

rollback;
