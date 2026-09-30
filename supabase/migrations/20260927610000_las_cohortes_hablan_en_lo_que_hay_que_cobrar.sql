-- ============================================================================
-- Ronda — Las cohortes hablan en lo que hay que COBRAR (Métricas › Cohortes)
--
-- Lo que pidió Javier el 2026-09-27: «En la pestaña de cohortes hagamos que
-- la métrica "Consumo, sin servicio" sea el consumo + el fee: aquí ya no nos
-- interesa tanto el consumo plano porque estamos cobrando y viendo el
-- rendimiento de los pagos, así que queremos ver el total completo que
-- debemos cobrar. Quizás abajo en pequeño sí podamos mostrar el consumo sin
-- fee».
--
-- Es una excepción aprobada a la regla de no sumar el fee a un total, y SOLO
-- en Cohortes: vale porque es un desglose con sus sumandos a la vista. Por eso
-- el total a cobrar viaja SIEMPRE con su consumo (sin fee) y su service fee
-- (IVA incluido), y cada estado igual.
--
-- Cada cohorte gana una clave, `a_cobrar`: la cuota 1 y la cuota 2 juntas,
-- con la misma forma que una cuota (lo que se cobra con su desglose, sus
-- cinco estados y sus porcentajes) y dos agregados más, `cobrado` (a tiempo +
-- tarde) y `falta` (vencido + por vencer). Las personas de cada parte son
-- personas DISTINTAS (quien tiene las dos cuotas vencidas cuenta una vez), así
-- que no se pueden sumar de las dos cuotas: salen de la misma pasada por
-- `metricas.cuotas` que el resto, en `metricas.cohorte_cobro`.
--
-- No se quita ninguna clave: `financed_usd`, `volvio_*` y el resto siguen
-- donde estaban. `admin_metricas_cohortes` y `admin_metricas_cohorte` no
-- cambian: las dos leen `metricas.cohorte_json`, que es lo que se redefine.
--
-- Va después de 20260927530000 (las cohortes) y no cambia la firma ni el tipo
-- de nada de ella: si 530000 se vuelve a aplicar, deja la versión anterior,
-- coherente pero sin `a_cobrar`, y basta con volver a aplicar esta.
--
-- Las columnas se llaman `_usd` pero el dinero es EURO.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Lo que se cobra en cada cohorte, por cuota y en las dos juntas
-- ---------------------------------------------------------------------------
-- Una fila por semana, cuota y estado de hoy, como `metricas.cohorte_cuotas`,
-- y además las filas con `sequence` nulo: las dos cuotas juntas (lo que hay
-- que cobrar de la semana). `estado` nulo es la cuota (o el total) entera. Lo
-- mismo partido por local (`por_local`).
--
-- `personas_cobrado` y `personas_falta` son las personas distintas con alguna
-- cuota pagada (a tiempo o tarde) o viva (vencida o por vencer) en la fila:
-- tienen sentido en las filas con `estado` nulo.

create or replace function metricas.cohorte_cobro(p_merchant_id uuid default null)
returns table (
  semana            date,
  por_local         boolean,
  merchant_id       uuid,
  sequence          smallint,
  estado            text,
  cuotas            integer,
  personas          integer,
  payable_usd       numeric,
  financed_usd      numeric,
  fee_usd           numeric,
  vence_desde       date,
  vence_hasta       date,
  personas_cobrado  integer,
  personas_falta    integer
)
language sql
stable
as $$
  select q.semana,
         grouping(q.merchant_id) = 0,
         case when grouping(q.merchant_id) = 0 then q.merchant_id end,
         case when grouping(q.sequence) = 0 then q.sequence end,
         case when grouping(q.estado_hoy) = 0 then q.estado_hoy end,
         count(*)::integer,
         count(distinct q.user_id)::integer,
         coalesce(sum(q.payable_usd), 0)::numeric,
         coalesce(sum(q.financed_usd), 0)::numeric,
         coalesce(sum(q.fee_usd), 0)::numeric,
         min(q.due_date),
         max(q.due_date),
         (count(distinct q.user_id) filter (where q.estado_hoy in ('a_tiempo', 'tarde')))::integer,
         (count(distinct q.user_id) filter (where q.estado_hoy in ('vencida', 'por_vencer')))::integer
  from metricas.cuotas q
  where p_merchant_id is null or q.merchant_id = p_merchant_id
  group by grouping sets (
    (q.semana, q.sequence),
    (q.semana, q.sequence, q.estado_hoy),
    (q.semana),
    (q.semana, q.estado_hoy),
    (q.semana, q.merchant_id, q.sequence),
    (q.semana, q.merchant_id, q.sequence, q.estado_hoy),
    (q.semana, q.merchant_id),
    (q.semana, q.merchant_id, q.estado_hoy)
  );
