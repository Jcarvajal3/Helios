-- ============================================================================
-- Ronda — Cada aprobación guarda el movimiento del extracto que la respaldó
--
-- Al aprobar un pago reportado, el panel enseña los movimientos del extracto
-- que encajan (referencia, monto ±1 Bs y fecha ±5 días), pero la base no
-- guardaba cuál vio el operador. Dos consecuencias:
--   · un mismo movimiento podía respaldar dos pagos aprobados (dos personas
--     que reportan la misma referencia, o el mismo pago reportado dos veces);
--   · la salud de la conciliación contaba como «con respaldo» lo que coincide
--     HOY con el extracto, no lo que se miró al aprobar.
--
-- Decisión de Javier (2026-09-25):
--   · `payment_reports.statement_line_id`: la línea que respaldó la
--     aprobación, única entre los pagos (una línea respalda un pago, no dos);
--   · `admin_reconcile_payment` gana `p_statement_line_id` (al final, con
--     default): con un único candidato libre se liga solo; si se pasa uno, se
--     valida; con varios y ninguno elegido, solo se aprueba «sin cotejo», con
--     motivo;
--   · la línea ligada pasa a `asignado`: ya tiene dueño y deja de salir en
--     Abonos sin dueño. `bank_statement_lines.report_id` sigue significando
--     «el pago nació de asignar este abono»;
--   · `admin_statement_matches` dice qué candidatos ya están usados y por qué
--     pago; la cola y la ficha devuelven la línea ligada; la salud cuenta como
--     cotejo lo ligado al aprobar.
--
-- Retrocompatible: la llamada vieja sin `p_statement_line_id` sigue valiendo y
-- ningún campo se quita. Los pagos aprobados antes de esto no tienen línea
-- (no se sabe cuál miró nadie), salvo los nacidos de asignar un abono, que se
-- rellenan con su abono.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- La columna, su índice y el relleno
-- ---------------------------------------------------------------------------

alter table public.payment_reports
  add column if not exists statement_line_id uuid references public.bank_statement_lines (id);

comment on column public.payment_reports.statement_line_id is
  'El movimiento del extracto que respaldó la aprobación. Único: una línea no respalda dos pagos.';

create unique index if not exists payment_reports_statement_line_once
  on public.payment_reports (statement_line_id)
  where statement_line_id is not null;

-- Los nacidos de asignar un abono: su respaldo es ese abono, por construcción.
update public.payment_reports r
set statement_line_id = l.id
from public.bank_statement_lines l
where l.report_id = r.id
  and r.statement_line_id is null
  and not exists (
    select 1 from public.payment_reports r2 where r2.statement_line_id = l.id
  );

-- ---------------------------------------------------------------------------
-- Los candidatos de un pago, en un solo sitio
-- ---------------------------------------------------------------------------
-- El criterio de siempre (el de `statement_matches` de la cola): la referencia
-- del movimiento termina en la del pago, el monto cuadra con la cotización en
-- bolívares (±tolerancia) y la fecha cae a ±N días del reporte. Además dice
-- si el movimiento ya respalda OTRO pago (`used_by_report_id`), si se
-- descartó y si es el que respalda a este.

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
as $fn$
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
   and l.moved_on between (r.created_at::date - coalesce(p_window_days, 5))
                      and (r.created_at::date + coalesce(p_window_days, 5))
  where r.id = p_report_id;
$fn$;

comment on function public.helios_statement_candidates(uuid, numeric, integer) is
  'Los movimientos del extracto que encajan con un pago reportado, con si ya respaldan otro pago. Interna: la usan admin_statement_matches y admin_reconcile_payment.';

