-- ============================================================================
-- Ronda — Prueba de humo de los vencimientos de cuota
--
--   docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f supabase/tests/due_dates_smoke.sql
--
-- 🔁 REESCRITA DOS VECES, y la segunda por un cambio de una sola línea.
--
-- Hasta el 2026-08-27 las cuotas vencían en cortes fijos del mes con un colchón
-- mínimo de 7 días. `20260827050000` las pasó a 14 y 28 días desde el consumo, y
-- `20260830150000_cuotas_semanales` las parte por la mitad otra vez:
--
--     cuota 1 = día operativo del consumo + 7 días
--     cuota 2 = día operativo del consumo + 14 días
--
-- Los dos cambios cupieron en `helios_installment_interval_days()`, que es
-- exactamente el motivo por el que ese número vive en una función y no repartido
-- por los seis caminos de cobro. Aquí solo hubo que mover las cifras esperadas.
-- ============================================================================

begin;

do $$
declare
  v_bd   date;
  v_d1   date;
  v_d2   date;
  v_n    integer := 0;
begin
  -- --- 1. Casos concretos, incluidos los bordes de calendario -------------
  -- Fin de mes, febrero corto, febrero bisiesto y cruce de año: con una regla
  -- de "+7 y +14 días" ninguno necesita una rama especial, y eso es
  -- precisamente lo que hay que demostrar.
  for v_bd, v_d1, v_d2 in
    select * from (values
      ('2026-08-22'::date, '2026-08-29'::date, '2026-09-05'::date),
      ('2026-08-30'::date, '2026-09-06'::date, '2026-09-13'::date),
      ('2026-02-20'::date, '2026-02-27'::date, '2026-03-06'::date),
      ('2028-02-20'::date, '2028-02-27'::date, '2028-03-05'::date),
      ('2026-12-28'::date, '2027-01-04'::date, '2027-01-11'::date)
    ) as c(bd, d1, d2)
  loop
    if (select due_1 from public.helios_installment_due_dates(v_bd)) <> v_d1
       or (select due_2 from public.helios_installment_due_dates(v_bd)) <> v_d2 then
      raise exception 'Consumo del %: se esperaba % y %, salió % y %',
        v_bd, v_d1, v_d2,
        (select due_1 from public.helios_installment_due_dates(v_bd)),
        (select due_2 from public.helios_installment_due_dates(v_bd));
    end if;
  end loop;
  raise notice 'TEST CUOTAS 1 OK — 5 casos concretos, con fin de mes, bisiesto y cambio de año';

  -- --- 2. La invariante, sobre dos años completos -------------------------
  -- Un barrido en vez de más casos sueltos: lo que hay que garantizar no es
  -- una lista de fechas, es que la regla se cumpla TODOS los días del
  -- calendario sin excepción.
  for v_bd in select generate_series('2026-01-01'::date, '2027-12-31'::date, '1 day')::date loop
    select due_1, due_2 into v_d1, v_d2 from public.helios_installment_due_dates(v_bd);
    v_n := v_n + 1;

    if v_d1 is null or v_d2 is null then
      raise exception 'Consumo del %: la función no devolvió dos vencimientos (%, %)', v_bd, v_d1, v_d2;
    end if;
    if v_d1 - v_bd <> 7 then
      raise exception 'Consumo del %: la cuota 1 vence a % días, debían ser 7', v_bd, v_d1 - v_bd;
    end if;
    if v_d2 - v_bd <> 14 then
      raise exception 'Consumo del %: la cuota 2 vence a % días, debían ser 14', v_bd, v_d2 - v_bd;
    end if;
  end loop;

  raise notice 'TEST CUOTAS 2 OK — % días seguidos: siempre 7 y 14 días exactos', v_n;

  -- --- 3. Las dos cuotas caen en el MISMO día de la semana que la compra ---
  -- Es la propiedad que regala el plazo semanal, y la que hace que la regla se
  -- pueda explicar sin fechas: "pagas los sábados". Con 14 y 28 también se
  -- cumplía; con cualquier plazo que no sea múltiplo de 7, no.
  for v_bd in select generate_series('2026-01-01'::date, '2026-03-31'::date, '1 day')::date loop
    select due_1, due_2 into v_d1, v_d2 from public.helios_installment_due_dates(v_bd);
    if extract(dow from v_d1) <> extract(dow from v_bd)
       or extract(dow from v_d2) <> extract(dow from v_bd) then
      raise exception 'Consumo del % (%): las cuotas cayeron en % y %',
        v_bd, to_char(v_bd, 'Day'), to_char(v_d1, 'Day'), to_char(v_d2, 'Day');
    end if;
  end loop;
  raise notice 'TEST CUOTAS 3 OK — las dos cuotas caen siempre en el mismo día de la semana que la compra';

  -- --- 4. El día operativo empieza a medianoche (Helios, H2) -------------
  -- En Ronda corría de 10 AM a 10 AM y una compra de las 3 de la madrugada era
  -- de la noche anterior. En Helios es el día del calendario de Caracas: las
  -- 11 PM y las 3 AM son días distintos, y las 00:00 y las 9:59 son el mismo.
  if (select due_1 from public.helios_installment_due_dates(public.helios_business_date('2026-08-22 23:00-04'::timestamptz)))
     = (select due_1 from public.helios_installment_due_dates(public.helios_business_date('2026-08-23 03:00-04'::timestamptz))) then
    raise exception 'Una consulta de las 11 PM y otra de las 3 AM del día siguiente deben vencer en días distintos';
  end if;
  if (select due_1 from public.helios_installment_due_dates(public.helios_business_date('2026-08-23 00:00-04'::timestamptz)))
     <> (select due_1 from public.helios_installment_due_dates(public.helios_business_date('2026-08-23 09:59-04'::timestamptz))) then
    raise exception 'Las 00:00 y las 9:59 del mismo día deben vencer igual';
  end if;
  if (select due_1 from public.helios_installment_due_dates(public.helios_business_date('2026-08-23 03:00-04'::timestamptz))) <> '2026-08-30' then
    raise exception 'Una consulta del 23/08 a las 3 AM vence el 30/08';
  end if;
  raise notice 'TEST CUOTAS 4 OK — el día operativo empieza a medianoche';

  raise notice '=== TODOS LOS TESTS DE VENCIMIENTOS PASARON ===';
end $$;

rollback;
