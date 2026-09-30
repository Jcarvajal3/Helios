-- ============================================================================
-- Ronda — 🐛 Al comercio se le encolaba la MITAD de lo que se le debe
--
-- `per_installment_pct` está definido como un porcentaje **del consumo**: la
-- restricción `settlement_adds_up` lo dice sin lugar a dudas —
-- `upfront + per_installment*2 + commission = 100`— y docs/00 §2.5 lo escribe
-- como "fecha de cuota 1 → 25% → comercio".
--
-- Pero `run_scheduled_settlements` lo aplicaba al importe de **la cuota**, que
-- es la mitad del consumo:
--
--     v_amount := round(v_inst.amount_usd * v_terms.per_installment_pct / 100, 4)
--                        ^^^^^^^^^^^^^^^^^ la cuota, no el consumo
--
-- Consumo de $100 con las condiciones por defecto (30 / 25 / 25 / 20):
--
--     devengado en el libro al vender ......... $80,00   (correcto)
--     encolado para pagar:
--       advance ............................... $30,00
--       scheduled_installment (cuota 1) ....... $12,50   ← debería ser $25,00
--       scheduled_installment (cuota 2) ....... $12,50   ← debería ser $25,00
--                                               ───────
--                                               $55,00
--
-- **$25 de cada $100 vendidos nunca llegaban a la cola de pago.** El libro
-- decía que se le debían al comercio y la cola no los pedía nunca: un pasivo
-- que crece en silencio y un comercio que cobra el 55% cuando se le prometió
-- el 80%.
--
-- Con un cobro de mesa era peor de leer pero igual de malo: las cuotas de un
-- mismo vencimiento sumaban la mitad del consumo entre todos los integrantes,
-- así que el resultado era el mismo 50%.
--
-- ---------------------------------------------------------------------------
-- El arreglo: se devenga por CONSUMO y fecha, no por cuota
-- ---------------------------------------------------------------------------
-- Un consumo genera exactamente dos liquidaciones programadas, una por fecha
-- de vencimiento, cada una del `per_installment_pct` del consumo. Cuántas
-- cuotas haya dentro de esa fecha —una si pagó uno solo, ocho si lo repartió
-- una mesa— deja de importar: lo que se le debe al comercio depende de lo que
-- vendió, no de entre cuántos se repartió el pago.
--
-- La idempotencia pasa de `(installment_id, reason)` a
-- `(charge_id, reason, business_date)`, que es lo que ahora identifica una
-- liquidación. Sin la fecha, la segunda cuota no se encolaría nunca.
--
-- ⚠️ **Los consumos ya liquidados no se recalculan.** Las filas viejas de
-- `settlements` se quedan como están: son instrucciones de pago, algunas ya
-- ejecutadas contra un banco. La diferencia acumulada hay que sacarla con un
-- ajuste desde el super admin, con su motivo y su firma — no reescribiendo el
-- pasado desde una migración.
-- ============================================================================

create or replace function public.run_scheduled_settlements(p_business_date date)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_charge record;
  v_terms  public.merchant_settlement_terms%rowtype;
  v_amount numeric(18,4);
  v_count  integer := 0;
begin
  /**
   * Un consumo por vuelta, no una cuota por vuelta.
   *
   * `distinct` sobre el cobro: en un consumo de mesa hay una cuota por
   * integrante venciendo el mismo día, y todas hablan de la misma venta.
   */
  for v_charge in
    select distinct c.id as charge_id, c.merchant_id, c.amount_usd
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.due_date = p_business_date
  loop
    select * into v_terms from public.merchant_settlement_terms
    where merchant_id = v_charge.merchant_id;

    if v_terms.policy <> 'scheduled' then
      continue;
    end if;

    -- Idempotente por consumo Y FECHA: correr la función dos veces el mismo
    -- día no duplica, y la segunda cuota sí se encola cuando le toque.
    if exists (
      select 1 from public.settlements
      where charge_id = v_charge.charge_id
        and reason = 'scheduled_installment'
        and business_date = p_business_date
    ) then
      continue;
    end if;

    v_amount := round(v_charge.amount_usd * v_terms.per_installment_pct / 100, 4);

    -- `installment_id` queda en null a propósito: la liquidación es del
    -- consumo. Apuntar a una cuota cualquiera de las ocho de una mesa sería
    -- elegir una al azar y dar a entender que las otras siete no cuentan.
    insert into public.settlements
      (merchant_id, charge_id, installment_id, reason, amount_usd, business_date, due_date, status)
    values
      (v_charge.merchant_id, v_charge.charge_id, null, 'scheduled_installment',
       v_amount, p_business_date, p_business_date, 'pending');

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.run_scheduled_settlements(date) from public, anon, authenticated;
