-- ============================================================================
-- Helios — Lo de capacitación se borra a medianoche
--
-- 20261014100200 retiraba a los pacientes de capacitación (sin cédula, la fila
-- seguía): cada capacitación dejaba pacientes muertos en el padrón del
-- superadmin. Decisión de Javier (2026-10-14): a medianoche se borran del
-- todo, el paciente y sus órdenes.
--
-- Lo que impedía borrarlos era el libro: la confirmación escribe el asiento
-- de la orden, y el libro es append-only (`transactions_no_delete`,
-- `entries_no_delete`). Apagar esas protecciones cada noche desde un trabajo
-- automático, sin respaldo ni nadie mirando, no se hace. En vez de eso:
--
--   1. Una orden de un paciente de capacitación (`is_demo`) no escribe en el
--      libro: ni el asiento de cuatro patas ni el adelanto. Nunca fue dinero
--      (no se le liquida a la clínica desde 20261014100000 y no se cobra).
--      Todo lo demás de la confirmación sigue igual: cuotas, comprobante,
--      bienvenida y aviso al médico.
--
--   2. `helios_demo_purge` borra, de las hojas a la raíz, todo lo de los
--      pacientes de capacitación SIN rastro en el libro: cotizaciones,
--      cuotas, mensajes, órdenes, notificaciones, límite, consultas de cédula
--      y el paciente. Las sesiones del bot que recordaban una de esas órdenes
--      vuelven al menú y los contactos de WhatsApp se quedan sin paciente
--      (el número sigue: es el del capacitador). Nunca toca la bitácora.
--      No borra a nadie con algo pagado, un pago reportado o una liquidación:
--      ese sale en `sin_reiniciar` y se mira a mano.
--
--   3. `helios_demo_reset` (medianoche y el botón): anula lo que espera el
--      «sí», revierte lo que sí tiene asiento (las órdenes de antes de esta
--      migración), borra lo que no lo tiene y, a lo que no se pudo borrar por
--      tener historia en el libro, lo retira como antes.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Lo de capacitación no entra al libro
-- ---------------------------------------------------------------------------
-- Copiada de la versión viva salvo el bloque marcado NUEVO.

create or replace function public.helios_finalize_charge(
  p_charge_id           uuid,
  p_welcome_channel     text,
  p_over_limit_message  text default null
)
returns void
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_charge   public.charges%rowtype;
  v_terms    public.merchant_terms%rowtype;
  v_due_1    date;
  v_due_2    date;
  v_financed numeric(18,4);
  v_revenue  numeric(18,4);
  v_share    numeric(18,4);
  v_tx       uuid;
  v_cuotas   text;
  v_merchant text;
  v_rate     numeric;
  v_demo     boolean;
begin
  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Orden no encontrada' using errcode = 'P0002';
  end if;

  if v_charge.status = 'pending' then
    update public.charges
       set status = 'confirmed', confirmed_at = now()
     where id = p_charge_id
    returning * into v_charge;
  end if;

  if v_charge.status <> 'confirmed' or v_charge.user_id is null then
    raise exception 'La orden no se puede confirmar' using errcode = '22023';
  end if;

  select * into v_terms from public.helios_terms_at(v_charge.merchant_id, v_charge.business_date);
  if v_terms.id is null then
    raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
      using errcode = '22023';
  end if;

  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_charge.business_date);

  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);
  v_revenue  := coalesce(v_charge.consumer_fee_usd, 0) + coalesce(v_charge.merchant_fee_usd, 0);
  v_share    := coalesce(v_charge.merchant_net_usd, v_charge.amount_usd - v_revenue);

  -- NUEVO: una orden de capacitación no es dinero y no deja asiento; así se
  -- puede borrar entera a medianoche sin tocar el libro.
  select p.is_demo into v_demo from public.profiles p where p.id = v_charge.user_id;

  if not coalesce(v_demo, false) then
    -- El asiento de cuatro patas, saltándose las que valen cero. En dólares.
    insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
    values ('charge', 'charge:' || v_charge.idempotency_key, v_charge.business_date, v_charge.id,
            'Financiamiento de consulta')
    returning id into v_tx;

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    select v_tx, x.acct, x.debit, x.credit
    from (values
      (ledger.get_or_create_account('user_receivable', v_charge.user_id), v_charge.amount_usd, 0::numeric),
      (ledger.get_or_create_account('merchant_payable', v_charge.merchant_id), 0::numeric, v_share),
      (ledger.get_or_create_account('platform_revenue', null), 0::numeric, v_revenue),
      (ledger.get_or_create_account('vat_payable', null), 0::numeric,
       v_charge.amount_usd - v_share - v_revenue)
    ) as x(acct, debit, credit)
    where x.debit <> 0 or x.credit <> 0;

    -- El adelanto a la clínica (no hace nada con upfront_pct = 0).
    perform ledger.record_advance_settlement(
      v_charge.merchant_id, v_charge.id, round(v_share * v_terms.upfront_pct / 100, 4), v_charge.business_date);
  end if;

  -- La deuda: las 2 cuotas a +7 y +14 días y el bloque de crédito. Cada cuota
  -- se pone sola su monto en la moneda de la orden (trigger
  -- `installments_currency`).
  perform public.helios_assign_debt(
    v_charge.user_id, v_charge.id, v_financed, v_charge.amount_usd, v_due_1, v_due_2,
    coalesce(p_over_limit_message, public.helios_not_available_message()));

  -- La comisión de quien lo registró.
  perform public.helios_accrue_staff_commission(v_charge.id);

  -- Los mensajes: el comprobante (al correo REGISTRADO) y la bienvenida.
  perform public.helios_enqueue_charge_receipt(v_charge.id);

  v_rate := public.helios_fx_rate(v_charge.currency);

  select m.name into v_merchant from public.merchants m where m.id = v_charge.merchant_id;
  select string_agg(format('* %s%s — %s',
                           public.helios_money_cur_text(i.amount_cur, v_charge.currency),
                           case when v_rate is not null
                                then ' (hoy ' || public.helios_ves_text(round(i.amount_cur * v_rate, 2)) || ')'
                                else '' end,
                           to_char(i.due_date, 'DD/MM/YYYY')),
                    E'\n' order by i.sequence)
    into v_cuotas
  from public.installments i where i.charge_id = v_charge.id;

  perform public.helios_enqueue_message(
    'bienvenida', v_charge.user_id, v_charge.id, p_welcome_channel,
    jsonb_build_object('clinica', v_merchant, 'orden', v_charge.order_number::text, 'cuotas', v_cuotas,
                       'moneda', public.helios_currency_name(v_charge.currency)),
    null, 'bienvenida:' || v_charge.id::text);
