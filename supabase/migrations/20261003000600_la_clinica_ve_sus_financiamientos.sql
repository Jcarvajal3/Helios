-- ============================================================================
-- Helios — Lo que la clínica (y el equipo) ve de un financiamiento (docs/01 §1.5)
--
-- Las lecturas heredadas de Ronda, con lo nuevo de Helios:
--
-- 1. `merchant_transactions(p_from, p_to, p_limit)`: cada fila añade
--    `concept`, `beneficiary_name`, `receipt_status`, `staff_commission_usd` y
--    `registered_by_name`; desaparece `payer_count` (era de grupos). Cambian
--    las columnas: se borra y se crea.
-- 2. `merchant_charge_detail`: añade `concept`, `beneficiary_name`, `receipt`
--    (`{status, sent_at, last_event, email_enmascarado}`),
--    `staff_commission_usd`, `commission_staff_name` e `installments` (solo
--    fechas y cuándo se le paga a la clínica: `run_date`,
--    `paid_to_merchant_on`). NUNCA el estado de pago de las cuotas del
--    paciente. Los `payouts` incluyen la comisión (`kind` = 'staff_commission').
-- 3. `merchant_sales_by_staff`: cada fila añade `commission_usd`.
-- 4. `merchant_sales_export` / `merchant_sales_export_items`: las columnas
--    `*_eur` (Ronda era en euros) pasan a `*_usd`; el export añade `concept`,
--    `beneficiary_name` y `staff_commission_usd`. Quien registró sale de
--    `helios_staff_name` (antes leía `profiles`, que ahora son pacientes). Lo
--    liquidado por la venta no cuenta la comisión.
-- 5. Superadmin: `admin_charge_detail` y `admin_charges` añaden el concepto,
--    el paciente atendido, quién lo registró, la comisión, las condiciones y
--    el comprobante.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La lista de financiamientos de la clínica
-- ---------------------------------------------------------------------------

drop function public.merchant_transactions(date, date, integer);

