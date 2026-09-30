-- ============================================================================
-- Batería de coherencia de ALG3 (dev): el escalón «Listos para consumir»
--
-- 20260927630000 cambia el rótulo del escalón `listos` del embudo de Gente
-- («Terminaron de darse de alta» → «Listos para consumir»). Es un escalón
-- acumulado: los registros que ya crearon su PIN, hayan consumido o no. El
-- panel dice en la caída hacia «Consumieron al menos una vez» cuántos listos
-- aún no han consumido (listos − compraron), así que esa resta no puede salir
-- negativa: nadie consume sin estar listo.
--
-- 20260927680000 (AUD-CAJA-LOCALES-GENTE) lo renombra a «Crearon su PIN»,
-- que es lo que cuenta; A1 comprueba ya el rótulo nuevo.
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok, como las
-- demás baterías. Solo SELECT; se hace pasar por un admin activo.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_alg3.sql
-- ============================================================================

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

with
h   as (select metricas.hoy() as hoy),
emb as (select public.admin_growth_funnel(metricas.gente_primer_dia(), (select hoy from h)) as j),
gro as (select public.admin_growth_overview(metricas.gente_primer_dia(), (select hoy from h)) as j),
paso as (
  select e.s->>'key' as clave, e.s->>'label' as rotulo, (e.s->>'users')::int as n, e.o as orden
  from emb, jsonb_array_elements(emb.j->'steps') with ordinality as e(s, o)
),
-- Las doce últimas semanas, cada una con su embudo.
semanas as (
  select metricas.lunes((select hoy from h)) - 7 * k as lunes
  from generate_series(0, 11) as k
),
por_semana as (
  select s.lunes,
         (select (x->>'users')::int from jsonb_array_elements(f.j->'steps') x where x->>'key' = 'listos')    as listos,
         (select (x->>'users')::int from jsonb_array_elements(f.j->'steps') x where x->>'key' = 'compraron') as compraron
  from semanas s
  cross join lateral (select public.admin_growth_funnel(s.lunes, least(s.lunes + 6, (select hoy from h))) as j) f
),
un_local as (select id from public.merchants where not is_test order by created_at limit 1),

n(orden, comprobacion, e, o) as (
  select '001', 'A1 El escalón listos se llama «Crearon su PIN»',
    'Crearon su PIN', (select rotulo from paso where clave = 'listos')
  union all select '002', 'A2 Las claves del embudo no cambian, ni su orden',
    'pidieron,confirmaron,registrados,listos,compraron,repitieron',
    (select string_agg(clave, ',' order by orden) from paso)
  union all select '003', 'A3 Desde el inicio: listos del embudo = «Listos para consumir» de Todos los usuarios (totals.onboarded)',
    (select n::text from paso where clave = 'listos'), (select j->'totals'->>'onboarded' from gro)
  union all select '004', 'A4 Desde el inicio: consumieron del embudo = «Han comprado alguna vez» (totals.ever_bought)',
    (select n::text from paso where clave = 'compraron'), (select j->'totals'->>'ever_bought' from gro)
  union all select '005', 'A5 Desde el inicio: aún no han consumido (listos − compraron) no es negativo',
    'verdadero',
    (select case when l.n >= c.n then 'verdadero' else 'falso' end
     from paso l join paso c on l.clave = 'listos' and c.clave = 'compraron')
  union all select '006', 'A6 12 semanas: en ninguna salen más consumieron que listos',
    '12 semanas', (select count(*) filter (where compraron <= listos)::text || ' semanas' from por_semana)
  union all select '007', 'A7 Con un local, el embudo sigue valiendo null (no se parte)',
    'null', (select (public.admin_growth_funnel(null, null, id)->'steps')::text from un_local)
)
select comprobacion, coalesce(e, 'nulo') as esperado, coalesce(o, 'nulo') as obtenido,
       e is not distinct from o and e is not null as ok
from n
order by orden;
