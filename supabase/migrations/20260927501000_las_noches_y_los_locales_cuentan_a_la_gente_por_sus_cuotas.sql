-- ============================================================================
-- Ronda — Las noches y los locales cuentan a la gente por sus cuotas
--
-- «Gente» en Directorio › Consumos › por local y noche decía 22 el 19-09 en La
-- Quinta Bar, donde 32 personas tienen cuota: contaba `charges.user_id`, que es
-- quien abrió la cuenta, y en un consumo de grupo pagan todos los del grupo.
-- La ficha del local y la tabla de locales de Riesgo hacían lo mismo.
--
-- Las tres funciones leen ahora del esquema `metricas` (20260927500000) y no
-- escriben su propia cuenta. Firmas y claves, las de siempre; lo que cambia es
-- el valor de las que mentían:
--
--   admin_nights            distinct_users = personas con cuota esa noche en
--                           ese local; new_users = las que estrenaban ESE local
--                           (su primera cuota allí es de esa noche);
--                           repeat_users = el resto.
--   admin_merchant_stats    distinct_users = personas con cuota. En la cartera:
--                           arrears_pct es LA mora (vencido ÷ vencido + por
--                           vencer, como la de toda la cartera y con los mismos
--                           umbrales), no vencido ÷ todo lo facturado;
--                           written_off_usd es lo perdido y sin pagar;
--                           bad_debt_pct es el impago en consumo; on_time_pct y
--                           due_count miran solo las cuotas cuyo plazo ya cerró
--                           (vencimiento + gracia < hoy): una cuota que vence
--                           hoy no puede contar como «no pagada a tiempo».
--                           Nuevas: open_usd (lo vivo), el desglose financed +
--                           fee de lo vencido y de lo vivo, on_time_count y
--                           overdue_count.
--   admin_merchant_risk     las columnas viejas pasan a valer lo que dicen:
--                           financed_usd = consumo sin servicio, distinct_users
--                           = personas, overdue_usd = vencido cobrable,
--                           arrears_pct y overdue_debt_pct = LA mora,
--                           volume_share_pct = su parte del consumo.
--                           repeat_ratio sigue siendo consumos ÷ quien abrió la
--                           cuenta (la señal de fraude de local), y por eso se
--                           añade account_openers al final.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las noches
-- ---------------------------------------------------------------------------

