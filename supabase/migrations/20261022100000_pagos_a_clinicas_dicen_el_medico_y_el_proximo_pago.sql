-- ============================================================================
-- Helios — Pagos a clínicas dicen el médico y el próximo pago
--
-- Javier (2026-10-22): en Pagos a clínicas el dato principal es el médico
-- titular, no el nombre de la clínica; y cada clínica tiene que decir su
-- próximo pago (el siguiente día con algo que transferirle, con las mitades
-- de la consulta y las comisiones sumadas) para que el equipo se organice
-- antes de que toque.
--
-- `admin_merchant_payables` añade, sin quitar nada:
--   doctor_name               el titular con su título (`helios_doctor_name`;
--                             sin titular, el nombre de la clínica).
--   next_pay_date             el primer día de pago DESPUÉS del de hoy con algo
--                             que pagar. null si no hay.
--   next_pay_usd              lo de ese día: las liquidaciones que ya existen
--                             y las mitades por vencer
--                             (`admin_merchant_upcoming_settlements`).
--   next_pay_consultas_usd    de eso, consultas.
--   next_pay_comisiones_usd   de eso, comisiones del personal.
--
-- Lo de hoy sigue en `next_run_usd` y su reparto en `next_run_consultas_usd`
-- y `next_run_comisiones_usd` (ya venían de `helios_settlement_outlook`).
-- ============================================================================

create or replace function public.admin_merchant_payables(p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.total_pending_usd desc), '[]'::jsonb)
  into v_rows
  from (
    select
      m.id     as merchant_id,
      m.name   as merchant_name,
      m.tax_id,
      m.is_test,
      -- NUEVO: el médico titular, que es como lo conoce el equipo.
      public.helios_doctor_name(m.id) as doctor_name,
      o.*,
      -- Helios: lo devengado y sin transferir, partido (docs/01 §2.5).
      o.accrued_consultas_usd  as consultas_usd,
      o.accrued_comisiones_usd as comisiones_usd,
      -- NUEVO: el próximo pago, después del de hoy.
      np.run_date              as next_pay_date,
      coalesce(np.usd, 0)       as next_pay_usd,
      coalesce(np.consultas, 0) as next_pay_consultas_usd,
      coalesce(np.comisiones, 0) as next_pay_comisiones_usd
    from public.merchants m
    cross join lateral public.helios_settlement_outlook(m.id) o
    left join lateral (
      select
        l.run_date,
        sum(l.usd)                                                as usd,
        coalesce(sum(l.usd) filter (where l.reason <> 'staff_commission'), 0) as consultas,
        coalesce(sum(l.usd) filter (where l.reason = 'staff_commission'), 0)  as comisiones
      from (
        -- Lo que ya es liquidación y sale otro día.
        select public.helios_settlement_run_for(coalesce(s.due_date, s.business_date)) as run_date,
               s.reason::text                                                       as reason,
               s.amount_usd - s.paid_usd                                            as usd
        from public.settlements s
        where s.merchant_id = m.id
          and s.status in ('pending', 'partial')
        union all
        -- Las mitades de la consulta que el cron todavía no ha creado.
        select (u->>'run_date')::date, u->>'reason', (u->>'amount_usd')::numeric
        from jsonb_array_elements(public.admin_merchant_upcoming_settlements(m.id)) u
      ) l
      where l.run_date > o.next_run_date
        and l.usd > 0.005
      group by l.run_date
      order by l.run_date
      limit 1
    ) np on true
    where (o.accrued_usd > 0 or o.upcoming_usd > 0)
      and (p_merchant_id is null or m.id = p_merchant_id)
  ) q;

  return v_rows;
end;
$function$;
