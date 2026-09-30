-- ============================================================================
-- Ronda — El asistente consulta vistas de solo lectura con SQL
--
-- El asistente del super admin solo veía lo que cubrían sus RPC: no sabía qué
-- sistema lleva cada persona ni cuántos recordatorios push se entregaron,
-- aunque la base lo guarda. Esta migración le abre una puerta acotada:
--
--   1. El esquema `asistente`: vistas con nombres en español sobre la
--      operación, sin cuentas ni locales de prueba, sin teléfono, cédula,
--      fecha de nacimiento, IP, referencias bancarias ni textos libres, y con
--      el nombre de cada persona acortado («MARÍA P.»).
--   2. El rol `asistente_lector` (sin login): solo puede leer esas vistas.
--   3. `asistente.ejecutar`: corre un SELECT como `asistente_lector`, con los
--      claims del JWT vaciados antes (una función de la base que se cuele no
--      reconoce a nadie como admin) y con tope de filas.
--   4. `public.admin_assistant_query`: la única entrada. Comprueba que quien
--      llama es del equipo, filtra la consulta y llama a `ejecutar`.
--
-- Las capas, de fuera hacia dentro: la comprobación de admin; el filtro de
-- texto (un solo SELECT, sin esquemas ajenos ni funciones peligrosas); la
-- transacción de solo lectura (PostgREST la abre para una función STABLE, y
-- plpgsql no deja escribir desde una función STABLE); el rol, que no tiene
-- permiso sobre ninguna tabla; y el `statement_timeout` de 8 s de
-- `authenticated`.
--
-- Importes: los `_eur` son euros. `consumo_eur` es consumo SIN el fee (sale de
-- las cuotas, `installments.financed_usd`); `servicio_eur` es el fee de Ronda
-- sin IVA; `cuota_eur` es deuda CON el fee dentro. Ninguna vista trae
-- `charges.amount_usd` (el total con el fee): no se presenta nunca.
-- ============================================================================

create schema if not exists asistente;
revoke all on schema asistente from public;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'asistente_lector') then
    create role asistente_lector nologin noinherit;
  end if;
end $$;

-- `postgres` tiene que poder hacerse pasar por el rol para darle la función.
grant asistente_lector to postgres;

-- ── Ayudantes de fecha ──────────────────────────────────────────────────────

create or replace function asistente.hoy()
returns date
language sql
stable
set search_path = pg_catalog
as $$ select (now() at time zone 'America/Caracas')::date $$;

comment on function asistente.hoy() is
  'El día natural de hoy en Caracas.';

-- La misma cuenta que public.helios_business_date: aquí no se ve el esquema public.
create or replace function asistente.dia_operativo(p_ts timestamptz)
returns date
language sql
immutable
set search_path = pg_catalog
as $$ select (p_ts at time zone 'America/Caracas' - interval '10 hours')::date $$;

comment on function asistente.dia_operativo(timestamptz) is
  'El día operativo (de 10:00 a 10:00 de Caracas) de un instante.';

create or replace function asistente.dia_operativo_actual()
returns date
language sql
stable
set search_path = pg_catalog
as $$ select (now() at time zone 'America/Caracas' - interval '10 hours')::date $$;

comment on function asistente.dia_operativo_actual() is
  'El día operativo en curso.';

-- ── Vistas ──────────────────────────────────────────────────────────────────

