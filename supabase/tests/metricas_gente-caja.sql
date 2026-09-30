-- ============================================================================
-- Prueba de humo de GENTE-CAJA: las RPC de Métricas › Gente y › Caja.
--
-- Se hace pasar por un admin activo y cambia el rol a `authenticated`, como
-- llega el panel. Llama a cada RPC sin local y con el local que más consume,
-- y comprueba la forma de la respuesta: con un local, lo que no se parte
-- vale null (nunca cero), y todo lo que se paga en cuotas trae su consumo y
-- su servicio e IVA. Solo lectura: no escribe nada.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_gente-caja.sql
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok. Que las
-- cifras cuadren con `metricas.*` está en metricas_coherencia_gente-caja.sql.
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

with
l as (
  -- El local que más consume, sin mirar metricas (authenticated no lo ve):
  -- el primero de la lista de lo que se les debe.
  select (x->>'merchant_id')::uuid as id
  from jsonb_array_elements(public.admin_merchant_payables()) x
  where not (x->>'is_test')::boolean
  order by (x->>'total_pending_usd')::numeric desc
  limit 1
),
ov   as (select public.admin_growth_overview(current_date - 27, current_date) as j),
ovl  as (select public.admin_growth_overview(current_date - 27, current_date, l.id) as j from l),
fu   as (select public.admin_growth_funnel(current_date - 27, current_date) as j),
ful  as (select public.admin_growth_funnel(current_date - 27, current_date, l.id) as j from l),
be   as (select public.admin_user_behavior(current_date - 27, current_date) as j),
bel  as (select public.admin_user_behavior(current_date - 27, current_date, l.id) as j from l),
gr   as (select public.admin_group_metrics(current_date - 27, current_date) as j),
grl  as (select public.admin_group_metrics(current_date - 27, current_date, l.id) as j from l),
co   as (select public.admin_user_cohorts('week', 8) as j),
col  as (select public.admin_user_cohorts('week', 8, l.id) as j from l),
pe   as (select public.admin_user_persona('registrados') as j),
pel  as (select public.admin_user_persona('registrados', l.id) as j from l),
cp   as (select public.admin_cash_position() as j),
cpl  as (select public.admin_cash_position(l.id) as j from l),
fc   as (select public.admin_cash_forecast(4) as j),
fcl  as (select public.admin_cash_forecast(4, l.id) as j from l),
mpl  as (select public.admin_merchant_payables(l.id) as j from l),
mc   as (select public.admin_metricas_caja() as j),
mcl  as (select public.admin_metricas_caja(current_date - 7, l.id) as j from l),
r(orden, comprobacion, esperado, obtenido) as (
  values
  (1,  'rol de la llamada', 'authenticated', current_user::text),
  (2,  'authenticated no ve el esquema metricas', 'false', has_schema_privilege('authenticated', 'metricas', 'usage')::text),
  (3,  'anon no puede llamar a admin_metricas_caja', 'false', has_function_privilege('anon', 'public.admin_metricas_caja(date, uuid)', 'execute')::text),
  -- Por el catálogo y no por nombre: resolver `metricas.x(...)` ya pide USAGE del esquema.
  (4,  'authenticated no puede llamar a ninguna función de metricas de Gente y Caja', '0',
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'metricas' and p.proname ~ '^(gente|caja)_'
          and has_function_privilege('authenticated', p.oid, 'execute'))::text),
  -- Gente sin local: lo de siempre.
  (10, 'tablero: registros sin local', 'number', jsonb_typeof((select j from ov)->'registered'->'count')),
  (11, 'tablero: la ventana anterior va en semanas enteras', '28', ((select (j->>'from')::date - (j->>'previous_from')::date from ov))::text),
  (12, 'embudo: seis escalones sin local', '6', jsonb_array_length((select j from fu)->'steps')::text),
  (13, 'retención: sin local, desde el registro', 'registro', (select j->>'base' from co)),
  (14, 'perfil: sin local, la base pedida', 'registrados', (select j->>'base' from pe)),
  -- Gente con local: lo del padrón no se parte.
  (20, 'tablero con local: registros null', 'null', jsonb_typeof((select j from ovl)->'registered')),
  (21, 'tablero con local: nuevas en el local', 'number', jsonb_typeof((select j from ovl)->'activated'->'count')),
  (22, 'tablero con local: el padrón no se parte', 'null', jsonb_typeof((select j from ovl)->'totals'->'registered')),
  (23, 'tablero con local: la serie sin registros', 'null', jsonb_typeof((select j from ovl)->'series'->0->'registered')),
  (24, 'embudo con local: null', 'null', jsonb_typeof((select j from ful)->'steps')),
  (25, 'uso con local: estados null', 'null', jsonb_typeof((select j from bel)->'statuses')),
  (26, 'uso con local: gente por nivel null', 'null', jsonb_typeof((select j from bel)->'levels'->0->'users')),
  (27, 'grupos con local: creados null', 'null', jsonb_typeof((select j from grl)->'groups'->'created')),
  (28, 'grupos con local: los que gastaron sí', 'number', jsonb_typeof((select j from grl)->'groups'->'with_spend')),
  (29, 'retención con local: desde la primera visita', 'primera_visita', (select j->>'base' from col)),
  (30, 'perfil con local: la base es consumieron', 'consumieron', (select j->>'base' from pel)),
  (31, 'perfil con local: registrados null', 'null', jsonb_typeof((select j from pel)->'bases'->'registrados')),
  -- Caja sin local.
  (40, 'foto: la caja del libro', 'number', jsonb_typeof((select j from cp)->'cash')),
  (41, 'foto: lo perdido no es negativo', 'true', ((select (j->>'written_off')::numeric >= 0 from cp))::text),
  (42, 'foto: por cobrar = consumo + servicio e IVA', 'true',
       ((select abs((j->'receivable'->>'payable_usd')::numeric
                   - (j->'receivable'->>'financed_usd')::numeric
                   - (j->'receivable'->>'fee_usd')::numeric) < 0.005 from cp))::text),
  (43, 'proyección: cada fila vence = consumo + servicio e IVA', '0',
       (select count(*) from fc, jsonb_array_elements(fc.j->'rows') x
        where abs((x->>'expected_gross_usd')::numeric - (x->>'expected_gross_financed_usd')::numeric
                  - (x->>'expected_gross_fee_usd')::numeric) >= 0.005)::text),
  (44, 'semana: la caja al cierre', 'number', jsonb_typeof((select j from mc)->'caja'->'al_cierre_usd')),
  (45, 'semana: ocho semanas para las chispas', '8', jsonb_array_length((select j from mc)->'semanas')::text),
  (46, 'semana: lo cobrado trae su desglose', 'true',
       ((select abs((j->'movimientos'->'cobrado'->>'payable_usd')::numeric
                   - (j->'movimientos'->'cobrado'->>'financed_usd')::numeric
                   - (j->'movimientos'->'cobrado'->>'fee_usd')::numeric) < 0.005 from mc))::text),
  (47, 'semana: el lunes de la semana', '1', (select extract(isodow from (j->'semana'->>'desde')::date)::text from mc)),
  -- Caja con local: la caja no se parte.
  (50, 'foto con local: caja null', 'null', jsonb_typeof((select j from cpl)->'cash')),
  (51, 'foto con local: lo que se le debe', 'number', jsonb_typeof((select j from cpl)->'merchant_payable')),
  (52, 'proyección con local: sin caja de partida', 'null', jsonb_typeof((select j from fcl)->'cash_now_usd')),
  (53, 'por pagar con local: solo ese local', '1', jsonb_array_length((select j from mpl))::text),
  (54, 'semana con local: caja null', 'null', jsonb_typeof((select j from mcl)->'caja')),
  (55, 'semana con local: libro null', 'null', jsonb_typeof((select j from mcl)->'movimientos'->'libro')),
  (56, 'semana con local: lo transferido al local', 'number', jsonb_typeof((select j from mcl)->'movimientos'->'transferido'->'usd'))
)
select comprobacion, esperado, obtenido, esperado is not distinct from obtenido as ok
from r
order by orden;

rollback;
