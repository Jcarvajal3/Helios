-- ============================================================================
-- Batería de coherencia de Métricas › Semana (dev) — agente SEMANA
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok. Las que
-- van semana a semana (o por local) dan una fila resumen («N filas / M
-- cuadran») y una fila de detalle por cada una que no cuadra.
--
-- Qué se comprueba de `admin_metricas_semanas` (12 semanas, sin local y con
-- cada local con ventas):
--   A-E  cada cifra de cada semana contra su definición en metricas.* (y la
--        caja contra el libro);
--   W    contra `admin_weekly_summary`, que Inicio sigue leyendo;
--   X    contra las otras pestañas: Caja, Locales, General y admin_overview;
--   P    por local: cada local cuadra, y la suma por locales da el total;
--   M    la comparación con la semana anterior (a la misma altura);
--   F    la regla del fee: todo payable trae su consumo y su servicio y cuadran.
--
-- Solo SELECT. Se hace pasar por un admin activo (request.jwt.claims con
-- aal2) sin cambiar de rol, para poder leer metricas.* en la misma consulta.
-- Tarda unos segundos: llama a la RPC una vez por local.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_semana.sql
--
-- GENERADO por <scratchpad>/semana/gen_bateria.cjs: una comprobación nueva se
-- añade allí y se regenera.
-- ============================================================================

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

with
h as (select metricas.hoy() as hoy, public.helios_on_time_grace_days() as gracia),
mc as (select * from metricas.consumos),
mq as (select * from metricas.cuotas),
mp as (select * from metricas.personas),
mca as (select * from metricas.cargos_por_atraso),
r as (select public.admin_metricas_semanas(null, 12, null) as j),
f as (
  select (x->>'desde')::date as lunes, (x->>'hasta_dato')::date as hasta,
         to_char((x->>'desde')::date, 'DD-MM') as sem, (x->>'en_curso')::boolean as en_curso, x
  from r cross join lateral jsonb_array_elements(r.j->'filas') x
),
locs as (
  select m.id, m.name from public.merchants m
  where not m.is_test and exists (select 1 from mc k where k.merchant_id = m.id)
),
fl as (
  select l.id as merchant_id, l.name as local, (x->>'desde')::date as lunes, (x->>'hasta_dato')::date as hasta, x
  from locs l cross join lateral jsonb_array_elements(public.admin_metricas_semanas(null, 12, l.id)->'filas') x
),
ws as (select (x->>'week_start')::date as lunes, x from jsonb_array_elements(public.admin_weekly_summary(12)->'rows') x),
rc as (select public.admin_metricas_caja(null, null) as j),
wc as (select (x->>'lunes')::date as lunes, x from rc cross join lateral jsonb_array_elements(rc.j->'semanas') x),
rloc as (select public.admin_metricas_locales(null, null) as j),
rgen as (select public.admin_metricas_general(null) as j),
rover as (select public.admin_overview(30) as j),
-- Una semana cerrada elegida (la anterior a la en curso) con dos columnas.
rpas as (select public.admin_metricas_semanas((select max(f.lunes) - 7 from f), 2, null) as j),
-- La anterior de la semana de hoy: sus días y el instante de su corte.
rc0 as (select (r.j->'comparacion'->>'desde')::date as d, (r.j->'comparacion'->>'hasta')::date as h,
               (r.j->'comparacion'->>'corte')::timestamptz as c from r),
