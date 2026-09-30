-- ============================================================================
-- Ronda — La cuota 1 vence en el PRÓXIMO corte, con un colchón mínimo
--
-- Cambia la regla confirmada el 2026-08-22 (docs/00-BASES §2.2). La anterior
-- se saltaba siempre el corte inmediato:
--
--     consumo día 1–15   → cuota 1: último día del mes    (15 a 30 días)
--     consumo día 16–fin → cuota 1: día 15 del siguiente  (15 a 30 días)
--
-- El efecto que la hizo insostenible: una compra del 22 de agosto no vencía
-- nada hasta el 15 de septiembre, saltándose el corte del 31 de agosto. El
-- usuario ve pasar un ciclo entero de facturación sin que le toque pagar, y
-- Ronda financia esa compra 24 días de más — con el 30% ya adelantado al
-- comercio el mismo día de la venta (docs/05 §3). Es caja parada.
--
-- Regla nueva:
--
--     cuota 1 = el primer corte (día 15 o último día del mes) que caiga al
--               menos `helios_min_float_days()` días después del día operativo
--     cuota 2 = el corte siguiente a ese
--
--     compra 22-ago → 31-ago y 15-sep     ← el caso que motivó el cambio
--     compra 14-ago → 31-ago y 15-sep
--     compra  8-ago → 15-ago y 31-ago
--     compra 30-ago → 15-sep y 30-sep
--
-- POR QUÉ EL COLCHÓN Y NO "EL PRÓXIMO CORTE" A SECAS. Sin él, una compra del
-- día 14 vencería el 15: un día para pagar. El plazo quedaría entre 1 y 15
-- días según el capricho de la fecha de compra, y el usuario no tendría forma
-- de anticiparlo antes de consumir. Con el colchón, todo el mundo tiene como
-- mínimo una semana, siempre, y el plazo máximo baja de 30 a 22 días.
--
-- El colchón es una función y no una constante en línea porque es un
-- parámetro de negocio: subirlo a 10 días es un `create or replace` de una
-- línea, no reescribir el cálculo.
-- ============================================================================

/** Días mínimos entre el consumo y su primera cuota. Ver cabecera. */
create or replace function public.helios_min_float_days()
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 7 $fn$;

comment on function public.helios_min_float_days() is
  'Colchón mínimo, en días, entre el día operativo del consumo y su primera cuota.';

revoke all on function public.helios_min_float_days() from public, anon;
grant execute on function public.helios_min_float_days() to authenticated;

-- ---------------------------------------------------------------------------

create or replace function public.helios_installment_due_dates(p_business_date date)
returns table (due_1 date, due_2 date)
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$
  -- Se generan los cortes de seis meses y se cogen los dos primeros que pasen
  -- el colchón. Enumerar en vez de calcular con `case` sobre el día del mes
  -- es lo que hace que "último día del mes" salga bien en febrero y en los
  -- meses de 30 sin ninguna rama especial.
  --
  -- Seis meses son doce cortes: sobra para cualquier colchón por debajo de
  -- ~150 días. Si algún día se sube más allá, esto devolvería null y
  -- `confirm_charge` fallaría al insertar la cuota — ruidoso, que es como
  -- tiene que fallar.
  --
  -- El cast a `timestamp` (sin zona) no es decorativo: con un `date` a secas,
  -- `date_trunc` resuelve a la variante `timestamptz`, que es STABLE y
  -- depende del TimeZone de la sesión. Esta función se declara IMMUTABLE, así
  -- que tiene que serlo de verdad.
  select
    (array_agg(c.cut order by c.cut))[1],
    (array_agg(c.cut order by c.cut))[2]
  from (
    -- El día 15 de cada mes.
    select (date_trunc('month', p_business_date::timestamp) + make_interval(months => n) + interval '14 days')::date as cut
    from generate_series(0, 5) as n
    union all
    -- El último día de cada mes: el 1 del siguiente menos un día.
    select (date_trunc('month', p_business_date::timestamp) + make_interval(months => n + 1) - interval '1 day')::date
    from generate_series(0, 5) as n
  ) c
  where c.cut >= p_business_date + public.helios_min_float_days();
$fn$;

comment on function public.helios_installment_due_dates(date) is
  'Vencimientos de cuota 1 y 2: los dos primeros cortes (15 y último día del mes) que caen al menos helios_min_float_days() días después del consumo. Ver docs/00-BASES §2.2.';

revoke all on function public.helios_installment_due_dates(date) from public, anon;
grant execute on function public.helios_installment_due_dates(date) to authenticated;

-- ---------------------------------------------------------------------------
-- Recolocar las cuotas ya generadas con la regla vieja
-- ---------------------------------------------------------------------------
-- Esto SOLO es aceptable ahora, antes del piloto: las filas que hay son de
-- prueba y no hay nadie a quien se le haya comunicado una fecha. Mover el
-- vencimiento de una deuda real hacia adelante en el tiempo es cambiarle el
-- contrato al usuario por la puerta de atrás. Si esta regla vuelve a tocarse
-- con usuarios de verdad dentro, lo correcto es que la fecha nueva rija solo
-- para los consumos nuevos.
--
-- Las tres guardas que lo hacen seguro incluso ahora:
--   · solo cuotas `pending` — una cuota pagada ya no tiene fecha que discutir;
--   · solo cobros `confirmed` — los anulados no se tocan;
--   · nunca se mueve una fecha al pasado ni se adelanta a algo ya vencido,
--     que sería fabricar una mora que nunca existió.

do $$
declare
  v_today date := public.helios_business_date(now());
  v_moved integer := 0;
begin
  with recalculated as (
    select
      i.id,
      case i.sequence when 1 then d.due_1 else d.due_2 end as new_due
    from public.installments i
    join public.charges c on c.id = i.charge_id
    cross join lateral public.helios_installment_due_dates(c.business_date) d
    where i.status = 'pending'
      and c.status = 'confirmed'
      and c.business_date is not null
  )
  update public.installments i
     set due_date = r.new_due
    from recalculated r
   where i.id = r.id
     and i.due_date <> r.new_due
     -- Ni la fecha vieja ni la nueva pueden estar ya vencidas.
     and i.due_date > v_today
     and r.new_due  > v_today;

  get diagnostics v_moved = row_count;
  raise notice 'Cuotas recolocadas con la regla nueva: %', v_moved;
end;
$$;
