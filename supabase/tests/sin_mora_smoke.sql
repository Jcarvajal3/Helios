-- ============================================================================
-- Helios — Sin cargos por mora, por ahora (20261007000800)
--
--   bash supabase/tests/run.sh sin_mora_smoke
--
-- Con `late_fee_usd` en 0 (lo que está en la base desde el 2026-10-07):
--  1. El parámetro vigente es 0 y el motor no cobra nada a una cuota vencida.
--  2. La vista previa dice 0: el panel y el bot no leen ninguna regla.
--  3. El comprobante y el aviso de cuota vencida no prometen ningún cargo.
--  4. Con el cargo de vuelta (una fila nueva del parámetro), las frases
--     vuelven solas.
--
-- No usa `-- @ayudas` para el parámetro: las ayudas lo ponen en $2 para las
-- demás suites. Este parte del valor real de la base.
-- ============================================================================

begin;

do $$
declare
  v_today   date := public.helios_business_date(now());
  v_cajero  uuid := gen_random_uuid();
  v_m       uuid;
  v_branch  uuid;
  v_pac     jsonb;
  v_j       jsonb;
  v_charge  uuid;
  v_inst    uuid;
  v_txt     text;
begin
  -- =========================================================================
  -- 1. El parámetro y el motor
  -- =========================================================================
  if public.helios_late_fee_usd() <> 0 then
    raise exception 'El cargo por mora debía estar en 0 desde el 2026-10-07: %', public.helios_late_fee_usd();
  end if;

  -- La confirmación del paciente, apagada solo aquí: el alta confirma al instante.
  insert into public.business_parameters (key, value, effective_from, note)
  values ('patient_confirmation_required', 0, v_today, 'pruebas (rollback)')
  on conflict (key, effective_from) do update set value = 0;
  update public.platform_maintenance set is_active = false;
  update public.platform_contact set whatsapp_number = '+584140001122';
  update public.levels set monthly_limit_usd = 150 where level = 1;

  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at, raw_user_meta_data)
  values (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'sinmora-' || v_cajero || '@prueba.helios.test', now(), now(), now(), '{"full_name":"Ana Secretaria"}');
  insert into public.merchants (name) values ('Clínica Sin Mora') returning id into v_m;
  select id into v_branch from public.merchant_branches where merchant_id = v_m and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values (v_cajero, v_m, v_branch, 'cajero');

  v_pac := jsonb_build_object(
    'document', '45678901', 'first_name', 'Luisa', 'last_name', 'Mora',
    'birth_date', (v_today - interval '30 years')::date, 'sex', 'f',
    'phone', '0414-222.33.44', 'email', 'luisa@correo.test',
    'state', 'Miranda', 'city', 'Caracas', 'address', 'Chacao', 'occupation', null,
    'reference_name', 'Rosa Mora', 'reference_phone', '0412-555.12.34', 'reference_relationship', 'Madre');

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V45678901');

  -- =========================================================================
  -- 2. La vista previa dice 0
  -- =========================================================================
  v_j := public.preview_patient_charge(v_m, 'V45678901', 100, 'USD');
  if (v_j->>'late_fee_usd')::numeric <> 0 then
    raise exception 'La vista previa debía decir que no hay cargo por mora: %', v_j;
  end if;

  v_charge := ((public.create_patient_charge(v_m, null, v_pac, 100, null, null, 'sinmora-1', 'USD'))->>'id')::uuid;
  reset role;

  -- El motor: una cuota vencida hace 10 días no devenga nada.
  select id into v_inst from public.installments where charge_id = v_charge and sequence = 1;
  update public.installments set due_date = v_today - 10 where id = v_inst;
  if public.charge_late_fee(v_inst, 10) is not null
     or exists (select 1 from public.late_fees where installment_id = v_inst) then
    raise exception 'Con el cargo en 0 no se debía cobrar nada';
  end if;
  raise notice 'TEST SIN MORA 1-2 OK — parámetro en 0, el motor no cobra, la vista previa dice 0';

  -- =========================================================================
  -- 3. Ningún texto promete el cargo
  -- =========================================================================
  select rendered_text into v_txt from public.outbound_messages
  where charge_id = v_charge and template_key = 'comprobante_financiamiento';
  if v_txt ilike '%cargo de%' or v_txt not like '%queda en pausa%' or v_txt not like '%• A los 30 días de atraso%' then
    raise exception 'El comprobante no debía prometer un cargo por mora: %', v_txt;
  end if;
  if (select html from public.outbound_messages
       where charge_id = v_charge and template_key = 'comprobante_financiamiento') ilike '%cargo de%' then
    raise exception 'El HTML del comprobante no debía prometer un cargo por mora';
  end if;

  update public.notification_templates set enabled = true where key = 'cuota_vencida_d1';
  update public.installments set due_date = v_today - 1 where id = v_inst;
  perform public.helios_enqueue_reminders('cuota_vencida_d1', v_today);
  select rendered_text into v_txt from public.outbound_messages
  where charge_id = v_charge and template_key = 'cuota_vencida_d1' and channel = 'whatsapp';
  if v_txt is null or v_txt ilike '%cargo%'
     or v_txt not like '%no podrás pagar nuevas consultas en cuotas con Helios.' || E'\n\n' || 'Para pagar, en bolívares%' then
    raise exception 'El aviso de cuota vencida no debía hablar de un cargo: %', v_txt;
  end if;
  raise notice 'TEST SIN MORA 3 OK — ni el comprobante ni el aviso prometen un cargo';

  -- =========================================================================
  -- 4. Con el cargo de vuelta, las frases vuelven solas
  -- =========================================================================
  insert into public.business_parameters (key, value, effective_from, note)
  values ('late_fee_usd', 2, v_today, 'pruebas (rollback)')
  on conflict (key, effective_from) do update set value = 2;

  v_j := public.helios_message_builtins(null);
  if v_j->>'condicion_cargo_atraso' not like '• Después de % días de gracia se suma un cargo de $2 por cada cuota vencida.%'
     or v_j->>'aviso_cargo_atraso' not like ' Si la pagas antes de cumplir % días de atraso, evitas el cargo de $2.'
     or v_j->>'condicion_cargo_atraso_html' not like '%se suma un cargo de $2 por cada cuota vencida.</td></tr>%' then
    raise exception 'Con el cargo de vuelta las frases debían volver: %', v_j;
  end if;
  raise notice 'TEST SIN MORA 4 OK — retomarlo es poner el monto en el parámetro';
end
$$;

set constraints all immediate;

rollback;
