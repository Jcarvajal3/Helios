-- ============================================================================
-- Helios — Un pago cuadra con margen: 10 Bs por debajo, 100 Bs por encima
-- (Javier, 2026-10-26)
--
-- Andrea Valeska Toledo Hurtado pagó Bs 14.155,00 por una cuota cotizada en
-- Bs 14.141,58 (13,42 de más) y nada lo reconoció: el lector y el aviso del
-- BNC exigían el monto al céntimo y el cruce con el extracto ±1 Bs. El
-- equipo acabó asignando el abono «sin dueño» y quedaron dos pagos.
--
-- Desde ahora un monto pagado CUADRA con lo cotizado si está entre
-- `payment_margin_under_ves` por debajo (10 Bs) y `payment_margin_over_ves`
-- por encima (100 Bs): más holgura para quien paga de más que para quien
-- paga de menos. Los dos son parámetros (Ajustes › Parámetros). La diferencia
-- ni se cobra ni se devuelve: el pago salda sus cuotas por su valor en
-- dólares, como siempre.
--
--  1. Los parámetros y `helios_monto_cuadra(pagado, cotizado [, tolerancia])`.
--  2. El lector (`helios_receipt_tramo`): el tramo de cuotas cuya cotización
--     cuadra con lo pagado (D5 con margen).
--  3. El aviso del BNC (`helios_bank_sms_evaluate`): el SMS cuadra con la
--     cotización del pago. Lo que dice el comprobante y lo que dice el SMS
--     siguen teniendo que ser iguales: los dos son lo que se pagó.
--  4. El cruce con el extracto: `helios_statement_candidates`,
--     `admin_link_candidates`, `admin_link_reports_for_line`,
--     `helios_admin_payment_item`, `admin_unmatched_deposits` y
--     `admin_reconciliation_health`, que usaban ±1 Bs. Donde el panel pasa
--     una tolerancia propia (`p_tolerance_ves`, para ensanchar la búsqueda),
--     se sigue respetando: vale lo que cuadre por cualquiera de las dos.
--
-- Las definiciones del punto 4 y del 3 son las vivas el 2026-10-26
-- (pg_get_functiondef), con solo la comparación del monto cambiada.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Los parámetros y la regla
-- ---------------------------------------------------------------------------

insert into public.business_parameter_catalog (key, label, unit, grupo) values
  ('payment_margin_under_ves', 'Margen de un pago por debajo de lo cotizado', 'Bs', 'producto'),
  ('payment_margin_over_ves',  'Margen de un pago por encima de lo cotizado', 'Bs', 'producto')
on conflict (key) do nothing;

insert into public.business_parameters (key, value, effective_from, note) values
  ('payment_margin_under_ves', 10,  public.helios_business_date(now()), 'Javier, 2026-10-26: 10 Bs de menos se aceptan'),
  ('payment_margin_over_ves',  100, public.helios_business_date(now()), 'Javier, 2026-10-26: 100 Bs de más se aceptan')
on conflict (key, effective_from) do nothing;

/**
 * ¿Lo pagado cuadra con lo cotizado? Entre el margen por debajo y el margen
 * por encima (parámetros). Con `p_tolerancia` (la que pasa el panel para
 * ensanchar una búsqueda), también si la diferencia cabe en ella.
 */
create or replace function public.helios_monto_cuadra(
  p_pagado     numeric,
  p_cotizado   numeric,
  p_tolerancia numeric default null
)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(
    p_pagado between p_cotizado - public.helios_parameter('payment_margin_under_ves', 10)
                 and p_cotizado + public.helios_parameter('payment_margin_over_ves', 100)
    or (p_tolerancia is not null and abs(p_pagado - p_cotizado) <= p_tolerancia),
    false)
$$;