x_a1(entidad, e, o) as (select f.sem, (select coalesce(sum(k.financed_usd), 0) from mc k where k.business_date between f.lunes and f.hasta),
          (f.x->'consumo'->>'financed_usd')::numeric from f
),
x_a2(entidad, e, o) as (select f.sem, (select count(*) from mc k where k.business_date between f.lunes and f.hasta)::numeric,
          (f.x->'consumo'->>'consumos')::numeric from f
),
x_a3(entidad, e, o) as (select f.sem, (select round(sum(k.financed_usd) / nullif(count(*), 0), 2) from mc k where k.business_date between f.lunes and f.hasta),
          (f.x->'consumo'->>'ticket_medio_usd')::numeric from f
),
x_a4(entidad, e, o) as (select f.sem, (select count(distinct q.user_id) from mq q where q.business_date between f.lunes and f.hasta)::numeric,
          (f.x->'consumo'->>'personas')::numeric from f
),
x_a5(entidad, e, o) as (select f.sem, (select count(distinct k.merchant_id) from mc k where k.business_date between f.lunes and f.hasta)::numeric,
          (f.x->'consumo'->>'locales')::numeric from f
),
x_a6(entidad, e, o) as (select f.sem, (select coalesce(sum(k.servicio_usd), 0) from mc k where k.business_date between f.lunes and f.hasta),
          (f.x->'ingreso'->>'servicio_usd')::numeric from f
),
x_a7(entidad, e, o) as (select f.sem, (select coalesce(sum(a.amount_usd), 0) from mca a where a.business_date between f.lunes and f.hasta),
          (f.x->'ingreso'->>'cargos_por_atraso_usd')::numeric from f
),
x_b1(entidad, e, o) as (select f.sem, (select coalesce(sum(q.payable_usd), 0) from mq q where q.due_date between f.lunes and f.hasta),
          (f.x->'cobro'->'vencian'->>'payable_usd')::numeric from f
),
x_b2(entidad, e, o) as (select f.sem, (f.x->'cobro'->'vencian'->>'payable_usd')::numeric,
          (f.x->'cobro'->'vencian'->>'financed_usd')::numeric + (f.x->'cobro'->'vencian'->>'fee_usd')::numeric from f
),
x_b3(entidad, e, o) as (select f.sem, (select round(100.0 * count(*) filter (where q.estado_hoy = 'a_tiempo') / nullif(count(*), 0), 2)
                  from mq q, h where q.plazo_cerrado and q.due_date between f.lunes and least(f.hasta, h.hoy - h.gracia - 1)),
          (f.x->'cobro'->'a_tiempo'->>'pct')::numeric from f
),
x_b4(entidad, e, o) as (select f.sem, (select round(100.0 * count(*) filter (where q.estado_hoy = 'a_tiempo') / nullif(count(*), 0), 2)
                  from mq q, h where q.sequence = 1 and q.plazo_cerrado and q.due_date between f.lunes and least(f.hasta, h.hoy - h.gracia - 1)),
          (f.x->'cobro'->'cuota_1'->>'pct')::numeric from f
),
x_b5(entidad, e, o) as (select f.sem, (select round(100.0 * count(*) filter (where q.estado_hoy = 'a_tiempo') / nullif(count(*), 0), 2)
                  from mq q, h where q.sequence = 2 and q.plazo_cerrado and q.due_date between f.lunes and least(f.hasta, h.hoy - h.gracia - 1)),
          (f.x->'cobro'->'cuota_2'->>'pct')::numeric from f
),
x_c1(entidad, e, o) as (select f.sem, k.vencido_payable_usd, (f.x->'riesgo'->'vencido'->>'payable_usd')::numeric
   from f cross join lateral metricas.cartera_al(f.hasta, null) k
),
x_c2(entidad, e, o) as (select f.sem, k.mora_pct, (f.x->'riesgo'->>'mora_pct')::numeric
   from f cross join lateral metricas.cartera_al(f.hasta, null) k
),
x_c3(entidad, e, o) as (select f.sem, (f.x->'riesgo'->'vencido'->>'payable_usd')::numeric,
          (f.x->'riesgo'->'vencido'->>'financed_usd')::numeric + (f.x->'riesgo'->'vencido'->>'fee_usd')::numeric from f
),
x_c4(entidad, e, o) as (select f.sem, (select coalesce(sum(q.financed_usd), 0) from metricas.cuotas_al(f.hasta) q
                  where q.estado_hoy = 'perdida' and public.helios_business_date(q.written_off_at) between f.lunes and f.hasta),
          (f.x->'riesgo'->'perdido'->>'financed_usd')::numeric from f
),
x_d0(entidad, e, o) as (select f.sem, (select count(*) from metricas.solicitudes s where s.solicito_dia between f.lunes and f.hasta)::numeric,
          (f.x->'gente'->>'solicitaron')::numeric from f
),
x_d1(entidad, e, o) as (select f.sem, (select count(*) from mp p where p.registro_dia between f.lunes and f.hasta)::numeric,
          (f.x->'gente'->>'registros')::numeric from f
),
x_d2(entidad, e, o) as (select f.sem, (f.x->'gente'->>'registros')::numeric,
          (f.x->'gente'->>'verificados')::numeric from f
),
x_d4(entidad, e, o) as (select f.sem, (select count(*) from metricas.solicitudes s where s.etapa = 'verificado' and s.verificado_dia between f.lunes and f.hasta)::numeric,
          (f.x->'gente'->>'registros')::numeric from f
),
x_d3(entidad, e, o) as (select f.sem, (select count(*) from mp p where p.primer_consumo_dia between f.lunes and f.hasta)::numeric,
          (f.x->'gente'->>'primer_consumo')::numeric from f
),
x_e1(entidad, e, o) as (select f.sem, (select coalesce(sum(p.amount_usd), 0) from public.merchant_payouts p join public.merchants m on m.id = p.merchant_id
                  where not m.is_test and p.business_date between f.lunes and f.hasta),
          (f.x->'caja'->>'transferido_a_locales_usd')::numeric from f
),
x_e2(entidad, e, o) as (select f.sem, (select coalesce(sum(e.debit) - sum(e.credit), 0)
                  from ledger.entries e join ledger.accounts a on a.id = e.account_id join ledger.transactions t on t.id = e.transaction_id
                  where a.account_type = 'cash' and t.business_date <= f.hasta
                    and not exists (select 1 from ledger.entries e2 join ledger.accounts a2 on a2.id = e2.account_id
                                    where e2.transaction_id = e.transaction_id and a2.owner_id is not null
                                      and (public.helios_is_test_user(a2.owner_id) or public.helios_is_test_merchant(a2.owner_id)))),
          (f.x->'caja'->>'en_caja_usd')::numeric from f
),
x_e3(entidad, e, o) as (select 'libro', ledger.balance_by_type('cash'), (f.x->'caja'->>'en_caja_usd')::numeric from f where f.en_curso
   union all
   select 'admin_cash_position', (public.admin_cash_position()->>'cash')::numeric, (f.x->'caja'->>'en_caja_usd')::numeric from f where f.en_curso
),
x_w1(entidad, e, o) as (select f.sem, (w.x->>'financed_usd')::numeric, (f.x->'consumo'->>'financed_usd')::numeric from f join ws w on w.lunes = f.lunes
),
x_w2(entidad, e, o) as (select f.sem, (w.x->>'charge_count')::numeric, (f.x->'consumo'->>'consumos')::numeric from f join ws w on w.lunes = f.lunes
),
x_w3(entidad, e, o) as (select f.sem, (w.x->>'service_fee_usd')::numeric, (f.x->'ingreso'->>'servicio_usd')::numeric from f join ws w on w.lunes = f.lunes
),
x_w4(entidad, e, o) as (select f.sem, (w.x->>'active_users')::numeric, (f.x->'consumo'->>'personas')::numeric from f join ws w on w.lunes = f.lunes
),
x_w5(entidad, e, o) as (select f.sem, (w.x->>'merchants_with_sales')::numeric, (f.x->'consumo'->>'locales')::numeric from f join ws w on w.lunes = f.lunes
),
x_w6(entidad, e, o) as (select f.sem, (w.x->>'new_users')::numeric, (f.x->'gente'->>'registros')::numeric from f join ws w on w.lunes = f.lunes
),
x_w7(entidad, e, o) as (select f.sem, (w.x->>'first_time_buyers')::numeric, (f.x->'gente'->>'primer_consumo')::numeric from f join ws w on w.lunes = f.lunes
),
x_w8(entidad, e, o) as (select f.sem, (w.x->>'late_fee_usd')::numeric, (f.x->'ingreso'->>'cargos_por_atraso_usd')::numeric from f join ws w on w.lunes = f.lunes
),
x_w9(entidad, e, o) as (select f.sem, (w.x->>'overdue_pct')::numeric, (f.x->'riesgo'->>'mora_pct')::numeric from f join ws w on w.lunes = f.lunes
),
x_w10(entidad, e, o) as (select f.sem, (w.x->>'overdue_debt_usd')::numeric, (f.x->'riesgo'->'vencido'->>'payable_usd')::numeric from f join ws w on w.lunes = f.lunes
),
x_w11(entidad, e, o) as (select f.sem, (w.x->>'written_off_financed_usd')::numeric, (f.x->'riesgo'->'perdido'->>'financed_usd')::numeric from f join ws w on w.lunes = f.lunes
),
x_x1(entidad, e, o) as (select f.sem, (w.x->>'transferido_usd')::numeric, (f.x->'caja'->>'transferido_a_locales_usd')::numeric from f join wc w on w.lunes = f.lunes
),
x_x2(entidad, e, o) as (select f.sem, (w.x->>'caja_al_cierre_usd')::numeric, (f.x->'caja'->>'en_caja_usd')::numeric from f join wc w on w.lunes = f.lunes
),
x_x3(entidad, e, o) as (select f.sem, (w.x->'vencia'->>'payable_usd')::numeric, (f.x->'cobro'->'vencian'->>'payable_usd')::numeric from f join wc w on w.lunes = f.lunes where not f.en_curso
),
x_x4(entidad, e, o) as (select 'consumo', (l.j->'totales'->>'consumo_usd')::numeric, (f.x->'consumo'->>'financed_usd')::numeric from f, rloc l where f.en_curso
   union all select 'consumos', (l.j->'totales'->>'consumos')::numeric, (f.x->'consumo'->>'consumos')::numeric from f, rloc l where f.en_curso
   union all select 'personas', (l.j->'totales'->>'personas')::numeric, (f.x->'consumo'->>'personas')::numeric from f, rloc l where f.en_curso
),
x_x5(entidad, e, o) as (select fl.local || ' consumo', (y->>'consumo_usd')::numeric, (fl.x->'consumo'->>'financed_usd')::numeric
   from fl join rloc l on true cross join lateral jsonb_array_elements(l.j->'locales') y
   where (y->>'merchant_id')::uuid = fl.merchant_id and fl.lunes = (select lunes from f where f.en_curso)
   union all
   select fl.local || ' personas', (y->>'personas')::numeric, (fl.x->'consumo'->>'personas')::numeric
   from fl join rloc l on true cross join lateral jsonb_array_elements(l.j->'locales') y
   where (y->>'merchant_id')::uuid = fl.merchant_id and fl.lunes = (select lunes from f where f.en_curso)
),
x_x6(entidad, e, o) as (select 'caja', (g.j->'dinero'->>'caja_usd')::numeric, (f.x->'caja'->>'en_caja_usd')::numeric from f, rgen g where f.en_curso
   union all select 'vencido', (g.j->'dinero'->'vencido'->>'payable_usd')::numeric, (f.x->'riesgo'->'vencido'->>'payable_usd')::numeric from f, rgen g where f.en_curso
   union all select 'mora', (g.j->'riesgo'->>'mora_pct')::numeric, (f.x->'riesgo'->>'mora_pct')::numeric from f, rgen g where f.en_curso
),
x_x7(entidad, e, o) as (select 'vencido', (o.j->'arrears'->>'overdue_usd')::numeric, (f.x->'riesgo'->'vencido'->>'payable_usd')::numeric from f, rover o where f.en_curso
   union all select 'mora', (o.j->'arrears'->>'rate_pct')::numeric, (f.x->'riesgo'->>'mora_pct')::numeric from f, rover o where f.en_curso
),
x_p1(entidad, e, o) as (select f.sem, (f.x->'consumo'->>'financed_usd')::numeric, (select coalesce(sum((fl.x->'consumo'->>'financed_usd')::numeric), 0) from fl where fl.lunes = f.lunes) from f
),
x_p2(entidad, e, o) as (select f.sem, (f.x->'consumo'->>'consumos')::numeric, (select coalesce(sum((fl.x->'consumo'->>'consumos')::numeric), 0) from fl where fl.lunes = f.lunes) from f
),
x_p3(entidad, e, o) as (select f.sem, (f.x->'ingreso'->>'servicio_usd')::numeric, (select coalesce(sum((fl.x->'ingreso'->>'servicio_usd')::numeric), 0) from fl where fl.lunes = f.lunes) from f
),
x_p4(entidad, e, o) as (select f.sem, (f.x->'consumo'->>'locales')::numeric, (select coalesce(sum((fl.x->'consumo'->>'locales')::numeric), 0) from fl where fl.lunes = f.lunes) from f
),
x_p5(entidad, e, o) as (select f.sem, (f.x->'cobro'->'vencian'->>'payable_usd')::numeric, (select coalesce(sum((fl.x->'cobro'->'vencian'->>'payable_usd')::numeric), 0) from fl where fl.lunes = f.lunes) from f
),
x_p6(entidad, e, o) as (select f.sem, (f.x->'riesgo'->'vencido'->>'payable_usd')::numeric, (select coalesce(sum((fl.x->'riesgo'->'vencido'->>'payable_usd')::numeric), 0) from fl where fl.lunes = f.lunes) from f
),
x_p7(entidad, e, o) as (select f.sem, (f.x->'riesgo'->'perdido'->>'financed_usd')::numeric, (select coalesce(sum((fl.x->'riesgo'->'perdido'->>'financed_usd')::numeric), 0) from fl where fl.lunes = f.lunes) from f
),
x_p8(entidad, e, o) as (select f.sem, (f.x->'caja'->>'transferido_a_locales_usd')::numeric, (select coalesce(sum((fl.x->'caja'->>'transferido_a_locales_usd')::numeric), 0) from fl where fl.lunes = f.lunes) from f
),
x_p9(entidad, e, o) as (select f.sem, (f.x->'ingreso'->>'cargos_por_atraso_usd')::numeric,
          (select coalesce(sum((fl.x->'ingreso'->>'cargos_por_atraso_usd')::numeric), 0) from fl where fl.lunes = f.lunes)
          + (select coalesce(sum(a.amount_usd), 0) from mca a where a.merchant_id is null and a.business_date between f.lunes and f.hasta)
   from f
),
x_p10(entidad, e, o) as (select f.sem, null::numeric,
          ((select coalesce(max((fl.x->'consumo'->>'personas')::numeric), 0) from fl where fl.lunes = f.lunes) <= (f.x->'consumo'->>'personas')::numeric
           and (f.x->'consumo'->>'personas')::numeric <= (select coalesce(sum((fl.x->'consumo'->>'personas')::numeric), 0) from fl where fl.lunes = f.lunes))
   from f
),
x_p11(entidad, e, o) as (select to_char(fl.lunes, 'DD-MM') || ' ' || fl.local,
          (select coalesce(sum(k.financed_usd), 0) from mc k where k.merchant_id = fl.merchant_id and k.business_date between fl.lunes and fl.hasta),
          (fl.x->'consumo'->>'financed_usd')::numeric from fl
),
x_p12(entidad, e, o) as (select to_char(fl.lunes, 'DD-MM') || ' ' || fl.local,
          (select count(*) from metricas.personas_por_local l where l.merchant_id = fl.merchant_id and l.primer_dia between fl.lunes and fl.hasta)::numeric,
          (fl.x->'gente'->>'primer_consumo')::numeric from fl
),
x_p13(entidad, e, o) as (select to_char(fl.lunes, 'DD-MM') || ' ' || fl.local, k.vencido_payable_usd, (fl.x->'riesgo'->'vencido'->>'payable_usd')::numeric
   from fl cross join lateral metricas.cartera_al(fl.hasta, fl.merchant_id) k
),
x_p14(entidad, e, o) as (select to_char(fl.lunes, 'DD-MM') || ' ' || fl.local, null::numeric,
          jsonb_typeof(fl.x->'gente'->'registros') = 'null' and jsonb_typeof(fl.x->'gente'->'verificados') = 'null'
          and jsonb_typeof(fl.x->'gente'->'solicitaron') = 'null'
          and jsonb_typeof(fl.x->'caja'->'en_caja_usd') = 'null' from fl
),
x_m1(entidad, e, o) as (select 'anterior', (select coalesce(sum(k.financed_usd), 0) from mc k, rc0 where k.business_date between rc0.d and rc0.h and (rc0.c is null or k.confirmed_at <= rc0.c)),
          (r.j->'comparacion'->'consumo'->>'financed_usd')::numeric from r
),
x_m6(entidad, e, o) as (select 'anterior', (select count(*) from mc k, rc0 where k.business_date between rc0.d and rc0.h and (rc0.c is null or k.confirmed_at <= rc0.c))::numeric,
          (r.j->'comparacion'->'consumo'->>'consumos')::numeric from r
),
x_m7(entidad, e, o) as (select 'anterior', (select count(*) from (
            select q.user_id from mq q join mc k on k.charge_id = q.charge_id, rc0
            where q.business_date between rc0.d and rc0.h
            group by q.user_id, rc0.c having rc0.c is null or min(k.confirmed_at) <= rc0.c) x)::numeric,
          (r.j->'comparacion'->'consumo'->>'personas')::numeric from r
),
x_m8(entidad, e, o) as (select 'corte', null::numeric,
          case when f.en_curso then (r.j->'comparacion'->>'corte')::timestamptz = now() - interval '7 days'
               else jsonb_typeof(r.j->'comparacion'->'corte') = 'null' end
          and jsonb_typeof(p.j->'comparacion'->'corte') = 'null'
   from r, rpas p, f where f.lunes = (r.j->'semana'->>'desde')::date
),
x_m9(entidad, e, o) as (select 'anterior', (select count(*) from mp p join metricas.solicitudes s on s.user_id = p.user_id, rc0
                       where p.registro_dia between rc0.d and rc0.h and (rc0.c is null or s.verificado_en <= rc0.c))::numeric,
          (r.j->'comparacion'->'gente'->>'registros')::numeric from r
),
x_m10(entidad, e, o) as (select 'anterior', (select count(*) from metricas.solicitudes s, rc0
                       where s.solicito_dia between rc0.d and rc0.h and (rc0.c is null or s.solicito_en <= rc0.c))::numeric,
          (r.j->'comparacion'->'gente'->>'solicitaron')::numeric from r
),
x_m11(entidad, e, o) as (select 'anterior', (select count(*) from mp p, rc0
                       where p.primer_consumo_dia between rc0.d and rc0.h
                         and (rc0.c is null or (select min(k.confirmed_at) from mq q join mc k on k.charge_id = q.charge_id
                                                where q.user_id = p.user_id) <= rc0.c))::numeric,
          (r.j->'comparacion'->'gente'->>'primer_consumo')::numeric from r
),
x_m12(entidad, e, o) as (select 'anterior', (select coalesce(sum(a.amount_usd), 0) from mca a join public.late_fees lf on lf.id = a.late_fee_id, rc0
                       where a.business_date between rc0.d and rc0.h and (rc0.c is null or lf.created_at <= rc0.c)),
          (r.j->'comparacion'->'ingreso'->>'cargos_por_atraso_usd')::numeric from r
),
x_m13(entidad, e, o) as (select 'anterior', (select coalesce(sum(x.amount_usd), 0) from public.merchant_payouts x join public.merchants m on m.id = x.merchant_id, rc0
                       where not m.is_test and x.business_date between rc0.d and rc0.h and (rc0.c is null or x.created_at <= rc0.c)),
          (r.j->'comparacion'->'caja'->>'transferido_a_locales_usd')::numeric from r
),
x_m2(entidad, e, o) as (select 'dias', null::numeric,
          (r.j->'comparacion'->>'desde')::date = f.lunes - 7
          and (r.j->'comparacion'->>'hasta')::date = f.hasta - 7
          and (r.j->'comparacion'->>'misma_altura')::boolean = f.en_curso
   from r, f where f.lunes = (r.j->'semana'->>'desde')::date
),
x_m3(entidad, e, o) as (select 'vencido', k.vencido_payable_usd, (r.j->'comparacion'->'riesgo'->'vencido'->>'payable_usd')::numeric
   from r cross join lateral metricas.cartera_al((r.j->'comparacion'->>'hasta')::date, null) k
),
x_m4(entidad, e, o) as (select 'juzgado', null::numeric,
          (r.j->'comparacion'->>'juzgado_hasta') is not distinct from
          (select case when least(f.hasta, h.hoy - h.gracia - 1) - 7 >= f.lunes - 7
                       then (least(f.hasta, h.hoy - h.gracia - 1) - 7)::text end
           from f, h where f.lunes = (r.j->'semana'->>'desde')::date)
   from r
),
x_m5(entidad, e, o) as (select (p.j->'semana'->>'desde'), null::numeric,
          (p.j->'comparacion') - 'desde' - 'hasta' - 'dias' - 'misma_altura' - 'juzgado_hasta' - 'corte'
          = (p.j->'filas'->0) - 'desde' - 'hasta' - 'hasta_dato' - 'dias' - 'en_curso'
          and not (p.j->'comparacion'->>'misma_altura')::boolean
   from rpas p
),
x_f1(entidad, e, o) as (select coalesce(z.origen, '') || ' ' || z.bloque, null::numeric,
          abs((z.o->>'payable_usd')::numeric - (z.o->>'financed_usd')::numeric - (z.o->>'fee_usd')::numeric) < 0.005
   from (
     select to_char(f.lunes, 'DD-MM') as origen, b.bloque, b.o
     from f cross join lateral (values ('vencian', f.x->'cobro'->'vencian'), ('vencido', f.x->'riesgo'->'vencido'),
                                       ('por_vencer', f.x->'riesgo'->'por_vencer'), ('perdido', f.x->'riesgo'->'perdido')) b(bloque, o)
     union all
     select to_char(fl.lunes, 'DD-MM') || ' ' || fl.local, b.bloque, b.o
     from fl cross join lateral (values ('vencian', fl.x->'cobro'->'vencian'), ('vencido', fl.x->'riesgo'->'vencido'),
                                        ('por_vencer', fl.x->'riesgo'->'por_vencer'), ('perdido', fl.x->'riesgo'->'perdido')) b(bloque, o)
   ) z
),
resultado as (
select '001' as orden, 'A1 Semana: consumo = metricas.consumos' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_a1 x
union all
select '001.' || x.entidad, '   A1 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_a1 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '002' as orden, 'A2 Semana: consumos = metricas.consumos' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_a2 x
union all
select '002.' || x.entidad, '   A2 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_a2 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '003' as orden, 'A3 Semana: ticket medio = consumo ÷ consumos' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_a3 x
union all
select '003.' || x.entidad, '   A3 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_a3 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '004' as orden, 'A4 Semana: personas = cuotas (count distinct user_id)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_a4 x
union all
select '004.' || x.entidad, '   A4 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_a4 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '005' as orden, 'A5 Semana: locales con ventas' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_a5 x
union all
select '005.' || x.entidad, '   A5 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_a5 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '006' as orden, 'A6 Semana: servicio sin IVA = metricas.consumos.servicio_usd' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_a6 x
union all
select '006.' || x.entidad, '   A6 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_a6 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '007' as orden, 'A7 Semana: cargos por atraso = metricas.cargos_por_atraso' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_a7 x
union all
select '007.' || x.entidad, '   A7 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_a7 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '008' as orden, 'B1 Semana: cuotas que vencían (payable) = metricas.cuotas por vencimiento' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_b1 x
union all
select '008.' || x.entidad, '   B1 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_b1 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '009' as orden, 'B2 Semana: lo que vencía = consumo + servicio e IVA' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_b2 x
union all
select '009.' || x.entidad, '   B2 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_b2 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '010' as orden, 'B3 Semana: cobrado a tiempo = a_tiempo ÷ plazo cerrado' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)), true) as ok
from x_b3 x
union all
select '010.' || x.entidad, '   B3 ' || x.entidad,
       coalesce(round(x.e, 2)::text || ' %', 'nulo'), coalesce(round(x.o, 2)::text || ' %', 'nulo'), false
from x_b3 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null), false)
union all
select '011' as orden, 'B4 Semana: cuota 1 a tiempo' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)), true) as ok
from x_b4 x
union all
select '011.' || x.entidad, '   B4 ' || x.entidad,
       coalesce(round(x.e, 2)::text || ' %', 'nulo'), coalesce(round(x.o, 2)::text || ' %', 'nulo'), false
