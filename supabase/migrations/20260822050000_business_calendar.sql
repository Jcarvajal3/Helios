-- ============================================================================
-- Ronda — Calendario operativo y regla de corte de ciclo
--
-- Decisión confirmada 2026-08-22 (docs/00-BASES-DEL-NEGOCIO.md §2.2,
-- docs/06-REGLAS-OPERATIVAS.md §1): el día operativo corre de 10:00 AM a
-- 10:00 AM America/Caracas. Un consumo del día 15 a las 3 AM pertenece al
-- día operativo 14 — la misma noche en que salió el usuario.
--
-- Ninguna fecha de negocio (vencimientos, cortes, moras) se calcula con
-- date_trunc('day', ...) ni CURRENT_DATE. Todo pasa por estas dos funciones.
-- ============================================================================

-- Día operativo de un instante dado.
create or replace function public.helios_business_date(p_ts timestamptz)
returns date
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select (p_ts at time zone 'America/Caracas' - interval '10 hours')::date;
$$;

comment on function public.helios_business_date(timestamptz) is
  'Día operativo Helios (10 AM a 10 AM America/Caracas). Toda fecha de negocio pasa por aquí.';

revoke all on function public.helios_business_date(timestamptz) from public, anon;
grant execute on function public.helios_business_date(timestamptz) to authenticated;

-- Fechas de vencimiento de las dos cuotas para un consumo con el día
-- operativo dado. Regla (docs/00-BASES §2.2):
--
--   día operativo 1–15   → cuota 1: último día del mes en curso
--                          cuota 2: día 15 del mes siguiente
--   día operativo 16–fin → cuota 1: día 15 del mes siguiente
--                          cuota 2: último día del mes siguiente
create or replace function public.helios_installment_due_dates(p_business_date date)
returns table (due_1 date, due_2 date)
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select
    case when extract(day from p_business_date) <= 15
      then (date_trunc('month', p_business_date) + interval '1 month' - interval '1 day')::date
      else (date_trunc('month', p_business_date) + interval '1 month' + interval '14 days')::date
    end,
    case when extract(day from p_business_date) <= 15
      then (date_trunc('month', p_business_date) + interval '1 month' + interval '14 days')::date
      else (date_trunc('month', p_business_date) + interval '2 months' - interval '1 day')::date
    end;
$$;

comment on function public.helios_installment_due_dates(date) is
  'Vencimientos de cuota 1 y 2 para un consumo del día operativo dado. Ver docs/00-BASES §2.2.';

revoke all on function public.helios_installment_due_dates(date) from public, anon;
grant execute on function public.helios_installment_due_dates(date) to authenticated;
