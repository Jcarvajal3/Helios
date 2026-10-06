-- ============================================================================
-- Helios — Prueba de humo del «Sí» del paciente (docs/00 §5.1, docs/01 §1.3.1)
--
--   bash supabase/tests/run.sh patient_confirmation_smoke
--
-- Con `patient_confirmation_required` = 1 (20261005000300):
--   1. Sin la API de WhatsApp configurada no se registra (si no hay claves).
--   2. La orden nace pendiente: sin cuotas, asiento, comisión ni comprobante;
--      la pregunta va al teléfono registrado, con el cargo por servicio
--      desglosado y sin un total con el fee; la respuesta trae el plazo, el
--      plan de cuotas y la confirmación por enviar.
--   3. La reserva de cupo: otra clínica ve el disponible descontado y no
--      puede registrar otra orden mientras esta espera.
--   4. Un «Sí» desde otro teléfono no vale.
--   5. El «Sí» confirma: cuotas desde su business_date, asiento de 4 patas,
--      comisión, comprobante, bienvenida automática; idempotente por mensaje.
--   6. El «No» rechaza, libera el cupo y calla la pregunta pendiente.
--   7. Vencer, reenviar (reabre con plazo nuevo) y el límite de reenvíos.
--   8. Un «Sí» que ya no se puede financiar (lista negra en la espera) se
--      rechaza como no_disponible, sin deuda.
--   9. La lista de la clínica muestra las órdenes con su estado, el canal sale
--      de `helios.canal`, y el webhook es el único que puede decidir.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin    uuid;
  v_gerente  uuid := gen_random_uuid();
  v_cajero   uuid := gen_random_uuid();
  v_otro     uuid := gen_random_uuid();
  v_m        uuid;
  v_otra     uuid;
  v_bdate    date := public.helios_business_date(now());
  v_pac      jsonb;
  v_j        jsonb;
  v_charge   uuid;
  v_charge2  uuid;
  v_charge3  uuid;
  v_charge4  uuid;
  v_profile  uuid;
  v_n        integer;
  v_err      text;
  v_failed   boolean;
  v_row      record;
  v_text     text;
  v_exp      timestamptz;
