-- ============================================================================
-- Ronda — El embudo y los grupos de Gente dicen exactamente lo que cuentan
--
-- Repaso de rigor (AUD-CAJA-LOCALES-GENTE, 27-09). Dos cambios, sin cambiar
-- ninguna firma ni quitar ninguna clave:
--
-- 1. admin_growth_funnel: dos rótulos que no decían lo que cuentan.
--      listos      «Listos para consumir»  → «Crearon su PIN»: registros cuyo
--                  estado ya no es pending_kyc ni pending_pin, hayan
--                  consumido o no.
--      repitieron  «Volvieron a consumir»  → «Hicieron 2 consumos o más»: son
--                  dos consumos distintos o más, aunque sean de la misma noche.
--    Las cuentas no cambian. Copia de 20260927630000 (su última versión).
--
-- 2. admin_group_metrics: clave nueva `groups.ever_with_spend`, los grupos que
--    han consumido alguna vez (de los mismos que cuenta `total`). El panel
--    enseñaba «Grupos que gastaron» (los de la VENTANA) con un anillo «de los
--    creados» (TODOS, desde el inicio): con la ventana de una semana daba
--    21 de 149 = 14 %, cuando 133 de 149 han consumido alguna vez (89 %). El
--    anillo pasa a ser ever_with_spend ÷ total. Copia de 20260927570000.
--
-- Orden: después de 20260927630000 y de 20260927570000. Si alguien reaplica
-- cualquiera de las dos, hay que reaplicar esta. La genera
-- <scratchpad AUD-CLG>/gen_680.cjs.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El embudo
-- ---------------------------------------------------------------------------

