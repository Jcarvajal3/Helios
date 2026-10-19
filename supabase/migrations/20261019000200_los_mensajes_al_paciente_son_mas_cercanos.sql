-- ============================================================================
-- Helios — Los mensajes al paciente son más cercanos y ordenados
-- (2026-10-19, textos aprobados por Javier)
--
-- 1. El bloque de pago, igual en todos los mensajes que dicen cómo pagar:
--    los bolívares de HOY (solo aquí, junto a los medios de pago, y dicho
--    que el día que pague será el equivalente a la tasa de ese día), cada
--    cuenta en líneas separadas (Banco, Teléfono, RIF con guiones,
--    Titular), «envíanos la foto del comprobante» y la frase de los niveles
--    (`helios_level_reminder`: Javier la pidió aunque los niveles estén
--    apagados; cuando se retome lo de los niveles, se cambia ahí).
-- 2. La pregunta (`confirmar_financiamiento`): nombra al médico, la
--    bienvenida no supone el género y los bolívares salen del total.
-- 3. La bienvenida tras el «Sí» trae las cuotas y cómo pagar la primera.
-- 4. Los recordatorios nombran al médico y llevan el bloque.
-- 5. El paciente recibe respuesta cuando dice «No», cuando contesta tarde y
--    cuando la orden no se pudo confirmar (antes, silencio).
-- 6. Pago confirmado o rechazado: además del correo, un WhatsApp si la
--    ventana de 24 h está abierta (gratis: casi siempre acaba de mandar el
--    comprobante).
-- 7. `bot_paciente_resumen` trae lo que el bot necesita para «Mi saldo y
--    cuotas» (lo disponible, las cuotas pagadas, las órdenes terminadas) y
--    el médico de cada orden; `bot_paciente_contexto`, la respuesta a un
--    «sí» escrito cuando la orden ya venció.
--
-- LAS PLANTILLAS DE META NO CAMBIAN: siguen conectadas las aprobadas, con
-- sus variables de siempre (`clinica`, `monto_cuota`, `cuentas_de_cobro`…),
-- que se siguen calculando igual. Las variables nuevas (`medico`, `monto`,
-- `monto_bs`, `bloque_de_pago`, `pago_movil_*`, `cuotas_detalle`) quedan
-- listas para las `_v2` (docs/00 §15.8). Cambia el texto libre: el WhatsApp
-- dentro de la ventana de 24 h y el texto plano del correo.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El bloque de pago
-- ---------------------------------------------------------------------------

-- «J504967866» → «J-50496786-6». Lo que no tenga esa forma, tal cual.
create or replace function public.helios_rif_text(p_rif text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case when x ~ '^[VEJGPC][0-9]{9}$'
              then substr(x, 1, 1) || '-' || substr(x, 2, 8) || '-' || substr(x, 10, 1)
              else p_rif end
  from (select upper(regexp_replace(coalesce(p_rif, ''), '[^0-9A-Za-z]', '', 'g')) as x) s;
$$;

-- La frase de los niveles (Javier, 2026-10-19), en un solo sitio.
create or replace function public.helios_level_reminder()
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select '⭐ Recuerda pagar a tiempo para subir de nivel y disponer de mayores beneficios.'::text;
$$;

-- Las cuentas de cobro, una por bloque y cada dato en su línea (para el
-- texto libre; las plantillas de Meta usan `cuentas_de_cobro`, en una línea).
create or replace function public.helios_payment_accounts_block()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    string_agg(
      case d.method
        when 'pago_movil' then concat_ws(E'\n',
          '🏦 *Pago Móvil*',
          'Banco: ' || nullif(btrim(d.bank_name), ''),
          'Teléfono: ' || coalesce(public.helios_format_ve_phone(d.phone), d.phone),
          'RIF: ' || public.helios_rif_text(nullif(btrim(d.rif), '')),
          'Titular: ' || nullif(btrim(d.holder_name), ''))
        when 'transferencia' then concat_ws(E'\n',
          '🏦 *Transferencia*',
          'Banco: ' || nullif(btrim(d.bank_name), ''),
          'Cuenta: ' || nullif(btrim(d.account_number), ''),
          'RIF: ' || public.helios_rif_text(nullif(btrim(d.rif), '')),
          'Titular: ' || nullif(btrim(d.holder_name), ''))
      end,
      E'\n\n' order by d.sort_order, d.created_at),
    'Te escribiremos por aquí con los datos para pagar.')
  from public.payment_destinations d
  where d.is_active and d.method in ('pago_movil', 'transferencia');
$$;

