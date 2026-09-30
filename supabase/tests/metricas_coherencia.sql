-- ============================================================================
-- Batería de coherencia de las métricas (dev)
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok. «Esperado»
-- es la definición canónica (esquema metricas, 20260927500000); «obtenido»,
-- lo que devuelve la RPC que pinta el panel. Las comprobaciones por noche,
-- local, semana, día o mes dan una fila resumen («N filas / M cuadran») y
-- una fila de detalle por cada una que no cuadra.
--
-- Solo SELECT. Se hace pasar por un admin activo poniendo request.jwt.claims
-- (con aal2, por si el segundo factor está exigido). NO cambia el rol a
-- authenticated: las RPC son security definer y solo miran auth.uid(), y así
-- la misma consulta puede leer metricas.*, que authenticated no ve.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia.sql
--
-- Generada junto con metricas_coherencia_prod_antes.sql desde la misma lista
-- de comprobaciones: si se añade una, que sea en las dos.
-- ============================================================================

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

with
h as (select metricas.hoy() as hoy, public.helios_on_time_grace_days() as gracia),
mc as (select * from metricas.consumos),
mq as (select * from metricas.cuotas),
mp as (select * from metricas.personas),
ms as (select * from metricas.solicitudes),
mppl as (select * from metricas.personas_por_local),
mca as (select * from metricas.cargos_por_atraso),
r_nights as (select n.*, m.name as local from public.admin_nights(30, null) n join public.merchants m on m.id = n.merchant_id),
r_stats as (
  select m.id as merchant_id, m.name as local, public.admin_merchant_stats(m.id, 30) as j
  from public.merchants m
  where not m.is_test and exists (select 1 from mc k where k.merchant_id = m.id)
),
r_risk as (select r.* from public.admin_merchant_risk(90) r),
r_perf as (select public.admin_merchant_performance(null, null) as j),
r_week as (
  select (x->>'week_start')::date as lunes, x
  from jsonb_array_elements(public.admin_weekly_summary(12)->'rows') x
),
r_day as (select d.* from public.admin_daily_series(30) d),
r_over as (select public.admin_overview(30) as j),
r_coh as (
  select x->>'month' as mes, x
  from jsonb_array_elements(public.admin_credit_cohorts(6)->'rows') x
),
r_ontime as (select public.admin_on_time_collection(30) as j),
r_growth as (select public.admin_growth_overview(null, null) as j),
r_behavior as (select public.admin_user_behavior(null, null) as j),
r_groups as (select public.admin_group_metrics(null, null) as j),
r_unit as (select public.admin_unit_economics(null, null) as j),
x_a5(entidad, e, o) as (
  select s.semana::text, s.consumo, coalesce(q.cuotas, 0)
   from (select semana, sum(financed_usd) as consumo from mc group by semana) s
   left join (select semana, sum(financed_usd) filter (where sequence in (1, 2)) as cuotas from mq group by semana) q
     on q.semana = s.semana
),
x_b1(entidad, e, o) as (
  select n.business_date::text || ' ' || n.local, (select count(distinct q.user_id) from mq q
                     where q.business_date = n.business_date and q.merchant_id = n.merchant_id),
          n.distinct_users from r_nights n
),
x_b2(entidad, e, o) as (
  select n.business_date::text || ' ' || n.local, (select count(*) from mppl p
                     where p.merchant_id = n.merchant_id and p.primer_dia = n.business_date),
          n.new_users from r_nights n
),
x_b3(entidad, e, o) as (
  select n.business_date::text || ' ' || n.local, (select count(*) from mc k
                     where k.business_date = n.business_date and k.merchant_id = n.merchant_id),
          n.charge_count from r_nights n
),
x_b4(entidad, e, o) as (
  select n.business_date::text || ' ' || n.local, (select coalesce(sum(k.financed_usd), 0) from mc k
                     where k.business_date = n.business_date and k.merchant_id = n.merchant_id),
          n.financed_usd from r_nights n
),
x_c1(entidad, e, o) as (
  select s.local, (select count(distinct q.user_id) from mq q, h
                    where q.merchant_id = s.merchant_id and q.business_date between h.hoy - 29 and h.hoy),
          (s.j->>'distinct_users')::numeric from r_stats s
),
x_c2(entidad, e, o) as (
  select s.local, (select coalesce(sum(k.financed_usd), 0) from mc k where k.merchant_id = s.merchant_id and k.business_date between (select hoy from h) - 29 and (select hoy from h)),
          (s.j->>'financed_usd')::numeric from r_stats s
),
x_c3(entidad, e, o) as (
  select s.local, coalesce((select round(100 * coalesce(sum(q.payable_usd) filter (where q.estado_hoy = 'vencida'), 0)
          / nullif(sum(q.payable_usd) filter (where q.estado_hoy in ('vencida', 'por_vencer')), 0), 2)
    from mq q where q.merchant_id = s.merchant_id), 0),
          (s.j->'portfolio'->>'arrears_pct')::numeric from r_stats s
),
x_c4(entidad, e, o) as (
  select s.local, (select round(100.0 * count(*) filter (where q.estado_hoy = 'a_tiempo')
                                   / nullif(count(*), 0), 1)
                    from mq q where q.merchant_id = s.merchant_id and q.plazo_cerrado),
          (s.j->'portfolio'->>'on_time_pct')::numeric from r_stats s
),
x_c5(entidad, e, o) as (
  select s.local, (select count(*) from mq q where q.merchant_id = s.merchant_id and q.plazo_cerrado),
          (s.j->'portfolio'->>'due_count')::numeric from r_stats s
),
x_c6(entidad, e, o) as (
  select r.merchant_name, (select count(distinct q.user_id) from mq q where q.merchant_id = r.merchant_id and q.business_date between (select hoy from h) - 89 and (select hoy from h)),
          r.distinct_users from r_risk r
),
x_c7(entidad, e, o) as (
  select r.merchant_name, (select coalesce(sum(k.financed_usd), 0) from mc k where k.merchant_id = r.merchant_id and k.business_date between (select hoy from h) - 89 and (select hoy from h)),
          r.financed_usd from r_risk r
),
x_c8(entidad, e, o) as (
  select r.merchant_name, (select round(100 * coalesce(sum(q.payable_usd) filter (where q.estado_hoy = 'vencida'), 0)
          / nullif(sum(q.payable_usd) filter (where q.estado_hoy in ('vencida', 'por_vencer')), 0), 2)
    from mq q where q.merchant_id = r.merchant_id and q.business_date between (select hoy from h) - 89 and (select hoy from h)),
          r.overdue_debt_pct from r_risk r
),
x_c9(entidad, e, o) as (
  select r.merchant_name, coalesce((select round(100 * coalesce(sum(q.payable_usd) filter (where q.estado_hoy = 'vencida'), 0)
          / nullif(sum(q.payable_usd) filter (where q.estado_hoy in ('vencida', 'por_vencer')), 0), 2)
    from mq q where q.merchant_id = r.merchant_id and q.business_date between (select hoy from h) - 89 and (select hoy from h)), 0),
          r.arrears_pct from r_risk r
),
x_c14(entidad, e, o) as (
  select l->>'nombre', (select count(distinct q.user_id) from mq q
                         where q.merchant_id = (l->>'merchant_id')::uuid and q.business_date between (p.j->>'desde')::date and (p.j->>'hasta')::date),
          (l->>'personas')::numeric
   from r_perf p, jsonb_array_elements(p.j->'locales') l
),
x_c15(entidad, e, o) as (
  select l->>'nombre', (select count(*) from mppl x
                         where x.merchant_id = (l->>'merchant_id')::uuid and x.primer_dia between (p.j->>'desde')::date and (p.j->>'hasta')::date),
          (l->>'nuevas')::numeric
   from r_perf p, jsonb_array_elements(p.j->'locales') l
),
x_d1(entidad, e, o) as (
  select w.lunes::text, (select coalesce(sum(k.financed_usd), 0) from mc k where k.semana = w.lunes), (w.x->>'financed_usd')::numeric from r_week w
),
x_d2(entidad, e, o) as (
  select w.lunes::text, (select count(*) from mc k where k.semana = w.lunes), (w.x->>'charge_count')::numeric from r_week w
),
x_d3(entidad, e, o) as (
  select w.lunes::text, (select count(distinct q.user_id) from mq q where q.semana = w.lunes), (w.x->>'active_users')::numeric from r_week w
),
x_d4(entidad, e, o) as (
  select w.lunes::text, (select coalesce(sum(k.servicio_usd), 0) from mc k where k.semana = w.lunes), (w.x->>'service_fee_usd')::numeric from r_week w
),
x_d5(entidad, e, o) as (
  select w.lunes::text, (select count(*) from mp p where p.registro_semana = w.lunes), (w.x->>'new_users')::numeric from r_week w
),
x_d6(entidad, e, o) as (
  select w.lunes::text, (select count(*) from mp p where p.primer_consumo_semana = w.lunes), (w.x->>'first_time_buyers')::numeric from r_week w
),
x_d8(entidad, e, o) as (
  select w.lunes::text, (select coalesce(sum(a.amount_usd), 0) from mca a where a.semana = w.lunes), (w.x->>'late_fee_usd')::numeric from r_week w
),
x_d7(entidad, e, o) as (
  select w.lunes::text, (select (select c.mora_pct from metricas.cartera_al(least(w.lunes + 6, hh.hoy)) c) from h hh), (w.x->>'overdue_pct')::numeric from r_week w
),
x_e1(entidad, e, o) as (
  select d.business_date::text, (select coalesce(sum(k.financed_usd), 0) from mc k where k.business_date = d.business_date), (d.financed_usd)::numeric from r_day d
),
x_e2(entidad, e, o) as (
  select d.business_date::text, (select count(*) from mc k where k.business_date = d.business_date), (d.charge_count)::numeric from r_day d
),
x_e3(entidad, e, o) as (
  select d.business_date::text, (select count(distinct q.user_id) from mq q where q.business_date = d.business_date), (d.active_users)::numeric from r_day d
),
x_e4(entidad, e, o) as (
  select d.business_date::text, (select coalesce(sum(k.servicio_usd), 0) from mc k where k.business_date = d.business_date), (d.service_fee_usd)::numeric from r_day d
),
x_e5(entidad, e, o) as (
  select d.business_date::text, (select count(*) from mp p where p.registro_dia = d.business_date), (d.new_users)::numeric from r_day d
),
x_e7(entidad, e, o) as (
  select d.business_date::text, (select coalesce(sum(a.amount_usd), 0) from mca a where a.business_date = d.business_date), (d.late_fee_usd)::numeric from r_day d
),
x_e6(entidad, e, o) as (
  select d.business_date::text, (select count(*) from mp p where p.primer_consumo_dia = d.business_date), (d.first_time_buyers)::numeric from r_day d
),
x_g1(entidad, e, o) as (
  select c.mes, (select count(distinct q.user_id) from mq q where to_char(q.business_date, 'YYYY-MM') = c.mes), (c.x->>'user_count')::numeric from r_coh c
),
x_g2(entidad, e, o) as (
  select c.mes, (select count(distinct q.user_id) from mq q where to_char(q.business_date, 'YYYY-MM') = c.mes), (c.x->>'people_count')::numeric from r_coh c
),
x_g3(entidad, e, o) as (
  select c.mes, (select coalesce(sum(k.financed_usd), 0) from mc k where to_char(k.business_date, 'YYYY-MM') = c.mes), (c.x->>'financed_usd')::numeric from r_coh c
),
x_g4(entidad, e, o) as (
  select c.mes, (select coalesce(sum(k.financed_usd), 0) from mc k where to_char(k.business_date, 'YYYY-MM') = c.mes), (c.x->>'financed_volume_usd')::numeric from r_coh c
),
x_g5(entidad, e, o) as (
  select c.mes, (select count(*) from mc k where to_char(k.business_date, 'YYYY-MM') = c.mes), (c.x->>'charge_count')::numeric from r_coh c
),
x_h1(entidad, e, o) as (
  with base as (
      select q.sequence, count(*) as n, count(*) filter (where q.estado_hoy = 'a_tiempo') as a
      from mq q, h
      where q.plazo_cerrado
        and q.due_date between h.hoy - h.gracia - 1 - 29 and h.hoy - h.gracia - 1
      group by q.sequence)
    select 'cuota ' || s.k,  coalesce(b.n, 0), coalesce(((select j->'installments'->('cuota_' || s.k)->>'due_count' from r_ontime))::numeric, 0)
   from (values (1), (2)) s(k) left join base b on b.sequence = s.k
),
x_h2(entidad, e, o) as (
  with base as (
      select q.sequence, count(*) as n, count(*) filter (where q.estado_hoy = 'a_tiempo') as a
      from mq q, h
      where q.plazo_cerrado
        and q.due_date between h.hoy - h.gracia - 1 - 29 and h.hoy - h.gracia - 1
      group by q.sequence)
    select 'cuota ' || s.k,  coalesce(b.a, 0), coalesce(((select j->'installments'->('cuota_' || s.k)->>'on_time_count' from r_ontime))::numeric, 0)
   from (values (1), (2)) s(k) left join base b on b.sequence = s.k
),
x_h3(entidad, e, o) as (
  with base as (
      select q.sequence, count(*) as n, count(*) filter (where q.estado_hoy = 'a_tiempo') as a
      from mq q, h
      where q.plazo_cerrado
        and q.due_date between h.hoy - h.gracia - 1 - 29 and h.hoy - h.gracia - 1
      group by q.sequence)
    select 'cuota ' || s.k,  round(100.0 * b.a / nullif(b.n, 0), 1), ((select j->'installments'->('cuota_' || s.k)->>'rate_pct' from r_ontime))::numeric
   from (values (1), (2)) s(k) left join base b on b.sequence = s.k
),
r(orden, comprobacion, esperado, obtenido, ok) as (
select '001', 'A1 Consumo: la suma de las cuotas (financed) = la suma de los consumos',
       coalesce(round((select coalesce(sum(financed_usd), 0) from mq), 2)::text, 'nulo'), coalesce(round((select coalesce(sum(financed_usd), 0) from mc), 2)::text, 'nulo'), coalesce(abs(((select coalesce(sum(financed_usd), 0) from mq)) - ((select coalesce(sum(financed_usd), 0) from mc))) < 0.01, ((select coalesce(sum(financed_usd), 0) from mq)) is null and ((select coalesce(sum(financed_usd), 0) from mc)) is null)
union all
select '002', 'A2 Lo que se paga: la suma de las cuotas (payable) = la de los consumos',
       coalesce(round((select coalesce(sum(payable_usd), 0) from mq), 2)::text, 'nulo'), coalesce(round((select coalesce(sum(payable_usd), 0) from mc), 2)::text, 'nulo'), coalesce(abs(((select coalesce(sum(payable_usd), 0) from mq)) - ((select coalesce(sum(payable_usd), 0) from mc))) < 0.01, ((select coalesce(sum(payable_usd), 0) from mq)) is null and ((select coalesce(sum(payable_usd), 0) from mc)) is null)
union all
select '003', 'A3 Consumos cuyo consumo (cuotas) no es charges.base_usd',
       coalesce(((select 0))::text, 'nulo'), coalesce(((select count(*) from mc k join public.charges c on c.id = k.charge_id
   where abs(k.financed_usd - coalesce(c.base_usd, c.amount_usd)) >= 0.01))::text, 'nulo'), ((select 0)) is not distinct from ((select count(*) from mc k join public.charges c on c.id = k.charge_id
   where abs(k.financed_usd - coalesce(c.base_usd, c.amount_usd)) >= 0.01))
union all
select '004', 'A4 Consumos cuyo servicio + IVA (cuotas) no es el de charges',
       coalesce(((select 0))::text, 'nulo'), coalesce(((select count(*) from mc k join public.charges c on c.id = k.charge_id
   where abs(k.fee_usd - coalesce(c.consumer_fee_usd, 0) - coalesce(c.consumer_fee_vat_usd, 0)
             - coalesce(c.vat_usd, 0)) >= 0.01))::text, 'nulo'), ((select 0)) is not distinct from ((select count(*) from mc k join public.charges c on c.id = k.charge_id
   where abs(k.fee_usd - coalesce(c.consumer_fee_usd, 0) - coalesce(c.consumer_fee_vat_usd, 0)
             - coalesce(c.vat_usd, 0)) >= 0.01))
union all
select '005' as orden, 'A5 Cohorte: cuota 1 + cuota 2 (financed) = consumo de la semana' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_a5 x
union all
select '005.' || x.entidad, '   A5 ' || x.entidad || ': cuota 1 + cuota 2 (financed) = consumo de la semana',
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_a5 x where not (coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null))
union all
select '006', 'A6 Mora de hoy: la de las cuotas = la de cartera_al(hoy)',
       coalesce(round((select round(100 * coalesce(sum(payable_usd) filter (where estado_hoy = 'vencida'), 0)
                / nullif(sum(payable_usd) filter (where estado_hoy in ('vencida', 'por_vencer')), 0), 2) from mq), 2)::text || ' %', 'nulo'), coalesce(round((select (select c.mora_pct from metricas.cartera_al(h.hoy) c) from h), 2)::text || ' %', 'nulo'), coalesce(abs(((select round(100 * coalesce(sum(payable_usd) filter (where estado_hoy = 'vencida'), 0)
                / nullif(sum(payable_usd) filter (where estado_hoy in ('vencida', 'por_vencer')), 0), 2) from mq)) - ((select (select c.mora_pct from metricas.cartera_al(h.hoy) c) from h))) < 0.05, ((select round(100 * coalesce(sum(payable_usd) filter (where estado_hoy = 'vencida'), 0)
                / nullif(sum(payable_usd) filter (where estado_hoy in ('vencida', 'por_vencer')), 0), 2) from mq)) is null and ((select (select c.mora_pct from metricas.cartera_al(h.hoy) c) from h)) is null)
