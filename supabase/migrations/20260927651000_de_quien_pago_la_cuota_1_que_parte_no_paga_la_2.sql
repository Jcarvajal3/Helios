-- ============================================================================
-- Ronda — De quien pagó la cuota 1, qué parte no paga la 2
--
-- Javier (27-09): la cifra nueva de Mora › Impago por cuota. El impago de la
-- cuota 2 cuenta a todos, también a quien nunca pagó la 1: no distingue a
-- quien empieza pagando y se cae de quien no pagó nunca. Esta sí.
--
-- admin_first_payment_default gana, en cada fila y en el total, la clave
-- `previous_paid`: las mismas cifras de siempre (maduras, sin pagar, %,
-- consumo, y a los 30 días) contadas solo sobre las cuotas de quien ya había
-- pagado la ANTERIOR (la 1, si se juzga la 2) el día en que se juzga esta:
--
--   * base: cuota 2 madura (pasó su gracia) cuya cuota 1, de la misma persona
--     en el mismo consumo, estaba pagada al acabar esa gracia;
--   * sin pagar: de ellas, las que seguían sin pagar la 2 al acabar la gracia.
--
-- «Pagada» se mira con el mismo día del pago que el resto (el del reporte) y
-- el mismo día de corte que la 2: quien paga la 1 después de que se juzgue la
-- 2 no entra, porque ese día todavía no la había pagado. Con p_cuota = 1 la
-- clave vale null (no hay cuota anterior).
--
-- Misma firma: nadie cambia de llamada (Inicio, el asistente, Mora). Ninguna
-- clave se quita. Copiada de 20260927600000 con solo esto añadido.
-- ============================================================================

