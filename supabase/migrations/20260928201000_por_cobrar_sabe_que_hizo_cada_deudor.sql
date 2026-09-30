-- ============================================================================
-- Ronda — Por cobrar sabe qué hizo cada deudor, y quién debe de cada semana
--
-- Rediseño de Por cobrar (Javier, 28-09):
--
--   1. metricas.senales_deudor(uuid[]): los hechos con fecha que quien cobra
--      mira antes de escribir. Cuándo abrió la app, si le llegan los avisos,
--      si entró a pagar o copió los datos, si abrió los avisos de cuota, su
--      último pago reportado y si tiene uno en revisión. Son hechos, no
--      etiquetas: el panel decide cómo se leen (features/admin/cobranza/senales.ts).
--
--   2. admin_collections: cada fila lleva `senales`, con esos hechos y los de
--      su historia que ya calcula metricas.perfil_deudor (cuotas pagadas, a
--      tiempo, atraso medio, promesas rotas, gestiones sin respuesta). Copiada
--      de 20260927601000; la firma y las claves de antes no cambian.
--
--   3. admin_deudores_de_la_semana(semana, local): Por cobrar › Por semana.
--      Quien debe algo (vencido, por vencer o dado por perdido) de lo
--      consumido esa semana, con lo que debe DE ESA SEMANA cuota a cuota y su
--      fila de la cartera entera (horizonte de 30 días), perfil y señales.
--      Las cuotas salen de metricas.cuotas, la misma fuente que las cifras de
--      la semana (admin_metricas_cohorte): la suma de lo vencido y lo por
--      vencer de esta lista es la de las tarjetas de arriba.
--
-- Todo lo que se cobra va con el fee dentro (Javier, 28-09: «cuando se trate
-- de cobranza debemos incluir el fee, ya que eso lo tenemos que cobrar») y
-- siempre con sus dos partes: financed (consumo) y fee (service fee + IVA).
-- ============================================================================

-- ─── 1. Las señales ──────────────────────────────────────────────────────────

create or replace function metricas.senales_deudor(p_users uuid[])
returns table (user_id uuid, senales jsonb)
language sql
stable
set search_path = public, pg_temp
as $$
  with
  u as (select distinct x as user_id from unnest(p_users) x where x is not null),
  hoy as (select public.helios_business_date(now()) as dia),
  -- Desde cuándo debe algo vencido: su cuota pendiente más vieja ya vencida
  -- (sin lo dado por perdido). Los avisos se cuentan desde ese día.
  vence as (
    select i.user_id, min(i.due_date) as desde
    from public.installments i
    join u using (user_id)
    cross join hoy
    where i.status = 'pending'
      and not i.is_test
      and i.written_off_at is null
      and i.due_date < hoy.dia
    group by i.user_id
  ),
  -- El token de push se registra en cada arranque: su last_seen_at es la
  -- última vez que la app arrancó con sesión.
  tok as (
    select
      t.user_id,
      max(t.last_seen_at)                                   as visto,
      count(*) filter (where t.disabled_at is null)         as activos,
      count(*)                                              as total,
      (array_agg(t.disabled_reason order by t.disabled_at desc nulls last))[1] as motivo
    from public.push_tokens t
    join u using (user_id)
    group by t.user_id
  ),
  dev as (
    select d.user_id, max(d.last_seen_at) as visto
    from public.user_devices d
    join u using (user_id)
    group by d.user_id
  ),
  act as (
    select
      a.user_id,
      max(a.created_at) filter (where a.kind = 'app_open')        as apertura,
      max(a.created_at) filter (where a.kind = 'pay_screen')      as pago,
      max(a.created_at) filter (where a.kind = 'pay_data_copied') as copio,
      max(a.created_at) filter (where a.kind = 'push_opened')     as aviso,
      min(a.created_at)                                           as desde
    from public.app_activity a
    join u using (user_id)
    group by a.user_id
  ),
  -- Avisos de cuota que llegaron al teléfono desde que venció lo más viejo.
  entregados as (
    select n.user_id, count(distinct n.id)::integer as n
    from public.notifications n
    join vence v using (user_id)
    where n.type = 'installment_due'
      and public.helios_business_date(n.created_at) >= v.desde
      and exists (
        select 1 from public.push_deliveries pd
        where pd.notification_id = n.id and pd.status = 'delivered')
    group by n.user_id
  ),
  -- Y los que tocó en ese tiempo (lo anota la app desde la OTA de 28-09).
  abiertos as (
    select a.user_id, count(*)::integer as n
    from public.app_activity a
    join vence v using (user_id)
    where a.kind = 'push_opened'
      and a.detail = 'installment_due'
      and public.helios_business_date(a.created_at) >= v.desde
    group by a.user_id
  ),
  rep as (
    select distinct on (pr.user_id)
      pr.user_id, pr.status::text as estado, pr.created_at, pr.reviewed_at, pr.rejection_note
    from public.payment_reports pr
    join u using (user_id)
    where pr.status <> 'duplicate'
    order by pr.user_id, pr.created_at desc
  ),
  rev as (
    select pr.user_id, min(pr.created_at) as desde
    from public.payment_reports pr
    join u using (user_id)
    where pr.status in ('reported', 'in_review')
    group by pr.user_id
  )
  select
    u.user_id,
    jsonb_build_object(
      -- greatest() ignora los null: la más reciente de las tres fuentes.
      'ultima_apertura',   greatest(tok.visto, dev.visto, act.apertura),
      'avisos',            case when coalesce(tok.activos, 0) > 0 then 'activos'
                                when coalesce(tok.total, 0) > 0   then 'apagados'
                                else 'nunca' end,
      'avisos_motivo',     case when coalesce(tok.activos, 0) = 0 then tok.motivo end,
      -- Desde cuándo la app anota gestos de esta persona: sin esto, «no entró
      -- a pagar» no se puede afirmar.
      'gestos_desde',      act.desde,
      'entro_a_pagar',     act.pago,
      'copio_datos',       act.copio,
      'abrio_aviso',       act.aviso,
      'vencida_desde',     vence.desde,
      'avisos_entregados', coalesce(entregados.n, 0),
      'avisos_abiertos',   coalesce(abiertos.n, 0),
      'ultimo_reporte',    case when rep.user_id is not null then jsonb_build_object(
                             'estado',      rep.estado,
                             'en',          rep.created_at,
                             'revisado_en', rep.reviewed_at,
                             'nota',        rep.rejection_note) end,
      'en_revision_desde', rev.desde
    )
  from u
  left join vence      on vence.user_id      = u.user_id
  left join tok        on tok.user_id        = u.user_id
  left join dev        on dev.user_id        = u.user_id
  left join act        on act.user_id        = u.user_id
  left join entregados on entregados.user_id = u.user_id
  left join abiertos   on abiertos.user_id   = u.user_id
  left join rep        on rep.user_id        = u.user_id
  left join rev        on rev.user_id        = u.user_id;