end;
$$;

revoke all on function public.helios_finalize_charge(uuid, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. El borrado
-- ---------------------------------------------------------------------------
-- Devuelve cuántos pacientes y órdenes borró. Solo pacientes `is_demo` sin
-- nada en el libro (ninguna transacción con referencia a sus órdenes ni
-- cuenta propia), sin cuotas pagadas, sin pagos reportados y sin
-- liquidaciones. Si algo inesperado apunta todavía a una fila (una clave
-- foránea sin `on delete`), el borrado falla entero y no queda nada a medias.

create or replace function public.helios_demo_purge(p_phone text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_perfiles uuid[];
  v_ordenes  uuid[];
  v_cuotas   uuid[];
  v_claves   text[];
  v_n_ord    integer;
begin
  select coalesce(array_agg(p.id), '{}')
    into v_perfiles
  from public.profiles p
  where p.is_demo
    and (p_phone is null or p.phone_e164 = p_phone)
    -- Nada en el libro.
    and not exists (select 1 from ledger.accounts a where a.owner_id = p.id)
    and not exists (select 1 from public.charges c
                    join ledger.transactions t on t.reference_id = c.id
                    where c.user_id = p.id)
    -- Nada de dinero de verdad.
    and not exists (select 1 from public.installments i where i.user_id = p.id and i.status = 'paid')
    and not exists (select 1 from public.payment_reports r where r.user_id = p.id)
    and not exists (select 1 from public.settlements s
                    join public.charges c on c.id = s.charge_id
                    where c.user_id = p.id);

  if cardinality(v_perfiles) = 0 then
    return jsonb_build_object('borrados', 0, 'ordenes_borradas', 0);
  end if;

  select coalesce(array_agg(c.id), '{}') into v_ordenes
  from public.charges c where c.user_id = any(v_perfiles);

  select coalesce(array_agg(i.id), '{}') into v_cuotas
  from public.installments i
  where i.charge_id = any(v_ordenes) or i.user_id = any(v_perfiles);

  select coalesce(array_agg(p.document_key), '{}') into v_claves
  from public.profiles p
  where p.id = any(v_perfiles) and p.document_key is not null
    -- Una cédula que también es de alguien que se queda conserva sus consultas.
    and not exists (select 1 from public.profiles q
                    where q.document_key = p.document_key and not (q.id = any(v_perfiles)));

  -- El bot del médico que recordaba una de esas órdenes vuelve al menú.
  update public.whatsapp_sessions s
     set state = 'menu', data = '{}'::jsonb, updated_at = now()
   where exists (select 1 from unnest(v_ordenes) o where s.data::text like '%' || o::text || '%')
      or exists (select 1 from unnest(v_perfiles) p where s.data::text like '%' || p::text || '%');

  -- De las hojas a la raíz.
  delete from public.payment_quotes where user_id = any(v_perfiles);   -- sus líneas y cargos, en cascada
  delete from public.late_fees where user_id = any(v_perfiles) or installment_id = any(v_cuotas);
  delete from public.staff_commissions where charge_id = any(v_ordenes);
  delete from public.installments where id = any(v_cuotas);
  delete from public.outbound_messages where charge_id = any(v_ordenes) or profile_id = any(v_perfiles);
  delete from public.charges where id = any(v_ordenes);                -- sus líneas, en cascada
  get diagnostics v_n_ord = row_count;

  delete from public.notifications where user_id = any(v_perfiles);
  delete from public.user_credit_blocks where user_id = any(v_perfiles);
  delete from public.user_blocks where user_id = any(v_perfiles);
  delete from public.level_changes where user_id = any(v_perfiles);
  delete from public.profile_change_requests where profile_id = any(v_perfiles);
  update public.whatsapp_contacts set profile_id = null where profile_id = any(v_perfiles);
  update public.whatsapp_contacts set patient_profile_id = null where patient_profile_id = any(v_perfiles);
  update public.demo_resets set user_id = null where user_id = any(v_perfiles);
  delete from public.eligibility_lookups where document_key = any(v_claves);

  delete from public.profiles where id = any(v_perfiles);              -- collection_contacts, en cascada

  return jsonb_build_object('borrados', cardinality(v_perfiles), 'ordenes_borradas', v_n_ord);
end;
$$;

revoke all on function public.helios_demo_purge(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. El reinicio: anular, revertir lo que tiene asiento, borrar y retirar
-- ---------------------------------------------------------------------------

create or replace function public.helios_demo_reset(p_phone text default null, p_actor uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $$
declare
  v_c      record;
  v_motivo text;
  v_rev    integer := 0;
  v_anul   integer := 0;
  v_ret    integer := 0;
  v_purga  jsonb;
  v_sin    jsonb := '[]'::jsonb;
  v_out    jsonb;
begin
  -- 1. Las que esperan el «sí»: anuladas (el trigger cancela su pregunta).
  with anuladas as (
    update public.charges c
       set status = 'voided',
           void_reason = 'Reinicio de la demo',
           voided_by = p_actor,
           voided_at = now()
     where c.status = 'pending'
       and c.user_id in (select p.id from public.profiles p
                         where p.is_demo and (p_phone is null or p.phone_e164 = p_phone))
    returning 1
  )
  select count(*) into v_anul from anuladas;

  -- 2. Las confirmadas CON asiento (de antes de 20261014100300): revertidas.
  --    Las que no tienen asiento no hace falta revertirlas: se borran.
  for v_c in
    select c.id, c.order_number
    from public.charges c
    join public.profiles p on p.id = c.user_id
    where p.is_demo
      and (p_phone is null or p.phone_e164 = p_phone)
      and c.status = 'confirmed'
      and exists (select 1 from ledger.transactions t where t.reference_id = c.id)
    order by c.created_at
  loop
    begin
      v_motivo := public.helios_demo_reverse_charge(v_c.id, p_actor);
    exception when others then
      v_motivo := sqlerrm;
    end;

    if v_motivo is null then
      v_rev := v_rev + 1;
    else
      v_sin := v_sin || jsonb_build_object('charge_id', v_c.id, 'order_number', v_c.order_number,
                                           'motivo', v_motivo);
    end if;
  end loop;

  -- Lo que no tiene asiento pero sí algo de dinero de verdad no se borra:
  -- se dice, para mirarlo a mano.
  for v_c in
    select c.id, c.order_number
    from public.charges c
    join public.profiles p on p.id = c.user_id
    where p.is_demo
      and (p_phone is null or p.phone_e164 = p_phone)
      and c.status = 'confirmed'
      and not exists (select 1 from ledger.transactions t where t.reference_id = c.id)
      and (exists (select 1 from public.installments i where i.charge_id = c.id and i.status = 'paid')
           or exists (select 1 from public.payment_reports r where r.user_id = p.id))
  loop
    v_sin := v_sin || jsonb_build_object('charge_id', v_c.id, 'order_number', v_c.order_number,
                                         'motivo', 'Tiene un pago: no se borra, revísalo a mano.');
  end loop;

  -- 3. Borrar todo lo que no dejó rastro en el libro.
  v_purga := public.helios_demo_purge(p_phone);

  -- 4. Lo que queda con historia en el libro: retirado, sin cédula.
  with retirados as (
    update public.profiles p
       set document_number = null,
           demo_retired_at = now()
     where p.is_demo
       and p.demo_retired_at is null
       and (p_phone is null or p.phone_e164 = p_phone)
       and not exists (select 1 from public.charges c
                       where c.user_id = p.id and c.status in ('pending', 'confirmed'))
    returning 1
  )
  select count(*) into v_ret from retirados;

  v_out := jsonb_build_object(
    'anuladas', v_anul,
    'revertidas', v_rev,
    'borrados', (v_purga->>'borrados')::integer,
    'ordenes_borradas', (v_purga->>'ordenes_borradas')::integer,
    'retirados', v_ret,
    'sin_reiniciar', v_sin
  );

  insert into public.demo_resets (actor, phone_e164, detail)
  values (p_actor, p_phone, v_out);

  -- La bitácora es de personas (`actor` no admite null): el de medianoche
  -- queda solo en `demo_resets`.
  if p_actor is not null then
    perform audit.log(p_actor, 'demo.reset', null, v_out || jsonb_build_object('phone_e164', p_phone));
  end if;

  return v_out;
end;
$$;

revoke all on function public.helios_demo_reset(text, uuid) from public, anon, authenticated;
