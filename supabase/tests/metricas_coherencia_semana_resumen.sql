-- ============================================================================
-- Batería de coherencia de Métricas › Semana › Resumen (dev) — SEMANA-RESUMEN
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok. Cada una
-- da una fila resumen («N filas / M cuadran») y una fila de detalle por cada
-- caso que no cuadra.
--
-- Qué se comprueba de `admin_metricas_semana_resumen`, en las 8 últimas
-- semanas, sin local y con cada local con ventas:
--   S  sus cifras = las de `admin_metricas_semanas` para la misma semana y
--      local (consumo, consumos, personas, ticket, service fee sin IVA), su
--      comparación (a la misma altura) y su chispa de 8 semanas;
--   D  sus cifras = su definición en metricas.* (fee, total a cobrar, nuevas);
--   N  cada noche y local = `admin_nights` de esa semana y local, y la suma
--      de las noches = las cifras de la semana;
--   L  las nuevas = las de `admin_metricas_locales` (fila de todos o del
--      local), y la suma por locales = el total;
--   X  el total a cobrar, el facturado, los consumos y los usuarios = los de
--      la cohorte de esa semana en Cohortes (`admin_metricas_cohortes`,
--      su `a_cobrar`);
--   F  la regla del fee: total a cobrar = facturado + service fee, y el fee =
--      sin IVA + IVA, en las cifras, la comparación, la chispa y las noches.
--
-- Solo SELECT. Se hace pasar por un admin activo (request.jwt.claims con
-- aal2) sin cambiar de rol, para poder leer metricas.* en la misma consulta.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_semana_resumen.sql
-- ============================================================================

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

with
h as (select metricas.hoy() as hoy, metricas.lunes(metricas.hoy()) as lunes_hoy),
sem as (
  select generate_series((select lunes_hoy from h) - 49, (select lunes_hoy from h), interval '7 days')::date as lunes
),
locs as (
  select null::uuid as mid, 'todos' as local
  union all
  select m.id, m.name from public.merchants m
  where not m.is_test and exists (select 1 from metricas.consumos k where k.merchant_id = m.id)
),
-- Lo de esta RPC, por semana y local.
r as materialized (
  select s.lunes, l.mid, l.local, to_char(s.lunes, 'DD-MM') || ' ' || l.local as entidad,
         least(s.lunes + 6, (select hoy from h)) as hasta,
         public.admin_metricas_semana_resumen(s.lunes, l.mid) as j
  from sem s cross join locs l
),
-- Semana a semana, una vez por local: sus 8 columnas son las 8 semanas.
w as materialized (
  select l.mid, public.admin_metricas_semanas(null, 8, l.mid) as j from locs l
),
wf as (
  select w.mid, (x->>'desde')::date as lunes, x as f, (x->>'desde')::date = (select lunes_hoy from h) as elegida
  from w cross join lateral jsonb_array_elements(w.j->'filas') x
),
rw as (
  select r.*, wf.f from r join wf on wf.lunes = r.lunes and wf.mid is not distinct from r.mid
),
-- Los locales de cada semana, una vez por semana.
lo as materialized (
  select s.lunes, public.admin_metricas_locales(s.lunes, null) as j from sem s
),
-- Las noches de admin_nights, por semana y local.
an as materialized (
  select r.lunes, r.mid, r.entidad, n.*
  from r cross join lateral public.admin_nights(14, r.mid, r.lunes) n
),
rn as (
  select r.lunes, r.mid, r.entidad, x
  from r cross join lateral jsonb_array_elements(r.j->'noches') x
),
-- Las cohortes de Cohortes, una vez por local.
co as materialized (
  select l.mid, public.admin_metricas_cohortes(l.mid) as j from locs l
),
cof as (
  select co.mid, (x->>'semana')::date as lunes, x
  from co cross join lateral jsonb_array_elements(co.j->'cohortes') x
),

