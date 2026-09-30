-- ============================================================================
-- Ronda — Cosechas y locales, también en consumo
--
-- `admin_credit_cohorts` y `admin_merchant_risk` suman `amount_usd`, que es
-- deuda con el servicio de Ronda y su IVA dentro, y lo llaman `financed_usd`.
-- Sus porcentajes salen bien (deuda entre deuda), pero sus montos no son
-- consumo, y el impago no se puede medir contra lo financiado.
--
-- Se añaden, sin quitar ni renombrar nada (el panel de `main` lee dev):
--   cosechas  billed_debt_usd (el mismo `financed_usd` con su nombre de
--             verdad), financed_volume_usd, paid_/overdue_/current_/
--             written_off_financed_usd, written_off_financed_pct, people_count
--   locales   financed_volume_usd, volume_share_financed_pct, distinct_people,
--             billed_debt_usd, overdue_debt_usd, overdue_debt_pct,
--             written_off_financed_usd, written_off_financed_pct
--
-- Qué denominador lleva cada tasa:
--   * Impago (lo dado por perdido): financed sobre financed. Es principal que
--     no vuelve, y se compara con el punto de empate.
--   * Mora (lo vencido y cobrable): deuda sobre deuda, payable entre payable.
--     Es lo que se debe transferir, y no se compara con el consumo.
--   Ninguna tasa de aquí mezcla clases.
--
-- Y dos arreglos de valor en `admin_merchant_risk`:
--   * `pending_payout_usd` cuenta ahora el resto de 'pending' y 'partial'
--     (`amount_usd - paid_usd`); antes perdía el resto de los pagos parciales.
--   * Cambia el tipo de salida (columnas nuevas al final), así que la función
--     se borra y se vuelve a crear, con sus permisos.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_credit_cohorts(p_months integer DEFAULT 6)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today  date := public.helios_business_date(now());
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

  select coalesce(jsonb_agg(to_jsonb(q) order by q.month desc), '[]'::jsonb)
  into v_rows
  from (
    select
      to_char(date_trunc('month', c.business_date::timestamp), 'YYYY-MM') as month,
      count(distinct c.id)::integer                                       as charge_count,
      count(distinct c.user_id)::integer                                  as user_count,
      sum(i.amount_usd)                                                   as financed_usd,
      sum(i.amount_usd) filter (where i.status = 'paid')                  as paid_usd,
      -- Vencido y todavía cobrable. Es la mora de esa cosecha, hoy.
      sum(i.amount_usd) filter (
        where i.status = 'pending' and i.written_off_at is null
          and i.due_date < v_today)                                       as overdue_usd,
      -- Vivo y sin vencer: ni cobrado ni problema, todavía.
      sum(i.amount_usd) filter (
        where i.status = 'pending' and i.written_off_at is null
          and i.due_date >= v_today)                                      as current_usd,
      sum(i.amount_usd) filter (where i.written_off_at is not null)       as written_off_usd,
      round(100 * sum(i.amount_usd) filter (
        where i.status = 'pending' and i.written_off_at is null
          and i.due_date < v_today) / nullif(sum(i.amount_usd), 0), 2)    as overdue_pct,
      round(100 * sum(i.amount_usd) filter (where i.written_off_at is not null)
                / nullif(sum(i.amount_usd), 0), 2)                        as written_off_pct,
      -- Una cosecha joven da 0% de impago por construcción, no por mérito: su
      -- última cuota todavía no ha tenido tiempo de recorrer la escalera. La
      -- pantalla tiene que poder decirlo en vez de dejar leer un cero limpio.
      (max(c.business_date) + v_season) <= v_today                        as matured,
      -- ── Añadido el 2026-09-25 ──────────────────────────────────────────
      -- Todo lo de arriba suma `amount_usd`: deuda (payable), con el servicio y
      -- su IVA dentro. `financed_usd` es un nombre heredado y NO es consumo;
      -- `billed_debt_usd` es el mismo número con su nombre de verdad.
      sum(i.amount_usd)                                                   as billed_debt_usd,
      -- FINANCED: el consumo de la cosecha, sin el fee.
      sum(i.financed_usd)                                                 as financed_volume_usd,
      coalesce(sum(i.financed_usd) filter (where i.status = 'paid'), 0)   as paid_financed_usd,
      coalesce(sum(i.financed_usd) filter (
        where i.status = 'pending' and i.written_off_at is null
          and i.due_date < v_today), 0)                                   as overdue_financed_usd,
      coalesce(sum(i.financed_usd) filter (
        where i.status = 'pending' and i.written_off_at is null
          and i.due_date >= v_today), 0)                                  as current_financed_usd,
      coalesce(sum(i.financed_usd) filter (where i.written_off_at is not null), 0)
                                                                          as written_off_financed_usd,
      -- El impago se mide sobre lo financiado. La mora es deuda vencida y se
      -- mide sobre la deuda: para eso sigue `overdue_pct`.
      round(100 * coalesce(sum(i.financed_usd) filter (where i.written_off_at is not null), 0)
                / nullif(sum(i.financed_usd), 0), 2)                      as written_off_financed_pct,
      -- `user_count` cuenta a quien abrió la cuenta; esto, a todos los que
      -- pusieron algo en un consumo de la cosecha (por cuotas).
      count(distinct i.user_id)::integer                                  as people_count
    from public.charges c
    join public.installments i on i.charge_id = c.id
    where c.status = 'confirmed'
      and not c.is_test
      and c.business_date >= v_from
    group by 1
  ) q;

  return jsonb_build_object(
    'business_date',  v_today,
    'months',         v_months,
    'season_days',    v_season,
    'expulsion_days', public.helios_mora_expulsion_days(),
    'rows',           v_rows
  );
