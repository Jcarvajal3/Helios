-- El volumen de las noches, de la ficha del local y del directorio de locales
-- sumaba charges.amount_usd, que lleva dentro el servicio de Ronda y su IVA.
-- Los tres campos se llaman «financed» y los pinta el panel como consumo: es
-- un total con el fee sumado, justo lo que la regla prohíbe. Se arregla el
-- propio campo (el nombre ya decía lo que tenía que ser), con base_usd.
--
-- coalesce(base_usd, amount_usd): los cobros anteriores al desglose
-- (20260827100000) no tenían fee y su amount_usd era la base; el relleno de
-- esa migración solo tocó los locales con condiciones. En dev no queda
-- ninguno sin base, pero la columna admite nulos.
--
-- De paso, el cobro a tiempo de la ficha del local (portfolio.on_time_pct)
-- contaba en el numerador las cuotas pagadas por adelantado que aún no vencen
-- y en el denominador solo las vencidas: en dev salía 225 %. Ahora las dos
-- partes salen de la misma población.
--
-- Nada cambia de forma: mismas columnas, mismos tipos y mismos permisos.

CREATE OR REPLACE FUNCTION public.admin_nights(p_days integer DEFAULT 14, p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(business_date date, merchant_id uuid, merchant_name text, charge_count integer, financed_usd numeric, avg_ticket_usd numeric, distinct_users integer, new_users integer, repeat_users integer, first_sale_at timestamp with time zone, last_sale_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today date := public.helios_business_date(now());
  v_days  integer := greatest(least(coalesce(p_days, 14), 180), 1);
  v_from  date;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := v_today - (v_days - 1);

  return query
  with noches as (
    select
      c.business_date as d,
      c.merchant_id   as mid,
      c.user_id       as uid,
      -- Consumo sin el servicio de Ronda. Los cobros anteriores al desglose
      -- no tienen base, y entonces su amount_usd ERA la base.
      coalesce(c.base_usd, c.amount_usd) as financed,
      c.confirmed_at,
      -- ¿Había consumido antes en ESTE local? Se mira contra toda su historia
      -- con el local, no contra la ventana: alguien que vino en julio y vuelve
      -- hoy no es clientela nueva.
      not exists (
        select 1 from public.charges c0
        where c0.merchant_id = c.merchant_id
          and c0.user_id = c.user_id
          and c0.status = 'confirmed'
          and c0.business_date < c.business_date
      ) as es_nuevo
    from public.charges c
    where c.status = 'confirmed'
      and not c.is_test
      and c.business_date between v_from and v_today
      and (p_merchant_id is null or c.merchant_id = p_merchant_id)
  )
  select
    n.d,
    n.mid,
    m.name,
    count(*)::integer,
    sum(n.financed)::numeric,
    round(sum(n.financed) / count(*), 2),
    count(distinct n.uid)::integer,
    count(distinct n.uid) filter (where n.es_nuevo)::integer,
    count(distinct n.uid) filter (where not n.es_nuevo)::integer,
    min(n.confirmed_at),
    max(n.confirmed_at)
  from noches n
  join public.merchants m on m.id = n.mid
  group by n.d, n.mid, m.name
  order by n.d desc, sum(n.financed) desc;
end;
$function$;

revoke all on function public.admin_nights(integer, uuid) from public, anon;
grant execute on function public.admin_nights(integer, uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.admin_merchant_stats(p_merchant_id uuid, p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today date := public.helios_business_date(now());
  v_days  integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_grace integer := public.helios_on_time_grace_days();
  v_from  date;
  v_terms public.merchant_settlement_terms%rowtype;
  v_out   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := v_today - (v_days - 1);

  select * into v_terms
  from public.merchant_settlement_terms where merchant_id = p_merchant_id;

  -- Volumen de la ventana.
  select jsonb_build_object(
    'window_days', v_days,
    'charge_count', count(*)::integer,
    -- Consumo sin el servicio de Ronda: amount_usd lo lleva dentro.
    'financed_usd', coalesce(sum(coalesce(c.base_usd, c.amount_usd)), 0),
    'distinct_users', count(distinct c.user_id)::integer,
    'avg_ticket_usd', case
      when count(*) > 0 then round(sum(coalesce(c.base_usd, c.amount_usd)) / count(*), 2) else 0 end
  )
  into v_out
  from public.charges c
  where c.merchant_id = p_merchant_id
    and c.status = 'confirmed'
    and not c.is_test
    and c.business_date between v_from and v_today;

  -- Cobro a tiempo, mora e impago de las cuotas que nacieron aquí. Sin
  -- ventana: la cartera de un local es toda su historia, y con treinta días
  -- casi nunca hay suficientes cuotas vencidas para decir nada.
  v_out := v_out || jsonb_build_object('portfolio', (
    select jsonb_build_object(
      'billed_usd', coalesce(sum(i.amount_usd), 0),
      'paid_usd', coalesce(sum(i.amount_usd) filter (where i.status = 'paid'), 0),
      'overdue_usd', coalesce(sum(i.amount_usd) filter (
        where i.status = 'pending' and i.written_off_at is null
          and i.due_date < v_today), 0),
      'written_off_usd', coalesce(sum(i.amount_usd) filter (
        where i.written_off_at is not null), 0),
      'arrears_pct', case
        when coalesce(sum(i.amount_usd), 0) > 0
        then round(100 * coalesce(sum(i.amount_usd) filter (
               where i.status = 'pending' and i.written_off_at is null
                 and i.due_date < v_today), 0) / sum(i.amount_usd), 2)
        else 0 end,
      'bad_debt_pct', case
        when coalesce(sum(i.amount_usd), 0) > 0
        then round(100 * coalesce(sum(i.amount_usd) filter (
               where i.written_off_at is not null), 0) / sum(i.amount_usd), 2)
        else 0 end,
      -- Null y no cero cuando no venció ninguna: un 0 % sin denominador es una
      -- alarma inventada.
      'on_time_pct', case
        when count(*) filter (where i.due_date <= v_today and i.written_off_at is null) > 0
        then round(100.0 * count(*) filter (
               where i.status = 'paid' and i.paid_at is not null
                 and public.helios_business_date(i.paid_at) <= i.due_date + v_grace
                 -- La misma población que el denominador: una cuota pagada
                 -- por adelantado que aún no vence no cuenta en ninguno.
                 and i.due_date <= v_today and i.written_off_at is null
             ) / count(*) filter (
               where i.due_date <= v_today and i.written_off_at is null), 1)
        else null end,
      'due_count', count(*) filter (
        where i.due_date <= v_today and i.written_off_at is null)::integer
    )
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.merchant_id = p_merchant_id and not i.is_test
  ));

  -- El punto de empate de ESTE local, con sus condiciones.
  v_out := v_out || jsonb_build_object('break_even', (
    select jsonb_build_object(
      'policy', coalesce(v_terms.policy::text, 'scheduled'),
      'fee_usd', coalesce(sum(coalesce(c.consumer_fee_usd, 0)), 0),
      'at_risk_usd', coalesce(sum(
        case
          -- Por cobranza al local no se le adelanta nada: lo único que se
          -- pierde en un impago es el fee que no se cobró.
          when v_terms.policy = 'on_collection' then 0
          else coalesce(c.merchant_net_usd, c.amount_usd)
        end
      ), 0),
      'break_even_pct', (
        select case
          when coalesce(sum(
            coalesce(c2.consumer_fee_usd, 0) +
            case when v_terms.policy = 'on_collection' then 0
                 else coalesce(c2.merchant_net_usd, c2.amount_usd) end
          ), 0) > 0
          then round(100 * sum(coalesce(c2.consumer_fee_usd, 0)) / sum(
            coalesce(c2.consumer_fee_usd, 0) +
            case when v_terms.policy = 'on_collection' then 0
                 else coalesce(c2.merchant_net_usd, c2.amount_usd) end
          ), 2)
          else null end
        from public.charges c2
        where c2.merchant_id = p_merchant_id
          and c2.status = 'confirmed' and not c2.is_test
      )
    )
    from public.charges c
    where c.merchant_id = p_merchant_id
      and c.status = 'confirmed' and not c.is_test
  ));

  return v_out;
end;
$function$;

revoke all on function public.admin_merchant_stats(uuid, integer) from public, anon;
grant execute on function public.admin_merchant_stats(uuid, integer) to authenticated;

-- El directorio de locales. `create or replace view` conserva los permisos
-- pero SUSTITUYE las opciones: sin el `with`, la vista perdería
-- security_invoker y leería charges saltándose la RLS de quien pregunta.
create or replace view public.merchant_directory
with (security_invoker = true)
as
select
  m.id,
  m.name,
  m.legal_name,
  m.tax_id,
  m.status,
  m.created_at,
  (select count(*) from public.merchant_users mu
     where mu.merchant_id = m.id and mu.is_active) as staff_count,
  (select count(*) from public.charges c
     where c.merchant_id = m.id and c.status = 'confirmed') as sales_count,
  m.category,
  m.city,
  m.handle,
  m.logo_url,
  m.social_url,
  m.is_test,
  -- Los últimos 30 días operativos. Un local que vendió mucho en agosto y nada
  -- desde entonces no puede leerse igual que uno que está funcionando.
  (select count(*) from public.charges c
     where c.merchant_id = m.id and c.status = 'confirmed' and not c.is_test
       and c.business_date > public.helios_business_date(now()) - 30) as sales_30d,
  -- Consumo, sin el servicio de Ronda.
  (select coalesce(sum(coalesce(c.base_usd, c.amount_usd)), 0) from public.charges c
     where c.merchant_id = m.id and c.status = 'confirmed' and not c.is_test
       and c.business_date > public.helios_business_date(now()) - 30) as financed_30d
from public.merchants m;

grant select on public.merchant_directory to authenticated;