create or replace view asistente.personas as
select
  p.id                                                      as user_id,
  nullif(trim(
    upper(split_part(coalesce(nullif(trim(p.first_name), ''), trim(p.full_name), ''), ' ', 1))
    || coalesce(' ' || upper(left(nullif(trim(p.last_name), ''), 1)) || '.', '')
  ), '')                                                    as nombre,
  p.created_at                                              as alta_at,
  (p.created_at at time zone 'America/Caracas')::date       as alta_dia,
  p.status::text                                            as estado,
  p.level                                                   as nivel,
  p.is_blacklisted                                          as en_lista_negra,
  g.extracted_gender                                        as sexo,
  coalesce(d.sistema, a.sistema)                            as sistema,
  case when d.sistema is not null then 'didit'
       when a.sistema is not null then 'app' end            as sistema_fuente,
  k.status::text                                            as kyc_estado,
  c.primer_consumo_at,
  coalesce(c.consumos, 0)                                   as consumos,
  coalesce(f.consumo_eur, 0)                                as consumo_eur
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
left join lateral (
  select min(ch.confirmed_at) as primer_consumo_at, count(*) as consumos
    from public.charges ch
   where ch.user_id = p.id and ch.status = 'confirmed' and not ch.is_test
) c on true
left join lateral (
  select sum(i.financed_usd) as consumo_eur
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
   where i.user_id = p.id and ch.status = 'confirmed' and not i.is_test
) f on true
where not p.is_test;

comment on view asistente.personas is
  'Una fila por persona registrada. sistema: iOS o Android, primero según Didit (al verificarse) y si no según la app.';

create or replace view asistente.aparatos as
select
  u.user_id,
  case lower(u.platform) when 'ios' then 'iOS' when 'android' then 'Android' else u.platform end as sistema,
  u.os_version     as version_sistema,
  u.app_version    as version_app,
  u.app_build      as build_app,
  u.is_trusted     as de_confianza,
  u.first_seen_at  as primera_vez_at,
  u.last_seen_at   as ultima_vez_at
from public.user_devices u
join public.profiles p on p.id = u.user_id and not p.is_test;

comment on view asistente.aparatos is
  'Cada teléfono con el que entra una persona a la app (puede tener varios).';

create or replace view asistente.verificaciones as
select
  v.id                                            as verificacion_id,
  v.user_id,
  v.status::text                                  as estado,
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
  (v.didit_device ->> 'is_data_center')::boolean  as centro_de_datos
from kyc.verifications v
join public.profiles p on p.id = v.user_id and not p.is_test;

comment on view asistente.verificaciones is
  'Cada verificación de identidad (Didit), con el aparato con el que se hizo. Una persona puede tener varias.';

create or replace view asistente.locales as
select
  m.id           as local_id,
  m.name         as nombre,
  m.status::text as estado,
  m.category::text as categoria,
  m.city         as ciudad,
  m.created_at   as alta_at
from public.merchants m
where not m.is_test;

comment on view asistente.locales is 'Los locales (comercios) de Helios.';

create or replace view asistente.consumos as
select
  ch.id                                   as consumo_id,
  ch.order_number                         as numero_orden,
  ch.user_id,
  ch.merchant_id                          as local_id,
  ch.branch_id                            as sucursal_id,
  ch.group_id                             as grupo_id,
  ch.status::text                         as estado,
  ch.business_date                        as dia_operativo,
  ch.created_at                           as creado_at,
  ch.confirmed_at                         as confirmado_at,
  ch.voided_at                            as anulado_at,
  coalesce(q.consumo_eur, ch.base_usd)    as consumo_eur,
  ch.consumer_fee_usd                     as servicio_eur,
  ch.consumer_fee_vat_usd                 as servicio_iva_eur,
  ch.merchant_net_usd                     as neto_local_eur,
  coalesce(q.personas, 0)                 as personas,
  coalesce(q.cuotas, 0)                   as cuotas
from public.charges ch
left join lateral (
  select sum(i.financed_usd) as consumo_eur, count(distinct i.user_id) as personas, count(*) as cuotas
    from public.installments i where i.charge_id = ch.id
) q on true
where not ch.is_test;

comment on view asistente.consumos is
  'Cada consumo en un local. Solo cuenta estado = confirmed. user_id es quien abrió la cuenta: en un consumo de grupo, lo de cada persona sale de cuotas.';

