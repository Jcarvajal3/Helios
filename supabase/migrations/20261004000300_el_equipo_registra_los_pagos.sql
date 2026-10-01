-- ============================================================================
-- Helios — El equipo registra los pagos (docs/00 §7.1, docs/01 §2.1)
--
-- En Ronda el cliente cotizaba y reportaba su pago desde la app
-- (`quote_installments` + `report_payment`, con `auth.uid()` como deudor). En
-- Helios el paciente paga y manda la captura por WhatsApp, y es el EQUIPO el
-- que registra el pago. A partir de ahí es la misma cola de «Pagos
-- reportados» de Ronda y la misma conciliación contra el extracto.
--
-- 1. `payment_reports` sabe quién lo registró (`registered_by`), qué día dice
--    el comprobante que se pagó (`paid_on`), cuánto dice en bolívares
--    (`declared_amount_ves`) y una nota del operador.
-- 2. Bucket privado `payment-receipts` para las capturas: solo el equipo sube
--    y lee (el panel pide una URL firmada con la ruta). Nadie más.
-- 3. `admin_register_payment(...)`: operador o super admin. Cotiza con
--    `helios_quote_installments(p_user, ids, true)` —las mismas reglas de
--    Ronda: lo vencido va primero y los cargos por atraso viajan con su
--    cuota—, pero en bolívares A LA TASA DEL DÍA DEL PAGO (`paid_on`), que es
--    la que usó el paciente; crea el `payment_report` en `reported` (o
--    `in_review` si la referencia ya existe) y cuenta cuántas líneas del
--    extracto encajan. Bitácora `payment.registered`. Los avisos de cuota de
--    esas fechas se cancelan solos (trigger de 20261004000200).
-- 4. Doble control (`payment_four_eyes = 1`): quien registró un pago no puede
--    aprobarlo, salvo un super admin. Con el parámetro en 0,
--    `admin_reconcile_payment` se porta exactamente como antes.
-- 5. El cruce con el extracto mira ±5 días alrededor de la fecha del pago
--    (`paid_on`), no de la fecha en que se registró: un pago del viernes
--    registrado el lunes sigue encontrando su movimiento.
-- 6. La ficha del pago (`helios_admin_payment_item`, que leen
--    `admin_payment_queue` y `admin_payment_report`) trae quién lo registró,
--    la captura (bucket + ruta, para firmarla) y si quien mira puede
--    aprobarlo.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columnas
-- ---------------------------------------------------------------------------

alter table public.payment_reports
  add column registered_by       uuid references auth.users(id),
  add column paid_on             date,
  add column declared_amount_ves numeric(18,2) check (declared_amount_ves is null or declared_amount_ves > 0),
  add column note                text;

comment on column public.payment_reports.registered_by is
  'Quién del equipo registró el pago (admin_register_payment). Null: lo reportó la app de Ronda o nació de asignar un abono.';
comment on column public.payment_reports.paid_on is
  'El día del pago según el comprobante. El cruce con el extracto mira ±5 días alrededor de él.';
comment on column public.payment_reports.declared_amount_ves is
  'Lo que dice el comprobante en bolívares (null si fue en divisas).';

create index payment_reports_registered_by_idx on public.payment_reports (registered_by)
  where registered_by is not null;

-- ---------------------------------------------------------------------------
-- 2. Las capturas
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-receipts', 'payment-receipts', false, 10485760,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'])
on conflict (id) do nothing;

drop policy if exists payment_receipts_admin_insert on storage.objects;
drop policy if exists payment_receipts_admin_select on storage.objects;

create policy payment_receipts_admin_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'payment-receipts' and (select public.is_platform_admin()));

create policy payment_receipts_admin_select on storage.objects
  for select to authenticated
  using (bucket_id = 'payment-receipts' and (select public.is_platform_admin()));

-- ---------------------------------------------------------------------------
-- 5. El cruce con el extracto, por la fecha del pago
-- ---------------------------------------------------------------------------

