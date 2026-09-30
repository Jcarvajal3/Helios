-- ============================================================================
-- Ronda — Las métricas tienen una sola definición (esquema `metricas`)
--
-- El 19-09 en La Quinta Bar hubo 26 consumos. «Gente» decía 22 y las cuotas
-- decían 32: una pantalla contaba a quien abrió la cuenta (`charges.user_id`)
-- y la otra a todos los que pagaron su parte (`installments.user_id`). Cada RPC
-- del super admin escribía su propia cuenta, y dos cuentas del mismo concepto
-- acaban diciendo cosas distintas.
--
-- Este esquema es el sitio único donde se decide qué es cada cifra. Las RPC
-- `admin_*` leen de aquí y no vuelven a escribir la definición:
--
--   metricas.hoy()                 el día operativo de hoy (10:00 a 10:00).
--   metricas.lunes(d)              el lunes de la semana de `d`.
--   metricas.a_tiempo(dia, vence)  si un pago de ese día llegó a tiempo.
--   metricas.consumos              una fila por consumo confirmado real.
--   metricas.cuotas                una fila por cuota de esos consumos, con su
--                                  estado de hoy.
--   metricas.cuotas_al(dia)        las mismas cuotas tal como estaban al
--                                  cierre de un día operativo.
--   metricas.cartera_al(dia,local) lo vencido, lo por vencer, lo perdido y la
--                                  mora, al cierre de un día.
--   metricas.personas              una fila por registro real.
--   metricas.personas_por_local    una fila por persona y local.
--
-- Reglas que valen para todo el esquema:
--   * Sin pruebas: fuera los consumos con `charges.is_test` (la bandera ya
--     copia la de la persona que abre y la del local; `installments.is_test`
--     es copia de la del consumo) y los perfiles con `profiles.is_test`.
--   * Personas desde las cuotas. En un consumo de grupo cada persona que pagó
--     su parte tiene su cuota; `charges.user_id` es solo quien abrió la cuenta.
--   * Dos clases de dinero que no se suman nunca: financed (el consumo, sin
--     servicio) y payable (lo que se paga, con el servicio y su IVA). El
--     servicio y su IVA van en sus propias columnas.
--   * Las columnas se llaman `_usd` pero el dinero es EURO.
--
-- Sin acceso para `anon` ni `authenticated`: no se expone por la API y solo lo
-- leen las funciones `security definer` del super admin (que corren como su
-- dueño). Las funciones de tabla son `language sql` sin `set` ni `security
-- definer` a propósito: así el planificador puede meterlas dentro de la
-- consulta que las llama y empujar los filtros (por local, por día) hasta las
-- tablas. Por eso todo va con el esquema escrito.
-- ============================================================================

create schema if not exists metricas;

comment on schema metricas is
  'Definiciones canónicas de las cifras del negocio (una cifra, una definición). Sin acceso para anon/authenticated: lo leen las RPC security definer del super admin.';

revoke all on schema metricas from public;
revoke all on schema metricas from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Días
-- ---------------------------------------------------------------------------

create or replace function metricas.hoy()
returns date
language sql
stable
as $$
  select public.helios_business_date(now());
$$;

comment on function metricas.hoy() is
  'El día operativo de hoy: de 10:00 a 10:00 hora de Caracas (public.helios_business_date(now())). Lo que se vende el sábado a las 2:00 es del viernes.';

create or replace function metricas.lunes(d date)
returns date
language sql
immutable
as $$
  select d - (extract(isodow from d)::integer - 1);
$$;

comment on function metricas.lunes(date) is
  'El lunes de la semana de un día operativo. La semana del negocio va de lunes a domingo.';

-- ---------------------------------------------------------------------------
-- 2. A tiempo
-- ---------------------------------------------------------------------------
-- Una cuota se paga a tiempo si el día operativo de su pago no pasa del
-- vencimiento más los días de gracia (`on_time_grace_days`, hoy 2). La
-- versión de tres argumentos existe para que una consulta que evalúa miles de
-- filas lea el parámetro una vez; la de dos es la que se usa suelta.

