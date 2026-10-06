-- ============================================================================
-- Helios — Recorrido completo de UN financiamiento, de punta a punta
--
--   bash supabase/tests/run.sh recorrido_completo_smoke
--
-- Una sola historia, en el orden en que pasa de verdad (docs/00 §2, §4.5, §6,
-- §7), con las RPC que usan el panel de la clínica y el superadmin:
--
--   1. Preparación: clínica (categoría clínica) con cuenta de pago, gerente y
--      secretaria «Ana», un super_admin y un operador (MFA encendida dentro de
--      la prueba: se entra con aal2), el contacto de Helios con WhatsApp, una
--      cuenta de cobro activa y la tasa BCV del día.
--   2. La clínica (Ana): cédula nueva → `nuevo`; vista previa de $100 (base
--      100, fee 20, IVA 3.20, dos cuotas de 61.60 a +7/+14 desde la medianoche
--      de Caracas, sin total con el fee); alta → confirmado, nº de orden,
--      comprobante, comisión 0.50; la misma clave → el mismo financiamiento;
--      Ana no lee profiles / installments / payment_reports.
--   3. Libro: Dr user_receivable 123.20 = Cr merchant_payable 100 + platform_
--      revenue 20 + vat_payable 3.20; comisión Dr commission_expense 0.50 /
--      Cr merchant_payable 0.50; el libro entero cuadra.
--   4. Mensajes: comprobante (correo, sin total, «no es una factura») y
--      bienvenida (WhatsApp manual). Con Resend SUSTITUIDO dentro de la
--      transacción, el despacho lo envía. Otra clínica consulta la cédula: solo
--      lo enmascarado y disponible 250, nunca la deuda.
--   5. Víspera de la cuota 1: cuota_manana con dedupe; dos veces no duplica.
--   6. Pago de la cuota 1 por el equipo (operador registra, super_admin
--      concilia contra el extracto importado): cuota pagada, caja / cuentas por
--      cobrar, pago_recibido, avisos de esa fecha cancelados; el cupo sigue en
--      250 hasta pagar las dos.
--   7. Mora en la cuota 2: congelado desde el día 1, un cargo de $2 pasada la
--      gracia (uno solo aunque se repita), cuenta_congelada y cargo_por_
--      atraso_d4; la elegibilidad dice «no disponible» con el texto neutro.
--      Pago de la cuota 2 + cargo → activo, cupo 350, bloque cerrado.
--   8. Liquidación a la clínica: 50 + 50 + 0.50 de comisión; payables partido;
--      transferencia → comisión pagada; lo que ven gerente y secretaria.
--   9. Bitácora: registro, conciliación y transferencia.
--  10. Final: libro cuadrado y nada pendiente que no deba estarlo.
--
-- NUNCA sale a la red ni toca un secreto de verdad: `helios_resend_api_key()`
-- y `helios_resend_request(...)` se sustituyen por dobles dentro de la
-- transacción (como en email_dispatch_smoke) y el rollback devuelve las de
-- verdad. Correos solo en @prueba.helios.test.
-- ============================================================================

begin;

-- @ayudas

-- Dobles de Resend (misma firma que las de verdad) -------------------------
create temp table _clave (k text) on commit drop;
create temp table _respuestas (n serial primary key, status integer, body text) on commit drop;
create temp table _llamadas (n serial primary key, method text, path text, body jsonb, idem text, api_key text) on commit drop;
create temp sequence _pos minvalue 0 start 0;

create or replace function public.helios_resend_api_key()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$ select k from pg_temp._clave limit 1 $$;

