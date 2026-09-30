-- ============================================================================
-- Ronda — Un pago reportado se lee solo
--
-- La ficha de un pago (`FichaCobro` en el panel) no tenía cómo pedir UN pago:
-- pedía la cola entera, con todos los estados y todo su historial, y buscaba
-- el suyo dentro. Cada pago aprobado hace esa llamada más pesada para siempre.
--
-- La forma de un pago de la cola —pago → compras → cuotas, más los cargos por
-- atraso— pasa a una función interna, `helios_admin_payment_item`, que usan las
-- dos: la cola, para cada fila, y `admin_payment_report`, para una. Así la
-- ficha y la lista no pueden llegar a enseñar dos versiones del mismo pago. La
-- salida de la cola no cambia (el ensayo compara la de antes y la de después
-- con todos los estados, campo a campo).
--
-- `admin_payment_report` devuelve null si el pago no existe o es de una cuenta
-- de prueba: la cola tampoco las enseña.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Un pago, con su árbol
-- ---------------------------------------------------------------------------
-- Interna: lee datos de personas y no mira quién llama, así que no tiene grant
-- para nadie. Solo la llaman funciones `security definer` con su guarda.
create or replace function public.helios_admin_payment_item(p_report_id uuid, p_today date)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
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

    -- `installments_usd` es lo que suman las cuotas; el resto del monto son
    -- cargos por atraso, y el operador tiene que poder cuadrar las dos cifras
    -- sin restar de cabeza.
    'amount_usd',        q.amount_usd,
    'amount_ves',        q.amount_ves,
    'fx_rate',           q.fx_rate,
    'installment_count', q.installment_count,
    'installments_usd',  q.amount_usd - q.late_fee_usd,
    'late_fee_usd',      q.late_fee_usd,

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
    'reference_collisions', (
      select count(*) - 1 from public.payment_reports r2
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
  where r.id = p_report_id
$$;

revoke all on function public.helios_admin_payment_item(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. La cola, sobre la función de un pago
-- ---------------------------------------------------------------------------
create or replace function public.admin_payment_queue(
  p_statuses text[] default array['reported', 'in_review']
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(
           jsonb_agg(public.helios_admin_payment_item(r.id, v_today) order by r.created_at),
           '[]'::jsonb
         )
    into v_result
  from public.payment_reports r
  join public.payment_quotes q on q.id = r.quote_id
  join public.profiles p on p.id = r.user_id
  where r.status::text = any(p_statuses)
    and not p.is_test;

  return v_result;
end;
$$;

revoke all on function public.admin_payment_queue(text[]) from public, anon;
grant execute on function public.admin_payment_queue(text[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Un pago suelto
-- ---------------------------------------------------------------------------
create or replace function public.admin_payment_report(p_report_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_item jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select public.helios_admin_payment_item(r.id, public.helios_business_date(now()))
    into v_item
  from public.payment_reports r
  join public.profiles p on p.id = r.user_id
  where r.id = p_report_id
    and not p.is_test;

  return v_item;
end;
$$;

revoke all on function public.admin_payment_report(uuid) from public, anon;
grant execute on function public.admin_payment_report(uuid) to authenticated;
