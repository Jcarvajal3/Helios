-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — La clínica cobra en su propia fecha
--
-- Decisión de Javier, 2026-11-06: las cuotas del paciente pasan a +14 y +28
-- días (migración siguiente), y a la clínica no le cambia nada: la mitad a los
-- días 8 y la otra a los 15 desde la orden, pague o no el paciente.
--
-- Hasta hoy la fecha del médico salía de la cuota: el cron creaba la
-- liquidación el día `installments.due_date` y se pagaba al siguiente
-- (`helios_settlement_run_for`). Con solo mover el parámetro, los médicos
-- cobrarían a los 15 y 29. Esta migración las desacopla y NO cambia ningún
-- comportamiento: el parámetro sigue en 7 y en todas las filas las dos fechas
-- son iguales.
--
--   · `helios_settlement_interval_days()`: lo pactado con la clínica. Una
--     constante, no un parámetro, igual que las condiciones que fija el
--     servidor en `admin_set_settlement_terms`.
--   · `installments.settlement_due_date`: el día en que se devenga a la clínica
--     la mitad que corresponde a esa cuota; el pago sale el día siguiente.
--     `due_date` queda como la fecha del paciente y nada más.
--   · Trigger `installments_settlement_due_date`: la pone al insertar, así no
--     cambia la firma de `helios_assign_debt`, la única función que crea deuda.
--   · `helios_installment_due_dates(d)` lee el intervalo VIGENTE EN d: una orden
--     pendiente de antes del corte vence como se le dijo cuando se registró. El
--     resto de usos de `helios_installment_interval_days()` (tramos de atraso,
--     temporada de las cosechas) sigue con el valor de hoy.
--   · Todo lo que derivaba la fecha del médico de la cuota pasa a la columna
--     nueva. Lo que lee `settlements.due_date` ya guardado no cambia.
--
-- Las funciones se reescriben desde `pg_get_functiondef` del 2026-11-06.
-- ═══════════════════════════════════════════════════════════════════════════

-- 1. Lo que se pacta con la clínica ─────────────────────────────────────────

create or replace function public.helios_settlement_interval_days()
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $function$
  select 7;
$function$;

comment on function public.helios_settlement_interval_days() is
  'Días entre la orden y la primera mitad de la clínica, y entre la primera y la segunda. El pago sale el día siguiente (helios_settlement_run_for): días 8 y 15. Es lo pactado, no un parámetro: no depende de cuándo vencen las cuotas del paciente.';

revoke all on function public.helios_settlement_interval_days() from public, anon;
grant execute on function public.helios_settlement_interval_days() to authenticated, service_role;

-- 2. La columna y su relleno ────────────────────────────────────────────────
-- `installments_evaluate_level` (AFTER UPDATE) solo actúa cuando la cuota pasa
-- a pagada y aquí `status` no cambia: el relleno no tiene efectos. El
-- `alter table` retiene la tabla hasta el final de la transacción, así que no
-- se cuela ninguna cuota sin la columna.

alter table public.installments add column settlement_due_date date;

update public.installments
   set settlement_due_date = due_date
 where settlement_due_date is null;

alter table public.installments alter column settlement_due_date set not null;

comment on column public.installments.settlement_due_date is
  'Día en que se devenga a la clínica la mitad que corresponde a esta cuota; el pago sale el día siguiente (helios_settlement_run_for). No sigue a due_date, que es solo la fecha del paciente.';

-- El cron y las proyecciones buscan por esta fecha, como antes por `due_date`.
create index installments_settlement_due_date_idx
  on public.installments (settlement_due_date);

-- 3. El trigger ─────────────────────────────────────────────────────────────
-- Los BEFORE disparan por orden alfabético: este va detrás de
-- `installments_currency` e `installments_mark_test`, y ninguno de los tres lee
-- lo que escriben los otros. El `not null` de la columna es la red.
-- Sin `business_date` en la orden (solo `pg_temp.prueba_cobro` de las suites, que
-- la pone después de crear la deuda), el día operativo de hoy, que es el que
-- esa orden va a tener.

create or replace function public.helios_installment_settlement_due_date()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_dia date;
begin
  if new.settlement_due_date is not null then
    return new;
  end if;

  select c.business_date into v_dia from public.charges c where c.id = new.charge_id;

  new.settlement_due_date := coalesce(v_dia, public.helios_business_date(now()))
                             + public.helios_settlement_interval_days() * new.sequence;
  return new;
end;
$function$;

revoke all on function public.helios_installment_settlement_due_date() from public, anon, authenticated;

create trigger installments_settlement_due_date
  before insert on public.installments
  for each row
  execute function public.helios_installment_settlement_due_date();

-- 3 bis. El asistente decía un día antes: `se_paga_el` era el día de devengo.

create or replace view asistente.liquidaciones as
 SELECT s.id AS liquidacion_id,
    s.merchant_id AS clinica_id,
    m.name AS clinica,
    s.charge_id AS orden_id,
    ch.order_number AS numero_orden,
    asistente.estado('motivo'::text, s.reason::text) AS motivo,
    asistente.estado('liquidacion'::text, s.status::text) AS estado,
    public.helios_settlement_run_for(s.due_date) AS se_paga_el,
    s.business_date AS dia,
    s.currency AS moneda,
    s.amount_usd AS monto_usd,
    s.paid_usd AS pagado_usd,
    s.amount_cur AS monto_en_moneda
   FROM settlements s
     JOIN merchants m ON m.id = s.merchant_id AND NOT m.is_test
     LEFT JOIN charges ch ON ch.id = s.charge_id;

-- 4. Los vencimientos del paciente, con el intervalo vigente en su fecha ────
-- `security definer` como `helios_installment_interval_days`: la función de los
-- vencimientos corre como quien la llama y `business_parameters` tiene RLS.

create or replace function public.helios_installment_interval_days_at(p_day date)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce((
    select p.value::integer
    from public.business_parameters p
    where p.key = 'installment_interval_days'
      and p.effective_from <= p_day
    order by p.effective_from desc
    limit 1
  ), 7);
$function$;

