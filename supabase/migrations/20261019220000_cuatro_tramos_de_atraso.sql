-- ============================================================================
-- Helios — Cuatro tramos de atraso, no cinco
--
-- Los tramos venían de Ronda: t1 = 1…gracia (cupo congelado, sin cargo) y
-- t2 = gracia+1…intervalo (ya con cargo por atraso). En Helios no hay cargo
-- por atraso (`late_fee_usd` = 0, 2026-10-07), así que partir la primera
-- semana en dos no separa a nadie que haya que tratar distinto. Javier lo
-- aprobó el 2026-10-19. Los cortes salen SOLO de `installment_interval_days`
-- (7), `mora_demotion_days` (30) y `mora_expulsion_days` (60); la gracia ya
-- no corta tramos:
--
--   t1  1 … intervalo            la cuota 1 vencida; cuenta congelada
--   t2  intervalo+1 … baja−1     las dos cuotas vencidas
--   t3  baja … expulsión         cuenta suspendida (y baja un nivel si tiene
--                                más de uno)
--   t4  más de expulsión         expulsado; la deuda se da por perdida
--
-- Las claves siguen siendo t1…t4: el panel y los enlaces guardados las
-- conocen. Lo que era t5 es ahora t4; lo que era t2 cae en t1.
--
-- Las plantillas de WhatsApp de cobranza (`collection_templates`) se
-- reescriben para los cuatro tramos. `body` solo se toca si nadie lo editó
-- (`body = default_body`). La fila t5 se queda sin uso: no se borra, pero
-- `admin_collection_templates` ya no la lista. Tampoco lista `por_vencer` ni
-- `vence_hoy` en el modo tramos: los recordatorios antes del vencimiento
-- salen solos (crons cuota_en_3_dias, cuota_manana, cuota_hoy) y el botón de
-- WhatsApp de cobranza solo sale a quien tiene algo vencido.
--
-- `metricas.cobranza_tramos_al` no cambia: llama a `helios_tramo_de_atraso`
-- con la gracia, que aquí queda sin uso.
-- ============================================================================

-- El tramo de unos días de atraso. Se mantiene la firma (la llaman
-- `metricas.cobranza_tramos_al` y `admin_collection_recovered`): `p_grace`
-- queda SIN USO desde el 2026-10-19, la gracia ya no corta tramos.
create or replace function public.helios_tramo_de_atraso(
  p_days integer, p_grace integer, p_interval integer, p_demotion integer, p_expulsion integer)
returns text
language sql
immutable
as $function$
  select case
    when p_days is null or p_days <= 0 then 'al_dia'
    when p_days <= p_interval          then 't1'
    when p_days <  p_demotion          then 't2'
    when p_days <= p_expulsion         then 't3'
    else 't4'
  end
$function$;

-- Los cortes, para que el panel pinte los rótulos con los días de la base.
-- `grace_days` sigue viajando (informativo, no corta tramos) para que un
-- panel de antes de este cambio no se quede sin cortes.
create or replace function public.helios_tramos_de_atraso()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  with p as (
    select public.helios_late_fee_grace_days()       as g,
           public.helios_installment_interval_days() as i,
           public.helios_mora_demotion_days()        as b,
           public.helios_mora_expulsion_days()       as e
  )
  select jsonb_build_object(
    'grace_days',     g,
    'interval_days',  i,
    'demotion_days',  b,
    'expulsion_days', e,
    'buckets', jsonb_build_array(
      jsonb_build_object('key', 'al_dia', 'from_days', null,  'to_days', 0),
      jsonb_build_object('key', 't1',     'from_days', 1,     'to_days', i),
      jsonb_build_object('key', 't2',     'from_days', i + 1, 'to_days', b - 1),
      jsonb_build_object('key', 't3',     'from_days', b,     'to_days', e),
      jsonb_build_object('key', 't4',     'from_days', e + 1, 'to_days', null)
    )
  )
  from p
$function$;

-- ── Las funciones que listan los tramos: t1…t4 ──────────────────────────────
-- Copias de la definición viva con la lista de tramos sin t5.

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
  if not public.is_platform_admin() then
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
$function$
;

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
  if not public.is_platform_admin() then
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
$function$
;

CREATE OR REPLACE FUNCTION public.admin_metricas_cobranza(p_semana date DEFAULT NULL::date, p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
        from (values ('t1', 1), ('t2', 2), ('t3', 3), ('t4', 4)) t(tramo, ord)
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
$function$
;

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
  if not public.is_platform_admin() then
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
$function$
;

-- ── Las plantillas de WhatsApp de los cuatro tramos ─────────────────────────
-- Van al paciente: no tiene app ni cuenta que abrir. Paga por Pago Móvil y
-- manda la foto del comprobante por el mismo chat. Sin cargo por atraso y sin
-- hablar de niveles. El `body` se reescribe solo si nadie lo había editado.
update public.collection_templates t
set label        = n.label,
    body         = case when t.body = t.default_body then n.cuerpo else t.body end,
    default_body = n.cuerpo
from (values
  ('t1', 'Cuota vencida',
   $t$Hola {nombre}, te escribimos de Helios. Tu cuota del {fecha_vencimiento} está vencida: son {monto_usd} ({monto_bs}). Mientras siga pendiente, no podrás usar Helios para nuevos pagos en cuotas. Puedes pagarla por Pago Móvil a {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago} y enviarnos la foto del comprobante por este chat. Si ya pagaste, ignora este mensaje.$t$),
  ('t2', 'Dos cuotas vencidas',
   $t$Hola {nombre}, te escribimos de Helios. Tu deuda lleva {dias_atraso} vencida y las cuotas vencidas suman {monto_usd} ({monto_bs}). Mientras no te pongas al día no podrás usar Helios para nuevos pagos en cuotas y, si la deuda sigue pendiente, tu acceso a Helios quedará suspendido. Puedes pagar por Pago Móvil a {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago} y enviarnos la foto del comprobante por este chat. Si necesitas acordar una fecha, respóndenos por aquí.$t$),
  ('t3', 'Acceso suspendido',
   $t$Hola {nombre}, te escribimos de Helios. Tu cuota del {fecha_vencimiento} lleva {dias_atraso} vencida y tu acceso a Helios está suspendido. Las cuotas vencidas suman {monto_usd} ({monto_bs}). Respóndenos por aquí para acordar cómo pagarlas, o abónalas por Pago Móvil a {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago} y envíanos la foto del comprobante por este chat.$t$),
  ('t4', 'Último aviso',
   $t$Hola {nombre}, te escribimos de Helios. Tu deuda de {monto_usd} ({monto_bs}) lleva {dias_atraso} vencida y ya no puedes usar Helios. Queremos resolverlo contigo: respóndenos por aquí y buscamos juntos la forma de que te pongas al día. También puedes pagar por Pago Móvil a {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago} y enviarnos la foto del comprobante por este chat.$t$)
) as n(bucket, label, cuerpo)
where t.bucket = n.bucket;