$$;

comment on function metricas.cohorte_cobro(uuid) is
  'Lo que se cobra en cada cohorte de consumo, en PAYABLE con su desglose financed + fee: una fila por semana, cuota (sequence nulo = la cuota 1 y la 2 juntas, lo que hay que cobrar de la semana) y estado de hoy (nulo = entera), y lo mismo por local (por_local). personas = count distinct user_id; personas_cobrado / personas_falta = personas distintas con alguna cuota pagada (a tiempo o tarde) / viva (vencida o por vencer). Con p_merchant_id, solo ese local.';

-- `metricas.cohorte_cuotas` se queda con su firma y su forma, pero sale de la
-- misma cuenta: una sola definición de lo que se cobra en cada cuota.
create or replace function metricas.cohorte_cuotas(p_merchant_id uuid default null)
returns table (
  semana        date,
  por_local     boolean,
  merchant_id   uuid,
  sequence      smallint,
  estado        text,
  cuotas        integer,
  personas      integer,
  payable_usd   numeric,
  financed_usd  numeric,
  fee_usd       numeric,
  vence_desde   date,
  vence_hasta   date
)
language sql
stable
as $$
  select x.semana, x.por_local, x.merchant_id, x.sequence, x.estado, x.cuotas, x.personas,
         x.payable_usd, x.financed_usd, x.fee_usd, x.vence_desde, x.vence_hasta
  from metricas.cohorte_cobro(p_merchant_id) x
  where x.sequence is not null;
$$;

comment on function metricas.cohorte_cuotas(uuid) is
  'Las cuotas de cada cohorte de consumo: una fila por semana, número de cuota y estado de hoy (estado nulo = la cuota entera), y lo mismo por local (por_local). Lo que se cobra en PAYABLE con su desglose financed + fee; personas = count distinct user_id. Sale de metricas.cohorte_cobro (sin las filas de las dos cuotas juntas). Con p_merchant_id, solo ese local.';

-- ---------------------------------------------------------------------------
-- 2. El JSON de una cohorte, con lo que hay que cobrar
-- ---------------------------------------------------------------------------
-- El mismo objeto de 20260927530000 y, además, `a_cobrar`:
--
--   a_cobrar: { cuotas, personas, payable_usd, financed_usd, fee_usd,
--               vence_desde, vence_hasta,
--               cobrado_pct, a_tiempo_pct, vencido_pct, falta_pct,
--               cobrado: { cuotas, personas, payable_usd, financed_usd, fee_usd },
--               falta:   { cuotas, personas, payable_usd, financed_usd, fee_usd },
--               estados: { a_tiempo, tarde, vencida, por_vencer, perdida } }
--
-- payable = la cuota 1 + la cuota 2 (el total a cobrar); financed = su
-- consumo, sin fee; fee = payable − financed (el service fee con su IVA).
-- cobrado = a tiempo + tarde; falta = vencida + por vencer; lo dado por
-- perdido va aparte, en su estado. Los porcentajes son sobre el total a
-- cobrar. Una semana sin cuotas (no debería existir) lleva todo a cero.