create function public.merchant_transactions(p_from date, p_to date, p_limit integer default 500)
returns table(
  charge_id uuid, order_number bigint, business_date date, confirmed_at timestamptz,
  amount_usd numeric, merchant_sale_usd numeric, customer_name text, staff_name text,
  cuota_1_due date, cuota_1_run date, cuota_2_due date, cuota_2_run date,
  concept text, beneficiary_name text, receipt_status text,
  staff_commission_usd numeric, registered_by_name text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit      integer := greatest(least(coalesce(p_limit, 500), 500), 1);
  v_gerente_de uuid    := public.my_merchant_id_as_gerente();
  v_me         uuid    := auth.uid();
begin
  return query
  with mias as (
    select c.id,
           c.order_number as num,
           c.business_date as bdate,
           c.confirmed_at as conf,
           c.amount_usd as charged,
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale,
           c.user_id as quien,
           c.merchant_id as local,
           c.requested_by as cobro,
           c.concept as concepto,
           c.beneficiary_name as atendido,
           c.staff_commission_usd as comision
    from public.charges c
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status = 'confirmed'
      and c.business_date between p_from and p_to
      -- El gerente de ESA clínica ve todos; cualquier otro, solo los suyos.
      and (c.merchant_id = v_gerente_de or c.requested_by = v_me)
    order by c.business_date desc, c.confirmed_at desc
    limit v_limit
  ),
  cuotas as (
    select i.charge_id                                            as cid,
           i.sequence                                             as seq,
           min(i.due_date)                                        as due,
           public.helios_settlement_run_for(min(i.due_date))       as run
    from public.installments i
    join mias m on m.id = i.charge_id
    group by i.charge_id, i.sequence
  )
  select m.id,
         m.num,
         m.bdate,
         m.conf,
         m.charged,
         m.sale,
         p.full_name,
         case when m.local = v_gerente_de or m.cobro = v_me
              then public.helios_staff_name(m.cobro) end,
         c1.due,
         c1.run,
         c2.due,
         c2.run,
         m.concepto,
         m.atendido,
         public.helios_charge_receipt(m.id) ->> 'status',
         m.comision,
         case when m.local = v_gerente_de or m.cobro = v_me
              then public.helios_staff_name(m.cobro) end
  from mias m
  left join public.profiles p on p.id = m.quien
  left join cuotas c1 on c1.cid = m.id and c1.seq = 1
  left join cuotas c2 on c2.cid = m.id and c2.seq = 2
  order by m.bdate desc, m.conf desc;
end;
$$;

revoke all on function public.merchant_transactions(date, date, integer) from public, anon;
grant execute on function public.merchant_transactions(date, date, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El detalle de un financiamiento
-- ---------------------------------------------------------------------------

create or replace function public.merchant_charge_detail(p_charge_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_charge  public.charges%rowtype;
  v_gerente boolean;
  v_out     jsonb;
begin
  select * into v_charge from public.charges where id = p_charge_id;

  -- El mismo error exista o no la orden.
  if not found or v_charge.merchant_id not in (select public.my_merchant_ids()) then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  v_gerente := coalesce(public.my_merchant_id_as_gerente() = v_charge.merchant_id, false);

  if not v_gerente and v_charge.requested_by is distinct from auth.uid() then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'charge_id', c.id,
    'order_number', c.order_number,
    'status', c.status::text,
    'business_date', c.business_date,
    'created_at', c.created_at,
    'confirmed_at', c.confirmed_at,
    'void_reason', c.void_reason,
    'is_test', c.is_test,
    -- El nombre del paciente, y nada más de él (ni deuda ni pagos).
    'customer_name', p.full_name,
    'staff_name', public.helios_staff_name(c.requested_by),
    'merchant_sale_usd', public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd),
    'base_usd', c.base_usd,
    'vat_usd', c.vat_usd,
    'amount_usd', c.amount_usd,
    'consumer_fee_usd', c.consumer_fee_usd,
    'consumer_fee_vat_usd', c.consumer_fee_vat_usd,
    'merchant_fee_usd', case when v_gerente then c.merchant_fee_usd end,
    'merchant_fee_vat_usd', case when v_gerente then c.merchant_fee_vat_usd end,
    'merchant_net_usd', case when v_gerente then c.merchant_net_usd end,
    'is_gerente', v_gerente,
    'branch', case when b.id is null then null else jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address
    ) end,
    -- Helios
    'concept', c.concept,
    'beneficiary_name', c.beneficiary_name,
    'receipt', public.helios_charge_receipt(c.id),
    'staff_commission_usd', c.staff_commission_usd,
    'commission_staff_name', case when c.commission_staff_id is not null
                                  then public.helios_staff_name(c.commission_staff_id) end,
    'payer_count', 1
  )
  into v_out
  from public.charges c
  left join public.merchant_branches b on b.id = c.branch_id
  left join public.profiles p on p.id = c.user_id
  where c.id = p_charge_id;

  v_out := v_out || jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', ci.name,
      'quantity', ci.quantity,
      'unit_price_usd', ci.unit_price_usd,
      'line_total_usd', ci.line_total_usd
    ) order by ci.position, ci.created_at)
    from public.charge_items ci where ci.charge_id = p_charge_id
  ), '[]'::jsonb));

  -- Las cuotas del paciente: SOLO sus fechas y cuándo se le paga a la clínica
  -- la mitad que corresponde. Nunca si el paciente pagó.
  v_out := v_out || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'sequence', m.seq,
      'due_date', m.due,
      'run_date', public.helios_settlement_run_for(m.due),
      'paid_to_merchant_on', (
        select max(coalesce(mp.paid_on, mp.business_date))
        from public.settlements s
        join public.merchant_payout_items it on it.settlement_id = s.id
        join public.merchant_payouts mp on mp.id = it.payout_id
        where s.charge_id = p_charge_id
          and s.reason = 'scheduled_installment'
          and s.business_date = m.due
          and s.status = 'paid'
      )
    ) order by m.seq)
    from (
      select i.sequence as seq, min(i.due_date) as due
      from public.installments i
      where i.charge_id = p_charge_id
      group by i.sequence
    ) m
  ), '[]'::jsonb));

  -- Cuándo se le paga a la clínica cada parte: el adelanto (si lo hay), cada
  -- mitad y la comisión del personal. Los montos, solo al gerente.
  v_out := v_out || jsonb_build_object('payouts', coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', x.kind,
      'sequence', x.seq,
      'due_date', x.due,
      'run_date', public.helios_settlement_run_for(x.due),
      'amount_usd', case when v_gerente or x.kind = 'staff_commission' then x.amount end,
      'paid_usd', case when v_gerente or x.kind = 'staff_commission' then x.paid end,
      'status', case when v_gerente or x.kind = 'staff_commission' then x.status end
    ) order by x.due, x.seq nulls first)
    from (
      select 'advance'::text    as kind,
             null::smallint     as seq,
             s.due_date         as due,
             s.amount_usd       as amount,
             s.paid_usd         as paid,
             s.status::text     as status
      from public.settlements s
      where s.charge_id = p_charge_id and s.reason = 'advance'

      union all

      select 'installment',
             m.seq,
             m.due,
             s.amount_usd,
             s.paid_usd,
             s.status::text
      from (
        select i.sequence as seq, min(i.due_date) as due
        from public.installments i
        where i.charge_id = p_charge_id
        group by i.sequence
      ) m
      left join public.settlements s
        on s.charge_id = p_charge_id
       and s.reason = 'scheduled_installment'
       and s.business_date = m.due

      union all

      select 'staff_commission',
             null::smallint,
             s.due_date,
             s.amount_usd,
             s.paid_usd,
             s.status::text
      from public.settlements s
      where s.charge_id = p_charge_id and s.reason = 'staff_commission'
    ) x
  ), '[]'::jsonb));

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Ventas por persona, con su comisión
-- ---------------------------------------------------------------------------

