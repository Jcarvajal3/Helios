-- ═══════════════════════════════════════════════════════════════════════════
-- Ronda — La bóveda salda las liquidaciones de su local
--
-- A un local con garantía (La Quinta) no se le transfiere nada: Ronda ya le
-- adelantó el dinero. Pero el cierre le seguía generando liquidaciones, que
-- se quedaban pendientes y salían como pago atrasado. Desde aquí:
--
--   1. El depósito de la bóveda se anota en el libro: sale de caja y entra en
--      la garantía del local (`merchant_prepaid`). Los depósitos que ya había
--      se anotan con su día operativo de entonces.
--   2. «Bóveda» es un medio de pago más (`merchant_payouts.method = 'boveda'`).
--      Saldar con él baja lo que se le debe al local y baja su garantía, sin
--      tocar la caja: no sale nada del banco.
--   3. Cada mañana, después de generar las liquidaciones programadas, las
--      pendientes de un local con garantía se saldan solas contra ella, hasta
--      donde alcance. Lo que no alcance queda pendiente, para una transferencia.
--   4. Con garantía sin gastar, el panel no deja registrar una transferencia a
--      ese local: sería pagarle dos veces lo mismo.
--
-- Qué NO cambia: el saldo de la bóveda que enseña el panel (€8.149 el 29-09)
-- lo calcula `merchant_vault_state` como depósitos menos la base de las compras
-- confirmadas, y no mira ni liquidaciones ni pagos. Saldar contra la garantía
-- no lo vuelve a bajar. Son dos cifras distintas y las dos son ciertas:
--
--   · saldo de la bóveda — lo que el local todavía puede vender con la
--     garantía (baja al confirmar cada compra);
--   · garantía en el libro — lo adelantado que todavía no se ha aplicado a
--     liquidaciones (baja al saldar cada liquidación, que llega después, con
--     las cuotas). Cuando todas las ventas se hayan liquidado, coinciden.
--
-- Lo que miraba `merchant_payouts` como «transferido a los locales» (la serie
-- diaria, Caja y la semana) deja fuera las de bóveda: no salieron del banco.
-- ═══════════════════════════════════════════════════════════════════════════


-- ── 1. El medio «boveda» y quién lo paga ─────────────────────────────────

alter table public.merchant_payouts drop constraint merchant_payouts_method_check;
alter table public.merchant_payouts add constraint merchant_payouts_method_check
  check (method = any (array['pago_movil', 'transferencia', 'zelle', 'usdt', 'efectivo', 'boveda']));

-- Un saldo automático de la bóveda no lo hace nadie: lo hace el trabajo de la
-- mañana. `paid_by` nulo es eso, y solo eso.
alter table public.merchant_payouts alter column paid_by drop not null;
alter table public.merchant_payouts add constraint merchant_payouts_paid_by_solo_boveda
  check (paid_by is not null or method = 'boveda');

-- Una liquidación a medias se termina de pagar en OTRO pago: la garantía se
-- acaba a mitad de una y el resto va por transferencia, o una transferencia
-- parcial se completa el lunes siguiente. El índice de 20260822120000 («una
-- liquidación solo se puede pagar una vez») es anterior a los pagos parciales
-- (20260911191000) y hacía fallar ese segundo pago con una clave duplicada.
-- Que no se pague de más lo guardan las funciones: solo tocan liquidaciones
-- 'pending'/'partial' y nunca por encima de lo que les falta.
drop index if exists public.payout_items_settlement_unique;

comment on column public.merchant_payouts.method is
  'Por dónde salió. «boveda» no sale del banco: se descuenta de la garantía del local (ledger merchant_prepaid).';


-- ── 2. La garantía de un local, según el libro ───────────────────────────

create or replace function ledger.merchant_prepaid_balance(p_merchant_id uuid)
returns numeric
language sql
stable
set search_path = ledger, pg_temp
as $$
  select coalesce(sum(e.debit - e.credit), 0)
  from ledger.entries e
  join ledger.accounts a on a.id = e.account_id
  where a.account_type = 'merchant_prepaid'
    and a.owner_id = p_merchant_id;
$$;

revoke all on function ledger.merchant_prepaid_balance(uuid) from public, anon, authenticated;

comment on function ledger.merchant_prepaid_balance(uuid) is
  'Lo que Helios le adelantó al local (depósitos de la bóveda) menos lo ya aplicado a sus liquidaciones. No es el saldo de la bóveda del panel: ese es merchant_vault_state.';


-- ── 3. El depósito, al libro ─────────────────────────────────────────────

-- Idempotente por la clave: el trigger y el relleno de abajo pueden pasar por
-- el mismo depósito sin anotarlo dos veces.
create or replace function ledger.record_vault_deposit(p_topup_id uuid)
returns void
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_topup public.merchant_vault_topups%rowtype;
  v_tx    uuid;
begin
  select * into v_topup from public.merchant_vault_topups where id = p_topup_id;
  if not found then
    raise exception 'No existe ese depósito de bóveda' using errcode = 'P0002';
  end if;

  if exists (
    select 1 from ledger.transactions where idempotency_key = 'vault_topup:' || p_topup_id::text
  ) then
    return;
  end if;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo, created_by)
  values (
    'vault_deposit', 'vault_topup:' || p_topup_id::text,
    -- El día operativo en que salió, no el de hoy: el relleno anota el
    -- depósito del 19-09 en su semana.
    public.helios_business_date(v_topup.created_at),
    p_topup_id,
    'Garantía depositada en el local',
    v_topup.actor
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, ledger.get_or_create_account('merchant_prepaid', v_topup.merchant_id), v_topup.amount_usd, 0),
    (v_tx, ledger.get_or_create_account('cash', null), 0, v_topup.amount_usd);
end;
$$;

revoke all on function ledger.record_vault_deposit(uuid) from public, anon, authenticated;

create or replace function public.vault_topup_to_ledger()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform ledger.record_vault_deposit(new.id);
  return null;
