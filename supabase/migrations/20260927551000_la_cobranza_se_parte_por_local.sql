-- ============================================================================
-- Ronda — La cobranza y el riesgo se parten por local (y por semana)
--
-- Métricas tiene dos controles que valen para todas las pestañas: la semana y
-- el local. Las RPC de Cobranza y riesgo ganan `p_merchant_id uuid default
-- null` (null = todos los locales, lo de siempre) y, las que lo necesitan para
-- la semana elegida, un día de referencia (`p_hasta`). Quien las llama sin
-- ellos —Inicio, Por cobrar, el asistente— recibe exactamente lo de antes: los
-- parámetros nuevos van con `default` y ninguna clave JSON se quita.
--
-- Las que se reescriben pasan a leer de `metricas.*` (una cifra, una
-- definición):
--   admin_collection_flow        sobre metricas.cobranza_tramos_al.
--   admin_due_vs_collected       sobre metricas.cuotas; gana el desglose y
--                                «lo que entró de lo que vencía ese día».
--   admin_first_payment_default  sobre metricas.cuotas; gana la dimensión
--                                'semana' (la cohorte de consumo).
--   admin_cohort_curves          sobre metricas.cuotas.
--   admin_collection_recovered   sobre metricas.cuotas / cuotas_al /
--                                cargos_por_atraso; gana el desglose.
--
-- Qué quiere decir «de un local» en cada una:
--   * Dinero de cuotas (vencido, recuperado, cosechas, primera cuota, flujo):
--     las cuotas de los consumos de ese local.
--   * Gestiones y promesas: las de las personas con alguna cuota en ese local
--     (a una persona se la llama por toda su deuda).
--   * Uso del cupo: la gente que ha consumido en ese local (el cupo es de la
--     persona, no del local). La respuesta lo dice en `poblacion`.
--   * La cola de Por cobrar: las personas que deben algo de ese local, con
--     sus importes de siempre (por persona).
--   * Lo que no se parte (registros, KYC, caja): la clave vale null.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. admin_overview
-- ---------------------------------------------------------------------------

drop function if exists public.admin_overview(integer);