union all
select '007' as orden, 'B1 Noches: Gente = personas con cuota esa noche en ese local' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_b1 x
union all
select '007.' || x.entidad, '   B1 ' || x.entidad || ': Gente = personas con cuota esa noche en ese local',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_b1 x where not ((x.e) is not distinct from (x.o))
union all
select '008' as orden, 'B2 Noches: Nuevos = personas que estrenaban ese local' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_b2 x
union all
select '008.' || x.entidad, '   B2 ' || x.entidad || ': Nuevos = personas que estrenaban ese local',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_b2 x where not ((x.e) is not distinct from (x.o))
union all
select '009' as orden, 'B3 Noches: consumos' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_b3 x
union all
select '009.' || x.entidad, '   B3 ' || x.entidad || ': consumos',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_b3 x where not ((x.e) is not distinct from (x.o))
union all
select '010' as orden, 'B4 Noches: Vendido (consumo sin servicio)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_b4 x
union all
select '010.' || x.entidad, '   B4 ' || x.entidad || ': Vendido (consumo sin servicio)',
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_b4 x where not (coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null))
union all
select '011', 'B5 Noches: la suma de los locales = todos los consumos de 30 días',
       coalesce(((select count(*) from mc, h where business_date between h.hoy - 29 and h.hoy))::text, 'nulo'), coalesce(((select coalesce(sum(charge_count), 0) from r_nights))::text, 'nulo'), ((select count(*) from mc, h where business_date between h.hoy - 29 and h.hoy)) is not distinct from ((select coalesce(sum(charge_count), 0) from r_nights))
