-- ============================================================================
-- Ronda — Los avisos de cuota se miden por cohorte de consumo
--
-- La pestaña Avisos de Métricas: qué avisos push de cuota salieron (o van a
-- salir) para los consumos de una semana, cuántos llegaron, cuántos fallaron y
-- cuánta gente pagó después de recibirlos.
--
-- La programación que se enseña es la del MOTOR, no una copia:
--   · el día de cada peldaño respecto al vencimiento lo dice
--     `public.helios_reminder_offset(clave)` (el signo vive en el código y el
--     día en `notification_templates.lead_days`);
--   · la hora es `notification_templates.run_at` (hora de Caracas), que
--     `admin_set_notification_schedule` mantiene igual que el cron;
--   · un peldaño está activo si su plantilla está encendida y su trabajo de
--     `cron.job` existe y está activo;
--   · el ancla es el día NATURAL de Caracas: el peldaño de desfase d para una
--     fecha de pago D sale el día D + d a su hora; uno de atraso, además, solo
--     si ese instante ya es un día operativo posterior a D (el seguro de
--     `helios_reminder_due_date`);
--   · el motor avisa a quien tiene una cuota `pending` de esa fecha sin un
--     pago en revisión, una vez por persona, clave y fecha.
--
-- La unidad es el DESTINATARIO: una persona y una fecha de pago de una cuota
-- de la cohorte (un aviso es por persona y fecha, no por cuota). Casi siempre
-- es una persona por cuota; quien consumió dos noches de la misma semana
-- tiene dos fechas y dos destinatarios.
--
-- «Pagó» es cuando REPORTÓ el pago que saldó la cuota
-- (`metricas.cuotas.reportada_en`), o cuando se aprobó si se saldó sin reporte.
-- Un pago se atribuye a un solo aviso: el último que le llegó antes de pagar.
-- Así los peldaños suman el total de la cohorte.
--
-- Las entregas (`push_deliveries`) se borran 30 días después de cerrarse
-- (`purge_push_queue`): un aviso más viejo sin entregas no es «sin
-- dispositivo», es «sin dato».
--
-- Solo lee. Nada de aquí toca el motor de avisos ni sus tablas.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Los peldaños de la escalera, tal como los tiene el motor
-- ---------------------------------------------------------------------------

create or replace function metricas.avisos_desfase(p_clave text)
returns integer
language plpgsql
stable
as $fn$
begin
  -- El motor lanza una excepción si una plantilla de atraso no tiene día:
  -- ese peldaño no sale, y aquí se lee como «sin día» en vez de romper.
  return public.helios_reminder_offset(p_clave);
exception when others then
  return null;
end;
$fn$;

comment on function metricas.avisos_desfase(text) is
  'Días desde el vencimiento en que sale un aviso de cuota (negativo antes, 0 el día, positivo en atraso). Se lo pregunta al motor (public.helios_reminder_offset); null si el motor no sabe darlo.';

create or replace function metricas.avisos_motivo(p_error text)
returns text
language sql
immutable
as $fn$
  select case
    when p_error is null or btrim(p_error) = '' then 'Sin motivo'
    when position(':' in p_error) > 0 then btrim(split_part(p_error, ':', 1))
    else left(btrim(p_error), 80)
  end;
$fn$;

comment on function metricas.avisos_motivo(text) is
  'El motivo de un fallo de push, sin el detalle: lo que va antes de los dos puntos («DeviceNotRegistered», «HTTP 400») o el texto entero si es corto («Sesión cerrada»).';

create or replace view metricas.avisos_peldanos as
select
  t.key                                        as clave,
  t.label                                      as rotulo,
  t.sort_order                                 as orden,
  metricas.avisos_desfase(t.key)               as desfase,
  t.run_at                                     as hora,
  t.enabled                                    as encendido,
  t.cron_job                                   as cron_job,
  coalesce(j.active, false)                    as cron_activo,
  (t.enabled and coalesce(j.active, false)
     and metricas.avisos_desfase(t.key) is not null
     and t.run_at is not null)                 as activo,
  (select min(n.created_at) from public.notifications n
    where n.template_key = t.key)              as primer_aviso_en
from public.notification_templates t
left join cron.job j on j.jobname = t.cron_job
where t.type = 'installment_due'
  and t.cron_job is not null;

comment on view metricas.avisos_peldanos is
  'Los peldaños de la escalera de avisos de cuota, uno por plantilla del cron: su día respecto al vencimiento (desfase, del motor), su hora de Caracas, si está activo (plantilla encendida y cron activo) y cuándo salió su primer aviso.';