create or replace view asistente.cuotas as
select
  i.id                                                       as cuota_id,
  i.charge_id                                                as consumo_id,
  i.user_id,
  i.sequence                                                 as numero,
  i.due_date                                                 as vence_el,
  i.status::text                                             as estado,
  (i.status = 'pending' and i.written_off_at is null
     and i.due_date < asistente.hoy())                       as vencida,
  case when i.status = 'pending' and i.written_off_at is null and i.due_date < asistente.hoy()
       then asistente.hoy() - i.due_date end                 as dias_atraso,
  i.amount_usd                                               as cuota_eur,
  i.financed_usd                                             as consumo_eur,
  i.paid_at                                                  as pagada_at,
  asistente.dia_operativo(i.paid_at)                         as pagada_dia_operativo,
  i.written_off_at                                           as castigada_at
from public.installments i
join public.charges ch on ch.id = i.charge_id and ch.status = 'confirmed'
where not i.is_test;

comment on view asistente.cuotas is
  'Cada cuota de un consumo confirmado: una por persona y plazo. cuota_eur es deuda CON el fee; consumo_eur es la parte de consumo SIN el fee.';

create or replace view asistente.pagos_reportados as
select
  r.id                 as pago_id,
  r.user_id,
  r.status::text       as estado,
  r.method             as metodo,
  r.bank               as banco,
  r.created_at         as reportado_at,
  r.reviewed_at        as revisado_at,
  q.amount_usd         as importe_eur,
  q.late_fee_usd       as cargo_atraso_eur,
  q.installment_count  as cuotas
from public.payment_reports r
join public.payment_quotes q on q.id = r.quote_id
join public.profiles p on p.id = r.user_id and not p.is_test;

comment on view asistente.pagos_reportados is
  'Cada pago de cuotas que una persona reporta desde la app. estado: reported, in_review, reconciled (aprobado), rejected, duplicate.';

create or replace view asistente.cargos_por_atraso as
select
  lf.id               as cargo_id,
  lf.user_id,
  lf.installment_id   as cuota_id,
  lf.amount_usd       as importe_eur,
  lf.days_late        as dias_atraso,
  lf.business_date    as dia_operativo,
  lf.status::text     as estado,
  lf.paid_at          as pagado_at,
  lf.waived_at        as condonado_at
from public.late_fees lf
join public.profiles p on p.id = lf.user_id and not p.is_test;

comment on view asistente.cargos_por_atraso is 'Los cargos por atraso (mora) que se cobran a una persona.';

create or replace view asistente.contactos_cobranza as
select
  cc.id              as contacto_id,
  cc.user_id,
  cc.channel::text   as canal,
  cc.template        as plantilla,
  cc.outcome         as resultado,
  cc.promise_date    as promesa_para,
  cc.next_action_on  as proxima_accion,
  cc.contacted_at    as contactado_at
from public.collection_contacts cc
join public.profiles p on p.id = cc.user_id and not p.is_test;

comment on view asistente.contactos_cobranza is 'Cada llamada, WhatsApp o visita del equipo de cobranza a una persona.';

create or replace view asistente.notificaciones as
select
  n.id            as notificacion_id,
  n.user_id,
  n.type::text    as tipo,
  n.template_key  as plantilla,
  n.campaign_id   as campana_id,
  n.created_at    as creada_at,
  n.read_at       as leida_at
from public.notifications n
join public.profiles p on p.id = n.user_id and not p.is_test;

comment on view asistente.notificaciones is
  'Cada aviso que se le crea a una persona en la app (la campana). Si hay push, sus envíos están en envios_push.';

create or replace view asistente.envios_push as
select
  d.id                 as envio_id,
  d.notification_id    as notificacion_id,
  n.user_id,
  n.type::text         as tipo,
  n.template_key       as plantilla,
  d.status::text       as estado,
  d.attempts           as intentos,
  regexp_replace(d.error, 'Expo(nent)?PushToken\[[^\]]*\]', 'ExpoPushToken[…]', 'g') as error,
  d.priority           as prioridad,
  d.created_at         as creado_at,
  d.sent_at            as enviado_at,
  d.settled_at         as resuelto_at,
  case lower(t.platform) when 'ios' then 'iOS' when 'android' then 'Android' else t.platform end as sistema
from public.push_deliveries d
join public.notifications n on n.id = d.notification_id
join public.profiles p on p.id = n.user_id and not p.is_test
left join public.push_tokens t on t.token = d.token;

