-- ============================================================================
-- Ronda — El historial de importaciones del banco
--
-- Cada vez que alguien sube un estado de cuenta, el panel dice cuántos entraron
-- y se olvida. No queda quién lo subió, qué archivo era ni cuándo — y con eso
-- se pierden dos cosas distintas:
--
--   * **La trazabilidad.** Un abono aparece en la lista de sin dueño y nadie
--     puede decir de qué archivo salió ni quién lo trajo.
--   * **El aviso.** «Llevas siete días sin importar el estado de cuenta» es la
--     alerta que explica por qué media cola de pagos está sin cotejar. Sin
--     saber cuándo fue el último import, no se puede dar.
--
-- Esto último es lo que más duele en el día a día: sin importar, todo pago
-- reportado sale como «no encontrado» y el operador acaba aprobándolos a ciegas
-- sin darse cuenta de que el problema no son los pagos, es que falta el archivo.
-- ============================================================================

create table if not exists public.statement_imports (
  id           uuid primary key default gen_random_uuid(),
  bank         text not null,
  file_name    text,
  -- Lo que venía en el archivo y lo que acabó entrando. Los tres números son
  -- los que el panel enseña al terminar, guardados para poder repetirlos.
  rows_read    integer not null default 0,
  deposits     integer not null default 0,
  inserted     integer not null default 0,
  duplicates   integer not null default 0,
  imported_by  uuid references auth.users (id),
  imported_at  timestamptz not null default now()
);

comment on table public.statement_imports is
  'Quien subio que estado de cuenta y cuando. Alimenta el aviso de "llevas N dias sin importar", que es lo que explica una cola entera de pagos sin cotejar.';

create index if not exists statement_imports_at_idx
  on public.statement_imports (imported_at desc);

alter table public.statement_imports enable row level security;
revoke all on table public.statement_imports from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- El import deja constancia
-- ---------------------------------------------------------------------------
-- Cuerpo del de 20260822130000 con dos parámetros más —el nombre del archivo y
-- cuántas filas traía— y la fila del historial. El cálculo de la huella y el
-- `on conflict do nothing` que lo hacen idempotente no se tocan.

drop function if exists public.admin_import_statement(text, jsonb);

create or replace function public.admin_import_statement(
  p_bank      text,
  p_lines     jsonb,
  p_file_name text default null,
  p_rows_read integer default null
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
  v_import   uuid;
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

  insert into public.statement_imports
    (bank, file_name, rows_read, deposits, inserted, duplicates, imported_by)
  values (
    p_bank,
    nullif(trim(coalesce(p_file_name, '')), ''),
    -- Las filas leídas las cuenta el panel: aquí solo llegan las que pasaron
    -- el filtro de abonos. Si no las manda, lo que hay son los abonos.
    coalesce(p_rows_read, v_total),
    v_total,
    v_inserted,
    v_total - v_inserted
  )
  returning id into v_import;

  perform audit.log(v_actor, 'statement.import', v_import,
    jsonb_build_object(
      'bank', p_bank, 'file_name', p_file_name,
      'rows_read', coalesce(p_rows_read, v_total),
      'deposits', v_total, 'inserted', v_inserted
    ));

  return jsonb_build_object(
    'ok', true,
    'import_id', v_import,
    'received', v_total,
    'inserted', v_inserted,
    'duplicates', v_total - v_inserted
  );
end;
$$;

revoke all on function public.admin_import_statement(text, jsonb, text, integer) from public, anon;
grant execute on function public.admin_import_statement(text, jsonb, text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Quién subió qué, y hace cuánto fue el último
-- ---------------------------------------------------------------------------

create or replace function public.admin_statement_imports(p_limit integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_rows jsonb;
  v_last timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select max(imported_at) into v_last from public.statement_imports;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.imported_at desc), '[]'::jsonb)
  into v_rows
  from (
    select
      i.id, i.bank, i.file_name, i.rows_read, i.deposits,
      i.inserted, i.duplicates, i.imported_at,
      coalesce(pa.full_name, 'Alguien del equipo') as imported_by_name
    from public.statement_imports i
    left join public.platform_admins pa on pa.user_id = i.imported_by
    order by i.imported_at desc
    limit least(coalesce(p_limit, 30), 200)
  ) q;

  return jsonb_build_object(
    'last_import_at', v_last,
    -- Null si nunca se ha importado nada: la pantalla tiene que poder
    -- distinguir "hace mucho" de "nunca", que se resuelven distinto.
    'days_since_last', case
      when v_last is null then null
      else floor(extract(epoch from (now() - v_last)) / 86400)::integer
    end,
    'rows', v_rows
  );
end;
$$;

comment on function public.admin_statement_imports(integer) is
  'Historial de importaciones del banco, y cuantos dias han pasado desde la ultima. Sin importar, todo pago reportado sale como "no encontrado" y el operador acaba aprobando a ciegas.';

revoke all on function public.admin_statement_imports(integer) from public, anon;
grant execute on function public.admin_statement_imports(integer) to authenticated;
