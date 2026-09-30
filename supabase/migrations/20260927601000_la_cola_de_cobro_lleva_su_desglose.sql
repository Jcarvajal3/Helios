-- ============================================================================
-- Ronda — La cola de Por cobrar lleva el desglose de lo que debe cada persona
--
-- Regla del fee (CORRECCIONES §2 de Métricas, 27-09): una cifra que lleva el
-- service fee dentro se enseña SIEMPRE con su desglose a la vista. La cola
-- enseñaba «Deuda vencida €45,20» sin decir de qué estaba hecha.
--
-- admin_collections gana, en cada fila, overdue_financed_usd, overdue_fee_usd,
-- upcoming_financed_usd y upcoming_fee_usd: la misma cuenta que overdue_usd y
-- upcoming_usd (helios_collection_rows, que no se toca), partida en consumo y
-- service fee con su IVA. Ninguna clave se quita y la firma no cambia.
--
-- Copiada de 20260927551000 con solo el desglose añadido.
-- ============================================================================

create or replace function public.admin_collections(
  p_horizon_days integer default 3,
  p_merchant_id  uuid    default null,
  -- El lunes de una semana de consumo: solo la gente que debe algo VENCIDO de
  -- consumos de esa semana (el enlace «Quién debe de esta semana» de Cohortes).
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
  v_horizon   integer := greatest(least(coalesce(p_horizon_days, 3), 30), 0);
  v_demotion  integer := public.helios_mora_demotion_days();
  v_expulsion integer := public.helios_mora_expulsion_days();
  v_rows      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- El orden de siempre: el vencimiento más antiguo primero (el mayor
  -- atraso) y el que más debe. El panel puede ordenar por `orden`, que es la
  -- prioridad del perfil del deudor.
  with
  filas as (
    select r
    from public.helios_collection_rows(v_today, v_horizon) r
    -- Con un local: las personas que deben algo de ese local en el horizonte.
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
  -- Con una cohorte: quien debe algo vencido de consumos de esa semana. Las
  -- cuotas vencidas son las de la cola (pendientes y con el día pasado).
  de_la_cohorte as (
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
    select pd.user_id, pd.perfil, pd.prioridad, pd.orden, pd.motivo
    from metricas.perfil_deudor() pd
  )
  select coalesce(
           jsonb_agg(
             f.r || jsonb_build_object(
               'perfil',    p.perfil,
               'prioridad', p.prioridad,
               'orden',     p.orden,
               'motivo',    p.motivo,
               -- El desglose de lo que debe: la misma cuenta que overdue_usd y
               -- upcoming_usd de helios_collection_rows, partida en consumo
               -- (financed) y service fee con su IVA (payable − financed).
               'overdue_financed_usd',  d.vencido_financed,
               'overdue_fee_usd',       coalesce((f.r ->> 'overdue_usd')::numeric, 0) - d.vencido_financed,
               'upcoming_financed_usd', d.por_vencer_financed,
               'upcoming_fee_usd',      coalesce((f.r ->> 'upcoming_usd')::numeric, 0) - d.por_vencer_financed)
             order by (f.r ->> 'next_due_date')::date, (f.r ->> 'open_usd')::numeric desc, f.r ->> 'user_id'),
           '[]'::jsonb)
    into v_rows
  from de_la_cohorte f
  left join perfiles p on p.user_id = (f.r ->> 'user_id')::uuid
  -- Las mismas cuotas que suma helios_collection_rows: pendientes, reales y
  -- que vencen dentro del horizonte (lo dado por perdido va dentro, como en
  -- overdue_usd).
  cross join lateral (
    select
      coalesce(sum(i.financed_usd) filter (where i.due_date <  v_today), 0) as vencido_financed,
      coalesce(sum(i.financed_usd) filter (where i.due_date >= v_today), 0) as por_vencer_financed
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
    -- Los umbrales de los perfiles, para que la pantalla los explique con
    -- los números de verdad.
    'umbrales_perfil', (select to_jsonb(u) from metricas.perfil_deudor_umbrales() u),
    'demotion_days', v_demotion,
    'expulsion_days', v_expulsion,
    'rows', v_rows
  );
end;
$$;

comment on function public.admin_collections(integer, uuid, date) is
  'Cola de cobranza por persona, con su tramo, lo que debe (PAYABLE, con lo dado por perdido dentro, como siempre) con su desglose (overdue_/upcoming_ financed_usd y fee_usd: consumo y service fee con su IVA) y la ultima gestion. Cada fila lleva su perfil de deudor (metricas.perfil_deudor): perfil, prioridad, orden y motivo. Con p_merchant_id, las personas que deben algo de ese local; con p_cohorte (un lunes), las que deben algo vencido de consumos de esa semana; en los dos casos con sus importes de siempre (la cola es por persona). Los umbrales viajan fuera de las filas.';

revoke all on function public.admin_collections(integer, uuid, date) from public, anon;
grant execute on function public.admin_collections(integer, uuid, date) to authenticated, service_role;