-- ── S: contra admin_metricas_semanas ─────────────────────────────────────
x_s1(entidad, e, o) as (select entidad, (f->'consumo'->>'financed_usd')::numeric, (j->'cifras'->>'financed_usd')::numeric from rw),
x_s2(entidad, e, o) as (select entidad, (f->'consumo'->>'consumos')::numeric, (j->'cifras'->>'consumos')::numeric from rw),
x_s3(entidad, e, o) as (select entidad, (f->'consumo'->>'personas')::numeric, (j->'cifras'->>'personas')::numeric from rw),
x_s4(entidad, e, o) as (select entidad, (f->'consumo'->>'ticket_medio_usd')::numeric, (j->'cifras'->>'ticket_medio_usd')::numeric from rw),
x_s5(entidad, e, o) as (select entidad, (f->'ingreso'->>'servicio_usd')::numeric, (j->'cifras'->>'servicio_usd')::numeric from rw),
-- La comparación de la semana de hoy, contra la de Semana (a la misma altura).
x_s6(entidad, e, o) as (
  select r.entidad || ' ' || c.k, (w.j->'comparacion'->'consumo'->>c.k)::numeric, (r.j->'comparacion'->>c.k)::numeric
  from r join w on w.mid is not distinct from r.mid
  cross join (values ('financed_usd'), ('consumos'), ('personas'), ('ticket_medio_usd')) c(k)
  where r.lunes = (select lunes_hoy from h)
),
x_s7(entidad, o) as (
  select r.entidad,
         (r.j->'anterior'->>'desde')::date = (w.j->'comparacion'->>'desde')::date
         and (r.j->'anterior'->>'hasta')::date = (w.j->'comparacion'->>'hasta')::date
         and (r.j->'anterior'->>'misma_altura')::boolean = (w.j->'comparacion'->>'misma_altura')::boolean
  from r join w on w.mid is not distinct from r.mid
  where r.lunes = (select lunes_hoy from h)
),
-- La chispa de la semana de hoy: sus 8 semanas = las 8 columnas de Semana.
x_s8(entidad, e, o) as (
  select to_char(wf.lunes, 'DD-MM') || ' ' || r.local || ' ' || c.k,
         (wf.f->'consumo'->>c.k)::numeric, (x->>c.k)::numeric
  from r
  cross join lateral jsonb_array_elements(r.j->'semanas') x
  join wf on wf.mid is not distinct from r.mid and wf.lunes = (x->>'desde')::date
  cross join (values ('financed_usd'), ('consumos'), ('personas')) c(k)
  where r.lunes = (select lunes_hoy from h)
),
x_s9(entidad, o) as (
  select r.entidad, jsonb_array_length(r.j->'semanas') = 8
         and (r.j->'semanas'->7->>'desde')::date = r.lunes
         and (r.j->'semanas'->7->'financed_usd') = (r.j->'cifras'->'financed_usd')
         and (r.j->'semanas'->7->'personas') = (r.j->'cifras'->'personas')
  from r
),
-- Una semana cerrada se compara con la anterior entera.
x_s10(entidad, e, o) as (
  select r.entidad || ' ' || c.k, (p.j->'cifras'->>c.k)::numeric, (r.j->'comparacion'->>c.k)::numeric
  from r join r p on p.mid is not distinct from r.mid and p.lunes = r.lunes - 7
  cross join (values ('financed_usd'), ('fee_usd'), ('payable_usd'), ('consumos'), ('personas'), ('nuevas')) c(k)
  where r.lunes < (select lunes_hoy from h)
),

-- ── D: contra su definición en metricas.* ────────────────────────────────
x_d1(entidad, e, o) as (
  select r.entidad, (select coalesce(sum(k.fee_usd), 0) from metricas.consumos k
                     where k.business_date between r.lunes and r.hasta
                       and (r.mid is null or k.merchant_id = r.mid)),
         (r.j->'cifras'->>'fee_usd')::numeric from r
),
x_d2(entidad, e, o) as (
  select r.entidad, (select coalesce(sum(k.payable_usd), 0) from metricas.consumos k
                     where k.business_date between r.lunes and r.hasta
                       and (r.mid is null or k.merchant_id = r.mid)),
         (r.j->'cifras'->>'payable_usd')::numeric from r
),
x_d3(entidad, e, o) as (
  select r.entidad, (select coalesce(sum(i.amount_usd), 0) from public.installments i
                     join public.charges c on c.id = i.charge_id
                     where c.status = 'confirmed' and not c.is_test and not i.is_test
                       and c.business_date between r.lunes and r.hasta
                       and (r.mid is null or c.merchant_id = r.mid)),
         (r.j->'cifras'->>'payable_usd')::numeric from r
),
x_d4(entidad, e, o) as (
  select r.entidad, (select count(distinct pl.user_id) from metricas.personas_por_local pl
                     where pl.primer_dia between r.lunes and r.hasta
                       and (r.mid is null or pl.merchant_id = r.mid))::numeric,
         (r.j->'cifras'->>'nuevas')::numeric from r
),

