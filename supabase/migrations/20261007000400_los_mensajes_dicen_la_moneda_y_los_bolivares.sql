-- ============================================================================
-- Helios — Los mensajes al paciente dicen la moneda y los bolívares
-- (Javier, 2026-10-07)
--
-- Una orden puede ir en dólares o en euros
-- (`20261007000200_la_consulta_se_cobra_en_dolares_o_euros`) y el paciente
-- paga en bolívares a la tasa BCV de esa moneda. Decisión de Javier: el
-- paciente ve **la moneda y los bolívares**: «€56,96 (Bs 56.063,47)». El
-- monto en la moneda es fijo; los bolívares son los de la tasa de hoy.
--
-- 1. **Las variables de dinero traen su símbolo.** Hasta hoy las plantillas
--    escribían «${monto_cuota}» y la variable era «56,96». Con dos monedas el
--    símbolo es de la variable: `monto_cuota` = «€56,96 (Bs 56.063,47)»,
--    `total` = «€113,92», `cargo_atraso` = «$2». En las plantillas de Helios
--    (las tres capas: fábrica, publicada y borrador, texto y HTML) se quita
--    el «$» de delante de esas variables. Las plantillas de la app de Ronda
--    (canal `app`, apagadas) no se tocan.
--
-- 2. **Variables nuevas**: `total_bs` («Bs 112.126,94», el total a la tasa de
--    hoy) y `moneda` («dólar» | «euro», para «la tasa BCV del euro»).
--
-- 3. **Los textos**: el total lleva sus bolívares; «a la tasa BCV del dólar»
--    pasa a «del {moneda}»; la bienvenida ya no ofrece pagar «en efectivo en
--    divisas» (solo bolívares: Pago Móvil o transferencia).
--
-- 4. **Quien arma cada mensaje** (`helios_enqueue_confirmation`,
--    `helios_enqueue_charge_receipt`, `helios_finalize_charge`,
--    `helios_enqueue_reminders`, `notify_payment_result`,
--    `helios_notify_staff_of_charge`, `helios_message_builtins`) usa la moneda
--    de la orden. Un aviso que junta cuotas de órdenes en monedas distintas
--    dice las dos: «€56,96 + $30 (Bs 85.276,49)».
--
-- 5. **Los bots**: `bot_paciente_resumen` da cada orden en su moneda y las dos
--    tasas; `bot_patient_eligibility` añade la tasa cruzada para que el bot
--    del médico diga lo disponible en euros.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Montos para el paciente
-- ---------------------------------------------------------------------------

/** «€56,96», «$30», «€56,96 + $2»: lo que va en cada moneda, sin bolívares. */
create or replace function public.helios_amounts_label(p_usd numeric, p_eur numeric)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select concat_ws(' + ',
    case when coalesce(p_eur, 0) > 0 then public.helios_money_cur_text(p_eur, 'EUR') end,
    case when coalesce(p_usd, 0) > 0 or coalesce(p_eur, 0) <= 0
         then public.helios_money_cur_text(coalesce(p_usd, 0), 'USD') end);
$$;

/**
 * «€56,96 (Bs 56.063,47)»: lo de cada moneda y, entre paréntesis, los
 * bolívares de ese día (cada parte a la tasa BCV de su moneda). Sin la tasa
 * que hace falta, sin paréntesis.
 */
create or replace function public.helios_amounts_text(p_usd numeric, p_eur numeric, p_as_of date default null)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_ves numeric;
begin
  begin
    v_ves := (public.helios_bolivares(coalesce(p_usd, 0), coalesce(p_eur, 0), p_as_of)->>'amount_ves')::numeric;
  exception when sqlstate 'P0002' then
    v_ves := null;
  end;

  return public.helios_amounts_label(p_usd, p_eur)
         || coalesce(' (' || public.helios_ves_text(v_ves) || ')', '');
end;
$$;

/** Un monto en la moneda de una orden, con sus bolívares de hoy. */
create or replace function public.helios_money_with_ves(p_amount numeric, p_currency text, p_as_of date default null)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.helios_amounts_text(
    case when p_currency = 'EUR' then 0 else p_amount end,
    case when p_currency = 'EUR' then p_amount else 0 end,
    p_as_of);
