-- ============================================================================
-- Prueba de humo de Métricas › Semana › Resumen: `admin_metricas_semana_resumen`.
--
-- Se hace pasar por un admin activo y cambia el rol a `authenticated`, como
-- llega el panel. Comprueba los permisos (el panel no ve `metricas`, un no
-- admin no puede llamar a la RPC, anon tampoco), la forma de la respuesta y
-- los bordes del parámetro: la semana se lleva a su lunes, una futura es la en
-- curso, la chispa lleva 8 semanas que acaban en la elegida y la anterior va a
-- la misma altura. Todo dentro de begin/rollback: no deja nada.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_semana_resumen.sql
--
-- Que las cifras digan lo que deben lo comprueba
-- metricas_coherencia_semana_resumen.sql.
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
  perform public.admin_metricas_semana_resumen(null, null);
  return false;
exception when insufficient_privilege then
  return true;
end;
$$;

-- El resultado se guarda para leerlo en el resumen, ya con el rol del panel.
create temp table no_admin on commit drop as select pg_temp.rechaza_a_un_no_admin() as rechazado;
grant select on no_admin to authenticated;

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as admin,
       set_config('role', 'authenticated', true) as rol;

with
hoy as (select public.helios_business_date(now()) as d),
lunes as (select d - (extract(isodow from d)::integer - 1) as l, d from hoy),
esta as (select public.admin_metricas_semana_resumen(null, null) as j),
por_defecto as (select public.admin_metricas_semana_resumen() as j),
un_miercoles as (select public.admin_metricas_semana_resumen((select l - 12 from lunes), null) as j),
futura as (select public.admin_metricas_semana_resumen((select d + 40 from hoy), null) as j),
con_local as (
  select public.admin_metricas_semana_resumen(null,
    (select m.id from public.merchants m where not m.is_test order by m.created_at limit 1)) as j
),
resumen as (
select jsonb_build_object(
  'rol',                              current_user,
  'no_admin_rechazado',               (select rechazado from no_admin),
  'authenticated_no_ve_metricas',     not has_schema_privilege('authenticated', 'metricas', 'usage'),
  -- Por oid: el nombre no se puede resolver sin USAGE sobre el esquema.
  'authenticated_no_llama_el_tramo',  not has_function_privilege('authenticated',
                                        (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                         where n.nspname = 'metricas' and p.proname = 'semana_resumen_tramo'), 'execute'),
  'anon_no_llama_la_rpc',             not has_function_privilege('anon', 'public.admin_metricas_semana_resumen(date, uuid)', 'execute'),
  'la_semana_usada_es_la_de_hoy',     ((select j from esta)->'semana'->>'desde')::date = (select l from lunes),
  'la_de_hoy_esta_en_curso',          ((select j from esta)->'semana'->>'en_curso')::boolean,
  'cuenta_hasta_hoy',                 ((select j from esta)->>'hasta')::date = (select d from hoy),
  'dias_de_la_en_curso',              ((select j from esta)->>'dias')::integer = (select d - l + 1 from lunes),
  'la_anterior_a_la_misma_altura',    ((select j from esta)->'anterior'->>'dias')::integer
                                        = ((select j from esta)->>'dias')::integer
                                      and ((select j from esta)->'anterior'->>'desde')::date = (select l - 7 from lunes),
  'ocho_semanas_de_chispa',           jsonb_array_length((select j from esta)->'semanas') = 8,
  'la_chispa_acaba_en_la_elegida',    ((select j from esta)->'semanas'->7->>'desde')::date = (select l from lunes)
                                      and ((select j from esta)->'semanas'->7->'financed_usd')
                                            = ((select j from esta)->'cifras'->'financed_usd'),
  'por_defecto_la_de_hoy',            ((select j from por_defecto)->'semana'->>'desde')::date = (select l from lunes),
  'un_dia_suelto_va_a_su_lunes',      ((select j from un_miercoles)->'semana'->>'desde')::date = (select l - 14 from lunes),
  'una_semana_cerrada_no_esta_en_curso', not ((select j from un_miercoles)->'semana'->>'en_curso')::boolean
                                      and ((select j from un_miercoles)->>'dias')::integer = 7
                                      and not ((select j from un_miercoles)->'anterior'->>'misma_altura')::boolean,
  'una_futura_es_la_en_curso',        ((select j from futura)->'semana'->>'desde')::date = (select l from lunes),
  'las_cifras_traen_sus_claves',      (select j from esta)->'cifras' ?& array['financed_usd', 'fee_usd', 'payable_usd',
                                        'servicio_usd', 'iva_usd', 'consumos', 'ticket_medio_usd', 'personas', 'nuevas'],
  'la_comparacion_trae_sus_claves',   (select j from esta)->'comparacion' ?& array['financed_usd', 'fee_usd', 'payable_usd',
                                        'consumos', 'personas'],
  'las_noches_son_una_lista',         jsonb_typeof((select j from esta)->'noches') = 'array',
  'cada_noche_trae_su_desglose',      coalesce((select bool_and(x ?& array['business_date', 'merchant_id', 'nombre', 'consumos',
                                        'personas', 'nuevas', 'financed_usd', 'fee_usd', 'payable_usd', 'ticket_medio_usd'])
                                        from jsonb_array_elements((select j from esta)->'noches') x), true),
  'con_local_solo_ese_local',         coalesce((select bool_and(x->>'merchant_id' = (select j from con_local)->>'local')
                                        from jsonb_array_elements((select j from con_local)->'noches') x), true),
  'con_local_dice_su_local',          jsonb_typeof((select j from con_local)->'local') = 'string',
  'la_semana_de_hoy',                 (select j from esta) - 'noches' - 'semanas'
) as r
)
-- `ok`: todas las comprobaciones (los valores booleanos) dan verdadero.
select r as resumen,
       (select bool_and(v::text::boolean) from jsonb_each(r) e(k, v) where jsonb_typeof(v) = 'boolean') as ok
from resumen;

rollback;