comment on function public.helios_installment_interval_days_at(date) is
  'El intervalo entre cuotas del paciente vigente en esa fecha (7 si no hay fila). Lo usa helios_installment_due_dates: la fecha de la orden manda, no la de hoy.';

revoke all on function public.helios_installment_interval_days_at(date) from public, anon;
grant execute on function public.helios_installment_interval_days_at(date) to authenticated, service_role;

create or replace function public.helios_installment_due_dates(p_business_date date)
returns table(due_1 date, due_2 date)
language sql
stable
set search_path = pg_catalog, pg_temp
as $function$
  select p_business_date + x.dias, p_business_date + x.dias * 2
  from (select public.helios_installment_interval_days_at(p_business_date) as dias) x;
$function$;

-- 5. Lo que deriva la fecha del médico de las cuotas ────────────────────────

-- El cron: las mitades que se devengan hoy, no las cuotas que vencen hoy.
CREATE OR REPLACE FUNCTION public.run_scheduled_settlements_batch(p_business_date date, p_after uuid, p_limit integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_charge  record;
  v_terms   public.merchant_terms;
  v_amount  numeric(18,4);
  v_room    numeric(18,4);
  v_last    uuid := p_after;
  v_seen    integer := 0;
  v_created integer := 0;
begin
  for v_charge in
    select distinct c.id as charge_id, c.merchant_id, c.business_date,
           coalesce(c.merchant_net_usd, c.amount_usd) as net_usd
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.settlement_due_date = p_business_date
      and c.id > p_after
    order by c.id
    limit p_limit
  loop
    v_last := v_charge.charge_id;
    v_seen := v_seen + 1;

    begin
      select * into v_terms
      from public.helios_terms_at(
        v_charge.merchant_id,
        coalesce(v_charge.business_date, p_business_date)
      );

      if coalesce(v_terms.policy::text, '') <> 'scheduled' then
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

      -- Por un consumo nunca se devenga más que su neto. Helios: la comisión
      -- del personal no es parte del neto de la consulta y no cuenta.
      select v_charge.net_usd - coalesce(sum(s.amount_usd), 0)
        into v_room
      from public.settlements s
      where s.charge_id = v_charge.charge_id
        and s.reason <> 'staff_commission';

      v_amount := least(v_amount, v_room);

      if v_amount <= 0 then
        continue;
      end if;

      insert into public.settlements
        (merchant_id, charge_id, installment_id, reason, amount_usd, business_date, due_date, status)
      values
        (v_charge.merchant_id, v_charge.charge_id, null, 'scheduled_installment',
         v_amount, p_business_date, p_business_date, 'pending');

      v_created := v_created + 1;
    exception when others then
      raise warning 'Liquidación programada fallida para el consumo % (comercio %): %',
        v_charge.charge_id, v_charge.merchant_id, sqlerrm;
    end;
  end loop;

  return jsonb_build_object('last', v_last, 'seen', v_seen, 'created', v_created);
end;
$function$;

-- Lo que falta por devengar, por día de pago (proyección de caja).
CREATE OR REPLACE FUNCTION metricas.mitades_por_devengar(p_desde date, p_hasta date, p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(dia date, merchant_id uuid, usd numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- Una por orden y día de devengo, como el cron (que recorre las órdenes con
  -- alguna mitad que se devenga ese día, pague o no el paciente). Lo que ya se
  -- devengó está en `settlements` y no se cuenta dos veces.
  with x as (
    select distinct c.id as charge_id, c.merchant_id, i.settlement_due_date as due_date,
           coalesce(c.merchant_net_usd, c.amount_usd) as neto,
           coalesce(c.business_date, i.settlement_due_date) as dia_orden
    from public.installments i
    join public.charges c on c.id = i.charge_id
    join public.merchants m on m.id = c.merchant_id
    where i.settlement_due_date between p_desde and p_hasta
      and c.status = 'confirmed'
      and not i.is_test
      and not m.is_test
      and (p_merchant_id is null or c.merchant_id = p_merchant_id)
      and not exists (
        select 1 from public.settlements s
        where s.charge_id = c.id
          and s.reason = 'scheduled_installment'
          and s.business_date = i.settlement_due_date
      )
  )
  select public.helios_settlement_run_for(x.due_date) as dia,
         x.merchant_id,
         sum(round(x.neto * t.per_installment_pct / 100, 4)) as usd
  from x
  cross join lateral public.helios_terms_at(x.merchant_id, x.dia_orden) t
  where t.policy = 'scheduled'
  group by 1, 2;
$function$;

-- El cierre de cada semana en Métricas › Clínicas: lo previsto.
CREATE OR REPLACE FUNCTION metricas.locales_cierre(p_cierre date)
 RETURNS TABLE(merchant_id uuid, generado_usd numeric, transferido_usd numeric, pendiente_usd numeric, previsto_usd numeric, atrasado_usd numeric)
 LANGUAGE sql
 STABLE
AS $function$
  with
  cal as (
    select metricas.hoy() as hoy
  ),
  -- Lo que ya se generó para esa semana: lo que se paga de martes a lunes,
  -- que es lo de las mitades que se devengaron de lunes a domingo.
  generado as (
    select s.merchant_id                                                         as mid,
           sum(s.amount_usd)                                                     as generado,
           sum(s.paid_usd)                                                       as transferido,
           coalesce(sum(s.amount_usd - s.paid_usd)
                    filter (where s.status in ('pending', 'partial')), 0)        as pendiente
    from public.settlements s
    where public.helios_settlement_run_for(coalesce(s.due_date, s.business_date))
          between p_cierre - 6 and p_cierre
    group by s.merchant_id
  ),
  -- Lo que el cron generará de aquí al cierre (solo si el cierre no ha
  -- llegado). Copia de la parte «u» de `helios_settlement_outlook`: el tramo
  -- se calcula sobre TODOS los vencimientos futuros del consumo (el techo del
  -- neto se reparte en orden) y después se quedan los de antes del cierre.
  previsto as (
    select f.mid, sum(f.amount_usd) as previsto
    from (
      select d.mid,
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
          c.id                                                                  as charge_id,
          c.merchant_id                                                         as mid,
          i.settlement_due_date as due_date,
          round(coalesce(c.merchant_net_usd, c.amount_usd) * t.per_installment_pct / 100, 4) as tranche,
          coalesce(c.merchant_net_usd, c.amount_usd) - coalesce((
            select sum(s2.amount_usd)
            from public.settlements s2
            where s2.charge_id = c.id
              and s2.reason <> 'staff_commission'
          ), 0)                                                                 as room
        from public.installments i
        join public.charges c on c.id = i.charge_id
        cross join cal
        cross join lateral public.helios_terms_at(c.merchant_id, coalesce(c.business_date, cal.hoy)) t
        where t.policy = 'scheduled'
          and i.settlement_due_date >= cal.hoy
          and p_cierre > cal.hoy
          and not exists (
            select 1 from public.settlements s3
            where s3.charge_id = c.id
              and s3.reason = 'scheduled_installment'
              and s3.business_date = i.settlement_due_date
          )
      ) d
    ) f
    where f.amount_usd > 0
      and f.due_date < p_cierre
      and f.due_date >= p_cierre - 7
    group by f.mid
  ),
  -- Lo de semanas anteriores que sigue sin transferirse.
  atrasado as (
    select s.merchant_id as mid, sum(s.amount_usd - s.paid_usd) as atrasado
    from public.settlements s
    cross join cal
    where p_cierre > cal.hoy
      and s.status in ('pending', 'partial')
      and public.helios_settlement_run_for(s.due_date) < p_cierre - 6
    group by s.merchant_id
  ),
  ids as (
    select g.mid from generado g
    union select p.mid from previsto p
    union select a.mid from atrasado a
  )
  select
    i.mid,
    coalesce(g.generado, 0)::numeric,
    coalesce(g.transferido, 0)::numeric,
    coalesce(g.pendiente, 0)::numeric,
    coalesce(p.previsto, 0)::numeric,
    coalesce(a.atrasado, 0)::numeric
  from ids i
  left join generado g on g.mid = i.mid
  left join previsto p on p.mid = i.mid
  left join atrasado a on a.mid = i.mid;
$function$;

-- La previsión de pagos a una clínica: lo que el cron encolará.
CREATE OR REPLACE FUNCTION public.helios_settlement_outlook(p_merchant_id uuid)
 RETURNS TABLE(today_date date, next_run_date date, next_run_usd numeric, accrued_usd numeric, accrued_count integer, overdue_usd numeric, oldest_due_date date, upcoming_usd numeric, total_pending_usd numeric, last_payout_on date, last_payout_usd numeric, accrued_consultas_usd numeric, accrued_comisiones_usd numeric, next_run_consultas_usd numeric, next_run_comisiones_usd numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select
    cal.today,
    cal.next_run,
    a.in_next_run + u.in_next_run,
    a.usd,
    a.n,
    a.overdue,
    a.oldest,
    u.usd,
    a.usd + u.usd,
    p.last_on,
    p.last_usd,
    a.usd - a.com,
    a.com,
    a.in_next_run - a.com_next + u.in_next_run,
    a.com_next
  from (
    select public.helios_business_date(now())      as today,
           public.helios_next_settlement_run(now()) as next_run
  ) cal
  -- 1. Devengado y sin transferir. Lo que falta, no el importe original.
  cross join lateral (
    select
      coalesce(sum(s.amount_usd - s.paid_usd), 0)                              as usd,
      count(s.id)::int                                                         as n,
      min(s.due_date)                                                          as oldest,
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where public.helios_settlement_run_for(s.due_date) < cal.next_run
      ), 0)                                                                    as overdue,
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where s.due_date < cal.next_run), 0)                                   as in_next_run,
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where s.reason = 'staff_commission'), 0)                               as com,
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where s.reason = 'staff_commission' and s.due_date < cal.next_run), 0) as com_next
    from public.settlements s
    where s.merchant_id = p_merchant_id
      and s.status in ('pending', 'partial')
  ) a
  -- 2. Lo que el cron encolará y todavía no existe, con las condiciones
  --    vigentes el día de CADA venta. Siempre consultas: la comisión nace
  --    devengada.
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
          i.settlement_due_date as due_date,
          round(coalesce(c.merchant_net_usd, c.amount_usd) * t.per_installment_pct / 100, 4) as tranche,
          coalesce(c.merchant_net_usd, c.amount_usd) - coalesce((
            select sum(s2.amount_usd)
            from public.settlements s2
            where s2.charge_id = c.id
              and s2.reason <> 'staff_commission'
          ), 0)                                                  as room
        from public.installments i
        join public.charges c on c.id = i.charge_id
        cross join lateral public.helios_terms_at(
          c.merchant_id, coalesce(c.business_date, cal.today)
        ) t
        where c.merchant_id = p_merchant_id
          and t.policy = 'scheduled'
          and i.settlement_due_date >= cal.today
          and not exists (
            select 1 from public.settlements s3
            where s3.charge_id = c.id
              and s3.reason = 'scheduled_installment'
              and s3.business_date = i.settlement_due_date
          )
      ) d
    ) f
    where f.amount_usd > 0
  ) u
  left join lateral (
    select mp.paid_on as last_on, mp.amount_usd as last_usd
    from public.merchant_payouts mp
    where mp.merchant_id = p_merchant_id
    order by mp.paid_on desc nulls last, mp.created_at desc
    limit 1
  ) p on true;
