-- ============================================================================
-- Helios — Verificación estática de la base (docs/00 §4.1 paso 6, §9)
--
--   supabase db query --linked --project-ref ahyfbnfsbyzdoyjzjvfb \
--     -f supabase/poda/verificar.sql
--
-- Postgres NO valida el cuerpo de una función al crearla: una función que lee
-- una tabla podada (`group_members`, `bits_entries`…) solo falla cuando
-- alguien la llama, en producción. Esto la hace fallar aquí:
--
--   1. plpgsql_check sobre TODA función y procedimiento plpgsql de public,
--      ledger, audit, metricas y asistente (las de trigger, contra la tabla de
--      su trigger). Todo lo de nivel `error` es un fallo.
--   2. Las funciones `language sql`, que plpgsql_check no mira: se vuelve a
--      ejecutar su `create or replace` (pg_get_functiondef) con
--      check_function_bodies encendido, dentro de un subbloque que se deshace
--      siempre. Si referencian algo que no existe, falla.
--   3. Cada vista: `select 1 from vista limit 0` (planifica la consulta).
--   4. Los trabajos de cron que quedan, para leerlos (tipo `cron`, no fallo).
--
-- Devuelve UNA tabla (la Management API solo devuelve el último resultado):
-- tipo, objeto, nivel, detalle. Cero filas de nivel `error` = verde.
-- Los avisos (`warning`, `performance`) se listan para revisarlos a mano.
--
-- Todo va dentro de begin/rollback: no deja nada escrito. Necesita la
-- extensión plpgsql_check (migración 20261001000100).
-- ============================================================================

begin;

create temp table _verificacion (
  tipo    text,
  objeto  text,
  nivel   text,
  detalle text
) on commit drop;

-- 1. plpgsql ------------------------------------------------------------------
do $$
declare
  f      record;
  v_rel  oid;
  r      record;
begin
  for f in
    select p.oid, p.oid::regprocedure::text as nombre, p.prorettype
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join pg_language l on l.oid = p.prolang
    where l.lanname = 'plpgsql'
      and n.nspname in ('public', 'ledger', 'audit', 'metricas', 'asistente')
      and p.prorettype <> 'event_trigger'::regtype
  loop
    v_rel := 0;
    if f.prorettype = 'trigger'::regtype then
      select t.tgrelid into v_rel from pg_trigger t where t.tgfoid = f.oid limit 1;
      if v_rel is null then
        insert into _verificacion values ('plpgsql', f.nombre, 'warning',
          'función de trigger que ningún trigger usa: no se puede comprobar');
        continue;
      end if;
    end if;

    begin
      for r in
        select * from extensions.plpgsql_check_function_tb(
          f.oid, v_rel,
          fatal_errors := false,
          other_warnings := true,
          performance_warnings := false,
          extra_warnings := false)
      loop
        insert into _verificacion values ('plpgsql', f.nombre, r.level,
          coalesce('línea ' || r.lineno || ': ', '') || r.message
          || coalesce(' — ' || r.query, ''));
      end loop;
    exception when others then
      insert into _verificacion values ('plpgsql', f.nombre, 'error',
        'plpgsql_check no pudo analizarla: ' || sqlerrm);
    end;
  end loop;
end
$$;

-- 2. language sql -------------------------------------------------------------
do $$
declare
  f record;
begin
  set local check_function_bodies = on;
  for f in
    select p.oid, p.oid::regprocedure::text as nombre
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join pg_language l on l.oid = p.prolang
    where l.lanname = 'sql'
      and n.nspname in ('public', 'ledger', 'audit', 'metricas', 'asistente')
  loop
    begin
      execute pg_get_functiondef(f.oid);
      raise exception using errcode = 'P0001', message = '__deshacer__';
    exception when others then
      if sqlerrm <> '__deshacer__' then
        insert into _verificacion values ('sql', f.nombre, 'error', sqlerrm);
      end if;
    end;
  end loop;
end
$$;

-- 3. Vistas -------------------------------------------------------------------
do $$
declare
  v record;
begin
  for v in
    select c.oid::regclass::text as nombre
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where c.relkind in ('v', 'm')
      and n.nspname in ('public', 'ledger', 'audit', 'metricas', 'asistente')
  loop
    begin
      execute format('select 1 from %s limit 0', v.nombre);
    exception when others then
      insert into _verificacion values ('vista', v.nombre, 'error', sqlerrm);
    end;
  end loop;
end
$$;

-- 4. Cron ---------------------------------------------------------------------
insert into _verificacion
select 'cron', j.jobname, 'info', j.schedule || ' · ' || btrim(j.command)
from cron.job j;

select tipo, nivel, objeto, detalle
from _verificacion
order by case nivel when 'error' then 0 when 'warning' then 1 else 2 end, tipo, objeto;

rollback;
