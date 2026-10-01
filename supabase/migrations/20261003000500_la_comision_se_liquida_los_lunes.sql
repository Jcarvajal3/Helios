-- ============================================================================
-- Helios — La comisión se liquida los lunes (H5, docs/00 §6 y docs/01 §1.5-1.6, §2.5)
--
-- La comisión se devenga al registrar el financiamiento
-- (`helios_accrue_staff_commission`, 20261003000400) como una liquidación
-- `staff_commission` que vence ese mismo día. Desde ahí sigue el camino de
-- cualquier liquidación: aparece en el cierre del lunes siguiente, el equipo
-- la paga con `admin_report_merchant_payout` y, cuando su liquidación queda
-- pagada entera, la comisión pasa a `pagada` (trigger de 20261003000300).
--
-- Lo que hay que enseñarle a lo que ya existía:
--
-- 1. El «techo» de cada consumo. El cron de las 10:10, la previsión del
--    cierre (`helios_settlement_outlook`) y `metricas.locales_cierre`
--    calculaban lo que le queda por devengar a un consumo como «neto menos
--    TODAS sus liquidaciones». La comisión también lleva el `charge_id`, así
--    que la segunda mitad saldría con 0,50 de menos. Ahora la comisión no
--    cuenta para ese techo.
-- 2. La previsión y la cola de pagos separan consultas y comisiones
--    (`*_consultas_usd`, `*_comisiones_usd`).
-- 3. Cada transferencia guarda su reparto (`merchant_payouts.consultas_usd` y
--    `comisiones_usd`) y el detalle lo enseña por línea.
-- 4. La reversa (`admin_reverse_charge`): el asiento espejo ya refleja la
--    comisión (refleja todo lo que lleva la referencia del financiamiento);
--    además la comisión queda `revertida` y su liquidación pendiente se borra
--    con las demás. Si ya se le pagó algo a la clínica —consultas o
--    comisión— la reversa sigue bloqueada, como en Ronda.
-- 5. `admin_set_settlement_terms` acepta `p_staff_commission_usd` (null = el
--    parámetro global).
-- 6. Las comisiones para la clínica: `merchant_commissions` y
--    `merchant_commission_items` (el gerente ve todas; la secretaria, las
--    suyas).
-- 7. El teléfono de referencia no puede ser el del propio paciente
--    (`helios_patient_input`).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El cron no cuenta la comisión en el techo del consumo
-- ---------------------------------------------------------------------------

create or replace function public.run_scheduled_settlements_batch(p_business_date date, p_after uuid, p_limit integer)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_charge  record;
  v_terms   public.merchant_terms;
  v_amount  numeric(18,4);
  v_room    numeric(18,4);
  v_last    uuid := p_after;
  v_seen    integer := 0;
  v_created integer := 0;
begin
  for v_charge in
    select distinct c.id as charge_id, c.merchant_id, c.business_date,
           coalesce(c.merchant_net_usd, c.amount_usd) as net_usd
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.due_date = p_business_date
      and c.id > p_after
    order by c.id
    limit p_limit
  loop
    v_last := v_charge.charge_id;
    v_seen := v_seen + 1;

    begin
      select * into v_terms
      from public.helios_terms_at(
        v_charge.merchant_id,
        coalesce(v_charge.business_date, p_business_date)
      );

      if coalesce(v_terms.policy::text, '') <> 'scheduled' then
        continue;
      end if;

      if exists (
        select 1 from public.settlements
        where charge_id = v_charge.charge_id
          and reason = 'scheduled_installment'
          and business_date = p_business_date
      ) then
        continue;
      end if;

      v_amount := round(v_charge.net_usd * v_terms.per_installment_pct / 100, 4);

      -- Por un consumo nunca se devenga más que su neto. Helios: la comisión
      -- del personal no es parte del neto de la consulta y no cuenta.
      select v_charge.net_usd - coalesce(sum(s.amount_usd), 0)
        into v_room
      from public.settlements s
      where s.charge_id = v_charge.charge_id
        and s.reason <> 'staff_commission';

      v_amount := least(v_amount, v_room);

      if v_amount <= 0 then
        continue;
      end if;

      insert into public.settlements
        (merchant_id, charge_id, installment_id, reason, amount_usd, business_date, due_date, status)
      values
        (v_charge.merchant_id, v_charge.charge_id, null, 'scheduled_installment',
         v_amount, p_business_date, p_business_date, 'pending');

      v_created := v_created + 1;
    exception when others then
      raise warning 'Liquidación programada fallida para el consumo % (comercio %): %',
        v_charge.charge_id, v_charge.merchant_id, sqlerrm;
    end;
  end loop;

  return jsonb_build_object('last', v_last, 'seen', v_seen, 'created', v_created);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. La previsión del cierre, partida
