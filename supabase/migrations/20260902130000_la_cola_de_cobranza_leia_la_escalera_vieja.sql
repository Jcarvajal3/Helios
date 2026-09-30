-- ============================================================================
-- Ronda — La cola de cobranza se quedó cortando por 15 y 30
--
-- El 2026-08-30 la escalera de mora se alargó (20260830230000): la bajada de
-- nivel pasó de 15 a 30 días y la expulsión de 30 a 60. Esa migración cambió
-- los dos sitios que decidían de verdad —`recompute_profile_mora_state`, que
-- es el motor, y los tramos de `admin_overview`— pero `admin_collections` se
-- quedó fuera, con los umbrales viejos escritos a mano dentro del `case`.
--
-- Tres días después la cola de cobranza está mintiendo:
--
--   | Retraso | Lo que hace el motor | Lo que decía la cola |
--   |---------|----------------------|----------------------|
--   | 16 días | Congelado            | **Baja de nivel**    |
--   | 31 días | Baja de nivel        | **Expulsión**        |
--   | 61 días | Expulsión            | Expulsión            |
--
-- No es cosmético: quien llama trabaja esa lista de arriba abajo. El tramo
-- "Expulsión" es a quien hay que llamar HOY porque se le va la cuenta, y
-- llevaba tres días lleno de gente a la que aún le quedaba un mes. Los que de
-- verdad pasaron de 60 estaban ahí dentro, mezclados y sin forma de
-- distinguirlos.
--
-- Los umbrales pasan a salir de `helios_mora_demotion_days()` y
-- `helios_mora_expulsion_days()`, que es de donde los lee el motor. Es el
-- tercer sitio que se desincroniza por tener el número escrito a mano, y con
-- este ya no queda ninguno.
--
-- ---------------------------------------------------------------------------
-- De paso, el día de desfase que ya estaba
-- ---------------------------------------------------------------------------
-- La cola comparaba `> 15` donde el motor comparaba `>= 15`. Con exactamente
-- 15 días de retraso el motor ya había bajado el nivel y la lista seguía
-- diciendo "congelado". Los operadores se igualan a los del motor y a los de
-- docs/00-BASES §2.4 —`>= demotion`, `> expulsion`— para que el tramo diga
-- literalmente lo que ya le pasó a la persona.
--
-- ---------------------------------------------------------------------------
-- Los tramos son acumulativos, y el nombre de cada uno engaña
-- ---------------------------------------------------------------------------
-- `bucket` dice la consecuencia NUEVA de ese tramo, no que la anterior haya
-- caducado. En concreto: **la congelación del saldo no se levanta a los 30
-- días.** Lo que pasa ese día es que además cuesta un nivel y el saldo pasa de
-- congelado a bloqueado (docs/06 §3) — el motor mueve `frozen → suspended`, y
-- todo lo que gasta exige `status = 'active'`, así que los dos estados cierran
-- el grifo igual. Lo único que devuelve el saldo es pagar.
--
-- Se deja dicho aquí porque un `case` que va de 'congelado' a 'baja_nivel'
-- invita a leer que al día 30 se descongeló, y porque las etiquetas del panel
-- decían exactamente eso.
--
-- ---------------------------------------------------------------------------
-- Por qué la función cambia de forma (y no solo de números)
-- ---------------------------------------------------------------------------
-- El panel etiquetaba los tramos con "1–15 d" y "15–30 d" escritos en el
-- cliente, así que arreglar solo el SQL habría dejado la pantalla igual de
-- mentirosa. `admin_overview` ya resolvió esto devolviendo `demotion_days` y
-- `expulsion_days` junto a los datos, y aquí se hace lo mismo.
--
-- Lo que obliga al cambio de forma es el caso vacío: **las pastillas de filtro
-- se pintan también cuando no hay nadie en la cola**, que es justo cuando no
-- hay ninguna fila de la que sacar los umbrales. Con `returns table` los
-- umbrales solo pueden viajar como columna repetida en cada fila, y entonces
-- una cola vacía dejaría al panel sin nada que leer y con los números otra vez
-- escritos a mano. Así que devuelve un objeto:
--
--     { demotion_days, expulsion_days, rows: [ ... ] }
--
-- Es la forma que ya usa `admin_kyc_queue`. Y hay que dropear la función de
-- todos modos: `create or replace` no sabe cambiarle las columnas de salida a
-- una función `returns table`.
--
-- **Lo que NO cambia:** las filas llevan exactamente las mismas claves que
-- llevaban como columnas, con los mismos nombres y en el mismo orden de
-- salida. La agrupación sigue siendo por persona y no por cuota —quien llama
-- llama a alguien, y esa persona puede deber tres cuotas de dos locales—, y el
-- tramo `por_vencer` sigue entrando en la cola a propósito (20260822201000):
-- la cobranza que funciona es la que ocurre antes del vencimiento.
-- ============================================================================