from x_b4 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null), false)
union all
select '012' as orden, 'B5 Semana: cuota 2 a tiempo' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)), true) as ok
from x_b5 x
union all
select '012.' || x.entidad, '   B5 ' || x.entidad,
       coalesce(round(x.e, 2)::text || ' %', 'nulo'), coalesce(round(x.o, 2)::text || ' %', 'nulo'), false
from x_b5 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null), false)
union all
select '013' as orden, 'C1 Semana: vencido al cierre = metricas.cartera_al' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_c1 x
union all
select '013.' || x.entidad, '   C1 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_c1 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '014' as orden, 'C2 Semana: mora al cierre = metricas.cartera_al' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)), true) as ok
from x_c2 x
union all
select '014.' || x.entidad, '   C2 ' || x.entidad,
       coalesce(round(x.e, 2)::text || ' %', 'nulo'), coalesce(round(x.o, 2)::text || ' %', 'nulo'), false
from x_c2 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null), false)
union all
select '015' as orden, 'C3 Semana: vencido = consumo + servicio e IVA' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_c3 x
union all
select '015.' || x.entidad, '   C3 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_c3 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '016' as orden, 'C4 Semana: dado por perdido (consumo) = cuotas_al perdidas en la semana' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_c4 x
union all
select '016.' || x.entidad, '   C4 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_c4 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '017' as orden, 'D0 Semana: solicitaron el código = metricas.solicitudes' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_d0 x
union all
select '017.' || x.entidad, '   D0 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_d0 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '018' as orden, 'D1 Semana: registros = metricas.personas' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_d1 x
union all
select '018.' || x.entidad, '   D1 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_d1 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '019' as orden, 'D2 Semana: verificados = registros (todo registro está verificado)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_d2 x
union all
select '019.' || x.entidad, '   D2 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_d2 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '020' as orden, 'D4 Semana: registros = solicitudes verificadas ese día' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_d4 x
union all
select '020.' || x.entidad, '   D4 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_d4 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '021' as orden, 'D3 Semana: primer consumo = metricas.personas.primer_consumo_dia' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_d3 x
union all
select '021.' || x.entidad, '   D3 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_d3 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '022' as orden, 'E1 Semana: transferido a locales = merchant_payouts' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_e1 x
union all
select '022.' || x.entidad, '   E1 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_e1 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '023' as orden, 'E2 Semana: caja al cierre = libro de caja hasta ese día' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_e2 x
union all
select '023.' || x.entidad, '   E2 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_e2 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '024' as orden, 'E3 Hoy: caja = ledger.balance_by_type(cash) = admin_cash_position' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_e3 x
union all
select '024.' || x.entidad, '   E3 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_e3 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '025' as orden, 'W1 Resumen semanal (Inicio): consumo' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_w1 x
union all
select '025.' || x.entidad, '   W1 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_w1 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '026' as orden, 'W2 Resumen semanal (Inicio): consumos' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_w2 x
union all
select '026.' || x.entidad, '   W2 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_w2 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '027' as orden, 'W3 Resumen semanal (Inicio): servicio sin IVA' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_w3 x
union all
select '027.' || x.entidad, '   W3 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_w3 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '028' as orden, 'W4 Resumen semanal (Inicio): personas' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_w4 x
union all
select '028.' || x.entidad, '   W4 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_w4 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '029' as orden, 'W5 Resumen semanal (Inicio): locales con ventas' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_w5 x
union all
select '029.' || x.entidad, '   W5 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_w5 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '030' as orden, 'W6 Resumen semanal (Inicio): registros' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_w6 x
union all
select '030.' || x.entidad, '   W6 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_w6 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '031' as orden, 'W7 Resumen semanal (Inicio): primer consumo' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_w7 x
union all
select '031.' || x.entidad, '   W7 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_w7 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '032' as orden, 'W8 Resumen semanal (Inicio): cargos por atraso' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_w8 x
union all
select '032.' || x.entidad, '   W8 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_w8 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '033' as orden, 'W9 Resumen semanal (Inicio): mora al cierre' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null)), true) as ok
from x_w9 x
union all
select '033.' || x.entidad, '   W9 ' || x.entidad,
       coalesce(round(x.e, 2)::text || ' %', 'nulo'), coalesce(round(x.o, 2)::text || ' %', 'nulo'), false
