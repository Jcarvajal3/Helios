-- ============================================================================
-- Batería de coherencia de LOCALES (Métricas › Locales), en dev
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok. «Esperado»
-- es la definición canónica (esquema metricas y, para el dinero de los
-- locales, las liquidaciones que lee Pagos a locales); «obtenido», lo que
-- devuelve la RPC que pinta el panel. Se mira la semana en curso y una
-- cerrada (la de hace dos), todos los locales y cada uno.
--
-- Qué se cruza:
--   L  admin_metricas_locales contra metricas.* (consumo, personas, nuevas,
--      a la misma altura, vencido al cierre, cobro a tiempo), la suma de los
--      locales contra el total, y el cierre del lunes contra
--      admin_settlement_runs y helios_settlement_outlook.
--   S  la serie y las cohortes contra metricas.*, y el total de la semana
--      contra admin_weekly_summary (lo que usa Semana): una cifra, un valor.
--   N  admin_nights con la semana, contra la fila del local.
--   F  admin_merchant_stats con la semana, contra la fila y cartera_al.
--   P  la respuesta con un local = su fila en la de todos.
--
-- Solo SELECT. Se hace pasar por un admin activo con request.jwt.claims sin
-- cambiar de rol (las RPC son security definer y solo miran auth.uid(); así
-- la misma consulta puede leer metricas.*, que authenticated no ve).
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_locales.sql
-- ============================================================================

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