-- `returns table` → `returns jsonb`: no hay `create or replace` que valga.
drop function if exists public.admin_collections(integer);

create function public.admin_collections(p_horizon_days integer default 3)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today     date := public.helios_business_date(now());
  v_horizon   integer := greatest(least(coalesce(p_horizon_days, 3), 30), 0);
  -- NUEVO: los umbrales salen de los parámetros, como en el motor de mora.
  v_demotion  integer := public.helios_mora_demotion_days();
  v_expulsion integer := public.helios_mora_expulsion_days();
  v_rows      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- El orden es el de siempre —el más atrasado arriba, y a igual atraso el que
  -- más debe— escrito sobre `next_due_date` porque es el mismo dato:
  -- `days_late` es `max(hoy - due_date)`, o sea `hoy - min(due_date)`, así que
  -- el vencimiento más antiguo primero ES el mayor atraso primero, y además
  -- ordena entre sí a los que aún no vencen, que `days_overdue` aplana a cero.
  -- Hay que decirlo dentro del `jsonb_agg`: el orden de una subconsulta no se
  -- hereda al agregarla.
  select coalesce(
           jsonb_agg(to_jsonb(q) order by q.next_due_date, q.open_usd desc),
           '[]'::jsonb
         )
    into v_rows
  from (
    with pending as (
      select
        i.user_id as uid,
        i.amount_usd,
        i.due_date,
        m.name as merchant_name
      from public.installments i
      join public.charges ch on ch.id = i.charge_id
      join public.merchants m on m.id = ch.merchant_id
      where i.status = 'pending'
        and i.due_date <= v_today + v_horizon
    ),
    grouped as (
      select
        uid,
        sum(amount_usd) as open_usd,
        sum(amount_usd) filter (where due_date < v_today) as overdue_usd,
        sum(amount_usd) filter (where due_date >= v_today) as upcoming_usd,
        max(v_today - due_date) as days_late,
        min(due_date) as next_due,
        count(*)::integer as cnt,
        array_agg(distinct merchant_name) as merchant_names
      from pending
      group by 1
    )
    select
      g.uid as user_id,
      p.full_name,
      p.phone_e164,
      p.status::text as status,
      p.level,
      -- ── NUEVO: los umbrales, y los operadores del motor ──────────────────
      -- `>= v_demotion` y `> v_expulsion` son los de
      -- `recompute_profile_mora_state` y los de docs/00-BASES §2.4. Aquí ponía
      -- `> 30` / `> 15`: ni los días eran esos, ni el corte era ese.
      --
      -- El tramo es la consecuencia NUEVA, y se suma a las anteriores: quien
      -- cae en 'baja_nivel' sigue con el saldo cerrado, ahora como bloqueado.
      case
        when g.days_late > v_expulsion then 'expulsion'
        when g.days_late >= v_demotion then 'baja_nivel'
        when g.days_late >= 1 then 'congelado'
        when g.days_late = 0  then 'vence_hoy'
        else 'por_vencer'
      end as bucket,
      -- ─────────────────────────────────────────────────────────────────────
      g.open_usd::numeric as open_usd,
      coalesce(g.overdue_usd, 0)::numeric as overdue_usd,
      coalesce(g.upcoming_usd, 0)::numeric as upcoming_usd,
      greatest(g.days_late, 0)::integer as days_overdue,
      g.next_due as next_due_date,
      g.cnt as installment_count,
      g.merchant_names as merchants,
      (
        select max(pr.created_at) from public.payment_reports pr
        where pr.user_id = g.uid and pr.status = 'reconciled'
      ) as last_payment_at
    from grouped g
    join public.profiles p on p.id = g.uid
  ) q;

  -- NUEVO: los umbrales viajan con la cola, no dentro del panel. Van fuera de
  -- las filas para que una cola vacía siga sabiendo etiquetar sus tramos.
  return jsonb_build_object(
    'demotion_days', v_demotion,
    'expulsion_days', v_expulsion,
    'rows', v_rows
  );
end;
$$;

comment on function public.admin_collections(integer) is
  'Cola de cobranza agrupada por persona, con los umbrales de la escalera de mora para que el panel etiquete los tramos solo. Ver docs/06 3.';

revoke all on function public.admin_collections(integer) from public, anon;
grant execute on function public.admin_collections(integer) to authenticated;
