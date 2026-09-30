-- ============================================================================
-- Ronda — El impago de la primera cuota
--
-- La mora y el impago de una cosecha tardan meses en tener su número: la
-- cuota 2 vence a los 14 días y la expulsión llega a los 60. La primera cuota
-- da la señal en diez días: si alguien no paga la primera, casi nunca paga la
-- segunda. Es la cifra con la que Riesgo puede reaccionar a tiempo.
--
-- ── La unidad ───────────────────────────────────────────────────────────────
-- La cuota 1 de cada persona en cada consumo, sacada de `installments`: un
-- consumo de grupo es UN cargo con una cuota 1 por integrante, y cada una es
-- una apuesta distinta. Solo cuenta cuando ya maduró (vencimiento + los días
-- de gracia del cargo por atraso, antes de hoy); las demás salen aparte como
-- `in_grace_count`, para que un mes joven no se lea como un mes limpio.
--
-- «Impago temprano» = no estaba pagada al terminar la gracia (el día
-- operativo del pago, igual que el cobro a tiempo). Y la misma cifra a los 30
-- días, que es la que separa el despiste del impago.
--
-- ── El nivel al consumir ────────────────────────────────────────────────────
-- `helios_level_at` lo reconstruye con `level_changes`: el `to_level` del último
-- cambio antes del consumo o, si no lo hay, el `from_level` del primero
-- después. Quien nunca cambió de nivel no tiene historia y se usa el nivel
-- actual, que para esa persona es el mismo. La respuesta dice cuántas cuotas
-- salieron de cada fuente (`level_basis`).
-- ============================================================================

create or replace function public.helios_level_at(p_user uuid, p_at timestamptz)
returns smallint
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select lc.to_level from public.level_changes lc
      where lc.user_id = p_user and lc.created_at <= p_at
      order by lc.created_at desc limit 1),
    (select lc.from_level from public.level_changes lc
      where lc.user_id = p_user and lc.created_at > p_at
      order by lc.created_at limit 1)
  );
$$;

comment on function public.helios_level_at(uuid, timestamptz) is
  'El nivel de una persona en un momento, segun level_changes. Null si nunca cambio de nivel: entonces vale el actual.';

-- Es un ladrillo de las funciones del panel, no una lectura suelta: el
-- historial de niveles de cualquiera no se pregunta desde fuera.
revoke all on function public.helios_level_at(uuid, timestamptz) from public, anon, authenticated;

create or replace function public.admin_first_payment_default(
  p_months integer default 6,
  p_dim    text    default 'mes'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date    := public.helios_business_date(now());
  v_months integer := greatest(least(coalesce(p_months, 6), 24), 1);
  v_dim    text    := coalesce(nullif(trim(p_dim), ''), 'mes');
  v_grace  integer := public.helios_late_fee_grace_days();
  -- Fijo a propósito: es la vara estándar (FPD30) y no una regla del producto.
  v_late   constant integer := 30;
  v_from   date;
  v_out    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_dim not in ('mes', 'local', 'nivel', 'grupo', 'primera_compra') then
    raise exception 'No se puede agrupar por «%»: usa mes, local, nivel, grupo o primera_compra', v_dim
      using errcode = '22023';
  end if;

  v_from := (date_trunc('month', v_today::timestamp)
             - ((v_months - 1) * interval '1 month'))::date;

  with
  cuota as (
    select
      i.user_id,
      i.charge_id,
      i.financed_usd,
      c.business_date,
      c.merchant_id,
      coalesce(c.confirmed_at, c.created_at) as consumed_at,
      i.due_date + v_grace < v_today as madura,
      i.due_date + v_late  < v_today as madura_30,
      -- Un `paid` sin fecha es de antes de que se guardara: cuenta como pagada.
      i.status = 'paid' and (i.paid_at is null
        or public.helios_business_date(i.paid_at) <= i.due_date + v_grace) as pagada_en_gracia,
      i.status = 'paid' and (i.paid_at is null
        or public.helios_business_date(i.paid_at) <= i.due_date + v_late)  as pagada_a_30
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.sequence = 1
      and not i.is_test
      and not c.is_test
      and c.status = 'confirmed'
      and c.business_date >= v_from
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
        when 'mes'   then to_char(date_trunc('month', d.business_date::timestamp), 'YYYY-MM')
        when 'local' then d.merchant_id::text
        when 'nivel' then coalesce(d.nivel_historia, d.nivel_actual)::text
        when 'grupo' then case
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
      count(*) filter (where not k.madura)::integer                               as in_grace_count
    from clave k
    group by k.key
  ),
  rotulada as (
    select
      f.*,
      case v_dim
        when 'mes'   then f.key
        when 'local' then (select m.name from public.merchants m where m.id::text = f.key)
        when 'nivel' then (select l.label from public.levels l where l.level::text = f.key)
        when 'grupo' then case f.key
          when '1' then 'Una persona' when '2' then 'Dos personas'
          when '3-4' then 'De tres a cuatro personas' else 'Cinco personas o más' end
        else case f.key when 'si' then 'Primer consumo' else 'Consumos siguientes' end
      end as label,
      -- El orden en que se leen: el mes más reciente primero, el local con más
      -- cuotas primero, y los demás en su orden natural.
      case v_dim
        when 'mes'   then -(extract(year from to_date(f.key, 'YYYY-MM')) * 12
                            + extract(month from to_date(f.key, 'YYYY-MM')))
        when 'local' then -f.matured_count
        when 'nivel' then f.key::numeric
        when 'grupo' then array_position(array['1', '2', '3-4', '5+'], f.key)
        else case f.key when 'si' then 0 else 1 end
      end as orden
    from fila f
  )
  select jsonb_build_object(
    'business_date', v_today,
    'from',          v_from,
    'months',        v_months,
    'dim',           v_dim,
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
        'in_grace_count',           count(*) filter (where not madura)
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

comment on function public.admin_first_payment_default(integer, text) is
  'Impago de la cuota 1 (al terminar la gracia y a los 30 dias) por mes de consumo, local, nivel al consumir, tamano del reparto o primera compra. Sin cuentas de prueba.';

revoke all on function public.admin_first_payment_default(integer, text) from public, anon;
grant execute on function public.admin_first_payment_default(integer, text) to authenticated;
