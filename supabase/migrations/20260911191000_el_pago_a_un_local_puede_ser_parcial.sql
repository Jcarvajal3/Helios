-- ============================================================================
-- Ronda — Un pago a un local puede ser parcial, tener fecha y tener recibo
--
-- Registrar un pago a un comercio era todo o nada: se marcaban liquidaciones y
-- se daban por pagadas enteras, con la fecha de hoy y sin comprobante. Eso
-- obliga a mentir en los tres sitios:
--
--   * Se transfirió €40 de los €52,50 que tocaban porque el banco cortó.
--     Hoy o se marca todo como pagado —y el local aparece al día debiéndole
--     €12,50— o no se registra nada y la caja del libro miente.
--   * Se transfirió el viernes y se registró el lunes. El libro dice lunes.
--   * El comprobante vive en el WhatsApp de alguien.
--
-- ---------------------------------------------------------------------------
-- Cómo se reparte un pago parcial
-- ---------------------------------------------------------------------------
-- **De la liquidación más antigua a la más nueva.** Es la regla que ya usa el
-- pago del usuario y la única que no necesita que nadie decida nada: lo que
-- lleva más tiempo esperando se cobra primero. La última que alcanza queda en
-- `partial` con su resto, y sigue apareciendo en el cierre hasta que se cubra.
--
-- `paid_usd` es lo que lleva cobrado cada liquidación. El pendiente de verdad
-- es `amount_usd - paid_usd`, y eso es lo que ahora suma el cierre: antes
-- sumaba el importe entero de todo lo que no estuviera en `paid`, que con
-- parciales habría enseñado de más.
--
-- ---------------------------------------------------------------------------
-- Y la fecha del pago no es la fecha del registro
-- ---------------------------------------------------------------------------
-- `business_date` se queda siendo cuándo se registró —es lo que ordena el
-- libro— y `paid_on` es cuándo salió del banco. Son distintas cada vez que
-- alguien registra el lunes lo del viernes, y la que se coteja contra el
-- extracto es la segunda.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Lo que lleva cobrado cada liquidación
-- ---------------------------------------------------------------------------

alter table public.settlements
  add column if not exists paid_usd numeric(18,4) not null default 0;

comment on column public.settlements.paid_usd is
  'Lo que lleva cobrado de esta liquidacion. El pendiente es amount_usd - paid_usd. Con status paid son iguales; con partial, paid_usd es menor.';

-- Lo que ya estaba pagado, lo estaba entero.
update public.settlements
set paid_usd = amount_usd
where status = 'paid' and paid_usd = 0;

alter table public.merchant_payouts
  add column if not exists paid_on date;

alter table public.merchant_payouts
  add column if not exists receipt_path text;

comment on column public.merchant_payouts.paid_on is
  'Cuando salio del banco. business_date es cuando se registro en el panel: son distintas cada vez que alguien registra el lunes lo del viernes.';

-- La fecha del pago de lo ya registrado es la del registro, que es lo único
-- que se sabe de ellos.
update public.merchant_payouts
set paid_on = business_date
where paid_on is null;

-- El comprobante vive en un bucket privado: es un documento con datos
-- bancarios de un tercero.
insert into storage.buckets (id, name, public)
values ('merchant-receipts', 'merchant-receipts', false)
on conflict (id) do nothing;