comment on view asistente.envios_push is
  'Cada envío push a un teléfono (una notificación puede ir a varios). estado: pending (en cola), sent (aceptado por Expo, sin confirmar), delivered (entregado), failed (fallido, ver error), cancelled (anulado porque la persona reportó el pago).';

create or replace view asistente.plantillas_push as
select
  t.key            as plantilla,
  t.type::text     as tipo,
  t.label          as nombre,
  t.trigger_label  as cuando,
  t.enabled        as activa,
  t.lead_days      as dias,
  t.run_at         as hora
from public.notification_templates t;

comment on view asistente.plantillas_push is
  'Las plantillas de los avisos. Los recordatorios de cuota son installment_due (antes de vencer), installment_due_today, installment_due_today_evening e installment_late_d1/d3/d5/d7 (de atraso).';

create or replace view asistente.grupos as
select
  g.id             as grupo_id,
  g.created_by     as creado_por,
  g.status::text   as estado,
  g.created_at     as creado_at,
  g.business_date  as dia_operativo,
  g.closed_at      as cerrado_at,
  (select count(*) from public.group_members m where m.group_id = g.id) as miembros
from public.groups g
join public.profiles p on p.id = g.created_by and not p.is_test;

comment on view asistente.grupos is 'Los grupos para consumir juntos una noche.';

create or replace view asistente.miembros_grupo as
select
  m.group_id       as grupo_id,
  m.user_id,
  m.status::text   as estado,
  m.cap_usd        as aporte_maximo_eur,
  m.spent_usd      as gastado_eur,
  m.joined_at      as unido_at,
  m.left_at        as salio_at,
  m.business_date  as dia_operativo
from public.group_members m
join public.profiles p on p.id = m.user_id and not p.is_test;

comment on view asistente.miembros_grupo is 'Cada persona dentro de un grupo, con su aporte máximo y lo que lleva gastado.';

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
  mp.created_at     as creado_at
from public.merchant_payouts mp
join public.merchants m on m.id = mp.merchant_id and not m.is_test;

comment on view asistente.pagos_a_locales is 'Cada transferencia de Helios a un local.';

create or replace view asistente.bits as
select
  b.user_id,
  b.amount      as cantidad,
  b.reason      as motivo,
  b.created_at  as creado_at
from public.bits_entries b
join public.profiles p on p.id = b.user_id and not p.is_test;

comment on view asistente.bits is 'Los Bits (puntos) que gana o gasta cada persona.';

create or replace view asistente.lista_de_espera as
select
  w.user_id,
  w.merchant_id   as local_id,
  w.entered_at    as entro_at,
  w.entry_reason  as motivo,
  w.released_at   as salio_at
from public.credit_waitlist w
join public.profiles p on p.id = w.user_id and not p.is_test;

comment on view asistente.lista_de_espera is 'La lista de espera de la bóveda piloto.';

create or replace view asistente.niveles as
select
  l.level              as nivel,
  l.label              as nombre,
  l.monthly_limit_usd  as cupo_eur,
  l.required_spend_usd as consumo_requerido_eur,
  l.required_months    as meses_requeridos,
  l.is_active          as activo
from public.levels l;

comment on view asistente.niveles is 'La escalera de niveles y el cupo de cada uno.';

grant usage on schema asistente to asistente_lector;
grant select on all tables in schema asistente to asistente_lector;
grant execute on function asistente.hoy(), asistente.dia_operativo(timestamptz), asistente.dia_operativo_actual()
  to asistente_lector;

-- ── La consulta ─────────────────────────────────────────────────────────────

