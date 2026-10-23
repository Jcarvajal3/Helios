-- ============================================================================
-- Prueba de humo de Métricas › Semana: `admin_metricas_semanas`.
--
-- Se hace pasar por un admin activo y cambia el rol a `authenticated`, como
-- llega el panel. Comprueba los permisos (el panel no ve `metricas`, un no
-- admin no puede llamar a la RPC), la forma de la respuesta y los bordes de
-- los parámetros: la semana se lleva a su lunes, una futura es la en curso,
-- las columnas van de 1 a 52 y con un local lo que no se parte vale null.
-- Todo dentro de begin/rollback: no deja nada.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_semana.sql
--
-- Que las cifras digan lo que deben lo comprueba
-- metricas_coherencia_semana.sql.
-- ============================================================================

begin;

-- @ayudas
-- Helios: la base nace sin equipo; la suite crea su propio admin activo.
select pg_temp.prueba_admin() is not null as admin_de_prueba;

-- Un no admin, para comprobar que la RPC lo rechaza.
create function pg_temp.rechaza_a_un_no_admin() returns boolean
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select p.id::text from public.profiles p
                              where not exists (select 1 from public.platform_admins a where a.user_id = p.id)
                              limit 1),
                      'role', 'authenticated')::text, true);
  perform public.admin_metricas_semanas(null, 8, null);
  return false;
exception when insufficient_privilege then
  return true;
end;
$$;

-- El resultado se guarda para leerlo en el resumen, ya con el rol del panel.
create temp table no_admin on commit drop as select pg_temp.rechaza_a_un_no_admin() as rechazado;
grant select on no_admin to authenticated;

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active and role in ('super_admin', 'operador') limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as admin,
       set_config('role', 'authenticated', true) as rol;

with
hoy as (select public.helios_business_date(now()) as d),
lunes as (select d - (extract(isodow from d)::integer - 1) as l, d from hoy),
ocho as (select public.admin_metricas_semanas(null, 8, null) as j),
por_defecto as (select public.admin_metricas_semanas() as j),
un_miercoles as (select public.admin_metricas_semanas((select l - 12 from lunes), 3, null) as j),
futura as (select public.admin_metricas_semanas((select d + 40 from hoy), 1, null) as j),
muchas as (select public.admin_metricas_semanas(null, 500, null) as j),
ninguna as (select public.admin_metricas_semanas(null, 0, null) as j),
con_local as (
  select public.admin_metricas_semanas(null, 2,
    (select m.id from public.merchants m where not m.is_test order by m.created_at limit 1)) as j
)
select jsonb_build_object(
  'rol',                              current_user,
  'no_admin_rechazado',               (select rechazado from no_admin),
  'authenticated_no_ve_metricas',     not has_schema_privilege('authenticated', 'metricas', 'usage'),
  -- Por oid: el nombre no se puede resolver sin USAGE sobre el esquema.
  'authenticated_no_llama_periodo',   not has_function_privilege('authenticated',
                                        (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                         where n.nspname = 'metricas' and p.proname = 'semana_periodo'), 'execute'),
  'anon_no_llama_la_rpc',             not has_function_privilege('anon', 'public.admin_metricas_semanas(date, integer, uuid)', 'execute'),
  'ocho_columnas',                    jsonb_array_length((select j from ocho)->'filas') = 8,
  'la_ultima_es_la_de_hoy',           ((select j from ocho)->'filas'->7->>'desde')::date = (select l from lunes),
  'la_ultima_esta_en_curso',          ((select j from ocho)->'filas'->7->>'en_curso')::boolean,
  'la_semana_usada_es_la_de_hoy',     ((select j from ocho)->'semana'->>'desde')::date = (select l from lunes),
  'dias_de_la_en_curso',              ((select j from ocho)->'filas'->7->>'dias')::integer
                                        = (select d - l + 1 from lunes),
  'la_comparacion_va_a_la_misma_altura',
                                      ((select j from ocho)->'comparacion'->>'dias')::integer
                                        = ((select j from ocho)->'filas'->7->>'dias')::integer,
  'por_defecto_ocho',                 jsonb_array_length((select j from por_defecto)->'filas') = 8,
  'un_dia_suelto_va_a_su_lunes',      ((select j from un_miercoles)->'semana'->>'desde')::date = (select l - 14 from lunes),
  'una_semana_cerrada_no_esta_en_curso', not ((select j from un_miercoles)->'semana'->>'en_curso')::boolean,
  'una_futura_es_la_en_curso',        ((select j from futura)->'semana'->>'desde')::date = (select l from lunes),
  'como_mucho_52',                    jsonb_array_length((select j from muchas)->'filas') = 52,
  'como_poco_1',                      jsonb_array_length((select j from ninguna)->'filas') = 1,
  'con_local_registros_null',         jsonb_typeof((select j from con_local)->'filas'->1->'gente'->'registros') = 'null',
  'con_local_caja_null',              jsonb_typeof((select j from con_local)->'filas'->1->'caja'->'en_caja_usd') = 'null',
  'con_local_consumo_numero',         jsonb_typeof((select j from con_local)->'filas'->1->'consumo'->'financed_usd') = 'number',
  'la_semana_de_hoy',                 (select j from ocho)->'filas'->7
) as resumen;

rollback;
