-- ============================================================================
-- Ronda — Conciliar un pago no puede saltarse ninguna de sus cuotas
--
-- EL FALLO
--
-- `reconcile_payment` recorría las cuotas de la cotización con este FROM:
--
--     from payment_quote_items i
--     join installments ins             on ins.id = i.installment_id
--     join charges c                    on c.id = ins.charge_id
--     join merchant_settlement_terms t  on t.merchant_id = c.merchant_id
--
-- Ese último es un INNER JOIN. Un comercio sin fila en
-- `merchant_settlement_terms` no descarta su liquidación: descarta LA CUOTA
-- ENTERA del bucle. Y el resto de la función sigue como si nada:
--
--   * la cuota se queda en `pending` — el usuario la sigue debiendo
--   * no suma a `v_total`, así que el asiento del ledger y el abono al
--     bloque de crédito se hacen por MENOS dinero del que entró
--   * el reporte se marca `reconciled` igual
--
-- Resultado: el usuario transfirió, el panel aprobó, y la app le sigue
-- pidiendo la misma cuota — sin ningún error en ninguna parte. Se cobra dos
-- veces si vuelve a pagar.
--
-- Hoy el trigger `bootstrap_merchant` crea las condiciones con cada comercio,
-- así que en un proyecto limpio no pasa. Pero eso es una salvaguarda de
-- INSERCIÓN: no sobrevive a un borrado, a un comercio cargado por seed o
-- migración de datos, ni a que mañana ese join se amplíe con otra tabla.
-- Un fallo silencioso que se lleva dinero no puede depender de eso.
--
-- EL ARREGLO
--
--   1. `left join`: la falta de condiciones ya no puede sacar una cuota del
--      bucle. Lo que se salta es la liquidación al comercio, no el cobro.
--   2. Si de verdad faltan condiciones, se levanta excepción y la
--      transacción entera se deshace. Ruidoso y atómico en vez de silencioso
--      y a medias: el operador configura el comercio y vuelve a aprobar.
--   3. Al terminar se comprueba que se tocaron TODAS las cuotas de la
--      cotización. Es la red por si algún join futuro vuelve a descartar
--      filas.
--
-- Cuerpo por lo demás idéntico al de 20260822121000_report_merchant_payout.
-- ============================================================================

