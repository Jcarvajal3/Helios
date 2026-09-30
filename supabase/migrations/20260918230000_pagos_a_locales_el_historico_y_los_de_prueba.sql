-- ============================================================================
-- Ronda — Pagos a locales: el histórico, y los locales de prueba dentro
--
-- Dos huecos de la pantalla de pagos a locales, y los dos son de datos que ya
-- existen en la base y que nadie leía.
--
-- ---------------------------------------------------------------------------
-- 1. Las transferencias no se podían mirar
-- ---------------------------------------------------------------------------
-- Cada pago a un local escribe una fila en `merchant_payouts` —importe, medio,
-- referencia, fecha real del banco, comprobante, quién lo registró— y una fila
-- por liquidación cubierta en `merchant_payout_items`. Desde agosto. No había
-- una sola función que los leyera: el panel solo sabía CREARLOS. Lo único que
-- se veía de todo eso era «última transferencia: día e importe», en una
-- columna de la tabla.
--
-- Así que la pregunta más normal del mundo —«¿qué le hemos pagado a este local
-- y qué cubrió cada pago?»— se contestaba en el libro contable o no se
-- contestaba.
--
-- ---------------------------------------------------------------------------
-- 2. Un local de prueba no tenía dónde verse su deuda
-- ---------------------------------------------------------------------------
-- `not m.is_test` dejaba a los locales de prueba fuera de la pantalla entera,
-- y con ellos la deuda que se les debe. Y esa deuda es real aunque no cuente
-- para el negocio: alguien la tiene que mirar.
--
-- La regla del panel no es «los de prueba no se ven», es **«los de prueba no
-- suman»**, y en Consumos ya está resuelta así desde hace tiempo: la fila sale
-- en la tabla con su etiqueta y se queda fuera de las cifras de arriba. Estas
-- funciones pasan a devolverlos marcados con `is_test`, y quien pinta decide;
-- los totales por cierre vienen partidos en dos —lo real y lo de prueba— para
-- que nadie tenga que sumar restando.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Lo que se le debe a cada local, con los de prueba marcados
-- ---------------------------------------------------------------------------
-- Copiada de 20260911180000_las_cuentas_de_prueba_no_cuentan.sql salvo el
-- bloque marcado NUEVO.

