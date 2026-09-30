-- ============================================================================
-- Ronda — Los abonos sin dueño
--
-- El estado de cuenta del banco se importa para **cotejar**: dado un pago que
-- alguien reportó, comprobar que existe. La pregunta contraria no se podía
-- hacer: *¿qué dinero entró que nadie ha reclamado?*
--
-- Y entra. Alguien transfiere y no reporta desde la app; alguien reporta mal la
-- referencia; alguien paga por otra persona. Ese dinero está en la cuenta de
-- Ronda, la cuota de alguien sigue vencida, y no hay ninguna pantalla donde se
-- vea que las dos cosas son la misma.
--
-- ---------------------------------------------------------------------------
-- Qué es "sin dueño"
-- ---------------------------------------------------------------------------
-- Un abono importado que **ningún pago aprobado** reclama, con el mismo cotejo
-- que ya usa la cola: sufijo de referencia, importe dentro de la tolerancia y
-- fecha dentro de la ventana. No se mira contra los reportes pendientes a
-- propósito: mientras un reporte no se apruebe, ese dinero sigue sin asignar y
-- tiene que seguir viéndose.
--
-- ---------------------------------------------------------------------------
-- Asignar es aprobar un pago, por el mismo camino
-- ---------------------------------------------------------------------------
-- No se inventa una ruta paralela para mover dinero. Asignar un abono crea la
-- misma cotización y el mismo reporte que habría creado el usuario desde la
-- app, y después llama a la conciliación de siempre. El asiento, el saldo, los
-- Bits, el aviso y la bitácora salen exactamente igual — y el día que cambie
-- la regla de aplicación de pagos, cambia para los dos caminos a la vez.
--
-- Para eso, la cotización se parte en dos: el motor, que recibe de quién es, y
-- la función de la app, que sigue siendo la de siempre y le pasa `auth.uid()`.
-- El cuerpo es el mismo texto; lo único que cambia es de dónde sale el usuario.
--
-- ---------------------------------------------------------------------------
-- Y "no es de un usuario" no mueve el libro
-- ---------------------------------------------------------------------------
-- Un depósito propio, una devolución del banco, una transferencia entre cuentas
-- de Ronda: existen y hay que poder sacarlos de la lista. Lo que NO se hace
-- aquí es inventarles un asiento: no hay cuenta contra la que asentarlos —el
-- libro tiene caja, receivable, payable, comisión y provisión, ninguna es
-- "aporte del socio"— y elegir una al azar descuadra el libro de verdad para
-- limpiar una lista. Se descarta con motivo, queda en la bitácora, y el asiento
-- lo decide el contador cuando haya contra qué asentarlo.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El abono tiene estado
-- ---------------------------------------------------------------------------

do $do$
begin
  if not exists (select 1 from pg_type where typname = 'deposit_status') then
    create type public.deposit_status as enum ('sin_dueno', 'asignado', 'descartado');
  end if;
end
$do$;

alter table public.bank_statement_lines
  add column if not exists status public.deposit_status not null default 'sin_dueno';

alter table public.bank_statement_lines
  add column if not exists resolved_by uuid references auth.users (id);

alter table public.bank_statement_lines
  add column if not exists resolved_at timestamptz;

alter table public.bank_statement_lines
  add column if not exists resolution_note text;

alter table public.bank_statement_lines
  add column if not exists report_id uuid references public.payment_reports (id);

comment on column public.bank_statement_lines.status is
  'sin_dueno: nadie lo ha reclamado. asignado: se aplico a las cuotas de alguien desde el panel. descartado: no era de un usuario. El cotejo automatico contra pagos aprobados manda por encima de sin_dueno.';

create index if not exists bank_statement_lines_status_idx
  on public.bank_statement_lines (status) where status = 'sin_dueno';

-- ---------------------------------------------------------------------------
-- 2. El motor de la cotización, con el usuario como parámetro
-- ---------------------------------------------------------------------------