create or replace function public.reconcile_payment(
  p_report_id uuid,
  p_actor     uuid,
  p_approve   boolean,
  p_note      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_report    public.payment_reports%rowtype;
  v_quote     public.payment_quotes%rowtype;
  v_item      record;
  v_bdate     date;
  v_tx        uuid;
  v_acct_recv uuid;
  v_acct_cash uuid;
  v_block     public.user_credit_blocks%rowtype;
  v_total     numeric(18,4) := 0;
  v_settled   numeric(18,4);
  v_done      integer := 0;
  v_expected  integer;
begin
  select * into v_report from public.payment_reports where id = p_report_id for update;
  if not found then
    raise exception 'Reporte no encontrado' using errcode = 'P0002';
  end if;

  if v_report.status not in ('reported', 'in_review') then
    raise exception 'Este reporte ya fue resuelto (%)', v_report.status using errcode = '22023';
  end if;

  if not p_approve then
    update public.payment_reports
      set status = 'rejected', reviewed_by = p_actor, reviewed_at = now(),
          rejection_note = p_note
    where id = p_report_id;

    return jsonb_build_object('ok', true, 'status', 'rejected');
  end if;

  select * into v_quote from public.payment_quotes where id = v_report.quote_id;

  select count(*) into v_expected
  from public.payment_quote_items where quote_id = v_quote.id;

  if v_expected = 0 then
    raise exception 'La cotización % no tiene cuotas', v_quote.id using errcode = '22023';
  end if;

  v_bdate := public.helios_business_date(now());
  v_acct_recv := ledger.get_or_create_account('user_receivable', v_report.user_id);
  v_acct_cash := ledger.get_or_create_account('cash', null);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'installment_payment', 'reconcile:' || p_report_id::text, v_bdate, p_report_id,
    format('Pago conciliado de %s cuota(s)', v_quote.installment_count)
  )
  returning id into v_tx;

  for v_item in
    select i.installment_id, i.amount_usd, c.merchant_id,
           t.policy, t.per_installment_pct,
           ins.due_date
    from public.payment_quote_items i
    join public.installments ins on ins.id = i.installment_id
    join public.charges c on c.id = ins.charge_id
    -- LEFT: la falta de condiciones de liquidación no puede sacar la cuota
    -- del bucle. `ins` sigue en el lado no anulable, así que el `for update`
    -- de abajo es válido.
    left join public.merchant_settlement_terms t on t.merchant_id = c.merchant_id
    where i.quote_id = v_quote.id
    for update of ins
  loop
    if v_item.policy is null then
      raise exception
        'El comercio % no tiene condiciones de liquidación: configúralas antes de conciliar este pago',
        v_item.merchant_id
        using errcode = '22023';
    end if;

    if (select status from public.installments where id = v_item.installment_id) = 'paid' then
      raise exception 'La cuota % ya estaba pagada', v_item.installment_id using errcode = '22023';
    end if;

    update public.installments
      set status = 'paid', paid_at = now()
    where id = v_item.installment_id;

    v_total := v_total + v_item.amount_usd;
    v_done  := v_done + 1;

    -- En 'on_collection' la obligación nace al cobrar. Se DEVENGA, igual que
    -- el adelanto: la caja se mueve cuando se reporte la transferencia.
    if v_item.policy = 'on_collection' then
      v_settled := round(v_item.amount_usd * v_item.per_installment_pct * 2 / 100, 4);

      insert into public.settlements
        (merchant_id, installment_id, reason, amount_usd, business_date, due_date, status)
      values
        (v_item.merchant_id, v_item.installment_id, 'on_collection', v_settled,
         v_bdate, v_bdate, 'pending');
    end if;
  end loop;

  -- La red. Si el bucle no tocó todas las cuotas de la cotización, algo las
  -- descartó: se deshace todo antes de asentar dinero por una cifra que no
  -- corresponde con lo que se acaba de saldar.
  if v_done <> v_expected then
    raise exception
      'Se saldaron % de % cuotas de la cotización %: no se concilia a medias',
      v_done, v_expected, v_quote.id
      using errcode = '22023';
  end if;

  -- Lo único que mueve caja aquí es el dinero que ENTRÓ del usuario.
  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_cash, v_total, 0),
    (v_tx, v_acct_recv, 0, v_total);

  update public.payment_reports
    set status = 'reconciled', reviewed_by = p_actor, reviewed_at = now(),
        rejection_note = coalesce(p_note, rejection_note)
  where id = p_report_id;

  select * into v_block
  from public.user_credit_blocks
  where user_id = v_report.user_id and closed_at is null
  for update;

  if found then
    update public.user_credit_blocks
      set paid_usd = paid_usd + v_total
    where id = v_block.id;

    if v_block.paid_usd + v_total >= v_block.charged_usd then
      update public.user_credit_blocks
        set closed_at = now(), close_reason = 'paid'
      where id = v_block.id;
    end if;
  end if;

  perform public.recompute_profile_mora_state(v_report.user_id);

  return jsonb_build_object(
    'ok', true, 'status', 'reconciled',
    'amount_usd', v_total,
    'installments', v_done
  );
end;
$$;

revoke all on function public.reconcile_payment(uuid, uuid, boolean, text)
  from public, anon, authenticated;

comment on function public.reconcile_payment(uuid, uuid, boolean, text) is
  'Aprueba o rechaza un reporte de pago. Al aprobar salda TODAS las cuotas de la cotización o no salda ninguna.';