end;
$$;

revoke all on function public.vault_topup_to_ledger() from public, anon, authenticated;

drop trigger if exists vault_topups_to_ledger on public.merchant_vault_topups;
create trigger vault_topups_to_ledger
  after insert on public.merchant_vault_topups
  for each row execute function public.vault_topup_to_ledger();

-- Los depósitos que ya había.
select ledger.record_vault_deposit(t.id)
from public.merchant_vault_topups t
order by t.created_at;


-- ── 4. Saldar liquidaciones contra la garantía ───────────────────────────

-- El camino común del botón del panel y del trabajo de la mañana.
--
--   p_settlement_ids  las marcadas; nulo (solo en automático) = todas las
--                     pendientes del local.
--   p_amount_usd      nulo = todo lo marcado.
--   p_strict          en el panel, lo que la garantía no cubre es un error que
--                     se explica; en automático se salda hasta donde alcance
--                     y el resto espera a una transferencia.
create or replace function public.helios_settle_from_vault(
  p_merchant_id    uuid,
  p_settlement_ids uuid[],
  p_amount_usd     numeric,
  p_actor          uuid,
  p_note           text,
  p_strict         boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $$
declare
  v_ids       uuid[];
  v_garantia  numeric(18,4);
  v_pendiente numeric(18,4);
  v_total     numeric(18,4);
  v_restante  numeric(18,4);
  v_aplicado  numeric(18,4);
  v_count     integer;
  v_cubiertas integer := 0;
  v_bdate     date := public.helios_business_date(now());
  v_payout    public.merchant_payouts%rowtype;
  v_tx        uuid;
  v_fila      record;
  v_note      text := coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Cubierto por la garantía');
begin
  -- Serializa por local: dos saldos a la vez leerían la misma garantía y
  -- gastarían dos veces lo mismo.
  perform 1 from public.merchant_vaults where merchant_id = p_merchant_id for update;
  if not found then
    raise exception 'Ese local no tiene bóveda' using errcode = '22023';
  end if;

  if p_settlement_ids is null then
    if p_strict then
      raise exception 'Selecciona al menos una liquidación' using errcode = '22023';
    end if;
    select array_agg(s.id order by s.due_date, s.id) into v_ids
    from public.settlements s
    where s.merchant_id = p_merchant_id
      and s.status in ('pending', 'partial');
  else
    v_ids := p_settlement_ids;
  end if;

  if v_ids is null or array_length(v_ids, 1) is null then
    if p_strict then
      raise exception 'Selecciona al menos una liquidación' using errcode = '22023';
    end if;
    return jsonb_build_object('ok', true, 'merchant_id', p_merchant_id, 'amount_usd', 0, 'settlements', 0);
  end if;

  perform 1 from public.settlements where id = any(v_ids) for update;

  select coalesce(sum(amount_usd - paid_usd), 0), count(*)
    into v_pendiente, v_count
  from public.settlements
  where id = any(v_ids)
    and merchant_id = p_merchant_id
    and status in ('pending', 'partial');

  if v_count <> array_length(v_ids, 1) then
    raise exception 'Alguna liquidación no es de este comercio o ya está pagada entera'
      using errcode = '22023';
  end if;

  v_total    := coalesce(p_amount_usd, v_pendiente);
  v_garantia := ledger.merchant_prepaid_balance(p_merchant_id);

  if v_total <= 0 then
    raise exception 'El importe tiene que ser mayor que cero' using errcode = '22023';
  end if;

  if v_total > v_pendiente + 0.005 then
    raise exception 'No puedes saldar % cuando lo marcado suma %',
      round(v_total, 2), round(v_pendiente, 2) using errcode = '22023';
  end if;

  if v_total > v_garantia + 0.005 then
    if p_strict then
      raise exception 'La garantía de este local solo cubre %: marca menos o paga el resto por transferencia',
        round(greatest(v_garantia, 0), 2) using errcode = '22023';
    end if;
    v_total := greatest(v_garantia, 0);
  end if;

  if v_total < 0.005 then
    return jsonb_build_object('ok', true, 'merchant_id', p_merchant_id, 'amount_usd', 0,
      'settlements', 0, 'guarantee_left_usd', v_garantia);
  end if;

  insert into public.merchant_payouts
    (merchant_id, amount_usd, amount_ves, fx_rate, method, reference, note,
     paid_by, business_date, paid_on, receipt_path)
  values
    (p_merchant_id, v_total, null, null, 'boveda', null, v_note,
     p_actor, v_bdate, v_bdate, null)
  returning * into v_payout;

  -- De la más antigua a la más nueva, como una transferencia: la última que
  -- alcanza queda parcial.
  v_restante := v_total;

  for v_fila in
    select id, amount_usd, paid_usd
    from public.settlements
    where id = any(v_ids)
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

    v_restante  := v_restante - v_aplicado;
    v_cubiertas := v_cubiertas + 1;
  end loop;

  -- Baja lo que se le debe al local y baja la garantía. La caja, quieta: ese
  -- dinero salió el día del depósito.
  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo, created_by)
  values (
    'vault_settlement', 'payout:' || v_payout.id::text, v_bdate, v_payout.id,
    format('Cubierto por la garantía (%s liquidaciones)', v_cubiertas),
    p_actor
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, ledger.get_or_create_account('merchant_payable', p_merchant_id), v_total, 0),
    (v_tx, ledger.get_or_create_account('merchant_prepaid', p_merchant_id), 0, v_total);

  -- La bitácora es de lo que hace una persona (`actor` no admite nulos). El
  -- saldo de la mañana queda en `merchant_payouts` con `paid_by` nulo y en el
  -- libro.
  if p_actor is not null then
    perform audit.log(p_actor, 'merchant.payout', p_merchant_id,
      jsonb_build_object(
        'payout_id', v_payout.id, 'amount_usd', v_total,
        'pending_usd', v_pendiente,
        'partial', v_total < v_pendiente - 0.005,
        'settlements', v_cubiertas, 'method', 'boveda',
        'paid_on', v_bdate,
        'guarantee_before_usd', v_garantia,
        'guarantee_after_usd', v_garantia - v_total,
        'note', v_note
      ));
  end if;

  return jsonb_build_object(
    'ok', true, 'merchant_id', p_merchant_id, 'payout_id', v_payout.id,
    'amount_usd', v_total, 'pending_usd', v_pendiente, 'settlements', v_cubiertas,
    'amount_ves', null, 'fx_rate', null, 'paid_on', v_bdate,
    'guarantee_left_usd', v_garantia - v_total
  );