$function$;

-- Los próximos pagos de una clínica: `due_date` y `run_date` son los de la mitad.
CREATE OR REPLACE FUNCTION public.admin_merchant_upcoming_settlements(p_merchant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
  v_hoy  date := public.helios_business_date(now());
  v_usd  numeric := public.current_fx_rate('BCV', v_hoy);
  v_eur  numeric := public.current_fx_rate('BCV_EUR', v_hoy);
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.due_date, q.order_number), '[]'::jsonb)
  into v_rows
  from (
    select
      'scheduled_installment'                          as reason,
      f.amount_usd,
      f.currency,
      f.amount_cur,
      round(f.amount_cur * case f.currency when 'EUR' then v_eur else v_usd end, 2) as pending_ves_hoy,
      f.due_date,
      public.helios_settlement_run_for(f.due_date)     as run_date,
      f.charge_id,
      f.order_number,
      -- NUEVO: la tasa de hoy de su moneda y, si el paciente ya adelantó su
      -- cuota, a qué tasa la pagó.
      case f.currency when 'EUR' then v_eur else v_usd end as tasa_hoy,
      cp.cuotas,
      cp.cuotas_pagadas,
      cp.paid_on                                       as paciente_pago_el,
      cp.fx_rate                                       as paciente_tasa
    from (
      select
        g.*,
        -- En la moneda de la orden, como `helios_settlement_currency`: la
        -- mitad que completa el neto se lleva lo que falte; las otras, su
        -- parte proporcional.
        case
          when g.currency = 'USD' then g.amount_usd
          when g.prev_usd
               + coalesce(sum(g.amount_usd) over (
                   partition by g.charge_id order by g.due_date
                   rows between unbounded preceding and 1 preceding), 0)
               + g.amount_usd >= g.net_usd - 0.005
            then greatest(g.net_cur - g.prev_cur
                          - coalesce(sum(round(g.net_cur * g.amount_usd / nullif(g.net_usd, 0), 2)) over (
                              partition by g.charge_id order by g.due_date
                              rows between unbounded preceding and 1 preceding), 0), 0)
          else round(g.net_cur * g.amount_usd / nullif(g.net_usd, 0), 2)
        end as amount_cur
      from (
        select
          d.*,
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
            c.order_number,
            c.currency,
            i.settlement_due_date as due_date,
            coalesce(c.merchant_net_usd, c.amount_usd)             as net_usd,
            coalesce(c.merchant_net_cur, c.amount_cur, c.merchant_net_usd, c.amount_usd) as net_cur,
            round(coalesce(c.merchant_net_usd, c.amount_usd) * t.per_installment_pct / 100, 4) as tranche,
            coalesce((
              select sum(s2.amount_usd) from public.settlements s2
              where s2.charge_id = c.id and s2.reason <> 'staff_commission'
            ), 0)                                                  as prev_usd,
            coalesce((
              select sum(coalesce(s2.amount_cur, s2.amount_usd)) from public.settlements s2
              where s2.charge_id = c.id and s2.reason <> 'staff_commission'
            ), 0)                                                  as prev_cur,
            coalesce(c.merchant_net_usd, c.amount_usd) - coalesce((
              select sum(s2.amount_usd) from public.settlements s2
              where s2.charge_id = c.id and s2.reason <> 'staff_commission'
            ), 0)                                                  as room
          from public.installments i
          join public.charges c on c.id = i.charge_id
          cross join lateral public.helios_terms_at(
            c.merchant_id, coalesce(c.business_date, v_hoy)
          ) t
          where c.merchant_id = p_merchant_id
            and t.policy = 'scheduled'
            and i.settlement_due_date >= v_hoy
            and not exists (
              select 1 from public.settlements s3
              where s3.charge_id = c.id
                and s3.reason = 'scheduled_installment'
                and s3.business_date = i.settlement_due_date
            )
            and not public.helios_charge_of_test_patient(c.id, null)
        ) d
      ) g
    ) f
    cross join lateral public.helios_cuota_pagada(f.charge_id, f.due_date) cp
    where f.amount_usd > 0
  ) q;

  return v_rows;
