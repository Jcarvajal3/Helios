-- ============================================================================
-- Ronda — Las cohortes de consumo, semana a semana (Métricas › Cohortes)
--
-- Lo que pidió Javier: seguir lo consumido en una semana concreta hasta
-- cobrar sus dos cuotas. Cuánto se cobra en la cuota 1 y en la 2, cuánto se
-- ha cobrado ya (a tiempo o tarde), cuánto está vencido, por vencer o dado
-- por perdido, y cómo se fue cobrando cada cuota día a día desde que vence.
--
-- Una COHORTE es el conjunto de consumos cuyo día operativo cae en una semana
-- (de lunes a domingo), con sus cuotas 1 y 2 (CONTRATOS §2). Todo sale de
-- `metricas.consumos` y `metricas.cuotas` (20260927500000): aquí no se vuelve
-- a decidir qué es una cuota vencida ni qué es pagar a tiempo.
--
-- Lo que añade, en el esquema `metricas` (prefijo `cohorte_`):
--
--   metricas.cohorte_semanas(local)  una fila por cohorte (y por cohorte y
--                                    local): consumo, consumos, personas y en
--                                    qué acabó el consumo (financed).
--   metricas.cohorte_cuotas(local)   una fila por cohorte, cuota y estado (y
--                                    por local): lo que se cobra, en payable
--                                    con su desglose financed + fee.
--   metricas.cohorte_curva(local)    el % cobrado de cada cuota según los días
--                                    desde que vence, de −6 a +14.
--   metricas.cohorte_json(...)       el objeto JSON de una cohorte, el mismo
--                                    en la lista y en el detalle.
--
-- Y las dos RPC de la pestaña:
--
--   admin_metricas_cohortes(p_merchant_id)          la lista de todas las
--                                                   cohortes con sus cuotas.
--   admin_metricas_cohorte(p_semana, p_merchant_id) el detalle de una: sus
--                                                   cuotas, sus curvas frente
--                                                   a la media de las cuatro
--                                                   semanas anteriores y el
--                                                   reparto por local.
--
-- La regla del fee: la cuota 1 y la 2 nunca se suman en una cifra. Por eso no
-- hay un «payable» de la cohorte: lo que se cobra va SIEMPRE por cuota, y todo
-- objeto con `payable_usd` trae `financed_usd` y `fee_usd` (= payable −
-- financed). Lo que sí es de la cohorte entera va en consumo (financed): el
-- consumo, lo que ya volvió de él, lo vencido, lo por vencer y lo perdido.
--
-- Las columnas se llaman `_usd` pero el dinero es EURO.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La cohorte entera, en consumo
-- ---------------------------------------------------------------------------
-- Una fila por semana (`por_local = false`, `merchant_id` nulo) y otra por
-- semana y local. Consumo y consumos salen de `metricas.consumos`; personas y
-- el destino del consumo, de `metricas.cuotas`. «Volvió» es la parte de
-- consumo de las cuotas ya pagadas (a tiempo o tarde): financed, sin el
-- servicio, así que sí se puede sumar entre la cuota 1 y la 2.

