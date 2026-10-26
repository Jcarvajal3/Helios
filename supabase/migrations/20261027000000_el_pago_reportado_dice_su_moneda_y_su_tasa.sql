-- ============================================================================
-- Helios — El pago reportado dice su moneda y su tasa
--
-- Javier (2026-10-26): en superadmin › Pagos reportados solo se veía el monto
-- (en dólares y en bolívares). Un pago de cuotas de una orden en euros se
-- cotiza a la tasa BCV del euro, y la lista y la ficha no lo decían: la ficha
-- incluso escribía «a 886,23 Bs/$» en un pago que se hizo a la del euro.
--
-- `helios_admin_payment_item` (lo que leen `admin_payment_queue` y
-- `admin_payment_report`) añade, sin quitar nada:
--
--   · `monedas`: las monedas del pago, dólares primero. Los cargos por atraso
--     van siempre en dólares.
--   · `fx_rate_eur` y `amount_eur`: la tasa del euro de la cotización y la
--     parte del pago en euros, en euros (la de `payment_quotes`).
--   · `usd_part_usd` / `eur_part_usd`: qué parte del monto (en dólares del
--     libro) va a la tasa del dólar y cuál a la del euro.
--   · En cada compra, `currency`; en cada cuota, `quoted_cur` (lo cotizado en
--     la moneda de su orden).
--
-- Solo lectura. Cuerpo copiado de la definición viva (20261004000300).
-- ============================================================================

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

    -- NUEVO: la moneda y la tasa de cada parte del pago.
    'monedas',      mon.monedas,
    'fx_rate_eur',  q.fx_rate_eur,
    'amount_eur',   q.amount_eur,
    'usd_part_usd', q.amount_usd - mon.eur_usd,
    'eur_part_usd', mon.eur_usd,

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
            -- NUEVO
            'currency',          ch.currency,
            'installments_total', (
              select count(*) from public.installments t
              where t.charge_id = ch.id and t.user_id = r.user_id
            ),
            'installments', jsonb_agg(jsonb_build_object(
              'installment_id', ins.id,
              'sequence',       ins.sequence,
              'quoted_usd',     qi.amount_usd,
              -- NUEVO
              'quoted_cur',     coalesce(qi.amount_cur, qi.amount_usd),
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
  -- NUEVO: las monedas del pago (los cargos por atraso, en dólares) y lo que
  -- va a la tasa del euro, en dólares del libro.
  cross join lateral (
    select
      coalesce(
        to_jsonb(array_agg(distinct x.currency order by x.currency desc)),
        '[]'::jsonb
      ) as monedas,
      coalesce(sum(x.usd) filter (where x.currency = 'EUR'), 0)::numeric as eur_usd
    from (
      select coalesce(qi5.currency, 'USD') as currency, qi5.amount_usd as usd
      from public.payment_quote_items qi5
      where qi5.quote_id = q.id
      union all
      select 'USD', q.late_fee_usd where q.late_fee_usd > 0
    ) x
  ) mon
  where r.id = p_report_id
$function$;
