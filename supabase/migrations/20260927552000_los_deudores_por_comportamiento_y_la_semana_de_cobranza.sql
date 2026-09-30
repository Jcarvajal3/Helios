-- ============================================================================
-- Ronda — Los deudores por comportamiento y la semana de Cobranza y riesgo
--
-- Dos RPC nuevas para Métricas › Cobranza y riesgo, las dos sobre `metricas.*`:
--
--   admin_deudores_por_perfil(local)  a quién llamar y por qué: cada perfil de
--                                     deudor con su gente, lo que debe y lo
--                                     que se ha recuperado de gente así, y la
--                                     lista ordenada por prioridad.
--   admin_metricas_cobranza(semana, local)
--                                     la cartera al cierre de la semana
--                                     elegida (o ahora, si está en curso): lo
--                                     vencido, la mora, la mora por tramo y el
--                                     impago, y la misma altura de la semana
--                                     anterior para compararla.
--
-- Lo demás de la pestaña sale de las RPC de siempre, con la semana y el local
-- (20260927551000): lo que vencía y entró día a día, el paso entre tramos, el
-- cobro a tiempo, la primera cuota, lo recuperado, las gestiones, las
-- promesas y el uso del cupo.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. admin_deudores_por_perfil
-- ---------------------------------------------------------------------------

