-- ============================================================================
-- Batería de coherencia de Métricas › Gente y › Caja (dev)
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok, con el
-- formato de metricas_coherencia.sql. «Esperado» es la definición canónica
-- (esquema metricas) o la otra pantalla que enseña lo mismo; «obtenido», lo
-- que devuelve la RPC que pinta la pestaña. Las comprobaciones por local o
-- por semana dan una fila resumen «N cuadran de M».
--
-- Solo SELECT. Se hace pasar por un admin activo (request.jwt.claims) sin
-- cambiar el rol, para poder leer metricas.* en la misma consulta.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_gente-caja.sql
-- ============================================================================

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

with
h as (
  select metricas.hoy() as hoy,
         metricas.lunes(metricas.hoy()) as lunes,
         metricas.hoy() - 27 as desde28
),
locales as (
  select m.id
  from public.merchants m
  where not m.is_test and exists (select 1 from metricas.consumos k where k.merchant_id = m.id)
),

-- ── Gente ──────────────────────────────────────────────────────────────────
g_todos as (select public.admin_growth_overview(h.desde28, h.hoy) as j from h),
g_local as (
  select l.id, public.admin_growth_overview(h.desde28, h.hoy, l.id) as j,
         public.admin_user_behavior(h.desde28, h.hoy, l.id) as b,
         public.admin_group_metrics(h.desde28, h.hoy, l.id) as g
  from locales l cross join h
),
g_esp as (
  select l.id,
         (select count(distinct q.user_id) from metricas.cuotas q
          where q.merchant_id = l.id and q.business_date between h.desde28 and h.hoy) as personas,
         (select count(*) from metricas.consumos k
          where k.merchant_id = l.id and k.business_date between h.desde28 and h.hoy) as consumos,
         (select coalesce(sum(k.financed_usd), 0) from metricas.consumos k
          where k.merchant_id = l.id and k.business_date between h.desde28 and h.hoy) as consumo,
         (select count(*) from metricas.personas_por_local p
          where p.merchant_id = l.id and p.primer_dia between h.desde28 and h.hoy) as nuevas
  from locales l cross join h
),
g_cmp as (
  select e.id,
         e.personas = (o.j->'active_users'->>'count')::int                                   as personas_ok,
         e.personas = (o.b->>'active_users')::int                                            as uso_ok,
         abs(e.consumo - (o.j->'spend'->>'financed_usd')::numeric) < 0.01                   as consumo_ok,
         e.nuevas = (o.j->'activated'->>'count')::int                                        as nuevas_ok,
         e.consumos = (o.g->'split'->>'group_charges')::int + (o.g->'split'->>'solo_charges')::int as grupos_ok
  from g_esp e join g_local o using (id)
),
-- La semana en curso de Gente (ventana «la semana») contra la pestaña Semana.
g_semana as (select public.admin_growth_overview(h.lunes, h.hoy) as j from h),
s_semana as (select public.admin_weekly_summary(1)->'rows'->-1 as j),
-- La retención con local: el tamaño de las cohortes es la gente nueva en el local.
r_local as (
  select l.id, public.admin_user_cohorts('week', 8, l.id) as j,
         (select count(*) from metricas.personas_por_local p
          where p.merchant_id = l.id
            and p.primer_semana between h.lunes - 49 and h.lunes) as esperado
  from locales l cross join h
),
r_todos as (
  select public.admin_user_cohorts('week', 8) as j,
         (select count(*) from metricas.personas p, h where p.registro_semana between h.lunes - 49 and h.lunes) as esperado
),
p_local as (
  select l.id, public.admin_user_persona('consumieron', l.id) as j,
         (select count(*) from metricas.personas_por_local p
          join metricas.personas r on r.user_id = p.user_id
          where p.merchant_id = l.id) as esperado
  from locales l
),