from x_w9 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.05, (x.e) is null and (x.o) is null), false)
union all
select '034' as orden, 'W10 Resumen semanal (Inicio): vencido al cierre' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_w10 x
union all
select '034.' || x.entidad, '   W10 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_w10 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '035' as orden, 'W11 Resumen semanal (Inicio): dado por perdido (consumo)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_w11 x
union all
select '035.' || x.entidad, '   W11 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_w11 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '036' as orden, 'X1 Caja (admin_metricas_caja): transferido por semana' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_x1 x
union all
select '036.' || x.entidad, '   X1 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_x1 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '037' as orden, 'X2 Caja (admin_metricas_caja): caja al cierre por semana' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_x2 x
union all
select '037.' || x.entidad, '   X2 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_x2 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '038' as orden, 'X3 Caja (admin_metricas_caja): lo que vencía, semanas cerradas' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_x3 x
union all
select '038.' || x.entidad, '   X3 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_x3 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '039' as orden, 'X4 Locales (admin_metricas_locales): totales de la semana en curso' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_x4 x
union all
select '039.' || x.entidad, '   X4 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_x4 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '040' as orden, 'X5 Locales (admin_metricas_locales): consumo y personas de cada local, semana en curso' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_x5 x
union all
select '040.' || x.entidad, '   X5 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_x5 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '041' as orden, 'X6 General (admin_metricas_general): caja, vencido y mora de hoy' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_x6 x
union all
select '041.' || x.entidad, '   X6 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_x6 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '042' as orden, 'X7 Resumen/Riesgo (admin_overview): vencido y mora de hoy' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_x7 x
union all
select '042.' || x.entidad, '   X7 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_x7 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '043' as orden, 'P1 Suma por locales = total: consumo' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_p1 x
union all
select '043.' || x.entidad, '   P1 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_p1 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '044' as orden, 'P2 Suma por locales = total: consumos' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_p2 x
union all
select '044.' || x.entidad, '   P2 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_p2 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '045' as orden, 'P3 Suma por locales = total: servicio' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_p3 x
union all
select '045.' || x.entidad, '   P3 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_p3 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '046' as orden, 'P4 Suma por locales = total: locales con ventas' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_p4 x
union all
select '046.' || x.entidad, '   P4 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_p4 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '047' as orden, 'P5 Suma por locales = total: lo que vencía' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_p5 x
union all
select '047.' || x.entidad, '   P5 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_p5 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '048' as orden, 'P6 Suma por locales = total: vencido al cierre' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_p6 x
union all
select '048.' || x.entidad, '   P6 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_p6 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '049' as orden, 'P7 Suma por locales = total: dado por perdido' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_p7 x
union all
select '049.' || x.entidad, '   P7 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_p7 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '050' as orden, 'P8 Suma por locales = total: transferido' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_p8 x
union all
select '050.' || x.entidad, '   P8 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_p8 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '051' as orden, 'P9 Suma por locales + cargos sin local = total: cargos por atraso' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_p9 x
union all
select '051.' || x.entidad, '   P9 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_p9 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '052' as orden, 'P10 Personas: la del local más grande ≤ total ≤ suma por locales' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.o) is true))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.o) is true), true) as ok
from x_p10 x
union all
select '052.' || x.entidad, '   P10 ' || x.entidad,
       'verdadero', case when x.o then 'verdadero' else 'falso' end, false
