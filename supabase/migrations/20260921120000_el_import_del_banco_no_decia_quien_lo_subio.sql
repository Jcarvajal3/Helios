-- ============================================================================
-- Ronda — El import del estado de cuenta no podía terminar
--
-- `admin_import_statement` guardaba las líneas del banco y, acto seguido,
-- dejaba constancia del import en `statement_imports`. Ese segundo insert
-- nombraba SIETE columnas y pasaba SEIS valores: se quedó fuera `imported_by`.
--
--     insert into public.statement_imports
--       (bank, file_name, rows_read, deposits, inserted, duplicates, imported_by)
--     values (p_bank, …, v_total - v_inserted)   -- ← falta v_actor
--
-- Postgres no rellena lo que falta con el valor por defecto: aborta con
-- "INSERT has more target columns than expressions" (42601). Y como el error
-- salta dentro de la función, la transacción entera se deshace — también el
-- insert de las líneas, que sí estaba bien. Resultado: el panel leía el
-- archivo, enseñaba los abonos y al pulsar "Importar" no entraba ni uno.
--
-- Es un error de tiempo de ejecución: plpgsql no comprueba el cuerpo al
-- crear la función, así que la migración 20260911192000 se aplicó limpia y
-- el fallo no apareció hasta el primer import de verdad.
--
-- Aquí solo se añade `v_actor` a la lista de valores. Todo lo demás es el
-- cuerpo de 20260911192000 sin tocar.
-- ============================================================================

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
    v_total - v_inserted,
    -- El que faltaba. Sin él, la tabla del historial no puede decir quién
    -- subió el archivo, que es justo para lo que se creó.
    v_actor
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
