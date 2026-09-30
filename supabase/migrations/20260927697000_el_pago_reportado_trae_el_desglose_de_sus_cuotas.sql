-- PAGOS (aplicar AUD-OPERACION, 2026-09-28). Parte de la versión VIVA en dev,
-- que viene de 20260925145000_cada_aprobacion_guarda_su_movimiento_del_extracto.
--
-- 1. Cada cuota de un pago reportado trae su desglose: `financed_usd` y
--    `fee_usd` (= cotizado − facturado). Y el pago, el de todas sus cuotas:
--    `installments_financed_usd` e `installments_fee_usd`. Regla del fee: un
--    objeto con cifra payable trae sus dos partes. Solo se AÑADEN claves.
-- 2. `reference_collisions` se excluye a sí mismo por id. Con `count(*) - 1`
--    todo pago rechazado daba -1 (él no entra en la cuenta).
--
-- `admin_payment_queue` y `admin_payment_report` la llaman tal cual: no cambian.

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
    -- Cuándo se decidió (null mientras no se decide) y quién lo tomó: en
    -- in_review es quien lo marcó para revisar; resuelto, quien lo decidió.
    'reviewed_at',      r.reviewed_at,
    'reviewed_by',      r.reviewed_by,
    'reviewed_by_name', case when r.reviewed_by is not null
                             then coalesce(pa.full_name, 'Alguien del equipo') end,

    -- `installments_usd` es lo que suman las cuotas; el resto del monto son
    -- cargos por atraso, y el operador tiene que poder cuadrar las dos cifras
    -- sin restar de cabeza.
    'amount_usd',        q.amount_usd,
    'amount_ves',        q.amount_ves,
    'fx_rate',           q.fx_rate,
    'installment_count', q.installment_count,
    'installments_usd',  q.amount_usd - q.late_fee_usd,
    'late_fee_usd',      q.late_fee_usd,
    -- Las cuotas son payable: su desglose va con ellas (regla del fee). El
    -- facturado es el de cada cuota; el service fee + IVA, lo cotizado menos
    -- ese facturado.
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

    -- Cuántos OTROS reportes no rechazados comparten banco + referencia. Con
    -- referencias de 6 dígitos esto es sospecha, no prueba (docs/00 §3.7).
    -- Se excluye a sí mismo por id: con `count(*) - 1` un pago rechazado,
    -- que no entra en la cuenta, restaba uno que no estaba (daba -1, o 0 con
    -- una colisión de verdad).
    'reference_collisions', (
      select count(*) filter (where r2.id <> r.id) from public.payment_reports r2
      where r2.bank = r.bank and r2.reference = r.reference
        and r2.reference is not null and r2.status <> 'rejected'
    ),
    -- Movimientos del extracto importado que encajan: referencia, monto y
    -- fecha, las tres a la vez.
    'statement_matches', (
      select count(*) from public.bank_statement_lines l
      where r.reference is not null
        and l.reference like '%' || r.reference
        and abs(l.amount_ves - q.amount_ves) <= 1.00
        and l.moved_on between (r.created_at::date - 5) and (r.created_at::date + 5)
    ),
    -- De esos, los que todavía se pueden usar: ni respaldan otro pago ni se
    -- descartaron.
    'statement_matches_available', (
      select count(*) from public.helios_statement_candidates(r.id) c
      where c.used_by_report_id is null and not c.discarded
    ),
    -- El movimiento que respaldó la aprobación; null si no se ligó ninguno.
    'statement_line', (
      select jsonb_build_object(
        'id', sl.id, 'bank', sl.bank, 'moved_on', sl.moved_on,
        'reference', sl.reference, 'amount_ves', sl.amount_ves,
        'description', sl.description
      )
      from public.bank_statement_lines sl
      where sl.id = r.statement_line_id
    ),

    -- Las compras que toca este pago, cada una con las cuotas que salda.
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
            -- El denominador del "cuota 2 de 2", sobre las cuotas de ESTA
            -- persona: en un consumo de grupo el cargo tiene cuotas de varios.
            'installments_total', (
              select count(*) from public.installments t
              where t.charge_id = ch.id and t.user_id = r.user_id
            ),
            'installments', jsonb_agg(jsonb_build_object(
              'installment_id', ins.id,
              'sequence',       ins.sequence,
              -- El congelado al cotizar: la cifra contra la que concilia el
              -- servidor. Si difiere del de la cuota, el pago no se aprueba.
              'quoted_usd',     qi.amount_usd,
              'amount_usd',     ins.amount_usd,
              -- El desglose de la cuota cotizada: facturado (sin fee) y
              -- service fee + IVA (= cotizado − facturado).
              'financed_usd',   ins.financed_usd,
              'fee_usd',        qi.amount_usd - ins.financed_usd,
              'due_date',       ins.due_date,
              'status',         ins.status::text,
              'days_overdue',   greatest(p_today - ins.due_date, 0),
              -- Intentos anteriores sobre esta misma cuota.
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

    -- Los cargos por atraso, con la cuota que los disparó. Sin esto el monto
    -- no cuadra con ninguna suma de cuotas.
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
        -- HUÉRFANO: el de una cuota que ya se pagó, o uno sin cuota. Viaja con
        -- este pago aunque su cuota no esté aquí.
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
    ), '[]'::jsonb)
  )
  from public.payment_reports r
  join public.payment_quotes q on q.id = r.quote_id
  join public.profiles p on p.id = r.user_id
  left join public.platform_admins pa on pa.user_id = r.reviewed_by
  cross join lateral (
    select coalesce(sum(i2.financed_usd), 0)::numeric as financed_usd
    from public.payment_quote_items qi4
    join public.installments i2 on i2.id = qi4.installment_id
    where qi4.quote_id = q.id
  ) fin
  where r.id = p_report_id
$function$;
