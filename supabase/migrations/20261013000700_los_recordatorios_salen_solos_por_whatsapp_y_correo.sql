-- ============================================================================
-- Helios — Los recordatorios salen solos, por WhatsApp y por correo (2026-10-13)
--
-- Decidido por Javier el 2026-10-13 (docs/00 §7.2 y §15.7):
--
--   1. Un recordatorio más, `cuota_en_3_dias`: tres días antes del
--      vencimiento, a las 12:00 (Caracas). Los momentos de una fecha D quedan
--      en D-3, D-1, D y D+1 (D+4, el cargo por atraso, sigue apagado mientras
--      `late_fee_usd` = 0).
--   2. Los avisos del paciente pasan de `whatsapp_manual` a `whatsapp`
--      (automático, 360dialog) y TODOS salen también por correo:
--      `cuota_en_3_dias`, `cuota_manana`, `cuota_hoy`, `cuota_vencida_d1`,
--      `cargo_por_atraso_d4`, `pago_recibido`, `pago_rechazado` y
--      `cuenta_congelada`. Dentro de la ventana de 24 h el WhatsApp sale como
--      texto libre; fuera, con la plantilla de Meta (`wa_template_name`), y
--      mientras Meta no la apruebe, cae a la cola manual «Avisos de hoy» como
--      hasta ahora (helios_whatsapp_payload). Por eso esto puede estar en
--      producción antes de la aprobación: se conecta cada plantilla con un
--      `update` de `wa_template_name` (docs/00 §15.7). Los parámetros
--      (`wa_template_params`) ya quedan puestos.
--   3. `cuenta_congelada` se APAGA. El motor de mora (10:05) congela la
--      cuenta el día +1, dos horas después de `cuota_vencida_d1` (08:05), que
--      ya dice lo mismo («mientras esté vencida no podrás pagar nuevas
--      consultas en cuotas») con el monto, la fecha y la orden: le llegaban
--      dos mensajes casi iguales el mismo día. Y el congelamiento no mira los
--      pagos registrados, así que a quien ya había mandado su comprobante le
--      llegaba «tienes una cuota vencida… para pagar». `notify_account_status`
--      no encola nada si la plantilla está apagada (antes dejaba una fila
--      `omitido`). Se puede volver a encender desde el panel.
--   4. `{por_whatsapp}`: dónde mandar el comprobante, según el canal. En
--      WhatsApp «por este chat»; en el correo «por WhatsApp al 0414-…». Así el
--      mismo cuerpo vale para los dos canales (el correo lleva el texto como
--      versión plana).
--   5. Los correos llevan la marca (la misma maqueta que `cuota_manana`,
--      20261008000200). «¡Gracias por tu puntualidad!» de `pago_recibido`
--      pasa a «¡Gracias por confiar en Helios!»: también lo recibe quien pagó
--      tarde.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El recordatorio de tres días antes
-- ---------------------------------------------------------------------------

insert into public.notification_templates (
  key, label, trigger_label, help, variables, required_variables,
  default_title, default_body, enabled, editable, can_disable,
  cron_job, lead_days, run_at, sort_order, channels
) values (
  'cuota_en_3_dias',
  'Tu cuota vence en 3 días',
  'Tres días antes del vencimiento',
  'El primer recordatorio, con margen para organizarse. Por WhatsApp y por correo.',
  array['nombre','clinica','orden','monto_cuota','fecha','moneda','cuentas_de_cobro',
        'cuentas_de_cobro_html','whatsapp_helios','por_whatsapp'],
  array['monto_cuota','fecha'],
  'Tu cuota de {monto_cuota} vence el {fecha}',
  E'Hola, {nombre}. Te recordamos que el {fecha} vence tu cuota de {monto_cuota} de la orden #{orden} en {clinica}.\n\nPuedes pagar en bolívares (Pago Móvil o transferencia), a la tasa BCV del {moneda} del día en que pagues:\n{cuentas_de_cobro}\n\nCuando pagues, envíanos el comprobante {por_whatsapp}. ¡Gracias!',
  true, true, true,
  'helios_aviso_cuota_en_3_dias', 3, time '12:00', 25, array['whatsapp','email']
)
on conflict (key) do nothing;

-- 12:00 en Caracas = 16:00 UTC.
select cron.schedule('helios_aviso_cuota_en_3_dias', '0 16 * * *',
                     'select public.helios_enqueue_reminders(''cuota_en_3_dias'');');

-- ---------------------------------------------------------------------------
-- 2. Los textos: el mismo cuerpo para WhatsApp y para el correo
-- ---------------------------------------------------------------------------

update public.notification_templates
   set default_body = E'Hola, {nombre}. Te recordamos que mañana, {fecha}, vence tu cuota de {monto_cuota} de la orden #{orden} en {clinica}.\n\nPuedes pagar en bolívares (Pago Móvil o transferencia), a la tasa BCV del {moneda} del día en que pagues:\n{cuentas_de_cobro}\n\nCuando pagues, envíanos el comprobante {por_whatsapp}. ¡Gracias!'
 where key = 'cuota_manana';