create or replace function metricas.cohorte_semanas(p_merchant_id uuid default null)
returns table (
  semana                   date,
  por_local                boolean,
  merchant_id              uuid,
  consumos                 integer,
  financed_usd             numeric,
  personas                 integer,
  volvio_financed_usd      numeric,
  a_tiempo_financed_usd    numeric,
  tarde_financed_usd       numeric,
  vencido_financed_usd     numeric,
  por_vencer_financed_usd  numeric,
  perdido_financed_usd     numeric,
  personas_con_vencido     integer
)
language sql
stable
as $$
  with k as (
    select c.semana,
           grouping(c.merchant_id) = 0                              as por_local,
           case when grouping(c.merchant_id) = 0 then c.merchant_id end as merchant_id,
           count(*)::integer                                        as consumos,
           coalesce(sum(c.financed_usd), 0)::numeric                as financed_usd
    from metricas.consumos c
    where p_merchant_id is null or c.merchant_id = p_merchant_id
    group by grouping sets ((c.semana), (c.semana, c.merchant_id))
  ),
  q as (
    select c.semana,
           grouping(c.merchant_id) = 0                              as por_local,
           case when grouping(c.merchant_id) = 0 then c.merchant_id end as merchant_id,
           count(distinct c.user_id)::integer                       as personas,
           coalesce(sum(c.financed_usd) filter (where c.estado_hoy in ('a_tiempo', 'tarde')), 0) as volvio,
           coalesce(sum(c.financed_usd) filter (where c.estado_hoy = 'a_tiempo'), 0)   as a_tiempo,
           coalesce(sum(c.financed_usd) filter (where c.estado_hoy = 'tarde'), 0)      as tarde,
           coalesce(sum(c.financed_usd) filter (where c.estado_hoy = 'vencida'), 0)    as vencido,
           coalesce(sum(c.financed_usd) filter (where c.estado_hoy = 'por_vencer'), 0) as por_vencer,
           coalesce(sum(c.financed_usd) filter (where c.estado_hoy = 'perdida'), 0)    as perdido,
           (count(distinct c.user_id) filter (where c.estado_hoy = 'vencida'))::integer as personas_con_vencido
    from metricas.cuotas c
    where p_merchant_id is null or c.merchant_id = p_merchant_id
    group by grouping sets ((c.semana), (c.semana, c.merchant_id))
  )
  select k.semana,
         k.por_local,
         k.merchant_id,
         k.consumos,
         k.financed_usd,
         coalesce(q.personas, 0),
         coalesce(q.volvio, 0)::numeric,
         coalesce(q.a_tiempo, 0)::numeric,
         coalesce(q.tarde, 0)::numeric,
         coalesce(q.vencido, 0)::numeric,
         coalesce(q.por_vencer, 0)::numeric,
         coalesce(q.perdido, 0)::numeric,
         coalesce(q.personas_con_vencido, 0)
  from k
  left join q
    on q.semana = k.semana
   and q.por_local = k.por_local
   and q.merchant_id is not distinct from k.merchant_id;
$$;

comment on function metricas.cohorte_semanas(uuid) is
  'Las cohortes de consumo (los consumos de una semana de lunes a domingo, por día operativo): una fila por semana (por_local = false) y una por semana y local. Consumo y consumos de metricas.consumos; personas y el destino del consumo (volvió = pagado a tiempo o tarde, vencido, por vencer, perdido) de metricas.cuotas, todo en FINANCED (sin servicio). Con p_merchant_id, solo ese local.';

-- ---------------------------------------------------------------------------
-- 2. Las cuotas de la cohorte, por estado
-- ---------------------------------------------------------------------------
-- Una fila por semana, cuota (1 o 2) y estado de hoy, y una más con
-- `estado` nulo para la cuota entera; lo mismo partido por local. El estado
-- es el de `metricas.cuotas.estado_hoy`: a_tiempo, tarde, vencida,
-- por_vencer o perdida, excluyentes. Lo que se cobra va en PAYABLE, con su
-- desglose financed + fee en la misma fila.

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
  select q.semana,
         grouping(q.merchant_id) = 0,
         case when grouping(q.merchant_id) = 0 then q.merchant_id end,
         q.sequence,
         case when grouping(q.estado_hoy) = 0 then q.estado_hoy end,
         count(*)::integer,
         count(distinct q.user_id)::integer,
         coalesce(sum(q.payable_usd), 0)::numeric,
         coalesce(sum(q.financed_usd), 0)::numeric,
         coalesce(sum(q.fee_usd), 0)::numeric,
         min(q.due_date),
         max(q.due_date)
  from metricas.cuotas q
  where p_merchant_id is null or q.merchant_id = p_merchant_id
  group by grouping sets (
    (q.semana, q.sequence),
    (q.semana, q.sequence, q.estado_hoy),
    (q.semana, q.merchant_id, q.sequence),
    (q.semana, q.merchant_id, q.sequence, q.estado_hoy)
  );
$$;

comment on function metricas.cohorte_cuotas(uuid) is
  'Las cuotas de cada cohorte de consumo: una fila por semana, número de cuota y estado de hoy (estado nulo = la cuota entera), y lo mismo por local (por_local). Lo que se cobra en PAYABLE con su desglose financed + fee; personas = count distinct user_id. vence_desde / vence_hasta: el primer y el último vencimiento. Con p_merchant_id, solo ese local.';