comment on column metricas.avisos_peldanos.desfase is 'Días desde el vencimiento: −3, −1, 0, 0, +1, +3, +5, +7 con la configuración de fábrica.';
comment on column metricas.avisos_peldanos.hora is 'Hora de Caracas a la que sale (notification_templates.run_at, igual que el cron).';
comment on column metricas.avisos_peldanos.activo is 'Va a salir: la plantilla está encendida, su cron existe y está activo y tiene día y hora.';
comment on column metricas.avisos_peldanos.primer_aviso_en is 'El primer aviso que mandó este peldaño a alguien. Antes de eso el peldaño no existía (o no tenía a quién avisar).';

-- ---------------------------------------------------------------------------
-- 2. Cada aviso de cuota y qué fue de él
-- ---------------------------------------------------------------------------

create or replace view metricas.avisos as
select
  n.id                                         as aviso_id,
  n.user_id                                    as user_id,
  n.template_key                               as clave,
  (n.data ->> 'due_date')::date                as due_date,
  n.created_at                                 as creado_en,
  n.read_at                                    as leido_en,
  coalesce(e.entregas, 0)::integer             as entregas,
  case
    when e.entregadas > 0                    then 'entregado'
    when e.en_camino > 0                     then 'en_camino'
    when e.sin_acuse > 0                     then 'sin_acuse'
    when e.canceladas_pago > 0               then 'cancelado_por_pago'
    when e.canceladas > 0                    then 'cancelado'
    when e.fallidas > 0                      then 'fallido'
    when n.created_at < now() - interval '30 days' then 'sin_dato'
    else                                          'sin_dispositivo'
  end                                          as resultado,
  e.motivo_fallo                               as motivo_fallo
from public.notifications n
left join lateral (
  select
    count(*)                                                          as entregas,
    count(*) filter (where d.status = 'delivered')                    as entregadas,
    count(*) filter (where d.status = 'pending'
                        or (d.status = 'sent' and d.settled_at is null)) as en_camino,
    count(*) filter (where d.status = 'sent' and d.settled_at is not null) as sin_acuse,
    count(*) filter (where d.status = 'cancelled'
                       and d.error ilike '%pago%')                    as canceladas_pago,
    count(*) filter (where d.status = 'cancelled')                    as canceladas,
    count(*) filter (where d.status = 'failed')                       as fallidas,
    min(metricas.avisos_motivo(d.error)) filter (where d.status = 'failed') as motivo_fallo
  from public.push_deliveries d
  where d.notification_id = n.id
) e on true
where n.type = 'installment_due'
  and n.template_key is not null
  and (n.data ->> 'due_date') ~ '^\d{4}-\d{2}-\d{2}$';

comment on view metricas.avisos is
  'Un aviso de cuota (una persona, una clave de la escalera, una fecha de pago) y su resultado, el mejor de sus dispositivos: entregado > en_camino (en cola o sin acuse todavía) > sin_acuse (Expo no llegó a confirmarlo) > cancelado_por_pago (se frenó porque reportó el pago) > cancelado (el dispositivo se dio de baja) > fallido > sin_dispositivo (no tenía ningún teléfono con la app). sin_dato: más de 30 días y sin entregas, que purge_push_queue ya borró.';
comment on column metricas.avisos.motivo_fallo is 'Si falló en todos sus dispositivos: el motivo (metricas.avisos_motivo) de uno de ellos.';

-- ---------------------------------------------------------------------------
-- 3. Los destinatarios de una cohorte: persona y fecha de pago de una cuota
-- ---------------------------------------------------------------------------

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
  'A quién le toca un aviso de cuota en las cohortes de p_desde a p_hasta (lunes), de un local o de todos: una fila por persona, número de cuota y fecha de pago. pago_en es cuándo REPORTÓ el pago que saldó la última de esas cuotas (o cuándo se aprobó, si se saldó sin reporte); reporto_en, su primer reporte de cualquier estado; pendiente_*, lo que queda por pagar (payable con su parte financed).';