-- ── Caja ───────────────────────────────────────────────────────────────────
c_pos as (select public.admin_cash_position() as j),
c_sem as (select public.admin_metricas_caja() as j),
c_semanas as (
  select w.lunes, m.*
  from h
  cross join lateral (select (h.lunes - 7 * g.k)::date as lunes from generate_series(0, 11) g(k)) w
  cross join lateral metricas.caja_movimientos(w.lunes, least(w.lunes + 6, h.hoy)) m
),
c_local_sem as (
  select l.id, m.*
  from locales l cross join h
  cross join lateral metricas.caja_movimientos(h.lunes, h.hoy, l.id) m
),
c_local_todo as (
  select l.id, m.*
  from locales l cross join h
  cross join lateral metricas.caja_movimientos('2000-01-01'::date, h.hoy, l.id) m
),
c_todo as (select m.* from h cross join lateral metricas.caja_movimientos('2000-01-01'::date, h.hoy) m),
c_sem_todos as (select m.* from h cross join lateral metricas.caja_movimientos(h.lunes, h.hoy) m),
-- La proyección canónica contra la de siempre (la que se guarda cada lunes).
p_nueva as (
  select p.*
  from h cross join lateral metricas.caja_proyeccion(
    h.hoy, public.helios_next_settlement_run(now()) - 7, 13, h.hoy + 84) p
),
p_vieja as (
  select (x->>'week_start')::date as week_start,
         (x->>'expected_gross_usd')::numeric as bruto,
         (x->>'expected_out_usd')::numeric as sale
  from h cross join lateral jsonb_array_elements(
    public.helios_cash_forecast(h.hoy, public.helios_next_settlement_run(now()) - 7, 13, h.hoy + 84) -> 'rows') x
),
p_locales as (
  select p.week_start, sum(p.vence_payable_usd) as bruto, sum(p.sale_usd) as sale
  from locales l cross join h
  cross join lateral metricas.caja_proyeccion(
    h.hoy, public.helios_next_settlement_run(now()) - 7, 13, h.hoy + 84, l.id) p
  group by p.week_start
),
c_pagar as (
  select coalesce(sum((x->>'total_pending_usd')::numeric), 0) as total
  from jsonb_array_elements(public.admin_merchant_payables()) x
  where not (x->>'is_test')::boolean
),
c_pagar_local as (
  select l.id,
         (public.admin_cash_position(l.id)->>'merchant_payable')::numeric as foto,
         (public.admin_metricas_caja(null, l.id)->'por_pagar_locales'->>'total_usd')::numeric as semana
  from locales l
),
-- El servicio sin IVA de cada cuota, por su estado: lo cobrado, lo vivo y lo
-- perdido suman lo ganado.
c_servicio as (
  select coalesce(sum(q.fee_usd * coalesce(k.servicio_usd / nullif(k.fee_usd, 0), 0)), 0) as todo
  from metricas.cuotas q join metricas.consumos k on k.charge_id = q.charge_id
),