union all
select '012', 'B6 Noches: la suma de los locales = todo el consumo de 30 días',
       coalesce(round((select coalesce(sum(financed_usd), 0) from mc, h where business_date between h.hoy - 29 and h.hoy), 2)::text, 'nulo'), coalesce(round((select coalesce(sum(financed_usd), 0) from r_nights), 2)::text, 'nulo'), coalesce(abs(((select coalesce(sum(financed_usd), 0) from mc, h where business_date between h.hoy - 29 and h.hoy)) - ((select coalesce(sum(financed_usd), 0) from r_nights))) < 0.01, ((select coalesce(sum(financed_usd), 0) from mc, h where business_date between h.hoy - 29 and h.hoy)) is null and ((select coalesce(sum(financed_usd), 0) from r_nights)) is null)
union all
select '013' as orden, 'C1 Ficha del local: personas en 30 días' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_c1 x
union all
select '013.' || x.entidad, '   C1 ' || x.entidad || ': personas en 30 días',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_c1 x where not ((x.e) is not distinct from (x.o))
union all
select '014' as orden, 'C2 Ficha del local: vendido en 30 días' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_c2 x
union all
select '014.' || x.entidad, '   C2 ' || x.entidad || ': vendido en 30 días',
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_c2 x where not (coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null))
union all
select '015' as orden, 'C3 Ficha del local: mora de su gente = la mora de siempre, en su local' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)), true) as ok
from x_c3 x
union all
select '015.' || x.entidad, '   C3 ' || x.entidad || ': mora de su gente = la mora de siempre, en su local',
       coalesce(round(x.e, 2)::text || ' %', 'nulo'), coalesce(round(x.o, 2)::text || ' %', 'nulo'), false
