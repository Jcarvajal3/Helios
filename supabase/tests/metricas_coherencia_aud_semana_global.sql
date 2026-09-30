-- ============================================================================
-- Batería del repaso de rigor de Semana (Resumen y Rendimiento) y de Global
-- (Resumen y Cupos) — agente AUD-SEMANA-GLOBAL (27-09)
--
-- Recalcula las cifras de esas pantallas DESDE LAS TABLAS (charges,
-- installments, profiles, levels, late_fees…), sin pasar por las vistas de
-- `metricas`, y las compara con lo que devuelve cada RPC:
--   R  Semana › Resumen: la anterior hasta el mismo momento (20260927660000),
--      y que el «Total facturado (sin fee)» de Resumen es la fila «Total
--      facturado» de Rendimiento en la semana de hoy, en una cerrada y en un
--      local.
--   G  Global › Resumen: facturado, consumos, usuarios, por cobrar, vencido,
--      cobrado, perdido, mora, service fee sin IVA, activos, repiten, la
--      curva y el impago frente a «por cada €100».
--   C  Global › Cupos: ocupado, exposición, cupo total, uso y registros por
--      nivel; y que la exposición es el facturado de lo que está por cobrar
--      en Global › Resumen (la misma cifra con dos nombres).
--
-- Solo SELECT. Se hace pasar por un admin activo (request.jwt.claims con
-- aal2) sin cambiar de rol, para leer las tablas en la misma consulta.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_aud_semana_global.sql
-- ============================================================================

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

with
h as (select public.helios_business_date(now()) as hoy),
-- Los consumos y sus cuotas, desde las tablas (la definición del contrato:
-- confirmados, sin pruebas, con día operativo).
ch as (
  select c.id, c.business_date, c.merchant_id, c.confirmed_at, c.consumer_fee_usd
  from public.charges c
  where c.status = 'confirmed' and not c.is_test and c.business_date is not null
),
iq as (
  select i.*, ch.business_date, ch.merchant_id, ch.confirmed_at
  from public.installments i join ch on ch.id = i.charge_id
  where not i.is_test
),
-- El local con más consumo (para las comprobaciones con local).
loc as (select merchant_id as id from ch group by 1 order by count(*) desc limit 1),

-- ── R. Semana › Resumen ──────────────────────────────────────────────────
rr as (select public.admin_metricas_semana_resumen(null, null) as j),
ra as (select (j->'anterior'->>'desde')::date as d, (j->'anterior'->>'hasta')::date as hh,
              (j->'anterior'->>'corte')::timestamptz as c, (j->'semana'->>'en_curso')::boolean as en_curso,
              j->'comparacion' as x from rr),
rs as (select public.admin_metricas_semanas(null, 8, null) as j),
-- Una semana cerrada y un local, en las dos sub-pestañas.
rr_cerrada as (select public.admin_metricas_semana_resumen((select hoy - 14 from h), null) as j),
rs_cerrada as (select public.admin_metricas_semanas((select hoy - 14 from h), 1, null) as j),
rr_local as (select public.admin_metricas_semana_resumen(null, (select id from loc)) as j),
rs_local as (select public.admin_metricas_semanas(null, 1, (select id from loc)) as j),

-- ── G. Global › Resumen ──────────────────────────────────────────────────
g as (select public.admin_metricas_general(null) as j),
gl as (select public.admin_metricas_general((select id from loc)) as j),

-- ── C. Global › Cupos ────────────────────────────────────────────────────
cu as (select public.admin_credit_utilization(null) as j),
gente_cupo as (
  select p.id, p.level, l.monthly_limit_usd as limite, (l.is_active and l.level >= 1) as en_nivel,
         (select coalesce(sum(i.financed_usd), 0) from public.installments i
           where i.user_id = p.id and not i.is_test
             and exists (select 1 from public.installments j2
                         where j2.charge_id = i.charge_id and j2.user_id = i.user_id and j2.status = 'pending')) as usado,
         (select coalesce(sum(i.financed_usd), 0) from public.installments i
           where i.user_id = p.id and not i.is_test and i.status = 'pending' and i.written_off_at is null) as expuesto
  from public.profiles p join public.levels l on l.level = p.level
  where not p.is_test
),