create or replace function metricas.a_tiempo(pagada_dia date, vence date, gracia integer)
returns boolean
language sql
immutable
as $$
  select coalesce(pagada_dia <= vence + gracia, false);
$$;

create or replace function metricas.a_tiempo(pagada_dia date, vence date)
returns boolean
language sql
stable
as $$
  select metricas.a_tiempo(pagada_dia, vence, public.helios_on_time_grace_days());
$$;

comment on function metricas.a_tiempo(date, date, integer) is
  'Si un pago hecho el día operativo `pagada_dia` llega a tiempo a una cuota que vence `vence`, con `gracia` días de margen. Falso si no hay pago.';
comment on function metricas.a_tiempo(date, date) is
  'Si un pago hecho el día operativo `pagada_dia` llega a tiempo a una cuota que vence `vence`: pagada_dia <= vence + helios_on_time_grace_days(). Falso si no hay pago.';

-- ---------------------------------------------------------------------------
-- 3. Los consumos
-- ---------------------------------------------------------------------------
-- El dinero sale de las cuotas y no de `charges`: sus `financed_usd` suman el
-- `base_usd` del consumo y son lo único que sabe quién puso qué en un grupo.
-- `iva_usd` es el resto entre el fee y el servicio, para que siempre se cumpla
-- financed + servicio + iva = payable: desde el 2026-08-30 es solo el IVA del
-- servicio; en los consumos anteriores lleva también el IVA de la venta, que
-- entonces Ronda cobraba aparte (`charges.vat_usd`).

create or replace view metricas.consumos as
select
  c.id                                                         as charge_id,
  c.business_date                                              as business_date,
  metricas.lunes(c.business_date)                              as semana,
  c.merchant_id                                                as merchant_id,
  c.branch_id                                                  as branch_id,
  c.group_id                                                   as group_id,
  c.user_id                                                    as abrio_user_id,
  c.confirmed_at                                               as confirmed_at,
  coalesce(q.financed, 0)::numeric                             as financed_usd,
  (coalesce(q.payable, 0) - coalesce(q.financed, 0))::numeric  as fee_usd,
  coalesce(q.payable, 0)::numeric                              as payable_usd,
  coalesce(c.consumer_fee_usd, 0)::numeric                     as servicio_usd,
  (coalesce(q.payable, 0) - coalesce(q.financed, 0)
     - coalesce(c.consumer_fee_usd, 0))::numeric               as iva_usd,
  coalesce(q.personas, 0)::integer                             as personas,
  (c.group_id is not null)                                     as es_grupo,
  c.order_number                                               as order_number,
  coalesce(q.cuotas, 0)::integer                               as cuotas,
  coalesce(c.merchant_fee_usd, 0)::numeric                     as comision_local_usd,
  coalesce(c.merchant_net_usd, c.amount_usd)::numeric          as neto_local_usd
from public.charges c
left join lateral (
  select sum(i.financed_usd)          as financed,
         sum(i.amount_usd)            as payable,
         count(distinct i.user_id)    as personas,
         count(*)                     as cuotas
  from public.installments i
  where i.charge_id = c.id
    and not i.is_test
) q on true
where c.status = 'confirmed'
  and not c.is_test
  and c.business_date is not null;

comment on view metricas.consumos is
  'Una fila por consumo confirmado que no es de prueba. Consumo = financed_usd (sin servicio). Consumos = count(*). Ticket medio = sum(financed_usd) / count(*).';