-- ---------------------------------------------------------------------------
-- 4. La escalera: cada destinatario en cada peldaño
-- ---------------------------------------------------------------------------

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
      max(y.aviso_en) filter (where y.aviso_en < y.pago_en)
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
  'Cada destinatario (metricas.avisos_destinatarios) en cada peldaño (metricas.avisos_peldanos): cuándo sale (sale_en, hora de Caracas sobre el día natural), si el motor lo va a mandar (saldra), el aviso que salió de verdad y su resultado, y la situacion, una sola: pagada_antes (ya había pagado), avisada, programada (va a salir), no_saldra (apagado), en_revision (tenía un pago en revisión y el motor lo salta), no_existia (el peldaño aún no mandaba nada) o sin_aviso (le tocaba y no salió). ultimo_antes_de_pagar marca el aviso al que se atribuye el pago: el último antes de pagar.';

-- ---------------------------------------------------------------------------
-- 5. El resumen de una cohorte y una cuota: el embudo y la efectividad
-- ---------------------------------------------------------------------------

-- La firma de salida puede crecer: se borra antes de volver a crearla.
drop function if exists metricas.avisos_por_cohorte(date, date, uuid);

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
      bool_or(e.aviso_id is not null and e.resultado = 'entregado')  as recibio,
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
  'Por cohorte (semana de consumo) y número de cuota: el embudo en personas (con cuota → alcanzables: con un teléfono con la app → avisadas → les llegó un aviso; y pagaron antes de cualquier aviso / tras un aviso / siguen sin pagar, que suman las personas) y la efectividad en destinatarios (pagaron_24h: pagaron en las 24 h siguientes al último aviso que recibieron antes de pagar ÷ destinatarios_avisados). Lo que queda sin pagar va en payable con su parte financed y su fee. ventana_abierta_24h: destinatarios sin pagar cuyo último aviso salió hace menos de 24 h (todavía pueden contar).';

revoke all on function metricas.avisos_desfase(text) from public, anon, authenticated;
revoke all on function metricas.avisos_motivo(text) from public, anon, authenticated;
revoke all on function metricas.avisos_destinatarios(date, date, uuid) from public, anon, authenticated;
revoke all on function metricas.avisos_escalera(date, date, uuid) from public, anon, authenticated;
revoke all on function metricas.avisos_por_cohorte(date, date, uuid) from public, anon, authenticated;
revoke all on metricas.avisos_peldanos, metricas.avisos from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. La RPC de la pestaña: una cohorte
-- ---------------------------------------------------------------------------