-- ---------------------------------------------------------------------------
-- 3. La curva de cobro de cada cuota
-- ---------------------------------------------------------------------------
-- Para cada cohorte y cuota, qué parte de lo que se cobra (payable) estaba
-- pagada a cada día desde el vencimiento: día 0 es el día en que vence, −3
-- tres días antes, +7 una semana después. Cada cuota se mide contra SU
-- vencimiento (los consumos de una semana vencen en días distintos), con el
-- día del pago que usa todo el panel: `pagada_dia`, el día operativo en que
-- se aprobó. Así el punto `dia = gracia` es exactamente lo cobrado a tiempo.
--
-- `cerrado`: ese día ya terminó para TODAS las cuotas de la cohorte (el
-- último vencimiento + dia < hoy). Un punto sin cerrar todavía puede subir, y
-- el panel no lo pinta. Un pago de antes de `p_desde` cuenta desde `p_desde`.

create or replace function metricas.cohorte_curva(
  p_merchant_id uuid default null,
  p_desde integer default -6,
  p_hasta integer default 14
)
returns table (
  semana               date,
  sequence             smallint,
  dia                  integer,
  payable_usd          numeric,
  cobrado_payable_usd  numeric,
  cobrado_pct          numeric,
  cerrado              boolean
)
language sql
stable
as $$
  with base as (
    select q.semana, q.sequence, q.payable_usd, q.due_date,
           case when q.status = 'paid' then q.pagada_dia - q.due_date end as dia_pago
    from metricas.cuotas q
    where p_merchant_id is null or q.merchant_id = p_merchant_id
  ),
  tot as (
    select b.semana, b.sequence, sum(b.payable_usd) as total, max(b.due_date) as ultimo
    from base b
    group by b.semana, b.sequence
  ),
  pagos as (
    select b.semana, b.sequence, greatest(b.dia_pago, p_desde) as dia, sum(b.payable_usd) as cobrado
    from base b
    where b.dia_pago is not null and b.dia_pago <= p_hasta
    group by b.semana, b.sequence, greatest(b.dia_pago, p_desde)
  )
  select t.semana,
         t.sequence,
         g.dia,
         t.total::numeric,
         (sum(coalesce(p.cobrado, 0)) over w)::numeric,
         round(100 * (sum(coalesce(p.cobrado, 0)) over w) / nullif(t.total, 0), 2),
         t.ultimo + g.dia < metricas.hoy()
  from tot t
  cross join generate_series(p_desde, p_hasta) g(dia)
  left join pagos p on p.semana = t.semana and p.sequence = t.sequence and p.dia = g.dia
  window w as (partition by t.semana, t.sequence order by g.dia rows between unbounded preceding and current row);
$$;

comment on function metricas.cohorte_curva(uuid, integer, integer) is
  'La curva de cobro de cada cuota de cada cohorte: para cada día desde el vencimiento (p_desde..p_hasta; 0 = el día en que vence), la parte de lo que se cobra (payable) ya pagada, con el día del pago de siempre (pagada_dia, el de la aprobación). cerrado = ese día ya terminó para todas las cuotas de la cohorte. En dia = helios_on_time_grace_days() es lo cobrado a tiempo.';

