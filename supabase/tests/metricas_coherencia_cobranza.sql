-- ============================================================================
-- Batería de coherencia de Métricas › Cobranza y riesgo (dev)
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok. «Esperado»
-- es la definición canónica (esquema metricas) o la otra pantalla que enseña
-- lo mismo; «obtenido», lo que devuelve la RPC que pinta el panel. Lo que se
-- parte por local se comprueba sumando los locales contra el total.
--
-- Solo SELECT. Se hace pasar por un admin activo poniendo request.jwt.claims
-- (con aal2); no cambia el rol, así la misma consulta puede leer metricas.*.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_cobranza.sql
-- ============================================================================

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

with
h as (
  select metricas.hoy() as hoy,
         metricas.lunes(metricas.hoy()) as lunes,
         metricas.lunes(metricas.hoy()) + 6 as domingo,
         metricas.lunes(metricas.hoy()) - 7 as lunes_ant,
         metricas.lunes(metricas.hoy()) - 1 as domingo_ant
),
mq as (select * from metricas.cuotas),
locales as (
  select m.id from public.merchants m
  where not m.is_test and exists (select 1 from metricas.consumos k where k.merchant_id = m.id)
),
-- Las respuestas del panel.
sem   as (select public.admin_metricas_cobranza(null, null) as j),
semp  as (select public.admin_metricas_cobranza((select lunes_ant from h), null) as j),
ov    as (select public.admin_overview(30) as j),
deud  as (select public.admin_deudores_por_perfil(null) as j),
cola  as (select public.admin_collections(7) as j),
flujo as (select public.admin_collection_flow(1, null, (select hoy from h)) as j),
flujop as (select public.admin_collection_flow(1, null, (select domingo_ant from h)) as j),
dias  as (select d.* from public.admin_due_vs_collected(7, null, (select domingo from h)) d),
ont   as (select public.admin_on_time_collection(7, null, (select domingo_ant from h)) as j),
fpdm  as (select public.admin_first_payment_default(3, 'mes') as j),
fpds  as (select public.admin_first_payment_default(3, 'semana') as j),
-- El impago de cada cuota (COBRANZA3): la 1 pedida a mano y la 2.
fpd1  as (select public.admin_first_payment_default(3, 'mes', null, null, 1) as j),
fpd2m as (select public.admin_first_payment_default(3, 'mes', null, null, 2) as j),
fpd2s as (select public.admin_first_payment_default(3, 'semana', null, null, 2) as j),
-- Lo mismo contado a mano sobre metricas.cuotas: los consumos desde el día 1
-- del mes de hace dos meses, maduras al pasar la gracia de su vencimiento.
fpd_mano as (
  select q.sequence as cuota,
         count(*) filter (where q.due_date + g.dias < h.hoy)                                   as maduras,
         count(*) filter (where q.due_date + g.dias < h.hoy
                            and not (q.status = 'paid'
                                     and (q.pagada_dia is null or q.pagada_dia <= q.due_date + g.dias))) as impagas
  from mq q, h, (select public.helios_late_fee_grace_days() as dias) g
  where q.business_date between (date_trunc('month', h.hoy::timestamp) - interval '2 months')::date and h.hoy
  group by q.sequence
),
-- De quien pagó la cuota 1, qué parte no paga la 2 (MORA-INICIO), contado a
-- mano: la cuota 2 madura cuya cuota 1 (misma persona, mismo consumo) estaba
-- pagada al acabar la gracia de la 2.
fpd2_tras_1_mano as (
  select count(*) filter (where d.madura and d.pago_la_1)                              as maduras,
         count(*) filter (where d.madura and d.pago_la_1 and not d.pago_la_2)          as impagas
  from (
    select q2.due_date + g.dias < h.hoy as madura,
           q2.status = 'paid' and (q2.pagada_dia is null or q2.pagada_dia <= q2.due_date + g.dias) as pago_la_2,
           coalesce(q1.status = 'paid' and (q1.pagada_dia is null or q1.pagada_dia <= q2.due_date + g.dias), false) as pago_la_1
    from mq q2
    cross join h
    cross join (select public.helios_late_fee_grace_days() as dias) g
    left join mq q1 on q1.charge_id = q2.charge_id and q1.user_id = q2.user_id and q1.sequence = 1
    where q2.sequence = 2
      and q2.business_date between (date_trunc('month', h.hoy::timestamp) - interval '2 months')::date and h.hoy
  ) d
),
-- Una sola gracia: las cuotas 1 maduras de la ventana, pagadas a tiempo
-- (metricas.cuotas) y sin pagar tras la gracia (el impago).
una_gracia as (
  select count(*) filter (where q.estado_hoy = 'a_tiempo')              as a_tiempo,
         count(*) filter (where q.due_date + g.dias < h.hoy)            as maduras
  from mq q, h, (select public.helios_late_fee_grace_days() as dias) g
  where q.sequence = 1
    and q.due_date + g.dias < h.hoy
    and q.business_date between (date_trunc('month', h.hoy::timestamp) - interval '2 months')::date and h.hoy
),
-- Inicio › Deuda vencida: la semana en curso de admin_weekly_summary.
ws as (
  select r as j
  from jsonb_array_elements(public.admin_weekly_summary(1)->'rows') r
  order by r->>'week_start' desc
  limit 1
),
rec   as (select public.admin_collection_recovered((select lunes_ant from h), (select domingo_ant from h)) as j),
por_local as (
  select l.id,
         public.admin_metricas_cobranza(null, l.id) as sem,
         public.admin_deudores_por_perfil(l.id) as deud,
         public.admin_collection_recovered((select lunes_ant from h), (select domingo_ant from h), l.id) as rec,
         (select coalesce(sum(d.due_usd), 0) from public.admin_due_vs_collected(7, l.id, (select domingo from h)) d) as vence,
         (select jsonb_agg(x) from public.admin_merchant_risk(90, l.id) x) as riesgo,
         public.admin_first_payment_default(3, 'mes', l.id, null, 2) as fpd2
  from locales l
),
r(orden, comprobacion, esperado, obtenido, ok) as (
  -- ── La cartera al corte ────────────────────────────────────────────────
  select '01', 'C1 Vencido de hoy = Σ cuotas vencidas (metricas.cuotas)',
         round((select coalesce(sum(payable_usd), 0) from mq where estado_hoy = 'vencida'), 2)::text,
         round((select (j->'cartera'->'vencido'->>'payable_usd')::numeric from sem), 2)::text,
         abs((select coalesce(sum(payable_usd), 0) from mq where estado_hoy = 'vencida')
             - (select (j->'cartera'->'vencido'->>'payable_usd')::numeric from sem)) < 0.01
  union all
  select '02', 'C2 Vencido de hoy = Resumen/Inicio (admin_overview.arrears.overdue_usd)',
         round((select (j->'arrears'->>'overdue_usd')::numeric from ov), 2)::text,
         round((select (j->'cartera'->'vencido'->>'payable_usd')::numeric from sem), 2)::text,
         abs((select (j->'arrears'->>'overdue_usd')::numeric from ov)
             - (select (j->'cartera'->'vencido'->>'payable_usd')::numeric from sem)) < 0.01
  union all
  select '03', 'C3 Mora de hoy = admin_overview.arrears.rate_pct',
         (select j->'arrears'->>'rate_pct' from ov),
         coalesce((select j->'cartera'->>'mora_pct' from sem), 'nulo'),
         coalesce((select (j->'arrears'->>'rate_pct')::numeric from ov)
                  = (select (j->'cartera'->>'mora_pct')::numeric from sem), false)
  union all
  select '04', 'C4 Personas con algo vencido = admin_overview.arrears.overdue_users',
         (select j->'arrears'->>'overdue_users' from ov),
         (select j->'cartera'->>'personas_vencidas' from sem),
         (select (j->'arrears'->>'overdue_users')::integer from ov)
           = (select (j->'cartera'->>'personas_vencidas')::integer from sem)
  union all
  select '05', 'C5 La semana anterior a la misma altura = metricas.cartera_al(corte − 7)',
         round((select vencido_payable_usd from metricas.cartera_al((select hoy from h) - 7)), 2)::text,
         round((select (j->'cartera_anterior'->'vencido'->>'payable_usd')::numeric from sem), 2)::text,
         abs((select vencido_payable_usd from metricas.cartera_al((select hoy from h) - 7))
             - (select (j->'cartera_anterior'->'vencido'->>'payable_usd')::numeric from sem)) < 0.01
  union all
  select '06', 'C6 Semana pasada: vencido a su cierre = metricas.cartera_al(domingo)',
         round((select vencido_payable_usd from metricas.cartera_al((select domingo_ant from h))), 2)::text,
         round((select (j->'cartera'->'vencido'->>'payable_usd')::numeric from semp), 2)::text,
         abs((select vencido_payable_usd from metricas.cartera_al((select domingo_ant from h)))
             - (select (j->'cartera'->'vencido'->>'payable_usd')::numeric from semp)) < 0.01
  -- ── La mora por tramo ──────────────────────────────────────────────────
  union all
  select '07', 'C7 Σ tramos (vencido) = vencido de la cartera',
         round((select (j->'cartera'->'vencido'->>'payable_usd')::numeric from sem), 2)::text,
         round((select sum((f->>'payable_usd')::numeric) from sem, jsonb_array_elements(sem.j->'tramos'->'filas') f), 2)::text,
         abs((select (j->'cartera'->'vencido'->>'payable_usd')::numeric from sem)
             - (select sum((f->>'payable_usd')::numeric) from sem, jsonb_array_elements(sem.j->'tramos'->'filas') f)) < 0.01
  union all
  select '08', 'C8 Σ tramos (personas) = personas con algo vencido',
         (select j->'cartera'->>'personas_vencidas' from sem),
         (select sum((f->>'personas')::integer)::text from sem, jsonb_array_elements(sem.j->'tramos'->'filas') f),
         (select (j->'cartera'->>'personas_vencidas')::integer from sem)
           = (select sum((f->>'personas')::integer) from sem, jsonb_array_elements(sem.j->'tramos'->'filas') f)
  union all
  select '09', 'C9 Semana pasada: Σ tramos = vencido a su cierre',
         round((select (j->'cartera'->'vencido'->>'payable_usd')::numeric from semp), 2)::text,
         round((select sum((f->>'payable_usd')::numeric) from semp, jsonb_array_elements(semp.j->'tramos'->'filas') f), 2)::text,
         abs((select (j->'cartera'->'vencido'->>'payable_usd')::numeric from semp)
             - (select sum((f->>'payable_usd')::numeric) from semp, jsonb_array_elements(semp.j->'tramos'->'filas') f)) < 0.01
  -- ── El paso entre tramos ───────────────────────────────────────────────
  union all
  select '10', 'C10 Paso hasta hoy: personas por tramo = mora por tramo',
         (select string_agg(f->>'personas', ',' order by f->>'tramo') from sem, jsonb_array_elements(sem.j->'tramos'->'filas') f),
         (select string_agg(coalesce(flujo.j->'weeks'->-1->'people'->>t, '0'), ',' order by t)
            from flujo, unnest(array['t1', 't2', 't3', 't4', 't5']) t),
         (select string_agg(f->>'personas', ',' order by f->>'tramo') from sem, jsonb_array_elements(sem.j->'tramos'->'filas') f)
           = (select string_agg(coalesce(flujo.j->'weeks'->-1->'people'->>t, '0'), ',' order by t)
                from flujo, unnest(array['t1', 't2', 't3', 't4', 't5']) t)
  union all
  select '11', 'C11 Paso hasta hoy: vencido por tramo = mora por tramo',
         round((select sum((f->>'payable_usd')::numeric) from sem, jsonb_array_elements(sem.j->'tramos'->'filas') f), 2)::text,
         round((select sum(v::numeric) from flujo, jsonb_each_text(flujo.j->'weeks'->-1->'overdue_usd') e(k, v)), 2)::text,
         abs((select sum((f->>'payable_usd')::numeric) from sem, jsonb_array_elements(sem.j->'tramos'->'filas') f)
             - (select sum(v::numeric) from flujo, jsonb_each_text(flujo.j->'weeks'->-1->'overdue_usd') e(k, v))) < 0.01
  union all
  select '12', 'C12 Paso: la gente de la cartera = personas con alguna cuota',
         (select count(distinct user_id)::text from mq),
         (select flujo.j->'weeks'->-1->>'people_total' from flujo),
         (select count(distinct user_id) from mq) = (select (flujo.j->'weeks'->-1->>'people_total')::integer from flujo)
  union all
  select '13', 'C13 Paso: cada persona en una sola casilla (Σ pasos = gente del corte)',
         (select flujo.j->'weeks'->-1->>'people_total' from flujo),
         (select sum((t->>'people')::integer)::text from flujo, jsonb_array_elements(flujo.j->'weeks'->-1->'transitions') t),
         (select (flujo.j->'weeks'->-1->>'people_total')::integer from flujo)
           = (select sum((t->>'people')::integer) from flujo, jsonb_array_elements(flujo.j->'weeks'->-1->'transitions') t)
  union all
  select '14', 'C14 Semana pasada: el paso acaba donde empieza el de esta (lunes)',
         (select flujop.j->'weeks'->-1->>'cut_date' from flujop),
         (select flujo.j->'weeks'->-1->>'from_date' from flujo),
         (select flujop.j->'weeks'->-1->>'cut_date' from flujop) = (select flujo.j->'weeks'->-1->>'from_date' from flujo)
  -- ── Los deudores ───────────────────────────────────────────────────────
  union all
  select '15', 'C15 Deudores en mora = personas con algo vencido',
         (select j->'cartera'->>'personas_vencidas' from sem),
         (select j->'en_mora'->>'personas' from deud),
         (select (j->'cartera'->>'personas_vencidas')::integer from sem) = (select (j->'en_mora'->>'personas')::integer from deud)
  union all
  select '16', 'C16 Lo que deben vencido = vencido de la cartera',
         round((select (j->'cartera'->'vencido'->>'payable_usd')::numeric from sem), 2)::text,
         round((select (j->'en_mora'->'vencido'->>'payable_usd')::numeric from deud), 2)::text,
         abs((select (j->'cartera'->'vencido'->>'payable_usd')::numeric from sem)
             - (select (j->'en_mora'->'vencido'->>'payable_usd')::numeric from deud)) < 0.01
  union all
  select '17', 'C17 Σ perfiles de mora (personas) = deudores en mora',
         (select j->'en_mora'->>'personas' from deud),
         (select sum((p->>'personas')::integer)::text from deud, jsonb_array_elements(deud.j->'perfiles') p
           where p->>'perfil' <> 'vigilar'),
         (select (j->'en_mora'->>'personas')::integer from deud)
           = (select sum((p->>'personas')::integer) from deud, jsonb_array_elements(deud.j->'perfiles') p
               where p->>'perfil' <> 'vigilar')
  union all
  select '18', 'C18 La lista tiene a todos los de las tarjetas',
         (select sum((p->>'personas')::integer)::text from deud, jsonb_array_elements(deud.j->'perfiles') p),
         (select jsonb_array_length(j->'personas')::text from deud),
         (select sum((p->>'personas')::integer) from deud, jsonb_array_elements(deud.j->'perfiles') p)
           = (select jsonb_array_length(j->'personas') from deud)
  union all
  select '19', 'C19 Por cobrar: cada deudor está en la cola con el mismo perfil y orden',
         (select jsonb_array_length(j->'personas')::text from deud),
         (select count(*)::text from deud, jsonb_array_elements(deud.j->'personas') p
            join lateral (select f from cola, jsonb_array_elements(cola.j->'rows') f
                          where f->>'user_id' = p->>'user_id') c on true
           where c.f->>'perfil' = p->>'perfil' and c.f->>'orden' = p->>'orden'),
         (select jsonb_array_length(j->'personas') from deud)
           = (select count(*) from deud, jsonb_array_elements(deud.j->'personas') p
                join lateral (select f from cola, jsonb_array_elements(cola.j->'rows') f
                              where f->>'user_id' = p->>'user_id') c on true
               where c.f->>'perfil' = p->>'perfil' and c.f->>'orden' = p->>'orden')
  union all
  select '20', 'C20 Por cobrar: nadie tiene perfil fuera de los deudores',
         (select jsonb_array_length(j->'personas')::text from deud),
         (select count(*)::text from cola, jsonb_array_elements(cola.j->'rows') f where f->>'perfil' is not null),
         (select jsonb_array_length(j->'personas') from deud)
           = (select count(*) from cola, jsonb_array_elements(cola.j->'rows') f where f->>'perfil' is not null)
  -- ── Lo que vencía y entró ──────────────────────────────────────────────
  union all
  select '21', 'C21 Vencía en la semana = Σ cuotas que vencen en ella (sin lo perdido)',
         round((select coalesce(sum(payable_usd), 0) from mq, h
                 where due_date between h.lunes and h.domingo and estado_hoy <> 'perdida'), 2)::text,
         round((select sum(due_usd) from dias), 2)::text,
         abs((select coalesce(sum(payable_usd), 0) from mq, h
               where due_date between h.lunes and h.domingo and estado_hoy <> 'perdida')
             - (select sum(due_usd) from dias)) < 0.01
  union all
  select '22', 'C22 De eso entró = Σ de esas cuotas ya pagadas',
         round((select coalesce(sum(payable_usd), 0) from mq, h
                 where due_date between h.lunes and h.domingo and estado_hoy <> 'perdida' and status = 'paid'), 2)::text,
         round((select sum(due_paid_usd) from dias), 2)::text,
         abs((select coalesce(sum(payable_usd), 0) from mq, h
               where due_date between h.lunes and h.domingo and estado_hoy <> 'perdida' and status = 'paid')
             - (select sum(due_paid_usd) from dias)) < 0.01
  union all
  select '23', 'C23 Vencía = consumo + servicio e IVA, día a día',
         '0', (select count(*)::text from dias where abs(due_usd - due_financed_usd - due_fee_usd) >= 0.01),
         not exists (select 1 from dias where abs(due_usd - due_financed_usd - due_fee_usd) >= 0.01)
  -- ── Cobro a tiempo y primera cuota ─────────────────────────────────────
  union all
  select '24', 'C24 Cobro a tiempo de la semana pasada = metricas.cuotas con el plazo cerrado',
         (select format('%s de %s', count(*) filter (where q.estado_hoy = 'a_tiempo'), count(*))
            from mq q, ont where q.plazo_cerrado and q.due_date between (ont.j->>'from')::date and (ont.j->>'to')::date),
         (select format('%s de %s', j->'total'->>'on_time_count', j->'total'->>'due_count') from ont),
         (select format('%s de %s', count(*) filter (where q.estado_hoy = 'a_tiempo'), count(*))
            from mq q, ont where q.plazo_cerrado and q.due_date between (ont.j->>'from')::date and (ont.j->>'to')::date)
           = (select format('%s de %s', j->'total'->>'on_time_count', j->'total'->>'due_count') from ont)
  union all
  select '25', 'C25 Cobro a tiempo: el total = cuota 1 + cuota 2',
         (select j->'total'->>'due_count' from ont),
         (select sum((c->>'due_count')::integer)::text from ont, jsonb_each(ont.j->'installments') e(k, c)),
         (select (j->'total'->>'due_count')::integer from ont)
           = coalesce((select sum((c->>'due_count')::integer) from ont, jsonb_each(ont.j->'installments') e(k, c)), 0)
  union all
  select '26', 'C26 Primera cuota: por semana y por mes juzgan las mismas cuotas',
         (select j->'total'->>'matured_count' from fpdm),
         (select j->'total'->>'matured_count' from fpds),
         (select j->'total' from fpdm) = (select j->'total' from fpds)
  union all
  select '27', 'C27 Primera cuota por semana: Σ semanas = total',
         (select j->'total'->>'defaulted_count' from fpds),
         (select sum((r->>'defaulted_count')::integer)::text from fpds, jsonb_array_elements(fpds.j->'rows') r),
         (select (j->'total'->>'defaulted_count')::integer from fpds)
           = (select sum((r->>'defaulted_count')::integer) from fpds, jsonb_array_elements(fpds.j->'rows') r)
  -- ── Impago ─────────────────────────────────────────────────────────────
  union all
  select '28', 'C28 Impago = admin_overview.bad_debt (tasa y punto de empate)',
         (select format('%s · %s', j->'bad_debt'->>'rate_financed_pct', j->'bad_debt'->>'break_even_pct') from ov),
         (select format('%s · %s', j->'impago'->>'impago_pct', j->'impago'->>'empate_pct') from sem),
         (select format('%s · %s', j->'bad_debt'->>'rate_financed_pct', j->'bad_debt'->>'break_even_pct') from ov)
           = (select format('%s · %s', j->'impago'->>'impago_pct', j->'impago'->>'empate_pct') from sem)
  -- ── Recuperado ─────────────────────────────────────────────────────────
  union all
  select '29', 'C29 Recuperado la semana pasada = cuotas aprobadas en ella que ya estaban vencidas',
         round((select coalesce(sum(payable_usd), 0) from mq, h
                 where status = 'paid' and pagada_dia between h.lunes_ant and h.domingo_ant
                   and pagada_dia > due_date), 2)::text,
         round((select (j->'recovered'->>'usd')::numeric from rec), 2)::text,
         abs((select coalesce(sum(payable_usd), 0) from mq, h
               where status = 'paid' and pagada_dia between h.lunes_ant and h.domingo_ant and pagada_dia > due_date)
             - (select (j->'recovered'->>'usd')::numeric from rec)) < 0.01
  union all
  select '30', 'C30 Recuperado = consumo + servicio e IVA',
         round((select (j->'recovered'->>'usd')::numeric from rec), 2)::text,
         round((select (j->'recovered'->>'financed_usd')::numeric + (j->'recovered'->>'fee_usd')::numeric from rec), 2)::text,
         abs((select (j->'recovered'->>'usd')::numeric - (j->'recovered'->>'financed_usd')::numeric
                     - (j->'recovered'->>'fee_usd')::numeric from rec)) < 0.01
  -- ── Por local: los locales suman el total ──────────────────────────────
  union all
  select '31', 'C31 Σ locales: vencido de hoy = total',
         round((select (j->'cartera'->'vencido'->>'payable_usd')::numeric from sem), 2)::text,
         round((select sum((sem->'cartera'->'vencido'->>'payable_usd')::numeric) from por_local), 2)::text,
         abs((select (j->'cartera'->'vencido'->>'payable_usd')::numeric from sem)
             - (select sum((sem->'cartera'->'vencido'->>'payable_usd')::numeric) from por_local)) < 0.01
  union all
  select '32', 'C32 Σ locales: lo que deben los deudores = total',
         round((select (j->'en_mora'->'vencido'->>'payable_usd')::numeric from deud), 2)::text,
         round((select sum((deud->'en_mora'->'vencido'->>'payable_usd')::numeric) from por_local), 2)::text,
         abs((select (j->'en_mora'->'vencido'->>'payable_usd')::numeric from deud)
             - (select sum((deud->'en_mora'->'vencido'->>'payable_usd')::numeric) from por_local)) < 0.01
  union all
  select '33', 'C33 Σ locales: recuperado la semana pasada = total',
         round((select (j->'recovered'->>'usd')::numeric from rec), 2)::text,
         round((select sum((rec->'recovered'->>'usd')::numeric) from por_local), 2)::text,
         abs((select (j->'recovered'->>'usd')::numeric from rec)
             - (select sum((rec->'recovered'->>'usd')::numeric) from por_local)) < 0.01
  union all
  select '34', 'C34 Σ locales: lo que vencía esta semana = total',
         round((select sum(due_usd) from dias), 2)::text,
         round((select sum(vence) from por_local), 2)::text,
         abs((select sum(due_usd) from dias) - (select sum(vence) from por_local)) < 0.01
  union all
  select '35', 'C35 Riesgo por local: con p_merchant_id sale su misma fila',
         (select count(*)::text from locales),
         (select count(*)::text from por_local p
            where (p.riesgo->0) = (select to_jsonb(x) from public.admin_merchant_risk(90) x where x.merchant_id = p.id)),
         (select count(*) from locales)
           = (select count(*) from por_local p
               where (p.riesgo->0) = (select to_jsonb(x) from public.admin_merchant_risk(90) x where x.merchant_id = p.id))
  -- ── El impago de cada cuota: la 2 tiene lo mismo que la 1 ──────────────
  union all
  select '36', 'C36 Impago por cuota: sin p_cuota es la cuota 1, como la llama Inicio',
         (select format('cuota %s · %s', j->>'cuota', j->'total'->>'defaulted_count') from fpd1),
         (select format('cuota %s · %s', j->>'cuota', j->'total'->>'defaulted_count') from fpdm),
         (select j from fpd1) = (select j from fpdm) and (select j->>'cuota' from fpdm) = '1'
  union all
  select '37', 'C37 Cuota 1: maduras e impagadas tras la gracia = metricas.cuotas',
         (select format('%s de %s', impagas, maduras) from fpd_mano where cuota = 1),
         (select format('%s de %s', j->'total'->>'defaulted_count', j->'total'->>'matured_count') from fpd1),
         (select format('%s de %s', impagas, maduras) from fpd_mano where cuota = 1)
           = (select format('%s de %s', j->'total'->>'defaulted_count', j->'total'->>'matured_count') from fpd1)
  union all
  select '38', 'C38 Cuota 2: maduras e impagadas tras la gracia = metricas.cuotas',
         (select format('%s de %s', impagas, maduras) from fpd_mano where cuota = 2),
         (select format('%s de %s', j->'total'->>'defaulted_count', j->'total'->>'matured_count') from fpd2m),
         (select format('%s de %s', impagas, maduras) from fpd_mano where cuota = 2)
           = (select format('%s de %s', j->'total'->>'defaulted_count', j->'total'->>'matured_count') from fpd2m)
  union all
  select '39', 'C39 Cuota 2: por semana y por mes juzgan las mismas cuotas',
         (select j->'total'->>'matured_count' from fpd2m),
         (select j->'total'->>'matured_count' from fpd2s),
         (select j->'total' from fpd2m) = (select j->'total' from fpd2s) and (select j->>'cuota' from fpd2s) = '2'
  union all
  select '40', 'C40 Cuota 2 por semana: Σ semanas = total',
         (select j->'total'->>'defaulted_count' from fpd2s),
         (select coalesce(sum((r->>'defaulted_count')::integer), 0)::text from fpd2s, jsonb_array_elements(fpd2s.j->'rows') r),
         (select (j->'total'->>'defaulted_count')::integer from fpd2s)
           = (select coalesce(sum((r->>'defaulted_count')::integer), 0) from fpd2s, jsonb_array_elements(fpd2s.j->'rows') r)
  union all
  select '41', 'C41 Cuota 2: Σ locales = total (maduras e impagadas)',
         (select format('%s de %s', j->'total'->>'defaulted_count', j->'total'->>'matured_count') from fpd2m),
         (select format('%s de %s', sum((fpd2->'total'->>'defaulted_count')::integer),
                        sum((fpd2->'total'->>'matured_count')::integer)) from por_local),
         (select format('%s de %s', j->'total'->>'defaulted_count', j->'total'->>'matured_count') from fpd2m)
           = (select format('%s de %s', sum((fpd2->'total'->>'defaulted_count')::integer),
                            sum((fpd2->'total'->>'matured_count')::integer)) from por_local)
  -- ── La cola de Por cobrar lleva su desglose ────────────────────────────
  union all
  select '42', 'C42 Por cobrar: el consumo de la deuda vencida = Σ financed de las cuotas pendientes vencidas',
         round((select coalesce(sum(i.financed_usd), 0) from public.installments i, h
                 where i.status = 'pending' and not i.is_test and i.due_date < h.hoy), 2)::text,
         round((select sum((f->>'overdue_financed_usd')::numeric) from cola, jsonb_array_elements(cola.j->'rows') f), 2)::text,
         abs((select coalesce(sum(i.financed_usd), 0) from public.installments i, h
               where i.status = 'pending' and not i.is_test and i.due_date < h.hoy)
             - (select sum((f->>'overdue_financed_usd')::numeric) from cola, jsonb_array_elements(cola.j->'rows') f)) < 0.01
  union all
  select '43', 'C43 Por cobrar: en cada fila, consumo + fee = deuda (vencida y por vencer) y el fee nunca es negativo',
         '0',
         (select count(*)::text from cola, jsonb_array_elements(cola.j->'rows') f
           where abs((f->>'overdue_usd')::numeric - (f->>'overdue_financed_usd')::numeric - (f->>'overdue_fee_usd')::numeric) >= 0.005
              or abs((f->>'upcoming_usd')::numeric - (f->>'upcoming_financed_usd')::numeric - (f->>'upcoming_fee_usd')::numeric) >= 0.005
              or (f->>'overdue_fee_usd')::numeric < 0 or (f->>'upcoming_fee_usd')::numeric < 0),
         not exists (select 1 from cola, jsonb_array_elements(cola.j->'rows') f
           where abs((f->>'overdue_usd')::numeric - (f->>'overdue_financed_usd')::numeric - (f->>'overdue_fee_usd')::numeric) >= 0.005
              or abs((f->>'upcoming_usd')::numeric - (f->>'upcoming_financed_usd')::numeric - (f->>'upcoming_fee_usd')::numeric) >= 0.005
              or (f->>'overdue_fee_usd')::numeric < 0 or (f->>'upcoming_fee_usd')::numeric < 0)
  -- ── De quien pagó la cuota 1, qué parte no paga la 2 (MORA-INICIO) ──────
  union all
  select '44', 'C44 Cuota 1: previous_paid es null (no hay cuota anterior), en el total y en cada fila',
         'null',
         (select coalesce(j->'total'->'previous_paid', 'null'::jsonb)::text from fpd1),
         (select j->'total'->'previous_paid' = 'null'::jsonb from fpd1)
           and not exists (select 1 from fpds, jsonb_array_elements(fpds.j->'rows') r
                            where r->'previous_paid' <> 'null'::jsonb)
  union all
  select '45', 'C45 Cuota 2 de quien pagó la 1: maduras y sin pagar = metricas.cuotas',
         (select format('%s de %s', impagas, maduras) from fpd2_tras_1_mano),
         (select format('%s de %s', j->'total'->'previous_paid'->>'defaulted_count',
                        j->'total'->'previous_paid'->>'matured_count') from fpd2m),
         (select format('%s de %s', impagas, maduras) from fpd2_tras_1_mano)
           = (select format('%s de %s', j->'total'->'previous_paid'->>'defaulted_count',
                            j->'total'->'previous_paid'->>'matured_count') from fpd2m)
  union all
  select '46', 'C46 Cuota 2 de quien pagó la 1: es una parte de la cuota 2 (maduras, sin pagar y consumo)',
         (select format('%s de %s', j->'total'->>'defaulted_count', j->'total'->>'matured_count') from fpd2m),
         (select format('%s de %s', j->'total'->'previous_paid'->>'defaulted_count',
                        j->'total'->'previous_paid'->>'matured_count') from fpd2m),
         (select (j->'total'->'previous_paid'->>'matured_count')::integer <= (j->'total'->>'matured_count')::integer
             and (j->'total'->'previous_paid'->>'defaulted_count')::integer <= (j->'total'->>'defaulted_count')::integer
             and (j->'total'->'previous_paid'->>'defaulted_financed_usd')::numeric <= (j->'total'->>'defaulted_financed_usd')::numeric
             and (j->'total'->'previous_paid'->>'matured_30_count')::integer <= (j->'total'->>'matured_30_count')::integer
            from fpd2m)
  union all
  select '47', 'C47 Cuota 2 de quien pagó la 1 por semana: Σ semanas = total',
         (select format('%s de %s', j->'total'->'previous_paid'->>'defaulted_count',
                        j->'total'->'previous_paid'->>'matured_count') from fpd2s),
         (select format('%s de %s', coalesce(sum((r->'previous_paid'->>'defaulted_count')::integer), 0),
                        coalesce(sum((r->'previous_paid'->>'matured_count')::integer), 0))
            from fpd2s, jsonb_array_elements(fpd2s.j->'rows') r),
         (select format('%s de %s', j->'total'->'previous_paid'->>'defaulted_count',
                        j->'total'->'previous_paid'->>'matured_count') from fpd2s)
           = (select format('%s de %s', coalesce(sum((r->'previous_paid'->>'defaulted_count')::integer), 0),
                            coalesce(sum((r->'previous_paid'->>'matured_count')::integer), 0))
                from fpd2s, jsonb_array_elements(fpd2s.j->'rows') r)
  union all
  select '48', 'C48 Cuota 2 de quien pagó la 1: Σ locales = total',
         (select format('%s de %s', j->'total'->'previous_paid'->>'defaulted_count',
                        j->'total'->'previous_paid'->>'matured_count') from fpd2m),
         (select format('%s de %s', sum((fpd2->'total'->'previous_paid'->>'defaulted_count')::integer),
                        sum((fpd2->'total'->'previous_paid'->>'matured_count')::integer)) from por_local),
         (select format('%s de %s', j->'total'->'previous_paid'->>'defaulted_count',
                        j->'total'->'previous_paid'->>'matured_count') from fpd2m)
           = (select format('%s de %s', sum((fpd2->'total'->'previous_paid'->>'defaulted_count')::integer),
                            sum((fpd2->'total'->'previous_paid'->>'matured_count')::integer)) from por_local)
  -- ── Una sola gracia (MORA-INICIO) ───────────────────────────────────────
  union all
  select '49', 'C49 Una sola gracia: «a tiempo», el cargo por atraso y el impago usan los mismos días',
         (select public.helios_late_fee_grace_days()::text),
         (select format('a tiempo %s · impago %s', public.helios_on_time_grace_days(), j->>'grace_days') from fpd1),
         (select public.helios_on_time_grace_days() = public.helios_late_fee_grace_days()
             and (j->>'grace_days')::integer = public.helios_late_fee_grace_days() from fpd1)
  union all
  select '50', 'C50 Cuota 1: pagadas a tiempo + sin pagar tras la gracia = maduras',
         (select maduras::text from una_gracia),
         (select format('%s a tiempo + %s sin pagar', g.a_tiempo, j->'total'->>'defaulted_count') from una_gracia g, fpd1),
         (select g.a_tiempo + (j->'total'->>'defaulted_count')::integer = g.maduras
             and g.maduras = (j->'total'->>'matured_count')::integer from una_gracia g, fpd1)
  -- ── Inicio › Deuda vencida lleva su desglose (MORA-INICIO) ──────────────
  union all
  select '51', 'C51 Inicio › Deuda vencida: consumo + fee = deuda, la vencida y la viva',
         (select format('%s = %s + %s', j->>'overdue_debt_usd', j->>'overdue_financed_usd', j->>'overdue_fee_usd') from ws),
         (select format('%s = %s + %s', j->>'open_debt_usd', j->>'open_financed_usd', j->>'open_fee_usd') from ws),
         (select abs((j->>'overdue_debt_usd')::numeric - (j->>'overdue_financed_usd')::numeric - (j->>'overdue_fee_usd')::numeric) < 0.005
             and abs((j->>'open_debt_usd')::numeric - (j->>'open_financed_usd')::numeric - (j->>'open_fee_usd')::numeric) < 0.005
             and (j->>'overdue_fee_usd')::numeric >= 0 and (j->>'open_fee_usd')::numeric >= 0
            from ws)
  union all
  select '52', 'C52 Inicio › Deuda vencida: el consumo vencido = Σ financed de las cuotas vencidas (metricas.cuotas)',
         round((select coalesce(sum(financed_usd), 0) from mq where estado_hoy = 'vencida'), 2)::text,
         round((select (j->>'overdue_financed_usd')::numeric from ws), 2)::text,
         abs((select coalesce(sum(financed_usd), 0) from mq where estado_hoy = 'vencida')
             - (select (j->>'overdue_financed_usd')::numeric from ws)) < 0.01
)
select comprobacion, esperado, obtenido, ok
from r
order by orden;
