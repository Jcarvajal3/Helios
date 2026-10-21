-- ============================================================================
-- Batería de coherencia de Métricas › General (dev)
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok, como la
-- batería de CIMIENTOS (metricas_coherencia.sql). «Esperado» es la definición
-- canónica (esquema metricas) o la cifra que ya enseña otra pantalla con la
-- misma definición (admin_overview, admin_on_time_collection,
-- admin_growth_overview, admin_cash_position, admin_merchant_payables);
-- «obtenido», lo que devuelve admin_metricas_general. Las comprobaciones por
-- local y por semana dan una fila resumen («N / M cuadran») y una fila de
-- detalle por cada una que no cuadra.
--
-- Solo SELECT. Se hace pasar por un admin activo poniendo request.jwt.claims
-- (con aal2). NO cambia el rol a authenticated: las RPC son security definer
-- y solo miran auth.uid(), y así la misma consulta puede leer metricas.*.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_general.sql
-- ============================================================================

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

with
h   as (select metricas.hoy() as hoy),
g   as (select public.admin_metricas_general(null) as j),
ov  as (select public.admin_overview(30) as j),
ot  as (select public.admin_on_time_collection(365) as j),
gr  as (select public.admin_growth_overview(null, null) as j),
cp  as (select public.admin_cash_position() as j),
mc  as (select * from metricas.consumos),
mq  as (select * from metricas.cuotas),
mp  as (select * from metricas.personas),
ms  as (select * from metricas.solicitudes),
mppl as (select * from metricas.personas_por_local),
ma  as (select * from metricas.cargos_por_atraso),
car as (select * from metricas.cartera_al(metricas.hoy())),
pag as (
  select (x->>'merchant_id')::uuid as merchant_id,
         (x->>'total_pending_usd')::numeric as total,
         (x->>'overdue_usd')::numeric as atrasado
  from jsonb_array_elements(public.admin_merchant_payables()) x
  where not coalesce((x->>'is_test')::boolean, false)
),
-- Los locales reales con algo que partir: consumo, cargos o deuda con ellos.
locs as (
  select m.id, m.name, public.admin_metricas_general(m.id) as j
  from public.merchants m
  where not m.is_test
    and (exists (select 1 from mc where mc.merchant_id = m.id)
         or exists (select 1 from ma where ma.merchant_id = m.id)
         or exists (select 1 from pag where pag.merchant_id = m.id))
),
-- La curva de todos los locales, semana a semana.
cu as (
  select (s->>'semana')::date as semana,
         (s->>'registros')::numeric as registros,
         (s->>'registros_acum')::numeric as registros_acum,
         (s->>'consumos')::numeric as consumos,
         (s->>'financed_usd')::numeric as financed,
         (s->>'financed_acum_usd')::numeric as financed_acum
  from g, jsonb_array_elements(g.j->'curva') s
),
-- Lo que devuelve la RPC, ya leído.
r as (
  select
    (j->'gente'->>'solicitaron')::numeric                  as solicitaron,
    (j->'gente'->>'telefono_confirmado')::numeric          as telefono_confirmado,
    (j->'gente'->>'registros')::numeric                    as registros,
    (j->'gente'->>'verificados')::numeric                  as verificados,
    (j->'gente'->>'han_comprado')::numeric                 as han_comprado,
    (j->'gente'->>'han_comprado_pct')::numeric             as han_comprado_pct,
    (j->'gente'->>'activos')::numeric                      as activos,
    (j->'gente'->>'repiten')::numeric                      as repiten,
    (j->'consumo'->>'financed_usd')::numeric               as consumo,
    (j->'consumo'->>'consumos')::numeric                   as consumos,
    (j->'consumo'->>'ticket_usd')::numeric                 as ticket,
    (j->'consumo'->>'personas')::numeric                   as personas,
    (j->'consumo'->>'locales')::numeric                    as locales,
    (j->'consumo'->>'locales_activos')::numeric            as locales_activos,
    (j->'dinero'->'por_cobrar'->>'payable_usd')::numeric   as cobrar_p,
    (j->'dinero'->'por_cobrar'->>'financed_usd')::numeric  as cobrar_f,
    (j->'dinero'->'por_cobrar'->>'fee_usd')::numeric       as cobrar_fee,
    (j->'dinero'->'vencido'->>'payable_usd')::numeric      as vencido_p,
    (j->'dinero'->'vencido'->>'financed_usd')::numeric     as vencido_f,
    (j->'dinero'->'vencido'->>'fee_usd')::numeric          as vencido_fee,
    (j->'dinero'->'vencido'->>'personas')::numeric         as vencido_personas,
    (j->'dinero'->'cobrado'->>'payable_usd')::numeric      as cobrado_p,
    (j->'dinero'->'cobrado'->>'financed_usd')::numeric     as cobrado_f,
    (j->'dinero'->'cobrado'->>'fee_usd')::numeric          as cobrado_fee,
    (j->'dinero'->>'servicio_usd')::numeric                as servicio,
    (j->'dinero'->'cargos_por_atraso'->>'devengado_usd')::numeric as cargos,
    (j->'dinero'->'cargos_por_atraso'->>'cobrado_usd')::numeric   as cargos_cobrados,
    (j->'dinero'->'perdido'->>'payable_usd')::numeric      as perdido_p,
    (j->'dinero'->'perdido'->>'financed_usd')::numeric     as perdido_f,
    (j->'dinero'->'perdido'->>'fee_usd')::numeric          as perdido_fee,
    (j->'dinero'->>'caja_usd')::numeric                    as caja,
    (j->'dinero'->'por_pagar_locales'->>'total_usd')::numeric    as por_pagar,
    (j->'dinero'->'por_pagar_locales'->>'atrasado_usd')::numeric as por_pagar_atrasado,
    (j->'riesgo'->>'mora_pct')::numeric                    as mora,
    (j->'riesgo'->>'impago_pct')::numeric                  as impago,
    (j->'riesgo'->>'empate_pct')::numeric                  as empate,
    (j->'riesgo'->'a_tiempo'->0->>'juzgadas')::numeric     as juzgadas_1,
    (j->'riesgo'->'a_tiempo'->0->>'a_tiempo')::numeric     as a_tiempo_1,
    (j->'riesgo'->'a_tiempo'->0->>'pct')::numeric          as pct_1,
    (j->'riesgo'->'a_tiempo'->1->>'juzgadas')::numeric     as juzgadas_2,
    (j->'riesgo'->'a_tiempo'->1->>'a_tiempo')::numeric     as a_tiempo_2,
    (j->'riesgo'->'a_tiempo'->1->>'pct')::numeric          as pct_2,
    (j->'por_cada_100'->>'financed_usd')::numeric          as c100_financed,
    (j->'por_cada_100'->>'perdido_usd')::numeric           as c100_perdido,
    (j->'por_cada_100'->>'cargos_usd')::numeric            as c100_cargos,
    (j->'por_cada_100'->'por_100'->>'servicio_usd')::numeric as p100_servicio,
    (j->'por_cada_100'->'por_100'->>'cargos_usd')::numeric   as p100_cargos,
    (j->'por_cada_100'->'por_100'->>'perdido_usd')::numeric  as p100_perdido,
    (j->'por_cada_100'->'por_100'->>'personal_usd')::numeric as p100_personal,
    (j->'por_cada_100'->'por_100'->>'margen_usd')::numeric   as p100_margen,
    (j->>'desde')::date                                    as desde
  from g
),
-- Las comprobaciones globales: (orden, comprobación, esperado, obtenido, tolerancia).
n(orden, comprobacion, e, o, tol) as (
  -- ── A. Gente ──────────────────────────────────────────────────────────────
  select '001', 'A1 Registros = metricas.personas', (select count(*) from mp)::numeric, (select registros from r), 0::numeric
  union all select '002', 'A2 Registros = Riesgo › Usuarios por estado (admin_overview.users.total)',
    (select (j->'users'->>'total')::numeric from ov), (select registros from r), 0
  union all select '003', 'A3 Registros = Gente (admin_growth_overview.totals.registered)',
    (select (j->'totals'->>'registered')::numeric from gr), (select registros from r), 0
  union all select '004', 'A4 Verificados = Registros (todo registro está verificado)',
    (select registros from r), (select verificados from r), 0
  union all select '005', 'A5 Han comprado = registros con primer consumo',
    (select count(*) filter (where primer_consumo_dia is not null) from mp)::numeric, (select han_comprado from r), 0
  union all select '006', 'A6 Han comprado = Gente (admin_growth_overview.totals.ever_bought)',
    (select (j->'totals'->>'ever_bought')::numeric from gr), (select han_comprado from r), 0
  union all select '007', 'A7 Han comprado (registros) = personas con cuota (consumo.personas)',
    (select personas from r), (select han_comprado from r), 0
  union all select '008', 'A8 Han comprado, % de los registros',
    (select round(100.0 * count(*) filter (where primer_consumo_dia is not null) / nullif(count(*), 0), 1) from mp),
    (select han_comprado_pct from r), 0
  union all select '009', 'A9 Activos en 30 días = personas con cuota en 30 días',
    (select count(distinct q.user_id) from mq q, h where q.business_date between h.hoy - 29 and h.hoy)::numeric,
    (select activos from r), 0
  union all select '010', 'A10 Activos en 30 días = Resumen (admin_overview.volume.active_people)',
    (select (j->'volume'->>'active_people')::numeric from ov), (select activos from r), 0
  union all select '011', 'A11 Repiten = personas con cuota en 2 noches o más',
    (select count(*) from (select user_id from mq group by user_id having count(distinct business_date) >= 2) x)::numeric,
    (select repiten from r), 0
  union all select '012', 'A12 Repiten = registros con 2 noches o más (metricas.personas.noches)',
    (select count(*) filter (where noches >= 2) from mp)::numeric, (select repiten from r), 0
  union all select '013', 'A13 Solicitaron el código = metricas.solicitudes',
    (select count(*) from ms)::numeric, (select solicitaron from r), 0
  union all select '014', 'A14 Solicitaron el código = Gente (admin_growth_overview.totals.requested)',
    (select (j->'totals'->>'requested')::numeric from gr), (select solicitaron from r), 0
  union all select '015', 'A15 Solicitaron el código = admin_overview.users.requested_otp',
    (select (j->'users'->>'requested_otp')::numeric from ov), (select solicitaron from r), 0
  union all select '016', 'A16 Confirmaron el teléfono = solicitudes que pasaron del código',
    (select count(*) filter (where etapa <> 'solicito_el_codigo') from ms)::numeric, (select telefono_confirmado from r), 0
  union all select '017', 'A17 Confirmaron el teléfono = Gente (totals.phone_confirmed)',
    (select (j->'totals'->>'phone_confirmed')::numeric from gr), (select telefono_confirmado from r), 0
  union all select '018', 'A18 Registros = solicitudes verificadas',
    (select count(*) filter (where etapa = 'verificado') from ms)::numeric, (select registros from r), 0

  -- ── B. Consumo ────────────────────────────────────────────────────────────
  union all select '020', 'B1 Consumo = Σ metricas.consumos.financed_usd',
    (select coalesce(sum(financed_usd), 0) from mc), (select consumo from r), 0.005
  union all select '021', 'B2 Consumos = metricas.consumos',
    (select count(*) from mc)::numeric, (select consumos from r), 0
  union all select '022', 'B3 Ticket medio = consumo ÷ consumos',
    (select round(sum(financed_usd) / nullif(count(*), 0), 2) from mc), (select ticket from r), 0.005
  union all select '023', 'B4 Personas = personas distintas con cuota',
    (select count(distinct user_id) from mq)::numeric, (select personas from r), 0
  union all select '024', 'B5 Locales con ventas desde el inicio',
    (select count(distinct merchant_id) from mc)::numeric, (select locales from r), 0
  union all select '025', 'B6 Locales activos = Resumen (admin_overview.merchants.selling_in_window)',
    (select (j->'merchants'->>'selling_in_window')::numeric from ov), (select locales_activos from r), 0
  union all select '026', 'B7 Consumo = Σ consumo de sus cuotas (metricas.cuotas)',
    (select coalesce(sum(financed_usd), 0) from mq), (select consumo from r), 0.005

  -- ── C. Dinero ─────────────────────────────────────────────────────────────
  union all select '030', 'C1 Por cobrar (payable) = Resumen (arrears.open_usd)',
    (select (j->'arrears'->>'open_usd')::numeric from ov), (select cobrar_p from r), 0.005
  union all select '031', 'C2 Por cobrar, consumo = arrears.open_financed_usd',
    (select (j->'arrears'->>'open_financed_usd')::numeric from ov), (select cobrar_f from r), 0.005
  union all select '032', 'C3 Por cobrar, servicio e IVA = arrears.open_fee_usd',
    (select (j->'arrears'->>'open_fee_usd')::numeric from ov), (select cobrar_fee from r), 0.005
  union all select '033', 'C4 Por cobrar: consumo + servicio e IVA = payable',
    (select cobrar_p from r), (select cobrar_f + cobrar_fee from r), 0.005
  union all select '034', 'C5 Vencido (payable) = arrears.overdue_usd',
    (select (j->'arrears'->>'overdue_usd')::numeric from ov), (select vencido_p from r), 0.005
  union all select '035', 'C6 Vencido, consumo = arrears.overdue_financed_usd',
    (select (j->'arrears'->>'overdue_financed_usd')::numeric from ov), (select vencido_f from r), 0.005
  union all select '036', 'C7 Vencido, servicio e IVA = arrears.overdue_fee_usd',
    (select (j->'arrears'->>'overdue_fee_usd')::numeric from ov), (select vencido_fee from r), 0.005
  union all select '037', 'C8 Personas con algo vencido = arrears.overdue_users',
    (select (j->'arrears'->>'overdue_users')::numeric from ov), (select vencido_personas from r), 0
  union all select '038', 'C9 Cobrado (payable) = Σ cuotas pagadas',
    (select coalesce(sum(payable_usd) filter (where status = 'paid'), 0) from mq), (select cobrado_p from r), 0.005
  union all select '039', 'C10 Cobrado: consumo + servicio e IVA = payable',
    (select cobrado_p from r), (select cobrado_f + cobrado_fee from r), 0.005
  union all select '040', 'C11 Cobrado + por cobrar + perdido = todo lo facturado en cuotas',
    (select coalesce(sum(payable_usd), 0) from mc), (select cobrado_p + cobrar_p + perdido_p from r), 0.005
  union all select '041', 'C12 Servicio sin IVA = Σ metricas.consumos.servicio_usd',
    (select coalesce(sum(servicio_usd), 0) from mc), (select servicio from r), 0.005
  union all select '042', 'C13 Cargos por atraso devengados = metricas.cargos_por_atraso',
    (select coalesce(sum(amount_usd), 0) from ma), (select cargos from r), 0.005
  union all select '043', 'C14 Cargos por atraso cobrados',
    (select coalesce(sum(amount_usd) filter (where status = 'paid'), 0) from ma), (select cargos_cobrados from r), 0.005
  union all select '044', 'C15 Perdido, consumo = Resumen (bad_debt.written_off_financed_usd)',
    (select (j->'bad_debt'->>'written_off_financed_usd')::numeric from ov), (select perdido_f from r), 0.005
  union all select '045', 'C16 Perdido, payable = bad_debt.written_off_debt_usd',
    (select (j->'bad_debt'->>'written_off_debt_usd')::numeric from ov), (select perdido_p from r), 0.005
  union all select '046', 'C17 Perdido, servicio e IVA = bad_debt.written_off_fee_usd',
    (select (j->'bad_debt'->>'written_off_fee_usd')::numeric from ov), (select perdido_fee from r), 0.005
  union all select '047', 'C18 Caja = Caja y Resumen (admin_overview.cash.cash)',
    (select (j->'cash'->>'cash')::numeric from ov), (select caja from r), 0.005
  union all select '048', 'C19 Caja = admin_cash_position.cash',
    (select (j->>'cash')::numeric from cp), (select caja from r), 0.005
  union all select '049', 'C20 Por pagar a locales = Pagos a locales (Σ total_pending_usd sin prueba)',
    (select coalesce(sum(total), 0) from pag), (select por_pagar from r), 0.005
  union all select '050', 'C21 Por pagar a locales, atrasado',
    (select coalesce(sum(atrasado), 0) from pag), (select por_pagar_atrasado from r), 0.005

  -- ── D. Riesgo ─────────────────────────────────────────────────────────────
  union all select '060', 'D1 Mora = metricas.cartera_al(hoy)',
    (select mora_pct from car), (select mora from r), 0.005
  union all select '061', 'D2 Mora = Resumen (arrears.rate_pct, que da 0 sin nada vivo)',
    (select (j->'arrears'->>'rate_pct')::numeric from ov), (select coalesce(mora, 0) from r), 0.005
  union all select '062', 'D3 Impago = Resumen (bad_debt.rate_financed_pct)',
    (select (j->'bad_debt'->>'rate_financed_pct')::numeric from ov), (select impago from r), 0.005
  union all select '063', 'D4 Punto de empate = Resumen (bad_debt.break_even_pct)',
    (select (j->'bad_debt'->>'break_even_pct')::numeric from ov), (select empate from r), 0.005
  union all select '064', 'D5 Cuota 1, juzgadas = admin_on_time_collection(365)',
    (select coalesce((j->'installments'->'cuota_1'->>'due_count')::numeric, 0) from ot), (select juzgadas_1 from r), 0
  union all select '065', 'D6 Cuota 1, a tiempo = admin_on_time_collection(365)',
    (select coalesce((j->'installments'->'cuota_1'->>'on_time_count')::numeric, 0) from ot), (select a_tiempo_1 from r), 0
  union all select '066', 'D7 Cuota 1, tasa = admin_on_time_collection(365)',
    (select (j->'installments'->'cuota_1'->>'rate_pct')::numeric from ot), (select pct_1 from r), 0.05
  union all select '067', 'D8 Cuota 2, juzgadas = admin_on_time_collection(365)',
    (select coalesce((j->'installments'->'cuota_2'->>'due_count')::numeric, 0) from ot), (select juzgadas_2 from r), 0
  union all select '068', 'D9 Cuota 2, a tiempo = admin_on_time_collection(365)',
    (select coalesce((j->'installments'->'cuota_2'->>'on_time_count')::numeric, 0) from ot), (select a_tiempo_2 from r), 0
  union all select '069', 'D10 Cuota 2, tasa = admin_on_time_collection(365)',
    (select (j->'installments'->'cuota_2'->>'rate_pct')::numeric from ot), (select pct_2 from r), 0.05
  union all select '070', 'D11 Juzgadas = cuotas 1 y 2 con el plazo cerrado',
    (select count(*) filter (where plazo_cerrado and sequence in (1, 2)) from mq)::numeric,
    (select juzgadas_1 + juzgadas_2 from r), 0

  -- ── E. Por cada 100 € ─────────────────────────────────────────────────────
  union all select '080', 'E1 Por cada 100: el consumo es el de Consumo',
    (select consumo from r), (select c100_financed from r), 0.005
  union all select '081', 'E2 Por cada 100: lo perdido es el de Dinero (consumo)',
    (select perdido_f from r), (select c100_perdido from r), 0.005
  union all select '082', 'E3 Por cada 100: los cargos son los de Dinero',
    (select cargos from r), (select c100_cargos from r), 0.005
  union all select '083', 'E4 Por cada 100: servicio = 100 × servicio ÷ consumo',
    (select round(100 * servicio / nullif(consumo, 0), 2) from r), (select p100_servicio from r), 0.005
  union all select '084', 'E5 Por cada 100: cargos = 100 × cargos ÷ consumo',
    (select round(100 * cargos / nullif(consumo, 0), 2) from r), (select p100_cargos from r), 0.005
  union all select '085', 'E6 Por cada 100: perdido = 100 × perdido ÷ consumo',
    (select round(100 * perdido_f / nullif(consumo, 0), 2) from r), (select p100_perdido from r), 0.005
  union all select '086', 'E7 Por cada 100: margen = servicio + cargos − personal − perdido',
    (select p100_servicio + p100_cargos - p100_personal - p100_perdido from r), (select p100_margen from r), 0.02

  -- ── F. La curva ───────────────────────────────────────────────────────────
  union all select '090', 'F1 Desde = la primera solicitud del código o el primer consumo',
    (select (least((select min(solicito_dia) from ms), (select min(business_date) from mc)) - date '2000-01-01')::numeric),
    (select (desde - date '2000-01-01')::numeric from r), 0
  union all select '091', 'F2 Semanas de la curva = del lunes de «desde» al de hoy',
    (select ((metricas.lunes(h.hoy) - metricas.lunes(r.desde)) / 7 + 1)::numeric from h, r),
    (select count(*)::numeric from cu), 0
  union all select '092', 'F3 Registros acumulados al final = registros',
    (select registros from r), (select registros_acum from cu order by semana desc limit 1), 0
  union all select '093', 'F4 Σ registros de cada semana = registros',
    (select registros from r), (select sum(registros) from cu), 0
  union all select '094', 'F5 Consumo acumulado al final = consumo',
    (select consumo from r), (select financed_acum from cu order by semana desc limit 1), 0.005
  union all select '095', 'F6 Σ consumos de cada semana = consumos',
    (select consumos from r), (select sum(consumos) from cu), 0
  union all select '096', 'F7 Semanas con consumo cuyo consumo cuadra con metricas.consumos',
    (select count(*)::numeric from (select semana from mc group by semana) x),
    (select count(*)::numeric from cu
      where abs(cu.financed - coalesce((select sum(financed_usd) from mc where mc.semana = cu.semana), 0)) < 0.005
        and cu.financed > 0), 0
  union all select '097', 'F8 Semanas con registros cuyo número cuadra con metricas.personas',
    (select count(*)::numeric from (select registro_semana from mp group by registro_semana) x),
    (select count(*)::numeric from cu
      where cu.registros = (select count(*) from mp where mp.registro_semana = cu.semana)
        and cu.registros > 0), 0

  -- ── G. Por local: la suma de los locales es el total ─────────────────────
  union all select '100', 'G0 Locales comprobados (con consumo, cargos o deuda)',
    (select count(*)::numeric from locs), (select count(*)::numeric from locs), 0
  union all select '101', 'G1 Σ consumo por local = consumo',
    (select consumo from r), (select coalesce(sum((j->'consumo'->>'financed_usd')::numeric), 0) from locs), 0.005
  union all select '102', 'G2 Σ consumos por local = consumos',
    (select consumos from r), (select coalesce(sum((j->'consumo'->>'consumos')::numeric), 0) from locs), 0
  union all select '103', 'G3 Σ por cobrar (payable) por local = por cobrar',
    (select cobrar_p from r), (select coalesce(sum((j->'dinero'->'por_cobrar'->>'payable_usd')::numeric), 0) from locs), 0.005
  union all select '104', 'G4 Σ por cobrar, consumo, por local = por cobrar, consumo',
    (select cobrar_f from r), (select coalesce(sum((j->'dinero'->'por_cobrar'->>'financed_usd')::numeric), 0) from locs), 0.005
  union all select '105', 'G5 Σ por cobrar, servicio e IVA, por local = por cobrar, servicio e IVA',
    (select cobrar_fee from r), (select coalesce(sum((j->'dinero'->'por_cobrar'->>'fee_usd')::numeric), 0) from locs), 0.005
  union all select '106', 'G6 Σ vencido por local = vencido',
    (select vencido_p from r), (select coalesce(sum((j->'dinero'->'vencido'->>'payable_usd')::numeric), 0) from locs), 0.005
  union all select '107', 'G7 Σ cobrado por local = cobrado',
    (select cobrado_p from r), (select coalesce(sum((j->'dinero'->'cobrado'->>'payable_usd')::numeric), 0) from locs), 0.005
  union all select '108', 'G8 Σ servicio por local = servicio',
    (select servicio from r), (select coalesce(sum((j->'dinero'->>'servicio_usd')::numeric), 0) from locs), 0.005
  union all select '109', 'G9 Σ perdido (consumo) por local = perdido',
    (select perdido_f from r), (select coalesce(sum((j->'dinero'->'perdido'->>'financed_usd')::numeric), 0) from locs), 0.005
  union all select '110', 'G10 Σ cargos por local + cargos sin local = cargos',
    (select cargos from r),
    (select coalesce(sum((j->'dinero'->'cargos_por_atraso'->>'devengado_usd')::numeric), 0) from locs)
      + (select coalesce(sum(amount_usd), 0) from ma where merchant_id is null), 0.005
  union all select '111', 'G11 Σ por pagar por local = por pagar a locales',
    (select por_pagar from r), (select coalesce(sum((j->'dinero'->'por_pagar_locales'->>'total_usd')::numeric), 0) from locs), 0.005
  union all select '112', 'G12 Σ consumo de la curva de cada local = consumo',
    (select consumo from r),
    (select coalesce(sum((s->>'financed_usd')::numeric), 0) from locs, jsonb_array_elements(locs.j->'curva') s), 0.005
),
-- Las comprobaciones de cada local: (clave, qué, local, esperado, obtenido, tolerancia).
pl(clave, titulo, entidad, e, o, tol) as (
  select 'L01', 'consumo = metricas.consumos del local', l.name,
         (select coalesce(sum(financed_usd), 0) from mc where merchant_id = l.id),
         (l.j->'consumo'->>'financed_usd')::numeric, 0.005::numeric from locs l
  union all select 'L02', 'personas = personas con cuota en el local', l.name,
         (select count(distinct user_id) from mq where merchant_id = l.id)::numeric,
         (l.j->'consumo'->>'personas')::numeric, 0 from locs l
  union all select 'L03', 'repiten = personas_por_local con 2 noches o más', l.name,
         (select count(*) from mppl where merchant_id = l.id and noches >= 2)::numeric,
         (l.j->'gente'->>'repiten')::numeric, 0 from locs l
  union all select 'L04', 'mora = metricas.cartera_al(hoy, local)', l.name,
         (select mora_pct from metricas.cartera_al(metricas.hoy(), l.id)),
         (l.j->'riesgo'->>'mora_pct')::numeric, 0.005 from locs l
  union all select 'L05', 'vencido = cartera_al del local', l.name,
         (select vencido_payable_usd from metricas.cartera_al(metricas.hoy(), l.id)),
         (l.j->'dinero'->'vencido'->>'payable_usd')::numeric, 0.005 from locs l
  union all select 'L06', 'impago = consumo perdido ÷ consumo del local', l.name,
         (select round(100 * coalesce(sum(financed_usd) filter (where estado_hoy = 'perdida'), 0)
                   / nullif(sum(financed_usd), 0), 2) from mq where merchant_id = l.id),
         (l.j->'riesgo'->>'impago_pct')::numeric, 0.005 from locs l
  union all select 'L07', 'por pagar = Pagos a locales del local', l.name,
         (select coalesce(sum(total), 0) from pag where merchant_id = l.id),
         (l.j->'dinero'->'por_pagar_locales'->>'total_usd')::numeric, 0.005 from locs l
  union all select 'L08', 'consumo acumulado al final de la curva = consumo', l.name,
         (l.j->'consumo'->>'financed_usd')::numeric,
         coalesce((select (s->>'financed_acum_usd')::numeric from jsonb_array_elements(l.j->'curva') s
                    order by (s->>'semana')::date desc limit 1), 0), 0.005 from locs l
  union all select 'L09', 'lo que no se parte viene nulo (1 = sí)', l.name, 1::numeric,
         case when (l.j->'gente'->'registros') = 'null'::jsonb
               and (l.j->'gente'->'verificados') = 'null'::jsonb
               and (l.j->'gente'->'solicitaron') = 'null'::jsonb
               and (l.j->'gente'->'telefono_confirmado') = 'null'::jsonb
               and (l.j->'gente'->'han_comprado') = 'null'::jsonb
               and (l.j->'gente'->'han_comprado_pct') = 'null'::jsonb
               and (l.j->'consumo'->'locales') = 'null'::jsonb
               and (l.j->'consumo'->'locales_activos') = 'null'::jsonb
               and (l.j->'dinero'->'caja_usd') = 'null'::jsonb
               and not exists (select 1 from jsonb_array_elements(l.j->'curva') s
                               where (s->'registros') <> 'null'::jsonb)
              then 1 else 0 end::numeric, 0 from locs l
  union all select 'L10', 'por cobrar: consumo + servicio e IVA = payable', l.name,
         (l.j->'dinero'->'por_cobrar'->>'payable_usd')::numeric,
         (l.j->'dinero'->'por_cobrar'->>'financed_usd')::numeric + (l.j->'dinero'->'por_cobrar'->>'fee_usd')::numeric,
         0.005 from locs l
),
salida(orden, comprobacion, esperado, obtenido, ok) as (
  select n.orden, n.comprobacion,
         coalesce(round(n.e, 2)::text, 'nulo'), coalesce(round(n.o, 2)::text, 'nulo'),
         coalesce(abs(n.e - n.o) <= n.tol, n.e is null and n.o is null)
  from n
  union all
  select '2' || p.clave, 'Por local: ' || p.titulo,
         count(*)::text || ' locales',
         (count(*) filter (where coalesce(abs(p.e - p.o) <= p.tol, p.e is null and p.o is null)))::text || ' cuadran',
         bool_and(coalesce(abs(p.e - p.o) <= p.tol, p.e is null and p.o is null))
  from pl p
  group by p.clave, p.titulo
  union all
  select '2' || p.clave || '.' || p.entidad, '   ' || p.entidad || ': ' || p.titulo,
         coalesce(round(p.e, 2)::text, 'nulo'), coalesce(round(p.o, 2)::text, 'nulo'), false
  from pl p
  where not coalesce(abs(p.e - p.o) <= p.tol, p.e is null and p.o is null)
)
select comprobacion, esperado, obtenido, ok
from salida
order by orden;
