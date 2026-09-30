-- ============================================================================
-- Ronda — Cuánto cupo se usa, nivel a nivel
--
-- `admin_level_config` dice cuánta gente hay en cada nivel y cuánta deuda
-- lleva, pero en payable y sin separar a quien apenas usa el cupo de quien lo
-- tiene lleno. Riesgo necesita lo segundo: una escalera donde todo el mundo
-- vive al 100 % es una escalera que se queda corta o que se está exprimiendo.
--
-- ── El cupo ocupado es el del freno de compra ───────────────────────────────
-- Se cuenta como `helios_credit_used_usd`, que es lo que mira
-- `helios_assign_debt` antes de dejar comprar: todo lo financiado de cada
-- consumo que aún tiene alguna cuota de esa persona pendiente. No se usa el
-- disponible de `admin_user_detail`: sale del bloque de crédito y resta un
-- `paid_usd` que lleva el fee dentro (payable) a un `charged_usd` que no lo
-- lleva (financed), así que no coincide con el freno.
--
-- ── Y la exposición, aparte ─────────────────────────────────────────────────
-- El cupo ocupado no es el dinero en la calle: quien pagó la cuota 1 sigue
-- ocupando el consumo entero hasta pagar la 2. La exposición es el principal
-- que falta por volver: lo financiado de cada cuota pendiente y no dada por
-- perdida. Las dos cifras son financed.
-- ============================================================================

create or replace function public.admin_credit_utilization()
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
        then 100 * coalesce(u.usado, 0) / l.monthly_limit_usd end as pct
    from public.profiles p
    join public.levels l on l.level = p.level
    left join uso u      on u.user_id = p.id
    left join expuesto e on e.user_id = p.id
    where not p.is_test
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
      coalesce(sum(g.principal), 0)                               as exposure_financed_usd,
      round(100 * sum(g.usado) / nullif(sum(g.limite), 0), 1)     as usage_pct,
      -- Los tramos de uso del cupo, persona a persona, en su orden.
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
    'levels', coalesce((select jsonb_agg(to_jsonb(n) order by n.level) from por_nivel n), '[]'::jsonb),
    -- Quien está fuera de la escalera activa (nivel 0 o un nivel apagado) y
    -- aun así debe algo: suele ser gente expulsada, y su deuda es exposición.
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

comment on function public.admin_credit_utilization() is
  'Uso del cupo por nivel activo: personas, limite, cupo ocupado (como el freno de compra), exposicion (principal pendiente) y reparto en tramos. Todo financed y sin cuentas de prueba.';

revoke all on function public.admin_credit_utilization() from public, anon;
grant execute on function public.admin_credit_utilization() to authenticated;