create or replace function public.admin_first_payment_default(
  p_months      integer default 6,
  p_dim         text    default 'mes',
  p_merchant_id uuid    default null,
  p_hasta       date    default null,
  p_cuota       integer default 1
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date    := metricas.hoy();
  v_ref    date    := least(coalesce(p_hasta, metricas.hoy()), metricas.hoy());
  v_months integer := greatest(least(coalesce(p_months, 6), 24), 1);
  v_dim    text    := coalesce(nullif(trim(p_dim), ''), 'mes');
  -- Qué cuota se juzga: la 1 (lo de siempre, la señal más temprana) o la 2.
  v_cuota  integer := coalesce(p_cuota, 1);
  v_grace  integer := public.helios_late_fee_grace_days();
  -- Fijo a propósito: es la vara estándar (FPD30) y no una regla del producto.
  v_late   constant integer := 30;
  v_from   date;
  v_out    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_dim not in ('mes', 'semana', 'local', 'nivel', 'grupo', 'primera_compra') then
    raise exception 'No se puede agrupar por «%»: usa mes, semana, local, nivel, grupo o primera_compra', v_dim
      using errcode = '22023';
  end if;

  if v_cuota < 1 then
    raise exception 'La cuota % no existe: las cuotas se cuentan desde la 1', v_cuota
      using errcode = '22023';
  end if;

  -- Los consumos de los p_months meses que acaban en el de v_ref, hasta v_ref.
  -- Si la cuota ya pasó la gracia se juzga HOY: es lo que se sabe ahora.
  v_from := (date_trunc('month', v_ref::timestamp)
             - ((v_months - 1) * interval '1 month'))::date;

  with
  -- La cuota anterior (la 1, si se juzga la 2) de cada persona en cada
  -- consumo. Vacía si se juzga la 1: no hay anterior. Una por persona y
  -- consumo: installments es único en (charge_id, user_id, sequence).
  anterior as (
    select a.charge_id, a.user_id, a.status, a.pagada_dia
    from metricas.cuotas a
    where v_cuota > 1
      and a.sequence = v_cuota - 1
      and a.business_date between v_from and v_ref
      and (p_merchant_id is null or a.merchant_id = p_merchant_id)
  ),
  cuota as (
    select
      q.user_id,
      q.charge_id,
      q.financed_usd,
      q.business_date,
      q.merchant_id,
      coalesce(ch.confirmed_at, ch.created_at) as consumed_at,
      q.due_date + v_grace < v_today as madura,
      q.due_date + v_late  < v_today as madura_30,
      -- Un `paid` sin fecha es de antes de que se guardara: cuenta como pagada.
      q.status = 'paid' and (q.pagada_dia is null or q.pagada_dia <= q.due_date + v_grace) as pagada_en_gracia,
      q.status = 'paid' and (q.pagada_dia is null or q.pagada_dia <= q.due_date + v_late)  as pagada_a_30,
      -- Si ya había pagado la anterior el día en que se juzga ESTA: al acabar
      -- su gracia, y a los 30 días. Con el mismo «día del pago» (el del
      -- reporte) y la misma regla para un `paid` sin fecha. Null con la 1.
      case when v_cuota > 1 then coalesce(ant.status = 'paid'
        and (ant.pagada_dia is null or ant.pagada_dia <= q.due_date + v_grace), false) end as anterior_pagada,
      case when v_cuota > 1 then coalesce(ant.status = 'paid'
        and (ant.pagada_dia is null or ant.pagada_dia <= q.due_date + v_late), false) end  as anterior_pagada_a_30
    from metricas.cuotas q
    join public.charges ch on ch.id = q.charge_id
    left join anterior ant on ant.charge_id = q.charge_id and ant.user_id = q.user_id
    where q.sequence = v_cuota
      and q.business_date between v_from and v_ref
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ),
  -- Solo se calcula lo que pide la dimensión: el CASE no evalúa las otras ramas.
  dimension as (
    select
      cu.*,
      case when v_dim = 'nivel'
        then public.helios_level_at(cu.user_id, cu.consumed_at) end as nivel_historia,
      case when v_dim = 'nivel'
        then (select p.level from public.profiles p where p.id = cu.user_id) end as nivel_actual,
      case when v_dim = 'grupo'
        then (select count(distinct j.user_id) from public.installments j
               where j.charge_id = cu.charge_id) end as personas,
      case when v_dim = 'primera_compra'
        then cu.charge_id = (
          select j.charge_id
          from public.installments j
          join public.charges c2 on c2.id = j.charge_id
          where j.user_id = cu.user_id
            and c2.status = 'confirmed'
            and not c2.is_test
          order by c2.business_date, c2.confirmed_at, c2.id
          limit 1) end as es_primera
    from cuota cu
  ),
  clave as (
    select
      d.*,
      case v_dim
        when 'mes'    then to_char(date_trunc('month', d.business_date::timestamp), 'YYYY-MM')
        when 'semana' then metricas.lunes(d.business_date)::text
        when 'local'  then d.merchant_id::text
        when 'nivel'  then coalesce(d.nivel_historia, d.nivel_actual)::text
        when 'grupo'  then case
          when d.personas <= 1 then '1'
          when d.personas = 2  then '2'
          when d.personas <= 4 then '3-4'
          else '5+' end
        else case when d.es_primera then 'si' else 'no' end
      end as key
    from dimension d
  ),
  fila as (
    select
      k.key,
      count(*) filter (where k.madura)::integer                                   as matured_count,
      count(*) filter (where k.madura and not k.pagada_en_gracia)::integer        as defaulted_count,
      round(100.0 * count(*) filter (where k.madura and not k.pagada_en_gracia)
            / nullif(count(*) filter (where k.madura), 0), 1)                     as defaulted_pct,
      coalesce(sum(k.financed_usd) filter (where k.madura), 0)                    as matured_financed_usd,
      coalesce(sum(k.financed_usd) filter (where k.madura and not k.pagada_en_gracia), 0)
                                                                                  as defaulted_financed_usd,
      count(*) filter (where k.madura_30)::integer                                as matured_30_count,
      count(*) filter (where k.madura_30 and not k.pagada_a_30)::integer          as defaulted_30_count,
      round(100.0 * count(*) filter (where k.madura_30 and not k.pagada_a_30)
            / nullif(count(*) filter (where k.madura_30), 0), 1)                  as defaulted_30_pct,
      coalesce(sum(k.financed_usd) filter (where k.madura_30), 0)                 as matured_30_financed_usd,
      coalesce(sum(k.financed_usd) filter (where k.madura_30 and not k.pagada_a_30), 0)
                                                                                  as defaulted_30_financed_usd,
      count(*) filter (where not k.madura)::integer                               as in_grace_count,
      -- De quien había pagado la anterior: qué parte no paga esta.
      case when v_cuota > 1 then jsonb_build_object(
        'matured_count',             count(*) filter (where k.madura and k.anterior_pagada),
        'defaulted_count',           count(*) filter (where k.madura and k.anterior_pagada and not k.pagada_en_gracia),
        'defaulted_pct',             round(100.0 * count(*) filter (where k.madura and k.anterior_pagada and not k.pagada_en_gracia)
                                           / nullif(count(*) filter (where k.madura and k.anterior_pagada), 0), 1),
        'matured_financed_usd',      coalesce(sum(k.financed_usd) filter (where k.madura and k.anterior_pagada), 0),
        'defaulted_financed_usd',    coalesce(sum(k.financed_usd) filter (where k.madura and k.anterior_pagada and not k.pagada_en_gracia), 0),
        'matured_30_count',          count(*) filter (where k.madura_30 and k.anterior_pagada_a_30),
        'defaulted_30_count',        count(*) filter (where k.madura_30 and k.anterior_pagada_a_30 and not k.pagada_a_30),
        'defaulted_30_pct',          round(100.0 * count(*) filter (where k.madura_30 and k.anterior_pagada_a_30 and not k.pagada_a_30)
                                           / nullif(count(*) filter (where k.madura_30 and k.anterior_pagada_a_30), 0), 1),
        'matured_30_financed_usd',   coalesce(sum(k.financed_usd) filter (where k.madura_30 and k.anterior_pagada_a_30), 0),
        'defaulted_30_financed_usd', coalesce(sum(k.financed_usd) filter (where k.madura_30 and k.anterior_pagada_a_30 and not k.pagada_a_30), 0)
      ) end                                                as previous_paid
    from clave k
    group by k.key
  ),
  rotulada as (
    select
      f.*,
      case v_dim
        when 'mes'    then f.key
        when 'semana' then f.key
        when 'local'  then (select m.name from public.merchants m where m.id::text = f.key)
        when 'nivel'  then (select l.label from public.levels l where l.level::text = f.key)
        when 'grupo'  then case f.key
          when '1' then 'Una persona' when '2' then 'Dos personas'
          when '3-4' then 'De tres a cuatro personas' else 'Cinco personas o más' end
        else case f.key when 'si' then 'Primer consumo' else 'Consumos siguientes' end
      end as label,
      -- El orden en que se leen: el mes y la semana más recientes primero, el
      -- local con más cuotas primero, y los demás en su orden natural.
      case v_dim
        when 'mes'    then -(extract(year from to_date(f.key, 'YYYY-MM')) * 12
                             + extract(month from to_date(f.key, 'YYYY-MM')))
        when 'semana' then -(f.key::date - date '2000-01-03')
        when 'local'  then -f.matured_count
        when 'nivel'  then f.key::numeric
        when 'grupo'  then array_position(array['1', '2', '3-4', '5+'], f.key)
        else case f.key when 'si' then 0 else 1 end
      end as orden
    from fila f
  )
  select jsonb_build_object(
    'business_date', v_today,
    'from',          v_from,
    'to',            v_ref,
    'months',        v_months,
    'dim',           v_dim,
    'cuota',         v_cuota,
    'merchant_id',   p_merchant_id,
    'grace_days',    v_grace,
    'late_days',     v_late,
    -- Solo con `nivel`: de dónde salió el nivel de las cuotas maduras.
    'level_basis', case when v_dim = 'nivel' then jsonb_build_object(
        'history', (select count(*) from clave where madura and nivel_historia is not null),
        'current', (select count(*) from clave where madura and nivel_historia is null)
      ) end,
    'total', (
      select jsonb_build_object(
        'matured_count',            count(*) filter (where madura),
        'defaulted_count',          count(*) filter (where madura and not pagada_en_gracia),
        'defaulted_pct',            round(100.0 * count(*) filter (where madura and not pagada_en_gracia)
                                          / nullif(count(*) filter (where madura), 0), 1),
        'matured_financed_usd',     coalesce(sum(financed_usd) filter (where madura), 0),
        'defaulted_financed_usd',   coalesce(sum(financed_usd) filter (where madura and not pagada_en_gracia), 0),
        'matured_30_count',         count(*) filter (where madura_30),
        'defaulted_30_count',       count(*) filter (where madura_30 and not pagada_a_30),
        'defaulted_30_pct',         round(100.0 * count(*) filter (where madura_30 and not pagada_a_30)
                                          / nullif(count(*) filter (where madura_30), 0), 1),
        'matured_30_financed_usd',  coalesce(sum(financed_usd) filter (where madura_30), 0),
        'defaulted_30_financed_usd', coalesce(sum(financed_usd) filter (where madura_30 and not pagada_a_30), 0),
        'in_grace_count',           count(*) filter (where not madura),
        -- De quien había pagado la anterior: qué parte no paga esta. Null con la 1.
        'previous_paid',            case when v_cuota > 1 then jsonb_build_object(
        'matured_count',             count(*) filter (where madura and anterior_pagada),
        'defaulted_count',           count(*) filter (where madura and anterior_pagada and not pagada_en_gracia),
        'defaulted_pct',             round(100.0 * count(*) filter (where madura and anterior_pagada and not pagada_en_gracia)
                                           / nullif(count(*) filter (where madura and anterior_pagada), 0), 1),
        'matured_financed_usd',      coalesce(sum(financed_usd) filter (where madura and anterior_pagada), 0),
        'defaulted_financed_usd',    coalesce(sum(financed_usd) filter (where madura and anterior_pagada and not pagada_en_gracia), 0),
        'matured_30_count',          count(*) filter (where madura_30 and anterior_pagada_a_30),
        'defaulted_30_count',        count(*) filter (where madura_30 and anterior_pagada_a_30 and not pagada_a_30),
        'defaulted_30_pct',          round(100.0 * count(*) filter (where madura_30 and anterior_pagada_a_30 and not pagada_a_30)
                                           / nullif(count(*) filter (where madura_30 and anterior_pagada_a_30), 0), 1),
        'matured_30_financed_usd',   coalesce(sum(financed_usd) filter (where madura_30 and anterior_pagada_a_30), 0),
        'defaulted_30_financed_usd', coalesce(sum(financed_usd) filter (where madura_30 and anterior_pagada_a_30 and not pagada_a_30), 0)
      ) end
      )
      from cuota
    ),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(r) - 'orden' order by r.orden, r.label)
      from rotulada r
    ), '[]'::jsonb)
  )
  into v_out;

  return v_out;
end;
$$;

comment on function public.admin_first_payment_default(integer, text, uuid, date, integer) is
  'El impago de una cuota tras la gracia (la misma gracia que «a tiempo» desde 2026-09-27): de cada consumo confirmado de los p_months meses que acaban en p_hasta (por defecto hoy), la cuota p_cuota (por defecto la 1; la 2 con p_cuota = 2) de cada persona; impagada si seguía sin pagar el último día de la gracia (late_fee_grace_days), y a los 30 días. Partido por mes, semana (la cohorte de consumo, clave = su lunes), local, nivel, grupo o primera_compra. Montos en consumo (financed). Con p_cuota >= 2, cada fila y el total llevan previous_paid: lo mismo contado solo sobre quien ya habia pagado la cuota anterior el dia en que se juzga esta («de quien pago la cuota 1, que parte no paga la 2»); null con la 1. Lee de metricas.cuotas; con p_merchant_id, los consumos de ese local.';

revoke all on function public.admin_first_payment_default(integer, text, uuid, date, integer) from public, anon;
grant execute on function public.admin_first_payment_default(integer, text, uuid, date, integer) to authenticated, service_role;