revoke all on function public.helios_statement_candidates(uuid, numeric, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Los candidatos que ve el panel
-- ---------------------------------------------------------------------------
-- Misma firma y mismos campos de antes; cada movimiento gana `available`,
-- `linked`, `discarded` y `used_by` (a quién respalda ya).

create or replace function public.admin_statement_matches(
  p_report_id     uuid,
  p_tolerance_ves numeric default 1.00,
  p_window_days   integer default 5
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  if not exists (select 1 from public.payment_reports where id = p_report_id) then
    raise exception 'Reporte no encontrado' using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id,
      'bank', c.bank,
      'moved_on', c.moved_on,
      'reference', c.reference,
      'amount_ves', c.amount_ves,
      'description', c.description,
      'difference_ves', c.difference_ves,
      -- Se puede elegir para respaldar este pago.
      'available', c.used_by_report_id is null and not c.discarded,
      -- Es el que ya respalda a este pago.
      'linked', c.linked,
      'discarded', c.discarded,
      'used_by', case when c.used_by_report_id is not null then jsonb_build_object(
        'report_id', u.id,
        'user_id', u.user_id,
        'full_name', p.full_name,
        'status', u.status::text
      ) end
    ) order by c.moved_on desc, c.id), '[]'::jsonb)
  into v_rows
  from public.helios_statement_candidates(p_report_id, p_tolerance_ves, p_window_days) c
  left join public.payment_reports u on u.id = c.used_by_report_id
  left join public.profiles p on p.id = u.user_id;

  return v_rows;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Aprobar o rechazar, con el movimiento que respalda la aprobación
-- ---------------------------------------------------------------------------

drop function if exists public.admin_reconcile_payment(uuid, boolean, text);

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
as $fn$
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

  if p_approve then
    if p_statement_line_id is not null then
      -- El elegido: bloqueado, para que dos aprobaciones a la vez no lo usen
      -- las dos. El índice único es la última red.
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
        -- Un único candidato libre: es ese, y se guarda sin preguntar.
        perform 1 from public.bank_statement_lines where id = v_unica for update;
        v_linea := v_unica;
        v_auto := true;
      elsif v_libres > 1 and (p_note is null or length(trim(p_note)) < 3) then
        -- Con varios, elegir es el trabajo de quien aprueba. Sin elegir, solo
        -- por el camino de «aprobar sin cotejo», que deja el motivo escrito.
        raise exception 'Hay % movimientos del extracto que encajan con este pago: elige cuál lo respalda o apruébalo sin cotejo, con el motivo',
          v_libres using errcode = '22023';
      end if;
    end if;
  end if;

  v_result := public.reconcile_payment(p_report_id, v_actor, p_approve, p_note);

  if v_linea is not null then
    update public.payment_reports set statement_line_id = v_linea where id = p_report_id;

    -- Ya tiene dueño: deja de ser un abono sin dueño. `report_id` no se toca,
    -- porque dice que el pago NACIÓ de asignar el abono, y este no.
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
$fn$;

revoke all on function public.admin_reconcile_payment(uuid, boolean, text, uuid) from public, anon;
grant execute on function public.admin_reconcile_payment(uuid, boolean, text, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Abonos sin dueño: sin las líneas que ya respaldan un pago
-- ---------------------------------------------------------------------------
-- La línea ligada pasa a `asignado` y ya no es `sin_dueno`; además se excluye
-- por la columna, por si alguna quedó ligada sin cambiar de estado. La
-- sospecha por coincidencia con un pago aprobado se queda para los aprobados
-- SIN línea (los de antes de esto).

create or replace function public.admin_unmatched_deposits(p_limit integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.moved_on desc), '[]'::jsonb)
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
      -- En euros a la tasa de ESE día, no a la de hoy: el abono entró con la
      -- tasa de su fecha y volver a convertirlo con otra inventa una
      -- diferencia que no existió.
      (
        select round(l.amount_ves / r.rate, 2)
        from public.exchange_rates r
        where r.effective_date <= l.moved_on
        order by r.effective_date desc
        limit 1
      ) as amount_usd
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
          and abs(l.amount_ves - pq.amount_ves) <= 1.00
          and l.moved_on between (pr.created_at::date - 5) and (pr.created_at::date + 5)
      )
    order by l.moved_on desc
    limit least(coalesce(p_limit, 100), 500)
  ) q;

  return v_rows;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Asignar un abono: el pago que nace de él queda ligado a él