create or replace function public.merchant_sales_by_staff(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_gerente_de uuid := public.my_merchant_id_as_gerente();
  v_me         uuid := auth.uid();
  v_rows       jsonb;
begin
  if v_me is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id',        x.user_id,
           'name',           x.nombre,
           'role',           x.role,
           'is_active',      x.is_active,
           'is_self',        x.is_self,
           'order_count',    x.order_count,
           'sale_usd',       x.sale_usd,
           'charged_usd',    x.charged_usd,
           'avg_ticket_usd', public.helios_avg_ticket_usd(x.sale_usd, x.order_count),
           'active_days',    x.active_days,
           'last_sale_at',   x.last_sale_at,
           -- Helios: la comisión devengada por esos financiamientos.
           'commission_usd', x.commission_usd
         ) order by x.sale_usd desc, x.nombre), '[]'::jsonb)
  into v_rows
  from (
    select c.requested_by                                as user_id,
           public.helios_staff_name(c.requested_by)       as nombre,
           (select mu.role::text
              from public.merchant_users mu
             where mu.user_id = c.requested_by
               and mu.merchant_id = c.merchant_id
             order by mu.is_active desc, mu.created_at desc
             limit 1)                                    as role,
           coalesce((select bool_or(mu.is_active)
                       from public.merchant_users mu
                      where mu.user_id = c.requested_by
                        and mu.merchant_id = c.merchant_id), false) as is_active,
           c.requested_by = v_me                         as is_self,
           count(*)::integer                             as order_count,
           round(sum(public.helios_merchant_sale_usd(
             c.base_usd, c.vat_usd, c.amount_usd)), 2)   as sale_usd,
           round(sum(c.amount_usd), 2)                   as charged_usd,
           count(distinct c.business_date)::integer      as active_days,
           max(c.confirmed_at)                           as last_sale_at,
           round(coalesce(sum(sc.amount_usd) filter (where sc.status <> 'revertida'), 0), 2)
                                                         as commission_usd
    from public.charges c
    left join public.staff_commissions sc on sc.charge_id = c.id
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status = 'confirmed'
      and c.business_date between p_from and p_to
      and (c.merchant_id = v_gerente_de or c.requested_by = v_me)
    group by c.requested_by, c.merchant_id
  ) x;

  return jsonb_build_object(
    'scope', case when v_gerente_de is null then 'self' else 'gerente' end,
    'rows',  v_rows
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. La exportación, en dólares
-- ---------------------------------------------------------------------------

drop function public.merchant_sales_export(date, date);

create function public.merchant_sales_export(p_from date, p_to date)
returns table(
  order_number bigint, charge_id uuid, business_date date, confirmed_at timestamptz,
  branch_name text, cashier text, status text, void_reason text, group_name text,
  payer_count integer, item_count integer,
  base_usd numeric, vat_pct numeric, vat_usd numeric, sale_usd numeric,
  consumer_fee_pct numeric, consumer_fee_usd numeric, consumer_fee_vat_usd numeric,
  charged_to_customer_usd numeric,
  merchant_fee_pct numeric, merchant_fee_usd numeric, merchant_fee_vat_usd numeric,
  net_to_merchant_usd numeric,
  fx_rate numeric, sale_ves numeric, charged_to_customer_ves numeric, net_to_merchant_ves numeric,
  cuota_1_due date, cuota_1_run date, cuota_2_due date, cuota_2_run date,
  settled_usd numeric, paid_usd numeric, is_test boolean,
  concept text, beneficiary_name text, staff_commission_usd numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_max      integer := 20000;
  v_count    bigint;
begin
  if v_merchant is null then
    raise exception 'Solo el administrador de la clínica puede descargar sus financiamientos'
      using errcode = '42501';
  end if;

  select count(*) into v_count
  from public.charges c
  where c.merchant_id = v_merchant
    and c.business_date between p_from and p_to
    and c.status in ('confirmed', 'reverted');

  perform public.helios_assert_sales_export(p_from, p_to, v_count, v_max);

  return query
  with ventas as (
    select c.*,
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale,
           public.current_fx_rate('BCV', c.business_date) as rate
    from public.charges c
    where c.merchant_id = v_merchant
      and c.business_date between p_from and p_to
      and c.status in ('confirmed', 'reverted')
  ),
  cuotas as (
    select i.charge_id as cid,
           i.sequence  as seq,
           min(i.due_date) as due,
           public.helios_settlement_run_for(min(i.due_date)) as run
    from public.installments i
    join ventas v on v.id = i.charge_id
    group by i.charge_id, i.sequence
  ),
  lineas as (
    select ci.charge_id as cid, count(*)::integer as n
    from public.charge_items ci
    join ventas v on v.id = ci.charge_id
    group by ci.charge_id
  ),
  liquidado as (
    -- Lo liquidado por la VENTA: la comisión del personal va en su columna.
    select s.charge_id as cid,
           sum(s.amount_usd) as programado,
           sum(coalesce(s.paid_usd, 0)) as pagado
    from public.settlements s
    join ventas v on v.id = s.charge_id
    where s.reason <> 'staff_commission'
    group by s.charge_id
  )
  select
    v.order_number,
    v.id,
    v.business_date,
    v.confirmed_at,
    b.name,
    public.helios_staff_name(v.requested_by),
    v.status::text,
    v.void_reason,
    v.group_name,
    1,
    coalesce(l.n, 0),
    round(coalesce(v.base_usd, 0), 2),
    coalesce(v.vat_pct, 0),
    round(coalesce(v.vat_usd, 0), 2),
    round(v.sale, 2),
    coalesce(v.consumer_fee_pct, 0),
    round(coalesce(v.consumer_fee_usd, 0), 2),
    round(coalesce(v.consumer_fee_vat_usd, 0), 2),
    round(v.amount_usd, 2),
    coalesce(v.merchant_fee_pct, 0),
    round(coalesce(v.merchant_fee_usd, 0), 2),
    round(coalesce(v.merchant_fee_vat_usd, 0), 2),
    round(coalesce(v.merchant_net_usd, v.sale), 2),
    v.rate,
    round(v.sale * v.rate, 2),
    round(v.amount_usd * v.rate, 2),
    round(coalesce(v.merchant_net_usd, v.sale) * v.rate, 2),
    c1.due, c1.run,
    c2.due, c2.run,
    round(coalesce(s.programado, 0), 2),
    round(coalesce(s.pagado, 0), 2),
    v.is_test,
    v.concept,
    v.beneficiary_name,
    v.staff_commission_usd
  from ventas v
  left join public.merchant_branches b on b.id = v.branch_id
  left join lineas l on l.cid = v.id
  left join liquidado s on s.cid = v.id
  left join cuotas c1 on c1.cid = v.id and c1.seq = 1
  left join cuotas c2 on c2.cid = v.id and c2.seq = 2
  order by v.business_date, v.confirmed_at, v.order_number;
end;
$$;

drop function public.merchant_sales_export_items(date, date);

create function public.merchant_sales_export_items(p_from date, p_to date)
returns table(
  order_number bigint, charge_id uuid, business_date date, confirmed_at timestamptz,
  branch_name text, status text, line_no smallint, product_id uuid, product_name text,
  quantity integer, unit_price_usd numeric, line_total_usd numeric, fx_rate numeric,
  line_total_ves numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_max      integer := 50000;
  v_count    bigint;
begin
  if v_merchant is null then
    raise exception 'Solo el administrador de la clínica puede descargar sus financiamientos'
      using errcode = '42501';
  end if;

  select count(*) into v_count
  from public.charge_items ci
  join public.charges c on c.id = ci.charge_id
  where c.merchant_id = v_merchant
    and c.business_date between p_from and p_to
    and c.status in ('confirmed', 'reverted');

  perform public.helios_assert_sales_export(p_from, p_to, v_count, v_max);

  return query
  select
    c.order_number,
    c.id,
    c.business_date,
    c.confirmed_at,
    b.name,
    c.status::text,
    ci.position,
    ci.product_id,
    ci.name,
    ci.quantity,
    round(ci.unit_price_usd, 2),
    round(ci.line_total_usd, 2),
    r.rate,
    round(ci.line_total_usd * r.rate, 2)
  from public.charge_items ci
  join public.charges c on c.id = ci.charge_id
  left join public.merchant_branches b on b.id = c.branch_id
  left join lateral (
    select public.current_fx_rate('BCV', c.business_date) as rate
  ) r on true
  where c.merchant_id = v_merchant
    and c.business_date between p_from and p_to
    and c.status in ('confirmed', 'reverted')
  order by c.business_date, c.confirmed_at, c.order_number, ci.position;
end;
$$;

revoke all on function public.merchant_sales_export(date, date) from public, anon;
revoke all on function public.merchant_sales_export_items(date, date) from public, anon;
grant execute on function public.merchant_sales_export(date, date) to authenticated;
grant execute on function public.merchant_sales_export_items(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Superadmin
-- ---------------------------------------------------------------------------

create or replace function public.admin_charge_detail(p_charge_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today    date := public.helios_business_date(now());
  v_charge   public.charges%rowtype;
  v_financed numeric(18,4);
  v_out      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);

  select jsonb_build_object(
    'charge_id', c.id,
    'order_number', c.order_number,
    'status', c.status::text,
    'business_date', c.business_date,
    'created_at', c.created_at,
    'confirmed_at', c.confirmed_at,
    'void_reason', c.void_reason,
    'amount_usd', c.amount_usd,
    'financed_usd', v_financed,
    'consumer_fee_usd', c.consumer_fee_usd,
    'consumer_fee_vat_usd', c.consumer_fee_vat_usd,
    'merchant_fee_usd', c.merchant_fee_usd,
    'merchant_fee_vat_usd', c.merchant_fee_vat_usd,
    'merchant_net_usd', c.merchant_net_usd,
    'is_group', c.group_id is not null,
    'group_id', c.group_id,
    'is_test', c.is_test,
    'merchant', jsonb_build_object(
      'id', m.id, 'name', m.name, 'legal_name', m.legal_name, 'tax_id', m.tax_id
    ),
    'branch', case when b.id is null then null else jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address
    ) end,
    'user', case when p.id is null then null else jsonb_build_object(
      'id', p.id, 'full_name', p.full_name, 'phone_e164', p.phone_e164,
      'document_number', p.document_number, 'email', p.email
    ) end,
    -- Helios
    'concept', c.concept,
    'beneficiary_name', c.beneficiary_name,
    'registered_by', c.requested_by,
    'registered_by_name', public.helios_staff_name(c.requested_by),
    'terms_version', (select t.version from public.terms_versions t where t.id = c.terms_version_id),
    'receipt', public.helios_charge_receipt(c.id),
    'staff_commission', (
      select jsonb_build_object(
        'id', sc.id,
        'amount_usd', sc.amount_usd,
        'staff_user_id', sc.staff_user_id,
        'staff_name', public.helios_staff_name(sc.staff_user_id),
        'status', sc.status,
        'settlement_id', sc.settlement_id,
        'created_at', sc.created_at
      )
      from public.staff_commissions sc where sc.charge_id = c.id
    )
  )
  into v_out
  from public.charges c
  join public.merchants m on m.id = c.merchant_id
  left join public.merchant_branches b on b.id = c.branch_id
  left join public.profiles p on p.id = c.user_id
  where c.id = p_charge_id;

  v_out := v_out || jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', ci.name,
      'quantity', ci.quantity,
      'unit_price_usd', ci.unit_price_usd,
      'line_total_usd', ci.line_total_usd
    ) order by ci.position, ci.created_at)
    from public.charge_items ci where ci.charge_id = p_charge_id
  ), '[]'::jsonb));

  v_out := v_out || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'user_id', i.user_id,
      'full_name', pi.full_name,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      'financed_usd', i.financed_usd,
      'due_date', i.due_date,
      'status', i.status::text,
      'paid_at', i.paid_at,
      'written_off_at', i.written_off_at,
      'days_overdue', case
        when i.status = 'paid' or i.written_off_at is not null then 0
        else greatest(v_today - i.due_date, 0)
      end
    ) order by pi.full_name nulls last, i.user_id, i.sequence)
    from public.installments i
    left join public.profiles pi on pi.id = i.user_id
    where i.charge_id = p_charge_id
  ), '[]'::jsonb));

  v_out := v_out || jsonb_build_object('split', coalesce((
    select jsonb_agg(jsonb_build_object(
      'user_id', x.user_id,
      'full_name', pr.full_name,
      'phone_e164', pr.phone_e164,
      'financed_usd', x.financed_usd,
      'payable_usd', x.payable_usd,
      'installments_paid', x.paid,
      'installments_total', x.total,
      'started_it', x.user_id = v_charge.user_id,
      'reason', null
    ) order by x.payable_usd desc nulls last, pr.full_name nulls last)
    from (
      select i.user_id,
             sum(i.financed_usd)                                  as financed_usd,
             sum(i.amount_usd)                                    as payable_usd,
             count(*) filter (where i.status = 'paid')::integer    as paid,
             count(*)::integer                                     as total
      from public.installments i
      where i.charge_id = p_charge_id
      group by i.user_id
    ) x
    join public.profiles pr on pr.id = x.user_id
  ), '[]'::jsonb));

  -- Los mensajes de este financiamiento (comprobante, bienvenida, avisos).
  v_out := v_out || jsonb_build_object('messages', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', o.id, 'channel', o.channel, 'template_key', o.template_key,
      'status', o.status, 'recipient', o.recipient, 'last_event', o.last_event,
      'created_at', o.created_at, 'sent_at', o.sent_at
    ) order by o.created_at)
    from public.outbound_messages o where o.charge_id = p_charge_id
  ), '[]'::jsonb));

  v_out := v_out || jsonb_build_object('group', null::jsonb);

  return v_out;
