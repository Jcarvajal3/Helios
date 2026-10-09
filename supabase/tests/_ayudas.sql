-- ============================================================================
-- Helios — Ayudas de las pruebas de humo
--
-- NO es una suite. `run.sh` pega este archivo dentro de cada suite, en el
-- lugar de la línea `-- @ayudas` (justo después de su `begin;`). Así las
-- funciones viven en `pg_temp`, dentro de la transacción de la suite, y el
-- `rollback` final se las lleva: nunca queda nada en la base.
--
-- Por qué existen: en Ronda la deuda nacía de `request_charge` (el cajero) +
-- `confirm_charge` (el cliente con su PIN, escaneando el QR). Helios poda las
-- dos (20261001000000_la_poda_de_la_app) y la RPC que las sustituye,
-- `create_patient_charge`, llega con H4. Mientras tanto, las suites de dinero
-- crean la deuda con `pg_temp.prueba_cobro`, que hace EXACTAMENTE lo que hacía
-- `confirm_charge` sin el PIN ni el reclamo: el mismo desglose
-- (`helios_charge_breakdown`), el mismo asiento de cuatro patas, el mismo
-- devengo (`ledger.record_advance_settlement`) y la misma y única función que
-- crea deuda (`helios_assign_debt`). Cuando exista `create_patient_charge`,
-- las suites deberían pasar a usarla y esto se borra.
--
-- Pacientes (H3, 20261002000300): el paciente NO tiene cuenta en Auth. Una
-- suite crea sus pacientes con `insert into public.profiles (id, phone_e164)`
-- (nacen `active` y en nivel 1) y solo el PERSONAL va a `auth.users`.
-- `pg_temp.quote_installments` y `pg_temp.report_payment` envuelven las RPC
-- de la app (sin permiso para la API desde H3) para que las suites de pago
-- sigan cotizando y reportando «como el paciente» (con sus claims) hasta que
-- exista `admin_register_payment` (fase 3).
-- ============================================================================

-- Las suites no dependen de la configuración real: dentro de su transacción
-- la confirmación del paciente por WhatsApp arranca APAGADA (el registro
-- confirma al instante). Las suites que la prueban la encienden después.
insert into public.business_parameters (key, value, effective_from, note)
values ('patient_confirmation_required', 0, public.helios_business_date(now()), 'pruebas (rollback)')
on conflict (key, effective_from) do update set value = 0;

-- Desde el 2026-10-07 no se cobran cargos por mora (`late_fee_usd` = 0), pero
-- el motor sigue en el código para retomarlo: las suites lo siguen probando
-- con el cargo de siempre, $2. `sin_mora_smoke` prueba el modo apagado.
insert into public.business_parameters (key, value, effective_from, note)
values ('late_fee_usd', 2, public.helios_business_date(now()), 'pruebas (rollback)')
on conflict (key, effective_from) do update set value = 2;

-- La base de Helios es la de PRODUCCIÓN (2026-10-08): tiene el contacto, el
-- remitente y las cuentas de cobro reales. Las suites arrancan como una base
-- recién creada —sin contacto ni cuentas activas— y configuran lo suyo; si
-- no, una prueba lee el banco real («Banco Nacional de Crédito») o cuenta
-- una cuenta de más. Igual que lo de arriba, el `rollback` lo deshace.
update public.platform_contact
   set whatsapp_number = null, support_email = null, support_hours = null,
       sender_name = null, sender_email = null
 where id;
update public.payment_destinations set is_active = false where is_active;

-- Y la cola real: los mensajes que ya había quedan fuera del alcance de los
-- despachadores (`helios_dispatch_*`: pendientes con la hora ya cumplida) y
-- de `helios_check_email_status` (enviados sin revisar en un rato). Si no,
-- un correo real de hace un minuto se cuela en la prueba y se lleva una de
-- sus respuestas simuladas (2026-10-09). Como lo de arriba, el `rollback`
-- lo deshace.
update public.outbound_messages
   set next_attempt_at = now() + interval '1 day',
       last_checked_at = now()
 where status in ('pendiente', 'enviado');

/**
 * Un consumo confirmado de `p_base` (sin fee) para `p_user` en `p_merchant`,
 * registrado por `p_staff`. Devuelve lo mismo que devolvía `confirm_charge`.
 * Lanza los mismos errores de negocio (cupo, mora, bloqueo, local pausado).
 */