-- El bloque entero. `p_ves`: los bolívares de hoy (null si falta la tasa);
-- `p_equivalente`: «$56,96»; `p_moneda`: «dólar», «euro» o «dólar y del
-- euro»; `p_por`: dónde mandar el comprobante («por este chat»).
create or replace function public.helios_payment_block(
  p_ves numeric, p_equivalente text, p_moneda text, p_por text default 'por este chat')
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select concat_ws(E'\n\n',
    case when p_ves is not null then
      format(E'💵 *Monto en bolívares hoy: %s*\nEs el equivalente a %s a la tasa BCV del %s de hoy. Si pagas otro día, paga el equivalente a la tasa BCV de ese día.',
             public.helios_ves_text(p_ves), p_equivalente, p_moneda)
    else
      format(E'💵 *Monto en bolívares*\nPagas el equivalente a %s a la tasa BCV del %s del día en que pagues.',
             p_equivalente, p_moneda)
    end,
    public.helios_payment_accounts_block(),
    format('📸 Cuando pagues, envíanos la foto del comprobante %s.', coalesce(p_por, 'por este chat')),
    public.helios_level_reminder());
$$;

-- Dónde mandar el comprobante, como `{por_whatsapp}` (20261013000700): en
-- WhatsApp, este mismo chat; en el correo, el número de Helios.
create or replace function public.helios_por_whatsapp(p_channel text)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
           when coalesce(p_channel, 'whatsapp') <> 'email' then 'por este chat'
           when c.whatsapp_number is not null
             then 'por WhatsApp al ' || coalesce(public.helios_format_ve_phone(c.whatsapp_number), c.whatsapp_number)
           else 'por WhatsApp'
         end
  from (select 1) uno
  left join public.platform_contact c on c.id;
$$;

-- Las variables de siempre, más los datos del Pago Móvil sueltos (para las
-- plantillas `_v2`: Meta no admite saltos de línea en una variable ni una
-- variable vacía).
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
  v_pm      public.payment_destinations%rowtype;
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
  select * into v_pm from public.payment_destinations d
  where d.is_active and d.method = 'pago_movil'
  order by d.sort_order, d.created_at limit 1;

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
    -- NUEVO (2026-10-19)
    'datos_de_pago', public.helios_payment_accounts_block(),
    'pago_movil_banco', coalesce(nullif(btrim(v_pm.bank_name), ''), '—'),
    'pago_movil_telefono', coalesce(public.helios_format_ve_phone(v_pm.phone), nullif(btrim(v_pm.phone), ''), '—'),
    'pago_movil_rif', coalesce(public.helios_rif_text(nullif(btrim(v_pm.rif), '')), '—'),
    'pago_movil_titular', coalesce(nullif(btrim(v_pm.holder_name), ''), '—'),
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
$$;

-- ---------------------------------------------------------------------------
-- 2. La pregunta
-- ---------------------------------------------------------------------------