-- ---------------------------------------------------------------------------
-- Cambian las columnas que devuelve: se borra y se crea. La usan
-- `merchant_settlement_outlook` y `admin_merchant_payables` (abajo).

drop function public.helios_settlement_outlook(uuid);

create function public.helios_settlement_outlook(p_merchant_id uuid)
returns table(
  today_date date, next_run_date date, next_run_usd numeric, accrued_usd numeric,
  accrued_count integer, overdue_usd numeric, oldest_due_date date, upcoming_usd numeric,
  total_pending_usd numeric, last_payout_on date, last_payout_usd numeric,
  accrued_consultas_usd numeric, accrued_comisiones_usd numeric,
  next_run_consultas_usd numeric, next_run_comisiones_usd numeric
)
language sql
stable
security definer
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
    p.last_usd,
    a.usd - a.com,
    a.com,
    a.in_next_run - a.com_next + u.in_next_run,
    a.com_next
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
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where public.helios_settlement_run_for(s.due_date) < cal.next_run
      ), 0)                                                                    as overdue,
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where s.due_date < cal.next_run), 0)                                   as in_next_run,
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where s.reason = 'staff_commission'), 0)                               as com,
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where s.reason = 'staff_commission' and s.due_date < cal.next_run), 0) as com_next
    from public.settlements s
    where s.merchant_id = p_merchant_id
      and s.status in ('pending', 'partial')
  ) a
  -- 2. Lo que el cron encolará y todavía no existe, con las condiciones
  --    vigentes el día de CADA venta. Siempre consultas: la comisión nace
  --    devengada.
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
              and s2.reason <> 'staff_commission'
          ), 0)                                                  as room
        from public.installments i
        join public.charges c on c.id = i.charge_id
        cross join lateral public.helios_terms_at(
          c.merchant_id, coalesce(c.business_date, cal.today)
        ) t
        where c.merchant_id = p_merchant_id
          and t.policy = 'scheduled'
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
  left join lateral (
    select mp.paid_on as last_on, mp.amount_usd as last_usd
    from public.merchant_payouts mp
    where mp.merchant_id = p_merchant_id
    order by mp.paid_on desc nulls last, mp.created_at desc
    limit 1
  ) p on true;
$$;

revoke all on function public.helios_settlement_outlook(uuid) from public, anon, authenticated;

create or replace function public.merchant_settlement_outlook()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_out      record;
begin
  if v_merchant is null then
    raise exception 'Solo el administrador de la clínica' using errcode = '42501';
  end if;

  select * into v_out from public.helios_settlement_outlook(v_merchant);

  return jsonb_build_object(
    'today_date',              v_out.today_date,
    'next_run_date',           v_out.next_run_date,
    'next_run_usd',            v_out.next_run_usd,
    'next_run_consultas_usd',  v_out.next_run_consultas_usd,
    'next_run_comisiones_usd', v_out.next_run_comisiones_usd,
    'accrued_usd',             v_out.accrued_usd,
    'accrued_count',           v_out.accrued_count,
    'consultas_usd',           v_out.accrued_consultas_usd,
    'comisiones_usd',          v_out.accrued_comisiones_usd,
    'overdue_usd',             v_out.overdue_usd,
    'oldest_due_date',         v_out.oldest_due_date,
    'upcoming_usd',            v_out.upcoming_usd,
    'total_pending_usd',       v_out.total_pending_usd,
    'last_payout_on',          v_out.last_payout_on,
    'last_payout_usd',         v_out.last_payout_usd
  );
end;
$$;

create or replace function public.admin_merchant_payables(p_merchant_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.total_pending_usd desc), '[]'::jsonb)
  into v_rows
  from (
    select
      m.id     as merchant_id,
      m.name   as merchant_name,
      m.tax_id,
      m.is_test,
      o.*,
      -- Helios: lo devengado y sin transferir, partido (docs/01 §2.5).
      o.accrued_consultas_usd  as consultas_usd,
      o.accrued_comisiones_usd as comisiones_usd
    from public.merchants m
    cross join lateral public.helios_settlement_outlook(m.id) o
    where (o.accrued_usd > 0 or o.upcoming_usd > 0)
      and (p_merchant_id is null or m.id = p_merchant_id)
  ) q;

  return v_rows;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Las transferencias, partidas
