-- ============================================================================
-- Prueba de humo de COHORTES: admin_metricas_cohortes y admin_metricas_cohorte.
--
-- Dentro de una transacción que se deshace:
--   1. Sin ser admin, las dos RPC se rechazan con 42501 (si no, revienta).
--   2. Se hace pasar por un admin activo y cambia el rol a `authenticated`,
--      como llega el panel: ese rol no ve el esquema `metricas` ni puede
--      ejecutar sus funciones de cohorte, y las dos RPC contestan.
-- Devuelve una fila con el resumen de cada una (la última sentencia).
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_cohortes.sql
--
-- La coherencia de las cifras está en metricas_coherencia_cohortes.sql.
-- ============================================================================

begin;

-- @ayudas
-- Helios: la base nace sin equipo; la suite crea su propio admin activo.
select pg_temp.prueba_admin() is not null as admin_de_prueba;

-- 1. Sin ser admin: rechazadas con 42501.
select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-0000-0000-000000000000', 'role', 'authenticated')::text, true) is not null as no_admin;

do $$
begin
  perform public.admin_metricas_cohortes();
  raise exception 'admin_metricas_cohortes no rechazó a quien no es admin';
exception when insufficient_privilege then
  null;
end;
$$;

do $$
begin
  perform public.admin_metricas_cohorte(null);
  raise exception 'admin_metricas_cohorte no rechazó a quien no es admin';
exception when insufficient_privilege then
  null;
end;
$$;

-- 2. Como admin y con el rol del panel. Lo que `authenticated` no puede ni
-- nombrar se mira antes de cambiar de rol y se guarda en un ajuste local.
select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as admin,
       set_config('cohortes_prueba.no_ejecuta',
         (not has_function_privilege('authenticated', 'metricas.cohorte_json(uuid, date, boolean)', 'execute')
          and not has_function_privilege('authenticated', 'metricas.cohorte_curva(uuid, integer, integer)', 'execute')
          and not has_function_privilege('authenticated', 'metricas.cohorte_cobro(uuid)', 'execute'))::text,
         true) as authenticated_no_ejecuta_cohortes;
set local role authenticated;

select jsonb_build_object(
  'rol',                               current_user,
  'sin_admin_rechazan',                true,
  'authenticated_no_ve_metricas',      not has_schema_privilege('authenticated', 'metricas', 'usage'),
  'authenticated_no_ejecuta_cohortes', current_setting('cohortes_prueba.no_ejecuta')::boolean,
  'anon_no_ejecuta_la_lista',          not has_function_privilege('anon', 'public.admin_metricas_cohortes(uuid)', 'execute'),
  'anon_no_ejecuta_el_detalle',        not has_function_privilege('anon', 'public.admin_metricas_cohorte(date, uuid)', 'execute'),
  'lista_hoy',                         public.admin_metricas_cohortes() -> 'hoy',
  'lista_semanas',                     jsonb_array_length(public.admin_metricas_cohortes() -> 'cohortes'),
  'lista_primera',                     (public.admin_metricas_cohortes() -> 'cohortes' -> 0) - 'cuotas' - 'a_cobrar',
  -- Lo que hay que cobrar de la semana (20260927610000): la cuota 1 + la 2, con su desglose.
  'lista_primera_a_cobrar',            ((public.admin_metricas_cohortes() -> 'cohortes' -> 0 -> 'a_cobrar') - 'estados'),
  'detalle_semana_en_curso',           public.admin_metricas_cohorte(null) -> 'semana',
  'detalle_semana_futura_se_queda_en_hoy',
    (public.admin_metricas_cohorte(current_date + 60) -> 'semana' ->> 'desde')
      = (public.admin_metricas_cohorte(null) -> 'semana' ->> 'desde'),
  'detalle_lunes_de_un_miercoles',
    public.admin_metricas_cohorte(((public.admin_metricas_cohortes() -> 'cohortes' -> 0 ->> 'semana')::date + 2)) -> 'semana',
  'detalle_de_la_mas_reciente',
    (select jsonb_build_object(
       'cohorte',   (d -> 'cohorte') - 'cuotas',
       'cuota_1',   (d -> 'cohorte' -> 'cuotas' -> 0) - 'estados',
       'estados_1', d -> 'cohorte' -> 'cuotas' -> 0 -> 'estados',
       'curva_1',   d -> 'curvas' -> 0 -> 'dias' -> 6,
       'medias_1',  d -> 'curvas' -> 0 -> 'semanas_media',
       'por_local', jsonb_array_length(d -> 'por_local'))
     from (select public.admin_metricas_cohorte(
             (public.admin_metricas_cohortes() -> 'cohortes' -> 0 ->> 'semana')::date) as d) x),
  'una_semana_sin_consumos',
    (select jsonb_build_object('cohorte', d -> 'cohorte', 'por_local', d -> 'por_local',
                               'curvas', jsonb_array_length(d -> 'curvas'))
     from (select public.admin_metricas_cohorte(date '2020-01-06') as d) x),
  'con_un_local',
    (select jsonb_build_object(
       'local', m.name,
       'semanas', jsonb_array_length(public.admin_metricas_cohortes(m.id) -> 'cohortes'),
       'por_local', jsonb_array_length(public.admin_metricas_cohorte(null, m.id) -> 'por_local'))
     from public.merchants m
     where not m.is_test
       and exists (select 1 from public.charges c where c.merchant_id = m.id and c.status = 'confirmed')
     order by m.created_at
     limit 1)
) as resumen;

rollback;
