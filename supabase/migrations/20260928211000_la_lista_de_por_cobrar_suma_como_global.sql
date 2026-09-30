-- ============================================================================
-- Ronda — La Lista de Por cobrar suma lo mismo que Métricas › Global
--
-- Javier (28-09): la cifra de encima de la Lista tiene que ser el total por
-- cobrar, no solo lo de la semana. Dos cambios en admin_collections:
--
--   1. El horizonte admite hasta 3650 días (antes 30): la Lista pide todo lo
--      que queda por vencer. Inicio y la insignia siguen pidiendo 7.
--   2. Cada fila lleva lost_usd y lost_financed_usd: la parte de lo vencido
--      dada por perdida. overdue_usd la sigue llevando dentro (la cola la
--      sigue cobrando), y la Lista la resta del total y la enseña aparte, como
--      Global, que no la cuenta en «Por cobrar».
--
-- Copia de 20260928201000 con solo eso cambiado; la firma no cambia.
-- ============================================================================

create or replace function public.admin_collections(
  p_horizon_days integer default 3,
  p_merchant_id  uuid    default null,
  p_cohorte      date    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today     date    := public.helios_business_date(now());
  -- Hasta diez años: la Lista de Por cobrar pide todo lo que queda, para que
  -- su total sea el de Métricas › Global.
  v_horizon   integer := greatest(least(coalesce(p_horizon_days, 3), 3650), 0);
  v_demotion  integer := public.helios_mora_demotion_days();
  v_expulsion integer := public.helios_mora_expulsion_days();
  v_rows      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  with
  filas as (
    select r
    from public.helios_collection_rows(v_today, v_horizon) r
    where p_merchant_id is null
       or exists (
         select 1
         from public.installments i
         join public.charges c on c.id = i.charge_id
         where i.user_id = (r ->> 'user_id')::uuid
           and i.status = 'pending'
           and not i.is_test
           and i.due_date <= v_today + v_horizon
           and c.merchant_id = p_merchant_id)
  ),
  de_la_cohorte as materialized (
    select f.r
    from filas f
    where p_cohorte is null
       or exists (
         select 1
         from public.installments i
         join public.charges c on c.id = i.charge_id
         where i.user_id = (f.r ->> 'user_id')::uuid
           and i.status = 'pending'
           and not i.is_test
           and i.due_date < v_today
           and c.business_date between metricas.lunes(p_cohorte) and metricas.lunes(p_cohorte) + 6
           and (p_merchant_id is null or c.merchant_id = p_merchant_id))
  ),
  perfiles as materialized (
    select pd.*
    from metricas.perfil_deudor() pd
  ),
  senales as materialized (
    select s.*
    from metricas.senales_deudor(array(select (r ->> 'user_id')::uuid from de_la_cohorte)) s
  )
  select coalesce(
           jsonb_agg(
             f.r || jsonb_build_object(
               'perfil',    p.perfil,
               'prioridad', p.prioridad,
               'orden',     p.orden,
               'motivo',    p.motivo,
               'overdue_financed_usd',  d.vencido_financed,
               'overdue_fee_usd',       coalesce((f.r ->> 'overdue_usd')::numeric, 0) - d.vencido_financed,
               'upcoming_financed_usd', d.por_vencer_financed,
               'upcoming_fee_usd',      coalesce((f.r ->> 'upcoming_usd')::numeric, 0) - d.por_vencer_financed,
               -- De lo vencido, lo dado por perdido: sigue en la cola, pero
               -- Métricas no lo cuenta como por cobrar y la Lista lo enseña aparte.
               'lost_usd',              d.perdido_payable,
               'lost_financed_usd',     d.perdido_financed,
               'senales', coalesce(s.senales, '{}'::jsonb) || jsonb_build_object(
                 'cuotas_pagadas',          p.cuotas_pagadas,
                 'pagadas_a_tiempo',        p.pagadas_a_tiempo,
                 'pagadas_tarde',           p.pagadas_tarde,
                 'atraso_medio_al_pagar',   p.atraso_medio_al_pagar,
                 'promesas_rotas',          p.promesas_rotas,
                 'ultima_promesa_rota',     p.ultima_promesa_rota,
                 'gestiones_sin_respuesta', p.gestiones_sin_respuesta,
                 'reportes_rechazados',     p.reportes_rechazados))
             order by (f.r ->> 'next_due_date')::date, (f.r ->> 'open_usd')::numeric desc, f.r ->> 'user_id'),
           '[]'::jsonb)
    into v_rows
  from de_la_cohorte f
  left join perfiles p on p.user_id = (f.r ->> 'user_id')::uuid
  left join senales  s on s.user_id = (f.r ->> 'user_id')::uuid
  cross join lateral (
    select
      coalesce(sum(i.financed_usd) filter (where i.due_date <  v_today), 0) as vencido_financed,
      coalesce(sum(i.financed_usd) filter (where i.due_date >= v_today), 0) as por_vencer_financed,
      coalesce(sum(i.amount_usd)   filter (where i.due_date <  v_today and i.written_off_at is not null), 0) as perdido_payable,
      coalesce(sum(i.financed_usd) filter (where i.due_date <  v_today and i.written_off_at is not null), 0) as perdido_financed
    from public.installments i
    where i.user_id = (f.r ->> 'user_id')::uuid
      and i.status = 'pending'
      and not i.is_test
      and i.due_date <= v_today + v_horizon
  ) d;

  return jsonb_build_object(
    'business_date', v_today,
    'merchant_id', p_merchant_id,
    'cohorte', case when p_cohorte is not null then metricas.lunes(p_cohorte) end,
    'umbrales_perfil', (select to_jsonb(u) from metricas.perfil_deudor_umbrales() u),
    'demotion_days', v_demotion,
    'expulsion_days', v_expulsion,
    'rows', v_rows
  );
end;
$$;

comment on function public.admin_collections(integer, uuid, date) is
  'Cola de cobranza por persona, con su tramo, lo que debe (PAYABLE, con lo dado por perdido dentro, y aparte en lost_usd y lost_financed_usd) con su desglose (overdue_/upcoming_ financed_usd y fee_usd), la ultima gestion, su perfil de deudor (perfil, prioridad, orden, motivo) y sus senales (metricas.senales_deudor + la historia del perfil). Con p_merchant_id, las personas que deben algo de ese local; con p_cohorte (un lunes), las que deben algo vencido de consumos de esa semana. Los umbrales viajan fuera de las filas.';

revoke all on function public.admin_collections(integer, uuid, date) from public, anon;
grant execute on function public.admin_collections(integer, uuid, date) to authenticated, service_role;