end;
$function$;

-- La ficha de la orden para la clínica: en `installments`, `due_date` sigue
-- siendo la del paciente y `run_date` sale de la fecha de la clínica; en
-- `payouts`, `due_date` es el día de devengo de la mitad.
CREATE OR REPLACE FUNCTION public.merchant_charge_detail(p_charge_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_charge  public.charges%rowtype;
  v_gerente boolean;
  v_out     jsonb;
begin
  -- La secretaria que solo registra no consulta el historial (2026-10-29).
  perform public.helios_assert_ve_el_historial();

  select * into v_charge from public.charges where id = p_charge_id;

  -- El mismo error exista o no la orden.
  if not found or v_charge.merchant_id not in (select public.my_merchant_ids()) then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  v_gerente := coalesce(public.my_merchant_id_as_gerente() = v_charge.merchant_id, false);

  if not v_gerente and v_charge.requested_by is distinct from auth.uid() then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'charge_id', c.id,
    'order_number', c.order_number,
    'status', c.status::text,
    'business_date', c.business_date,
    'created_at', c.created_at,
    'confirmed_at', c.confirmed_at,
    'void_reason', c.void_reason,
    'is_test', c.is_test,
    -- El nombre del paciente, y nada más de él (ni deuda ni pagos).
    'customer_name', p.full_name,
    'staff_name', public.helios_staff_name(c.requested_by),
    'merchant_sale_usd', public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd),
    'base_usd', c.base_usd,
    'vat_usd', c.vat_usd,
    'amount_usd', c.amount_usd,
    'consumer_fee_usd', c.consumer_fee_usd,
    'consumer_fee_vat_usd', c.consumer_fee_vat_usd,
    'merchant_fee_usd', case when v_gerente then c.merchant_fee_usd end,
    'merchant_fee_vat_usd', case when v_gerente then c.merchant_fee_vat_usd end,
    'merchant_net_usd', case when v_gerente then c.merchant_net_usd end,
    -- En la moneda en la que cobró la clínica: lo que se le enseña.
    'currency', c.currency,
    'merchant_sale_cur', coalesce(c.base_cur, public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd)),
    'base_cur', c.base_cur,
    'consumer_fee_cur', c.consumer_fee_cur,
    'consumer_fee_vat_cur', c.consumer_fee_vat_cur,
    'merchant_net_cur', case when v_gerente then c.merchant_net_cur end,
    'is_gerente', v_gerente,
    'branch', case when b.id is null then null else jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address
    ) end,
    -- Helios
    'concept', c.concept,
    'beneficiary_name', c.beneficiary_name,
    'receipt', public.helios_charge_receipt(c.id),
    'staff_commission_usd', c.staff_commission_usd,
    'commission_staff_name', case when c.commission_staff_id is not null
                                  then public.helios_staff_name(c.commission_staff_id) end,
    'payer_count', 1
  )
  into v_out
  from public.charges c
  left join public.merchant_branches b on b.id = c.branch_id
  left join public.profiles p on p.id = c.user_id
  where c.id = p_charge_id;

  v_out := v_out || jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', ci.name,
      'quantity', ci.quantity,
      'unit_price_usd', ci.unit_price_usd,
      'line_total_usd', ci.line_total_usd,
      'line_total_cur', round(ci.line_total_usd * coalesce(v_charge.base_cur, v_charge.base_usd)
                              / nullif(v_charge.base_usd, 0), 2)
    ) order by ci.position, ci.created_at)
    from public.charge_items ci where ci.charge_id = p_charge_id
  ), '[]'::jsonb));

  -- Las cuotas del paciente: SOLO sus fechas (`due_date`) y cuándo se le paga a
  -- la clínica la mitad que corresponde (`run_date`, de su propia fecha). Nunca
  -- si el paciente pagó.
  v_out := v_out || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'sequence', m.seq,
      'due_date', m.due,
      'run_date', public.helios_settlement_run_for(m.cobro),
      'paid_to_merchant_on', (
        select max(coalesce(mp.paid_on, mp.business_date))
        from public.settlements s
        join public.merchant_payout_items it on it.settlement_id = s.id
        join public.merchant_payouts mp on mp.id = it.payout_id
        where s.charge_id = p_charge_id
          and s.reason = 'scheduled_installment'
          and s.business_date = m.cobro
          and s.status = 'paid'
      )
    ) order by m.seq)
    from (
      select i.sequence as seq, min(i.due_date) as due, min(i.settlement_due_date) as cobro
      from public.installments i
      where i.charge_id = p_charge_id
      group by i.sequence
    ) m
  ), '[]'::jsonb));

  -- Cuándo se le paga a la clínica cada parte: el adelanto (si lo hay), cada
  -- mitad y la comisión del personal. Los montos, solo al gerente. Cada parte
  -- en su moneda (`currency`, `amount_cur`): la consulta en la de la orden y
  -- la comisión en dólares.
  v_out := v_out || jsonb_build_object('payouts', coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', x.kind,
      'sequence', x.seq,
      'due_date', x.due,
      'run_date', public.helios_settlement_run_for(x.due),
      'amount_usd', case when v_gerente or x.kind = 'staff_commission' then x.amount end,
      'paid_usd', case when v_gerente or x.kind = 'staff_commission' then x.paid end,
      'status', case when v_gerente or x.kind = 'staff_commission' then x.status end,
      'currency', x.moneda,
      'amount_cur', case when v_gerente or x.kind = 'staff_commission' then x.amount_c end,
      'paid_cur', case when v_gerente or x.kind = 'staff_commission' then x.paid_c end
    ) order by x.due, x.seq nulls first)
    from (
      select 'advance'::text    as kind,
             null::smallint     as seq,
             s.due_date         as due,
             s.amount_usd       as amount,
             s.paid_usd         as paid,
             s.status::text     as status,
             s.currency         as moneda,
             s.amount_cur       as amount_c,
             s.paid_cur         as paid_c
      from public.settlements s
      where s.charge_id = p_charge_id and s.reason = 'advance'

      union all

      select 'installment',
             m.seq,
             m.cobro,
             s.amount_usd,
             s.paid_usd,
             s.status::text,
             coalesce(s.currency, v_charge.currency),
             s.amount_cur,
             s.paid_cur
      from (
        select i.sequence as seq, min(i.settlement_due_date) as cobro
        from public.installments i
        where i.charge_id = p_charge_id
        group by i.sequence
      ) m
      left join public.settlements s
        on s.charge_id = p_charge_id
       and s.reason = 'scheduled_installment'
       and s.business_date = m.cobro

      union all

      select 'staff_commission',
             null::smallint,
             s.due_date,
             s.amount_usd,
             s.paid_usd,
             s.status::text,
             s.currency,
             s.amount_cur,
             s.paid_cur
      from public.settlements s
      where s.charge_id = p_charge_id and s.reason = 'staff_commission'
    ) x
  ), '[]'::jsonb));

  return v_out;