-- ---------------------------------------------------------------------------

create or replace function public.admin_report_merchant_payout(
  p_merchant_id    uuid,
  p_settlement_ids uuid[],
  p_method         text,
  p_reference      text    default null,
  p_amount_ves     numeric default null,
  p_fx_rate        numeric default null,
  p_note           text    default null,
  p_amount_usd     numeric default null,
  p_paid_on        date    default null,
  p_receipt_path   text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $$
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
  v_consultas   numeric(18,4);
  v_comisiones  numeric(18,4);
  v_note        text := nullif(trim(coalesce(p_note, '')), '');
begin
  perform public.helios_assert_super_admin('registrar pagos a comercios');

  -- PODA (Helios): el método 'boveda' (saldar contra la garantía del piloto)
  -- y el freno de «garantía sin gastar» se fueron con la bóveda.
  if p_method = 'boveda' then
    raise exception 'Helios no tiene bóveda: registra la transferencia' using errcode = '22023';
  end if;

  if p_settlement_ids is null or array_length(p_settlement_ids, 1) is null then
    raise exception 'Selecciona al menos una liquidación' using errcode = '22023';
  end if;

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

  v_total := coalesce(p_amount_usd, v_pendiente);

  if v_total <= 0 then
    raise exception 'El importe tiene que ser mayor que cero' using errcode = '22023';
  end if;

  if v_total > v_pendiente + 0.005 then
    raise exception 'No puedes registrar % cuando lo marcado suma %',
      v_total, v_pendiente using errcode = '22023';
  end if;

  v_bdate   := public.helios_business_date(now());
  v_paid_on := coalesce(p_paid_on, v_bdate);

  if v_paid_on > v_bdate then
    raise exception 'La fecha del pago no puede ser posterior a hoy' using errcode = '22023';
  end if;

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

    -- Al quedar 'paid', el trigger `settlements_sync_staff_commission` marca
    -- la comisión como pagada.
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

  -- Helios: la transferencia partida en consultas y comisiones del personal.
  select coalesce(sum(it.amount_usd) filter (where s.reason <> 'staff_commission'), 0),
         coalesce(sum(it.amount_usd) filter (where s.reason = 'staff_commission'), 0)
    into v_consultas, v_comisiones
  from public.merchant_payout_items it
  join public.settlements s on s.id = it.settlement_id
  where it.payout_id = v_payout.id;

  update public.merchant_payouts
     set consultas_usd = v_consultas, comisiones_usd = v_comisiones
   where id = v_payout.id;

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
      'consultas_usd', v_consultas, 'comisiones_usd', v_comisiones,
      'pending_usd', v_pendiente,
      'partial', v_total < v_pendiente - 0.005,
      'settlements', v_count, 'method', p_method, 'reference', p_reference,
      'paid_on', v_paid_on, 'amount_ves', v_ves, 'fx_rate', v_fx,
      'has_receipt', p_receipt_path is not null,
      'note', v_note
    ));

  return jsonb_build_object(
    'ok', true, 'payout_id', v_payout.id,
    'amount_usd', v_total, 'pending_usd', v_pendiente, 'settlements', v_count,
    'consultas_usd', v_consultas, 'comisiones_usd', v_comisiones,
    'amount_ves', v_ves, 'fx_rate', v_fx, 'paid_on', v_paid_on
  );
end;
$$;