create or replace function public.admin_nights(p_days integer default 14, p_merchant_id uuid default null)
returns table (
  business_date  date,
  merchant_id    uuid,
  merchant_name  text,
  charge_count   integer,
  financed_usd   numeric,
  avg_ticket_usd numeric,
  distinct_users integer,
  new_users      integer,
  repeat_users   integer,
  first_sale_at  timestamptz,
  last_sale_at   timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date    := metricas.hoy();
  v_days  integer := greatest(least(coalesce(p_days, 14), 180), 1);
  v_from  date;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := v_today - (v_days - 1);

  return query
  with
  por_noche as (
    select k.business_date as d, k.merchant_id as mid,
           count(*)::integer    as consumos,
           sum(k.financed_usd)  as consumo,
           min(k.confirmed_at)  as primera,
           max(k.confirmed_at)  as ultima
    from metricas.consumos k
    where k.business_date between v_from and v_today
      and (p_merchant_id is null or k.merchant_id = p_merchant_id)
    group by k.business_date, k.merchant_id
  ),
  -- La gente de cada noche: todos los que tienen cuota, no quien abrió.
  gente as (
    select distinct q.business_date as d, q.merchant_id as mid, q.user_id as uid
    from metricas.cuotas q
    where q.business_date between v_from and v_today
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ),
  -- Nueva = su primera cuota en ESE local es de esa noche. Se mira toda su
  -- historia con el local, no la ventana: quien vino en julio y vuelve hoy
  -- no es clientela nueva.
  por_gente as (
    select g.d, g.mid,
           count(*)::integer                                   as personas,
           (count(*) filter (where pl.primer_dia = g.d))::integer as nuevas
    from gente g
    join metricas.personas_por_local pl on pl.user_id = g.uid and pl.merchant_id = g.mid
    group by g.d, g.mid
  )
  select
    n.d,
    n.mid,
    m.name,
    n.consumos,
    n.consumo::numeric,
    round(n.consumo / n.consumos, 2),
    coalesce(pg.personas, 0),
    coalesce(pg.nuevas, 0),
    coalesce(pg.personas - pg.nuevas, 0),
    n.primera,
    n.ultima
  from por_noche n
  join public.merchants m on m.id = n.mid
  left join por_gente pg on pg.d = n.d and pg.mid = n.mid
  order by n.d desc, n.consumo desc;
end;
$$;

comment on function public.admin_nights(integer, uuid) is
  'Una fila por noche (día operativo) y local: consumos, consumo sin servicio, ticket medio, personas con cuota (distinct_users), las que estrenaban el local (new_users) y las que repetían (repeat_users). Lee de metricas.';

revoke all on function public.admin_nights(integer, uuid) from public, anon;
grant execute on function public.admin_nights(integer, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. La ficha del local
-- ---------------------------------------------------------------------------

create or replace function public.admin_merchant_stats(p_merchant_id uuid, p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date    := metricas.hoy();
  v_days  integer := greatest(least(coalesce(p_days, 30), 365), 1);
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

  -- Lo vendido en la ventana.
  select jsonb_build_object(
    'window_days',    v_days,
    'charge_count',   count(*)::integer,
    'financed_usd',   coalesce(sum(k.financed_usd), 0),
    -- Personas con cuota en sus consumos de la ventana, no quien abrió.
    'distinct_users', (
      select count(distinct q.user_id)::integer
      from metricas.cuotas q
      where q.merchant_id = p_merchant_id
        and q.business_date between v_from and v_today
    ),
    'avg_ticket_usd', case
      when count(*) > 0 then round(sum(k.financed_usd) / count(*), 2) else 0 end
  )
  into v_out
  from metricas.consumos k
  where k.merchant_id = p_merchant_id
    and k.business_date between v_from and v_today;

  -- Su cartera, de toda su historia: con treinta días casi nunca hay cuotas
  -- vencidas suficientes para decir nada.
  v_out := v_out || jsonb_build_object('portfolio', (
    select jsonb_build_object(
      'billed_usd',           coalesce(sum(q.payable_usd), 0),
      'paid_usd',             coalesce(sum(q.payable_usd) filter (where q.status = 'paid'), 0),
      'overdue_usd',          coalesce(sum(q.payable_usd) filter (where q.estado_hoy = 'vencida'), 0),
      'overdue_financed_usd', coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'vencida'), 0),
      'overdue_fee_usd',      coalesce(sum(q.fee_usd) filter (where q.estado_hoy = 'vencida'), 0),
      'open_usd',             coalesce(sum(q.payable_usd) filter (where q.estado_hoy in ('vencida', 'por_vencer')), 0),
      'open_financed_usd',    coalesce(sum(q.financed_usd) filter (where q.estado_hoy in ('vencida', 'por_vencer')), 0),
      'open_fee_usd',         coalesce(sum(q.fee_usd) filter (where q.estado_hoy in ('vencida', 'por_vencer')), 0),
      'written_off_usd',      coalesce(sum(q.payable_usd) filter (where q.estado_hoy = 'perdida'), 0),
      -- LA mora: la misma cuenta y los mismos umbrales que la de toda la
      -- cartera, restringida a los consumos de este local.
      'arrears_pct',          coalesce((select c.mora_pct from metricas.cartera_al(v_today, p_merchant_id) c), 0),
      -- El impago, en consumo sobre consumo.
      'bad_debt_pct', case
        when coalesce(sum(q.financed_usd), 0) > 0
        then round(100 * coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'perdida'), 0)
                       / sum(q.financed_usd), 2)
        else 0 end,
      -- Cobro a tiempo sobre las cuotas cuyo plazo ya cerró. Null y no cero
      -- cuando no hay ninguna: un 0 % sin denominador es una alarma inventada.
      'on_time_pct', case
        when count(*) filter (where q.plazo_cerrado) > 0
        then round(100.0 * count(*) filter (where q.plazo_cerrado and q.estado_hoy = 'a_tiempo')
                         / count(*) filter (where q.plazo_cerrado), 1)
        else null end,
      'due_count',            (count(*) filter (where q.plazo_cerrado))::integer,
      'on_time_count',        (count(*) filter (where q.plazo_cerrado and q.estado_hoy = 'a_tiempo'))::integer,
      'overdue_count',        (count(*) filter (where q.estado_hoy = 'vencida'))::integer
    )
    from metricas.cuotas q
    where q.merchant_id = p_merchant_id
  ));

  -- El punto de empate de ESTE local, con sus condiciones.
  v_out := v_out || jsonb_build_object('break_even', (
    select jsonb_build_object(
      'policy', coalesce(v_terms.policy::text, 'scheduled'),
      'fee_usd', coalesce(sum(k.servicio_usd), 0),
      'at_risk_usd', coalesce(sum(
        case
          -- Por cobranza al local no se le adelanta nada: lo único que se
          -- pierde en un impago es el servicio que no se cobró.
          when v_terms.policy = 'on_collection' then 0
          else k.neto_local_usd
        end
      ), 0),
      'break_even_pct', case
        when coalesce(sum(
          k.servicio_usd +
          case when v_terms.policy = 'on_collection' then 0 else k.neto_local_usd end
        ), 0) > 0
        then round(100 * sum(k.servicio_usd) / sum(
          k.servicio_usd +
          case when v_terms.policy = 'on_collection' then 0 else k.neto_local_usd end
        ), 2)
        else null end
    )
    from metricas.consumos k
    where k.merchant_id = p_merchant_id
  ));

  return v_out;