create or replace function public.admin_overview(
  p_days        integer default 30,
  p_merchant_id uuid    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today     date    := metricas.hoy();
  v_days      integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_from      date;
  v_prev_from date;
  v_count     integer;
  v_openers   integer;
  v_fin       numeric;
  v_prev_fin  numeric;
  v_people    integer;
  v_cartera   record;
  v_impago    record;
  v_result    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from      := v_today - (v_days - 1);
  v_prev_from := v_from - v_days;

  -- El consumo de la ventana y de la anterior, sin el servicio de Ronda.
  select coalesce(sum(k.financed_usd) filter (where k.business_date >= v_from), 0),
         coalesce(sum(k.financed_usd) filter (where k.business_date <  v_from), 0),
         (count(*) filter (where k.business_date >= v_from))::integer,
         (count(distinct k.abrio_user_id) filter (where k.business_date >= v_from))::integer
    into v_fin, v_prev_fin, v_count, v_openers
  from metricas.consumos k
  where k.business_date between v_prev_from and v_today
    and (p_merchant_id is null or k.merchant_id = p_merchant_id);

  -- La gente: todos los que tienen cuota, no quien abrió la cuenta.
  select count(distinct q.user_id)::integer into v_people
  from metricas.cuotas q
  where q.business_date between v_from and v_today
    and (p_merchant_id is null or q.merchant_id = p_merchant_id);

  v_result := jsonb_build_object(
    'business_date', v_today,
    'window_days',   v_days,
    'merchant_id',   p_merchant_id,
    'volume', jsonb_build_object(
      'financed_usd',   v_fin,
      'previous_usd',   v_prev_fin,
      'charge_count',   v_count,
      'active_users',   v_people,
      'avg_ticket_usd', case when v_count > 0 then round(v_fin / v_count, 2) else 0 end,
      'financed_volume_usd',          v_fin,
      'previous_financed_volume_usd', v_prev_fin,
      'financed_change_pct', case when v_prev_fin > 0
        then round(100 * (v_fin - v_prev_fin) / v_prev_fin, 1) else null end,
      'avg_ticket_financed_usd', case when v_count > 0 then round(v_fin / v_count, 2) else null end,
      'active_people',   v_people,
      -- Quien abrió la cuenta. En un consumo de grupo pagan más.
      'account_openers', v_openers
    )
  );

  -- La mora. Sobre lo que todavía se puede cobrar: lo dado por perdido tiene
  -- su cifra aparte.
  select * into v_cartera from metricas.cartera_al(v_today, p_merchant_id);

  v_result := v_result || jsonb_build_object('arrears', (
    select jsonb_build_object(
      'open_usd',             v_cartera.vencido_payable_usd + v_cartera.por_vencer_payable_usd,
      'open_financed_usd',    v_cartera.vencido_financed_usd + v_cartera.por_vencer_financed_usd,
      'open_fee_usd',         v_cartera.vencido_fee_usd + v_cartera.por_vencer_fee_usd,
      'overdue_usd',          v_cartera.vencido_payable_usd,
      'overdue_financed_usd', v_cartera.vencido_financed_usd,
      'overdue_fee_usd',      v_cartera.vencido_fee_usd,
      'overdue_users',        v_cartera.personas_vencidas,
      'due_today_usd',        coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'por_vencer' and q.due_date = v_today), 0),
      'rate_pct',             coalesce(v_cartera.mora_pct, 0),
      'demotion_days',        public.helios_mora_demotion_days(),
      'expulsion_days',       public.helios_mora_expulsion_days(),
      'bucket_frozen_usd',    coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'vencida'
                                   and q.dias_atraso <= public.helios_mora_demotion_days()), 0),
      'bucket_demotion_usd',  coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'vencida'
                                   and q.dias_atraso >  public.helios_mora_demotion_days()
                                   and q.dias_atraso <= public.helios_mora_expulsion_days()), 0),
      'bucket_expulsion_usd', coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'vencida'
                                   and q.dias_atraso >  public.helios_mora_expulsion_days()), 0)
    )
    from metricas.cuotas q
    where q.estado_hoy in ('vencida', 'por_vencer')
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ));

  -- Impago: lo dado por perdido, en consumo, sobre TODO lo financiado en la
  -- historia (lo que se pierde hoy nació hace meses). La tasa y el punto de
  -- empate salen de metricas.cobranza_impago, la misma función que Cobranza.
  select * into v_impago from metricas.cobranza_impago(p_merchant_id);

  v_result := v_result || jsonb_build_object('bad_debt', (
    select jsonb_build_object(
      'written_off_usd',          v_impago.perdido_financed_usd,
      'written_off_users',        v_impago.personas_perdidas,
      'financed_usd',             v_impago.financiado_usd,
      'window_usd',               coalesce(sum(q.financed_usd) filter (
                                     where q.estado_hoy = 'perdida'
                                       and public.helios_business_date(q.written_off_at) between v_from and v_today), 0),
      'rate_pct',                 coalesce(v_impago.impago_pct, 0),
      'written_off_financed_usd', v_impago.perdido_financed_usd,
      'lifetime_financed_usd',    v_impago.financiado_usd,
      'window_financed_usd',      coalesce(sum(q.financed_usd) filter (
                                     where q.estado_hoy = 'perdida'
                                       and public.helios_business_date(q.written_off_at) between v_from and v_today), 0),
      'rate_financed_pct',        v_impago.impago_pct,
      'written_off_debt_usd',     v_impago.perdido_payable_usd,
      'written_off_fee_usd',      v_impago.perdido_fee_usd,
      'break_even_pct',           v_impago.empate_pct
    )
    from metricas.cuotas q
    where q.estado_hoy = 'perdida'
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ));

  -- Los registros por estado: no son de ningún local.
  v_result := v_result || jsonb_build_object('users', case when p_merchant_id is null then (
    select jsonb_build_object(
      'total',         count(*),
      'pending_kyc',   count(*) filter (where p.estado in ('pending_kyc', 'pending_pin')),
      'active',        count(*) filter (where p.estado = 'active'),
      'frozen',        count(*) filter (where p.estado = 'frozen'),
      'suspended',     count(*) filter (where p.estado = 'suspended'),
      'expelled',      count(*) filter (where p.estado = 'expelled'),
      'blacklisted',   count(*) filter (where pr.is_blacklisted),
      'new_in_window', count(*) filter (where p.registro_dia between v_from and v_today),
      'unconfirmed_phone', (
        select count(*) from public.profiles x
        where not x.is_test
          and not exists (select 1 from metricas.personas y where y.user_id = x.id)
      )
    )
    from metricas.personas p
    join public.profiles pr on pr.id = p.user_id
  ) end);

  -- Embudo de KYC: tampoco es de un local.
  v_result := v_result || jsonb_build_object('kyc', case when p_merchant_id is null then (
    select jsonb_build_object(
      'pending_review', count(*) filter (where v.status = 'manual_review'),
      'processing',     count(*) filter (where v.status = 'processing'),
      'approved',       count(*) filter (where v.status = 'approved'),
      'rejected',       count(*) filter (where v.status = 'rejected'),
      'approval_rate_pct', case
        when count(*) filter (where v.status in ('approved', 'rejected')) > 0
        then round(100.0 * count(*) filter (where v.status = 'approved')
                        / count(*) filter (where v.status in ('approved', 'rejected')), 1)
        else null end,
      'oldest_pending_hours', coalesce(round(extract(epoch from
        (now() - min(v.created_at) filter (where v.status = 'manual_review'))) / 3600.0, 1), 0)
    )
    from kyc.verifications v
    where not public.helios_is_test_user(v.user_id)
  ) end);

  -- Colas de trabajo. Lo que se le debe al local sí se parte; los pagos por
  -- revisar son de personas, no de locales.
  v_result := v_result || jsonb_build_object('queues', jsonb_build_object(
    'payments_to_reconcile', case when p_merchant_id is null then (
      select count(*) from public.payment_reports r
      where r.status in ('reported', 'in_review')
        and not public.helios_is_test_user(r.user_id)
    ) end,
    'merchant_payouts_due', (
      select coalesce(sum(s.amount_usd - s.paid_usd), 0) from public.settlements s
      where s.status in ('pending', 'partial') and s.due_date <= v_today
        and not public.helios_is_test_merchant(s.merchant_id)
        and (p_merchant_id is null or s.merchant_id = p_merchant_id)
    ),
    'merchant_payouts_pending', (
      select coalesce(sum(s.amount_usd - s.paid_usd), 0) from public.settlements s
      where s.status in ('pending', 'partial')
        and not public.helios_is_test_merchant(s.merchant_id)
        and (p_merchant_id is null or s.merchant_id = p_merchant_id)
    )
  ));

  v_result := v_result || jsonb_build_object('merchants', case when p_merchant_id is null then (
    select jsonb_build_object(
      'total',      count(*),
      'active',     count(*) filter (where m.status = 'active'),
      'paused',     count(*) filter (where m.status = 'paused'),
      'terminated', count(*) filter (where m.status = 'terminated'),
      'selling_in_window', (
        select count(distinct k.merchant_id) from metricas.consumos k
        where k.business_date between v_from and v_today
      )
    )
    from public.merchants m
    where not m.is_test
  ) end);

  -- Tasa BCV: vale igual para cualquier local.
  v_result := v_result || jsonb_build_object('fx', (
    select jsonb_build_object(
      'rate',           e.rate,
      'effective_date', e.effective_date,
      'fetched_at',     e.fetched_at,
      'age_hours',      round(extract(epoch from (now() - e.fetched_at)) / 3600.0, 1),
      'stale',          (now() - e.fetched_at) > interval '48 hours'
    )
    from public.exchange_rates e
    order by e.effective_date desc limit 1
  ));

  -- La caja es de Ronda, no de un local.
  v_result := v_result || jsonb_build_object('cash',
    case when p_merchant_id is null then public.admin_cash_position() end);

  return v_result;
end;
$$;

comment on function public.admin_overview(integer, uuid) is
  'El pulso del negocio: consumo de la ventana y la anterior (sin servicio), personas con cuota, la mora canónica con sus tramos, el impago en consumo con su punto de empate (metricas.cobranza_impago), los registros por estado, KYC, colas, locales, tasa BCV y caja. Con p_merchant_id: consumo, mora, impago y lo debido al local de ese local; users, kyc, merchants, cash y payments_to_reconcile valen null (no se parten). Lee de metricas.';

revoke all on function public.admin_overview(integer, uuid) from public, anon;
grant execute on function public.admin_overview(integer, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. admin_collections: la cola de Por cobrar, con el perfil de cada deudor
-- ---------------------------------------------------------------------------

drop function if exists public.admin_collections(integer);
drop function if exists public.admin_collections(integer, uuid);

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
               'motivo',    p.motivo)
             order by (f.r ->> 'next_due_date')::date, (f.r ->> 'open_usd')::numeric desc, f.r ->> 'user_id'),
           '[]'::jsonb)
    into v_rows
  from de_la_cohorte f
  left join perfiles p on p.user_id = (f.r ->> 'user_id')::uuid;

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
  'Cola de cobranza por persona, con su tramo, lo que debe (PAYABLE, con lo dado por perdido dentro, como siempre) y la ultima gestion. Cada fila lleva su perfil de deudor (metricas.perfil_deudor): perfil, prioridad, orden y motivo. Con p_merchant_id, las personas que deben algo de ese local; con p_cohorte (un lunes), las que deben algo vencido de consumos de esa semana; en los dos casos con sus importes de siempre (la cola es por persona). Los umbrales viajan fuera de las filas.';

