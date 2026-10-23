-- ============================================================================
-- Prueba de humo de Métricas › Juan Pablo: `admin_metricas_juan_pablo`.
--
-- Se hace pasar por un admin activo y cambia el rol a `authenticated`, como
-- llega el panel. Comprueba los permisos (un no admin no puede llamar a la
-- RPC, anon tampoco), los bordes de las fechas (sin fechas es hoy, el futuro
-- se recorta a hoy, un «desde» después del «hasta» se lleva al «hasta») y que
-- las cifras cuadran: las órdenes, el GTV y el revenue son los de
-- `metricas.semana_periodo` para el mismo tramo, las órdenes de cada médico
-- suman las del periodo y nunca hay más médicos con órdenes que afiliados.
-- Todo dentro de begin/rollback: no deja nada.
--
--   bash supabase/tests/run.sh metricas_juan_pablo
-- ============================================================================

begin;

-- @ayudas
select pg_temp.prueba_admin() is not null as admin_de_prueba;

create function pg_temp.rechaza_a_un_no_admin() returns boolean
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select p.id::text from public.profiles p
                              where not exists (select 1 from public.platform_admins a where a.user_id = p.id)
                              limit 1),
                      'role', 'authenticated')::text, true);
  perform public.admin_metricas_juan_pablo(null, null);
  return false;
exception when insufficient_privilege then
  return true;
end;
$$;

create temp table no_admin on commit drop as select pg_temp.rechaza_a_un_no_admin() as rechazado;
grant select on no_admin to authenticated;

-- Lo que dice Semana para los últimos 30 días, leído antes de dejar de ser
-- dueño del esquema `metricas`.
create temp table semana on commit drop as
select metricas.semana_periodo(metricas.hoy() - 29, metricas.hoy()) as j, metricas.hoy() as hoy;
grant select on semana to authenticated;

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active and role in ('super_admin', 'operador') limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as admin,
       set_config('role', 'authenticated', true) as rol;

with
s as (select j, hoy from semana),
por_defecto as (select public.admin_metricas_juan_pablo() as j),
treinta as (select public.admin_metricas_juan_pablo((select hoy - 29 from s), (select hoy from s)) as j),
futuro as (select public.admin_metricas_juan_pablo((select hoy + 3 from s), (select hoy + 40 from s)) as j),
al_reves as (select public.admin_metricas_juan_pablo((select hoy - 2 from s), (select hoy - 9 from s)) as j),
resumen as (
select jsonb_build_object(
  'rol',                          current_user,
  'no_admin_rechazado',           (select rechazado from no_admin),
  'anon_no_llama_la_rpc',         not has_function_privilege('anon', 'public.admin_metricas_juan_pablo(date, date)', 'execute'),
  'sin_fechas_es_hoy',            ((select j from por_defecto)->>'desde')::date = (select hoy from s)
                                  and ((select j from por_defecto)->>'hasta')::date = (select hoy from s)
                                  and ((select j from por_defecto)->>'dias')::integer = 1,
  'el_futuro_es_hoy',             ((select j from futuro)->>'desde')::date = (select hoy from s)
                                  and ((select j from futuro)->>'hasta')::date = (select hoy from s),
  'desde_despues_del_hasta',      ((select j from al_reves)->>'desde')::date = (select hoy - 9 from s)
                                  and ((select j from al_reves)->>'dias')::integer = 1,
  'treinta_dias',                 ((select j from treinta)->>'dias')::integer = 30,
  'ordenes_como_semana',          ((select j from treinta)->>'ordenes')::integer
                                    = ((select j from s)->'consumo'->>'consumos')::integer,
  'gtv_como_semana',              ((select j from treinta)->>'gtv_usd')::numeric
                                    = ((select j from s)->'consumo'->>'financed_usd')::numeric,
  'revenue_como_semana',          ((select j from treinta)->>'revenue_usd')::numeric
                                    = ((select j from s)->'ingreso'->>'servicio_usd')::numeric,
  'los_medicos_suman_las_ordenes', coalesce((select sum((e->>'ordenes')::integer)
                                             from jsonb_array_elements((select j from treinta)->'por_medico') e), 0)
                                    = ((select j from treinta)->>'ordenes')::integer,
  'una_fila_por_medico_con_ordenes', jsonb_array_length((select j from treinta)->'por_medico')
                                    = ((select j from treinta)->'medicos'->>'con_ordenes')::integer,
  'nunca_mas_del_cien',           ((select j from treinta)->'medicos'->>'con_ordenes')::integer
                                    <= ((select j from treinta)->'medicos'->>'afiliados')::integer
)
as r)
-- `ok`: todas las comprobaciones (los valores booleanos) dan verdadero. Si
-- alguna falla, la división por cero saca el `ERROR:` que busca run.sh.
select r as resumen,
       1 / (select bool_and(v::text::boolean) from jsonb_each(r) e(k, v)
            where jsonb_typeof(v) = 'boolean')::integer = 1 as ok
from resumen;

rollback;