create or replace function public.helios_enqueue_confirmation(p_charge_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c       public.charges%rowtype;
  v_plan    jsonb;
  v_linea   text;
  v_montos  numeric[];
  v_fechas  text;
  v_lista   text;
  v_detalle text;
  v_iva     numeric;
  v_rate    numeric;
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
         string_agg(to_char((x->>'due_date')::date, 'DD/MM'), ' y ' order by (x->>'sequence')::integer),
         -- NUEVO (2026-10-19): con el día de la semana.
         string_agg(format('📅 %s · %s',
                           public.helios_money_cur_text((x->>'amount_cur')::numeric, v_c.currency),
                           public.helios_weekday_es((x->>'due_date')::date) || ' ' || to_char((x->>'due_date')::date, 'DD/MM')),
                    E'\n' order by (x->>'sequence')::integer),
         string_agg(format('%s el %s',
                           public.helios_money_cur_text((x->>'amount_cur')::numeric, v_c.currency),
                           public.helios_weekday_es((x->>'due_date')::date) || ' ' || to_char((x->>'due_date')::date, 'DD/MM')),
                    ' y ' order by (x->>'sequence')::integer)
    into v_linea, v_montos, v_fechas, v_lista, v_detalle
  from jsonb_array_elements(v_plan) x;

  -- El IVA del cargo, como porcentaje del cargo (el que se cobró de verdad).
  v_iva := case when coalesce(v_c.consumer_fee_usd, 0) > 0
                then round(v_c.consumer_fee_vat_usd * 100 / v_c.consumer_fee_usd, 2)
                else public.helios_parameter('vat_pct', 16) end;

  return public.helios_enqueue_message(
    'confirmar_financiamiento', v_c.user_id, p_charge_id, 'whatsapp',
    jsonb_build_object(
      'clinica', (select m.name from public.merchants m where m.id = v_c.merchant_id),
      'medico', public.helios_doctor_ref(v_c.merchant_id),
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
      'cuotas_lista', v_lista,
      'cuotas_detalle', v_detalle,
      'orden', coalesce(v_c.order_number::text, left(v_c.id::text, 8)),
      'vence', to_char(v_c.expires_at at time zone 'America/Caracas', 'HH24:MI')
    ),
    null, null);
end;
$$;

update public.notification_templates
   set default_body =
          E'👋 ¡Hola, {nombre}! Te damos la bienvenida a Helios 💙\n\n'
       || E'Tu consulta con {medico} quedó registrada para que la pagues en *2 cuotas, sin inicial*.\n\n'
       || E'*Tu consulta*\n'
       || E'Consulta: {monto_consulta}\n'
       || E'Comisión de servicio ({servicio_pct}%): {cargo_servicio}\n'
       || E'IVA de la comisión ({iva_pct}%): {iva_cargo_servicio}\n'
       || E'*Total: {total}*\n\n'
       || E'*Tus cuotas*\n'
       || E'{cuotas_lista}\n\n'
       || E'Pagas cada cuota en bolívares, a la tasa BCV del {moneda} del día en que pagues.\n\n'
       || '¿Confirmas tu pago en cuotas? Responde Sí o No. Tienes 2 horas para responder.',
       variables = (select array_agg(distinct v order by v)
                    from unnest(variables || array['medico', 'cuotas_lista', 'cuotas_detalle']) v),
       required_variables = array['medico', 'monto_consulta', 'servicio_pct', 'cargo_servicio', 'iva_pct',
                                  'iva_cargo_servicio', 'total', 'cuotas_lista']
 where key = 'confirmar_financiamiento';

-- ---------------------------------------------------------------------------
-- 3. La bienvenida tras el «Sí»: las cuotas y cómo pagar la primera
-- ---------------------------------------------------------------------------

create or replace function public.helios_finalize_charge(
  p_charge_id uuid, p_welcome_channel text, p_over_limit_message text default null)
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
  v_demo     boolean;
  v_first    public.installments%rowtype;
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

  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);
  v_revenue  := coalesce(v_charge.consumer_fee_usd, 0) + coalesce(v_charge.merchant_fee_usd, 0);
  v_share    := coalesce(v_charge.merchant_net_usd, v_charge.amount_usd - v_revenue);

  -- Una orden de capacitación no es dinero y no deja asiento; así se puede
  -- borrar entera a medianoche sin tocar el libro.
  select p.is_demo into v_demo from public.profiles p where p.id = v_charge.user_id;

  if not coalesce(v_demo, false) then
    -- El asiento de cuatro patas, saltándose las que valen cero. En dólares.
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
  end if;

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
  -- NUEVO (2026-10-19): «1️⃣ $56,96 · lunes 26/10», sin bolívares (van en el
  -- bloque de pago).
  select string_agg(format('%s %s · %s',
                           case i.sequence when 1 then '1️⃣' when 2 then '2️⃣' when 3 then '3️⃣'
                                           else i.sequence::text || '.' end,
                           public.helios_money_cur_text(i.amount_cur, v_charge.currency),
                           public.helios_weekday_es(i.due_date) || ' ' || to_char(i.due_date, 'DD/MM')),
                    E'\n' order by i.sequence)
    into v_cuotas
  from public.installments i where i.charge_id = v_charge.id;

  select * into v_first from public.installments i
  where i.charge_id = v_charge.id order by i.sequence limit 1;

  perform public.helios_enqueue_message(
    'bienvenida', v_charge.user_id, v_charge.id, p_welcome_channel,
    jsonb_build_object(
      'clinica', v_merchant,
      'medico', public.helios_doctor_ref(v_charge.merchant_id),
      'orden', v_charge.order_number::text,
      'cuotas', v_cuotas,
      'moneda', public.helios_currency_name(v_charge.currency),
      'bloque_de_pago', public.helios_payment_block(
        case when v_rate is not null then round(v_first.amount_cur * v_rate, 2) end,
        public.helios_money_cur_text(v_first.amount_cur, v_charge.currency),
        public.helios_currency_name(v_charge.currency),
        public.helios_por_whatsapp(p_welcome_channel))),
    null, 'bienvenida:' || v_charge.id::text);
end;
$$;

