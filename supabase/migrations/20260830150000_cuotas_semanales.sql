-- ============================================================================
-- Ronda — Las cuotas pasan a ser semanales: 7 y 14 días desde la compra
--
-- Decisión del 2026-08-30. El plazo se parte por la mitad:
--
--     cuota 1 = día operativo del consumo + 7 días      (antes: 14)
--     cuota 2 = día operativo del consumo + 14 días     (antes: 28)
--
--     compra 22-ago → 29-ago y 05-sep
--     compra 30-ago → 06-sep y 13-sep
--
-- ---------------------------------------------------------------------------
-- Qué cambia de verdad
-- ---------------------------------------------------------------------------
-- **El ciclo entero de un consumo baja de 28 días a 14.** Eso es la mitad de
-- tiempo con el dinero fuera: el colchón necesario para el mismo volumen
-- mensual cae casi a la mitad (docs/00-BASES §1.3), que es la restricción dura
-- del negocio. Y el cupo del usuario, que solo se libera al saldar el bloque
-- entero (§2.2), vuelve el doble de rápido.
--
-- **La frase también se parte por la mitad**: "lo pagas en dos, a los 7 días y
-- a los 14". Cae en el mismo día de la semana que la compra, que es más fácil
-- de recordar que una fecha suelta — quien sale un sábado paga los sábados.
--
-- ---------------------------------------------------------------------------
-- Lo que NO hay que tocar
-- ---------------------------------------------------------------------------
-- 1. **Las cuotas ya emitidas se quedan como están.** Quien compró con la regla
--    vieja conserva las fechas que se le prometieron en su acuse. Adelantarle
--    un vencimiento que ya vio es cambiarle el trato por detrás, y esta vez lo
--    adelantaría DOS SEMANAS.
-- 2. **La mora no se entera.** Compara `due_date` contra el día operativo, sin
--    preguntar de dónde salió esa fecha.
-- 3. **Los Bits tampoco.** El trigger premia pagar antes del vencimiento, sea
--    cual sea (docs/00-BASES §2.10). Con 7 días hay menos margen para
--    adelantarse, pero la regla es la misma.
-- 4. **La liquidación al comercio ya no cuelga de estas fechas**
--    (20260830140000): se devenga entera al vender.
--
-- Sigue siendo una función de una línea y no un número suelto por lo mismo de
-- siempre: es un parámetro de negocio, y hoy queda demostrado que cambia.
-- ============================================================================

/** Días entre una cuota y la siguiente, y entre el consumo y la primera. */
create or replace function public.helios_installment_interval_days()
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 7 $fn$;

comment on function public.helios_installment_interval_days() is
  'Días entre el consumo y la cuota 1, y entre la cuota 1 y la cuota 2. 7 desde 2026-08-30. Ver docs/00-BASES 2.2.';

revoke all on function public.helios_installment_interval_days() from public, anon;
grant execute on function public.helios_installment_interval_days() to authenticated;

-- `helios_installment_due_dates` no se toca: ya deriva las dos fechas del
-- intervalo, así que los seis caminos de cobro pasan a 7 y 14 a la vez. Solo se
-- corrige lo que promete su comentario, que decía 14 y 28.
comment on function public.helios_installment_due_dates(date) is
  'Vencimientos de cuota 1 y 2: 7 y 14 días después del día operativo del consumo. Ver docs/00-BASES 2.2.';