with
h as (select metricas.hoy() as hoy, public.helios_on_time_grace_days() as gracia),
sem as (
  select s.etiqueta, s.lunes, s.lunes + 6 as domingo, least(s.lunes + 6, h.hoy) as hasta, s.lunes + 7 as cierre,
         public.admin_metricas_locales(s.lunes, null) as j
  from h, lateral (values ('en curso', metricas.lunes(h.hoy)), ('cerrada', metricas.lunes(h.hoy) - 14)) s(etiqueta, lunes)
),
fila as (
  select s.etiqueta, s.lunes, s.domingo, s.hasta, s.cierre,
         (x->>'merchant_id')::uuid as mid, x->>'nombre' as nombre, x
  from sem s, jsonb_array_elements(s.j->'locales') x
),
tot as (select s.*, s.j->'totales' as t from sem s),
mc as (select * from metricas.consumos),
mq as (select * from metricas.cuotas),
ppl as (select * from metricas.personas_por_local),
cart as (
  select f.etiqueta, f.mid, c.*
  from fila f, lateral metricas.cartera_al(f.domingo, f.mid) c
),
runs as (
  select (x->>'run_date')::date as run_date, (x->>'generado_usd')::numeric as generado
  from jsonb_array_elements(public.admin_settlement_runs()) x
),
semana_resumen as (
  select (x->>'week_start')::date as lunes, x
  from jsonb_array_elements(public.admin_weekly_summary(12)->'rows') x
),
noches as (
  select f.etiqueta, f.mid, n.*
  from fila f, lateral public.admin_nights(7, f.mid, f.lunes) n
),
stats as (
  select f.etiqueta, f.mid, public.admin_merchant_stats(f.mid, 7, f.lunes) as s
  from fila f
),
checks(orden, comprobacion, e, o) as (
  -- ── L: la semana ─────────────────────────────────────────────────────────
  select '01 ' || t.etiqueta, 'L1 Consumo de todos (' || t.etiqueta || ')',
         (select coalesce(sum(k.financed_usd), 0) from mc k where k.business_date between t.lunes and t.hasta),
         (t.t->>'consumo_usd')::numeric
  from tot t
  union all
  select '02 ' || t.etiqueta, 'L2 La suma del consumo por local = el de todos (' || t.etiqueta || ')',
         (t.t->>'consumo_usd')::numeric,
         (select coalesce(sum((f.x->>'consumo_usd')::numeric), 0) from fila f where f.etiqueta = t.etiqueta)
  from tot t
  union all
  select '03 ' || t.etiqueta, 'L3 Consumos de todos, y la suma por local (' || t.etiqueta || ')',
         (select count(*) from mc k where k.business_date between t.lunes and t.hasta),
         (select coalesce(sum((f.x->>'consumos')::numeric), 0) from fila f where f.etiqueta = t.etiqueta)
  from tot t
  union all
  select '04 ' || f.etiqueta || f.nombre, 'L4 Consumo · ' || f.nombre || ' (' || f.etiqueta || ')',
         (select coalesce(sum(k.financed_usd), 0) from mc k where k.merchant_id = f.mid and k.business_date between f.lunes and f.hasta),
         (f.x->>'consumo_usd')::numeric
  from fila f
  union all
  select '05 ' || f.etiqueta || f.nombre, 'L5 Personas (por cuotas) · ' || f.nombre || ' (' || f.etiqueta || ')',
         (select count(distinct q.user_id) from mq q where q.merchant_id = f.mid and q.business_date between f.lunes and f.hasta),
         (f.x->>'personas')::numeric
  from fila f
  union all
  select '06 ' || t.etiqueta, 'L6 Personas de todos, recontadas (' || t.etiqueta || ')',
         (select count(distinct q.user_id) from mq q where q.business_date between t.lunes and t.hasta),
         (t.t->>'personas')::numeric
  from tot t
  union all
  select '07 ' || f.etiqueta || f.nombre, 'L7 Primer consumo aquí · ' || f.nombre || ' (' || f.etiqueta || ')',
         (select count(*) from ppl p where p.merchant_id = f.mid and p.primer_semana = f.lunes),
         (f.x->>'nuevas')::numeric
  from fila f
  union all
  select '08 ' || t.etiqueta, 'L8 Primer consumo en algún local, recontado (' || t.etiqueta || ')',
         (select count(distinct p.user_id) from ppl p where p.primer_semana = t.lunes),
         (t.t->>'nuevas')::numeric
  from tot t
  union all
  select '09 ' || f.etiqueta || f.nombre, 'L9 Consumo de la anterior a la misma altura · ' || f.nombre || ' (' || f.etiqueta || ')',
         (select coalesce(sum(k.financed_usd), 0) from mc k where k.merchant_id = f.mid and k.business_date between f.lunes - 7 and f.hasta - 7),
         (f.x->>'consumo_anterior_usd')::numeric
  from fila f
  union all
  select '10 ' || f.etiqueta || f.nombre, 'L10 Vencido de su gente (payable) = cartera_al · ' || f.nombre || ' (' || f.etiqueta || ')',
         c.vencido_payable_usd, (f.x->'vencido'->>'payable_usd')::numeric
  from fila f join cart c on c.etiqueta = f.etiqueta and c.mid = f.mid
  union all
  select '11 ' || f.etiqueta || f.nombre, 'L11 Vencido: consumo = cartera_al · ' || f.nombre || ' (' || f.etiqueta || ')',
         c.vencido_financed_usd, (f.x->'vencido'->>'financed_usd')::numeric
  from fila f join cart c on c.etiqueta = f.etiqueta and c.mid = f.mid
  union all
  select '12 ' || f.etiqueta || f.nombre, 'L12 Vencido: servicio e IVA = cartera_al · ' || f.nombre || ' (' || f.etiqueta || ')',
         c.vencido_fee_usd, (f.x->'vencido'->>'fee_usd')::numeric
  from fila f join cart c on c.etiqueta = f.etiqueta and c.mid = f.mid
  union all
  select '13 ' || t.etiqueta, 'L13 Vencido de todos = cartera_al de toda la cartera (' || t.etiqueta || ')',
         (select c.vencido_payable_usd from metricas.cartera_al(t.domingo, null) c),
         (t.t->'vencido'->>'payable_usd')::numeric
  from tot t
  union all
  select '14 ' || t.etiqueta, 'L14 La suma del vencido por local = el de todos (' || t.etiqueta || ')',
         (t.t->'vencido'->>'payable_usd')::numeric,
         (select coalesce(sum((f.x->'vencido'->>'payable_usd')::numeric), 0) from fila f where f.etiqueta = t.etiqueta)
  from tot t
  union all
  select '15 ' || t.etiqueta, 'L15 Vencido de todos: payable = consumo + servicio e IVA (' || t.etiqueta || ')',
         (t.t->'vencido'->>'payable_usd')::numeric,
         (t.t->'vencido'->>'financed_usd')::numeric + (t.t->'vencido'->>'fee_usd')::numeric
  from tot t
  union all
  select '16 ' || f.etiqueta || f.nombre, 'L16 Cuotas de la semana juzgadas · ' || f.nombre || ' (' || f.etiqueta || ')',
         (select count(*) from mq q where q.merchant_id = f.mid and q.due_date between f.lunes and f.domingo and q.plazo_cerrado),
         (f.x->'a_tiempo'->>'juzgadas')::numeric
  from fila f
  union all
  select '17 ' || f.etiqueta || f.nombre, 'L17 Cobrado a tiempo (tasa) · ' || f.nombre || ' (' || f.etiqueta || ')',
         (select round(100.0 * count(*) filter (where q.estado_hoy = 'a_tiempo') / nullif(count(*), 0), 1)
          from mq q where q.merchant_id = f.mid and q.due_date between f.lunes and f.domingo and q.plazo_cerrado),
         (f.x->'a_tiempo'->>'pct')::numeric
  from fila f
  union all
  select '18 ' || t.etiqueta, 'L18 La suma de las juzgadas por local = las de todos (' || t.etiqueta || ')',
         (t.t->'a_tiempo'->>'juzgadas')::numeric,
         (select coalesce(sum((f.x->'a_tiempo'->>'juzgadas')::numeric), 0) from fila f where f.etiqueta = t.etiqueta)
  from tot t
  union all
  select '19 ' || f.etiqueta || f.nombre, 'L19 Cierre del lunes: generado = liquidaciones de ese cierre · ' || f.nombre || ' (' || f.etiqueta || ')',
         (select coalesce(sum(s.amount_usd), 0) from public.settlements s
          where s.merchant_id = f.mid and public.helios_settlement_run_for(coalesce(s.due_date, s.business_date)) = f.cierre),
         (f.x->'transferencia'->>'generado_usd')::numeric
  from fila f
  union all
  select '20 ' || t.etiqueta, 'L20 Cierre del lunes: generado de todos = Pagos a locales (admin_settlement_runs) (' || t.etiqueta || ')',
         coalesce((select r.generado from runs r where r.run_date = t.cierre), 0),
         (t.t->'transferencia'->>'generado_usd')::numeric
  from tot t
  union all
  -- Solo cuando el próximo cierre ES el de la semana (no un lunes antes de
  -- las 10:00): lo pendiente + lo previsto + lo atrasado = lo que el outlook
  -- dice que sale en el próximo cierre («toca pagar este lunes» de Caja).
  select '21 ' || f.etiqueta || f.nombre, 'L21 Cierre en curso: pendiente + previsto + atrasado = outlook.next_run_usd (Caja) · ' || f.nombre,
         o.next_run_usd,
         (f.x->'transferencia'->>'pendiente_usd')::numeric + (f.x->'transferencia'->>'previsto_usd')::numeric
           + (f.x->'transferencia'->>'atrasado_usd')::numeric
  from fila f, lateral public.helios_settlement_outlook(f.mid) o
  where f.etiqueta = 'en curso' and o.next_run_date = f.cierre
  union all
  select '22 ' || f.etiqueta || f.nombre, 'L22 Cierre en curso: atrasado = outlook.overdue_usd · ' || f.nombre,
         o.overdue_usd, (f.x->'transferencia'->>'atrasado_usd')::numeric
  from fila f, lateral public.helios_settlement_outlook(f.mid) o
  where f.etiqueta = 'en curso' and o.next_run_date = f.cierre
  union all
  select '23 ' || t.etiqueta, 'L23 Una semana cerrada no tiene previsto ni atrasado (' || t.etiqueta || ')',
         0,
         (t.t->'transferencia'->>'previsto_usd')::numeric + (t.t->'transferencia'->>'atrasado_usd')::numeric
  from tot t
  where t.etiqueta = 'cerrada'
  union all
  -- ── S: la serie, las cohortes y la pestaña Semana ────────────────────────
  select '30 ' || f.etiqueta || f.nombre, 'S1 La serie: la última semana = la fila · ' || f.nombre || ' (' || f.etiqueta || ')',
         (f.x->>'consumo_usd')::numeric,
         (select (sl->'consumo_usd'->>-1)::numeric
          from sem s, jsonb_array_elements(s.j->'series'->'locales') sl
          where s.etiqueta = f.etiqueta and (sl->>'merchant_id')::uuid = f.mid)
  from fila f
  where (f.x->>'consumo_usd')::numeric > 0
  union all
  select '31 ' || w.i, 'S2 La serie: la suma de los locales = el consumo de la semana ' || (s.j->'series'->'semanas'->>(w.i - 1)),
         (select coalesce(sum(k.financed_usd), 0) from mc k
          where k.semana = (s.j->'series'->'semanas'->>(w.i - 1))::date and k.business_date <= (select hoy from h)),
         (select coalesce(sum((sl->'consumo_usd'->>(w.i - 1))::numeric), 0) from jsonb_array_elements(s.j->'series'->'locales') sl)
  from sem s, generate_series(1, 12) w(i)
  where s.etiqueta = 'en curso'
  union all
  select '32 ' || t.etiqueta, 'S3 El consumo de todos = el de Semana (admin_weekly_summary) (' || t.etiqueta || ')',
         (r.x->>'financed_usd')::numeric, (t.t->>'consumo_usd')::numeric
  from tot t join semana_resumen r on r.lunes = t.lunes
  union all
  select '33 ' || t.etiqueta, 'S4 Las personas de todos = las de Semana (admin_weekly_summary) (' || t.etiqueta || ')',
         (r.x->>'active_users')::numeric, (t.t->>'personas')::numeric
  from tot t join semana_resumen r on r.lunes = t.lunes
  union all
  select '34 ' || t.etiqueta, 'S5 El vencido de todos al cierre = el de Semana (admin_weekly_summary) (' || t.etiqueta || ')',
         (r.x->>'overdue_debt_usd')::numeric, (t.t->'vencido'->>'payable_usd')::numeric
  from tot t join semana_resumen r on r.lunes = t.lunes
  union all
  select '35 ' || (cl->>'nombre') || (cs->>'semana') || n.n, 'S6 Cohorte ' || (cs->>'semana') || ' cuota ' || n.n || ': cuotas · ' || (cl->>'nombre'),
         (select count(*) from mq q
          where q.merchant_id = (cl->>'merchant_id')::uuid and q.semana = (cs->>'semana')::date and q.sequence = n.n),
         coalesce((cs->('cuota_' || n.n)->>'cuotas')::numeric, 0)
  from sem s, jsonb_array_elements(s.j->'cohortes'->'locales') cl, jsonb_array_elements(cl->'semanas') cs,
       (values (1), (2)) n(n)
  where s.etiqueta = 'en curso'
  union all
  select '36 ' || (cl->>'nombre') || (cs->>'semana') || n.n, 'S7 Cohorte ' || (cs->>'semana') || ' cuota ' || n.n || ': a tiempo (tasa) · ' || (cl->>'nombre'),
         (select round(100.0 * count(*) filter (where q.estado_hoy = 'a_tiempo') / nullif(count(*), 0), 1)
          from mq q
          where q.merchant_id = (cl->>'merchant_id')::uuid and q.semana = (cs->>'semana')::date and q.sequence = n.n
            and q.plazo_cerrado),
         (cs->('cuota_' || n.n)->>'pct_a_tiempo')::numeric
  from sem s, jsonb_array_elements(s.j->'cohortes'->'locales') cl, jsonb_array_elements(cl->'semanas') cs,
       (values (1), (2)) n(n)
  where s.etiqueta = 'en curso'
  union all
  select '37 ' || (cl->>'nombre') || (cs->>'semana') || n.n, 'S8 Cohorte ' || (cs->>'semana') || ' cuota ' || n.n || ': los cinco estados suman las cuotas · ' || (cl->>'nombre'),
         coalesce((cs->('cuota_' || n.n)->>'cuotas')::numeric, 0),
         coalesce((cs->('cuota_' || n.n)->>'a_tiempo')::numeric + (cs->('cuota_' || n.n)->>'tarde')::numeric
                  + (cs->('cuota_' || n.n)->>'vencidas')::numeric + (cs->('cuota_' || n.n)->>'por_vencer')::numeric
                  + (cs->('cuota_' || n.n)->>'perdidas')::numeric, 0)
  from sem s, jsonb_array_elements(s.j->'cohortes'->'locales') cl, jsonb_array_elements(cl->'semanas') cs,
       (values (1), (2)) n(n)
  where s.etiqueta = 'en curso'
  union all
  -- ── N: sus noches ────────────────────────────────────────────────────────
  select '40 ' || f.etiqueta || f.nombre, 'N1 Sus noches suman su consumo · ' || f.nombre || ' (' || f.etiqueta || ')',
         (f.x->>'consumo_usd')::numeric,
         (select coalesce(sum(n.financed_usd), 0) from noches n where n.etiqueta = f.etiqueta and n.mid = f.mid)
  from fila f
  union all
  select '41 ' || f.etiqueta || f.nombre, 'N2 Sus noches: cuántas = las de la fila · ' || f.nombre || ' (' || f.etiqueta || ')',
         (f.x->>'noches')::numeric,
         (select count(*) from noches n where n.etiqueta = f.etiqueta and n.mid = f.mid)
  from fila f
  union all
  select '42 ' || n.etiqueta || n.mid || n.business_date, 'N3 Personas de la noche ' || n.business_date || ' (por cuotas) · ' || f.nombre,
         (select count(distinct q.user_id) from mq q where q.merchant_id = n.mid and q.business_date = n.business_date),
         n.distinct_users
  from noches n join fila f on f.etiqueta = n.etiqueta and f.mid = n.mid
  union all
  select '43 ' || f.etiqueta || f.nombre, 'N4 Sus noches no salen de la semana · ' || f.nombre || ' (' || f.etiqueta || ')',
         0,
         (select count(*) from noches n where n.etiqueta = f.etiqueta and n.mid = f.mid
                                          and n.business_date not between f.lunes and f.hasta)
  from fila f
  union all
  -- ── F: la cartera del local ──────────────────────────────────────────────
  select '50 ' || f.etiqueta || f.nombre, 'F1 admin_merchant_stats con la semana: consumo = la fila · ' || f.nombre || ' (' || f.etiqueta || ')',
         (f.x->>'consumo_usd')::numeric, (s.s->>'financed_usd')::numeric
  from fila f join stats s on s.etiqueta = f.etiqueta and s.mid = f.mid
  union all
  select '51 ' || f.etiqueta || f.nombre, 'F2 admin_merchant_stats con la semana: personas = la fila · ' || f.nombre || ' (' || f.etiqueta || ')',
         (f.x->>'personas')::numeric, (s.s->>'distinct_users')::numeric
  from fila f join stats s on s.etiqueta = f.etiqueta and s.mid = f.mid
  union all
  select '52 ' || f.etiqueta || f.nombre, 'F3 admin_merchant_stats con la semana: vencido = la fila · ' || f.nombre || ' (' || f.etiqueta || ')',
         (f.x->'vencido'->>'payable_usd')::numeric, (s.s->'portfolio'->>'overdue_usd')::numeric
  from fila f join stats s on s.etiqueta = f.etiqueta and s.mid = f.mid
  union all
  select '53 ' || f.etiqueta || f.nombre, 'F4 admin_merchant_stats con la semana: mora = cartera_al · ' || f.nombre || ' (' || f.etiqueta || ')',
         coalesce(c.mora_pct, 0), (s.s->'portfolio'->>'arrears_pct')::numeric
  from fila f
  join stats s on s.etiqueta = f.etiqueta and s.mid = f.mid
  join cart c on c.etiqueta = f.etiqueta and c.mid = f.mid
  union all
  -- ── P: con un local, lo mismo que en la de todos ─────────────────────────
  select '60 ' || f.etiqueta || f.nombre, 'P1 Con el local elegido, su fila es la misma que en la de todos · ' || f.nombre || ' (' || f.etiqueta || ')',
         1,
         case when public.admin_metricas_locales(f.lunes, f.mid)->'locales'->0 = f.x then 1 else 0 end
  from fila f
)
select comprobacion, e::text as esperado, o::text as obtenido,
       coalesce(abs(e - o) < 0.005, e is null and o is null) as ok
from checks
order by orden;