-- ── N: las noches ────────────────────────────────────────────────────────
x_n1(entidad, e, o) as (
  select r.entidad, (select count(*) from an where an.lunes = r.lunes and an.mid is not distinct from r.mid)::numeric,
         jsonb_array_length(r.j->'noches')::numeric from r
),
x_n2(entidad, o) as (
  select coalesce(a.entidad, n.entidad) || ' ' || coalesce(a.business_date, (n.x->>'business_date')::date)::text
           || ' ' || coalesce(a.merchant_name, n.x->>'nombre'),
         a.business_date is not null and n.x is not null
         and a.charge_count = (n.x->>'consumos')::integer
         and abs(a.financed_usd - (n.x->>'financed_usd')::numeric) < 0.01
         and a.distinct_users = (n.x->>'personas')::integer
         and a.new_users = (n.x->>'nuevas')::integer
         and a.avg_ticket_usd = (n.x->>'ticket_medio_usd')::numeric
  from an a
  full join rn n on n.lunes = a.lunes and n.mid is not distinct from a.mid
                and (n.x->>'business_date')::date = a.business_date
                and (n.x->>'merchant_id')::uuid = a.merchant_id
),
x_n3(entidad, e, o) as (
  select r.entidad || ' ' || c.k,
         (r.j->'cifras'->>c.k)::numeric,
         (select coalesce(sum((x->>c.k)::numeric), 0) from jsonb_array_elements(r.j->'noches') x)
  from r cross join (values ('financed_usd'), ('fee_usd'), ('payable_usd'), ('consumos')) c(k)
),
x_n4(entidad, o) as (
  select r.entidad,
         (r.j->'cifras'->>'personas')::integer
           <= (select coalesce(sum((x->>'personas')::integer), 0) from jsonb_array_elements(r.j->'noches') x)
         and (r.j->'cifras'->>'personas')::integer
           >= (select coalesce(max((x->>'personas')::integer), 0) from jsonb_array_elements(r.j->'noches') x)
         and (r.j->'cifras'->>'nuevas')::integer
           <= (select coalesce(sum((x->>'nuevas')::integer), 0) from jsonb_array_elements(r.j->'noches') x)
  from r
),
x_n5(entidad, o) as (
  -- Las noches van de la más reciente a la más vieja, y dentro de la semana.
  select r.entidad,
         coalesce((select bool_and((x->>'business_date')::date between r.lunes and r.hasta)
                   from jsonb_array_elements(r.j->'noches') x), true)
         and coalesce((select bool_and(d >= lead_d) from (
                         select (x->>'business_date')::date as d,
                                lead((x->>'business_date')::date) over (order by o) as lead_d
                         from jsonb_array_elements(r.j->'noches') with ordinality t(x, o)) z
                       where lead_d is not null), true)
  from r
),

-- ── L: contra Locales, y por locales ─────────────────────────────────────
x_l1(entidad, e, o) as (
  select r.entidad,
         case when r.mid is null then (lo.j->'totales'->>'nuevas')::numeric
              else (select (x->>'nuevas')::numeric from jsonb_array_elements(lo.j->'locales') x
                    where (x->>'merchant_id')::uuid = r.mid) end,
         (r.j->'cifras'->>'nuevas')::numeric
  from r join lo on lo.lunes = r.lunes
),
x_l2(entidad, e, o) as (
  select to_char(t.lunes, 'DD-MM') || ' ' || c.k,
         (t.j->'cifras'->>c.k)::numeric,
         (select coalesce(sum((p.j->'cifras'->>c.k)::numeric), 0) from r p where p.lunes = t.lunes and p.mid is not null)
  from r t cross join (values ('financed_usd'), ('fee_usd'), ('payable_usd'), ('servicio_usd'), ('iva_usd'), ('consumos')) c(k)
  where t.mid is null
),