revoke all on function public.admin_collections(integer, uuid, date) from public, anon;
grant execute on function public.admin_collections(integer, uuid, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. admin_on_time_collection
-- ---------------------------------------------------------------------------

drop function if exists public.admin_on_time_collection(integer);

create or replace function public.admin_on_time_collection(
  p_days        integer default 30,
  p_merchant_id uuid    default null,
  p_hasta       date    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date    := metricas.hoy();
  v_days  integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_grace integer := public.helios_on_time_grace_days();
  v_to    date;
  v_from  date;
  v_rows  jsonb;
  v_total jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- El último vencimiento cuyo plazo ya cerró, o `p_hasta` si es anterior:
  -- con la semana elegida, las cuotas que vencían en ella (o, si todavía no
  -- se pueden juzgar, los últimos días que sí).
  v_to   := least(coalesce(p_hasta, v_today), v_today - v_grace - 1);
  v_from := v_to - (v_days - 1);

  select coalesce(jsonb_object_agg(x.key, x.value), '{}'::jsonb)
  into v_rows
  from (
    select
      'cuota_' || q.sequence::text as key,
      jsonb_build_object(
        'sequence',      q.sequence,
        'due_count',     count(*)::integer,
        'on_time_count', (count(*) filter (where q.estado_hoy = 'a_tiempo'))::integer,
        'late_count',    (count(*) filter (where q.estado_hoy = 'tarde'))::integer,
        'unpaid_count',  (count(*) filter (where q.estado_hoy in ('vencida', 'perdida')))::integer,
        'due_usd',       coalesce(sum(q.payable_usd), 0),
        'due_financed_usd', coalesce(sum(q.financed_usd), 0),
        'due_fee_usd',   coalesce(sum(q.fee_usd), 0),
        'on_time_usd',   coalesce(sum(q.payable_usd) filter (where q.estado_hoy = 'a_tiempo'), 0),
        'rate_pct', case
          when count(*) > 0
          then round(100.0 * count(*) filter (where q.estado_hoy = 'a_tiempo') / count(*), 1)
          else null end
      ) as value
    from metricas.cuotas q
    where q.plazo_cerrado
      and q.due_date between v_from and v_to
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    group by q.sequence
  ) x;

  -- Las dos cuotas juntas: la cifra titular de «cobrado a tiempo».
  select jsonb_build_object(
           'due_count',     count(*)::integer,
           'on_time_count', (count(*) filter (where q.estado_hoy = 'a_tiempo'))::integer,
           'late_count',    (count(*) filter (where q.estado_hoy = 'tarde'))::integer,
           'unpaid_count',  (count(*) filter (where q.estado_hoy in ('vencida', 'perdida')))::integer,
           'rate_pct', case
             when count(*) > 0
             then round(100.0 * count(*) filter (where q.estado_hoy = 'a_tiempo') / count(*), 1)
             else null end)
    into v_total
  from metricas.cuotas q
  where q.plazo_cerrado
    and q.due_date between v_from and v_to
    and (p_merchant_id is null or q.merchant_id = p_merchant_id);

  return jsonb_build_object(
    'business_date', v_today,
    'window_days',   v_days,
    'grace_days',    v_grace,
    'from',          v_from,
    'to',            v_to,
    'merchant_id',   p_merchant_id,
    'installments',  v_rows,
    'total',         v_total
  );
end;
$$;

comment on function public.admin_on_time_collection(integer, uuid, date) is
  'Cobro a tiempo: de las cuotas con el plazo cerrado que vencían en los p_days días que acaban en min(p_hasta, hoy − gracia − 1), cuántas se pagaron a tiempo (metricas.cuotas.estado_hoy). Por cuota (installments) y las dos juntas (total). Lo perdido cuenta en el denominador. Con p_merchant_id, las cuotas de los consumos de ese local.';

revoke all on function public.admin_on_time_collection(integer, uuid, date) from public, anon;
grant execute on function public.admin_on_time_collection(integer, uuid, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. admin_collection_flow: el paso entre tramos, sobre cobranza_tramos_al
-- ---------------------------------------------------------------------------

drop function if exists public.admin_collection_flow(integer);

create or replace function public.admin_collection_flow(
  p_weeks       integer default 8,
  p_merchant_id uuid    default null,
  p_hasta       date    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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
    values ('t1', 1), ('t2', 2), ('t3', 3), ('t4', 4), ('t5', 5)
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
                       order by array_position(array['nuevo','al_dia','t1','t2','t3','t4','t5'], ps.from_t),
                                array_position(array['al_dia','t1','t2','t3','t4','t5'], ps.to_t))
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
$$;

comment on function public.admin_collection_flow(integer, uuid, date) is
  'El paso entre tramos: en cada corte (el cierre de cada domingo, o de p_hasta si cae a media semana; ahora si es hoy), el tramo de cada persona según metricas.cobranza_tramos_al, y de un corte al siguiente de dónde venía (nuevo si no tenía cuotas) y adónde fue. Lo vencido es PAYABLE con desglose y sin lo dado por perdido. Sin p_hasta, los lunes de siempre. Con p_merchant_id, las cuotas de ese local.';

revoke all on function public.admin_collection_flow(integer, uuid, date) from public, anon;
grant execute on function public.admin_collection_flow(integer, uuid, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. admin_due_vs_collected: lo que vencía y lo que entró, día a día
-- ---------------------------------------------------------------------------

drop function if exists public.admin_due_vs_collected(integer);

create or replace function public.admin_due_vs_collected(
  p_days        integer default 30,
  p_merchant_id uuid    default null,
  p_hasta       date    default null
)
returns table (
  business_date          date,
  due_usd                numeric,
  due_count              integer,
  collected_usd          numeric,
  collected_count        integer,
  due_financed_usd       numeric,
  due_fee_usd            numeric,
  due_paid_usd           numeric,
  due_paid_financed_usd  numeric,
  due_paid_fee_usd       numeric,
  due_paid_count         integer,
  collected_financed_usd numeric,
  collected_fee_usd      numeric,
  is_future              boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date    := metricas.hoy();
  v_days  integer := greatest(least(coalesce(p_days, 30), 365), 1);
  -- Se puede mirar hasta un mes por delante: lo que vence después de hoy
  -- sale marcado (is_future) y todavía puede pagarse.
  v_hasta date    := least(coalesce(p_hasta, metricas.hoy()), metricas.hoy() + 31);
  v_desde date;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_desde := v_hasta - (v_days - 1);

  return query
  with
  dias as (
    select (v_desde + k)::date as d from generate_series(0, v_days - 1) k
  ),
  -- Lo que vencía ese día y, de eso, lo que ya se pagó. Lo dado por perdido
  -- queda fuera: dejó de esperarse.
  vence as (
    select q.due_date as d,
           sum(q.payable_usd)  as usd,
           sum(q.financed_usd) as fin,
           sum(q.fee_usd)      as fee,
           count(*)::integer   as n,
           sum(q.payable_usd)  filter (where q.status = 'paid') as p_usd,
           sum(q.financed_usd) filter (where q.status = 'paid') as p_fin,
           sum(q.fee_usd)      filter (where q.status = 'paid') as p_fee,
           (count(*) filter (where q.status = 'paid'))::integer  as p_n
    from metricas.cuotas q
    where q.estado_hoy <> 'perdida'
      and q.due_date between v_desde and v_hasta
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    group by q.due_date
  ),
  -- Lo que entró ese día (el día operativo en que se aprobó el pago), fuera
  -- cual fuera su vencimiento.
  entra as (
    select q.pagada_dia as d,
           sum(q.payable_usd)  as usd,
           sum(q.financed_usd) as fin,
           sum(q.fee_usd)      as fee,
           count(*)::integer   as n
    from metricas.cuotas q
    where q.status = 'paid'
      and q.pagada_dia between v_desde and v_hasta
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    group by q.pagada_dia
  )
  select
    dias.d,
    coalesce(v.usd, 0)::numeric,
    coalesce(v.n, 0)::integer,
    coalesce(e.usd, 0)::numeric,
    coalesce(e.n, 0)::integer,
    coalesce(v.fin, 0)::numeric,
    coalesce(v.fee, 0)::numeric,
    coalesce(v.p_usd, 0)::numeric,
    coalesce(v.p_fin, 0)::numeric,
    coalesce(v.p_fee, 0)::numeric,
    coalesce(v.p_n, 0)::integer,
    coalesce(e.fin, 0)::numeric,
    coalesce(e.fee, 0)::numeric,
    dias.d > v_today
  from dias
  left join vence v on v.d = dias.d
  left join entra e on e.d = dias.d
  order by dias.d;
end;
$$;

comment on function public.admin_due_vs_collected(integer, uuid, date) is
  'Día a día (p_days días que acaban en p_hasta, por defecto hoy): lo que vencía (due_*, PAYABLE con desglose, sin lo dado por perdido), lo que de eso ya se pagó (due_paid_*) y lo que entró ese día por cualquier cuota (collected_*, por el día operativo de la aprobación). is_future: el día todavía no ha llegado. Lee de metricas.cuotas; con p_merchant_id, las cuotas de ese local.';

revoke all on function public.admin_due_vs_collected(integer, uuid, date) from public, anon;
grant execute on function public.admin_due_vs_collected(integer, uuid, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. admin_first_payment_default: la primera cuota, también por semana
-- ---------------------------------------------------------------------------

drop function if exists public.admin_first_payment_default(integer, text);

create or replace function public.admin_first_payment_default(
  p_months      integer default 6,
  p_dim         text    default 'mes',
  p_merchant_id uuid    default null,
  p_hasta       date    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date    := metricas.hoy();
  v_ref    date    := least(coalesce(p_hasta, metricas.hoy()), metricas.hoy());
  v_months integer := greatest(least(coalesce(p_months, 6), 24), 1);
  v_dim    text    := coalesce(nullif(trim(p_dim), ''), 'mes');
  v_grace  integer := public.helios_late_fee_grace_days();
  -- Fijo a propósito: es la vara estándar (FPD30) y no una regla del producto.
  v_late   constant integer := 30;
  v_from   date;
  v_out    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_dim not in ('mes', 'semana', 'local', 'nivel', 'grupo', 'primera_compra') then
    raise exception 'No se puede agrupar por «%»: usa mes, semana, local, nivel, grupo o primera_compra', v_dim
      using errcode = '22023';
  end if;

  -- Los consumos de los p_months meses que acaban en el de v_ref, hasta v_ref.
  -- Si la cuota ya pasó la gracia se juzga HOY: es lo que se sabe ahora.
  v_from := (date_trunc('month', v_ref::timestamp)
             - ((v_months - 1) * interval '1 month'))::date;

  with
  cuota as (
    select
      q.user_id,
      q.charge_id,
      q.financed_usd,
      q.business_date,
      q.merchant_id,
      coalesce(ch.confirmed_at, ch.created_at) as consumed_at,
      q.due_date + v_grace < v_today as madura,
      q.due_date + v_late  < v_today as madura_30,
      -- Un `paid` sin fecha es de antes de que se guardara: cuenta como pagada.
      q.status = 'paid' and (q.pagada_dia is null or q.pagada_dia <= q.due_date + v_grace) as pagada_en_gracia,
      q.status = 'paid' and (q.pagada_dia is null or q.pagada_dia <= q.due_date + v_late)  as pagada_a_30
    from metricas.cuotas q
    join public.charges ch on ch.id = q.charge_id
    where q.sequence = 1
      and q.business_date between v_from and v_ref
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ),
  -- Solo se calcula lo que pide la dimensión: el CASE no evalúa las otras ramas.
  dimension as (
    select
      cu.*,
      case when v_dim = 'nivel'
        then public.helios_level_at(cu.user_id, cu.consumed_at) end as nivel_historia,
      case when v_dim = 'nivel'
        then (select p.level from public.profiles p where p.id = cu.user_id) end as nivel_actual,
      case when v_dim = 'grupo'
        then (select count(distinct j.user_id) from public.installments j
               where j.charge_id = cu.charge_id) end as personas,
      case when v_dim = 'primera_compra'
        then cu.charge_id = (
          select j.charge_id
          from public.installments j
          join public.charges c2 on c2.id = j.charge_id
          where j.user_id = cu.user_id
            and c2.status = 'confirmed'
            and not c2.is_test
          order by c2.business_date, c2.confirmed_at, c2.id
          limit 1) end as es_primera
    from cuota cu
  ),
  clave as (
    select
      d.*,
      case v_dim
        when 'mes'    then to_char(date_trunc('month', d.business_date::timestamp), 'YYYY-MM')
        when 'semana' then metricas.lunes(d.business_date)::text
        when 'local'  then d.merchant_id::text
        when 'nivel'  then coalesce(d.nivel_historia, d.nivel_actual)::text
        when 'grupo'  then case
          when d.personas <= 1 then '1'
          when d.personas = 2  then '2'
          when d.personas <= 4 then '3-4'
          else '5+' end
        else case when d.es_primera then 'si' else 'no' end
      end as key
    from dimension d
  ),
  fila as (
    select
      k.key,
      count(*) filter (where k.madura)::integer                                   as matured_count,
      count(*) filter (where k.madura and not k.pagada_en_gracia)::integer        as defaulted_count,
      round(100.0 * count(*) filter (where k.madura and not k.pagada_en_gracia)
            / nullif(count(*) filter (where k.madura), 0), 1)                     as defaulted_pct,
      coalesce(sum(k.financed_usd) filter (where k.madura), 0)                    as matured_financed_usd,
      coalesce(sum(k.financed_usd) filter (where k.madura and not k.pagada_en_gracia), 0)
                                                                                  as defaulted_financed_usd,
      count(*) filter (where k.madura_30)::integer                                as matured_30_count,
      count(*) filter (where k.madura_30 and not k.pagada_a_30)::integer          as defaulted_30_count,
      round(100.0 * count(*) filter (where k.madura_30 and not k.pagada_a_30)
            / nullif(count(*) filter (where k.madura_30), 0), 1)                  as defaulted_30_pct,
      coalesce(sum(k.financed_usd) filter (where k.madura_30), 0)                 as matured_30_financed_usd,
      coalesce(sum(k.financed_usd) filter (where k.madura_30 and not k.pagada_a_30), 0)
                                                                                  as defaulted_30_financed_usd,
      count(*) filter (where not k.madura)::integer                               as in_grace_count
    from clave k
    group by k.key
  ),
  rotulada as (
    select
      f.*,
      case v_dim
        when 'mes'    then f.key
        when 'semana' then f.key
        when 'local'  then (select m.name from public.merchants m where m.id::text = f.key)
        when 'nivel'  then (select l.label from public.levels l where l.level::text = f.key)
        when 'grupo'  then case f.key
          when '1' then 'Una persona' when '2' then 'Dos personas'
          when '3-4' then 'De tres a cuatro personas' else 'Cinco personas o más' end
        else case f.key when 'si' then 'Primer consumo' else 'Consumos siguientes' end
      end as label,
      -- El orden en que se leen: el mes y la semana más recientes primero, el
      -- local con más cuotas primero, y los demás en su orden natural.
      case v_dim
        when 'mes'    then -(extract(year from to_date(f.key, 'YYYY-MM')) * 12
                             + extract(month from to_date(f.key, 'YYYY-MM')))
        when 'semana' then -(f.key::date - date '2000-01-03')
        when 'local'  then -f.matured_count
        when 'nivel'  then f.key::numeric
        when 'grupo'  then array_position(array['1', '2', '3-4', '5+'], f.key)
        else case f.key when 'si' then 0 else 1 end
      end as orden
    from fila f
  )
  select jsonb_build_object(
    'business_date', v_today,
    'from',          v_from,
    'to',            v_ref,
    'months',        v_months,
    'dim',           v_dim,
    'merchant_id',   p_merchant_id,
    'grace_days',    v_grace,
    'late_days',     v_late,
    -- Solo con `nivel`: de dónde salió el nivel de las cuotas maduras.
    'level_basis', case when v_dim = 'nivel' then jsonb_build_object(
        'history', (select count(*) from clave where madura and nivel_historia is not null),
        'current', (select count(*) from clave where madura and nivel_historia is null)
      ) end,
    'total', (
      select jsonb_build_object(
        'matured_count',            count(*) filter (where madura),
        'defaulted_count',          count(*) filter (where madura and not pagada_en_gracia),
        'defaulted_pct',            round(100.0 * count(*) filter (where madura and not pagada_en_gracia)
                                          / nullif(count(*) filter (where madura), 0), 1),
        'matured_financed_usd',     coalesce(sum(financed_usd) filter (where madura), 0),
        'defaulted_financed_usd',   coalesce(sum(financed_usd) filter (where madura and not pagada_en_gracia), 0),
        'matured_30_count',         count(*) filter (where madura_30),
        'defaulted_30_count',       count(*) filter (where madura_30 and not pagada_a_30),
        'defaulted_30_pct',         round(100.0 * count(*) filter (where madura_30 and not pagada_a_30)
                                          / nullif(count(*) filter (where madura_30), 0), 1),
        'matured_30_financed_usd',  coalesce(sum(financed_usd) filter (where madura_30), 0),
        'defaulted_30_financed_usd', coalesce(sum(financed_usd) filter (where madura_30 and not pagada_a_30), 0),
        'in_grace_count',           count(*) filter (where not madura)
      )
      from cuota
    ),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(r) - 'orden' order by r.orden, r.label)
      from rotulada r
    ), '[]'::jsonb)
  )
  into v_out;

  return v_out;
end;
$$;

comment on function public.admin_first_payment_default(integer, text, uuid, date) is
  'El impago de la primera cuota: de cada consumo confirmado de los p_months meses que acaban en p_hasta (por defecto hoy), la cuota 1 de cada persona; impagada si seguía sin pagar el último día de la gracia (late_fee_grace_days), y a los 30 días. Partido por mes, semana (la cohorte de consumo, clave = su lunes), local, nivel, grupo o primera_compra. Montos en consumo (financed). Lee de metricas.cuotas; con p_merchant_id, los consumos de ese local.';

revoke all on function public.admin_first_payment_default(integer, text, uuid, date) from public, anon;
grant execute on function public.admin_first_payment_default(integer, text, uuid, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. admin_credit_cohorts
-- ---------------------------------------------------------------------------

drop function if exists public.admin_credit_cohorts(integer);

create or replace function public.admin_credit_cohorts(
  p_months      integer default 6,
  p_merchant_id uuid    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date    := metricas.hoy();
  v_months integer := greatest(least(coalesce(p_months, 6), 24), 1);
  v_from   date;
  -- Cuántos días tarda una cosecha en tener su número definitivo: lo que tarda
  -- la última cuota en vencer, más la escalera entera.
  v_season integer := 2 * public.helios_installment_interval_days()
                    + public.helios_mora_expulsion_days();
  v_rows   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := (date_trunc('month', v_today::timestamp)
             - ((v_months - 1) * interval '1 month'))::date;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.month desc), '[]'::jsonb)
  into v_rows
  from (
    select
      to_char(date_trunc('month', q.business_date::timestamp), 'YYYY-MM')   as month,
      count(distinct q.charge_id)::integer                                   as charge_count,
      count(distinct q.user_id)::integer                                     as user_count,
      sum(q.financed_usd)                                                    as financed_usd,
      sum(q.payable_usd) filter (where q.status = 'paid')                    as paid_usd,
      sum(q.payable_usd) filter (where q.estado_hoy = 'vencida')             as overdue_usd,
      sum(q.payable_usd) filter (where q.estado_hoy = 'por_vencer')          as current_usd,
      sum(q.payable_usd) filter (where q.estado_hoy = 'perdida')             as written_off_usd,
      round(100 * sum(q.payable_usd) filter (where q.estado_hoy = 'vencida')
                / nullif(sum(q.payable_usd), 0), 2)                          as overdue_pct,
      round(100 * sum(q.payable_usd) filter (where q.estado_hoy = 'perdida')
                / nullif(sum(q.payable_usd), 0), 2)                          as written_off_pct,
      (max(q.business_date) + v_season) <= v_today                          as matured,
      sum(q.payable_usd)                                                     as billed_debt_usd,
      sum(q.financed_usd)                                                    as financed_volume_usd,
      coalesce(sum(q.financed_usd) filter (where q.status = 'paid'), 0)      as paid_financed_usd,
      coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'vencida'), 0)    as overdue_financed_usd,
      coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'por_vencer'), 0) as current_financed_usd,
      coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'perdida'), 0)    as written_off_financed_usd,
      round(100 * coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'perdida'), 0)
                / nullif(sum(q.financed_usd), 0), 2)                         as written_off_financed_pct,
      count(distinct q.user_id)::integer                                     as people_count
    from metricas.cuotas q
    where q.business_date >= v_from
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    group by 1
  ) r;

  return jsonb_build_object(
    'business_date',  v_today,
    'months',         v_months,
    'merchant_id',    p_merchant_id,
    'season_days',    v_season,
    'expulsion_days', public.helios_mora_expulsion_days(),
    'rows',           v_rows
  );
