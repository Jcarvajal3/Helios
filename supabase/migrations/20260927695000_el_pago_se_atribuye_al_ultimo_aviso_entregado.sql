-- ============================================================================
-- Ronda — El pago se atribuye al último aviso ENTREGADO
--
-- Decisión de Javier (2026-09-27): en Cobros › Recordatorios, un pago contaba
-- para el último aviso ENVIADO antes del reporte, llegara o no al teléfono.
-- Ahora cuenta para el último aviso ENTREGADO (alguna entrega push en
-- 'delivered') antes del reporte, en la misma ventana de 24 h (y de 72 h).
--
-- Consecuencias, todas en la misma dirección:
--   · «Pagaron en 24 h» (suma de peldaños y cifra de la cuota) solo cuenta
--     pagos tras un aviso que llegó. En dev, de ~252 a ~113 en diez semanas.
--   · El embudo: «pagaron tras un aviso» son los que pagaron después de que
--     les llegara uno (siempre dentro de «les llegó»); los demás que pagaron
--     van a «pagaron sin que les llegara ningún aviso antes». Siguen sumando
--     las personas.
--   · El denominador no cambia: los destinatarios a los que se MANDÓ un aviso
--     sin haber pagado. Un aviso que no llega es un fallo del recordatorio y
--     tiene que pesar en su efectividad.
--   · ventana_abierta_24h solo mira avisos entregados o aún en camino (uno
--     fallido ya no puede contar).
--
-- avisos_escalera se copia de 20260927540000 (la única que la define) y
-- avisos_por_cohorte de 20260927670000 (la última); cambian solo esas
-- líneas y sus comentarios. Mismas firmas y columnas: admin_metricas_avisos
-- y admin_metricas_avisos_semanas las leen y no cambian.
-- ============================================================================

create or replace function metricas.avisos_escalera(
  p_desde       date,
  p_hasta       date,
  p_merchant_id uuid default null
)
returns table (
  semana                  date,
  sequence                smallint,
  user_id                 uuid,
  due_date                date,
  clave                   text,
  rotulo                  text,
  orden                   integer,
  desfase                 integer,
  hora                    time,
  activo                  boolean,
  sale_en                 timestamptz,
  saldra                  boolean,
  pagada                  boolean,
  pago_en                 timestamptz,
  vencida                 boolean,
  pendiente_payable_usd   numeric,
  pendiente_financed_usd  numeric,
  aviso_id                uuid,
  aviso_en                timestamptz,
  resultado               text,
  motivo_fallo            text,
  situacion               text,
  ultimo_antes_de_pagar   boolean,
  horas_hasta_pagar       numeric
)
language sql
stable
as $fn$
  with d as materialized (
    select * from metricas.avisos_destinatarios(p_desde, p_hasta, p_merchant_id)
  ),
  -- Materializado: así el cruce con los destinatarios va por hash sobre
  -- columnas llanas y no compara cada aviso con cada fila.
  av as materialized (
    select a.*
    from metricas.avisos a
    where a.due_date between (select min(d.due_date) from d) and (select max(d.due_date) from d)
      and a.user_id in (select d.user_id from d)
  ),
  -- Cada peldaño para cada fecha de pago: cuándo sale y si el motor lo va a
  -- mandar. Una vez por fecha y no por persona: `helios_business_date` no se
  -- inlinea (lleva `set search_path`) y llamarla fila a fila es lo más caro.
  pd as materialized (
    select
      f.due_date,
      p.clave, p.rotulo, p.orden, p.desfase, p.hora, p.activo, p.primer_aviso_en,
      s.sale_en,
      (p.activo and (p.desfase <= 0 or public.helios_business_date(s.sale_en) > f.due_date)) as saldra
    from (select distinct d.due_date from d) f
    cross join metricas.avisos_peldanos p
    cross join lateral (
      select (((f.due_date + p.desfase)::timestamp + p.hora) at time zone 'America/Caracas') as sale_en
    ) s
    where p.desfase is not null
      and p.hora is not null
  ),
  y as (
    select
      d.*,
      pd.clave, pd.rotulo, pd.orden, pd.desfase, pd.hora, pd.activo, pd.primer_aviso_en,
      pd.sale_en, pd.saldra,
      av.aviso_id, av.creado_en as aviso_en, av.resultado, av.motivo_fallo
    from d
    join pd on pd.due_date = d.due_date
    left join av on av.user_id = d.user_id and av.clave = pd.clave and av.due_date = d.due_date
  ),
  z as (
    select
      y.*,
      case
        when y.pagada and y.pago_en is not null
             and y.pago_en <= coalesce(y.aviso_en, y.sale_en)            then 'pagada_antes'
        when y.aviso_id is not null                                       then 'avisada'
        -- Saldada sin hora conocida: no se le atribuye a ningún aviso.
        when y.pagada and y.pago_en is null                               then 'pagada_antes'
        when y.sale_en > now() then
          case
            when y.reporte_abierto                                        then 'en_revision'
            when y.saldra                                                 then 'programada'
            else                                                               'no_saldra'
          end
        when y.primer_aviso_en is null or y.sale_en < y.primer_aviso_en   then 'no_existia'
        when y.reporto_en is not null and y.reporto_en <= y.sale_en       then 'en_revision'
        else                                                                   'sin_aviso'
      end as situacion,
      -- El pago se atribuye al último aviso ENTREGADO antes del reporte: uno
      -- que se mandó y no llegó a ningún teléfono no pudo empujarlo.
      max(y.aviso_en) filter (where y.aviso_en < y.pago_en and y.resultado = 'entregado')
        over (partition by y.semana, y.sequence, y.user_id, y.due_date) as ultimo_aviso_antes
    from y
  )
  select
    z.semana, z.sequence, z.user_id, z.due_date,
    z.clave, z.rotulo, z.orden, z.desfase, z.hora, z.activo,
    z.sale_en, z.saldra,
    z.pagada, z.pago_en, z.vencida,
    z.pendiente_payable_usd, z.pendiente_financed_usd,
    z.aviso_id, z.aviso_en, z.resultado, z.motivo_fallo,
    z.situacion,
    coalesce(z.aviso_id is not null and z.aviso_en = z.ultimo_aviso_antes, false),
    case when z.aviso_id is not null and z.aviso_en = z.ultimo_aviso_antes
         then round(extract(epoch from (z.pago_en - z.aviso_en)) / 3600.0, 2) end
  from z;