-- ── X: contra Cohortes ───────────────────────────────────────────────────
-- Una semana sin consumos no tiene cohorte: ahí todo vale cero.
x_x1(entidad, e, o) as (
  select r.entidad || ' ' || c.k,
         coalesce(case c.k when 'payable_usd' then (cof.x->'a_cobrar'->>'payable_usd')::numeric
                           when 'fee_usd'     then (cof.x->'a_cobrar'->>'fee_usd')::numeric
                           else (cof.x->>c.k)::numeric end, 0),
         (r.j->'cifras'->>c.k)::numeric
  from r
  left join cof on cof.lunes = r.lunes and cof.mid is not distinct from r.mid
  cross join (values ('financed_usd'), ('fee_usd'), ('payable_usd'), ('consumos'), ('personas')) c(k)
),

-- ── F: la regla del fee ──────────────────────────────────────────────────
tramos as (
  select entidad || ' cifras' as entidad, j->'cifras' as t from r
  union all select entidad || ' comparación', j->'comparacion' from r
  union all select r.entidad || ' chispa ' || (x->>'desde'), x from r cross join lateral jsonb_array_elements(r.j->'semanas') x
),
x_f1(entidad, o) as (
  select entidad,
         abs((t->>'financed_usd')::numeric + (t->>'fee_usd')::numeric - (t->>'payable_usd')::numeric) < 0.005
         and abs((t->>'servicio_usd')::numeric + (t->>'iva_usd')::numeric - (t->>'fee_usd')::numeric) < 0.005
  from tramos
),
x_f2(entidad, o) as (
  select entidad || ' ' || (x->>'business_date') || ' ' || (x->>'nombre'),
         abs((x->>'financed_usd')::numeric + (x->>'fee_usd')::numeric - (x->>'payable_usd')::numeric) < 0.005
  from rn
),

resultado as (
select '01' as orden, 'S1 Total facturado = consumo de admin_metricas_semanas (semana y local)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)), true) as ok
from x_s1 x
union all
select '01.' || x.entidad, '   S1 ' || x.entidad, coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_s1 x where not coalesce(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null), false)
union all
select '02', 'S2 Consumos = los de admin_metricas_semanas',
       count(*)::text || ' filas', (count(*) filter (where x.e is not distinct from x.o))::text || ' cuadran',
       coalesce(bool_and(x.e is not distinct from x.o), true)
from x_s2 x
union all
select '02.' || x.entidad, '   S2 ' || x.entidad, coalesce(x.e::text, 'nulo'), coalesce(x.o::text, 'nulo'), false
from x_s2 x where x.e is distinct from x.o
union all
select '03', 'S3 Usuarios que consumieron = personas de admin_metricas_semanas',
       count(*)::text || ' filas', (count(*) filter (where x.e is not distinct from x.o))::text || ' cuadran',
       coalesce(bool_and(x.e is not distinct from x.o), true)
from x_s3 x
union all
select '03.' || x.entidad, '   S3 ' || x.entidad, coalesce(x.e::text, 'nulo'), coalesce(x.o::text, 'nulo'), false
from x_s3 x where x.e is distinct from x.o
union all
select '04', 'S4 Ticket medio (sin fee) = el de admin_metricas_semanas',
       count(*)::text || ' filas',
       (count(*) filter (where coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)))::text || ' cuadran',
       coalesce(bool_and(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)), true)
from x_s4 x
union all
select '04.' || x.entidad, '   S4 ' || x.entidad, coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_s4 x where not coalesce(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null), false)
union all
select '05', 'S5 Service fee sin IVA = el ingreso de admin_metricas_semanas',
       count(*)::text || ' filas',
       (count(*) filter (where coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)))::text || ' cuadran',
       coalesce(bool_and(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)), true)
from x_s5 x
union all
select '05.' || x.entidad, '   S5 ' || x.entidad, coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_s5 x where not coalesce(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null), false)
union all
select '06', 'S6 Semana de hoy: la comparación = la de admin_metricas_semanas (a la misma altura)',
       count(*)::text || ' filas',
       (count(*) filter (where coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)))::text || ' cuadran',
       coalesce(bool_and(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)), true)
