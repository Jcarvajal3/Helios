-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — Lo que puede hacer el rol de cobranza
--
-- El rol `cobranza` (20261118120000) solo entra a superadmin › Por cobrar
-- (/admin/cobranza): la lista, Morosos, Cohortes, Calendario y Promesas.
--
-- 1. `is_platform_admin()` lo deja fuera, como a la agenda y al capacitador:
--    no lee pagos, el libro, clínicas ni la bitácora.
-- 2. `helios_puede_cobrar()`: super admin, operador o cobranza, con el
--    segundo factor si se exige.
-- 3. Las RPC de lo que lee esa pantalla pasan a `helios_puede_cobrar()`. Los
--    cuerpos salen tal cual de la base, con solo esa sustitución. Escribir
--    (gestiones, promesas, mensajes) sigue siendo del equipo.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.helios_puede_cobrar()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.helios_es_del_equipo(array['super_admin', 'operador', 'cobranza']::public.platform_role[]);
$$;

comment on function public.helios_puede_cobrar() is
  'Por cobrar: si quien llama puede leerlo (super admin, operador o el rol cobranza), con el segundo factor si se exige.';

revoke all on function public.helios_puede_cobrar() from public, anon;
grant execute on function public.helios_puede_cobrar() to authenticated;

CREATE OR REPLACE FUNCTION public.admin_collection_case(p_user uuid, p_horizon_days integer DEFAULT 3)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today   date    := public.helios_business_date(now());
  v_horizon integer := greatest(least(coalesce(p_horizon_days, 3), 30), 0);
  v_row     jsonb;