-- ---------------------------------------------------------------------------
-- El cuerpo es el de siempre; solo cambia el insert del reporte.

create or replace function public.admin_assign_deposit(p_line_id uuid, p_user_id uuid, p_installment_ids uuid[], p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor   uuid := auth.uid();
  v_line    public.bank_statement_lines%rowtype;
  v_quote   jsonb;
  v_report  public.payment_reports%rowtype;
  v_result  jsonb;
  v_name    text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_line from public.bank_statement_lines
  where id = p_line_id for update;

  if not found then
    raise exception 'No existe ese abono' using errcode = 'P0002';
  end if;

  if v_line.status <> 'sin_dueno' then
    raise exception 'Ese abono ya se resolvió' using errcode = '22023';
  end if;

  select full_name into v_name from public.profiles where id = p_user_id;
  if not found then
    raise exception 'No existe esa persona' using errcode = '22023';
  end if;

  -- La cotización, por el mismo camino que la app. Se ignora la red de
  -- "ya hay un reporte abierto": el dinero ya entró al banco, y lo que toca
  -- es aplicarlo.
  v_quote := public.helios_quote_installments(p_user_id, p_installment_ids, true);

  -- El reporte, con los datos del banco y no con los que escribió nadie: es
  -- la diferencia entre asignar un abono real y registrar una afirmación.
  insert into public.payment_reports
    (user_id, quote_id, method, bank, reference, status, statement_line_id)
  values (
    p_user_id,
    (v_quote->>'quote_id')::uuid,
    'transferencia',
    v_line.bank,
    v_line.reference,
    'reported',
    -- Su respaldo es el propio abono: nadie más puede usarlo.
    p_line_id
  )
  returning * into v_report;

  -- Y se concilia con la función de siempre.
  v_result := public.reconcile_payment(v_report.id, v_actor, true, p_note);

  update public.bank_statement_lines
  set status = 'asignado',
      resolved_by = v_actor,
      resolved_at = now(),
      resolution_note = nullif(trim(coalesce(p_note, '')), ''),
      report_id = v_report.id
  where id = p_line_id;

  perform audit.log(v_actor, 'deposit.assigned', p_line_id, jsonb_build_object(
    'user_id', p_user_id,
    'full_name', v_name,
    'bank', v_line.bank,
    'reference', v_line.reference,
    'amount_ves', v_line.amount_ves,
    'amount_usd', v_quote->>'amount_usd',
    'installments', array_length(p_installment_ids, 1),
    'note', p_note
  ));

  return jsonb_build_object(
    'report_id', v_report.id,
    'quote', v_quote,
    'result', v_result
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- La cola y la ficha de un pago: la línea que lo respaldó
-- ---------------------------------------------------------------------------
-- Gana `statement_line` (null si no se ligó ninguna) y
-- `statement_matches_available`. `statement_matches` sigue contando todos los
-- que encajan, para el panel de `main`.

create or replace function public.helios_admin_payment_item(p_report_id uuid, p_today date)
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
  where r.id = p_report_id
$function$;

-- ---------------------------------------------------------------------------
-- La salud de la conciliación: cotejo es lo ligado al aprobar
-- ---------------------------------------------------------------------------
-- `approved_matched` y `match_pct` (y los de `by_method`) cuentan los
-- aprobados con una línea ligada. `rejected_matched` sigue con la
-- coincidencia de hoy. La forma del JSON no cambia.

create or replace function public.admin_reconciliation_health(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
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

  v_from_ts := (v_from::timestamp + interval '10 hours') at time zone 'America/Caracas';
  v_to_ts   := ((v_to + 1)::timestamp + interval '10 hours') at time zone 'America/Caracas';

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
          and abs(l.amount_ves - b.amount_ves) <= 1.00
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
