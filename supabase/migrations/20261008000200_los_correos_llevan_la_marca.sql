-- ============================================================================
-- Helios — Los correos llevan la marca (docs/00 §7.3)
--
-- El comprobante salía con el azul de Ronda (#1A56DB), Arial y «Helios»
-- escrito como texto en una franja azul. Desde aquí los dos correos que salen
-- (`comprobante_financiamiento` y `cuota_manana`, que hasta ahora iba solo en
-- texto) usan la paleta de la portada (panel/src/styles/portada.css):
--
--   tinta #050F2C · tinta-2 #46526F · tinta-3 #6B7690 · marino #002770
--   azul #045EF3 · cielo-3 #E8F3FF · niebla #F4F6FA · línea #E3E8F1
--   la franja de arriba: los seis azules de los rayos del logo
--   aviso: warningContainer #FFF0DA / onWarningContainer #5E3000 (tokens)
--
-- Tipos: Outfit en los títulos y Source Sans 3 en el texto, como la portada.
-- Se piden a Google Fonts (Apple Mail e iOS los cargan); Gmail y Outlook
-- caen a Segoe UI / Arial, que es lo previsto.
--
-- EL LOGO es un PNG (Gmail y Outlook no pintan SVG) servido por la web:
-- `https://conhelios.com/correo/logo-helios.png` (panel/public/correo/,
-- 480 × 194 sobre blanco, se pinta a 120 × 49). Lleva fondo blanco a
-- propósito: con el modo oscuro de Gmail, la palabra azul marino no
-- desaparece sobre un fondo negro. Si el cliente bloquea las imágenes, el
-- `alt` sale como «Helios» en azul marino y en negrita, no como un recuadro
-- roto.
--
-- Se tocan:
--   1. `helios_enqueue_charge_receipt`: las filas de las cuotas y el botón de
--      avisar el pago (lo demás, idéntico a 20261007000400).
--   2. `helios_message_builtins`: la fila del cargo por atraso en el HTML
--      (hoy vacía: el cargo vale 0) y las cuentas de cobro, cada línea en su
--      renglón.
--   3. `default_html` de las dos plantillas. `html` (la versión editada en el
--      superadmin) sigue en null en las dos: nadie la había tocado.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El comprobante: las cuotas y el botón
-- ---------------------------------------------------------------------------

create or replace function public.helios_enqueue_charge_receipt(p_charge_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
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
  v_font     constant text := $f$font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;$f$;
  v_td       constant text := 'padding:14px 0;border-top:1px solid #E3E8F1;';
  v_aviso    text;
  v_aviso_h  text;
  v_noreco   text;
  v_noreco_h text;
  v_iva      numeric;
  v_rate     numeric;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found then
    raise exception 'Orden no encontrada' using errcode = 'P0002';
  end if;

  if v_c.status <> 'confirmed' or v_c.user_id is null then
    raise exception 'La orden no está confirmada' using errcode = '22023';
  end if;

  select * into v_p       from public.profiles  where id = v_c.user_id;
  select * into v_m       from public.merchants where id = v_c.merchant_id;
  select * into v_contact from public.platform_contact where id;
  select name into v_sede from public.merchant_branches where id = v_c.branch_id;

  -- Bolívares de hoy por unidad de la moneda de la orden.
  v_rate := public.helios_fx_rate(v_c.currency);

  -- Solo el nombre de pila de quien registró (docs/00 §7.3).
  v_staff := public.helios_staff_name(v_c.requested_by);
  v_staff := case
    when v_staff is null or position('@' in v_staff) > 0 then 'el personal de la clínica'
    else split_part(btrim(v_staff), ' ', 1)
  end;

  select string_agg(ci.name, ', ' order by ci.position) into v_concepto
  from public.charge_items ci where ci.charge_id = p_charge_id;

  -- Cada cuota en la moneda de la orden y, al lado, sus bolívares de hoy: el
  -- monto es fijo, los bolívares los da la tasa del día en que pague. En el
  -- HTML, dos columnas: «Cuota 1 / vence el…» y el monto con sus bolívares.
  select count(*)::integer,
         string_agg(format('• Cuota %s: %s%s, vence el %s %s', i.sequence,
                           public.helios_money_cur_text(i.amount_cur, v_c.currency),
                           case when v_rate is not null
                                then ' (hoy ' || public.helios_ves_text(round(i.amount_cur * v_rate, 2)) || ')'
                                else '' end,
                           public.helios_weekday_es(i.due_date), to_char(i.due_date, 'DD/MM/YYYY')),
                    E'\n' order by i.sequence),
         string_agg(format(
             '<tr><td style="%s%s">'
             '<span style="font-size:16px;line-height:22px;font-weight:600;color:#050F2C;">Cuota %s</span><br>'
             '<span style="font-size:14px;line-height:20px;color:#46526F;">Vence el %s %s</span></td>'
             '<td align="right" style="%s%s">'
             '<span style="font-size:18px;line-height:24px;font-weight:700;color:#050F2C;">%s</span>%s</td></tr>',
             v_td, v_font, i.sequence,
             public.helios_weekday_es(i.due_date), to_char(i.due_date, 'DD/MM/YYYY'),
             v_td, v_font,
             public.helios_html_escape(public.helios_money_cur_text(i.amount_cur, v_c.currency)),
             case when v_rate is not null
                  then '<br><span style="font-size:13px;line-height:18px;color:#6B7690;">hoy '
                       || public.helios_html_escape(public.helios_ves_text(round(i.amount_cur * v_rate, 2)))
                       || '</span>'
                  else '' end),
           '' order by i.sequence)
    into v_n, v_cuotas, v_cuotas_h
  from public.installments i where i.charge_id = p_charge_id;

  if coalesce(v_n, 0) = 0 then
    raise exception 'La orden no tiene cuotas' using errcode = '22023';
  end if;

  select * into v_first from public.installments
  where charge_id = p_charge_id order by sequence limit 1;

  v_orden := coalesce(v_c.order_number::text, left(v_c.id::text, 8));
  v_wa    := v_contact.whatsapp_number;

  if v_wa is not null then
    v_wa_txt := coalesce(public.helios_format_ve_phone(v_wa), v_wa);
    v_link := 'https://wa.me/' || regexp_replace(v_wa, '\D', '', 'g') || '?text='
              || public.helios_url_encode(format('Hola, quiero avisar un pago de la orden #%s', v_orden));
    v_aviso := format('Cuando pagues, envíanos el comprobante por WhatsApp al %s: %s', v_wa_txt, v_link);
    -- El botón «a prueba de clientes»: la celda lleva el color (Outlook no
    -- pinta el fondo de un <a>) y el enlace, el relleno.
    v_aviso_h := format(
      '<p style="margin:0 0 16px 0;">Cuando pagues, env&iacute;anos el comprobante por WhatsApp al <strong style="color:#050F2C;">%s</strong>, indicando la orden #%s.</p>'
      '<table role="presentation" border="0" cellpadding="0" cellspacing="0"><tr>'
      '<td bgcolor="#045EF3" style="background-color:#045EF3;border-radius:999px;">'
      '<a href="%s" target="_blank" style="display:inline-block;padding:13px 26px;%sfont-size:16px;line-height:20px;font-weight:600;color:#FFFFFF;text-decoration:none;border-radius:999px;">Avisar mi pago por WhatsApp</a>'
      '</td></tr></table>',
      public.helios_html_escape(v_wa_txt), public.helios_html_escape(v_orden),
      public.helios_html_escape(v_link), v_font);
    v_noreco := format('Si no reconoces este pago en cuotas, escríbenos enseguida por WhatsApp al %s%s.',
                       v_wa_txt, coalesce(' o a ' || v_contact.support_email, ''));
  else
    v_link := '';
    v_aviso := 'Helios te escribirá por WhatsApp con las instrucciones para avisar tu pago.';
    v_aviso_h := '<p style="margin:0;">Helios te escribir&aacute; por WhatsApp con las instrucciones para avisar tu pago.</p>';
    v_noreco := case
      when v_contact.support_email is not null then
        format('Si no reconoces este pago en cuotas, escríbenos enseguida a %s.', v_contact.support_email)
      else 'Si no reconoces este pago en cuotas, escríbenos enseguida respondiendo a este correo.'
    end;
  end if;
  v_noreco_h := '<strong>' || public.helios_html_escape(v_noreco) || '</strong>';

  -- El IVA de la comisión, como porcentaje de la comisión (el que se cobró de
  -- verdad), igual que en la pregunta al paciente.
  v_iva := case when coalesce(v_c.consumer_fee_usd, 0) > 0
                then round(v_c.consumer_fee_vat_usd * 100 / v_c.consumer_fee_usd, 2)
                else public.helios_parameter('vat_pct', 16) end;

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
      'moneda', public.helios_currency_name(v_c.currency),
      'monto_consulta', public.helios_money_cur_text(coalesce(v_c.base_cur, v_c.amount_cur), v_c.currency),
      'servicio_helios', public.helios_money_cur_text(coalesce(v_c.consumer_fee_cur, 0)
                                                      + coalesce(v_c.consumer_fee_vat_cur, 0), v_c.currency),
      'servicio_helios_pct', rtrim(to_char(coalesce(v_c.consumer_fee_pct, 0), 'FM990.##'), '.'),
      -- Al paciente sí se le enseña la comisión, su IVA y el total (Javier,
      -- 2026-10-06): es lo que paga.
      'comision_servicio', public.helios_money_cur_text(coalesce(v_c.consumer_fee_cur, 0), v_c.currency),
      'iva_pct', public.helios_pct_text(v_iva),
      'iva_comision', public.helios_money_cur_text(coalesce(v_c.consumer_fee_vat_cur, 0), v_c.currency),
      'total', public.helios_money_cur_text(v_c.amount_cur, v_c.currency),
      'total_bs', case when v_rate is null then 'el equivalente en bolívares'
                       else public.helios_ves_text(round(v_c.amount_cur * v_rate, 2)) end,
      'n_cuotas', v_n::text,
      'cuotas', v_cuotas,
      'cuotas_html', v_cuotas_h,
      'monto_cuota', public.helios_money_cur_text(v_first.amount_cur, v_c.currency),
      'fecha', to_char(v_first.due_date, 'DD/MM/YYYY'),
      'whatsapp_link', v_link,
      'aviso_pago', v_aviso,
      'aviso_pago_html', v_aviso_h,
      'no_reconoces', v_noreco,
      'no_reconoces_html', v_noreco_h
    ),
    null, null);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 2. Las variables de siempre: la fila del cargo y las cuentas
