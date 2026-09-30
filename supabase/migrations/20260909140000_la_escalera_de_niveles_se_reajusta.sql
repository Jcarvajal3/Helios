-- ============================================================================
-- Ronda — La escalera se reajusta: 30 / 50 / 80 / 100, y el nivel 4 abre
--
-- Decisión del 2026-09-09, la misma semana en que el ancla pasó a ser el euro
-- (`20260909100000_el_precio_se_pacta_en_euros.sql`). Aquello cambió de qué
-- eran las cifras; esto cambia las cifras.
--
--   Nivel 1 · €50  → **€30**
--   Nivel 2 · €100 → **€50**
--   Nivel 3 · €150 → **€80**
--   Nivel 4 · —    → **€100**, y deja de ser "próximamente"
--   Nivel 5 · sigue en "próximamente"
--
-- **Por qué bajan los tres primeros.** La escalera vieja empezaba en el 60 %
-- del techo (€50 de €150) y se acababa en tres escalones: se subía poco y se
-- llegaba pronto. La nueva empieza en el 30 % (€30 de €100) y tiene cuatro
-- peldaños, así que cada ascenso se nota y hay a dónde seguir subiendo.
--
-- **Los requisitos bajan con los límites.** El 2026-08-30, cuando el nivel 3
-- bajó de €200 a €150, se decidió lo contrario —"cambia lo que da el nivel, no
-- lo que cuesta"— porque era un ajuste de un solo escalón. Aquí se mueve la
-- escalera entera y hacia abajo: dejar €600 pagados como precio de un cupo de
-- €80 sería pedir siete veces el cupo para conseguirlo. Los requisitos se
-- recortan al mismo ritmo que los límites (×0,6):
--
--   Nivel 2 · €200 pagados → **€120**, sigue 1 mes de antigüedad
--   Nivel 3 · €600 pagados → **€360**, siguen 2 meses
--   Nivel 4 · **€800 pagados + 3 meses** (nuevo)
--
-- El salto al 4 es deliberadamente el más largo de la escalera: es el techo, y
-- se llega después de haber pagado diez veces el cupo del nivel 1.
--
-- **Qué le pasa a quien ya está arriba.** Nada que se le reclame. Igual que en
-- la bajada del nivel 3, el límite acota lo que se puede tomar de NUEVO, no lo
-- que ya se tomó: `charged_usd` no está acotado por el límite, así que quien
-- esté en nivel 3 debiendo €120 se queda con disponible 0 hasta bajar de €80.
-- No se recalcula ninguna deuda ni se cancela ningún plan de cuotas.
--
-- **Y quien ya cumplía de sobra.** Al bajar los requisitos, gente que hoy está
-- en nivel 1 o 2 pasa a cumplir el 3 —o el 4— y el motor la sube en la corrida
-- de las 10:20 (`process_level_promotions`). Es el efecto buscado: los
-- requisitos nuevos son los que valen para todo el mundo, no solo para quien
-- se registre a partir de hoy. `evaluate_level` ya salta varios escalones de
-- una vez, porque los requisitos son crecientes y cumplir el 4 implica cumplir
-- el 3.
--
-- No se toca ninguna función: los límites y los requisitos nunca estuvieron
-- hardcodeados —todo lee `public.levels`— y `max(level) where is_active` ya
-- hacía que el techo fuese el que dijera la tabla. Abrir el nivel 4 es una
-- fila, no un despliegue.
-- ============================================================================

update public.levels
set monthly_limit_usd  = 30.0000,
    required_spend_usd = 0.0000,
    required_months    = 0,
    is_active          = true,
    updated_at         = now()
where level = 1;

update public.levels
set monthly_limit_usd  = 50.0000,
    required_spend_usd = 120.0000,
    required_months    = 1,
    is_active          = true,
    updated_at         = now()
where level = 2;

update public.levels
set monthly_limit_usd  = 80.0000,
    required_spend_usd = 360.0000,
    required_months    = 2,
    is_active          = true,
    updated_at         = now()
where level = 3;

update public.levels
set monthly_limit_usd  = 100.0000,
    required_spend_usd = 800.0000,
    required_months    = 3,
    is_active          = true,
    updated_at         = now()
where level = 4;

-- El 5 se queda como estaba: existe en el esquema, sale como "próximamente" en
-- la app y no tiene reglas todavía. Se deja explícito para que una lectura de
-- esta migración no tenga que ir a buscar si se olvidó.
update public.levels
set is_active = false,
    updated_at = now()
where level = 5;

-- Guardarraíl: la app pinta la escalera desde esta tabla y un nivel activo con
-- límite cero daría un ascenso a un cupo de cero. Es el mismo error que
-- `admin_set_level_config` impide a mano; aquí se comprueba que la migración
-- no lo haya cometido.
do $$
declare
  v_bad integer;
begin
  select count(*) into v_bad
  from public.levels
  where is_active and monthly_limit_usd <= 0;

  if v_bad > 0 then
    raise exception 'La escalera quedó con % nivel(es) activo(s) sin límite', v_bad;
  end if;
end;
$$;
