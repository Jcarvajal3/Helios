-- ============================================================================
-- Ronda — «Les llegó un aviso» cuenta solo lo que llegó antes de pagar
--
-- Auditoría de rigor de Métricas (AUD-COBROS-MORA, 2026-09-27). En Cobros ›
-- Recordatorios, el embudo de una cuota dice: usuarios con la cuota → con la
-- app → «avisados» (se les mandó un aviso SIN haber pagado) → «les llegó un
-- aviso». Pero `recibieron` contaba cualquier aviso entregado, también uno que
-- salió DESPUÉS de que la persona reportara el pago. En dev, 8 usuarios de las
-- últimas diez semanas salían en «les llegó» sin estar en «avisados», y la
-- frase decía «a 45 se les mandó al menos un aviso y a 35 les llegó» con gente
-- en los 35 que no estaba en los 45.
--
-- Ahora `recibieron` son los usuarios con al menos un aviso ENTREGADO que salió
-- antes de pagar (la misma condición que `avisadas`: situación «avisada» en la
-- escalera). Así «les llegó» es siempre una parte de «avisados», y el escalón
-- del embudo mide lo que de verdad pudo empujar el pago. Las cifras por aviso
-- («avisos», «entregados», fallos) no cambian: cuentan todos los avisos.
--
-- Copiada de 20260927540000 (la única que define la función) con solo esa
-- línea y su comentario cambiados. Misma firma y mismas columnas: las dos RPC
-- (admin_metricas_avisos y admin_metricas_avisos_semanas) la leen y no cambian.
-- ============================================================================