create or replace function public.admin_payout_detail(p_payout_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_payout public.merchant_payouts%rowtype;
  v_out    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_payout from public.merchant_payouts where id = p_payout_id;

  if not found then
    raise exception 'No existe esa transferencia' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'id',             v_payout.id,
    'paid_on',        coalesce(v_payout.paid_on, v_payout.business_date),
    'business_date',  v_payout.business_date,
    'created_at',     v_payout.created_at,
    'amount_usd',     v_payout.amount_usd,
    'consultas_usd',  v_payout.consultas_usd,
    'comisiones_usd', v_payout.comisiones_usd,
    'amount_ves',     v_payout.amount_ves,
    'fx_rate',        v_payout.fx_rate,
    'method',         v_payout.method,
    'reference',      v_payout.reference,
    'note',           v_payout.note,
    'receipt_path',   v_payout.receipt_path,
    'actor_name',     (
      select pa.full_name from public.platform_admins pa
      where pa.user_id = v_payout.paid_by
    ),
    'merchant', (
      select jsonb_build_object(
        'id', m.id, 'name', m.name, 'tax_id', m.tax_id, 'is_test', m.is_test,
        'status', m.status::text
      )
      from public.merchants m where m.id = v_payout.merchant_id
    ),
    'items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'settlement_id',   s.id,
          'reason',          s.reason,
          'status',          s.status,
          'applied_usd',     it.amount_usd,
          'settlement_usd',  s.amount_usd,
          'paid_usd',        s.paid_usd,
          'pending_usd',     s.amount_usd - s.paid_usd,
          'due_date',        coalesce(s.due_date, s.business_date),
          'run_date',        public.helios_settlement_run_for(
                               coalesce(s.due_date, s.business_date)),
          'charge_id',       c.id,
          'order_number',    c.order_number,
          'charge_date',     c.business_date,
          -- Helios: de quién es la comisión.
          'staff_user_id',   sc.staff_user_id,
          'staff_name',      case when sc.staff_user_id is not null
                                  then public.helios_staff_name(sc.staff_user_id) end
        )
        order by coalesce(s.due_date, s.business_date), s.id
      )
      from public.merchant_payout_items it
      join public.settlements s on s.id = it.settlement_id
      left join public.charges c on c.id = s.charge_id
      left join public.staff_commissions sc on sc.settlement_id = s.id
      where it.payout_id = v_payout.id
    ), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;