-- ---------------------------------------------------------------------------
-- 4. El JSON de una cohorte
-- ---------------------------------------------------------------------------
-- El mismo objeto para la lista (todas las semanas) y para el detalle (una
-- semana, entera o partida por local): así la lista y el detalle no pueden
-- decir cosas distintas de la misma semana. Devuelve un array, de la semana
-- más reciente a la más vieja (y por nombre de local).
--
-- Cada cohorte:
--   semana, hasta, en_curso, [merchant_id, nombre], consumos, financed_usd,
--   personas, volvio_financed_usd, volvio_pct, a_tiempo_financed_usd,
--   tarde_financed_usd, vencido_financed_usd, por_vencer_financed_usd,
--   perdido_financed_usd, personas_con_vencido, cuotas[]
-- Cada cuota (1 y 2, nunca sumadas):
--   sequence, vence_desde, vence_hasta, cuotas, personas, payable_usd,
--   financed_usd, fee_usd, cobrado_pct, a_tiempo_pct, vencido_pct,
--   estados { a_tiempo, tarde, vencida, por_vencer, perdida } con
--   { cuotas, personas, payable_usd, financed_usd, fee_usd } (los cinco
--   siempre, a cero si no hay).

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
    from metricas.cohorte_cuotas(p_merchant_id) x
    where x.por_local = p_por_local
      and (p_semana is null or x.semana = p_semana)
  ),
  estados as (
    select t.semana, t.merchant_id, t.sequence,
           jsonb_object_agg(e.estado, jsonb_build_object(
             'cuotas',       coalesce(x.cuotas, 0),
             'personas',     coalesce(x.personas, 0),
             'payable_usd',  coalesce(x.payable_usd, 0),
             'financed_usd', coalesce(x.financed_usd, 0),
             'fee_usd',      coalesce(x.fee_usd, 0)
           ))                                                                      as obj,
           coalesce(sum(x.payable_usd) filter (where e.estado in ('a_tiempo', 'tarde')), 0) as cobrado,
           coalesce(sum(x.payable_usd) filter (where e.estado = 'a_tiempo'), 0)            as a_tiempo,
           coalesce(sum(x.payable_usd) filter (where e.estado = 'vencida'), 0)             as vencido
    from c t
    cross join unnest(array['a_tiempo', 'tarde', 'vencida', 'por_vencer', 'perdida']) e(estado)
    left join c x
      on x.semana = t.semana
     and x.merchant_id is not distinct from t.merchant_id
     and x.sequence = t.sequence
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
    group by t.semana, t.merchant_id
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
  left join public.merchants m on m.id = s.merchant_id;
$$;

comment on function metricas.cohorte_json(uuid, date, boolean) is
  'El JSON de las cohortes de consumo (un array, de la semana más reciente a la más vieja): el mismo objeto en admin_metricas_cohortes y admin_metricas_cohorte. Con p_semana, solo esa; con p_por_local, una por semana y local (con merchant_id y nombre). Lo de la cohorte entera en FINANCED; cada cuota por separado en PAYABLE con financed_usd y fee_usd, nunca la 1 y la 2 sumadas.';

-- ---------------------------------------------------------------------------
-- 5. Permisos del esquema
-- ---------------------------------------------------------------------------

revoke all on function metricas.cohorte_semanas(uuid) from public, anon, authenticated;
revoke all on function metricas.cohorte_cuotas(uuid) from public, anon, authenticated;
revoke all on function metricas.cohorte_curva(uuid, integer, integer) from public, anon, authenticated;
revoke all on function metricas.cohorte_json(uuid, date, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. La lista: admin_metricas_cohortes
-- ---------------------------------------------------------------------------
-- Todas las cohortes, de la más reciente a la más vieja, con sus dos cuotas
-- por estado. No depende de la semana elegida: es la lista entre la que se
-- elige. Con p_merchant_id, solo lo de ese local.
--
--   { hoy, gracia_dias, semana_en_curso, local, cohortes: [ cohorte… ] }

create or replace function public.admin_metricas_cohortes(p_merchant_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy date := metricas.hoy();
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'hoy',             v_hoy,
    'gracia_dias',     public.helios_on_time_grace_days(),
    'semana_en_curso', metricas.lunes(v_hoy),
    'local',           p_merchant_id,
    'cohortes',        metricas.cohorte_json(p_merchant_id, null, false)
  );
end;
$$;

comment on function public.admin_metricas_cohortes(uuid) is
  'Métricas › Cohortes: todas las cohortes de consumo (semana de lunes a domingo) con su consumo, personas, lo que volvió del consumo y sus cuotas 1 y 2 por estado, en payable con desglose. Con p_merchant_id, solo ese local. Solo personal de Helios.';

revoke all on function public.admin_metricas_cohortes(uuid) from public, anon;
grant execute on function public.admin_metricas_cohortes(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. El detalle: admin_metricas_cohorte
-- ---------------------------------------------------------------------------
-- Una cohorte: la semana elegida (llevada a su lunes; una semana futura se
-- queda en la de hoy).
--
--   { semana: {desde, hasta, en_curso}, hoy, gracia_dias, local,
--     cohorte: cohorte | null,
--     curvas: [ { sequence, semanas_media: [lunes…],
--                 dias: [ { dia, esta_pct, media_pct, semanas_en_media } ] } ],
--     por_local: [ cohorte con merchant_id y nombre ] }
--
-- La curva de esta semana solo trae los días ya cerrados (`esta_pct` nulo en
-- los demás). La media es la de las cohortes de las cuatro semanas anteriores
-- que tengan esa cuota (`semanas_media`), cada una con el mismo peso, y solo
-- en los días que TODAS ellas ya cerraron (`media_pct` nulo en los demás;
-- `semanas_en_media` dice cuántas lo cerraron): así la media nunca cambia de
-- semanas a mitad de la curva.

create or replace function public.admin_metricas_cohorte(p_semana date, p_merchant_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy    date := metricas.hoy();
  v_lunes  date;
  v_curvas jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_lunes := least(metricas.lunes(coalesce(p_semana, v_hoy)), metricas.lunes(v_hoy));

  with cv as materialized (
    select *
    from metricas.cohorte_curva(p_merchant_id)
    where semana between v_lunes - 28 and v_lunes
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'sequence', n.sequence,
           'semanas_media', coalesce((
             select jsonb_agg(distinct p.semana order by p.semana desc)
             from cv p
             where p.sequence = n.sequence and p.semana < v_lunes
           ), '[]'::jsonb),
           'dias', (
             select jsonb_agg(jsonb_build_object(
                      'dia', g.dia,
                      'esta_pct', (
                        select e.cobrado_pct from cv e
                        where e.semana = v_lunes and e.sequence = n.sequence
                          and e.dia = g.dia and e.cerrado
                      ),
                      'media_pct', m.media_pct,
                      'semanas_en_media', m.cerradas
                    ) order by g.dia)
             from generate_series(-6, 14) g(dia)
             cross join lateral (
               select count(*)::integer as cerradas,
                      -- Solo cuando TODAS las semanas de la media cerraron ese
                      -- día: si la media cambiara de semanas a mitad de la
                      -- curva, bajaría sin que nadie dejara de pagar.
                      case when count(*) = n.previas and n.previas > 0
                           then round(avg(p.cobrado_pct), 2) end as media_pct
               from cv p
               where p.semana < v_lunes and p.sequence = n.sequence
                 and p.dia = g.dia and p.cerrado
             ) m
           )
         ) order by n.sequence), '[]'::jsonb)
    into v_curvas
  from (
    select s.sequence,
           (select count(distinct p.semana)::integer from cv p
            where p.sequence = s.sequence and p.semana < v_lunes) as previas
    from (values (1::smallint), (2::smallint)) s(sequence)
  ) n;

  return jsonb_build_object(
    'semana', jsonb_build_object(
      'desde',    v_lunes,
      'hasta',    v_lunes + 6,
      'en_curso', v_lunes = metricas.lunes(v_hoy)
    ),
    'hoy',         v_hoy,
    'gracia_dias', public.helios_on_time_grace_days(),
    'local',       p_merchant_id,
    'cohorte',     metricas.cohorte_json(p_merchant_id, v_lunes, false) -> 0,
    'curvas',      v_curvas,
    'por_local',   metricas.cohorte_json(p_merchant_id, v_lunes, true)
  );
end;
$$;

comment on function public.admin_metricas_cohorte(date, uuid) is
  'Métricas › Cohortes: el detalle de la cohorte de una semana (p_semana se lleva a su lunes): consumo, personas, lo que volvió, las cuotas 1 y 2 por estado (payable con desglose), la curva de cobro de cada cuota por días desde que vence frente a la media de las cuatro semanas anteriores, y el reparto por local. Con p_merchant_id, solo ese local. Solo personal de Helios.';

revoke all on function public.admin_metricas_cohorte(date, uuid) from public, anon;
grant execute on function public.admin_metricas_cohorte(date, uuid) to authenticated;
