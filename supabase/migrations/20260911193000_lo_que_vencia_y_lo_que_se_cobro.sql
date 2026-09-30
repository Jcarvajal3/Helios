-- ============================================================================
-- Ronda — Lo que vencía cada día, y lo que se cobró
--
-- El gráfico del panel enseña **financiado vs. cobrado**: lo que se vendió cada
-- noche contra lo que entró ese mismo día. Con cuotas a 7 y 14 días esas dos
-- series no tienen nada que ver entre sí — lo que se vende un viernes se cobra
-- el viernes siguiente y el otro. En cualquier ventana corta la curva de
-- cobrado va muy por debajo de la de financiado, y eso no significa nada: es
-- aritmética del plazo, no un problema de cobro.
--
-- La curva que sí mide el cobro es **vencía vs. cobrado**: de lo que tocaba
-- cobrar ese día, cuánto entró. Las dos series hablan del mismo dinero y del
-- mismo día, así que la distancia entre ellas es exactamente lo que no se
-- cobró.
--
-- ---------------------------------------------------------------------------
-- Dos fechas que no son la misma
-- ---------------------------------------------------------------------------
-- «Vencía» va por `due_date`, el día operativo en que tocaba pagar. «Cobrado»
-- va por el día operativo en que se concilió el pago, que puede ser otro — y
-- normalmente lo es, porque se paga tarde o porque el reporte tarda en
-- aprobarse.
--
-- Por eso las dos series no suman lo mismo en una ventana: lo cobrado de hoy
-- puede corresponder a una cuota de la semana pasada. Es correcto que sea así,
-- y es justo lo que se quiere ver.
-- ============================================================================

create or replace function public.admin_due_vs_collected(p_days integer default 30)
returns table (
  business_date date,
  due_usd       numeric,
  due_count     integer,
  collected_usd numeric,
  collected_count integer
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today date := public.helios_business_date(now());
  v_days  integer := greatest(least(coalesce(p_days, 30), 365), 1);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  with dias as (
    select generate_series(v_today - (v_days - 1), v_today, interval '1 day')::date as d
  )
  select
    dias.d,
    coalesce(v.usd, 0)::numeric,
    coalesce(v.n, 0)::integer,
    coalesce(c.usd, 0)::numeric,
    coalesce(c.n, 0)::integer
  from dias
  left join (
    -- Lo que tocaba cobrar ese día. Lo castigado queda fuera: dejó de
    -- esperarse, y dejarlo dentro haría que la curva de vencido subiera para
    -- siempre por deuda que ya se dio por perdida.
    select i.due_date as d, sum(i.amount_usd) as usd, count(*)::integer as n
    from public.installments i
    where not i.is_test and i.written_off_at is null
    group by 1
  ) v on v.d = dias.d
  left join (
    -- Lo que entró ese día, por el día operativo del cobro.
    select public.helios_business_date(i.paid_at) as d,
           sum(i.amount_usd) as usd,
           count(*)::integer as n
    from public.installments i
    where not i.is_test and i.status = 'paid' and i.paid_at is not null
    group by 1
  ) c on c.d = dias.d
  order by dias.d;
end;
$$;

comment on function public.admin_due_vs_collected(integer) is
  'Por dia operativo: lo que vencia y lo que se cobro. Reemplaza a financiado-vs-cobrado, que con cuotas a 7 y 14 dias compara dos series que no hablan del mismo dinero.';

revoke all on function public.admin_due_vs_collected(integer) from public, anon;
grant execute on function public.admin_due_vs_collected(integer) to authenticated;
