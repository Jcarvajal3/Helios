-- ============================================================================
-- Batería de rigor de Caja, Locales y Gente (AUD-CAJA-LOCALES-GENTE, dev)
--
-- Cada cifra que pintan Métricas › Caja (Balance y Proyección), › Locales
-- (tabla, pequeños múltiplos, cuota 1 a tiempo por local, ficha del local) y
-- › Gente (Resumen, Uso, Grupos, Retención y Perfil), recalculada A MANO desde
-- las tablas (installments, charges, late_fees, merchant_payouts, settlements,
-- ledger, groups, profiles, kyc), sin pasar por las vistas de `metricas`, y
-- comparada con lo que devuelve la RPC que la pinta. Se mira la semana en
-- curso, la anterior (cerrada) y cada local.
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok. Las que
-- recorren locales o semanas dan «N de M». Solo SELECT; se hace pasar por un
-- admin activo.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_aud_clg.sql
-- ============================================================================

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

with
h as (
  select metricas.hoy() as hoy,
         metricas.lunes(metricas.hoy()) as lunes,
         metricas.lunes(metricas.hoy()) - 7 as cerrada,
         public.helios_on_time_grace_days() as gracia
),
semanas as (
  select h.lunes as lunes, least(h.lunes + 6, h.hoy) as hasta, 'en curso' as cual from h
  union all
  select h.cerrada, h.cerrada + 6, 'cerrada' from h
),
locales as (
  select m.id, m.name from public.merchants m
  where not m.is_test and exists (select 1 from public.charges c where c.merchant_id = m.id and c.status = 'confirmed' and not c.is_test)
),

-- ── La base, desde las tablas ───────────────────────────────────────────────
b as (
  select i.id, i.user_id, i.charge_id, i.sequence, i.due_date, i.status, i.paid_at, i.written_off_at,
         i.amount_usd::numeric as pay, i.financed_usd::numeric as fin,
         c.merchant_id, c.business_date as bd, c.group_id, c.created_at as abierto,
         coalesce(public.helios_business_date(pr.created_at), public.helios_business_date(i.paid_at)) as dia_pago
  from public.installments i
  join public.charges c on c.id = i.charge_id
  left join public.payment_reports pr on pr.id = i.paid_by_report_id
  where c.status = 'confirmed' and not c.is_test and not i.is_test and c.business_date is not null
),
k as (
  select c.id, c.merchant_id, c.business_date as bd, c.group_id, coalesce(c.consumer_fee_usd, 0)::numeric as serv
  from public.charges c
  where c.status = 'confirmed' and not c.is_test and c.business_date is not null
),
cargos as (
  select lf.amount_usd::numeric as usd, lf.status::text as st, lf.business_date as bd,
         public.helios_business_date(lf.paid_at) as pagado, c.merchant_id
  from public.late_fees lf
  join public.profiles p on p.id = lf.user_id and not p.is_test
  left join public.installments i on i.id = lf.installment_id
  left join public.charges c on c.id = i.charge_id
  where lf.waived_at is null
),
libro as (
  select t.business_date as bd, e.debit, e.credit
  from ledger.entries e
  join ledger.accounts a on a.id = e.account_id and a.account_type = 'cash'
  join ledger.transactions t on t.id = e.transaction_id
  where e.transaction_id not in (
    select e2.transaction_id from ledger.entries e2 join ledger.accounts a2 on a2.id = e2.account_id
    where a2.owner_id in (select id from public.profiles where is_test union all select id from public.merchants where is_test))
),
-- Registros: la primera aprobación de la verificación de identidad.
reg as (
  select p.id as user_id, p.status::text as estado,
         public.helios_business_date(p.created_at) as pidio,
         public.helios_business_date(ap.en) as dia
  from public.profiles p
  left join (
    select v.user_id, min(coalesce(l.en, v.reviewed_at, v.created_at)) as en
    from kyc.verifications v
    left join (select d.verification_id, min(d.created_at) as en from kyc.decision_log d
               where d.to_status = 'approved' group by 1) l on l.verification_id = v.id
    where v.status = 'approved'
    group by v.user_id
  ) ap on ap.user_id = p.id
  where not p.is_test
),
primera as (select user_id, min(bd) as dia from b group by 1),
primera_local as (select user_id, merchant_id, min(bd) as dia from b group by 1, 2),

