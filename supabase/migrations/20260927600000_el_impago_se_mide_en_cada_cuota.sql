-- ============================================================================
-- Ronda — El impago tras la gracia se mide en cada cuota, no solo en la 1
--
-- Javier (27-09): «¿Por qué en Cobranza y riesgo solo hay métricas y vistas
-- para la primera cuota pero no para la segunda?». La cuota 2 tiene ahora lo
-- mismo que la 1: el impago al terminar la gracia y a los 30 días, partido por
-- mes, semana, local, nivel, personas en el consumo o primer consumo.
--
-- admin_first_payment_default gana `p_cuota integer default 1`. Quien la llama
-- sin él (Inicio, el asistente, Riesgo) recibe exactamente lo de antes: la
-- cuota 1. La respuesta gana la clave `cuota`; ninguna se quita.
--
-- La cuota 2 se juzga igual que la 1 y por su propio vencimiento: madura
-- cuando pasa su gracia, e impagada si el último día de la gracia seguía sin
-- pagar. Cuenta también a quien tampoco pagó la cuota 1: es lo que queda sin
-- volver de esa cuota, sea quien sea.
--
-- Se cambia la firma: drop de la vieja (integer, text, uuid, date) y create de
-- la nueva, copiada de 20260927551000 con solo lo de la cuota añadido.
-- ============================================================================

drop function if exists public.admin_first_payment_default(integer, text, uuid, date);

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
      q.status = 'paid' and (q.pagada_dia is null or q.pagada_dia <= q.due_date + v_late)  as pagada_a_30
    from metricas.cuotas q
    join public.charges ch on ch.id = q.charge_id
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
      count(*) filter (where not k.madura)::integer                               as in_grace_count
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

comment on function public.admin_first_payment_default(integer, text, uuid, date, integer) is
  'El impago de una cuota tras la gracia: de cada consumo confirmado de los p_months meses que acaban en p_hasta (por defecto hoy), la cuota p_cuota (por defecto la 1; la 2 con p_cuota = 2) de cada persona; impagada si seguía sin pagar el último día de la gracia (late_fee_grace_days), y a los 30 días. Partido por mes, semana (la cohorte de consumo, clave = su lunes), local, nivel, grupo o primera_compra. Montos en consumo (financed). Lee de metricas.cuotas; con p_merchant_id, los consumos de ese local.';

revoke all on function public.admin_first_payment_default(integer, text, uuid, date, integer) from public, anon;
grant execute on function public.admin_first_payment_default(integer, text, uuid, date, integer) to authenticated, service_role;
