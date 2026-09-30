-- ============================================================================
-- Ronda — REGRESIÓN: la venta volvía a sacar el adelanto de la caja
--
-- ---------------------------------------------------------------------------
-- QUÉ PASÓ
-- ---------------------------------------------------------------------------
-- `20260822120000_merchant_payouts.sql` corrigió un error de origen: al vender,
-- `confirm_charge` asentaba
--
--     Dr merchant_payable 30 / Cr cash 30
--
-- es decir, el libro afirmaba que el 30% ya había salido de la caja cuando
-- nadie había transferido nada. Desde esa migración el adelanto solo se
-- DEVENGA —una fila `pending` en `settlements`— y la caja se mueve cuando
-- alguien transfiere de verdad y lo reporta (`report_merchant_payout`).
--
-- `20260824170000_pin_to_pay.sql` reescribió `confirm_charge` para exigir el
-- PIN y lo hizo partiendo de la versión de `20260822070000` —lo dice su propia
-- cabecera: *"el resto es idéntico a la versión de 20260822070000"*—, que es
-- ANTERIOR al arreglo. Con el parámetro nuevo se llevó de vuelta el asiento de
-- caja, y ahí sigue.
--
-- ---------------------------------------------------------------------------
-- QUÉ ROMPE
-- ---------------------------------------------------------------------------
-- El adelanto se cuenta DOS veces: sale de la caja en la venta y vuelve a
-- salir cuando el operador reporta la transferencia al comercio. Efectos, los
-- mismos que ya documentó la migración de agosto 22 y uno más:
--
--   * `cash` enseña menos dinero del que hay en el banco — el doble del
--     adelanto de menos.
--   * `merchant_payable` enseña menos deuda de la que se le debe al comercio,
--     que es el número que se mira para pagarle.
--   * La liquidación 'advance' queda `pending` igual, así que quien la pague
--     desde el panel volverá a sacar el mismo dinero.
--
-- Solo afecta al cobro INDIVIDUAL. `confirm_charge_as_group`, escrito de nuevo
-- en esa misma migración, sí quedó con el devengo correcto — por eso el libro
-- de la prueba de grupos cuadraba y el de la individual no.
--
-- ---------------------------------------------------------------------------
-- CÓMO SE ENCONTRÓ, Y POR QUÉ TARDÓ UN DÍA
-- ---------------------------------------------------------------------------
-- `ledger_smoke` y `merchant_payout_smoke` lo afirman con todas las letras
-- ("vender no debía mover la caja"), pero llevaban desde el 24 de agosto sin
-- poder ejecutarse: la firma de `request_charge` había cambiado y las dos
-- suites morían en la primera línea, contadas como "1 error" entre otras diez
-- rotas por lo mismo. Una prueba que no corre no es una red.
--
-- ---------------------------------------------------------------------------
-- LO QUE ESTA MIGRACIÓN NO HACE
-- ---------------------------------------------------------------------------
-- No toca los asientos ya escritos. Revertir movimientos de un libro contable
-- es una decisión de negocio —con su asiento de reverso y su fecha—, no un
-- efecto colateral de un despliegue. Las ventas individuales confirmadas entre
-- el 2026-08-24 y hoy tienen una transacción `merchant_advance` de más:
--
--     select t.id, t.business_date, t.reference_id, e.debit, e.credit
--     from ledger.transactions t
--     join ledger.entries e on e.transaction_id = t.id
--     where t.type = 'merchant_advance' and t.business_date >= '2026-08-24';
--
-- Cuerpo idéntico al de `20260824170000_pin_to_pay.sql` salvo el asiento de
-- caja, que se va, y `v_acct_cash`, que se queda sin uso.
-- ============================================================================