from x_p10 x where not coalesce((x.o) is true, false)
union all
select '053' as orden, 'P11 Cada local y semana: consumo = metricas.consumos del local' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_p11 x
union all
select '053.' || x.entidad, '   P11 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_p11 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '054' as orden, 'P12 Cada local y semana: primer consumo = nuevos en el local (personas_por_local)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_p12 x
union all
select '054.' || x.entidad, '   P12 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_p12 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '055' as orden, 'P13 Cada local y semana: vencido al cierre = cartera_al del local' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_p13 x
union all
select '055.' || x.entidad, '   P13 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_p13 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '056' as orden, 'P14 Con local: solicitaron, registros, verificados y caja valen null (no cero)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.o) is true))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.o) is true), true) as ok
from x_p14 x
union all
select '056.' || x.entidad, '   P14 ' || x.entidad,
       'verdadero', case when x.o then 'verdadero' else 'falso' end, false
from x_p14 x where not coalesce((x.o) is true, false)
union all
select '057' as orden, 'M1 Semana en curso frente a la anterior hasta el mismo momento: consumo' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_m1 x
union all
select '057.' || x.entidad, '   M1 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_m1 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '058' as orden, 'M6 La anterior hasta el mismo momento: consumos' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_m6 x
union all
select '058.' || x.entidad, '   M6 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_m6 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '059' as orden, 'M7 La anterior hasta el mismo momento: usuarios (min del instante de sus consumos)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_m7 x
union all
select '059.' || x.entidad, '   M7 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_m7 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '060' as orden, 'M8 El corte: ahora − 7 días si la elegida está en curso; nulo si está cerrada' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.o) is true))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.o) is true), true) as ok
from x_m8 x
union all
select '060.' || x.entidad, '   M8 ' || x.entidad,
       'verdadero', case when x.o then 'verdadero' else 'falso' end, false