create or replace function public.helios_statement_candidates(
  p_report_id     uuid,
  p_tolerance_ves numeric default 1.00,
  p_window_days   integer default 5
)
returns table (
  id                uuid,
  bank              text,
  moved_on          date,
  reference         text,
  amount_ves        numeric,
  description       text,
  difference_ves    numeric,
  discarded         boolean,
  linked            boolean,
  used_by_report_id uuid
)
language sql
stable
set search_path = public, pg_temp
as $$
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
   and abs(l.amount_ves - q.amount_ves) <= coalesce(p_tolerance_ves, 1.00)
   -- Helios: alrededor del día del pago que dice el comprobante; si no lo
   -- hay (Ronda, abonos), del día en que se reportó.
   and l.moved_on between (coalesce(r.paid_on, r.created_at::date) - coalesce(p_window_days, 5))
                      and (coalesce(r.paid_on, r.created_at::date) + coalesce(p_window_days, 5))
  where r.id = p_report_id;
$$;

-- ---------------------------------------------------------------------------
-- 6. La ficha del pago
-- ---------------------------------------------------------------------------

/** ¿`p_actor` puede aprobar el pago `p_report_id` con el doble control? */
create or replace function public.helios_can_approve_payment(p_report_id uuid, p_actor uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select not (
    public.helios_payment_four_eyes()
    and exists (select 1 from public.payment_reports r
                where r.id = p_report_id and r.registered_by = p_actor)
    and not exists (select 1 from public.platform_admins a
                    where a.user_id = p_actor and a.is_active and a.role = 'super_admin')
  );
$$;

revoke all on function public.helios_can_approve_payment(uuid, uuid) from public, anon, authenticated;

-- Copiada de la base (pg_get_functiondef, 2026-09-30) con lo del registro por
-- el equipo añadido al final y el cruce por `paid_on`.
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
        and abs(l.amount_ves - q.amount_ves) <= 1.00
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
$$;

-- ---------------------------------------------------------------------------
-- 3. Registrar un pago
-- ---------------------------------------------------------------------------

/**
 * El equipo registra un pago que el paciente mandó por WhatsApp (docs/01
 * §2.1). Operador o super admin.
 *
 * Devuelve `{report_id, quote_id, amount_usd, late_fee_usd, fx_rate,
 * amount_ves, status, candidatos_extracto}` y además `installments_usd`,
 * `installment_count`, `declared_amount_ves` y `diferencia_ves` (lo declarado
 * menos lo esperado; null si no se declaró monto en bolívares).
 */
create or replace function public.admin_register_payment(
  p_user            uuid,
  p_installment_ids uuid[],
  p_method          text,
  p_bank            text,
  p_reference       text,
  p_paid_on         date,
  p_amount_ves      numeric,
  p_receipt_path    text,
  p_note            text
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_today  date := public.helios_business_date(now());
  v_method text := lower(btrim(coalesce(p_method, '')));
  v_bank   text := nullif(btrim(coalesce(p_bank, '')), '');
  v_ref    text := nullif(btrim(coalesce(p_reference, '')), '');
  v_path   text := nullif(btrim(coalesce(p_receipt_path, '')), '');
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_quote  jsonb;
  v_q      public.payment_quotes%rowtype;
  v_rate   numeric(18,6);
  v_dup    boolean;
  v_dest   uuid;
  v_status public.payment_report_status;
  v_row    public.payment_reports%rowtype;
  v_cands  integer;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_method not in ('pago_movil', 'transferencia', 'zelle', 'usdt', 'efectivo') then
    raise exception 'Método de pago no válido: pago_movil, transferencia, zelle, usdt o efectivo'
      using errcode = '22023';
  end if;

  if v_method <> 'efectivo' and v_ref is null then
    raise exception 'La referencia es obligatoria para %', replace(v_method, '_', ' ')
      using errcode = '22023';
  end if;

  if v_method in ('pago_movil', 'transferencia') and v_bank is null then
    raise exception 'Falta el banco del pago' using errcode = '22023';
  end if;

  if p_paid_on is null then
    raise exception 'Falta la fecha del pago' using errcode = '22023';
  end if;
  if p_paid_on > v_today then
    raise exception 'La fecha del pago no puede ser posterior a hoy' using errcode = '22023';
  end if;
  if p_paid_on < v_today - 120 then
    raise exception 'La fecha del pago es de hace más de 120 días: revísala' using errcode = '22023';
  end if;

  if p_amount_ves is not null and p_amount_ves <= 0 then
    raise exception 'El monto en bolívares tiene que ser mayor que cero' using errcode = '22023';
  end if;
  if p_amount_ves is not null and p_amount_ves <> round(p_amount_ves, 2) then
    raise exception 'El monto en bolívares admite como mucho 2 decimales' using errcode = '22023';
  end if;
  if v_method in ('pago_movil', 'transferencia') and p_amount_ves is null then
    raise exception 'Falta el monto en bolívares que dice el comprobante' using errcode = '22023';
  end if;

  if v_path is not null and (v_path like '/%' or v_path like '%..%' or length(v_path) > 500) then
    raise exception 'Ruta de la captura no válida' using errcode = '22023';
  end if;

  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'Paciente no encontrado' using errcode = 'P0002';
  end if;

  -- La red de «ya hay un pago abierto» se revisa aquí, con palabras del
  -- equipo; la cotización se pide sin ella para que el resto de sus mensajes
  -- también hablen al operador y no al paciente.
  if exists (
    select 1
    from public.payment_quote_items i
    join public.payment_reports r on r.quote_id = i.quote_id
    where i.installment_id = any(coalesce(p_installment_ids, '{}'::uuid[]))
      and r.status in ('reported', 'in_review')
  ) then
    raise exception 'Alguna de esas cuotas ya tiene un pago registrado esperando aprobación'
      using errcode = '22023';
  end if;

  v_quote := public.helios_quote_installments(p_user, p_installment_ids, true);

  -- En bolívares a la tasa del día del pago, que es la que usó el paciente.
  v_rate := public.current_fx_rate('BCV', p_paid_on);
  select * into v_q from public.payment_quotes where id = (v_quote ->> 'quote_id')::uuid for update;
  if v_rate is not null and v_rate <> v_q.fx_rate then
    update public.payment_quotes
       set fx_rate = v_rate, amount_ves = round(amount_usd * v_rate, 2)
     where id = v_q.id
    returning * into v_q;
  end if;

  -- Coincidencia de referencia: sospechosa, no concluyente. Va a revisión.
  v_dup := v_ref is not null and exists (
    select 1 from public.payment_reports
    where reference = v_ref
      and coalesce(bank, '') = coalesce(v_bank, '')
      and status <> 'rejected'
  );
  v_status := case when v_dup then 'in_review' else 'reported' end;

  select id into v_dest
  from public.payment_destinations
  where is_active and method = case v_method when 'pago_movil' then 'pago_movil'
                                             when 'transferencia' then 'transferencia'
                                             when 'zelle' then 'zelle' end
  order by sort_order, created_at
  limit 1;

  insert into public.payment_reports (
    quote_id, user_id, method, bank, reference, receipt_path, status, rejection_note,
    destination_id, registered_by, paid_on, declared_amount_ves, note
  ) values (
    v_q.id, p_user, v_method, v_bank, v_ref, v_path, v_status,
    case when v_dup then 'Referencia repetida: revisar contra el estado de cuenta antes de aprobar.' end,
    v_dest, v_actor, p_paid_on, p_amount_ves, v_note
  )
  returning * into v_row;

  select count(*)::integer into v_cands
  from public.helios_statement_candidates(v_row.id) c
  where c.used_by_report_id is null and not c.discarded;

  perform audit.log(v_actor, 'payment.registered', v_row.id, jsonb_build_object(
    'user_id', p_user,
    'quote_id', v_q.id,
    'installments', to_jsonb(p_installment_ids),
    'method', v_method, 'bank', v_bank, 'reference', v_ref,
    'paid_on', p_paid_on,
    'declared_amount_ves', p_amount_ves,
    'amount_usd', v_q.amount_usd, 'amount_ves', v_q.amount_ves, 'fx_rate', v_q.fx_rate,
    'receipt_path', v_path,
    'status', v_status,
    'note', v_note
  ));

  return jsonb_build_object(
    'report_id', v_row.id,
    'quote_id', v_q.id,
    'amount_usd', v_q.amount_usd,
    'late_fee_usd', v_q.late_fee_usd,
    'installments_usd', v_q.amount_usd - v_q.late_fee_usd,
    'installment_count', v_q.installment_count,
    'fx_rate', v_q.fx_rate,
    'amount_ves', v_q.amount_ves,
    'declared_amount_ves', p_amount_ves,
    'diferencia_ves', case when p_amount_ves is not null then round(p_amount_ves - v_q.amount_ves, 2) end,
    'status', v_row.status,
    'candidatos_extracto', v_cands
  );
end;
$$;

revoke all on function public.admin_register_payment(uuid, uuid[], text, text, text, date, numeric, text, text) from public, anon;
grant execute on function public.admin_register_payment(uuid, uuid[], text, text, text, date, numeric, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Aprobar con doble control
-- ---------------------------------------------------------------------------
-- Copiada de la base (pg_get_functiondef, 2026-09-30) con el bloque del doble
-- control al principio y nada más.

create or replace function public.admin_reconcile_payment(
  p_report_id         uuid,
  p_approve           boolean,
  p_note              text default null,
  p_statement_line_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_result jsonb;
  v_cand   record;
  v_libres integer := 0;
  v_unica  uuid;
  v_linea  uuid;
  v_auto   boolean := false;
  v_quien  text;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  if not p_approve and (p_note is null or length(trim(p_note)) = 0) then
    raise exception 'Rechazar un pago requiere motivo' using errcode = '22023';
  end if;

  -- ── Helios: doble control (docs/00 §7.1) ────────────────────────────────
  if p_approve and not public.helios_can_approve_payment(p_report_id, v_actor) then
    raise exception 'Tú registraste este pago: con el doble control encendido lo aprueba otra persona del equipo'
      using errcode = '42501';
  end if;
  -- ─────────────────────────────────────────────────────────────────────────

  if p_approve then
    if p_statement_line_id is not null then
      perform 1 from public.bank_statement_lines where id = p_statement_line_id for update;
      if not found then
        raise exception 'No existe ese movimiento del extracto' using errcode = 'P0002';
      end if;

      select * into v_cand
      from public.helios_statement_candidates(p_report_id) c
      where c.id = p_statement_line_id;

      if not found then
        raise exception 'Ese movimiento del extracto no coincide con este pago: la referencia, el monto o la fecha no encajan'
          using errcode = '22023';
      end if;

      if v_cand.used_by_report_id is not null then
        select coalesce(p.full_name, 'otra persona') into v_quien
        from public.payment_reports u
        left join public.profiles p on p.id = u.user_id
        where u.id = v_cand.used_by_report_id;
        raise exception 'Ese movimiento del extracto ya respalda el pago de %', coalesce(v_quien, 'otra persona')
          using errcode = '22023';
      end if;

      if v_cand.discarded then
        raise exception 'Ese movimiento del extracto se descartó como ajeno a los usuarios'
          using errcode = '22023';
      end if;

      v_linea := p_statement_line_id;
    else
      select count(*), min(c.id::text)::uuid into v_libres, v_unica
      from public.helios_statement_candidates(p_report_id) c
      where c.used_by_report_id is null and not c.discarded;

      if v_libres = 1 then
        perform 1 from public.bank_statement_lines where id = v_unica for update;
        v_linea := v_unica;
        v_auto := true;
      elsif v_libres > 1 and (p_note is null or length(trim(p_note)) < 3) then
        raise exception 'Hay % movimientos del extracto que encajan con este pago: elige cuál lo respalda o apruébalo sin cotejo, con el motivo',
          v_libres using errcode = '22023';
      end if;
    end if;
  end if;

  v_result := public.reconcile_payment(p_report_id, v_actor, p_approve, p_note);

  if v_linea is not null then
    update public.payment_reports set statement_line_id = v_linea where id = p_report_id;

    update public.bank_statement_lines
    set status = 'asignado', resolved_by = v_actor, resolved_at = now()
    where id = v_linea and status = 'sin_dueno';
  end if;

  perform audit.log(
    v_actor,
    case when p_approve then 'payment.reconciled' else 'payment.rejected' end,
    p_report_id,
    jsonb_build_object(
      'note', p_note,
      'result', v_result,
      'statement_line_id', v_linea,
      'statement_line_auto', v_auto,
      'statement_candidates', case when p_approve and p_statement_line_id is null then v_libres end
    )
  );

  return v_result || jsonb_build_object('statement_line_id', v_linea);
end;
$$;
