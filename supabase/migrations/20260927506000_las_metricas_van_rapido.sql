-- Las métricas van rápido
--
-- Todas las pestañas de Métricas pasan por metricas.cuotas_al, y con los
-- datos de la semilla (unas 1.000 cuotas) «Semana a semana» de 26 semanas
-- tardaba 1,4 s. Dos causas, que vieron LOCALES, AVISOS y SEMANA:
--
-- 1. La CTE «ref» se inlineaba, y metricas.hoy() y
--    helios_on_time_grace_days() (que lee business_parameters) se evaluaban
--    fila a fila. Ahora es «materialized»: una vez por llamada.
-- 2. public.helios_business_date lleva SET search_path, y Postgres no inlinea
--    una función con SET: una llamada por fila, dos veces por cuota. Aquí se
--    usa metricas.dia_operativo, la MISMA expresión sin el SET. No se toca
--    helios_business_date: la usa todo el producto.
--
-- Mismas columnas, mismo resultado (lo comprueba
-- supabase/tests/metricas_coherencia_rapidez.sql). Idempotente.

create or replace function metricas.dia_operativo(p_ts timestamptz)
returns date
language sql
immutable
parallel safe
as $$
  select (p_ts at time zone 'America/Caracas' - interval '10 hours')::date;
$$;

comment on function metricas.dia_operativo(timestamptz) is
  'El día operativo de un instante, de 10:00 a 10:00 de Caracas. Es EXACTAMENTE public.helios_business_date sin el SET search_path, para que Postgres la pueda inlinear dentro de una consulta. Si cambia la regla del día operativo, cambian las dos.';

revoke all on function metricas.dia_operativo(timestamptz) from public, anon, authenticated;

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
      -- EL día del pago: el único sitio que lo decide.
      metricas.dia_operativo(i.paid_at)                                as dia_pago,
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
