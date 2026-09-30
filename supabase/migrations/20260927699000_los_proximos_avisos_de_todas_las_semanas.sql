-- ============================================================================
-- Ronda — Los próximos avisos de cuota, de todas las semanas
--
-- Reorganización aprobada por Javier (2026-09-28): «Próximos envíos» es
-- trabajo, no una métrica. Sale de Métricas › Cobros › Avisos y pasa a la
-- página de Recordatorios (Cobranza), junto a la configuración de la escalera.
-- Allí no hay semana de consumo elegida: se quiere ver lo que va a salir en
-- los próximos días a TODA la gente que sigue sin pagar.
--
-- admin_avisos_proximos(p_dias) lee la misma escalera que Métricas
-- (metricas.avisos_escalera) sobre las semanas de consumo que todavía pueden
-- tener avisos por salir, y devuelve lo mismo que la clave `proximos` de
-- admin_metricas_avisos (con la semana de consumo de cada envío), solo de
-- los envíos de las próximas p_dias × 24 h.
--
-- Hasta dónde mira atrás: la cuota 2 vence como mucho a las ~4 semanas del
-- consumo y el último peldaño sale una semana después de vencer; diez
-- semanas sobran. admin_metricas_avisos no cambia (su `proximos` se queda:
-- lo leen las baterías).
-- ============================================================================

create or replace function public.admin_avisos_proximos(p_dias integer default 7)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_hoy    date := metricas.hoy();
  v_dias   integer := least(greatest(coalesce(p_dias, 7), 1), 31);
  v_hasta  timestamptz := now() + make_interval(days => least(greatest(coalesce(p_dias, 7), 1), 31));
  v_res    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  with
  e as materialized (
    select *
    from metricas.avisos_escalera(metricas.lunes(v_hoy) - 70, metricas.lunes(v_hoy), null)
    where sale_en > now()
      and sale_en <= v_hasta
      and aviso_id is null
  ),
  proximo as (
    select
      e.sale_en, e.clave, e.sequence, e.due_date,
      min(e.rotulo) as rotulo, min(e.orden) as orden, min(e.desfase) as desfase, min(e.hora) as hora,
      count(*) filter (where e.situacion = 'programada')  as personas,
      count(*) filter (where e.situacion = 'no_saldra')   as no_saldra,
      count(*) filter (where e.situacion = 'en_revision') as en_revision
    from e
    group by e.sale_en, e.clave, e.sequence, e.due_date
    having count(*) filter (where e.situacion in ('programada', 'no_saldra', 'en_revision')) > 0
  )
  select jsonb_build_object(
    'hoy',   v_hoy,
    'ahora', now(),
    'dias',  v_dias,
    'hasta', v_hasta,
    'proximos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'sale_en',     x.sale_en,
               'dia',         (x.sale_en at time zone 'America/Caracas')::date,
               'hora',        to_char(x.hora, 'HH24:MI'),
               'clave',       x.clave,
               'rotulo',      x.rotulo,
               'desfase',     x.desfase,
               'cuota',       x.sequence,
               'vence',       x.due_date,
               'personas',    x.personas,
               'no_saldra',   x.no_saldra,
               'en_revision', x.en_revision
             ) order by x.sale_en, x.orden, x.sequence), '[]'::jsonb)
      from proximo x
    )
  )
  into v_res;

  return v_res;
end;
$fn$;

comment on function public.admin_avisos_proximos(integer) is
  'Los avisos de cuota que el motor va a mandar en los próximos p_dias días (1 a 31, 7 por defecto) a toda la gente que sigue sin pagar, de cualquier semana de consumo: por hora de salida, peldaño, cuota y vencimiento, con cuántos usuarios lo recibirán (personas), a cuántos no les saldrá porque el peldaño está apagado (no_saldra) y cuántos tienen un pago en revisión (en_revision). La misma escalera que Métricas › Cobros › Avisos (metricas.avisos_escalera). Solo personal de Helios.';

revoke all on function public.admin_avisos_proximos(integer) from public, anon;
grant execute on function public.admin_avisos_proximos(integer) to authenticated;