update public.notification_templates
   set default_body =
          E'✅ ¡Listo, {nombre}! Tu pago en cuotas #{orden} con {medico} está confirmado.\n\n'
       || E'*Tus cuotas*\n'
       || E'{cuotas}\n\n'
       || E'Te escribiremos antes de cada fecha. Si prefieres adelantarte, así pagas tu 1.ª cuota:\n\n'
       || '{bloque_de_pago}',
       variables = (select array_agg(distinct v order by v)
                    from unnest(variables || array['medico', 'bloque_de_pago']) v),
       required_variables = array['orden', 'cuotas', 'bloque_de_pago']
 where key = 'bienvenida';

-- ---------------------------------------------------------------------------
-- 4. Los recordatorios
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
  v_ves     numeric;
  v_monto   text;
  v_moneda  text;
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
      min(q.merchant_name)                              as una_clinica,
      -- NUEVO (2026-10-19): «la Dra. Nadia Khabbaze» (o los médicos, con «y»).
      string_agg(distinct public.helios_doctor_ref(q.merchant_id), ' y ') as medicos
    from cuotas q
    join public.profiles p on p.id = q.user_id
    -- El aviso del cargo solo sale si el cargo ya se cobró.
    where p_key <> 'cargo_por_atraso_d4' or q.fee_usd > 0
    group by q.user_id, p.email, p.email_invalid_at, p.phone_e164
    order by q.user_id
  loop
    -- Los bolívares de hoy, para el bloque de pago (null sin tasa).
    begin
      v_ves := (public.helios_bolivares(v_row.monto_usd, v_row.monto_eur, v_today)->>'amount_ves')::numeric;
    exception when sqlstate 'P0002' then
      v_ves := null;
    end;
    v_monto  := public.helios_amounts_label(v_row.monto_usd, v_row.monto_eur);
    v_moneda := case when v_row.monto_eur = 0 then 'dólar'
                     when v_row.monto_usd = 0 then 'euro'
                     else 'dólar y del euro' end;

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
            end,
            -- NUEVO (2026-10-19): el texto libre y las plantillas `_v2`.
            'medico', v_row.medicos,
            'monto', v_monto,
            'monto_bs', coalesce(public.helios_ves_text(v_ves), 'el equivalente en bolívares'),
            'bloque_de_pago', public.helios_payment_block(
              v_ves, v_monto, v_moneda, public.helios_por_whatsapp(v_channel))
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

update public.notification_templates
   set default_body = case key
     when 'cuota_en_3_dias' then
          E'Hola, {nombre} 👋 Te recordamos que tu cuota de {monto} de la consulta con {medico} vence el {fecha}.\n\n'
       || '{bloque_de_pago}'
     when 'cuota_manana' then
          E'Hola, {nombre} 👋 Mañana, {fecha}, vence tu cuota de {monto} de la consulta con {medico}.\n\n'
       || '{bloque_de_pago}'
     when 'cuota_hoy' then
          E'¡Buenos días, {nombre}! ☀️ Hoy, {fecha}, vence tu cuota de {monto} de la consulta con {medico}.\n\n'
       || E'{bloque_de_pago}\n\n'
       || 'Si ya pagaste, ¡gracias! Puedes ignorar este mensaje.'
     when 'cuota_vencida_d1' then
          'Hola, {nombre}. Tu cuota de {monto} de la consulta con {medico} venció ayer, {fecha}, y sigue pendiente. '
       || 'Sabemos que a veces pasa 💙 Mientras esté pendiente no podrás pagar nuevas consultas en cuotas; '
       || E'en cuanto pagues, se reactiva.{aviso_cargo_atraso}\n\n'
       || E'{bloque_de_pago}\n\n'
       || 'Si tienes algún inconveniente, escríbenos {por_whatsapp} y lo resolvemos juntos.'
   end,
       variables = (select array_agg(distinct v order by v)
                    from unnest(variables || array['medico', 'monto', 'monto_bs', 'bloque_de_pago', 'datos_de_pago',
                                                   'pago_movil_banco', 'pago_movil_telefono', 'pago_movil_rif',
                                                   'pago_movil_titular']) v),
       required_variables = case key when 'cuota_hoy' then array['monto', 'bloque_de_pago']
                                     else array['monto', 'fecha', 'bloque_de_pago'] end
 where key in ('cuota_en_3_dias', 'cuota_manana', 'cuota_hoy', 'cuota_vencida_d1');

-- ---------------------------------------------------------------------------
-- 5. La respuesta al «Sí» y al «No»
-- ---------------------------------------------------------------------------

