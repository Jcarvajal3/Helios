-- ============================================================================
-- Ronda — Revertir un consumo confirmado
--
-- Un cobro pendiente se anula: nadie lo escaneó, no generó nada. Un consumo ya
-- **confirmado** no se podía deshacer de ninguna manera, y ese es el caso que
-- de verdad pasa: el mesonero teclea €500 en vez de €50 y la persona lo
-- confirma sin mirar. Hoy la única salida es arreglarlo por fuera del sistema,
-- que quiere decir no arreglarlo.
--
-- ---------------------------------------------------------------------------
-- Qué hay que deshacer, y en qué orden
-- ---------------------------------------------------------------------------
-- Un consumo confirmado dejó cinco cosas:
--
--   1. Un asiento en el libro: deuda de la persona, deuda con el local,
--      comisión e IVA.
--   2. Dos cuotas.
--   3. Una liquidación de adelanto, si el local la tenía pactada.
--   4. Cupo consumido en el bloque de crédito.
--   5. Un aviso que ya se mandó y no se puede recoger.
--
-- Se deshacen las cuatro primeras. El asiento **no se borra**: se escribe otro
-- contrario. Es lo que hace que el libro sea auditable — un asiento que
-- desaparece es un asiento que nadie puede revisar.
--
-- ---------------------------------------------------------------------------
-- El límite que evita el caso difícil entero
-- ---------------------------------------------------------------------------
-- Solo se puede revertir si **ninguna de sus cuotas tiene un pago**: ni
-- aprobado, ni pendiente, ni rechazado. Con eso fuera:
--
--   * No hay dinero que devolver, que es la parte que ningún panel debería
--     hacer solo.
--   * No hay cotizaciones apuntando a las cuotas, así que se pueden borrar sin
--     dejar referencias rotas.
--   * No hay Bits que quitar: se ganan al pagar.
--
-- Y si alguna liquidación al local **ya se pagó**, tampoco: eso deja un saldo a
-- favor de Ronda contra ese comercio, y compensarlo en el cierre siguiente es
-- otra operación con otras consecuencias. Se corta aquí y se dice por qué.
-- ============================================================================

create or replace function public.admin_reverse_charge(
  p_charge_id uuid,
  p_reason    text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $$
declare
  v_actor    uuid := auth.uid();
  v_charge   public.charges%rowtype;
  v_bdate    date := public.helios_business_date(now());
  v_financed numeric(18,4);
  v_payable  numeric(18,4);
  v_pagadas  integer;
  v_reportes integer;
  v_liq_pag  integer;
  v_tx       uuid;
  v_origen   record;
  v_name     text;
begin
  -- Revertir mueve el libro hacia atrás: es del super admin.
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede revertir un consumo'
      using errcode = '42501';
  end if;

  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'Revertir un consumo requiere motivo' using errcode = '22023';
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;

  if not found then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  if v_charge.status <> 'confirmed' then
    raise exception 'Solo se puede revertir un consumo confirmado (este está %)',
      v_charge.status using errcode = '22023';
  end if;

  -- ── Las tres redes ───────────────────────────────────────────────────────

  select count(*) into v_pagadas
  from public.installments
  where charge_id = p_charge_id and status = 'paid';

  if v_pagadas > 0 then
    raise exception 'Este consumo ya tiene % cuota(s) pagada(s): revertirlo sería devolver dinero, y eso no se hace desde aquí',
      v_pagadas using errcode = '22023';
  end if;

  select count(*) into v_reportes
  from public.payment_reports r
  join public.payment_quote_items qi on qi.quote_id = r.quote_id
  join public.installments i on i.id = qi.installment_id
  where i.charge_id = p_charge_id;

  if v_reportes > 0 then
    raise exception 'Alguien ya reportó un pago para una cuota de este consumo: resuélvelo antes de revertir'
      using errcode = '22023';
  end if;

  select count(*) into v_liq_pag
  from public.settlements
  where charge_id = p_charge_id and status in ('paid', 'partial');

  if v_liq_pag > 0 then
    raise exception 'Al local ya se le pagó parte de este consumo: compensarlo en el próximo cierre es otra operación'
      using errcode = '22023';
  end if;

  select full_name into v_name from public.profiles where id = v_charge.user_id;

  select
    coalesce(sum(financed_usd), 0),
    coalesce(sum(amount_usd), 0)
  into v_financed, v_payable
  from public.installments where charge_id = p_charge_id;

  -- ── 1. El asiento contrario ──────────────────────────────────────────────
  -- Se refleja lo que se escribió, pata por pata, en vez de recalcularlo: si
  -- el consumo se asentó con una comisión o un IVA distintos de los de hoy
  -- —porque los parámetros cambiaron— recalcular dejaría un residuo.

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'manual_adjustment',
    'reverse_charge:' || p_charge_id::text,
    v_bdate,
    p_charge_id,
    format('Consumo revertido: %s', trim(p_reason))
  )
  returning id into v_tx;

  for v_origen in
    select e.account_id, e.debit, e.credit
    from ledger.transactions t
    join ledger.entries e on e.transaction_id = t.id
    where t.reference_id = p_charge_id
      and t.type <> 'manual_adjustment'
  loop
    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, v_origen.account_id, v_origen.credit, v_origen.debit);
  end loop;

  -- ── 2. Las cuotas ────────────────────────────────────────────────────────
  -- Se borran, no se marcan. Sin pagos detrás no dejan nada que auditar —lo
  -- que pasó está en el asiento y en la bitácora— y dejarlas con un estado
  -- nuevo obligaría a que las quince consultas que filtran por 'pending' se
  -- acordaran de excluirlo.

  delete from public.installments where charge_id = p_charge_id;

  -- ── 3. Las liquidaciones al local que no se han pagado ───────────────────

  delete from public.settlements
  where charge_id = p_charge_id and status = 'pending';

  -- ── 4. El cupo vuelve ────────────────────────────────────────────────────

  update public.user_credit_blocks
  set charged_usd = greatest(charged_usd - v_financed, 0),
      fee_usd     = greatest(fee_usd - (v_payable - v_financed), 0)
  where user_id = v_charge.user_id and closed_at is null;

  -- ── 5. El consumo queda marcado ──────────────────────────────────────────

  update public.charges
  set status      = 'reverted',
      void_reason = trim(p_reason),
      voided_by   = v_actor,
      voided_at   = now()
  where id = p_charge_id;

  -- La persona tiene que enterarse: le desapareció una deuda y un cargo de su
  -- historial. Enterarse por sorpresa es peor que el error original.
  perform public.notify(
    v_charge.user_id,
    'payment_reconciled',
    'Anulamos un consumo',
    format('Anulamos el consumo de €%s. Ya no lo debes y tu cupo vuelve a estar disponible.',
           to_char(v_charge.amount_usd, 'FM999999990.00'))
  );

  perform audit.log(v_actor, 'charge.reverted', p_charge_id, jsonb_build_object(
    'user_id', v_charge.user_id,
    'full_name', v_name,
    'merchant_id', v_charge.merchant_id,
    'amount_usd', v_charge.amount_usd,
    'financed_usd', v_financed,
    'payable_usd', v_payable,
    'business_date', v_charge.business_date,
    'reason', trim(p_reason)
  ));

  return jsonb_build_object(
    'ok', true,
    'charge_id', p_charge_id,
    'amount_usd', v_charge.amount_usd,
    'credit_returned_usd', v_financed
  );