drop policy if exists "merchant_receipts_admin" on storage.objects;
create policy "merchant_receipts_admin"
  on storage.objects for all
  to authenticated
  using (bucket_id = 'merchant-receipts' and public.is_platform_admin())
  with check (bucket_id = 'merchant-receipts' and public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- 2. Registrar el pago
-- ---------------------------------------------------------------------------
-- Cuerpo del de 20260824101000 con tres cosas nuevas: el importe, que puede
-- ser menor que lo marcado; la fecha real; y el comprobante. Lo demás —la
-- tasa por defecto cuando el medio es en bolívares, el asiento, la bitácora—
-- es idéntico.

drop function if exists public.admin_report_merchant_payout(uuid, uuid[], text, text, numeric, numeric, text);

create or replace function public.admin_report_merchant_payout(
  p_merchant_id    uuid,
  p_settlement_ids uuid[],
  p_method         text,
  p_reference      text default null,
  p_amount_ves     numeric default null,
  p_fx_rate        numeric default null,
  p_note           text default null,
  p_amount_usd     numeric default null,
  p_paid_on        date default null,
  p_receipt_path   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $fn$
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
begin
  -- Registrar un pago mueve la caja del libro: es del super admin.
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede registrar pagos a comercios'
      using errcode = '42501';
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
    (p_merchant_id, v_total, v_ves, v_fx, p_method, p_reference, p_note,
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
      'has_receipt', p_receipt_path is not null
    ));

  return jsonb_build_object(
    'ok', true, 'payout_id', v_payout.id,
    'amount_usd', v_total, 'pending_usd', v_pendiente, 'settlements', v_count,
    'amount_ves', v_ves, 'fx_rate', v_fx, 'paid_on', v_paid_on
  );
end;
$fn$;

comment on function public.admin_report_merchant_payout(uuid, uuid[], text, text, numeric, numeric, text, numeric, date, text) is
  'Registra una transferencia ya hecha a un comercio. Puede ser parcial: se reparte de la liquidacion mas antigua a la mas nueva y la ultima que alcanza queda en partial. Solo super admin.';

revoke all on function public.admin_report_merchant_payout(uuid, uuid[], text, text, numeric, numeric, text, numeric, date, text)
  from public, anon;
grant execute on function public.admin_report_merchant_payout(uuid, uuid[], text, text, numeric, numeric, text, numeric, date, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El cierre cuenta lo que falta, no el importe entero
-- ---------------------------------------------------------------------------
-- Cuerpo del de 20260902120000 con dos cambios: `amount_usd - paid_usd` en vez
-- de `amount_usd`, y `status in ('pending','partial')` en vez de solo pending.
-- Sin el primero, una liquidación pagada a medias aparecería entera en el
-- cierre siguiente y se le pagaría dos veces.
--
-- `drop` antes del `create or replace`: se suman dos columnas nuevas
-- (`last_payout_on`, `last_payout_usd`) y Postgres no deja cambiar la fila
-- de retorno de una función existente sin borrarla primero.
drop function if exists public.helios_settlement_outlook(uuid);

create or replace function public.helios_settlement_outlook(p_merchant_id uuid)
returns table (
  today_date        date,
  next_run_date     date,
  next_run_usd      numeric,
  accrued_usd       numeric,
  accrued_count     integer,
  overdue_usd       numeric,
  oldest_due_date   date,
  upcoming_usd      numeric,
  total_pending_usd numeric,
  last_payout_on    date,
  last_payout_usd   numeric
)
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select
    cal.today,
    cal.next_run,
    a.in_next_run + u.in_next_run,
    a.usd,
    a.n,
    a.overdue,
    a.oldest,
    u.usd,
    a.usd + u.usd,
    p.last_on,
    p.last_usd
  from (
    select public.helios_business_date(now())      as today,
           public.helios_next_settlement_run(now()) as next_run
  ) cal
  -- 1. Devengado y sin transferir. Lo que falta, no el importe original.
  cross join lateral (
    select
      coalesce(sum(s.amount_usd - s.paid_usd), 0)                              as usd,
      count(s.id)::int                                                         as n,
      min(s.due_date)                                                          as oldest,
      -- Atrasado = su cierre ya pasó y sigue sin transferirse. Con cierre
      -- semanal, "vencido ayer" NO es un atraso: es dinero esperando al lunes.
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where public.helios_settlement_run_for(s.due_date) < cal.next_run
      ), 0)                                                                    as overdue,
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where s.due_date < cal.next_run), 0)                                   as in_next_run
    from public.settlements s
    where s.merchant_id = p_merchant_id
      and s.status in ('pending', 'partial')
  ) a
  -- 2. Lo que el cron encolará y todavía no existe.
  cross join lateral (
    select
      coalesce(sum(f.amount_usd), 0)                                           as usd,
      coalesce(sum(f.amount_usd) filter (where f.due_date < cal.next_run), 0)  as in_next_run
    from (
      select
        d.due_date,
        greatest(0, least(
          d.tranche,
          d.room - coalesce(sum(d.tranche) over (
            partition by d.charge_id order by d.due_date
            rows between unbounded preceding and 1 preceding
          ), 0)
        )) as amount_usd
      from (
        select distinct
          c.id                                                   as charge_id,
          i.due_date,
          round(coalesce(c.merchant_net_usd, c.amount_usd) * t.per_installment_pct / 100, 4) as tranche,
          coalesce(c.merchant_net_usd, c.amount_usd) - coalesce((
            select sum(s2.amount_usd)
            from public.settlements s2
            where s2.charge_id = c.id
          ), 0)                                                  as room
        from public.installments i
        join public.charges c on c.id = i.charge_id
        join public.merchant_settlement_terms t on t.merchant_id = c.merchant_id
        where c.merchant_id = p_merchant_id
          and t.policy = 'scheduled'
          -- Vencimientos pasados que el cron no encoló ya no los encolará
          -- nunca: solo mira el día operativo de hoy. Prometerlos sería
          -- enseñar dinero que no va a llegar.
          and i.due_date >= cal.today
          and not exists (
            select 1 from public.settlements s3
            where s3.charge_id = c.id
              and s3.reason = 'scheduled_installment'
              and s3.business_date = i.due_date
          )
      ) d
    ) f
    where f.amount_usd > 0
  ) u
  -- 3. La última vez que se le pagó. Es la primera pregunta del gerente que
  --    llama, y hasta ahora había que buscarla en el libro.
  -- `left` y no `cross`: un comercio al que nunca se le ha pagado tiene que
  -- seguir apareciendo en el cierre, que es justo cuando más falta hace.
  left join lateral (
    select mp.paid_on as last_on, mp.amount_usd as last_usd
    from public.merchant_payouts mp
    where mp.merchant_id = p_merchant_id
    order by mp.paid_on desc nulls last, mp.created_at desc
    limit 1
  ) p on true;
$$;

revoke all on function public.helios_settlement_outlook(uuid) from public, anon;
grant execute on function public.helios_settlement_outlook(uuid) to authenticated;
