-- «A tiempo» se juzga por el día del REPORTE
--
-- Decisión de Javier (2026-09-27): una cuota se paga a tiempo si la persona
-- REPORTÓ el pago dentro de plazo (vencimiento + gracia), aunque el equipo lo
-- apruebe después. Hasta hoy se juzgaba por la aprobación (paid_at).
--
-- Se cambia en UN solo sitio, metricas.cuotas_al (dia_pago), y lo heredan
-- todas las cifras que leen de metricas: cobro a tiempo, cuota 1 y 2 a tiempo,
-- estados de las cohortes, atraso al pagar, curvas, perfiles de deudor…
--
-- El estado «pagada» a un corte pasado sigue siendo por la aprobación: el
-- dinero no está confirmado hasta que se aprueba. Lo que cambia es el
-- veredicto de a tiempo / tarde y los días de atraso.
--
-- Y admin_contact_effectiveness ya no cuenta la aprobación de una cuota que
-- tuvo reporte (el reporte ya cuenta por su hora). La caja, en cambio, sigue
-- contando cada cobro el día que se aprueba (metricas.caja_movimientos).
--
-- Va después de 551000 y 572000 porque redefine funciones de ellas.

create or replace function metricas.cuotas_al(p_dia date)
returns table (
  installment_id     uuid,
  charge_id          uuid,
  user_id            uuid,
  sequence           smallint,
  due_date           date,
  payable_usd        numeric,
  financed_usd       numeric,
  fee_usd            numeric,
  status             text,
  paid_at            timestamptz,
  pagada_dia         date,
  reportada_en       timestamptz,
  written_off_at     timestamptz,
  business_date      date,
  semana             date,
  merchant_id        uuid,
  group_id           uuid,
  estado_hoy         text,
  dias_atraso        integer,
  plazo_cerrado      boolean,
  reportada_dia      date,
  report_id          uuid,
  branch_id          uuid,
  es_grupo           boolean,
  dia_de_referencia  date
)
language sql
stable
as $$
  with ref as materialized (
    select
      -- El día que hace de «hoy» para decidir si algo está vencido.
      case when p_dia < h.hoy then p_dia + 1 else h.hoy end              as dia,
      -- Hasta qué instante cuenta un pago o una pérdida.
      case when p_dia < h.hoy then public.helios_business_day_end(p_dia)
           else now() end                                                as corte,
      -- Hasta qué día operativo existían los consumos.
      least(p_dia, h.hoy)                                                as hasta,
      public.helios_on_time_grace_days()                                  as gracia
    from (select metricas.hoy() as hoy) h
  ),
  q as (
    select
      i.id, i.charge_id, i.user_id, i.sequence, i.due_date,
      i.amount_usd, i.financed_usd, i.paid_at, i.written_off_at,
      i.paid_by_report_id,
      c.business_date, c.merchant_id, c.branch_id, c.group_id,
      r.dia, r.gracia,
      (i.status = 'paid' and (i.paid_at is null or i.paid_at <= r.corte))  as pagada,
      (i.written_off_at is not null and i.written_off_at <= r.corte)       as perdida,
      -- EL día del pago: el único sitio que lo decide. Es el día en que la
      -- persona REPORTÓ el pago (decisión de Javier, 27-09): lo que tarde el
      -- equipo en aprobarlo no la hace llegar tarde. Sin reporte (un abono
      -- asignado a mano, por ejemplo), el de la aprobación.
      coalesce(metricas.dia_operativo(pr.created_at),
               metricas.dia_operativo(i.paid_at))                      as dia_pago,
      pr.created_at                                                        as reportada_en
    from public.installments i
    join public.charges c on c.id = i.charge_id
    left join public.payment_reports pr on pr.id = i.paid_by_report_id
    cross join ref r
    where c.status = 'confirmed'
      and not c.is_test
      and not i.is_test
      and c.business_date is not null
      and c.business_date <= r.hasta
  )
  select
    q.id,
    q.charge_id,
    q.user_id,
    q.sequence,
    q.due_date,
    q.amount_usd::numeric,
    q.financed_usd::numeric,
    (q.amount_usd - q.financed_usd)::numeric,
    case when q.pagada then 'paid' else 'pending' end,
    case when q.pagada then q.paid_at end,
    case when q.pagada then q.dia_pago end,
    case when q.pagada then q.reportada_en end,
    case when q.perdida then q.written_off_at end,
    q.business_date,
    metricas.lunes(q.business_date),
    q.merchant_id,
    q.group_id,
    case
      when q.pagada and metricas.a_tiempo(q.dia_pago, q.due_date, q.gracia)
                              then 'a_tiempo'
      when q.pagada           then 'tarde'
      when q.perdida          then 'perdida'
      when q.due_date < q.dia then 'vencida'
      else                         'por_vencer'
    end,
    case
      when q.pagada           then greatest(q.dia_pago - q.due_date, 0)
      when q.due_date < q.dia then q.dia - q.due_date
      else 0
    end,
    q.due_date + q.gracia < q.dia,
    case when q.pagada then metricas.dia_operativo(q.reportada_en) end,
    case when q.pagada then q.paid_by_report_id end,
    q.branch_id,
    q.group_id is not null,
    q.dia
  from q;