end;
$function$;

-- La lista de órdenes de la clínica: `cuota_N_due` del paciente, `cuota_N_run` de
-- la clínica.
CREATE OR REPLACE FUNCTION public.merchant_transactions(p_from date, p_to date, p_limit integer DEFAULT 500)
 RETURNS TABLE(charge_id uuid, order_number bigint, business_date date, confirmed_at timestamp with time zone, amount_usd numeric, merchant_sale_usd numeric, customer_name text, staff_name text, cuota_1_due date, cuota_1_run date, cuota_2_due date, cuota_2_run date, concept text, beneficiary_name text, receipt_status text, staff_commission_usd numeric, registered_by_name text, status text, expires_at timestamp with time zone, currency text, merchant_sale_cur numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_limit      integer := greatest(least(coalesce(p_limit, 500), 500), 1);
  v_gerente_de uuid    := public.my_merchant_id_as_gerente();
  v_me         uuid    := auth.uid();
begin
  -- La secretaria que solo registra no consulta el historial (2026-10-29).
  perform public.helios_assert_ve_el_historial();

  return query
  with mias as (
    select c.id,
           c.order_number as num,
           c.business_date as bdate,
           c.confirmed_at as conf,
           c.created_at as creado,
           c.amount_usd as charged,
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale,
           c.user_id as quien,
           c.merchant_id as local,
           c.requested_by as cobro,
           c.concept as concepto,
           c.beneficiary_name as atendido,
           c.staff_commission_usd as comision,
           c.status::text as estado,
           c.expires_at as vence,
           c.currency as moneda,
           coalesce(c.base_cur, public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd)) as sale_cur
    from public.charges c
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status in ('confirmed', 'pending', 'declined', 'expired')
      and c.business_date between p_from and p_to
      -- El gerente de ESA clínica ve todos; cualquier otro, solo los suyos.
      and (c.merchant_id = v_gerente_de or c.requested_by = v_me)
    order by c.business_date desc, coalesce(c.confirmed_at, c.created_at) desc
    limit v_limit
  ),
  cuotas as (
    select (m.id)                                                  as cid,
           (x->>'sequence')::integer                               as seq,
           (x->>'due_date')::date                                  as due,
           public.helios_settlement_run_for((x->>'settlement_due_date')::date) as run
    from mias m
    cross join lateral jsonb_array_elements(public.helios_charge_planned_installments(m.id)) x
  )
  select m.id,
         m.num,
         m.bdate,
         m.conf,
         m.charged,
         m.sale,
         p.full_name,
         case when m.local = v_gerente_de or m.cobro = v_me
              then public.helios_staff_name(m.cobro) end,
         c1.due,
         c1.run,
         c2.due,
         c2.run,
         m.concepto,
         m.atendido,
         case when m.estado = 'confirmed' then public.helios_charge_receipt(m.id) ->> 'status'
              else 'sin_enviar' end,
         m.comision,
         case when m.local = v_gerente_de or m.cobro = v_me
              then public.helios_staff_name(m.cobro) end,
         m.estado,
         case when m.estado in ('pending', 'expired') then m.vence end,
         m.moneda,
         m.sale_cur
  from mias m
  left join public.profiles p on p.id = m.quien
  left join cuotas c1 on c1.cid = m.id and c1.seq = 1
  left join cuotas c2 on c2.cid = m.id and c2.seq = 2
  order by m.bdate desc, coalesce(m.conf, m.creado) desc;