-- `p_kind`: 'no' (dijo que no), 'vencida' (contestó pasadas las 2 h),
-- 'cuota_vencida' (no se confirmó porque debe una cuota) o 'no_disponible'
-- (no se confirmó por otra razón, que no se le detalla).
create or replace function public.helios_patient_decision_text(p_charge_id uuid, p_kind text)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_c      public.charges%rowtype;
  v_nombre text;
  v_med    text;
  v_txt    text;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found then
    return null;
  end if;

  select coalesce(nullif(btrim(p.first_name), ''), nullif(split_part(btrim(coalesce(p.full_name, '')), ' ', 1), ''))
    into v_nombre
  from public.profiles p where p.id = v_c.user_id;
  v_med := public.helios_doctor_ref(v_c.merchant_id);

  v_txt := case p_kind
    when 'no' then
      format(E'Entendido%s. No se registró ningún pago en cuotas y no debes nada 💙\nSi fue un error, pídele a %s que te lo envíe de nuevo.',
             coalesce(', ' || v_nombre, ''), v_med)
    when 'vencida' then
      coalesce(v_nombre || ', ', '') ||
      format(E'esta solicitud venció porque pasaron más de 2 horas ⌛. No te preocupes: no se registró nada.\nSi aún quieres pagar tu consulta en cuotas, pídele a %s que te la envíe otra vez.',
             v_med)
    when 'cuota_vencida' then
      coalesce(v_nombre || ', ', '') ||
      'no pudimos confirmar este pago en cuotas porque tienes una cuota pendiente. En cuanto la pagues podrás volver a usar Helios 💙'
    when 'no_disponible' then
      coalesce(v_nombre || ', ', '') ||
      'en este momento no pudimos confirmar tu pago en cuotas y no se registró ningún cargo. Si quieres, te ayudamos por aquí.'
  end;

  -- Sin nombre, la frase empieza con mayúscula.
  return upper(left(v_txt, 1)) || substr(v_txt, 2);
end;
$$;

-- Un WhatsApp al paciente si su ventana de 24 h está abierta. Si no sale, no
-- tumba nada (la decisión ya está tomada).
create or replace function public.helios_tell_patient(p_profile_id uuid, p_text text, p_buttons jsonb default '[]'::jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text;
begin
  select p.phone_e164 into v_phone from public.profiles p where p.id = p_profile_id;
  if v_phone is null or p_text is null or not public.helios_whatsapp_window_open(v_phone) then
    return;
  end if;
  perform public.helios_whatsapp_patient_text(v_phone, p_text, p_profile_id, coalesce(p_buttons, '[]'::jsonb));
exception when others then
  raise warning 'No se avisó al paciente %: %', p_profile_id, sqlerrm;
end;
$$;

create or replace function public.helios_patient_decision(
  p_charge_id uuid, p_decision text, p_from_phone text, p_wa_message_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $$
declare
  v_c        public.charges%rowtype;
  v_p        public.profiles%rowtype;
  v_decision text := lower(btrim(coalesce(p_decision, '')));
  v_msg_id   text := nullif(btrim(coalesce(p_wa_message_id, '')), '');
  v_ok       boolean;
  v_limit    numeric(18,4);
begin
  if v_decision not in ('si', 'no') or v_msg_id is null then
    return jsonb_build_object('ok', false, 'reason', 'peticion_invalida');
  end if;

  -- Un reintento del mismo mensaje: lo que ya se decidió.
  select * into v_c from public.charges where answer_wa_message_id = v_msg_id;
  if found then
    return jsonb_build_object('ok', v_c.status in ('confirmed', 'declined'), 'duplicate', true,
                              'charge_id', v_c.id, 'status', v_c.status::text,
                              'order_number', v_c.order_number);
  end if;

  select * into v_c from public.charges where id = p_charge_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_existe');
  end if;

  if v_c.status <> 'pending' then
    -- NUEVO (2026-10-19): pulsó el botón de una orden que ya venció.
    if v_c.status = 'expired' and v_c.answered_at is null then
      perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'vencida'));
    end if;
    return jsonb_build_object('ok', false, 'reason', 'no_pendiente', 'status', v_c.status::text);
  end if;

  if v_c.expires_at <= now() then
    update public.charges set status = 'expired' where id = v_c.id;
    perform public.helios_notify_staff_of_charge(v_c.id, 'vencida');
    perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'vencida'));
    return jsonb_build_object('ok', false, 'reason', 'vencida', 'status', 'expired');
  end if;

  select * into v_p from public.profiles where id = v_c.user_id for update;

  if regexp_replace(coalesce(p_from_phone, ''), '\D', '', 'g')
     <> regexp_replace(coalesce(v_p.phone_e164, '-'), '\D', '', 'g') then
    return jsonb_build_object('ok', false, 'reason', 'otro_telefono');
  end if;

  update public.charges
     set answered_at = now(), answer_wa_message_id = v_msg_id
   where id = v_c.id;

  if v_decision = 'no' then
    update public.charges
       set status = 'declined', decline_reason = 'paciente'
     where id = v_c.id;
    perform public.helios_notify_staff_of_charge(v_c.id, 'rechazada');
    perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'no'));
    return jsonb_build_object('ok', true, 'charge_id', v_c.id, 'status', 'declined',
                              'decline_reason', 'paciente', 'order_number', v_c.order_number);
  end if;

  -- «Sí»: revalidar lo que pudo cambiar mientras esperaba.
  v_ok := v_p.status = 'active'
          and not v_p.is_blacklisted
          and not public.helios_spend_blocked(v_p.id)
          and public.can_take_debt(v_p.id);

  if v_ok then
    begin
      perform public.helios_assert_merchant_operating(v_c.merchant_id);
    exception when others then
      v_ok := false;
    end;
  end if;

  if v_ok then
    -- El cupo ocupado incluye ya la reserva de ESTA orden.
    select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_p.level;
    v_ok := public.helios_credit_used_usd(v_p.id) <= coalesce(v_limit, 0);
  end if;

  if v_ok then
    begin
      perform public.helios_finalize_charge(v_c.id, 'whatsapp', null);
    exception when others then
      -- Se deshace todo lo de la confirmación; la orden se rechaza abajo.
      v_ok := false;
    end;
  end if;

  if not v_ok then
    update public.charges
       set status = 'declined', decline_reason = 'no_disponible'
     where id = v_c.id;
    perform public.helios_notify_staff_of_charge(v_c.id, 'rechazada');
    -- Al paciente: si debe una cuota, que la pague; si no, sin detalles.
    if public.helios_available_blocked_reason(v_p.id) = 'cuota_vencida' then
      perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'cuota_vencida'),
                                         '[{"id":"paciente:pagar","title":"Pagar mi cuota"}]'::jsonb);
    else
      perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'no_disponible'),
                                         '[{"id":"paciente:ayuda","title":"Hablar con alguien"}]'::jsonb);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'no_disponible', 'charge_id', v_c.id,
                              'status', 'declined', 'order_number', v_c.order_number);
  end if;

  perform public.helios_notify_staff_of_charge(v_c.id, 'aceptada');
  return jsonb_build_object('ok', true, 'charge_id', v_c.id, 'status', 'confirmed',
                            'order_number', v_c.order_number);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Pago confirmado o rechazado, también por WhatsApp si la ventana está
