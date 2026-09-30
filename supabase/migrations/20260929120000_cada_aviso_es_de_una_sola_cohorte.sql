-- ============================================================================
-- Ronda — Cada aviso es de una sola cohorte
--
-- Un aviso de cuota sale por persona y fecha de pago, y cubre todo lo que esa
-- persona debe ese día. Con cuotas cada 7 días, la cuota 2 de la semana W y
-- la cuota 1 de la semana W+1 vencen el mismo día: quien consumió las dos
-- semanas recibe UN aviso, y las métricas lo contaban en las dos cohortes.
-- Sumando cohortes, ese aviso salía dos veces. Decisión de Javier
-- (2026-09-29): cada aviso pertenece a una sola cohorte.
--
-- La regla: el aviso es de la cohorte de la deuda MÁS VIEJA que avisa (la
-- semana de consumo más antigua con una cuota de esa persona ese día). En la
-- cohorte más nueva, esa persona y fecha no es destinataria de avisos: no
-- entra en ningún porcentaje de avisos de esa cohorte, aunque su cuota sí
-- cuente en lo cobrado (eso sale de las cuotas, no de aquí). Así cada aviso
-- cuenta exactamente una vez y las cohortes suman.
--
-- Se aplica en `metricas.avisos_destinatarios`, de donde beben la escalera,
-- el embudo, la comparación de cohortes y los próximos envíos: todos quedan
-- coherentes sin tocarlos. Misma firma y mismas columnas.
--
-- Nuevo: `admin_avisos_de_la_cohorte`, los avisos de una cohorte día a día
-- (lo enviado y lo programado, con su resultado y los pagos que siguieron),
-- para la pestaña Notificaciones › Rendimiento.
-- ============================================================================

create or replace function metricas.avisos_destinatarios(
  p_desde       date,
  p_hasta       date,
  p_merchant_id uuid default null
)
returns table (
  semana                  date,
  sequence                smallint,
  user_id                 uuid,
  due_date                date,
  cuotas                  integer,
  pagada                  boolean,
  pago_en                 timestamptz,
  reporto_en              timestamptz,
  reporte_abierto         boolean,
  vencida                 boolean,
  pendiente_payable_usd   numeric,
  pendiente_financed_usd  numeric
)
language sql
stable
as $fn$
  with c as materialized (
    select *
    from metricas.cuotas c
    -- Por el día del consumo y no por `semana`: así llega al índice.
    where c.business_date between metricas.lunes(p_desde) and metricas.lunes(p_hasta) + 6
      and (p_merchant_id is null or c.merchant_id = p_merchant_id)
  ),
  -- De quién es el aviso de cada persona y fecha: la cohorte más vieja que
  -- tiene una cuota de esa persona ese día, de cualquier local.
  dueno as materialized (
    select t.user_id, t.due_date, min(t.semana) as semana
    from metricas.cuotas t
    where (t.user_id, t.due_date) in (select c.user_id, c.due_date from c)
    group by t.user_id, t.due_date
  ),
  -- Los reportes de esas cuotas, de una vez (una cotización puede tener
  -- varios: si rechazan uno, la persona reporta otra vez).
  rp as materialized (
    select qi.installment_id,
           min(pr.created_at)                                   as reporto_en,
           bool_or(pr.status in ('reported', 'in_review'))      as reporte_abierto
    from public.payment_quote_items qi
    join public.payment_reports pr on pr.quote_id = qi.quote_id
    where qi.installment_id in (select c.installment_id from c)
    group by qi.installment_id
  ),
  q as (
    select c.*, rp.reporto_en, rp.reporte_abierto
    from c
    join dueno o on o.user_id = c.user_id and o.due_date = c.due_date and o.semana = c.semana
    left join rp on rp.installment_id = c.installment_id
  )
  select
    q.semana,
    q.sequence,
    q.user_id,
    q.due_date,
    count(*)::integer,
    bool_and(q.status = 'paid'),
    case when bool_and(q.status = 'paid') then max(coalesce(q.reportada_en, q.paid_at)) end,
    min(q.reporto_en),
    coalesce(bool_or(q.reporte_abierto), false),
    bool_or(q.estado_hoy in ('vencida', 'perdida')),
    coalesce(sum(q.payable_usd)  filter (where q.status <> 'paid'), 0),
    coalesce(sum(q.financed_usd) filter (where q.status <> 'paid'), 0)
  from q
  group by q.semana, q.sequence, q.user_id, q.due_date;
$fn$;

comment on function metricas.avisos_destinatarios(date, date, uuid) is
  'A quién le toca un aviso de cuota en las cohortes de p_desde a p_hasta (lunes), de un local o de todos: una fila por persona, número de cuota y fecha de pago. Un aviso es de UNA sola cohorte: la más vieja con una cuota de esa persona ese día; en las más nuevas esa persona y fecha no sale (decisión del 2026-09-29). pago_en es cuándo REPORTÓ el pago que saldó la última de esas cuotas (o cuándo se aprobó, si se saldó sin reporte); reporto_en, su primer reporte de cualquier estado; pendiente_*, lo que queda por pagar (payable con su parte financed).';

