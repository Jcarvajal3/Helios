-- ============================================================================
-- Helios — La comisión del personal sale con la primera mitad de la consulta
--
-- La comisión de quien registró la orden (`staff_commission`) nacía con
-- `due_date` = el día de la confirmación, así que se pagaba sola al día
-- siguiente y en Pagos a clínicas salía como «Sale hoy» una semana antes que
-- la consulta. Javier (2026-10-21): la comisión se paga junto con las cuotas,
-- sumada a ellas, y el detalle del pago la desglosa.
--
-- Ahora vence el mismo día que la PRIMERA cuota del paciente (día 7), como la
-- primera mitad de la consulta (`scheduled_installment`, `due_date` = el de su
-- cuota), y las dos salen el día 8 en el mismo pago. El desglose «Consultas +
-- Comisiones del personal» ya lo hacen la lista, el detalle de la
-- transferencia y el aviso a la clínica.
--
--   1. `helios_accrue_staff_commission`: `due_date` = la primera cuota. El
--      asiento del libro sigue en el día de la confirmación (es cuando se
--      devenga); solo cambia cuándo se paga.
--   2. Las comisiones pendientes, sin nada pagado ni en ninguna transferencia,
--      pasan a vencer con la primera cuota de su orden.
--   3. `merchant_commission_items` devuelve `pay_date`, el día en que Helios se
--      la paga a la clínica, para que el panel no lo calcule por su cuenta.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El devengo: vence con la primera cuota
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
  v_due date;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found or v_c.status <> 'confirmed' then
    raise exception 'El financiamiento no está confirmado' using errcode = '22023';
  end if;

  if coalesce(v_c.staff_commission_usd, 0) <= 0 or v_c.commission_staff_id is null then
    return null;
  end if;

  -- Una consulta de práctica no le gana nada a la secretaria.
  if public.helios_charge_of_test_patient(p_charge_id, null) then
    return null;
  end if;

  select id into v_id from public.staff_commissions where charge_id = p_charge_id;
  if found then
    return v_id;
  end if;

  -- NUEVO: vence con la primera cuota, como la primera mitad de la consulta,
  -- y sale en su mismo pago (`helios_settlement_run_for`). Las cuotas ya
  -- existen: `helios_assign_debt` va antes en el alta.
  select min(i.due_date) into v_due from public.installments i where i.charge_id = p_charge_id;
  v_due := coalesce(v_due, v_c.business_date + public.helios_installment_interval_days());

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
     v_c.business_date, v_due, 'pending')
  returning id into v_set;

  insert into public.staff_commissions (charge_id, merchant_id, staff_user_id, amount_usd, settlement_id)
  values (p_charge_id, v_c.merchant_id, v_c.commission_staff_id, v_c.staff_commission_usd, v_set)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.helios_accrue_staff_commission(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Las pendientes pasan a la primera cuota de su orden
-- ---------------------------------------------------------------------------
-- Solo las que no se han tocado: nada pagado y en ninguna transferencia. Una
-- que ya se pagó (o se pagó en parte) se queda como está.

update public.settlements s
   set due_date = q.primera
  from (
    select i.charge_id, min(i.due_date) as primera
    from public.installments i
    group by i.charge_id
  ) q
 where q.charge_id = s.charge_id
   and s.reason = 'staff_commission'
   and s.status = 'pending'
   and s.paid_usd = 0
   and s.due_date < q.primera
   and not exists (select 1 from public.merchant_payout_items it where it.settlement_id = s.id);

-- ---------------------------------------------------------------------------
-- 3. Lo que ve la clínica: el día en que se paga cada comisión
-- ---------------------------------------------------------------------------
-- Cambia la forma de la tabla que devuelve: hay que borrarla y crearla.

drop function if exists public.merchant_commission_items(date, date, uuid);

create function public.merchant_commission_items(p_from date, p_to date, p_staff_user_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(charge_id uuid, order_number bigint, created_at timestamp with time zone, amount_usd numeric, status text, payout_id uuid, paid_on date, staff_user_id uuid, staff_name text, business_date date, confirmed_at timestamp with time zone, pay_date date)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me         uuid := auth.uid();
  v_gerente_de uuid := public.my_merchant_id_as_gerente();
begin
  if v_me is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if not exists (select 1 from public.merchant_users mu
                 where mu.user_id = v_me and mu.is_active and mu.role in ('gerente', 'cajero')) then
    raise exception 'Solo el personal de una clínica' using errcode = '42501';
  end if;

  return query
  select sc.charge_id,
         c.order_number,
         sc.created_at,
         sc.amount_usd,
         sc.status,
         po.id,
         case when sc.status = 'pagada' then po.paid_on end,
         sc.staff_user_id,
         public.helios_staff_name(sc.staff_user_id),
         c.business_date,
         c.confirmed_at,
         -- NUEVO: el día del pago que la lleva (el de la primera mitad de la
         -- consulta). Sin liquidación (revertida), null.
         case when s.due_date is not null then public.helios_settlement_run_for(s.due_date) end
  from public.staff_commissions sc
  join public.charges c on c.id = sc.charge_id
  left join public.settlements s on s.id = sc.settlement_id
  left join lateral (
    select mp.id, coalesce(mp.paid_on, mp.business_date) as paid_on
    from public.merchant_payout_items it
    join public.merchant_payouts mp on mp.id = it.payout_id
    where sc.settlement_id is not null and it.settlement_id = sc.settlement_id
    order by mp.created_at desc
    limit 1
  ) po on true
  where sc.merchant_id in (select public.my_merchant_ids())
    and (sc.merchant_id = v_gerente_de or sc.staff_user_id = v_me)
    and (p_staff_user_id is null or sc.staff_user_id = p_staff_user_id)
    and c.business_date between p_from and p_to
  order by sc.created_at desc;
end;
$function$;

revoke all on function public.merchant_commission_items(date, date, uuid) from public, anon;
grant execute on function public.merchant_commission_items(date, date, uuid) to authenticated, service_role;
