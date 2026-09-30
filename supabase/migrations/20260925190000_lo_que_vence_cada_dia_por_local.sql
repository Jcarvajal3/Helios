-- ============================================================================
-- Ronda — Lo que vence cada día, y de qué local es
--
-- «Por cobrar a usuarios» (Dinero › Balance) es una sola cifra, sin fecha. Caja
-- necesita verla como calendario: cuánto vence cada día de una semana, partido
-- en consumo y comisión e IVA, y qué parte corresponde a cada local.
--
-- `admin_receivables_by_day(p_desde, p_hasta, p_incluir_pagadas)`, de solo
-- lectura:
--   · el día es el vencimiento de la cuota (`installments.due_date`, día
--     natural de Caracas);
--   · el local sale de `installments.charge_id → charges.merchant_id`;
--   · lo pendiente son las cuotas en 'pending' que no se dieron por perdidas
--     (`written_off_at`): lo perdido no es por cobrar;
--   · los cargos por atraso cuelgan de su cuota (`late_fees.installment_id`) y
--     van en su propia cifra, nunca dentro de la comisión;
--   · las cuentas de prueba (cuota, consumo, persona o local) no suman.
-- ============================================================================

create or replace function public.admin_receivables_by_day(
  p_desde           date,
  p_hasta           date,
  p_incluir_pagadas boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  -- Lo vencido lo decide el día operativo, como el motor de mora: una cuota
  -- del jueves no está vencida el viernes a las 08:00.
  v_bd    date    := public.helios_business_date(now());
  v_hoy   date    := public.helios_caracas_date(now());
  v_todas boolean := coalesce(p_incluir_pagadas, false);
  v_res   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_desde is null or p_hasta is null or p_hasta < p_desde then
    raise exception 'El rango de fechas no es válido' using errcode = '22023';
  end if;
  if p_hasta - p_desde > 62 then
    raise exception 'El rango no puede pasar de 63 días' using errcode = '22023';
  end if;

  with
  -- Las cuotas que vencen en el rango, con su local.
  cuotas as (
    select i.id, i.user_id, i.due_date, c.merchant_id, m.name as local_nombre,
           i.status, i.amount_usd, i.financed_usd
    from public.installments i
    join public.charges   c on c.id = i.charge_id
    join public.merchants m on m.id = c.merchant_id
    join public.profiles  p on p.id = i.user_id
    where i.due_date between p_desde and p_hasta
      and i.written_off_at is null
      and not i.is_test and not c.is_test and not m.is_test and not p.is_test
  ),
  -- Una pieza por cuota (su consumo y su comisión) y otra por su cargo por
  -- atraso: el cargo puede seguir pendiente con la cuota ya pagada. Un cargo
  -- condonado o dado por perdido ('written_off') no es por cobrar.
  piezas as (
    select q.id as cuota_id, q.user_id, q.due_date as dia, q.merchant_id, q.local_nombre,
           q.status = 'paid'                 as pagada,
           q.financed_usd                    as consumo,
           q.amount_usd - q.financed_usd     as comision,
           0::numeric                        as cargos
    from cuotas q
    union all
    select q.id, q.user_id, q.due_date, q.merchant_id, q.local_nombre,
           lf.status = 'paid', 0, 0, lf.amount_usd
    from cuotas q
    join public.late_fees lf on lf.installment_id = q.id
    where lf.status in ('pending', 'paid')
  ),
  -- Lo que se enseña: lo que sigue sin pagar, o todo lo que vence.
  vistas as (
    select * from piezas where v_todas or not pagada
  ),
  -- Todo lo pendiente, de cualquier fecha: para lo vencido de antes y para
  -- cotejar con el libro.
  pendientes as (
    select i.id as cuota_id, i.user_id, i.due_date as dia,
           i.financed_usd as consumo, i.amount_usd - i.financed_usd as comision, 0::numeric as cargos
    from public.installments i
    join public.charges   c on c.id = i.charge_id
    join public.merchants m on m.id = c.merchant_id
    join public.profiles  p on p.id = i.user_id
    where i.status = 'pending'
      and i.written_off_at is null
      and not i.is_test and not c.is_test and not m.is_test and not p.is_test
    union all
    select i.id, i.user_id, i.due_date, 0, 0, lf.amount_usd
    from public.late_fees lf
    join public.installments i on i.id = lf.installment_id
    join public.charges   c on c.id = i.charge_id
    join public.merchants m on m.id = c.merchant_id
    join public.profiles  p on p.id = i.user_id
    where lf.status = 'pending'
      and i.written_off_at is null
      and not i.is_test and not c.is_test and not m.is_test and not p.is_test
  ),
  -- Cada cifra suelta, redondeada al céntimo ANTES de sumar el total: así el
  -- desglose cierra siempre con su suma, sin un céntimo de diferencia.
  bloques as (
    select b.bloque,
           count(distinct b.cuota_id)       as cuotas,
           count(distinct b.user_id)        as personas,
           round(coalesce(sum(b.consumo), 0), 2)  as consumo_usd,
           round(coalesce(sum(b.comision), 0), 2) as comision_usd,
           round(coalesce(sum(b.cargos), 0), 2)   as cargos_usd
    from (
      select 'periodo' as bloque, cuota_id, user_id, consumo, comision, cargos from vistas
      union all
      select 'pagado', cuota_id, user_id, consumo, comision, cargos from piezas where pagada
      union all
      select 'vencido_antes', cuota_id, user_id, consumo, comision, cargos
      from pendientes where dia < least(p_desde, v_bd)
      union all
      select 'pendiente', cuota_id, user_id, consumo, comision, cargos from pendientes
    ) b
    group by b.bloque
  ),
  por_dia as (
    select d.dia,
           count(distinct v.cuota_id)       as cuotas,
           count(distinct v.user_id)        as personas,
           count(distinct v.merchant_id)    as locales,
           round(coalesce(sum(v.consumo), 0), 2)  as consumo_usd,
           round(coalesce(sum(v.comision), 0), 2) as comision_usd,
           round(coalesce(sum(v.cargos), 0), 2)   as cargos_usd,
           (select count(distinct x.cuota_id) from piezas x
            where x.dia = d.dia and not x.pagada) as cuotas_sin_pagar
    from (select generate_series(p_desde, p_hasta, interval '1 day')::date as dia) d
    left join vistas v on v.dia = d.dia
    group by d.dia
  ),
  por_local as (
    select v.merchant_id, v.local_nombre,
           count(distinct v.cuota_id)       as cuotas,
           count(distinct v.user_id)        as personas,
           round(sum(v.consumo), 2)         as consumo_usd,
           round(sum(v.comision), 2)        as comision_usd,
           round(sum(v.cargos), 2)          as cargos_usd
    from vistas v
    group by v.merchant_id, v.local_nombre
  ),
  por_dia_y_local as (
    select v.dia, v.merchant_id, v.local_nombre,
           count(distinct v.cuota_id)       as cuotas,
           count(distinct v.user_id)        as personas,
           round(sum(v.consumo), 2)         as consumo_usd,
           round(sum(v.comision), 2)        as comision_usd,
           round(sum(v.cargos), 2)          as cargos_usd
    from vistas v
    group by v.dia, v.merchant_id, v.local_nombre
  )
  select jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'hoy', v_hoy,
    'dia_operativo', v_bd,
    'incluye_pagadas', v_todas,
    'periodo', (
      select jsonb_build_object(
        'cuotas', coalesce(max(b.cuotas), 0),
        'personas', coalesce(max(b.personas), 0),
        'locales', (select count(distinct v.merchant_id) from vistas v),
        'consumo_usd', coalesce(max(b.consumo_usd), 0),
        'comision_usd', coalesce(max(b.comision_usd), 0),
        'cargos_usd', coalesce(max(b.cargos_usd), 0),
        'total_usd', coalesce(max(b.consumo_usd + b.comision_usd + b.cargos_usd), 0))
      from bloques b where b.bloque = 'periodo'),
    'pagado', (
      select jsonb_build_object(
        'cuotas', coalesce(max(b.cuotas), 0),
        'personas', coalesce(max(b.personas), 0),
        'consumo_usd', coalesce(max(b.consumo_usd), 0),
        'comision_usd', coalesce(max(b.comision_usd), 0),
        'cargos_usd', coalesce(max(b.cargos_usd), 0),
        'total_usd', coalesce(max(b.consumo_usd + b.comision_usd + b.cargos_usd), 0))
      from bloques b where b.bloque = 'pagado'),
    'vencido_antes', (
      select jsonb_build_object(
        'hasta', least(p_desde, v_bd) - 1,
        'cuotas', coalesce(max(b.cuotas), 0),
        'personas', coalesce(max(b.personas), 0),
        'consumo_usd', coalesce(max(b.consumo_usd), 0),
        'comision_usd', coalesce(max(b.comision_usd), 0),
        'cargos_usd', coalesce(max(b.cargos_usd), 0),
        'total_usd', coalesce(max(b.consumo_usd + b.comision_usd + b.cargos_usd), 0))
      from bloques b where b.bloque = 'vencido_antes'),
    'por_dia', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'dia', d.dia,
        'cuotas', d.cuotas,
        'personas', d.personas,
        'locales', d.locales,
        'consumo_usd', d.consumo_usd,
        'comision_usd', d.comision_usd,
        'cargos_usd', d.cargos_usd,
        'total_usd', d.consumo_usd + d.comision_usd + d.cargos_usd,
        'cuotas_sin_pagar', d.cuotas_sin_pagar,
        'vencido', d.dia < v_bd and d.cuotas_sin_pagar > 0
      ) order by d.dia), '[]'::jsonb)
      from por_dia d),
    'por_local', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'local_id', l.merchant_id,
        'local', l.local_nombre,
        'cuotas', l.cuotas,
        'personas', l.personas,
        'consumo_usd', l.consumo_usd,
        'comision_usd', l.comision_usd,
        'cargos_usd', l.cargos_usd,
        'total_usd', l.consumo_usd + l.comision_usd + l.cargos_usd
      ) order by l.consumo_usd + l.comision_usd + l.cargos_usd desc, l.local_nombre), '[]'::jsonb)
      from por_local l),
    'por_dia_y_local', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'dia', f.dia,
        'local_id', f.merchant_id,
        'local', f.local_nombre,
        'cuotas', f.cuotas,
        'personas', f.personas,
        'consumo_usd', f.consumo_usd,
        'comision_usd', f.comision_usd,
        'cargos_usd', f.cargos_usd,
        'total_usd', f.consumo_usd + f.comision_usd + f.cargos_usd
      ) order by f.dia, f.consumo_usd + f.comision_usd + f.cargos_usd desc, f.local_nombre), '[]'::jsonb)
      from por_dia_y_local f),
    -- Para explicar por qué lo pendiente de todas las fechas puede no ser la
    -- cifra del libro: el libro también lleva los cargos sin cuota (anteriores
    -- al reparto por cuota) y cualquier ajuste manual.
    'cotejo', jsonb_build_object(
      'pendiente_usd', (
        select coalesce(max(b.consumo_usd + b.comision_usd + b.cargos_usd), 0)
        from bloques b where b.bloque = 'pendiente'),
      'cargos_sin_cuota_usd', (
        select round(coalesce(sum(lf.amount_usd), 0), 2)
        from public.late_fees lf
        join public.profiles p on p.id = lf.user_id
        where lf.status = 'pending' and lf.installment_id is null and not p.is_test),
      'libro_usd', round(ledger.balance_by_type('user_receivable'), 2)
    )
  )
  into v_res;

  return v_res;
end;
$fn$;

comment on function public.admin_receivables_by_day(date, date, boolean) is
  'Lo que vence cada día del rango (due_date) y de qué local es: consumo (financed), comisión e IVA y cargos por atraso aparte. Solo lectura, sin cuentas de prueba.';

revoke all on function public.admin_receivables_by_day(date, date, boolean) from public, anon;
grant execute on function public.admin_receivables_by_day(date, date, boolean) to authenticated;
