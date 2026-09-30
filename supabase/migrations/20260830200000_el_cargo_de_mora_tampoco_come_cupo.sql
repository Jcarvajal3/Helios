-- ============================================================================
-- Ronda — El cargo por mora tampoco ocupa cupo
--
-- Lo destapó `mora_smoke` al correr contra el modelo nuevo: tras separar cupo
-- de fee (20260830190000), el bloque de un usuario en mora cargaba 40,00 de
-- consumo **más los 4,00 del cargo**, y esos 4 seguían restando de su límite.
--
-- Es la misma regla de ayer aplicada a la otra comisión: **Ronda financia el
-- consumo, no sus propios cobros.** El cargo por mora es una penalización, no
-- algo que el usuario se haya llevado del local, así que no tiene por qué
-- encogerle el cupo — igual que no se lo encoge el fee del servicio.
--
-- Sigue siendo deuda a todos los efectos: entra en `fee_usd`, hay que pagarlo
-- para cerrar el bloque, viaja en la siguiente cotización y se castiga con el
-- resto si la cuenta acaba en incobrable. Lo único que cambia es que no resta
-- del límite del nivel.
--
-- En la práctica se nota poco —quien tiene un cargo por mora está congelado y
-- no puede consumir— pero se nota justo cuando importa: al ponerse al día, el
-- límite que recupera es el suyo entero y no el suyo menos cuatro dólares.
-- ============================================================================

-- Cuerpo idéntico al de 20260830170000 salvo la línea marcada NUEVO.
create or replace function public.charge_late_fee(
  p_user_id   uuid,
  p_days_late integer
)
returns uuid
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_block  public.user_credit_blocks%rowtype;
  v_amount numeric(18,4) := public.helios_late_fee_usd();
  v_bdate  date := public.helios_business_date(now());
  v_fee_id uuid;
  v_tx     uuid;
begin
  -- Poner el parámetro en 0 apaga el cargo entero sin desconectar el motor.
  if v_amount <= 0 then
    return null;
  end if;

  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user_id and closed_at is null
  for update;

  -- Sin bloque abierto no hay deuda viva a la que sumar el cargo. Pasa con un
  -- usuario ya castigado por incobrable: su bloque se cerró.
  if not found then
    return null;
  end if;

  if exists (select 1 from public.late_fees where credit_block_id = v_block.id) then
    return null;
  end if;

  insert into public.late_fees
    (user_id, credit_block_id, amount_usd, days_late, business_date)
  values
    (p_user_id, v_block.id, v_amount, p_days_late, v_bdate)
  returning id into v_fee_id;

  -- Ingreso devengado, sin IVA. La caja no se mueve: el dinero entra cuando el
  -- usuario pague, igual que con una cuota.
  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'late_fee', 'late_fee:' || v_fee_id::text, v_bdate, v_fee_id,
    format('Cargo por mora (%s dias de retraso)', p_days_late)
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, ledger.get_or_create_account('user_receivable', p_user_id), v_amount, 0),
    (v_tx, ledger.get_or_create_account('platform_revenue', null), 0, v_amount);

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- A `fee_usd`, no a `charged_usd`. Sigue siendo deuda —el bloque no se cierra
  -- hasta cubrirlo— pero no resta del límite del nivel: no es consumo.
  update public.user_credit_blocks
    set fee_usd = fee_usd + v_amount
  where id = v_block.id;
  -- ─────────────────────────────────────────────────────────────────────────

  -- La deuda de alguien no puede crecer en silencio.
  perform public.notify(
    p_user_id,
    'late_fee_charged',
    'Cargo por mora',
    format(
      'Se sumaron $%s a tu deuda por %s %s de retraso. Es un cargo único: no vuelve a cobrarse aunque sigas con la cuota pendiente.',
      trim(to_char(v_amount, 'FM999999990.00')),
      p_days_late,
      case when p_days_late = 1 then 'día' else 'días' end
    ),
    jsonb_build_object(
      'late_fee_id', v_fee_id,
      'amount_usd', v_amount,
      'days_late', p_days_late
    )
  );

  return v_fee_id;
end;
$$;

revoke all on function public.charge_late_fee(uuid, integer) from public, anon, authenticated;

-- Los cargos ya devengados, reclasificados. En dev son de las pruebas; en
-- producción todavía no hay ninguno, así que esto es un no-op — pero si lo
-- hubiera, dejarlo en `charged_usd` le comería el cupo para siempre.
with cargos as (
  select f.credit_block_id, sum(f.amount_usd) as total
  from public.late_fees f
  where f.status = 'pending'
  group by f.credit_block_id
)
update public.user_credit_blocks b
set charged_usd = b.charged_usd - c.total,
    fee_usd     = b.fee_usd + c.total
from cargos c
where c.credit_block_id = b.id
  and b.closed_at is null
  and b.charged_usd >= c.total;