--    abierta
-- ---------------------------------------------------------------------------

create or replace function public.helios_payment_result_whatsapp(p_report_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_r       public.payment_reports%rowtype;
  v_q       public.payment_quotes%rowtype;
  v_nombre  text;
  v_ordenes text;
  v_n       integer;
  v_meds    text;
  v_eur_usd numeric(18,4);
  v_txt     text;
  v_sig     record;
begin
  select * into v_r from public.payment_reports where id = p_report_id;
  if not found then
    return null;
  end if;
  select * into v_q from public.payment_quotes where id = v_r.quote_id;

  select coalesce(nullif(btrim(p.first_name), ''), nullif(split_part(btrim(coalesce(p.full_name, '')), ' ', 1), ''))
    into v_nombre
  from public.profiles p where p.id = v_r.user_id;

  if v_r.status::text = 'rejected' then
    v_txt := coalesce(v_nombre || ', ', '') ||
             format(E'no pudimos confirmar el pago que nos enviaste 😕\nMotivo: %s\n\nRevisa el comprobante y envíanoslo de nuevo por aquí. Si crees que es un error, lo vemos juntos.',
                    coalesce(nullif(btrim(v_r.rejection_note), ''), 'no encontramos ese pago en nuestra cuenta'));
    return upper(left(v_txt, 1)) || substr(v_txt, 2);
  end if;

  if v_r.status::text <> 'reconciled' then
    return null;
  end if;

  select string_agg(distinct c.order_number::text, ', #'),
         count(distinct c.id),
         string_agg(distinct public.helios_doctor_ref(c.merchant_id), ' y ')
    into v_ordenes, v_n, v_meds
  from public.payment_quote_items qi
  join public.installments i on i.id = qi.installment_id
  join public.charges c on c.id = i.charge_id
  where qi.quote_id = v_r.quote_id;

  select coalesce(sum(qi.amount_usd), 0) into v_eur_usd
  from public.payment_quote_items qi
  where qi.quote_id = v_r.quote_id and qi.currency = 'EUR';

  v_txt := format(E'✅ ¡Pago confirmado%s!\nRecibimos %s de %s #%s con %s.',
                  coalesce(', ' || v_nombre, ''),
                  public.helios_amounts_label(v_q.amount_usd - v_eur_usd, v_q.amount_eur),
                  case when v_n > 1 then 'tus órdenes' else 'tu orden' end,
                  coalesce(v_ordenes, ''), v_meds);

  -- Lo que queda de esas órdenes, sin las cuotas de este pago.
  select i.sequence, i.due_date, coalesce(i.amount_cur, i.amount_usd) as monto, c.currency,
         count(*) over () as quedan
    into v_sig
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where i.charge_id in (select i2.charge_id from public.payment_quote_items qi2
                        join public.installments i2 on i2.id = qi2.installment_id
                        where qi2.quote_id = v_r.quote_id)
    and i.status = 'pending' and i.written_off_at is null
    and i.id not in (select qi3.installment_id from public.payment_quote_items qi3 where qi3.quote_id = v_r.quote_id)
  order by i.due_date, i.sequence
  limit 1;

  if v_sig is null or v_sig.sequence is null then
    return v_txt || format(E'\n\n🎉 ¡Terminaste de pagar %s! Gracias por confiar en Helios 💙',
                           case when v_n > 1 then 'tus consultas' else 'tu consulta' end);
  elsif v_sig.quedan = 1 then
    return v_txt || format(E'\n\nTe queda: %s.ª cuota de %s · %s', v_sig.sequence,
                           public.helios_money_cur_text(v_sig.monto, v_sig.currency),
                           public.helios_weekday_es(v_sig.due_date) || ' ' || to_char(v_sig.due_date, 'DD/MM'));
  end if;
  return v_txt || format(E'\n\nTu próxima cuota: %s · %s',
                         public.helios_money_cur_text(v_sig.monto, v_sig.currency),
                         public.helios_weekday_es(v_sig.due_date) || ' ' || to_char(v_sig.due_date, 'DD/MM'));
end;
$$;

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

  -- NUEVO (2026-10-19): también por WhatsApp, solo con la ventana abierta
  -- (texto libre, sin plantilla: no cuesta). Con la ventana cerrada, solo el
  -- correo, como hasta ahora.
  if v_tpl.enabled then
    perform public.helios_tell_patient(
      new.user_id, public.helios_payment_result_whatsapp(new.id),
      case when new.status = 'rejected'
           then '[{"id":"paciente:ayuda","title":"Hablar con alguien"}]'::jsonb
           else '[]'::jsonb end);
  end if;

  return null;
end;
$$;

update public.notification_templates
   set help = 'Por correo; y por WhatsApp (texto libre, sin plantilla) solo si el paciente escribió en las últimas 24 h (2026-10-19).'
 where key in ('pago_recibido', 'pago_rechazado');

-- ---------------------------------------------------------------------------
-- 7. El bot del paciente
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
    -- atraso, en dólares. `cuotas`: las pendientes; `pagadas` (2026-10-19):
    -- las ya pagadas de la misma orden.
    'financiamientos', coalesce((
      select jsonb_agg(f order by f->>'primera')
      from (
        select jsonb_build_object(
                 'orden', c.order_number,
                 'clinica', m.name,
                 'medico', public.helios_doctor_name(c.merchant_id),
                 'medico_ref', public.helios_doctor_ref(c.merchant_id),
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
                           order by i.due_date, i.sequence),
                 'pagadas', coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'sequence', pi.sequence,
                            'due_date', pi.due_date,
                            'monto', coalesce(pi.amount_cur, pi.amount_usd))
                          order by pi.sequence)
                   from public.installments pi
                   where pi.charge_id = c.id and pi.status = 'paid'), '[]'::jsonb)) as f
        from public.installments i
        join public.charges c on c.id = i.charge_id and c.status = 'confirmed'
        join public.merchants m on m.id = c.merchant_id
        where i.user_id = p_profile_id and i.status = 'pending' and i.written_off_at is null
        group by c.id, c.order_number, m.name, c.merchant_id, c.currency, c.base_cur, c.base_usd, c.amount_usd
      ) x
    ), '[]'::jsonb),
    -- Las últimas 3 órdenes ya pagadas completas.
    'terminados', coalesce((
      select jsonb_agg(t order by t->>'confirmada' desc)
      from (
        select jsonb_build_object(
                 'orden', c.order_number,
                 'medico', public.helios_doctor_name(c.merchant_id),
                 'moneda', c.currency,
                 'consulta', coalesce(c.base_cur, c.base_usd, c.amount_usd),
                 'confirmada', c.confirmed_at) as t
        from public.charges c
        where c.user_id = p_profile_id and c.status = 'confirmed'
          and exists (select 1 from public.installments i where i.charge_id = c.id)
          and not exists (select 1 from public.installments i where i.charge_id = c.id and i.status <> 'paid')
        order by c.confirmed_at desc
        limit 3
      ) y
    ), '[]'::jsonb),
    -- Lo que puede usar hoy (la misma cifra que ve el médico) y, si es cero,
    -- por qué ('cuota_vencida', 'estado', 'bloqueo').
    'disponible_usd', public.helios_available_now_usd(p_profile_id),
    'bloqueo', public.helios_available_blocked_reason(p_profile_id),
    'tasa_bcv', public.current_fx_rate('BCV'),
    'tasa_bcv_eur', public.current_fx_rate('BCV_EUR'),
    'cuentas_de_cobro', public.helios_payment_accounts_text(),
    'datos_de_pago', public.helios_payment_accounts_block(),
    'pago_en_revision', exists (select 1 from public.payment_reports r
                                where r.user_id = p_profile_id and r.status in ('reported', 'in_review'))
  );