end;
$$;

comment on function public.admin_credit_cohorts(integer, uuid) is
  'Cosechas por mes de consumo: personas con cuota, consumo (financed), y en deuda (payable) lo pagado, vencido, por vencer y perdido. overdue_pct es vencido ÷ todo lo facturado por la cosecha (no la mora de la cartera). Lee de metricas.cuotas; con p_merchant_id, los consumos de ese local.';

revoke all on function public.admin_credit_cohorts(integer, uuid) from public, anon;
grant execute on function public.admin_credit_cohorts(integer, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. admin_cohort_curves
-- ---------------------------------------------------------------------------

drop function if exists public.admin_cohort_curves(integer);

create or replace function public.admin_cohort_curves(
  p_months      integer default 6,
  p_merchant_id uuid    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date    := metricas.hoy();
  v_months integer := greatest(least(coalesce(p_months, 6), 24), 1);
  v_from   date;
  v_max    integer;
  v_rows   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := (date_trunc('month', v_today::timestamp)
             - ((v_months - 1) * interval '1 month'))::date;
  v_max  := greatest((v_today - v_from) / 7, 1);

  with
  cuota as (
    select
      q.charge_id,
      q.business_date                                                      as dia,
      to_char(date_trunc('month', q.business_date::timestamp), 'YYYY-MM') as mes,
      q.financed_usd,
      q.due_date,
      q.status,
      q.pagada_dia,
      q.written_off_at
    from metricas.cuotas q
    where q.business_date >= v_from
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ),
  cosecha as (
    select
      q.mes,
      sum(q.financed_usd)                  as financiado,
      count(distinct q.charge_id)::integer as consumos,
      min(q.dia)                           as primero,
      max(q.dia)                           as ultimo
    from cuota q
    group by q.mes
  ),
  -- Cada cuota en cada edad que ya cumplió. En el corte de hoy manda el
  -- estado de ahora: un pago de esta mañana ya cuenta.
  punto as (
    select
      q.mes,
      e.k,
      q.financed_usd,
      q.due_date < q.dia + 7 * e.k                                   as vencida_ya,
      q.status = 'paid' and (q.pagada_dia is null
        or q.pagada_dia < q.dia + 7 * e.k
        or q.dia + 7 * e.k >= v_today)                               as pagada,
      q.written_off_at is not null and (
        public.helios_business_date(q.written_off_at) < q.dia + 7 * e.k
        or q.dia + 7 * e.k >= v_today)                               as perdida
    from cuota q
    cross join generate_series(1, v_max) as e(k)
    where q.dia + 7 * e.k <= v_today
  ),
  celda as (
    select
      p.mes,
      p.k,
      sum(p.financed_usd)                                                         as alcanzado,
      coalesce(sum(p.financed_usd) filter (where p.vencida_ya and not p.pagada and not p.perdida), 0) as vencido,
      coalesce(sum(p.financed_usd) filter (where p.perdida), 0)                   as perdido
    from punto p
    group by p.mes, p.k
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'month',         co.mes,
      'financed_usd',  co.financiado,
      'charge_count',  co.consumos,
      'first_day',     co.primero,
      'last_day',      co.ultimo,
      'curve', coalesce((
        select jsonb_agg(jsonb_build_object(
            'week',                     ce.k,
            'reached_financed_usd',     ce.alcanzado,
            'overdue_financed_usd',     ce.vencido,
            'overdue_pct',              round(100 * ce.vencido / nullif(ce.alcanzado, 0), 2),
            'written_off_financed_usd', ce.perdido,
            'written_off_pct',          round(100 * ce.perdido / nullif(ce.alcanzado, 0), 2),
            'complete',                 co.ultimo + 7 * ce.k <= v_today
          ) order by ce.k)
        from celda ce
        where ce.mes = co.mes
      ), '[]'::jsonb)
    ) order by co.mes desc), '[]'::jsonb)
  into v_rows
  from cosecha co;

  return jsonb_build_object(
    'business_date', v_today,
    'months',        v_months,
    'merchant_id',   p_merchant_id,
    'from',          v_from,
    'max_week',      v_max,
    'rows',          v_rows
  );
