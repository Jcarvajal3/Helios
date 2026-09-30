-- ============================================================================
-- Ronda — Importador de estados de cuenta y cotejo automático
--
-- docs/01-ARQUITECTURA.md §8 lo llama el mayor costo operativo oculto: sin
-- esto, alguien compara a mano cada reporte de pago contra el estado de
-- cuenta del banco, todas las noches.
--
-- Además es la mitigación del problema de la referencia corta (§3.7): la app
-- solo pide los últimos 6 dígitos, así que una coincidencia de referencia
-- entre dos reportes es sospecha y no prueba. Cotejar contra el movimiento
-- real del banco —referencia + monto + fecha— sí es prueba.
--
-- El importador es agnóstico al formato: el panel parsea el CSV/XLSX del
-- banco que sea y manda filas normalizadas. Aquí solo se guardan y se cotejan.
-- ============================================================================

create table if not exists public.bank_statement_lines (
  id            uuid primary key default gen_random_uuid(),
  bank          text not null,
  -- Fecha del movimiento según el banco.
  moved_on      date not null,
  -- Referencia COMPLETA tal como la da el banco. El cotejo usa el sufijo,
  -- porque el usuario solo reporta los últimos dígitos.
  reference     text not null,
  amount_ves    numeric(18,2) not null check (amount_ves > 0),
  description   text,
  -- Para no importar dos veces la misma línea si se vuelve a subir el mismo
  -- archivo: el banco no da un id estable, así que se deriva del contenido.
  fingerprint   text not null,
  imported_by   uuid not null references auth.users (id),
  imported_at   timestamptz not null default now(),
  unique (fingerprint)
);

comment on table public.bank_statement_lines is
  'Movimientos del estado de cuenta. Solo entradas: lo que sale se registra en merchant_payouts.';

create index bank_lines_lookup_idx
  on public.bank_statement_lines (bank, moved_on);

-- El cotejo busca por sufijo de referencia, así que se indexa al revés.
create index bank_lines_reference_rev_idx
  on public.bank_statement_lines (reverse(reference));

alter table public.bank_statement_lines enable row level security;

create policy "bank_lines_read_admin"
  on public.bank_statement_lines for select to authenticated
  using (public.is_platform_admin());

grant select on public.bank_statement_lines to authenticated;

-- ---------------------------------------------------------------------------
-- Importar
-- ---------------------------------------------------------------------------

/**
 * Recibe las filas ya normalizadas por el panel.
 *
 * Idempotente por huella: volver a subir el mismo archivo no duplica nada, y
 * subir un archivo que solapa con otro anterior solo añade lo nuevo. Es
 * importante porque el operador va a exportar rangos que se pisan.
 */
