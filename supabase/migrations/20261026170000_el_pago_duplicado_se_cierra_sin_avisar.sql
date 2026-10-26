-- ============================================================================
-- Helios — El pago duplicado se cierra sin avisar al paciente, y asignar un
-- abono no crea otro (Javier, 2026-10-26)
--
-- Andrea Valeska Toledo Hurtado quedó con dos pagos para la misma cuota: el
-- que registró el equipo (pendiente) y el que nació al asignar el abono «sin
-- dueño» del extracto (aprobado). El pendiente no se podía cerrar sin
-- molestarla: rechazarlo le manda «No pudimos confirmar el pago…».
--
--  1. `admin_mark_payment_duplicate`: cierra un pago pendiente como
--     «duplicado», con motivo y bitácora. `notify_payment_result` solo avisa
--     de los aprobados y los rechazados: al paciente no le llega nada.
--  2. `admin_assign_deposit` (la definición viva, de 20260925145000): si las
--     cuotas elegidas ya tienen un pago pendiente que salda exactamente esas
--     cuotas, se aprueba ESE pago con el abono en vez de crear otro. Si el
--     pendiente salda también otras, no se adivina: se pide cerrarlo desde su
--     ficha.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Marcar como duplicado
-- ---------------------------------------------------------------------------

create or replace function public.admin_mark_payment_duplicate(p_report_id uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_r     public.payment_reports%rowtype;
  v_nota  text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_nota is null or length(v_nota) < 3 then
    raise exception 'Marcar un pago como duplicado pide el motivo' using errcode = '22023';
  end if;

  select * into v_r from public.payment_reports where id = p_report_id for update;
  if not found then
    raise exception 'No existe ese pago' using errcode = 'P0002';
  end if;
  if v_r.status not in ('reported', 'in_review') then
    raise exception 'Este pago ya se resolvió (%)', v_r.status using errcode = '22023';
  end if;

  -- Como un rechazo (quién, cuándo y por qué), sin el aviso al paciente.
  update public.payment_reports
     set status = 'duplicate', reviewed_by = v_actor, reviewed_at = now(),
         rejection_note = 'Duplicado: ' || v_nota
   where id = v_r.id;

  perform audit.log(v_actor, 'payment.marked_duplicate', v_r.id, jsonb_build_object(
    'user_id', v_r.user_id,
    'reference', v_r.reference,
    'from_status', v_r.status,
    'note', v_nota
  ));

  return jsonb_build_object('ok', true, 'report_id', v_r.id, 'status', 'duplicate');
end;
$$;

revoke all on function public.admin_mark_payment_duplicate(uuid, text) from public, anon;
grant execute on function public.admin_mark_payment_duplicate(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Asignar un abono sin duplicar
-- ---------------------------------------------------------------------------

create or replace function public.admin_assign_deposit(
  p_line_id uuid, p_user_id uuid, p_installment_ids uuid[], p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $function$
declare
  v_actor    uuid := auth.uid();
  v_line     public.bank_statement_lines%rowtype;
  v_quote    jsonb;
  v_report   public.payment_reports%rowtype;
  v_result   jsonb;
  v_name     text;
  v_abiertos uuid[];
  v_reusado  boolean := false;
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

  -- NUEVO (2026-10-26): los pagos pendientes de esas cuotas.
  select array_agg(distinct r.id) into v_abiertos
  from public.payment_quote_items qi
  join public.payment_reports r on r.quote_id = qi.quote_id
  where qi.installment_id = any(p_installment_ids)
    and r.user_id = p_user_id
    and r.status in ('reported', 'in_review');

  if v_abiertos is not null then
    -- Uno solo y que salde justo esas cuotas: es el mismo pago. Se aprueba
    -- ese con el abono como respaldo, en vez de crear otro.
    if array_length(v_abiertos, 1) > 1 or (
      select array_agg(qi.installment_id order by qi.installment_id)
      from public.payment_reports r
      join public.payment_quote_items qi on qi.quote_id = r.quote_id
      where r.id = v_abiertos[1]
    ) is distinct from (
      select array_agg(distinct x order by x) from unnest(p_installment_ids) x
    ) then
      raise exception 'Esas cuotas ya tienen un pago registrado pendiente que salda otras cuotas: ciérralo desde su ficha en Pagos reportados'
        using errcode = '22023';
    end if;

    select * into v_report from public.payment_reports where id = v_abiertos[1] for update;
    update public.payment_reports set statement_line_id = p_line_id where id = v_report.id;
    v_reusado := true;
  else
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
  end if;

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
    'amount_usd', coalesce(v_quote->>'amount_usd',
                           (select q.amount_usd::text from public.payment_quotes q where q.id = v_report.quote_id)),
    'installments', array_length(p_installment_ids, 1),
    'note', p_note,
    -- El pago pendiente que se aprobó con el abono, en vez de crear otro.
    'closed_open_report', case when v_reusado then v_report.id end
  ));

  return jsonb_build_object(
    'report_id', v_report.id,
    'reused_open_report', v_reusado,
    'quote', v_quote,
    'result', v_result
  );
end;
$function$;