create or replace function public.admin_growth_funnel(
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
  v_today  date := metricas.hoy();
  v_from   date;
  v_to     date;
  v_days   integer;
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select w.desde, w.hasta, w.dias into v_from, v_to, v_days
  from metricas.gente_ventana(p_from, p_to) w;

  if p_merchant_id is not null then
    return jsonb_build_object(
      'business_date',     v_today,
      'from',              v_from,
      'to',                v_to,
      'window_days',       v_days,
      'merchant_id',       p_merchant_id,
      'steps',             null,
      'p50_days_to_first', null,
      'p90_days_to_first', null,
      'same_day_pct',      null
    );
  end if;

  with
  -- Todo el que pidió el código en la ventana, se verificara o no. El hueco
  -- entre este escalón y el siguiente avisa de que los SMS no llegan.
  cohorte as (
    select s.user_id, s.etapa
    from metricas.solicitudes s
    where s.solicito_dia between v_from and v_to
  ),
  -- Los registros de la cohorte, con su día de registro y su estado de hoy.
  registros as (
    select p.user_id, p.registro_dia as dia, p.estado as status
    from metricas.personas p
    join cohorte c on c.user_id = p.user_id
  ),
  compras as (
    select q.user_id,
           count(distinct q.charge_id)::int as ordenes,
           min(q.business_date)             as primer_dia
    from metricas.cuotas q
    join registros r on r.user_id = q.user_id
    group by 1
  ),
  -- Días entre registrarse y estrenar. La mediana y no la media: un solo
  -- rezagado que estrena a los 90 días le sube la media a todo el mundo.
  demora as (
    select (cp.primer_dia - r.dia) as dias
    from compras cp
    join registros r on r.user_id = cp.user_id
  )
  select jsonb_build_object(
    'business_date', v_today,
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,
    'merchant_id',   null,
    'steps', jsonb_build_array(
      jsonb_build_object('key', 'pidieron', 'label', 'Solicitaron el código',
        'users', (select count(*) from cohorte)),
      jsonb_build_object('key', 'confirmaron', 'label', 'Confirmaron el teléfono',
        'users', (select count(*) from cohorte where etapa <> 'solicito_el_codigo')),
      jsonb_build_object('key', 'registrados', 'label', 'Se registraron (identidad verificada)',
        'users', (select count(*) from registros)),
      jsonb_build_object('key', 'listos', 'label', 'Crearon su PIN',
        'users', (select count(*) from registros where status not in ('pending_kyc', 'pending_pin'))),
      jsonb_build_object('key', 'compraron', 'label', 'Consumieron al menos una vez',
        'users', (select count(*) from compras)),
      jsonb_build_object('key', 'repitieron', 'label', 'Hicieron 2 consumos o más',
        'users', (select count(*) from compras where ordenes >= 2))
    ),
    'p50_days_to_first', (
      select coalesce(percentile_disc(0.5) within group (order by dias), 0)::int from demora
    ),
    'p90_days_to_first', (
      select coalesce(percentile_disc(0.9) within group (order by dias), 0)::int from demora
    ),
    -- Cuántos de los que compraron lo hicieron la misma noche del registro.
    'same_day_pct', (
      select case when (select count(*) from demora) > 0
             then round(100.0 * (select count(*) from demora where dias = 0)
                              / (select count(*) from demora), 1)
             else 0 end
    )
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.admin_growth_funnel(date, date, uuid) is
  'Métricas › Gente: el embudo de la gente que pidió el código en la ventana (solicitaron el código, confirmaron el teléfono, se registraron = identidad verificada, crearon su PIN, consumieron al menos una vez, hicieron 2 consumos o más). Cada escalón está dentro del anterior. Es del registro: con p_merchant_id los escalones valen null.';

revoke all on function public.admin_growth_funnel(date, date, uuid) from public, anon;
grant execute on function public.admin_growth_funnel(date, date, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Los grupos
-- ---------------------------------------------------------------------------

create or replace function public.admin_group_metrics(
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
  v_today  date := metricas.hoy();
  v_local  boolean := p_merchant_id is not null;
  v_from   date;
  v_to     date;
  v_days   integer;
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select w.desde, w.hasta, w.dias into v_from, v_to, v_days
  from metricas.gente_ventana(p_from, p_to) w;

  with
  -- Un grupo es de prueba si lo es quien lo creó.
  grupos as (
    select g.id, g.name, g.created_at, g.business_date,
           public.helios_business_date(g.created_at) as dia,
           g.created_by, p.full_name as created_by_name
    from public.groups g
    join public.profiles p on p.id = g.created_by and not p.is_test
  ),
  miembros as (
    select gm.group_id, count(*)::int as n
    from public.group_members gm
    join grupos g on g.id = gm.group_id
    where gm.status <> 'left'
    group by 1
  ),
  -- Los consumos de la ventana (del local, si lo hay). `payers` sale de las
  -- cuotas: entre cuánta gente se repartió la cuenta de verdad.
  cargos as (
    select k.charge_id as id, k.group_id, k.business_date as dia,
           k.financed_usd as fin, k.personas as payers
    from metricas.consumos k
    where k.business_date between v_from and v_to
      and (p_merchant_id is null or k.merchant_id = p_merchant_id)
  )
  select jsonb_build_object(
    'business_date', v_today,
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,
    'merchant_id',   p_merchant_id,

    -- Un grupo no es de ningún local: lo que cuenta grupos creados no se
    -- parte. Los que gastaron sí: gastaron en ese local.
    'groups', jsonb_build_object(
      'total',       case when v_local then null else (select count(*) from grupos) end,
      'created',     case when v_local then null else (select count(*) from grupos where dia between v_from and v_to) end,
      'open',        case when v_local then null else (select count(*) from grupos where public.helios_group_is_open(business_date, created_at)) end,
      'with_spend',  (select count(distinct group_id) from cargos where group_id is not null),
      -- Los grupos (de los de `total`) que han consumido alguna vez, desde el
      -- primer día: el numerador que va con `total`. `with_spend` es de la
      -- ventana y dividirlo entre todos los creados mezclaba dos periodos.
      'ever_with_spend', (
        select count(distinct k.group_id)
        from metricas.consumos k
        join grupos g on g.id = k.group_id
        where p_merchant_id is null or k.merchant_id = p_merchant_id
      ),
      'avg_members', case when v_local then null else (select coalesce(round(avg(n), 1), 0) from miembros) end
    ),

    'split', jsonb_build_object(
      'group_charges',  (select count(*) from cargos where group_id is not null),
      'solo_charges',   (select count(*) from cargos where group_id is null),
      'group_financed', (select coalesce(sum(fin), 0) from cargos where group_id is not null),
      'solo_financed',  (select coalesce(sum(fin), 0) from cargos where group_id is null),
      'group_avg_usd',  (select coalesce(round(avg(fin), 2), 0) from cargos where group_id is not null),
      'solo_avg_usd',   (select coalesce(round(avg(fin), 2), 0) from cargos where group_id is null),
      'avg_payers',     (select coalesce(round(avg(payers), 2), 0) from cargos where group_id is not null)
    ),

    'series', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.day)
      from (
        select (v_from + k)                                            as day,
               case when v_local then null else coalesce(gc.n, 0)::int end as groups_created,
               coalesce(ca.n, 0)::int                                  as group_charges,
               coalesce(ca.f, 0)                                       as group_financed_usd
        from generate_series(0, v_days - 1) as g(k)
        left join (
          select dia, count(*) as n from grupos
          where dia between v_from and v_to group by 1
        ) gc on gc.dia = v_from + k
        left join (
          select dia, count(*) as n, sum(fin) as f from cargos
          where group_id is not null group by 1
        ) ca on ca.dia = v_from + k
      ) s
    ), '[]'::jsonb),

    'top', coalesce((
      select jsonb_agg(jsonb_build_object(
        'group_id',        t.id,
        'name',            t.name,
        'created_by',      t.created_by,
        'created_by_name', t.created_by_name,
        'members',         coalesce(m.n, 0),
        'charges',         t.cuentas,
        'financed_usd',    t.financiado
      ) order by t.financiado desc, t.cuentas desc, t.name, t.id)
      from (
        select g.id, g.name, g.created_by, g.created_by_name,
               count(ca.id)::int         as cuentas,
               coalesce(sum(ca.fin), 0)  as financiado
        from grupos g
        join cargos ca on ca.group_id = g.id
        group by g.id, g.name, g.created_by, g.created_by_name
        order by financiado desc, cuentas desc, g.name, g.id
        limit 10
      ) t
      left join miembros m on m.group_id = t.id
    ), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.admin_group_metrics(date, date, uuid) is
  'Métricas › Gente › Grupos: grupos que consumieron en la ventana (with_spend) y alguna vez (ever_with_spend, sobre total), consumo de grupo frente a individual (sin service fee) y los que más mueven. Con p_merchant_id, lo que cuenta grupos creados vale null.';

revoke all on function public.admin_group_metrics(date, date, uuid) from public, anon;
grant execute on function public.admin_group_metrics(date, date, uuid) to authenticated;