revoke all on function metricas.avisos_destinatarios(date, date, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Los avisos de una cohorte, día a día
-- ---------------------------------------------------------------------------

create or replace function public.admin_avisos_de_la_cohorte(
  p_semana      date,
  p_merchant_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, metricas, pg_temp
as $$
declare
  v_lunes date := metricas.lunes(coalesce(p_semana, metricas.hoy()));
  v_out   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  with e as materialized (
    select * from metricas.avisos_escalera(v_lunes, v_lunes, p_merchant_id)
  ),
  -- Un peldaño de un destinatario, en el día en que sale (el aviso de verdad,
  -- o el programado si todavía no ha salido), en hora de Caracas.
  f as (
    select
      e.*,
      (coalesce(e.aviso_en, e.sale_en) at time zone 'America/Caracas')::date as dia,
      e.aviso_id is not null                                        as enviado,
      e.aviso_id is null and e.situacion = 'programada'            as programado
    from e
    where e.aviso_id is not null or e.situacion in ('programada', 'sin_aviso', 'en_revision', 'no_saldra')
  ),
  dias as (
    select
      f.dia, f.sequence, f.clave, f.rotulo, f.desfase, f.orden,
      count(*) filter (where f.enviado)                                          as enviados,
      count(*) filter (where f.resultado = 'entregado')                          as entregados,
      count(*) filter (where f.resultado in ('en_camino'))                       as en_camino,
      count(*) filter (where f.resultado in ('fallido', 'sin_acuse'))            as fallidos,
      count(*) filter (where f.resultado = 'sin_dispositivo')                    as sin_dispositivo,
      count(*) filter (where f.resultado in ('cancelado', 'cancelado_por_pago')) as cancelados,
      count(*) filter (where f.resultado = 'sin_dato')                           as sin_dato,
      count(*) filter (where f.programado)                                       as programados,
      count(*) filter (where f.situacion = 'sin_aviso')                          as no_salieron,
      count(*) filter (where f.ultimo_antes_de_pagar and f.horas_hasta_pagar <= 24) as pagaron_24h,
      count(*) filter (where f.ultimo_antes_de_pagar and f.horas_hasta_pagar <= 72) as pagaron_72h
    from f
    group by f.dia, f.sequence, f.clave, f.rotulo, f.desfase, f.orden
  ),
  -- La cohorte vista desde las cuotas, para decir cuántas personas y fechas
  -- recibieron su aviso con una cohorte anterior.
  propias as (
    select c.user_id, c.due_date
    from metricas.cuotas c
    where c.business_date between v_lunes and v_lunes + 6
      and (p_merchant_id is null or c.merchant_id = p_merchant_id)
    group by c.user_id, c.due_date
  ),
  compartidas as (
    select count(*) as n
    from propias pr
    where exists (
      select 1 from metricas.cuotas t
      where t.user_id = pr.user_id and t.due_date = pr.due_date and t.semana < v_lunes
    )
  ),
  cohorte as (
    select * from metricas.avisos_por_cohorte(v_lunes, v_lunes, p_merchant_id)
  )
  select jsonb_build_object(
    'semana', v_lunes,
    'hoy', metricas.hoy(),
    'ahora', now(),
    'local', p_merchant_id,
    'compartidas', (select n from compartidas),
    'totales', jsonb_build_object(
      'enviados',               coalesce((select sum(enviados) from dias), 0),
      'entregados',             coalesce((select sum(entregados) from dias), 0),
      'en_camino',              coalesce((select sum(en_camino) from dias), 0),
      'fallidos',               coalesce((select sum(fallidos) from dias), 0),
      'sin_dispositivo',        coalesce((select sum(sin_dispositivo) from dias), 0),
      'cancelados',             coalesce((select sum(cancelados) from dias), 0),
      'sin_dato',               coalesce((select sum(sin_dato) from dias), 0),
      'programados',            coalesce((select sum(programados) from dias), 0),
      'no_salieron',            coalesce((select sum(no_salieron) from dias), 0),
      'personas',               coalesce((select sum(personas) from cohorte), 0),
      'destinatarios_avisados', coalesce((select sum(destinatarios_avisados) from cohorte), 0),
      'pagaron_24h',            coalesce((select sum(pagaron_24h) from cohorte), 0),
      'pagaron_72h',            coalesce((select sum(pagaron_72h) from cohorte), 0),
      'ventana_abierta_24h',    coalesce((select sum(ventana_abierta_24h) from cohorte), 0)
    ),
    'cuotas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'numero', c.sequence,
        'vence_desde', c.vence_desde,
        'vence_hasta', c.vence_hasta,
        'personas', c.personas,
        'destinatarios_avisados', c.destinatarios_avisados,
        'pagaron_24h', c.pagaron_24h
      ) order by c.sequence)
      from cohorte c
    ), '[]'::jsonb),
    'dias', coalesce((
      select jsonb_agg(jsonb_build_object(
        'dia', d.dia,
        'cuota', d.sequence,
        'clave', d.clave,
        'rotulo', d.rotulo,
        'desfase', d.desfase,
        'enviados', d.enviados,
        'entregados', d.entregados,
        'en_camino', d.en_camino,
        'fallidos', d.fallidos,
        'sin_dispositivo', d.sin_dispositivo,
        'cancelados', d.cancelados,
        'sin_dato', d.sin_dato,
        'programados', d.programados,
        'no_salieron', d.no_salieron,
        'pagaron_24h', d.pagaron_24h,
        'pagaron_72h', d.pagaron_72h
      ) order by d.dia, d.sequence, d.orden)
      from dias d
    ), '[]'::jsonb)
  )
  into v_out;

  return v_out;
end;
$$;

comment on function public.admin_avisos_de_la_cohorte(date, uuid) is
  'Notificaciones › Rendimiento: los avisos de cuota de una cohorte (semana de consumo) día a día, por cuota y peldaño: enviados con su resultado, programados (aún no salen), los que no salieron y los pagos reportados en las 24/72 h siguientes al último aviso entregado. Cada aviso cuenta en una sola cohorte (la más vieja); compartidas dice cuántas personas y fechas de esta cohorte recibieron su aviso con una anterior. Solo super admin.';

revoke all on function public.admin_avisos_de_la_cohorte(date, uuid) from public, anon;
grant execute on function public.admin_avisos_de_la_cohorte(date, uuid) to authenticated;