end;
$$;

comment on function public.admin_merchant_stats(uuid, integer) is
  'La ficha de un local: lo vendido en la ventana (consumo sin servicio, consumos, personas con cuota, ticket), su cartera de toda la historia (mora canónica, lo vivo y lo vencido con su desglose, impago en consumo, cobro a tiempo sobre plazos cerrados) y su punto de empate. Lee de metricas.';

revoke all on function public.admin_merchant_stats(uuid, integer) from public, anon;
grant execute on function public.admin_merchant_stats(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Los locales en Riesgo
-- ---------------------------------------------------------------------------
-- Cambia el tipo de salida (account_openers al final): se borra y se crea.

drop function if exists public.admin_merchant_risk(integer);

create function public.admin_merchant_risk(p_days integer default 90)
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
  -- La cartera que generaron sus consumos del periodo. La mora se imputa al
  -- local que originó el consumo (docs/05 §3).
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
    -- Lo que se le debe al local: el resto de lo pendiente y de lo pagado a
    -- medias.
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
    -- Consumos por cada persona que los ABRIÓ: muchos consumos abiertos por
    -- muy poca gente es la forma del fraude de un local.
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
  order by coalesce(pl.consumo, 0) desc;
end;
$$;

comment on function public.admin_merchant_risk(integer) is
  'Una fila por local real con lo de los últimos p_days días operativos: consumos, consumo sin servicio (financed_usd = financed_volume_usd), personas con cuota (distinct_users = distinct_people), consumos por quien abrió la cuenta (repeat_ratio, con account_openers), la mora canónica de sus consumos (arrears_pct = overdue_debt_pct), su parte del consumo y lo que se le debe. Lee de metricas.';

revoke all on function public.admin_merchant_risk(integer) from public, anon;
grant execute on function public.admin_merchant_risk(integer) to authenticated;