-- Corre como asistente_lector (SECURITY DEFINER con ese dueño). Los claims se
-- vacían mientras corre la consulta: si llegara a una función de public,
-- auth.uid() sería null y ninguna RPC de admin la reconocería. Después se
-- devuelven, para que el resto de la transacción siga sabiendo quién es.
create or replace function asistente.ejecutar(p_sql text, p_max integer)
returns json
language plpgsql
stable
security definer
set search_path = asistente, pg_catalog, pg_temp
as $$
declare
  v_filas  json;
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub    text := current_setting('request.jwt.claim.sub', true);
  v_role   text := current_setting('request.jwt.claim.role', true);
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  -- La consulta va entre saltos de línea: un comentario «--» al final no se
  -- come el cierre. Los alias son raros a propósito: una columna llamada «q»
  -- taparía un alias «q», y json_agg recogería esa columna en vez de la fila.
  execute format(
    E'select coalesce(json_agg(asistente_fila__), ''[]''::json) from (select * from (\n%s\n) as asistente_consulta__ limit %s) as asistente_fila__',
    p_sql, p_max + 1
  ) into v_filas;
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(v_sub, ''), true);
  perform set_config('request.jwt.claim.role', coalesce(v_role, ''), true);
  return v_filas;
end;
$$;

-- Para cambiarle el dueño, el rol tiene que poder crear en el esquema; se le
-- quita después y la función sigue siendo suya.
grant create on schema asistente to asistente_lector;
alter function asistente.ejecutar(text, integer) owner to asistente_lector;
revoke create on schema asistente from asistente_lector;
revoke all on function asistente.ejecutar(text, integer) from public;
grant execute on function asistente.ejecutar(text, integer) to postgres;

create or replace function public.admin_assistant_query(p_sql text, p_max_rows integer default 200)
returns json
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_sql   text := btrim(coalesce(p_sql, ''));
  v_max   integer := least(greatest(coalesce(p_max_rows, 200), 1), 500);
  v_filas json;
  v_n     integer;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_sql := regexp_replace(v_sql, '[;[:space:]]+$', '');
  if v_sql = '' then
    raise exception 'La consulta está vacía.' using errcode = '22023';
  end if;
  if length(v_sql) > 8000 then
    raise exception 'La consulta es demasiado larga (más de 8000 caracteres).' using errcode = '22023';
  end if;
  if v_sql !~* '^\s*(select|with)\M' then
    raise exception 'Solo se admite una consulta SELECT (o WITH … SELECT).' using errcode = '22023';
  end if;
  if position(';' in v_sql) > 0 then
    raise exception 'Una sola consulta, sin punto y coma en medio.' using errcode = '22023';
  end if;
  if v_sql ~* '"?\m(public|kyc|auth|audit|storage|extensions|vault|cron|net|realtime|graphql|graphql_public|pgsodium|pgbouncer|information_schema|pg_catalog|pg_toast|supabase_[a-z_]+)\M"?\s*\.' then
    raise exception 'Solo se leen las vistas del asistente, sin prefijo de esquema.' using errcode = '42501';
  end if;
  if v_sql ~* '\m(set_config|current_setting|query_to_[a-z_]+|table_to_[a-z_]+|cursor_to_[a-z_]+|schema_to_[a-z_]+|database_to_[a-z_]+|dblink[a-z_]*|pg_read_[a-z_]+|pg_ls_[a-z_]+|pg_stat_file|lo_[a-z_]+|pg_sleep[a-z_]*|pg_terminate_backend|pg_cancel_backend|pg_advisory_[a-z_]+|pg_notify|txid_[a-z_]+|pg_catalog|pg_authid|pg_shadow|pg_proc)\M' then
    raise exception 'La consulta usa una función o una tabla del sistema que no se admite.' using errcode = '42501';
  end if;

  v_filas := asistente.ejecutar(v_sql, v_max);
  v_n := json_array_length(v_filas);
  if v_n > v_max then
    select json_agg(e order by i) into v_filas
      from json_array_elements(v_filas) with ordinality as t(e, i)
     where i <= v_max;
  end if;
  return json_build_object('filas', v_filas, 'truncado', v_n > v_max, 'n', least(v_n, v_max));
end;
$$;

comment on function public.admin_assistant_query(text, integer) is
  'El asistente del super admin: un SELECT sobre las vistas del esquema asistente, como asistente_lector y de solo lectura. Devuelve {filas, truncado, n}.';

revoke all on function public.admin_assistant_query(text, integer) from public, anon;
grant execute on function public.admin_assistant_query(text, integer) to authenticated;