end;
$$;

create or replace function public.bot_paciente_contexto(p_phone text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text := public.helios_wa_e164(p_phone);
  v_c     public.whatsapp_contacts%rowtype;
  v_perf  jsonb;
begin
  select * into v_c from public.whatsapp_contacts where phone_e164 = v_phone;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id,
           'nombre', coalesce(nullif(btrim(p.first_name), ''), split_part(btrim(coalesce(p.full_name, '')), ' ', 1)),
           'documento', p.document_key,
           'documento_enmascarado', public.helios_mask_document(p.document_number))
         order by p.created_at), '[]'::jsonb)
    into v_perf
  from public.profiles p
  where regexp_replace(coalesce(p.phone_e164, ''), '\D', '', 'g') = regexp_replace(coalesce(v_phone, '-'), '\D', '', 'g');

  return jsonb_build_object(
    'perfiles', v_perf,
    'elegido', case when v_c.patient_profile_id is not null
                     and v_perf @> jsonb_build_array(jsonb_build_object('id', v_c.patient_profile_id))
                    then v_c.patient_profile_id end,
    'estado', v_c.patient_state,
    'humano', coalesce(v_c.human_until > now(), false),
    'menu_reciente', coalesce(v_c.bot_menu_at > now() - interval '2 hours', false),
    -- NUEVO (2026-10-19): si escribe «sí» o «no» y su orden venció sin
    -- respuesta en las últimas 12 h, lo que se le contesta.
    'vencida_texto', (
      select public.helios_patient_decision_text(c.id, 'vencida')
      from public.charges c
      join public.profiles p on p.id = c.user_id
      where regexp_replace(coalesce(p.phone_e164, ''), '\D', '', 'g') = regexp_replace(coalesce(v_phone, '-'), '\D', '', 'g')
        and (c.status = 'expired' or (c.status = 'pending' and c.expires_at <= now()))
        and c.answered_at is null
        and c.expires_at > now() - interval '12 hours'
      order by c.expires_at desc
      limit 1)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------

revoke all on function public.helios_rif_text(text) from public, anon, authenticated;
revoke all on function public.helios_level_reminder() from public, anon, authenticated;
revoke all on function public.helios_payment_accounts_block() from public, anon, authenticated;
revoke all on function public.helios_payment_block(numeric, text, text, text) from public, anon, authenticated;
revoke all on function public.helios_por_whatsapp(text) from public, anon, authenticated;
revoke all on function public.helios_message_builtins(uuid) from public, anon, authenticated;
revoke all on function public.helios_enqueue_confirmation(uuid) from public, anon, authenticated;
revoke all on function public.helios_finalize_charge(uuid, text, text) from public, anon, authenticated;
revoke all on function public.helios_enqueue_reminders(text, date) from public, anon, authenticated;
revoke all on function public.helios_patient_decision_text(uuid, text) from public, anon, authenticated;
revoke all on function public.helios_tell_patient(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.helios_patient_decision(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.helios_payment_result_whatsapp(uuid) from public, anon, authenticated;
revoke all on function public.bot_paciente_resumen(uuid) from public, anon, authenticated;
revoke all on function public.bot_paciente_contexto(text) from public, anon, authenticated;
grant execute on function public.helios_patient_decision(uuid, text, text, text) to service_role;
grant execute on function public.bot_paciente_resumen(uuid) to service_role;
grant execute on function public.bot_paciente_contexto(text) to service_role;
