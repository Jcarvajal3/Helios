-- ============================================================================
-- Prueba de humo de CIMIENTOS: el esquema `metricas` y las RPC que lo leen.
--
-- Se hace pasar por un admin activo y cambia el rol a `authenticated`, como
-- llega el panel. Comprueba que ese rol NO ve el esquema `metricas` pero que
-- las RPC security definer sí lo leen, y devuelve un resumen de cada una.
-- Solo lectura: no escribe nada.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_cimientos.sql
--
-- La coherencia de las cifras entre sí está en metricas_coherencia.sql.
-- ============================================================================

-- Helios: en begin/rollback, como todas (run.sh no corre una suite sin ellos).
begin;

-- @ayudas
-- Helios: la base nace sin equipo; la suite crea su propio admin activo.
select pg_temp.prueba_admin() is not null as admin_de_prueba;

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as admin,
       set_config('role', 'authenticated', true) as rol;

select jsonb_build_object(
  'rol',                          current_user,
  'authenticated_no_ve_metricas', not has_schema_privilege('authenticated', 'metricas', 'usage'),
  'anon_no_ve_metricas',          not has_schema_privilege('anon', 'metricas', 'usage'),
  'admin_merchant_stats',         (select jsonb_agg(public.admin_merchant_stats(m.id, 30) -> 'portfolio')
                                   from public.merchants m where not m.is_test),
  'admin_merchant_risk',          (select count(*) from public.admin_merchant_risk(90)),
  'admin_overview_volume',        public.admin_overview(30) -> 'volume',
  'admin_overview_arrears',       public.admin_overview(30) -> 'arrears',
  'admin_overview_users',         public.admin_overview(30) -> 'users',
  'admin_credit_cohorts',         public.admin_credit_cohorts(6) -> 'rows',
  'admin_on_time_collection',     public.admin_on_time_collection(30),
  'admin_growth_overview_spend',  public.admin_growth_overview(null, null) -> 'spend'
) as resumen;

rollback;