-- ---------------------------------------------------------------------------

create or replace function public.helios_message_builtins(p_profile_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path = public, pg_temp
as $function$
declare
  v_p       public.profiles%rowtype;
  v_c       public.platform_contact%rowtype;
  v_wa      text;
  v_cuentas text := public.helios_payment_accounts_text();
  v_tasa    numeric := public.current_fx_rate('BCV');
  v_tasa_e  numeric := public.current_fx_rate('BCV_EUR');
  v_cargo   numeric := public.helios_late_fee_usd();
  v_gracia  integer := public.helios_late_fee_grace_days();
  v_cargo_t text    := public.helios_money_cur_text(v_cargo, 'USD');
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
    'tasa_bcv_euro', case when v_tasa_e is null then 'del día'
                          else trim(to_char(v_tasa_e, 'FM999999990.00')) end,
    -- La de la orden la pisa (20261007000600).
    'moneda', 'dólar',
    -- Con su símbolo: el cargo por atraso es en dólares.
    'cargo_atraso', v_cargo_t,
    'dias_gracia', v_gracia::text,
    'dias_suspension', public.helios_mora_demotion_days()::text,
    'dias_expulsion', public.helios_mora_expulsion_days()::text,
    -- La regla del cargo, solo si hay cargo (20261007000800). Con el cargo en
    -- 0, vacías: nadie promete un cargo que no se cobra. La fila del HTML
    -- tiene la forma de las otras condiciones del comprobante (20261008000200).
    'condicion_cargo_atraso', case when v_cargo > 0 then
      format(E'• Después de %s días de gracia se suma un cargo de %s por cada cuota vencida.\n',
             v_gracia, v_cargo_t) else '' end,
    'condicion_cargo_atraso_html', case when v_cargo > 0 then
      format($h$<tr><td valign="top" width="20" style="padding:0 0 10px 0;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#045EF3;">&#9679;</td><td style="padding:0 0 10px 0;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#46526F;">Despu&eacute;s de %s d&iacute;as de gracia se suma un cargo de %s por cada cuota vencida.</td></tr>$h$,
             v_gracia, public.helios_html_escape(v_cargo_t)) else '' end,
    'aviso_cargo_atraso', case when v_cargo > 0 then
      format(' Si la pagas antes de cumplir %s días de atraso, evitas el cargo de %s.', v_gracia, v_cargo_t)
      else '' end
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 3a. La plantilla del comprobante
-- ---------------------------------------------------------------------------

update public.notification_templates
   set default_html = $html$<!doctype html>
<html lang="es" xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
<title>Tu pago en cuotas con Helios</title>
<link href="https://fonts.googleapis.com/css2?family=Outfit:wght@500;600&amp;family=Source+Sans+3:wght@400;600;700&amp;display=swap" rel="stylesheet">
<style>
  @media only screen and (max-width: 620px) {
    .h-card { width: 100% !important; border-radius: 0 !important; }
    .h-pad { padding-left: 20px !important; padding-right: 20px !important; }
    .h-h1 { font-size: 24px !important; line-height: 30px !important; }
  }
</style>
</head>
<body style="margin:0;padding:0;background-color:#F4F6FA;">
<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;">Orden #{orden} en {clinica}: {n_cuotas} cuotas de {monto_cuota}.</div>
<table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" bgcolor="#F4F6FA" style="background-color:#F4F6FA;">
<tr><td align="center" style="padding:32px 12px;">

<table role="presentation" class="h-card" width="600" border="0" cellpadding="0" cellspacing="0" bgcolor="#FFFFFF" style="width:600px;max-width:600px;background-color:#FFFFFF;border:1px solid #E3E8F1;border-radius:20px;overflow:hidden;">

<!-- La franja: los seis azules de los rayos del logo -->
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

<!-- El logo y qué es -->
<tr><td class="h-pad" style="padding:28px 36px 0 36px;">
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0"><tr>
    <td valign="middle"><a href="https://conhelios.com" target="_blank" style="text-decoration:none;"><img src="https://conhelios.com/correo/logo-helios.png" width="120" height="49" alt="Helios" style="display:block;width:120px;height:auto;border:0;outline:none;text-decoration:none;font-family:Outfit,'Segoe UI',Arial,sans-serif;font-size:28px;font-weight:600;line-height:49px;color:#002770;"></a></td>
    <td valign="middle" align="right" style="font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:12px;line-height:16px;font-weight:600;letter-spacing:1.5px;text-transform:uppercase;color:#6B7690;">Comprobante</td>
  </tr></table>
</td></tr>

<!-- El saludo -->
<tr><td class="h-pad" style="padding:28px 36px 0 36px;">
  <h1 class="h-h1" style="margin:0;font-family:Outfit,'Segoe UI',Arial,sans-serif;font-size:28px;line-height:34px;font-weight:600;letter-spacing:-0.5px;color:#050F2C;">Hola, {nombre}</h1>
  <p style="margin:10px 0 0 0;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:16px;line-height:24px;color:#46526F;">Este es el comprobante de tu pago en cuotas con Helios. Gu&aacute;rdalo: aqu&iacute; est&aacute;n tus cuotas y c&oacute;mo pagarlas.</p>
  <table role="presentation" border="0" cellpadding="0" cellspacing="0" style="margin-top:16px;"><tr>
    <td bgcolor="#E8F3FF" style="background-color:#E8F3FF;border-radius:999px;padding:6px 14px;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:14px;line-height:18px;font-weight:700;color:#045EF3;">Orden #{orden}</td>
    <td style="padding-left:12px;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:14px;line-height:18px;color:#6B7690;">{fecha_hora} &middot; hora de Caracas</td>
  </tr></table>
</td></tr>

<!-- El plan de pagos -->
<tr><td class="h-pad" style="padding:28px 36px 0 36px;">
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" bgcolor="#F8FBFF" style="background-color:#F8FBFF;border:1px solid #DCE8FF;border-radius:16px;">
  <tr><td style="padding:20px 22px 6px 22px;">
    <p style="margin:0;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:12px;line-height:16px;font-weight:700;letter-spacing:1.5px;text-transform:uppercase;color:#045EF3;">Tu plan de pagos &middot; sin inicial</p>
    <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" style="margin-top:8px;">
    {cuotas_html}
    </table>
  </td></tr>
  <tr><td style="padding:0 22px 18px 22px;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:14px;line-height:20px;color:#6B7690;">Las cuotas ya incluyen la comisi&oacute;n de servicio y su IVA.</td></tr>
  </table>
</td></tr>

<!-- El detalle -->
<tr><td class="h-pad" style="padding:32px 36px 0 36px;font-family:Outfit,'Segoe UI',Arial,sans-serif;font-size:19px;line-height:24px;font-weight:600;color:#050F2C;">El detalle</td></tr>
<tr><td class="h-pad" style="padding:6px 36px 0 36px;">
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" style="font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:21px;">
  <tr>
    <td width="44%" valign="top" style="padding:11px 12px 11px 0;border-bottom:1px solid #E3E8F1;color:#6B7690;">Cl&iacute;nica</td>
    <td valign="top" style="padding:11px 0;border-bottom:1px solid #E3E8F1;color:#050F2C;">{clinica} {clinica_rif}</td>
  </tr>
  <tr>
    <td valign="top" style="padding:11px 12px 11px 0;border-bottom:1px solid #E3E8F1;color:#6B7690;">Sede</td>
    <td valign="top" style="padding:11px 0;border-bottom:1px solid #E3E8F1;color:#050F2C;">{sede}</td>
  </tr>
  <tr>
    <td valign="top" style="padding:11px 12px 11px 0;border-bottom:1px solid #E3E8F1;color:#6B7690;">Registr&oacute;</td>
    <td valign="top" style="padding:11px 0;border-bottom:1px solid #E3E8F1;color:#050F2C;">{registrado_por}</td>
  </tr>
  <tr>
    <td valign="top" style="padding:11px 12px 11px 0;border-bottom:1px solid #E3E8F1;color:#6B7690;">Titular</td>
    <td valign="top" style="padding:11px 0;border-bottom:1px solid #E3E8F1;color:#050F2C;">{nombre_completo} &middot; C.I. {documento}</td>
  </tr>
  <tr>
    <td valign="top" style="padding:11px 12px 11px 0;border-bottom:1px solid #E3E8F1;color:#6B7690;">Servicios</td>
    <td valign="top" style="padding:11px 0;border-bottom:1px solid #E3E8F1;color:#050F2C;">{concepto}</td>
  </tr>
  <tr>
    <td valign="top" style="padding:11px 12px 11px 0;border-bottom:1px solid #E3E8F1;color:#6B7690;">Monto de la consulta</td>
    <td valign="top" style="padding:11px 0;border-bottom:1px solid #E3E8F1;color:#050F2C;font-weight:700;">{monto_consulta}</td>
  </tr>
  <tr>
    <td valign="top" style="padding:11px 12px 11px 0;border-bottom:1px solid #E3E8F1;color:#6B7690;">Comisi&oacute;n de servicio ({servicio_helios_pct}%)</td>
    <td valign="top" style="padding:11px 0;border-bottom:1px solid #E3E8F1;color:#050F2C;">{comision_servicio}</td>
  </tr>
  <tr>
    <td valign="top" style="padding:11px 12px 11px 0;border-bottom:1px solid #E3E8F1;color:#6B7690;">IVA de la comisi&oacute;n ({iva_pct}%)</td>
    <td valign="top" style="padding:11px 0;border-bottom:1px solid #E3E8F1;color:#050F2C;">{iva_comision}</td>
  </tr>
  <tr>
    <td valign="top" style="padding:13px 12px 0 0;color:#050F2C;font-weight:700;">Total a pagar</td>
    <td valign="top" style="padding:13px 0 0 0;color:#050F2C;"><span style="font-family:Outfit,'Segoe UI',Arial,sans-serif;font-size:20px;line-height:26px;font-weight:600;">{total}</span><br><span style="font-size:14px;line-height:20px;color:#6B7690;">{total_bs} a la tasa BCV de hoy</span></td>
  </tr>
  </table>
</td></tr>

<!-- Cómo pagar -->
<tr><td class="h-pad" style="padding:32px 36px 0 36px;font-family:Outfit,'Segoe UI',Arial,sans-serif;font-size:19px;line-height:24px;font-weight:600;color:#050F2C;">C&oacute;mo pagar</td></tr>
<tr><td class="h-pad" style="padding:10px 36px 0 36px;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#46526F;">
  <p style="margin:0 0 12px 0;">Pagas en <strong style="color:#050F2C;">bol&iacute;vares</strong> (Pago M&oacute;vil o transferencia), a la tasa BCV del {moneda} <strong style="color:#050F2C;">del d&iacute;a en que pagues</strong>.</p>
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" bgcolor="#F4F6FA" style="background-color:#F4F6FA;border-radius:12px;">
  <tr><td style="padding:14px 16px;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#050F2C;">{cuentas_de_cobro_html}</td></tr>
  </table>
</td></tr>
<tr><td class="h-pad" style="padding:18px 36px 0 36px;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#46526F;">
  {aviso_pago_html}
</td></tr>

<!-- Condiciones -->
<tr><td class="h-pad" style="padding:32px 36px 0 36px;font-family:Outfit,'Segoe UI',Arial,sans-serif;font-size:19px;line-height:24px;font-weight:600;color:#050F2C;">Condiciones</td></tr>
<tr><td class="h-pad" style="padding:12px 36px 0 36px;">
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0">
  <tr><td valign="top" width="20" style="padding:0 0 10px 0;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#045EF3;">&#9679;</td><td style="padding:0 0 10px 0;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#46526F;">Desde el d&iacute;a siguiente al vencimiento de una cuota sin pagar, tu cuenta queda en pausa: no podr&aacute;s registrar otro pago en cuotas hasta ponerte al d&iacute;a.</td></tr>
  {condicion_cargo_atraso_html}<tr><td valign="top" width="20" style="padding:0 0 10px 0;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#045EF3;">&#9679;</td><td style="padding:0 0 10px 0;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#46526F;">A los {dias_suspension} d&iacute;as de atraso la cuenta se suspende.</td></tr>
  <tr><td valign="top" width="20" style="padding:0 0 10px 0;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#045EF3;">&#9679;</td><td style="padding:0 0 10px 0;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#46526F;">A los {dias_expulsion} d&iacute;as de atraso la cuenta se cierra, tu c&eacute;dula ya no podr&aacute; usar Helios y la deuda pasa a cobranza.</td></tr>
  </table>
</td></tr>

<!-- ¿No lo reconoces? -->
<tr><td class="h-pad" style="padding:20px 36px 36px 36px;">
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" bgcolor="#FFF0DA" style="background-color:#FFF0DA;border-radius:12px;">
  <tr><td style="padding:14px 16px;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#5E3000;">{no_reconoces_html}</td></tr>
  </table>
</td></tr>

</table>

<!-- El pie -->
<table role="presentation" class="h-card" width="600" border="0" cellpadding="0" cellspacing="0" style="width:600px;max-width:600px;">
<tr><td class="h-pad" align="center" style="padding:24px 36px 0 36px;font-family:Outfit,'Segoe UI',Arial,sans-serif;font-size:15px;line-height:20px;font-weight:600;color:#002770;">Helios &middot; Tu salud hoy</td></tr>
<tr><td class="h-pad" align="center" style="padding:6px 36px 0 36px;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:13px;line-height:20px;color:#6B7690;">
  <a href="https://conhelios.com" target="_blank" style="color:#045EF3;text-decoration:none;">conhelios.com</a> &middot; <a href="https://www.instagram.com/helios.salud" target="_blank" style="color:#045EF3;text-decoration:none;">Instagram @helios.salud</a>
</td></tr>
<tr><td class="h-pad" align="center" style="padding:10px 36px 0 36px;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:12px;line-height:18px;color:#6B7690;">Este comprobante no es una factura fiscal. Helios es operado por Quarto Latam, C.A.</td></tr>
</table>

</td></tr>
</table>
</body>
</html>$html$
 where key = 'comprobante_financiamiento';

-- ---------------------------------------------------------------------------
-- 3b. El recordatorio de la víspera, ahora también en HTML
-- ---------------------------------------------------------------------------
-- Sus variables son las del aviso (`helios_enqueue_reminders`: clinica,
-- orden, monto_cuota, fecha) más las de siempre. Sin botón de WhatsApp: si
-- Helios no tiene número, `whatsapp_link` viene vacío y el botón quedaría
-- roto; el número va escrito en `{whatsapp_helios}`.

update public.notification_templates
   set default_html = $html$<!doctype html>
<html lang="es" xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
<title>Ma&ntilde;ana vence tu cuota</title>
<link href="https://fonts.googleapis.com/css2?family=Outfit:wght@500;600&amp;family=Source+Sans+3:wght@400;600;700&amp;display=swap" rel="stylesheet">
<style>
  @media only screen and (max-width: 620px) {
    .h-card { width: 100% !important; border-radius: 0 !important; }
    .h-pad { padding-left: 20px !important; padding-right: 20px !important; }
  }
</style>
</head>
<body style="margin:0;padding:0;background-color:#F4F6FA;">
<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;">Ma&ntilde;ana, {fecha}, vence tu cuota de {monto_cuota}.</div>
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
    <td valign="middle" align="right" style="font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:12px;line-height:16px;font-weight:600;letter-spacing:1.5px;text-transform:uppercase;color:#6B7690;">Recordatorio</td>
  </tr></table>
</td></tr>

<tr><td class="h-pad" style="padding:28px 36px 0 36px;">
  <h1 style="margin:0;font-family:Outfit,'Segoe UI',Arial,sans-serif;font-size:28px;line-height:34px;font-weight:600;letter-spacing:-0.5px;color:#050F2C;">Hola, {nombre}</h1>
  <p style="margin:10px 0 0 0;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:16px;line-height:24px;color:#46526F;">Te recordamos que ma&ntilde;ana vence una cuota de tu pago en cuotas en {clinica}.</p>
</td></tr>

<tr><td class="h-pad" style="padding:24px 36px 0 36px;">
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" bgcolor="#F8FBFF" style="background-color:#F8FBFF;border:1px solid #DCE8FF;border-radius:16px;">
  <tr><td style="padding:20px 22px;">
    <p style="margin:0;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:12px;line-height:16px;font-weight:700;letter-spacing:1.5px;text-transform:uppercase;color:#045EF3;">Vence ma&ntilde;ana, {fecha}</p>
    <p style="margin:8px 0 0 0;font-family:Outfit,'Segoe UI',Arial,sans-serif;font-size:30px;line-height:36px;font-weight:600;letter-spacing:-0.5px;color:#050F2C;">{monto_cuota}</p>
    <p style="margin:6px 0 0 0;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:14px;line-height:20px;color:#6B7690;">Orden #{orden} &middot; {clinica}</p>
  </td></tr>
  </table>
</td></tr>

<tr><td class="h-pad" style="padding:28px 36px 0 36px;font-family:Outfit,'Segoe UI',Arial,sans-serif;font-size:19px;line-height:24px;font-weight:600;color:#050F2C;">C&oacute;mo pagar</td></tr>
<tr><td class="h-pad" style="padding:10px 36px 0 36px;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#46526F;">
  <p style="margin:0 0 12px 0;">Pagas en <strong style="color:#050F2C;">bol&iacute;vares</strong> (Pago M&oacute;vil o transferencia), a la tasa BCV <strong style="color:#050F2C;">del d&iacute;a en que pagues</strong>.</p>
  <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" bgcolor="#F4F6FA" style="background-color:#F4F6FA;border-radius:12px;">
  <tr><td style="padding:14px 16px;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#050F2C;">{cuentas_de_cobro_html}</td></tr>
  </table>
</td></tr>
<tr><td class="h-pad" style="padding:18px 36px 36px 36px;font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:#46526F;">
  Cuando pagues, env&iacute;anos el comprobante por WhatsApp: <strong style="color:#050F2C;">{whatsapp_helios}</strong>. &iexcl;Gracias!
</td></tr>

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
</html>$html$,
       variables = (select array_agg(distinct v order by v)
                      from unnest(variables || array['cuentas_de_cobro_html']) v)
 where key = 'cuota_manana';

-- ---------------------------------------------------------------------------
-- 4. Comprobaciones
-- ---------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from public.notification_templates
              where key in ('comprobante_financiamiento', 'cuota_manana')
                and (default_html is null
                     or default_html ~* '#1A56DB'
                     or default_html not like '%https://conhelios.com/correo/logo-helios.png%'
                     or default_html not like '%alt="Helios"%')) then
    raise exception 'Las plantillas de correo no quedaron con la marca y el logo';
  end if;

  if (select prosrc from pg_proc where oid = 'public.helios_enqueue_charge_receipt(uuid)'::regprocedure) ~* '#1A56DB'
     or (select prosrc from pg_proc where oid = 'public.helios_message_builtins(uuid)'::regprocedure) ~* '#1A56DB' then
    raise exception 'Queda el azul de Ronda en el HTML de los correos';
  end if;
end
$$;
