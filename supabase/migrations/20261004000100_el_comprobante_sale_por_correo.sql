-- ============================================================================
-- Helios — El comprobante sale por correo (H6, docs/00 §4.4 y §7.3)
--
-- 20261002000700 dejó la cola (`outbound_messages`) y el comprobante ya
-- renderizado. Esto es el TRANSPORTE del canal `email`, dentro de la base,
-- con el mismo patrón que la cola de push de Ronda (20260825100000) y la
-- ingesta de la tasa BCV (20260824100000): `pg_cron` + la extensión `http`,
-- sin runtime aparte y con la cola consultable y auditable.
--
-- 1. `helios_resend_api_key()`: la clave de Resend, del secreto de Vault
--    `resend_api_key`. Nunca vive en una tabla legible. Si no existe, todo lo
--    que sigue NO HACE NADA: los correos se quedan en `pendiente` y ningún
--    cron falla (D-H13: Resend se configura después).
-- 2. `helios_resend_request(...)`: la ÚNICA función que sale a la red. Todo lo
--    demás pasa por ella, así que una suite la sustituye dentro de su
--    transacción (create or replace + rollback) y prueba el despacho sin
--    mandar un solo correo de verdad.
-- 3. `helios_dispatch_email_batch(p_limit)`: cada minuto. Toma los correos
--    `pendiente` cuyo `next_attempt_at` ya llegó (FOR UPDATE SKIP LOCKED: dos
--    ejecuciones solapadas nunca mandan el mismo), hace POST /emails con la
--    cabecera `Idempotency-Key` = id del mensaje (si una respuesta se pierde y
--    se reintenta, Resend no lo manda dos veces) y:
--      · 2xx → `enviado`, `provider_id`, `sent_at`, `last_event = 'sent'`;
--      · 4xx (salvo 401/403/409/429) → `fallido` con el motivo: el mensaje
--        está mal y reintentarlo no lo arregla;
--      · 401/403 → la CONFIGURACIÓN está mal (clave inválida, dominio sin
--        verificar): el mensaje vuelve a esperar 15 minutos sin gastar
--        intento y el lote se corta. Un error de configuración no puede
--        quemar los comprobantes de todo el mundo;
--      · 409/429/5xx/sin respuesta → reintento con espera creciente (1, 2,
--        4, 8, 16 min); al 6.º intento, `fallido`.
--    Sin remitente (`platform_contact.sender_email`) o sin clave: no-op.
-- 4. `helios_check_email_status(p_limit)`: cada 15 minutos, el equivalente de
--    `check_push_receipts`. Pregunta GET /emails/{id} por los enviados de las
--    últimas 72 h y guarda `last_event` (delivered, bounced, complained…).
--    Un rebote o una queja marca `profiles.email_invalid_at` (si el paciente
--    sigue teniendo ESE correo): el siguiente comprobante sale `omitido`, la
--    alerta `correo_rebotado` aparece y la clínica ve «el correo del paciente
--    no es válido». Los ya entregados se vuelven a mirar cada 6 h (una queja
--    llega después de la entrega), los demás en cada pasada.
-- 5. El comprobante (docs/00 §7.3): HTML con tablas (Gmail/Outlook) y versión
--    de texto. Clínica, paciente enmascarado, concepto, monto de la consulta,
--    las cuotas con fecha y monto, el Servicio Helios SOLO como línea aparte
--    (nunca sumado a la consulta en un total), cómo pagar, el enlace wa.me con
--    el número de financiamiento, las condiciones, «Si no reconoces este
--    financiamiento…» y «Este comprobante no es una factura fiscal».
-- 6. `admin_resend_receipt(p_charge_id, p_email)` (docs/01 §2.2): el equipo
--    reenvía el comprobante y, si viene `p_email`, corrige antes el correo
--    del paciente (bitácora) y limpia `email_invalid_at`.
--
-- Para encender Resend (nada de esto lo hace una migración):
--   select vault.create_secret('<re_…>', 'resend_api_key', 'Resend (correo de Helios)');
--   y en Ajustes › Contacto: sender_name y sender_email de un dominio
--   verificado en Resend (SPF, DKIM y DMARC en su DNS).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Columnas del seguimiento
-- ---------------------------------------------------------------------------

alter table public.outbound_messages
  add column last_checked_at timestamptz,
  add column last_event_at   timestamptz;