from x_s6 x
union all
select '06.' || x.entidad, '   S6 ' || x.entidad, coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_s6 x where not coalesce(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null), false)
union all
select '07', 'S7 Semana de hoy: la anterior son los mismos días que en admin_metricas_semanas',
       count(*)::text || ' filas', (count(*) filter (where x.o is true))::text || ' cuadran', coalesce(bool_and(x.o is true), true)
from x_s7 x
union all
select '07.' || x.entidad, '   S7 ' || x.entidad, 'verdadero', case when x.o then 'verdadero' else 'falso' end, false
from x_s7 x where not coalesce(x.o is true, false)
union all
select '08', 'S8 La chispa: sus 8 semanas = las 8 columnas de admin_metricas_semanas',
       count(*)::text || ' filas',
       (count(*) filter (where coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)))::text || ' cuadran',
       coalesce(bool_and(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)), true)
from x_s8 x
union all
select '08.' || x.entidad, '   S8 ' || x.entidad, coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_s8 x where not coalesce(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null), false)
union all
select '09', 'S9 La chispa lleva 8 semanas y acaba en la elegida, con sus mismas cifras',
       count(*)::text || ' filas', (count(*) filter (where x.o is true))::text || ' cuadran', coalesce(bool_and(x.o is true), true)
from x_s9 x
union all
select '09.' || x.entidad, '   S9 ' || x.entidad, 'verdadero', case when x.o then 'verdadero' else 'falso' end, false
from x_s9 x where not coalesce(x.o is true, false)
union all
select '10', 'S10 Semana cerrada: su comparación es la semana anterior entera',
       count(*)::text || ' filas',
       (count(*) filter (where coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)))::text || ' cuadran',
       coalesce(bool_and(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)), true)
from x_s10 x
union all
select '10.' || x.entidad, '   S10 ' || x.entidad, coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_s10 x where not coalesce(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null), false)
union all
select '11', 'D1 Service fee + IVA = Σ metricas.consumos.fee_usd',
       count(*)::text || ' filas',
       (count(*) filter (where coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)))::text || ' cuadran',
       coalesce(bool_and(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)), true)
from x_d1 x
union all
select '11.' || x.entidad, '   D1 ' || x.entidad, coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_d1 x where not coalesce(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null), false)
union all
select '12', 'D2 Total a cobrar = Σ metricas.consumos.payable_usd',
       count(*)::text || ' filas',
       (count(*) filter (where coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)))::text || ' cuadran',
       coalesce(bool_and(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)), true)
from x_d2 x
union all
select '12.' || x.entidad, '   D2 ' || x.entidad, coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_d2 x where not coalesce(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null), false)
union all
select '13', 'D3 Total a cobrar = Σ de las cuotas (installments.amount_usd) de esos consumos',
       count(*)::text || ' filas',
       (count(*) filter (where coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)))::text || ' cuadran',
       coalesce(bool_and(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)), true)
from x_d3 x
union all
select '13.' || x.entidad, '   D3 ' || x.entidad, coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_d3 x where not coalesce(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null), false)
union all
select '14', 'D4 Nuevas = personas con su primera cuota en un local dentro de la semana (personas_por_local)',
       count(*)::text || ' filas', (count(*) filter (where x.e is not distinct from x.o))::text || ' cuadran',
       coalesce(bool_and(x.e is not distinct from x.o), true)
from x_d4 x
union all
select '14.' || x.entidad, '   D4 ' || x.entidad, coalesce(x.e::text, 'nulo'), coalesce(x.o::text, 'nulo'), false
from x_d4 x where x.e is distinct from x.o
union all
select '15', 'N1 Tantas noches y locales como admin_nights de la semana',
       count(*)::text || ' filas', (count(*) filter (where x.e is not distinct from x.o))::text || ' cuadran',
       coalesce(bool_and(x.e is not distinct from x.o), true)
from x_n1 x
union all
select '15.' || x.entidad, '   N1 ' || x.entidad, coalesce(x.e::text, 'nulo'), coalesce(x.o::text, 'nulo'), false
from x_n1 x where x.e is distinct from x.o
union all
select '16', 'N2 Cada noche y local = admin_nights (consumos, consumo, personas, nuevas, ticket)',
       count(*)::text || ' filas', (count(*) filter (where x.o is true))::text || ' cuadran', coalesce(bool_and(x.o is true), true)
