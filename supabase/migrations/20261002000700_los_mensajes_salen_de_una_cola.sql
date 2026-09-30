-- ============================================================================
-- Helios — Los mensajes salen de una cola (cimientos de H6 y H7)
--
-- Ronda avisaba por push (Expo) a una app. Helios no tiene app: al paciente
-- le llega un CORREO (el comprobante, H6) y mensajes de WHATSAPP que manda una
-- persona del equipo desde una cola diaria (H7). Esta migración pone la base
-- común a los dos, sin despachar nada todavía:
--
-- 1. `notification_templates` sabe por qué canal sale cada plantilla
--    (`channels`: `app` | `email` | `whatsapp_manual`) y puede llevar una
--    versión HTML (`default_html` de fábrica, `html` publicada). `type` (el
--    enum de la bandeja de la app) pasa a ser opcional: las plantillas de
--    Helios no van a la bandeja.
-- 2. Las 22 plantillas de Ronda quedan como `app` y APAGADAS: eran la
--    bandeja y el push de la app, y ningún paciente de Helios las leería.
--    Apagada, `notify()` no escribe nada y `helios_reminder_due_date()`
--    devuelve null, así que los 12 crons de avisos de Ronda corren sin hacer
--    nada hasta que H7 los lleve a `outbound_messages`. No se borran: el
--    catálogo del panel y esos crons las leen por clave. (Ya nada escribe en
--    tablas de push: la poda quitó `notifications_enqueue_push` y
--    verificar.sql lo comprueba.)
-- 3. Las plantillas de Helios (docs/01 §4), con texto por defecto.
-- 4. `outbound_messages`: la cola. Una fila por mensaje, con el texto (y el
--    HTML) ya renderizados: es la prueba de qué se le dijo al paciente. La lee
--    el equipo (RLS); nadie escribe desde la API.
-- 5. `helios_enqueue_message(...)`: renderiza una plantilla con las variables
--    del llamador más las de siempre ({nombre}, {whatsapp_helios},
--    {cuentas_de_cobro}…) y la mete en la cola. `helios_enqueue_charge_receipt`
--    arma el comprobante de un financiamiento y lo encola por correo.
--    Las dos son internas (sin permiso para la API): las llaman
--    `create_patient_charge` (H4), `staff_resend_receipt`/`admin_resend_receipt`
--    (H6) y los avisos (H7).
-- 6. El editor de plantillas: los límites de 65/240 caracteres eran de la
--    bandeja de Android; un correo o un WhatsApp caben más largos. Y el
--    catálogo devuelve el canal y cuenta los envíos de la cola.
--
-- Reglas de redacción de las plantillas (docs/00): voz de Helios, clara y
-- respetuosa; NUNCA un total que sume el fee de Helios: el fee va dentro de
-- las cuotas o en su propia línea del desglose («Servicio Helios 20 % + IVA»).
-- El comprobante no es una factura y no lo dice.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El canal de cada plantilla
-- ---------------------------------------------------------------------------

alter table public.notification_templates
  add column channels     text[] not null default '{app}',
  add column default_html text,
  add column html         text;

alter table public.notification_templates
  add constraint notification_templates_channels_check
    check (channels <> '{}' and channels <@ array['app', 'email', 'whatsapp_manual']);

alter table public.notification_templates alter column type drop not null;

comment on column public.notification_templates.channels is
  'Por dónde sale: app (la bandeja de Ronda, apagada en Helios), email, whatsapp_manual.';
comment on column public.notification_templates.default_html is
  'Versión HTML de fábrica (correo). Las variables se rellenan escapadas; las que acaban en _html van tal cual.';

-- ---------------------------------------------------------------------------
-- 2. Las plantillas de la app se apagan
-- ---------------------------------------------------------------------------

update public.notification_templates
   set enabled = false,
       help = coalesce(help || ' ', '') || '[Helios: aviso de la app de Ronda, apagado. Los avisos del paciente salen por WhatsApp y correo.]'
 where channels = '{app}';

-- ---------------------------------------------------------------------------
-- 3. Las plantillas de Helios
-- ---------------------------------------------------------------------------

insert into public.notification_templates
  (key, type, channels, label, trigger_label, help, variables, required_variables,
   default_title, default_body, default_html, enabled, editable, can_disable, lead_days, run_at, sort_order)