$$;

/** «dólar» | «euro»: para «a la tasa BCV del euro». */
create or replace function public.helios_currency_name(p_currency text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case upper(coalesce(p_currency, 'USD')) when 'EUR' then 'euro' else 'dólar' end;
$$;

revoke all on function public.helios_amounts_label(numeric, numeric) from public, anon, authenticated;
revoke all on function public.helios_amounts_text(numeric, numeric, date) from public, anon, authenticated;
revoke all on function public.helios_money_with_ves(numeric, text, date) from public, anon, authenticated;
revoke all on function public.helios_currency_name(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Las plantillas
-- ---------------------------------------------------------------------------

-- 2a. Fuera el «$» de delante de las variables de dinero.
update public.notification_templates
set default_title = regexp_replace(default_title, '\$\{(monto|monto_cuota|monto_consulta|cargo_servicio|iva_cargo_servicio|total|comision_servicio|iva_comision|servicio_helios|cargo_atraso|cargo)\}', '{\1}', 'g'),
    default_body  = regexp_replace(default_body,  '\$\{(monto|monto_cuota|monto_consulta|cargo_servicio|iva_cargo_servicio|total|comision_servicio|iva_comision|servicio_helios|cargo_atraso|cargo)\}', '{\1}', 'g'),
    title         = regexp_replace(title,         '\$\{(monto|monto_cuota|monto_consulta|cargo_servicio|iva_cargo_servicio|total|comision_servicio|iva_comision|servicio_helios|cargo_atraso|cargo)\}', '{\1}', 'g'),
    body          = regexp_replace(body,          '\$\{(monto|monto_cuota|monto_consulta|cargo_servicio|iva_cargo_servicio|total|comision_servicio|iva_comision|servicio_helios|cargo_atraso|cargo)\}', '{\1}', 'g'),
    draft_title   = regexp_replace(draft_title,   '\$\{(monto|monto_cuota|monto_consulta|cargo_servicio|iva_cargo_servicio|total|comision_servicio|iva_comision|servicio_helios|cargo_atraso|cargo)\}', '{\1}', 'g'),
    draft_body    = regexp_replace(draft_body,    '\$\{(monto|monto_cuota|monto_consulta|cargo_servicio|iva_cargo_servicio|total|comision_servicio|iva_comision|servicio_helios|cargo_atraso|cargo)\}', '{\1}', 'g'),
    default_html  = regexp_replace(default_html,  '\$\{(monto|monto_cuota|monto_consulta|cargo_servicio|iva_cargo_servicio|total|comision_servicio|iva_comision|servicio_helios|cargo_atraso|cargo)\}', '{\1}', 'g'),
    html          = regexp_replace(html,          '\$\{(monto|monto_cuota|monto_consulta|cargo_servicio|iva_cargo_servicio|total|comision_servicio|iva_comision|servicio_helios|cargo_atraso|cargo)\}', '{\1}', 'g')
where key in ('confirmar_financiamiento', 'comprobante_financiamiento', 'bienvenida',
              'cuota_manana', 'cuota_hoy', 'cuota_vencida_d1', 'cargo_por_atraso_d4',
              'cuenta_congelada', 'pago_recibido', 'pago_rechazado');

-- 2b. El total, con sus bolívares de hoy (texto y HTML).
update public.notification_templates
set default_body = replace(default_body, '* Total: {total}', '* Total: {total} ({total_bs} a la tasa BCV de hoy)'),
    body         = replace(body,         '* Total: {total}', '* Total: {total} ({total_bs} a la tasa BCV de hoy)'),
    draft_body   = replace(draft_body,   '* Total: {total}', '* Total: {total} ({total_bs} a la tasa BCV de hoy)')
where key = 'confirmar_financiamiento';

update public.notification_templates
set default_body = replace(default_body, E'📅 {cuotas_fechas}\n', E'📅 {cuotas_fechas}\nLas pagas en bolívares, a la tasa BCV del {moneda} del día en que pagues.\n'),
    body         = replace(body,         E'📅 {cuotas_fechas}\n', E'📅 {cuotas_fechas}\nLas pagas en bolívares, a la tasa BCV del {moneda} del día en que pagues.\n'),
    draft_body   = replace(draft_body,   E'📅 {cuotas_fechas}\n', E'📅 {cuotas_fechas}\nLas pagas en bolívares, a la tasa BCV del {moneda} del día en que pagues.\n')
where key = 'confirmar_financiamiento';

update public.notification_templates
set default_body = replace(replace(default_body,
                     'Total a pagar: {total}', 'Total a pagar: {total} ({total_bs} a la tasa BCV de hoy)'),
                     'Pagas en bolívares, a la tasa BCV del dólar del día en que pagues.',
                     'Pagas en bolívares (Pago Móvil o transferencia), a la tasa BCV del {moneda} del día en que pagues.'),
    body         = replace(replace(body,
                     'Total a pagar: {total}', 'Total a pagar: {total} ({total_bs} a la tasa BCV de hoy)'),
                     'Pagas en bolívares, a la tasa BCV del dólar del día en que pagues.',
                     'Pagas en bolívares (Pago Móvil o transferencia), a la tasa BCV del {moneda} del día en que pagues.'),
    draft_body   = replace(replace(draft_body,
                     'Total a pagar: {total}', 'Total a pagar: {total} ({total_bs} a la tasa BCV de hoy)'),
                     'Pagas en bolívares, a la tasa BCV del dólar del día en que pagues.',
                     'Pagas en bolívares (Pago Móvil o transferencia), a la tasa BCV del {moneda} del día en que pagues.'),
    default_html = replace(replace(default_html,
                     'font-weight:bold;">{total}</td>',
                     'font-weight:bold;">{total}<br><span style="font-weight:normal;font-size:13px;color:#64748b;">{total_bs} a la tasa BCV de hoy</span></td>'),
                     'a la tasa BCV del d&oacute;lar <strong>', 'a la tasa BCV del {moneda} <strong>'),
    html         = replace(replace(html,
                     'font-weight:bold;">{total}</td>',
                     'font-weight:bold;">{total}<br><span style="font-weight:normal;font-size:13px;color:#64748b;">{total_bs} a la tasa BCV de hoy</span></td>'),
                     'a la tasa BCV del d&oacute;lar <strong>', 'a la tasa BCV del {moneda} <strong>')
where key = 'comprobante_financiamiento';

-- 2c. La bienvenida: solo bolívares.
update public.notification_templates
set default_body = replace(default_body,
                     'Puedes pagar en bolívares a tasa BCV del día o en efectivo en divisas.',
                     'Pagas en bolívares (Pago Móvil o transferencia), a la tasa BCV del {moneda} del día en que pagues.'),
    body         = replace(body,
                     'Puedes pagar en bolívares a tasa BCV del día o en efectivo en divisas.',
                     'Pagas en bolívares (Pago Móvil o transferencia), a la tasa BCV del {moneda} del día en que pagues.'),
    draft_body   = replace(draft_body,
                     'Puedes pagar en bolívares a tasa BCV del día o en efectivo en divisas.',
                     'Pagas en bolívares (Pago Móvil o transferencia), a la tasa BCV del {moneda} del día en que pagues.')
where key = 'bienvenida';

-- 2d. Las variables que el editor de avisos ofrece.
update public.notification_templates
set variables = (select array_agg(distinct v order by v) from unnest(variables || array['total_bs', 'moneda']) v)
where key in ('confirmar_financiamiento', 'comprobante_financiamiento');

update public.notification_templates
set variables = (select array_agg(distinct v order by v) from unnest(variables || array['moneda']) v)
where key = 'bienvenida';

-- ---------------------------------------------------------------------------
-- 3. Las variables de siempre
-- ---------------------------------------------------------------------------

create or replace function public.helios_message_builtins(p_profile_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_p       public.profiles%rowtype;
  v_c       public.platform_contact%rowtype;
  v_wa      text;
  v_cuentas text := public.helios_payment_accounts_text();
  v_tasa    numeric := public.current_fx_rate('BCV');
  v_tasa_e  numeric := public.current_fx_rate('BCV_EUR');
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
    -- Con su símbolo: el cargo por atraso es en dólares.
    'cargo_atraso', public.helios_money_cur_text(public.helios_late_fee_usd(), 'USD'),
    'dias_gracia', public.helios_late_fee_grace_days()::text,
    'dias_suspension', public.helios_mora_demotion_days()::text,
    'dias_expulsion', public.helios_mora_expulsion_days()::text
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. La pregunta al paciente
-- ---------------------------------------------------------------------------

create or replace function public.helios_enqueue_confirmation(p_charge_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c      public.charges%rowtype;
  v_plan   jsonb;
  v_linea  text;
  v_montos numeric[];
  v_fechas text;
  v_iva    numeric;
  v_rate   numeric;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found or v_c.status <> 'pending' then
    raise exception 'La orden no está esperando al paciente' using errcode = '22023';
  end if;

  v_plan := public.helios_charge_planned_installments(p_charge_id);
  v_rate := public.helios_fx_rate(v_c.currency);

  -- En una sola línea: Meta no admite saltos de línea en una variable. Cada
  -- cuota en la moneda de la orden.
  select string_agg(format('%s el %s',
                           public.helios_money_cur_text((x->>'amount_cur')::numeric, v_c.currency),
                           to_char((x->>'due_date')::date, 'DD/MM')),
                    ' y ' order by (x->>'sequence')::integer),
         array_agg((x->>'amount_cur')::numeric order by (x->>'sequence')::integer),
         string_agg(to_char((x->>'due_date')::date, 'DD/MM'), ' y ' order by (x->>'sequence')::integer)
    into v_linea, v_montos, v_fechas
  from jsonb_array_elements(v_plan) x;

  -- El IVA del cargo, como porcentaje del cargo (el que se cobró de verdad).
  v_iva := case when coalesce(v_c.consumer_fee_usd, 0) > 0
                then round(v_c.consumer_fee_vat_usd * 100 / v_c.consumer_fee_usd, 2)
                else public.helios_parameter('vat_pct', 16) end;

  return public.helios_enqueue_message(
    'confirmar_financiamiento', v_c.user_id, p_charge_id, 'whatsapp',
    jsonb_build_object(
      'clinica', (select m.name from public.merchants m where m.id = v_c.merchant_id),
      'moneda', public.helios_currency_name(v_c.currency),
      'monto_consulta', public.helios_money_cur_text(coalesce(v_c.base_cur, v_c.amount_cur), v_c.currency),
      'servicio_pct', public.helios_pct_text(v_c.consumer_fee_pct),
      'cargo_servicio', public.helios_money_cur_text(coalesce(v_c.consumer_fee_cur, 0), v_c.currency),
      'iva_pct', public.helios_pct_text(v_iva),
      'iva_cargo_servicio', public.helios_money_cur_text(coalesce(v_c.consumer_fee_vat_cur, 0), v_c.currency),
      'total', public.helios_money_cur_text(v_c.amount_cur, v_c.currency),
      'total_bs', case when v_rate is null then 'el equivalente en bolívares'
                       else public.helios_ves_text(round(v_c.amount_cur * v_rate, 2)) end,
      'cuotas_monto', case
        when v_montos[1] = v_montos[array_upper(v_montos, 1)]
          then public.helios_money_cur_text(v_montos[1], v_c.currency)
        else (select string_agg(public.helios_money_cur_text(m, v_c.currency), ' y ') from unnest(v_montos) m) end,
      'cuotas_fechas', v_fechas,
      'cuotas_linea', v_linea,
      'orden', coalesce(v_c.order_number::text, left(v_c.id::text, 8)),
      'vence', to_char(v_c.expires_at at time zone 'America/Caracas', 'HH24:MI')
    ),
    null, null);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. El comprobante
-- ---------------------------------------------------------------------------

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
  -- monto es fijo, los bolívares los da la tasa del día en que pague.
  select count(*)::integer,
         string_agg(format('• Cuota %s: %s%s, vence el %s %s', i.sequence,
                           public.helios_money_cur_text(i.amount_cur, v_c.currency),
                           case when v_rate is not null
                                then ' (hoy ' || public.helios_ves_text(round(i.amount_cur * v_rate, 2)) || ')'
                                else '' end,
                           public.helios_weekday_es(i.due_date), to_char(i.due_date, 'DD/MM/YYYY')),
                    E'\n' order by i.sequence),
         string_agg(format('<tr><td style="%s">Cuota %s</td><td style="%s">%s %s</td>'
                           '<td align="right" style="%sfont-weight:bold;">%s%s</td></tr>',
                           v_td, i.sequence, v_td, public.helios_weekday_es(i.due_date),
                           to_char(i.due_date, 'DD/MM/YYYY'), v_td,
                           public.helios_html_escape(public.helios_money_cur_text(i.amount_cur, v_c.currency)),
                           case when v_rate is not null
                                then '<br><span style="font-weight:normal;font-size:12px;color:#64748b;">hoy '
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
    v_aviso_h := format(
      '<p style="margin:0 0 10px 0;">Cuando pagues, env&iacute;anos el comprobante por WhatsApp al %s, indicando la orden #%s.</p>'
      '<table role="presentation" border="0" cellpadding="0" cellspacing="0"><tr>'
      '<td bgcolor="#1A56DB" style="background-color:#1A56DB;border-radius:4px;">'
      '<a href="%s" target="_blank" style="display:inline-block;padding:11px 20px;font-family:Arial,Helvetica,sans-serif;font-size:15px;font-weight:bold;color:#ffffff;text-decoration:none;">Avisar mi pago por WhatsApp</a>'
      '</td></tr></table>',
      public.helios_html_escape(v_wa_txt), public.helios_html_escape(v_orden),
      public.helios_html_escape(v_link));
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
$$;

-- ---------------------------------------------------------------------------
-- 6. La bienvenida (dentro de `helios_finalize_charge`)
-- ---------------------------------------------------------------------------

create or replace function public.helios_finalize_charge(
  p_charge_id          uuid,
  p_welcome_channel    text,
  p_over_limit_message text default null
)
returns void
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_charge   public.charges%rowtype;
  v_terms    public.merchant_terms%rowtype;
  v_due_1    date;
  v_due_2    date;
  v_financed numeric(18,4);
  v_revenue  numeric(18,4);
  v_share    numeric(18,4);
  v_tx       uuid;
  v_cuotas   text;
  v_merchant text;
  v_rate     numeric;
begin
  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Orden no encontrada' using errcode = 'P0002';
  end if;

  if v_charge.status = 'pending' then
    update public.charges
       set status = 'confirmed', confirmed_at = now()
     where id = p_charge_id
    returning * into v_charge;
  end if;

  if v_charge.status <> 'confirmed' or v_charge.user_id is null then
    raise exception 'La orden no se puede confirmar' using errcode = '22023';
  end if;

  select * into v_terms from public.helios_terms_at(v_charge.merchant_id, v_charge.business_date);
  if v_terms.id is null then
    raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
      using errcode = '22023';
  end if;

  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_charge.business_date);

  -- El asiento de cuatro patas, saltándose las que valen cero. En dólares.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);
  v_revenue  := coalesce(v_charge.consumer_fee_usd, 0) + coalesce(v_charge.merchant_fee_usd, 0);
  v_share    := coalesce(v_charge.merchant_net_usd, v_charge.amount_usd - v_revenue);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', 'charge:' || v_charge.idempotency_key, v_charge.business_date, v_charge.id,
          'Financiamiento de consulta')
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit)
  select v_tx, x.acct, x.debit, x.credit
  from (values
    (ledger.get_or_create_account('user_receivable', v_charge.user_id), v_charge.amount_usd, 0::numeric),
    (ledger.get_or_create_account('merchant_payable', v_charge.merchant_id), 0::numeric, v_share),
    (ledger.get_or_create_account('platform_revenue', null), 0::numeric, v_revenue),
    (ledger.get_or_create_account('vat_payable', null), 0::numeric,
     v_charge.amount_usd - v_share - v_revenue)
  ) as x(acct, debit, credit)
  where x.debit <> 0 or x.credit <> 0;

  -- El adelanto a la clínica (no hace nada con upfront_pct = 0).
  perform ledger.record_advance_settlement(
    v_charge.merchant_id, v_charge.id, round(v_share * v_terms.upfront_pct / 100, 4), v_charge.business_date);

  -- La deuda: las 2 cuotas a +7 y +14 días y el bloque de crédito. Cada cuota
  -- se pone sola su monto en la moneda de la orden (trigger
  -- `installments_currency`).
  perform public.helios_assign_debt(
    v_charge.user_id, v_charge.id, v_financed, v_charge.amount_usd, v_due_1, v_due_2,
    coalesce(p_over_limit_message, public.helios_not_available_message()));

  -- La comisión de quien lo registró.
  perform public.helios_accrue_staff_commission(v_charge.id);

  -- Los mensajes: el comprobante (al correo REGISTRADO) y la bienvenida.
  perform public.helios_enqueue_charge_receipt(v_charge.id);

  v_rate := public.helios_fx_rate(v_charge.currency);

  select m.name into v_merchant from public.merchants m where m.id = v_charge.merchant_id;
  select string_agg(format('* %s%s — %s',
                           public.helios_money_cur_text(i.amount_cur, v_charge.currency),
                           case when v_rate is not null
                                then ' (hoy ' || public.helios_ves_text(round(i.amount_cur * v_rate, 2)) || ')'
                                else '' end,
                           to_char(i.due_date, 'DD/MM/YYYY')),
                    E'\n' order by i.sequence)
    into v_cuotas
  from public.installments i where i.charge_id = v_charge.id;

  perform public.helios_enqueue_message(
    'bienvenida', v_charge.user_id, v_charge.id, p_welcome_channel,
    jsonb_build_object('clinica', v_merchant, 'orden', v_charge.order_number::text, 'cuotas', v_cuotas,
                       'moneda', public.helios_currency_name(v_charge.currency)),
    null, 'bienvenida:' || v_charge.id::text);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Los avisos de cuota
-- ---------------------------------------------------------------------------

create or replace function public.helios_enqueue_reminders(p_key text, p_today date default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
  if p_key is null or p_key not in ('cuota_manana', 'cuota_hoy', 'cuota_vencida_d1', 'cargo_por_atraso_d4') then
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
      continue when v_channel not in ('whatsapp_manual', 'email');
      -- El correo de la víspera es un extra automático: sin correo válido no
      -- se encola nada (el WhatsApp sí).
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
            'fecha', public.helios_weekday_es(v_due) || ' ' || to_char(v_due, 'DD/MM')
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
$$;

-- ---------------------------------------------------------------------------
-- 8. «Recibimos tu pago»: lo de cada moneda y los bolívares que pagó
-- ---------------------------------------------------------------------------

create or replace function public.notify_payment_result()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_quote   public.payment_quotes%rowtype;
  v_ordenes text;
  v_cargo   uuid;
  v_n       integer;
  v_eur_usd numeric(18,4);
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

  begin
    if new.status = 'reconciled' then
      perform public.helios_enqueue_message(
        'pago_recibido', new.user_id, case when v_n = 1 then v_cargo end, 'whatsapp_manual',
        jsonb_build_object(
          'monto', public.helios_amounts_label(v_quote.amount_usd - v_eur_usd, v_quote.amount_eur)
                   || coalesce(' (' || public.helios_ves_text(v_quote.amount_ves) || ')', ''),
          'orden', coalesce(v_ordenes, '')
        ),
        null, 'pago_recibido:' || new.id);
    else
      perform public.helios_enqueue_message(
        'pago_rechazado', new.user_id, case when v_n = 1 then v_cargo end, 'whatsapp_manual',
        jsonb_build_object(
          'motivo', coalesce(nullif(btrim(new.rejection_note), ''),
                             'no encontramos ese pago en nuestra cuenta'),
          'orden', coalesce(v_ordenes, '')
        ),
        null, 'pago_rechazado:' || new.id);
    end if;
  exception when others then
    raise warning 'No se encoló el aviso del pago %: %', new.id, sqlerrm;
  end;

  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. El aviso al médico por WhatsApp
-- ---------------------------------------------------------------------------

create or replace function public.helios_notify_staff_of_charge(p_charge_id uuid, p_kind text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c     public.charges%rowtype;
  v_phone text;
  v_quien text;
  v_texto text;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found or v_c.channel <> 'whatsapp' then
    return;
  end if;

  select n.phone_e164 into v_phone from public.staff_whatsapp_numbers n
  where n.user_id = v_c.requested_by and n.merchant_id = v_c.merchant_id and n.revoked_at is null;
  if v_phone is null or not public.helios_whatsapp_window_open(v_phone) then
    return;
  end if;

  select concat_ws(' ', nullif(btrim(p.first_name), ''),
                   case when nullif(btrim(p.last_name), '') is not null then left(btrim(p.last_name), 1) || '.' end)
    into v_quien
  from public.profiles p where p.id = v_c.user_id;
  v_quien := coalesce(nullif(v_quien, ''), 'El paciente');

  v_texto := case p_kind
    when 'aceptada' then format('✅ %s aceptó. Orden #%s confirmada: consulta de %s.',
                                v_quien, v_c.order_number,
                                public.helios_money_cur_text(coalesce(v_c.base_cur, v_c.amount_cur), v_c.currency))
    when 'rechazada' then case v_c.decline_reason
      when 'no_disponible' then format('La orden #%s de %s no se pudo confirmar. %s',
                                       v_c.order_number, v_quien, public.helios_not_available_message())
      else format('❌ %s no aceptó la orden #%s. No se creó ninguna deuda.', v_quien, v_c.order_number) end
    when 'vencida' then format('⌛ La orden #%s de %s venció sin respuesta. Escribe «reenviar %s» para enviársela otra vez.',
                               v_c.order_number, v_quien, v_c.order_number)
  end;
  if v_texto is null then
    return;
  end if;

  perform public.helios_whatsapp_text(v_phone, v_texto, v_c.requested_by);
exception when others then
  -- Un aviso que no sale no puede tumbar la confirmación del paciente.
  null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Los bots
-- ---------------------------------------------------------------------------

create or replace function public.bot_paciente_resumen(p_profile_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy date := public.helios_business_date(now());
begin
  return jsonb_build_object(
    'nombre', (select coalesce(nullif(btrim(p.first_name), ''), split_part(btrim(coalesce(p.full_name, '')), ' ', 1))
               from public.profiles p where p.id = p_profile_id),
    -- Cada orden en su moneda: la consulta y las cuotas en ella; el cargo por
    -- atraso, en dólares.
    'financiamientos', coalesce((
      select jsonb_agg(f order by f->>'primera')
      from (
        select jsonb_build_object(
                 'orden', c.order_number,
                 'clinica', m.name,
                 'moneda', c.currency,
                 'consulta', coalesce(c.base_cur, c.base_usd, c.amount_usd),
                 'primera', min(i.due_date),
                 'cuotas', jsonb_agg(jsonb_build_object(
                             'sequence', i.sequence,
                             'due_date', i.due_date,
                             'monto', coalesce(i.amount_cur, i.amount_usd),
                             'cargo_atraso', coalesce((select sum(lf.amount_usd) from public.late_fees lf
                                                       where lf.installment_id = i.id and lf.status = 'pending'), 0),
                             'vencida', i.due_date < v_hoy)
                           order by i.due_date, i.sequence)) as f
        from public.installments i
        join public.charges c on c.id = i.charge_id and c.status = 'confirmed'
        join public.merchants m on m.id = c.merchant_id
        where i.user_id = p_profile_id and i.status = 'pending' and i.written_off_at is null
        group by c.id, c.order_number, m.name, c.currency, c.base_cur, c.base_usd, c.amount_usd
      ) x
    ), '[]'::jsonb),
    'tasa_bcv', public.current_fx_rate('BCV'),
    'tasa_bcv_eur', public.current_fx_rate('BCV_EUR'),
    'cuentas_de_cobro', public.helios_payment_accounts_text(),
    'pago_en_revision', exists (select 1 from public.payment_reports r
                                where r.user_id = p_profile_id and r.status in ('reported', 'in_review'))
  );
end;
$$;

create or replace function public.bot_patient_eligibility(p_phone text, p_document text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n   public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_usd numeric;
  v_eur numeric;
begin
  perform public.helios_bot_as(v_n.user_id);

  -- La tasa cruzada de hoy, para decir lo disponible en euros.
  v_usd := public.current_fx_rate('BCV');
  v_eur := public.current_fx_rate('BCV_EUR');

  return public.helios_patient_eligibility(v_n.merchant_id, p_document)
         || jsonb_build_object('usd_per_eur', case when v_usd > 0 and v_eur > 0
                                                   then round(v_eur / v_usd, 6) end);
end;
$$;