end;
$function$;

revoke all on function public.admin_credit_cohorts(integer) from public, anon;
grant execute on function public.admin_credit_cohorts(integer) to authenticated;

drop function if exists public.admin_merchant_risk(integer);

CREATE OR REPLACE FUNCTION public.admin_merchant_risk(p_days integer DEFAULT 90)
 RETURNS TABLE(merchant_id uuid, merchant_name text, status text, charge_count integer, financed_usd numeric, distinct_users integer, repeat_ratio numeric, overdue_usd numeric, arrears_pct numeric, volume_share_pct numeric, pending_payout_usd numeric, financed_volume_usd numeric, volume_share_financed_pct numeric, distinct_people integer, billed_debt_usd numeric, overdue_debt_usd numeric, overdue_debt_pct numeric, written_off_financed_usd numeric, written_off_financed_pct numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today date := public.helios_business_date(now());
  v_from  date;
  v_total numeric;
  v_total_fin numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := v_today - (greatest(least(coalesce(p_days, 90), 365), 1) - 1);

  -- Alias explícito: esta función declara OUT parameters llamados `status` y
  -- `financed_usd`, y sin calificar la columna Postgres no sabe si `status`
  -- es la de la tabla o la variable.
  select coalesce(sum(c0.amount_usd), 0) into v_total
  from public.charges c0
  where c0.status = 'confirmed' and not c0.is_test
    and c0.business_date between v_from and v_today;

  -- El mismo total en FINANCED, para la cuota de volumen sin el fee.
  select coalesce(sum(i0.financed_usd), 0) into v_total_fin
  from public.installments i0
  join public.charges c0 on c0.id = i0.charge_id
  where c0.status = 'confirmed' and not c0.is_test and not i0.is_test
    and c0.business_date between v_from and v_today;

  return query
  with per_merchant as (
    select
      ch.merchant_id as mid,
      count(*)::integer as cnt,
      sum(ch.amount_usd) as financed,
      count(distinct ch.user_id)::integer as users
    from public.charges ch
    where ch.status = 'confirmed' and not ch.is_test
      and ch.business_date between v_from and v_today
    group by 1
  ),
  arrears as (
    -- La mora se imputa al comercio que originó el consumo. Es la métrica que
    -- docs/05 §3 llama "de primera línea" y la que dispararía el holdback.
    select
      ch.merchant_id as mid,
      sum(i.amount_usd) filter (where i.status = 'pending' and i.due_date < v_today) as overdue,
      sum(i.amount_usd) as billed
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    where ch.business_date between v_from and v_today
      and not ch.is_test
    group by 1
  ),
  consumo as (
    -- De las cuotas: el consumo en FINANCED, la deuda que generó (payable) y
    -- la gente. Un consumo de grupo es un cargo con una cuota por persona.
    select
      ch.merchant_id as mid,
      sum(i.financed_usd) as fin,
      count(distinct i.user_id)::integer as people,
      sum(i.amount_usd) as billed,
      -- Vencido y todavía cobrable, como la mora de `admin_overview` y de las
      -- cosechas. `overdue_usd` (arriba) cuenta además lo dado por perdido.
      sum(i.amount_usd) filter (
        where i.status = 'pending' and i.written_off_at is null
          and i.due_date < v_today) as overdue_debt,
      sum(i.financed_usd) filter (where i.written_off_at is not null) as written_off_fin
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    where ch.status = 'confirmed' and not ch.is_test and not i.is_test
      and ch.business_date between v_from and v_today
    group by 1
  ),
  payables as (
    -- Lo que se le debe al local: el resto de lo pendiente y de lo pagado a
    -- medias. Hasta el 2026-09-25 solo miraba 'pending'.
    select s.merchant_id as mid, sum(s.amount_usd - s.paid_usd) as pending
    from public.settlements s
    where s.status in ('pending', 'partial')
      and not public.helios_is_test_merchant(s.merchant_id)
    group by 1
  )
  select
    m.id,
    m.name,
    m.status::text,
    coalesce(pm.cnt, 0),
    coalesce(pm.financed, 0)::numeric,
    coalesce(pm.users, 0),
    case when coalesce(pm.users, 0) > 0
         then round(pm.cnt::numeric / pm.users, 2) else 0 end,
    coalesce(a.overdue, 0)::numeric,
    case when coalesce(a.billed, 0) > 0
         then round(100 * coalesce(a.overdue, 0) / a.billed, 2) else 0 end,
    case when v_total > 0
         then round(100 * coalesce(pm.financed, 0) / v_total, 2) else 0 end,
    coalesce(p.pending, 0)::numeric,
    coalesce(co.fin, 0)::numeric,
    case when v_total_fin > 0
         then round(100 * coalesce(co.fin, 0) / v_total_fin, 2) else null end,
    coalesce(co.people, 0),
    coalesce(co.billed, 0)::numeric,
    coalesce(co.overdue_debt, 0)::numeric,
    case when coalesce(co.billed, 0) > 0
         then round(100 * coalesce(co.overdue_debt, 0) / co.billed, 2) else null end,
    coalesce(co.written_off_fin, 0)::numeric,
    case when coalesce(co.fin, 0) > 0
         then round(100 * coalesce(co.written_off_fin, 0) / co.fin, 2) else null end
  from public.merchants m
  left join per_merchant pm on pm.mid = m.id
  left join arrears a on a.mid = m.id
  left join payables p on p.mid = m.id
  left join consumo co on co.mid = m.id
  where not m.is_test
  order by coalesce(pm.financed, 0) desc;
end;
$function$;

revoke all on function public.admin_merchant_risk(integer) from public, anon;
grant execute on function public.admin_merchant_risk(integer) to authenticated;