values
(
  'comprobante_financiamiento', null, '{email}',
  'Comprobante del financiamiento',
  'Al confirmar un financiamiento, y cada vez que se reenvía',
  'El único documento que recibe el paciente. El asunto es el título. El fee de Helios va en su propia línea, nunca sumado a la consulta.',
  array['nombre','nombre_completo','documento','clinica','clinica_rif','sede','registrado_por','orden',
        'fecha_hora','concepto','monto_consulta','servicio_helios','servicio_helios_pct','n_cuotas',
        'cuotas','cuotas_html','monto_cuota','fecha','cuentas_de_cobro','cuentas_de_cobro_html',
        'whatsapp_helios','whatsapp_link','soporte_email','cargo_atraso','dias_gracia',
        'dias_suspension','dias_expulsion','tasa_bcv'],
  array['orden','cuotas'],
  'Tu financiamiento en {clinica}: {n_cuotas} cuotas de ${monto_cuota}',
  E'Hola, {nombre}:\n\n'
  || E'Este es el comprobante de tu financiamiento con Helios. Guárdalo: aquí están tus cuotas y cómo pagarlas.\n\n'
  || E'Financiamiento #{orden} · {fecha_hora} (hora de Caracas)\n'
  || E'Clínica: {clinica} {clinica_rif}\n'
  || E'Sede: {sede} · Registró: {registrado_por}\n'
  || E'Titular: {nombre_completo} · C.I. {documento}\n\n'
  || E'Servicios: {concepto}\n'
  || E'Monto de la consulta: ${monto_consulta}\n'
  || E'Servicio Helios ({servicio_helios_pct} % + IVA): ${servicio_helios}\n\n'
  || E'Tu plan de pagos, sin inicial:\n{cuotas}\n\n'
  || E'Cómo pagar\n'
  || E'Pagas en bolívares, a la tasa BCV del dólar del día en que pagues.\n{cuentas_de_cobro}\n\n'
  || E'Cuando pagues, envíanos el comprobante por WhatsApp: {whatsapp_helios}\n\n'
  || E'Condiciones\n'
  || E'• Mientras una cuota esté vencida no podrás financiar nuevas consultas con Helios.\n'
  || E'• Después de {dias_gracia} días de atraso se suma un cargo de ${cargo_atraso} por cuota.\n'
  || E'• A los {dias_suspension} días de atraso la cuenta se suspende; a los {dias_expulsion} días se cierra y la deuda pasa a cobranza.\n\n'
  || E'¿No reconoces este financiamiento? Escríbenos enseguida por WhatsApp: {whatsapp_helios}\n\n'
  || 'Este correo es un comprobante de tu financiamiento, no una factura.',
  $html$<!doctype html>
<html lang="es"><head><meta charset="utf-8"><title>Tu financiamiento con Helios</title></head>
<body style="margin:0;padding:0;background:#f4f6fb;font-family:Arial,Helvetica,sans-serif;color:#1f2937;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6fb;padding:24px 0;"><tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border-radius:8px;">
<tr><td style="padding:24px 28px;background:#1A56DB;color:#ffffff;border-radius:8px 8px 0 0;">
  <div style="font-size:22px;font-weight:bold;">Helios</div>
  <div style="font-size:14px;margin-top:4px;">Financiamiento #{orden} · {fecha_hora} (hora de Caracas)</div>
</td></tr>
<tr><td style="padding:24px 28px;font-size:15px;line-height:1.5;">
  <p style="margin:0 0 12px;">Hola, {nombre}:</p>
  <p style="margin:0 0 16px;">Este es el comprobante de tu financiamiento con Helios. Guárdalo: aquí están tus cuotas y cómo pagarlas.</p>
  <table role="presentation" width="100%" cellpadding="6" cellspacing="0" style="font-size:14px;border-collapse:collapse;">
    <tr><td style="color:#6b7280;width:40%;">Clínica</td><td>{clinica} {clinica_rif}</td></tr>
    <tr><td style="color:#6b7280;">Sede</td><td>{sede}</td></tr>
    <tr><td style="color:#6b7280;">Registró</td><td>{registrado_por}</td></tr>
    <tr><td style="color:#6b7280;">Titular</td><td>{nombre_completo} · C.I. {documento}</td></tr>
    <tr><td style="color:#6b7280;">Servicios</td><td>{concepto}</td></tr>
    <tr><td style="color:#6b7280;">Monto de la consulta</td><td>${monto_consulta}</td></tr>
    <tr><td style="color:#6b7280;">Servicio Helios ({servicio_helios_pct} % + IVA)</td><td>${servicio_helios}</td></tr>
  </table>
  <h2 style="font-size:16px;margin:24px 0 8px;">Tu plan de pagos, sin inicial</h2>
  <table role="presentation" width="100%" cellpadding="8" cellspacing="0" style="font-size:14px;border-collapse:collapse;border:1px solid #e5e7eb;">
    <tr style="background:#f9fafb;"><th align="left">Cuota</th><th align="left">Vence</th><th align="right">Monto</th></tr>
    {cuotas_html}
  </table>
  <h2 style="font-size:16px;margin:24px 0 8px;">Cómo pagar</h2>
  <p style="margin:0 0 8px;">Pagas en bolívares, a la tasa BCV del dólar del día en que pagues.</p>
  <p style="margin:0 0 8px;">{cuentas_de_cobro_html}</p>
  <p style="margin:0 0 8px;">Cuando pagues, envíanos el comprobante por WhatsApp: <a href="{whatsapp_link}" style="color:#1A56DB;">{whatsapp_helios}</a></p>
  <h2 style="font-size:16px;margin:24px 0 8px;">Condiciones</h2>
  <ul style="margin:0 0 16px;padding-left:20px;">
    <li>Mientras una cuota esté vencida no podrás financiar nuevas consultas con Helios.</li>
    <li>Después de {dias_gracia} días de atraso se suma un cargo de ${cargo_atraso} por cuota.</li>
    <li>A los {dias_suspension} días de atraso la cuenta se suspende; a los {dias_expulsion} días se cierra y la deuda pasa a cobranza.</li>
  </ul>
  <p style="margin:16px 0 0;padding:12px;background:#fef3c7;border-radius:6px;">¿No reconoces este financiamiento? Escríbenos enseguida por WhatsApp: {whatsapp_helios}</p>
</td></tr>
<tr><td style="padding:16px 28px;font-size:12px;color:#6b7280;border-top:1px solid #e5e7eb;">
  Este correo es un comprobante de tu financiamiento, no una factura.
</td></tr>
</table>
</td></tr></table>
</body></html>$html$,
  true, true, false, null, null, 10
),
(
  'bienvenida', null, '{whatsapp_manual}',
  'Bienvenida',
  'Al confirmar un financiamiento',
  'El primer WhatsApp al paciente: confirma el financiamiento y explica cómo pagar.',
  array['nombre','clinica','orden','cuotas','cuentas_de_cobro','whatsapp_helios','tasa_bcv'],
  array['orden','cuotas'],
  'Bienvenida a Helios',
  E'Hola, {nombre}. Te escribimos de Helios.\n\n'
  || E'Hoy {clinica} registró tu financiamiento #{orden}: pagas tu consulta en cuotas, sin inicial.\n{cuotas}\n\n'
  || E'Para pagar (en bolívares, a la tasa BCV del día del pago):\n{cuentas_de_cobro}\n\n'
  || 'Cuando pagues, envíanos el comprobante por este chat. También te mandamos todos los detalles a tu correo. Si no reconoces este financiamiento, avísanos por aquí.',
  null, true, true, true, null, null, 20
),
(
  'cuota_manana', null, '{whatsapp_manual,email}',
  'Tu cuota vence mañana',
  'La víspera del vencimiento, 19:00',
  'Recordatorio amable. También sale por correo.',
  array['nombre','clinica','orden','monto_cuota','fecha','cuentas_de_cobro','whatsapp_helios','tasa_bcv'],
  array['monto_cuota','fecha'],
  'Mañana vence tu cuota de ${monto_cuota}',
  E'Hola, {nombre}. Te recordamos que mañana, {fecha}, vence tu cuota de ${monto_cuota} del financiamiento #{orden} en {clinica}.\n\n'
  || E'Puedes pagar en bolívares a la tasa BCV del día:\n{cuentas_de_cobro}\n\n'
  || 'Cuando pagues, envíanos el comprobante por WhatsApp: {whatsapp_helios}. ¡Gracias!',
  null, true, true, true, 1, time '19:00', 30
),
(
  'cuota_hoy', null, '{whatsapp_manual}',
  'Tu cuota vence hoy',
  'El día del vencimiento, 08:00',
  null,
  array['nombre','clinica','orden','monto_cuota','fecha','cuentas_de_cobro','whatsapp_helios','tasa_bcv'],
  array['monto_cuota'],
  'Hoy vence tu cuota de ${monto_cuota}',
  E'Buenos días, {nombre}. Hoy vence tu cuota de ${monto_cuota} del financiamiento #{orden} en {clinica}.\n\n'
  || E'Para pagar:\n{cuentas_de_cobro}\n\n'
  || 'Cuando pagues, envíanos el comprobante por aquí. Si ya pagaste, ignora este mensaje.',
  null, true, true, true, 0, time '08:00', 40
),
(
  'cuota_vencida_d1', null, '{whatsapp_manual}',
  'Cuota vencida: primer día',
  'Un día después del vencimiento',
  null,
  array['nombre','clinica','orden','monto_cuota','fecha','cuentas_de_cobro','whatsapp_helios','cargo_atraso','dias_gracia'],
  array['monto_cuota','fecha'],
  'Tu cuota venció ayer',
  E'Hola, {nombre}. Tu cuota de ${monto_cuota} del {fecha} (financiamiento #{orden}) sigue pendiente.\n\n'
  || E'Mientras esté vencida no podrás financiar nuevas consultas con Helios. Si la pagas antes de cumplir {dias_gracia} días de atraso, evitas el cargo de ${cargo_atraso}.\n\n'
  || E'Para pagar:\n{cuentas_de_cobro}\n\n'
  || 'Si tienes algún inconveniente, escríbenos y lo resolvemos juntos.',
  null, true, true, true, 1, null, 50
),
(
  'cargo_por_atraso_d4', null, '{whatsapp_manual}',
  'Cargo por atraso',
  'Cuando se cobra el cargo por atraso (tras los días de gracia)',
  null,
  array['nombre','clinica','orden','monto_cuota','fecha','cuentas_de_cobro','whatsapp_helios','cargo_atraso'],
  array['monto_cuota','fecha'],
  'Se sumó un cargo por atraso',
  E'Hola, {nombre}. Tu cuota del {fecha} (financiamiento #{orden}) sigue pendiente y hoy se sumó el cargo por atraso de ${cargo_atraso}. El monto a pagar de esa cuota es ahora ${monto_cuota}.\n\n'
  || E'Para pagar:\n{cuentas_de_cobro}\n\n'
  || 'Si necesitas ayuda para ponerte al día, escríbenos por aquí.',
  null, true, true, true, 4, null, 60
),
(
  'pago_recibido', null, '{whatsapp_manual}',
  'Pago confirmado',
  'Al conciliar un pago',
  null,
  array['nombre','monto','orden','whatsapp_helios'],
  array['monto'],
  'Confirmamos tu pago',
  'Hola, {nombre}. Recibimos y confirmamos tu pago de ${monto}. ¡Gracias por tu puntualidad!',
  null, true, true, true, null, null, 70
),
(
  'pago_rechazado', null, '{whatsapp_manual}',
  'No pudimos confirmar el pago',
  'Al rechazar un pago registrado',
  null,
  array['nombre','motivo','orden','whatsapp_helios','cuentas_de_cobro'],
  array['motivo'],
  'No pudimos confirmar tu pago',
  E'Hola, {nombre}. No pudimos confirmar el pago que nos enviaste: {motivo}.\n\n'
  || 'Revísalo, por favor, y envíanos de nuevo el comprobante por aquí. Si crees que es un error, escríbenos y lo vemos juntos.',
  null, true, true, true, null, null, 80
),
(
  'cuenta_congelada', null, '{whatsapp_manual}',
  'Cuenta congelada',
  'Al pasar a congelada (una cuota vencida)',
  null,
  array['nombre','cuentas_de_cobro','whatsapp_helios'],
  '{}',
  'Tu cuenta está en pausa',
  E'Hola, {nombre}. Tienes una cuota vencida, así que por ahora no puedes financiar nuevas consultas con Helios. En cuanto te pongas al día se reactiva sola.\n\n'
  || E'Para pagar:\n{cuentas_de_cobro}',
  null, true, true, true, null, null, 90
)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 4. La cola
-- ---------------------------------------------------------------------------

