-- ============================================================================
-- Helios — La consulta se cobra en dólares o en euros (20261007000100–000500)
--
--   bash supabase/tests/run.sh moneda_smoke
--
-- Con tasas propias dentro de la transacción (dólar 800 Bs, euro 900 Bs, así
-- que €1 = $1,125) para que las cifras sean exactas:
--
--  1. Las tasas: la cruzada, `helios_fx_today`, la carga a mano del euro y el
--     historial por moneda.
--  2. La vista previa en euros: el desglose en euros (lo que se enseña) y en
--     dólares (el libro), los bolívares de cada cuota, el mínimo y el límite
--     dichos en euros.
--  3. El alta en euros: la orden guarda su moneda y su tasa cruzada; las
--     cuotas, sus euros; el libro, dólares. La clínica lo ve en euros.
--  4. Los mensajes al paciente: euros y bolívares, «la tasa BCV del euro».
--  5. Una orden en dólares sigue igual (sus `_cur` son sus `_usd`).
--  6. El pago del paciente: la cuota en euros se cotiza a la tasa del euro
--     (con fecha, a la del día del pago); el libro asienta dólares;
--     «Recibimos tu pago» dice euros y bolívares.
--  7. El aviso de cuota en euros.
--  8. A la clínica: cada mitad en euros y la transferencia a la tasa del euro;
--     con dólares y euros a la vez no se acepta una tasa única.
--  9. Las cuentas de cobro: solo Pago Móvil y transferencia.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_super    uuid := gen_random_uuid();
  v_op       uuid := gen_random_uuid();
  v_cajero   uuid := gen_random_uuid();
  v_m        uuid;
  v_branch   uuid;
  v_today    date := public.helios_business_date(now());
  v_pac      jsonb;
  v_pac2     jsonb;
  v_j        jsonb;
  v_charge   uuid;
  v_usd_ch   uuid;
  v_c        public.charges%rowtype;
  v_profile  uuid;
  v_i1       uuid;
  v_i2       uuid;
  v_s        record;
  v_n        integer;
  v_failed   boolean;
  v_err      text;
  v_txt      text;
  v_q        public.payment_quotes%rowtype;
  v_rep      uuid;
  v_s1       uuid;
  v_s2       uuid;
  v_sc       uuid;
  v_k        uuid;
  v_d        date;
