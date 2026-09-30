-- Coherencia de la migración 20260927506000 (las métricas van rápido).
--
-- metricas.dia_operativo tiene que dar EXACTAMENTE lo mismo que
-- public.helios_business_date, y cuotas_al tiene que fechar cada pago con el
-- día operativo del REPORTE (o, sin reporte, el de la aprobación: migración
-- 20260927580000) y cada reporte con el suyo. Solo SELECT.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_rapidez.sql

with instantes as (
  select paid_at as ts from public.installments where paid_at is not null
  union all
  select created_at from public.payment_reports
  union all
  select created_at from public.charges
  union all
  -- Los bordes del día operativo, en invierno y en verano del hemisferio norte
  -- (Caracas no cambia de hora, pero el servidor no está en Caracas).
  select t from unnest(array[
    '2026-09-27 13:59:59+00', '2026-09-27 14:00:00+00',
    '2026-01-01 13:59:59+00', '2026-01-01 14:00:00+00',
    '2026-07-01 03:30:00+00'
  ]::timestamptz[]) as t
),
dias as (
  select count(*) as total,
         count(*) filter (where metricas.dia_operativo(ts) is distinct from public.helios_business_date(ts)) as distintos
  from instantes
),
cuotas as (
  select count(*) as total,
         count(*) filter (where q.status = 'paid' and q.pagada_dia is distinct from
           public.helios_business_date(coalesce(q.reportada_en, q.paid_at))) as pago_mal,
         count(*) filter (where q.status = 'paid' and q.reportada_en is not null
                            and q.reportada_dia is distinct from public.helios_business_date(q.reportada_en)) as reporte_mal
  from metricas.cuotas q
),
al_pasado as (
  select count(*) as total,
         count(*) filter (where q.status = 'paid' and q.pagada_dia is distinct from
           public.helios_business_date(coalesce(q.reportada_en, q.paid_at))) as pago_mal
  from metricas.cuotas_al(metricas.hoy() - 14) q
)
select 'dia_operativo = helios_business_date' as comprobacion, '0 distintos' as esperado,
       distintos || ' de ' || total as obtenido, distintos = 0 as ok
from dias
union all
select 'cuotas: el día del pago es el del reporte (o el de la aprobación sin reporte)', '0', pago_mal::text, pago_mal = 0 from cuotas
union all
select 'cuotas: día del reporte de siempre', '0', reporte_mal::text, reporte_mal = 0 from cuotas
union all
select 'cuotas_al(hace 14 días): el día del pago es el del reporte', '0', pago_mal::text, pago_mal = 0 from al_pasado
union all
select 'cuotas no vacía', '> 0', total::text, total > 0 from cuotas;