-- ── Caja ────────────────────────────────────────────────────────────────────
caja_sem as (
  select s.cual, s.lunes, s.hasta, l.id as loc,
         public.admin_metricas_caja(s.lunes, l.id) as j
  from semanas s
  cross join (select null::uuid as id union all select id from locales) l
),
caja_esp as (
  select cs.cual, cs.loc,
    (select round(coalesce(sum(b.pay), 0), 2) from b
      where b.status = 'paid' and public.helios_business_date(b.paid_at) between cs.lunes and cs.hasta
        and (cs.loc is null or b.merchant_id = cs.loc)) as cobrado,
    (select round(coalesce(sum(b.fin), 0), 2) from b
      where b.status = 'paid' and public.helios_business_date(b.paid_at) between cs.lunes and cs.hasta
        and (cs.loc is null or b.merchant_id = cs.loc)) as cobrado_fin,
    (select round(coalesce(sum(c.usd), 0), 2) from cargos c
      where c.st = 'paid' and c.pagado between cs.lunes and cs.hasta and (cs.loc is null or c.merchant_id = cs.loc)) as cargos,
    (select round(coalesce(sum(mp.amount_usd), 0), 2) from public.merchant_payouts mp
      join public.merchants m on m.id = mp.merchant_id and not m.is_test
      where mp.business_date between cs.lunes and cs.hasta and (cs.loc is null or mp.merchant_id = cs.loc)) as transferido,
    (select round(coalesce(sum(k.serv), 0), 2) from k
      where k.bd between cs.lunes and cs.hasta and (cs.loc is null or k.merchant_id = cs.loc)) as serv,
    (select round(coalesce(sum(b.fin), 0), 2) from b
      where b.bd between cs.lunes and cs.hasta and (cs.loc is null or b.merchant_id = cs.loc)) as facturado,
    (select round(coalesce(sum(debit) - sum(credit), 0), 2) from libro where bd <= cs.hasta) as caja
  from caja_sem cs
),
caja_cmp as (
  select cs.cual, cs.loc,
    e.cobrado = round((cs.j->'movimientos'->'cobrado'->>'payable_usd')::numeric, 2)
      and e.cobrado_fin = round((cs.j->'movimientos'->'cobrado'->>'financed_usd')::numeric, 2) as cobrado_ok,
    e.cargos = round((cs.j->'movimientos'->'cargos_cobrados'->>'usd')::numeric, 2) as cargos_ok,
    e.transferido = round((cs.j->'movimientos'->'transferido'->>'usd')::numeric, 2) as transf_ok,
    e.serv = round((cs.j->'movimientos'->>'servicio_ganado_usd')::numeric, 2) as serv_ok,
    e.facturado = round((cs.j->'movimientos'->'consumo'->>'financed_usd')::numeric, 2) as fact_ok,
    (cs.loc is not null and cs.j->'caja' = 'null'::jsonb)
      or (cs.loc is null and e.caja = round((cs.j->'caja'->>'al_cierre_usd')::numeric, 2)) as caja_ok
  from caja_sem cs
  join caja_esp e on e.cual = cs.cual and e.loc is not distinct from cs.loc
),
foto as (select public.admin_cash_position(null) as j),
foto_esp as (
  select
    (select round(sum(b.pay), 2) from b where b.status = 'pending' and b.written_off_at is null) as vivo_pay,
    (select round(sum(b.fin), 2) from b where b.status = 'pending' and b.written_off_at is null) as vivo_fin,
    (select round(coalesce(sum(b.fin), 0), 2) from b where b.status = 'pending' and b.written_off_at is not null) as perdido_fin,
    (select round(coalesce(sum(c.usd), 0), 2) from cargos c where c.st = 'pending') as cargos_pend,
    (select round(sum(k.serv), 2) from k) as serv_total
),
por_pagar as (
  select
    (select round((public.admin_metricas_caja(null, null)->'por_pagar_locales'->>'total_usd')::numeric, 2)) as balance,
    (select round(coalesce(sum((x->>'total_pending_usd')::numeric), 0), 2)
       from jsonb_array_elements(public.admin_merchant_payables(null)) x
      where not (x->>'is_test')::boolean) as semaforo
),
proy as (select public.admin_cash_forecast(4, null) as j),
proy_filas as (
  select (r->>'week_start')::date as w, round((r->>'expected_gross_usd')::numeric, 2) as vence
  from proy, jsonb_array_elements(proy.j->'rows') r
),
proy_esp as (
  select f.w, f.vence,
    (select round(coalesce(sum(b.pay), 0), 2) from b, h
      where b.status = 'pending' and b.written_off_at is null
        and b.due_date between greatest(f.w, h.hoy) and f.w + 6 and b.due_date <= h.hoy + 28) as ind
  from proy_filas f
),
factor as (
  select round(count(*) filter (where b.due_date + h.gracia < h.hoy and b.status = 'paid' and b.dia_pago <= b.due_date + h.gracia)::numeric
               / nullif(count(*) filter (where b.due_date + h.gracia < h.hoy), 0), 4) as canon
  from b, h
  where b.due_date between h.hoy - 90 and h.hoy
    -- lo perdido con el plazo cerrado también se juzga (no se pagó a tiempo)
),