create table public.outbound_messages (
  id                   uuid primary key default gen_random_uuid(),
  channel              text not null check (channel in ('email', 'whatsapp_manual')),
  template_key         text not null references public.notification_templates(key),
  profile_id           uuid not null references public.profiles(id),
  charge_id            uuid references public.charges(id),
  installment_due_date date,
  recipient            text,
  subject              text,
  rendered_text        text not null,
  html                 text,
  status               text not null default 'pendiente'
                       check (status in ('pendiente', 'enviado', 'omitido', 'fallido', 'cancelado')),
  provider_id          text,
  attempts             integer not null default 0 check (attempts >= 0),
  next_attempt_at      timestamptz,
  last_event           text,
  last_error           text,
  sent_by              uuid references auth.users(id),
  sent_at              timestamptz,
  created_at           timestamptz not null default now(),
  dedupe_key           text unique
);

comment on table public.outbound_messages is
  'Cola de mensajes al paciente (correo y WhatsApp manual), con el texto y el HTML exactos que se mandaron. La llenan helios_enqueue_message y helios_enqueue_charge_receipt; el despacho es de H6 (correo) y H7 (WhatsApp).';
comment on column public.outbound_messages.recipient is 'Correo (email) o teléfono E.164 (whatsapp_manual) en el momento de encolar.';
comment on column public.outbound_messages.dedupe_key is 'Opcional: la misma clave no encola dos veces (p. ej. un aviso por cuota y momento).';