create or replace function public.helios_quote_installments(
  p_user               uuid,
  p_installment_ids    uuid[],
  p_ignore_open_report boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user       uuid := p_user;
  v_rate       numeric(18,6);
  v_total_usd  numeric(18,4);
  v_count      integer;
  v_fee_ids    uuid[];
  v_fee_usd    numeric(18,4) := 0;
  v_grand_usd  numeric(18,4);
  v_quote      public.payment_quotes%rowtype;
begin
  if v_user is null then
    raise exception 'Falta de quién es el pago' using errcode = '22023';
  end if;

  if p_installment_ids is null or array_length(p_installment_ids, 1) is null then
    raise exception 'Selecciona al menos una cuota' using errcode = '22023';
  end if;

  -- Solo cuotas propias y pendientes. Si el cliente manda una ajena o ya
  -- pagada, no se cotiza a medias: se rechaza entero.
  select coalesce(sum(amount_usd), 0), count(*)
    into v_total_usd, v_count
  from public.installments
  where id = any(p_installment_ids)
    and user_id = v_user
    and status = 'pending';

  if v_count <> array_length(p_installment_ids, 1) then
    raise exception 'Alguna de las cuotas no es tuya o ya está pagada'
      using errcode = '22023';
  end if;

  -- Cuota con un pago ya reportado y sin conciliar. Se corta AQUÍ, en la
  -- cotización, y no al reportar: entre una cosa y la otra el usuario hace la
  -- transferencia, y negarle el reporte con el dinero ya enviado es el peor
  -- momento posible para decirle que no hacía falta pagar.
  if not p_ignore_open_report and exists (
    select 1
    from public.payment_quote_items i
    join public.payment_reports r on r.quote_id = i.quote_id
    where i.installment_id = any(p_installment_ids)
      and r.user_id = v_user
      and r.status in ('reported', 'in_review')
  ) then
    raise exception
      'Ya reportaste un pago para alguna de esas cuotas y está en revisión. Te avisamos en cuanto lo confirmemos.'
      using errcode = '22023';
  end if;

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- Los cargos de las cuotas elegidas, más los huérfanos. Se guardan los ids
  -- para no repetir el predicado al escribir el enlace.
  select coalesce(array_agg(f.id), '{}'::uuid[]), coalesce(sum(f.amount_usd), 0)
    into v_fee_ids, v_fee_usd
  from public.late_fees f
  left join public.installments i on i.id = f.installment_id
  where f.user_id = v_user
    and f.status = 'pending'
    and (
      f.installment_id = any(p_installment_ids)
      or f.installment_id is null
      or i.status <> 'pending'
    );

  v_grand_usd := v_total_usd + v_fee_usd;
  -- ─────────────────────────────────────────────────────────────────────────

  v_rate := public.current_fx_rate();
  if v_rate is null then
    raise exception 'No hay tasa de cambio vigente' using errcode = 'P0002';
  end if;

  insert into public.payment_quotes
    (user_id, amount_usd, fx_rate, amount_ves, installment_count, valid_until,
     late_fee_usd)
  values (
    v_user,
    v_grand_usd,
    v_rate,
    round(v_grand_usd * v_rate, 2),
    v_count,
    -- Fin del día calendario en Caracas (docs/05 §1): el BCV publica una vez
    -- al día, así que una cotización de la tarde sigue viva esa noche.
    (date_trunc('day', now() at time zone 'America/Caracas') + interval '1 day')
      at time zone 'America/Caracas',
    v_fee_usd
  )
  returning * into v_quote;

  insert into public.payment_quote_items (quote_id, installment_id, amount_usd)
  select v_quote.id, id, amount_usd
  from public.installments
  where id = any(p_installment_ids);

  -- NUEVO: el detalle de los cargos, con su importe congelado.
  insert into public.payment_quote_late_fees (quote_id, late_fee_id, amount_usd)
  select v_quote.id, f.id, f.amount_usd
  from public.late_fees f
  where f.id = any(v_fee_ids);

  return jsonb_build_object(
    'quote_id', v_quote.id,
    'amount_usd', v_quote.amount_usd,
    'fx_rate', v_quote.fx_rate,
    'amount_ves', v_quote.amount_ves,
    'installment_count', v_quote.installment_count,
    -- Partido, para que la pantalla pueda enseñar los cargos en su propia
    -- línea sin restar dos cifras que ya sabe el servidor.
    'installments_usd', v_total_usd,
    'late_fee_usd', v_quote.late_fee_usd,
    -- NUEVO: cuántos son. Es lo que deja escribir "2 cargos por mora" en vez de
    -- una cifra suelta que ya no se explica sola.
    'late_fee_count', coalesce(array_length(v_fee_ids, 1), 0),
    'valid_until', v_quote.valid_until,
    'destination', (
      select jsonb_build_object(
        'bank_name', bank_name, 'rif', rif, 'phone', phone, 'holder_name', holder_name
      )
      from public.payment_destinations where is_active limit 1
    )
  );
end;
$$;

revoke all on function public.helios_quote_installments(uuid, uuid[], boolean)
  from public, anon, authenticated;

-- Y la de siempre, que es la que llama la app.
create or replace function public.quote_installments(p_installment_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  return public.helios_quote_installments(auth.uid(), p_installment_ids, false);
end;
$$;

revoke all on function public.quote_installments(uuid[]) from public, anon;
grant execute on function public.quote_installments(uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Qué entró que nadie ha reclamado
-- ---------------------------------------------------------------------------

create or replace function public.admin_unmatched_deposits(
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
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
        select 1
        from public.payment_reports pr
        join public.payment_quotes pq on pq.id = pr.quote_id
        where pr.status = 'reconciled'
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
$$;

comment on function public.admin_unmatched_deposits(integer) is
  'Abonos del banco que ningun pago APROBADO reclama. Los reportes pendientes no cuentan: mientras no se aprueben, ese dinero sigue sin asignar.';

revoke all on function public.admin_unmatched_deposits(integer) from public, anon;
grant execute on function public.admin_unmatched_deposits(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Asignarlo a las cuotas de alguien
-- ---------------------------------------------------------------------------

create or replace function public.admin_assign_deposit(
  p_line_id         uuid,
  p_user_id         uuid,
  p_installment_ids uuid[],
  p_note            text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
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
    (user_id, quote_id, method, bank, reference, status)
  values (
    p_user_id,
    (v_quote->>'quote_id')::uuid,
    'transferencia',
    v_line.bank,
    v_line.reference,
    'reported'
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
$$;

comment on function public.admin_assign_deposit(uuid, uuid, uuid[], text) is
  'Aplica un abono sin dueno a las cuotas de una persona. Crea la misma cotizacion y el mismo reporte que habria creado ella desde la app y llama a la conciliacion de siempre: un solo camino para mover dinero.';

revoke all on function public.admin_assign_deposit(uuid, uuid, uuid[], text) from public, anon;
grant execute on function public.admin_assign_deposit(uuid, uuid, uuid[], text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. O descartarlo, con motivo
-- ---------------------------------------------------------------------------

create or replace function public.admin_discard_deposit(
  p_line_id uuid,
  p_reason  text
)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_line  public.bank_statement_lines%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'Descartar un abono requiere motivo' using errcode = '22023';
  end if;

  select * into v_line from public.bank_statement_lines
  where id = p_line_id for update;

  if not found then
    raise exception 'No existe ese abono' using errcode = 'P0002';
  end if;

  if v_line.status <> 'sin_dueno' then
    raise exception 'Ese abono ya se resolvió' using errcode = '22023';
  end if;

  update public.bank_statement_lines
  set status = 'descartado',
      resolved_by = v_actor,
      resolved_at = now(),
      resolution_note = trim(p_reason)
  where id = p_line_id;

  perform audit.log(v_actor, 'deposit.discarded', p_line_id, jsonb_build_object(
    'bank', v_line.bank,
    'reference', v_line.reference,
    'amount_ves', v_line.amount_ves,
    'reason', trim(p_reason)
  ));
end;
$$;

comment on function public.admin_discard_deposit(uuid, text) is
  'Saca un abono de la lista de sin dueno: un deposito propio, una devolucion. NO escribe asiento: no hay cuenta contra la que asentarlo y elegir una al azar descuadraria el libro.';

revoke all on function public.admin_discard_deposit(uuid, text) from public, anon;
grant execute on function public.admin_discard_deposit(uuid, text) to authenticated;