end;
$$;

drop function public.admin_charges(text, uuid, text, date, date, integer);

create function public.admin_charges(
  p_search      text    default null,
  p_merchant_id uuid    default null,
  p_status      text    default null,
  p_from        date    default null,
  p_to          date    default null,
  p_limit       integer default 100
)
returns table(
  charge_id uuid, order_number bigint, amount_usd numeric, status text, business_date date,
  created_at timestamptz, confirmed_at timestamptz, void_reason text, user_id uuid,
  full_name text, phone_e164 text, user_status text, merchant_id uuid, merchant_name text,
  branch_name text, is_group boolean, is_test boolean, installments_paid integer,
  installments_total integer, financed_usd numeric,
  concept text, beneficiary_name text, registered_by_name text, staff_commission_usd numeric,
  document_number text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_needle text;
  v_order  bigint;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_needle := nullif(trim(coalesce(p_search, '')), '');

  if v_needle ~ '^#?\d{1,18}$' then
    v_order := replace(v_needle, '#', '')::bigint;
  else
    v_order := null;
  end if;

  return query
  select
    ch.id,
    ch.order_number,
    ch.amount_usd,
    ch.status::text,
    ch.business_date,
    ch.created_at,
    ch.confirmed_at,
    ch.void_reason,
    ch.user_id,
    p.full_name,
    p.phone_e164,
    p.status::text,
    m.id,
    m.name,
    b.name,
    ch.group_id is not null,
    ch.is_test,
    coalesce(i.paid, 0)::integer,
    coalesce(i.total, 0)::integer,
    coalesce(ch.base_usd, ch.amount_usd)::numeric,
    ch.concept,
    ch.beneficiary_name,
    public.helios_staff_name(ch.requested_by),
    ch.staff_commission_usd,
    p.document_number
  from public.charges ch
  left join public.profiles p on p.id = ch.user_id
  join public.merchants m on m.id = ch.merchant_id
  join public.merchant_branches b on b.id = ch.branch_id
  left join (
    select ins.charge_id as cid,
           count(*) filter (where ins.status = 'paid')::integer as paid,
           count(*)::integer as total
    from public.installments ins group by 1
  ) i on i.cid = ch.id
  where
    (p_merchant_id is null or ch.merchant_id = p_merchant_id)
    and (p_status is null or ch.status::text = p_status)
    and (p_from is null or ch.business_date >= p_from)
    and (p_to is null or ch.business_date <= p_to)
    and (
      v_needle is null
      or (v_order is not null and ch.order_number = v_order)
      or p.phone_e164 ilike '%' || v_needle || '%'
      or p.full_name ilike '%' || v_needle || '%'
      or p.document_number ilike '%' || v_needle || '%'
      or p.email ilike '%' || v_needle || '%'
      or m.name ilike '%' || v_needle || '%'
      or ch.concept ilike '%' || v_needle || '%'
      or ch.beneficiary_name ilike '%' || v_needle || '%'
    )
  order by ch.created_at desc
  limit least(coalesce(p_limit, 100), 500);
end;
$$;

revoke all on function public.admin_charges(text, uuid, text, date, date, integer) from public, anon;
grant execute on function public.admin_charges(text, uuid, text, date, date, integer) to authenticated;
