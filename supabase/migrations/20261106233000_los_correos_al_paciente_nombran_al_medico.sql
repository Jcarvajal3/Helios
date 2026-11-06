-- ============================================================================
-- Helios — Los correos al paciente nombran a su médico (2026-11-06)
--
-- La regla es del 2026-10-19 (docs/00 §15.8): al paciente se le nombra a su
-- médico, no a la clínica. Los WhatsApp ya la cumplían; los correos no, y como
-- `merchants.name` es desde el 2026-10-29 el nombre del médico, decían «Tu pago
-- en cuotas en Dr. Leonardo Veliz» y «vence una cuota de tu pago en cuotas en
-- Dra. Cecil Palmero». Textos aprobados por Javier el 2026-11-06.
--
-- · Los recordatorios usan {tu_cuota}, como su WhatsApp: «Te recordamos que
--   mañana vence tu cuota de €34,17 de la consulta con la Dra. Cecil Palmero».
--   De paso, con varias cuotas el mismo día ya no dicen «una cuota».
-- · La línea bajo el monto: «Orden #123 · Consulta con la Dra. Cecil Palmero».
-- · El comprobante: asunto «Tu pago en cuotas con la Dra. …» y la fila «Médico»
--   con el RIF, en lugar de «Clínica». La sede se queda (docs/00 §7.3).
-- · El título de `confirmar_financiamiento` no lo lee nadie (sale solo por
--   WhatsApp), pero se alinea para que no vuelva {clinica} por copia.
--
-- `helios_enqueue_reminders`, `helios_enqueue_confirmation` y
-- `helios_finalize_charge` siguen pasando `clinica`: sin efecto, ningún texto la
-- usa y ya no se ofrece en `variables`. No se redefinen por eso.
-- ============================================================================

-- --- Los recordatorios: la frase ----------------------------------------------
update public.notification_templates
   set default_html = replace(default_html,
         'Te recordamos que el {fecha} vence una cuota de tu pago en cuotas en {clinica}.',
         'Te recordamos que {tu_cuota} {vence} el {fecha}.')
 where key = 'cuota_en_3_dias';

update public.notification_templates
   set default_html = replace(default_html,
         'Te recordamos que ma&ntilde;ana vence una cuota de tu pago en cuotas en {clinica}.',
         'Te recordamos que ma&ntilde;ana {vence} {tu_cuota}.')
 where key = 'cuota_manana';

update public.notification_templates
   set default_html = replace(default_html,
         'Hoy vence una cuota de tu pago en cuotas en {clinica}.',
         'Hoy {vence} {tu_cuota}.')
 where key = 'cuota_hoy';

-- --- Los recordatorios: la línea bajo el monto ---------------------------------
update public.notification_templates
   set default_html = replace(default_html,
         'Orden #{orden} &middot; {clinica}',
         'Orden #{orden} &middot; Consulta con {medico}')
 where key in ('cuota_en_3_dias', 'cuota_manana', 'cuota_hoy', 'cuota_vencida_d1', 'cargo_por_atraso_d4');

-- --- El comprobante ------------------------------------------------------------
update public.notification_templates
   set default_title = replace(default_title, 'Tu pago en cuotas en {clinica}', 'Tu pago en cuotas con {medico}'),
       default_body  = replace(default_body, 'Clínica: {clinica} {clinica_rif}', 'Médico: {medico_nombre} {clinica_rif}'),
       default_html  = replace(replace(replace(default_html,
         'Orden #{orden} en {clinica}:', 'Orden #{orden} con {medico}:'),
         'Cl&iacute;nica</td>', 'M&eacute;dico</td>'),
         '{clinica} {clinica_rif}', '{medico_nombre} {clinica_rif}')
 where key = 'comprobante_financiamiento';

-- --- La pregunta al paciente: solo su título ------------------------------------
update public.notification_templates
   set default_title = replace(default_title, 'Confirma tu pago en cuotas en {clinica}', 'Confirma tu pago en cuotas con {medico}')
 where key = 'confirmar_financiamiento';

-- --- Lo que el editor ofrece ----------------------------------------------------
update public.notification_templates t
   set variables = (select array_agg(distinct v order by v)
                    from unnest(array_remove(t.variables, 'clinica')
                                || array['medico']
                                || case when t.key = 'comprobante_financiamiento'
                                        then array['medico_nombre'] else array[]::text[] end) as v)
 where key in ('cuota_en_3_dias', 'cuota_manana', 'cuota_hoy', 'cuota_vencida_d1', 'cargo_por_atraso_d4',
               'comprobante_financiamiento', 'confirmar_financiamiento');

-- --- El comprobante recibe al médico --------------------------------------------
create or replace function public.helios_enqueue_charge_receipt(p_charge_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
      -- Al paciente se le nombra a su médico (20261106233000): «la Dra. Ana
      -- Lara» en las frases, «Dra. Ana Lara» en la fila del detalle.
      'medico', public.helios_doctor_ref(v_m.id),
      'medico_nombre', public.helios_doctor_name(v_m.id),
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

-- --- Comprobación: si un texto cambió antes, que falle y no quede a medias --------
do $$
declare
  v_mal text;
begin
  select string_agg(key, ', ') into v_mal
  from public.notification_templates
  where key in ('cuota_en_3_dias', 'cuota_manana', 'cuota_hoy', 'cuota_vencida_d1', 'cargo_por_atraso_d4',
                'comprobante_financiamiento', 'confirmar_financiamiento')
    and concat_ws(' ', default_title, default_body, default_html, title, body, html,
                  draft_title, draft_body) like '%{clinica}%';
  if v_mal is not null then
    raise exception 'Estas plantillas siguen usando {clinica}: %', v_mal;
  end if;

  if not exists (select 1 from public.notification_templates
                 where key = 'comprobante_financiamiento'
                   and default_html like '%M&eacute;dico</td>%'
                   and default_body like '%Médico: {medico_nombre} {clinica_rif}%') then
    raise exception 'El comprobante no quedó con la fila del médico';
  end if;
end;
$$;
