-- ============================================================================
-- Ronda — El asistente habla con nombres y ve los productos
--
-- Las vistas de 20260925170000 respondían con identificadores y con los
-- estados en inglés de la base (`delivered`, `reconciled`): el asistente los
-- copiaba tal cual y quien pregunta no es programador. Además no veía los
-- productos de cada cuenta, así que contestaba que Ronda no los guarda.
--
--   1. `asistente.nombre_corto` y `asistente.estado`: el nombre acortado de
--      una persona («MARÍA P.») y cada estado en español.
--   2. Todas las vistas dicen los estados en español y, donde hay una persona,
--      un local o un consumo, suman su nombre, su local y su número de orden
--      (las columnas nuevas van al final: `create or replace view` no deja
--      moverlas).
--   3. `personas` cuenta los consumos desde las cuotas: en un consumo de grupo
--      cada integrante consumió, no solo quien abrió la cuenta.
--   4. Dos vistas nuevas: `productos_vendidos` (cada línea de cada cuenta
--      confirmada) y `productos` (la carta de cada local).
--
-- Los importes de producto son consumo SIN el fee: la suma de las líneas de
-- una cuenta es su `base_usd`, céntimo a céntimo (comprobado en producción).
-- ============================================================================

-- ── Ayudantes ───────────────────────────────────────────────────────────────