create function pg_temp.prueba_cobro(
  p_user     uuid,
  p_merchant uuid,
  p_branch   uuid,
  p_staff    uuid,
  p_base     numeric,
  p_key      text,
  p_concepto text default 'Consulta'
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_status   public.merchant_status;
  v_terms    public.merchant_settlement_terms%rowtype;
  v_b        jsonb;
  v_charge   public.charges%rowtype;
  v_profile  public.profiles%rowtype;
  v_stop     jsonb;
  v_limit    numeric(18,4);
  v_open     numeric(18,4);
  v_financed numeric(18,4);
  v_bdate    date;
  v_due_1    date;
  v_due_2    date;
  v_tx       uuid;
  v_recv     uuid;
  v_pay      uuid;
  v_rev      uuid;
  v_revenue  numeric(18,4);
  v_share    numeric(18,4);
  v_split    jsonb;
begin
  -- Lo que comprobaba request_charge ------------------------------------
  select status into v_status from public.merchants where id = p_merchant;
  if v_status is distinct from 'active' then
    raise exception 'Este local no puede cobrar: está %', v_status using errcode = '22023';
  end if;
  -- Helios (H1): el mínimo es el parámetro `min_charge_usd`, no los 5 euros de Ronda.
  perform public.helios_assert_charge_amount(p_base);

  select * into v_terms from public.merchant_settlement_terms where merchant_id = p_merchant;
  v_b := public.helios_charge_breakdown(p_base, coalesce(v_terms.commission_pct, 0));

  insert into public.charges (
    merchant_id, branch_id, requested_by, idempotency_key,
    amount_usd, base_usd, vat_pct, vat_usd,
    consumer_fee_pct, consumer_fee_usd, consumer_fee_vat_usd,
    merchant_fee_pct, merchant_fee_usd, merchant_fee_vat_usd, merchant_net_usd
  ) values (
    p_merchant, p_branch, p_staff, p_key,
    (v_b->>'consumer_total_usd')::numeric, (v_b->>'base_usd')::numeric,
    (v_b->>'vat_pct')::numeric, (v_b->>'vat_usd')::numeric,
    (v_b->>'consumer_fee_pct')::numeric, (v_b->>'consumer_fee_usd')::numeric,
    (v_b->>'consumer_fee_vat_usd')::numeric,
    (v_b->>'merchant_fee_pct')::numeric, (v_b->>'merchant_fee_usd')::numeric,
    (v_b->>'merchant_fee_vat_usd')::numeric, (v_b->>'merchant_net_usd')::numeric
  )
  returning * into v_charge;

  insert into public.charge_items (charge_id, product_id, name, unit_price_usd, quantity, position)
  values (v_charge.id, null, p_concepto, (v_b->>'base_usd')::numeric, 1, 0);

  -- Lo que comprobaba y hacía confirm_charge, sin PIN ni QR --------------
  select * into v_profile from public.profiles where id = p_user for update;
  if v_profile.status <> 'active' then
    raise exception 'La cuenta no puede consumir en este estado (%)', v_profile.status
      using errcode = '22023';
  end if;

  v_stop := public.helios_spend_block(p_user);
  if coalesce((v_stop->>'blocks_balance')::boolean, false) then
    raise exception '%', v_stop->>'message' using errcode = '22023';
  end if;

  if not public.can_take_debt(p_user) then
    raise exception 'Tienes una cuota vencida: págala para volver a consumir'
      using errcode = '22023';
  end if;

  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);
  select monthly_limit_usd into v_limit from public.levels where level = v_profile.level;
  v_open := public.helios_credit_used_usd(p_user);
  if v_open + v_financed > v_limit then
    raise exception 'Saldo insuficiente: disponible %, consumo %', (v_limit - v_open), v_financed
      using errcode = '22023';
  end if;

  v_bdate := public.helios_business_date(now());
  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_bdate);

  v_recv := ledger.get_or_create_account('user_receivable', p_user);
  v_pay  := ledger.get_or_create_account('merchant_payable', v_charge.merchant_id);
  v_rev  := ledger.get_or_create_account('platform_revenue', null);

  v_revenue := coalesce(v_charge.consumer_fee_usd, 0) + coalesce(v_charge.merchant_fee_usd, 0);
  v_share   := coalesce(v_charge.merchant_net_usd, v_charge.amount_usd - v_revenue);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', p_key || '-confirm', v_bdate, v_charge.id, 'Venta en comercio')
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit)
  select v_tx, x.acct, x.debit, x.credit
  from (values
    (v_recv, v_charge.amount_usd, 0::numeric),
    (v_pay, 0::numeric, v_share),
    (v_rev, 0::numeric, v_revenue),
    (ledger.get_or_create_account('vat_payable', null), 0::numeric,
     v_charge.amount_usd - v_share - v_revenue)
  ) as x(acct, debit, credit)
  where x.debit <> 0 or x.credit <> 0;

  perform ledger.record_advance_settlement(
    v_charge.merchant_id, v_charge.id, round(v_share * v_terms.upfront_pct / 100, 4), v_bdate);

  v_split := public.helios_assign_debt(
    p_user, v_charge.id, v_financed, v_charge.amount_usd, v_due_1, v_due_2,
    format('Saldo insuficiente para un consumo de %s', v_financed));

  update public.charges
     set status = 'confirmed', user_id = p_user, business_date = v_bdate, confirmed_at = now()
   where id = v_charge.id;

  return jsonb_build_object(
    'ok', true, 'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd, 'financed_usd', v_financed,
    'due_1', v_due_1, 'due_2', v_due_2,
    'installment_1_usd', (v_split->>'installment_1_usd')::numeric,
    'installment_2_usd', (v_split->>'installment_2_usd')::numeric
  );