-- ── Locales ─────────────────────────────────────────────────────────────────
loc_sem as (
  select s.cual, s.lunes, s.hasta, public.admin_metricas_locales(s.lunes, null) as j from semanas s
),
loc_filas as (
  select ls.cual, ls.lunes, ls.hasta, f as fila
  from loc_sem ls, jsonb_array_elements(ls.j->'locales' || jsonb_build_array(ls.j->'totales')) f
),
loc_cmp as (
  select lf.cual, lf.fila->>'nombre' as nombre,
    round((lf.fila->>'consumo_usd')::numeric, 2) =
      (select round(coalesce(sum(b.fin), 0), 2) from b
        where b.bd between lf.lunes and lf.hasta and (lf.fila->>'merchant_id' is null or b.merchant_id = (lf.fila->>'merchant_id')::uuid))
    and (lf.fila->>'consumos')::int =
      (select count(distinct b.charge_id) from b
        where b.bd between lf.lunes and lf.hasta and (lf.fila->>'merchant_id' is null or b.merchant_id = (lf.fila->>'merchant_id')::uuid))
    and (lf.fila->>'personas')::int =
      (select count(distinct b.user_id) from b
        where b.bd between lf.lunes and lf.hasta and (lf.fila->>'merchant_id' is null or b.merchant_id = (lf.fila->>'merchant_id')::uuid))
    and (lf.fila->>'nuevas')::int =
      (select count(distinct pl.user_id) from primera_local pl
        where metricas.lunes(pl.dia) = lf.lunes and (lf.fila->>'merchant_id' is null or pl.merchant_id = (lf.fila->>'merchant_id')::uuid))
    as ok_venta,
    (lf.fila->'a_tiempo'->>'juzgadas')::int =
      (select count(*) from b, h where b.due_date between lf.lunes and lf.lunes + 6 and b.due_date + h.gracia < h.hoy
        and (lf.fila->>'merchant_id' is null or b.merchant_id = (lf.fila->>'merchant_id')::uuid))
    and (lf.fila->'a_tiempo'->>'a_tiempo')::int =
      (select count(*) from b, h where b.due_date between lf.lunes and lf.lunes + 6 and b.due_date + h.gracia < h.hoy
        and b.status = 'paid' and b.dia_pago <= b.due_date + h.gracia
        and (lf.fila->>'merchant_id' is null or b.merchant_id = (lf.fila->>'merchant_id')::uuid))
    as ok_a_tiempo,
    round((lf.fila->'vencido'->>'payable_usd')::numeric, 2) =
      (select round(coalesce(sum(b.pay), 0), 2) from b, h
        where (lf.fila->>'merchant_id' is null or b.merchant_id = (lf.fila->>'merchant_id')::uuid)
          and b.bd <= lf.lunes + 6
          and b.due_date < least(lf.lunes + 7, h.hoy)
          and not (b.status = 'paid' and b.paid_at <= case when lf.lunes + 6 < h.hoy then public.helios_business_day_end(lf.lunes + 6) else now() end)
          and not (b.written_off_at is not null and b.written_off_at <= case when lf.lunes + 6 < h.hoy then public.helios_business_day_end(lf.lunes + 6) else now() end))
    as ok_vencido
  from loc_filas lf
),
serie as (
  select (sem.s)::date as semana, (l->>'merchant_id')::uuid as mid, (l->'consumo_usd'->>(sem.i - 1)::int)::numeric as consumo
  from loc_sem ls,
       jsonb_array_elements(ls.j->'series'->'locales') l,
       jsonb_array_elements_text(ls.j->'series'->'semanas') with ordinality sem(s, i)
  where ls.cual = 'en curso'
),
serie_cmp as (
  select s.semana, s.mid,
    round(s.consumo, 2) = (select round(coalesce(sum(b.fin), 0), 2) from b, h
                           where b.merchant_id = s.mid and metricas.lunes(b.bd) = s.semana and b.bd <= h.hoy) as ok
  from serie s
),
coh as (
  select (w->>'semana')::date as semana, (l->>'merchant_id')::uuid as mid, w->'cuota_1' as c1
  from loc_sem ls,
       jsonb_array_elements(ls.j->'cohortes'->'locales') l,
       jsonb_array_elements(l->'semanas') w
  where ls.cual = 'en curso'
),
coh_cmp as (
  select c.semana, c.mid,
    coalesce((c.c1->>'juzgadas')::int, 0) =
      (select count(*) from b, h where b.merchant_id = c.mid and metricas.lunes(b.bd) = c.semana and b.sequence = 1
         and b.due_date + h.gracia < h.hoy)
    and coalesce((c.c1->>'a_tiempo_juzgadas')::int, 0) =
      (select count(*) from b, h where b.merchant_id = c.mid and metricas.lunes(b.bd) = c.semana and b.sequence = 1
         and b.due_date + h.gracia < h.hoy and b.status = 'paid' and b.dia_pago <= b.due_date + h.gracia) as ok
  from coh c
),
noches as (
  select l.id as mid, n.* from locales l, h
  cross join lateral public.admin_nights(14, l.id, h.lunes) n
),
noches_cmp as (
  select n.mid, n.business_date,
    n.charge_count = (select count(distinct b.charge_id) from b where b.merchant_id = n.mid and b.bd = n.business_date)
    and round(n.financed_usd, 2) = (select round(sum(b.fin), 2) from b where b.merchant_id = n.mid and b.bd = n.business_date)
    and n.distinct_users = (select count(distinct b.user_id) from b where b.merchant_id = n.mid and b.bd = n.business_date)
    and n.new_users = (select count(*) from primera_local pl where pl.merchant_id = n.mid and pl.dia = n.business_date) as ok
  from noches n
),
cartera as (
  select l.id as mid, public.admin_merchant_stats(l.id, 30, h.lunes)->'portfolio' as p from locales l, h
),
cartera_cmp as (
  select c.mid,
    round((c.p->>'open_usd')::numeric, 2) =
      (select round(coalesce(sum(b.pay), 0), 2) from b where b.merchant_id = c.mid and b.status = 'pending' and b.written_off_at is null)
    and round((c.p->>'overdue_usd')::numeric, 2) =
      (select round(coalesce(sum(b.pay), 0), 2) from b, h where b.merchant_id = c.mid and b.status = 'pending' and b.written_off_at is null and b.due_date < h.hoy)
    and (c.p->>'due_count')::int =
      (select count(*) from b, h where b.merchant_id = c.mid and b.due_date + h.gracia < h.hoy)
    and (c.p->>'on_time_count')::int =
      (select count(*) from b, h where b.merchant_id = c.mid and b.due_date + h.gracia < h.hoy and b.status = 'paid' and b.dia_pago <= b.due_date + h.gracia)
    as ok
  from cartera c
),