end;
$$;

comment on function public.admin_cohort_curves(integer, uuid) is
  'Curvas de cosecha por mes: semana a semana de edad, el consumo (financed) vencido sin pagar y el dado por perdido sobre lo alcanzado. Lee de metricas.cuotas; con p_merchant_id, los consumos de ese local.';

revoke all on function public.admin_cohort_curves(integer, uuid) from public, anon;
grant execute on function public.admin_cohort_curves(integer, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. admin_credit_utilization
-- ---------------------------------------------------------------------------

drop function if exists public.admin_credit_utilization();

create or replace function public.admin_credit_utilization(p_merchant_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := public.helios_business_date(now());
  v_out   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  with
  -- El cupo es de la persona, no del local: con un local se mira a SU gente
  -- (quien tiene alguna cuota allí), con todo su cupo.
  del_local as (
    select distinct q.user_id
    from metricas.cuotas q
    where q.merchant_id = p_merchant_id
  ),
  uso as (
    select i.user_id, sum(i.financed_usd) as usado
    from public.installments i
    where not i.is_test
      and exists (
        select 1 from public.installments j
        where j.charge_id = i.charge_id
          and j.user_id   = i.user_id
          and j.status    = 'pending')
    group by 1
  ),
  expuesto as (
    select i.user_id, sum(i.financed_usd) as principal
    from public.installments i
    where not i.is_test
      and i.status = 'pending'
      and i.written_off_at is null
    group by 1
  ),
  gente as (
    select
      p.id,
      p.level,
      p.status,
      l.monthly_limit_usd                         as limite,
      (l.is_active and l.level >= 1)              as en_nivel,
      coalesce(u.usado, 0)                        as usado,
      coalesce(e.principal, 0)                    as principal,
      case when l.monthly_limit_usd > 0
        then 100 * coalesce(u.usado, 0) / l.monthly_limit_usd end as pct,
      public.helios_available_now_usd(p.id)        as ahora
    from public.profiles p
    join public.levels l on l.level = p.level
    left join uso u      on u.user_id = p.id
    left join expuesto e on e.user_id = p.id
    where not p.is_test
      and (p_merchant_id is null or p.id in (select d.user_id from del_local d))
  ),
  por_nivel as (
    select
      l.level,
      l.label,
      l.monthly_limit_usd                                         as limit_usd,
      count(g.id)::integer                                        as user_count,
      count(g.id) filter (where g.status = 'active')::integer     as active_count,
      count(g.id) filter (where g.usado > 0)::integer             as using_count,
      coalesce(sum(g.limite), 0)                                  as limit_total_usd,
      coalesce(sum(g.usado), 0)                                   as used_financed_usd,
      coalesce(sum(greatest(g.limite - g.usado, 0)), 0)           as available_financed_usd,
      coalesce(sum(g.ahora), 0)                                   as spendable_now_usd,
      coalesce(sum(g.principal), 0)                               as exposure_financed_usd,
      round(100 * sum(g.usado) / nullif(sum(g.limite), 0), 1)     as usage_pct,
      jsonb_build_array(
        jsonb_build_object('key', '0',     'count', count(g.id) filter (where g.pct = 0)),
        jsonb_build_object('key', '1-25',  'count', count(g.id) filter (where g.pct > 0  and g.pct <= 25)),
        jsonb_build_object('key', '26-50', 'count', count(g.id) filter (where g.pct > 25 and g.pct <= 50)),
        jsonb_build_object('key', '51-75', 'count', count(g.id) filter (where g.pct > 50 and g.pct <= 75)),
        jsonb_build_object('key', '76-99', 'count', count(g.id) filter (where g.pct > 75 and g.pct < 100)),
        jsonb_build_object('key', '100',   'count', count(g.id) filter (where g.pct >= 100))
      )                                                           as buckets
    from public.levels l
    left join gente g on g.level = l.level
    where l.is_active and l.level >= 1
    group by l.level, l.label, l.monthly_limit_usd
  )
  select jsonb_build_object(
    'business_date', v_today,
    'merchant_id', p_merchant_id,
    -- Sobre quién se mide: todo el mundo, o la gente del local elegido.
    'poblacion', case when p_merchant_id is null then 'todos' else 'gente_del_local' end,
    'levels', coalesce((select jsonb_agg(to_jsonb(n) order by n.level) from por_nivel n), '[]'::jsonb),
    'outside_levels', (
      select jsonb_build_object(
        'user_count',            count(*),
        'used_financed_usd',     coalesce(sum(g.usado), 0),
        'exposure_financed_usd', coalesce(sum(g.principal), 0)
      )
      from gente g
      where not g.en_nivel and (g.usado > 0 or g.principal > 0)
    ),
    'total', (
      select jsonb_build_object(
        'user_count',             count(*) filter (where g.en_nivel),
        'using_count',            count(*) filter (where g.en_nivel and g.usado > 0),
        'limit_total_usd',        coalesce(sum(g.limite) filter (where g.en_nivel), 0),
        'used_financed_usd',      coalesce(sum(g.usado), 0),
        'available_financed_usd', coalesce(sum(greatest(g.limite - g.usado, 0)) filter (where g.en_nivel), 0),
        'spendable_now_usd',      coalesce(sum(g.ahora) filter (where g.en_nivel), 0),
        'exposure_financed_usd',  coalesce(sum(g.principal), 0),
        'usage_pct',              round(100 * sum(g.usado) filter (where g.en_nivel)
                                        / nullif(sum(g.limite) filter (where g.en_nivel), 0), 1)
      )
      from gente g
    )
  )
  into v_out;

  return v_out;
end;
$$;

comment on function public.admin_credit_utilization(uuid) is
  'El uso del cupo por nivel (en consumo, sin servicio): límite, ocupado, disponible, gastable hoy, exposición y reparto de la gente por el uso de su cupo. Con p_merchant_id, la gente con alguna cuota en ese local y todo su cupo (poblacion = gente_del_local): el cupo es de la persona, no del local.';

revoke all on function public.admin_credit_utilization(uuid) from public, anon;
grant execute on function public.admin_credit_utilization(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 10. admin_merchant_risk (conserva account_openers)
-- ---------------------------------------------------------------------------

drop function if exists public.admin_merchant_risk(integer);

create or replace function public.admin_merchant_risk(
  p_days        integer default 90,
  p_merchant_id uuid    default null
)
returns table (
  merchant_id               uuid,
  merchant_name             text,
  status                    text,
  charge_count              integer,
  financed_usd              numeric,
  distinct_users            integer,
  repeat_ratio              numeric,
  overdue_usd               numeric,
  arrears_pct               numeric,
  volume_share_pct          numeric,
  pending_payout_usd        numeric,
  financed_volume_usd       numeric,
  volume_share_financed_pct numeric,
  distinct_people           integer,
  billed_debt_usd           numeric,
  overdue_debt_usd          numeric,
  overdue_debt_pct          numeric,
  written_off_financed_usd  numeric,
  written_off_financed_pct  numeric,
  account_openers           integer
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := metricas.hoy();
  v_from  date;
  v_total numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := v_today - (greatest(least(coalesce(p_days, 90), 365), 1) - 1);

  -- El peso de un local se mide sobre el consumo de TODOS: con un local
  -- elegido sigue siendo su parte del total.
  select coalesce(sum(k.financed_usd), 0) into v_total
  from metricas.consumos k
  where k.business_date between v_from and v_today;

  return query
  with
  por_local as (
    select k.merchant_id as mid,
           count(*)::integer                           as consumos,
           sum(k.financed_usd)                         as consumo,
           count(distinct k.abrio_user_id)::integer    as abrieron
    from metricas.consumos k
    where k.business_date between v_from and v_today
    group by k.merchant_id
  ),
  cartera as (
    select q.merchant_id as mid,
           count(distinct q.user_id)::integer                                    as personas,
           sum(q.payable_usd)                                                    as facturado,
           sum(q.payable_usd)  filter (where q.estado_hoy = 'vencida')           as vencido,
           sum(q.payable_usd)  filter (where q.estado_hoy in ('vencida', 'por_vencer')) as vivo,
           sum(q.financed_usd) filter (where q.estado_hoy = 'perdida')           as perdido
    from metricas.cuotas q
    where q.business_date between v_from and v_today
    group by q.merchant_id
  ),
  payables as (
    select s.merchant_id as mid, sum(s.amount_usd - s.paid_usd) as pendiente
    from public.settlements s
    where s.status in ('pending', 'partial')
      and not public.helios_is_test_merchant(s.merchant_id)
    group by s.merchant_id
  )
  select
    m.id,
    m.name,
    m.status::text,
    coalesce(pl.consumos, 0),
    coalesce(pl.consumo, 0)::numeric,
    coalesce(ca.personas, 0),
    case when coalesce(pl.abrieron, 0) > 0
         then round(pl.consumos::numeric / pl.abrieron, 2) else 0 end,
    coalesce(ca.vencido, 0)::numeric,
    coalesce(round(100 * coalesce(ca.vencido, 0) / nullif(ca.vivo, 0), 2), 0),
    case when v_total > 0
         then round(100 * coalesce(pl.consumo, 0) / v_total, 2) else 0 end,
    coalesce(p.pendiente, 0)::numeric,
    coalesce(pl.consumo, 0)::numeric,
    case when v_total > 0
         then round(100 * coalesce(pl.consumo, 0) / v_total, 2) else null end,
    coalesce(ca.personas, 0),
    coalesce(ca.facturado, 0)::numeric,
    coalesce(ca.vencido, 0)::numeric,
    round(100 * coalesce(ca.vencido, 0) / nullif(ca.vivo, 0), 2),
    coalesce(ca.perdido, 0)::numeric,
    case when coalesce(pl.consumo, 0) > 0
         then round(100 * coalesce(ca.perdido, 0) / pl.consumo, 2) else null end,
    coalesce(pl.abrieron, 0)
  from public.merchants m
  left join por_local pl on pl.mid = m.id
  left join cartera   ca on ca.mid = m.id
  left join payables  p  on p.mid  = m.id
  where not m.is_test
    and (p_merchant_id is null or m.id = p_merchant_id)
  order by coalesce(pl.consumo, 0) desc;
end;
$$;

comment on function public.admin_merchant_risk(integer, uuid) is
  'Los locales por consumo de los últimos p_days días: consumo (financed), personas con cuota, consumos por quien abre la cuenta (account_openers), lo vencido (payable) y LA mora de sus consumos, y su parte del consumo de todos. Con p_merchant_id, solo ese local (su parte sigue siendo sobre el total). Lee de metricas.';

revoke all on function public.admin_merchant_risk(integer, uuid) from public, anon;
grant execute on function public.admin_merchant_risk(integer, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 11. admin_collection_recovered
-- ---------------------------------------------------------------------------

drop function if exists public.admin_collection_recovered(date, date);

create or replace function public.admin_collection_recovered(
  p_from        date default null,
  p_to          date default null,
  p_merchant_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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
    values ('t1', 1), ('t2', 2), ('t3', 3), ('t4', 4), ('t5', 5)
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
$$;

comment on function public.admin_collection_recovered(date, date, uuid) is
  'Lo recuperado entre dos días operativos: las cuotas aprobadas en el rango que ya estaban vencidas al pagarse (PAYABLE con desglose), por el tramo que tenían ese día; lo vencido al empezar (cierre del día anterior, con lo perdido) y qué parte se cobró; los cargos por atraso cobrados (sin IVA, aparte). Lee de metricas.cuotas, metricas.cuotas_al y metricas.cargos_por_atraso; con p_merchant_id, las cuotas de ese local.';

revoke all on function public.admin_collection_recovered(date, date, uuid) from public, anon;
grant execute on function public.admin_collection_recovered(date, date, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 12. admin_contact_effectiveness
-- ---------------------------------------------------------------------------

drop function if exists public.admin_contact_effectiveness(date, date);

create or replace function public.admin_contact_effectiveness(
  p_from        date default null,
  p_to          date default null,
  p_merchant_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_to      date := coalesce(p_to, public.helios_caracas_date(now()));
  v_from    date := coalesce(p_from, coalesce(p_to, public.helios_caracas_date(now())) - 29);
  v_from_ts timestamptz;
  v_to_ts   timestamptz;
  v_result  jsonb;
begin
  if not public.is_platform_admin() then
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
    select i.user_id, i.paid_at
    from public.installments i
    where i.status = 'paid'
      and not i.is_test
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
$$;

comment on function public.admin_contact_effectiveness(date, date, uuid) is
  'Las gestiones de cobranza entre dos días de Caracas, y cuántas fueron seguidas de un pago reportado o una cuota pagada en 72 h (solo cuentan las que ya cumplieron las 72 h). Por canal, resultado y hora. Con p_merchant_id, las gestiones a personas con alguna cuota en ese local.';

revoke all on function public.admin_contact_effectiveness(date, date, uuid) from public, anon;
grant execute on function public.admin_contact_effectiveness(date, date, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 13. admin_collection_promises
-- ---------------------------------------------------------------------------

drop function if exists public.admin_collection_promises(date, date);

create or replace function public.admin_collection_promises(
  p_from        date default null,
  p_to          date default null,
  p_merchant_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := public.helios_business_date(now());
  v_from  date := coalesce(p_from, public.helios_business_date(now()) - 30);
  v_rows  jsonb;
begin
  if not public.is_platform_admin() then
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
      -- Lo vencido HOY (payable, con su desglose). Misma regla que
      -- `overdue_usd` de `admin_collections`; con un local, lo de ese local.
      coalesce(d.overdue_usd, 0)::numeric as overdue_usd,
      coalesce(d.overdue_financed_usd, 0)::numeric as overdue_financed_usd,
      coalesce(d.overdue_usd - d.overdue_financed_usd, 0)::numeric as overdue_fee_usd,
      coalesce(d.days_overdue, 0)::integer as days_overdue,
      lp.last_payment
    from public.collection_contacts c
    join public.profiles p on p.id = c.user_id
    left join public.platform_admins pa on pa.user_id = c.actor
    left join lateral (
      select sum(i.amount_usd) as overdue_usd,
             sum(i.financed_usd) as overdue_financed_usd,
             max(v_today - i.due_date) as days_overdue
      from public.installments i
      join public.charges ch on ch.id = i.charge_id
      where i.user_id = c.user_id
        and i.status = 'pending'
        and not i.is_test
        and i.due_date < v_today
        and (p_merchant_id is null or ch.merchant_id = p_merchant_id)
    ) d on true
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
$$;

comment on function public.admin_collection_promises(date, date, uuid) is
  'Las promesas de pago con fecha desde p_from (por defecto hace 30 días) hasta p_to, con su estado (helios_promise_status), si se renegociaron y lo vencido hoy de la persona (PAYABLE con desglose, como en la cola). Con p_merchant_id, las promesas de personas con alguna cuota en ese local y lo vencido de ese local.';

revoke all on function public.admin_collection_promises(date, date, uuid) from public, anon;
grant execute on function public.admin_collection_promises(date, date, uuid) to authenticated, service_role;
