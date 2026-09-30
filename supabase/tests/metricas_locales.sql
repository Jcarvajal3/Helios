-- ============================================================================
-- Prueba de humo de LOCALES (Métricas › Locales)
--
-- Como llega el panel: un admin activo con el rol `authenticated`, dentro de
-- begin/rollback (no escribe nada). Comprueba:
--   * que quien no es del personal de Ronda recibe 42501 (si no, la prueba
--     revienta con un error que lo dice);
--   * que `authenticated` no ve `metricas.locales_cierre` y sí la RPC, y
--     `anon` tampoco la RPC;
--   * que admin_metricas_locales contesta para la semana en curso, para una
--     pasada, para una futura (que se queda en la de hoy) y con un local;
--   * que admin_merchant_stats acepta la semana y sigue (Helios: admin_nights,
--     las noches, se podó)
--     funcionando como antes sin ella.
-- Devuelve una fila por prueba con un resumen de lo que contestó. `db query`
-- solo enseña la última sentencia, así que todo acaba en una sola consulta.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_locales.sql
-- ============================================================================

begin;

-- @ayudas
-- Helios: la base nace sin equipo; la suite crea su propio admin activo.
select pg_temp.prueba_admin() is not null as admin_de_prueba;

-- 1. Los permisos, mirados como el dueño (`authenticated` ni siquiera puede
--    nombrar una función de un esquema que no ve). Se guardan para el final.
select set_config('prueba.permisos', jsonb_build_object(
  'authenticated_usa_metricas',        has_schema_privilege('authenticated', 'metricas', 'usage'),
  'authenticated_ejecuta_locales_cierre', has_function_privilege('authenticated', 'metricas.locales_cierre(date)', 'execute'),
  'authenticated_ejecuta_la_rpc',      has_function_privilege('authenticated', 'public.admin_metricas_locales(date, uuid)', 'execute'),
  'anon_ejecuta_la_rpc',               has_function_privilege('anon', 'public.admin_metricas_locales(date, uuid)', 'execute')
)::text, true) is not null as permisos;

-- 2. Quien no es del personal no pasa.
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true) is not null as intruso;
set local role authenticated;

do $$
begin
  begin
    perform public.admin_metricas_locales(null, null);
    raise exception 'admin_metricas_locales no se negó a alguien de fuera';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.admin_merchant_stats(gen_random_uuid(), 7, current_date);
    raise exception 'admin_merchant_stats no se negó a alguien de fuera';
  exception when sqlstate '42501' then null;
  end;
end $$;

-- 3. Un admin de verdad.
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as admin;
set local role authenticated;

with
h        as (select public.helios_business_date(now()) as hoy),
l_hoy    as (select public.admin_metricas_locales(null, null) as j),
l_pasada as (select public.admin_metricas_locales(h.hoy - 14, null) as j from h),
l_futura as (select public.admin_metricas_locales(h.hoy + 30, null) as j from h),
un_local as (
  select (x->>'merchant_id')::uuid as id
  from l_hoy, jsonb_array_elements(l_hoy.j->'locales') x
  order by (x->>'consumo_usd')::numeric desc
  limit 1
),
l_local  as (select public.admin_metricas_locales(null, (select id from un_local)) as j)
select '1 permisos' as prueba, current_setting('prueba.permisos')::jsonb as resumen
union all
select '2 quien no es del personal recibe 42501', jsonb_build_object('ok', true)
union all
select '3 semana en curso',
       jsonb_build_object(
         'semana',     j->'semana',
         'hoy',        j->'hoy',
         'anterior',   j->'anterior',
         'cierre',     j->'cierre',
         'locales',    jsonb_array_length(j->'locales'),
         'consumo',    j->'totales'->'consumo_usd',
         'personas',   j->'totales'->'personas',
         'vencido',    j->'totales'->'vencido',
         'cierre_usd', j->'totales'->'transferencia',
         'series',     jsonb_array_length(j->'series'->'semanas'),
         'cohortes',   jsonb_array_length(j->'cohortes'->'semanas')
       )
from l_hoy
union all
select '4 semana pasada (hace dos)',
       jsonb_build_object('semana', j->'semana', 'anterior', j->'anterior', 'cierre', j->'cierre',
                          'consumo', j->'totales'->'consumo_usd', 'cierre_usd', j->'totales'->'transferencia')
from l_pasada
union all
select '5 semana futura: se queda en la de hoy',
       jsonb_build_object('semana', j->'semana',
                          'igual_que_hoy', (j->'semana') = (select l_hoy.j->'semana' from l_hoy))
from l_futura
union all
select '6 con un local',
       jsonb_build_object('local', j->'local', 'filas', jsonb_array_length(j->'locales'),
                          'nombre', j->'locales'->0->'nombre', 'consumo', j->'locales'->0->'consumo_usd',
                          'series', jsonb_array_length(j->'series'->'locales'),
                          'cohortes', jsonb_array_length(j->'cohortes'->'locales'),
                          'totales_son_de_todos',
                          (j->'totales'->'consumo_usd') = (select l_hoy.j->'totales'->'consumo_usd' from l_hoy))
from l_local
union all
select '9 admin_merchant_stats con la semana pasada',
       (select jsonb_build_object('semana', s->'semana', 'window_days', s->'window_days',
                                  'financed_usd', s->'financed_usd', 'portfolio', s->'portfolio')
        from (select public.admin_merchant_stats((select id from un_local), 7, (select hoy from h) - 7) as s) x)
union all
select '10 admin_merchant_stats sin la semana (como siempre)',
       (select jsonb_build_object('semana', s->'semana', 'window_days', s->'window_days',
                                  'arrears_pct', s->'portfolio'->'arrears_pct',
                                  'dia_de_referencia', s->'portfolio'->'dia_de_referencia')
        from (select public.admin_merchant_stats((select id from un_local), 30) as s) x);

rollback;