from x_m8 x where not coalesce((x.o) is true, false)
union all
select '061' as orden, 'M9 La anterior hasta el mismo momento: registros (verificados antes del corte)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_m9 x
union all
select '061.' || x.entidad, '   M9 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_m9 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '062' as orden, 'M10 La anterior hasta el mismo momento: solicitaron el código' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_m10 x
union all
select '062.' || x.entidad, '   M10 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_m10 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '063' as orden, 'M11 La anterior hasta el mismo momento: primer consumo (su primer consumo, antes del corte)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.e) is not distinct from (x.o)))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.e) is not distinct from (x.o)), true) as ok
from x_m11 x
union all
select '063.' || x.entidad, '   M11 ' || x.entidad,
       coalesce((x.e)::text, 'nulo'), coalesce((x.o)::text, 'nulo'), false
from x_m11 x where not coalesce((x.e) is not distinct from (x.o), false)
union all
select '064' as orden, 'M12 La anterior hasta el mismo momento: cargos por atraso (cargados antes del corte)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_m12 x
union all
select '064.' || x.entidad, '   M12 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_m12 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '065' as orden, 'M13 La anterior hasta el mismo momento: transferido a locales (apuntado antes del corte)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_m13 x
union all
select '065.' || x.entidad, '   M13 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_m13 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '066' as orden, 'M2 La anterior a la misma altura: los mismos días que la elegida' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.o) is true))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.o) is true), true) as ok
from x_m2 x
union all
select '066.' || x.entidad, '   M2 ' || x.entidad,
       'verdadero', case when x.o then 'verdadero' else 'falso' end, false