begin
  if not public.helios_puede_cobrar() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_user is null then
    return null;
  end if;

  v_row := (select r from public.helios_collection_rows(v_today, v_horizon, p_user) r limit 1);
  if v_row is null then
    return null;
  end if;

  return v_row || public.helios_collection_amounts(p_user, v_today, v_horizon);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_collection_flow(p_weeks integer DEFAULT 8, p_merchant_id uuid DEFAULT NULL::uuid, p_hasta date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today   date    := metricas.hoy();
  v_weeks   integer := greatest(least(coalesce(p_weeks, 8), 52), 1);
  v_hasta   date;
  v_domingo date;
  v_cortes  date[];
  v_out     jsonb;
begin
  if not public.helios_puede_cobrar() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- El último corte. Sin p_hasta, el de siempre: el cierre del último
  -- domingo, que es el lunes a las 10:00. Con p_hasta (la semana elegida en
  -- Métricas), el cierre de ese día; si es hoy o después, ahora mismo.
  v_hasta   := case when p_hasta is null then metricas.lunes(v_today) - 1
                    else least(p_hasta, v_today) end;
  -- El último domingo que cierra antes de v_hasta o en él.
  v_domingo := metricas.lunes(v_hasta + 1) - 1;

  -- Los cortes, del más viejo al más nuevo: un cierre de domingo por semana
  -- y, si v_hasta cae a media semana, v_hasta al final.
  if v_hasta = v_domingo then
    v_cortes := array(select v_domingo - 7 * k from generate_series(v_weeks, 0, -1) k);
  else
    v_cortes := array(select v_domingo - 7 * k from generate_series(v_weeks - 1, 0, -1) k) || v_hasta;
  end if;

  with
  cortes as (
    select x.k::integer as k,
           x.dia,
           -- El día que hace de «hoy» en el corte: el siguiente al cierre, o
           -- hoy si el corte es ahora.
           case when x.dia < v_today then x.dia + 1 else v_today end as ref
    from unnest(v_cortes) with ordinality as x(dia, k)
  ),
  -- Cada persona de la cartera en cada corte, con su tramo: la definición de
  -- la mora por tramo, no otra.
  estado as materialized (
    select c.k, t.user_id, t.tramo,
           t.vencido_payable_usd, t.vencido_financed_usd, t.vencido_fee_usd
    from cortes c
    cross join lateral metricas.cobranza_tramos_al(c.dia, p_merchant_id) t
  ),
  pasos as (
    select b.k,
           -- Sin cuotas en el corte anterior: es nueva en la cartera.
           coalesce(a.tramo, 'nuevo') as from_t,
           b.tramo                    as to_t,
           count(*)::integer          as people
    from estado b
    left join estado a on a.k = b.k - 1 and a.user_id = b.user_id
    where b.k > 1
    group by 1, 2, 3
  ),
  por_tramo as (
    select e.k, e.tramo,
           count(*)::integer            as people,
           sum(e.vencido_payable_usd)   as usd,
           sum(e.vencido_financed_usd)  as fin,
           sum(e.vencido_fee_usd)       as fee
    from estado e
    group by e.k, e.tramo
  ),
  total as (
    select e.k, count(*)::integer as people from estado e group by e.k
  ),
  tramos(tramo, ord) as (
    values ('t1', 1), ('t2', 2), ('t3', 3), ('t4', 4)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    -- El día que hace de «hoy» en este corte (un lunes, o hoy si es ahora).
    'cut_date',     c.ref,
    -- El del corte anterior: la semana va de from_date a cut_date.
    'from_date',    (select p.ref from cortes p where p.k = c.k - 1),
    'cierre',       c.dia,
    'en_curso',     c.dia >= v_today,
    'people_total', coalesce((select t.people from total t where t.k = c.k), 0),
    'people', jsonb_build_object('al_dia', coalesce((
        select pt.people from por_tramo pt where pt.k = c.k and pt.tramo = 'al_dia'), 0)) || (
      select jsonb_object_agg(tr.tramo, coalesce(pt.people, 0))
      from tramos tr left join por_tramo pt on pt.k = c.k and pt.tramo = tr.tramo
    ),
    -- PAYABLE: lo vencido y sin pagar en el corte, por tramo, con su desglose.
    'overdue_usd', (
      select jsonb_object_agg(tr.tramo, coalesce(pt.usd, 0))
      from tramos tr left join por_tramo pt on pt.k = c.k and pt.tramo = tr.tramo
    ),
    'overdue_financed_usd', (
      select jsonb_object_agg(tr.tramo, coalesce(pt.fin, 0))
      from tramos tr left join por_tramo pt on pt.k = c.k and pt.tramo = tr.tramo
    ),
    'overdue_fee_usd', (
      select jsonb_object_agg(tr.tramo, coalesce(pt.fee, 0))
      from tramos tr left join por_tramo pt on pt.k = c.k and pt.tramo = tr.tramo
    ),
    'transitions', coalesce((
      select jsonb_agg(jsonb_build_object('from', ps.from_t, 'to', ps.to_t, 'people', ps.people)
                       order by array_position(array['nuevo','al_dia','t1','t2','t3','t4'], ps.from_t),
                                array_position(array['al_dia','t1','t2','t3','t4'], ps.to_t))
      from pasos ps
      where ps.k = c.k and ps.people > 0
    ), '[]'::jsonb),
    -- De los que estaban en el tramo en el corte anterior, cuántos están al día.
    'cure', (
      select jsonb_object_agg(tr.tramo, jsonb_build_object(
        'from_people', coalesce(kp.people, 0),
        'cured', coalesce(ps.people, 0),
        'pct', case when coalesce(kp.people, 0) > 0
                    then round(100.0 * coalesce(ps.people, 0) / kp.people, 1) end
      ))
      from tramos tr
      left join por_tramo kp on kp.k = c.k - 1 and kp.tramo = tr.tramo
      left join pasos ps on ps.k = c.k and ps.from_t = tr.tramo and ps.to_t = 'al_dia'
    )
  ) order by c.k), '[]'::jsonb)
    into v_out
  from cortes c
  where c.k > 1;

  return jsonb_build_object(
    'business_date',   v_today,
    'weeks_requested', v_weeks,
    'hasta',           v_hasta,
    'merchant_id',     p_merchant_id,
    'tramos',          public.helios_tramos_de_atraso(),
    'weeks',           v_out
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_collection_promises(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today date := public.helios_business_date(now());
  v_from  date := coalesce(p_from, public.helios_business_date(now()) - 30);
  v_rows  jsonb;
begin
  if not public.helios_puede_cobrar() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_to is not null and p_to < v_from then
    raise exception 'El rango de fechas está al revés' using errcode = '22023';
  end if;

  with
  -- Con un local: las promesas de personas con alguna cuota en él.
  del_local as (
    select distinct q.user_id
    from metricas.cuotas q
    where q.merchant_id = p_merchant_id
  ),
  -- Lo vencido HOY de cada usuario, con la definición canónica: cuotas en
  -- estado 'vencida' de metricas.cuotas (sin pagar, con el vencimiento antes
  -- de hoy y SIN lo dado por perdido, que es 'perdida'). Con un local, lo de
  -- ese local.
  vencido as (
    select q.user_id,
           sum(q.payable_usd)  as overdue_usd,
           sum(q.financed_usd) as overdue_financed_usd,
           max(q.dias_atraso)  as days_overdue
    from metricas.cuotas q
    where q.estado_hoy = 'vencida'
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    group by q.user_id
  )
  select coalesce(jsonb_agg(to_jsonb(q) order by q.promise_date, q.contacted_at), '[]'::jsonb)
    into v_rows
  from (
    select
      c.id as contact_id,
      c.user_id,
      p.full_name,
      p.phone_e164,
      p.status::text as user_status,
      c.contacted_at,
      c.channel::text as channel,
      c.outcome,
      c.note,
      c.actor as actor_id,
      coalesce(pa.full_name, 'Alguien del equipo') as actor_name,
      c.promise_date,
      public.helios_promise_status(c.user_id, c.contacted_at, c.promise_date, v_today) as status,
      exists (
        select 1 from public.collection_contacts c2
        where c2.user_id = c.user_id
          and c2.promise_date is not null
          and c2.contacted_at > c.contacted_at
      ) as superseded,
      -- Lo vencido HOY (payable, con su desglose), sin lo perdido. Con un
      -- local, lo de ese local.
      coalesce(d.overdue_usd, 0)::numeric as overdue_usd,
      coalesce(d.overdue_financed_usd, 0)::numeric as overdue_financed_usd,
      coalesce(d.overdue_usd - d.overdue_financed_usd, 0)::numeric as overdue_fee_usd,
      coalesce(d.days_overdue, 0)::integer as days_overdue,
      lp.last_payment
    from public.collection_contacts c
    join public.profiles p on p.id = c.user_id
    left join public.platform_admins pa on pa.user_id = c.actor
    left join vencido d on d.user_id = c.user_id
    left join lateral (
      select jsonb_build_object(
               'report_id',  r.id,
               'created_at', r.created_at,
               'status',     r.status::text,
               'amount_usd', q2.amount_usd
             ) as last_payment
      from public.payment_reports r
      join public.payment_quotes q2 on q2.id = r.quote_id
      where r.user_id = c.user_id
        and r.created_at >= c.contacted_at
      order by r.created_at desc
      limit 1
    ) lp on true
    where c.promise_date is not null
      and c.promise_date >= v_from
      and (p_to is null or c.promise_date <= p_to)
      and not p.is_test
      and (p_merchant_id is null or c.user_id in (select dl.user_id from del_local dl))
  ) q;

  return jsonb_build_object(
    'business_date', v_today,
    'from', v_from,
    'to', p_to,
    'merchant_id', p_merchant_id,
    'summary', jsonb_build_object(
      'vence_hoy', (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'vence_hoy'),
      'pendiente', (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'pendiente'),
      'cumplida',  (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'cumplida'),
      'rota',      (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'rota')
    ),
    'rows', v_rows
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_collection_recovered(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_to        date := coalesce(p_to, metricas.hoy());
  v_from      date := coalesce(p_from, coalesce(p_to, metricas.hoy()) - 29);
  v_grace     integer := public.helios_late_fee_grace_days();
  v_interval  integer := public.helios_installment_interval_days();
  v_demotion  integer := public.helios_mora_demotion_days();
  v_expulsion integer := public.helios_mora_expulsion_days();
  v_result    jsonb;
begin
  if not public.helios_puede_cobrar() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_to < v_from then
    raise exception 'El rango de fechas está al revés' using errcode = '22023';
  end if;

  with
  -- Las cuotas pagadas en el rango que ya estaban vencidas al pagarse (se
  -- aprobaron después del día en que vencían).
  rec as (
    select
      q.installment_id,
      q.user_id,
      q.payable_usd,
      q.financed_usd,
      q.fee_usd,
      (q.written_off_at is not null and q.written_off_at < q.paid_at) as was_written_off,
      public.helios_tramo_de_atraso(q.pagada_dia - q.due_date,
        v_grace, v_interval, v_demotion, v_expulsion)                 as tramo
    from metricas.cuotas q
    where q.status = 'paid'
      and q.pagada_dia between v_from and v_to
      and q.pagada_dia > q.due_date
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ),
  -- Lo vencido y sin pagar al comenzar el día operativo v_from (el cierre del
  -- día anterior), con lo dado por perdido dentro.
  inicio as (
    select q.installment_id, q.user_id, q.payable_usd, q.financed_usd, q.fee_usd,
           (q.estado_hoy = 'perdida') as was_written_off
    from metricas.cuotas_al(v_from - 1) q
    where q.estado_hoy in ('vencida', 'perdida')
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ),
  fees as (
    select coalesce(sum(f.amount_usd), 0) as usd, count(*)::integer as n
    from metricas.cargos_por_atraso f
    where f.status = 'paid'
      and f.pagado_dia between v_from and v_to
      and (p_merchant_id is null or f.merchant_id = p_merchant_id)
  ),
  tramos(tramo, ord) as (
    values ('t1', 1), ('t2', 2), ('t3', 3), ('t4', 4)
  )
  select jsonb_build_object(
    'from', v_from,
    'to', v_to,
    'merchant_id', p_merchant_id,
    -- PAYABLE: cuotas cobradas que ya estaban vencidas, con su desglose.
    'recovered', (
      select jsonb_build_object(
        'usd', coalesce(sum(payable_usd), 0),
        'financed_usd', coalesce(sum(financed_usd), 0),
        'fee_usd', coalesce(sum(fee_usd), 0),
        'installments', count(*)::integer,
        'people', count(distinct user_id)::integer,
        'written_off_usd', coalesce(sum(payable_usd) filter (where was_written_off), 0)
      ) from rec
    ),
    -- Los cargos por atraso cobrados en el rango (sin IVA). Línea aparte: no se suman.
    'late_fees', (select jsonb_build_object('usd', usd, 'count', n) from fees),
    'by_tramo', (
      select jsonb_agg(jsonb_build_object(
               'tramo', t.tramo,
               'usd', coalesce(x.usd, 0),
               'financed_usd', coalesce(x.fin, 0),
               'fee_usd', coalesce(x.fee, 0),
               'installments', coalesce(x.n, 0),
               'people', coalesce(x.people, 0)
             ) order by t.ord)
      from tramos t
      left join (
        select tramo, sum(payable_usd) as usd, sum(financed_usd) as fin, sum(fee_usd) as fee,
               count(*)::integer as n, count(distinct user_id)::integer as people
        from rec group by tramo
      ) x on x.tramo = t.tramo
    ),
    'overdue_at_start', (
      select jsonb_build_object(
        'usd', coalesce(sum(payable_usd), 0),
        'financed_usd', coalesce(sum(financed_usd), 0),
        'fee_usd', coalesce(sum(fee_usd), 0),
        'installments', count(*)::integer,
        'people', count(distinct user_id)::integer,
        'written_off_usd', coalesce(sum(payable_usd) filter (where was_written_off), 0)
      ) from inicio
    ),
    'recovered_from_start', (
      select jsonb_build_object(
        'usd', coalesce(sum(r.payable_usd), 0),
        'financed_usd', coalesce(sum(r.financed_usd), 0),
        'fee_usd', coalesce(sum(r.fee_usd), 0),
        'installments', count(*)::integer,
        'people', count(distinct r.user_id)::integer
      )
      from rec r
      where r.installment_id in (select i.installment_id from inicio i)
    ),
    'recovery_pct', (
      select case when s.usd > 0 then round(100.0 * r.usd / s.usd, 1) end
      from (select coalesce(sum(payable_usd), 0) as usd from inicio) s,
           (select coalesce(sum(x.payable_usd), 0) as usd from rec x
             where x.installment_id in (select i.installment_id from inicio i)) r
    ),
    'tramos', public.helios_tramos_de_atraso()
  )
  into v_result;

  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_collection_templates(p_tramos boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tramos boolean := coalesce(p_tramos, false);
  v_rows   jsonb;
begin
  if not public.helios_puede_cobrar() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.sort_order), '[]'::jsonb)
  into v_rows
  from (
    select
      t.bucket, t.label, t.body, t.default_body, t.sort_order, t.updated_at,
      t.body is distinct from t.default_body as edited,
      coalesce(pa.full_name, 'Alguien del equipo') as updated_by_name
    from public.collection_templates t
    left join public.platform_admins pa on pa.user_id = t.updated_by
    where case
      when v_tramos then t.bucket in ('t1', 't2', 't3', 't4')
      else t.bucket in ('por_vencer', 'vence_hoy', 'congelado', 'baja_nivel', 'expulsion')
    end
  ) q;

  return jsonb_build_object(
    -- Las variables que el panel sabe rellenar. Viajan con las plantillas para
    -- que la pantalla pueda listarlas sin tenerlas escritas dos veces.
    'variables', to_jsonb(public.helios_collection_template_variables(v_tramos)),
    'rows', v_rows
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_collections(p_horizon_days integer DEFAULT 3, p_merchant_id uuid DEFAULT NULL::uuid, p_cohorte date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today     date    := public.helios_business_date(now());
  -- Hasta diez años: la Lista de Por cobrar pide todo lo que queda, para que
  -- su total sea el de Métricas › Global.
  v_horizon   integer := greatest(least(coalesce(p_horizon_days, 3), 3650), 0);
  v_demotion  integer := public.helios_mora_demotion_days();
  v_expulsion integer := public.helios_mora_expulsion_days();
  v_rows      jsonb;
begin
  if not public.helios_puede_cobrar() then
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
             f.r || public.helios_collection_amounts((f.r ->> 'user_id')::uuid, v_today, v_horizon)
                 || jsonb_build_object(
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
$function$;

CREATE OR REPLACE FUNCTION public.admin_contact_effectiveness(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_to      date := coalesce(p_to, public.helios_caracas_date(now()));
  v_from    date := coalesce(p_from, coalesce(p_to, public.helios_caracas_date(now())) - 29);
  v_from_ts timestamptz;
  v_to_ts   timestamptz;
  v_result  jsonb;
begin
  if not public.helios_puede_cobrar() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_to < v_from then
    raise exception 'El rango de fechas está al revés' using errcode = '22023';
  end if;

  v_from_ts := v_from::timestamp at time zone 'America/Caracas';
  v_to_ts   := (v_to + 1)::timestamp at time zone 'America/Caracas';

  with
  -- Con un local: las gestiones a personas con alguna cuota en él.
  del_local as (
    select distinct q.user_id
    from metricas.cuotas q
    where q.merchant_id = p_merchant_id
  ),
  c0 as (
    select c.id, c.user_id, c.contacted_at, c.channel, c.outcome
    from public.collection_contacts c
    join public.profiles p on p.id = c.user_id
    where c.contacted_at >= v_from_ts
      and c.contacted_at <  v_to_ts
      and not p.is_test
      and (p_merchant_id is null or c.user_id in (select d.user_id from del_local d))
  ),
  ev as (
    select pr.user_id, pr.created_at as at
    from public.payment_reports pr
    where pr.status not in ('rejected', 'duplicate')
      and pr.created_at >  v_from_ts
      and pr.created_at <= v_to_ts + interval '72 hours'
    union all
    -- Un pago sin reporte (un abono asignado a mano) cuenta por su
    -- aprobación. Si hubo reporte, ya contó arriba por la hora del reporte:
    -- contar también su aprobación daba por «pagó tras la gestión» un pago
    -- reportado ANTES de la llamada y aprobado después.
    select i.user_id, i.paid_at
    from public.installments i
    where i.status = 'paid'
      and not i.is_test
      and i.paid_by_report_id is null
      and i.paid_at >  v_from_ts
      and i.paid_at <= v_to_ts + interval '72 hours'
  ),
  con_pago as (
    select distinct c0.id
    from c0
    join ev on ev.user_id = c0.user_id
           and ev.at >  c0.contacted_at
           and ev.at <= c0.contacted_at + interval '72 hours'
  ),
  g as (
    select
      c0.channel::text as channel,
      coalesce(c0.outcome, 'sin_resultado') as outcome,
      extract(hour from c0.contacted_at at time zone 'America/Caracas')::integer as hour,
      (c0.contacted_at + interval '72 hours' > now()) as open_window,
      (cp.id is not null) as paid
    from c0
    left join con_pago cp on cp.id = c0.id
  ),
  claves as (
    select 'channel' as dim, k.v as clave, k.ord::integer as ord
    from unnest(enum_range(null::public.collection_channel)::text[]) with ordinality k(v, ord)
    union all
    select 'outcome', k.v, k.ord::integer
    from unnest(array['contesto', 'no_contesta', 'numero_equivocado', 'mensaje_enviado',
                      'promesa', 'otro', 'sin_resultado']) with ordinality k(v, ord)
    union all
    select 'hour', h::text, h
    from generate_series(0, 23) h
  ),
  stats as (
    select
      k.dim, k.clave, k.ord,
      count(g.*)::integer as contacts,
      count(g.*) filter (where g.paid)::integer as with_payment,
      count(g.*) filter (where g.open_window)::integer as open_window,
      case when count(g.*) filter (where not g.open_window) > 0
           then round(100.0 * count(g.*) filter (where g.paid and not g.open_window)
                      / count(g.*) filter (where not g.open_window), 1)
      end as rate_pct
    from claves k
    left join g on case k.dim
                     when 'channel' then g.channel = k.clave
                     when 'outcome' then g.outcome = k.clave
                     else g.hour = k.ord
                   end
    group by k.dim, k.clave, k.ord
  )
  select jsonb_build_object(
    'from', v_from,
    'to', v_to,
    'merchant_id', p_merchant_id,
    'window_hours', 72,
    'total', (
      select jsonb_build_object(
        'contacts', count(*)::integer,
        'with_payment', (count(*) filter (where paid))::integer,
        'open_window', (count(*) filter (where open_window))::integer,
        'rate_pct', case when count(*) filter (where not open_window) > 0
                         then round(100.0 * count(*) filter (where paid and not open_window)
                                    / count(*) filter (where not open_window), 1) end
      )
      from g
    ),
    'by_channel', (
      select jsonb_agg(jsonb_build_object('key', clave, 'contacts', contacts,
               'with_payment', with_payment, 'open_window', open_window, 'rate_pct', rate_pct)
             order by ord)
      from stats where dim = 'channel'
    ),
    'by_outcome', (
      select jsonb_agg(jsonb_build_object('key', clave, 'contacts', contacts,
               'with_payment', with_payment, 'open_window', open_window, 'rate_pct', rate_pct)
             order by ord)
      from stats where dim = 'outcome'
    ),
    'by_hour', (
      select jsonb_agg(jsonb_build_object('hour', ord, 'contacts', contacts,
               'with_payment', with_payment, 'open_window', open_window, 'rate_pct', rate_pct)
             order by ord)
      from stats where dim = 'hour'
    )
  )
  into v_result;

  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_deudores_de_la_semana(p_semana date DEFAULT NULL::date, p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  -- La cartera entera de cada persona se mira a 30 días: la cuota 2 de la
  -- semana en curso vence dentro de ese plazo.
  c_horizonte constant integer := 30;
  v_today     date := public.helios_business_date(now());
  v_lunes     date := metricas.lunes(coalesce(p_semana, v_today));
  v_rows      jsonb;
begin
  if not public.helios_puede_cobrar() then
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
$function$;

CREATE OR REPLACE FUNCTION public.admin_payment_destinations()
 RETURNS TABLE(id uuid, bank_name text, rif text, phone text, holder_name text, is_active boolean, created_at timestamp with time zone, report_count integer, method text, account_number text, email text, sort_order integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.helios_puede_cobrar() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  select d.id, d.bank_name, d.rif, d.phone, d.holder_name, d.is_active, d.created_at,
         coalesce(r.cnt, 0)::integer,
         d.method, d.account_number, d.email, d.sort_order
  from public.payment_destinations d
  left join (
    select destination_id as did, count(*)::integer as cnt
    from public.payment_reports where destination_id is not null group by 1
  ) r on r.did = d.id
  order by d.is_active desc, d.sort_order, d.created_at desc;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_perfil_de_morosos()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  -- El umbral de privacidad de Gente › Perfil: una ciudad con menos gente
  -- va a «otras».
  c_min   constant integer := 3;
  v_today date := public.helios_business_date(now());
  v_out   jsonb;
begin
  if not public.helios_puede_cobrar() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  with
  q as materialized (
    select * from metricas.cuotas
  ),
  -- Cada persona que ya tuvo que pagar algo, con su situación de hoy.
  pp as (
    select
      q.user_id,
      bool_or(q.estado_hoy in ('vencida', 'perdida'))                     as moroso,
      max(q.dias_atraso) filter (where q.estado_hoy in ('vencida', 'perdida')) as dias,
      bool_or(q.es_grupo)                                                 as en_grupo,
      sum(q.financed_usd)                                                 as fin,
      min(q.semana)                                                       as primera
    from q
    group by q.user_id
    having min(q.due_date) < v_today
  ),
  rasgos as materialized (
    select * from metricas.rasgos_de_personas(array(select user_id from pp))
  ),
  base as (
    select
      case when pp.moroso then 'morosos' else 'al_dia' end                as grupo,
      pp.user_id, pp.moroso, pp.dias, pp.en_grupo, pp.fin,
      r.sexo, r.edad, r.ciudad, r.plataforma, r.nivel, r.avisos_activos,
      pp.primera > metricas.lunes(v_today) - 28                            as nuevo
    from pp
    left join rasgos r on r.user_id = pp.user_id
  ),
  ciudades as (
    select b.grupo, b.ciudad, count(*)::int as n
    from base b
    where b.ciudad is not null
    group by b.grupo, b.ciudad
  ),
  ciudades_json as (
    select c.grupo,
      coalesce(jsonb_agg(jsonb_build_object('ciudad', c.ciudad, 'personas', c.n)
                         order by c.n desc, c.ciudad) filter (where c.n >= c_min), '[]'::jsonb) as top,
      coalesce(sum(c.n) filter (where c.n < c_min), 0)::int              as otras
    from ciudades c
    group by c.grupo
  ),
  resumen as (
    select
      b.grupo,
      jsonb_build_object(
        'personas',          count(*),
        'vencidas',          count(*) filter (where b.moroso),
        'atraso_medio_dias', round(avg(b.dias) filter (where b.moroso), 1),
        'edad', jsonb_build_object(
          'conocida', count(b.edad),
          'mediana',  percentile_cont(0.5) within group (order by b.edad) filter (where b.edad is not null),
          'tramos', jsonb_build_object(
            '18-24', count(*) filter (where b.edad between 18 and 24),
            '25-34', count(*) filter (where b.edad between 25 and 34),
            '35-44', count(*) filter (where b.edad between 35 and 44),
            '45+',   count(*) filter (where b.edad >= 45))),
        'sexo', jsonb_build_object(
          'F',        count(*) filter (where b.sexo = 'F'),
          'M',        count(*) filter (where b.sexo = 'M'),
          'sin_dato', count(*) filter (where b.sexo is null)),
        'plataforma', jsonb_build_object(
          'android',  count(*) filter (where b.plataforma = 'android'),
          'ios',      count(*) filter (where b.plataforma = 'ios'),
          'otra',     count(*) filter (where b.plataforma = 'web'),
          'sin_dato', count(*) filter (where b.plataforma is null)),
        'nivel_medio',       round(avg(b.nivel), 1),
        'nuevos',            count(*) filter (where b.nuevo),
        'en_grupo',          count(*) filter (where b.en_grupo),
        'sin_avisos',        count(*) filter (where not coalesce(b.avisos_activos, false)),
        'consumo_medio_usd', round(avg(b.fin), 2)
      ) as r
    from base b
    group by b.grupo
  )
  select jsonb_build_object(
    'business_date', v_today,
    'morosos', (select s.r || jsonb_build_object('ciudades', coalesce(cj.top, '[]'::jsonb), 'ciudades_otras', coalesce(cj.otras, 0))
                from resumen s left join ciudades_json cj on cj.grupo = s.grupo
                where s.grupo = 'morosos'),
    'al_dia',  (select s.r || jsonb_build_object('ciudades', coalesce(cj.top, '[]'::jsonb), 'ciudades_otras', coalesce(cj.otras, 0))
                from resumen s left join ciudades_json cj on cj.grupo = s.grupo
                where s.grupo = 'al_dia')
  ) into v_out;

  return v_out;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_receivables_by_day(p_desde date, p_hasta date, p_incluir_pagadas boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  -- Lo vencido lo decide el día operativo, como el motor de mora: una cuota
  -- del jueves no está vencida el viernes a las 08:00.
  v_bd    date    := public.helios_business_date(now());
  v_hoy   date    := public.helios_caracas_date(now());
  v_todas boolean := coalesce(p_incluir_pagadas, false);
  v_res   jsonb;
begin
  if not public.helios_puede_cobrar() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_desde is null or p_hasta is null or p_hasta < p_desde then
    raise exception 'El rango de fechas no es válido' using errcode = '22023';
  end if;
  if p_hasta - p_desde > 62 then
    raise exception 'El rango no puede pasar de 63 días' using errcode = '22023';
  end if;

  with
  -- Las cuotas que vencen en el rango, con su local.
  cuotas as (
    select i.id, i.user_id, i.due_date, c.merchant_id, m.name as local_nombre,
           i.status, i.amount_usd, i.financed_usd
    from public.installments i
    join public.charges   c on c.id = i.charge_id
    join public.merchants m on m.id = c.merchant_id
    join public.profiles  p on p.id = i.user_id
    where i.due_date between p_desde and p_hasta
      and i.written_off_at is null
      and not i.is_test and not c.is_test and not m.is_test and not p.is_test
  ),
  -- Una pieza por cuota (su consumo y su comisión) y otra por su cargo por
  -- atraso: el cargo puede seguir pendiente con la cuota ya pagada. Un cargo
  -- condonado o dado por perdido ('written_off') no es por cobrar.
  piezas as (
    select q.id as cuota_id, q.user_id, q.due_date as dia, q.merchant_id, q.local_nombre,
           q.status = 'paid'                 as pagada,
           q.financed_usd                    as consumo,
           q.amount_usd - q.financed_usd     as comision,
           0::numeric                        as cargos
    from cuotas q
    union all
    select q.id, q.user_id, q.due_date, q.merchant_id, q.local_nombre,
           lf.status = 'paid', 0, 0, lf.amount_usd
    from cuotas q
    join public.late_fees lf on lf.installment_id = q.id
    where lf.status in ('pending', 'paid')
  ),
  -- Lo que se enseña: lo que sigue sin pagar, o todo lo que vence.
  vistas as (
    select * from piezas where v_todas or not pagada
  ),
  -- Todo lo pendiente, de cualquier fecha: para lo vencido de antes y para
  -- cotejar con el libro.
  pendientes as (
    select i.id as cuota_id, i.user_id, i.due_date as dia,
           i.financed_usd as consumo, i.amount_usd - i.financed_usd as comision, 0::numeric as cargos
    from public.installments i
    join public.charges   c on c.id = i.charge_id
    join public.merchants m on m.id = c.merchant_id
    join public.profiles  p on p.id = i.user_id
    where i.status = 'pending'
      and i.written_off_at is null
      and not i.is_test and not c.is_test and not m.is_test and not p.is_test
    union all
    select i.id, i.user_id, i.due_date, 0, 0, lf.amount_usd
    from public.late_fees lf
    join public.installments i on i.id = lf.installment_id
    join public.charges   c on c.id = i.charge_id
    join public.merchants m on m.id = c.merchant_id
    join public.profiles  p on p.id = i.user_id
    where lf.status = 'pending'
      and i.written_off_at is null
      and not i.is_test and not c.is_test and not m.is_test and not p.is_test
  ),
  -- Cada cifra suelta, redondeada al céntimo ANTES de sumar el total: así el
  -- desglose cierra siempre con su suma, sin un céntimo de diferencia.
  bloques as (
    select b.bloque,
           count(distinct b.cuota_id)       as cuotas,
           count(distinct b.user_id)        as personas,
           round(coalesce(sum(b.consumo), 0), 2)  as consumo_usd,
           round(coalesce(sum(b.comision), 0), 2) as comision_usd,
           round(coalesce(sum(b.cargos), 0), 2)   as cargos_usd
    from (
      select 'periodo' as bloque, cuota_id, user_id, consumo, comision, cargos from vistas
      union all
      select 'pagado', cuota_id, user_id, consumo, comision, cargos from piezas where pagada
      union all
      select 'vencido_antes', cuota_id, user_id, consumo, comision, cargos
      from pendientes where dia < least(p_desde, v_bd)
      union all
      select 'pendiente', cuota_id, user_id, consumo, comision, cargos from pendientes
    ) b
    group by b.bloque
  ),
  por_dia as (
    select d.dia,
           count(distinct v.cuota_id)       as cuotas,
           count(distinct v.user_id)        as personas,
           count(distinct v.merchant_id)    as locales,
           round(coalesce(sum(v.consumo), 0), 2)  as consumo_usd,
           round(coalesce(sum(v.comision), 0), 2) as comision_usd,
           round(coalesce(sum(v.cargos), 0), 2)   as cargos_usd,
           (select count(distinct x.cuota_id) from piezas x
            where x.dia = d.dia and not x.pagada) as cuotas_sin_pagar
    from (select generate_series(p_desde, p_hasta, interval '1 day')::date as dia) d
    left join vistas v on v.dia = d.dia
    group by d.dia
  ),
  por_local as (
    select v.merchant_id, v.local_nombre,
           count(distinct v.cuota_id)       as cuotas,
           count(distinct v.user_id)        as personas,
           round(sum(v.consumo), 2)         as consumo_usd,
           round(sum(v.comision), 2)        as comision_usd,
           round(sum(v.cargos), 2)          as cargos_usd
    from vistas v
    group by v.merchant_id, v.local_nombre
  ),
  por_dia_y_local as (
    select v.dia, v.merchant_id, v.local_nombre,
           count(distinct v.cuota_id)       as cuotas,
           count(distinct v.user_id)        as personas,
           round(sum(v.consumo), 2)         as consumo_usd,
           round(sum(v.comision), 2)        as comision_usd,
           round(sum(v.cargos), 2)          as cargos_usd
    from vistas v
    group by v.dia, v.merchant_id, v.local_nombre
  )
  select jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'hoy', v_hoy,
    'dia_operativo', v_bd,
    'incluye_pagadas', v_todas,
    'periodo', (
      select jsonb_build_object(
        'cuotas', coalesce(max(b.cuotas), 0),
        'personas', coalesce(max(b.personas), 0),
        'locales', (select count(distinct v.merchant_id) from vistas v),
        'consumo_usd', coalesce(max(b.consumo_usd), 0),
        'comision_usd', coalesce(max(b.comision_usd), 0),
        'cargos_usd', coalesce(max(b.cargos_usd), 0),
        'total_usd', coalesce(max(b.consumo_usd + b.comision_usd + b.cargos_usd), 0))
      from bloques b where b.bloque = 'periodo'),
    'pagado', (
      select jsonb_build_object(
        'cuotas', coalesce(max(b.cuotas), 0),
        'personas', coalesce(max(b.personas), 0),
        'consumo_usd', coalesce(max(b.consumo_usd), 0),
        'comision_usd', coalesce(max(b.comision_usd), 0),
        'cargos_usd', coalesce(max(b.cargos_usd), 0),
        'total_usd', coalesce(max(b.consumo_usd + b.comision_usd + b.cargos_usd), 0))
      from bloques b where b.bloque = 'pagado'),
    'vencido_antes', (
      select jsonb_build_object(
        'hasta', least(p_desde, v_bd) - 1,
        'cuotas', coalesce(max(b.cuotas), 0),
        'personas', coalesce(max(b.personas), 0),
        'consumo_usd', coalesce(max(b.consumo_usd), 0),
        'comision_usd', coalesce(max(b.comision_usd), 0),
        'cargos_usd', coalesce(max(b.cargos_usd), 0),
        'total_usd', coalesce(max(b.consumo_usd + b.comision_usd + b.cargos_usd), 0))
      from bloques b where b.bloque = 'vencido_antes'),
    'por_dia', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'dia', d.dia,
        'cuotas', d.cuotas,
        'personas', d.personas,
        'locales', d.locales,
        'consumo_usd', d.consumo_usd,
        'comision_usd', d.comision_usd,
        'cargos_usd', d.cargos_usd,
        'total_usd', d.consumo_usd + d.comision_usd + d.cargos_usd,
        'cuotas_sin_pagar', d.cuotas_sin_pagar,
        'vencido', d.dia < v_bd and d.cuotas_sin_pagar > 0
      ) order by d.dia), '[]'::jsonb)
      from por_dia d),
    'por_local', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'local_id', l.merchant_id,
        'local', l.local_nombre,
        'cuotas', l.cuotas,
        'personas', l.personas,
        'consumo_usd', l.consumo_usd,
        'comision_usd', l.comision_usd,
        'cargos_usd', l.cargos_usd,
        'total_usd', l.consumo_usd + l.comision_usd + l.cargos_usd
      ) order by l.consumo_usd + l.comision_usd + l.cargos_usd desc, l.local_nombre), '[]'::jsonb)
      from por_local l),
    'por_dia_y_local', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'dia', f.dia,
        'local_id', f.merchant_id,
        'local', f.local_nombre,
        'cuotas', f.cuotas,
        'personas', f.personas,
        'consumo_usd', f.consumo_usd,
        'comision_usd', f.comision_usd,
        'cargos_usd', f.cargos_usd,
        'total_usd', f.consumo_usd + f.comision_usd + f.cargos_usd
      ) order by f.dia, f.consumo_usd + f.comision_usd + f.cargos_usd desc, f.local_nombre), '[]'::jsonb)
      from por_dia_y_local f),
    -- Para explicar por qué lo pendiente de todas las fechas puede no ser la
    -- cifra del libro: el libro también lleva los cargos sin cuota (anteriores
    -- al reparto por cuota) y cualquier ajuste manual.
    'cotejo', jsonb_build_object(
      'pendiente_usd', (
        select coalesce(max(b.consumo_usd + b.comision_usd + b.cargos_usd), 0)
        from bloques b where b.bloque = 'pendiente'),
      'cargos_sin_cuota_usd', (
        select round(coalesce(sum(lf.amount_usd), 0), 2)
        from public.late_fees lf
        join public.profiles p on p.id = lf.user_id
        where lf.status = 'pending' and lf.installment_id is null and not p.is_test),
      'libro_usd', round(ledger.balance_by_type('user_receivable'), 2)
    )
  )
  into v_res;

  return v_res;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_user_contacts(p_user uuid, p_limit integer DEFAULT 20)
 RETURNS TABLE(id uuid, contacted_at timestamp with time zone, channel text, template text, note text, promise_date date, actor_name text, outcome text, next_action_on date, promise_status text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today date := public.helios_business_date(now());
begin
  if not public.helios_puede_cobrar() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  select c.id, c.contacted_at, c.channel::text, c.template, c.note, c.promise_date,
         coalesce(pa.full_name, 'Alguien del equipo'),
         c.outcome, c.next_action_on,
         public.helios_promise_status(c.user_id, c.contacted_at, c.promise_date, v_today)
  from public.collection_contacts c
  left join public.platform_admins pa on pa.user_id = c.actor
  where c.user_id = p_user
  order by c.contacted_at desc
  limit least(coalesce(p_limit, 20), 100);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_user_late_fees(p_user uuid)
 RETURNS TABLE(id uuid, amount_usd numeric, days_late integer, business_date date, status text, waived_at timestamp with time zone, waive_reason text, sequence smallint, due_date date, merchant_name text, installment_id uuid)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.helios_puede_cobrar() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  select
    f.id,
    f.amount_usd,
    f.days_late,
    f.business_date,
    f.status::text,
    f.waived_at,
    f.waive_reason,
    i.sequence,
    i.due_date,
    m.name,
    f.installment_id
  from public.late_fees f
  left join public.installments i on i.id = f.installment_id
  left join public.charges ch on ch.id = i.charge_id
  left join public.merchants m on m.id = ch.merchant_id
  where f.user_id = p_user
  order by f.created_at desc;
end;
$function$;

