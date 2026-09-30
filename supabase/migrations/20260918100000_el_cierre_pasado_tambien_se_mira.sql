-- ============================================================================
-- Ronda — El cierre pasado también se mira
--
-- «Pagos a locales» solo sabía hablar del cierre que viene. Enseñaba tres
-- cifras por comercio —lo que toca este lunes, lo atrasado, lo comprometido a
-- futuro— y todas se miden contra `helios_next_settlement_run(now())`. Sirve
-- para la tarea del lunes, que es para lo que se hizo, pero deja dos preguntas
-- sin sitio donde contestarse:
--
--   * «¿Qué pasó con el cierre del 14?» El arrastre se ve sumado en la columna
--     de atrasado, pero no de qué cierre viene ni qué se llegó a transferir.
--   * «¿Cuánto le hemos pagado a este local desde que empezó?» El histórico
--     existía en el libro y en `merchant_payouts`, nunca por cierre.
--
-- Cada liquidación pertenece a UN cierre y solo a uno: el primer lunes
-- posterior a su vencimiento, que es justo lo que devuelve
-- `helios_settlement_run_for(due_date)`. Ese es el eje que faltaba. Agrupando
-- por él sale la semana de caja entera: lo que se generó, lo que salió del
-- banco y lo que quedó a deber, esté el cierre abierto, saldado o todavía por
-- llegar.
--
-- Nada de esto reemplaza al outlook. `helios_settlement_outlook` sigue siendo
-- la aritmética del lunes —y la única que suma lo que el cron aún no ha
-- encolado, que por definición no tiene cierre porque no tiene fila—. Lo de
-- aquí es la lectura del pasado, que es de filas reales o no es nada.
--
-- Los comercios de prueba siguen fuera, como en todas las cifras del panel
-- (20260911180000).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La lista de cierres
-- ---------------------------------------------------------------------------
/**
 * Un renglón por lunes de caja, del más reciente al más viejo.
 *
 * `due_date` es lo que decide a qué cierre va cada liquidación. Las filas
 * viejas —los adelantos de agosto— pueden no tenerla: para ésas manda la fecha
 * en que se devengaron, que es la misma respuesta que daría el cron. Sin el
 * coalesce su cierre sería `null` y desaparecerían del histórico, que es
 * exactamente el fallo que esta migración viene a arreglar.
 */