-- ── Gente ───────────────────────────────────────────────────────────────────
gente_sem as (
  select s.cual, s.lunes, s.hasta, l.id as loc,
         public.admin_growth_overview(s.lunes, s.hasta, l.id) as o,
         public.admin_user_behavior(s.lunes, s.hasta, l.id) as u,
         public.admin_group_metrics(s.lunes, s.hasta, l.id) as g
  from semanas s cross join (select null::uuid as id union all select id from locales) l
),
gente_cmp as (
  select gs.cual, gs.loc,
    ((gs.loc is not null and gs.o->'requested' = 'null'::jsonb and gs.o->'registered' = 'null'::jsonb)
     or (gs.loc is null
         and (gs.o->'requested'->>'count')::int = (select count(*) from reg where reg.pidio between gs.lunes and gs.hasta)
         and (gs.o->'registered'->>'count')::int = (select count(*) from reg where reg.dia between gs.lunes and gs.hasta))) as ok_padron,
    (gs.o->'activated'->>'count')::int =
      case when gs.loc is null
        then (select count(*) from primera p where p.dia between gs.lunes and gs.hasta)
        else (select count(*) from primera_local pl where pl.merchant_id = gs.loc and pl.dia between gs.lunes and gs.hasta) end as ok_nuevos,
    (gs.o->'active_users'->>'count')::int =
      (select count(distinct b.user_id) from b where b.bd between gs.lunes and gs.hasta and (gs.loc is null or b.merchant_id = gs.loc))
    and (gs.u->>'active_users')::int = (gs.o->'active_users'->>'count')::int
    and (gs.o->'orders'->>'count')::int =
      (select count(distinct b.charge_id) from b where b.bd between gs.lunes and gs.hasta and (gs.loc is null or b.merchant_id = gs.loc))
    and round((gs.o->'spend'->>'financed_usd')::numeric, 2) =
      (select round(coalesce(sum(b.fin), 0), 2) from b where b.bd between gs.lunes and gs.hasta and (gs.loc is null or b.merchant_id = gs.loc)) as ok_consumo,
    round((gs.u->'per_user'->>'p50_financed_usd')::numeric, 2) =
      (select round(coalesce(percentile_cont(0.5) within group (order by x.g), 0)::numeric, 2)
       from (select sum(b.fin) as g from b where b.bd between gs.lunes and gs.hasta and (gs.loc is null or b.merchant_id = gs.loc) group by b.user_id) x) as ok_mediana,
    (select coalesce(sum((c->>'users')::int), 0) from jsonb_array_elements(gs.u->'concentration') c) = (gs.u->>'active_users')::int
    and (select round(coalesce(sum((c->>'financed_usd')::numeric), 0), 2) from jsonb_array_elements(gs.u->'concentration') c)
        = round((gs.o->'spend'->>'financed_usd')::numeric, 2) as ok_concentracion,
    (gs.g->'groups'->>'with_spend')::int =
      (select count(distinct k.group_id) from k where k.group_id is not null and k.bd between gs.lunes and gs.hasta
         and (gs.loc is null or k.merchant_id = gs.loc)) as ok_grupos_ventana,
    (gs.g->'groups'->>'ever_with_spend')::int =
      (select count(distinct k.group_id) from k
         join public.groups gr on gr.id = k.group_id
         join public.profiles p on p.id = gr.created_by and not p.is_test
         where gs.loc is null or k.merchant_id = gs.loc) as ok_grupos_siempre,
    (gs.loc is not null and gs.g->'groups'->'total' = 'null'::jsonb)
      or ((gs.g->'groups'->>'total')::int =
            (select count(*) from public.groups gr join public.profiles p on p.id = gr.created_by and not p.is_test)
          and (gs.g->'groups'->>'ever_with_spend')::int <= (gs.g->'groups'->>'total')::int) as ok_grupos_total
  from gente_sem gs
),
embudo as (select public.admin_growth_funnel(h.lunes, h.hoy, null) as j from h),
paso as (
  select e.s->>'key' as clave, e.s->>'label' as rotulo, (e.s->>'users')::int as n, e.o as orden
  from embudo, jsonb_array_elements(embudo.j->'steps') with ordinality as e(s, o)
),
reten as (select public.admin_user_cohorts('week', 8, null) as j),
reten_cmp as (
  select (r->>'start')::date as inicio,
    (r->>'size')::int = (select count(*) from reg where reg.dia is not null and metricas.lunes(reg.dia) = (r->>'start')::date)
    and coalesce((select (c->>'active')::int from jsonb_array_elements(r->'cells') c where (c->>'k')::int = 0), 0) =
        (select count(distinct b.user_id) from b join reg on reg.user_id = b.user_id
          where metricas.lunes(reg.dia) = (r->>'start')::date and metricas.lunes(b.bd) = (r->>'start')::date) as ok
  from reten, jsonb_array_elements(reten.j->'rows') r
),
perfil as (select public.admin_user_persona('consumieron', null) as j),
totales as (select public.admin_growth_overview(metricas.gente_primer_dia(), (select hoy from h), null)->'totals' as t),