create or replace function public.admin_metricas_avisos(
  p_semana      date,
  p_merchant_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_hoy    date := metricas.hoy();
  v_lunes  date := metricas.lunes(coalesce(p_semana, metricas.hoy()));
  v_res    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- Nunca una semana futura.
  if v_lunes > metricas.lunes(v_hoy) then
    v_lunes := metricas.lunes(v_hoy);
  end if;

  with
  e as materialized (
    select * from metricas.avisos_escalera(v_lunes, v_lunes, p_merchant_id)
  ),
  resumen as (
    select * from metricas.avisos_por_cohorte(v_lunes, v_lunes, p_merchant_id)
  ),
  peldano as (
    select
      e.sequence, e.clave,
      min(e.rotulo)                                                    as rotulo,
      min(e.orden)                                                     as orden,
      min(e.desfase)                                                   as desfase,
      min(e.hora)                                                      as hora,
      bool_and(e.activo)                                               as activo,
      min(e.sale_en)                                                   as sale_desde,
      max(e.sale_en)                                                   as sale_hasta,
      case
        when not bool_and(e.activo)                                    then 'apagado'
        when bool_and(e.sale_en <= now())                              then 'enviado'
        when bool_and(e.sale_en > now()) and not bool_or(e.saldra)     then 'apagado'
        when bool_and(e.sale_en > now())                               then 'programado'
        else                                                                'en_curso'
      end                                                              as estado,
      count(*)                                                         as destinatarios,
      count(*) filter (where e.situacion = 'pagada_antes')             as pagada_antes,
      count(*) filter (where e.situacion = 'avisada')                  as avisada,
      count(*) filter (where e.situacion = 'programada')               as programada,
      count(*) filter (where e.situacion = 'no_saldra')                as no_saldra,
      count(*) filter (where e.situacion = 'en_revision')              as en_revision,
      count(*) filter (where e.situacion = 'no_existia')               as no_existia,
      count(*) filter (where e.situacion = 'sin_aviso')                as sin_aviso,
      count(e.aviso_id)                                                as avisos,
      count(*) filter (where e.aviso_id is not null
                         and e.situacion = 'pagada_antes')             as avisos_tras_pagar,
      count(*) filter (where e.resultado = 'entregado')                as entregados,
      count(*) filter (where e.resultado = 'en_camino')                as en_camino,
      count(*) filter (where e.resultado = 'sin_acuse')                as sin_acuse,
      count(*) filter (where e.resultado = 'cancelado_por_pago')       as cancelados_por_pago,
      count(*) filter (where e.resultado = 'cancelado')                as cancelados,
      count(*) filter (where e.resultado = 'fallido')                  as fallidos,
      count(*) filter (where e.resultado = 'sin_dispositivo')          as sin_dispositivo,
      count(*) filter (where e.resultado = 'sin_dato')                 as sin_dato,
      count(*) filter (where e.ultimo_antes_de_pagar)                  as pagaron_tras,
      count(*) filter (where e.ultimo_antes_de_pagar
                         and e.horas_hasta_pagar <= 24)                as pagaron_24h,
      count(*) filter (where e.ultimo_antes_de_pagar
                         and e.horas_hasta_pagar <= 72)                as pagaron_72h,
      count(*) filter (where e.situacion = 'avisada' and not e.pagada
                         and e.aviso_en > now() - interval '24 hours') as ventana_abierta_24h
    from e
    group by e.sequence, e.clave
  ),
  fallo as (
    select e.sequence, e.motivo_fallo as motivo,
           count(*) as avisos, count(distinct e.user_id) as personas
    from e
    where e.resultado = 'fallido'
    group by e.sequence, e.motivo_fallo
  ),
  -- Quien no tiene hoy ningún teléfono con la app y los avisos activos, y por qué.
  sin_tel as (
    select x.sequence, x.user_id,
           case
             when not exists (select 1 from public.push_tokens t where t.user_id = x.user_id)
               then 'nunca'
             when (select t.disabled_reason from public.push_tokens t
                    where t.user_id = x.user_id order by t.disabled_at desc nulls last limit 1)
                  = 'DeviceNotRegistered'
               then 'desinstalo'
             when (select t.disabled_reason from public.push_tokens t
                    where t.user_id = x.user_id order by t.disabled_at desc nulls last limit 1)
                  = 'Sesión cerrada'
               then 'cerro_sesion'
             else 'otro'
           end as porque
    from (select distinct e.sequence, e.user_id from e) x
    where not exists (select 1 from public.push_tokens t
                       where t.user_id = x.user_id and t.disabled_at is null)
  ),
  proximo as (
    select
      e.sale_en, e.clave, e.sequence, e.due_date,
      min(e.rotulo) as rotulo, min(e.orden) as orden, min(e.desfase) as desfase, min(e.hora) as hora,
      count(*) filter (where e.situacion = 'programada')  as personas,
      count(*) filter (where e.situacion = 'no_saldra')   as no_saldra,
      count(*) filter (where e.situacion = 'en_revision') as en_revision
    from e
    where e.sale_en > now()
      and e.aviso_id is null
    group by e.sale_en, e.clave, e.sequence, e.due_date
    having count(*) filter (where e.situacion in ('programada', 'no_saldra', 'en_revision')) > 0
  )
  select jsonb_build_object(
    'semana', jsonb_build_object(
      'desde',    v_lunes,
      'hasta',    v_lunes + 6,
      'en_curso', v_lunes = metricas.lunes(v_hoy)
    ),
    'hoy',   v_hoy,
    'ahora', now(),
    'local', p_merchant_id,
    'peldanos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'clave',       pp.clave,
               'rotulo',      pp.rotulo,
               'orden',       pp.orden,
               'desfase',     pp.desfase,
               'hora',        to_char(pp.hora, 'HH24:MI'),
               'activo',      pp.activo,
               'encendido',   pp.encendido,
               'cron_activo', pp.cron_activo
             ) order by pp.desfase nulls last, pp.hora, pp.orden), '[]'::jsonb)
      from metricas.avisos_peldanos pp
    ),
    'cuotas', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'numero',                 r.sequence,
        'vence_desde',            r.vence_desde,
        'vence_hasta',            r.vence_hasta,
        'primer_envio',           r.primer_envio,
        'ultimo_envio',           r.ultimo_envio,
        'embudo', jsonb_build_object(
          'personas',               r.personas,
          'alcanzables',            r.alcanzables,
          'avisadas',               r.avisadas,
          'recibieron',             r.recibieron,
          'pagaron_antes',          r.pagaron_antes,
          'pagaron_tras_aviso',     r.pagaron_tras_aviso,
          'pagaron_tras_aviso_24h', r.pagaron_tras_aviso_24h,
          'sin_pagar',              r.sin_pagar,
          'sin_pagar_vencida',      r.sin_pagar_vencida,
          'sin_pagar_importe', jsonb_build_object(
            'payable_usd',  round(r.sin_pagar_payable_usd, 2),
            'financed_usd', round(r.sin_pagar_financed_usd, 2),
            'fee_usd',      round(r.sin_pagar_fee_usd, 2)
          )
        ),
        'efectividad', jsonb_build_object(
          'destinatarios',          r.destinatarios,
          'destinatarios_avisados', r.destinatarios_avisados,
          'pagaron_24h',            r.pagaron_24h,
          'pagaron_72h',            r.pagaron_72h,
          'avisos',                 r.avisos,
          'avisos_entregados',      r.avisos_entregados,
          'avisos_fallidos',        r.avisos_fallidos,
          'avisos_sin_dispositivo', r.avisos_sin_dispositivo,
          'avisos_sin_dato',        r.avisos_sin_dato,
          'ventana_abierta_24h',    r.ventana_abierta_24h
        ),
        'escalera', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'clave',               pe.clave,
            'rotulo',              pe.rotulo,
            'orden',               pe.orden,
            'desfase',             pe.desfase,
            'hora',                to_char(pe.hora, 'HH24:MI'),
            'activo',              pe.activo,
            'estado',              pe.estado,
            'sale_desde',          pe.sale_desde,
            'sale_hasta',          pe.sale_hasta,
            'destinatarios',       pe.destinatarios,
            'situacion', jsonb_build_object(
              'pagada_antes', pe.pagada_antes,
              'avisada',      pe.avisada,
              'programada',   pe.programada,
              'no_saldra',    pe.no_saldra,
              'en_revision',  pe.en_revision,
              'no_existia',   pe.no_existia,
              'sin_aviso',    pe.sin_aviso
            ),
            'avisos',              pe.avisos,
            'avisos_tras_pagar',   pe.avisos_tras_pagar,
            'resultado', jsonb_build_object(
              'entregado',          pe.entregados,
              'en_camino',          pe.en_camino,
              'sin_acuse',          pe.sin_acuse,
              'cancelado_por_pago', pe.cancelados_por_pago,
              'cancelado',          pe.cancelados,
              'fallido',            pe.fallidos,
              'sin_dispositivo',    pe.sin_dispositivo,
              'sin_dato',           pe.sin_dato
            ),
            'pagaron_tras',        pe.pagaron_tras,
            'pagaron_24h',         pe.pagaron_24h,
            'pagaron_72h',         pe.pagaron_72h,
            'ventana_abierta_24h', pe.ventana_abierta_24h
          ) order by pe.desfase, pe.hora, pe.orden), '[]'::jsonb)
          from peldano pe
          where pe.sequence = r.sequence
        ),
        'fallos', jsonb_build_object(
          'por_motivo', (
            select coalesce(jsonb_agg(jsonb_build_object(
                     'motivo', f.motivo, 'avisos', f.avisos, 'personas', f.personas
                   ) order by f.avisos desc, f.motivo), '[]'::jsonb)
            from fallo f where f.sequence = r.sequence
          ),
          'sin_dispositivo', (
            select jsonb_build_object(
              'personas',     count(*),
              'nunca',        count(*) filter (where s.porque = 'nunca'),
              'desinstalo',   count(*) filter (where s.porque = 'desinstalo'),
              'cerro_sesion', count(*) filter (where s.porque = 'cerro_sesion'),
              'otro',         count(*) filter (where s.porque = 'otro')
            )
            from sin_tel s where s.sequence = r.sequence
          )
        )
      ) order by r.sequence), '[]'::jsonb)
      from resumen r
    ),
    'proximos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'sale_en',     x.sale_en,
               'dia',         (x.sale_en at time zone 'America/Caracas')::date,
               'hora',        to_char(x.hora, 'HH24:MI'),
               'clave',       x.clave,
               'rotulo',      x.rotulo,
               'desfase',     x.desfase,
               'cuota',       x.sequence,
               'vence',       x.due_date,
               'personas',    x.personas,
               'no_saldra',   x.no_saldra,
               'en_revision', x.en_revision
             ) order by x.sale_en, x.orden, x.sequence), '[]'::jsonb)
      from proximo x
    )
  )
  into v_res;

  return v_res;