create or replace function public.helios_resend_request(
  p_method text, p_path text, p_api_key text, p_body jsonb default null, p_idempotency_key text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v record;
begin
  insert into pg_temp._llamadas (method, path, body, idem, api_key)
  values (p_method, p_path, p_body, p_idempotency_key, p_api_key);

  select * into v from pg_temp._respuestas
  where n > (select last_value from pg_temp._pos) order by n limit 1;
  if not found then
    raise exception 'La prueba no preparó respuesta para % %', p_method, p_path;
  end if;
  perform setval('pg_temp._pos', v.n);
  return jsonb_build_object('status', v.status, 'body', v.body);
end;
$$;

-- Quién llama: los claims del JWT (con el nivel de la sesión para la MFA).
create function pg_temp.como(p_user uuid, p_aal text default 'aal2')
returns void
language sql
as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;

do $$
declare
  v_super    uuid := gen_random_uuid();
  v_oper     uuid := gen_random_uuid();
  v_gerente  uuid := gen_random_uuid();
  v_ana      uuid := gen_random_uuid();
  v_otro     uuid := gen_random_uuid();
  v_m        uuid;
  v_otra     uuid;
  v_br       uuid;
  v_dest     uuid;
  v_bdate    date := public.helios_business_date(now());
  v_rate     numeric := 187.654321;
  v_doc      text := 'V31415926';
  v_pac      jsonb;
  v_j        jsonb;
  v_j2       jsonb;
  v_charge   uuid;
  v_profile  uuid;
  v_i1       public.installments%rowtype;
  v_i2       public.installments%rowtype;
  v_rep1     jsonb;
  v_rep2     jsonb;
  v_fee_id   uuid;
  v_payout   jsonb;
  v_ids      uuid[];
  v_row      record;
  v_msg      public.outbound_messages%rowtype;
  v_n        integer;
  v_num      numeric;
  v_failed   boolean;
  v_err      text;
  v_cash0    numeric;
  v_cash1    numeric;
  v_neutral  text;
  v_receipt0 text;
begin
  -- =========================================================================
  -- PASO 1 — Preparación
  -- =========================================================================
  update public.platform_maintenance set is_active = false;
  -- La MFA del equipo encendida dentro de la prueba: el equipo entra con aal2.
  update public.platform_security set require_mfa = true where id;
  update public.levels set monthly_limit_usd = 350 where level = 1;
  -- El doble control como se siembra (apagado): aquí además registra uno y
  -- aprueba otro.
  insert into public.business_parameters (key, value, effective_from, note)
  values ('payment_four_eyes', 0, v_bdate, 'recorrido completo')
  on conflict (key, effective_from) do update set value = excluded.value;
  -- La tasa BCV del día (la del registro y la del comprobante).
  insert into public.exchange_rates (source, rate, effective_date)
  values ('BCV', v_rate, v_bdate)
  on conflict (source, effective_date) do update set rate = excluded.rate;
  -- Resend «configurado» con una clave FALSA que solo ve el doble de arriba.
  insert into _clave values ('re_prueba_no_es_real');
  -- Los correos que ya hubiera en la base no entran en esta prueba.
  update public.outbound_messages set next_attempt_at = now() + interval '1 year'
   where channel = 'email' and status = 'pendiente';

  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at, raw_user_meta_data)
  values
    (v_super,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'rc-super@prueba.helios.test', now(), now(), now(), '{"full_name":"Sara Super"}'),
    (v_oper,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'rc-oper@prueba.helios.test', now(), now(), now(), '{"full_name":"Omar Operador"}'),
    (v_gerente, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'rc-gerente@prueba.helios.test', now(), now(), now(), '{"full_name":"Gloria Gerente"}'),
    (v_ana,     '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'rc-ana@prueba.helios.test', now(), now(), now(), '{"full_name":"Ana Rivas"}'),
    (v_otro,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'rc-otro@prueba.helios.test', now(), now(), now(), '{"full_name":"Otro Gerente"}');
  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_super, 'super_admin', 'Sara Super', true),
         (v_oper,  'operador',    'Omar Operador', true);

  set local role authenticated;
  -- Sin el segundo factor, el super_admin no escribe.
  perform pg_temp.como(v_super, 'aal1');
  v_failed := false;
  begin
    perform public.admin_create_merchant('Clínica sin MFA', null, 'J-310000009', 'clinica');
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'PASO 1: con la MFA exigida, un super_admin en aal1 no debía poder crear una clínica';
  end if;

  perform pg_temp.como(v_super);
  v_m    := (public.admin_create_merchant('Clínica Recorrido', 'Clínica Recorrido C.A.', 'J-310000001', 'clinica')).id;
  v_otra := (public.admin_create_merchant('Otra Clínica Recorrido', null, 'J-310000002', 'consultorio')).id;
  if (select category::text from public.merchants where id = v_m) is distinct from 'clinica' then
    raise exception 'PASO 1: la clínica debía quedar en la categoría clinica';
  end if;

  v_j := public.admin_set_merchant_payout_account(v_m, jsonb_build_object(
    'bank', 'Banesco', 'account_holder', 'Clínica Recorrido C.A.', 'holder_document', 'J-310000001',
    'account_number', '01340000000000000001', 'pago_movil_phone', '04141230001', 'pago_movil_bank', 'Banesco'));
  if v_j->>'account_number' is distinct from '01340000000000000001' or v_j->>'pago_movil_phone' is distinct from '+584141230001' then
    raise exception 'PASO 1: cuenta de pago de la clínica inesperada: %', v_j;
  end if;

  v_j := public.admin_set_platform_contact(jsonb_build_object(
    'whatsapp_number', '0414-000.11.22', 'sender_name', 'Helios',
    'sender_email', 'avisos@prueba.helios.test', 'support_email', 'soporte@prueba.helios.test'));
  if v_j->>'whatsapp_number' is distinct from '+584140001122' then
    raise exception 'PASO 1: el WhatsApp de Helios debía guardarse en E.164: %', v_j;
  end if;

  update public.payment_destinations set is_active = false where is_active;
  v_dest := public.admin_set_payment_destination('Banesco', 'J-500000001', '04141230002', 'Helios Pagos C.A.');
  if (select count(*) from public.payment_destinations where is_active) is distinct from 1
     or not exists (select 1 from public.payment_destinations where id = v_dest and is_active and method = 'pago_movil') then
    raise exception 'PASO 1: debía quedar exactamente una cuenta de cobro activa (Pago Móvil)';
  end if;
  reset role;

  select id into v_br from public.merchant_branches where merchant_id = v_m and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values
    (v_gerente, v_m, v_br, 'gerente'),
    (v_ana,     v_m, v_br, 'cajero'),
    (v_otro,    v_otra, (select id from public.merchant_branches where merchant_id = v_otra and is_default), 'gerente');

  if public.current_fx_rate('BCV', v_bdate) is distinct from v_rate then
    raise exception 'PASO 1: la tasa BCV del día debía ser la de la prueba';
  end if;
  if (select status::text from public.merchants where id = v_m) is distinct from 'active' then
    raise exception 'PASO 1: la clínica debía nacer activa';
  end if;
  raise notice 'PASO 1 OK — clínica con cuenta de pago, gerente y Ana, super_admin y operador con MFA, contacto, cuenta de cobro y tasa';

  -- =========================================================================
  -- PASO 2 — La clínica registra el financiamiento (Ana)
  -- =========================================================================
  v_pac := jsonb_build_object(
    'document', v_doc,
    'first_name', 'Paula', 'last_name', 'Recorrido',
    'birth_date', (v_bdate - interval '35 years')::date,
    'sex', 'F',
    'phone', '04141234599',
    'email', 'paula.recorrido@prueba.helios.test',
    'state', 'Miranda', 'city', 'Caracas', 'address', 'Chacao',
    'occupation', null,
    'reference_name', 'Pedro Recorrido', 'reference_phone', '04241112299', 'reference_relationship', 'Hermano');

  -- La fecha operativa es el día de Caracas, empezando a medianoche.
  if v_bdate is distinct from (now() at time zone 'America/Caracas')::date then
    raise exception 'PASO 2: el día operativo debía ser el día de Caracas (medianoche): % vs %',
      v_bdate, (now() at time zone 'America/Caracas')::date;
  end if;

  v_receipt0 := case when exists (select 1 from vault.secrets s where s.name = 'resend_api_key')
                     then 'pendiente' else 'sin_configurar' end;

  set local role authenticated;
  perform pg_temp.como(v_ana, 'aal1');

  v_j := public.helios_patient_eligibility(v_m, v_doc);
  if v_j->>'estado' is distinct from 'nuevo' or (v_j->>'limite_usd')::numeric is distinct from 350 then
    raise exception 'PASO 2: una cédula nueva debía responder nuevo con límite 350: %', v_j;
  end if;

  v_j := public.preview_patient_charge(v_m, v_doc, 100);
  if (v_j->>'base_usd')::numeric is distinct from 100 or (v_j->>'consumer_fee_usd')::numeric is distinct from 20
     or (v_j->>'consumer_fee_vat_usd')::numeric is distinct from 3.20
     or jsonb_array_length(v_j->'installments') is distinct from 2
     or (v_j->'installments'->0->>'amount_usd')::numeric is distinct from 61.60
     or (v_j->'installments'->1->>'amount_usd')::numeric is distinct from 61.60
     or (v_j->'installments'->0->>'due_date')::date is distinct from v_bdate + 7
     or (v_j->'installments'->1->>'due_date')::date is distinct from v_bdate + 14
     or (v_j->>'business_date')::date is distinct from v_bdate
     or not (v_j->>'cabe')::boolean then
    raise exception 'PASO 2: vista previa inesperada: %', v_j;
  end if;
  if v_j ? 'amount_usd' or v_j ? 'consumer_total_usd' or v_j::text like '%123.2%' then
    raise exception 'PASO 2: la vista previa no puede traer un total que sume el fee: %', v_j;
  end if;

  v_j := public.create_patient_charge(v_m, null, v_pac, 100, null, null, 'recorrido-1');
  v_charge := (v_j->>'id')::uuid;
  if v_j->>'status' is distinct from 'confirmed' or (v_j->>'order_number') is null
     or (v_j->>'merchant_sale_usd')::numeric is distinct from 100
     -- `pendiente` si Resend está configurado en Vault; el remoto de desarrollo
     -- no tiene la clave (y la prueba no escribe secretos): `sin_configurar`.
     or v_j->'receipt'->>'status' is distinct from v_receipt0
     or (v_j->>'staff_commission_usd')::numeric is distinct from 0.50
     or v_j->>'registered_by' is distinct from 'Ana Rivas (Secretaria)'
     or jsonb_array_length(v_j->'installments') is distinct from 2
     or (v_j->'installments'->0->>'amount_usd')::numeric is distinct from 61.60
     or (v_j->'installments'->1->>'amount_usd')::numeric is distinct from 61.60
     or (v_j->'breakdown'->>'base_usd')::numeric is distinct from 100
     or (v_j->'breakdown'->>'consumer_fee_usd')::numeric is distinct from 20
     or (v_j->'breakdown'->>'consumer_fee_vat_usd')::numeric is distinct from 3.20 then
    raise exception 'PASO 2: respuesta de create_patient_charge inesperada: %', v_j;
  end if;
  if v_j::text like '%123.2%' then
    raise exception 'PASO 2: la respuesta a la clínica no puede traer un total con el fee: %', v_j;
  end if;

  -- La misma clave: el mismo financiamiento, sin duplicar nada.
  v_j2 := public.create_patient_charge(v_m, null, v_pac, 100, null, null, 'recorrido-1');
  if v_j2->>'id' is distinct from v_charge::text or v_j2->>'order_number' is distinct from v_j->>'order_number' then
    raise exception 'PASO 2: la misma clave de idempotencia debía devolver el mismo financiamiento: % vs %', v_j2, v_j;
  end if;

  -- Ana no lee las tablas de pacientes directamente (RLS: 0 filas o sin permiso).
  begin
    if (select count(*) from public.profiles) is distinct from 0 then
      raise exception 'PASO 2: la secretaria no debía leer profiles directamente';
    end if;
  exception when insufficient_privilege then null;
  end;
  begin
    if (select count(*) from public.installments) is distinct from 0 then
      raise exception 'PASO 2: la secretaria no debía leer installments directamente';
    end if;
  exception when insufficient_privilege then null;
  end;
  begin
    if (select count(*) from public.payment_reports) is distinct from 0 then
      raise exception 'PASO 2: la secretaria no debía leer payment_reports directamente';
    end if;
  exception when insufficient_privilege then null;
  end;
  reset role;

  if (select count(*) from public.charges where idempotency_key = 'recorrido-1') is distinct from 1
     or (select count(*) from public.installments where charge_id = v_charge) is distinct from 2
     or (select count(*) from public.staff_commissions where charge_id = v_charge) is distinct from 1
     or (select count(*) from public.outbound_messages where charge_id = v_charge) is distinct from 2 then
    raise exception 'PASO 2: el reintento con la misma clave no debía duplicar nada';
  end if;
  select id into v_profile from public.profiles where document_key = v_doc;
  select * into v_i1 from public.installments where charge_id = v_charge and sequence = 1;
  select * into v_i2 from public.installments where charge_id = v_charge and sequence = 2;
  if v_profile is null or v_i1.user_id is distinct from v_profile
     or v_i1.due_date is distinct from v_bdate + 7 or v_i2.due_date is distinct from v_bdate + 14
     or v_i1.amount_usd is distinct from 61.60 or v_i2.amount_usd is distinct from 61.60
     or v_i1.status is distinct from 'pending' or v_i2.status is distinct from 'pending' then
    raise exception 'PASO 2: cuotas inesperadas: % / %', to_jsonb(v_i1), to_jsonb(v_i2);
  end if;
  if public.helios_credit_used_usd(v_profile) is distinct from 100 then
    raise exception 'PASO 2: el financiamiento debía ocupar 100 de cupo (sin el fee)';
  end if;
  raise notice 'PASO 2 OK — nuevo, vista previa 100/20/3.20 y 2×61.60 a +7/+14, alta confirmada con orden y comisión 0.50, idempotente, sin lectura directa';

  -- =========================================================================
  -- PASO 3 — El libro
  -- =========================================================================
  for v_row in
    select t.id, t.type::text as type, t.idempotency_key, sum(e.debit) as d, sum(e.credit) as c, count(*) as n
    from ledger.transactions t join ledger.entries e on e.transaction_id = t.id
    where t.reference_id = v_charge group by t.id, t.type, t.idempotency_key
  loop
    if v_row.d is distinct from v_row.c then
      raise exception 'PASO 3: asiento descuadrado: %', to_jsonb(v_row);
    end if;
  end loop;
  if (select count(*) from ledger.transactions where reference_id = v_charge) is distinct from 2 then
    raise exception 'PASO 3: el financiamiento debía tener dos asientos (venta y comisión)';
  end if;

  select
    sum(e.debit)  filter (where a.account_type = 'user_receivable' and a.owner_id = v_profile) as recv_dr,
    sum(e.credit) filter (where a.account_type = 'merchant_payable' and a.owner_id = v_m)     as pay_cr,
    sum(e.credit) filter (where a.account_type = 'platform_revenue')                          as rev_cr,
    sum(e.credit) filter (where a.account_type = 'vat_payable')                               as vat_cr,
    count(*) as n
  into v_row
  from ledger.transactions t
  join ledger.entries e on e.transaction_id = t.id
  join ledger.accounts a on a.id = e.account_id
  where t.reference_id = v_charge and t.type = 'charge';
  if v_row.n is distinct from 4 or v_row.recv_dr is distinct from 123.20 or v_row.pay_cr is distinct from 100 or v_row.rev_cr is distinct from 20 or v_row.vat_cr is distinct from 3.20 then
    raise exception 'PASO 3: la venta debía ser Dr user_receivable 123.20 / Cr merchant_payable 100 + platform_revenue 20 + vat_payable 3.20: %',
      to_jsonb(v_row);
  end if;

  select
    sum(e.debit)  filter (where a.account_type = 'commission_expense') as exp_dr,
    sum(e.credit) filter (where a.account_type = 'merchant_payable' and a.owner_id = v_m) as pay_cr,
    count(*) as n,
    min(t.idempotency_key) as k
  into v_row
  from ledger.transactions t
  join ledger.entries e on e.transaction_id = t.id
  join ledger.accounts a on a.id = e.account_id
  where t.reference_id = v_charge and t.type = 'staff_commission';
  if v_row.n is distinct from 2 or v_row.exp_dr is distinct from 0.50 or v_row.pay_cr is distinct from 0.50 or v_row.k is distinct from 'staff_commission:' || v_charge then
    raise exception 'PASO 3: la comisión debía ser Dr commission_expense 0.50 / Cr merchant_payable 0.50: %', to_jsonb(v_row);
  end if;

  if (select sum(debit) - sum(credit) from ledger.entries) is distinct from 0 then
    raise exception 'PASO 3: el libro entero no cuadra (sum(debit) is distinct from sum(credit))';
  end if;
  raise notice 'PASO 3 OK — venta de 4 patas 123.20 = 100 + 20 + 3.20, comisión 0.50, libro cuadrado';

  -- =========================================================================
  -- PASO 4 — Comprobante, bienvenida, despacho y privacidad entre clínicas
  -- =========================================================================
  select * into v_msg from public.outbound_messages
   where charge_id = v_charge and template_key = 'comprobante_financiamiento';
  if v_msg.id is null or v_msg.channel is distinct from 'email' or v_msg.status is distinct from 'pendiente'
     or v_msg.recipient is distinct from 'paula.recorrido@prueba.helios.test' then
    raise exception 'PASO 4: el comprobante debía quedar pendiente por correo: %', to_jsonb(v_msg);
  end if;
  if v_msg.rendered_text not like '%Cuota 1: $61,60%' or v_msg.rendered_text not like '%Cuota 2: $61,60%'
     or v_msg.html is null
     or (length(v_msg.html) - length(replace(v_msg.html, '61,60', ''))) / length('61,60') < 2
     or v_msg.html not like '%no es una factura%' or v_msg.rendered_text not like '%no es una factura%' then
    raise exception 'PASO 4: al comprobante le faltan las dos cuotas o «no es una factura»';
  end if;
  if v_msg.html like '%123.20%' or v_msg.html like '%123,20%'
     or v_msg.rendered_text like '%123.20%' or v_msg.rendered_text like '%123,20%'
     or coalesce(v_msg.subject, '') like '%123%' then
    raise exception 'PASO 4: el comprobante no puede mostrar 123.20 como total (fee sumado)';
  end if;
  if not exists (select 1 from public.outbound_messages
                 where charge_id = v_charge and template_key = 'bienvenida' and channel = 'whatsapp_manual'
                   and status = 'pendiente' and recipient = '+584141234599') then
    raise exception 'PASO 4: la bienvenida debía encolarse por WhatsApp manual';
  end if;

  -- El despacho con la clave falsa (paso 1) y Resend sustituido.
  insert into _respuestas (status, body) values (200, '{"id":"re_recorrido_0001"}');
  v_j := public.helios_dispatch_email_batch();
  select * into v_msg from public.outbound_messages where id = v_msg.id;
  if v_msg.status is distinct from 'enviado' or v_msg.provider_id is distinct from 're_recorrido_0001' or v_msg.sent_at is null then
    raise exception 'PASO 4: con 200 de Resend el comprobante debía quedar enviado: % / %', to_jsonb(v_msg), v_j;
  end if;
  if (select count(*) from _llamadas) is distinct from 1
     or (select body->'to'->>0 from _llamadas order by n desc limit 1) is distinct from 'paula.recorrido@prueba.helios.test'
     or (select idem from _llamadas order by n desc limit 1) is distinct from v_msg.id::text then
    raise exception 'PASO 4: debía salir exactamente una petición a Resend, al correo de la paciente';
  end if;

  set local role authenticated;
  perform pg_temp.como(v_ana, 'aal1');
  if public.helios_charge_for_staff(v_charge)->'receipt'->>'status' is distinct from 'enviado' then
    raise exception 'PASO 4: la clínica debía ver el comprobante enviado: %', public.helios_charge_for_staff(v_charge)->'receipt';
  end if;

  -- Otra clínica consulta la misma cédula: enmascarado y disponible, nada más.
  perform pg_temp.como(v_otro, 'aal1');
  v_j := public.helios_patient_eligibility(v_otra, v_doc);
  if v_j->>'estado' is distinct from 'disponible' or (v_j->>'disponible_usd')::numeric is distinct from 250
     or v_j->>'nombre_enmascarado' is distinct from 'P*** R***'
     or v_j->>'telefono_enmascarado' is distinct from '0414-***-**99'
     or v_j->>'email_enmascarado' is null or v_j->>'email_enmascarado' like '%paula.recorrido%' then
    raise exception 'PASO 4: otra clínica debía ver solo lo enmascarado y disponible 250: %', v_j;
  end if;
  if (select array_agg(k order by k) from jsonb_object_keys(v_j) k)
       is distinct from array['disponible_usd', 'email_enmascarado', 'estado', 'min_charge_usd', 'nombre_enmascarado', 'telefono_enmascarado']
     or v_j::text like '%61.6%' or v_j::text like '%123.2%' or v_j::text like '%Clínica Recorrido%' then
    raise exception 'PASO 4: la elegibilidad de otra clínica no puede revelar la deuda: %', v_j;
  end if;
  reset role;
  raise notice 'PASO 4 OK — comprobante sin total y «no es una factura», bienvenida, despacho a Resend (doble) enviado, otra clínica ve 250 enmascarado';

  -- =========================================================================
  -- PASO 5 — La víspera de la cuota 1
  -- =========================================================================
  v_j := public.helios_enqueue_reminders('cuota_manana', v_i1.due_date - 1);
  if v_j->>'due_date' is distinct from v_i1.due_date::text then
    raise exception 'PASO 5: la víspera debía apuntar a la cuota 1: %', v_j;
  end if;
  select count(*) into v_n from public.outbound_messages
   where profile_id = v_profile and template_key = 'cuota_manana' and installment_due_date = v_i1.due_date
     and status = 'pendiente';
  if v_n < 1 or not exists (
       select 1 from public.outbound_messages
        where profile_id = v_profile and template_key = 'cuota_manana' and channel = 'whatsapp_manual'
          and installment_due_date = v_i1.due_date and rendered_text like '%61,60%'
          and dedupe_key = format('cuota_manana:whatsapp_manual:%s:%s', v_profile, v_i1.due_date)) then
    raise exception 'PASO 5: cuota_manana debía encolarse con su dedupe (hay %)', v_n;
  end if;
  perform public.helios_enqueue_reminders('cuota_manana', v_i1.due_date - 1);
  if (select count(*) from public.outbound_messages
       where profile_id = v_profile and template_key = 'cuota_manana' and installment_due_date = v_i1.due_date) is distinct from v_n then
    raise exception 'PASO 5: encolar la víspera dos veces no puede duplicar';
  end if;
  raise notice 'PASO 5 OK — víspera de la cuota 1: cuota_manana (% mensajes) sin duplicar', v_n;

  -- =========================================================================
  -- PASO 6 — El equipo registra y concilia el pago de la cuota 1
  -- =========================================================================
  select coalesce(sum(ledger.account_balance(id)), 0) into v_cash0
    from ledger.accounts where account_type = 'cash' and owner_id is null;

  -- El extracto del banco trae el movimiento (referencia completa).
  set local role authenticated;
  perform pg_temp.como(v_super);
  v_j := public.admin_import_statement('Banesco', jsonb_build_array(jsonb_build_object(
    'moved_on', to_char(v_bdate, 'YYYY-MM-DD'), 'reference', '0000771001',
    'amount_ves', round(61.60 * v_rate, 2), 'description', 'PAGO MOVIL RECIBIDO')));
  if (v_j->>'inserted')::int is distinct from 1 then
    raise exception 'PASO 6: debía importarse 1 línea del extracto: %', v_j;
  end if;

  -- Sin el segundo factor el operador no registra.
  perform pg_temp.como(v_oper, 'aal1');
  v_failed := false;
  begin
    perform public.admin_register_payment(v_profile, array[v_i1.id], 'pago_movil', 'Banesco', '771001',
                                          v_bdate, round(61.60 * v_rate, 2), null, null);
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'PASO 6: con la MFA exigida, un operador en aal1 no debía registrar pagos';
  end if;

  perform pg_temp.como(v_oper);
  v_rep1 := public.admin_register_payment(v_profile, array[v_i1.id], 'pago_movil', 'Banesco', '771001',
                                          v_bdate, round(61.60 * v_rate, 2), null, 'Mandó la captura por WhatsApp');
  if v_rep1->>'status' is distinct from 'reported' or (v_rep1->>'amount_usd')::numeric is distinct from 61.60
     or (v_rep1->>'late_fee_usd')::numeric is distinct from 0 or (v_rep1->>'fx_rate')::numeric is distinct from v_rate
     or (v_rep1->>'amount_ves')::numeric is distinct from round(61.60 * v_rate, 2)
     or (v_rep1->>'diferencia_ves')::numeric is distinct from 0 or (v_rep1->>'candidatos_extracto')::int is distinct from 1 then
    raise exception 'PASO 6: registro del pago de la cuota 1 inesperado: %', v_rep1;
  end if;
  reset role;
  if (select registered_by from public.payment_reports where id = (v_rep1->>'report_id')::uuid) is distinct from v_oper then
    raise exception 'PASO 6: el pago debía quedar registrado por el operador';
  end if;
  -- Registrar ya cancela los avisos pendientes de esa fecha.
  if exists (select 1 from public.outbound_messages
             where profile_id = v_profile and installment_due_date = v_i1.due_date and status = 'pendiente') then
    raise exception 'PASO 6: registrar el pago debía cancelar los avisos pendientes de la cuota 1';
  end if;

  set local role authenticated;
  perform pg_temp.como(v_super);
  v_j := public.admin_reconcile_payment((v_rep1->>'report_id')::uuid, true, null);
  if v_j->>'status' is distinct from 'reconciled' or (v_j->>'amount_usd')::numeric is distinct from 61.60 or v_j->>'statement_line_id' is null then
    raise exception 'PASO 6: la conciliación de la cuota 1 debía aprobarse ligada al extracto: %', v_j;
  end if;
  reset role;

  select * into v_i1 from public.installments where id = v_i1.id;
  if v_i1.status is distinct from 'paid' or v_i1.paid_by_report_id is distinct from (v_rep1->>'report_id')::uuid then
    raise exception 'PASO 6: la cuota 1 debía quedar pagada por ese reporte: %', to_jsonb(v_i1);
  end if;
  if (select status::text from public.payment_reports where id = (v_rep1->>'report_id')::uuid) is distinct from 'reconciled'
     or (select status::text from public.bank_statement_lines
          where id = (select statement_line_id from public.payment_reports where id = (v_rep1->>'report_id')::uuid)) is distinct from 'asignado' then
    raise exception 'PASO 6: el reporte debía quedar conciliado y la línea del extracto asignada';
  end if;
  select
    sum(e.debit)  filter (where a.account_type = 'cash') as cash_dr,
    sum(e.credit) filter (where a.account_type = 'user_receivable' and a.owner_id = v_profile) as recv_cr,
    sum(e.debit) - sum(e.credit) as diff
  into v_row
  from ledger.transactions t
  join ledger.entries e on e.transaction_id = t.id
  join ledger.accounts a on a.id = e.account_id
  where t.idempotency_key = 'reconcile:' || (v_rep1->>'report_id');
  if v_row.cash_dr is distinct from 61.60 or v_row.recv_cr is distinct from 61.60 or v_row.diff is distinct from 0 then
    raise exception 'PASO 6: el pago debía asentarse Dr cash 61.60 / Cr user_receivable 61.60: %', to_jsonb(v_row);
  end if;
  if not exists (select 1 from public.outbound_messages
                 where dedupe_key = 'pago_recibido:' || (v_rep1->>'report_id') and status = 'pendiente'
                   and profile_id = v_profile and rendered_text like '%61,60%') then
    raise exception 'PASO 6: conciliar debía encolar pago_recibido';
  end if;
  if (select count(*) from public.outbound_messages
       where profile_id = v_profile and template_key = 'cuota_manana'
         and installment_due_date = v_i1.due_date and status = 'cancelado') is distinct from v_n then
    raise exception 'PASO 6: los avisos de la víspera de la cuota 1 debían quedar cancelados';
  end if;
  -- El cupo se libera por financiamiento: con una cuota pagada sigue ocupado.
  if public.helios_credit_used_usd(v_profile) is distinct from 100
     or not exists (select 1 from public.user_credit_blocks where user_id = v_profile and closed_at is null) then
    raise exception 'PASO 6: con solo la cuota 1 pagada el cupo seguía ocupado (100) y el bloque abierto';
  end if;
  set local role authenticated;
  perform pg_temp.como(v_otro, 'aal1');
  v_j := public.helios_patient_eligibility(v_otra, v_doc);
  if v_j->>'estado' is distinct from 'disponible' or (v_j->>'disponible_usd')::numeric is distinct from 250 then
    raise exception 'PASO 6: el disponible debía seguir en 250 hasta pagar ambas cuotas: %', v_j;
  end if;
  reset role;
  raise notice 'PASO 6 OK — operador registra (Bs a la tasa del día), super_admin concilia con el extracto: cuota 1 pagada, caja, pago_recibido, avisos cancelados, cupo aún 250';

  -- =========================================================================
  -- PASO 7 — Mora en la cuota 2 y su pago
  -- =========================================================================
  -- Día 1 de atraso: congelada, sin cargo (la gracia es solo del cargo).
  update public.installments set due_date = v_bdate - 1 where id = v_i2.id;
  perform public.recompute_profile_mora_state(v_profile);
  if (select status::text from public.profiles where id = v_profile) is distinct from 'frozen' then
    raise exception 'PASO 7: con la cuota 2 vencida ayer la paciente debía quedar congelada (día 1)';
  end if;
  if exists (select 1 from public.late_fees where user_id = v_profile) then
    raise exception 'PASO 7: el día 1 está dentro de la gracia: no debía haber cargo';
  end if;
  if (select count(*) from public.outbound_messages
       where profile_id = v_profile and template_key = 'cuenta_congelada' and status = 'pendiente') is distinct from 1 then
    raise exception 'PASO 7: congelarse debía encolar un cuenta_congelada';
  end if;

  -- 4 días de atraso: pasada la gracia (3), un cargo de $2 sobre la cuota 2.
  update public.installments set due_date = v_bdate - (public.helios_late_fee_grace_days() + 1) where id = v_i2.id;
  select * into v_i2 from public.installments where id = v_i2.id;
  if v_i2.due_date is distinct from v_bdate - 4 then
    raise exception 'PASO 7: la prueba supone 3 días de gracia (cuota 2 con 4 días de atraso)';
  end if;
  perform public.recompute_profile_mora_state(v_profile);
  perform public.recompute_profile_mora_state(v_profile);
  perform public.recompute_profile_mora_state(v_profile);
  if (select count(*) from public.late_fees where user_id = v_profile) is distinct from 1
     or (select amount_usd from public.late_fees where user_id = v_profile) is distinct from 2
     or (select installment_id from public.late_fees where user_id = v_profile) is distinct from v_i2.id
     or (select status::text from public.late_fees where user_id = v_profile) is distinct from 'pending' then
    raise exception 'PASO 7: debía haber UN cargo de $2 pendiente sobre la cuota 2 (hay %)',
      (select count(*) from public.late_fees where user_id = v_profile);
  end if;
  select id into v_fee_id from public.late_fees where user_id = v_profile;
  if (select status::text from public.profiles where id = v_profile) is distinct from 'frozen' then
    raise exception 'PASO 7: con 4 días de atraso la paciente sigue congelada';
  end if;
  if (select count(*) from public.outbound_messages where profile_id = v_profile and template_key = 'cuenta_congelada') is distinct from 1 then
    raise exception 'PASO 7: seguir congelada no es una transición: un solo cuenta_congelada';
  end if;
  select sum(e.debit)  filter (where a.account_type = 'user_receivable' and a.owner_id = v_profile) as dr,
         sum(e.credit) filter (where a.account_type = 'platform_revenue') as cr
    into v_row
  from ledger.transactions t join ledger.entries e on e.transaction_id = t.id
  join ledger.accounts a on a.id = e.account_id
  where t.idempotency_key = 'late_fee:' || v_fee_id;
  if v_row.dr is distinct from 2 or v_row.cr is distinct from 2 then
    raise exception 'PASO 7: el cargo debía asentarse Dr user_receivable 2 / Cr platform_revenue 2: %', to_jsonb(v_row);
  end if;

  -- +4 días: el aviso del cargo (ya cobrado), con la cuota + el cargo.
  perform public.helios_enqueue_reminders('cargo_por_atraso_d4', v_bdate);
  if not exists (select 1 from public.outbound_messages
                 where profile_id = v_profile and template_key = 'cargo_por_atraso_d4'
                   and installment_due_date = v_i2.due_date and status = 'pendiente'
                   and rendered_text like '%63,60%') then
    raise exception 'PASO 7: debía encolarse cargo_por_atraso_d4 con $63.60';
  end if;

  -- Cualquier clínica: «no disponible», con el texto neutro y sin el motivo.
  v_neutral := public.helios_not_available_message();
  set local role authenticated;
  perform pg_temp.como(v_ana, 'aal1');
  v_j := public.helios_patient_eligibility(v_m, v_doc);
  perform pg_temp.como(v_otro, 'aal1');
  v_j2 := public.helios_patient_eligibility(v_otra, v_doc);
  reset role;
  if v_j->>'estado' is distinct from 'no_disponible' or v_j is distinct from v_j2
     or (select array_agg(k order by k) from jsonb_object_keys(v_j) k) is distinct from array['estado', 'mensaje', 'whatsapp_helios']
     or v_j->>'mensaje' is distinct from v_neutral or v_j->>'whatsapp_helios' is distinct from '+584140001122'
     or v_j->>'mensaje' ~* '(mora|atras|venc|deud|cuota|congel|\$)' then
    raise exception 'PASO 7: la elegibilidad debía ser no_disponible con el texto neutro y nada más: % / %', v_j, v_j2;
  end if;

  -- El pago de la cuota 2 + el cargo.
  set local role authenticated;
  perform pg_temp.como(v_super);
  perform public.admin_import_statement('Banesco', jsonb_build_array(jsonb_build_object(
    'moved_on', to_char(v_bdate, 'YYYY-MM-DD'), 'reference', '0000771002',
    'amount_ves', round(63.60 * v_rate, 2), 'description', 'PAGO MOVIL RECIBIDO')));
  perform pg_temp.como(v_oper);
  v_rep2 := public.admin_register_payment(v_profile, array[v_i2.id], 'pago_movil', 'Banesco', '771002',
                                          v_bdate, round(63.60 * v_rate, 2), null, 'Pagó la cuota 2 con el cargo');
  if v_rep2->>'status' is distinct from 'reported' or (v_rep2->>'amount_usd')::numeric is distinct from 63.60
     or (v_rep2->>'late_fee_usd')::numeric is distinct from 2 or (v_rep2->>'installments_usd')::numeric is distinct from 61.60
     or (v_rep2->>'candidatos_extracto')::int is distinct from 1 or (v_rep2->>'diferencia_ves')::numeric is distinct from 0 then
    raise exception 'PASO 7: el registro de la cuota 2 debía llevar el cargo (63.60): %', v_rep2;
  end if;
  perform pg_temp.como(v_super);
  v_j := public.admin_reconcile_payment((v_rep2->>'report_id')::uuid, true, null);
  if v_j->>'status' is distinct from 'reconciled' or (v_j->>'amount_usd')::numeric is distinct from 63.60
     or (v_j->>'late_fee_count')::int is distinct from 1 or v_j->>'statement_line_id' is null then
    raise exception 'PASO 7: la conciliación de la cuota 2 + cargo inesperada: %', v_j;
  end if;
  reset role;

  if (select status::text from public.installments where id = v_i2.id) is distinct from 'paid'
     or (select status::text from public.late_fees where id = v_fee_id) is distinct from 'paid' then
    raise exception 'PASO 7: la cuota 2 y su cargo debían quedar pagados';
  end if;
  if (select status::text from public.profiles where id = v_profile) is distinct from 'active' then
    raise exception 'PASO 7: al pagar todo la paciente debía volver a active (está %)',
      (select status from public.profiles where id = v_profile);
  end if;
  if exists (select 1 from public.user_credit_blocks where user_id = v_profile and closed_at is null)
     or not exists (select 1 from public.user_credit_blocks where user_id = v_profile and close_reason = 'paid') then
    raise exception 'PASO 7: el bloque de crédito debía cerrarse como pagado';
  end if;
  if public.helios_credit_used_usd(v_profile) is distinct from 0 then
    raise exception 'PASO 7: con las dos cuotas pagadas el cupo ocupado debía ser 0';
  end if;
  set local role authenticated;
  perform pg_temp.como(v_otro, 'aal1');
  v_j := public.helios_patient_eligibility(v_otra, v_doc);
  reset role;
  if v_j->>'estado' is distinct from 'disponible' or (v_j->>'disponible_usd')::numeric is distinct from 350 then
    raise exception 'PASO 7: pagado todo, el disponible debía volver a 350: %', v_j;
  end if;
  if exists (select 1 from public.outbound_messages
             where profile_id = v_profile and template_key in ('cuenta_congelada', 'cargo_por_atraso_d4')
               and status = 'pendiente') then
    raise exception 'PASO 7: al pagar, cuenta_congelada y cargo_por_atraso_d4 pendientes debían cancelarse';
  end if;
  if not exists (select 1 from public.outbound_messages
                 where dedupe_key = 'pago_recibido:' || (v_rep2->>'report_id') and status = 'pendiente') then
    raise exception 'PASO 7: conciliar la cuota 2 debía encolar pago_recibido';
  end if;
  raise notice 'PASO 7 OK — mora: congelada el día 1, un cargo de $2 al día 4 (idempotente), avisos, no_disponible neutro; pagada la cuota 2 + cargo: activa, cupo 350, bloque cerrado';

  -- =========================================================================
  -- PASO 8 — La liquidación a la clínica
  -- =========================================================================
  perform public.run_scheduled_settlements(v_i1.due_date);
  perform public.run_scheduled_settlements(v_i2.due_date);
  perform public.run_scheduled_settlements(v_i1.due_date);   -- otra vez: no duplica
  perform public.run_scheduled_settlements(v_i2.due_date);
  if (select count(*) from public.settlements
       where merchant_id = v_m and reason = 'scheduled_installment' and amount_usd = 50 and status = 'pending') is distinct from 2
     or (select count(*) from public.settlements where merchant_id = v_m and reason = 'scheduled_installment') is distinct from 2
     or (select count(*) from public.settlements
          where merchant_id = v_m and reason = 'staff_commission' and amount_usd = 0.50 and status = 'pending') is distinct from 1
     or (select count(*) from public.settlements where merchant_id = v_m) is distinct from 3 then
    raise exception 'PASO 8: la clínica debía tener 50 + 50 (scheduled_installment) + 0.50 (staff_commission): %',
      (select jsonb_agg(jsonb_build_object('reason', reason, 'amount', amount_usd, 'status', status))
         from public.settlements where merchant_id = v_m);
  end if;

  set local role authenticated;
  perform pg_temp.como(v_super);
  v_j := public.admin_merchant_payables(v_m);
  if jsonb_array_length(v_j) is distinct from 1 or (v_j->0->>'consultas_usd')::numeric is distinct from 100
     or (v_j->0->>'comisiones_usd')::numeric is distinct from 0.50 then
    raise exception 'PASO 8: admin_merchant_payables debía decir consultas 100 y comisiones 0.50: %', v_j;
  end if;

  select array_agg(id) into v_ids from public.settlements where merchant_id = v_m and status = 'pending';
  v_payout := public.admin_report_merchant_payout(v_m, v_ids, 'transferencia', 'TRF-RECORRIDO-1');
  if (v_payout->>'amount_usd')::numeric is distinct from 100.50 or (v_payout->>'consultas_usd')::numeric is distinct from 100
     or (v_payout->>'comisiones_usd')::numeric is distinct from 0.50 then
    raise exception 'PASO 8: la transferencia debía ser 100.50 = 100 + 0.50: %', v_payout;
  end if;
  reset role;

  if (select status::text from public.staff_commissions where charge_id = v_charge) is distinct from 'pagada' then
    raise exception 'PASO 8: la comisión de Ana debía quedar pagada';
  end if;
  select * into v_row from public.merchant_payouts where id = (v_payout->>'payout_id')::uuid;
  if v_row.consultas_usd is distinct from 100 or v_row.comisiones_usd is distinct from 0.50 or v_row.merchant_id is distinct from v_m then
    raise exception 'PASO 8: merchant_payouts debía guardar consultas 100 y comisiones 0.50: %', to_jsonb(v_row);
  end if;
  if exists (select 1 from public.settlements where merchant_id = v_m and status is distinct from 'paid') then
    raise exception 'PASO 8: todas las liquidaciones de la clínica debían quedar pagadas';
  end if;
  if (select coalesce(sum(e.credit) - sum(e.debit), 0) from ledger.entries e join ledger.accounts a on a.id = e.account_id
      where a.account_type = 'merchant_payable' and a.owner_id = v_m) is distinct from 0 then
    raise exception 'PASO 8: tras la transferencia a la clínica no se le debía nada';
  end if;

  -- Lo que ve el gerente.
  set local role authenticated;
  perform pg_temp.como(v_gerente, 'aal1');
  v_j := public.merchant_settlement_outlook();
  if (v_j->>'comisiones_usd')::numeric is distinct from 0 or (v_j->>'consultas_usd')::numeric is distinct from 0
     or (v_j->>'last_payout_usd')::numeric is distinct from 100.50 or (v_j->>'last_payout_on') is null then
    raise exception 'PASO 8: merchant_settlement_outlook del gerente debía mostrar la transferencia pagada: %', v_j;
  end if;
  select * into v_row from public.merchant_commissions(v_bdate, v_bdate) mc where mc.staff_user_id = v_ana;
  if v_row.amount_usd is distinct from 0.50 or v_row.paid_usd is distinct from 0.50 or v_row.pending_usd is distinct from 0
     or v_row.charge_count is distinct from 1 or v_row.staff_name is distinct from 'Ana Rivas' then
    raise exception 'PASO 8: el gerente debía ver la comisión de Ana pagada: %', to_jsonb(v_row);
  end if;
  if (select comisiones_usd from public.merchant_payouts where id = (v_payout->>'payout_id')::uuid) is distinct from 0.50 then
    raise exception 'PASO 8: el gerente debía leer su transferencia partida';
  end if;
  -- Lo que ve la secretaria: solo su fila.
  perform pg_temp.como(v_ana, 'aal1');
  if (select count(*) from public.merchant_commissions(v_bdate, v_bdate)) is distinct from 1
     or exists (select 1 from public.merchant_commissions(v_bdate, v_bdate) mc where mc.staff_user_id is distinct from v_ana)
     or (select paid_usd from public.merchant_commissions(v_bdate, v_bdate)) is distinct from 0.50 then
    raise exception 'PASO 8: la secretaria debía ver solo su fila de comisiones, pagada';
  end if;
  reset role;
  raise notice 'PASO 8 OK — liquidación 50 + 50 + 0.50, payables partido, transferencia 100.50, comisión pagada, gerente y secretaria lo ven';

  -- =========================================================================
  -- PASO 9 — Bitácora
  -- =========================================================================
  if (select count(*) from audit.admin_actions
       where action = 'payment.registered' and actor = v_oper
         and target_id in ((v_rep1->>'report_id')::uuid, (v_rep2->>'report_id')::uuid)) is distinct from 2 then
    raise exception 'PASO 9: los dos registros de pago debían quedar en la bitácora';
  end if;
  if (select count(*) from audit.admin_actions
       where action = 'payment.reconciled' and actor = v_super
         and target_id in ((v_rep1->>'report_id')::uuid, (v_rep2->>'report_id')::uuid)) is distinct from 2 then
    raise exception 'PASO 9: las dos conciliaciones debían quedar en la bitácora';
  end if;
  if not exists (select 1 from audit.admin_actions
                 where action = 'merchant.payout' and actor = v_super and target_id = v_m) then
    raise exception 'PASO 9: la transferencia a la clínica debía quedar en la bitácora';
  end if;
  if not exists (select 1 from audit.admin_actions where action = 'charge.created' and target_id = v_charge and actor = v_ana) then
    raise exception 'PASO 9: el alta del financiamiento debía quedar en la bitácora';
  end if;
  raise notice 'PASO 9 OK — bitácora: alta, 2 registros, 2 conciliaciones y la transferencia';

  -- =========================================================================
  -- PASO 10 — Cierre
  -- =========================================================================
  if (select sum(debit) - sum(credit) from ledger.entries) is distinct from 0 then
    raise exception 'PASO 10: el libro entero no cuadra';
  end if;
  if (select coalesce(sum(e.debit) - sum(e.credit), 0) from ledger.entries e join ledger.accounts a on a.id = e.account_id
      where a.account_type = 'user_receivable' and a.owner_id = v_profile) is distinct from 0 then
    raise exception 'PASO 10: la paciente no debía deber nada en el libro';
  end if;
  select coalesce(sum(ledger.account_balance(id)), 0) into v_cash1
    from ledger.accounts where account_type = 'cash' and owner_id is null;
  -- Entró 61.60 + 63.60 = 125.20 y salió 100.50: la caja sube 24.70
  -- (= fee 20 + IVA 3.20 + cargo 2 − comisión 0.50).
  if v_cash1 - v_cash0 is distinct from 24.70 then
    raise exception 'PASO 10: la caja debía subir 24.70 en el recorrido, subió %', v_cash1 - v_cash0;
  end if;
  if exists (select 1 from public.installments where charge_id = v_charge and status is distinct from 'paid')
     or exists (select 1 from public.late_fees where user_id = v_profile and status is distinct from 'paid')
     or exists (select 1 from public.payment_reports where user_id = v_profile and status::text in ('reported', 'in_review'))
     or exists (select 1 from public.user_credit_blocks where user_id = v_profile and closed_at is null)
     or exists (select 1 from public.settlements where merchant_id = v_m and status is distinct from 'paid') then
    raise exception 'PASO 10: quedó algo pendiente (cuotas, cargos, pagos, bloque o liquidaciones)';
  end if;
  -- En la cola solo queda lo que el equipo manda a mano: la bienvenida y los
  -- dos pago_recibido. Ningún recordatorio de una deuda ya pagada.
  select string_agg(template_key || ':' || channel, ', ' order by template_key) into v_err
    from public.outbound_messages where profile_id = v_profile and status = 'pendiente';
  if v_err is distinct from 'bienvenida:whatsapp_manual, pago_recibido:whatsapp_manual, pago_recibido:whatsapp_manual' then
    raise exception 'PASO 10: en la cola debían quedar solo la bienvenida y los dos pago_recibido, quedan: %', v_err;
  end if;
  if (select status from public.outbound_messages
       where charge_id = v_charge and template_key = 'comprobante_financiamiento') is distinct from 'enviado' then
    raise exception 'PASO 10: el comprobante debía seguir enviado';
  end if;
  raise notice 'PASO 10 OK — libro cuadrado, caja +24.70, nada pendiente salvo los WhatsApp manuales que tocan';

  raise notice '=== RECORRIDO COMPLETO DE UN FINANCIAMIENTO: TODO VERDE ===';
end $$;

set constraints all immediate;

rollback;