create or replace function public.admin_merchant_payouts(
  p_merchant_id uuid default null,
  p_from        date default null,
  p_to          date default null,
  p_method      text default null,
  p_limit       integer default 200
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(
           jsonb_agg(to_jsonb(q) order by q.paid_on desc, q.created_at desc),
           '[]'::jsonb
         )
  into v_rows
  from (
    select
      p.id,
      p.merchant_id,
      m.name                             as merchant_name,
      m.is_test,
      coalesce(p.paid_on, p.business_date) as paid_on,
      p.business_date,
      p.created_at,
      p.amount_usd,
      p.consultas_usd,
      p.comisiones_usd,
      p.amount_ves,
      p.fx_rate,
      p.method,
      p.reference,
      p.note,
      p.receipt_path is not null         as tiene_comprobante,
      pa.full_name                       as actor_name,
      coalesce(i.lineas, 0)::int         as lineas,
      i.primer_vencimiento,
      i.ultimo_vencimiento
    from public.merchant_payouts p
    join public.merchants m on m.id = p.merchant_id
    left join public.platform_admins pa on pa.user_id = p.paid_by
    left join lateral (
      select
        count(*)                                            as lineas,
        min(coalesce(s.due_date, s.business_date))          as primer_vencimiento,
        max(coalesce(s.due_date, s.business_date))          as ultimo_vencimiento
      from public.merchant_payout_items it
      join public.settlements s on s.id = it.settlement_id
      where it.payout_id = p.id
    ) i on true
    where (p_merchant_id is null or p.merchant_id = p_merchant_id)
      and (p_from is null or coalesce(p.paid_on, p.business_date) >= p_from)
      and (p_to   is null or coalesce(p.paid_on, p.business_date) <= p_to)
      and (p_method is null or p.method = p_method)
    order by coalesce(p.paid_on, p.business_date) desc, p.created_at desc
    limit least(coalesce(p_limit, 200), 500)
  ) q;

  return v_rows;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. La reversa revierte la comisión
-- ---------------------------------------------------------------------------

create or replace function public.admin_reverse_charge(p_charge_id uuid, p_reason text)
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
  v_bloqueo  text;
  v_tx       uuid;
  v_origen   record;
  v_name     text;
  v_partes   jsonb;
  v_parte    record;
  v_n        integer;
  v_comision numeric(18,4);
begin
  perform public.helios_assert_super_admin('revertir un consumo');

  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'Revertir un consumo requiere motivo' using errcode = '22023';
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;

  if not found then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  -- Las redes: cuotas pagadas, pagos reportados, liquidaciones ya pagadas
  -- (también la de la comisión) y cotizaciones vivas.
  v_bloqueo := public.helios_charge_reverse_blocker(p_charge_id);
  if v_bloqueo is not null then
    raise exception '%', v_bloqueo using errcode = '22023';
  end if;

  select full_name into v_name from public.profiles where id = v_charge.user_id;

  select
    coalesce(sum(financed_usd), 0),
    coalesce(sum(amount_usd), 0)
  into v_financed, v_payable
  from public.installments where charge_id = p_charge_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id',  s.user_id,
           'financed', s.financed,
           'payable',  s.payable
         ) order by s.user_id), '[]'::jsonb)
  into v_partes
  from (
    select i.user_id,
           sum(i.financed_usd) as financed,
           sum(i.amount_usd)   as payable
    from public.installments i
    where i.charge_id = p_charge_id
    group by i.user_id
  ) s;

  v_n := jsonb_array_length(v_partes);

  -- ── 1. El asiento contrario ──────────────────────────────────────────────
  -- Refleja pata por pata todo lo asentado con la referencia del
  -- financiamiento: la venta y, en Helios, la comisión del personal
  -- (Dr merchant_payable / Cr commission_expense).
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
  delete from public.payment_quotes q
  where q.valid_until <= now()
    and not exists (select 1 from public.payment_reports r where r.quote_id = q.id)
    and exists (
      select 1
      from public.payment_quote_items qi
      join public.installments i on i.id = qi.installment_id
      where qi.quote_id = q.id and i.charge_id = p_charge_id
    );

  delete from public.installments where charge_id = p_charge_id;

  -- ── 3. La comisión y las liquidaciones que no se han pagado ──────────────
  update public.staff_commissions
     set status = 'revertida', settlement_id = null
   where charge_id = p_charge_id
  returning amount_usd into v_comision;

  delete from public.settlements
  where charge_id = p_charge_id and status = 'pending';

  -- ── 4. El cupo vuelve, a cada quien lo suyo ──────────────────────────────
  for v_parte in
    select (e->>'user_id')::uuid     as user_id,
           (e->>'financed')::numeric as financed,
           (e->>'payable')::numeric  as payable
    from jsonb_array_elements(v_partes) e
  loop
    update public.user_credit_blocks
    set charged_usd = greatest(charged_usd - v_parte.financed, 0),
        fee_usd     = greatest(fee_usd - (v_parte.payable - v_parte.financed), 0)
    where user_id = v_parte.user_id and closed_at is null;

    -- PODA (Helios): aquí se devolvía el techo de la mesa (`group_members`).
  end loop;

  -- ── 5. El consumo queda marcado ──────────────────────────────────────────
  update public.charges
  set status      = 'reverted',
      void_reason = trim(p_reason),
      voided_by   = v_actor,
      voided_at   = now()
  where id = p_charge_id;

  for v_parte in
    select (e->>'user_id')::uuid    as user_id,
           (e->>'payable')::numeric as payable
    from jsonb_array_elements(v_partes) e
  loop
    perform public.notify(
      v_parte.user_id,
      'payment_reconciled',
      'Anulamos un consumo',
      case when v_n > 1 then
        format('Anulamos la cuenta del grupo. Tu parte de $%s ya no la debes y tu cupo vuelve a estar disponible.',
               to_char(v_parte.payable, 'FM999999990.00'))
      else
        format('Anulamos el consumo de $%s. Ya no lo debes y tu cupo vuelve a estar disponible.',
               to_char(v_parte.payable, 'FM999999990.00'))
      end
    );
  end loop;

  perform audit.log(v_actor, 'charge.reverted', p_charge_id, jsonb_build_object(
    'user_id', v_charge.user_id,
    'full_name', v_name,
    'merchant_id', v_charge.merchant_id,
    'amount_usd', v_charge.amount_usd,
    'financed_usd', v_financed,
    'payable_usd', v_payable,
    'staff_commission_usd', v_comision,
    'debtors', v_n,
    'split', v_partes,
    'business_date', v_charge.business_date,
    'reason', trim(p_reason)
  ));

  return jsonb_build_object(
    'ok', true,
    'charge_id', p_charge_id,
    'amount_usd', v_charge.amount_usd,
    'credit_returned_usd', v_financed,
    'staff_commission_reverted_usd', v_comision,
    'debtors', v_n,
    'split', v_partes
  );
end;
$$;

/**
 * Anula un cobro PENDIENTE (el QR de Ronda que nadie escaneó). En Helios los
 * financiamientos nacen confirmados, así que en la práctica siempre rechaza:
 * un financiamiento confirmado se deshace con `admin_reverse_charge`.
 */