end;
$fn$;

comment on function public.admin_metricas_avisos(date, uuid) is
  'Métricas › Avisos: los avisos push de cuota de la cohorte de consumo de la semana (lunes) p_semana, de un local o de todos. Por cuota: la escalera (cada peldaño con su día, hora, estado, a quién iba, qué fue de cada aviso y quién pagó tras él), el embudo, la efectividad y los fallos; y los próximos envíos programados. Lee de metricas.avisos_*.';

revoke all on function public.admin_metricas_avisos(date, uuid) from public, anon;
grant execute on function public.admin_metricas_avisos(date, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. La RPC de la comparación: varias cohortes seguidas
-- ---------------------------------------------------------------------------

create or replace function public.admin_metricas_avisos_semanas(
  p_semana      date,
  p_merchant_id uuid default null,
  p_semanas     integer default 8
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_hoy    date := metricas.hoy();
  v_lunes  date := metricas.lunes(coalesce(p_semana, metricas.hoy()));
  v_n      integer := least(greatest(coalesce(p_semanas, 8), 1), 26);
  v_desde  date;
  v_res    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_lunes > metricas.lunes(v_hoy) then
    v_lunes := metricas.lunes(v_hoy);
  end if;
  v_desde := v_lunes - 7 * (v_n - 1);

  with
  r as (
    select * from metricas.avisos_por_cohorte(v_desde, v_lunes, p_merchant_id)
  ),
  s as (
    select g::date as semana, q.n as sequence
    from generate_series(v_desde::timestamp, v_lunes::timestamp, interval '7 days') g
    cross join (values (1::smallint), (2::smallint)) q(n)
  )
  select jsonb_build_object(
    'semana', jsonb_build_object(
      'desde',    v_lunes,
      'hasta',    v_lunes + 6,
      'en_curso', v_lunes = metricas.lunes(v_hoy)
    ),
    'hoy',   v_hoy,
    'ahora', now(),
    'local', p_merchant_id,
    'semanas', (
      select coalesce(jsonb_agg(w.fila order by w.semana), '[]'::jsonb)
      from (
        select s1.semana, jsonb_build_object(
          'semana',   s1.semana,
          'en_curso', s1.semana = metricas.lunes(v_hoy),
          'cuotas', (
            select jsonb_agg(jsonb_build_object(
              'numero',                 s.sequence,
              'estado', case
                          when r.semana is null               then 'sin_consumos'
                          when r.primer_envio is null
                            or r.primer_envio > now()         then 'sin_empezar'
                          when r.ultimo_envio > now()         then 'en_curso'
                          else                                     'cerrada'
                        end,
              'personas',               coalesce(r.personas, 0),
              'avisadas',               coalesce(r.avisadas, 0),
              'recibieron',             coalesce(r.recibieron, 0),
              'pagaron_antes',          coalesce(r.pagaron_antes, 0),
              'pagaron_tras_aviso',     coalesce(r.pagaron_tras_aviso, 0),
              'sin_pagar',              coalesce(r.sin_pagar, 0),
              'destinatarios_avisados', coalesce(r.destinatarios_avisados, 0),
              'pagaron_24h',            coalesce(r.pagaron_24h, 0),
              'pagaron_72h',            coalesce(r.pagaron_72h, 0),
              'avisos',                 coalesce(r.avisos, 0),
              'avisos_entregados',      coalesce(r.avisos_entregados, 0),
              'avisos_sin_dato',        coalesce(r.avisos_sin_dato, 0)
            ) order by s.sequence)
            from s
            left join r on r.semana = s.semana and r.sequence = s.sequence
            where s.semana = s1.semana
          )
        ) as fila
        from (select distinct s.semana from s) s1
      ) w
    )
  )
  into v_res;

  return v_res;
end;
$fn$;

comment on function public.admin_metricas_avisos_semanas(date, uuid, integer) is
  'Métricas › Avisos, comparar cohortes: las p_semanas semanas de consumo que acaban en p_semana (lunes), cada una con su cuota 1 y 2 (metricas.avisos_por_cohorte): personas, avisadas, les llegó, pagaron antes o tras un aviso, sin pagar y la efectividad (pagaron en 24 h ÷ destinatarios avisados). estado: sin_consumos, sin_empezar, en_curso o cerrada.';

revoke all on function public.admin_metricas_avisos_semanas(date, uuid, integer) from public, anon;
grant execute on function public.admin_metricas_avisos_semanas(date, uuid, integer) to authenticated;