from x_c3 x where not (coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null))
union all
select '016' as orden, 'C4 Ficha del local: cobro a tiempo sobre plazos cerrados' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)), true) as ok
from x_c4 x
union all
select '016.' || x.entidad, '   C4 ' || x.entidad || ': cobro a tiempo sobre plazos cerrados',
       coalesce(round(x.e, 2)::text || ' %', 'nulo'), coalesce(round(x.o, 2)::text || ' %', 'nulo'), false
from x_c4 x where not (coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null))
union all
select '017' as orden, 'C5 Ficha del local: cuotas con veredicto (due_count)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_c5 x
union all
select '017.' || x.entidad, '   C5 ' || x.entidad || ': cuotas con veredicto (due_count)',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_c5 x where not ((x.e) is not distinct from (x.o))
union all
select '018' as orden, 'C6 Riesgo › Locales (90 días): personas (distinct_users)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_c6 x
union all
select '018.' || x.entidad, '   C6 ' || x.entidad || ': personas (distinct_users)',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_c6 x where not ((x.e) is not distinct from (x.o))
union all
select '019' as orden, 'C7 Riesgo › Locales (90 días): consumo (financed_usd)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_c7 x
union all
select '019.' || x.entidad, '   C7 ' || x.entidad || ': consumo (financed_usd)',
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_c7 x where not (coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null))
union all
select '020' as orden, 'C8 Riesgo › Locales (90 días): Mora (overdue_debt_pct)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)), true) as ok
from x_c8 x
union all
select '020.' || x.entidad, '   C8 ' || x.entidad || ': Mora (overdue_debt_pct)',
       coalesce(round(x.e, 2)::text || ' %', 'nulo'), coalesce(round(x.o, 2)::text || ' %', 'nulo'), false
from x_c8 x where not (coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null))
union all
select '021' as orden, 'C9 Riesgo › Locales (90 días): mora (arrears_pct)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)), true) as ok
from x_c9 x
union all
select '021.' || x.entidad, '   C9 ' || x.entidad || ': mora (arrears_pct)',
       coalesce(round(x.e, 2)::text || ' %', 'nulo'), coalesce(round(x.o, 2)::text || ' %', 'nulo'), false
from x_c9 x where not (coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null))
union all
select '022', 'C10 Riesgo › Locales: la suma de los locales = el consumo de 90 días',
       coalesce(round((select coalesce(sum(k.financed_usd), 0) from mc k where k.business_date between (select hoy from h) - 89 and (select hoy from h)), 2)::text, 'nulo'), coalesce(round((select coalesce(sum(financed_volume_usd), 0) from r_risk), 2)::text, 'nulo'), coalesce(abs(((select coalesce(sum(k.financed_usd), 0) from mc k where k.business_date between (select hoy from h) - 89 and (select hoy from h))) - ((select coalesce(sum(financed_volume_usd), 0) from r_risk))) < 0.01, ((select coalesce(sum(k.financed_usd), 0) from mc k where k.business_date between (select hoy from h) - 89 and (select hoy from h))) is null and ((select coalesce(sum(financed_volume_usd), 0) from r_risk)) is null)
union all
select '023', 'C11 Locales › Rendimiento: consumo total = el de los consumos del periodo',
       coalesce(round((select coalesce(sum(k.financed_usd), 0) from mc k, r_perf p where k.business_date between (p.j->>'desde')::date and (p.j->>'hasta')::date), 2)::text, 'nulo'), coalesce(round((select (j->'totales'->>'consumo_usd')::numeric from r_perf), 2)::text, 'nulo'), coalesce(abs(((select coalesce(sum(k.financed_usd), 0) from mc k, r_perf p where k.business_date between (p.j->>'desde')::date and (p.j->>'hasta')::date)) - ((select (j->'totales'->>'consumo_usd')::numeric from r_perf))) < 0.01, ((select coalesce(sum(k.financed_usd), 0) from mc k, r_perf p where k.business_date between (p.j->>'desde')::date and (p.j->>'hasta')::date)) is null and ((select (j->'totales'->>'consumo_usd')::numeric from r_perf)) is null)
union all
select '024', 'C12 Locales › Rendimiento: la suma de los locales = el total',
       coalesce(round((select (j->'totales'->>'consumo_usd')::numeric from r_perf), 2)::text, 'nulo'), coalesce(round((select coalesce(sum((l->>'consumo_usd')::numeric), 0) from r_perf, jsonb_array_elements(j->'locales') l), 2)::text, 'nulo'), coalesce(abs(((select (j->'totales'->>'consumo_usd')::numeric from r_perf)) - ((select coalesce(sum((l->>'consumo_usd')::numeric), 0) from r_perf, jsonb_array_elements(j->'locales') l))) < 0.01, ((select (j->'totales'->>'consumo_usd')::numeric from r_perf)) is null and ((select coalesce(sum((l->>'consumo_usd')::numeric), 0) from r_perf, jsonb_array_elements(j->'locales') l)) is null)
union all
select '025', 'C13 Locales › Rendimiento: personas del periodo',
       coalesce(((select count(distinct q.user_id) from mq q, r_perf p where q.business_date between (p.j->>'desde')::date and (p.j->>'hasta')::date))::text, 'nulo'), coalesce(((select (j->'totales'->>'personas')::numeric from r_perf))::text, 'nulo'), ((select count(distinct q.user_id) from mq q, r_perf p where q.business_date between (p.j->>'desde')::date and (p.j->>'hasta')::date)) is not distinct from ((select (j->'totales'->>'personas')::numeric from r_perf))