create or replace function public.admin_void_charge(p_charge_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_status public.charge_status;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select status into v_status from public.charges where id = p_charge_id;
  if v_status is not null and v_status <> 'pending' then
    raise exception 'Solo se anula un cobro pendiente. Un financiamiento confirmado se revierte'
      using errcode = '22023';
  end if;

  perform public.void_charge(p_charge_id, v_actor, p_reason);

  perform audit.log(v_actor, 'charge.void', p_charge_id,
    jsonb_build_object('reason', p_reason));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Las condiciones de una clínica, con la comisión
-- ---------------------------------------------------------------------------
-- Se añade `p_staff_commission_usd` al final y con default. Como cambia la
-- lista de argumentos, se borra la firma vieja y se crea la nueva. La de
-- cinco argumentos (settlement_policy) sigue delegando aquí.

drop function public.admin_set_settlement_terms(uuid, numeric, numeric, numeric, text, date, text);

create function public.admin_set_settlement_terms(
  p_merchant_id          uuid,
  p_upfront_pct          numeric,
  p_per_installment_pct  numeric,
  p_commission_pct       numeric,
  p_policy               text,
  p_effective_from       date    default null,
  p_note                 text    default null,
  p_staff_commission_usd numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_today date := public.helios_business_date(now());
  v_desde date;
  v_antes public.merchant_terms;
  v_name  text;
begin
  perform public.helios_assert_super_admin('cambiar las condiciones de un comercio');

  select name into v_name from public.merchants where id = p_merchant_id;
  if not found then
    raise exception 'No existe ese comercio' using errcode = '22023';
  end if;

  v_desde := coalesce(p_effective_from, v_today);

  if v_desde < v_today then
    raise exception 'Las condiciones no pueden entrar en vigor en el pasado'
      using errcode = '22023';
  end if;

  if abs(p_upfront_pct + (p_per_installment_pct * 2) - 100.00) > 0.001 then
    raise exception 'El adelanto y las dos cuotas tienen que repartir el neto entero: % + (% × 2) da %, no 100',
      p_upfront_pct, p_per_installment_pct,
      p_upfront_pct + (p_per_installment_pct * 2)
      using errcode = '22023';
  end if;

  if p_upfront_pct < 0 or p_per_installment_pct < 0 or p_commission_pct < 0 then
    raise exception 'Ningún porcentaje puede ser negativo' using errcode = '22023';
  end if;

  -- Helios: la comisión del personal pactada con esta clínica. Null = la global.
  if p_staff_commission_usd is not null
     and (p_staff_commission_usd < 0 or p_staff_commission_usd <> round(p_staff_commission_usd, 2)
          or p_staff_commission_usd > 100) then
    raise exception 'La comisión del personal va entre $0 y $100, con 2 decimales como mucho'
      using errcode = '22023';
  end if;

  select * into v_antes from public.helios_terms_at(p_merchant_id, v_today);

  insert into public.merchant_terms
    (merchant_id, upfront_pct, per_installment_pct, commission_pct, policy,
     effective_from, note, created_by, staff_commission_usd)
  values (
    p_merchant_id, p_upfront_pct, p_per_installment_pct, p_commission_pct,
    p_policy::public.settlement_policy, v_desde,
    nullif(trim(coalesce(p_note, '')), ''), v_actor, p_staff_commission_usd
  )
  on conflict (merchant_id, effective_from) do update
    set upfront_pct = excluded.upfront_pct,
        per_installment_pct = excluded.per_installment_pct,
        commission_pct = excluded.commission_pct,
        policy = excluded.policy,
        note = excluded.note,
        created_by = excluded.created_by,
        staff_commission_usd = excluded.staff_commission_usd,
        created_at = now();

  perform audit.log(v_actor, 'merchant.set_terms', p_merchant_id, jsonb_build_object(
    'merchant_name', v_name,
    'effective_from', v_desde,
    'from_upfront_pct', v_antes.upfront_pct,
    'to_upfront_pct', p_upfront_pct,
    'from_per_installment_pct', v_antes.per_installment_pct,
    'to_per_installment_pct', p_per_installment_pct,
    'from_commission_pct', v_antes.commission_pct,
    'to_commission_pct', p_commission_pct,
    'from_policy', v_antes.policy,
    'to_policy', p_policy,
    'from_staff_commission_usd', v_antes.staff_commission_usd,
    'to_staff_commission_usd', p_staff_commission_usd,
    'note', p_note
  ));

  return jsonb_build_object('ok', true, 'effective_from', v_desde,
                            'staff_commission_usd', p_staff_commission_usd);
end;
$$;

revoke all on function public.admin_set_settlement_terms(uuid, numeric, numeric, numeric, text, date, text, numeric) from public, anon;
grant execute on function public.admin_set_settlement_terms(uuid, numeric, numeric, numeric, text, date, text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Las comisiones, para la clínica (docs/01 §1.6)
-- ---------------------------------------------------------------------------

/**
 * Comisiones por persona del personal, de los financiamientos registrados en
 * el rango (día operativo). El gerente ve las de toda su clínica; la
 * secretaria, solo su fila. Las revertidas no cuentan.
 */
create or replace function public.merchant_commissions(p_from date, p_to date)
returns table(
  staff_user_id uuid, staff_name text, charge_count integer,
  amount_usd numeric, paid_usd numeric, pending_usd numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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
  select sc.staff_user_id,
         public.helios_staff_name(sc.staff_user_id),
         count(*)::integer,
         sum(sc.amount_usd)::numeric,
         sum(x.paid)::numeric,
         sum(sc.amount_usd - x.paid)::numeric
  from public.staff_commissions sc
  join public.charges c on c.id = sc.charge_id
  left join public.settlements s on s.id = sc.settlement_id
  cross join lateral (
    select case when sc.status = 'pagada' then sc.amount_usd
                else least(coalesce(s.paid_usd, 0), sc.amount_usd) end as paid
  ) x
  where sc.merchant_id in (select public.my_merchant_ids())
    and (sc.merchant_id = v_gerente_de or sc.staff_user_id = v_me)
    and sc.status <> 'revertida'
    and c.business_date between p_from and p_to
  group by sc.staff_user_id
  order by sum(sc.amount_usd) desc, 2;
end;
$$;

/**
 * Una fila por comisión, con su transferencia si ya se pagó. Misma regla de
 * visibilidad que `merchant_commissions`; `p_staff_user_id` filtra (la
 * secretaria solo puede pedir las suyas).
 */
create or replace function public.merchant_commission_items(
  p_from          date,
  p_to            date,
  p_staff_user_id uuid default null
)
returns table(
  charge_id uuid, order_number bigint, created_at timestamptz, amount_usd numeric,
  status text, payout_id uuid, paid_on date, staff_user_id uuid, staff_name text,
  business_date date
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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
         c.business_date
  from public.staff_commissions sc
  join public.charges c on c.id = sc.charge_id
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
$$;

revoke all on function public.merchant_commissions(date, date) from public, anon;
revoke all on function public.merchant_commission_items(date, date, uuid) from public, anon;
grant execute on function public.merchant_commissions(date, date) to authenticated;
grant execute on function public.merchant_commission_items(date, date, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. El teléfono de referencia no es el del paciente
-- ---------------------------------------------------------------------------

create or replace function public.helios_patient_input(p_patient jsonb, p_strict boolean)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_out  jsonb := '{}'::jsonb;
  v_key  text;
  v_val  text;
  v_keys text[] := array['first_name', 'last_name', 'birth_date', 'sex', 'phone', 'email',
                         'state', 'city', 'address', 'occupation',
                         'reference_name', 'reference_phone', 'reference_relationship'];
begin
  foreach v_key in array v_keys loop
    if p_strict then
      v_val := public.helios_patient_field(v_key, p_patient->>v_key);
    else
      begin
        v_val := public.helios_patient_field(v_key, p_patient->>v_key);
      exception when others then
        v_val := null;
      end;
    end if;
    if v_val is not null then
      v_out := v_out || jsonb_build_object(v_key, v_val);
    end if;
  end loop;

  if p_strict then
    if v_out->>'first_name' is null or v_out->>'last_name' is null then
      raise exception 'Faltan los nombres y apellidos del paciente' using errcode = '22023';
    end if;
    if v_out->>'birth_date' is null then
      raise exception 'Falta la fecha de nacimiento del paciente' using errcode = '22023';
    end if;
    if v_out->>'sex' is null then
      raise exception 'El sexo debe ser F o M' using errcode = '22023';
    end if;
    if v_out->>'phone' is null then
      raise exception 'Teléfono móvil inválido' using errcode = '22023';
    end if;
    if v_out->>'email' is null then
      raise exception 'Correo inválido' using errcode = '22023';
    end if;
    if v_out->>'state' is null or v_out->>'city' is null or v_out->>'address' is null then
      raise exception 'Falta la dirección del paciente (estado, ciudad y dirección)' using errcode = '22023';
    end if;
    if v_out->>'reference_name' is null or v_out->>'reference_phone' is null
       or v_out->>'reference_relationship' is null then
      raise exception 'Falta el contacto de referencia' using errcode = '22023';
    end if;
    if v_out->>'reference_phone' = v_out->>'phone' then
      raise exception 'El teléfono del contacto de referencia tiene que ser distinto del del paciente'
        using errcode = '22023';
    end if;
  elsif v_out->>'reference_phone' = v_out->>'phone' then
    -- Para comparar con lo registrado: una referencia inválida no se propone.
    v_out := v_out - 'reference_phone';
  end if;

  return v_out;
end;
$$;

revoke all on function public.helios_patient_input(jsonb, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. metricas.locales_cierre: la comisión no cuenta en el techo del consumo
-- ---------------------------------------------------------------------------
-- Idéntica a la vigente (pg_get_functiondef, 2026-09-30) salvo la línea
-- `and s2.reason <> 'staff_commission'` del techo.

CREATE OR REPLACE FUNCTION metricas.locales_cierre(p_cierre date)
 RETURNS TABLE(merchant_id uuid, generado_usd numeric, transferido_usd numeric, pendiente_usd numeric, previsto_usd numeric, atrasado_usd numeric)
 LANGUAGE sql
 STABLE
AS $function$
  with
  cal as (
    select metricas.hoy() as hoy
  ),
  -- Lo que ya se generó para ese cierre.
  generado as (
    select s.merchant_id                                                         as mid,
           sum(s.amount_usd)                                                     as generado,
           sum(s.paid_usd)                                                       as transferido,
           coalesce(sum(s.amount_usd - s.paid_usd)
                    filter (where s.status in ('pending', 'partial')), 0)        as pendiente
    from public.settlements s
    where public.helios_settlement_run_for(coalesce(s.due_date, s.business_date)) = p_cierre
    group by s.merchant_id
  ),
  -- Lo que el cron generará de aquí al cierre (solo si el cierre no ha
  -- llegado). Copia de la parte «u» de `helios_settlement_outlook`: el tramo
  -- se calcula sobre TODOS los vencimientos futuros del consumo (el techo del
  -- neto se reparte en orden) y después se quedan los de antes del cierre.
  previsto as (
    select f.mid, sum(f.amount_usd) as previsto
    from (
      select d.mid,
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
          c.id                                                                  as charge_id,
          c.merchant_id                                                         as mid,
          i.due_date,
          round(coalesce(c.merchant_net_usd, c.amount_usd) * t.per_installment_pct / 100, 4) as tranche,
          coalesce(c.merchant_net_usd, c.amount_usd) - coalesce((
            select sum(s2.amount_usd)
            from public.settlements s2
            where s2.charge_id = c.id
              and s2.reason <> 'staff_commission'
          ), 0)                                                                 as room
        from public.installments i
        join public.charges c on c.id = i.charge_id
        cross join cal
        cross join lateral public.helios_terms_at(c.merchant_id, coalesce(c.business_date, cal.hoy)) t
        where t.policy = 'scheduled'
          and i.due_date >= cal.hoy
          and p_cierre > cal.hoy
          and not exists (
            select 1 from public.settlements s3
            where s3.charge_id = c.id
              and s3.reason = 'scheduled_installment'
              and s3.business_date = i.due_date
          )
      ) d
    ) f
    where f.amount_usd > 0
      and f.due_date < p_cierre
    group by f.mid
  ),
  -- Lo de cierres anteriores que sigue sin transferirse, como el outlook.
  atrasado as (
    select s.merchant_id as mid, sum(s.amount_usd - s.paid_usd) as atrasado
    from public.settlements s
    cross join cal
    where p_cierre > cal.hoy
      and s.status in ('pending', 'partial')
      and public.helios_settlement_run_for(s.due_date) < p_cierre
    group by s.merchant_id
  ),
  ids as (
    select g.mid from generado g
    union select p.mid from previsto p
    union select a.mid from atrasado a
  )
  select
    i.mid,
    coalesce(g.generado, 0)::numeric,
    coalesce(g.transferido, 0)::numeric,
    coalesce(g.pendiente, 0)::numeric,
    coalesce(p.previsto, 0)::numeric,
    coalesce(a.atrasado, 0)::numeric
  from ids i
  left join generado g on g.mid = i.mid
  left join previsto p on p.mid = i.mid
  left join atrasado a on a.mid = i.mid;
$function$
;
