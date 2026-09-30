-- ============================================================================
-- Ronda — Lo que rinde la cobranza
--
-- Hay una sola persona en cobranza. Su tiempo es lo más caro que hay en esa
-- área, y hasta hoy nadie podía decirle qué parte de ese tiempo trae dinero:
-- ¿contestan más las llamadas o los WhatsApp? ¿a qué hora? ¿cuánto de lo que
-- se debía al empezar el mes volvió?
--
--   admin_contact_effectiveness  gestiones por canal, resultado y hora, y
--                                cuántas tuvieron un pago en las 72 h siguientes
--   admin_collection_recovered   lo cobrado en cuotas que ya estaban vencidas,
--                                frente a lo vencido al empezar el rango
--
-- ── Los ejes de fecha ────────────────────────────────────────────────────────
-- Una gestión es una actividad de la gente: su rango va por el día de Caracas
-- (`helios_caracas_date`) y su hora es la de Caracas. Lo recuperado es dinero:
-- va por día operativo (`helios_business_date`), igual que el resto del libro.
--
-- ── Lo que una cuota pagó ────────────────────────────────────────────────────
-- La cuota no guarda un «monto pagado» aparte, y no le hace falta: una cuota
-- se paga entera o no se paga (no hay pagos parciales de cuota), y
-- `reconcile_payment` no aprueba nada si el importe cotizado difiere del de la
-- cuota. Así que lo pagado es `amount_usd`: PAYABLE, con el fee dentro. Los
-- cargos por atraso cobrados van en su propia línea, nunca sumados a eso.
--
-- Las cuentas de prueba no cuentan en ninguna cifra.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La efectividad de las gestiones
-- ---------------------------------------------------------------------------
-- «Tuvo un pago» = un pago reportado no rechazado (ni `duplicate`) o una cuota
-- pagada, en las 72 h siguientes a la gestión. No es causalidad: es la señal
-- que hay. La tasa se calcula solo sobre las gestiones cuya ventana de 72 h ya
-- terminó; contar las de ayer como «sin pago» hundiría siempre la última hora
-- trabajada.
create or replace function public.admin_contact_effectiveness(
  p_from date default null,
  p_to   date default null
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

  with c0 as (
    select c.id, c.user_id, c.contacted_at, c.channel, c.outcome
    from public.collection_contacts c
    join public.profiles p on p.id = c.user_id
    where c.contacted_at >= v_from_ts
      and c.contacted_at <  v_to_ts
      and not p.is_test
  ),
  -- Los pagos que pueden caer en la ventana de alguna gestión, leídos una vez
  -- y cruzados por persona. Con un `exists` por gestión, el planificador
  -- prefería recorrer todos los pagos de esos tres días para cada gestión.
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
  -- Las tres vistas son la misma cuenta sobre claves distintas. Se listan
  -- todas las claves, también las que no tuvieron gestiones, para que el panel
  -- no tenga que rellenar huecos (y un canal sin uso se vea como tal).
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

revoke all on function public.admin_contact_effectiveness(date, date) from public, anon;
grant execute on function public.admin_contact_effectiveness(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Lo recuperado
-- ---------------------------------------------------------------------------
-- «Recuperado» = cuota pagada en el rango que ya estaba vencida al pagarse
-- (vencimiento anterior al día operativo del pago: el mismo corte con el que
-- el motor la considera atrasada). Lo pagado el mismo día del vencimiento o
-- antes no es cobranza: es la cuota llegando a su hora.
--
-- La comparación honesta no es «recuperado ÷ vencido al empezar»: lo
-- recuperado incluye cuotas que vencieron DENTRO del rango. Por eso va aparte
-- `recovered_from_start`, lo que de verdad salió de la bolsa del primer día, y
-- la tasa se calcula con eso.
create or replace function public.admin_collection_recovered(
  p_from date default null,
  p_to   date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_to        date := coalesce(p_to, public.helios_business_date(now()));
  v_from      date := coalesce(p_from, coalesce(p_to, public.helios_business_date(now())) - 29);
  v_from_ts   timestamptz;
  v_to_ts     timestamptz;
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

  -- El rango en instantes: del comienzo del día operativo `v_from` al final
  -- del día operativo `v_to` (10:00 de Caracas del día siguiente).
  v_from_ts := (v_from::timestamp + interval '10 hours') at time zone 'America/Caracas';
  v_to_ts   := ((v_to + 1)::timestamp + interval '10 hours') at time zone 'America/Caracas';

  with rec as (
    select
      i.user_id,
      i.amount_usd,
      (i.written_off_at is not null and i.written_off_at < i.paid_at) as was_written_off,
      -- El día operativo del pago, con la fórmula de `helios_business_date`
      -- escrita en línea: la función lleva `search_path` fijo, Postgres no la
      -- puede escribir en línea, y llamarla por cada cuota era el 90 % del
      -- tiempo de un rango largo.
      public.helios_tramo_de_atraso(
        ((i.paid_at at time zone 'America/Caracas') - interval '10 hours')::date - i.due_date,
        v_grace, v_interval, v_demotion, v_expulsion) as tramo,
      (i.due_date < v_from and i.created_at < v_from_ts) as from_start
    from public.installments i
    where i.status = 'paid'
      and not i.is_test
      and i.paid_at >= v_from_ts
      and i.paid_at <  v_to_ts
      -- `due_date < helios_business_date(paid_at)`, escrito como instante: pagada
      -- después de las 10:00 del día siguiente al vencimiento. Llamar a la
      -- función en el filtro, por cada cuota del rango, quintuplicaba el coste.
      and i.paid_at >= ((i.due_date + 1)::timestamp + interval '10 hours')
                       at time zone 'America/Caracas'
  ),
  -- Lo vencido y sin pagar al comenzar el día operativo `v_from`.
  inicio as (
    select
      i.user_id,
      i.amount_usd,
      (i.written_off_at is not null and i.written_off_at < v_from_ts) as was_written_off
    from public.installments i
    where not i.is_test
      and i.due_date < v_from
      and i.created_at < v_from_ts
      and (i.status = 'pending' or i.paid_at >= v_from_ts)
  ),
  fees as (
    select coalesce(sum(f.amount_usd), 0) as usd, count(*)::integer as n
    from public.late_fees f
    join public.profiles p on p.id = f.user_id
    where f.status = 'paid'
      and f.paid_at >= v_from_ts
      and f.paid_at <  v_to_ts
      and not p.is_test
  ),
  tramos(tramo, ord) as (
    values ('t1', 1), ('t2', 2), ('t3', 3), ('t4', 4), ('t5', 5)
  )
  select jsonb_build_object(
    'from', v_from,
    'to', v_to,
    -- PAYABLE: cuotas cobradas que ya estaban vencidas.
    'recovered', (
      select jsonb_build_object(
        'usd', coalesce(sum(amount_usd), 0),
        'installments', count(*)::integer,
        'people', count(distinct user_id)::integer,
        'written_off_usd', coalesce(sum(amount_usd) filter (where was_written_off), 0)
      ) from rec
    ),
    -- Los cargos por atraso cobrados en el rango. Línea aparte: no se suman.
    'late_fees', (select jsonb_build_object('usd', usd, 'count', n) from fees),
    -- Por los días de atraso que tenía la cuota el día que se pagó.
    'by_tramo', (
      select jsonb_agg(jsonb_build_object(
               'tramo', t.tramo,
               'usd', coalesce(x.usd, 0),
               'installments', coalesce(x.n, 0),
               'people', coalesce(x.people, 0)
             ) order by t.ord)
      from tramos t
      left join (
        select tramo, sum(amount_usd) as usd, count(*)::integer as n,
               count(distinct user_id)::integer as people
        from rec group by tramo
      ) x on x.tramo = t.tramo
    ),
    -- PAYABLE: la bolsa vencida al comenzar el rango.
    'overdue_at_start', (
      select jsonb_build_object(
        'usd', coalesce(sum(amount_usd), 0),
        'installments', count(*)::integer,
        'people', count(distinct user_id)::integer,
        'written_off_usd', coalesce(sum(amount_usd) filter (where was_written_off), 0)
      ) from inicio
    ),
    -- De esa bolsa, lo que se cobró dentro del rango.
    'recovered_from_start', (
      select jsonb_build_object(
        'usd', coalesce(sum(amount_usd), 0),
        'installments', count(*)::integer,
        'people', count(distinct user_id)::integer
      ) from rec where from_start
    ),
    'recovery_pct', (
      select case when s.usd > 0 then round(100.0 * r.usd / s.usd, 1) end
      from (select coalesce(sum(amount_usd), 0) as usd from inicio) s,
           (select coalesce(sum(amount_usd), 0) as usd from rec where from_start) r
    ),
    'tramos', public.helios_tramos_de_atraso()
  )
  into v_result;

  return v_result;
end;
$$;

revoke all on function public.admin_collection_recovered(date, date) from public, anon;
grant execute on function public.admin_collection_recovered(date, date) to authenticated;