comment on column public.outbound_messages.last_event is
  'Correo: sent | delivered | delivery_delayed | bounced | complained | opened | clicked (lo que dice Resend).';
comment on column public.outbound_messages.last_checked_at is
  'Correo: la última vez que se le preguntó a Resend por su estado.';

create index outbound_messages_por_consultar_idx on public.outbound_messages (sent_at)
  where channel = 'email' and status = 'enviado';

-- ---------------------------------------------------------------------------
-- 1. La clave
-- ---------------------------------------------------------------------------

/**
 * La clave de la API de Resend, del secreto de Vault `resend_api_key`, o null
 * si no existe (o si Vault no se deja leer). Interna: solo la usan el
 * despacho y la consulta de estado, que corren como el dueño en el cron.
 */
create or replace function public.helios_resend_api_key()
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_key text;
begin
  begin
    select nullif(btrim(decrypted_secret), '') into v_key
    from vault.decrypted_secrets
    where name = 'resend_api_key'
    limit 1;
  exception when others then
    v_key := null;
  end;
  return v_key;
end;
$$;

revoke all on function public.helios_resend_api_key() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. La única salida a la red
-- ---------------------------------------------------------------------------

/**
 * Una llamada a la API de Resend. Devuelve `{status, body}` con el código
 * HTTP y el cuerpo en texto. Si la red falla (timeout, DNS…) LANZA: el
 * llamador lo trata como «sin respuesta» y reintenta.
 *
 * Es la costura de las pruebas: una suite la reemplaza dentro de su
 * transacción por una que no sale a la red.
 */
create or replace function public.helios_resend_request(
  p_method          text,
  p_path            text,
  p_api_key         text,
  p_body            jsonb default null,
  p_idempotency_key text  default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_headers extensions.http_header[];
  v_status  integer;
  v_content text;
begin
  if p_api_key is null then
    raise exception 'Falta la clave de Resend' using errcode = '22023';
  end if;

  v_headers := array[
    extensions.http_header('Authorization', 'Bearer ' || p_api_key),
    extensions.http_header('Accept', 'application/json'),
    -- La extensión `http` no descomprime gzip.
    extensions.http_header('Accept-Encoding', 'identity')
  ];
  if p_idempotency_key is not null then
    v_headers := v_headers || extensions.http_header('Idempotency-Key', p_idempotency_key);
  end if;

  -- Sin tope, un servidor que acepta la conexión y no contesta cuelga el cron.
  begin
    perform extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '4000');
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  exception when others then
    null;
  end;

  select r.status, r.content into v_status, v_content
  from extensions.http((
    upper(p_method),
    'https://api.resend.com' || p_path,
    v_headers,
    case when p_body is not null then 'application/json' end,
    case when p_body is not null then p_body::text end
  )::extensions.http_request) as r;

  return jsonb_build_object('status', v_status, 'body', v_content);
end;
$$;

revoke all on function public.helios_resend_request(text, text, text, jsonb, text) from public, anon, authenticated;

/** `Nombre <correo>` de `platform_contact`, o null si falta el correo. */
create or replace function public.helios_email_sender()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
    when c.sender_email is null then null
    else format('%s <%s>',
                coalesce(nullif(btrim(replace(replace(c.sender_name, '"', ''), '<', '')), ''), 'Helios'),
                c.sender_email)
  end
  from public.platform_contact c
  where c.id;
$$;

revoke all on function public.helios_email_sender() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. El despacho
-- ---------------------------------------------------------------------------

/**
 * Manda a Resend hasta `p_limit` correos pendientes (docs/00 §4.4 H6). La
 * llama el cron cada minuto. Devuelve un resumen:
 * `{ok, skipped?, claimed, sent, failed, retry}`.
 */