$$;

comment on function metricas.senales_deudor(uuid[]) is
  'Hechos con fecha de cada persona para la cobranza: última apertura de la app, estado de los avisos, gestos anotados por la app (app_activity), avisos de cuota entregados y abiertos desde que venció lo más viejo, último pago reportado y el que está en revisión. El panel los convierte en señales.';

-- ─── 2. La cola de Por cobrar, con señales ───────────────────────────────────

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
  v_horizon   integer := greatest(least(coalesce(p_horizon_days, 3), 30), 0);
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
    'umbrales_perfil', (select to_jsonb(u) from metricas.perfil_deudor_umbrales() u),
    'demotion_days', v_demotion,
    'expulsion_days', v_expulsion,
    'rows', v_rows
  );
end;
$$;

comment on function public.admin_collections(integer, uuid, date) is
  'Cola de cobranza por persona, con su tramo, lo que debe (PAYABLE, con lo dado por perdido dentro) con su desglose (overdue_/upcoming_ financed_usd y fee_usd), la ultima gestion, su perfil de deudor (perfil, prioridad, orden, motivo) y sus senales (metricas.senales_deudor + la historia del perfil). Con p_merchant_id, las personas que deben algo de ese local; con p_cohorte (un lunes), las que deben algo vencido de consumos de esa semana. Los umbrales viajan fuera de las filas.';

revoke all on function public.admin_collections(integer, uuid, date) from public, anon;
grant execute on function public.admin_collections(integer, uuid, date) to authenticated, service_role;

-- ─── 3. Quién debe de una semana ─────────────────────────────────────────────

