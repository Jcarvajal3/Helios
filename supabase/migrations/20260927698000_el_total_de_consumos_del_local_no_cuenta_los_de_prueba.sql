-- ============================================================================
-- Ronda — El total de consumos de un local no cuenta los de prueba
--
-- AUD-OPERACION (27-09), E6. En Directorio › Locales, la columna «Facturado
-- (sin fee, 30 días)» lleva debajo «N consumos · M desde el alta». Los dos
-- primeros números (`sales_30d`, `financed_30d`) dejan fuera los consumos de
-- prueba; el tercero (`sales_count`) no, así que un consumo de prueba
-- confirmado sumaba en «desde el alta» y no en los 30 días. En dev no hay
-- consumos de prueba confirmados y hoy no se nota (Terraza Semilla 147,
-- Bar Nocturno 64, Galpón Semilla 106 = metricas.consumos).
--
-- Solo cambia el filtro de `sales_count`: `and not c.is_test`. Mismas
-- columnas, en el mismo orden y del mismo tipo, así que basta con `create or
-- replace view` (conserva los permisos). Copiada de la versión viva en dev,
-- que es la de 20260925130000 (la última que la define), con
-- `security_invoker` como estaba.
-- ============================================================================

create or replace view public.merchant_directory
with (security_invoker = true)
as
select
  m.id,
  m.name,
  m.legal_name,
  m.tax_id,
  m.status,
  m.created_at,
  (select count(*) from public.merchant_users mu
     where mu.merchant_id = m.id and mu.is_active) as staff_count,
  -- Desde el alta, con el mismo filtro que los 30 días: sin los de prueba.
  (select count(*) from public.charges c
     where c.merchant_id = m.id and c.status = 'confirmed' and not c.is_test) as sales_count,
  m.category,
  m.city,
  m.handle,
  m.logo_url,
  m.social_url,
  m.is_test,
  -- Los últimos 30 días operativos. Un local que vendió mucho en agosto y nada
  -- desde entonces no puede leerse igual que uno que está funcionando.
  (select count(*) from public.charges c
     where c.merchant_id = m.id and c.status = 'confirmed' and not c.is_test
       and c.business_date > public.helios_business_date(now()) - 30) as sales_30d,
  -- Consumo, sin el servicio de Ronda.
  (select coalesce(sum(coalesce(c.base_usd, c.amount_usd)), 0) from public.charges c
     where c.merchant_id = m.id and c.status = 'confirmed' and not c.is_test
       and c.business_date > public.helios_business_date(now()) - 30) as financed_30d
from public.merchants m;

grant select on public.merchant_directory to authenticated;