create or replace function public.helios_dispatch_email_batch(p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_attempts constant integer := 6;
  v_key     text := public.helios_resend_api_key();
  v_from    text := public.helios_email_sender();
  v_reply   text := (select support_email from public.platform_contact where id);
  v_start   timestamptz := clock_timestamp();
  v_msg     public.outbound_messages%rowtype;
  v_payload jsonb;
  v_res     jsonb;
  v_status  integer;
  v_body    text;
  v_err     text;
  v_pid     text;
  v_att     integer;
  v_claimed integer := 0;
  v_sent    integer := 0;
  v_failed  integer := 0;
  v_retry   integer := 0;
  v_omit    integer := 0;
  v_first   boolean := true;
begin
  -- Sin clave o sin remitente no se toca nada: los correos esperan en
  -- `pendiente`, sin gastar intentos, hasta que se configure (D-H13).
  if v_key is null then
    return jsonb_build_object('ok', true, 'skipped', 'sin_clave', 'claimed', 0);
  end if;
  if v_from is null then
    return jsonb_build_object('ok', true, 'skipped', 'sin_remitente', 'claimed', 0);
  end if;

  for v_msg in
    select o.*
    from public.outbound_messages o
    where o.channel = 'email'
      and o.status = 'pendiente'
      and coalesce(o.next_attempt_at, o.created_at) <= now()
    order by coalesce(o.next_attempt_at, o.created_at), o.created_at
    limit least(greatest(coalesce(p_limit, 20), 1), 100)
    for update skip locked
  loop
    -- Un minuto por pasada, como mucho: lo que no dé tiempo sale en la
    -- siguiente (los reclamados y no mandados vuelven a estar libres al
    -- terminar la transacción).
    exit when clock_timestamp() - v_start > interval '40 seconds';
    v_claimed := v_claimed + 1;

    -- El paciente pudo quedarse sin correo válido entre encolar y mandar.
    if v_msg.recipient is null or not public.helios_valid_email(v_msg.recipient) then
      update public.outbound_messages
         set status = 'omitido', last_error = 'El paciente no tiene un correo válido'
       where id = v_msg.id;
      v_omit := v_omit + 1;
      continue;
    end if;

    if exists (
      select 1 from public.profiles p
      where p.id = v_msg.profile_id
        and p.email_invalid_at is not null
        and lower(p.email) = lower(v_msg.recipient)
    ) then
      update public.outbound_messages
         set status = 'omitido', last_error = 'El correo del paciente rebotó'
       where id = v_msg.id;
      v_omit := v_omit + 1;
      continue;
    end if;

    -- Resend admite 2 peticiones por segundo por equipo.
    if not v_first then
      perform pg_sleep(0.55);
    end if;
    v_first := false;

    v_payload := jsonb_build_object(
      'from',    v_from,
      'to',      jsonb_build_array(v_msg.recipient),
      'subject', coalesce(v_msg.subject, 'Helios'),
      'text',    v_msg.rendered_text
    );
    if v_msg.html is not null then
      v_payload := v_payload || jsonb_build_object('html', v_msg.html);
    end if;
    if v_reply is not null then
      v_payload := v_payload || jsonb_build_object('reply_to', v_reply);
    end if;

    v_status := null;
    v_body   := null;
    v_err    := null;
    begin
      v_res    := public.helios_resend_request('POST', '/emails', v_key, v_payload, v_msg.id::text);
      v_status := (v_res ->> 'status')::integer;
      v_body   := v_res ->> 'body';
    exception when others then
      v_err := left(sqlerrm, 300);
    end;

    v_att := v_msg.attempts + 1;

    if v_status between 200 and 299 then
      begin
        v_pid := v_body::jsonb ->> 'id';
      exception when others then
        v_pid := null;
      end;

      update public.outbound_messages
         set status = 'enviado', provider_id = v_pid, sent_at = now(),
             last_event = 'sent', last_event_at = now(),
             attempts = v_att, next_attempt_at = null, last_error = null
       where id = v_msg.id;
      v_sent := v_sent + 1;

    elsif v_status in (401, 403) then
      -- La configuración, no el mensaje: se espera sin gastar intento y se
      -- corta el lote (los demás fallarían igual).
      update public.outbound_messages
         set next_attempt_at = now() + interval '15 minutes',
             last_error = left(format('Resend rechazó la configuración (HTTP %s): %s', v_status, coalesce(v_body, '')), 300)
       where id = v_msg.id;
      v_retry := v_retry + 1;
      exit;

    elsif v_status between 400 and 499 and v_status not in (409, 429) then
      update public.outbound_messages
         set status = 'fallido', attempts = v_att, next_attempt_at = null,
             last_error = left(format('HTTP %s: %s', v_status, coalesce(v_body, '')), 300)
       where id = v_msg.id;
      v_failed := v_failed + 1;

    else
      -- 409 (la misma clave en curso), 429, 5xx o sin respuesta: más tarde.
      v_err := coalesce(v_err, format('HTTP %s: %s', v_status, left(coalesce(v_body, ''), 250)));
      if v_att >= c_max_attempts then
        update public.outbound_messages
           set status = 'fallido', attempts = v_att, next_attempt_at = null,
               last_error = left(format('Sin entregar a Resend tras %s intentos. Último: %s', v_att, v_err), 300)
         where id = v_msg.id;
        v_failed := v_failed + 1;
      else
        update public.outbound_messages
           set attempts = v_att,
               next_attempt_at = now() + interval '1 minute' * power(2, v_att - 1),
               last_error = left(v_err, 300)
         where id = v_msg.id;
        v_retry := v_retry + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true, 'claimed', v_claimed, 'sent', v_sent, 'failed', v_failed,
    'retry', v_retry, 'omitted', v_omit
  );
