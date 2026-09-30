-- ============================================================================
-- Ronda — La transferencia a un local guarda su motivo en la bitácora
--
-- Registrar una transferencia a un local mueve la caja del libro, y desde la
-- ola 3 el panel la confirma con un motivo obligatorio (el diálogo «sensible»).
-- El motivo ya viajaba en `p_note` y se guardaba en `merchant_payouts.note`,
-- pero la línea de la bitácora (`merchant.payout`) no lo llevaba: quien
-- revisara la bitácora veía el monto y la referencia sin saber por qué.
--
-- Ahora `detail.note` lleva el motivo, recortado (vacío → null), igual que las
-- diez escrituras de 20260925132000. La firma, los permisos y todo lo demás no
-- cambian; el servidor no lo exige, porque el panel de `main` no lo manda.
-- ============================================================================

create or replace function public.admin_report_merchant_payout(p_merchant_id uuid, p_settlement_ids uuid[], p_method text, p_reference text DEFAULT NULL::text, p_amount_ves numeric DEFAULT NULL::numeric, p_fx_rate numeric DEFAULT NULL::numeric, p_note text DEFAULT NULL::text, p_amount_usd numeric DEFAULT NULL::numeric, p_paid_on date DEFAULT NULL::date, p_receipt_path text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'audit', 'pg_temp'
AS $function$
declare
  v_actor       uuid := auth.uid();
  v_pendiente   numeric(18,4);
  v_total       numeric(18,4);
  v_restante    numeric(18,4);
  v_aplicado    numeric(18,4);
  v_count       integer;
  v_bdate       date;
  v_paid_on     date;
  v_payout      public.merchant_payouts%rowtype;
  v_tx          uuid;
  v_acct_pay    uuid;
  v_acct_cash   uuid;
  v_fx          numeric;
  v_ves         numeric;
  v_fila        record;
  -- El motivo que pide el panel. Recortado, y vacío es null: una nota en
  -- blanco no dice nada y no debe salir en la bitácora como si dijera algo.
  v_note        text := nullif(trim(coalesce(p_note, '')), '');
begin
  -- Registrar un pago mueve la caja del libro: es del super admin.
  perform public.helios_assert_super_admin('registrar pagos a comercios');

  if p_settlement_ids is null or array_length(p_settlement_ids, 1) is null then
    raise exception 'Selecciona al menos una liquidación' using errcode = '22023';
  end if;

  -- Se bloquean las filas antes de sumar: dos operadores pagando el mismo
  -- comercio a la vez no pueden liquidar dos veces lo mismo.
  perform 1 from public.settlements
  where id = any(p_settlement_ids) for update;

  select coalesce(sum(amount_usd - paid_usd), 0), count(*)
    into v_pendiente, v_count
  from public.settlements
  where id = any(p_settlement_ids)
    and merchant_id = p_merchant_id
    and status in ('pending', 'partial');

  if v_count <> array_length(p_settlement_ids, 1) then
    raise exception 'Alguna liquidación no es de este comercio o ya está pagada entera'
      using errcode = '22023';
  end if;

  -- Sin importe se paga todo lo marcado, que es el caso normal.
  v_total := coalesce(p_amount_usd, v_pendiente);

  if v_total <= 0 then
    raise exception 'El importe tiene que ser mayor que cero' using errcode = '22023';
  end if;

  -- Hacia arriba no: pagar de más no es un pago parcial al revés, es un error
  -- de tecleo que dejaría el libro con caja negativa contra ese comercio.
  if v_total > v_pendiente + 0.005 then
    raise exception 'No puedes registrar % cuando lo marcado suma %',
      v_total, v_pendiente using errcode = '22023';
  end if;

  v_bdate   := public.helios_business_date(now());
  v_paid_on := coalesce(p_paid_on, v_bdate);

  -- Una fecha de pago en el futuro es siempre un error de tecleo.
  if v_paid_on > v_bdate then
    raise exception 'La fecha del pago no puede ser posterior a hoy' using errcode = '22023';
  end if;

  -- La conversión, si toca. `current_fx_rate()` puede devolver null si la
  -- ingesta lleva días rota: en ese caso se guarda null, en vez de inventar
  -- una tasa. El aviso de tasa vieja del panel es lo que tiene que sonar ahí.
  if p_method in ('pago_movil', 'transferencia') then
    v_fx  := coalesce(p_fx_rate, public.current_fx_rate('BCV', v_paid_on));
    v_ves := coalesce(p_amount_ves, round(v_total * v_fx, 2));
  else
    v_fx  := p_fx_rate;
    v_ves := p_amount_ves;
  end if;

  insert into public.merchant_payouts
    (merchant_id, amount_usd, amount_ves, fx_rate, method, reference, note,
     paid_by, business_date, paid_on, receipt_path)
  values
    (p_merchant_id, v_total, v_ves, v_fx, p_method, p_reference, v_note,
     v_actor, v_bdate, v_paid_on, nullif(trim(coalesce(p_receipt_path, '')), ''))
  returning * into v_payout;

  -- El reparto: de la más antigua a la más nueva. La última que alcanza queda
  -- parcial con su resto y sigue apareciendo en el cierre.
  v_restante := v_total;

  for v_fila in
    select id, amount_usd, paid_usd, due_date
    from public.settlements
    where id = any(p_settlement_ids)
    order by due_date, id
  loop
    exit when v_restante <= 0;

    v_aplicado := least(v_restante, v_fila.amount_usd - v_fila.paid_usd);
    if v_aplicado <= 0 then
      continue;
    end if;

    update public.settlements
    set paid_usd = paid_usd + v_aplicado,
        status = case
          when paid_usd + v_aplicado >= amount_usd - 0.005 then 'paid'::public.settlement_status
          else 'partial'::public.settlement_status
        end
    where id = v_fila.id;

    insert into public.merchant_payout_items (payout_id, settlement_id, amount_usd)
    values (v_payout.id, v_fila.id, v_aplicado);

    v_restante := v_restante - v_aplicado;
  end loop;

  -- AHORA sí sale el dinero: es el momento en que de verdad salió del banco.
  v_acct_pay  := ledger.get_or_create_account('merchant_payable', p_merchant_id);
  v_acct_cash := ledger.get_or_create_account('cash', null);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'merchant_settlement', 'payout:' || v_payout.id::text, v_bdate, v_payout.id,
    format('Pago al comercio (%s liquidaciones)', v_count)
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_pay, v_total, 0),
    (v_tx, v_acct_cash, 0, v_total);

  perform audit.log(v_actor, 'merchant.payout', p_merchant_id,
    jsonb_build_object(
      'payout_id', v_payout.id, 'amount_usd', v_total,
      'pending_usd', v_pendiente,
      'partial', v_total < v_pendiente - 0.005,
      'settlements', v_count, 'method', p_method, 'reference', p_reference,
      'paid_on', v_paid_on, 'amount_ves', v_ves, 'fx_rate', v_fx,
      'has_receipt', p_receipt_path is not null,
      -- El motivo va con la transferencia: `note` es la clave que la bitácora
      -- del panel pinta como motivo.
      'note', v_note
    ));

  return jsonb_build_object(
    'ok', true, 'payout_id', v_payout.id,
    'amount_usd', v_total, 'pending_usd', v_pendiente, 'settlements', v_count,
    'amount_ves', v_ves, 'fx_rate', v_fx, 'paid_on', v_paid_on
  );
end;
$function$;
