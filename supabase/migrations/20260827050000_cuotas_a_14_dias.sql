-- ============================================================================
-- Ronda — Las cuotas dejan de vencer en cortes fijos: 14 y 28 días desde la compra
--
-- Decisión del 2026-08-27. Hasta aquí las cuotas caían en los **cortes del
-- mes** —día 15 y último día— y la fecha de compra solo decidía en cuál de
-- ellos caías:
--
--     cuota 1 = primer corte que caiga al menos 7 días después del consumo
--     cuota 2 = el corte siguiente
--
-- A partir de aquí el calendario lo pone la compra:
--
--     cuota 1 = día operativo del consumo + 14 días
--     cuota 2 = día operativo del consumo + 28 días
--
--     compra 22-ago → 05-sep y 19-sep
--     compra 14-ago → 28-ago y 11-sep
--     compra  8-ago → 22-ago y 05-sep
--     compra 30-ago → 13-sep y 27-sep
--
-- ---------------------------------------------------------------------------
-- Qué se gana
-- ---------------------------------------------------------------------------
-- **El plazo deja de depender del capricho de la fecha.** Con los cortes, dos
-- personas que consumían con un día de diferencia podían tener 7 días y 22
-- para pagar lo mismo. Todo el andamiaje del colchón mínimo
-- (`helios_min_float_days`) existía para tapar ese hueco, y aun así el plazo
-- seguía siendo un rango. Ahora son 14 días para todo el mundo, siempre, y se
-- puede decir en la pantalla de confirmación antes de comprar.
--
-- **Y se puede explicar en una frase.** "Lo pagas en dos: a los 14 días y a
-- los 28." La regla anterior necesitaba un párrafo y un ejemplo.
--
-- ---------------------------------------------------------------------------
-- Lo que hay que tener presente
-- ---------------------------------------------------------------------------
-- 1. **Al comercio se le liquida por fecha de cuota** (docs/00 §2.5), así que
--    los pagos dejan de caer dos veces al mes y pasan a gotear todos los días.
--    El importe mensual no cambia; el calendario sí. `settle_scheduled` ya
--    trabaja por fecha (`where i.due_date = p_business_date`) y el cron corre
--    a diario, así que no hay nada que tocar — pero el comercio lo va a notar.
-- 2. **Las cuotas ya emitidas NO se tocan.** Quien compró con la regla vieja
--    conserva las fechas que se le prometieron en su acuse. Mover una fecha de
--    vencimiento que alguien ya vio es cambiarle el trato por detrás.
-- 3. La mora no necesita cambios: compara `due_date` contra el día operativo,
--    sin saber de dónde salió esa fecha.
--
-- El intervalo es una función y no un número suelto por lo mismo que lo era el
-- colchón: es un parámetro de negocio. Pasar a 15 días es un `create or
-- replace` de una línea.
-- ============================================================================

/** Días entre una cuota y la siguiente, y entre el consumo y la primera. */
create or replace function public.helios_installment_interval_days()
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 14 $fn$;

comment on function public.helios_installment_interval_days() is
  'Días entre el consumo y la cuota 1, y entre la cuota 1 y la cuota 2. Ver docs/00-BASES §2.2.';

revoke all on function public.helios_installment_interval_days() from public, anon;
grant execute on function public.helios_installment_interval_days() to authenticated;

-- ---------------------------------------------------------------------------

/**
 * Vencimientos de las dos cuotas de un consumo.
 *
 * Se mantiene la firma —devuelve `(due_1, due_2)` a partir del día operativo—
 * porque la llaman los seis caminos de cobro que existen. Cambiando solo el
 * cuerpo, todos pasan a la regla nueva a la vez y ninguno puede quedarse con
 * la vieja.
 *
 * Sigue siendo IMMUTABLE, y ahora de verdad sin esfuerzo: sumar días a un
 * `date` no mira ni el reloj ni la zona de la sesión. La versión anterior
 * tenía que castear a `timestamp` a mano para que `date_trunc` no resolviera a
 * la variante con zona, que es STABLE.
 */
create or replace function public.helios_installment_due_dates(p_business_date date)
returns table (due_1 date, due_2 date)
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$
  select
    p_business_date + public.helios_installment_interval_days(),
    p_business_date + public.helios_installment_interval_days() * 2;
$fn$;

comment on function public.helios_installment_due_dates(date) is
  'Vencimientos de cuota 1 y 2: 14 y 28 días después del día operativo del consumo. Ver docs/00-BASES §2.2.';

revoke all on function public.helios_installment_due_dates(date) from public, anon;
grant execute on function public.helios_installment_due_dates(date) to authenticated;

-- ---------------------------------------------------------------------------
-- El colchón se retira
-- ---------------------------------------------------------------------------
-- `helios_min_float_days()` existía para que la cuota 1 nunca cayera a un día
-- vista cuando el corte estaba encima. Con un plazo fijo de 14 días el suelo
-- ES el plazo, así que la función se queda sin nada que hacer.
--
-- Se borra en vez de dejarla devolviendo un número que ya no lee nadie: una
-- función de negocio viva que no se llama es una trampa para el siguiente que
-- lea el esquema y crea que el colchón sigue existiendo.
drop function if exists public.helios_min_float_days();
