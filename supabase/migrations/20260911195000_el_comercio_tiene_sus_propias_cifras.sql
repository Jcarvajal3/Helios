-- ============================================================================
-- Ronda — Cada local, con sus propias cifras
--
-- La ficha de un comercio dice quién es, con qué condiciones trabaja y cuánto
-- se le debe. No dice **cómo le va**, y el local es la unidad de riesgo: si un
-- bar trae clientela que no paga, se ve aquí antes que en ninguna cifra global.
--
-- Lo que faltaba, y por qué cada cosa:
--
--   VENTAS DE 30 DÍAS      la lista enseñaba el total histórico. Un local que
--                          vendió mucho en agosto y nada desde entonces se lee
--                          igual que uno que está funcionando.
--
--   COBRO A TIEMPO         de las cuotas que nacieron aquí, cuántas se pagaron
--                          dentro de plazo. Es el indicador que avisa primero,
--                          también por local.
--
--   MORA E IMPAGO          lo vencido y lo perdido, imputado al comercio que
--                          originó el consumo.
--
--   PUNTO DE EMPATE        con qué impago deja de ganarse dinero **con este
--                          local**. Depende de su comisión y de su modalidad:
--                          con liquidación por cobranza la pérdida es solo la
--                          comisión no cobrada, así que el umbral es otro y
--                          mucho más alto.
--
-- ---------------------------------------------------------------------------
-- El punto de empate, por local
-- ---------------------------------------------------------------------------
-- Ronda gana el fee y, cuando alguien no paga, pierde lo que ya le transfirió
-- al comercio más el fee que no cobró. Con una tasa de impago `d`:
--
--     gana  fee × (1 − d)      pierde  perdida × d
--     empatan en   d = fee / (fee + perdida)
--
-- Con liquidación **por fecha**, `perdida` es el neto que se le pagó al local:
-- salió de la caja pase lo que pase. Con liquidación **por cobranza** no se le
-- paga hasta que el usuario paga, así que lo único que se pierde es el fee — y
-- el umbral se dispara. Es exactamente la diferencia que el local está
-- comprando cuando negocia su modalidad.
-- ============================================================================

create or replace function public.admin_merchant_stats(
  p_merchant_id uuid,
  p_days        integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
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
    'financed_usd', coalesce(sum(c.amount_usd), 0),
    'distinct_users', count(distinct c.user_id)::integer,
    'avg_ticket_usd', case
      when count(*) > 0 then round(sum(c.amount_usd) / count(*), 2) else 0 end
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
$$;

comment on function public.admin_merchant_stats(uuid, integer) is
  'Las cifras de un local: volumen de la ventana, cartera entera —cobro a tiempo, mora e impago— y su punto de empate, que depende de su comision y de su modalidad. Por cobranza el umbral es mucho mas alto: no se adelanta nada, asi que solo se pierde el fee.';

revoke all on function public.admin_merchant_stats(uuid, integer) from public, anon;
grant execute on function public.admin_merchant_stats(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Y la lista, con las ventas de la ventana y no con el total histórico
-- ---------------------------------------------------------------------------
-- La vista se recrea entera: `create or replace view` no sabe añadir columnas
-- en medio. Se conserva `sales_count` —el total de siempre— y se añaden las
-- dos de la ventana, que son las que dicen si el local está funcionando.

drop view if exists public.merchant_directory;

create view public.merchant_directory
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
  (select coalesce(sum(c.amount_usd), 0) from public.charges c
     where c.merchant_id = m.id and c.status = 'confirmed' and not c.is_test
       and c.business_date > public.helios_business_date(now()) - 30) as financed_30d
from public.merchants m;

grant select on public.merchant_directory to authenticated;