from x_m2 x where not coalesce((x.o) is true, false)
union all
select '067' as orden, 'M3 La anterior a la misma altura: vencido al cierre del día equivalente' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)))::text || ' cuadran' as obtenido,
       coalesce(bool_and(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null)), true) as ok
from x_m3 x
union all
select '067.' || x.entidad, '   M3 ' || x.entidad,
       coalesce(round(x.e, 2)::text, 'nulo'), coalesce(round(x.o, 2)::text, 'nulo'), false
from x_m3 x where not coalesce(coalesce(abs((x.e) - (x.o)) < 0.01, (x.e) is null and (x.o) is null), false)
union all
select '068' as orden, 'M4 La anterior: el cobro a tiempo se juzga en los mismos días de la semana' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.o) is true))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.o) is true), true) as ok
from x_m4 x
union all
select '068.' || x.entidad, '   M4 ' || x.entidad,
       'verdadero', case when x.o then 'verdadero' else 'falso' end, false
from x_m4 x where not coalesce((x.o) is true, false)
union all
select '069' as orden, 'M5 Semana cerrada: su comparación es la columna anterior entera' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.o) is true))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.o) is true), true) as ok
from x_m5 x
union all
select '069.' || x.entidad, '   M5 ' || x.entidad,
       'verdadero', case when x.o then 'verdadero' else 'falso' end, false
from x_m5 x where not coalesce((x.o) is true, false)
union all
select '070' as orden, 'F1 Todo payable = consumo + servicio e IVA (semanas y locales)' as comprobacion,
       count(*)::text || ' filas' as esperado,
       (count(*) filter (where (x.o) is true))::text || ' cuadran' as obtenido,
       coalesce(bool_and((x.o) is true), true) as ok
from x_f1 x
union all
select '070.' || x.entidad, '   F1 ' || x.entidad,
       'verdadero', case when x.o then 'verdadero' else 'falso' end, false
from x_f1 x where not coalesce((x.o) is true, false)
)
select comprobacion, esperado, obtenido, ok
from resultado
order by orden;