create or replace function public.admin_deudores_por_perfil(p_merchant_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy date := metricas.hoy();
  v_out jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  with
  pd as materialized (
    select * from metricas.perfil_deudor() d where d.perfil is not null
  ),
  -- Con un local: lo que cada persona debe de ESE local. El perfil sigue
  -- siendo el suyo (el de toda su deuda): una persona tiene un solo perfil.
  del_local as materialized (
    select q.user_id,
           coalesce(sum(q.payable_usd)  filter (where q.estado_hoy = 'vencida'), 0)    as v_payable,
           coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'vencida'), 0)    as v_financed,
           coalesce(sum(q.fee_usd)      filter (where q.estado_hoy = 'vencida'), 0)    as v_fee,
           coalesce(sum(q.payable_usd)  filter (where q.estado_hoy = 'por_vencer'), 0) as pv_payable,
           coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'por_vencer'), 0) as pv_financed,
           coalesce(sum(q.fee_usd)      filter (where q.estado_hoy = 'por_vencer'), 0) as pv_fee
    from metricas.cuotas q
    where q.merchant_id = p_merchant_id
      and q.estado_hoy in ('vencida', 'por_vencer')
    group by q.user_id
  ),
  gente as (
    select
      d.*,
      case when p_merchant_id is null then d.vencido_payable_usd     else l.v_payable   end as l_v_payable,
      case when p_merchant_id is null then d.vencido_financed_usd    else l.v_financed  end as l_v_financed,
      case when p_merchant_id is null then d.vencido_fee_usd         else l.v_fee       end as l_v_fee,
      case when p_merchant_id is null then d.por_vencer_payable_usd  else l.pv_payable  end as l_pv_payable,
      case when p_merchant_id is null then d.por_vencer_financed_usd else l.pv_financed end as l_pv_financed,
      case when p_merchant_id is null then d.por_vencer_fee_usd      else l.pv_fee      end as l_pv_fee
    from pd d
    left join del_local l on l.user_id = d.user_id
    where p_merchant_id is null
       -- Con un local: quien está en mora y debe algo vencido de él, o quien
       -- hay que vigilar y tiene algo por vencer de él.
       or (d.perfil <> 'vigilar' and l.v_payable > 0)
       or (d.perfil = 'vigilar' and l.pv_payable > 0)
  ),
  -- Los locales donde debe algo cada persona.
  locales as (
    select q.user_id, array_agg(distinct m.name order by m.name) as nombres
    from metricas.cuotas q
    join public.merchants m on m.id = q.merchant_id
    where q.estado_hoy in ('vencida', 'por_vencer')
      and q.user_id in (select g.user_id from gente g)
    group by q.user_id
  ),
  recup as (
    select * from metricas.cobranza_recuperacion_por_perfil(p_merchant_id)
  ),
  perfiles(perfil, prioridad, orden) as (
    values ('nunca_ha_pagado', 'alta', 1), ('promesa_rota', 'alta', 2),
           ('sin_respuesta', 'alta', 3), ('reincidente', 'media', 4),
           ('paga_tarde_pero_paga', 'media', 5), ('se_le_paso', 'baja', 6),
           ('vigilar', 'baja', 7)
  )
  select jsonb_build_object(
    'hoy', v_hoy,
    'merchant_id', p_merchant_id,
    'umbrales', (select to_jsonb(u) from metricas.perfil_deudor_umbrales() u),
    -- Las personas en mora, sin las de vigilar (que todavía no deben nada).
    'en_mora', (
      select jsonb_build_object(
        'personas', count(*),
        'vencido', jsonb_build_object(
          'payable_usd',  coalesce(sum(g.l_v_payable), 0),
          'financed_usd', coalesce(sum(g.l_v_financed), 0),
          'fee_usd',      coalesce(sum(g.l_v_fee), 0)))
      from gente g
      where g.perfil <> 'vigilar'
    ),
    'perfiles', (
      select jsonb_agg(jsonb_build_object(
        'perfil',    f.perfil,
        'prioridad', f.prioridad,
        'personas',  coalesce(x.personas, 0),
        'vencido', jsonb_build_object(
          'payable_usd',  coalesce(x.v_payable, 0),
          'financed_usd', coalesce(x.v_financed, 0),
          'fee_usd',      coalesce(x.v_fee, 0)),
        'por_vencer', jsonb_build_object(
          'payable_usd',  coalesce(x.pv_payable, 0),
          'financed_usd', coalesce(x.pv_financed, 0),
          'fee_usd',      coalesce(x.pv_fee, 0)),
        -- Días de atraso de media de su gente (vigilar: nulo, no está en mora).
        'atraso_medio_dias', x.atraso_medio,
        'recuperacion', case when r.perfil is null then null else jsonb_build_object(
          'episodios', r.episodios,
          'personas',  r.personas,
          'vencido', jsonb_build_object(
            'payable_usd',  r.vencido_payable_usd,
            'financed_usd', r.vencido_financed_usd,
            'fee_usd',      r.vencido_fee_usd),
          'recuperado', jsonb_build_object(
            'payable_usd',  r.recuperado_payable_usd,
            'financed_usd', r.recuperado_financed_usd,
            'fee_usd',      r.recuperado_fee_usd),
          'pct',  r.recuperado_pct,
          'dias', r.dias) end
      ) order by f.orden)
      from perfiles f
      left join (
        select g.perfil,
               count(*)::integer      as personas,
               sum(g.l_v_payable)     as v_payable,
               sum(g.l_v_financed)    as v_financed,
               sum(g.l_v_fee)         as v_fee,
               sum(g.l_pv_payable)    as pv_payable,
               sum(g.l_pv_financed)   as pv_financed,
               sum(g.l_pv_fee)        as pv_fee,
               round(avg(g.dias_atraso) filter (where g.dias_atraso > 0), 1) as atraso_medio
        from gente g
        group by g.perfil
      ) x on x.perfil = f.perfil
      left join recup r on r.perfil = f.perfil
    ),
    'personas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id',   g.user_id,
        'nombre',    p.full_name,
        'telefono',  p.phone_e164,
        'estado',    p.status::text,
        'nivel',     p.level,
        'perfil',    g.perfil,
        'prioridad', g.prioridad,
        'orden',     g.orden,
        'motivo',    g.motivo,
        -- PAYABLE con su desglose. Con un local, lo de ese local.
        'vencido', jsonb_build_object(
          'payable_usd',  g.l_v_payable,
          'financed_usd', g.l_v_financed,
          'fee_usd',      g.l_v_fee),
        'por_vencer', jsonb_build_object(
          'payable_usd',  g.l_pv_payable,
          'financed_usd', g.l_pv_financed,
          'fee_usd',      g.l_pv_fee),
        'dias_atraso',           g.dias_atraso,
        'tramo',                 g.tramo,
        'cuotas_vencidas',       g.cuotas_vencidas,
        'proximo_vencimiento',   g.proximo_vencimiento,
        'cuotas_pagadas',        g.cuotas_pagadas,
        'pagadas_a_tiempo',      g.pagadas_a_tiempo,
        'pagadas_tarde',         g.pagadas_tarde,
        'atraso_medio_al_pagar', g.atraso_medio_al_pagar,
        'promesas_hechas',       g.promesas_hechas,
        'promesas_cumplidas',    g.promesas_cumplidas,
        'promesas_rotas',        g.promesas_rotas,
        'gestiones',             g.gestiones,
        'gestiones_sin_respuesta', g.gestiones_sin_respuesta,
        'dias_desde_ultima_gestion', g.dias_desde_ultima_gestion,
        'reportes_rechazados',   g.reportes_rechazados,
        'antiguedad_dias',       g.antiguedad_dias,
        'tiene_push',            g.tiene_push,
        'locales',               coalesce(to_jsonb(lc.nombres), '[]'::jsonb)
      ) order by g.orden)
      from gente g
      join public.profiles p on p.id = g.user_id
      left join locales lc on lc.user_id = g.user_id
    ), '[]'::jsonb)
  )
  into v_out;

  return v_out;