end;
$$;

comment on function public.helios_dispatch_email_batch(integer) is
  'Manda a Resend un lote de correos pendientes de outbound_messages. La llama el cron cada minuto; sin clave o sin remitente no hace nada.';

revoke all on function public.helios_dispatch_email_batch(integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. El estado de lo enviado
-- ---------------------------------------------------------------------------

/**
 * Pregunta a Resend por el estado de los correos enviados en las últimas 72 h
 * y guarda `last_event`. Un rebote o una queja marca el correo del paciente
 * como inválido (`profiles.email_invalid_at`), solo si sigue siendo el mismo.
 */
create or replace function public.helios_check_email_status(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key     text := public.helios_resend_api_key();
  v_start   timestamptz := clock_timestamp();
  v_msg     public.outbound_messages%rowtype;
  v_res     jsonb;
  v_status  integer;
  v_body    jsonb;
  v_event   text;
  v_checked integer := 0;
  v_changed integer := 0;
  v_invalid integer := 0;
  v_first   boolean := true;
begin
  if v_key is null then
    return jsonb_build_object('ok', true, 'skipped', 'sin_clave', 'checked', 0);
  end if;

  for v_msg in
    select o.*
    from public.outbound_messages o
    where o.channel = 'email'
      and o.status = 'enviado'
      and o.provider_id is not null
      and o.sent_at > now() - interval '72 hours'
      and coalesce(o.last_event, 'sent') not in ('bounced', 'complained')
      and (
        o.last_checked_at is null
        or o.last_checked_at < now() - case
             when o.last_event in ('delivered', 'opened', 'clicked') then interval '6 hours'
             else interval '10 minutes' end
      )
    order by o.last_checked_at nulls first, o.sent_at
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
    for update skip locked
  loop
    exit when clock_timestamp() - v_start > interval '40 seconds';

    if not v_first then
      perform pg_sleep(0.55);
    end if;
    v_first := false;

    v_status := null;
    v_body   := null;
    begin
      v_res    := public.helios_resend_request('GET', '/emails/' || v_msg.provider_id, v_key, null, null);
      v_status := (v_res ->> 'status')::integer;
      v_body   := (v_res ->> 'body')::jsonb;
    exception when others then
      v_status := null;
    end;

    -- La clave dejó de valer: no tiene sentido seguir preguntando.
    exit when v_status in (401, 403);

    v_checked := v_checked + 1;
    v_event := case when v_status = 200 then nullif(v_body ->> 'last_event', '') end;

    update public.outbound_messages
       set last_checked_at = now(),
           last_event      = coalesce(v_event, last_event),
           last_event_at   = case when v_event is distinct from last_event and v_event is not null
                                  then now() else last_event_at end
     where id = v_msg.id;

    if v_event is distinct from v_msg.last_event and v_event is not null then
      v_changed := v_changed + 1;
    end if;

    if v_event in ('bounced', 'complained') then
      update public.profiles
         set email_invalid_at = coalesce(email_invalid_at, now())
       where id = v_msg.profile_id
         and lower(email) = lower(v_msg.recipient);
      if found then
        v_invalid := v_invalid + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'checked', v_checked, 'changed', v_changed,
                            'invalidated', v_invalid);
end;
$$;

comment on function public.helios_check_email_status(integer) is
  'Consulta a Resend el estado de los correos enviados (72 h) y marca los rebotes en el paciente. Cron cada 15 minutos.';

revoke all on function public.helios_check_email_status(integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. El comprobante
-- ---------------------------------------------------------------------------

update public.notification_templates
   set default_title = 'Tu financiamiento en {clinica} — {n_cuotas} cuotas de ${monto_cuota}',
       variables = array['nombre','nombre_completo','documento','clinica','clinica_rif','sede',
                         'registrado_por','orden','fecha_hora','concepto','monto_consulta',
                         'servicio_helios','servicio_helios_pct','n_cuotas','cuotas','cuotas_html',
                         'monto_cuota','fecha','cuentas_de_cobro','cuentas_de_cobro_html',
                         'whatsapp_helios','whatsapp_link','aviso_pago','aviso_pago_html',
                         'no_reconoces','no_reconoces_html','soporte_email','cargo_atraso',
                         'dias_gracia','dias_suspension','dias_expulsion','tasa_bcv'],
       default_body =
            E'Hola, {nombre}:\n\n'
         || E'Este es el comprobante de tu financiamiento con Helios. Guárdalo: aquí están tus cuotas y cómo pagarlas.\n\n'
         || E'FINANCIAMIENTO #{orden}\n'
         || E'{fecha_hora} (hora de Caracas)\n\n'
         || E'Clínica: {clinica} {clinica_rif}\n'
         || E'Sede: {sede}\n'
         || E'Registró: {registrado_por}\n'
         || E'Titular: {nombre_completo} · C.I. {documento}\n\n'
         || E'Servicios: {concepto}\n'
         || E'Monto de la consulta: ${monto_consulta}\n\n'
         || E'TU PLAN DE PAGOS (sin inicial)\n{cuotas}\n\n'
         || E'Desglose: las cuotas incluyen el Servicio Helios ({servicio_helios_pct} % + IVA) de ${servicio_helios}.\n\n'
         || E'CÓMO PAGAR\n'
         || E'Pagas en bolívares, a la tasa BCV del dólar del día en que pagues.\n{cuentas_de_cobro}\n\n'
         || E'{aviso_pago}\n\n'
         || E'CONDICIONES\n'
         || E'• Desde el primer día de atraso tu cuenta queda congelada: no podrás financiar nuevas consultas hasta ponerte al día.\n'
         || E'• Después de {dias_gracia} días de gracia se suma un cargo de ${cargo_atraso} por cada cuota vencida.\n'
         || E'• A los {dias_suspension} días de atraso la cuenta se suspende.\n'
         || E'• A los {dias_expulsion} días de atraso la cuenta se cierra y la deuda pasa a cobranza.\n\n'
         || E'{no_reconoces}\n\n'
         || 'Este comprobante no es una factura fiscal.',
       default_html = $html$<!doctype html>
<html lang="es" xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<title>Tu financiamiento con Helios</title>
</head>
<body style="margin:0;padding:0;background-color:#f1f4f9;">
<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;">Financiamiento #{orden} en {clinica}: {n_cuotas} cuotas de ${monto_cuota}.</div>
<table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" bgcolor="#f1f4f9" style="background-color:#f1f4f9;">
<tr><td align="center" style="padding:24px 12px;">
<table role="presentation" width="600" border="0" cellpadding="0" cellspacing="0" bgcolor="#ffffff" style="width:600px;max-width:600px;background-color:#ffffff;border:1px solid #dfe5ee;">

<tr><td bgcolor="#1A56DB" style="background-color:#1A56DB;padding:22px 28px;font-family:Arial,Helvetica,sans-serif;color:#ffffff;">
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0">
  <tr>
    <td style="font-family:Arial,Helvetica,sans-serif;font-size:24px;font-weight:bold;color:#ffffff;">Helios</td>
    <td align="right" style="font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#dbe7ff;">Comprobante de financiamiento</td>
  </tr>
  <tr><td colspan="2" style="padding-top:10px;font-family:Arial,Helvetica,sans-serif;font-size:15px;color:#ffffff;">
    Financiamiento <strong>#{orden}</strong> &middot; {fecha_hora} (hora de Caracas)
  </td></tr>
  </table>
</td></tr>

<tr><td style="padding:24px 28px 8px 28px;font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#1f2937;">
  <p style="margin:0 0 10px 0;">Hola, {nombre}:</p>
  <p style="margin:0;">Este es el comprobante de tu financiamiento con Helios. Gu&aacute;rdalo: aqu&iacute; est&aacute;n tus cuotas y c&oacute;mo pagarlas.</p>
</td></tr>

<tr><td style="padding:16px 28px 0 28px;">
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" style="border:1px solid #e5e7eb;">
  <tr><td colspan="2" bgcolor="#f8fafc" style="background-color:#f8fafc;padding:8px 12px;font-family:Arial,Helvetica,sans-serif;font-size:12px;font-weight:bold;color:#475569;text-transform:uppercase;letter-spacing:1px;">Datos del financiamiento</td></tr>
  <tr>
    <td width="40%" style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#64748b;">Cl&iacute;nica</td>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#1f2937;">{clinica} {clinica_rif}</td>
  </tr>
  <tr>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#64748b;">Sede</td>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#1f2937;">{sede}</td>
  </tr>
  <tr>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#64748b;">Registr&oacute;</td>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#1f2937;">{registrado_por}</td>
  </tr>
  <tr>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#64748b;">Titular</td>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#1f2937;">{nombre_completo} &middot; C.I. {documento}</td>
  </tr>
  <tr>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#64748b;">Servicios</td>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#1f2937;">{concepto}</td>
  </tr>
  <tr>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#64748b;">Monto de la consulta</td>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#1f2937;font-weight:bold;">${monto_consulta}</td>
  </tr>
  </table>
</td></tr>

<tr><td style="padding:24px 28px 0 28px;font-family:Arial,Helvetica,sans-serif;font-size:17px;font-weight:bold;color:#0f172a;">Tu plan de pagos, sin inicial</td></tr>
<tr><td style="padding:8px 28px 0 28px;">
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" style="border:1px solid #e5e7eb;">
  <tr bgcolor="#f8fafc">
    <th align="left" style="padding:8px 12px;font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#475569;">Cuota</th>
    <th align="left" style="padding:8px 12px;font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#475569;">Vence</th>
    <th align="right" style="padding:8px 12px;font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#475569;">Monto</th>
  </tr>
  {cuotas_html}
  </table>
</td></tr>
<tr><td style="padding:8px 28px 0 28px;font-family:Arial,Helvetica,sans-serif;font-size:13px;line-height:19px;color:#64748b;">
  Desglose: las cuotas incluyen el <strong>Servicio Helios ({servicio_helios_pct}&nbsp;% + IVA)</strong> de ${servicio_helios}.
</td></tr>

<tr><td style="padding:24px 28px 0 28px;font-family:Arial,Helvetica,sans-serif;font-size:17px;font-weight:bold;color:#0f172a;">C&oacute;mo pagar</td></tr>
<tr><td style="padding:8px 28px 0 28px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1f2937;">
  <p style="margin:0 0 8px 0;">Pagas en <strong>bol&iacute;vares</strong>, a la tasa BCV del d&oacute;lar <strong>del d&iacute;a en que pagues</strong>.</p>
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" bgcolor="#f8fafc" style="background-color:#f8fafc;border:1px solid #e5e7eb;">
  <tr><td style="padding:10px 12px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1f2937;">{cuentas_de_cobro_html}</td></tr>
  </table>
</td></tr>
<tr><td style="padding:16px 28px 0 28px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1f2937;">
  {aviso_pago_html}
</td></tr>

<tr><td style="padding:24px 28px 0 28px;font-family:Arial,Helvetica,sans-serif;font-size:17px;font-weight:bold;color:#0f172a;">Condiciones</td></tr>
<tr><td style="padding:8px 28px 0 28px;">
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0">
  <tr><td valign="top" width="18" style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1A56DB;">&bull;</td>
      <td style="padding-bottom:6px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1f2937;">Desde el primer d&iacute;a de atraso tu cuenta queda congelada: no podr&aacute;s financiar nuevas consultas hasta ponerte al d&iacute;a.</td></tr>
  <tr><td valign="top" width="18" style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1A56DB;">&bull;</td>
      <td style="padding-bottom:6px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1f2937;">Despu&eacute;s de {dias_gracia} d&iacute;as de gracia se suma un cargo de ${cargo_atraso} por cada cuota vencida.</td></tr>
  <tr><td valign="top" width="18" style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1A56DB;">&bull;</td>
      <td style="padding-bottom:6px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1f2937;">A los {dias_suspension} d&iacute;as de atraso la cuenta se suspende.</td></tr>
  <tr><td valign="top" width="18" style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1A56DB;">&bull;</td>
      <td style="padding-bottom:6px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1f2937;">A los {dias_expulsion} d&iacute;as de atraso la cuenta se cierra y la deuda pasa a cobranza.</td></tr>
  </table>
</td></tr>

<tr><td style="padding:20px 28px 0 28px;">
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" bgcolor="#fff7e6" style="background-color:#fff7e6;border:1px solid #f5d38b;">
  <tr><td style="padding:12px 14px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#7a4b00;">{no_reconoces_html}</td></tr>
  </table>
</td></tr>

<tr><td style="padding:24px 28px 24px 28px;font-family:Arial,Helvetica,sans-serif;font-size:12px;line-height:18px;color:#64748b;">
  <p style="margin:16px 0 0 0;padding-top:16px;border-top:1px solid #e5e7eb;">Este comprobante no es una factura fiscal.</p>
</td></tr>

</table>
</td></tr>
</table>
</body>
</html>$html$
 where key = 'comprobante_financiamiento';

/**
 * Arma el comprobante de un financiamiento confirmado (docs/00 §7.3) y lo
 * encola por correo al correo REGISTRADO del paciente. Devuelve el id del
 * mensaje. La de 20261002000700 con las variables del comprobante nuevo:
 * `aviso_pago(_html)` (el wa.me con el número de financiamiento, o el texto de
 * reserva si el WhatsApp no está configurado), `no_reconoces(_html)` y las
 * filas de las cuotas con su estilo.
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
  v_contact  public.platform_contact%rowtype;
  v_sede     text;
  v_staff    text;
  v_concepto text;
  v_cuotas   text;
  v_cuotas_h text;
  v_n        integer;
  v_first    public.installments%rowtype;
  v_orden    text;
  v_wa       text;
  v_wa_txt   text;
  v_link     text;
  v_td       constant text := 'padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#1f2937;';
  v_aviso    text;
  v_aviso_h  text;
  v_noreco   text;
  v_noreco_h text;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found then
    raise exception 'Financiamiento no encontrado' using errcode = 'P0002';
  end if;

  if v_c.status <> 'confirmed' or v_c.user_id is null then
    raise exception 'El financiamiento no está confirmado' using errcode = '22023';
  end if;

  select * into v_p       from public.profiles  where id = v_c.user_id;
  select * into v_m       from public.merchants where id = v_c.merchant_id;
  select * into v_contact from public.platform_contact where id;
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
         string_agg(format('<tr><td style="%s">Cuota %s</td><td style="%s">%s %s</td>'
                           '<td align="right" style="%sfont-weight:bold;">$%s</td></tr>',
                           v_td, i.sequence, v_td, public.helios_weekday_es(i.due_date),
                           to_char(i.due_date, 'DD/MM/YYYY'), v_td,
                           public.helios_money_text(i.amount_usd)),
                    '' order by i.sequence)
    into v_n, v_cuotas, v_cuotas_h
  from public.installments i where i.charge_id = p_charge_id;

  if coalesce(v_n, 0) = 0 then
    raise exception 'El financiamiento no tiene cuotas' using errcode = '22023';
  end if;

  select * into v_first from public.installments
  where charge_id = p_charge_id order by sequence limit 1;

  v_orden := coalesce(v_c.order_number::text, left(v_c.id::text, 8));
  v_wa    := v_contact.whatsapp_number;

  if v_wa is not null then
    v_wa_txt := coalesce(public.helios_format_ve_phone(v_wa), v_wa);
    v_link := 'https://wa.me/' || regexp_replace(v_wa, '\D', '', 'g') || '?text='
              || public.helios_url_encode(format('Hola, quiero avisar un pago del financiamiento #%s', v_orden));
    v_aviso := format('Cuando pagues, envíanos el comprobante por WhatsApp al %s: %s', v_wa_txt, v_link);
    v_aviso_h := format(
      '<p style="margin:0 0 10px 0;">Cuando pagues, env&iacute;anos el comprobante por WhatsApp al %s, indicando el financiamiento #%s.</p>'
      '<table role="presentation" border="0" cellpadding="0" cellspacing="0"><tr>'
      '<td bgcolor="#1A56DB" style="background-color:#1A56DB;border-radius:4px;">'
      '<a href="%s" target="_blank" style="display:inline-block;padding:11px 20px;font-family:Arial,Helvetica,sans-serif;font-size:15px;font-weight:bold;color:#ffffff;text-decoration:none;">Avisar mi pago por WhatsApp</a>'
      '</td></tr></table>',
      public.helios_html_escape(v_wa_txt), public.helios_html_escape(v_orden),
      public.helios_html_escape(v_link));
    v_noreco := format('Si no reconoces este financiamiento, escríbenos enseguida por WhatsApp al %s%s.',
                       v_wa_txt, coalesce(' o a ' || v_contact.support_email, ''));
  else
    v_link := '';
    v_aviso := 'Helios te escribirá por WhatsApp con las instrucciones para avisar tu pago.';
    v_aviso_h := '<p style="margin:0;">Helios te escribir&aacute; por WhatsApp con las instrucciones para avisar tu pago.</p>';
    v_noreco := case
      when v_contact.support_email is not null then
        format('Si no reconoces este financiamiento, escríbenos enseguida a %s.', v_contact.support_email)
      else 'Si no reconoces este financiamiento, escríbenos enseguida respondiendo a este correo.'
    end;
  end if;
  v_noreco_h := '<strong>' || public.helios_html_escape(v_noreco) || '</strong>';

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
      'orden', v_orden,
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
      'whatsapp_link', v_link,
      'aviso_pago', v_aviso,
      'aviso_pago_html', v_aviso_h,
      'no_reconoces', v_noreco,
      'no_reconoces_html', v_noreco_h
    ),
    null, null);
end;
$$;

revoke all on function public.helios_enqueue_charge_receipt(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Reenviar el comprobante desde el superadmin
-- ---------------------------------------------------------------------------

/**
 * Reenvía el comprobante de un financiamiento (docs/01 §2.2). Si viene
 * `p_email` y es distinto del registrado, primero corrige el correo del
 * paciente (queda en la bitácora con el de antes y el de después) y limpia
 * `email_invalid_at`: el correo nuevo empieza sin rebotes. Operador o super
 * admin, como `admin_update_patient_contact`.
 *
 * `{ok, message_id, status, email_enmascarado, email_changed, last_error}`.
 * `status` es el del mensaje encolado: `pendiente`, u `omitido` si el
 * paciente no tiene correo o el suyo rebotó y no se corrigió.
 */
create or replace function public.admin_resend_receipt(p_charge_id uuid, p_email text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor   uuid := auth.uid();
  v_charge  public.charges%rowtype;
  v_p       public.profiles%rowtype;
  v_email   text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_changed boolean := false;
  v_msg     uuid;
  v_row     public.outbound_messages%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'Financiamiento no encontrado' using errcode = 'P0002';
  end if;
  if v_charge.status <> 'confirmed' or v_charge.user_id is null then
    raise exception 'El financiamiento no está confirmado' using errcode = '22023';
  end if;

  select * into v_p from public.profiles where id = v_charge.user_id for update;

  if v_email is not null then
    if not public.helios_valid_email(v_email) then
      raise exception 'Correo inválido' using errcode = '22023';
    end if;

    if v_email is distinct from lower(v_p.email) then
      update public.profiles
         set email = v_email, email_invalid_at = null, updated_at = now()
       where id = v_p.id;
      v_changed := true;

      perform audit.log(v_actor, 'patient.email_corrected', v_p.id, jsonb_build_object(
        'antes', v_p.email,
        'despues', v_email,
        'email_invalid_at_antes', v_p.email_invalid_at,
        'charge_id', p_charge_id,
        'motivo', 'Reenvío del comprobante'
      ));
    end if;
  end if;

  v_msg := public.helios_enqueue_charge_receipt(p_charge_id);
  select * into v_row from public.outbound_messages where id = v_msg;

  perform audit.log(v_actor, 'receipt.resent', p_charge_id, jsonb_build_object(
    'message_id', v_msg,
    'status', v_row.status,
    'email_changed', v_changed,
    'order_number', v_charge.order_number
  ));

  return jsonb_build_object(
    'ok', true,
    'message_id', v_msg,
    'status', v_row.status,
    'email_enmascarado', public.helios_mask_email(v_row.recipient),
    'email_changed', v_changed,
    'last_error', v_row.last_error
  );
end;
$$;

revoke all on function public.admin_resend_receipt(uuid, text) from public, anon;
grant execute on function public.admin_resend_receipt(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Cron
-- ---------------------------------------------------------------------------

do $cron$
begin
  begin
    perform cron.unschedule('helios_email_dispatch');
  exception when others then
    null;
  end;
  begin
    perform cron.unschedule('helios_email_status');
  exception when others then
    null;
  end;
end;
$cron$;

select cron.schedule('helios_email_dispatch', '* * * * *',
                     $c$ select public.helios_dispatch_email_batch(); $c$);

select cron.schedule('helios_email_status', '*/15 * * * *',
                     $c$ select public.helios_check_email_status(); $c$);