create or replace function public.admin_settlement_runs()
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.run_date desc), '[]'::jsonb)
  into v_rows
  from (
    with por_cierre as (
      select
        public.helios_settlement_run_for(
          coalesce(s.due_date, s.business_date)
        )                                           as run_date,
        sum(s.amount_usd)                           as generado_usd,
        sum(s.paid_usd)                             as transferido_usd,
        sum(s.amount_usd - s.paid_usd)              as pendiente_usd,
        count(*)::int                               as lineas,
        count(distinct s.merchant_id)::int          as comercios,
        min(coalesce(s.due_date, s.business_date))  as primer_vencimiento,
        max(coalesce(s.due_date, s.business_date))  as ultimo_vencimiento
      from public.settlements s
      join public.merchants m on m.id = s.merchant_id
      where not m.is_test
      group by 1
    )
    -- Cada cierre dice en qué tiempo está. Lo decide el servidor y no el
    -- navegador: el día operativo cambia a las 10 AM, así que entre la
    -- medianoche y esa hora un `hoy` calculado en el cliente pone el lunes
    -- que no es. Y de esto depende qué viene marcado para pagar.
    select
      c.*,
      c.run_date = public.helios_next_settlement_run(now()) as is_next,
      c.run_date < public.helios_next_settlement_run(now()) as is_past
    from por_cierre c
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_settlement_runs() from public, anon;
grant execute on function public.admin_settlement_runs() to authenticated;

comment on function public.admin_settlement_runs() is
  'Los cierres de caja con filas: generado, transferido y pendiente por lunes. Del mas reciente al mas viejo, sin comercios de prueba.';

-- ---------------------------------------------------------------------------
-- 2. Un cierre concreto, comercio a comercio
-- ---------------------------------------------------------------------------
/**
 * Lo mismo que la fila de «Pagos a locales», pero de UN cierre.
 *
 * Aquí no hay proyección ni hay futuro: un cierre pasado es lo que fue. Las
 * tres cifras son las de la semana de caja —se generó, se transfirió, quedó a
 * deber— y el orden es el que le importa a quien mira: primero lo que sigue
 * sin pagarse.
 */
create or replace function public.admin_run_payables(p_run_date date)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  if p_run_date is null then
    raise exception 'Falta el cierre' using errcode = '22023';
  end if;

  select coalesce(
           jsonb_agg(to_jsonb(q) order by q.pendiente_usd desc, q.generado_usd desc),
           '[]'::jsonb
         )
  into v_rows
  from (
    select
      m.id                                        as merchant_id,
      m.name                                      as merchant_name,
      m.tax_id,
      sum(s.amount_usd)                           as generado_usd,
      sum(s.paid_usd)                             as transferido_usd,
      sum(s.amount_usd - s.paid_usd)              as pendiente_usd,
      count(*)::int                               as lineas,
      min(coalesce(s.due_date, s.business_date))  as primer_vencimiento
    from public.settlements s
    join public.merchants m on m.id = s.merchant_id
    where not m.is_test
      and public.helios_settlement_run_for(
            coalesce(s.due_date, s.business_date)
          ) = p_run_date
    group by 1, 2, 3
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_run_payables(date) from public, anon;
grant execute on function public.admin_run_payables(date) to authenticated;

comment on function public.admin_run_payables(date) is
  'Lo generado, lo transferido y lo pendiente de un cierre de caja, comercio a comercio. Ver admin_settlement_runs().';

-- ---------------------------------------------------------------------------
-- 3. Las líneas de un comercio: por cierre, y con las parciales dentro
-- ---------------------------------------------------------------------------
/**
 * Dos cambios, y el segundo es un fallo que llevaba una semana en pie.
 *
 * 1. `p_run_date` acota a un cierre. Sin él sigue devolviendo lo que se le
 *    debe hoy al comercio, que es lo que pide la pantalla del lunes; con él,
 *    las líneas de ese cierre **incluidas las ya pagadas**: un cierre saldado
 *    con una lista vacía no contaría nada.
 *
 * 2. 🐛 `status = 'pending'` dejaba fuera las parciales. Desde
 *    20260911191000 un pago que no alcanza deja la última liquidación en
 *    `partial` con su resto, y ese resto SÍ suma en `helios_settlement_outlook`
 *    —que mira `in ('pending','partial')`—. O sea: el comercio aparecía
 *    debiendo un dinero que no salía en ninguna línea, y al no salir tampoco
 *    tenía casilla, así que no había forma de terminar de pagarlo desde el
 *    panel. Justo el resto que el pago parcial promete «sigue apareciendo en
 *    el cierre».
 *
 * `pending_usd` es lo que falta de cada línea, que es lo que hay que sumar y
 * lo que hay que enseñar. El importe original se queda al lado porque en una
 * parcial las dos cifras son distintas y las dos se preguntan.
 *
 * El número de la orden viaja con la línea: es lo que identifica el consumo
 * cuando el gerente llama preguntando por una venta concreta.
 */
drop function if exists public.admin_merchant_settlements(uuid);

create or replace function public.admin_merchant_settlements(
  p_merchant_id uuid,
  p_run_date    date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.due_date, q.id), '[]'::jsonb)
  into v_rows
  from (
    select
      s.id,
      s.reason,
      s.status,
      s.amount_usd,
      s.paid_usd,
      s.amount_usd - s.paid_usd                          as pending_usd,
      coalesce(s.due_date, s.business_date)              as due_date,
      coalesce(s.due_date, s.business_date)
        <= public.helios_business_date(now())             as is_due,
      coalesce(s.due_date, s.business_date)
        < public.helios_next_settlement_run(now())        as in_next_run,
      public.helios_settlement_run_for(
        coalesce(s.due_date, s.business_date)
      )                                                  as run_date,
      c.id                                               as charge_id,
      c.order_number
    from public.settlements s
    left join public.charges c on c.id = s.charge_id
    where s.merchant_id = p_merchant_id
      and (
        case
          -- Un cierre concreto: lo que fue, pagado o no.
          when p_run_date is not null then
            public.helios_settlement_run_for(
              coalesce(s.due_date, s.business_date)
            ) = p_run_date
          -- Sin cierre: lo que se le debe hoy, de cualquier semana.
          else s.status in ('pending', 'partial')
        end
      )
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_merchant_settlements(uuid, date) from public, anon;
grant execute on function public.admin_merchant_settlements(uuid, date) to authenticated;

comment on function public.admin_merchant_settlements(uuid, date) is
  'Liquidaciones de un comercio. Sin p_run_date, lo pendiente y lo parcial de cualquier cierre; con el, todas las de ese cierre incluidas las pagadas.';

-- El histórico pregunta «qué hay en el cierre del 14», que es una fecha
-- calculada sobre `due_date`. La función es `immutable`, así que el índice
-- puede ser sobre la expresión y la agrupación no barre la tabla entera.
create index if not exists settlements_run_date_idx
  on public.settlements (
    (public.helios_settlement_run_for(coalesce(due_date, business_date)))
  );