update public.notification_templates
   set default_body = E'Buenos días, {nombre}. Hoy vence tu cuota de {monto_cuota} de la orden #{orden} en {clinica}.\n\nPara pagar, en bolívares a la tasa BCV del {moneda} del día:\n{cuentas_de_cobro}\n\nCuando pagues, envíanos el comprobante {por_whatsapp}. Si ya pagaste, ignora este mensaje.'
 where key = 'cuota_hoy';

update public.notification_templates
   set default_body = E'Hola, {nombre}. Tu cuota de {monto_cuota} del {fecha} (orden #{orden}) sigue pendiente.\n\nMientras esté vencida no podrás pagar nuevas consultas en cuotas con Helios.{aviso_cargo_atraso}\n\nPara pagar, en bolívares a la tasa BCV del {moneda} del día:\n{cuentas_de_cobro}\n\nSi tienes algún inconveniente, escríbenos {por_whatsapp} y lo resolvemos juntos.'
 where key = 'cuota_vencida_d1';

update public.notification_templates
   set default_body = E'Hola, {nombre}. Tu cuota del {fecha} (orden #{orden}) sigue pendiente y hoy se sumó el cargo por atraso de {cargo_atraso}. El monto a pagar de esa cuota es ahora {monto_cuota}.\n\nPara pagar:\n{cuentas_de_cobro}\n\nSi necesitas ayuda para ponerte al día, escríbenos {por_whatsapp}.'
 where key = 'cargo_por_atraso_d4';

update public.notification_templates
   set default_body = 'Hola, {nombre}. Recibimos y confirmamos tu pago de {monto}. ¡Gracias por confiar en Helios!'
 where key = 'pago_recibido';

update public.notification_templates
   set default_body = E'Hola, {nombre}. No pudimos confirmar el pago que nos enviaste: {motivo}.\n\nRevísalo, por favor, y envíanos de nuevo el comprobante {por_whatsapp}. Si crees que es un error, escríbenos y lo vemos juntos.'
 where key = 'pago_rechazado';

-- Las variables que ofrece el editor del panel.
update public.notification_templates
   set variables = (select array_agg(distinct v order by v)
                      from unnest(variables || array['por_whatsapp','whatsapp_helios','moneda',
                                                     'cuentas_de_cobro_html']) v)
 where key in ('cuota_manana', 'cuota_hoy', 'cuota_vencida_d1', 'cargo_por_atraso_d4');

update public.notification_templates
   set variables = (select array_agg(distinct v order by v)
                      from unnest(variables || array['por_whatsapp','whatsapp_helios']) v)
 where key in ('pago_recibido', 'pago_rechazado', 'cuenta_congelada');

-- ---------------------------------------------------------------------------
-- 3. Los canales y los parámetros de Meta (el nombre, al aprobarse)
-- ---------------------------------------------------------------------------

update public.notification_templates
   set channels = array['whatsapp', 'email'], wa_template_lang = 'es'
 where key in ('cuota_en_3_dias', 'cuota_manana', 'cuota_hoy', 'cuota_vencida_d1',
               'cargo_por_atraso_d4', 'pago_recibido', 'pago_rechazado', 'cuenta_congelada');

update public.notification_templates
   set wa_template_params = array['nombre','fecha','monto_cuota','orden','clinica','moneda','cuentas_de_cobro']
 where key in ('cuota_en_3_dias', 'cuota_manana');
update public.notification_templates
   set wa_template_params = array['nombre','monto_cuota','orden','clinica','moneda','cuentas_de_cobro']
 where key = 'cuota_hoy';
update public.notification_templates
   set wa_template_params = array['nombre','monto_cuota','fecha','orden','moneda','cuentas_de_cobro']
 where key = 'cuota_vencida_d1';
update public.notification_templates
   set wa_template_params = array['nombre','monto']
 where key = 'pago_recibido';
update public.notification_templates
   set wa_template_params = array['nombre','motivo']
 where key = 'pago_rechazado';

-- ---------------------------------------------------------------------------
-- 4. cuenta_congelada, apagada
-- ---------------------------------------------------------------------------

update public.notification_templates
   set enabled = false,
       help = 'Apagado desde el 2026-10-13: repetía a «Cuota vencida: primer día» el mismo día y le llegaba también a quien ya había registrado su pago.'
 where key = 'cuenta_congelada';

-- ---------------------------------------------------------------------------
-- 5. Los correos, con la marca
-- ---------------------------------------------------------------------------

do $correos$
declare
  v_fuente text := $f$font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;$f$;
  v_titulo text := $f$font-family:Outfit,'Segoe UI',Arial,sans-serif;$f$;
  v_layout text;
  v_saludo text;
  v_tarjeta text;
  v_pagar text;
  v_cierre text;
  r record;
