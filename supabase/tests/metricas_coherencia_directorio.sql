-- ============================================================================
-- Batería de coherencia del Directorio (dev) — DIRECTORIO (aplicar AUD-OPERACION)
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok.
--   D1  Locales: «desde el alta» (merchant_directory.sales_count) = consumos
--       confirmados del local sin los de prueba = metricas.consumos
--       (20260927698000).
--   D2  Locales: «N consumos» y «Facturado (sin fee, 30 días)» de cada local
--       = metricas.consumos de los últimos 30 días operativos.
--   D3  La vista sigue siendo security_invoker (lee con los permisos de
--       quien consulta, como antes).
--   D4  Usuarios: el resumen de la página (usuarios con deuda vencida y lo
--       vencido, sin cuentas de prueba) = metricas.cuotas vencidas, con el
--       desglose sumando (20260927691000).
--   D5  Usuarios: nadie sale con días de atraso sin nada vencido (lo
--       perdido no cuenta como vencido).
-- Las de la deuda, el cobrado a tiempo y los consumos de cada usuario, y la
-- búsqueda de un consumo de grupo, están en metricas_coherencia_operacion.sql
-- (O3, O4 y O7).
-- Solo SELECT; se hace pasar por un admin activo.
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_directorio.sql
-- ============================================================================

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

with
dir as materialized (select * from public.merchant_directory),
canon as materialized (
  select k.merchant_id,
         count(*) as total,
         count(*) filter (where k.business_date > public.helios_business_date(now()) - 30) as n30,
         coalesce(sum(k.financed_usd) filter (where k.business_date > public.helios_business_date(now()) - 30), 0) as fin30
  from metricas.consumos k
  group by 1
),
directo as materialized (
  select c.merchant_id, count(*) as total
  from public.charges c
  where c.status = 'confirmed' and not c.is_test
  group by 1
),
paginas as materialized (
  -- El padrón entero, en páginas de 200, para no depender de su tamaño.
  select p.*
  from generate_series(0, (select count(*) from public.profiles)::int / 200) g(n)
  cross join lateral public.admin_user_directory(p_limit => 200, p_offset => g.n * 200) p
),
vencidas as materialized (
  select count(distinct user_id) as usuarios,
         coalesce(sum(payable_usd), 0) as payable,
         coalesce(sum(financed_usd), 0) as financed
  from metricas.cuotas where estado_hoy = 'vencida'
)
select 'D1' as comprobacion, '0 locales que no cuadran' as esperado,
       (select count(*) from dir d
          left join canon k on k.merchant_id = d.id
          left join directo x on x.merchant_id = d.id
         where d.sales_count <> coalesce(x.total, 0)
            or (not d.is_test and d.sales_count <> coalesce(k.total, 0)))::text || ' locales' as obtenido,
       (select count(*) from dir d
          left join canon k on k.merchant_id = d.id
          left join directo x on x.merchant_id = d.id
         where d.sales_count <> coalesce(x.total, 0)
            or (not d.is_test and d.sales_count <> coalesce(k.total, 0))) = 0 as ok
union all
select 'D2', '0 locales que no cuadran',
       (select count(*) from dir d left join canon k on k.merchant_id = d.id
         where not d.is_test and (d.sales_30d <> coalesce(k.n30, 0) or d.financed_30d <> coalesce(k.fin30, 0)))::text || ' locales',
       (select count(*) from dir d left join canon k on k.merchant_id = d.id
         where not d.is_test and (d.sales_30d <> coalesce(k.n30, 0) or d.financed_30d <> coalesce(k.fin30, 0))) = 0
union all
select 'D3', 'security_invoker=true',
       coalesce((select array_to_string(reloptions, ',') from pg_class where oid = 'public.merchant_directory'::regclass), 'sin opciones'),
       coalesce((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.merchant_directory'::regclass), false)
union all
select 'D4',
       (select usuarios || ' · ' || payable || ' = ' || financed || ' + ' || (payable - financed) from vencidas),
       (select count(*) || ' · ' || coalesce(sum(overdue_usd), 0) || ' = ' || coalesce(sum(overdue_financed_usd), 0)
               || ' + ' || coalesce(sum(overdue_fee_usd), 0)
          from paginas where not is_test and overdue_usd > 0),
       (select count(*) = (select usuarios from vencidas)
               and coalesce(sum(overdue_usd), 0) = (select payable from vencidas)
               and coalesce(sum(overdue_financed_usd), 0) = (select financed from vencidas)
               and coalesce(sum(overdue_fee_usd), 0) = (select payable - financed from vencidas)
          from paginas where not is_test and overdue_usd > 0)
union all
select 'D5', '0 usuarios',
       (select count(*) from paginas where days_overdue > 0 and overdue_usd = 0)::text || ' usuarios',
       (select count(*) from paginas where days_overdue > 0 and overdue_usd = 0) = 0;