end;
$$;

comment on function public.admin_deudores_por_perfil(uuid) is
  'Deudores por comportamiento (metricas.perfil_deudor): por perfil, cuántas personas, lo vencido (PAYABLE con desglose), el atraso medio y lo recuperado históricamente de gente así (metricas.cobranza_recuperacion_por_perfil); y la lista ordenada por prioridad con su motivo. Con p_merchant_id: la gente que debe algo de ese local y lo que debe de él; el perfil sigue siendo el de toda su deuda.';

revoke all on function public.admin_deudores_por_perfil(uuid) from public, anon;
grant execute on function public.admin_deudores_por_perfil(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. admin_metricas_cobranza: la cartera de la semana elegida
-- ---------------------------------------------------------------------------

create or replace function public.admin_metricas_cobranza(
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
  v_hoy      date := metricas.hoy();
  v_lunes    date;
  v_domingo  date;
  v_corte    date;
  v_cartera  record;
  v_anterior record;
  v_ahora    record;
  v_impago   record;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- La semana (nunca una futura) y su corte: el cierre del domingo, o ahora
  -- si la semana está en curso.
  v_lunes   := metricas.lunes(least(coalesce(p_semana, v_hoy), v_hoy));
  v_domingo := v_lunes + 6;
  v_corte   := least(v_domingo, v_hoy);

  select * into v_cartera  from metricas.cartera_al(v_corte, p_merchant_id);
  -- La semana anterior A LA MISMA ALTURA: el mismo día de la semana.
  select * into v_anterior from metricas.cartera_al(v_corte - 7, p_merchant_id);
  -- Lo de hoy, para «Para actuar» (la cola se trabaja hoy). Con la semana en
  -- curso es la misma cartera: no se vuelve a leer.
  if v_corte = v_hoy then
    v_ahora := v_cartera;
  else
    select * into v_ahora from metricas.cartera_al(v_hoy, p_merchant_id);
  end if;
  select * into v_impago   from metricas.cobranza_impago(p_merchant_id);

  return jsonb_build_object(
    'semana', jsonb_build_object('desde', v_lunes, 'hasta', v_domingo, 'en_curso', v_domingo >= v_hoy),
    'hoy', v_hoy,
    'corte', v_corte,
    'merchant_id', p_merchant_id,
    -- PAYABLE, siempre con su desglose. La mora es la canónica
    -- (vencido ÷ vencido + por vencer, sin lo dado por perdido).
    'cartera', jsonb_build_object(
      'vencido', jsonb_build_object(
        'payable_usd',  v_cartera.vencido_payable_usd,
        'financed_usd', v_cartera.vencido_financed_usd,
        'fee_usd',      v_cartera.vencido_fee_usd),
      'por_vencer', jsonb_build_object(
        'payable_usd',  v_cartera.por_vencer_payable_usd,
        'financed_usd', v_cartera.por_vencer_financed_usd,
        'fee_usd',      v_cartera.por_vencer_fee_usd),
      'perdido', jsonb_build_object(
        'payable_usd',  v_cartera.perdido_payable_usd,
        'financed_usd', v_cartera.perdido_financed_usd,
        'fee_usd',      v_cartera.perdido_fee_usd),
      'mora_pct',          v_cartera.mora_pct,
      'cuotas_vencidas',   v_cartera.cuotas_vencidas,
      'personas_vencidas', v_cartera.personas_vencidas
    ),
    'cartera_anterior', jsonb_build_object(
      'corte', v_corte - 7,
      'vencido', jsonb_build_object(
        'payable_usd',  v_anterior.vencido_payable_usd,
        'financed_usd', v_anterior.vencido_financed_usd,
        'fee_usd',      v_anterior.vencido_fee_usd),
      'mora_pct',          v_anterior.mora_pct,
      'personas_vencidas', v_anterior.personas_vencidas
    ),
    -- La mora por tramo en el corte (metricas.cobranza_tramos_al): suma lo
    -- mismo que `cartera.vencido`, persona a persona.
    'tramos', jsonb_build_object(
      'cortes', public.helios_tramos_de_atraso(),
      'filas', (
        select jsonb_agg(jsonb_build_object(
          'tramo',        t.tramo,
          'personas',     coalesce(x.personas, 0),
          'cuotas',       coalesce(x.cuotas, 0),
          'payable_usd',  coalesce(x.payable, 0),
          'financed_usd', coalesce(x.financed, 0),
          'fee_usd',      coalesce(x.fee, 0),
          'dias_atraso_medio', x.dias
        ) order by t.ord)
        from (values ('t1', 1), ('t2', 2), ('t3', 3), ('t4', 4), ('t5', 5)) t(tramo, ord)
        left join (
          select c.tramo,
                 count(*)::integer                 as personas,
                 sum(c.cuotas_vencidas)::integer   as cuotas,
                 sum(c.vencido_payable_usd)        as payable,
                 sum(c.vencido_financed_usd)       as financed,
                 sum(c.vencido_fee_usd)            as fee,
                 round(avg(c.dias_atraso), 1)      as dias
          from metricas.cobranza_tramos_al(v_corte, p_merchant_id) c
          where c.tramo <> 'al_dia'
          group by c.tramo
        ) x on x.tramo = t.tramo
      )
    ),
    -- El impago desde el primer día (no es de la semana): la misma función
    -- que admin_overview.
    'impago', jsonb_build_object(
      'perdido', jsonb_build_object(
        'payable_usd',  v_impago.perdido_payable_usd,
        'financed_usd', v_impago.perdido_financed_usd,
        'fee_usd',      v_impago.perdido_fee_usd),
      'personas_perdidas', v_impago.personas_perdidas,
      'financiado_usd',    v_impago.financiado_usd,
      'impago_pct',        v_impago.impago_pct,
      'empate_pct',        v_impago.empate_pct
    ),
    'hoy_vencido', jsonb_build_object(
      'personas', v_ahora.personas_vencidas,
      'payable_usd',  v_ahora.vencido_payable_usd,
      'financed_usd', v_ahora.vencido_financed_usd,
      'fee_usd',      v_ahora.vencido_fee_usd
    )
  );
end;
$$;

comment on function public.admin_metricas_cobranza(date, uuid) is
  'Métricas › Cobranza y riesgo: la cartera al cierre de la semana de p_semana (o ahora si está en curso) — lo vencido, por vencer y perdido (PAYABLE con desglose), la mora canónica y las personas con algo vencido (metricas.cartera_al); la misma altura de la semana anterior; la mora por tramo (metricas.cobranza_tramos_al); el impago desde el inicio con su punto de empate (metricas.cobranza_impago), y lo vencido hoy. Con p_merchant_id, las cuotas de ese local.';

revoke all on function public.admin_metricas_cobranza(date, uuid) from public, anon;
grant execute on function public.admin_metricas_cobranza(date, uuid) to authenticated, service_role;