$fn$;

comment on function metricas.avisos_escalera(date, date, uuid) is
  'Cada destinatario (metricas.avisos_destinatarios) en cada peldaño (metricas.avisos_peldanos): cuándo sale (sale_en, hora de Caracas sobre el día natural), si el motor lo va a mandar (saldra), el aviso que salió de verdad y su resultado, y la situacion, una sola: pagada_antes (ya había pagado), avisada, programada (va a salir), no_saldra (apagado), en_revision (tenía un pago en revisión y el motor lo salta), no_existia (el peldaño aún no mandaba nada) o sin_aviso (le tocaba y no salió). ultimo_antes_de_pagar marca el aviso al que se atribuye el pago: el último ENTREGADO (resultado entregado: alguna entrega push en delivered) que salió antes del reporte; horas_hasta_pagar, del aviso al reporte.';

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
      -- Solo los que pueden acabar contando: entregados o aún en camino.
      max(e.aviso_en) filter (where e.resultado in ('entregado', 'en_camino')) as ultimo_aviso
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
  'Por cohorte (semana de consumo) y número de cuota: el embudo en personas (con cuota → alcanzables: con un teléfono con la app → avisadas: se les mandó un aviso sin haber pagado → recibieron: al menos uno de esos avisos, mandados antes de pagar, se entregó; y pagaron sin que les llegara antes ningún aviso / tras un aviso entregado / siguen sin pagar, que suman las personas) y la efectividad en destinatarios (persona y fecha de pago: pagaron_24h = reportaron el pago en las 24 h siguientes al último aviso ENTREGADO antes del reporte ÷ destinatarios_avisados, a los que se mandó un aviso sin haber pagado). Lo que queda sin pagar va en payable con su parte financed y su fee (incluye lo dado por perdido). ventana_abierta_24h: destinatarios sin pagar cuyo último aviso entregado (o aún en camino) salió hace menos de 24 h (todavía pueden contar).';

revoke all on function metricas.avisos_por_cohorte(date, date, uuid) from public, anon, authenticated;
revoke all on function metricas.avisos_escalera(date, date, uuid) from public, anon, authenticated;
