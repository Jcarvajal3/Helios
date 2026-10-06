-- ============================================================================
-- Helios — Métricas › Locales mira la semana de pagos, no el lunes
--
-- `metricas.locales_cierre(p_cierre)` recibe el lunes siguiente a la semana
-- (`admin_metricas_locales`: `v_cierre := v_domingo + 1`) y contaba lo que
-- se pagaba ESE lunes. Desde 20261006001200 a la clínica se le paga a diario
-- (el día siguiente a cada vencimiento), así que «generado» solo habría
-- contado lo vencido el domingo mientras «previsto» seguía cubriendo toda la
-- semana. Ahora las tres cifras miran la misma ventana: lo que se paga de
-- martes a lunes, que es lo de las cuotas que vencen de lunes a domingo.
-- «Atrasado» es lo de semanas anteriores sin transferir.
-- ============================================================================

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
  -- que es lo de las cuotas que vencieron de lunes a domingo.
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
          i.due_date,
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
          and i.due_date >= cal.hoy
          and p_cierre > cal.hoy
          and not exists (
            select 1 from public.settlements s3
            where s3.charge_id = c.id
              and s3.reason = 'scheduled_installment'
              and s3.business_date = i.due_date
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
$function$
;