union all
select '026' as orden, 'C14 Locales › Rendimiento: personas de cada local' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_c14 x
union all
select '026.' || x.entidad, '   C14 ' || x.entidad || ': personas de cada local',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_c14 x where not ((x.e) is not distinct from (x.o))
union all
select '027' as orden, 'C15 Locales › Rendimiento: nuevas de cada local' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_c15 x
union all
select '027.' || x.entidad, '   C15 ' || x.entidad || ': nuevas de cada local',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_c15 x where not ((x.e) is not distinct from (x.o))
union all
select '028' as orden, 'D1 Semana: consumo' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_d1 x
union all
select '028.' || x.entidad, '   D1 ' || x.entidad || ': consumo',
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_d1 x where not (coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null))
union all
select '029' as orden, 'D2 Semana: consumos' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_d2 x
union all
select '029.' || x.entidad, '   D2 ' || x.entidad || ': consumos',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_d2 x where not ((x.e) is not distinct from (x.o))
union all
select '030' as orden, 'D3 Semana: personas con cuota' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_d3 x
union all
select '030.' || x.entidad, '   D3 ' || x.entidad || ': personas con cuota',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_d3 x where not ((x.e) is not distinct from (x.o))
union all
select '031' as orden, 'D4 Semana: servicio de Helios sin IVA' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_d4 x
union all
select '031.' || x.entidad, '   D4 ' || x.entidad || ': servicio de Helios sin IVA',
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_d4 x where not (coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null))
union all
select '032' as orden, 'D5 Semana: registros' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_d5 x
union all
select '032.' || x.entidad, '   D5 ' || x.entidad || ': registros',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_d5 x where not ((x.e) is not distinct from (x.o))
union all
select '033' as orden, 'D6 Semana: primera compra' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_d6 x
union all
select '033.' || x.entidad, '   D6 ' || x.entidad || ': primera compra',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_d6 x where not ((x.e) is not distinct from (x.o))
union all
select '034' as orden, 'D8 Semana: cargos por atraso' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_d8 x
union all
select '034.' || x.entidad, '   D8 ' || x.entidad || ': cargos por atraso',
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_d8 x where not (coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null))
union all
select '035' as orden, 'D7 Semana: mora al cierre' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)), true) as ok
from x_d7 x
union all
select '035.' || x.entidad, '   D7 ' || x.entidad || ': mora al cierre',
       coalesce(round(x.e, 2)::text || ' %', 'nulo'), coalesce(round(x.o, 2)::text || ' %', 'nulo'), false
from x_d7 x where not (coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null))
union all
select '036' as orden, 'E1 Día: consumo' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_e1 x
union all
select '036.' || x.entidad, '   E1 ' || x.entidad || ': consumo',
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_e1 x where not (coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null))
union all
select '037' as orden, 'E2 Día: consumos' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_e2 x
union all
select '037.' || x.entidad, '   E2 ' || x.entidad || ': consumos',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_e2 x where not ((x.e) is not distinct from (x.o))
union all
select '038' as orden, 'E3 Día: personas con cuota' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_e3 x
union all
select '038.' || x.entidad, '   E3 ' || x.entidad || ': personas con cuota',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_e3 x where not ((x.e) is not distinct from (x.o))
union all
select '039' as orden, 'E4 Día: servicio sin IVA' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_e4 x
union all
select '039.' || x.entidad, '   E4 ' || x.entidad || ': servicio sin IVA',
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_e4 x where not (coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null))
union all
select '040' as orden, 'E5 Día: registros' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_e5 x
union all
select '040.' || x.entidad, '   E5 ' || x.entidad || ': registros',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_e5 x where not ((x.e) is not distinct from (x.o))
union all
select '041' as orden, 'E7 Día: cargos por atraso' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_e7 x
union all
select '041.' || x.entidad, '   E7 ' || x.entidad || ': cargos por atraso',
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_e7 x where not (coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null))
union all
select '042' as orden, 'E6 Día: primera compra' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_e6 x
union all
select '042.' || x.entidad, '   E6 ' || x.entidad || ': primera compra',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_e6 x where not ((x.e) is not distinct from (x.o))
union all
select '043', 'F1 Resumen: consumo de 30 días (volume.financed_usd)',
       coalesce(round((select coalesce(sum(k.financed_usd), 0) from mc k where k.business_date between (select hoy from h) - 29 and (select hoy from h)), 2)::text, 'nulo'), coalesce(round((select (j->'volume'->>'financed_usd')::numeric from r_over), 2)::text, 'nulo'), coalesce(abs(((select coalesce(sum(k.financed_usd), 0) from mc k where k.business_date between (select hoy from h) - 29 and (select hoy from h))) - ((select (j->'volume'->>'financed_usd')::numeric from r_over))) < 0.01, ((select coalesce(sum(k.financed_usd), 0) from mc k where k.business_date between (select hoy from h) - 29 and (select hoy from h))) is null and ((select (j->'volume'->>'financed_usd')::numeric from r_over)) is null)
union all
select '044', 'F2 Resumen: consumo de 30 días (volume.financed_volume_usd)',
       coalesce(round((select coalesce(sum(k.financed_usd), 0) from mc k where k.business_date between (select hoy from h) - 29 and (select hoy from h)), 2)::text, 'nulo'), coalesce(round((select (j->'volume'->>'financed_volume_usd')::numeric from r_over), 2)::text, 'nulo'), coalesce(abs(((select coalesce(sum(k.financed_usd), 0) from mc k where k.business_date between (select hoy from h) - 29 and (select hoy from h))) - ((select (j->'volume'->>'financed_volume_usd')::numeric from r_over))) < 0.01, ((select coalesce(sum(k.financed_usd), 0) from mc k where k.business_date between (select hoy from h) - 29 and (select hoy from h))) is null and ((select (j->'volume'->>'financed_volume_usd')::numeric from r_over)) is null)
union all
select '045', 'F3 Resumen: ticket medio (volume.avg_ticket_usd)',
       coalesce(round((select coalesce(round(sum(k.financed_usd) / nullif(count(*), 0), 2), 0) from mc k where k.business_date between (select hoy from h) - 29 and (select hoy from h)), 2)::text, 'nulo'), coalesce(round((select (j->'volume'->>'avg_ticket_usd')::numeric from r_over), 2)::text, 'nulo'), coalesce(abs(((select coalesce(round(sum(k.financed_usd) / nullif(count(*), 0), 2), 0) from mc k where k.business_date between (select hoy from h) - 29 and (select hoy from h))) - ((select (j->'volume'->>'avg_ticket_usd')::numeric from r_over))) < 0.01, ((select coalesce(round(sum(k.financed_usd) / nullif(count(*), 0), 2), 0) from mc k where k.business_date between (select hoy from h) - 29 and (select hoy from h))) is null and ((select (j->'volume'->>'avg_ticket_usd')::numeric from r_over)) is null)
