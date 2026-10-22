-- ============================================================================
-- Helios — El asistente del superadmin lee pacientes, clínicas y órdenes
-- (2026-10-23, fase 5 del plan: docs/00 §11)
--
-- Las vistas del esquema `asistente` llegaron de Ronda con la base
-- consolidada: hablan de locales, consumos, grupos, push y euros. El
-- asistente de Helios (`functions/admin-asistente`) lee estas otras, con el
-- vocabulario del superadmin y los montos en dólares (`_usd`, como el libro).
--
-- Solo lectura, como antes: las lee `asistente_lector` por
-- `admin_assistant_query`, que no cambia. Ninguna enseña teléfono, cédula,
-- correo ni dirección; el nombre llega acortado («MARÍA P.»).
--
-- Fuera: `consumos`, `locales`, `personas`, `notificaciones`,
-- `plantillas_push` (no hay app ni push) y `cargos_por_atraso` (sin mora
-- desde el 2026-10-07). Nada de la base depende de ellas.
-- ============================================================================

drop view asistente.consumos;
drop view asistente.cuotas;
drop view asistente.locales;
drop view asistente.personas;
drop view asistente.pagos_reportados;
drop view asistente.pagos_a_locales;
drop view asistente.cargos_por_atraso;
drop view asistente.contactos_cobranza;
drop view asistente.notificaciones;
drop view asistente.plantillas_push;
drop view asistente.niveles;