create or replace function public.admin_import_statement(
  p_bank  text,
  p_lines jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor    uuid := auth.uid();
  v_inserted integer;
  v_total    integer;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'El archivo no trae movimientos' using errcode = '22023';
  end if;

  v_total := jsonb_array_length(p_lines);

  with incoming as (
    select
      p_bank                                as bank,
      (x->>'moved_on')::date                as moved_on,
      trim(x->>'reference')                 as reference,
      (x->>'amount_ves')::numeric(18,2)     as amount_ves,
      nullif(trim(coalesce(x->>'description', '')), '') as description,
      -- La huella es el contenido del movimiento. Dos movimientos idénticos
      -- el mismo día por el mismo importe y referencia son, en la práctica,
      -- la misma línea reimportada.
      encode(extensions.digest(
        p_bank || '|' || (x->>'moved_on') || '|' || trim(x->>'reference')
          || '|' || (x->>'amount_ves'),
        'sha256'
      ), 'hex')                             as fingerprint
    from jsonb_array_elements(p_lines) x
  )
  insert into public.bank_statement_lines
    (bank, moved_on, reference, amount_ves, description, fingerprint, imported_by)
  select bank, moved_on, reference, amount_ves, description, fingerprint, v_actor
  from incoming
  where reference is not null and reference <> '' and amount_ves > 0
  on conflict (fingerprint) do nothing;

  get diagnostics v_inserted = row_count;

  perform audit.log(v_actor, 'statement.imported', null,
    jsonb_build_object('bank', p_bank, 'lines', v_total, 'inserted', v_inserted));

  return jsonb_build_object(
    'ok', true,
    'received', v_total,
    'inserted', v_inserted,
    'duplicates', v_total - v_inserted
  );
end;
$$;

revoke all on function public.admin_import_statement(text, jsonb) from public, anon;
grant execute on function public.admin_import_statement(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Cotejo
-- ---------------------------------------------------------------------------

/**
 * Movimientos del banco compatibles con un reporte de pago.
 *
 * Tres condiciones a la vez, y por eso el cotejo es fuerte aunque la
 * referencia sea corta:
 *   * la referencia del banco TERMINA en la que reportó el usuario,
 *   * el monto coincide dentro de la tolerancia,
 *   * la fecha del movimiento cae dentro de la ventana.
 *
 * Tolerancia por defecto 1,00 Bs: cubre el redondeo al bolívar. Ampliarla es
 * una decisión de negocio, no técnica — dice cuánto de menos aceptas cobrar.
 */
create or replace function public.admin_statement_matches(
  p_report_id     uuid,
  p_tolerance_ves numeric default 1.00,
  p_window_days   integer default 5
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_report public.payment_reports%rowtype;
  v_quote  public.payment_quotes%rowtype;
  v_rows   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_report from public.payment_reports where id = p_report_id;
  if not found then
    raise exception 'Reporte no encontrado' using errcode = 'P0002';
  end if;

  select * into v_quote from public.payment_quotes where id = v_report.quote_id;

  if v_report.reference is null then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.moved_on desc), '[]'::jsonb) into v_rows
  from (
    select
      l.id, l.bank, l.moved_on, l.reference, l.amount_ves, l.description,
      round(l.amount_ves - v_quote.amount_ves, 2) as difference_ves
    from public.bank_statement_lines l
    where l.reference like '%' || v_report.reference
      and abs(l.amount_ves - v_quote.amount_ves) <= p_tolerance_ves
      and l.moved_on between (v_report.created_at::date - p_window_days)
                         and (v_report.created_at::date + p_window_days)
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_statement_matches(uuid, numeric, integer) from public, anon;
grant execute on function public.admin_statement_matches(uuid, numeric, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- La cola incorpora el resultado del cotejo
-- ---------------------------------------------------------------------------

create or replace view public.payment_queue
with (security_invoker = true)
as
select
  r.id                as report_id,
  r.status,
  r.created_at,
  r.bank,
  r.reference,
  r.payer_document,
  r.payer_phone,
  r.rejection_note,
  q.amount_usd,
  q.amount_ves,
  q.fx_rate,
  q.installment_count,
  p.id                as user_id,
  p.full_name,
  p.phone_e164,
  p.status            as user_status,
  (
    select count(*) - 1 from public.payment_reports r2
    where r2.bank = r.bank and r2.reference = r.reference
      and r2.reference is not null and r2.status <> 'rejected'
  )                   as reference_collisions,
  -- Cuántos movimientos del banco encajan. 1 = verificado; 0 = no aparece
  -- (todavía); más de 1 = hay que mirarlo a mano.
  (
    select count(*) from public.bank_statement_lines l
    where r.reference is not null
      and l.reference like '%' || r.reference
      and abs(l.amount_ves - q.amount_ves) <= 1.00
      and l.moved_on between (r.created_at::date - 5) and (r.created_at::date + 5)
  )                   as statement_matches
from public.payment_reports r
join public.payment_quotes q on q.id = r.quote_id
join public.profiles p on p.id = r.user_id;

comment on view public.payment_queue is
  'Cola de conciliación. `statement_matches` coteja contra el estado de cuenta importado.';

grant select on public.payment_queue to authenticated;