end;
$function$;

-- La descarga de la clínica: igual.
CREATE OR REPLACE FUNCTION public.merchant_sales_export(p_from date, p_to date)
 RETURNS TABLE(order_number bigint, charge_id uuid, business_date date, confirmed_at timestamp with time zone, branch_name text, cashier text, status text, void_reason text, group_name text, payer_count integer, item_count integer, base_usd numeric, vat_pct numeric, vat_usd numeric, sale_usd numeric, consumer_fee_pct numeric, consumer_fee_usd numeric, consumer_fee_vat_usd numeric, charged_to_customer_usd numeric, merchant_fee_pct numeric, merchant_fee_usd numeric, merchant_fee_vat_usd numeric, net_to_merchant_usd numeric, fx_rate numeric, sale_ves numeric, charged_to_customer_ves numeric, net_to_merchant_ves numeric, cuota_1_due date, cuota_1_run date, cuota_2_due date, cuota_2_run date, settled_usd numeric, paid_usd numeric, is_test boolean, concept text, beneficiary_name text, staff_commission_usd numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_max      integer := 20000;
  v_count    bigint;
begin
  if v_merchant is null then
    raise exception 'Solo el administrador de la clínica puede descargar sus pagos en cuotas'
      using errcode = '42501';
  end if;

  select count(*) into v_count
  from public.charges c
  where c.merchant_id = v_merchant
    and c.business_date between p_from and p_to
    and c.status in ('confirmed', 'reverted');

  perform public.helios_assert_sales_export(p_from, p_to, v_count, v_max);

  return query
  with ventas as (
    select c.*,
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale,
           public.current_fx_rate('BCV', c.business_date) as rate
    from public.charges c
    where c.merchant_id = v_merchant
      and c.business_date between p_from and p_to
      and c.status in ('confirmed', 'reverted')
  ),
  cuotas as (
    select i.charge_id as cid,
           i.sequence  as seq,
           min(i.due_date) as due,
           public.helios_settlement_run_for(min(i.settlement_due_date)) as run
    from public.installments i
    join ventas v on v.id = i.charge_id
    group by i.charge_id, i.sequence
  ),
  lineas as (
    select ci.charge_id as cid, count(*)::integer as n
    from public.charge_items ci
    join ventas v on v.id = ci.charge_id
    group by ci.charge_id
  ),
  liquidado as (
    -- Lo liquidado por la VENTA: la comisión del personal va en su columna.
    select s.charge_id as cid,
           sum(s.amount_usd) as programado,
           sum(coalesce(s.paid_usd, 0)) as pagado
    from public.settlements s
    join ventas v on v.id = s.charge_id
    where s.reason <> 'staff_commission'
    group by s.charge_id
  )
  select
    v.order_number,
    v.id,
    v.business_date,
    v.confirmed_at,
    b.name,
    public.helios_staff_name(v.requested_by),
    v.status::text,
    v.void_reason,
    v.group_name,
    1,
    coalesce(l.n, 0),
    round(coalesce(v.base_usd, 0), 2),
    coalesce(v.vat_pct, 0),
    round(coalesce(v.vat_usd, 0), 2),
    round(v.sale, 2),
    coalesce(v.consumer_fee_pct, 0),
    round(coalesce(v.consumer_fee_usd, 0), 2),
    round(coalesce(v.consumer_fee_vat_usd, 0), 2),
    round(v.amount_usd, 2),
    coalesce(v.merchant_fee_pct, 0),
    round(coalesce(v.merchant_fee_usd, 0), 2),
    round(coalesce(v.merchant_fee_vat_usd, 0), 2),
    round(coalesce(v.merchant_net_usd, v.sale), 2),
    v.rate,
    round(v.sale * v.rate, 2),
    round(v.amount_usd * v.rate, 2),
    round(coalesce(v.merchant_net_usd, v.sale) * v.rate, 2),
    c1.due, c1.run,
    c2.due, c2.run,
    round(coalesce(s.programado, 0), 2),
    round(coalesce(s.pagado, 0), 2),
    v.is_test,
    v.concept,
    v.beneficiary_name,
    v.staff_commission_usd
  from ventas v
  left join public.merchant_branches b on b.id = v.branch_id
  left join lineas l on l.cid = v.id
  left join liquidado s on s.cid = v.id
  left join cuotas c1 on c1.cid = v.id and c1.seq = 1
  left join cuotas c2 on c2.cid = v.id and c2.seq = 2
  order by v.business_date, v.confirmed_at, v.order_number;
end;
$function$;

-- El plan de cuotas: ahora con las dos fechas, también en las órdenes pendientes.
CREATE OR REPLACE FUNCTION public.helios_charge_planned_installments(p_charge_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_c       public.charges%rowtype;
  v_out     jsonb;
  v_due_1   date;
  v_due_2   date;
  v_total   numeric(18,4);
  v_base    numeric(18,4);
  v_first   numeric(18,4);
  v_fin_1   numeric(18,4);
  v_total_c numeric(18,4);
  v_base_c  numeric(18,4);
  v_first_c numeric(18,4);
  v_fin_1_c numeric(18,4);
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'sequence', x.sequence, 'due_date', x.due_date,
           'settlement_due_date', x.settlement_due_date,
           'amount_usd', x.amount_usd, 'financed_usd', x.financed_usd,
           'amount_cur', x.amount_cur, 'financed_cur', x.financed_cur)
         order by x.sequence), null)
    into v_out
  from (
    select i.sequence, min(i.due_date) as due_date,
           min(i.settlement_due_date) as settlement_due_date,
           sum(i.amount_usd) as amount_usd, sum(i.financed_usd) as financed_usd,
           sum(coalesce(i.amount_cur, i.amount_usd)) as amount_cur,
           sum(coalesce(i.financed_cur, i.financed_usd)) as financed_cur
    from public.installments i where i.charge_id = p_charge_id group by i.sequence
  ) x;

  if v_out is not null then
    return v_out;
  end if;

  select * into v_c from public.charges where id = p_charge_id;
  if not found then
    return '[]'::jsonb;
  end if;

  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_c.business_date);
  v_total   := v_c.amount_usd;
  v_base    := coalesce(v_c.base_usd, v_c.amount_usd);
  v_first   := round(v_total / 2, 2);
  v_fin_1   := round(v_base / 2, 2);
  v_total_c := coalesce(v_c.amount_cur, v_c.amount_usd);
  v_base_c  := coalesce(v_c.base_cur, v_c.base_usd, v_c.amount_usd);
  v_first_c := round(v_total_c / 2, 2);
  v_fin_1_c := round(v_base_c / 2, 2);

  return jsonb_build_array(
    jsonb_build_object('sequence', 1, 'due_date', v_due_1,
                       'settlement_due_date', v_c.business_date + public.helios_settlement_interval_days(),
                       'amount_usd', v_first, 'financed_usd', v_fin_1,
                       'amount_cur', v_first_c, 'financed_cur', v_fin_1_c),
    jsonb_build_object('sequence', 2, 'due_date', v_due_2,
                       'settlement_due_date', v_c.business_date + public.helios_settlement_interval_days() * 2,
                       'amount_usd', v_total - v_first,
                       'financed_usd', v_base - v_fin_1,
                       'amount_cur', v_total_c - v_first_c, 'financed_cur', v_base_c - v_fin_1_c)
  );