comment on column metricas.consumos.charge_id is 'El consumo (charges.id).';
comment on column metricas.consumos.business_date is 'Día operativo del consumo (10:00 a 10:00 de Caracas).';
comment on column metricas.consumos.semana is 'Lunes de la semana del consumo: la cohorte de consumo.';
comment on column metricas.consumos.merchant_id is 'Local donde se consumió.';
comment on column metricas.consumos.branch_id is 'Sucursal donde se consumió.';
comment on column metricas.consumos.group_id is 'Grupo, si el consumo se hizo en uno.';
comment on column metricas.consumos.abrio_user_id is 'Quien abrió la cuenta (charges.user_id). NO es «la persona que consumió»: en un grupo pagan más. Úsese solo en cifras que digan «quien abrió la cuenta».';
comment on column metricas.consumos.confirmed_at is 'Instante en que se confirmó.';
comment on column metricas.consumos.financed_usd is 'FINANCED. El consumo en el local, sin el servicio de Helios ni su IVA: suma de installments.financed_usd (= charges.base_usd). Es «Consumo».';
comment on column metricas.consumos.fee_usd is 'payable_usd − financed_usd: el servicio de Helios con su IVA. Nunca se suma a un total: va como cuota o como línea aparte.';
comment on column metricas.consumos.payable_usd is 'PAYABLE. Lo que se paga en cuotas: suma de installments.amount_usd (= charges.amount_usd). Solo se enseña como cuotas y con su desglose.';
comment on column metricas.consumos.servicio_usd is 'El servicio de Helios SIN IVA (charges.consumer_fee_usd). Es el ingreso de Helios por el consumo; nunca sumado al consumo.';
comment on column metricas.consumos.iva_usd is 'fee_usd − servicio_usd. El IVA del servicio (y, en consumos anteriores al 2026-08-30, también el IVA de la venta que Helios cobraba aparte). No es de Helios: se remite.';
comment on column metricas.consumos.personas is 'Personas con cuota en este consumo (count distinct installments.user_id). En un grupo, todos los que pagaron su parte.';
comment on column metricas.consumos.es_grupo is 'Se hizo dentro de un grupo (group_id no nulo). Un grupo de una sola persona también cuenta.';
comment on column metricas.consumos.order_number is 'Número de orden: identifica el consumo ante el local y la persona.';
comment on column metricas.consumos.cuotas is 'Cuántas cuotas tiene el consumo (una por persona y número de cuota).';
comment on column metricas.consumos.comision_local_usd is 'Comisión que Helios le cobra al local, sin IVA (charges.merchant_fee_usd). Cero desde el 2026-08-30.';
comment on column metricas.consumos.neto_local_usd is 'Lo que se le paga al local por este consumo (charges.merchant_net_usd; amount_usd en los consumos anteriores al desglose).';

-- ---------------------------------------------------------------------------
-- 4. Las cuotas, al cierre de un día
-- ---------------------------------------------------------------------------
-- Una sola función escribe el estado de una cuota; la vista `metricas.cuotas`
-- es esta misma función con el día de hoy.
--
-- «Al cierre de p_dia» quiere decir a las 10:00 del día siguiente, cuando
-- p_dia ya terminó: lo pagado o dado por perdido hasta ese instante cuenta, y
-- una cuota que vencía ese mismo día ya está vencida. Si p_dia es hoy o
-- futuro, es el estado de ahora mismo y «hoy» es hoy (una cuota que vence hoy
-- todavía está por vencer). Lo que no se puede reconstruir: las cuotas de un
-- consumo revertido, que se borran con él.
--
-- El día del pago es el de `paid_at`, que pone `reconcile_payment` al APROBAR
-- el reporte, no cuando la persona lo hizo. El momento en que la persona
-- reportó el pago que la saldó está en `reportada_en`. «A tiempo» se juzga con
-- la aprobación, como el motor de cobranza y el resto del panel; si algún día
-- se juzga con el reporte, se cambia `pagada_dia` aquí y nada más.