end;
$$;

/**
 * El saldo de una persona, con la forma que devolvía `my_available_balance()`
 * (podada: era la vista del usuario en la app, con `auth.uid()`), sin la
 * reserva de grupos. Es lo que las suites de Ronda afirmaban.
 */
create function pg_temp.prueba_saldo(p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit     numeric(18,4);
  v_block     public.user_credit_blocks%rowtype;
  v_used      numeric(18,4);
  v_fee       numeric(18,4) := 0;
  v_to_unlock numeric(18,4) := 0;
  v_arrears   boolean;
  v_stop      jsonb;
  v_stopped   boolean;
  v_next_owed numeric(18,4);
  v_next_free numeric(18,4);
begin
  select l.monthly_limit_usd into v_limit
  from public.profiles p join public.levels l on l.level = p.level
  where p.id = p_user;

  v_arrears := public.helios_in_arrears(p_user);
  v_used    := public.helios_credit_used_usd(p_user);
  v_stop    := public.helios_spend_block(p_user);
  v_stopped := coalesce((v_stop->>'blocks_balance')::boolean, false);

  select * into v_block from public.user_credit_blocks where user_id = p_user and closed_at is null;
  if found then
    v_fee := v_block.fee_usd;
    v_to_unlock := v_block.charged_usd + v_block.fee_usd - v_block.paid_usd;
  end if;

  select owed, frees into v_next_owed, v_next_free
  from (
    select sum(i.amount_usd) filter (where i.status = 'pending') as owed,
           sum(i.financed_usd) as frees
    from public.installments i
    where i.user_id = p_user
      and exists (select 1 from public.installments j
                  where j.charge_id = i.charge_id and j.user_id = i.user_id and j.status = 'pending')
    group by i.charge_id
  ) c
  order by owed
  limit 1;

  return jsonb_build_object(
    'limit_usd', v_limit,
    'available_usd', case when v_arrears or v_stopped then 0
                          else greatest(v_limit - v_used, 0) end,
    'in_arrears', v_arrears,
    'spend_block', v_stop,
    'open_debt_usd', v_used,
    'service_fee_usd', v_fee,
    'amount_to_unlock_usd', v_to_unlock,
    'next_unlock_owed_usd', v_next_owed,
    'next_unlock_frees_usd', v_next_free
  );
end;
$$;

/**
 * Un super admin activo, para las suites de métricas que se hacen pasar por
 * «un admin activo» (en Ronda lo tomaban de los datos de dev; la base de
 * Helios nace sin equipo). Cuenta de correo sin contraseña, dentro de la
 * transacción: se va con el rollback.
 */
create function pg_temp.prueba_admin()
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'admin-' || v_id || '@prueba.helios.test', now(), now(), now());
  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_id, 'super_admin', 'Admin de prueba', true);
  return v_id;
end;
$$;

/**
 * `quote_installments` y `report_payment` eran de la app: el deudor cotizaba y
 * reportaba con SU sesión (`auth.uid()`). Desde H3 la API no puede
 * ejecutarlas; estas envolturas corren como el dueño de la transacción
 * (security definer) y respetan los claims que la suite puso, así que
 * `auth.uid()` sigue siendo el paciente de la prueba.
 */
create function pg_temp.quote_installments(p_installment_ids uuid[])
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$ select public.quote_installments(p_installment_ids) $$;

create function pg_temp.report_payment(
  p_quote_id       uuid,
  p_method         text,
  p_bank           text,
  p_reference      text,
  p_payer_document text default null,
  p_payer_phone    text default null,
  p_receipt_path   text default null
)
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  select public.report_payment(p_quote_id, p_method, p_bank, p_reference,
                               p_payer_document, p_payer_phone, p_receipt_path)
$$;