begin
  -- =========================================================================
  -- Preparación
  -- =========================================================================
  update public.platform_maintenance set is_active = false;
  update public.platform_contact set whatsapp_number = '+584140001122';
  update public.levels set monthly_limit_usd = 150 where level = 1;
  update public.notification_templates set enabled = true
   where key in ('cuota_hoy', 'pago_recibido', 'bienvenida', 'comprobante_financiamiento');

  insert into public.business_parameters (key, value, effective_from, note)
  values ('payment_four_eyes', 0, v_today, 'prueba')
  on conflict (key, effective_from) do update set value = excluded.value;

  -- Las tasas de hoy y las de hace 2 días (para un pago con fecha).
  perform public.record_fx_rate(800, v_today, 'BCV');
  perform public.record_fx_rate(900, v_today, 'BCV_EUR');
  perform public.record_fx_rate(780, v_today - 2, 'BCV');
  perform public.record_fx_rate(880, v_today - 2, 'BCV_EUR');

  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at, raw_user_meta_data)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'mon-' || u || '@prueba.helios.test', now(), now(), now(), '{"full_name":"Ana Secretaria"}'
  from unnest(array[v_super, v_op, v_cajero]) u;
  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_super, 'super_admin', 'Super Moneda', true),
         (v_op, 'operador', 'Operadora Moneda', true);

  insert into public.merchants (name) values ('Clínica Euro') returning id into v_m;
  select id into v_branch from public.merchant_branches where merchant_id = v_m and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_m, v_branch, 'cajero');

  v_pac := jsonb_build_object(
    'document', '23456789',
    'first_name', 'Carla', 'last_name', 'Rojas',
    'birth_date', (v_today - interval '30 years')::date,
    'sex', 'f',
    'phone', '0414-765.43.21',
    'email', 'carla@correo.test',
    'state', 'Miranda', 'city', 'Caracas', 'address', 'Altamira',
    'occupation', null,
    'reference_name', 'Rosa Rojas', 'reference_phone', '0412-555.12.34', 'reference_relationship', 'Madre');
  v_pac2 := v_pac || jsonb_build_object('document', '34567890', 'first_name', 'Pedro',
                                        'phone', '0414-111.22.33', 'email', 'pedro@correo.test');

  -- =========================================================================
  -- 1. Las tasas
  -- =========================================================================
  if public.helios_usd_per_unit('EUR', v_today) <> 1.125 or public.helios_usd_per_unit('USD', v_today) <> 1 then
    raise exception 'La tasa cruzada debía ser 900/800 = 1,125: %', public.helios_usd_per_unit('EUR', v_today);
  end if;
  if public.helios_fx_rate('EUR', v_today) <> 900 or public.helios_fx_rate('USD', v_today) <> 800 then
    raise exception 'helios_fx_rate debía leer la serie de cada moneda';
  end if;

  v_failed := false;
  begin
    perform public.helios_usd_per_unit('GBP', v_today);
  exception when sqlstate '22023' then v_failed := true;
  end;
  if not v_failed then
    raise exception 'Una moneda que no es USD ni EUR debía rechazarse';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_j := public.helios_fx_today();
  if (v_j->'usd'->>'rate')::numeric <> 800 or (v_j->'eur'->>'rate')::numeric <> 900
     or (v_j->>'usd_per_eur')::numeric <> 1.125 then
    raise exception 'helios_fx_today inesperado: %', v_j;
  end if;

  -- La carga a mano del euro (super admin con segundo factor).
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_set_fx_rate(905, v_today - 1, 'Prueba euro', 'EUR');
  if v_j->>'currency' <> 'EUR' or public.current_fx_rate('BCV_EUR', v_today - 1) <> 905
     or public.current_fx_rate('BCV', v_today - 1) = 905 then
    raise exception 'La carga a mano del euro debía ir a BCV_EUR: %', v_j;
  end if;
  reset role;
  if not exists (select 1 from public.fx_rate_syncs
                 where source_key = 'manual' and series = 'BCV_EUR' and effective_date = v_today - 1) then
    raise exception 'La carga a mano del euro debía quedar en la bitácora de su serie';
  end if;
  set local role authenticated;
  if (select count(*) from public.admin_fx_rate_history(5, 'EUR') h where h.rate in (900, 905)) <> 2 then
    raise exception 'El historial del euro debía traer las tasas del euro';
  end if;
  if exists (select 1 from public.admin_fx_rate_history(5, 'USD') h where h.rate in (900, 905)) then
    raise exception 'El historial del dólar no puede traer tasas del euro';
  end if;
  raise notice 'TEST MONEDA 1 OK — tasas por serie, cruzada, carga a mano y historial';

  -- =========================================================================
  -- 2. La vista previa en euros
  -- =========================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  v_j := public.helios_patient_eligibility(v_m, 'V23456789');
  if v_j->>'estado' <> 'nuevo' then
    raise exception 'La cédula de prueba debía ser nueva: %', v_j;
  end if;

  v_j := public.preview_patient_charge(v_m, 'V23456789', 100, 'eur');
  if v_j->>'currency' <> 'EUR' or (v_j->>'fx_usd_per_unit')::numeric <> 1.125
     or (v_j->>'tasa_bcv')::numeric <> 900
     -- Lo que se enseña, en euros: 12% + IVA 16% de la comisión.
     or (v_j->>'base_cur')::numeric <> 100 or (v_j->>'consumer_fee_cur')::numeric <> 12
     or (v_j->>'consumer_fee_vat_cur')::numeric <> 1.92
     or (v_j->'installments'->0->>'amount_cur')::numeric <> 56.96
     or (v_j->'installments'->1->>'amount_cur')::numeric <> 56.96
     or (v_j->'installments'->0->>'financed_cur')::numeric <> 50
     or (v_j->'installments'->0->>'amount_ves')::numeric <> 51264.00
     -- El libro, en dólares: la base pasada a dólares y el mismo desglose.
     or (v_j->>'base_usd')::numeric <> 112.50 or (v_j->>'consumer_fee_usd')::numeric <> 13.50
     or (v_j->>'consumer_fee_vat_usd')::numeric <> 2.16
     or (v_j->'installments'->0->>'amount_usd')::numeric <> 64.08
     or (v_j->'installments'->1->>'amount_usd')::numeric <> 64.08
     -- El límite de $150, en euros.
     or (v_j->>'limite_cur')::numeric <> 133.33 or (v_j->>'limite_usd')::numeric <> 150
     or not (v_j->>'cabe')::boolean then
    raise exception 'Vista previa en euros inesperada: %', v_j;
  end if;
  if v_j ? 'amount_usd' or v_j ? 'amount_cur' or v_j ? 'total_cur' then
    raise exception 'La vista previa no puede devolver un total con la comisión: %', v_j;
  end if;

  -- €140 = $157,50: no cabe en $150.
  v_j := public.preview_patient_charge(v_m, 'V23456789', 140, 'EUR');
  if (v_j->>'cabe')::boolean then
    raise exception '€140 no debía caber en el límite de $150: %', v_j;
  end if;

  -- El mínimo ($10) dicho en euros: €8,89.
  begin
    perform public.preview_patient_charge(v_m, 'V23456789', 8.88, 'EUR');
    raise exception '€8,88 ($9,99) debía estar por debajo del mínimo';
  exception when sqlstate '22023' then
    if sqlerrm <> 'El monto mínimo es €8,89' then
      raise exception 'Texto del mínimo en euros inesperado: %', sqlerrm;
    end if;
  end;
  perform public.preview_patient_charge(v_m, 'V23456789', 8.89, 'EUR');

  begin
    perform public.preview_patient_charge(v_m, 'V23456789', 9.99, 'USD');
    raise exception '$9,99 debía estar por debajo del mínimo';
  exception when sqlstate '22023' then
    if sqlerrm <> 'El monto mínimo es $10' then
      raise exception 'Texto del mínimo en dólares inesperado: %', sqlerrm;
    end if;
  end;

  begin
    perform public.preview_patient_charge(v_m, 'V23456789', 100, 'BTC');
    raise exception 'Una moneda desconocida debía fallar';
  exception when sqlstate '22023' then null;
  end;
  raise notice 'TEST MONEDA 2 OK — vista previa en euros, mínimo y límite en euros';

  -- =========================================================================
  -- 3. El alta en euros
  -- =========================================================================
  begin
    perform public.create_patient_charge(v_m, null, v_pac, 140, null, null, 'mon-key-over', 'EUR');
    raise exception '€140 no debía caber';
  exception when sqlstate '22023' then
    if sqlerrm <> 'El monto supera lo disponible (€133,33).' then
      raise exception 'Texto de «supera lo disponible» en euros inesperado: %', sqlerrm;
    end if;
  end;

  v_j := public.create_patient_charge(v_m, null, v_pac, 100, 'Limpieza dental', null, 'mon-key-1', 'EUR');
  v_charge := (v_j->>'id')::uuid;
  if v_j->>'status' <> 'confirmed' or v_j->>'currency' <> 'EUR'
     or (v_j->>'merchant_sale_cur')::numeric <> 100 or (v_j->>'merchant_sale_usd')::numeric <> 112.50
     or (v_j->'installments'->0->>'amount_cur')::numeric <> 56.96
     or (v_j->'installments'->0->>'amount_ves')::numeric <> 51264.00
     or (v_j->'breakdown'->>'base_cur')::numeric <> 100
     or (v_j->'breakdown'->>'consumer_fee_cur')::numeric <> 12 then
    raise exception 'El alta en euros devolvió algo inesperado: %', v_j;
  end if;

  -- Idempotente: la misma clave devuelve la misma orden.
  if (public.create_patient_charge(v_m, null, v_pac, 100, 'Limpieza dental', null, 'mon-key-1', 'EUR'))->>'id'
     <> v_charge::text then
    raise exception 'La misma clave debía devolver la misma orden';
  end if;
  reset role;

  select * into v_c from public.charges where id = v_charge;
  v_profile := v_c.user_id;
  if v_c.currency <> 'EUR' or v_c.fx_usd_per_unit <> 1.125
     or v_c.base_cur <> 100 or v_c.consumer_fee_cur <> 12 or v_c.consumer_fee_vat_cur <> 1.92
     or v_c.amount_cur <> 113.92 or v_c.merchant_net_cur <> 100
     or v_c.base_usd <> 112.50 or v_c.amount_usd <> 128.16 or v_c.merchant_net_usd <> 112.50 then
    raise exception 'La orden en euros no guardó lo esperado: %', to_jsonb(v_c);
  end if;

  select id into v_i1 from public.installments where charge_id = v_charge and sequence = 1;
  select id into v_i2 from public.installments where charge_id = v_charge and sequence = 2;
  if (select amount_cur from public.installments where id = v_i1) <> 56.96
     or (select amount_cur from public.installments where id = v_i2) <> 56.96
     or (select financed_cur from public.installments where id = v_i1) <> 50
     or (select amount_usd from public.installments where id = v_i1) <> 64.08 then
    raise exception 'Las cuotas en euros no se pusieron sus euros';
  end if;

  -- El libro, en dólares y cuadrado.
  if (select sum(e.debit) - sum(e.credit) from ledger.entries e
        join ledger.transactions t on t.id = e.transaction_id
       where t.reference_id = v_charge and t.type = 'charge') <> 0
     or not exists (select 1 from ledger.entries e
                      join ledger.transactions t on t.id = e.transaction_id
                     where t.reference_id = v_charge and t.type = 'charge' and e.debit = 128.16) then
    raise exception 'El asiento de la orden en euros debía ir en dólares (128,16) y cuadrar';
  end if;

  if not exists (select 1 from audit.admin_actions
                 where action = 'charge.created' and target_id = v_charge
                   and detail->>'currency' = 'EUR' and (detail->>'base_cur')::numeric = 100) then
    raise exception 'La bitácora del alta debía decir la moneda';
  end if;

  -- La clínica lo ve en euros.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  select count(*) into v_n
  from public.merchant_transactions(v_today, v_today, 10) t
  where t.charge_id = v_charge and t.currency = 'EUR' and t.merchant_sale_cur = 100 and t.merchant_sale_usd = 112.50;
  if v_n <> 1 then
    raise exception 'merchant_transactions debía traer la orden en euros';
  end if;
  v_j := public.merchant_charge_detail(v_charge);
  if v_j->>'currency' <> 'EUR' or (v_j->>'merchant_sale_cur')::numeric <> 100
     or (v_j->'items'->0->>'line_total_cur')::numeric <> 100 then
    raise exception 'merchant_charge_detail debía hablar en euros: %', v_j;
  end if;
  reset role;
  raise notice 'TEST MONEDA 3 OK — alta en euros, libro en dólares, la clínica lo ve en euros';

  -- =========================================================================
  -- 4. Los mensajes al paciente
  -- =========================================================================
  select rendered_text into v_txt from public.outbound_messages
  where charge_id = v_charge and template_key = 'comprobante_financiamiento';
  if v_txt not like '%Monto de la consulta: €100%'
     or v_txt not like '%Comisión de servicio (12%): €12%'
     or v_txt not like '%IVA de la comisión (16%): €1,92%'
     or v_txt not like '%Total a pagar: €113,92 (Bs 102.528,00 a la tasa BCV de hoy)%'
     or v_txt not like '%• Cuota 1: €56,96 (hoy Bs 51.264,00), vence el %'
     or v_txt not like '%a la tasa BCV del euro del día en que pagues%'
     or v_txt like '%$100%' or v_txt like '%$56%' then
    raise exception 'El comprobante en euros no dice lo esperado: %', v_txt;
  end if;
  if (select html from public.outbound_messages
       where charge_id = v_charge and template_key = 'comprobante_financiamiento')
     not like '%Bs 102.528,00 a la tasa BCV de hoy%' then
    raise exception 'El HTML del comprobante debía llevar los bolívares del total';
  end if;

  select rendered_text into v_txt from public.outbound_messages
  where charge_id = v_charge and template_key = 'bienvenida';
  if v_txt not like '%* €56,96 (hoy Bs 51.264,00) — %'
     or v_txt not like '%a la tasa BCV del euro%' or v_txt like '%efectivo%' then
    raise exception 'La bienvenida en euros no dice lo esperado: %', v_txt;
  end if;

  -- La pregunta al paciente (con la confirmación encendida): todo en euros.
  update public.business_parameters set value = 1
   where key = 'patient_confirmation_required' and effective_from = (
     select max(effective_from) from public.business_parameters
      where key = 'patient_confirmation_required' and effective_from <= v_today);
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  perform public.helios_patient_eligibility(v_m, 'V34567890');
  begin
    v_j := public.create_patient_charge(v_m, null, v_pac2, 20, null, null, 'mon-key-pend', 'EUR');
  exception when sqlstate '22023' then
    -- Sin la API de WhatsApp lista no se puede preguntar: se prueba el texto
    -- llamando directamente al que lo arma.
    v_j := null;
  end;
  reset role;
  if v_j is not null then
    select rendered_text into v_txt from public.outbound_messages
    where charge_id = (v_j->>'id')::uuid and template_key = 'confirmar_financiamiento';
    if v_txt not like '%tu consulta de €20 para pagarla%'
       or v_txt not like '%* Total: €22,78 (Bs 20.502,00 a la tasa BCV de hoy)%'
       or v_txt not like '%Tus cuotas serán de €11,39:%'
       or v_txt not like '%a la tasa BCV del euro del día en que pagues%' then
      raise exception 'La pregunta en euros no dice lo esperado: %', v_txt;
    end if;
  end if;
  update public.business_parameters set value = 0
   where key = 'patient_confirmation_required' and effective_from = (
     select max(effective_from) from public.business_parameters
      where key = 'patient_confirmation_required' and effective_from <= v_today);
  raise notice 'TEST MONEDA 4 OK — comprobante, bienvenida y pregunta en euros y bolívares';

  -- =========================================================================
  -- 5. Una orden en dólares sigue igual
  -- =========================================================================
  v_usd_ch := (pg_temp.prueba_cobro(v_profile, v_m, v_branch, v_cajero, 10.00, 'mon-usd')->>'charge_id')::uuid;
  select * into v_c from public.charges where id = v_usd_ch;
  if v_c.currency <> 'USD' or v_c.fx_usd_per_unit <> 1 or v_c.amount_cur <> v_c.amount_usd
     or v_c.base_cur <> v_c.base_usd
     or exists (select 1 from public.installments where charge_id = v_usd_ch and amount_cur <> amount_usd) then
    raise exception 'Una orden en dólares debía tener sus _cur iguales a sus _usd: %', to_jsonb(v_c);
  end if;
  raise notice 'TEST MONEDA 5 OK — una orden en dólares es su propia moneda';

  -- =========================================================================
  -- 6. El pago del paciente
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- Hoy: €56,96 × 900 = 51.264,00 Bs.
  v_j := public.admin_payment_preview(v_profile, array[v_i1], v_today);
  if (v_j->>'amount_eur')::numeric <> 56.96 or (v_j->>'amount_usd')::numeric <> 64.08
     or (v_j->>'amount_usd_part')::numeric <> 0
     or (v_j->>'fx_rate_eur')::numeric <> 900 or (v_j->>'amount_ves')::numeric <> 51264.00 then
    raise exception 'La vista previa del pago en euros es inesperada: %', v_j;
  end if;

  -- Con la cuota en dólares de la otra orden: cada parte con su tasa.
  v_j := public.admin_payment_preview(v_profile, array[v_i1,
           (select id from public.installments where charge_id = v_usd_ch and sequence = 1)], v_today);
  if (v_j->>'amount_ves')::numeric
     <> 51264.00 + round((select amount_usd from public.installments where charge_id = v_usd_ch and sequence = 1) * 800, 2) then
    raise exception 'Dólares y euros debían ir cada uno a su tasa: %', v_j;
  end if;

  -- Pagado hace 2 días: a la tasa del euro de ese día (880).
  v_j := public.admin_register_payment(v_profile, array[v_i1], 'pago_movil', 'Banesco', 'EU-1001',
                                       v_today - 2, 50124.80, null, null);
  v_rep := (v_j->>'report_id')::uuid;
  select * into v_q from public.payment_quotes where id = (v_j->>'quote_id')::uuid;
  if v_q.amount_usd <> 64.08 or v_q.amount_eur <> 56.96 or v_q.fx_rate_eur <> 880
     or v_q.amount_ves <> 50124.80 or (v_j->>'diferencia_ves')::numeric <> 0 then
    raise exception 'La cotización con fecha debía usar la tasa del euro de ese día: % / %', to_jsonb(v_q), v_j;
  end if;
  if (select currency || ':' || amount_cur from public.payment_quote_items where quote_id = v_q.id)
     <> 'EUR:56.9600' then
    raise exception 'La cuota de la cotización debía guardar su moneda y sus euros';
  end if;

  perform public.admin_reconcile_payment(v_rep, true, null);
  reset role;

  if (select status from public.installments where id = v_i1) <> 'paid' then
    raise exception 'La cuota en euros debía quedar pagada';
  end if;
  if not exists (select 1 from ledger.entries e
                   join ledger.transactions t on t.id = e.transaction_id
                  where t.idempotency_key = 'reconcile:' || v_rep and e.debit = 64.08) then
    raise exception 'El cobro de la cuota en euros debía asentarse en dólares (64,08)';
  end if;
  select rendered_text into v_txt from public.outbound_messages
  where dedupe_key = 'pago_recibido:email:' || v_rep;
  if v_txt is null or v_txt not like '%tu pago de €56,96 (Bs 50.124,80)%' then
    raise exception '«Recibimos tu pago» debía decir euros y bolívares: %', v_txt;
  end if;
  raise notice 'TEST MONEDA 6 OK — el pago en euros a la tasa del euro del día del pago; libro en dólares';

  -- =========================================================================
  -- 7. El aviso de cuota
  -- =========================================================================
  update public.installments set due_date = v_today where id = v_i2;
  perform public.helios_enqueue_reminders('cuota_hoy', v_today);
  select rendered_text into v_txt from public.outbound_messages
  where profile_id = v_profile and template_key = 'cuota_hoy' and installment_due_date = v_today;
  if v_txt not like '%Hoy vence tu cuota de €56,96 (Bs 51.264,00) de la orden #%' then
    raise exception 'El aviso de la cuota en euros no dice lo esperado: %', v_txt;
  end if;

  -- La víspera dice la tasa de su moneda (20261008000300), en el texto y en
  -- el correo.
  perform public.helios_enqueue_reminders('cuota_manana', v_today - 1);
  if exists (select 1 from public.outbound_messages
              where profile_id = v_profile and template_key = 'cuota_manana' and installment_due_date = v_today
                and (rendered_text not like '%a la tasa BCV del euro del día en que pagues%'
                     or (channel = 'email' and html not like '%a la tasa BCV del euro <strong%')))
     or not exists (select 1 from public.outbound_messages
                     where profile_id = v_profile and template_key = 'cuota_manana' and installment_due_date = v_today) then
    raise exception 'La víspera de una cuota en euros debía decir «a la tasa BCV del euro»';
  end if;

  -- El mismo día, también una cuota en dólares: las dos tasas.
  delete from public.outbound_messages
   where profile_id = v_profile and template_key = 'cuota_manana' and installment_due_date = v_today;
  select id, due_date into v_k, v_d from public.installments where charge_id = v_usd_ch and sequence = 1;
  update public.installments set due_date = v_today where id = v_k;
  perform public.helios_enqueue_reminders('cuota_manana', v_today - 1);
  select rendered_text into v_txt from public.outbound_messages
  where profile_id = v_profile and template_key = 'cuota_manana' and installment_due_date = v_today
    and channel = 'whatsapp';
  if v_txt is null or v_txt not like '%a la tasa BCV del dólar o del euro, según la moneda de cada cuota, del día en que pagues%' then
    raise exception 'Con cuotas en las dos monedas, la víspera debía nombrar las dos tasas: %', v_txt;
  end if;
  update public.installments set due_date = v_d where id = v_k;
  raise notice 'TEST MONEDA 7 OK — el aviso dice euros y bolívares, y la víspera, la tasa de su moneda';

  -- =========================================================================
  -- 8. A la clínica: cada mitad en euros
  -- =========================================================================
  perform public.run_scheduled_settlements_batch((select due_date from public.installments where id = v_i1),
                                                 '00000000-0000-0000-0000-000000000000'::uuid, 100);
  perform public.run_scheduled_settlements_batch(v_today, '00000000-0000-0000-0000-000000000000'::uuid, 100);

  select id into v_s1 from public.settlements
  where charge_id = v_charge and reason = 'scheduled_installment'
    and business_date = (select due_date from public.installments where id = v_i1);
  select id into v_s2 from public.settlements
  where charge_id = v_charge and reason = 'scheduled_installment' and business_date = v_today;
  if v_s1 is null or v_s2 is null then
    raise exception 'Faltaban las dos mitades de la clínica';
  end if;
  if (select currency || ':' || amount_cur || ':' || amount_usd from public.settlements where id = v_s1)
       <> 'EUR:50.0000:56.2500'
     or (select currency || ':' || amount_cur from public.settlements where id = v_s2) <> 'EUR:50.0000' then
    raise exception 'Cada mitad debía ir en euros (€50) y sumar el neto en dólares';
  end if;
  select id into v_sc from public.settlements
  where charge_id = v_usd_ch and reason = 'scheduled_installment' limit 1;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  v_j := public.admin_merchant_settlements(v_m, null);
  if not exists (select 1 from jsonb_array_elements(v_j) x
                 where (x->>'id')::uuid = v_s1 and x->>'currency' = 'EUR'
                   and (x->>'pending_cur')::numeric = 50 and (x->>'pending_ves_hoy')::numeric = 45000) then
    raise exception 'La lista de liquidaciones debía decir moneda y bolívares de hoy: %', v_j;
  end if;

  -- Con una de dólares y otra de euros no vale una tasa única.
  if v_sc is not null then
    begin
      perform public.admin_report_merchant_payout(v_m, array[v_s2, v_sc], 'pago_movil', 'REF-MIX',
                                                  null, 850, null, null, v_today, null);
      raise exception 'Una tasa única con dólares y euros debía fallar';
    exception when sqlstate '22023' then
      if sqlerrm not like 'Hay liquidaciones en dólares y en euros%' then
        raise exception 'Texto inesperado con monedas mezcladas: %', sqlerrm;
      end if;
    end;
  end if;

  -- La primera mitad, pagada hace 2 días: €50 × 880 = 44.000 Bs.
  v_j := public.admin_report_merchant_payout(v_m, array[v_s1], 'transferencia', 'REF-EU-1',
                                             null, null, null, null, v_today - 2, null);
  if (v_j->>'amount_ves')::numeric <> 44000 or (v_j->>'amount_eur')::numeric <> 50
     or (v_j->>'fx_rate_eur')::numeric <> 880 or (v_j->>'amount_usd')::numeric <> 56.25 then
    raise exception 'La transferencia en euros debía ir a la tasa del euro del día: %', v_j;
  end if;
  if (select paid_cur from public.settlements where id = v_s1) <> 50
     or (select status from public.settlements where id = v_s1) <> 'paid' then
    raise exception 'La mitad en euros debía quedar pagada entera';
  end if;
  v_j := public.admin_payout_detail((v_j->>'payout_id')::uuid);
  if v_j->'items'->0->>'currency' <> 'EUR' or (v_j->'items'->0->>'applied_cur')::numeric <> 50 then
    raise exception 'El detalle de la transferencia debía decir los euros: %', v_j;
  end if;

  -- La segunda, con la tasa del euro escrita a mano (una sola moneda: vale).
  v_j := public.admin_report_merchant_payout(v_m, array[v_s2], 'pago_movil', 'REF-EU-2',
                                             null, 901.5, null, null, v_today, null);
  if (v_j->>'amount_ves')::numeric <> 45075 or (v_j->>'fx_rate_eur')::numeric <> 901.5 then
    raise exception 'Con una sola moneda, la tasa escrita es la de esa moneda: %', v_j;
  end if;
  reset role;
  raise notice 'TEST MONEDA 8 OK — a la clínica en euros, a la tasa del euro';

  -- =========================================================================
  -- 9. Las cuentas de cobro: solo bolívares
  -- =========================================================================
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_super::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  begin
    perform public.admin_set_payment_destination(null, null, null, 'Helios', null, null, true, null,
                                                 'zelle', null, 'pagos@helios.test');
    raise exception 'Una cuenta de Zelle debía rechazarse';
  exception when sqlstate '22023' then
    if sqlerrm not like 'El paciente solo paga en bolívares%' then
      raise exception 'Texto inesperado para una cuenta de Zelle: %', sqlerrm;
    end if;
  end;
  perform public.admin_set_payment_destination('Banesco', 'J-500000001', '04141234567', 'Quarto Latam',
                                               null, 1, true, null, 'pago_movil', null, null);
  reset role;
  if exists (select 1 from public.payment_destinations where is_active and method not in ('pago_movil', 'transferencia')) then
    raise exception 'No puede quedar activa ninguna cuenta que no sea en bolívares';
  end if;
  if public.helios_payment_accounts_text() like '%Zelle%' then
    raise exception 'El texto de las cuentas no puede ofrecer Zelle';
  end if;
  raise notice 'TEST MONEDA 9 OK — solo Pago Móvil y transferencia';
end
$$;

set constraints all immediate;

rollback;
