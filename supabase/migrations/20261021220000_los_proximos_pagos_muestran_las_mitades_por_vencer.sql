-- ============================================================================
-- Helios — Los próximos pagos muestran las mitades de la consulta por vencer
--
-- En Pagos a clínicas › una clínica, la lista «Por día de pago» solo enseña
-- filas de `settlements`. La mitad de una consulta no es fila hasta que vence
-- su cuota (la crea `run_scheduled_settlements` ese día), y la comisión del
-- personal sí lo es desde la confirmación (20261021190000): los días que
-- vienen salían solo con la comisión, sin la consulta. Javier (2026-10-21):
-- que se vean las mitades por vencer, calculadas de las cuotas y sumadas a
-- las comisiones de su día, sin poder pagarlas antes de su día.
--
-- `admin_merchant_upcoming_settlements(p_merchant_id)`: una línea por mitad
-- que todavía no existe, con el mismo cálculo que la parte 2 de
-- `helios_settlement_outlook` («Por pagar en los próximos días») y el de
-- `run_scheduled_settlements_batch` (tramo, tope del neto) y con la forma de
-- `admin_merchant_settlements`. Solo lectura: no crea nada. Sin `id`: no es
-- una liquidación y no se puede meter en una transferencia.
--
-- Se dejan fuera las de pacientes de prueba, que el trigger
-- `settlements_aa_paciente_de_prueba` nunca dejará nacer.
-- ============================================================================

create or replace function public.admin_merchant_upcoming_settlements(p_merchant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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
      f.order_number
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
            i.due_date,
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
            and i.due_date >= v_hoy
            and not exists (
              select 1 from public.settlements s3
              where s3.charge_id = c.id
                and s3.reason = 'scheduled_installment'
                and s3.business_date = i.due_date
            )
            and not public.helios_charge_of_test_patient(c.id, null)
        ) d
      ) g
    ) f
    where f.amount_usd > 0
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_merchant_upcoming_settlements(uuid) from public, anon;
grant execute on function public.admin_merchant_upcoming_settlements(uuid) to authenticated, service_role;