create or replace function public.confirm_charge(
  p_charge_id       uuid,
  p_idempotency_key text,
  p_pin             text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_user        uuid := auth.uid();
  v_pin       jsonb;
  v_charge      public.charges%rowtype;
  v_profile     public.profiles%rowtype;
  v_limit       numeric(18,4);
  v_block       public.user_credit_blocks%rowtype;
  v_open_debt   numeric(18,4);
  v_reserved    numeric(18,4);
  v_terms       public.merchant_settlement_terms%rowtype;
  v_bdate       date;
  v_due_1       date;
  v_due_2       date;
  v_tx          uuid;
  v_acct_recv   uuid;
  v_acct_pay    uuid;
  v_acct_rev    uuid;
  v_upfront     numeric(18,4);
  v_revenue     numeric(18,4);
  v_merchant_share numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  /**
   * EL PIN, ANTES DE TOCAR NADA.
   *
   * Se comprueba con `verify_user_pin`, que es quien lleva el bloqueo
   * progresivo (3 fallos → 30s, 5 → 5min, 7 → exige OTP) y lo anota en
   * `pin_attempts`.
   *
   * Un PIN incorrecto se DEVUELVE, no se lanza — y esa diferencia es la que
   * hace que el bloqueo funcione. Un `raise` revertiría la transacción
   * entera, **incluido el intento fallido que acaba de anotarse**, y este
   * cobro quedaría convertido en un oráculo para probar PINes sin límite ni
   * rastro. Devolviendo, la transacción confirma y el contador sube.
   *
   * Por eso va lo PRIMERO: cuando se devuelve por PIN incorrecto, lo único
   * escrito en la transacción es ese intento.
   */
  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  if v_charge.status = 'confirmed' then
    if v_charge.user_id <> v_user then
      raise exception 'Este cobro ya fue tomado por otra persona' using errcode = '42501';
    end if;
    return jsonb_build_object('ok', true, 'charge_id', v_charge.id, 'already_confirmed', true);
  end if;

  if v_charge.status <> 'pending' then
    raise exception 'Este cobro ya no está disponible (%)', v_charge.status using errcode = '22023';
  end if;

  if v_charge.expires_at < now() then
    raise exception 'Este QR caducó, pídele al local que genere uno nuevo' using errcode = '22023';
  end if;

  if v_charge.user_id is not null and v_charge.user_id <> v_user then
    raise exception 'Este cobro ya fue tomado por otra persona' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where id = v_user for update;

  if v_profile.status <> 'active' then
    raise exception 'Tu cuenta no puede consumir en este estado (%)', v_profile.status
      using errcode = '22023';
  end if;

  select monthly_limit_usd into v_limit from public.levels where level = v_profile.level;

  select * into v_block
  from public.user_credit_blocks
  where user_id = v_user and closed_at is null
  for update;

  if not found then
    insert into public.user_credit_blocks (user_id) values (v_user)
    returning * into v_block;
  end if;

  v_open_debt := v_block.charged_usd;
  v_reserved  := public.group_holds_usd(v_user);

  if v_open_debt + v_reserved + v_charge.amount_usd > v_limit then
    if v_reserved > 0 then
      raise exception 'Saldo insuficiente: disponible $%, cobro $%. Tienes $% retenidos en grupos',
        (v_limit - v_open_debt - v_reserved), v_charge.amount_usd, v_reserved
        using errcode = '22023';
    end if;

    raise exception 'Saldo insuficiente: disponible $%, cobro $%',
      (v_limit - v_open_debt), v_charge.amount_usd
      using errcode = '22023';
  end if;

  select * into v_terms from public.merchant_settlement_terms where merchant_id = v_charge.merchant_id;

  v_bdate := public.helios_business_date(now());
  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_bdate);

  v_acct_recv := ledger.get_or_create_account('user_receivable', v_user);
  v_acct_pay  := ledger.get_or_create_account('merchant_payable', v_charge.merchant_id);
  v_acct_rev  := ledger.get_or_create_account('platform_revenue', null);

  v_revenue := round(v_charge.amount_usd * v_terms.commission_pct / 100, 4);
  v_merchant_share := v_charge.amount_usd - v_revenue;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', p_idempotency_key, v_bdate, v_charge.id, 'Venta en comercio')
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_recv, v_charge.amount_usd, 0),
    (v_tx, v_acct_pay, 0, v_merchant_share),
    (v_tx, v_acct_rev, 0, v_revenue);

  v_upfront := round(v_charge.amount_usd * v_terms.upfront_pct / 100, 4);
  -- --- El adelanto se DEVENGA, no se paga -------------------------------
  -- Aquí volvía a salir dinero de `cash` (ver la cabecera de esta migración).
  -- Solo queda la obligación: la caja se mueve cuando alguien transfiera de
  -- verdad y lo reporte.
  perform ledger.record_advance_settlement(v_charge.merchant_id, v_charge.id, v_upfront, v_bdate);

  insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
    (v_charge.id, v_user, 1, round(v_charge.amount_usd / 2, 4), v_due_1),
    (v_charge.id, v_user, 2, v_charge.amount_usd - round(v_charge.amount_usd / 2, 4), v_due_2);

  update public.user_credit_blocks
    set charged_usd = charged_usd + v_charge.amount_usd
  where id = v_block.id;

  update public.charges
    set status = 'confirmed', user_id = v_user, business_date = v_bdate, confirmed_at = now()
  where id = v_charge.id;

  return jsonb_build_object(
    'ok', true, 'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'due_1', v_due_1, 'due_2', v_due_2
  );
end;
$$;

revoke all on function public.confirm_charge(uuid, text, text) from public, anon;
grant execute on function public.confirm_charge(uuid, text, text) to authenticated;