-- «MARÍA JOSEFINA PÉREZ GÓMEZ» → «MARÍA P.», como enmascarar.ts: sin apellido
-- guardado aparte, el del nombre completo (el tercero con cuatro palabras o
-- más, si no el segundo).
create or replace function asistente.nombre_corto(p_nombre text, p_apellido text, p_completo text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
  with partes as (
    select regexp_split_to_array(trim(coalesce(p_completo, '')), '\s+') as p
  )
  select nullif(trim(
    upper(coalesce(nullif(split_part(trim(coalesce(p_nombre, '')), ' ', 1), ''), nullif(p[1], ''), ''))
    || coalesce(' ' || upper(left(coalesce(
         nullif(trim(p_apellido), ''),
         case when coalesce(array_length(p, 1), 0) >= 4 then p[3]
              when coalesce(array_length(p, 1), 0) >= 2 then p[2] end
       ), 1)) || '.', '')
  ), '')
  from partes
$$;

comment on function asistente.nombre_corto(text, text, text) is
  'El nombre de una persona acortado: primer nombre e inicial del apellido.';

create or replace function asistente.estado(p_dominio text, p_valor text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
  select coalesce(case p_dominio || ':' || p_valor
    when 'persona:pending_kyc'       then 'sin verificar'
    when 'persona:pending_pin'       then 'sin PIN'
    when 'persona:active'            then 'activa'
    when 'persona:frozen'            then 'congelada'
    when 'persona:suspended'         then 'suspendida'
    when 'persona:expelled'          then 'cerrada'
    when 'kyc:pending'               then 'pendiente'
    when 'kyc:processing'            then 'en proceso'
    when 'kyc:approved'              then 'aprobada'
    when 'kyc:rejected'              then 'rechazada'
    when 'kyc:manual_review'         then 'revisión manual'
    when 'consumo:pending'           then 'pendiente'
    when 'consumo:confirmed'         then 'confirmado'
    when 'consumo:voided'            then 'anulado'
    when 'consumo:reverted'          then 'revertido'
    when 'cuota:pending'             then 'pendiente'
    when 'cuota:paid'                then 'pagada'
    when 'pago:reported'             then 'reportado'
    when 'pago:in_review'            then 'en revisión'
    when 'pago:reconciled'           then 'aprobado'
    when 'pago:rejected'             then 'rechazado'
    when 'pago:duplicate'            then 'duplicado'
    when 'cargo:pending'             then 'pendiente'
    when 'cargo:paid'                then 'pagado'
    when 'cargo:written_off'         then 'castigado'
    when 'push:pending'              then 'en cola'
    when 'push:sent'                 then 'enviado'
    when 'push:delivered'            then 'entregado'
    when 'push:failed'               then 'fallido'
    when 'push:cancelled'            then 'cancelado'
    when 'local:active'              then 'activo'
    when 'local:paused'              then 'pausado'
    when 'local:terminated'          then 'cerrado'
    when 'grupo:active'              then 'activo'
    when 'grupo:closed'              then 'cerrado'
    when 'miembro:active'            then 'activo'
    when 'miembro:paused'            then 'en pausa'
    when 'miembro:left'              then 'salió'
  end, p_valor)
$$;

comment on function asistente.estado(text, text) is
  'El estado de la base, dicho en español para quien lee el asistente.';

-- ── Vistas de siempre, con nombres y estados en español ─────────────────────

create or replace view asistente.personas as
select
  p.id                                                      as user_id,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as nombre,
  p.created_at                                              as alta_at,
  (p.created_at at time zone 'America/Caracas')::date       as alta_dia,
  asistente.estado('persona', p.status::text)               as estado,
  p.level                                                   as nivel,
  p.is_blacklisted                                          as en_lista_negra,
  g.extracted_gender                                        as sexo,
  coalesce(d.sistema, a.sistema)                            as sistema,
  case when d.sistema is not null then 'didit'
       when a.sistema is not null then 'app' end            as sistema_fuente,
  asistente.estado('kyc', k.status::text)                   as kyc_estado,
  c.primer_consumo_at,
  coalesce(c.consumos, 0)                                   as consumos,
  coalesce(c.consumo_eur, 0)                                as consumo_eur,
  c.ultimo_consumo_at
from public.profiles p
left join lateral (
  select v.extracted_gender from kyc.verifications v
   where v.user_id = p.id and v.extracted_gender is not null
   order by v.created_at desc limit 1
) g on true
left join lateral (
  select v.didit_device ->> 'os_family' as sistema from kyc.verifications v
   where v.user_id = p.id and v.didit_device ? 'os_family'
   order by v.created_at desc limit 1
) d on true
left join lateral (
  select case lower(u.platform) when 'ios' then 'iOS' when 'android' then 'Android' else u.platform end as sistema
    from public.user_devices u
   where u.user_id = p.id
   order by u.last_seen_at desc nulls last limit 1
) a on true
left join lateral (
  select v.status from kyc.verifications v
   where v.user_id = p.id order by v.created_at desc limit 1
) k on true
-- Desde las cuotas: en un consumo de grupo cada integrante tiene la suya.
left join lateral (
  select min(ch.confirmed_at)           as primer_consumo_at,
         max(ch.confirmed_at)           as ultimo_consumo_at,
         count(distinct ch.id)          as consumos,
         sum(i.financed_usd)            as consumo_eur
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
   where i.user_id = p.id and ch.status = 'confirmed' and not ch.is_test and not i.is_test
) c on true
where not p.is_test;

comment on view asistente.personas is
  'Una fila por persona registrada. consumos cuenta también los de grupo (desde las cuotas). sistema: iOS o Android, primero según Didit y si no según la app.';

create or replace view asistente.aparatos as
select
  u.user_id,
  case lower(u.platform) when 'ios' then 'iOS' when 'android' then 'Android' else u.platform end as sistema,
  u.os_version     as version_sistema,
  u.app_version    as version_app,
  u.app_build      as build_app,
  u.is_trusted     as de_confianza,
  u.first_seen_at  as primera_vez_at,
  u.last_seen_at   as ultima_vez_at,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as persona
from public.user_devices u
join public.profiles p on p.id = u.user_id and not p.is_test;

create or replace view asistente.verificaciones as
select
  v.id                                            as verificacion_id,
  v.user_id,
  asistente.estado('kyc', v.status::text)         as estado,
  v.rejection_reason::text                        as motivo_rechazo,
  v.attempts                                      as intentos,
  v.created_at                                    as creada_at,
  v.reviewed_at                                   as revisada_at,
  v.extracted_gender                              as sexo,
  v.didit_device ->> 'os_family'                  as sistema,
  v.didit_device ->> 'device_brand'               as marca,
  v.didit_device ->> 'device_model'               as modelo,
  v.didit_device ->> 'browser_family'             as navegador,
  v.didit_device ->> 'ip_city'                    as ciudad,
  v.didit_device ->> 'ip_country'                 as pais,
  v.didit_device ->> 'isp'                        as operador,
  (v.didit_device ->> 'is_vpn_or_tor')::boolean   as vpn,
  (v.didit_device ->> 'is_data_center')::boolean  as centro_de_datos,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as persona
from kyc.verifications v
join public.profiles p on p.id = v.user_id and not p.is_test;

create or replace view asistente.locales as
select
  m.id                                  as local_id,
  m.name                                as nombre,
  asistente.estado('local', m.status::text) as estado,
  m.category::text                      as categoria,
  m.city                                as ciudad,
  m.created_at                          as alta_at
from public.merchants m
where not m.is_test;

create or replace view asistente.consumos as
select
  ch.id                                   as consumo_id,
  ch.order_number                         as numero_orden,
  ch.user_id,
  ch.merchant_id                          as local_id,
  ch.branch_id                            as sucursal_id,
  ch.group_id                             as grupo_id,
  asistente.estado('consumo', ch.status::text) as estado,
  ch.business_date                        as dia_operativo,
  ch.created_at                           as creado_at,
  ch.confirmed_at                         as confirmado_at,
  ch.voided_at                            as anulado_at,
  coalesce(q.consumo_eur, ch.base_usd)    as consumo_eur,
  ch.consumer_fee_usd                     as servicio_eur,
  ch.consumer_fee_vat_usd                 as servicio_iva_eur,
  ch.merchant_net_usd                     as neto_local_eur,
  coalesce(q.personas, 0)                 as personas,
  coalesce(q.cuotas, 0)                   as cuotas,
  m.name                                  as local,
  b.name                                  as sucursal,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as persona,
  ch.group_id is not null                 as en_grupo
from public.charges ch
left join lateral (
  select sum(i.financed_usd) as consumo_eur, count(distinct i.user_id) as personas, count(*) as cuotas
    from public.installments i where i.charge_id = ch.id
) q on true
left join public.merchants m on m.id = ch.merchant_id
left join public.merchant_branches b on b.id = ch.branch_id
left join public.profiles p on p.id = ch.user_id
where not ch.is_test;

comment on view asistente.consumos is
  'Cada consumo en un local; solo cuenta estado = confirmado. persona es quien abrió la cuenta: en un consumo de grupo, lo de cada integrante sale de cuotas.';

create or replace view asistente.cuotas as
select
  i.id                                                       as cuota_id,
  i.charge_id                                                as consumo_id,
  i.user_id,
  i.sequence                                                 as numero,
  i.due_date                                                 as vence_el,
  asistente.estado('cuota', i.status::text)                  as estado,
  (i.status = 'pending' and i.written_off_at is null
     and i.due_date < asistente.hoy())                       as vencida,
  case when i.status = 'pending' and i.written_off_at is null and i.due_date < asistente.hoy()
       then asistente.hoy() - i.due_date end                 as dias_atraso,
  i.amount_usd                                               as cuota_eur,
  i.financed_usd                                             as consumo_eur,
  i.paid_at                                                  as pagada_at,
  asistente.dia_operativo(i.paid_at)                         as pagada_dia_operativo,
  i.written_off_at                                           as castigada_at,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as persona,
  ch.merchant_id                                             as local_id,
  m.name                                                     as local,
  ch.order_number                                            as numero_orden,
  ch.business_date                                           as dia_operativo
from public.installments i
join public.charges ch on ch.id = i.charge_id and ch.status = 'confirmed'
left join public.merchants m on m.id = ch.merchant_id
left join public.profiles p on p.id = i.user_id
where not i.is_test;

create or replace view asistente.pagos_reportados as
select
  r.id                 as pago_id,
  r.user_id,
  asistente.estado('pago', r.status::text) as estado,
  r.method             as metodo,
  r.bank               as banco,
  r.created_at         as reportado_at,
  r.reviewed_at        as revisado_at,
  q.amount_usd         as importe_eur,
  q.late_fee_usd       as cargo_atraso_eur,
  q.installment_count  as cuotas,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as persona
from public.payment_reports r
join public.payment_quotes q on q.id = r.quote_id
join public.profiles p on p.id = r.user_id and not p.is_test;

create or replace view asistente.cargos_por_atraso as
select
  lf.id               as cargo_id,
  lf.user_id,
  lf.installment_id   as cuota_id,
  lf.amount_usd       as importe_eur,
  lf.days_late        as dias_atraso,
  lf.business_date    as dia_operativo,
  asistente.estado('cargo', lf.status::text) as estado,
  lf.paid_at          as pagado_at,
  lf.waived_at        as condonado_at,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as persona
from public.late_fees lf
join public.profiles p on p.id = lf.user_id and not p.is_test;

create or replace view asistente.contactos_cobranza as
select
  cc.id              as contacto_id,
  cc.user_id,
  cc.channel::text   as canal,
  cc.template        as plantilla,
  cc.outcome         as resultado,
  cc.promise_date    as promesa_para,
  cc.next_action_on  as proxima_accion,
  cc.contacted_at    as contactado_at,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as persona
from public.collection_contacts cc
join public.profiles p on p.id = cc.user_id and not p.is_test;

create or replace view asistente.notificaciones as
select
  n.id            as notificacion_id,
  n.user_id,
  n.type::text    as tipo,
  n.template_key  as plantilla,
  n.campaign_id   as campana_id,
  n.created_at    as creada_at,
  n.read_at       as leida_at,
  coalesce(t.label, n.template_key, n.type::text) as aviso,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as persona
from public.notifications n
join public.profiles p on p.id = n.user_id and not p.is_test
left join public.notification_templates t on t.key = n.template_key;

create or replace view asistente.envios_push as
select
  d.id                 as envio_id,
  d.notification_id    as notificacion_id,
  n.user_id,
  n.type::text         as tipo,
  n.template_key       as plantilla,
  asistente.estado('push', d.status::text) as estado,
  d.attempts           as intentos,
  regexp_replace(d.error, 'Expo(nent)?PushToken\[[^\]]*\]', 'ExpoPushToken[…]', 'g') as error,
  d.priority           as prioridad,
  d.created_at         as creado_at,
  d.sent_at            as enviado_at,
  d.settled_at         as resuelto_at,
  case lower(tk.platform) when 'ios' then 'iOS' when 'android' then 'Android' else tk.platform end as sistema,
  coalesce(t.label, n.template_key, n.type::text) as aviso,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as persona
from public.push_deliveries d
join public.notifications n on n.id = d.notification_id
join public.profiles p on p.id = n.user_id and not p.is_test
left join public.push_tokens tk on tk.token = d.token
left join public.notification_templates t on t.key = n.template_key;

comment on view asistente.envios_push is
  'Cada envío push a un teléfono (una notificación puede ir a varios). estado: en cola, enviado (aceptado sin confirmar), entregado, fallido (ver error), cancelado (la persona reportó el pago). aviso es el nombre de la plantilla.';

create or replace view asistente.grupos as
select
  g.id             as grupo_id,
  g.created_by     as creado_por,
  asistente.estado('grupo', g.status::text) as estado,
  g.created_at     as creado_at,
  g.business_date  as dia_operativo,
  g.closed_at      as cerrado_at,
  (select count(*) from public.group_members m where m.group_id = g.id) as miembros,
  g.name           as nombre,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as creado_por_persona
from public.groups g
join public.profiles p on p.id = g.created_by and not p.is_test;

create or replace view asistente.miembros_grupo as
select
  m.group_id       as grupo_id,
  m.user_id,
  asistente.estado('miembro', m.status::text) as estado,
  m.cap_usd        as aporte_maximo_eur,
  m.spent_usd      as gastado_eur,
  m.joined_at      as unido_at,
  m.left_at        as salio_at,
  m.business_date  as dia_operativo,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as persona
from public.group_members m
join public.profiles p on p.id = m.user_id and not p.is_test;

create or replace view asistente.pagos_a_locales as
select
  mp.id             as pago_id,
  mp.merchant_id    as local_id,
  mp.amount_usd     as importe_eur,
  mp.amount_ves     as importe_ves,
  mp.fx_rate        as tasa,
  mp.method         as metodo,
  mp.paid_on        as pagado_el,
  mp.business_date  as dia_operativo,
  mp.created_at     as creado_at,
  m.name            as local
from public.merchant_payouts mp
join public.merchants m on m.id = mp.merchant_id and not m.is_test;

create or replace view asistente.bits as
select
  b.user_id,
  b.amount      as cantidad,
  b.reason      as motivo,
  b.created_at  as creado_at,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as persona
from public.bits_entries b
join public.profiles p on p.id = b.user_id and not p.is_test;

create or replace view asistente.lista_de_espera as
select
  w.user_id,
  w.merchant_id   as local_id,
  w.entered_at    as entro_at,
  w.entry_reason  as motivo,
  w.released_at   as salio_at,
  asistente.nombre_corto(p.first_name, p.last_name, p.full_name) as persona,
  m.name          as local
from public.credit_waitlist w
join public.profiles p on p.id = w.user_id and not p.is_test
left join public.merchants m on m.id = w.merchant_id;

-- ── Productos ───────────────────────────────────────────────────────────────

create or replace view asistente.productos_vendidos as
select
  ci.charge_id          as consumo_id,
  ch.order_number       as numero_orden,
  ch.business_date      as dia_operativo,
  ch.merchant_id        as local_id,
  m.name                as local,
  ci.name               as producto,
  pc.name               as categoria,
  ci.quantity           as cantidad,
  ci.unit_price_usd     as precio_unitario_eur,
  ci.line_total_usd     as importe_eur,
  ch.user_id,
  ch.group_id is not null as en_grupo
from public.charge_items ci
join public.charges ch on ch.id = ci.charge_id and ch.status = 'confirmed' and not ch.is_test
join public.merchants m on m.id = ch.merchant_id and not m.is_test
left join public.products pr on pr.id = ci.product_id
left join public.product_categories pc on pc.id = pr.category_id;

comment on view asistente.productos_vendidos is
  'Cada producto de cada consumo confirmado. importe_eur es consumo SIN el fee (las líneas de una cuenta suman su consumo). producto es el nombre con que se vendió.';

create or replace view asistente.productos as
select
  pr.id           as producto_id,
  pr.merchant_id  as local_id,
  m.name          as local,
  pc.name         as categoria,
  pr.name         as producto,
  pr.price_usd    as precio_eur,
  pr.is_active    as activo
from public.products pr
join public.merchants m on m.id = pr.merchant_id and not m.is_test
left join public.product_categories pc on pc.id = pr.category_id;

comment on view asistente.productos is 'La carta de cada local: cada producto con su categoría y su precio.';

grant select on all tables in schema asistente to asistente_lector;
grant execute on function asistente.nombre_corto(text, text, text), asistente.estado(text, text) to asistente_lector;