create or replace function metricas.cuotas_al(p_dia date)
returns table (
  installment_id     uuid,
  charge_id          uuid,
  user_id            uuid,
  sequence           smallint,
  due_date           date,
  payable_usd        numeric,
  financed_usd       numeric,
  fee_usd            numeric,
  status             text,
  paid_at            timestamptz,
  pagada_dia         date,
  reportada_en       timestamptz,
  written_off_at     timestamptz,
  business_date      date,
  semana             date,
  merchant_id        uuid,
  group_id           uuid,
  estado_hoy         text,
  dias_atraso        integer,
  plazo_cerrado      boolean,
  reportada_dia      date,
  report_id          uuid,
  branch_id          uuid,
  es_grupo           boolean,
  dia_de_referencia  date
)
language sql
stable
as $$
  with ref as (
    select
      -- El día que hace de «hoy» para decidir si algo está vencido.
      case when p_dia < h.hoy then p_dia + 1 else h.hoy end              as dia,
      -- Hasta qué instante cuenta un pago o una pérdida.
      case when p_dia < h.hoy then public.helios_business_day_end(p_dia)
           else now() end                                                as corte,
      -- Hasta qué día operativo existían los consumos.
      least(p_dia, h.hoy)                                                as hasta,
      public.helios_on_time_grace_days()                                  as gracia
    from (select metricas.hoy() as hoy) h
  ),
  q as (
    select
      i.id, i.charge_id, i.user_id, i.sequence, i.due_date,
      i.amount_usd, i.financed_usd, i.paid_at, i.written_off_at,
      i.paid_by_report_id,
      c.business_date, c.merchant_id, c.branch_id, c.group_id,
      r.dia, r.gracia,
      (i.status = 'paid' and (i.paid_at is null or i.paid_at <= r.corte))  as pagada,
      (i.written_off_at is not null and i.written_off_at <= r.corte)       as perdida,
      -- EL día del pago: el único sitio que lo decide.
      public.helios_business_date(i.paid_at)                                as dia_pago,
      pr.created_at                                                        as reportada_en
    from public.installments i
    join public.charges c on c.id = i.charge_id
    left join public.payment_reports pr on pr.id = i.paid_by_report_id
    cross join ref r
    where c.status = 'confirmed'
      and not c.is_test
      and not i.is_test
      and c.business_date is not null
      and c.business_date <= r.hasta
  )
  select
    q.id,
    q.charge_id,
    q.user_id,
    q.sequence,
    q.due_date,
    q.amount_usd::numeric,
    q.financed_usd::numeric,
    (q.amount_usd - q.financed_usd)::numeric,
    case when q.pagada then 'paid' else 'pending' end,
    case when q.pagada then q.paid_at end,
    case when q.pagada then q.dia_pago end,
    case when q.pagada then q.reportada_en end,
    case when q.perdida then q.written_off_at end,
    q.business_date,
    metricas.lunes(q.business_date),
    q.merchant_id,
    q.group_id,
    case
      when q.pagada and metricas.a_tiempo(q.dia_pago, q.due_date, q.gracia)
                              then 'a_tiempo'
      when q.pagada           then 'tarde'
      when q.perdida          then 'perdida'
      when q.due_date < q.dia then 'vencida'
      else                         'por_vencer'
    end,
    case
      when q.pagada           then greatest(q.dia_pago - q.due_date, 0)
      when q.due_date < q.dia then q.dia - q.due_date
      else 0
    end,
    q.due_date + q.gracia < q.dia,
    case when q.pagada then public.helios_business_date(q.reportada_en) end,
    case when q.pagada then q.paid_by_report_id end,
    q.branch_id,
    q.group_id is not null,
    q.dia
  from q;
$$;

comment on function metricas.cuotas_al(date) is
  'Las cuotas de metricas.cuotas con su estado AL CIERRE del día operativo p_dia (a las 10:00 del día siguiente). Con p_dia >= hoy, el estado de ahora. Mismas columnas que metricas.cuotas.';

create or replace view metricas.cuotas as
select * from metricas.cuotas_al(metricas.hoy());

comment on view metricas.cuotas is
  'Una fila por cuota que no es de prueba de un consumo confirmado, con su estado de hoy. Vencida, por vencer, perdida, a tiempo y tarde salen de estado_hoy. Cobro a tiempo (tasa) = cuotas con estado_hoy = ''a_tiempo'' ÷ cuotas con plazo_cerrado. Mora (tasa): metricas.cartera_al.';