from x_n2 x
union all
select '16.' || x.entidad, '   N2 ' || x.entidad, 'verdadero', case when x.o then 'verdadero' else 'falso' end, false
from x_n2 x where not coalesce(x.o is true, false)
union all
select '17', 'N3 La suma de las noches = las cifras de la semana (facturado, fee, total a cobrar, consumos)',
       count(*)::text || ' filas',
       (count(*) filter (where coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)))::text || ' cuadran',
       coalesce(bool_and(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)), true)
from x_n3 x
union all
select '17.' || x.entidad, '   N3 ' || x.entidad, coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_n3 x where not coalesce(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null), false)
union all
select '18', 'N4 Usuarios y nuevas de la semana: recontados (≤ la suma de las noches, ≥ la noche mayor)',
       count(*)::text || ' filas', (count(*) filter (where x.o is true))::text || ' cuadran', coalesce(bool_and(x.o is true), true)
from x_n4 x
union all
select '18.' || x.entidad, '   N4 ' || x.entidad, 'verdadero', case when x.o then 'verdadero' else 'falso' end, false
from x_n4 x where not coalesce(x.o is true, false)
union all
select '19', 'N5 Las noches caen en la semana y van de la más reciente a la más vieja',
       count(*)::text || ' filas', (count(*) filter (where x.o is true))::text || ' cuadran', coalesce(bool_and(x.o is true), true)
from x_n5 x
union all
select '19.' || x.entidad, '   N5 ' || x.entidad, 'verdadero', case when x.o then 'verdadero' else 'falso' end, false
from x_n5 x where not coalesce(x.o is true, false)
union all
select '20', 'L1 Nuevas = las de admin_metricas_locales (fila de todos o del local)',
       count(*)::text || ' filas', (count(*) filter (where x.e is not distinct from x.o))::text || ' cuadran',
       coalesce(bool_and(x.e is not distinct from x.o), true)
from x_l1 x
union all
select '20.' || x.entidad, '   L1 ' || x.entidad, coalesce(x.e::text, 'nulo'), coalesce(x.o::text, 'nulo'), false
from x_l1 x where x.e is distinct from x.o
union all
select '21', 'L2 La suma por locales = el total (facturado, fee, total a cobrar, sin IVA, IVA, consumos)',
       count(*)::text || ' filas',
       (count(*) filter (where coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)))::text || ' cuadran',
       coalesce(bool_and(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)), true)
from x_l2 x
union all
select '21.' || x.entidad, '   L2 ' || x.entidad, coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_l2 x where not coalesce(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null), false)
union all
select '215', 'X1 = la cohorte de Cohortes: total a cobrar, fee, facturado, consumos y usuarios',
       count(*)::text || ' filas',
       (count(*) filter (where coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)))::text || ' cuadran',
       coalesce(bool_and(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null)), true)
from x_x1 x
union all
select '215.' || x.entidad, '   X1 ' || x.entidad, coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_x1 x where not coalesce(coalesce(abs(x.e - x.o) < 0.01, x.e is null and x.o is null), false)
union all
select '22', 'F1 Total a cobrar = facturado + service fee, y fee = sin IVA + IVA (cifras, comparación, chispa)',
       count(*)::text || ' filas', (count(*) filter (where x.o is true))::text || ' cuadran', coalesce(bool_and(x.o is true), true)
from x_f1 x
union all
select '22.' || x.entidad, '   F1 ' || x.entidad, 'verdadero', case when x.o then 'verdadero' else 'falso' end, false
from x_f1 x where not coalesce(x.o is true, false)
union all
select '23', 'F2 Cada noche: total a cobrar = facturado + service fee',
       count(*)::text || ' filas', (count(*) filter (where x.o is true))::text || ' cuadran', coalesce(bool_and(x.o is true), true)
from x_f2 x
union all
select '23.' || x.entidad, '   F2 ' || x.entidad, 'verdadero', case when x.o then 'verdadero' else 'falso' end, false
from x_f2 x where not coalesce(x.o is true, false)
)
select comprobacion, esperado, obtenido, ok
from resultado
order by orden;
