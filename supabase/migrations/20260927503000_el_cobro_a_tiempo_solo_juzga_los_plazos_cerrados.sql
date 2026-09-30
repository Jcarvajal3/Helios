-- ============================================================================
-- Ronda — El cobro a tiempo solo juzga los plazos que ya cerraron
--
-- `admin_on_time_collection` metía en el denominador todas las cuotas que
-- vencían en la ventana, HOY incluido. Una cuota que vence hoy, o ayer, y que
-- todavía está dentro de sus días de gracia contaba como «no pagada a
-- tiempo»: el día en que vencían las primeras cuotas de producción el panel
-- decía que menos del 60 % de la cuota 1 se había pagado a tiempo cuando
-- todavía no había vencido ninguna.
--
-- Ahora el cobro a tiempo es la definición de `metricas.cuotas`:
--     cuotas con estado_hoy = 'a_tiempo'  ÷  cuotas con plazo_cerrado
-- donde plazo_cerrado = vencimiento + gracia < hoy (el veredicto ya no puede
-- cambiar). Lo dado por perdido cuenta en el denominador: es una cuota que no
-- se pagó a tiempo. La ventana son los `p_days` últimos días de vencimiento
-- con veredicto, así que acaba `gracia + 1` días antes de hoy; se devuelven
-- `from` y `to` para que la pantalla pinte lo que se usó.
--
-- Mismas claves de siempre; nuevas: from, to, y por cuota late_count,
-- unpaid_count y el desglose financed + fee de lo vencido en la ventana.
-- ============================================================================

create or replace function public.admin_on_time_collection(p_days integer default 30)
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
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- El último vencimiento cuyo plazo ya cerró.
  v_to   := v_today - v_grace - 1;
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
        -- Null y no cero cuando no hay ninguna: la pantalla tiene que poder
        -- decir «todavía no hay con qué medirlo».
        'rate_pct', case
          when count(*) > 0
          then round(100.0 * count(*) filter (where q.estado_hoy = 'a_tiempo') / count(*), 1)
          else null end
      ) as value
    from metricas.cuotas q
    where q.plazo_cerrado
      and q.due_date between v_from and v_to
    group by q.sequence
  ) x;

  return jsonb_build_object(
    'business_date', v_today,
    'window_days',   v_days,
    'grace_days',    v_grace,
    'from',          v_from,
    'to',            v_to,
    'installments',  v_rows
  );
end;
$$;

comment on function public.admin_on_time_collection(integer) is
  'Cobro a tiempo por número de cuota: de las cuotas que vencieron en los p_days días anteriores al último plazo cerrado (vencimiento + gracia < hoy), cuántas se pagaron a tiempo. Lee de metricas.cuotas.';

revoke all on function public.admin_on_time_collection(integer) from public, anon;
grant execute on function public.admin_on_time_collection(integer) to authenticated;