create or replace function metricas.cohorte_json(
  p_merchant_id uuid default null,
  p_semana date default null,
  p_por_local boolean default false
)
returns jsonb
language sql
stable
as $$
  with
  s as (
    select *
    from metricas.cohorte_semanas(p_merchant_id) x
    where x.por_local = p_por_local
      and (p_semana is null or x.semana = p_semana)
  ),
  c as materialized (
    select *
    from metricas.cohorte_cobro(p_merchant_id) x
    where x.por_local = p_por_local
      and (p_semana is null or x.semana = p_semana)
  ),
  -- Por cada cuota (y por las dos juntas, `sequence` nulo): sus cinco estados
  -- y lo cobrado, lo que falta, lo cobrado a tiempo y lo vencido.
  estados as (
    select t.semana, t.merchant_id, t.sequence,
           jsonb_object_agg(e.estado, jsonb_build_object(
             'cuotas',       coalesce(x.cuotas, 0),
             'personas',     coalesce(x.personas, 0),
             'payable_usd',  coalesce(x.payable_usd, 0),
             'financed_usd', coalesce(x.financed_usd, 0),
             'fee_usd',      coalesce(x.fee_usd, 0)
           ))                                                                                  as obj,
           coalesce(sum(x.payable_usd)  filter (where e.estado in ('a_tiempo', 'tarde')), 0)        as cobrado,
           coalesce(sum(x.financed_usd) filter (where e.estado in ('a_tiempo', 'tarde')), 0)        as cobrado_financed,
           coalesce(sum(x.fee_usd)      filter (where e.estado in ('a_tiempo', 'tarde')), 0)        as cobrado_fee,
           coalesce(sum(x.cuotas)       filter (where e.estado in ('a_tiempo', 'tarde')), 0)        as cobrado_cuotas,
           coalesce(sum(x.payable_usd)  filter (where e.estado in ('vencida', 'por_vencer')), 0)    as falta,
           coalesce(sum(x.financed_usd) filter (where e.estado in ('vencida', 'por_vencer')), 0)    as falta_financed,
           coalesce(sum(x.fee_usd)      filter (where e.estado in ('vencida', 'por_vencer')), 0)    as falta_fee,
           coalesce(sum(x.cuotas)       filter (where e.estado in ('vencida', 'por_vencer')), 0)    as falta_cuotas,
           coalesce(sum(x.payable_usd)  filter (where e.estado = 'a_tiempo'), 0)                    as a_tiempo,
           coalesce(sum(x.payable_usd)  filter (where e.estado = 'vencida'), 0)                     as vencido
    from c t
    cross join unnest(array['a_tiempo', 'tarde', 'vencida', 'por_vencer', 'perdida']) e(estado)
    left join c x
      on x.semana = t.semana
     and x.merchant_id is not distinct from t.merchant_id
     and x.sequence is not distinct from t.sequence
     and x.estado = e.estado
    where t.estado is null
    group by t.semana, t.merchant_id, t.sequence
  ),
  cuotas as (
    select t.semana, t.merchant_id,
           jsonb_agg(jsonb_build_object(
             'sequence',     t.sequence,
             'vence_desde',  t.vence_desde,
             'vence_hasta',  t.vence_hasta,
             'cuotas',       t.cuotas,
             'personas',     t.personas,
             'payable_usd',  t.payable_usd,
             'financed_usd', t.financed_usd,
             'fee_usd',      t.fee_usd,
             'cobrado_pct',  round(100 * e.cobrado  / nullif(t.payable_usd, 0), 2),
             'a_tiempo_pct', round(100 * e.a_tiempo / nullif(t.payable_usd, 0), 2),
             'vencido_pct',  round(100 * e.vencido  / nullif(t.payable_usd, 0), 2),
             'estados',      e.obj
           ) order by t.sequence) as arr
    from c t
    join estados e
      on e.semana = t.semana
     and e.merchant_id is not distinct from t.merchant_id
     and e.sequence = t.sequence
    where t.estado is null
      and t.sequence is not null
    group by t.semana, t.merchant_id
  ),
  -- Lo que hay que cobrar de la semana: las dos cuotas juntas.
  total as (
    select t.semana, t.merchant_id,
           jsonb_build_object(
             'cuotas',       t.cuotas,
             'personas',     t.personas,
             'payable_usd',  t.payable_usd,
             'financed_usd', t.financed_usd,
             'fee_usd',      t.fee_usd,
             'vence_desde',  t.vence_desde,
             'vence_hasta',  t.vence_hasta,
             'cobrado_pct',  round(100 * e.cobrado  / nullif(t.payable_usd, 0), 2),
             'a_tiempo_pct', round(100 * e.a_tiempo / nullif(t.payable_usd, 0), 2),
             'vencido_pct',  round(100 * e.vencido  / nullif(t.payable_usd, 0), 2),
             'falta_pct',    round(100 * e.falta    / nullif(t.payable_usd, 0), 2),
             'cobrado', jsonb_build_object(
               'cuotas',       e.cobrado_cuotas,
               'personas',     t.personas_cobrado,
               'payable_usd',  e.cobrado,
               'financed_usd', e.cobrado_financed,
               'fee_usd',      e.cobrado_fee
             ),
             'falta', jsonb_build_object(
               'cuotas',       e.falta_cuotas,
               'personas',     t.personas_falta,
               'payable_usd',  e.falta,
               'financed_usd', e.falta_financed,
               'fee_usd',      e.falta_fee
             ),
             'estados', e.obj
           ) as obj
    from c t
    join estados e
      on e.semana = t.semana
     and e.merchant_id is not distinct from t.merchant_id
     and e.sequence is null
    where t.estado is null
      and t.sequence is null
  ),
  cero as (
    select jsonb_build_object('cuotas', 0, 'personas', 0, 'payable_usd', 0, 'financed_usd', 0, 'fee_usd', 0) as p
  ),
  total_vacio as (
    select jsonb_build_object(
             'cuotas', 0, 'personas', 0, 'payable_usd', 0, 'financed_usd', 0, 'fee_usd', 0,
             'vence_desde', null, 'vence_hasta', null,
             'cobrado_pct', null, 'a_tiempo_pct', null, 'vencido_pct', null, 'falta_pct', null,
             'cobrado', z.p, 'falta', z.p,
             'estados', (select jsonb_object_agg(e, z.p)
                         from unnest(array['a_tiempo', 'tarde', 'vencida', 'por_vencer', 'perdida']) e)
           ) as obj
    from cero z
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'semana',                  s.semana,
             'hasta',                   s.semana + 6,
             'en_curso',                s.semana = metricas.lunes(metricas.hoy()),
             'consumos',                s.consumos,
             'financed_usd',            s.financed_usd,
             'personas',                s.personas,
             'volvio_financed_usd',     s.volvio_financed_usd,
             'volvio_pct',              round(100 * s.volvio_financed_usd / nullif(s.financed_usd, 0), 2),
             'a_tiempo_financed_usd',   s.a_tiempo_financed_usd,
             'tarde_financed_usd',      s.tarde_financed_usd,
             'vencido_financed_usd',    s.vencido_financed_usd,
             'por_vencer_financed_usd', s.por_vencer_financed_usd,
             'perdido_financed_usd',    s.perdido_financed_usd,
             'personas_con_vencido',    s.personas_con_vencido,
             'a_cobrar',                coalesce(tt.obj, (select v.obj from total_vacio v)),
             'cuotas',                  coalesce(q.arr, '[]'::jsonb)
           )
           || case when p_por_local
                   then jsonb_build_object('merchant_id', s.merchant_id, 'nombre', m.name)
                   else '{}'::jsonb end
           order by s.semana desc, m.name, s.merchant_id
         ), '[]'::jsonb)
  from s
  left join cuotas q
    on q.semana = s.semana
   and q.merchant_id is not distinct from s.merchant_id
  left join total tt
    on tt.semana = s.semana
   and tt.merchant_id is not distinct from s.merchant_id
  left join public.merchants m on m.id = s.merchant_id;