begin
  v_layout := $l$<!doctype html>
<html lang="es" xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
<title>[[TITULO]]</title>
<link href="https://fonts.googleapis.com/css2?family=Outfit:wght@500;600&amp;family=Source+Sans+3:wght@400;600;700&amp;display=swap" rel="stylesheet">
<style>
  @media only screen and (max-width: 620px) {
    .h-card { width: 100% !important; border-radius: 0 !important; }
    .h-pad { padding-left: 20px !important; padding-right: 20px !important; }
  }
</style>
</head>
<body style="margin:0;padding:0;background-color:#F4F6FA;">
<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;">[[PREHEADER]]</div>
<table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" bgcolor="#F4F6FA" style="background-color:#F4F6FA;">
<tr><td align="center" style="padding:32px 12px;">

<table role="presentation" class="h-card" width="600" border="0" cellpadding="0" cellspacing="0" bgcolor="#FFFFFF" style="width:600px;max-width:600px;background-color:#FFFFFF;border:1px solid #E3E8F1;border-radius:20px;overflow:hidden;">

<tr><td style="padding:0;font-size:0;line-height:0;">
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0"><tr>
    <td height="5" bgcolor="#045EF3" style="background-color:#045EF3;font-size:0;line-height:0;">&nbsp;</td>
    <td height="5" bgcolor="#157EFD" style="background-color:#157EFD;font-size:0;line-height:0;">&nbsp;</td>
    <td height="5" bgcolor="#1F99FE" style="background-color:#1F99FE;font-size:0;line-height:0;">&nbsp;</td>
    <td height="5" bgcolor="#45A8FD" style="background-color:#45A8FD;font-size:0;line-height:0;">&nbsp;</td>
    <td height="5" bgcolor="#4EADFD" style="background-color:#4EADFD;font-size:0;line-height:0;">&nbsp;</td>
    <td height="5" bgcolor="#73C3FE" style="background-color:#73C3FE;font-size:0;line-height:0;">&nbsp;</td>
  </tr></table>
</td></tr>

<tr><td class="h-pad" style="padding:28px 36px 0 36px;">
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0"><tr>
    <td valign="middle"><a href="https://conhelios.com" target="_blank" style="text-decoration:none;"><img src="https://conhelios.com/correo/logo-helios.png" width="120" height="49" alt="Helios" style="display:block;width:120px;height:auto;border:0;outline:none;text-decoration:none;font-family:Outfit,'Segoe UI',Arial,sans-serif;font-size:28px;font-weight:600;line-height:49px;color:#002770;"></a></td>
    <td valign="middle" align="right" style="font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:12px;line-height:16px;font-weight:600;letter-spacing:1.5px;text-transform:uppercase;color:#6B7690;">[[ETIQUETA]]</td>
  </tr></table>
</td></tr>
[[CUERPO]]
</table>

<table role="presentation" class="h-card" width="600" border="0" cellpadding="0" cellspacing="0" style="width:600px;max-width:600px;">
<tr><td class="h-pad" align="center" style="padding:24px 36px 0 36px;font-family:Outfit,'Segoe UI',Arial,sans-serif;font-size:15px;line-height:20px;font-weight:600;color:#002770;">Helios &middot; Tu salud hoy</td></tr>
<tr><td class="h-pad" align="center" style="padding:6px 36px 0 36px;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:13px;line-height:20px;color:#6B7690;">
  <a href="https://conhelios.com" target="_blank" style="color:#045EF3;text-decoration:none;">conhelios.com</a> &middot; <a href="https://www.instagram.com/helios.salud" target="_blank" style="color:#045EF3;text-decoration:none;">Instagram @helios.salud</a>
</td></tr>
<tr><td class="h-pad" align="center" style="padding:10px 36px 0 36px;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:12px;line-height:18px;color:#6B7690;">Helios es operado por Quarto Latam, C.A.</td></tr>
</table>

</td></tr>
</table>
</body>
</html>
$l$;

  v_saludo := '
<tr><td class="h-pad" style="padding:28px 36px 0 36px;">
  <h1 style="margin:0;' || v_titulo || 'font-size:28px;line-height:34px;font-weight:600;letter-spacing:-0.5px;color:#050F2C;">Hola, {nombre}</h1>
  <p style="margin:10px 0 0 0;' || v_fuente || 'font-size:16px;line-height:24px;color:#46526F;">[[INTRO]]</p>
</td></tr>
';

  -- [[FONDO]] [[BORDE]] [[COLOR]]: azul para recordar, ámbar (los tokens de
  -- aviso) para lo vencido y lo rechazado.
  v_tarjeta := '