create or replace function public.admin_deudores_de_la_semana(
  p_semana      date default null,
  p_merchant_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  -- La cartera entera de cada persona se mira a 30 días: la cuota 2 de la
  -- semana en curso vence dentro de ese plazo.
  c_horizonte constant integer := 30;
  v_today     date := public.helios_business_date(now());
  v_lunes     date := metricas.lunes(coalesce(p_semana, v_today));
  v_rows      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  with
  sem as materialized (
    select
      q.user_id,
      jsonb_agg(
        jsonb_build_object(
          'numero',       q.sequence,
          'estado',       q.estado_hoy,
          'vence',        q.due_date,
          'dias_atraso',  q.dias_atraso,
          'payable_usd',  q.payable_usd,
          'financed_usd', q.financed_usd,
          'fee_usd',      q.fee_usd,
          'local',        m.name)
        order by q.due_date, q.sequence)                                      as cuotas,
      sum(q.payable_usd)                                                      as payable,
      sum(q.financed_usd)                                                     as financed,
      sum(q.fee_usd)                                                          as fee,
      coalesce(sum(q.payable_usd) filter (where q.estado_hoy = 'vencida'), 0) as vencido,
      max(q.dias_atraso) filter (where q.estado_hoy = 'vencida')              as dias
    from metricas.cuotas q
    left join public.merchants m on m.id = q.merchant_id
    where q.semana = v_lunes
      and q.estado_hoy in ('vencida', 'por_vencer', 'perdida')
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    group by q.user_id
  ),
  perfiles as materialized (
    select pd.*
    from metricas.perfil_deudor() pd
    where pd.user_id in (select user_id from sem)
  ),
  senales as materialized (
    select s.*
    from metricas.senales_deudor(array(select user_id from sem)) s
  )
  select coalesce(
           jsonb_agg(
             r.fila || jsonb_build_object(
               'perfil',    p.perfil,
               'prioridad', p.prioridad,
               'orden',     p.orden,
               'motivo',    p.motivo,
               'overdue_financed_usd',  d.vencido_financed,
               'overdue_fee_usd',       coalesce((r.fila ->> 'overdue_usd')::numeric, 0) - d.vencido_financed,
               'upcoming_financed_usd', d.por_vencer_financed,
               'upcoming_fee_usd',      coalesce((r.fila ->> 'upcoming_usd')::numeric, 0) - d.por_vencer_financed,
               'de_la_semana', jsonb_build_object(
                 'payable_usd',  s.payable,
                 'financed_usd', s.financed,
                 'fee_usd',      s.fee,
                 'cuotas',       s.cuotas),
               'senales', coalesce(sn.senales, '{}'::jsonb) || jsonb_build_object(
                 'cuotas_pagadas',          p.cuotas_pagadas,
                 'pagadas_a_tiempo',        p.pagadas_a_tiempo,
                 'pagadas_tarde',           p.pagadas_tarde,
                 'atraso_medio_al_pagar',   p.atraso_medio_al_pagar,
                 'promesas_rotas',          p.promesas_rotas,
                 'ultima_promesa_rota',     p.ultima_promesa_rota,
                 'gestiones_sin_respuesta', p.gestiones_sin_respuesta,
                 'reportes_rechazados',     p.reportes_rechazados))
             -- Lo vencido primero, por prioridad del perfil; después lo que
             -- vence, por fecha.
             order by (s.vencido > 0) desc, p.orden nulls last, s.dias desc nulls last,
                      s.payable desc, s.user_id),
           '[]'::jsonb)
    into v_rows
  from sem s
  cross join lateral public.helios_collection_rows(v_today, c_horizonte, s.user_id) r(fila)
  left join perfiles p  on p.user_id  = s.user_id
  left join senales  sn on sn.user_id = s.user_id
  cross join lateral (
    select
      coalesce(sum(i.financed_usd) filter (where i.due_date <  v_today), 0) as vencido_financed,
      coalesce(sum(i.financed_usd) filter (where i.due_date >= v_today), 0) as por_vencer_financed
    from public.installments i
    where i.user_id = s.user_id
      and i.status = 'pending'
      and not i.is_test
      and i.due_date <= v_today + c_horizonte
  ) d;

  return jsonb_build_object(
    'semana', v_lunes,
    'business_date', v_today,
    'merchant_id', p_merchant_id,
    'horizonte_dias', c_horizonte,
    'umbrales_perfil', (select to_jsonb(u) from metricas.perfil_deudor_umbrales() u),
    'demotion_days', public.helios_mora_demotion_days(),
    'expulsion_days', public.helios_mora_expulsion_days(),
    'rows', v_rows
  );
end;
$$;

comment on function public.admin_deudores_de_la_semana(date, uuid) is
  'Por cobrar › Por semana: quien debe algo (vencido, por vencer o perdido) de lo consumido la semana de p_semana (se lleva a su lunes), con lo que debe de esa semana cuota a cuota (de_la_semana, de metricas.cuotas: la misma fuente que admin_metricas_cohorte), su fila de la cartera a 30 dias, su perfil y sus senales. Todo lo que se cobra lleva el fee, con su desglose.';

revoke all on function public.admin_deudores_de_la_semana(date, uuid) from public, anon;
grant execute on function public.admin_deudores_de_la_semana(date, uuid) to authenticated, service_role;
