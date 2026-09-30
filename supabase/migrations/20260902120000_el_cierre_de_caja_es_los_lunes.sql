-- ============================================================================
-- Ronda — El cierre de caja es los lunes a las 10 AM
--
-- Regla confirmada el 2026-09-02, y cierra el ⚠️ PENDIENTE DE CONFIRMAR que
-- 20260830140000 dejó abierto ("volver a un calendario con fechas es un UPDATE
-- de una fila"). Pues es ese UPDATE, más el calendario que lo ordena.
--
--   **Todos los lunes a las 10 AM Ronda cierra caja, y ese mismo lunes le
--   transfiere al comercio las cuotas que vencieron durante la semana que
--   acaba de cerrar — hayan pagado o no sus clientes.**
--
-- El ejemplo que fijó la regla, con la semana entera delante:
--
--     viernes 4    el usuario compra                → cuotas: vie 11 y vie 18
--     lunes 7      10 AM · cierre                   → esa venta no entra
--     viernes 11   vence la cuota 1                 → se devenga el 50%
--     lunes 14     10 AM · cierre                   → se le paga la cuota 1
--     viernes 18   vence la cuota 2                 → se devenga el otro 50%
--     lunes 21     10 AM · cierre                   → se le paga la cuota 2
--
-- La ventana del cierre del lunes 14 va del **lunes 7 a las 10 AM al lunes 14
-- a las 10 AM**. Escrito en días operativos —que son de 10 AM a 10 AM desde
-- 20260822050000— eso es exactamente [lunes 7, domingo 13], o dicho de una
-- sola forma: due_date < 14. No hay una segunda convención horaria que
-- mantener; el corte de las 10 AM del negocio y el del cierre son el mismo.
--
-- ---------------------------------------------------------------------------
-- Lo que cambia de verdad: el comercio vuelve a cobrar en dos mitades
-- ---------------------------------------------------------------------------
-- Desde el 30 de agosto el comercio devengaba el 100% en el momento de la
-- venta (upfront_pct = 100). Con un cierre semanal por FECHA DE CUOTA eso ya
-- no describe nada: si todo se devenga al vender, no hay "cuota 2" que quede
-- pendiente, y la métrica que el comercio ha pedido —cuánto le falta por
-- cobrar contando la segunda— no tendría nada que contar.
--
--     upfront_pct = 0 · per_installment_pct = 50
--
-- El check settlement_adds_up se cumple sin tocarlo: 0 + (50 × 2) + 0 = 100.
-- Y record_advance_settlement ya sabe no encolar un adelanto de cero desde
-- 20260829030000, así que la venta no se rompe por el camino.
--
-- **Lo que NO cambia: se paga por fecha, no por cobranza.** El comercio cobra
-- su venta se retrase el usuario o no (docs/05 §3). El cierre del lunes mira
-- vencimientos, nunca pagos: por eso run_scheduled_settlements no consulta
-- installments.status en ninguna línea, y no debe empezar a hacerlo.
--
-- ---------------------------------------------------------------------------
-- El techo del 100%, que es lo único delicado de este cambio
-- ---------------------------------------------------------------------------
-- Las ventas hechas entre el 30 de agosto y hoy ya tienen su 100% encolado
-- como `advance`, y sus cuotas vencen DESPUÉS de esta migración. Sin más, el
-- cron les añadiría un 50% en cada fecha y el comercio cobraría el 200% de esas
-- ventas.
--
-- El arreglo no es una fecha de corte —que envejece mal y hay que recordar—
-- sino un invariante: **por un consumo nunca se devenga más que su neto**. El
-- cron descuenta lo ya devengado antes de encolar, y la previsión que ven los
-- dos paneles aplica el mismo techo. Las filas viejas no se tocan: son
-- instrucciones de pago, algunas ya ejecutadas contra un banco.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El calendario del cierre
-- ---------------------------------------------------------------------------

/**
 * En qué cierre se paga una liquidación que vence ese día operativo.
 *
 * Primer lunes ESTRICTAMENTE posterior. Lo que vence el lunes 7 —día operativo
 * que va del lunes 7 a las 10 AM al martes 8 a las 10 AM— nace después de que
 * el cierre de ese mismo lunes ya cerró, así que le toca el del lunes 14.
 */
create or replace function public.helios_settlement_run_for(p_due_date date)
returns date
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select p_due_date + (7 - ((extract(isodow from p_due_date)::int - 1) % 7));
$$;

comment on function public.helios_settlement_run_for(date) is
  'Lunes de cierre que paga una liquidación vencida ese día operativo: el primer lunes estrictamente posterior. Ver docs/05 3.';

/**
 * El cierre que viene: primer lunes >= el día operativo de ahora.
 *
 * Un lunes a las 10:30 el cierre EN CURSO es el de ese mismo lunes, no el de la
 * semana siguiente: el día operativo cambia a las 10 AM, que es la misma hora a
 * la que cierra la caja. Por eso >= y no >.
 */
create or replace function public.helios_next_settlement_run(p_ts timestamptz)
returns date
language sql
stable
set search_path = public, pg_temp
as $$
  select public.helios_business_date(p_ts)
       + ((8 - extract(isodow from public.helios_business_date(p_ts))::int) % 7);
$$;

comment on function public.helios_next_settlement_run(timestamptz) is
  'Proximo lunes de cierre de caja (10 AM Caracas), contando hoy si hoy es lunes. Ver docs/05 3.';

revoke all on function public.helios_settlement_run_for(date) from public, anon;
revoke all on function public.helios_next_settlement_run(timestamptz) from public, anon;
grant execute on function public.helios_settlement_run_for(date) to authenticated;
grant execute on function public.helios_next_settlement_run(timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Vuelven las dos mitades: 0 al vender, 50 en cada fecha de cuota
-- ---------------------------------------------------------------------------
-- Se acota a los comercios que están en las condiciones POR DEFECTO, como en
-- 20260830140000: a uno con condiciones negociadas no se le cambia el
-- calendario de pago desde una migración, eso son los términos de un contrato.

update public.merchant_settlement_terms
set upfront_pct = 0, per_installment_pct = 50.00, updated_at = now()
where upfront_pct = 100.00 and per_installment_pct = 0;

alter table public.merchant_settlement_terms
  alter column upfront_pct set default 0,
  alter column per_installment_pct set default 50.00;

comment on column public.merchant_settlement_terms.upfront_pct is
  'Porcentaje del neto que se devenga al vender. 0 desde 2026-09-02: nada se devenga con la venta, todo cae en las fechas de las dos cuotas.';
comment on column public.merchant_settlement_terms.per_installment_pct is
  'Porcentaje del neto que se devenga en la fecha de cada cuota. 50 desde 2026-09-02: media venta por cuota, y se paga en el cierre del lunes siguiente.';

-- ---------------------------------------------------------------------------
-- 3. El cron, con el techo del neto
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260829030000 salvo el bloque marcado NUEVO. Sigue
-- corriendo todos los días a las 10:05 AM (20260822059000): quien decide qué
-- día se devenga es el vencimiento de la cuota, no el cron.

create or replace function public.run_scheduled_settlements(p_business_date date)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_charge record;
  v_terms  public.merchant_settlement_terms%rowtype;
  v_amount numeric(18,4);
  v_room   numeric(18,4);
  v_count  integer := 0;
begin
  -- Un consumo por vuelta, no una cuota por vuelta: en un consumo de mesa hay
  -- una cuota por integrante venciendo el mismo día y todas hablan de la misma
  -- venta (ver 20260827080000).
  for v_charge in
    select distinct c.id as charge_id, c.merchant_id,
           coalesce(c.merchant_net_usd, c.amount_usd) as net_usd
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.due_date = p_business_date
  loop
    -- Cada consumo en su propio bloque: el fallo de uno no puede llevarse la
    -- liquidación de todos los demás (20260829030000).
    begin
      select * into v_terms from public.merchant_settlement_terms
      where merchant_id = v_charge.merchant_id;

      if coalesce(v_terms.policy, '') <> 'scheduled' then
        continue;
      end if;

      if exists (
        select 1 from public.settlements
        where charge_id = v_charge.charge_id
          and reason = 'scheduled_installment'
          and business_date = p_business_date
      ) then
        continue;
      end if;

      v_amount := round(v_charge.net_usd * v_terms.per_installment_pct / 100, 4);

      -- NUEVO (2026-09-02): por un consumo nunca se devenga más que su neto.
      --
      -- Las ventas del 30-ago al 2-sep tienen el 100% encolado como adelanto y
      -- sus cuotas siguen venciendo; sin este techo cobrarían el 200%. Es un
      -- invariante y no una fecha de corte a propósito: también cubre el caso
      -- general —un comercio al que se le renegocian las condiciones a mitad
      -- del ciclo— sin que nadie tenga que acordarse.
      select v_charge.net_usd - coalesce(sum(s.amount_usd), 0)
        into v_room
      from public.settlements s
      where s.charge_id = v_charge.charge_id;

      v_amount := least(v_amount, v_room);

      -- Un tramo del 0% es política válida, y un techo agotado también. No hay
      -- nada que encolar, y encolarlo violaría el check (amount_usd > 0).
      if v_amount <= 0 then
        continue;
      end if;

      insert into public.settlements
        (merchant_id, charge_id, installment_id, reason, amount_usd, business_date, due_date, status)
      values
        (v_charge.merchant_id, v_charge.charge_id, null, 'scheduled_installment',
         v_amount, p_business_date, p_business_date, 'pending');

      v_count := v_count + 1;
    exception when others then
      -- Al log de Postgres, y el bucle sigue. Es un cron sin nadie delante:
      -- callar sería peor, pero parar el resto también.
      raise warning 'Liquidación programada fallida para el consumo % (comercio %): %',
        v_charge.charge_id, v_charge.merchant_id, sqlerrm;
    end;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.run_scheduled_settlements(date) from public, anon, authenticated;

comment on function public.run_scheduled_settlements(date) is
  'Devenga el tramo del comercio en la fecha de vencimiento de cada cuota, pague o no pague el usuario. Corre a diario a las 10:05 AM; lo devengado se transfiere en el cierre del lunes siguiente. Nunca supera el neto del consumo. Ver docs/00-BASES 2.5.';

-- El techo y la previsión preguntan "cuánto se ha devengado ya por ESTE
-- consumo", que hasta ahora no era una pregunta que nadie hiciera.
create index if not exists settlements_charge_idx
  on public.settlements (charge_id);

-- ---------------------------------------------------------------------------
-- 4. Lo que se le debe a un comercio, con la parte que todavía no ha nacido
-- ---------------------------------------------------------------------------
/**
 * Las dos cifras que piden los dos paneles, y una sola aritmética detrás.
 *
 * Hay que sumar dos cosas de naturaleza distinta y no confundirlas:
 *
 *   1. **Lo devengado** — filas reales de `settlements` pendientes. Existe
 *      porque una cuota ya venció y el cron la encoló.
 *   2. **Lo que aún no ha nacido** — la cuota 2 de una venta de esta semana no
 *      tiene fila en ninguna tabla: el cron la creará el día que venza. Sin
 *      esta mitad, "total por cobrar" le enseñaría al comercio la mitad de lo
 *      que se le debe y parecería una respuesta legítima.
 *
 * La previsión reproduce al cron línea por línea —mismo neto, mismo tramo,
 * mismo techo, misma clave de idempotencia (consumo + fecha)— para que la cifra
 * de la pantalla y la que acabará en el banco no puedan separarse. El techo se
 * acumula por consumo con una ventana: si la cuota 1 ya se comió el hueco que
 * quedaba, la 2 no puede volver a comérselo.
 *
 * SECURITY DEFINER y sin permiso para nadie: lee `installments`, que el
 * personal del comercio no puede leer y no debe poder. Quien decide de qué
 * comercio se contesta son las dos RPC de abajo, no el llamante.
 */
create or replace function public.helios_settlement_outlook(p_merchant_id uuid)
returns table (
  today_date        date,
  next_run_date     date,
  next_run_usd      numeric,
  accrued_usd       numeric,
  accrued_count     integer,
  overdue_usd       numeric,
  oldest_due_date   date,
  upcoming_usd      numeric,
  total_pending_usd numeric
)
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select
    cal.today,
    cal.next_run,
    a.in_next_run + u.in_next_run,
    a.usd,
    a.n,
    a.overdue,
    a.oldest,
    u.usd,
    a.usd + u.usd
  from (
    select public.helios_business_date(now())      as today,
           public.helios_next_settlement_run(now()) as next_run
  ) cal
  -- 1. Devengado y sin transferir.
  cross join lateral (
    select
      coalesce(sum(s.amount_usd), 0)                                           as usd,
      count(s.id)::int                                                         as n,
      min(s.due_date)                                                          as oldest,
      -- Atrasado = su cierre ya pasó y sigue sin transferirse. Con cierre
      -- semanal, "vencido ayer" NO es un atraso: es dinero esperando al lunes.
      coalesce(sum(s.amount_usd) filter (
        where public.helios_settlement_run_for(s.due_date) < cal.next_run
      ), 0)                                                                    as overdue,
      coalesce(sum(s.amount_usd) filter (where s.due_date < cal.next_run), 0)  as in_next_run
    from public.settlements s
    where s.merchant_id = p_merchant_id and s.status = 'pending'
  ) a
  -- 2. Lo que el cron encolará y todavía no existe.
  cross join lateral (
    select
      coalesce(sum(f.amount_usd), 0)                                           as usd,
      coalesce(sum(f.amount_usd) filter (where f.due_date < cal.next_run), 0)  as in_next_run
    from (
      select
        d.due_date,
        greatest(0, least(
          d.tranche,
          d.room - coalesce(sum(d.tranche) over (
            partition by d.charge_id order by d.due_date
            rows between unbounded preceding and 1 preceding
          ), 0)
        )) as amount_usd
      from (
        select distinct
          c.id                                                   as charge_id,
          i.due_date,
          round(coalesce(c.merchant_net_usd, c.amount_usd) * t.per_installment_pct / 100, 4) as tranche,
          coalesce(c.merchant_net_usd, c.amount_usd) - coalesce((
            select sum(s2.amount_usd)
            from public.settlements s2
            where s2.charge_id = c.id
          ), 0)                                                  as room
        from public.installments i
        join public.charges c on c.id = i.charge_id
        join public.merchant_settlement_terms t on t.merchant_id = c.merchant_id
        where c.merchant_id = p_merchant_id
          and t.policy = 'scheduled'
          -- Vencimientos pasados que el cron no encoló ya no los encolará
          -- nunca: solo mira el día operativo de hoy. Prometerlos sería
          -- enseñar dinero que no va a llegar.
          and i.due_date >= cal.today
          and not exists (
            select 1 from public.settlements s3
            where s3.charge_id = c.id
              and s3.reason = 'scheduled_installment'
              and s3.business_date = i.due_date
          )
      ) d
    ) f
    where f.amount_usd > 0
  ) u;
$$;

revoke all on function public.helios_settlement_outlook(uuid) from public, anon, authenticated;

comment on function public.helios_settlement_outlook(uuid) is
  'Lo devengado mas lo que el cron encolara, con el cierre del lunes que viene. Interna: la llaman merchant_settlement_outlook y admin_merchant_payables.';

-- ---------------------------------------------------------------------------
-- 5. La misma cuenta para los dos paneles
-- ---------------------------------------------------------------------------

/**
 * Para el panel del comercio.
 *
 * No recibe `p_merchant_id`: se resuelve desde la sesión (20260822220000). Que
 * un gerente pueda leer la caja del local de al lado tiene que ser imposible
 * de escribir, no algo que haya que acordarse de comprobar.
 */
create or replace function public.merchant_settlement_outlook()
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_out      record;
begin
  if v_merchant is null then
    raise exception 'Solo el gerente del comercio' using errcode = '42501';
  end if;

  select * into v_out from public.helios_settlement_outlook(v_merchant);

  return jsonb_build_object(
    'today_date',        v_out.today_date,
    'next_run_date',     v_out.next_run_date,
    'next_run_usd',      v_out.next_run_usd,
    'accrued_usd',       v_out.accrued_usd,
    'accrued_count',     v_out.accrued_count,
    'overdue_usd',       v_out.overdue_usd,
    'oldest_due_date',   v_out.oldest_due_date,
    'upcoming_usd',      v_out.upcoming_usd,
    'total_pending_usd', v_out.total_pending_usd
  );
end;
$$;

revoke all on function public.merchant_settlement_outlook() from public, anon;
grant execute on function public.merchant_settlement_outlook() to authenticated;

/**
 * Para el super admin: lo mismo, comercio a comercio.
 *
 * Sustituye a la lectura directa de la vista `merchant_payables`, que se queda
 * donde está y sigue siendo cierta —lo devengado— pero no puede contar la cuota
 * que aún no ha nacido sin leer `installments`, y es `security_invoker`.
 *
 * Salen también los comercios sin nada devengado pero con cuotas por vencer:
 * hoy no hay que transferirles nada y el lunes que viene sí.
 */
create or replace function public.admin_merchant_payables()
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

  select coalesce(jsonb_agg(to_jsonb(q) order by q.total_pending_usd desc), '[]'::jsonb)
  into v_rows
  from (
    select
      m.id     as merchant_id,
      m.name   as merchant_name,
      m.tax_id,
      o.*
    from public.merchants m
    cross join lateral public.helios_settlement_outlook(m.id) o
    where o.accrued_usd > 0 or o.upcoming_usd > 0
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_merchant_payables() from public, anon;
grant execute on function public.admin_merchant_payables() to authenticated;

comment on view public.merchant_payables is
  'Lo DEVENGADO y sin transferir, comercio a comercio. Ya no la lee ningun panel: desde 2026-09-02 las dos pantallas de pagos preguntan por admin_merchant_payables() y merchant_settlement_outlook(), que ademas cuentan la cuota que todavia no ha vencido. Su overdue_usd es due_date <= hoy, que con cierre semanal no es un atraso sino dinero esperando al lunes.';

-- ---------------------------------------------------------------------------
-- 6. El detalle que elige el operador, acotado al cierre
-- ---------------------------------------------------------------------------
/**
 * Cuerpo idéntico al de 20260822121000 salvo `in_next_run`.
 *
 * `is_due` (vence hoy o antes) dejó de servir para decidir qué se paga: el
 * lunes del cierre, "todo lo vencido" incluye el tramo que vence ESE lunes, que
 * pertenece a la semana siguiente. Un operador que marcara todo lo vencido el
 * día del cierre le adelantaría al comercio una semana entera.
 *
 * `in_next_run` es la respuesta exacta a "qué entra en el cierre del lunes":
 * `due_date < next_run`, que incluye de paso lo que se quedó atrás en cierres
 * anteriores.
 */
create or replace function public.admin_merchant_settlements(p_merchant_id uuid)
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

  select coalesce(jsonb_agg(to_jsonb(q) order by q.due_date), '[]'::jsonb) into v_rows
  from (
    select
      s.id,
      s.reason,
      s.amount_usd,
      s.due_date,
      s.due_date <= public.helios_business_date(now()) as is_due,
      s.due_date < public.helios_next_settlement_run(now()) as in_next_run,
      public.helios_settlement_run_for(s.due_date) as run_date,
      c.id as charge_id
    from public.settlements s
    left join public.charges c on c.id = s.charge_id
    where s.merchant_id = p_merchant_id and s.status = 'pending'
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_merchant_settlements(uuid) from public, anon;
grant execute on function public.admin_merchant_settlements(uuid) to authenticated;