<tr><td class="h-pad" style="padding:24px 36px 0 36px;">
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" bgcolor="[[FONDO]]" style="background-color:[[FONDO]];border:1px solid [[BORDE]];border-radius:16px;">
  <tr><td style="padding:20px 22px;">
    <p style="margin:0;' || v_fuente || 'font-size:12px;line-height:16px;font-weight:700;letter-spacing:1.5px;text-transform:uppercase;color:[[COLOR]];">[[ROTULO]]</p>
    [[VALOR]]
    <p style="margin:6px 0 0 0;' || v_fuente || 'font-size:15px;line-height:22px;color:#46526F;">[[PIE]]</p>
  </td></tr>
  </table>
</td></tr>
';

  v_pagar := '
<tr><td class="h-pad" style="padding:28px 36px 0 36px;' || v_titulo || 'font-size:19px;line-height:24px;font-weight:600;color:#050F2C;">C&oacute;mo pagar</td></tr>
<tr><td class="h-pad" style="padding:10px 36px 0 36px;' || v_fuente || 'font-size:15px;line-height:22px;color:#46526F;">
  <p style="margin:0 0 12px 0;">Pagas en <strong style="color:#050F2C;">bol&iacute;vares</strong> (Pago M&oacute;vil o transferencia), a la tasa BCV del {moneda} <strong style="color:#050F2C;">del d&iacute;a en que pagues</strong>.</p>
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" bgcolor="#F4F6FA" style="background-color:#F4F6FA;border-radius:12px;">
  <tr><td style="padding:14px 16px;' || v_fuente || 'font-size:15px;line-height:22px;color:#050F2C;">{cuentas_de_cobro_html}</td></tr>
  </table>
</td></tr>
';

  v_cierre := '
<tr><td class="h-pad" style="padding:18px 36px 36px 36px;' || v_fuente || 'font-size:15px;line-height:22px;color:#46526F;">
  [[CIERRE]]
</td></tr>
';

  for r in
    select * from (values
      ('cuota_en_3_dias', 'Tu cuota vence pronto', 'El {fecha} vence tu cuota de {monto_cuota}.', 'Recordatorio',
       'Te recordamos que el {fecha} vence una cuota de tu pago en cuotas en {clinica}.',
       'azul', 'Vence el {fecha}', '{monto_cuota}', 'Orden #{orden} &middot; {clinica}', true,
       'Cuando pagues, env&iacute;anos el comprobante por WhatsApp: <strong style="color:#050F2C;">{whatsapp_helios}</strong>. &iexcl;Gracias!'),
      ('cuota_hoy', 'Hoy vence tu cuota', 'Hoy vence tu cuota de {monto_cuota}.', 'Recordatorio',
       'Hoy vence una cuota de tu pago en cuotas en {clinica}.',
       'azul', 'Vence hoy, {fecha}', '{monto_cuota}', 'Orden #{orden} &middot; {clinica}', true,
       'Cuando pagues, env&iacute;anos el comprobante por WhatsApp: <strong style="color:#050F2C;">{whatsapp_helios}</strong>. Si ya pagaste, ignora este correo.'),
      ('cuota_vencida_d1', 'Tu cuota est&aacute; vencida', 'Tu cuota de {monto_cuota} del {fecha} sigue pendiente.', 'Cuota vencida',
       'Tu cuota del {fecha} sigue pendiente. Mientras est&eacute; vencida no podr&aacute;s pagar nuevas consultas en cuotas con Helios.{aviso_cargo_atraso}',
       'ambar', 'Venci&oacute; el {fecha}', '{monto_cuota}', 'Orden #{orden} &middot; {clinica}', true,
       'Si tienes alg&uacute;n inconveniente, escr&iacute;benos por WhatsApp al <strong style="color:#050F2C;">{whatsapp_helios}</strong> y lo resolvemos juntos.'),
      ('cargo_por_atraso_d4', 'Se sum&oacute; un cargo por atraso', 'Tu cuota del {fecha} ahora es de {monto_cuota}.', 'Cuota vencida',
       'Tu cuota del {fecha} sigue pendiente y hoy se sum&oacute; el cargo por atraso de {cargo_atraso}.',
       'ambar', 'Monto a pagar de esa cuota', '{monto_cuota}', 'Orden #{orden} &middot; {clinica}', true,
       'Si necesitas ayuda para ponerte al d&iacute;a, escr&iacute;benos por WhatsApp al <strong style="color:#050F2C;">{whatsapp_helios}</strong>.'),
      ('pago_recibido', 'Confirmamos tu pago', 'Recibimos y confirmamos tu pago de {monto}.', 'Pago',
       'Recibimos y confirmamos tu pago. &iexcl;Gracias por confiar en Helios!',
       'azul', 'Pago confirmado', '{monto}', null, false,
       'Si tienes alguna duda, escr&iacute;benos por WhatsApp al <strong style="color:#050F2C;">{whatsapp_helios}</strong>.'),
      ('pago_rechazado', 'No pudimos confirmar tu pago', 'No pudimos confirmar el pago que nos enviaste.', 'Pago',
       'No pudimos confirmar el pago que nos enviaste.',
       'ambar', 'El motivo', null, '{motivo}', false,
       'Rev&iacute;salo, por favor, y env&iacute;anos de nuevo el comprobante por WhatsApp al <strong style="color:#050F2C;">{whatsapp_helios}</strong>. Si crees que es un error, escr&iacute;benos y lo vemos juntos.'),
      ('cuenta_congelada', 'Tu cuenta est&aacute; en pausa', 'Tienes una cuota vencida.', 'Cuenta',
       'Tienes una cuota vencida, as&iacute; que por ahora no puedes pagar nuevas consultas en cuotas con Helios. En cuanto te pongas al d&iacute;a se reactiva sola.',
       null, null, null, null, true,
       'Cuando pagues, env&iacute;anos el comprobante por WhatsApp: <strong style="color:#050F2C;">{whatsapp_helios}</strong>.')
    ) as t(key, titulo, preheader, etiqueta, intro, tono, rotulo, valor, pie, pagar, cierre)
  loop
    update public.notification_templates
       set default_html = replace(replace(replace(replace(v_layout,
             '[[TITULO]]', r.titulo),
             '[[PREHEADER]]', r.preheader),
             '[[ETIQUETA]]', r.etiqueta),
             '[[CUERPO]]',
               replace(v_saludo, '[[INTRO]]', r.intro)
               || case when r.tono is null then '' else
                    replace(replace(replace(replace(replace(replace(v_tarjeta,
                      '[[FONDO]]', case r.tono when 'azul' then '#F8FBFF' else '#FFF0DA' end),
                      '[[BORDE]]', case r.tono when 'azul' then '#DCE8FF' else '#F6D9AE' end),
                      '[[COLOR]]', case r.tono when 'azul' then '#045EF3' else '#5E3000' end),
                      '[[ROTULO]]', r.rotulo),
                      '[[VALOR]]', case when r.valor is null then '' else
                        '<p style="margin:8px 0 0 0;' || v_titulo || 'font-size:30px;line-height:36px;font-weight:600;letter-spacing:-0.5px;color:#050F2C;">' || r.valor || '</p>' end),
                      '[[PIE]]', coalesce(r.pie, ''))
                  end
               || case when r.pagar then v_pagar else '' end
               || replace(v_cierre, '[[CIERRE]]', r.cierre))
     where key = r.key;
  end loop;