end;
$$;

revoke all on function public.helios_settle_from_vault(uuid, uuid[], numeric, uuid, text, boolean)
  from public, anon, authenticated;

comment on function public.helios_settle_from_vault(uuid, uuid[], numeric, uuid, text, boolean) is
  'Salda liquidaciones de un local contra su garantía (ledger merchant_prepaid). No toca la caja ni el saldo de la bóveda del panel.';


-- Todos los locales con garantía por gastar y algo pendiente. Uno que falle no
-- para a los demás.
create or replace function public.helios_settle_vaults()
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_m   record;
  v_res jsonb;
  v_out jsonb := '[]'::jsonb;
begin
  for v_m in
    select distinct s.merchant_id
    from public.settlements s
    join public.merchant_vaults v on v.merchant_id = s.merchant_id
    where s.status in ('pending', 'partial')
    order by s.merchant_id
  loop
    if ledger.merchant_prepaid_balance(v_m.merchant_id) < 0.005 then
      continue;
    end if;

    begin
      v_res := public.helios_settle_from_vault(v_m.merchant_id, null, null, null, null, false);
      v_out := v_out || jsonb_build_array(v_res);
    exception when others then
      raise warning 'Saldo con la bóveda fallido para el comercio %: %', v_m.merchant_id, sqlerrm;
    end;
  end loop;

  return v_out;
end;
$$;

revoke all on function public.helios_settle_vaults() from public, anon, authenticated;


-- ── 5. El registro manual: «Bóveda» va por su camino, y con garantía por
--       gastar no se registran transferencias ──────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_report_merchant_payout(p_merchant_id uuid, p_settlement_ids uuid[], p_method text, p_reference text DEFAULT NULL::text, p_amount_ves numeric DEFAULT NULL::numeric, p_fx_rate numeric DEFAULT NULL::numeric, p_note text DEFAULT NULL::text, p_amount_usd numeric DEFAULT NULL::numeric, p_paid_on date DEFAULT NULL::date, p_receipt_path text DEFAULT NULL::text)
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

  -- Saldar contra la garantía no sale del banco: sin tasa, sin referencia y
  -- contra la cuenta de la garantía, no contra la caja.
  if p_method = 'boveda' then
    return public.helios_settle_from_vault(
      p_merchant_id, p_settlement_ids, p_amount_usd, v_actor, v_note, true
    );
  end if;

  -- Con garantía por gastar, una transferencia le pagaría al local dos veces
  -- lo mismo: primero se gasta la garantía.
  if ledger.merchant_prepaid_balance(p_merchant_id) >= 0.005 then
    raise exception 'Este local tiene % de garantía sin gastar: salda sus liquidaciones con «Bóveda»',
      round(ledger.merchant_prepaid_balance(p_merchant_id), 2) using errcode = '22023';
  end if;

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

-- ── 6. Cada mañana, después de generar las liquidaciones ─────────────────
CREATE OR REPLACE PROCEDURE public.run_scheduled_settlements_loop(IN p_days_back integer DEFAULT 7, IN p_batch integer DEFAULT 50)
 LANGUAGE plpgsql
AS $procedure$
declare
  v_today date := public.helios_business_date(now());
  v_day   date;
  v_after uuid;
  v_res   jsonb;
begin
  -- Del día más viejo al de hoy: lo atrasado se devenga antes que lo nuevo.
  for v_back in reverse p_days_back .. 0 loop
    v_day   := v_today - v_back;
    v_after := '00000000-0000-0000-0000-000000000000';
    loop
      v_res := public.run_scheduled_settlements_batch(v_day, v_after, p_batch);
      commit;
      exit when (v_res ->> 'seen')::integer < p_batch;
      v_after := (v_res ->> 'last')::uuid;
    end loop;
  end loop;

  -- Lo que cubre la garantía de un local se salda solo, contra ella: a ese
  -- local no se le transfiere nada.
  perform public.helios_settle_vaults();
  commit;
end;
$procedure$;