n(orden, comprobacion, e, o) as (
  -- Caja › Balance: los movimientos de la semana
  select '001', 'K01 Cobrado en cuotas (consumo + fee, por día de aprobación), 2 semanas × (todos + cada local)',
    (select count(*)::text || ' de ' || count(*)::text from caja_cmp), (select count(*) filter (where cobrado_ok)::text || ' de ' || count(*)::text from caja_cmp)
  union all select '002', 'K02 Cargos por atraso cobrados, 2 semanas × (todos + cada local)',
    (select count(*)::text || ' de ' || count(*)::text from caja_cmp), (select count(*) filter (where cargos_ok)::text || ' de ' || count(*)::text from caja_cmp)
  union all select '003', 'K03 Transferido a locales (merchant_payouts), 2 semanas × (todos + cada local)',
    (select count(*)::text || ' de ' || count(*)::text from caja_cmp), (select count(*) filter (where transf_ok)::text || ' de ' || count(*)::text from caja_cmp)
  union all select '004', 'K04 Service fee ganado sin IVA (Σ consumer_fee_usd), 2 semanas × (todos + cada local)',
    (select count(*)::text || ' de ' || count(*)::text from caja_cmp), (select count(*) filter (where serv_ok)::text || ' de ' || count(*)::text from caja_cmp)
  union all select '005', 'K05 Facturado (sin fee) del pie del service fee, 2 semanas × (todos + cada local)',
    (select count(*)::text || ' de ' || count(*)::text from caja_cmp), (select count(*) filter (where fact_ok)::text || ' de ' || count(*)::text from caja_cmp)
  union all select '006', 'K06 Dinero en caja al cierre = libro contable sin prueba (y null con local)',
    (select count(*)::text || ' de ' || count(*)::text from caja_cmp), (select count(*) filter (where caja_ok)::text || ' de ' || count(*)::text from caja_cmp)
  -- Caja › Balance: la foto de hoy
  union all select '007', 'K07 Por cobrar a usuarios: cuotas vivas (payable) = Σ installments pendientes no perdidas',
    (select vivo_pay::text from foto_esp), (select round((j->'receivable'->>'payable_usd')::numeric, 2)::text from foto)
  union all select '008', 'K08 Por cobrar a usuarios (consumo + fee + cargos) cuadra con el libro contable (user_receivable)',
    (select round((j->>'user_receivable')::numeric, 2)::text from foto),
    (select round((j->'receivable'->>'payable_usd')::numeric + (j->'receivable'->>'late_fees_usd')::numeric, 2)::text from foto)
  union all select '009', 'K09 Cargos por atraso pendientes = Σ late_fees pendientes',
    (select cargos_pend::text from foto_esp), (select round((j->'receivable'->>'late_fees_usd')::numeric, 2)::text from foto)
  union all select '010', 'K10 Consumo por cobrar (sin fee): la parte del Balance = la del semáforo (principal_outstanding) = Σ financed',
    (select vivo_fin::text || ' / ' || vivo_fin::text from foto_esp),
    (select round((j->'receivable'->>'financed_usd')::numeric, 2)::text || ' / ' || round((j->>'principal_outstanding')::numeric, 2)::text from foto)
  union all select '011', 'K11 Dado por perdido (sin fee) = Σ financed pendiente y castigado',
    (select perdido_fin::text from foto_esp), (select round((j->'lost'->>'financed_usd')::numeric, 2)::text from foto)
  union all select '012', 'K12 Service fee ganado desde el inicio, sin IVA = Σ consumer_fee_usd de todos los consumos',
    (select serv_total::text from foto_esp), (select round((j->'service'->>'earned_usd')::numeric, 2)::text from foto)
  union all select '013', 'K13 Por pagar a locales: la tarjeta del Balance = la del semáforo de capital',
    (select semaforo::text from por_pagar), (select balance::text from por_pagar)
  -- Caja › Proyección
  union all select '014', 'K14 Proyección: lo que vence cada semana = Σ cuotas pendientes con vencimiento desde hoy',
    (select count(*)::text || ' de ' || count(*)::text from proy_esp), (select count(*) filter (where vence = ind)::text || ' de ' || count(*)::text from proy_esp)
  union all select '015', 'K15 Proyección: el cobro a tiempo que multiplica = el canónico (90 días, plazo cerrado, día del reporte)',
    (select canon::text from factor), (select round((j->>'on_time_factor')::numeric, 4)::text from proy)
  -- Locales
  union all select '101', 'L01 Tabla: facturado, consumos, usuarios y usuarios nuevos en el local, 2 semanas × (cada local + Todos)',
    (select count(*)::text || ' de ' || count(*)::text from loc_cmp), (select count(*) filter (where ok_venta)::text || ' de ' || count(*)::text from loc_cmp)
  union all select '102', 'L02 Tabla: cobrado a tiempo (juzgadas y a tiempo, por día del reporte), 2 semanas × (cada local + Todos)',
    (select count(*)::text || ' de ' || count(*)::text from loc_cmp), (select count(*) filter (where ok_a_tiempo)::text || ' de ' || count(*)::text from loc_cmp)
  union all select '103', 'L03 Tabla: vencido (consumo + fee) al cierre de la semana, 2 semanas × (cada local + Todos)',
    (select count(*)::text || ' de ' || count(*)::text from loc_cmp), (select count(*) filter (where ok_vencido)::text || ' de ' || count(*)::text from loc_cmp)
  union all select '104', 'L04 Facturado por semana y local (pequeños múltiplos y serie de la ficha), 12 semanas × local',
    (select count(*)::text || ' de ' || count(*)::text from serie_cmp), (select count(*) filter (where ok)::text || ' de ' || count(*)::text from serie_cmp)
  union all select '105', 'L05 Cuota 1 cobrada a tiempo por local y semana de consumo (juzgadas y a tiempo), 8 semanas × local',
    (select count(*)::text || ' de ' || count(*)::text from coh_cmp), (select count(*) filter (where ok)::text || ' de ' || count(*)::text from coh_cmp)
  union all select '106', 'L06 Consumos por noche del local (consumos, facturado, usuarios, nuevos en el local), semana en curso',
    (select count(*)::text || ' de ' || count(*)::text from noches_cmp), (select count(*) filter (where ok)::text || ' de ' || count(*)::text from noches_cmp)
  union all select '107', 'L07 Cartera del local: por cobrar, vencido, cuotas juzgadas y a tiempo (histórico), cada local',
    (select count(*)::text || ' de ' || count(*)::text from cartera_cmp), (select count(*) filter (where ok)::text || ' de ' || count(*)::text from cartera_cmp)
  -- Gente
  union all select '201', 'G01 Solicitaron el código y Registros (null con local), 2 semanas × (todos + cada local)',
    (select count(*)::text || ' de ' || count(*)::text from gente_cmp), (select count(*) filter (where ok_padron)::text || ' de ' || count(*)::text from gente_cmp)
  union all select '202', 'G02 Usuarios con su primer consumo / nuevos en el local, 2 semanas × (todos + cada local)',
    (select count(*)::text || ' de ' || count(*)::text from gente_cmp), (select count(*) filter (where ok_nuevos)::text || ' de ' || count(*)::text from gente_cmp)
  union all select '203', 'G03 Usuarios que consumieron (Resumen = Uso), consumos y facturado, 2 semanas × (todos + cada local)',
    (select count(*)::text || ' de ' || count(*)::text from gente_cmp), (select count(*) filter (where ok_consumo)::text || ' de ' || count(*)::text from gente_cmp)
  union all select '204', 'G04 Uso: facturado por usuario, mediana, 2 semanas × (todos + cada local)',
    (select count(*)::text || ' de ' || count(*)::text from gente_cmp), (select count(*) filter (where ok_mediana)::text || ' de ' || count(*)::text from gente_cmp)
  union all select '205', 'G05 Uso: la concentración suma los usuarios y el facturado de la ventana',
    (select count(*)::text || ' de ' || count(*)::text from gente_cmp), (select count(*) filter (where ok_concentracion)::text || ' de ' || count(*)::text from gente_cmp)
  union all select '206', 'G06 Grupos que consumieron en la ventana, 2 semanas × (todos + cada local)',
    (select count(*)::text || ' de ' || count(*)::text from gente_cmp), (select count(*) filter (where ok_grupos_ventana)::text || ' de ' || count(*)::text from gente_cmp)
  union all select '207', 'G07 Grupos que han consumido alguna vez (el anillo), todos y cada local',
    (select count(*)::text || ' de ' || count(*)::text from gente_cmp), (select count(*) filter (where ok_grupos_siempre)::text || ' de ' || count(*)::text from gente_cmp)
  union all select '208', 'G08 Grupos creados desde el inicio (y el anillo nunca pasa del 100 %)',
    (select count(*)::text || ' de ' || count(*)::text from gente_cmp), (select count(*) filter (where ok_grupos_total)::text || ' de ' || count(*)::text from gente_cmp)
  union all select '209', 'G09 Embudo: el primer escalón = Solicitaron el código de la semana',
    (select (o->'requested'->>'count') from gente_sem where cual = 'en curso' and loc is null), (select n::text from paso where clave = 'pidieron')
  union all select '210', 'G10 Embudo: cada escalón está dentro del anterior',
    'verdadero', (select case when bool_and(p.n <= coalesce(a.n, p.n)) then 'verdadero' else 'falso' end
                  from paso p left join paso a on a.orden = p.orden - 1)
  union all select '211', 'G11 Embudo: los rótulos dicen lo que cuentan',
    'Crearon su PIN | Hicieron 2 consumos o más',
    (select max(rotulo) filter (where clave = 'listos') || ' | ' || max(rotulo) filter (where clave = 'repitieron') from paso)
  union all select '212', 'G12 Retención semanal: tamaño de cada cohorte (registros) y los que consumieron la semana 0',
    (select count(*)::text || ' de ' || count(*)::text from reten_cmp), (select count(*) filter (where ok)::text || ' de ' || count(*)::text from reten_cmp)
  union all select '213', 'G13 Totales desde el inicio: solicitaron, registros, con PIN y usuarios que han consumido',
    (select count(*)::text || ' / ' || count(*) filter (where dia is not null)::text || ' / '
            || count(*) filter (where dia is not null and estado not in ('pending_kyc', 'pending_pin'))::text || ' / '
            || (select count(distinct b.user_id) from b join reg r2 on r2.user_id = b.user_id and r2.dia is not null)::text from reg),
    (select (t->>'requested') || ' / ' || (t->>'registered') || ' / ' || (t->>'onboarded') || ' / ' || (t->>'ever_bought') from totales)
  union all select '214', 'G14 Perfil: las bases del selector (usuarios que consumieron · registros)',
    (select (select count(distinct b.user_id) from b join reg on reg.user_id = b.user_id and reg.dia is not null)::text
            || ' · ' || (select count(*) from reg where dia is not null)::text),
    (select (j->'bases'->>'consumieron') || ' · ' || (j->'bases'->>'registrados') from perfil)
)
select comprobacion, coalesce(e, 'nulo') as esperado, coalesce(o, 'nulo') as obtenido,
       e is not distinct from o and e is not null as ok
from n
order by orden;