end;
$correos$;

-- ---------------------------------------------------------------------------
-- 6. {por_whatsapp}, según el canal
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.helios_enqueue_message(p_template_key text, p_profile_id uuid, p_charge_id uuid, p_channel text, p_vars jsonb DEFAULT '{}'::jsonb, p_due_date date DEFAULT NULL::date, p_dedupe_key text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  v_wa        jsonb;
  v_params    jsonb;
  v_buttons   jsonb;
  v_builtins  jsonb;
begin
  if p_channel is null or p_channel not in ('email', 'whatsapp_manual', 'whatsapp') then
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

  v_builtins := public.helios_message_builtins(p_profile_id);

  v_vars := v_builtins
            -- Dónde mandar el comprobante (20261013000700): en WhatsApp es
            -- este mismo chat; en el correo, el número de Helios.
            || jsonb_build_object('por_whatsapp',
                 case
                   when p_channel <> 'email' then 'por este chat'
                   when exists (select 1 from public.platform_contact c
                                 where c.id and c.whatsapp_number is not null)
                     then 'por WhatsApp al ' || (v_builtins ->> 'whatsapp_helios')
                   else 'por WhatsApp'
                 end)
            || case when p_charge_id is not null
                    then jsonb_build_object('charge_id', p_charge_id::text) else '{}'::jsonb end
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

  if p_channel = 'whatsapp' then
    -- Las variables de Meta no admiten saltos de línea, tabuladores ni más de
    -- cuatro espacios seguidos: se aplanan.
    select coalesce(jsonb_agg(
             regexp_replace(regexp_replace(coalesce(v_vars ->> k, ''), '[\r\n\t]+', ' ', 'g'), ' {2,}', ' ', 'g')
             order by i), '[]'::jsonb)
      into v_params
    from unnest(v_tpl.wa_template_params) with ordinality as u(k, i);

    if exists (select 1 from unnest(v_tpl.wa_template_params) k where not (v_vars ? k)) then
      raise exception 'Faltan variables para la plantilla de WhatsApp %', p_template_key using errcode = '22023';
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
             'id', public.render_notification_text(b ->> 'id', v_vars),
             'title', left(b ->> 'title', 20)) order by i), '[]'::jsonb)
      into v_buttons
    from jsonb_array_elements(v_tpl.wa_buttons) with ordinality as e(b, i);

    if exists (select 1 from jsonb_array_elements(v_buttons) b where b ->> 'id' is null) then
      raise exception 'Faltan variables para los botones de %', p_template_key using errcode = '22023';
    end if;

    v_wa := jsonb_build_object(
      'name', v_tpl.wa_template_name,
      'language', v_tpl.wa_template_lang,
      'params', v_params,
      'buttons', v_buttons
    );
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
    next_attempt_at, dedupe_key, wa_template
  ) values (
    p_channel, p_template_key, p_profile_id, p_charge_id, p_due_date,
    v_recipient, v_subject, v_text, v_html, v_status, v_error,
    case when v_status = 'pendiente' and p_channel in ('email', 'whatsapp') then now() end,
    p_dedupe_key, v_wa
  )
  on conflict (dedupe_key) do nothing
  returning id into v_id;

  if v_id is null then
    -- Otra transacción encoló la misma clave entre la comprobación y el INSERT.
    select id into v_id from public.outbound_messages where dedupe_key = p_dedupe_key;
  end if;

  return v_id;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 7. Los avisos de cuota: el de tres días antes y el WhatsApp automático
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.helios_reminder_offset(p_key text)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_lead integer;
begin
  select lead_days into v_lead from public.notification_templates where key = p_key;

  case p_key
    when 'cuota_en_3_dias'     then return -greatest(coalesce(v_lead, 3), 1);
    when 'cuota_manana'        then return -greatest(coalesce(v_lead, 1), 1);
    when 'cuota_hoy'           then return 0;
    when 'cuota_vencida_d1'    then return greatest(coalesce(v_lead, 1), 1);
    when 'cargo_por_atraso_d4' then return greatest(coalesce(v_lead, 4), 1);
    -- Ronda (apagadas):
    when 'installment_due_d3'  then return -coalesce(v_lead, 3);
    when 'installment_due'     then return -coalesce(v_lead, 2);
    when 'installment_due_tomorrow' then return -coalesce(v_lead, 1);
    when 'installment_due_today', 'installment_due_today_evening' then return 0;
    else null;
  end case;

  if v_lead is null or v_lead < 1 then
    raise exception 'El aviso % no tiene un día de atraso configurado', p_key
      using errcode = '22023';
  end if;

  return v_lead;