end;
$function$;

-- La comisión del personal sale con la primera mitad, día 8.
CREATE OR REPLACE FUNCTION public.helios_accrue_staff_commission(p_charge_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'pg_temp'
AS $function$
declare
  v_c   public.charges%rowtype;
  v_id  uuid;
  v_tx  uuid;
  v_set uuid;
  v_due date;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found or v_c.status <> 'confirmed' then
    raise exception 'El financiamiento no está confirmado' using errcode = '22023';
  end if;

  if coalesce(v_c.staff_commission_usd, 0) <= 0 or v_c.commission_staff_id is null then
    return null;
  end if;

  -- Una consulta de práctica no le gana nada a la secretaria.
  if public.helios_charge_of_test_patient(p_charge_id, null) then
    return null;
  end if;

  select id into v_id from public.staff_commissions where charge_id = p_charge_id;
  if found then
    return v_id;
  end if;

  -- Vence con la primera mitad de la consulta (no con la cuota del paciente)
  -- y sale en su mismo pago (`helios_settlement_run_for`). Las cuotas ya
  -- existen: `helios_assign_debt` va antes en el alta.
  select min(i.settlement_due_date) into v_due from public.installments i where i.charge_id = p_charge_id;
  v_due := coalesce(v_due, v_c.business_date + public.helios_settlement_interval_days());

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('staff_commission', 'staff_commission:' || p_charge_id::text, v_c.business_date, p_charge_id,
          'Comisión del personal de la clínica')
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, ledger.get_or_create_account('commission_expense', null), v_c.staff_commission_usd, 0),
    (v_tx, ledger.get_or_create_account('merchant_payable', v_c.merchant_id), 0, v_c.staff_commission_usd);

  insert into public.settlements
    (merchant_id, charge_id, reason, amount_usd, business_date, due_date, status)
  values
    (v_c.merchant_id, p_charge_id, 'staff_commission', v_c.staff_commission_usd,
     v_c.business_date, v_due, 'pending')
  returning id into v_set;

  insert into public.staff_commissions (charge_id, merchant_id, staff_user_id, amount_usd, settlement_id)
  values (p_charge_id, v_c.merchant_id, v_c.commission_staff_id, v_c.staff_commission_usd, v_set)
  returning id into v_id;

  return v_id;
end;
$function$;