r(orden, comprobacion, esperado, obtenido, ok) as (
  -- Gente
  select 1, 'G1 Gente: personas que consumieron por local (28 días), desde las cuotas',
         (select count(*) from g_cmp)::text || ' locales',
         (select count(*) filter (where personas_ok) from g_cmp)::text || ' cuadran',
         (select bool_and(personas_ok) from g_cmp)
  union all
  select 2, 'G2 Gente › Uso: las mismas personas por local',
         (select count(*) from g_cmp)::text || ' locales',
         (select count(*) filter (where uso_ok) from g_cmp)::text || ' cuadran',
         (select bool_and(uso_ok) from g_cmp)
  union all
  select 3, 'G3 Gente: consumo por local (sin servicio)',
         (select count(*) from g_cmp)::text || ' locales',
         (select count(*) filter (where consumo_ok) from g_cmp)::text || ' cuadran',
         (select bool_and(consumo_ok) from g_cmp)
  union all
  select 4, 'G4 Gente: la suma de los locales es el consumo de todos',
         round((select (j->'spend'->>'financed_usd')::numeric from g_todos), 2)::text,
         round((select sum((j->'spend'->>'financed_usd')::numeric) from g_local), 2)::text,
         abs((select (j->'spend'->>'financed_usd')::numeric from g_todos)
             - (select sum((j->'spend'->>'financed_usd')::numeric) from g_local)) < 0.01
  union all
  select 5, 'G5 Gente: nuevas en el local = primera cuota en ese local',
         (select count(*) from g_cmp)::text || ' locales',
         (select count(*) filter (where nuevas_ok) from g_cmp)::text || ' cuadran',
         (select bool_and(nuevas_ok) from g_cmp)
  union all
  select 6, 'G6 Gente › Grupos: consumos de grupo + solos = consumos del local',
         (select count(*) from g_cmp)::text || ' locales',
         (select count(*) filter (where grupos_ok) from g_cmp)::text || ' cuadran',
         (select bool_and(grupos_ok) from g_cmp)
  union all
  select 7, 'G7 Gente (la semana) = Semana: personas que consumieron',
         (select j->>'active_users' from s_semana),
         (select j->'active_users'->>'count' from g_semana),
         (select (j->>'active_users')::int from s_semana) = (select (j->'active_users'->>'count')::int from g_semana)
  union all
  select 8, 'G8 Gente (la semana) = Semana: registros',
         (select j->>'new_users' from s_semana),
         (select j->'registered'->>'count' from g_semana),
         (select (j->>'new_users')::int from s_semana) = (select (j->'registered'->>'count')::int from g_semana)
  union all
  select 9, 'G9 Gente (la semana) = Semana: primeros consumos',
         (select j->>'first_time_buyers' from s_semana),
         (select j->'activated'->>'count' from g_semana),
         (select (j->>'first_time_buyers')::int from s_semana) = (select (j->'activated'->>'count')::int from g_semana)
  union all
  select 10, 'G10 Gente (la semana) = Semana: consumo',
         round((select (j->>'financed_usd')::numeric from s_semana), 2)::text,
         round((select (j->'spend'->>'financed_usd')::numeric from g_semana), 2)::text,
         abs((select (j->>'financed_usd')::numeric from s_semana) - (select (j->'spend'->>'financed_usd')::numeric from g_semana)) < 0.01
  union all
  select 11, 'G11 Gente (la semana) = Semana: servicio sin IVA',
         round((select (j->>'service_fee_usd')::numeric from s_semana), 2)::text,
         round((select (j->'spend'->>'revenue_usd')::numeric from g_semana), 2)::text,
         abs((select (j->>'service_fee_usd')::numeric from s_semana) - (select (j->'spend'->>'revenue_usd')::numeric from g_semana)) < 0.01
  union all
  select 12, 'G12 Retención: las cohortes de 8 semanas suman los registros de esas semanas',
         (select esperado::text from r_todos),
         (select coalesce(sum((x->>'size')::int), 0)::text from r_todos, jsonb_array_elements(r_todos.j->'rows') x),
         (select esperado from r_todos) = (select coalesce(sum((x->>'size')::int), 0) from r_todos, jsonb_array_elements(r_todos.j->'rows') x)
  union all
  select 13, 'G13 Retención con local: las cohortes suman la gente nueva en el local',
         (select count(*) from r_local)::text || ' locales',
         (select count(*) filter (where esperado = (select coalesce(sum((x->>'size')::int), 0) from jsonb_array_elements(r_local.j->'rows') x)) from r_local)::text || ' cuadran',
         (select bool_and(esperado = (select coalesce(sum((x->>'size')::int), 0) from jsonb_array_elements(r_local.j->'rows') x)) from r_local)
  union all
  select 14, 'G14 Perfil con local: la gente registrada que consumió en él',
         (select count(*) from p_local)::text || ' locales',
         (select count(*) filter (where esperado = (j->>'people')::int) from p_local)::text || ' cuadran',
         (select bool_and(esperado = (j->>'people')::int) from p_local)
  union all
  select 15, 'G15 Perfil sin local: consumieron = registros que han comprado',
         (select count(*) from metricas.personas where primer_consumo_dia is not null)::text,
         (select public.admin_user_persona('consumieron')->>'people'),
         (select count(*) from metricas.personas where primer_consumo_dia is not null)
           = (select (public.admin_user_persona('consumieron')->>'people')::int)

  -- Caja
  union all
  select 20, 'C1 Caja al cierre de la semana en curso = Dinero en caja del Balance (libro)',
         round((select (j->>'cash')::numeric from c_pos), 2)::text,
         round((select (j->'caja'->>'al_cierre_usd')::numeric from c_sem), 2)::text,
         abs((select (j->>'cash')::numeric from c_pos) - (select (j->'caja'->>'al_cierre_usd')::numeric from c_sem)) < 0.01
  union all
  select 21, 'C2 Libro de caja = cuotas cobradas + cargos por atraso (12 semanas)',
         (select count(*) from c_semanas)::text || ' semanas',
         (select count(*) filter (where abs(libro_cobrado_usd - cobrado_payable_usd - cargos_cobrados_usd) < 0.01) from c_semanas)::text || ' cuadran',
         (select bool_and(abs(libro_cobrado_usd - cobrado_payable_usd - cargos_cobrados_usd) < 0.01) from c_semanas)
  union all
  select 22, 'C3 Libro de caja = transferido a los locales (12 semanas)',
         (select count(*) from c_semanas)::text || ' semanas',
         (select count(*) filter (where abs(libro_transferido_usd - transferido_usd) < 0.01) from c_semanas)::text || ' cuadran',
         (select bool_and(abs(libro_transferido_usd - transferido_usd) < 0.01) from c_semanas)
  union all
  select 23, 'C4 Lo cobrado = consumo + servicio e IVA (12 semanas)',
         (select count(*) from c_semanas)::text || ' semanas',
         (select count(*) filter (where abs(cobrado_payable_usd - cobrado_financed_usd - cobrado_fee_usd) < 0.005) from c_semanas)::text || ' cuadran',
         (select bool_and(abs(cobrado_payable_usd - cobrado_financed_usd - cobrado_fee_usd) < 0.005) from c_semanas)
  union all
  select 24, 'C5 La suma de los locales es lo cobrado de todos (semana en curso)',
         round((select cobrado_payable_usd from c_sem_todos), 2)::text,
         round((select sum(cobrado_payable_usd) from c_local_sem), 2)::text,
         abs((select cobrado_payable_usd from c_sem_todos) - (select sum(cobrado_payable_usd) from c_local_sem)) < 0.01
  union all
  select 25, 'C6 La suma de los locales es lo transferido a todos (desde el inicio)',
         round((select transferido_usd from c_todo), 2)::text,
         round((select sum(transferido_usd) from c_local_todo), 2)::text,
         abs((select transferido_usd from c_todo) - (select sum(transferido_usd) from c_local_todo)) < 0.01
  union all
  select 26, 'C7 Cobrado desde el inicio = cuotas pagadas (lo que enseña General)',
         round((select coalesce(sum(payable_usd), 0) from metricas.cuotas where status = 'paid'), 2)::text,
         round((select cobrado_payable_usd from c_todo), 2)::text,
         abs((select coalesce(sum(payable_usd), 0) from metricas.cuotas where status = 'paid') - (select cobrado_payable_usd from c_todo)) < 0.01
  union all
  select 27, 'C8 Por cobrar a usuarios (libro) = cuotas vivas + cargos pendientes',
         round((select (j->>'user_receivable')::numeric from c_pos), 2)::text,
         round((select (j->'receivable'->>'payable_usd')::numeric + (j->'receivable'->>'late_fees_usd')::numeric from c_pos), 2)::text,
         abs((select (j->>'user_receivable')::numeric - (j->'receivable'->>'payable_usd')::numeric - (j->'receivable'->>'late_fees_usd')::numeric from c_pos)) < 0.01
  union all
  select 28, 'C9 Por cobrar (cuotas vivas) = vencido + por vencer de la cartera',
         round((select vencido_payable_usd + por_vencer_payable_usd from h cross join lateral metricas.cartera_al(h.hoy) c), 2)::text,
         round((select (j->'receivable'->>'payable_usd')::numeric from c_pos), 2)::text,
         abs((select vencido_payable_usd + por_vencer_payable_usd from h cross join lateral metricas.cartera_al(h.hoy) c)
             - (select (j->'receivable'->>'payable_usd')::numeric from c_pos)) < 0.01
  union all
  select 29, 'C10 Dado por perdido (libro) = cuotas perdidas + cargos castigados',
         round((select (j->>'written_off')::numeric from c_pos), 2)::text,
         round((select (j->'lost'->>'payable_usd')::numeric + (j->'lost'->>'late_fees_usd')::numeric from c_pos), 2)::text,
         abs((select (j->>'written_off')::numeric - (j->'lost'->>'payable_usd')::numeric - (j->'lost'->>'late_fees_usd')::numeric from c_pos)) < 0.01
  union all
  select 30, 'C11 Servicio ganado = el servicio sin IVA de los consumos (General y Semana)',
         round((select coalesce(sum(servicio_usd), 0) from metricas.consumos), 2)::text,
         round((select (j->'service'->>'earned_usd')::numeric from c_pos), 2)::text,
         abs((select coalesce(sum(servicio_usd), 0) from metricas.consumos) - (select (j->'service'->>'earned_usd')::numeric from c_pos)) < 0.01
  union all
  select 31, 'C12 Ingreso del libro = servicio sin IVA + cargos por atraso + comisión a locales',
         round((select (j->>'platform_revenue')::numeric from c_pos), 2)::text,
         round((select (j->'service'->>'earned_usd')::numeric + (j->'service'->>'late_fees_earned_usd')::numeric from c_pos)
               + (select coalesce(sum(comision_local_usd), 0) from metricas.consumos), 2)::text,
         abs((select (j->>'platform_revenue')::numeric - (j->'service'->>'earned_usd')::numeric - (j->'service'->>'late_fees_earned_usd')::numeric from c_pos)
             - (select coalesce(sum(comision_local_usd), 0) from metricas.consumos)) < 0.01
  union all
  select 32, 'C13 El servicio de las cuotas (cobradas, vivas y perdidas) suma el ganado',
         round((select coalesce(sum(servicio_usd), 0) from metricas.consumos), 2)::text,
         round((select todo from c_servicio), 2)::text,
         abs((select coalesce(sum(servicio_usd), 0) from metricas.consumos) - (select todo from c_servicio)) < 0.05
  union all
  select 33, 'C14 La proyección canónica = la que se guarda cada lunes (13 semanas)',
         (select count(*) from p_vieja)::text || ' semanas',
         (select count(*) from p_vieja v join p_nueva n using (week_start)
          where abs(v.bruto - n.vence_payable_usd) < 0.01 and abs(v.sale - n.sale_usd) < 0.01)::text || ' cuadran',
         (select count(*) from p_vieja) = (select count(*) from p_vieja v join p_nueva n using (week_start)
          where abs(v.bruto - n.vence_payable_usd) < 0.01 and abs(v.sale - n.sale_usd) < 0.01)
  union all
  select 34, 'C15 La proyección por locales suma la de todos (13 semanas)',
         (select count(*) from p_nueva)::text || ' semanas',
         (select count(*) from p_nueva n left join p_locales l using (week_start)
          where abs(n.vence_payable_usd - coalesce(l.bruto, 0)) < 0.01 and abs(n.sale_usd - coalesce(l.sale, 0)) < 0.01)::text || ' cuadran',
         (select count(*) from p_nueva) = (select count(*) from p_nueva n left join p_locales l using (week_start)
          where abs(n.vence_payable_usd - coalesce(l.bruto, 0)) < 0.01 and abs(n.sale_usd - coalesce(l.sale, 0)) < 0.01)
  union all
  select 35, 'C16 Por pagar a locales (Caja) = Pagos a locales',
         round((select total from c_pagar), 2)::text,
         round((select (j->'por_pagar_locales'->>'total_usd')::numeric from c_sem), 2)::text,
         abs((select total from c_pagar) - (select (j->'por_pagar_locales'->>'total_usd')::numeric from c_sem)) < 0.01
  union all
  select 36, 'C17 Por pagar a un local: la foto y la semana dicen lo mismo',
         (select count(*) from c_pagar_local)::text || ' locales',
         (select count(*) filter (where abs(foto - semana) < 0.01) from c_pagar_local)::text || ' cuadran',
         (select bool_and(abs(foto - semana) < 0.01) from c_pagar_local)
  union all
  select 37, 'C18 La semana de Caja (servicio ganado) = Semana',
         round((select (j->>'service_fee_usd')::numeric from s_semana), 2)::text,
         round((select (j->'movimientos'->>'servicio_ganado_usd')::numeric from c_sem), 2)::text,
         abs((select (j->>'service_fee_usd')::numeric from s_semana) - (select (j->'movimientos'->>'servicio_ganado_usd')::numeric from c_sem)) < 0.01
  union all
  select 38, 'C19 La semana de Caja (cargos por atraso cobrados) = Semana',
         round((select (j->>'late_fee_collected_usd')::numeric from s_semana), 2)::text,
         round((select (j->'movimientos'->'cargos_cobrados'->>'usd')::numeric from c_sem), 2)::text,
         abs((select (j->>'late_fee_collected_usd')::numeric from s_semana) - (select (j->'movimientos'->'cargos_cobrados'->>'usd')::numeric from c_sem)) < 0.01
)
select comprobacion, esperado, obtenido, coalesce(ok, false) as ok
from r
order by orden;