end;
$function$;

CREATE OR REPLACE FUNCTION public.helios_enqueue_reminders(p_key text, p_today date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tpl     public.notification_templates%rowtype;
  v_today   date := coalesce(p_today, public.helios_business_date(now()));
  v_offset  integer;
  v_due     date;
  v_row     record;
  v_channel text;
  v_id      uuid;
  v_new     integer := 0;
  v_errors  integer := 0;
  v_before  integer;
begin
  if p_key is null or p_key not in ('cuota_en_3_dias', 'cuota_manana', 'cuota_hoy',
                                    'cuota_vencida_d1', 'cargo_por_atraso_d4') then
    raise exception 'No es un aviso de cuota: %', coalesce(p_key, 'null') using errcode = '22023';
  end if;

  select * into v_tpl from public.notification_templates where key = p_key;
  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = 'P0002';
  end if;

  v_offset := public.helios_reminder_offset(p_key);
  v_due    := v_today - v_offset;

  -- Apagado es apagado: ni siquiera filas `omitido` en la cola del día.
  if not v_tpl.enabled then
    return jsonb_build_object('key', p_key, 'due_date', v_due, 'enqueued', 0, 'skipped', 'apagada');
  end if;

  select count(*) into v_before from public.outbound_messages
  where template_key = p_key and installment_due_date = v_due;

  for v_row in
    with cuotas as (
      select
        i.id, i.user_id, i.charge_id, i.amount_usd,
        c.currency, coalesce(i.amount_cur, i.amount_usd) as amount_cur,
        c.order_number, m.id as merchant_id, m.name as merchant_name,
        coalesce((select sum(f.amount_usd) from public.late_fees f
                   where f.installment_id = i.id and f.status = 'pending'), 0) as fee_usd
      from public.installments i
      join public.charges c   on c.id = i.charge_id
      join public.merchants m on m.id = c.merchant_id
      where i.status = 'pending'
        and i.due_date = v_due
        and c.status = 'confirmed'
        -- Con un pago registrado esperando conciliación no se avisa.
        and not exists (
          select 1
          from public.payment_quote_items qi
          join public.payment_reports r on r.quote_id = qi.quote_id
          where qi.installment_id = i.id
            and r.status in ('reported', 'in_review')
        )
    )
    select
      q.user_id,
      p.email, p.email_invalid_at, p.phone_e164,
      -- Lo que va en dólares (cuotas en dólares y todo cargo por atraso) y lo
      -- que va en euros, por separado: cada uno a la tasa de su moneda.
      sum(case when q.currency = 'EUR' then 0 else q.amount_cur end) + sum(q.fee_usd) as monto_usd,
      sum(case when q.currency = 'EUR' then q.amount_cur else 0 end)                as monto_eur,
      count(distinct q.charge_id)                       as cargos,
      min(q.charge_id::text)::uuid                      as un_cargo,
      string_agg(distinct q.order_number::text, ', #')  as ordenes,
      count(distinct q.merchant_id)                     as clinicas,
      min(q.merchant_name)                              as una_clinica
    from cuotas q
    join public.profiles p on p.id = q.user_id
    -- El aviso del cargo solo sale si el cargo ya se cobró.
    where p_key <> 'cargo_por_atraso_d4' or q.fee_usd > 0
    group by q.user_id, p.email, p.email_invalid_at, p.phone_e164
    order by q.user_id
  loop
    foreach v_channel in array v_tpl.channels loop
      continue when v_channel not in ('whatsapp', 'whatsapp_manual', 'email');
      -- Sin correo válido no se encola el correo (el WhatsApp sí).
      continue when v_channel = 'email' and (v_row.email is null or v_row.email_invalid_at is not null);

      begin
        v_id := public.helios_enqueue_message(
          p_key, v_row.user_id,
          case when v_row.cargos = 1 then v_row.un_cargo end,
          v_channel,
          jsonb_build_object(
            'clinica', case when v_row.clinicas = 1 then v_row.una_clinica
                            else format('%s clínicas', v_row.clinicas) end,
            'orden', v_row.ordenes,
            'monto_cuota', public.helios_amounts_text(v_row.monto_usd, v_row.monto_eur, v_today),
            'fecha', public.helios_weekday_es(v_due) || ' ' || to_char(v_due, 'DD/MM'),
            -- La tasa con la que paga (20261008000300): la de la moneda de sus
            -- cuotas. Un cargo por atraso va en dólares, así que una cuota en
            -- euros con cargo cuenta como las dos.
            'moneda', case
              when v_row.monto_eur = 0 then 'dólar'
              when v_row.monto_usd = 0 then 'euro'
              else 'dólar o del euro, según la moneda de cada cuota,'
            end
          ),
          v_due,
          format('%s:%s:%s:%s', p_key, v_channel, v_row.user_id, v_due)
        );
      exception when others then
        -- Un paciente con un dato raro no puede dejar sin aviso a los demás.
        v_errors := v_errors + 1;
        raise warning 'Aviso % de % no encolado: %', p_key, v_row.user_id, sqlerrm;
      end;
    end loop;
  end loop;

  select count(*) - v_before into v_new from public.outbound_messages
  where template_key = p_key and installment_due_date = v_due;

  return jsonb_build_object('key', p_key, 'due_date', v_due, 'enqueued', v_new, 'errors', v_errors);
end;
$function$;

CREATE OR REPLACE FUNCTION public.helios_cancel_covered_reminders(p_profile_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_n integer;
begin
  update public.outbound_messages o
     set status = 'cancelado',
         last_error = 'Ya pagó o registró el pago de las cuotas de esa fecha',
         next_attempt_at = null
   where o.profile_id = p_profile_id
     and o.status = 'pendiente'
     and o.template_key in ('cuota_en_3_dias', 'cuota_manana', 'cuota_hoy',
                            'cuota_vencida_d1', 'cargo_por_atraso_d4')
     and o.installment_due_date is not null
     and not exists (
       select 1
       from public.installments i
       where i.user_id = p_profile_id
         and i.due_date = o.installment_due_date
         and i.status = 'pending'
         and not exists (
           select 1
           from public.payment_quote_items qi
           join public.payment_reports r on r.quote_id = qi.quote_id
           where qi.installment_id = i.id
             and r.status in ('reported', 'in_review')
         )
     );
  get diagnostics v_n = row_count;
  return v_n;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_notification_schedule(p_key text, p_run_at time without time zone, p_lead_days integer DEFAULT NULL::integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := public.helios_assert_super_admin('cambiar el horario de un aviso');
  v_tpl   public.notification_templates%rowtype;
  v_utc   time;
begin
  select * into v_tpl from public.notification_templates where key = p_key;
  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = '22023';
  end if;

  if v_tpl.cron_job is null
     or p_key not in ('cuota_en_3_dias', 'cuota_manana', 'cuota_hoy',
                      'cuota_vencida_d1', 'cargo_por_atraso_d4') then
    raise exception '"%" no lo dispara el cron: lo dispara un evento, y un evento no tiene hora',
      v_tpl.label using errcode = '22023';
  end if;

  if p_run_at is null then
    raise exception 'Hace falta una hora' using errcode = '22023';
  end if;

  if p_key = 'cuota_hoy' and coalesce(p_lead_days, 0) <> 0 then
    raise exception 'Este aviso sale el mismo día del vencimiento: no lleva días' using errcode = '22023';
  end if;

  if p_key <> 'cuota_hoy' and p_lead_days is not null and p_lead_days not between 1 and 30 then
    raise exception 'Los días van entre 1 y 30' using errcode = '22023';
  end if;

  v_utc := (((current_date + p_run_at) at time zone 'America/Caracas') at time zone 'UTC')::time;

  perform cron.schedule(
    v_tpl.cron_job,
    format('%s %s * * *', extract(minute from v_utc)::integer, extract(hour from v_utc)::integer),
    format('select public.helios_enqueue_reminders(%L);', p_key)
  );

  update public.notification_templates
     set run_at    = p_run_at,
         lead_days = case when p_key = 'cuota_hoy' then 0 else coalesce(p_lead_days, lead_days) end
   where key = p_key;

  perform audit.log(v_actor, 'notification.schedule', null::uuid,
    jsonb_build_object('key', p_key, 'run_at', p_run_at, 'lead_days', p_lead_days));
end;
$function$;

-- ---------------------------------------------------------------------------
-- 8. Los avisos por evento salen por cada canal de su plantilla
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.notify_payment_result()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_quote   public.payment_quotes%rowtype;
  v_ordenes text;
  v_cargo   uuid;
  v_n       integer;
  v_eur_usd numeric(18,4);
  v_key     text;
  v_vars    jsonb;
  v_tpl     public.notification_templates%rowtype;
  v_p       public.profiles%rowtype;
  v_channel text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return null;
  end if;

  if new.status in ('reported', 'in_review', 'reconciled') then
    perform public.helios_cancel_covered_reminders(new.user_id);
  end if;

  if tg_op <> 'UPDATE' or new.status not in ('reconciled', 'rejected') then
    return null;
  end if;

  select * into v_quote from public.payment_quotes where id = new.quote_id;

  select string_agg(distinct c.order_number::text, ', #'),
         count(distinct c.id),
         min(c.id::text)::uuid
    into v_ordenes, v_n, v_cargo
  from public.payment_quote_items qi
  join public.installments i on i.id = qi.installment_id
  join public.charges c on c.id = i.charge_id
  where qi.quote_id = new.quote_id;

  select coalesce(sum(qi.amount_usd), 0) into v_eur_usd
  from public.payment_quote_items qi
  where qi.quote_id = new.quote_id and qi.currency = 'EUR';

  if new.status = 'reconciled' then
    v_key  := 'pago_recibido';
    v_vars := jsonb_build_object(
      'monto', public.helios_amounts_label(v_quote.amount_usd - v_eur_usd, v_quote.amount_eur)
               || coalesce(' (' || public.helios_ves_text(v_quote.amount_ves) || ')', ''),
      'orden', coalesce(v_ordenes, ''));
  else
    v_key  := 'pago_rechazado';
    v_vars := jsonb_build_object(
      'motivo', coalesce(nullif(btrim(new.rejection_note), ''),
                         'no encontramos ese pago en nuestra cuenta'),
      'orden', coalesce(v_ordenes, ''));
  end if;

  select * into v_tpl from public.notification_templates where key = v_key;
  select * into v_p from public.profiles where id = new.user_id;

  foreach v_channel in array coalesce(v_tpl.channels, '{}'::text[]) loop
    continue when v_channel not in ('whatsapp', 'whatsapp_manual', 'email');
    continue when v_channel = 'email' and (v_p.email is null or v_p.email_invalid_at is not null);
    begin
      perform public.helios_enqueue_message(
        v_key, new.user_id, case when v_n = 1 then v_cargo end, v_channel, v_vars, null,
        -- El WhatsApp conserva la clave de siempre.
        case when v_channel = 'email' then v_key || ':email:' || new.id
             else v_key || ':' || new.id end);
    exception when others then
      raise warning 'No se encoló el aviso del pago % (%): %', new.id, v_channel, sqlerrm;
    end;
  end loop;

  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.notify_account_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tpl     public.notification_templates%rowtype;
  v_channel text;
  v_hoy     date := public.helios_business_date(now());
begin
  if new.status is not distinct from old.status then
    return null;
  end if;

  if new.status = 'frozen' and old.status = 'active' then
    select * into v_tpl from public.notification_templates where key = 'cuenta_congelada';
    -- Apagada (20261013000700): ni una fila `omitido`.
    if not found or not v_tpl.enabled then
      return null;
    end if;

    foreach v_channel in array v_tpl.channels loop
      continue when v_channel not in ('whatsapp', 'whatsapp_manual', 'email');
      continue when v_channel = 'email' and (new.email is null or new.email_invalid_at is not null);
      begin
        perform public.helios_enqueue_message(
          'cuenta_congelada', new.id, null, v_channel, '{}'::jsonb, null,
          case when v_channel = 'email' then format('cuenta_congelada:email:%s:%s', new.id, v_hoy)
               else format('cuenta_congelada:%s:%s', new.id, v_hoy) end);
      exception when others then
        raise warning 'No se encoló el aviso de estado de % (%): %', new.id, v_channel, sqlerrm;
      end;
    end loop;
  elsif old.status = 'frozen' then
    update public.outbound_messages
       set status = 'cancelado', last_error = 'La cuenta ya no está congelada', next_attempt_at = null
     where profile_id = new.id
       and template_key = 'cuenta_congelada'
       and status = 'pendiente';
  end if;

  return null;
end;
$function$;