$$;

comment on function metricas.cohorte_json(uuid, date, boolean) is
  'El JSON de las cohortes de consumo (un array, de la semana más reciente a la más vieja): el mismo objeto en admin_metricas_cohortes y admin_metricas_cohorte. Con p_semana, solo esa; con p_por_local, una por semana y local (con merchant_id y nombre). Lo de la cohorte en consumo en FINANCED (financed_usd, volvio_*…); cada cuota por separado en PAYABLE con financed_usd y fee_usd; y a_cobrar: la cuota 1 + la 2 (el total a cobrar, excepción aprobada por Javier solo en Cohortes) SIEMPRE con su desglose financed + fee, sus cinco estados, cobrado (a tiempo + tarde) y falta (vencido + por vencer).';

-- ---------------------------------------------------------------------------
-- 3. Permisos y descripciones
-- ---------------------------------------------------------------------------

revoke all on function metricas.cohorte_cobro(uuid) from public, anon, authenticated;
revoke all on function metricas.cohorte_cuotas(uuid) from public, anon, authenticated;
revoke all on function metricas.cohorte_json(uuid, date, boolean) from public, anon, authenticated;

comment on function public.admin_metricas_cohortes(uuid) is
  'Métricas › Cohortes: todas las cohortes de consumo (semana de lunes a domingo) con lo que hay que cobrar de ellas (a_cobrar: la cuota 1 + la 2 con su desglose consumo + service fee, cobrado, falta y sus estados), su consumo sin fee, personas y sus cuotas 1 y 2 por estado, en payable con desglose. Con p_merchant_id, solo ese local. Solo personal de Helios.';

comment on function public.admin_metricas_cohorte(date, uuid) is
  'Métricas › Cohortes: el detalle de la cohorte de una semana (p_semana se lleva a su lunes): lo que hay que cobrar (a_cobrar, con su desglose), consumo sin fee, personas, las cuotas 1 y 2 por estado (payable con desglose), la curva de cobro de cada cuota por días desde que vence frente a la media de las cuatro semanas anteriores, y el reparto por local. Con p_merchant_id, solo ese local. Solo personal de Helios.';
