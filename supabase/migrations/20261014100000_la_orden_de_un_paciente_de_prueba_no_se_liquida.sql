-- ============================================================================
-- Helios — La orden de un paciente de prueba no le genera nada a la clínica
--
-- Los pacientes demo (20261014100100) existen para que el médico practique en
-- SU clínica, con su panel y su bot. Pero el día del vencimiento de cada cuota
-- `run_scheduled_settlements_batch` crea la liquidación de esa mitad, y al
-- registrar se devenga la comisión del personal (`helios_accrue_staff_commission`).
-- Ninguna de las dos miraba si el paciente era de prueba, y el archivo de pago
-- masivo (`helios_bulk_payout_due`, `admin_create_bulk_payout`) solo frena a
-- la CLÍNICA de prueba. Resultado: una consulta de práctica en una clínica real
-- habría salido en el archivo del banco como dinero de verdad.
--
-- Lo que cambia:
--
--   1. Un trigger BEFORE INSERT en `settlements` descarta la fila cuando la
--      orden (por `charge_id`) o la cuota (por `installment_id`) es de un
--      paciente de prueba. Es la red única para los cuatro sitios que
--      liquidan (cuotas programadas, adelanto, cobro y comisión del personal)
--      y para el que venga después. Una clínica de prueba con un paciente
--      real sigue como estaba: su liquidación existe, se ve con su etiqueta y
--      el archivo del banco la rechaza.
--
--   2. `helios_accrue_staff_commission` no devenga nada para un paciente de
--      prueba: ni asiento, ni fila en `staff_commissions` (que la clínica ve
--      en «Comisiones»). Sin esto la fila quedaría «devengada» y sin
--      liquidación detrás. Copiada de 20261003000400 salvo el bloque NUEVO.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. ¿Es de un paciente de prueba?
-- ---------------------------------------------------------------------------

create or replace function public.helios_charge_of_test_patient(p_charge_id uuid, p_installment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select p.is_test
    from public.charges c
    join public.profiles p on p.id = c.user_id
    where c.id = coalesce(
      p_charge_id,
      (select i.charge_id from public.installments i where i.id = p_installment_id)
    )
  ), false);
$$;

comment on function public.helios_charge_of_test_patient(uuid, uuid) is
  'true si la orden (o la orden de la cuota) es de un paciente de prueba. A esa orden no se le liquida nada a la clínica.';

revoke all on function public.helios_charge_of_test_patient(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. La red: la liquidación no se escribe
-- ---------------------------------------------------------------------------
-- Devolver null en un BEFORE INSERT descarta la fila sin error: quien liquida
-- sigue su camino (el lote de las cuotas no se corta, la confirmación de la
-- orden no falla). El nombre empieza por «aa» para correr antes que
-- `settlements_currency`: los BEFORE van por orden alfabético.

create or replace function public.helios_skip_settlement_of_test_patient()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.helios_charge_of_test_patient(new.charge_id, new.installment_id) then
    return null;
  end if;
  return new;
end;
$$;

revoke all on function public.helios_skip_settlement_of_test_patient() from public, anon, authenticated;

drop trigger if exists settlements_aa_paciente_de_prueba on public.settlements;
create trigger settlements_aa_paciente_de_prueba
  before insert on public.settlements
  for each row execute function public.helios_skip_settlement_of_test_patient();

-- ---------------------------------------------------------------------------
-- 3. La comisión del personal tampoco se devenga
-- ---------------------------------------------------------------------------

create or replace function public.helios_accrue_staff_commission(p_charge_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_c   public.charges%rowtype;
  v_id  uuid;
  v_tx  uuid;
  v_set uuid;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found or v_c.status <> 'confirmed' then
    raise exception 'El financiamiento no está confirmado' using errcode = '22023';
  end if;

  if coalesce(v_c.staff_commission_usd, 0) <= 0 or v_c.commission_staff_id is null then
    return null;
  end if;

  -- NUEVO: una consulta de práctica no le gana nada a la secretaria.
  if public.helios_charge_of_test_patient(p_charge_id, null) then
    return null;
  end if;

  select id into v_id from public.staff_commissions where charge_id = p_charge_id;
  if found then
    return v_id;
  end if;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('staff_commission', 'staff_commission:' || p_charge_id::text, v_c.business_date, p_charge_id,
          'Comisión del personal de la clínica')
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, ledger.get_or_create_account('commission_expense', null), v_c.staff_commission_usd, 0),
    (v_tx, ledger.get_or_create_account('merchant_payable', v_c.merchant_id), 0, v_c.staff_commission_usd);

  insert into public.settlements
    (merchant_id, charge_id, reason, amount_usd, business_date, due_date, status)
  values
    (v_c.merchant_id, p_charge_id, 'staff_commission', v_c.staff_commission_usd,
     v_c.business_date, v_c.business_date, 'pending')
  returning id into v_set;

  insert into public.staff_commissions (charge_id, merchant_id, staff_user_id, amount_usd, settlement_id)
  values (p_charge_id, v_c.merchant_id, v_c.commission_staff_id, v_c.staff_commission_usd, v_set)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.helios_accrue_staff_commission(uuid) from public, anon, authenticated;
