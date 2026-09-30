-- La insignia de Riesgo solo cuenta.
--
-- El menú del super admin pinta cuántas alertas de riesgo quedan sin revisar, y
-- para eso pedía admin_risk_alerts con 500 filas cada minuto, en cada pestaña
-- abierta. Esta función devuelve solo los tres números.
--
-- No copia la lógica de las alertas: llama a admin_risk_alerts y suma sus
-- contadores (counts, que ya ignora el filtro de tipos y viene con los cinco),
-- pidiéndole una sola fila. Así el criterio es el mismo por construcción, y
-- una alerta nueva en admin_risk_alerts llega a la insignia sin tocar nada.

create or replace function public.admin_risk_alert_counts()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_counts jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_counts := public.admin_risk_alerts(1, null) -> 'counts';

  return (
    select jsonb_build_object(
      'pendientes_alta',  coalesce(sum((c.value ->> 'unreviewed_high')::integer), 0),
      'pendientes_media', coalesce(sum((c.value ->> 'unreviewed')::integer
                                     - (c.value ->> 'unreviewed_high')::integer), 0),
      'revisadas',        coalesce(sum((c.value ->> 'total')::integer
                                     - (c.value ->> 'unreviewed')::integer), 0)
    )
    from jsonb_each(coalesce(v_counts, '{}'::jsonb)) c
  );
end;
$$;

comment on function public.admin_risk_alert_counts() is
  'Los contadores de la insignia de Riesgo: alertas sin revisar graves y medias, y revisadas. Sale de admin_risk_alerts (mismo criterio, sin cuentas de prueba), sin devolver filas.';

revoke all on function public.admin_risk_alert_counts() from public, anon;
grant execute on function public.admin_risk_alert_counts() to authenticated, service_role;