begin
  -- =========================================================================
  -- Preparación
  -- =========================================================================
  update public.platform_maintenance set is_active = false;
  update public.platform_contact set whatsapp_number = '+584140001122';

  insert into public.business_parameters (key, value, effective_from, note)
  values ('patient_confirmation_required', 1, v_bdate, 'prueba')
  on conflict (key, effective_from) do update set value = 1;

  if not public.helios_patient_confirmation_required() then
    raise exception 'El interruptor debía quedar encendido en la prueba';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  values
    (v_gerente, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'pcf-gerente@prueba.helios.test', now(), now(), '{"full_name":"Laura Gerente"}'),
    (v_cajero,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'pcf-cajero@prueba.helios.test', now(), now(), '{"full_name":"Ana Secretaria"}'),
    (v_otro,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'pcf-otro@prueba.helios.test', now(), now(), '{"full_name":"Otro Gerente"}');

  v_admin := pg_temp.prueba_admin();
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_m    := (public.admin_create_merchant('Clínica Confirma', null, 'J-400000011', 'clinica')).id;
  v_otra := (public.admin_create_merchant('Otra Clínica Confirma', null, 'J-400000012', 'consultorio')).id;
  reset role;

  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_gerente, v_m, (select id from public.merchant_branches where merchant_id = v_m and is_default), 'gerente'),
    (v_cajero,  v_m, (select id from public.merchant_branches where merchant_id = v_m and is_default), 'cajero'),
    (v_otro,    v_otra, (select id from public.merchant_branches where merchant_id = v_otra and is_default), 'gerente');

  v_pac := jsonb_build_object(
    'document', 'V20000001',
    'first_name', 'José', 'last_name', 'Pérez',
    'birth_date', (v_bdate - interval '30 years')::date,
    'sex', 'M', 'phone', '04141234567', 'email', 'jose@gmail.com',
    'state', 'Miranda', 'city', 'Caracas', 'address', 'Los Palos Grandes',
    'reference_name', 'María Pérez', 'reference_phone', '02125551234', 'reference_relationship', 'Madre');

  -- =========================================================================
  -- 1. Sin la API de WhatsApp no hay a quién preguntar
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V20000001');
  reset role;

  if not public.helios_whatsapp_api_ready() then
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
    v_failed := false;
    begin
      perform public.create_patient_charge(v_m, null, v_pac, 100, null, null, 'pcf-sin-api');
    exception when others then
      v_failed := true; v_err := sqlerrm;
    end;
    reset role;
    if not v_failed or v_err not like 'No podemos escribirle a este paciente por WhatsApp%' then
      raise exception 'Sin la API debía rechazarse el registro: %', coalesce(v_err, 'sin error');
    end if;

    perform vault.create_secret('prueba', 'd360_api_key');
    perform vault.create_secret('https://waba-sandbox.360dialog.io/v1', 'd360_base_url');
  end if;

  if not public.helios_whatsapp_api_ready() then
    raise exception 'La API debía quedar lista con los dos secretos';
  end if;

  -- =========================================================================
  -- 2. La orden nace pendiente
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_j := public.create_patient_charge(v_m, null, v_pac, 100, 'Consulta', null, 'pcf-key-1');
  reset role;
  v_charge := (v_j->>'id')::uuid;
  v_exp := (v_j->>'expires_at')::timestamptz;

  if v_j->>'status' <> 'pending' or v_j->>'channel' <> 'panel'
     or v_exp is null or v_exp < now() + interval '119 minutes' or v_exp > now() + interval '121 minutes'
     or jsonb_array_length(v_j->'installments') <> 2
     or (v_j->'installments'->0->>'amount_usd')::numeric <> 61.60
     or (v_j->'installments'->0->>'due_date')::date <> v_bdate + 7
     or (v_j->'installments'->1->>'due_date')::date <> v_bdate + 14
     or v_j->'receipt'->>'status' <> 'sin_enviar'
     or v_j->'confirmation'->>'status' <> 'por_enviar'
     or v_j->'confirmation'->>'telefono_enmascarado' is null
     or (v_j->'confirmation'->>'resends_today')::integer <> 0
     or v_j->>'confirmed_at' is not null
     or (v_j->>'merchant_sale_usd')::numeric <> 100 then
    raise exception 'La orden pendiente no quedó como dice el contrato: %', v_j;
  end if;

  select id into v_profile from public.profiles where document_key = 'V20000001';

  if exists (select 1 from public.installments where charge_id = v_charge)
     or exists (select 1 from ledger.transactions where reference_id = v_charge)
     or exists (select 1 from public.staff_commissions where charge_id = v_charge)
     or exists (select 1 from public.outbound_messages
                 where charge_id = v_charge and template_key in ('comprobante_financiamiento', 'bienvenida')) then
    raise exception 'Una orden pendiente no puede tener deuda, asiento, comisión, comprobante ni bienvenida';
  end if;

  select * into v_row from public.outbound_messages
  where charge_id = v_charge and template_key = 'confirmar_financiamiento';
  if v_row.id is null or v_row.channel <> 'whatsapp' or v_row.recipient <> '+584141234567'
     or v_row.status <> 'pendiente' or v_row.next_attempt_at is null then
    raise exception 'La pregunta al paciente no quedó en la cola: %', to_jsonb(v_row);
  end if;
  v_text := v_row.rendered_text;
  -- Al paciente sí se le enseña el total con el cargo (2026-10-06).
  if v_text not like '👋 Hola, José. Bienvenido a Helios 💙%'
     or v_text not like '%Clínica Confirma registró tu consulta de $100 para pagarla en 2 cuotas, sin inicial.%'
     or v_text not like '%* Consulta: $100%'
     or v_text not like '%* Servicio Helios (20\%): $20%'
     or v_text not like '%* IVA (16\% sobre el servicio): $3,20%'
     or v_text not like '%* Total: $123,20%'
     or v_text not like '%Tus cuotas serán de $61,60:%'
     or v_text not like '%📅 ' || to_char(v_bdate + 7, 'DD/MM') || ' y ' || to_char(v_bdate + 14, 'DD/MM') || '%'
     or v_text like '%{%' then
    raise exception 'El texto de la pregunta no es el esperado: %', v_text;
  end if;

  -- =========================================================================
  -- 3. La reserva de cupo
  -- =========================================================================
  if public.helios_credit_reserved_usd(v_profile) <> 100 or public.helios_credit_used_usd(v_profile) <> 100
     or public.available_usd(v_profile) <> 250 then
    raise exception 'La orden pendiente debía reservar $100: reservado %, usado %, disponible %',
      public.helios_credit_reserved_usd(v_profile), public.helios_credit_used_usd(v_profile),
      public.available_usd(v_profile);
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_otro::text, 'role', 'authenticated')::text, true);
  v_j := public.helios_patient_eligibility(v_otra, 'V20000001');
  if v_j->>'estado' <> 'disponible' or (v_j->>'disponible_usd')::numeric <> 250 then
    raise exception 'Otra clínica debía ver el disponible descontado (250): %', v_j;
  end if;
  v_failed := false;
  begin
    perform public.create_patient_charge(v_otra, null, jsonb_build_object('document', 'V20000001'), 50, null, null, 'pcf-otra');
  exception when others then
    v_failed := true; v_err := sqlerrm;
  end;
  reset role;
  if not v_failed or v_err not like 'Este paciente tiene otra solicitud esperando su respuesta%' then
    raise exception 'Con una orden esperando no se registra otra: %', coalesce(v_err, 'sin error');
  end if;

  -- =========================================================================
  -- 4. Un «Sí» desde otro teléfono no vale
  -- =========================================================================
  v_j := public.helios_patient_decision(v_charge, 'si', '584149999999', 'wamid.otro');
  if (v_j->>'ok')::boolean or v_j->>'reason' <> 'otro_telefono'
     or (select status::text from public.charges where id = v_charge) <> 'pending' then
    raise exception 'Un «Sí» de otro teléfono no podía valer: %', v_j;
  end if;

  v_j := public.helios_patient_decision(v_charge, 'quizas', '584141234567', 'wamid.x');
  if (v_j->>'ok')::boolean or v_j->>'reason' <> 'peticion_invalida' then
    raise exception 'Una decisión que no es si/no debía rechazarse: %', v_j;
  end if;

  -- =========================================================================
  -- 5. El «Sí» confirma
  -- =========================================================================
  v_j := public.helios_patient_decision(v_charge, 'si', '584141234567', 'wamid.si.1');
  if not (v_j->>'ok')::boolean or v_j->>'status' <> 'confirmed' then
    raise exception 'El «Sí» debía confirmar: %', v_j;
  end if;

  select * into v_row from public.charges where id = v_charge;
  if v_row.status <> 'confirmed' or v_row.confirmed_at is null or v_row.answered_at is null
     or v_row.answer_wa_message_id <> 'wamid.si.1' or v_row.business_date <> v_bdate then
    raise exception 'El financiamiento confirmado no quedó bien: %', to_jsonb(v_row);
  end if;

  if (select array_agg(due_date order by sequence) from public.installments where charge_id = v_charge)
       <> array[v_bdate + 7, v_bdate + 14]
     or (select sum(amount_usd) from public.installments where charge_id = v_charge) <> 123.20 then
    raise exception 'Las cuotas debían salir del business_date de la orden';
  end if;

  select count(*) into v_n from ledger.transactions t
  where t.reference_id = v_charge and t.type = 'charge' and t.idempotency_key = 'charge:pcf-key-1'
    and (select count(*) from ledger.entries e where e.transaction_id = t.id) = 4;
  if v_n <> 1 then
    raise exception 'Debía haber un asiento de 4 patas del financiamiento';
  end if;

  if not exists (select 1 from public.staff_commissions where charge_id = v_charge and staff_user_id = v_cajero)
     or not exists (select 1 from public.outbound_messages
                     where charge_id = v_charge and template_key = 'comprobante_financiamiento' and channel = 'email')
     or not exists (select 1 from public.outbound_messages
                     where charge_id = v_charge and template_key = 'bienvenida' and channel = 'whatsapp'
                       and rendered_text like '🩺 ¡Listo, José!%') then
    raise exception 'El «Sí» debía devengar la comisión y encolar comprobante y bienvenida automática';
  end if;

  if public.helios_credit_reserved_usd(v_profile) <> 0 or public.helios_credit_used_usd(v_profile) <> 100 then
    raise exception 'Confirmada, la orden deja de reservar y ocupa por sus cuotas';
  end if;

  -- Un reintento del webhook con el mismo mensaje no confirma dos veces.
  v_j := public.helios_patient_decision(v_charge, 'si', '584141234567', 'wamid.si.1');
  if not (v_j->>'duplicate')::boolean or v_j->>'status' <> 'confirmed'
     or (select count(*) from ledger.transactions where reference_id = v_charge and type = 'charge') <> 1 then
    raise exception 'El reintento debía devolver lo mismo sin tocar nada: %', v_j;
  end if;

  -- Otro mensaje sobre una orden ya confirmada.
  v_j := public.helios_patient_decision(v_charge, 'no', '584141234567', 'wamid.no.tarde');
  if (v_j->>'ok')::boolean or v_j->>'reason' <> 'no_pendiente' then
    raise exception 'Una orden confirmada ya no admite respuesta: %', v_j;
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_j := public.helios_charge_for_staff(v_charge);
  reset role;
  if v_j->'confirmation'->>'status' <> 'aceptada' or v_j->>'expires_at' is not null
     or v_j->'receipt'->>'status' = 'sin_enviar' then
    raise exception 'La clínica debía ver la orden aceptada: %', v_j;
  end if;

  -- =========================================================================
  -- 6. El «No» rechaza
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V20000002');
  v_j := public.create_patient_charge(v_m, null,
           v_pac || jsonb_build_object('document', 'V20000002', 'phone', '04241112233', 'email', 'b@gmail.com'),
           80, null, null, 'pcf-key-2');
  reset role;
  v_charge2 := (v_j->>'id')::uuid;

  v_j := public.helios_patient_decision(v_charge2, 'no', '+58 424 111 22 33', 'wamid.no.2');
  select * into v_row from public.charges where id = v_charge2;
  if not (v_j->>'ok')::boolean or v_row.status <> 'declined' or v_row.decline_reason <> 'paciente'
     or v_row.confirmed_at is not null
     or public.helios_credit_used_usd(v_row.user_id) <> 0
     or exists (select 1 from public.installments where charge_id = v_charge2) then
    raise exception 'El «No» debía rechazar sin deuda y liberar el cupo: % %', v_j, to_jsonb(v_row);
  end if;

  -- =========================================================================
  -- 7. Vencer y reenviar
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V20000003');
  v_j := public.create_patient_charge(v_m, null,
           v_pac || jsonb_build_object('document', 'V20000003', 'phone', '04161112233', 'email', 'c@gmail.com'),
           50, null, null, 'pcf-key-3');
  reset role;
  v_charge3 := (v_j->>'id')::uuid;

  update public.charges set expires_at = now() - interval '1 minute' where id = v_charge3;
  if public.helios_credit_reserved_usd((select user_id from public.charges where id = v_charge3)) <> 0 then
    raise exception 'Una orden pasada de plazo ya no reserva, aunque el cron no haya pasado';
  end if;

  v_n := public.helios_expire_pending_charges();
  if v_n < 1 or (select status::text from public.charges where id = v_charge3) <> 'expired' then
    raise exception 'El cron debía vencer la orden: vencidas %, estado %, vence %, ahora %', v_n,
      (select status::text from public.charges where id = v_charge3),
      (select expires_at from public.charges where id = v_charge3), now();
  end if;

  if (select status from public.outbound_messages
       where charge_id = v_charge3 and template_key = 'confirmar_financiamiento') <> 'cancelado' then
    raise exception 'La pregunta de una orden vencida debía cancelarse';
  end if;

  v_j := public.helios_patient_decision(v_charge3, 'si', '584161112233', 'wamid.tarde');
  if (v_j->>'ok')::boolean or v_j->>'reason' <> 'no_pendiente' then
    raise exception 'Un «Sí» a una orden vencida no vale: %', v_j;
  end if;

  -- Reenviar reabre: plazo nuevo, otra pregunta.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_j := public.staff_resend_confirmation(v_charge3);
  if v_j->>'status' <> 'pending' or (v_j->>'expires_at')::timestamptz < now() + interval '119 minutes'
     or (v_j->'confirmation'->>'resends_today')::integer <> 1 then
    raise exception 'Reenviar una vencida debía reabrirla con plazo nuevo: %', v_j;
  end if;
  v_exp := (v_j->>'expires_at')::timestamptz;

  -- Pendiente: solo otro mensaje, sin alargar el plazo.
  v_j := public.staff_resend_confirmation(v_charge3);
  if (v_j->>'expires_at')::timestamptz <> v_exp or (v_j->'confirmation'->>'resends_today')::integer <> 2 then
    raise exception 'Reenviar una pendiente no alarga el plazo: %', v_j;
  end if;
  perform public.staff_resend_confirmation(v_charge3);

  v_failed := false;
  begin
    perform public.staff_resend_confirmation(v_charge3);
  exception when others then
    v_failed := true; v_err := sqlerrm;
  end;
  if not v_failed or v_err not like 'Ya reenviaste esta solicitud 3 veces hoy%' then
    raise exception 'El cuarto reenvío del día debía rechazarse: %', coalesce(v_err, 'sin error');
  end if;

  v_failed := false;
  begin
    perform public.staff_resend_confirmation(v_charge);
  exception when others then
    v_failed := true; v_err := sqlerrm;
  end;
  reset role;
  if not v_failed or v_err <> 'Este financiamiento ya no se puede reenviar' then
    raise exception 'Una confirmada no se reenvía: %', coalesce(v_err, 'sin error');
  end if;

  if (select count(*) from public.outbound_messages
       where charge_id = v_charge3 and template_key = 'confirmar_financiamiento') <> 4 then
    raise exception 'Debían quedar la pregunta original y tres reenvíos';
  end if;

  -- =========================================================================
  -- 8. Un «Sí» que ya no se puede financiar
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V20000004');
  v_j := public.create_patient_charge(v_m, null,
           v_pac || jsonb_build_object('document', 'V20000004', 'phone', '04261112233', 'email', 'd@gmail.com'),
           40, null, null, 'pcf-key-4');
  reset role;
  v_charge4 := (v_j->>'id')::uuid;

  update public.profiles set is_blacklisted = true
   where id = (select user_id from public.charges where id = v_charge4);

  v_j := public.helios_patient_decision(v_charge4, 'si', '584261112233', 'wamid.si.4');
  select * into v_row from public.charges where id = v_charge4;
  if (v_j->>'ok')::boolean or v_j->>'reason' <> 'no_disponible'
     or v_row.status <> 'declined' or v_row.decline_reason <> 'no_disponible'
     or exists (select 1 from public.installments where charge_id = v_charge4)
     or exists (select 1 from ledger.transactions where reference_id = v_charge4) then
    raise exception 'Un «Sí» que ya no se puede financiar debía rechazarse sin deuda: % %', v_j, to_jsonb(v_row);
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_j := public.helios_charge_for_staff(v_charge4);
  if v_j->>'decline_message' not like 'No podemos financiar a esta persona.%'
     or v_j->'confirmation'->>'status' <> 'rechazada' then
    raise exception 'La clínica debía ver el texto neutro: %', v_j;
  end if;

  -- =========================================================================
  -- 9. La lista de la clínica, el canal y quién decide
  -- =========================================================================
  if (select count(*) from public.merchant_transactions(v_bdate, v_bdate)) <> 4
     or (select count(*) from public.merchant_transactions(v_bdate, v_bdate) t
          where t.status = 'pending' and t.expires_at is not null and t.receipt_status = 'sin_enviar'
            and t.cuota_1_due = v_bdate + 7) <> 1
     or (select count(*) from public.merchant_transactions(v_bdate, v_bdate) t where t.status = 'declined') <> 2
     or (select count(*) from public.merchant_transactions(v_bdate, v_bdate) t where t.status = 'confirmed') <> 1 then
    raise exception 'La lista de la clínica debía mostrar las 4 órdenes con su estado';
  end if;

  -- El bot marca el canal con `helios.canal`.
  perform public.helios_patient_eligibility(v_m, 'V20000005');
  perform set_config('helios.canal', 'whatsapp', true);
  v_j := public.create_patient_charge(v_m, null,
           v_pac || jsonb_build_object('document', 'V20000005', 'phone', '04121112233', 'email', 'e@gmail.com'),
           30, null, null, 'pcf-key-5');
  perform set_config('helios.canal', '', true);
  if v_j->>'channel' <> 'whatsapp' then
    raise exception 'El canal debía salir de helios.canal: %', v_j;
  end if;

  -- Solo el webhook (service_role) decide.
  v_failed := false;
  begin
    perform public.helios_patient_decision((v_j->>'id')::uuid, 'si', '584121112233', 'wamid.desde.panel');
  exception when insufficient_privilege then
    v_failed := true;
  end;
  reset role;
  if not v_failed then
    raise exception 'El personal de la clínica no puede decidir por el paciente';
  end if;
end;
$$;

set constraints all immediate;

rollback;