create or replace function public.admin_merchant_payables()
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.total_pending_usd desc), '[]'::jsonb)
  into v_rows
  from (
    select
      m.id     as merchant_id,
      m.name   as merchant_name,
      m.tax_id,
      -- NUEVO (2026-09-18): el local de prueba entra, marcado.
      --
      -- Antes había aquí un `not m.is_test` que lo dejaba fuera de la
      -- pantalla y se llevaba por delante su deuda. Lo que no puede es SUMAR
      -- en las cifras del negocio, y eso lo decide quien pinta —igual que en
      -- Consumos—, no una fila que no llega.
      m.is_test,
      o.*
    from public.merchants m
    cross join lateral public.helios_settlement_outlook(m.id) o
    where o.accrued_usd > 0 or o.upcoming_usd > 0
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_merchant_payables() from public, anon;
grant execute on function public.admin_merchant_payables() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Los cierres, con lo de prueba aparte
-- ---------------------------------------------------------------------------
-- Copiada de 20260918100000 salvo los totales, que ahora vienen partidos.

create or replace function public.admin_settlement_runs()
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.run_date desc), '[]'::jsonb)
  into v_rows
  from (
    with por_cierre as (
      select
        public.helios_settlement_run_for(
          coalesce(s.due_date, s.business_date)
        )                                                                as run_date,
        sum(s.amount_usd)      filter (where not m.is_test)              as generado_usd,
        sum(s.paid_usd)        filter (where not m.is_test)              as transferido_usd,
        sum(s.amount_usd - s.paid_usd) filter (where not m.is_test)      as pendiente_usd,
        count(*)               filter (where not m.is_test)              as lineas,
        count(distinct s.merchant_id) filter (where not m.is_test)       as comercios,
        -- Lo de prueba, contado aparte y nunca mezclado.
        sum(s.amount_usd - s.paid_usd) filter (where m.is_test)          as pendiente_prueba_usd,
        count(*)               filter (where m.is_test)                  as lineas_prueba,
        min(coalesce(s.due_date, s.business_date))                       as primer_vencimiento,
        max(coalesce(s.due_date, s.business_date))                       as ultimo_vencimiento
      from public.settlements s
      join public.merchants m on m.id = s.merchant_id
      group by 1
    )
    select
      c.run_date,
      coalesce(c.generado_usd, 0)          as generado_usd,
      coalesce(c.transferido_usd, 0)       as transferido_usd,
      coalesce(c.pendiente_usd, 0)         as pendiente_usd,
      coalesce(c.lineas, 0)::int           as lineas,
      coalesce(c.comercios, 0)::int        as comercios,
      coalesce(c.pendiente_prueba_usd, 0)  as pendiente_prueba_usd,
      coalesce(c.lineas_prueba, 0)::int    as lineas_prueba,
      c.primer_vencimiento,
      c.ultimo_vencimiento,
      c.run_date = public.helios_next_settlement_run(now()) as is_next,
      c.run_date < public.helios_next_settlement_run(now()) as is_past
    from por_cierre c
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_settlement_runs() from public, anon;
grant execute on function public.admin_settlement_runs() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Un cierre, comercio a comercio, con los de prueba marcados
-- ---------------------------------------------------------------------------

create or replace function public.admin_run_payables(p_run_date date)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  if p_run_date is null then
    raise exception 'Falta el cierre' using errcode = '22023';
  end if;

  select coalesce(
           jsonb_agg(to_jsonb(q) order by q.pendiente_usd desc, q.generado_usd desc),
           '[]'::jsonb
         )
  into v_rows
  from (
    select
      m.id                                        as merchant_id,
      m.name                                      as merchant_name,
      m.tax_id,
      m.is_test,
      sum(s.amount_usd)                           as generado_usd,
      sum(s.paid_usd)                             as transferido_usd,
      sum(s.amount_usd - s.paid_usd)              as pendiente_usd,
      count(*)::int                               as lineas,
      min(coalesce(s.due_date, s.business_date))  as primer_vencimiento
    from public.settlements s
    join public.merchants m on m.id = s.merchant_id
    where public.helios_settlement_run_for(
            coalesce(s.due_date, s.business_date)
          ) = p_run_date
    group by 1, 2, 3, 4
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_run_payables(date) from public, anon;
grant execute on function public.admin_run_payables(date) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. El histórico de transferencias
-- ---------------------------------------------------------------------------
/**
 * Todas las transferencias hechas a locales, de la más reciente a la más
 * vieja, con filtros.
 *
 * `paid_on` manda sobre `business_date` para ordenar y para filtrar: la
 * pregunta es «¿qué salió del banco en esta semana?», y esa fecha es la que se
 * coteja contra el extracto. `business_date` —cuándo se registró en el panel—
 * viaja al lado porque las dos importan cuando alguien registra el lunes lo
 * del viernes.
 *
 * Cada fila trae cuántas liquidaciones cubrió y entre qué vencimientos, que es
 * lo que deja leer la tabla sin abrir nada.
 */
create or replace function public.admin_merchant_payouts(
  p_merchant_id uuid     default null,
  p_from        date     default null,
  p_to          date     default null,
  p_method      text     default null,
  p_limit       integer  default 200
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(
           jsonb_agg(to_jsonb(q) order by q.paid_on desc, q.created_at desc),
           '[]'::jsonb
         )
  into v_rows
  from (
    select
      p.id,
      p.merchant_id,
      m.name                             as merchant_name,
      m.is_test,
      coalesce(p.paid_on, p.business_date) as paid_on,
      p.business_date,
      p.created_at,
      p.amount_usd,
      p.amount_ves,
      p.fx_rate,
      p.method,
      p.reference,
      p.note,
      -- La ruta no: el comprobante vive en un bucket privado y la URL se firma
      -- al abrirlo. Aquí solo hace falta saber si lo hay, para el icono.
      p.receipt_path is not null         as tiene_comprobante,
      pa.full_name                       as actor_name,
      coalesce(i.lineas, 0)::int         as lineas,
      i.primer_vencimiento,
      i.ultimo_vencimiento
    from public.merchant_payouts p
    join public.merchants m on m.id = p.merchant_id
    left join public.platform_admins pa on pa.user_id = p.paid_by
    left join lateral (
      select
        count(*)                                            as lineas,
        min(coalesce(s.due_date, s.business_date))          as primer_vencimiento,
        max(coalesce(s.due_date, s.business_date))          as ultimo_vencimiento
      from public.merchant_payout_items it
      join public.settlements s on s.id = it.settlement_id
      where it.payout_id = p.id
    ) i on true
    where (p_merchant_id is null or p.merchant_id = p_merchant_id)
      and (p_from is null or coalesce(p.paid_on, p.business_date) >= p_from)
      and (p_to   is null or coalesce(p.paid_on, p.business_date) <= p_to)
      and (p_method is null or p.method = p_method)
    order by coalesce(p.paid_on, p.business_date) desc, p.created_at desc
    limit least(coalesce(p_limit, 200), 500)
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_merchant_payouts(uuid, date, date, text, integer)
  from public, anon;
grant execute on function public.admin_merchant_payouts(uuid, date, date, text, integer)
  to authenticated;

comment on function public.admin_merchant_payouts(uuid, date, date, text, integer) is
  'Historico de transferencias a locales, por fecha de banco. Filtra por comercio, rango y medio. Incluye los de prueba, marcados.';

-- ---------------------------------------------------------------------------
-- 5. Una transferencia, con lo que cubrió
-- ---------------------------------------------------------------------------
/**
 * La página de un pago.
 *
 * Lo que contesta, y que hasta ahora no se podía contestar sin SQL: qué
 * liquidaciones cubrió, de qué consumo venía cada una, cuánto se aplicó a cada
 * una —que con un pago parcial NO es su importe— y qué le quedó a deber.
 *
 * El número de la orden viaja con cada línea: es como el local llama a la
 * venta cuando llama preguntando.
 */
create or replace function public.admin_payout_detail(p_payout_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_payout public.merchant_payouts%rowtype;
  v_out    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_payout from public.merchant_payouts where id = p_payout_id;

  if not found then
    raise exception 'No existe esa transferencia' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'id',            v_payout.id,
    'paid_on',       coalesce(v_payout.paid_on, v_payout.business_date),
    'business_date', v_payout.business_date,
    'created_at',    v_payout.created_at,
    'amount_usd',    v_payout.amount_usd,
    'amount_ves',    v_payout.amount_ves,
    'fx_rate',       v_payout.fx_rate,
    'method',        v_payout.method,
    'reference',     v_payout.reference,
    'note',          v_payout.note,
    'receipt_path',  v_payout.receipt_path,
    'actor_name',    (
      select pa.full_name from public.platform_admins pa
      where pa.user_id = v_payout.paid_by
    ),
    'merchant', (
      select jsonb_build_object(
        'id', m.id, 'name', m.name, 'tax_id', m.tax_id, 'is_test', m.is_test,
        'status', m.status::text
      )
      from public.merchants m where m.id = v_payout.merchant_id
    ),
    'items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'settlement_id',   s.id,
          'reason',          s.reason,
          'status',          s.status,
          -- Lo que cubrió ESTE pago de esa liquidación. Con un pago parcial no
          -- es su importe, y confundirlos es lo que hacía cuadrar de menos.
          'applied_usd',     it.amount_usd,
          'settlement_usd',  s.amount_usd,
          'paid_usd',        s.paid_usd,
          'pending_usd',     s.amount_usd - s.paid_usd,
          'due_date',        coalesce(s.due_date, s.business_date),
          'run_date',        public.helios_settlement_run_for(
                               coalesce(s.due_date, s.business_date)),
          'charge_id',       c.id,
          'order_number',    c.order_number,
          'charge_date',     c.business_date
        )
        order by coalesce(s.due_date, s.business_date), s.id
      )
      from public.merchant_payout_items it
      join public.settlements s on s.id = it.settlement_id
      left join public.charges c on c.id = s.charge_id
      where it.payout_id = v_payout.id
    ), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;

revoke all on function public.admin_payout_detail(uuid) from public, anon;
grant execute on function public.admin_payout_detail(uuid) to authenticated;

comment on function public.admin_payout_detail(uuid) is
  'Una transferencia a un local con las liquidaciones que cubrio, lo aplicado a cada una y el consumo del que venia.';