create or replace function metricas.avisos_por_cohorte(
  p_desde       date,
  p_hasta       date,
  p_merchant_id uuid default null
)
returns table (
  semana                   date,
  sequence                 smallint,
  personas                 integer,
  alcanzables              integer,
  avisadas                 integer,
  recibieron               integer,
  pagaron_antes            integer,
  pagaron_tras_aviso       integer,
  pagaron_tras_aviso_24h   integer,
  sin_pagar                integer,
  sin_pagar_vencida        integer,
  sin_pagar_payable_usd    numeric,
  sin_pagar_financed_usd   numeric,
  sin_pagar_fee_usd        numeric,
  destinatarios            integer,
  destinatarios_avisados   integer,
  pagaron_24h              integer,
  pagaron_72h              integer,
  avisos                   integer,
  avisos_entregados        integer,
  avisos_fallidos          integer,
  avisos_sin_dispositivo   integer,
  avisos_sin_dato          integer,
  vence_desde              date,
  vence_hasta              date,
  primer_envio             timestamptz,
  ultimo_envio             timestamptz,
  ventana_abierta_24h      integer
)
language sql
stable
as $fn$
  with e as (
    select * from metricas.avisos_escalera(p_desde, p_hasta, p_merchant_id)
  ),
  -- Un destinatario (persona y fecha de pago) con todo su recorrido.
  dest as (
    select
      e.semana, e.sequence, e.user_id, e.due_date,
      bool_and(e.pagada)                                              as pagada,
      bool_or(e.vencida)                                              as vencida,
      max(e.pendiente_payable_usd)                                    as pendiente_payable_usd,
      max(e.pendiente_financed_usd)                                   as pendiente_financed_usd,
      bool_or(e.situacion = 'avisada')                                as avisada,
      -- Solo los avisos que salieron antes de pagar (situación «avisada»): un
      -- aviso entregado después del pago no le llegó a quien todavía debía.
      bool_or(e.situacion = 'avisada' and e.resultado = 'entregado')  as recibio,
      bool_or(e.aviso_id is not null
              and e.resultado not in ('sin_dispositivo', 'sin_dato')) as con_dispositivo,
      bool_or(e.ultimo_antes_de_pagar)                                as pago_tras_aviso,
      bool_or(e.ultimo_antes_de_pagar and e.horas_hasta_pagar <= 24)  as pago_en_24h,
      bool_or(e.ultimo_antes_de_pagar and e.horas_hasta_pagar <= 72)  as pago_en_72h,
      count(e.aviso_id)                                               as avisos,
      count(*) filter (where e.resultado = 'entregado')               as entregados,
      count(*) filter (where e.resultado = 'fallido')                 as fallidos,
      count(*) filter (where e.resultado = 'sin_dispositivo')         as sin_dispositivo,
      count(*) filter (where e.resultado = 'sin_dato')                as sin_dato,
      min(e.sale_en) filter (where e.activo or e.aviso_id is not null) as primer_envio,
      max(e.sale_en) filter (where e.activo or e.aviso_id is not null) as ultimo_envio,
      max(e.aviso_en)                                                 as ultimo_aviso
    from e
    group by e.semana, e.sequence, e.user_id, e.due_date
  ),
  -- Una persona de la cohorte con esa cuota (puede tener varias fechas).
  per as (
    select
      dest.semana, dest.sequence, dest.user_id,
      bool_and(dest.pagada)                                           as pagada,
      bool_or(not dest.pagada and dest.vencida)                       as vencida,
      bool_or(dest.avisada)                                           as avisada,
      bool_or(dest.recibio)                                           as recibio,
      bool_or(dest.con_dispositivo)
        or exists (select 1 from public.push_tokens t
                    where t.user_id = dest.user_id and t.disabled_at is null) as alcanzable,
      bool_or(dest.pago_tras_aviso)                                   as pago_tras_aviso,
      bool_or(dest.pago_en_24h)                                       as pago_en_24h
    from dest
    group by dest.semana, dest.sequence, dest.user_id
  ),
  p as (
    select
      per.semana, per.sequence,
      count(*)                                                        as personas,
      count(*) filter (where per.alcanzable)                          as alcanzables,
      count(*) filter (where per.avisada)                             as avisadas,
      count(*) filter (where per.recibio)                             as recibieron,
      count(*) filter (where per.pagada and not per.pago_tras_aviso)  as pagaron_antes,
      count(*) filter (where per.pagada and per.pago_tras_aviso)      as pagaron_tras_aviso,
      count(*) filter (where per.pagada and per.pago_en_24h)          as pagaron_tras_aviso_24h,
      count(*) filter (where not per.pagada)                          as sin_pagar,
      count(*) filter (where not per.pagada and per.vencida)          as sin_pagar_vencida
    from per
    group by per.semana, per.sequence
  ),
  d as (
    select
      dest.semana, dest.sequence,
      count(*)                                                        as destinatarios,
      count(*) filter (where dest.avisada)                            as destinatarios_avisados,
      count(*) filter (where dest.pago_en_24h)                        as pagaron_24h,
      count(*) filter (where dest.pago_en_72h)                        as pagaron_72h,
      sum(dest.avisos)                                                as avisos,
      sum(dest.entregados)                                            as avisos_entregados,
      sum(dest.fallidos)                                              as avisos_fallidos,
      sum(dest.sin_dispositivo)                                       as avisos_sin_dispositivo,
      sum(dest.sin_dato)                                              as avisos_sin_dato,
      sum(dest.pendiente_payable_usd)                                 as sin_pagar_payable_usd,
      sum(dest.pendiente_financed_usd)                                as sin_pagar_financed_usd,
      min(dest.due_date)                                              as vence_desde,
      max(dest.due_date)                                              as vence_hasta,
      min(dest.primer_envio)                                          as primer_envio,
      max(dest.ultimo_envio)                                          as ultimo_envio,
      -- Sin pagar y con su último aviso de hace menos de 24 h: todavía pueden
      -- contar como «pagaron en 24 h».
      count(*) filter (where not dest.pagada
                         and dest.ultimo_aviso > now() - interval '24 hours') as ventana_abierta_24h
    from dest
    group by dest.semana, dest.sequence
  )
  select
    p.semana, p.sequence,
    p.personas::integer, p.alcanzables::integer, p.avisadas::integer, p.recibieron::integer,
    p.pagaron_antes::integer, p.pagaron_tras_aviso::integer, p.pagaron_tras_aviso_24h::integer,
    p.sin_pagar::integer, p.sin_pagar_vencida::integer,
    d.sin_pagar_payable_usd, d.sin_pagar_financed_usd,
    d.sin_pagar_payable_usd - d.sin_pagar_financed_usd,
    d.destinatarios::integer, d.destinatarios_avisados::integer,
    d.pagaron_24h::integer, d.pagaron_72h::integer,
    d.avisos::integer, d.avisos_entregados::integer, d.avisos_fallidos::integer,
    d.avisos_sin_dispositivo::integer, d.avisos_sin_dato::integer,
    d.vence_desde, d.vence_hasta, d.primer_envio, d.ultimo_envio,
    d.ventana_abierta_24h::integer
  from p
  join d on d.semana = p.semana and d.sequence = p.sequence;
$fn$;

comment on function metricas.avisos_por_cohorte(date, date, uuid) is
  'Por cohorte (semana de consumo) y número de cuota: el embudo en personas (con cuota → alcanzables: con un teléfono con la app → avisadas: se les mandó un aviso sin haber pagado → recibieron: al menos uno de esos avisos, mandados antes de pagar, se entregó; y pagaron antes de cualquier aviso / tras un aviso / siguen sin pagar, que suman las personas) y la efectividad en destinatarios (persona y fecha de pago: pagaron_24h = pagaron en las 24 h siguientes al último aviso que se les mandó antes de pagar ÷ destinatarios_avisados). Lo que queda sin pagar va en payable con su parte financed y su fee (incluye lo dado por perdido). ventana_abierta_24h: destinatarios sin pagar cuyo último aviso salió hace menos de 24 h (todavía pueden contar).';

revoke all on function metricas.avisos_por_cohorte(date, date, uuid) from public, anon, authenticated;
