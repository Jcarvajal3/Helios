-- ============================================================================
-- Helios — Métricas › Juan Pablo
--
-- Javier (2026-10-23): una pestaña nueva de Métricas, la primera, con las
-- cifras que mira Juan Pablo, para el periodo que se elija (un día, una
-- semana, un mes o un rango propio; por defecto, hoy):
--
--   órdenes        los pagos en cuotas confirmados del periodo
--   gtv_usd        lo que suman sus consultas, sin la comisión
--   revenue_usd    la Comisión Helios (el 12% de `consumer_fee_pct`), sin el
--                  IVA, que no es ingreso
--   médicos        los afiliados al cierre del periodo y cuántos de ellos
--                  generaron al menos una orden
--   por_medico     cada médico con órdenes y su parte de las del periodo
--                  (5 de 20 órdenes = 25%)
--
-- Las órdenes salen de `metricas.consumos`, las mismas que cuentan Semana y
-- Global: confirmadas, sin las de prueba, por su día operativo. Un médico es
-- una clínica (`merchants`, con su titular: `helios_doctor_name`).
-- «Afiliado» es lo que dice la Agenda desde el 20261023140000: activa, no de
-- prueba, dada de alta antes del cierre y con sus accesos
-- (`helios_clinica_tiene_accesos`). Un médico con órdenes en el periodo
-- cuenta siempre, aunque hoy ya no esté activo: así el porcentaje nunca pasa
-- del 100%.
-- ============================================================================

create or replace function public.admin_metricas_juan_pablo(p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy   date := metricas.hoy();
  v_hasta date;
  v_desde date;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- Sin fechas, hoy. Nunca después de hoy, y el «desde» nunca después del «hasta».
  v_hasta := least(coalesce(p_hasta, v_hoy), v_hoy);
  v_desde := least(coalesce(p_desde, v_hasta), v_hasta);

  return (
    with
    ordenes as (
      select k.merchant_id, k.financed_usd, k.servicio_usd
      from metricas.consumos k
      where k.business_date between v_desde and v_hasta
    ),
    por_medico as (
      select o.merchant_id,
             count(*)::integer      as ordenes,
             sum(o.financed_usd)    as gtv,
             sum(o.servicio_usd)    as revenue
      from ordenes o
      group by o.merchant_id
    ),
    total as (
      select count(*)::integer                  as ordenes,
             coalesce(sum(o.financed_usd), 0)   as gtv,
             coalesce(sum(o.servicio_usd), 0)   as revenue
      from ordenes o
    ),
    medicos as (
      select m.id
      from public.merchants m
      where not m.is_test
        and m.status = 'active'
        and public.helios_business_date(m.created_at) <= v_hasta
        and public.helios_clinica_tiene_accesos(m.id)
      union
      select pm.merchant_id from por_medico pm
    )
    select jsonb_build_object(
      'hoy',         v_hoy,
      'desde',       v_desde,
      'hasta',       v_hasta,
      'dias',        v_hasta - v_desde + 1,
      'ordenes',     t.ordenes,
      'gtv_usd',     t.gtv,
      'revenue_usd', t.revenue,
      'revenue_pct', round(100.0 * t.revenue / nullif(t.gtv, 0), 2),
      'ticket_medio_usd', round(t.gtv / nullif(t.ordenes, 0), 2),
      'medicos', jsonb_build_object(
        'afiliados',           (select count(*) from medicos)::integer,
        'con_ordenes',         (select count(*) from por_medico)::integer,
        'con_ordenes_pct',     round(100.0 * (select count(*) from por_medico)
                                       / nullif((select count(*) from medicos), 0), 2),
        -- Las órdenes entre los médicos que las generaron.
        'ordenes_por_medico',  round(t.ordenes::numeric / nullif((select count(*) from por_medico), 0), 2)
      ),
      'por_medico', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'merchant_id', pm.merchant_id,
                 'medico',      public.helios_doctor_name(pm.merchant_id),
                 'clinica',     m.name,
                 'ordenes',     pm.ordenes,
                 'pct',         round(100.0 * pm.ordenes / nullif(t.ordenes, 0), 2),
                 'gtv_usd',     pm.gtv,
                 'revenue_usd', pm.revenue
               ) order by pm.ordenes desc, pm.gtv desc, m.name)
        from por_medico pm
        join public.merchants m on m.id = pm.merchant_id
      ), '[]'::jsonb)
    )
    from total t
  );
end;
$$;

comment on function public.admin_metricas_juan_pablo(date, date) is
  'Métricas › Juan Pablo: órdenes, GTV, revenue (Comisión Helios sin IVA), médicos con órdenes y la parte de cada médico, del día operativo p_desde al p_hasta (por defecto, hoy).';

revoke all on function public.admin_metricas_juan_pablo(date, date) from public, anon;
grant execute on function public.admin_metricas_juan_pablo(date, date) to authenticated;