end;
$$;

comment on function public.admin_reverse_charge(uuid, text) is
  'Deshace un consumo confirmado: asiento contrario —el original se queda—, cuotas borradas, liquidaciones no pagadas canceladas y cupo devuelto. Solo si ninguna cuota tiene pagos y al local no se le pago nada de el. Solo super admin.';

revoke all on function public.admin_reverse_charge(uuid, text) from public, anon;
grant execute on function public.admin_reverse_charge(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Si se puede revertir, y por qué no
-- ---------------------------------------------------------------------------
-- La pantalla necesita saberlo **antes** de enseñar el botón. Un botón que
-- explica al pulsarlo por qué no se puede pulsar es un callejón.

create or replace function public.admin_can_reverse_charge(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_charge   public.charges%rowtype;
  v_pagadas  integer;
  v_reportes integer;
  v_liq_pag  integer;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  if v_charge.status <> 'confirmed' then
    return jsonb_build_object('can_reverse', false,
      'reason', format('El consumo está %s, no confirmado', v_charge.status));
  end if;

  select count(*) into v_pagadas
  from public.installments where charge_id = p_charge_id and status = 'paid';

  if v_pagadas > 0 then
    return jsonb_build_object('can_reverse', false,
      'reason', 'Ya tiene cuotas pagadas: revertirlo sería devolver dinero');
  end if;

  select count(*) into v_reportes
  from public.payment_reports r
  join public.payment_quote_items qi on qi.quote_id = r.quote_id
  join public.installments i on i.id = qi.installment_id
  where i.charge_id = p_charge_id;

  if v_reportes > 0 then
    return jsonb_build_object('can_reverse', false,
      'reason', 'Alguien reportó un pago para una de sus cuotas');
  end if;

  select count(*) into v_liq_pag
  from public.settlements
  where charge_id = p_charge_id and status in ('paid', 'partial');

  if v_liq_pag > 0 then
    return jsonb_build_object('can_reverse', false,
      'reason', 'Al local ya se le pagó parte de este consumo');
  end if;

  return jsonb_build_object('can_reverse', true, 'reason', null);
end;
$$;

revoke all on function public.admin_can_reverse_charge(uuid) from public, anon;
grant execute on function public.admin_can_reverse_charge(uuid) to authenticated;