-- Si el paciente ya pagó la cuota que corresponde a una mitad.
CREATE OR REPLACE FUNCTION public.helios_cuota_pagada(p_charge_id uuid, p_due_date date)
 RETURNS TABLE(cuotas integer, cuotas_pagadas integer, paid_on date, fx_rate numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select
    count(*)::integer,
    count(*) filter (where i.status = 'paid')::integer,
    (max(i.paid_at) filter (where i.status = 'paid') at time zone 'America/Caracas')::date,
    -- La del último pago: en una orden de un solo paciente es la única.
    (array_agg(
       case coalesce(qi.currency, c.currency) when 'EUR' then q.fx_rate_eur else q.fx_rate end
       order by i.paid_at desc nulls last
     ) filter (where i.status = 'paid'))[1]
  from public.installments i
  join public.charges c on c.id = i.charge_id
  left join public.payment_reports r on r.id = i.paid_by_report_id
  left join public.payment_quotes q on q.id = r.quote_id
  left join public.payment_quote_items qi on qi.quote_id = q.id and qi.installment_id = i.id
  where i.charge_id = p_charge_id
    -- `p_due_date` es el día de devengo de la mitad (`settlement_due_date`), no
    -- el vencimiento de la cuota: es lo que le pasan sus dos llamadores.
    and i.settlement_due_date = p_due_date
$function$;

-- Solo cambia un comentario (decía «+7 y +14»).
CREATE OR REPLACE FUNCTION public.helios_finalize_charge(p_charge_id uuid, p_welcome_channel text, p_over_limit_message text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'pg_temp'
AS $function$
declare
  v_charge   public.charges%rowtype;
  v_terms    public.merchant_terms%rowtype;
  v_due_1    date;
  v_due_2    date;
  v_financed numeric(18,4);
  v_revenue  numeric(18,4);
  v_share    numeric(18,4);
  v_tx       uuid;
  v_cuotas   text;
  v_merchant text;
  v_rate     numeric;
  v_demo     boolean;
  v_first    public.installments%rowtype;
begin
  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Orden no encontrada' using errcode = 'P0002';
  end if;

  if v_charge.status = 'pending' then
    update public.charges
       set status = 'confirmed', confirmed_at = now()
     where id = p_charge_id
    returning * into v_charge;
  end if;

  if v_charge.status <> 'confirmed' or v_charge.user_id is null then
    raise exception 'La orden no se puede confirmar' using errcode = '22023';
  end if;

  select * into v_terms from public.helios_terms_at(v_charge.merchant_id, v_charge.business_date);
  if v_terms.id is null then
    raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
      using errcode = '22023';
  end if;

  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_charge.business_date);

  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);
  v_revenue  := coalesce(v_charge.consumer_fee_usd, 0) + coalesce(v_charge.merchant_fee_usd, 0);
  v_share    := coalesce(v_charge.merchant_net_usd, v_charge.amount_usd - v_revenue);

  -- Una orden de capacitación no es dinero y no deja asiento; así se puede
  -- borrar entera a medianoche sin tocar el libro.
  select p.is_demo into v_demo from public.profiles p where p.id = v_charge.user_id;

  if not coalesce(v_demo, false) then
    -- El asiento de cuatro patas, saltándose las que valen cero. En dólares.
    insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
    values ('charge', 'charge:' || v_charge.idempotency_key, v_charge.business_date, v_charge.id,
            'Financiamiento de consulta')
    returning id into v_tx;

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    select v_tx, x.acct, x.debit, x.credit
    from (values
      (ledger.get_or_create_account('user_receivable', v_charge.user_id), v_charge.amount_usd, 0::numeric),
      (ledger.get_or_create_account('merchant_payable', v_charge.merchant_id), 0::numeric, v_share),
      (ledger.get_or_create_account('platform_revenue', null), 0::numeric, v_revenue),
      (ledger.get_or_create_account('vat_payable', null), 0::numeric,
       v_charge.amount_usd - v_share - v_revenue)
    ) as x(acct, debit, credit)
    where x.debit <> 0 or x.credit <> 0;

    -- El adelanto a la clínica (no hace nada con upfront_pct = 0).
    perform ledger.record_advance_settlement(
      v_charge.merchant_id, v_charge.id, round(v_share * v_terms.upfront_pct / 100, 4), v_charge.business_date);
  end if;

  -- La deuda: las 2 cuotas (a los días del intervalo vigente en la fecha de la
  -- orden, `helios_installment_due_dates`) y el bloque de crédito. Cada cuota
  -- se pone sola su monto en la moneda de la orden (trigger
  -- `installments_currency`) y el día en que se le devenga a la clínica su
  -- mitad (trigger `installments_settlement_due_date`).
  perform public.helios_assign_debt(
    v_charge.user_id, v_charge.id, v_financed, v_charge.amount_usd, v_due_1, v_due_2,
    coalesce(p_over_limit_message, public.helios_not_available_message()));

  -- La comisión de quien lo registró.
  perform public.helios_accrue_staff_commission(v_charge.id);

  -- Los mensajes: el comprobante (al correo REGISTRADO) y la bienvenida.
  perform public.helios_enqueue_charge_receipt(v_charge.id);

  v_rate := public.helios_fx_rate(v_charge.currency);

  select m.name into v_merchant from public.merchants m where m.id = v_charge.merchant_id;
  -- NUEVO (2026-10-19): «1️⃣ $56,96 · lunes 26/10», sin bolívares (van en el
  -- bloque de pago).
  select string_agg(format('%s %s · %s',
                           case i.sequence when 1 then '1️⃣' when 2 then '2️⃣' when 3 then '3️⃣'
                                           else i.sequence::text || '.' end,
                           public.helios_money_cur_text(i.amount_cur, v_charge.currency),
                           public.helios_weekday_es(i.due_date) || ' ' || to_char(i.due_date, 'DD/MM')),
                    E'\n' order by i.sequence)
    into v_cuotas
  from public.installments i where i.charge_id = v_charge.id;

  select * into v_first from public.installments i
  where i.charge_id = v_charge.id order by i.sequence limit 1;

  perform public.helios_enqueue_message(
    'bienvenida', v_charge.user_id, v_charge.id, p_welcome_channel,
    jsonb_build_object(
      'clinica', v_merchant,
      'medico', public.helios_doctor_ref(v_charge.merchant_id),
      'orden', v_charge.order_number::text,
      'cuotas', v_cuotas,
      'moneda', public.helios_currency_name(v_charge.currency),
      'bloque_de_pago', public.helios_payment_block(
        case when v_rate is not null then round(v_first.amount_cur * v_rate, 2) end,
        public.helios_money_cur_text(v_first.amount_cur, v_charge.currency),
        public.helios_currency_name(v_charge.currency),
        public.helios_por_whatsapp(p_welcome_channel))),
    null, 'bienvenida:' || v_charge.id::text);
end;
$function$;