comment on column metricas.cuotas.installment_id is 'La cuota (installments.id).';
comment on column metricas.cuotas.charge_id is 'El consumo al que pertenece.';
comment on column metricas.cuotas.user_id is 'Quien debe la cuota. Es LA persona del consumo: en un grupo, cada una tiene las suyas.';
comment on column metricas.cuotas.sequence is 'Número de cuota: 1 o 2.';
comment on column metricas.cuotas.due_date is 'Día en que vence (día operativo).';
comment on column metricas.cuotas.payable_usd is 'PAYABLE. Lo que se cobra en esta cuota (installments.amount_usd), con el servicio y su IVA. Siempre con su desglose financed_usd + fee_usd.';
comment on column metricas.cuotas.financed_usd is 'FINANCED. La parte de consumo de la cuota, sin servicio (installments.financed_usd).';
comment on column metricas.cuotas.fee_usd is 'payable_usd − financed_usd: el servicio y su IVA dentro de la cuota.';
comment on column metricas.cuotas.status is '''paid'' o ''pending'' en el momento del corte.';
comment on column metricas.cuotas.paid_at is 'Instante en que se APROBÓ el pago que la saldó (reconcile_payment pone now()). Nulo si no estaba pagada en el corte.';
comment on column metricas.cuotas.pagada_dia is 'Día operativo de paid_at: el día del pago con el que se juzga si llegó a tiempo (el de la aprobación, no el del reporte).';
comment on column metricas.cuotas.reportada_en is 'Instante en que la persona REPORTÓ el pago que la saldó (payment_reports.created_at de paid_by_report_id). Es «cuándo pagó» para medir los avisos.';
comment on column metricas.cuotas.written_off_at is 'Instante en que se dio por perdida, si ya lo estaba en el corte.';
comment on column metricas.cuotas.business_date is 'Día operativo del consumo que la generó.';
comment on column metricas.cuotas.semana is 'Lunes de la semana del consumo: la cohorte de la cuota.';
comment on column metricas.cuotas.merchant_id is 'Local del consumo.';
comment on column metricas.cuotas.group_id is 'Grupo del consumo, si lo hubo.';
comment on column metricas.cuotas.estado_hoy is 'a_tiempo: pagada y pagada_dia <= due_date + gracia. tarde: pagada fuera de plazo. perdida: sin pagar y dada por perdida. vencida: sin pagar, no perdida y due_date < hoy. por_vencer: sin pagar, no perdida y due_date >= hoy. Excluyentes.';
comment on column metricas.cuotas.dias_atraso is 'Pagada: días entre el vencimiento y el día del pago (0 si se pagó antes). Sin pagar: días desde el vencimiento hasta hoy (0 si no ha vencido).';
comment on column metricas.cuotas.plazo_cerrado is 'due_date + gracia < hoy: el veredicto a tiempo / tarde ya es definitivo. Es la población del cobro a tiempo.';
comment on column metricas.cuotas.reportada_dia is 'Día operativo de reportada_en.';
comment on column metricas.cuotas.report_id is 'El reporte de pago que la saldó (installments.paid_by_report_id).';
comment on column metricas.cuotas.branch_id is 'Sucursal del consumo.';
comment on column metricas.cuotas.es_grupo is 'El consumo se hizo en un grupo.';
comment on column metricas.cuotas.dia_de_referencia is 'El día que hace de «hoy» en el estado: hoy, o el siguiente a p_dia si p_dia ya cerró.';

-- ---------------------------------------------------------------------------
-- 5. La cartera y la mora
-- ---------------------------------------------------------------------------
-- Mora = vencido ÷ (vencido + por vencer), en payable, sin lo dado por
-- perdido. Es la de `admin_overview` desde el 2026-09-02: lo perdido tiene su
-- propia cifra, y si siguiera en el numerador la mora no podría bajar nunca.
-- Nula cuando no hay nada vivo: un 0 % sin denominador es una cifra inventada.

create or replace function metricas.cartera_al(p_dia date, p_merchant_id uuid default null)
returns table (
  dia_de_referencia        date,
  vencido_payable_usd      numeric,
  vencido_financed_usd     numeric,
  vencido_fee_usd          numeric,
  por_vencer_payable_usd   numeric,
  por_vencer_financed_usd  numeric,
  por_vencer_fee_usd       numeric,
  perdido_payable_usd      numeric,
  perdido_financed_usd     numeric,
  perdido_fee_usd          numeric,
  mora_pct                 numeric,
  cuotas_vencidas          integer,
  personas_vencidas        integer
)
language sql
stable
as $$
  select
    coalesce(max(q.dia_de_referencia),
             case when p_dia < metricas.hoy() then p_dia + 1 else metricas.hoy() end),
    coalesce(sum(q.payable_usd)  filter (where q.estado_hoy = 'vencida'), 0),
    coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'vencida'), 0),
    coalesce(sum(q.fee_usd)      filter (where q.estado_hoy = 'vencida'), 0),
    coalesce(sum(q.payable_usd)  filter (where q.estado_hoy = 'por_vencer'), 0),
    coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'por_vencer'), 0),
    coalesce(sum(q.fee_usd)      filter (where q.estado_hoy = 'por_vencer'), 0),
    coalesce(sum(q.payable_usd)  filter (where q.estado_hoy = 'perdida'), 0),
    coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'perdida'), 0),
    coalesce(sum(q.fee_usd)      filter (where q.estado_hoy = 'perdida'), 0),
    round(100 * coalesce(sum(q.payable_usd) filter (where q.estado_hoy = 'vencida'), 0)
          / nullif(sum(q.payable_usd) filter (where q.estado_hoy in ('vencida', 'por_vencer')), 0), 2),
    (count(*) filter (where q.estado_hoy = 'vencida'))::integer,
    (count(distinct q.user_id) filter (where q.estado_hoy = 'vencida'))::integer
  from metricas.cuotas_al(p_dia) q
  where p_merchant_id is null or q.merchant_id = p_merchant_id;
$$;

comment on function metricas.cartera_al(date, uuid) is
  'La cartera al cierre de p_dia (hoy = estado de ahora), de todos los locales o de uno: vencido, por vencer y perdido en payable con su desglose financed + fee, y la mora = vencido ÷ (vencido + por vencer) en payable, sin lo perdido (nula si no hay nada vivo).';

-- ---------------------------------------------------------------------------
-- 6. Las personas
-- ---------------------------------------------------------------------------
-- Un registro es un perfil real con el teléfono confirmado
-- (`public.helios_signups`, 20260920100000): un perfil nace cuando se PIDE el
-- código por SMS, y quien nunca lo metió no se registró. Verificado = tiene
-- una verificación de identidad aprobada.

create or replace view metricas.personas as
select
  s.user_id                                         as user_id,
  s.dia                                             as registro_dia,
  metricas.lunes(s.dia)                             as registro_semana,
  (v.dia is not null)                               as verificado,
  s.status::text                                    as estado,
  s.level                                           as nivel,
  k.primer_dia                                      as primer_consumo_dia,
  k.primer_merchant_id                              as primer_merchant_id,
  v.dia                                             as verificado_dia,
  metricas.lunes(k.primer_dia)                      as primer_consumo_semana,
  k.ultimo_dia                                      as ultimo_consumo_dia,
  coalesce(k.consumos, 0)::integer                  as consumos,
  coalesce(k.noches, 0)::integer                    as noches,
  coalesce(k.financed, 0)::numeric                  as financed_usd
from public.helios_signups s
left join (
  select vv.user_id,
         min(public.helios_business_date(coalesce(vv.reviewed_at, vv.created_at))) as dia
  from kyc.verifications vv
  where vv.status = 'approved'
  group by vv.user_id
) v on v.user_id = s.user_id
left join (
  select q.user_id,
         min(q.business_date)                   as primer_dia,
         max(q.business_date)                   as ultimo_dia,
         count(distinct q.charge_id)            as consumos,
         count(distinct q.business_date)        as noches,
         sum(q.financed_usd)                    as financed,
         (array_agg(q.merchant_id order by q.business_date, c.confirmed_at, q.charge_id))[1]
                                                as primer_merchant_id
  from metricas.cuotas q
  join public.charges c on c.id = q.charge_id
  group by q.user_id
) k on k.user_id = s.user_id;

comment on view metricas.personas is
  'Una fila por registro: perfil que no es de prueba con el teléfono confirmado (public.helios_signups). Registro = por registro_dia. Han comprado = primer_consumo_dia no nulo.';
comment on column metricas.personas.user_id is 'La persona (profiles.id).';
comment on column metricas.personas.registro_dia is 'Día operativo de profiles.created_at: el día en que se registró.';
comment on column metricas.personas.registro_semana is 'Lunes de la semana del registro.';
comment on column metricas.personas.verificado is 'Tiene una verificación de identidad aprobada (kyc.verifications).';
comment on column metricas.personas.estado is 'profiles.status de hoy (pending_kyc, pending_pin, active, frozen, suspended, expelled).';
comment on column metricas.personas.nivel is 'profiles.level de hoy.';
comment on column metricas.personas.primer_consumo_dia is 'Día operativo de su primera cuota (de un consumo propio o de su parte en un grupo). Nulo si nunca consumió.';
comment on column metricas.personas.primer_merchant_id is 'Local de ese primer consumo.';
comment on column metricas.personas.verificado_dia is 'Día operativo de su primera verificación aprobada.';
comment on column metricas.personas.primer_consumo_semana is 'Lunes de la semana del primer consumo.';
comment on column metricas.personas.ultimo_consumo_dia is 'Día operativo de su último consumo.';
comment on column metricas.personas.consumos is 'En cuántos consumos tiene cuota (los suyos y aquellos de grupo en que pagó su parte).';
comment on column metricas.personas.noches is 'En cuántos días operativos distintos consumió.';
comment on column metricas.personas.financed_usd is 'FINANCED. Todo lo que ha consumido, sin servicio (su parte en los grupos).';

create or replace view metricas.personas_por_local as
select
  q.user_id                               as user_id,
  q.merchant_id                           as merchant_id,
  min(q.business_date)                    as primer_dia,
  metricas.lunes(min(q.business_date))    as primer_semana,
  max(q.business_date)                    as ultimo_dia,
  count(distinct q.business_date)::integer as noches,
  count(distinct q.charge_id)::integer    as consumos,
  sum(q.financed_usd)::numeric            as financed_usd
from metricas.cuotas q
group by q.user_id, q.merchant_id;

comment on view metricas.personas_por_local is
  'Una fila por persona y local donde tiene alguna cuota. «Nuevo en un local» un día o una semana = su primer_dia (o primer_semana) en ESE local es ese día o esa semana.';
comment on column metricas.personas_por_local.primer_dia is 'Día operativo de su primera cuota en este local.';
comment on column metricas.personas_por_local.primer_semana is 'Lunes de la semana de primer_dia.';
comment on column metricas.personas_por_local.ultimo_dia is 'Día operativo de su última cuota en este local.';
comment on column metricas.personas_por_local.noches is 'Días operativos distintos en que consumió aquí.';
comment on column metricas.personas_por_local.consumos is 'Consumos de este local en los que tiene cuota.';
comment on column metricas.personas_por_local.financed_usd is 'FINANCED. Lo que consumió aquí, sin servicio.';

-- ---------------------------------------------------------------------------
-- 7. Permisos
-- ---------------------------------------------------------------------------
-- Postgres da EXECUTE a PUBLIC en toda función nueva; sin USAGE sobre el
-- esquema nadie puede llegar a ellas, pero se quita igual.

revoke all on all tables in schema metricas from public, anon, authenticated;
revoke all on all functions in schema metricas from public, anon, authenticated;
alter default privileges in schema metricas revoke execute on functions from public;