union all
select '046', 'F4 Resumen: personas de 30 días (volume.active_users)',
       coalesce(((select count(distinct q.user_id) from mq q where q.business_date between (select hoy from h) - 29 and (select hoy from h)))::text, 'nulo'), coalesce(((select (j->'volume'->>'active_users')::numeric from r_over))::text, 'nulo'), ((select count(distinct q.user_id) from mq q where q.business_date between (select hoy from h) - 29 and (select hoy from h))) is not distinct from ((select (j->'volume'->>'active_users')::numeric from r_over))
union all
select '047', 'F5 Resumen: personas de 30 días (volume.active_people)',
       coalesce(((select count(distinct q.user_id) from mq q where q.business_date between (select hoy from h) - 29 and (select hoy from h)))::text, 'nulo'), coalesce(((select (j->'volume'->>'active_people')::numeric from r_over))::text, 'nulo'), ((select count(distinct q.user_id) from mq q where q.business_date between (select hoy from h) - 29 and (select hoy from h))) is not distinct from ((select (j->'volume'->>'active_people')::numeric from r_over))
union all
select '048', 'F6 Resumen: tasa de mora (arrears.rate_pct)',
       coalesce(round((select coalesce((select round(100 * coalesce(sum(q.payable_usd) filter (where q.estado_hoy = 'vencida'), 0)
          / nullif(sum(q.payable_usd) filter (where q.estado_hoy in ('vencida', 'por_vencer')), 0), 2)
    from mq q where true), 0)), 2)::text || ' %', 'nulo'), coalesce(round((select (j->'arrears'->>'rate_pct')::numeric from r_over), 2)::text || ' %', 'nulo'), coalesce(abs(((select coalesce((select round(100 * coalesce(sum(q.payable_usd) filter (where q.estado_hoy = 'vencida'), 0)
          / nullif(sum(q.payable_usd) filter (where q.estado_hoy in ('vencida', 'por_vencer')), 0), 2)
    from mq q where true), 0))) - ((select (j->'arrears'->>'rate_pct')::numeric from r_over))) < 0.05, ((select coalesce((select round(100 * coalesce(sum(q.payable_usd) filter (where q.estado_hoy = 'vencida'), 0)
          / nullif(sum(q.payable_usd) filter (where q.estado_hoy in ('vencida', 'por_vencer')), 0), 2)
    from mq q where true), 0))) is null and ((select (j->'arrears'->>'rate_pct')::numeric from r_over)) is null)
union all
select '049', 'F7 Resumen: vencido (arrears.overdue_usd)',
       coalesce(round((select coalesce(sum(payable_usd) filter (where estado_hoy = 'vencida'), 0) from mq), 2)::text, 'nulo'), coalesce(round((select (j->'arrears'->>'overdue_usd')::numeric from r_over), 2)::text, 'nulo'), coalesce(abs(((select coalesce(sum(payable_usd) filter (where estado_hoy = 'vencida'), 0) from mq)) - ((select (j->'arrears'->>'overdue_usd')::numeric from r_over))) < 0.01, ((select coalesce(sum(payable_usd) filter (where estado_hoy = 'vencida'), 0) from mq)) is null and ((select (j->'arrears'->>'overdue_usd')::numeric from r_over)) is null)
union all
select '050', 'F8 Resumen: deuda viva (arrears.open_usd)',
       coalesce(round((select coalesce(sum(payable_usd) filter (where estado_hoy in ('vencida', 'por_vencer')), 0) from mq), 2)::text, 'nulo'), coalesce(round((select (j->'arrears'->>'open_usd')::numeric from r_over), 2)::text, 'nulo'), coalesce(abs(((select coalesce(sum(payable_usd) filter (where estado_hoy in ('vencida', 'por_vencer')), 0) from mq)) - ((select (j->'arrears'->>'open_usd')::numeric from r_over))) < 0.01, ((select coalesce(sum(payable_usd) filter (where estado_hoy in ('vencida', 'por_vencer')), 0) from mq)) is null and ((select (j->'arrears'->>'open_usd')::numeric from r_over)) is null)
union all
select '051', 'F9 Resumen: personas con algo vencido (arrears.overdue_users)',
       coalesce(((select count(distinct user_id) filter (where estado_hoy = 'vencida') from mq))::text, 'nulo'), coalesce(((select (j->'arrears'->>'overdue_users')::numeric from r_over))::text, 'nulo'), ((select count(distinct user_id) filter (where estado_hoy = 'vencida') from mq)) is not distinct from ((select (j->'arrears'->>'overdue_users')::numeric from r_over))
union all
select '052', 'F10 Resumen: tasa de impago en consumo (bad_debt.rate_financed_pct)',
       coalesce(round((select round(100 * coalesce(sum(financed_usd) filter (where estado_hoy = 'perdida'), 0) / nullif(sum(financed_usd), 0), 2) from mq), 2)::text || ' %', 'nulo'), coalesce(round((select (j->'bad_debt'->>'rate_financed_pct')::numeric from r_over), 2)::text || ' %', 'nulo'), coalesce(abs(((select round(100 * coalesce(sum(financed_usd) filter (where estado_hoy = 'perdida'), 0) / nullif(sum(financed_usd), 0), 2) from mq)) - ((select (j->'bad_debt'->>'rate_financed_pct')::numeric from r_over))) < 0.05, ((select round(100 * coalesce(sum(financed_usd) filter (where estado_hoy = 'perdida'), 0) / nullif(sum(financed_usd), 0), 2) from mq)) is null and ((select (j->'bad_debt'->>'rate_financed_pct')::numeric from r_over)) is null)
union all
select '053', 'F11 Resumen › Usuarios por estado: registros (users.total)',
       coalesce(((select count(*) from mp))::text, 'nulo'), coalesce(((select (j->'users'->>'total')::numeric from r_over))::text, 'nulo'), ((select count(*) from mp)) is not distinct from ((select (j->'users'->>'total')::numeric from r_over))
union all
select '054', 'F12 Resumen › Usuarios por estado: registros de 30 días (users.new_in_window)',
       coalesce(((select count(*) from mp p, h where p.registro_dia between h.hoy - 29 and h.hoy))::text, 'nulo'), coalesce(((select (j->'users'->>'new_in_window')::numeric from r_over))::text, 'nulo'), ((select count(*) from mp p, h where p.registro_dia between h.hoy - 29 and h.hoy)) is not distinct from ((select (j->'users'->>'new_in_window')::numeric from r_over))