resultado(orden, comprobacion, esperado, obtenido, tol) as (
  -- R1–R5: la anterior hasta el mismo momento
  select '01', 'R1 Resumen, anterior hasta el mismo momento: facturado (sin fee)',
         (select coalesce(sum(iq.financed_usd), 0) from iq, ra where iq.business_date between ra.d and ra.hh
             and (ra.c is null or iq.confirmed_at <= ra.c)),
         (select (x->>'financed_usd')::numeric from ra), 0.01
  union all
  select '02', 'R2 Resumen, anterior hasta el mismo momento: consumos',
         (select count(*) from ch, ra where ch.business_date between ra.d and ra.hh and (ra.c is null or ch.confirmed_at <= ra.c))::numeric,
         (select (x->>'consumos')::numeric from ra), 0
  union all
  select '03', 'R3 Resumen, anterior hasta el mismo momento: usuarios',
         (select count(distinct iq.user_id) from iq, ra where iq.business_date between ra.d and ra.hh
             and (ra.c is null or iq.confirmed_at <= ra.c))::numeric,
         (select (x->>'personas')::numeric from ra), 0
  union all
  select '04', 'R4 Resumen, anterior: total a cobrar = facturado + service fee + IVA',
         (select (x->>'financed_usd')::numeric + (x->>'fee_usd')::numeric from ra),
         (select (x->>'payable_usd')::numeric from ra), 0.01
  union all
  select '05', 'R5 Resumen, anterior hasta el mismo momento: nuevos en algún local',
         (select count(distinct x.user_id)::numeric from (
            select iq.user_id, iq.merchant_id, min(iq.business_date) as primer_dia, min(iq.confirmed_at) as primer_instante
            from iq group by 1, 2) x, ra
          where x.primer_dia between ra.d and ra.hh and (ra.c is null or x.primer_instante <= ra.c)),
         (select (x->>'nuevas')::numeric from ra), 0
  union all
  select '06', 'R6 El corte es ahora − 7 días con la semana en curso (1 = sí)',
         1, (select case when not ra.en_curso then (case when ra.c is null then 1 else 0 end)
                         when ra.c = now() - interval '7 days' then 1 else 0 end from ra)::numeric, 0
  union all
  select '07', 'R7 Resumen y Rendimiento comparan con lo mismo: facturado de la anterior',
         (select (j->'comparacion'->'consumo'->>'financed_usd')::numeric from rs),
         (select (x->>'financed_usd')::numeric from ra), 0.01
  union all
  -- R8–R10: «Total facturado (sin fee)» = la fila «Total facturado» de Rendimiento
  select '08', 'R8 Total facturado: Resumen = Rendimiento, semana de hoy',
         (select (j->'filas'->-1->'consumo'->>'financed_usd')::numeric from rs),
         (select (j->'cifras'->>'financed_usd')::numeric from rr), 0.01
  union all
  select '09', 'R9 Total facturado: Resumen = Rendimiento, semana cerrada (hace dos)',
         (select (j->'filas'->-1->'consumo'->>'financed_usd')::numeric from rs_cerrada),
         (select (j->'cifras'->>'financed_usd')::numeric from rr_cerrada), 0.01
  union all
  select '10', 'R10 Total facturado: Resumen = Rendimiento, semana de hoy con el local de más consumo',
         (select (j->'filas'->-1->'consumo'->>'financed_usd')::numeric from rs_local),
         (select (j->'cifras'->>'financed_usd')::numeric from rr_local), 0.01
  union all
  select '11', 'R11 Total facturado de hoy, desde las tablas',
         (select coalesce(sum(iq.financed_usd), 0) from iq, h where iq.business_date between h.hoy - (extract(isodow from h.hoy)::integer - 1) and h.hoy),
         (select (j->'cifras'->>'financed_usd')::numeric from rr), 0.01
  union all
  select '12', 'R12 Usuarios que consumieron: Resumen = Rendimiento, semana cerrada',
         (select (j->'filas'->-1->'consumo'->>'personas')::numeric from rs_cerrada),
         (select (j->'cifras'->>'personas')::numeric from rr_cerrada), 0

  -- G1–G14: Global › Resumen desde las tablas
  union all
  select '21', 'G1 Total facturado (sin fee) desde el inicio',
         (select coalesce(sum(financed_usd), 0) from iq), (select (j->'consumo'->>'financed_usd')::numeric from g), 0.01
  union all
  select '22', 'G2 Consumos desde el inicio',
         (select count(*) from ch)::numeric, (select (j->'consumo'->>'consumos')::numeric from g), 0
  union all
  select '23', 'G3 Usuarios que consumieron desde el inicio',
         (select count(distinct user_id) from iq)::numeric, (select (j->'consumo'->>'personas')::numeric from g), 0
  union all
  select '24', 'G4 Por cobrar hoy: facturado (pendiente y no perdido)',
         (select coalesce(sum(financed_usd), 0) from iq where status = 'pending' and written_off_at is null),
         (select (j->'dinero'->'por_cobrar'->>'financed_usd')::numeric from g), 0.01
  union all
  select '25', 'G5 Por cobrar hoy: total a cobrar (facturado + service fee + IVA)',
         (select coalesce(sum(amount_usd), 0) from iq where status = 'pending' and written_off_at is null),
         (select (j->'dinero'->'por_cobrar'->>'payable_usd')::numeric from g), 0.01
  union all
  select '26', 'G6 De ello, vencido hoy (vencimiento antes de hoy)',
         (select coalesce(sum(amount_usd), 0) from iq, h where status = 'pending' and written_off_at is null and due_date < h.hoy),
         (select (j->'dinero'->'vencido'->>'payable_usd')::numeric from g), 0.01
  union all
  select '27', 'G7 Cobrado desde el inicio (cuotas pagadas)',
         (select coalesce(sum(amount_usd), 0) from iq where status = 'paid'),
         (select (j->'dinero'->'cobrado'->>'payable_usd')::numeric from g), 0.01
  union all
  select '28', 'G8 Perdido (sin fee): pendiente y dado por perdido',
         (select coalesce(sum(financed_usd), 0) from iq where status = 'pending' and written_off_at is not null),
         (select (j->'dinero'->'perdido'->>'financed_usd')::numeric from g), 0.01
  union all
  select '29', 'G9 Mora hoy = vencido ÷ (vencido + por vencer)',
         (select round(100 * sum(amount_usd) filter (where due_date < h.hoy) / nullif(sum(amount_usd), 0), 2)
            from iq, h where status = 'pending' and written_off_at is null),
         (select (j->'riesgo'->>'mora_pct')::numeric from g), 0.01
  union all
  select '30', 'G10 Service fee sin IVA desde el inicio',
         (select coalesce(sum(consumer_fee_usd), 0) from ch), (select (j->'dinero'->>'servicio_usd')::numeric from g), 0.01
  union all
  select '31', 'G11 Usuarios activos (últimos 30 días operativos)',
         (select count(distinct user_id) from iq, h where business_date between h.hoy - 29 and h.hoy)::numeric,
         (select (j->'gente'->>'activos')::numeric from g), 0
  union all
  select '32', 'G12 Usuarios que repiten (dos noches o más)',
         (select count(*) from (select user_id from iq group by 1 having count(distinct business_date) >= 2) x)::numeric,
         (select (j->'gente'->>'repiten')::numeric from g), 0
  union all
  select '33', 'G13 Curva: el último acumulado de facturado = el total',
         (select (j->'consumo'->>'financed_usd')::numeric from g),
         (select (j->'curva'->-1->>'financed_acum_usd')::numeric from g), 0.01
  union all
  select '34', 'G14 Curva: el último acumulado de registros = los registros',
         (select (j->'gente'->>'registros')::numeric from g),
         (select (j->'curva'->-1->>'registros_acum')::numeric from g), 0
  union all
  select '35', 'G15 Impago (%) = perdido por cada €100 (la misma cifra dos veces)',
         (select (j->'riesgo'->>'impago_pct')::numeric from g),
         (select (j->'por_cada_100'->'por_100'->>'perdido_usd')::numeric from g), 0.01
  union all
  select '36', 'G16 Con local: total facturado del local',
         (select coalesce(sum(financed_usd), 0) from iq where merchant_id = (select id from loc)),
         (select (j->'consumo'->>'financed_usd')::numeric from gl), 0.01
  union all
  select '37', 'G17 Con local: usuarios que consumieron en el local',
         (select count(distinct user_id) from iq where merchant_id = (select id from loc))::numeric,
         (select (j->'consumo'->>'personas')::numeric from gl), 0
  union all
  select '38', 'G18 Registros que han consumido (%) = registros con consumo ÷ registros',
         (select round(100.0 * (j->'gente'->>'han_comprado')::numeric / nullif((j->'gente'->>'registros')::numeric, 0), 1) from g),
         (select (j->'gente'->>'han_comprado_pct')::numeric from g), 0.05

  -- C1–C6: Global › Cupos desde las tablas
  union all
  select '41', 'C1 Cupo ocupado (todo el mundo)',
         (select coalesce(sum(usado), 0) from gente_cupo), (select (j->'total'->>'used_financed_usd')::numeric from cu), 0.01
  union all
  select '42', 'C2 Exposición (facturado pendiente y no perdido, todo el mundo)',
         (select coalesce(sum(expuesto), 0) from gente_cupo), (select (j->'total'->>'exposure_financed_usd')::numeric from cu), 0.01
  union all
  select '43', 'C3 Cupo total de los niveles activos',
         (select coalesce(sum(limite), 0) from gente_cupo where en_nivel), (select (j->'total'->>'limit_total_usd')::numeric from cu), 0.01
  union all
  select '44', 'C4 Uso del cupo = ocupado en los niveles activos ÷ su cupo',
         (select round(100 * sum(usado) filter (where en_nivel) / nullif(sum(limite) filter (where en_nivel), 0), 1) from gente_cupo),
         (select (j->'total'->>'usage_pct')::numeric from cu), 0.05
  union all
  select '45', 'C5 Registros en los niveles activos',
         (select count(*) from gente_cupo where en_nivel)::numeric, (select (j->'total'->>'user_count')::numeric from cu), 0
  union all
  select '46', 'C6 Exposición (Cupos) = por cobrar, facturado (Global › Resumen)',
         (select (j->'dinero'->'por_cobrar'->>'financed_usd')::numeric from g),
         (select (j->'total'->>'exposure_financed_usd')::numeric from cu), 0.01
  union all
  select '47', 'C7 El reparto por uso de cada nivel suma sus registros (niveles que no cuadran)',
         0, (select count(*) from jsonb_array_elements((select j->'levels' from cu)) n
             where (n->>'user_count')::integer
                   <> (select coalesce(sum((b->>'count')::integer), 0) from jsonb_array_elements(n->'buckets') b))::numeric, 0
)
select comprobacion, coalesce(round(esperado, 2)::text, 'nulo') as esperado, coalesce(round(obtenido, 2)::text, 'nulo') as obtenido,
       coalesce(abs(esperado - obtenido) <= tol, esperado is null and obtenido is null) as ok
from resultado
order by orden;
