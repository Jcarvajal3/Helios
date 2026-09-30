-- ============================================================================
-- Ronda — Principal en la calle y comisión cobrada
--
-- El balance del panel enseña «deuda de usuarios»: un solo número con el fee
-- dentro. Faltan las dos mitades que de verdad contestan preguntas distintas:
--
--   PRINCIPAL EN LA CALLE   lo que Ronda pagó o pagará a los locales y los
--                           usuarios todavía no han devuelto. Es el dinero
--                           propio que está fuera, y el que se pierde entero
--                           en un impago.
--
--   COMISIÓN COBRADA        la parte del fee que ya se materializó. La
--                           devengada se gana al confirmarse el consumo; esta
--                           solo existe cuando alguien paga.
--
-- Sin separarlas, «te deben €1.200» no dice si son €1.000 de capital y €200 de
-- margen o al revés, y las dos cosas se gestionan distinto.
--
-- ---------------------------------------------------------------------------
-- No hace falta tocar el modelo: el dato ya estaba
-- ---------------------------------------------------------------------------
-- `installments.financed_usd` existe desde 20260830190000 y guarda exactamente
-- la parte de la cuota que descuenta cupo, o sea el principal.
-- `amount_usd` es lo pagadero. La diferencia de las dos **es** el fee de esa
-- cuota, y es `not null` en toda la tabla desde aquella migración, así que las
-- dos cifras salen de una suma y nada más.
--
--     principal en la calle  = Σ financed_usd            de las vivas
--     comisión cobrada       = Σ (amount_usd − financed_usd)  de las pagadas
--
-- Se leen de `installments` y no del libro a propósito: el libro lleva la
-- comisión devengada en una sola cuenta y no sabe repartir un pago entre
-- principal y fee. Las dos convenciones conviven porque miden cosas distintas,
-- y la tarjeta dice de dónde sale cada una.
-- ============================================================================

create or replace function public.admin_cash_position()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_cash        numeric(18,4);
  v_receivable  numeric(18,4);
  v_payable     numeric(18,4);
  v_revenue     numeric(18,4);
  v_written_off numeric(18,4);
  v_fx          numeric(18,4);
  v_overdue     numeric(18,4);
  v_principal   numeric(18,4);
  v_fee_paid    numeric(18,4);
  v_today       date := public.helios_business_date(now());
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_cash        :=  ledger.balance_by_type('cash');
  v_receivable  :=  ledger.balance_by_type('user_receivable');
  v_payable     := -ledger.balance_by_type('merchant_payable');
  v_revenue     := -ledger.balance_by_type('platform_revenue');
  v_written_off := -ledger.balance_by_type('bad_debt_provision');
  v_fx          :=  ledger.balance_by_type('fx_difference');

  -- Cuánto de la exposición ya está vencido. No es lo mismo tener €5.000 en
  -- la calle al corriente que €5.000 con la mitad vencida.
  --
  -- 🔁 Desde el 2026-09-11 excluye lo castigado y lo de prueba: lo primero ya
  -- no se espera cobrar y tiene su propia cifra, y lo segundo no es dinero.
  select coalesce(sum(amount_usd), 0) into v_overdue
  from public.installments
  where status = 'pending'
    and written_off_at is null
    and not is_test
    and due_date < v_today;

  -- El principal que sigue fuera. Lo que se pierde entero si no vuelve.
  select coalesce(sum(financed_usd), 0) into v_principal
  from public.installments
  where status = 'pending'
    and written_off_at is null
    and not is_test;

  -- El fee que ya se cobró de verdad. La cuota es todo o nada —no hay pagos a
  -- medias a nivel de cuota—, así que una cuota pagada trae su fee entero.
  select coalesce(sum(amount_usd - financed_usd), 0) into v_fee_paid
  from public.installments
  where status = 'paid'
    and not is_test;

  return jsonb_build_object(
    'cash', v_cash,
    'user_receivable', v_receivable,
    'overdue_receivable', v_overdue,
    'principal_outstanding', v_principal,
    'merchant_payable', v_payable,
    'platform_revenue', v_revenue,
    'commission_collected', v_fee_paid,
    'written_off', v_written_off,
    'fx_difference', v_fx,
    -- Todo lo que está comprometido y todavía no ha vuelto a caja.
    'committed', v_receivable + v_payable,
    -- Lo que queda libre para seguir financiando. Puede salir negativo, y con
    -- liquidación por fecha eso es lo normal: no es una alarma por sí solo.
    'free_capital', v_cash - v_payable
  );
end;
$$;

comment on function public.admin_cash_position() is
  'Caja y exposicion. Las cifras del libro salen del ledger; principal_outstanding y commission_collected salen de installments, que es lo unico que sabe repartir una cuota entre principal y fee.';

revoke all on function public.admin_cash_position() from public, anon;
grant execute on function public.admin_cash_position() to authenticated;