$$;

comment on column metricas.cuotas.pagada_dia is 'Día operativo en que la persona REPORTÓ el pago que saldó la cuota (payment_reports.created_at de paid_by_report_id); sin reporte, el de la aprobación (paid_at). Es el día con el que se juzga si llegó a tiempo (decisión de Javier del 2026-09-27).';

comment on column metricas.cuotas.paid_at is 'Cuándo se APROBÓ el pago (reconcile_payment pone now()). Decide si la cuota estaba pagada en un corte, no si llegó a tiempo: eso lo decide pagada_dia.';

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
$$;

-- La caja sigue contando cada cobro el día que se aprueba: es cuando entra el
-- dinero y cuando lo apunta el libro.
create or replace function metricas.caja_movimientos(
  p_desde       date,
  p_hasta       date,
  p_merchant_id uuid default null
)
returns table (
  cuotas_cobradas        integer,
  personas_que_pagaron   integer,
  cobrado_payable_usd    numeric,
  cobrado_financed_usd   numeric,
  cobrado_fee_usd        numeric,
  cobrado_servicio_usd   numeric,
  cargos_cobrados        integer,
  cargos_cobrados_usd    numeric,
  transferencias         integer,
  transferido_usd        numeric,
  consumos               integer,
  consumo_usd            numeric,
  servicio_ganado_usd    numeric,
  cargos_devengados_usd  numeric,
  libro_cobrado_usd      numeric,
  libro_transferido_usd  numeric,
  libro_otros_usd        numeric
)
language sql
stable
as $$
  with
  -- Las cuotas cuyo pago se aprobó en esos días, con la parte de servicio
  -- SIN IVA que llevaban dentro: la de su consumo, en proporción a su fee.
  cobradas as (
    select q.user_id, q.payable_usd, q.financed_usd, q.fee_usd,
           q.fee_usd * coalesce(k.servicio_usd / nullif(k.fee_usd, 0), 0) as servicio
    from metricas.cuotas q
    join metricas.consumos k on k.charge_id = q.charge_id
    where q.status = 'paid'
      -- El día de la APROBACIÓN, que es cuando el libro apunta el cobro.
      -- pagada_dia es ahora el del reporte (juzga «a tiempo»), no el de caja.
      and metricas.dia_operativo(q.paid_at) between p_desde and p_hasta
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ),
  cargos as (
    select c.amount_usd, c.status, c.business_date, c.pagado_dia
    from metricas.cargos_por_atraso c
    where p_merchant_id is null or c.merchant_id = p_merchant_id
  ),
  pagos as (
    select mp.amount_usd
    from public.merchant_payouts mp
    join public.merchants m on m.id = mp.merchant_id
    where not m.is_test
      and mp.business_date between p_desde and p_hasta
      and (p_merchant_id is null or mp.merchant_id = p_merchant_id)
  ),
  ventas as (
    select k.financed_usd, k.servicio_usd
    from metricas.consumos k
    where k.business_date between p_desde and p_hasta
      and (p_merchant_id is null or k.merchant_id = p_merchant_id)
  ),
  -- El libro de caja no sabe de locales: solo sin local.
  libro as (
    select l.tipo, l.debit, l.credit
    from metricas.libro_de_caja l
    where p_merchant_id is null
      and l.business_date between p_desde and p_hasta
  )
  select
    (select count(*) from cobradas)::integer,
    (select count(distinct user_id) from cobradas)::integer,
    (select coalesce(sum(payable_usd), 0) from cobradas),
    (select coalesce(sum(financed_usd), 0) from cobradas),
    (select coalesce(sum(fee_usd), 0) from cobradas),
    (select round(coalesce(sum(servicio), 0), 4) from cobradas),
    (select count(*) from cargos where status = 'paid' and pagado_dia between p_desde and p_hasta)::integer,
    (select coalesce(sum(amount_usd), 0) from cargos where status = 'paid' and pagado_dia between p_desde and p_hasta),
    (select count(*) from pagos)::integer,
    (select coalesce(sum(amount_usd), 0) from pagos),
    (select count(*) from ventas)::integer,
    (select coalesce(sum(financed_usd), 0) from ventas),
    (select coalesce(sum(servicio_usd), 0) from ventas),
    (select coalesce(sum(amount_usd), 0) from cargos where business_date between p_desde and p_hasta),
    case when p_merchant_id is null then
      (select coalesce(sum(debit), 0) from libro where tipo = 'installment_payment') end,
    case when p_merchant_id is null then
      (select coalesce(sum(credit), 0) from libro where tipo = 'merchant_settlement') end,
    case when p_merchant_id is null then
      (select coalesce(sum(debit - credit), 0) from libro
       where tipo not in ('installment_payment', 'merchant_settlement')) end;
$$;
