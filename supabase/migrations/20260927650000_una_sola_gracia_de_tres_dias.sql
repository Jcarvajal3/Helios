-- ============================================================================
-- Ronda — Una sola gracia: la del cargo por atraso
--
-- Javier (27-09): «pagada a tiempo» y «cuota sin pagar tras la gracia» usan
-- los mismos días: «deben ser el mismo, déjalo en 3 días». Hasta hoy había
-- dos parámetros para una sola idea:
--
--   * `on_time_grace_days` (2): «a tiempo» (metricas.cuotas_al y
--     metricas.a_tiempo), el padrón (admin_user_directory) y la proyección de
--     caja (helios_cash_forecast).
--   * `late_fee_grace_days` (3): el cargo por atraso del motor de mora, el
--     impago de cada cuota (admin_first_payment_default) y los tramos.
--
-- Con dos gracias, una cuota pagada el día +3 era «tarde» en el cobro a tiempo
-- y «pagada en la gracia» en el impago por cuota: las dos cifras no sumaban.
--
-- Queda UNA definición: helios_on_time_grace_days() devuelve la gracia del
-- cargo por atraso. Conserva su nombre y su firma porque la leen las
-- funciones de arriba; ninguna del producto (la app, el motor de mora, los
-- avisos) la usa, así que para la gente nada cambia. Cambiar la gracia es
-- cambiar `late_fee_grace_days` en Ajustes › Parámetros, y eso mueve el cargo,
-- «a tiempo» y el impago a la vez.
--
-- El parámetro `on_time_grace_days` se queda en business_parameters con su
-- historia (esa tabla no se reescribe), pero ya nadie lo lee: su rótulo del
-- catálogo lo dice, para el asistente y para cualquier lectura de la base, y
-- el panel deja de enseñarlo en Ajustes.
--
-- Efecto el 27-09 (medido antes de aplicar, solo lectura):
--   * dev: 19 cuotas pagadas el día +3 pasan de «tarde» a «a tiempo» (11 de la
--     cuota 1 y 8 de la 2) y 17 vuelven a tener el plazo abierto un día más.
--     El cobro a tiempo sobre plazos cerrados pasa del 77,2 % al 80,3 %.
--   * prod: ninguna. Ninguna cuota tiene todavía el plazo cerrado (la primera
--     venció el 26-09); el primer veredicto llega el 30-09 en vez del 29-09.
-- ============================================================================

create or replace function public.helios_on_time_grace_days()
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$ select public.helios_late_fee_grace_days() $fn$;

comment on function public.helios_on_time_grace_days() is
  'Dias despues del vencimiento que siguen contando como "a tiempo". Desde 2026-09-27 es la MISMA gracia que la del cargo por atraso (helios_late_fee_grace_days, parametro late_fee_grace_days): una sola gracia para «a tiempo», el impago de cada cuota y el cargo. El parametro on_time_grace_days ya no se lee.';

revoke all on function public.helios_on_time_grace_days() from public, anon;
grant execute on function public.helios_on_time_grace_days() to authenticated;

-- El catálogo dice lo mismo que el código. El panel ya pinta estos rótulos
-- aunque la base no esté migrada (parametrosPantalla.ts).
update public.business_parameter_catalog
   set label = 'Días de gracia'
 where key = 'late_fee_grace_days';

update public.business_parameter_catalog
   set label = 'Sin uso: «a tiempo» usa los días de gracia'
 where key = 'on_time_grace_days';