revoke all on function public.helios_monto_cuadra(numeric, numeric, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. El lector
-- ---------------------------------------------------------------------------

/**
 * Las cuotas que paga un monto en bolívares, o null (20261021200000, con el
 * margen). Se cotiza la primera cuota pendiente, las dos primeras, y así, en
 * el orden en que se pagan; vale el primer tramo cuya cotización cuadra con
 * lo pagado (`helios_monto_cuadra`). Lo que no cuadra con ningún tramo va al
 * equipo (D5).
 */
create or replace function public.helios_receipt_tramo(
  p_user       uuid,
  p_paid_on    date,
  p_amount_ves numeric
)
returns uuid[]
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_ids   uuid[] := '{}'::uuid[];
  v_id    uuid;
  v_bs    numeric;
  v_menos numeric := public.helios_parameter('payment_margin_under_ves', 10);
begin
  if p_amount_ves is null or p_amount_ves <= 0 then
    return null;
  end if;

  for v_id in
    select i.id
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.user_id = p_user
      and i.status = 'pending'
      and not exists (
        select 1
        from public.payment_quote_items qi
        join public.payment_reports r on r.quote_id = qi.quote_id
        where qi.installment_id = i.id
          and r.status in ('reported', 'in_review')
      )
    order by i.due_date, c.created_at, i.sequence
  loop
    v_ids := v_ids || v_id;
    v_bs := public.helios_installments_ves(p_user, v_ids, p_paid_on);
    if v_bs is null then
      return null;
    end if;
    if public.helios_monto_cuadra(p_amount_ves, v_bs) then
      return v_ids;
    end if;
    -- Cada cuota suma: si lo pagado ya no llega ni con el margen por debajo,
    -- ningún tramo más largo cuadra.
    exit when v_bs - v_menos > p_amount_ves;
  end loop;

  return null;
end;
$$;

revoke all on function public.helios_receipt_tramo(uuid, date, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- helios_statement_candidates (la definición viva, con el margen)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.helios_statement_candidates(p_report_id uuid, p_tolerance_ves numeric DEFAULT 1.00, p_window_days integer DEFAULT 5)
 RETURNS TABLE(id uuid, bank text, moved_on date, reference text, amount_ves numeric, description text, difference_ves numeric, discarded boolean, linked boolean, used_by_report_id uuid)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select
    l.id, l.bank, l.moved_on, l.reference, l.amount_ves, l.description,
    round(l.amount_ves - q.amount_ves, 2) as difference_ves,
    l.status = 'descartado' as discarded,
    r.statement_line_id is not distinct from l.id as linked,
    coalesce(
      (select r2.id from public.payment_reports r2
       where r2.statement_line_id = l.id and r2.id <> r.id
       limit 1),
      -- Un abono asignado antes de que existiera la columna.
      case when l.report_id is not null and l.report_id <> r.id then l.report_id end
    ) as used_by_report_id
  from public.payment_reports r
  join public.payment_quotes q on q.id = r.quote_id
  join public.bank_statement_lines l
    on r.reference is not null
   and l.reference like '%' || r.reference
   and public.helios_monto_cuadra(l.amount_ves, q.amount_ves, p_tolerance_ves)
   -- Helios: alrededor del día del pago que dice el comprobante; si no lo
   -- hay (Ronda, abonos), del día en que se reportó.
   and l.moved_on between (coalesce(r.paid_on, r.created_at::date) - coalesce(p_window_days, 5))
                      and (coalesce(r.paid_on, r.created_at::date) + coalesce(p_window_days, 5))
  where r.id = p_report_id;
$function$;

-- ---------------------------------------------------------------------------
-- admin_link_candidates (la definición viva, con el margen)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_link_candidates(p_report_id uuid, p_tolerance_ves numeric DEFAULT 1.00, p_window_days integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if not exists (select 1 from public.payment_reports where id = p_report_id) then
    raise exception 'Reporte no encontrado' using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(to_jsonb(c) order by c.reference_matches desc, abs(c.difference_ves), c.moved_on desc), '[]'::jsonb)
  into v_rows
  from (
    select
      l.id,
      l.bank,
      l.moved_on,
      l.reference,
      l.amount_ves,
      l.description,
      round(l.amount_ves - q.amount_ves, 2) as difference_ves,
      l.status::text as status,
      -- El motivo con el que se descartó, para que quien lo recupera lo lea.
      case when l.status = 'descartado' then l.resolution_note end as discard_note,
      case when l.status = 'descartado' then coalesce(pa.full_name, 'Alguien del equipo') end as discarded_by_name,
      r.reference is not null and l.reference like '%' || r.reference as reference_matches,
      u.id is null as available,
      case when u.id is not null then jsonb_build_object(
        'report_id', u.id,
        'user_id', u.user_id,
        'full_name', pu.full_name
      ) end as used_by
    from public.payment_reports r
    join public.payment_quotes q on q.id = r.quote_id
    join public.bank_statement_lines l
      on public.helios_monto_cuadra(l.amount_ves, q.amount_ves, p_tolerance_ves)
     and l.moved_on between (r.created_at::date - coalesce(p_window_days, 5))
                        and (r.created_at::date + coalesce(p_window_days, 5))
    -- El pago al que ya respalda: por la columna o, en un abono asignado antes
    -- de que existiera, por el pago que nació de él.
    left join lateral (
      select r2.id, r2.user_id
      from public.payment_reports r2
      where r2.id <> r.id
        and (r2.statement_line_id = l.id or r2.id = l.report_id)
      limit 1
    ) u on true
    left join public.profiles pu on pu.id = u.user_id
    left join public.platform_admins pa on pa.user_id = l.resolved_by
    where r.id = p_report_id
  ) c;

  return v_rows;
end;
$function$;

-- ---------------------------------------------------------------------------
-- admin_link_reports_for_line (la definición viva, con el margen)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_link_reports_for_line(p_line_id uuid, p_tolerance_ves numeric DEFAULT 1.00, p_window_days integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if not exists (select 1 from public.bank_statement_lines where id = p_line_id) then
    raise exception 'No existe ese abono' using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(to_jsonb(c) order by c.reference_matches desc, abs(c.difference_ves), c.created_at desc), '[]'::jsonb)
  into v_rows
  from (
    select
      r.id as report_id,
      r.user_id,
      p.full_name,
      r.created_at,
      r.reviewed_at,
      r.method,
      r.bank,
      r.reference,
      q.amount_ves,
      q.amount_usd,
      round(l.amount_ves - q.amount_ves, 2) as difference_ves,
      r.reference is not null and l.reference like '%' || r.reference as reference_matches
    from public.bank_statement_lines l
    join public.payment_reports r
      on r.status = 'reconciled'
     and r.statement_line_id is null
    join public.payment_quotes q on q.id = r.quote_id
    join public.profiles p on p.id = r.user_id
    where l.id = p_line_id
      and public.helios_monto_cuadra(l.amount_ves, q.amount_ves, p_tolerance_ves)
      and l.moved_on between (r.created_at::date - coalesce(p_window_days, 5))
                         and (r.created_at::date + coalesce(p_window_days, 5))
  ) c;

  return v_rows;
end;
$function$;

-- ---------------------------------------------------------------------------
-- helios_admin_payment_item (la definición viva, con el margen)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.helios_admin_payment_item(p_report_id uuid, p_today date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'report_id',      r.id,
    'status',         r.status::text,
    'created_at',     r.created_at,
    'method',         r.method,
    'bank',           r.bank,
    'reference',      r.reference,
    'payer_document', r.payer_document,
    'payer_phone',    r.payer_phone,
    'rejection_note', r.rejection_note,
    'reviewed_at',      r.reviewed_at,
    'reviewed_by',      r.reviewed_by,
    'reviewed_by_name', case when r.reviewed_by is not null
                             then coalesce(pa.full_name, 'Alguien del equipo') end,

    'amount_usd',        q.amount_usd,
    'amount_ves',        q.amount_ves,
    'fx_rate',           q.fx_rate,
    'installment_count', q.installment_count,
    'installments_usd',  q.amount_usd - q.late_fee_usd,
    'late_fee_usd',      q.late_fee_usd,
    'installments_financed_usd', fin.financed_usd,
    'installments_fee_usd',      (q.amount_usd - q.late_fee_usd) - fin.financed_usd,

    'user', jsonb_build_object(
      'user_id',         p.id,
      'full_name',       p.full_name,
      'phone_e164',      p.phone_e164,
      'document_number', p.document_number,
      'status',          p.status::text,
      'level',           p.level
    ),

    'reference_collisions', (
      select count(*) filter (where r2.id <> r.id) from public.payment_reports r2
      where r2.bank = r.bank and r2.reference = r.reference
        and r2.reference is not null and r2.status <> 'rejected'
    ),
    'statement_matches', (
      select count(*) from public.bank_statement_lines l
      where r.reference is not null
        and l.reference like '%' || r.reference
        and public.helios_monto_cuadra(l.amount_ves, q.amount_ves)
        and l.moved_on between (coalesce(r.paid_on, r.created_at::date) - 5)
                           and (coalesce(r.paid_on, r.created_at::date) + 5)
    ),
    'statement_matches_available', (
      select count(*) from public.helios_statement_candidates(r.id) c
      where c.used_by_report_id is null and not c.discarded
    ),
    'statement_line', (
      select jsonb_build_object(
        'id', sl.id, 'bank', sl.bank, 'moved_on', sl.moved_on,
        'reference', sl.reference, 'amount_ves', sl.amount_ves,
        'description', sl.description
      )
      from public.bank_statement_lines sl
      where sl.id = r.statement_line_id
    ),

    'purchases', coalesce((
      select jsonb_agg(purchase order by business_date nulls last, order_number nulls last)
      from (
        select
          ch.business_date,
          ch.order_number,
          jsonb_build_object(
            'charge_id',         ch.id,
            'order_number',      ch.order_number,
            'merchant_id',       m.id,
            'merchant_name',     m.name,
            'branch_name',       b.name,
            'charge_amount_usd', ch.amount_usd,
            'charge_status',     ch.status::text,
            'business_date',     ch.business_date,
            'confirmed_at',      ch.confirmed_at,
            'is_group',          ch.group_id is not null,
            'group_name',        ch.group_name,
            'installments_total', (
              select count(*) from public.installments t
              where t.charge_id = ch.id and t.user_id = r.user_id
            ),
            'installments', jsonb_agg(jsonb_build_object(
              'installment_id', ins.id,
              'sequence',       ins.sequence,
              'quoted_usd',     qi.amount_usd,
              'amount_usd',     ins.amount_usd,
              'financed_usd',   ins.financed_usd,
              'fee_usd',        qi.amount_usd - ins.financed_usd,
              'due_date',       ins.due_date,
              'status',         ins.status::text,
              'days_overdue',   greatest(p_today - ins.due_date, 0),
              'other_reports', (
                select count(*)
                from public.payment_quote_items qi2
                join public.payment_reports r2 on r2.quote_id = qi2.quote_id
                where qi2.installment_id = ins.id and r2.id <> r.id
              )
            ) order by ins.sequence)
          ) as purchase
        from public.payment_quote_items qi
        join public.installments ins on ins.id = qi.installment_id
        join public.charges ch on ch.id = ins.charge_id
        join public.merchants m on m.id = ch.merchant_id
        join public.merchant_branches b on b.id = ch.branch_id
        where qi.quote_id = q.id
        group by ch.id, m.id, b.id
      ) g
    ), '[]'::jsonb),

    'late_fees', coalesce((
      select jsonb_agg(jsonb_build_object(
        'late_fee_id',    f.id,
        'amount_usd',     fl.amount_usd,
        'days_late',      f.days_late,
        'business_date',  f.business_date,
        'installment_id', f.installment_id,
        'sequence',       ins.sequence,
        'order_number',   ch.order_number,
        'merchant_name',  m.name,
        'orphan', f.installment_id is null or not exists (
          select 1 from public.payment_quote_items qi3
          where qi3.quote_id = q.id and qi3.installment_id = f.installment_id
        )
      ) order by f.business_date, f.created_at)
      from public.payment_quote_late_fees fl
      join public.late_fees f on f.id = fl.late_fee_id
      left join public.installments ins on ins.id = f.installment_id
      left join public.charges ch on ch.id = ins.charge_id
      left join public.merchants m on m.id = ch.merchant_id
      where fl.quote_id = q.id
    ), '[]'::jsonb),

    -- ── Helios: el pago lo registró el equipo ────────────────────────────
    'registered_by',       r.registered_by,
    'registered_by_name',  case when r.registered_by is not null
                                then coalesce(ra.full_name, 'Alguien del equipo') end,
    'paid_on',             r.paid_on,
    'declared_amount_ves', r.declared_amount_ves,
    'note',                r.note,
    'receipt_path',        r.receipt_path,
    -- Para pedir la URL firmada: storage.from(bucket).createSignedUrl(path).
    'receipt', case when r.receipt_path is not null then
                 jsonb_build_object('bucket', 'payment-receipts', 'path', r.receipt_path) end,
    'four_eyes',   public.helios_payment_four_eyes(),
    'can_approve', public.helios_can_approve_payment(r.id, auth.uid())
  )
  from public.payment_reports r
  join public.payment_quotes q on q.id = r.quote_id
  join public.profiles p on p.id = r.user_id
  left join public.platform_admins pa on pa.user_id = r.reviewed_by
  left join public.platform_admins ra on ra.user_id = r.registered_by
  cross join lateral (
    select coalesce(sum(i2.financed_usd), 0)::numeric as financed_usd
    from public.payment_quote_items qi4
    join public.installments i2 on i2.id = qi4.installment_id
    where qi4.quote_id = q.id
  ) fin
  where r.id = p_report_id
$function$;

-- ---------------------------------------------------------------------------
-- admin_reconciliation_health (la definición viva, con el margen)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_reconciliation_health(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_to      date := coalesce(p_to, public.helios_business_date(now()));
  v_from    date := coalesce(p_from, coalesce(p_to, public.helios_business_date(now())) - 29);
  v_from_ts timestamptz;
  v_to_ts   timestamptz;
  v_result  jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_to < v_from then
    raise exception 'El rango de fechas está al revés' using errcode = '22023';
  end if;

  -- El día operativo empieza a medianoche (Helios, H2).
  v_from_ts := public.helios_business_day_end(v_from - 1);
  v_to_ts   := public.helios_business_day_end(v_to);

  with base as (
    select r.id, r.status::text as status, r.method, r.reference,
           r.created_at, r.reviewed_at, q.amount_ves, r.statement_line_id
    from public.payment_reports r
    join public.payment_quotes q on q.id = r.quote_id
    join public.profiles p on p.id = r.user_id
    where r.status in ('reconciled', 'rejected', 'duplicate')
      and r.reviewed_at >= v_from_ts
      and r.reviewed_at <  v_to_ts
      and not p.is_test
  ),
  res as (
    select
      b.*,
      exists (
        select 1 from public.bank_statement_lines l where l.report_id = b.id
      ) as from_deposit,
      -- Aprobado con un movimiento del extracto ligado: el que se miró al
      -- aprobar, no el que coincide hoy.
      b.statement_line_id is not null as linked,
      -- El criterio de `statement_matches` de la cola, tal cual. Solo para
      -- los rechazados: uno que encaja merece otra mirada.
      exists (
        select 1 from public.bank_statement_lines l
        where b.reference is not null
          and l.reference like '%' || b.reference
          and public.helios_monto_cuadra(l.amount_ves, b.amount_ves)
          and l.moved_on between (b.created_at::date - 5) and (b.created_at::date + 5)
      ) as matched,
      -- Los métodos que salen en el extracto del banco en bolívares. Zelle,
      -- USDT y efectivo no pueden tener coincidencia por construcción.
      b.method in ('pago_movil', 'transferencia') as in_statement,
      (extract(epoch from (b.reviewed_at - b.created_at)) / 60.0)::double precision as minutes
    from base b
  ),
  metodos(method, ord) as (
    values ('pago_movil', 1), ('transferencia', 2), ('zelle', 3), ('usdt', 4), ('efectivo', 5)
  ),
  cola as (
    select r.status::text as status, q.amount_usd,
           now() - r.created_at as age, r.created_at
    from public.payment_reports r
    join public.payment_quotes q on q.id = r.quote_id
    join public.profiles p on p.id = r.user_id
    where r.status in ('reported', 'in_review')
      and not p.is_test
  )
  select jsonb_build_object(
    'from', v_from,
    'to', v_to,
    'resolved', (
      select jsonb_build_object(
        'total',         count(*)::integer,
        'approved',      (count(*) filter (where status = 'reconciled'))::integer,
        'rejected',      (count(*) filter (where status = 'rejected'))::integer,
        'duplicate',     (count(*) filter (where status = 'duplicate'))::integer,
        -- Aprobados que nacieron de asignar un abono: respaldados por
        -- construcción, fuera de la tasa.
        'approved_from_deposit', (count(*) filter (where status = 'reconciled' and from_deposit))::integer,
        -- La tasa de respaldo: aprobados por métodos que salen en el extracto.
        'approved_in_statement_methods',
          (count(*) filter (where status = 'reconciled' and in_statement and not from_deposit))::integer,
        'approved_matched',
          (count(*) filter (where status = 'reconciled' and in_statement and not from_deposit and linked))::integer,
        'match_pct', case
          when count(*) filter (where status = 'reconciled' and in_statement and not from_deposit) > 0
          then round(100.0 * count(*) filter (where status = 'reconciled' and in_statement and not from_deposit and linked)
                     / count(*) filter (where status = 'reconciled' and in_statement and not from_deposit), 1)
        end,
        -- Rechazados que SÍ tienen un movimiento que encaja: merecen otra mirada.
        'rejected_matched', (count(*) filter (where status = 'rejected' and matched))::integer
      )
      from res
    ),
    'by_method', (
      select jsonb_agg(jsonb_build_object(
               'method', x.method,
               'approved', x.approved,
               'approved_matched', x.approved_matched,
               'rejected', x.rejected
             ) order by x.ord)
      from (
        select m.method, m.ord,
               (count(r.*) filter (where r.status = 'reconciled' and not r.from_deposit))::integer as approved,
               (count(r.*) filter (where r.status = 'reconciled' and not r.from_deposit and r.linked))::integer as approved_matched,
               (count(r.*) filter (where r.status = 'rejected'))::integer as rejected
        from metodos m
        left join res r on r.method = m.method
        group by m.method, m.ord
      ) x
    ),
    -- Minutos desde el reporte hasta la decisión. Sin los nacidos de un abono.
    'resolution_minutes', (
      select jsonb_build_object(
        'all', jsonb_build_object(
          'count', count(*)::integer,
          'median', round(percentile_cont(0.5) within group (order by minutes)::numeric, 1),
          'p90',    round(percentile_cont(0.9) within group (order by minutes)::numeric, 1)
        ),
        'approved', jsonb_build_object(
          'count', (count(*) filter (where status = 'reconciled'))::integer,
          'median', round((percentile_cont(0.5) within group (order by minutes)
                           filter (where status = 'reconciled'))::numeric, 1),
          'p90',    round((percentile_cont(0.9) within group (order by minutes)
                           filter (where status = 'reconciled'))::numeric, 1)
        ),
        'rejected', jsonb_build_object(
          'count', (count(*) filter (where status = 'rejected'))::integer,
          'median', round((percentile_cont(0.5) within group (order by minutes)
                           filter (where status = 'rejected'))::numeric, 1),
          'p90',    round((percentile_cont(0.9) within group (order by minutes)
                           filter (where status = 'rejected'))::numeric, 1)
        )
      )
      from res
      where not from_deposit
    ),
    -- La cola de ahora, por lo que lleva esperando. PAYABLE.
    'queue', (
      select jsonb_build_object(
        'count', count(*)::integer,
        'usd', coalesce(sum(amount_usd), 0),
        'in_review', (count(*) filter (where status = 'in_review'))::integer,
        'oldest_created_at', min(created_at),
        'under_24h', jsonb_build_object(
          'count', (count(*) filter (where age < interval '24 hours'))::integer,
          'usd', coalesce(sum(amount_usd) filter (where age < interval '24 hours'), 0)),
        'from_1_to_3_days', jsonb_build_object(
          'count', (count(*) filter (where age >= interval '24 hours' and age <= interval '72 hours'))::integer,
          'usd', coalesce(sum(amount_usd) filter (where age >= interval '24 hours' and age <= interval '72 hours'), 0)),
        'over_3_days', jsonb_build_object(
          'count', (count(*) filter (where age > interval '72 hours'))::integer,
          'usd', coalesce(sum(amount_usd) filter (where age > interval '72 hours'), 0))
      )
      from cola
    ),
    -- Hasta dónde llega el extracto importado.
    'statement', (
      select jsonb_build_object(
        'last_moved_on', max(l.moved_on),
        'last_imported_at', max(l.imported_at)
      )
      from public.bank_statement_lines l
    )
  )
  into v_result;

  return v_result;
end;
$function$;

-- ---------------------------------------------------------------------------
-- admin_unmatched_deposits (la definición viva, con el margen)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_unmatched_deposits(p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.de_helios desc, q.moved_on desc), '[]'::jsonb)
  into v_rows
  from (
    select
      l.id,
      l.bank,
      l.moved_on,
      l.reference,
      l.amount_ves,
      l.description,
      l.imported_at,
      -- En dólares a la tasa de ESE día, no a la de hoy: el abono entró con la
      -- tasa de su fecha y volver a convertirlo con otra inventa una
      -- diferencia que no existió.
      (
        select round(l.amount_ves / r.rate, 2)
        from public.exchange_rates r
        where r.source = 'BCV'
          and r.effective_date <= l.moved_on
        order by r.effective_date desc
        limit 1
      ) as amount_usd,
      -- Helios y Ronda cobran en la misma cuenta: sin un pagador de Helios,
      -- el abono casi seguro es de Ronda.
      public.helios_movimiento_es_de_helios(l.description) as de_helios
    from public.bank_statement_lines l
    where l.status = 'sin_dueno'
      and not exists (
        select 1 from public.payment_reports pr where pr.statement_line_id = l.id
      )
      and not exists (
        select 1
        from public.payment_reports pr
        join public.payment_quotes pq on pq.id = pr.quote_id
        where pr.status = 'reconciled'
          and pr.statement_line_id is null
          and pr.reference is not null
          and l.reference like '%' || pr.reference
          and public.helios_monto_cuadra(l.amount_ves, pq.amount_ves)
          and l.moved_on between (pr.created_at::date - 5) and (pr.created_at::date + 5)
      )
    order by l.moved_on desc
    limit least(coalesce(p_limit, 100), 500)
  ) q;

  return v_rows;
end;
$function$;

-- ---------------------------------------------------------------------------
-- helios_bank_sms_evaluate (la definición viva, con el margen)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.helios_bank_sms_evaluate(p_notice_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_n        public.bank_sms_notices%rowtype;
  v_cfg      public.bank_sms_settings%rowtype;
  v_count    integer;
  v_report   uuid;
  v_status   public.payment_report_status;
  v_phone    text;
  v_rivales  integer;
  v_outcome  text;
  v_note     text;
begin
  select * into v_n from public.bank_sms_notices where id = p_notice_id for update;
  if not found or v_n.outcome <> 'esperando' then
    return v_n.outcome;
  end if;

  select * into v_cfg from public.bank_sms_settings where id;
  if coalesce(v_cfg.mode, 'apagado') = 'apagado' then
    return 'esperando';
  end if;

  if v_cfg.allowed_sender is not null
     and coalesce(trim(v_n.sender), '') <> v_cfg.allowed_sender then
    update public.bank_sms_notices
    set outcome = 'remitente_ajeno', mode = v_cfg.mode, decided_at = now(),
        note = format('Remitente %s; se espera %s', coalesce(v_n.sender, 'desconocido'), v_cfg.allowed_sender)
    where id = v_n.id;
    return 'remitente_ajeno';
  end if;

  select count(*), min(r.id::text)::uuid into v_count, v_report
  from public.payment_reports r
  join public.payment_quotes q on q.id = r.quote_id
  where r.method = 'pago_movil'
    and public.helios_bank_sms_ref_match(v_n.reference, r.reference)
    and public.helios_monto_cuadra(v_n.amount_ves, q.amount_ves)
    and (r.declared_amount_ves is null or r.declared_amount_ves = v_n.amount_ves)
    and r.status not in ('rejected', 'duplicate')
    and public.helios_bank_sms_day_match(v_n.paid_at, r.paid_on, r.created_at);

  if v_count = 0 then
    return 'esperando';
  end if;

  if v_count > 1 then
    v_outcome := 'varios';
    v_note := format('%s pagos reportados encajan con este aviso', v_count);
  else
    select r.status, r.payer_phone into v_status, v_phone
    from public.payment_reports r where r.id = v_report;

    -- El otro sentido: otro aviso que encaje igual con ese pago.
    select count(*) into v_rivales
    from public.bank_sms_notices o
    join public.payment_reports r on r.id = v_report
    join public.payment_quotes q on q.id = r.quote_id
    where o.id <> v_n.id
      and o.reference is not null
      and public.helios_bank_sms_ref_match(o.reference, r.reference)
      and public.helios_monto_cuadra(o.amount_ves, q.amount_ves)
      -- Con margen (2026-10-26), el rival cumple lo mismo que el aviso que se
      -- coteja: el monto del comprobante, si lo hay, y un teléfono que no
      -- contradiga el del pago.
      and (r.declared_amount_ves is null or r.declared_amount_ves = o.amount_ves)
      and (r.payer_phone is null
           or public.helios_phone_matches_sms(r.payer_phone, o.payer_phone_prefix, o.payer_phone_last4))
      and public.helios_bank_sms_day_match(o.paid_at, r.paid_on, r.created_at);

    if v_rivales > 0 then
      v_outcome := 'varios';
      v_note := 'Otro aviso encaja con el mismo pago';
    elsif v_phone is not null
       and (left(regexp_replace(v_phone, '^\+?58', '0'), 4) <> v_n.payer_phone_prefix
            or right(v_phone, 4) <> v_n.payer_phone_last4) then
      v_outcome := 'telefono_distinto';
      v_note := format('El SMS dice %s***%s y el pago dice %s',
        v_n.payer_phone_prefix, v_n.payer_phone_last4, v_phone);
    elsif v_status = 'reconciled' then
      v_outcome := 'ya_aprobado';
    elsif v_cfg.mode = 'sombra' then
      v_outcome := 'aprobaria';
    elsif v_cfg.actor is null then
      v_outcome := 'error';
      v_note := 'Modo activo sin persona que firme las aprobaciones';
    else
      begin
        perform public.reconcile_payment(v_report, v_cfg.actor, true, 'Aprobado por el aviso del BNC');
        perform audit.log(v_cfg.actor, 'payment.reconciled', v_report, jsonb_build_object(
          'via', 'aviso_bnc',
          'notice_id', v_n.id,
          'sms_reference', v_n.reference,
          'amount_ves', v_n.amount_ves
        ));
        v_outcome := 'aprobado';
      exception when others then
        v_outcome := 'error';
        v_note := sqlerrm;
      end;
    end if;
  end if;

  update public.bank_sms_notices
  set outcome = v_outcome,
      report_id = v_report,
      mode = v_cfg.mode,
      decided_at = now(),
      note = v_note
  where id = v_n.id;

  return v_outcome;
end;
$function$;
