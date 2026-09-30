-- ============================================================================
-- Ronda — Un pago ya aprobado se liga a su movimiento del extracto
--
-- Un pago se aprueba antes de importar el extracto del día, o con la
-- referencia mal escrita, y queda aprobado sin movimiento ligado. Cuando luego
-- llega el extracto, el movimiento sale en «Abonos sin dueño» y solo se podía
-- ASIGNAR (crea un pago nuevo y cobra las cuotas otra vez) o DESCARTAR (dice
-- que ese dinero no es de nadie). Caso real (2026-09-28): dos pagos que
-- reportaron como referencia `001119`, las cifras iniciales del comprobante,
-- cuando en el banco eran `1119488724` y `1119542843`.
--
--   admin_link_candidates        los movimientos que pueden respaldar un pago
--                                aprobado: por monto y fecha, con cualquier
--                                referencia, también los descartados
--   admin_link_reports_for_line  lo contrario: los pagos aprobados sin
--                                movimiento que un abono puede respaldar
--   admin_link_statement_line    liga los dos
--
-- Ligar NO mueve dinero: el pago ya se aplicó al aprobarlo. Solo escribe
-- `payment_reports.statement_line_id`, pasa el movimiento a `asignado` y deja
-- la bitácora. El criterio de monto y fecha es el de siempre (±1 Bs contra la
-- cotización, ±5 días del reporte); la referencia puede no coincidir, y
-- entonces el motivo es obligatorio. Recuperar un descartado también lo pide.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Los movimientos que pueden respaldar un pago aprobado
-- ---------------------------------------------------------------------------

create or replace function public.admin_link_candidates(
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
      on abs(l.amount_ves - q.amount_ves) <= coalesce(p_tolerance_ves, 1.00)
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
$fn$;

comment on function public.admin_link_candidates(uuid, numeric, integer) is
  'Los movimientos del extracto que pueden respaldar un pago ya aprobado: por monto (±1 Bs) y fecha (±5 días), con cualquier referencia, descartados incluidos.';

revoke all on function public.admin_link_candidates(uuid, numeric, integer) from public, anon;
grant execute on function public.admin_link_candidates(uuid, numeric, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Los pagos aprobados sin movimiento que un abono puede respaldar
-- ---------------------------------------------------------------------------

create or replace function public.admin_link_reports_for_line(
  p_line_id       uuid,
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
      and abs(l.amount_ves - q.amount_ves) <= coalesce(p_tolerance_ves, 1.00)
      and l.moved_on between (r.created_at::date - coalesce(p_window_days, 5))
                         and (r.created_at::date + coalesce(p_window_days, 5))
  ) c;

  return v_rows;
end;
$fn$;

comment on function public.admin_link_reports_for_line(uuid, numeric, integer) is
  'Los pagos aprobados sin movimiento del extracto que un abono puede respaldar: por monto (±1 Bs) y fecha (±5 días), con cualquier referencia.';

revoke all on function public.admin_link_reports_for_line(uuid, numeric, integer) from public, anon;
grant execute on function public.admin_link_reports_for_line(uuid, numeric, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Ligar
-- ---------------------------------------------------------------------------

create or replace function public.admin_link_statement_line(
  p_report_id uuid,
  p_line_id   uuid,
  p_note      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor    uuid := auth.uid();
  v_report   public.payment_reports%rowtype;
  v_line     public.bank_statement_lines%rowtype;
  v_quote    public.payment_quotes%rowtype;
  v_note     text := nullif(trim(coalesce(p_note, '')), '');
  v_ref_ok   boolean;
  v_quien    text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_report from public.payment_reports where id = p_report_id for update;
  if not found then
    raise exception 'Reporte no encontrado' using errcode = 'P0002';
  end if;

  if v_report.status <> 'reconciled' then
    raise exception 'Solo se liga un movimiento del extracto a un pago aprobado' using errcode = '22023';
  end if;

  if v_report.statement_line_id is not null then
    raise exception 'Este pago ya tiene un movimiento del extracto ligado' using errcode = '22023';
  end if;

  select * into v_line from public.bank_statement_lines where id = p_line_id for update;
  if not found then
    raise exception 'No existe ese movimiento del extracto' using errcode = 'P0002';
  end if;

  select coalesce(p.full_name, 'otra persona') into v_quien
  from public.payment_reports u
  left join public.profiles p on p.id = u.user_id
  where u.id <> v_report.id
    and (u.statement_line_id = v_line.id or u.id = v_line.report_id)
  limit 1;

  if v_quien is not null then
    raise exception 'Ese movimiento del extracto ya respalda el pago de %', v_quien using errcode = '22023';
  end if;

  select * into v_quote from public.payment_quotes where id = v_report.quote_id;

  if abs(v_line.amount_ves - v_quote.amount_ves) > 1.00 then
    raise exception 'El monto del movimiento (% Bs) no cuadra con el del pago (% Bs)',
      v_line.amount_ves, v_quote.amount_ves using errcode = '22023';
  end if;

  if v_line.moved_on not between (v_report.created_at::date - 5) and (v_report.created_at::date + 5) then
    raise exception 'El movimiento es del %, a más de cinco días del reporte', v_line.moved_on using errcode = '22023';
  end if;

  v_ref_ok := v_report.reference is not null and v_line.reference like '%' || v_report.reference;

  if (not v_ref_ok or v_line.status = 'descartado') and (v_note is null or length(v_note) < 3) then
    raise exception '%', case
      when v_line.status = 'descartado' then 'Recuperar un movimiento descartado requiere motivo'
      else 'La referencia no coincide con la del pago: escribe el motivo'
    end using errcode = '22023';
  end if;

  update public.payment_reports set statement_line_id = v_line.id where id = v_report.id;

  -- `report_id` no se toca: dice que el pago NACIÓ de asignar el abono, y este no.
  update public.bank_statement_lines
  set status = 'asignado',
      resolved_by = v_actor,
      resolved_at = now(),
      resolution_note = v_note
  where id = v_line.id;

  perform audit.log(v_actor, 'payment.statement_linked', v_report.id, jsonb_build_object(
    'statement_line_id', v_line.id,
    'bank', v_line.bank,
    'line_reference', v_line.reference,
    'report_reference', v_report.reference,
    'reference_matches', v_ref_ok,
    'amount_ves', v_line.amount_ves,
    'moved_on', v_line.moved_on,
    'previous_status', v_line.status::text,
    'previous_note', v_line.resolution_note,
    'note', v_note
  ));

  return jsonb_build_object(
    'report_id', v_report.id,
    'statement_line_id', v_line.id,
    'reference_matches', v_ref_ok,
    'recovered', v_line.status = 'descartado'
  );
end;
$fn$;

comment on function public.admin_link_statement_line(uuid, uuid, text) is
  'Liga un movimiento del extracto a un pago ya aprobado que no tenía ninguno. No mueve dinero. Motivo obligatorio si la referencia no coincide o si el movimiento estaba descartado.';

revoke all on function public.admin_link_statement_line(uuid, uuid, text) from public, anon;
grant execute on function public.admin_link_statement_line(uuid, uuid, text) to authenticated;