-- ── 7. Lo que cuenta transferencias deja fuera la bóveda ─────────────────
CREATE OR REPLACE FUNCTION public.admin_daily_series(p_days integer DEFAULT 30)
 RETURNS TABLE(business_date date, financed_usd numeric, charge_count integer, collected_usd numeric, settled_usd numeric, service_fee_usd numeric, late_fee_usd numeric, active_users integer, merchants_with_sales integer, new_users integer, first_time_buyers integer, written_off_financed_usd numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today date    := public.helios_business_date(now());
  v_days  integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_from  date;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := v_today - (v_days - 1);

  return query
  with
  dias as (
    select generate_series(v_from, v_today, interval '1 day')::date as d
  ),
  cargo as (
    select ch.business_date as d,
           count(*)::integer                         as cnt,
           count(distinct ch.merchant_id)::integer   as locales,
           sum(coalesce(ch.consumer_fee_usd, 0))     as fee
    from public.charges ch
    where ch.status = 'confirmed' and not ch.is_test
      and ch.business_date between v_from and v_today
    group by 1
  ),
  cuota as (
    select ch.business_date as d,
           sum(i.financed_usd)                       as fin,
           count(distinct i.user_id)::integer        as gente
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    where ch.status = 'confirmed' and not ch.is_test and not i.is_test
      and ch.business_date between v_from and v_today
    group by 1
  ),
  cobrado as (
    -- Cobrado de verdad: cuotas aprobadas, por día operativo del cobro. Es
    -- deuda que vuelve, así que va en payable.
    select public.helios_business_date(i.paid_at) as d, sum(i.amount_usd) as cob
    from public.installments i
    where i.status = 'paid' and i.paid_at is not null and not i.is_test
      and i.paid_at >= public.helios_business_day_end(v_from - 1)
    group by 1
  ),
  pagado as (
    -- Salido de caja hacia los locales.
    select mp.business_date as d, sum(mp.amount_usd) as pag
    from public.merchant_payouts mp
    where not public.helios_is_test_merchant(mp.merchant_id)
      -- La bóveda no sale del banco: no es una transferencia.
      and mp.method <> 'boveda'
      and mp.business_date between v_from and v_today
    group by 1
  ),
  atraso as (
    -- Cargos por atraso que cayeron ese día. Los condonados no son ingreso.
    select lf.business_date as d, sum(lf.amount_usd) as cargo
    from public.late_fees lf
    join public.profiles p on p.id = lf.user_id and not p.is_test
    where lf.waived_at is null
      and lf.business_date between v_from and v_today
    group by 1
  ),
  registro as (
    select s.dia as d, count(*)::integer as n
    from public.helios_signups s
    where s.dia between v_from and v_today
    group by 1
  ),
  primer as (
    select x.d, count(*)::integer as n
    from (
      select i.user_id, min(ch.business_date) as d
      from public.installments i
      join public.charges ch on ch.id = i.charge_id
      where ch.status = 'confirmed' and not ch.is_test and not i.is_test
      group by 1
    ) x
    where x.d between v_from and v_today
    group by 1
  ),
  perdido as (
    select public.helios_business_date(i.written_off_at) as d, sum(i.financed_usd) as fin
    from public.installments i
    where i.written_off_at is not null and not i.is_test
      and i.written_off_at >= public.helios_business_day_end(v_from - 1)
    group by 1
  )
  select
    dias.d,
    coalesce(cu.fin, 0)::numeric,
    coalesce(ca.cnt, 0)::integer,
    coalesce(co.cob, 0)::numeric,
    coalesce(pa.pag, 0)::numeric,
    coalesce(ca.fee, 0)::numeric,
    coalesce(at.cargo, 0)::numeric,
    coalesce(cu.gente, 0)::integer,
    coalesce(ca.locales, 0)::integer,
    coalesce(re.n, 0)::integer,
    coalesce(pr.n, 0)::integer,
    coalesce(pe.fin, 0)::numeric
  from dias
  left join cargo ca    on ca.d = dias.d
  left join cuota cu    on cu.d = dias.d
  left join cobrado co  on co.d = dias.d
  left join pagado pa   on pa.d = dias.d
  left join atraso at   on at.d = dias.d
  left join registro re on re.d = dias.d
  left join primer pr   on pr.d = dias.d
  left join perdido pe  on pe.d = dias.d
  order by dias.d;
end;
$function$;

CREATE OR REPLACE FUNCTION metricas.caja_movimientos(p_desde date, p_hasta date, p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(cuotas_cobradas integer, personas_que_pagaron integer, cobrado_payable_usd numeric, cobrado_financed_usd numeric, cobrado_fee_usd numeric, cobrado_servicio_usd numeric, cargos_cobrados integer, cargos_cobrados_usd numeric, transferencias integer, transferido_usd numeric, consumos integer, consumo_usd numeric, servicio_ganado_usd numeric, cargos_devengados_usd numeric, libro_cobrado_usd numeric, libro_transferido_usd numeric, libro_otros_usd numeric)
 LANGUAGE sql
 STABLE
AS $function$
  with
  -- Las cuotas cuyo pago se aprobó en esos días, con la parte de servicio
  -- SIN IVA que llevaban dentro: la de su consumo, en proporción a su fee.
  cobradas as (
    select q.user_id, q.payable_usd, q.financed_usd, q.fee_usd,
           q.fee_usd * coalesce(k.servicio_usd / nullif(k.fee_usd, 0), 0) as servicio
    from metricas.cuotas q
    join metricas.consumos k on k.charge_id = q.charge_id
    where q.status = 'paid'
      -- El día de la APROBACIÓN, que es cuando el libro apunta el cobro.
      -- pagada_dia es ahora el del reporte (juzga «a tiempo»), no el de caja.
      and metricas.dia_operativo(q.paid_at) between p_desde and p_hasta
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ),
  cargos as (
    select c.amount_usd, c.status, c.business_date, c.pagado_dia
    from metricas.cargos_por_atraso c
    where p_merchant_id is null or c.merchant_id = p_merchant_id
  ),
  pagos as (
    select mp.amount_usd
    from public.merchant_payouts mp
    join public.merchants m on m.id = mp.merchant_id
    where not m.is_test
      and mp.business_date between p_desde and p_hasta
      -- La bóveda no sale del banco: no es una transferencia.
      and mp.method <> 'boveda'
      and (p_merchant_id is null or mp.merchant_id = p_merchant_id)
  ),
  ventas as (
    select k.financed_usd, k.servicio_usd
    from metricas.consumos k
    where k.business_date between p_desde and p_hasta
      and (p_merchant_id is null or k.merchant_id = p_merchant_id)
  ),
  -- El libro de caja no sabe de locales: solo sin local.
  libro as (
    select l.tipo, l.debit, l.credit
    from metricas.libro_de_caja l
    where p_merchant_id is null
      and l.business_date between p_desde and p_hasta
  )
  select
    (select count(*) from cobradas)::integer,
    (select count(distinct user_id) from cobradas)::integer,
    (select coalesce(sum(payable_usd), 0) from cobradas),
    (select coalesce(sum(financed_usd), 0) from cobradas),
    (select coalesce(sum(fee_usd), 0) from cobradas),
    (select round(coalesce(sum(servicio), 0), 4) from cobradas),
    (select count(*) from cargos where status = 'paid' and pagado_dia between p_desde and p_hasta)::integer,
    (select coalesce(sum(amount_usd), 0) from cargos where status = 'paid' and pagado_dia between p_desde and p_hasta),
    (select count(*) from pagos)::integer,
    (select coalesce(sum(amount_usd), 0) from pagos),
    (select count(*) from ventas)::integer,
    (select coalesce(sum(financed_usd), 0) from ventas),
    (select coalesce(sum(servicio_usd), 0) from ventas),
    (select coalesce(sum(amount_usd), 0) from cargos where business_date between p_desde and p_hasta),
    case when p_merchant_id is null then
      (select coalesce(sum(debit), 0) from libro where tipo = 'installment_payment') end,
    case when p_merchant_id is null then
      (select coalesce(sum(credit), 0) from libro where tipo = 'merchant_settlement') end,
    case when p_merchant_id is null then
      (select coalesce(sum(debit - credit), 0) from libro
       where tipo not in ('installment_payment', 'merchant_settlement')) end;
$function$;

CREATE OR REPLACE FUNCTION metricas.semana_periodo(p_desde date, p_hasta date, p_merchant_id uuid DEFAULT NULL::uuid, p_juzgado_hasta date DEFAULT NULL::date, p_corte timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
begin
  return (
    with
    consumo as (
      select count(*)::integer                      as consumos,
             coalesce(sum(k.financed_usd), 0)       as financed,
             coalesce(sum(k.servicio_usd), 0)       as servicio,
             count(distinct k.merchant_id)::integer as locales
      from metricas.consumos k
      where k.business_date between p_desde and p_hasta
        and (p_merchant_id is null or k.merchant_id = p_merchant_id)
        and (p_corte is null or k.confirmed_at <= p_corte)
    ),
    quienes as (
      -- Las personas salen de las cuotas: en un grupo, todas las que pagan.
      select count(distinct q.user_id)::integer as personas
      from metricas.cuotas q
      where q.business_date between p_desde and p_hasta
        and (p_merchant_id is null or q.merchant_id = p_merchant_id)
        and (p_corte is null or exists (
              select 1 from metricas.consumos k
              where k.charge_id = q.charge_id and k.confirmed_at <= p_corte))
    ),
    atraso as (
      select coalesce(sum(a.amount_usd), 0) as usd, count(*)::integer as cargos
      from metricas.cargos_por_atraso a
      where a.business_date between p_desde and p_hasta
        and (p_merchant_id is null or a.merchant_id = p_merchant_id)
        -- El instante en que se cargó: la vista no lo trae.
        and (p_corte is null or exists (
              select 1 from public.late_fees lf
              where lf.id = a.late_fee_id and lf.created_at <= p_corte))
    ),
    juicio as (
      select least(p_hasta, coalesce(p_juzgado_hasta, p_hasta)) as hasta
    ),
    vencian as (
      -- Las cuotas que vencían en el tramo, con su estado de hoy: el
      -- veredicto a tiempo / tarde ya no cambia una vez cerrado el plazo.
      select
        coalesce(sum(q.payable_usd), 0)  as payable,
        coalesce(sum(q.financed_usd), 0) as financed,
        coalesce(sum(q.fee_usd), 0)      as fee,
        count(*)::integer                as cuotas,
        count(*) filter (where q.due_date <= j.hasta and q.plazo_cerrado)::integer   as juzgadas,
        count(*) filter (where q.due_date <= j.hasta and q.plazo_cerrado
                           and q.estado_hoy = 'a_tiempo')::integer                   as a_tiempo,
        count(*) filter (where q.sequence = 1 and q.due_date <= j.hasta
                           and q.plazo_cerrado)::integer                             as juzgadas_1,
        count(*) filter (where q.sequence = 1 and q.due_date <= j.hasta and q.plazo_cerrado
                           and q.estado_hoy = 'a_tiempo')::integer                   as a_tiempo_1,
        count(*) filter (where q.sequence = 2 and q.due_date <= j.hasta
                           and q.plazo_cerrado)::integer                             as juzgadas_2,
        count(*) filter (where q.sequence = 2 and q.due_date <= j.hasta and q.plazo_cerrado
                           and q.estado_hoy = 'a_tiempo')::integer                   as a_tiempo_2
      from metricas.cuotas q
      cross join juicio j
      where q.due_date between p_desde and p_hasta
        and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    ),
    cartera as (
      -- La foto al cierre de `p_hasta`: la mora canónica.
      select * from metricas.cartera_al(p_hasta, p_merchant_id)
    ),
    perdido as (
      -- Lo que se dio por perdido dentro del tramo y seguía sin pagar al cierre.
      select coalesce(sum(q.payable_usd), 0)  as payable,
             coalesce(sum(q.financed_usd), 0) as financed,
             coalesce(sum(q.fee_usd), 0)      as fee,
             count(*)::integer                as cuotas
      from metricas.cuotas_al(p_hasta) q
      where q.estado_hoy = 'perdida'
        and public.helios_business_date(q.written_off_at) between p_desde and p_hasta
        and (p_corte is null or q.written_off_at <= p_corte)
        and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    ),
    padron as (
      -- Los registros (personas verificadas, por el día en que se aprobó su
      -- verificación) son del padrón, no de un local. `verificados` es la
      -- misma cifra y se queda por quien ya la lee.
      -- Con p_corte, solo lo que ya había pasado en ese instante: la
      -- verificación aprobada antes (`solicitudes.verificado_en`, el mismo
      -- instante que da el día de registro) y el primer consumo confirmado
      -- antes.
      select
        count(*) filter (where p.registro_dia between p_desde and p_hasta
                           and p.a_tiempo_del_corte)::integer                          as registros,
        count(*) filter (where p.verificado_dia between p_desde and p_hasta
                           and p.a_tiempo_del_corte)::integer                          as verificados,
        count(*) filter (where p.primer_consumo_dia between p_desde and p_hasta
                           and p.consumio_antes_del_corte)::integer                    as primer_consumo
      from (
        select pe.registro_dia, pe.verificado_dia, pe.primer_consumo_dia,
               (p_corte is null or s.verificado_en <= p_corte) as a_tiempo_del_corte,
               (p_corte is null or exists (
                  select 1 from metricas.cuotas q
                  join metricas.consumos k on k.charge_id = q.charge_id
                  where q.user_id = pe.user_id and k.confirmed_at <= p_corte)) as consumio_antes_del_corte
        from metricas.personas pe
        left join metricas.solicitudes s on p_corte is not null and s.user_id = pe.user_id
        where p_merchant_id is null
      ) p
    ),
    solicitudes as (
      -- Quien pidió el código en el tramo, se verificara o no: la boca del
      -- embudo. No es un registro. Tampoco es de ningún local.
      select count(*)::integer as solicitaron
      from metricas.solicitudes s
      where p_merchant_id is null
        and s.solicito_dia between p_desde and p_hasta
        and (p_corte is null or s.solicito_en <= p_corte)
    ),
    nuevos_en_el_local as (
      select count(*)::integer as primer_consumo
      from metricas.personas_por_local l
      where p_merchant_id is not null
        and l.merchant_id = p_merchant_id
        and l.primer_dia between p_desde and p_hasta
        and (p_corte is null or exists (
              select 1 from metricas.cuotas q
              join metricas.consumos k on k.charge_id = q.charge_id
              where q.user_id = l.user_id and q.merchant_id = l.merchant_id
                and k.confirmed_at <= p_corte))
    ),
    movimientos as (
      -- Con p_corte, sin los pagos a locales apuntados después de ese
      -- instante: el mismo conjunto que cuenta caja_movimientos (locales que
      -- no son de prueba, por su día operativo), menos los que aún no
      -- estaban.
      select m.transferido_usd - t.usd as transferido_usd,
             m.transferencias - t.n    as transferencias
      from metricas.caja_movimientos(p_desde, p_hasta, p_merchant_id) m
      cross join (
        select coalesce(sum(mp.amount_usd), 0) as usd, count(*)::integer as n
        from public.merchant_payouts mp
        join public.merchants me on me.id = mp.merchant_id
        where p_corte is not null
          and mp.created_at > p_corte
          -- La bóveda no sale del banco: no es una transferencia.
          and mp.method <> 'boveda'
          and not me.is_test
          and mp.business_date between p_desde and p_hasta
          and (p_merchant_id is null or mp.merchant_id = p_merchant_id)
      ) t
    )
    select jsonb_build_object(
      'consumo', jsonb_build_object(
        'financed_usd',     c.financed,
        'consumos',         c.consumos,
        'ticket_medio_usd', round(c.financed / nullif(c.consumos, 0), 2),
        'personas',         w.personas,
        'locales',          c.locales
      ),
      'ingreso', jsonb_build_object(
        'servicio_usd',          c.servicio,
        'cargos_por_atraso_usd', a.usd,
        'cargos_por_atraso',     a.cargos
      ),
      'cobro', jsonb_build_object(
        'vencian', jsonb_build_object(
          'payable_usd',  v.payable,
          'financed_usd', v.financed,
          'fee_usd',      v.fee,
          'cuotas',       v.cuotas
        ),
        'juzgado_hasta', case when j.hasta >= p_desde then j.hasta end,
        'a_tiempo', jsonb_build_object(
          'juzgadas', v.juzgadas,
          'a_tiempo', v.a_tiempo,
          'pct',      round(100.0 * v.a_tiempo / nullif(v.juzgadas, 0), 2)
        ),
        'cuota_1', jsonb_build_object(
          'juzgadas', v.juzgadas_1,
          'a_tiempo', v.a_tiempo_1,
          'pct',      round(100.0 * v.a_tiempo_1 / nullif(v.juzgadas_1, 0), 2)
        ),
        'cuota_2', jsonb_build_object(
          'juzgadas', v.juzgadas_2,
          'a_tiempo', v.a_tiempo_2,
          'pct',      round(100.0 * v.a_tiempo_2 / nullif(v.juzgadas_2, 0), 2)
        )
      ),
      'riesgo', jsonb_build_object(
        'al_cierre_de', p_hasta,
        'vencido', jsonb_build_object(
          'payable_usd',  k.vencido_payable_usd,
          'financed_usd', k.vencido_financed_usd,
          'fee_usd',      k.vencido_fee_usd,
          'cuotas',       k.cuotas_vencidas,
          'personas',     k.personas_vencidas
        ),
        'por_vencer', jsonb_build_object(
          'payable_usd',  k.por_vencer_payable_usd,
          'financed_usd', k.por_vencer_financed_usd,
          'fee_usd',      k.por_vencer_fee_usd
        ),
        'mora_pct', k.mora_pct,
        'perdido', jsonb_build_object(
          'payable_usd',  pe.payable,
          'financed_usd', pe.financed,
          'fee_usd',      pe.fee,
          'cuotas',       pe.cuotas
        )
      ),
      'gente', jsonb_build_object(
        'solicitaron',    case when p_merchant_id is null then so.solicitaron end,
        'registros',      case when p_merchant_id is null then g.registros end,
        'verificados',    case when p_merchant_id is null then g.verificados end,
        'primer_consumo', case when p_merchant_id is null then g.primer_consumo else n.primer_consumo end
      ),
      'caja', jsonb_build_object(
        'transferido_a_locales_usd', mv.transferido_usd,
        'pagos_a_locales',           mv.transferencias,
        'en_caja_usd',               case when p_merchant_id is null then metricas.caja_al(p_hasta) end
      )
    )
    from consumo c
    cross join quienes w
    cross join atraso a
    cross join juicio j
    cross join vencian v
    cross join cartera k
    cross join perdido pe
    cross join movimientos mv
    -- Las tres dan siempre una fila (son recuentos); solo se lee la que
    -- toca. La que no toca no recorre nada: su `where` es falso de entrada.
    cross join padron g
    cross join solicitudes so
    cross join nuevos_en_el_local n
  );
end;
$function$;

-- ── 8. El libro sabe de quién es un depósito de garantía ─────────────────
CREATE OR REPLACE FUNCTION public.admin_ledger_entries(p_limit integer DEFAULT 100, p_type text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_user_id uuid DEFAULT NULL::uuid, p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(transaction_id uuid, type text, business_date date, memo text, created_at timestamp with time zone, created_by uuid, actor_name text, amount_ves numeric, fx_rate numeric, cash_balance numeric, counterparty_kind text, counterparty_id uuid, counterparty_name text, lines jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  with movimiento as (
    -- Cuánto movió la caja cada transacción. Un asiento que no toca caja
    -- —un consumo, un devengo— no aparece aquí y deja el saldo donde estaba.
    select
      e.transaction_id as id,
      sum(e.debit) - sum(e.credit) as delta
    from ledger.entries e
    join ledger.accounts a on a.id = e.account_id
    where a.account_type = 'cash'
    group by e.transaction_id
  ),
  saldo as (
    -- La historia entera, acumulada. Se recorta después: el saldo tras un
    -- asiento no depende de cuántas filas quepan en la pantalla.
    select
      t.id,
      sum(coalesce(m.delta, 0)) over (
        order by t.created_at, t.id
        rows between unbounded preceding and current row
      ) as balance
    from ledger.transactions t
    left join movimiento m on m.id = t.id
  ),
  -- De quién es el asiento. Se toma el primer dueño que no sea nulo: una
  -- transacción toca varias cuentas pero solo una contraparte de negocio.
  parte as (
    select
      e.transaction_id,
      min(a.owner_id::text) filter (where a.account_type = 'user_receivable')  as user_id,
      min(a.owner_id::text) filter (where a.account_type in ('merchant_payable', 'merchant_prepaid')) as merchant_id
    from ledger.entries e
    join ledger.accounts a on a.id = e.account_id
    where a.owner_id is not null
    group by e.transaction_id
  )
  select
    t.id,
    t.type::text,
    t.business_date,
    t.memo,
    t.created_at,
    t.created_by,
    pa.full_name,
    -- El importe en bolívares a la tasa del día operativo **del asiento**, no
    -- a la de hoy: el movimiento ocurrió con aquella, y reconvertirlo con otra
    -- inventa una diferencia cambiaria que no existió. Se convierte lo que
    -- movió la caja, en valor absoluto: al banco le da igual el signo.
    (
      select round(abs(coalesce(m2.delta, 0)) * r.rate, 2)
      from public.exchange_rates r
      where r.effective_date <= t.business_date
      order by r.effective_date desc
      limit 1
    ),
    (
      select r.rate
      from public.exchange_rates r
      where r.effective_date <= t.business_date
      order by r.effective_date desc
      limit 1
    ),
    s.balance,
    case
      when p.user_id is not null then 'persona'
      when p.merchant_id is not null then 'comercio'
      else null
    end,
    coalesce(p.user_id, p.merchant_id)::uuid,
    coalesce(pr.full_name, me.name),
    (
      select jsonb_agg(
        jsonb_build_object(
          'account', a.account_type::text,
          'owner_id', a.owner_id,
          'debit', e.debit,
          'credit', e.credit
        ) order by e.id
      )
      from ledger.entries e
      join ledger.accounts a on a.id = e.account_id
      where e.transaction_id = t.id
    )
  from ledger.transactions t
  join saldo s on s.id = t.id
  left join movimiento m2 on m2.id = t.id
  left join parte p on p.transaction_id = t.id
  left join public.profiles pr on pr.id = p.user_id::uuid
  left join public.merchants me on me.id = p.merchant_id::uuid
  left join public.platform_admins pa on pa.user_id = t.created_by
  where (p_type is null or t.type::text = p_type)
    and (p_from is null or t.business_date >= p_from)
    and (p_to is null or t.business_date <= p_to)
    and (p_user_id is null or p.user_id::uuid = p_user_id)
    and (p_merchant_id is null or p.merchant_id::uuid = p_merchant_id)
  order by t.created_at desc, t.id desc
  limit least(coalesce(p_limit, 100), 500);
end;
$function$;

-- ── 9. La caja tras pagar a los locales no cuenta lo que cubre la garantía ─
CREATE OR REPLACE FUNCTION public.admin_cash_position(p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_local       boolean := p_merchant_id is not null;
  v_cash        numeric(18,4);
  v_receivable  numeric(18,4);
  v_payable     numeric(18,4);
  v_prepaid     numeric(18,4);
  v_covered     numeric(18,4) := 0;
  v_revenue     numeric(18,4);
  v_written_off numeric(18,4);
  v_fx          numeric(18,4);
  v_overdue     numeric(18,4);
  v_principal   numeric(18,4);
  v_fee_paid    numeric(18,4);
  v_cartera     record;
  v_serv        record;
  v_today       date := public.helios_business_date(now());
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- Lo del libro es de todo Ronda: sin local.
  if not v_local then
    v_cash        :=  ledger.balance_by_type('cash');
    v_receivable  :=  ledger.balance_by_type('user_receivable');
    v_payable     := -ledger.balance_by_type('merchant_payable');
    -- Lo adelantado a los locales con bóveda y todavía sin aplicar.
    v_prepaid     :=  ledger.balance_by_type('merchant_prepaid');
    -- De lo que se les debe, lo que ya cubre la garantía de cada local: eso
    -- no volverá a salir de caja. Local a local, porque la garantía de uno no
    -- paga lo de otro.
    select coalesce(sum(least(g.prepaid, g.payable)), 0) into v_covered
    from (
      select
        a.owner_id,
        coalesce(sum(e.debit - e.credit) filter (where a.account_type = 'merchant_prepaid'), 0) as prepaid,
        coalesce(sum(e.credit - e.debit) filter (where a.account_type = 'merchant_payable'), 0) as payable
      from ledger.entries e
      join ledger.accounts a on a.id = e.account_id
      where a.account_type in ('merchant_prepaid', 'merchant_payable')
        and a.owner_id is not null
        and not public.helios_is_test_merchant(a.owner_id)
      group by a.owner_id
    ) g
    where g.prepaid > 0 and g.payable > 0;
    v_revenue     := -ledger.balance_by_type('platform_revenue');
    -- La provisión es una cuenta de saldo DEUDOR: `charge_off_user_debt`
    -- la carga al debe. Su saldo, tal cual, es lo dado por perdido (con
    -- el signo cambiado salía negativo en cuanto había un castigo).
    v_written_off :=  ledger.balance_by_type('bad_debt_provision');
    v_fx          :=  ledger.balance_by_type('fx_difference');
  else
    -- Lo que se le debe a ESE local: lo devengado sin transferir más lo que
    -- el cierre encolará (la «Por pagar» de Pagos a locales).
    select o.total_pending_usd into v_payable
    from public.helios_settlement_outlook(p_merchant_id) o;
  end if;

  -- Cuánto de lo que se debe ya está vencido: sin lo perdido ni lo de prueba.
  select coalesce(sum(i.amount_usd), 0) into v_overdue
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where i.status = 'pending'
    and i.written_off_at is null
    and not i.is_test
    and i.due_date < v_today
    and (p_merchant_id is null or c.merchant_id = p_merchant_id);

  -- El consumo que sigue fuera. Lo que se pierde entero si no vuelve.
  select coalesce(sum(i.financed_usd), 0) into v_principal
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where i.status = 'pending'
    and i.written_off_at is null
    and not i.is_test
    and (p_merchant_id is null or c.merchant_id = p_merchant_id);

  -- El servicio con su IVA que ya se cobró: una cuota pagada trae su fee entero.
  select coalesce(sum(i.amount_usd - i.financed_usd), 0) into v_fee_paid
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where i.status = 'paid'
    and not i.is_test
    and (p_merchant_id is null or c.merchant_id = p_merchant_id);

  -- La cartera de hoy, la canónica (la misma de General y de Cobranza): lo
  -- vivo (vencido + por vencer) y lo dado por perdido, con su desglose. Lo
  -- vivo más los cargos pendientes suma lo que el libro llama `user_receivable`,
  -- y lo perdido más los cargos castigados, su provisión: la batería de
  -- coherencia lo comprueba.
  select * into v_cartera
  from metricas.cartera_al(v_today, p_merchant_id);

  -- El servicio de Ronda sin IVA, ganado y cobrado, desde el primer día; y los
  -- cargos por atraso, aparte.
  select m.servicio_ganado_usd, m.cobrado_servicio_usd,
         m.cargos_devengados_usd, m.cargos_cobrados_usd
    into v_serv
  from metricas.caja_movimientos('2000-01-01'::date, v_today, p_merchant_id) m;

  return jsonb_build_object(
    'business_date', v_today,
    'merchant_id', p_merchant_id,
    'cash', v_cash,
    'user_receivable', v_receivable,
    'overdue_receivable', v_overdue,
    'principal_outstanding', v_principal,
    'merchant_payable', v_payable,
    'merchant_prepaid', v_prepaid,
    'merchant_payable_covered', case when v_local then null else v_covered end,
    'platform_revenue', v_revenue,
    'commission_collected', v_fee_paid,
    'written_off', v_written_off,
    'fx_difference', v_fx,
    -- Todo lo que está comprometido y todavía no ha vuelto a caja.
    'committed', case when v_local then null else v_receivable + v_payable end,
    -- Lo que queda libre para seguir financiando. Puede salir negativo, y con
    -- liquidación por fecha eso es lo normal.
    -- Lo que cubre la garantía de un local no sale de caja.
    'free_capital', case when v_local then null else v_cash - (v_payable - v_covered) end,
    -- El desglose de lo que se debe (regla del fee): nunca el total solo.
    'receivable', jsonb_build_object(
      'payable_usd',   v_cartera.vencido_payable_usd + v_cartera.por_vencer_payable_usd,
      'financed_usd',  v_cartera.vencido_financed_usd + v_cartera.por_vencer_financed_usd,
      'fee_usd',       v_cartera.vencido_fee_usd + v_cartera.por_vencer_fee_usd,
      'late_fees_usd', (
        select coalesce(sum(c.amount_usd), 0) from metricas.cargos_por_atraso c
        where c.status = 'pending'
          and (p_merchant_id is null or c.merchant_id = p_merchant_id)
      )
    ),
    'overdue', jsonb_build_object(
      'payable_usd',  v_cartera.vencido_payable_usd,
      'financed_usd', v_cartera.vencido_financed_usd,
      'fee_usd',      v_cartera.vencido_fee_usd
    ),
    'lost', jsonb_build_object(
      'payable_usd',   v_cartera.perdido_payable_usd,
      'financed_usd',  v_cartera.perdido_financed_usd,
      'fee_usd',       v_cartera.perdido_fee_usd,
      'late_fees_usd', (
        select coalesce(sum(c.amount_usd), 0) from metricas.cargos_por_atraso c
        where c.status = 'written_off'
          and (p_merchant_id is null or c.merchant_id = p_merchant_id)
      )
    ),
    -- El ingreso de Ronda: servicio sin IVA ganado (al confirmar el consumo) y
    -- cobrado (dentro de las cuotas pagadas); los cargos por atraso aparte.
    'service', jsonb_build_object(
      'earned_usd',              round(v_serv.servicio_ganado_usd, 2),
      'collected_usd',           round(v_serv.cobrado_servicio_usd, 2),
      'late_fees_earned_usd',    v_serv.cargos_devengados_usd,
      'late_fees_collected_usd', v_serv.cargos_cobrados_usd
    )
  );
end;
$function$;