union all
select '055', 'F14 Resumen: pidieron el código, se verificaran o no (users.requested_otp)',
       coalesce(((select count(*) from ms))::text, 'nulo'), coalesce(((select (j->'users'->>'requested_otp')::numeric from r_over))::text, 'nulo'), ((select count(*) from ms)) is not distinct from ((select (j->'users'->>'requested_otp')::numeric from r_over))
union all
select '056', 'F15 Resumen: pidieron el código y nunca lo metieron (users.unconfirmed_phone)',
       coalesce(((select count(*) from ms where etapa = 'solicito_el_codigo'))::text, 'nulo'), coalesce(((select (j->'users'->>'unconfirmed_phone')::numeric from r_over))::text, 'nulo'), ((select count(*) from ms where etapa = 'solicito_el_codigo')) is not distinct from ((select (j->'users'->>'unconfirmed_phone')::numeric from r_over))
union all
select '057', 'F16 Resumen: pidieron el código y no son registros (users.not_verified)',
       coalesce(((select count(*) from ms where etapa <> 'verificado'))::text, 'nulo'), coalesce(((select (j->'users'->>'not_verified')::numeric from r_over))::text, 'nulo'), ((select count(*) from ms where etapa <> 'verificado')) is not distinct from ((select (j->'users'->>'not_verified')::numeric from r_over))
union all
select '058', 'F13 Resumen: locales con ventas en 30 días',
       coalesce(((select count(distinct k.merchant_id) from mc k where k.business_date between (select hoy from h) - 29 and (select hoy from h)))::text, 'nulo'), coalesce(((select (j->'merchants'->>'selling_in_window')::numeric from r_over))::text, 'nulo'), ((select count(distinct k.merchant_id) from mc k where k.business_date between (select hoy from h) - 29 and (select hoy from h))) is not distinct from ((select (j->'merchants'->>'selling_in_window')::numeric from r_over))
union all
select '059' as orden, 'G1 Cosecha: personas (user_count)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_g1 x
union all
select '059.' || x.entidad, '   G1 ' || x.entidad || ': personas (user_count)',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_g1 x where not ((x.e) is not distinct from (x.o))
union all
select '060' as orden, 'G2 Cosecha: personas (people_count)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_g2 x
union all
select '060.' || x.entidad, '   G2 ' || x.entidad || ': personas (people_count)',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_g2 x where not ((x.e) is not distinct from (x.o))
union all
select '061' as orden, 'G3 Cosecha: consumo (financed_usd)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_g3 x
union all
select '061.' || x.entidad, '   G3 ' || x.entidad || ': consumo (financed_usd)',
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_g3 x where not (coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null))
union all
select '062' as orden, 'G4 Cosecha: consumo (financed_volume_usd)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_g4 x
union all
select '062.' || x.entidad, '   G4 ' || x.entidad || ': consumo (financed_volume_usd)',
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_g4 x where not (coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null))
union all
select '063' as orden, 'G5 Cosecha: consumos' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_g5 x
union all
select '063.' || x.entidad, '   G5 ' || x.entidad || ': consumos',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_g5 x where not ((x.e) is not distinct from (x.o))
union all
select '064' as orden, 'H1 Cobro a tiempo: cuotas juzgadas (due_count)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_h1 x
union all
select '064.' || x.entidad, '   H1 ' || x.entidad || ': cuotas juzgadas (due_count)',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_h1 x where not ((x.e) is not distinct from (x.o))
union all
select '065' as orden, 'H2 Cobro a tiempo: pagadas a tiempo (on_time_count)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_h2 x
union all
select '065.' || x.entidad, '   H2 ' || x.entidad || ': pagadas a tiempo (on_time_count)',
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_h2 x where not ((x.e) is not distinct from (x.o))
union all
select '066' as orden, 'H3 Cobro a tiempo: tasa (rate_pct)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)), true) as ok
from x_h3 x
union all
select '066.' || x.entidad, '   H3 ' || x.entidad || ': tasa (rate_pct)',
       coalesce(round(x.e, 2)::text || ' %', 'nulo'), coalesce(round(x.o, 2)::text || ' %', 'nulo'), false
from x_h3 x where not (coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null))
union all
select '067', 'I1 Crecimiento: registros del periodo',
       coalesce(((select count(*) from mp p, r_growth g where p.registro_dia between (g.j->>'from')::date and (g.j->>'to')::date))::text, 'nulo'), coalesce(((select (j->'registered'->>'count')::numeric from r_growth))::text, 'nulo'), ((select count(*) from mp p, r_growth g where p.registro_dia between (g.j->>'from')::date and (g.j->>'to')::date)) is not distinct from ((select (j->'registered'->>'count')::numeric from r_growth))
union all
select '068', 'I2 Crecimiento: verificados del periodo',
       coalesce(((select count(*) from mp p, r_growth g where p.verificado_dia between (g.j->>'from')::date and (g.j->>'to')::date))::text, 'nulo'), coalesce(((select (j->'verified'->>'count')::numeric from r_growth))::text, 'nulo'), ((select count(*) from mp p, r_growth g where p.verificado_dia between (g.j->>'from')::date and (g.j->>'to')::date)) is not distinct from ((select (j->'verified'->>'count')::numeric from r_growth))
union all
select '069', 'I3 Crecimiento: primera compra en el periodo',
       coalesce(((select count(*) from mp p, r_growth g where p.primer_consumo_dia between (g.j->>'from')::date and (g.j->>'to')::date))::text, 'nulo'), coalesce(((select (j->'activated'->>'count')::numeric from r_growth))::text, 'nulo'), ((select count(*) from mp p, r_growth g where p.primer_consumo_dia between (g.j->>'from')::date and (g.j->>'to')::date)) is not distinct from ((select (j->'activated'->>'count')::numeric from r_growth))
union all
select '070', 'I4 Crecimiento: personas del periodo',
       coalesce(((select count(distinct q.user_id) from mq q, r_growth g where q.business_date between (g.j->>'from')::date and (g.j->>'to')::date))::text, 'nulo'), coalesce(((select (j->'active_users'->>'count')::numeric from r_growth))::text, 'nulo'), ((select count(distinct q.user_id) from mq q, r_growth g where q.business_date between (g.j->>'from')::date and (g.j->>'to')::date)) is not distinct from ((select (j->'active_users'->>'count')::numeric from r_growth))
union all
select '071', 'I5 Crecimiento: consumos del periodo',
       coalesce(((select count(*) from mc k, r_growth g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date))::text, 'nulo'), coalesce(((select (j->'orders'->>'count')::numeric from r_growth))::text, 'nulo'), ((select count(*) from mc k, r_growth g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date)) is not distinct from ((select (j->'orders'->>'count')::numeric from r_growth))