create index outbound_messages_por_despachar_idx on public.outbound_messages (channel, next_attempt_at)
  where status = 'pendiente';
create index outbound_messages_profile_idx on public.outbound_messages (profile_id, created_at);
create index outbound_messages_charge_idx  on public.outbound_messages (charge_id) where charge_id is not null;
create index outbound_messages_dia_idx     on public.outbound_messages (created_at, channel);

alter table public.outbound_messages enable row level security;
revoke all on public.outbound_messages from anon, authenticated;
grant select on public.outbound_messages to authenticated;

create policy outbound_messages_read_admin on public.outbound_messages
  for select to authenticated
  using ((select public.is_platform_admin()));

-- ---------------------------------------------------------------------------
-- 5. Encolar
-- ---------------------------------------------------------------------------

/** Texto seguro dentro de HTML. */
create or replace function public.helios_html_escape(p_text text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select replace(replace(replace(replace(replace(coalesce(p_text, ''),
    '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$$;

/** Percent-encoding UTF-8 (RFC 3986), para el `?text=` de un enlace wa.me. */
create or replace function public.helios_url_encode(p_text text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select coalesce(string_agg(
    case when b between 48 and 57 or b between 65 and 90 or b between 97 and 122
              or b in (45, 46, 95, 126)
         then chr(b)
         else '%' || upper(lpad(to_hex(b), 2, '0')) end,
    '' order by i), '')
  from (
    select i, get_byte(convert_to(coalesce(p_text, ''), 'UTF8'), i) as b
    from generate_series(0, octet_length(convert_to(coalesce(p_text, ''), 'UTF8')) - 1) as i
  ) x;
$$;

/** Un monto en dólares como texto de mensaje: «61.60». */
create or replace function public.helios_money_text(p_amount numeric)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$ select trim(to_char(coalesce(p_amount, 0), 'FM999999990.00')) $$;

revoke all on function public.helios_html_escape(text) from public, anon;
revoke all on function public.helios_url_encode(text)  from public, anon;
revoke all on function public.helios_money_text(numeric) from public, anon;
grant execute on function public.helios_html_escape(text) to authenticated;
grant execute on function public.helios_url_encode(text)  to authenticated;
grant execute on function public.helios_money_text(numeric) to authenticated;

/**
 * Las variables que toda plantilla puede usar: del paciente ({nombre}), de la
 * configuración ({whatsapp_helios}, {whatsapp_link}, {cuentas_de_cobro},
 * {cuentas_de_cobro_html}, {soporte_email}, {soporte_horario}) y de las reglas
 * ({tasa_bcv}, {cargo_atraso}, {dias_gracia}, {dias_suspension},
 * {dias_expulsion}). Mientras el WhatsApp o las cuentas no estén
 * configurados, llevan un texto de reserva en vez de quedar vacías.
 */
create or replace function public.helios_message_builtins(p_profile_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_p      public.profiles%rowtype;
  v_c      public.platform_contact%rowtype;
  v_wa     text;
  v_cuentas text := public.helios_payment_accounts_text();
  v_tasa   numeric := public.current_fx_rate('BCV');
begin
  select * into v_p from public.profiles where id = p_profile_id;
  select * into v_c from public.platform_contact where id;

  v_wa := coalesce(public.helios_format_ve_phone(v_c.whatsapp_number), v_c.whatsapp_number);

  return jsonb_build_object(
    'nombre', coalesce(nullif(btrim(v_p.first_name), ''),
                       nullif(split_part(btrim(coalesce(v_p.full_name, '')), ' ', 1), ''),
                       'paciente'),
    'whatsapp_helios', coalesce(v_wa, 'te escribiremos en breve desde el WhatsApp de Helios'),
    'whatsapp_link', case when v_c.whatsapp_number is not null
                          then 'https://wa.me/' || regexp_replace(v_c.whatsapp_number, '\D', '', 'g')
                          else '' end,
    'cuentas_de_cobro', v_cuentas,
    'cuentas_de_cobro_html', replace(public.helios_html_escape(v_cuentas), E'\n', '<br>'),
    'soporte_email', coalesce(v_c.support_email, ''),
    'soporte_horario', coalesce(v_c.support_hours, ''),
    'tasa_bcv', case when v_tasa is null then 'del día'
                     else trim(to_char(v_tasa, 'FM999999990.00')) end,
    'cargo_atraso', public.helios_money_text(public.helios_late_fee_usd()),
    'dias_gracia', public.helios_late_fee_grace_days()::text,
    'dias_suspension', public.helios_mora_demotion_days()::text,
    'dias_expulsion', public.helios_mora_expulsion_days()::text
  );
end;
$$;

/**
 * Renderiza la plantilla `p_template_key` para el paciente y la mete en la
 * cola por `p_channel` (`email` | `whatsapp_manual`). Devuelve el id del
 * mensaje.
 *
 * - Variables: las de siempre (`helios_message_builtins`) y encima `p_vars`
 *   (gana la del llamador). El texto publicado (`title`/`body`/`html`) gana al
 *   de fábrica; si al publicado le falta una variable se usa el de fábrica, y
 *   si también le falta, error 22023: un mensaje con «{monto}» sin rellenar
 *   no sale.
 * - En el HTML las variables van escapadas, salvo las que acaban en `_html`.
 * - `p_dedupe_key`: si ya hay un mensaje con esa clave, devuelve ese y no
 *   encola otro.
 * - Se encola igual, pero como `omitido` (con el motivo en `last_error`), si
 *   la plantilla está apagada, o si es un correo y el paciente no tiene correo
 *   o su correo rebotó: queda el rastro de que se intentó.
 * - Interna: sin permiso para la API.
 */
create or replace function public.helios_enqueue_message(
  p_template_key text,
  p_profile_id   uuid,
  p_charge_id    uuid,
  p_channel      text,
  p_vars         jsonb default '{}'::jsonb,
  p_due_date     date  default null,
  p_dedupe_key   text  default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tpl       public.notification_templates%rowtype;
  v_p         public.profiles%rowtype;
  v_vars      jsonb;
  v_vars_html jsonb;
  v_subject   text;
  v_text      text;
  v_html      text;
  v_recipient text;
  v_status    text := 'pendiente';
  v_error     text;
  v_id        uuid;
begin
  if p_channel is null or p_channel not in ('email', 'whatsapp_manual') then
    raise exception 'Canal no válido: %', coalesce(p_channel, 'null') using errcode = '22023';
  end if;

  if p_dedupe_key is not null then
    select id into v_id from public.outbound_messages where dedupe_key = p_dedupe_key;
    if found then
      return v_id;
    end if;
  end if;

  select * into v_tpl from public.notification_templates where key = p_template_key;
  if not found then
    raise exception 'No existe la plantilla %', p_template_key using errcode = 'P0002';
  end if;

  if not (p_channel = any (v_tpl.channels)) then
    raise exception 'La plantilla % no sale por %', p_template_key, p_channel using errcode = '22023';
  end if;

  select * into v_p from public.profiles where id = p_profile_id;
  if not found then
    raise exception 'Paciente no encontrado' using errcode = 'P0002';
  end if;

  v_vars := public.helios_message_builtins(p_profile_id)
            || coalesce(p_vars, '{}'::jsonb);

  -- Todas como texto, para `render_notification_text` (->>).
  select coalesce(jsonb_object_agg(k,
           case when k like '%\_html' then v
                else public.helios_html_escape(v) end), '{}'::jsonb)
    into v_vars_html
  from jsonb_each_text(v_vars) as e(k, v);

  v_subject := coalesce(public.render_notification_text(v_tpl.title, v_vars),
                        public.render_notification_text(v_tpl.default_title, v_vars));
  v_text    := coalesce(public.render_notification_text(v_tpl.body, v_vars),
                        public.render_notification_text(v_tpl.default_body, v_vars));

  if v_subject is null or v_text is null then
    raise exception 'Faltan variables para la plantilla %: tiene %, se pasaron %',
      p_template_key,
      array_to_string(public.notification_markers(v_tpl.default_title || ' ' || v_tpl.default_body), ', '),
      (select string_agg(k, ', ') from jsonb_object_keys(v_vars) k)
      using errcode = '22023';
  end if;

  if p_channel = 'email' then
    v_html := coalesce(public.render_notification_text(v_tpl.html, v_vars_html),
                       public.render_notification_text(v_tpl.default_html, v_vars_html));
    if v_html is null and coalesce(v_tpl.html, v_tpl.default_html) is not null then
      raise exception 'Faltan variables para el HTML de la plantilla %', p_template_key
        using errcode = '22023';
    end if;
    v_recipient := v_p.email;
  else
    v_recipient := v_p.phone_e164;
  end if;

  if not v_tpl.enabled then
    v_status := 'omitido';
    v_error  := 'La plantilla está apagada';
  elsif v_recipient is null then
    v_status := 'omitido';
    v_error  := case when p_channel = 'email' then 'El paciente no tiene correo'
                     else 'El paciente no tiene teléfono' end;
  elsif p_channel = 'email' and v_p.email_invalid_at is not null then
    v_status := 'omitido';
    v_error  := 'El correo del paciente rebotó';
  end if;

  insert into public.outbound_messages (
    channel, template_key, profile_id, charge_id, installment_due_date,
    recipient, subject, rendered_text, html, status, last_error,
    next_attempt_at, dedupe_key
  ) values (
    p_channel, p_template_key, p_profile_id, p_charge_id, p_due_date,
    v_recipient, v_subject, v_text, v_html, v_status, v_error,
    case when v_status = 'pendiente' and p_channel = 'email' then now() end,
    p_dedupe_key
  )
  on conflict (dedupe_key) do nothing
  returning id into v_id;

  if v_id is null then
    -- Otra transacción encoló la misma clave entre la comprobación y el INSERT.
    select id into v_id from public.outbound_messages where dedupe_key = p_dedupe_key;
  end if;

  return v_id;
end;
$$;

/**
 * Arma el comprobante de un financiamiento confirmado (docs/00 §7.3) y lo
 * encola por correo al correo REGISTRADO del paciente. Devuelve el id del
 * mensaje. Sin clave de deduplicación: cada reenvío es otro mensaje (el tope
 * de reenvíos lo ponen las RPC que lo llaman, H6).
 *
 * El fee de Helios va en su propia línea (`{servicio_helios}`) y dentro de las
 * cuotas; ninguna variable suma consulta + fee.
 */
create or replace function public.helios_enqueue_charge_receipt(p_charge_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c        public.charges%rowtype;
  v_p        public.profiles%rowtype;
  v_m        public.merchants%rowtype;
  v_sede     text;
  v_staff    text;
  v_concepto text;
  v_cuotas   text;
  v_cuotas_h text;
  v_n        integer;
  v_first    public.installments%rowtype;
  v_wa       text;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found then
    raise exception 'Financiamiento no encontrado' using errcode = 'P0002';
  end if;

  if v_c.status <> 'confirmed' or v_c.user_id is null then
    raise exception 'El financiamiento no está confirmado' using errcode = '22023';
  end if;

  select * into v_p from public.profiles  where id = v_c.user_id;
  select * into v_m from public.merchants where id = v_c.merchant_id;
  select name into v_sede from public.merchant_branches where id = v_c.branch_id;

  -- Solo el nombre de pila de quien registró (docs/00 §7.3).
  v_staff := public.helios_staff_name(v_c.requested_by);
  v_staff := case
    when v_staff is null or position('@' in v_staff) > 0 then 'el personal de la clínica'
    else split_part(btrim(v_staff), ' ', 1)
  end;

  select string_agg(ci.name, ', ' order by ci.position) into v_concepto
  from public.charge_items ci where ci.charge_id = p_charge_id;

  select count(*)::integer,
         string_agg(format('• Cuota %s: $%s, vence el %s %s', i.sequence,
                           public.helios_money_text(i.amount_usd),
                           public.helios_weekday_es(i.due_date), to_char(i.due_date, 'DD/MM/YYYY')),
                    E'\n' order by i.sequence),
         string_agg(format('<tr><td style="border-top:1px solid #e5e7eb;">Cuota %s</td>'
                           '<td style="border-top:1px solid #e5e7eb;">%s %s</td>'
                           '<td align="right" style="border-top:1px solid #e5e7eb;">$%s</td></tr>',
                           i.sequence, public.helios_weekday_es(i.due_date),
                           to_char(i.due_date, 'DD/MM/YYYY'), public.helios_money_text(i.amount_usd)),
                    '' order by i.sequence)
    into v_n, v_cuotas, v_cuotas_h
  from public.installments i where i.charge_id = p_charge_id;

  if coalesce(v_n, 0) = 0 then
    raise exception 'El financiamiento no tiene cuotas' using errcode = '22023';
  end if;

  select * into v_first from public.installments
  where charge_id = p_charge_id order by sequence limit 1;

  v_wa := (select whatsapp_number from public.platform_contact where id);

  return public.helios_enqueue_message(
    'comprobante_financiamiento', v_c.user_id, p_charge_id, 'email',
    jsonb_build_object(
      'nombre_completo', coalesce(nullif(btrim(v_p.full_name), ''),
                                  btrim(concat_ws(' ', v_p.first_name, v_p.last_name))),
      'documento', coalesce(public.helios_mask_document(v_p.document_number), '—'),
      'clinica', v_m.name,
      'clinica_rif', case when v_m.tax_id is not null then '(RIF ' || v_m.tax_id || ')' else '' end,
      'sede', coalesce(v_sede, '—'),
      'registrado_por', v_staff,
      'orden', coalesce(v_c.order_number::text, left(v_c.id::text, 8)),
      'fecha_hora', to_char(coalesce(v_c.confirmed_at, v_c.created_at) at time zone 'America/Caracas',
                            'DD/MM/YYYY HH24:MI'),
      'concepto', coalesce(v_concepto, 'Consulta'),
      'monto_consulta', public.helios_money_text(coalesce(v_c.base_usd, v_c.amount_usd)),
      'servicio_helios', public.helios_money_text(coalesce(v_c.consumer_fee_usd, 0)
                                                  + coalesce(v_c.consumer_fee_vat_usd, 0)),
      'servicio_helios_pct', rtrim(to_char(coalesce(v_c.consumer_fee_pct, 0), 'FM990.##'), '.'),
      'n_cuotas', v_n::text,
      'cuotas', v_cuotas,
      'cuotas_html', v_cuotas_h,
      'monto_cuota', public.helios_money_text(v_first.amount_usd),
      'fecha', to_char(v_first.due_date, 'DD/MM/YYYY'),
      'whatsapp_link', case when v_wa is not null then
        'https://wa.me/' || regexp_replace(v_wa, '\D', '', 'g') || '?text='
        || public.helios_url_encode(format('Hola, quiero avisar un pago del financiamiento #%s',
                                           coalesce(v_c.order_number::text, left(v_c.id::text, 8))))
        else '' end
    ),
    null, null);
end;
$$;

revoke all on function public.helios_message_builtins(uuid) from public, anon, authenticated;
revoke all on function public.helios_enqueue_message(text, uuid, uuid, text, jsonb, date, text) from public, anon, authenticated;
revoke all on function public.helios_enqueue_charge_receipt(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. El catálogo de plantillas
-- ---------------------------------------------------------------------------
-- La de la poda, con el canal de verdad y los envíos contados donde toca: la
-- bandeja de la app (`notifications`) o la cola (`outbound_messages`).

create or replace function public.admin_notification_catalog()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo para el equipo de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.sort_order), '[]'::jsonb)
    into v_rows
  from (
    select
      t.key, t.type::text as type, t.label, t.trigger_label, t.help,
      t.variables, t.required_variables,
      t.default_title, t.default_body,
      t.title, t.body,
      t.draft_title, t.draft_body, t.draft_at,
      t.enabled, t.editable, t.can_disable,
      t.cron_job, t.lead_days, t.run_at, t.sort_order,
      t.published_at,
      pa.full_name as published_by,
      da.full_name as draft_by,

      -- Helios: el primer canal (compatibilidad) y todos.
      t.channels[1] as channel,
      t.channels,
      (t.coalesce_html is not null) as has_html,
      null::text as priority,

      -- Los últimos 30 días.
      case when 'app' = any (t.channels) then
        (select count(*) from public.notifications n
          where n.template_key = t.key and n.created_at > now() - interval '30 days')
      else
        (select count(*) from public.outbound_messages o
          where o.template_key = t.key and o.status = 'enviado'
            and o.created_at > now() - interval '30 days')
      end as sent,
      (select count(*) from public.notifications n
        where n.template_key = t.key
          and n.created_at > now() - interval '30 days'
          and n.read_at is not null) as opened,
      (select count(*) from public.outbound_messages o
        where o.template_key = t.key and o.last_event = 'delivered'
          and o.created_at > now() - interval '30 days') as delivered,
      (select count(*) from public.outbound_messages o
        where o.template_key = t.key and o.status = 'fallido'
          and o.created_at > now() - interval '30 days') as failed,
      (select count(*) from public.outbound_messages o
        where o.template_key = t.key and o.status in ('cancelado', 'omitido')
          and o.created_at > now() - interval '30 days') as cancelled,
      greatest(
        (select max(n.created_at) from public.notifications n where n.template_key = t.key),
        (select max(o.created_at) from public.outbound_messages o where o.template_key = t.key)
      ) as last_sent_at
    from (select nt.*, coalesce(nt.html, nt.default_html) as coalesce_html
          from public.notification_templates nt) t
    left join public.platform_admins pa on pa.user_id = t.published_by
    left join public.platform_admins da on da.user_id = t.draft_by
  ) q;

  return v_rows;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6b. El editor: límites según el canal
-- ---------------------------------------------------------------------------
-- Copiada de la base (pg_get_functiondef, 2026-09-30) con el bloque de los
-- límites cambiado y nada más.

-- ── public.admin_save_notification_draft
CREATE OR REPLACE FUNCTION public.admin_save_notification_draft(p_key text, p_title text, p_body text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor   uuid := auth.uid();
  v_tpl     public.notification_templates%rowtype;
  v_title   text := trim(coalesce(p_title, ''));
  v_body    text := trim(coalesce(p_body, ''));
  v_markers text[];
  v_unknown text[];
  v_missing text[];
begin
  if not public.is_platform_admin() then
    raise exception 'Solo para el equipo de Helios' using errcode = '42501';
  end if;

  select * into v_tpl from public.notification_templates where key = p_key;
  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = '22023';
  end if;

  if not v_tpl.editable then
    raise exception 'El texto de "%" vive dentro de una función de dinero y no se edita desde aquí',
      v_tpl.label using errcode = '42501';
  end if;

  -- Los límites del push (65/240, la bandeja de Android) solo valen para los
  -- avisos de la app. Un WhatsApp o un correo (Helios, H11) caben más largos.
  if 'app' = any (v_tpl.channels) then
    if length(v_title) = 0 or length(v_title) > 65 then
      raise exception 'El título va entre 1 y 65 caracteres' using errcode = '22023';
    end if;

    if length(v_body) = 0 or length(v_body) > 240 then
      raise exception 'El texto va entre 1 y 240 caracteres' using errcode = '22023';
    end if;
  else
    if length(v_title) = 0 or length(v_title) > 150 then
      raise exception 'El título o asunto va entre 1 y 150 caracteres' using errcode = '22023';
    end if;

    if length(v_body) = 0 or length(v_body) > 4000 then
      raise exception 'El texto va entre 1 y 4000 caracteres' using errcode = '22023';
    end if;
  end if;

  v_markers := public.notification_markers(v_title || ' ' || v_body);

  select array_agg(m) into v_unknown
  from unnest(v_markers) m
  where not (m = any (v_tpl.variables));

  if v_unknown is not null then
    raise exception 'Este aviso no sabe rellenar %. Los que tiene son: %',
      array_to_string(v_unknown, ', '),
      coalesce(nullif(array_to_string(v_tpl.variables, ', '), ''), 'ninguno')
      using errcode = '22023';
  end if;

  select array_agg(r) into v_missing
  from unnest(v_tpl.required_variables) r
  where not (r = any (v_markers));

  if v_missing is not null then
    raise exception 'Falta %: sin ese dato el aviso no dice nada útil',
      array_to_string(v_missing, ', ') using errcode = '22023';
  end if;

  update public.notification_templates
     set draft_title = v_title,
         draft_body  = v_body,
         draft_by    = v_actor,
         draft_at    = now()
   where key = p_key;

  perform audit.log(v_actor, 'notification.draft', null::uuid,
    jsonb_build_object('key', p_key, 'title', v_title, 'body', v_body));
end;
$function$
;