-- En Helios el día empieza a medianoche (helios_business_date): el «día» de
-- una orden o de un pago es el día natural de Caracas.
create or replace function asistente.estado(p_dominio text, p_valor text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
  select coalesce(case p_dominio || ':' || p_valor
    when 'paciente:pending_kyc'  then 'sin verificar'
    when 'paciente:pending_pin'  then 'sin PIN'
    when 'paciente:active'       then 'activo'
    when 'paciente:frozen'       then 'congelado'
    when 'paciente:suspended'    then 'suspendido'
    when 'paciente:expelled'     then 'cerrado'
    when 'orden:pending'         then 'esperando al paciente'
    when 'orden:confirmed'       then 'confirmada'
    when 'orden:voided'          then 'anulada'
    when 'orden:reverted'        then 'revertida'
    when 'orden:declined'        then 'rechazada por el paciente'
    when 'orden:expired'         then 'vencida sin respuesta'
    when 'cuota:pending'         then 'pendiente'
    when 'cuota:paid'            then 'pagada'
    when 'pago:reported'         then 'reportado'
    when 'pago:in_review'        then 'en revisión'
    when 'pago:reconciled'       then 'aprobado'
    when 'pago:rejected'         then 'rechazado'
    when 'pago:duplicate'        then 'duplicado'
    when 'clinica:active'        then 'activa'
    when 'clinica:paused'        then 'pausada'
    when 'clinica:terminated'    then 'cerrada'
    when 'liquidacion:pending'   then 'pendiente'
    when 'liquidacion:partial'   then 'pagada en parte'
    when 'liquidacion:paid'      then 'pagada'
    when 'motivo:advance'               then 'adelanto'
    when 'motivo:scheduled_installment' then 'mitad de la consulta'
    when 'motivo:on_collection'         then 'al cobrar'
    when 'motivo:staff_commission'      then 'comisión del personal'
  end, p_valor)
$$;

-- El médico titular, como se le nombra en el panel: «Dra. Nadia Khabbaze».
create or replace function asistente.medico(p_titulo text, p_nombre text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
  select nullif(trim(coalesce(nullif(trim(p_titulo), '') || ' ', '') || coalesce(trim(p_nombre), '')), '')
$$;

create view asistente.clinicas as
select
  m.id                                   as clinica_id,
  m.name                                 as clinica,
  asistente.medico(m.doctor_title, m.owner_name) as medico,
  m.specialty                            as especialidad,
  m.category::text                       as categoria,
  asistente.estado('clinica', m.status::text) as estado,
  m.city                                 as ciudad,
  m.created_at                           as alta_at
from public.merchants m
where not m.is_test;

create view asistente.pacientes as
select
  p.id                                   as user_id,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as paciente,
  p.created_at                           as alta_at,
  (p.created_at at time zone 'America/Caracas')::date as alta_dia,
  asistente.estado('paciente', p.status::text) as estado,
  p.level                                as nivel,
  p.is_blacklisted                       as en_lista_negra,
  p.sex                                  as sexo,
  date_part('year', age(asistente.hoy(), p.birth_date))::int as edad,
  p.state                                as estado_del_pais,
  p.city                                 as ciudad,
  m.name                                 as clinica_de_registro,
  o.primera_orden_at,
  o.ultima_orden_at,
  coalesce(o.ordenes, 0)                 as ordenes,
  coalesce(o.consulta_usd, 0)            as consulta_usd
from public.profiles p
left join public.merchants m on m.id = p.registered_merchant_id
left join lateral (
  select min(ch.confirmed_at) as primera_orden_at,
         max(ch.confirmed_at) as ultima_orden_at,
         count(*)             as ordenes,
         sum(ch.base_usd)     as consulta_usd
  from public.charges ch
  where ch.user_id = p.id and ch.status = 'confirmed' and not ch.is_test
) o on true
where not p.is_test;

create view asistente.ordenes as
select
  ch.id                                  as orden_id,
  ch.order_number                        as numero_orden,
  ch.user_id,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as paciente,
  ch.merchant_id                         as clinica_id,
  m.name                                 as clinica,
  asistente.medico(m.doctor_title, m.owner_name) as medico,
  b.name                                 as sede,
  ch.concept                             as concepto,
  asistente.estado('orden', ch.status::text) as estado,
  ch.channel                             as canal,
  ch.currency                            as moneda,
  ch.business_date                       as dia,
  ch.created_at                          as creada_at,
  ch.answered_at                         as respondida_at,
  ch.confirmed_at                        as confirmada_at,
  ch.voided_at                           as anulada_at,
  ch.base_usd                            as consulta_usd,
  ch.consumer_fee_usd                    as comision_usd,
  ch.consumer_fee_vat_usd                as comision_iva_usd,
  ch.amount_usd                          as total_a_cobrar_usd,
  ch.merchant_net_usd                    as a_la_clinica_usd,
  ch.base_cur                            as consulta_en_moneda,
  ch.decline_reason                      as motivo_rechazo
from public.charges ch
left join public.profiles p on p.id = ch.user_id
left join public.merchants m on m.id = ch.merchant_id
left join public.merchant_branches b on b.id = ch.branch_id
where not ch.is_test;

create view asistente.cuotas as
select
  i.id                                   as cuota_id,
  i.charge_id                            as orden_id,
  ch.order_number                        as numero_orden,
  i.user_id,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as paciente,
  ch.merchant_id                         as clinica_id,
  m.name                                 as clinica,
  ch.business_date                       as dia_de_la_orden,
  ch.currency                            as moneda,
  i.sequence                             as numero,
  i.due_date                             as vence_el,
  asistente.estado('cuota', i.status::text) as estado,
  i.status = 'pending' and i.written_off_at is null and i.due_date < asistente.hoy() as vencida,
  case when i.status = 'pending' and i.written_off_at is null and i.due_date < asistente.hoy()
       then asistente.hoy() - i.due_date end as dias_atraso,
  i.amount_usd                           as cuota_usd,
  i.financed_usd                         as consulta_usd,
  i.amount_cur                           as cuota_en_moneda,
  i.paid_at                              as pagada_at,
  (i.paid_at at time zone 'America/Caracas')::date as pagada_dia,
  i.written_off_at                       as castigada_at
from public.installments i
join public.charges ch on ch.id = i.charge_id and ch.status = 'confirmed'
left join public.merchants m on m.id = ch.merchant_id
left join public.profiles p on p.id = i.user_id
where not i.is_test and not ch.is_test;

create view asistente.pagos_reportados as
select
  r.id                                   as pago_id,
  r.user_id,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as paciente,
  asistente.estado('pago', r.status::text) as estado,
  r.method                               as metodo,
  r.bank                                 as banco,
  case when r.receipt_read_id is not null then 'bot' else 'equipo' end as registrado_por,
  r.paid_on                              as pagado_el,
  r.created_at                           as reportado_at,
  r.reviewed_at                          as revisado_at,
  q.amount_usd                           as monto_usd,
  r.declared_amount_ves                  as monto_ves,
  q.installment_count                    as cuotas
from public.payment_reports r
join public.payment_quotes q on q.id = r.quote_id
join public.profiles p on p.id = r.user_id and not p.is_test;

create view asistente.comprobantes as
select
  c.id                                   as lectura_id,
  c.profile_id                           as user_id,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as paciente,
  c.kind                                 as tipo,
  c.status                               as estado,
  c.mode                                 as modo,
  c.reason                               as motivo,
  c.method                               as metodo,
  c.bank                                 as banco,
  c.amount_ves                           as monto_ves,
  c.paid_on                              as pagado_el,
  c.attempts                             as intentos,
  c.created_at                           as recibido_at,
  c.decided_at                           as decidido_at
from public.payment_receipt_reads c
left join public.profiles p on p.id = c.profile_id
where p.id is null or not p.is_test;

create view asistente.liquidaciones as
select
  s.id                                   as liquidacion_id,
  s.merchant_id                          as clinica_id,
  m.name                                 as clinica,
  s.charge_id                            as orden_id,
  ch.order_number                        as numero_orden,
  asistente.estado('motivo', s.reason::text) as motivo,
  asistente.estado('liquidacion', s.status::text) as estado,
  s.due_date                             as se_paga_el,
  s.business_date                        as dia,
  s.currency                             as moneda,
  s.amount_usd                           as monto_usd,
  s.paid_usd                             as pagado_usd,
  s.amount_cur                           as monto_en_moneda
from public.settlements s
join public.merchants m on m.id = s.merchant_id and not m.is_test
left join public.charges ch on ch.id = s.charge_id;

create view asistente.pagos_a_clinicas as
select
  mp.id                                  as pago_id,
  mp.merchant_id                         as clinica_id,
  m.name                                 as clinica,
  mp.amount_usd                          as monto_usd,
  mp.amount_ves                          as monto_ves,
  mp.fx_rate                             as tasa,
  mp.method                              as metodo,
  mp.paid_on                             as pagado_el,
  mp.business_date                       as dia,
  mp.created_at                          as creado_at
from public.merchant_payouts mp
join public.merchants m on m.id = mp.merchant_id and not m.is_test;

create view asistente.contactos_cobranza as
select
  cc.id                                  as contacto_id,
  cc.user_id,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as paciente,
  cc.channel::text                       as canal,
  cc.template                            as plantilla,
  cc.outcome                             as resultado,
  cc.promise_date                        as promesa_para,
  cc.next_action_on                      as proxima_accion,
  cc.contacted_at                        as contactado_at
from public.collection_contacts cc
join public.profiles p on p.id = cc.user_id and not p.is_test;

-- Lo que sale por WhatsApp y por correo. Sin el texto ni el destinatario:
-- llevan datos personales y no contestan nada que no diga la plantilla.
create view asistente.mensajes as
select
  o.id                                   as mensaje_id,
  o.profile_id                           as user_id,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as paciente,
  o.charge_id                            as orden_id,
  o.channel                              as canal,
  o.template_key                         as plantilla,
  o.status                               as estado,
  o.attempts                             as intentos,
  o.last_error                           as error,
  o.created_at                           as creado_at,
  o.sent_at                              as enviado_at
from public.outbound_messages o
left join public.profiles p on p.id = o.profile_id
where p.id is null or not p.is_test;

create view asistente.niveles as
select
  l.level                                as nivel,
  l.label                                as nombre,
  l.monthly_limit_usd                    as limite_usd,
  l.is_active                            as activo
from public.levels l;

grant select on all tables in schema asistente to asistente_lector;
grant execute on function asistente.medico(text, text) to asistente_lector;