union all
select '072', 'I6 Crecimiento: consumo del periodo',
       coalesce(round((select coalesce(sum(k.financed_usd), 0) from mc k, r_growth g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date), 2)::text, 'nulo'), coalesce(round((select (j->'spend'->>'financed_usd')::numeric from r_growth), 2)::text, 'nulo'), coalesce(abs(((select coalesce(sum(k.financed_usd), 0) from mc k, r_growth g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date)) - ((select (j->'spend'->>'financed_usd')::numeric from r_growth))) < 0.01, ((select coalesce(sum(k.financed_usd), 0) from mc k, r_growth g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date)) is null and ((select (j->'spend'->>'financed_usd')::numeric from r_growth)) is null)
union all
select '073', 'I7 Crecimiento: ingreso de Helios sin IVA (spend.revenue_usd)',
       coalesce(round((select coalesce(sum(k.servicio_usd), 0) from mc k, r_growth g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date), 2)::text, 'nulo'), coalesce(round((select (j->'spend'->>'revenue_usd')::numeric from r_growth), 2)::text, 'nulo'), coalesce(abs(((select coalesce(sum(k.servicio_usd), 0) from mc k, r_growth g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date)) - ((select (j->'spend'->>'revenue_usd')::numeric from r_growth))) < 0.01, ((select coalesce(sum(k.servicio_usd), 0) from mc k, r_growth g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date)) is null and ((select (j->'spend'->>'revenue_usd')::numeric from r_growth)) is null)
union all
select '074', 'I8 Crecimiento: registros en total',
       coalesce(((select count(*) from mp))::text, 'nulo'), coalesce(((select (j->'totals'->>'registered')::numeric from r_growth))::text, 'nulo'), ((select count(*) from mp)) is not distinct from ((select (j->'totals'->>'registered')::numeric from r_growth))
union all
select '075', 'I15 Crecimiento: pidieron el código en el periodo (requested.count)',
       coalesce(((select count(*) from ms s, r_growth g where s.solicito_dia between (g.j->>'from')::date and (g.j->>'to')::date))::text, 'nulo'), coalesce(((select (j->'requested'->>'count')::numeric from r_growth))::text, 'nulo'), ((select count(*) from ms s, r_growth g where s.solicito_dia between (g.j->>'from')::date and (g.j->>'to')::date)) is not distinct from ((select (j->'requested'->>'count')::numeric from r_growth))
union all
select '076', 'I16 Crecimiento: pidieron el código en total (totals.requested)',
       coalesce(((select count(*) from ms))::text, 'nulo'), coalesce(((select (j->'totals'->>'requested')::numeric from r_growth))::text, 'nulo'), ((select count(*) from ms)) is not distinct from ((select (j->'totals'->>'requested')::numeric from r_growth))
union all
select '077', 'I9 Crecimiento: han comprado alguna vez',
       coalesce(((select count(*) from mp where primer_consumo_dia is not null))::text, 'nulo'), coalesce(((select (j->'totals'->>'ever_bought')::numeric from r_growth))::text, 'nulo'), ((select count(*) from mp where primer_consumo_dia is not null)) is not distinct from ((select (j->'totals'->>'ever_bought')::numeric from r_growth))
union all
select '078', 'I10 Uso: personas del periodo',
       coalesce(((select count(distinct q.user_id) from mq q, r_behavior g where q.business_date between (g.j->>'from')::date and (g.j->>'to')::date))::text, 'nulo'), coalesce(((select (j->>'active_users')::numeric from r_behavior))::text, 'nulo'), ((select count(distinct q.user_id) from mq q, r_behavior g where q.business_date between (g.j->>'from')::date and (g.j->>'to')::date)) is not distinct from ((select (j->>'active_users')::numeric from r_behavior))
union all
select '079', 'I11 Grupos: consumos en grupo + solos = consumos del periodo',
       coalesce(((select count(*) from mc k, r_groups g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date))::text, 'nulo'), coalesce(((select (j->'split'->>'group_charges')::numeric + (j->'split'->>'solo_charges')::numeric from r_groups))::text, 'nulo'), ((select count(*) from mc k, r_groups g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date)) is not distinct from ((select (j->'split'->>'group_charges')::numeric + (j->'split'->>'solo_charges')::numeric from r_groups))
union all
select '080', 'I12 Grupos: consumo en grupo + solo = consumo del periodo',
       coalesce(round((select coalesce(sum(k.financed_usd), 0) from mc k, r_groups g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date), 2)::text, 'nulo'), coalesce(round((select (j->'split'->>'group_financed')::numeric + (j->'split'->>'solo_financed')::numeric from r_groups), 2)::text, 'nulo'), coalesce(abs(((select coalesce(sum(k.financed_usd), 0) from mc k, r_groups g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date)) - ((select (j->'split'->>'group_financed')::numeric + (j->'split'->>'solo_financed')::numeric from r_groups))) < 0.01, ((select coalesce(sum(k.financed_usd), 0) from mc k, r_groups g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date)) is null and ((select (j->'split'->>'group_financed')::numeric + (j->'split'->>'solo_financed')::numeric from r_groups)) is null)
union all
select '081', 'I13 Economía por consumo: consumo del periodo',
       coalesce(round((select coalesce(sum(k.financed_usd), 0) from mc k, r_unit g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date), 2)::text, 'nulo'), coalesce(round((select (j->>'financed_usd')::numeric from r_unit), 2)::text, 'nulo'), coalesce(abs(((select coalesce(sum(k.financed_usd), 0) from mc k, r_unit g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date)) - ((select (j->>'financed_usd')::numeric from r_unit))) < 0.01, ((select coalesce(sum(k.financed_usd), 0) from mc k, r_unit g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date)) is null and ((select (j->>'financed_usd')::numeric from r_unit)) is null)
union all
select '082', 'I14 Economía por consumo: servicio sin IVA del periodo',
       coalesce(round((select coalesce(sum(k.servicio_usd), 0) from mc k, r_unit g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date), 2)::text, 'nulo'), coalesce(round((select (j->>'service_fee_usd')::numeric from r_unit), 2)::text, 'nulo'), coalesce(abs(((select coalesce(sum(k.servicio_usd), 0) from mc k, r_unit g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date)) - ((select (j->>'service_fee_usd')::numeric from r_unit))) < 0.01, ((select coalesce(sum(k.servicio_usd), 0) from mc k, r_unit g where k.business_date between (g.j->>'from')::date and (g.j->>'to')::date)) is null and ((select (j->>'service_fee_usd')::numeric from r_unit)) is null)
)
select comprobacion, esperado, obtenido, ok
from r
order by orden;
