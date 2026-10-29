-- ============================================================================
-- Helios — La plantilla de cuota con vencidas separa sus variables (2026-10-29)
--
-- Meta rechazó `helios_cuota_con_vencidas`: «Two variables cannot be next to
-- each other» («…de la consulta con {{3}} {{4}}.»). El texto pasa a ser «…con
-- {{3}} vence {{4}}.», así que la variable `cuando` ya no lleva el verbo:
-- «el lunes 02/11», «mañana, lunes 02/11», «hoy, lunes 02/11». Lo demás de
-- `helios_enqueue_reminders` no cambia (20261029110000).
-- ============================================================================

create or replace function public.helios_enqueue_reminders(p_key text, p_today date default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tpl      public.notification_templates%rowtype;
  v_today    date := coalesce(p_today, public.helios_business_date(now()));
  v_offset   integer;
  v_due      date;
  v_row      record;
  v_channel  text;
  v_id       uuid;
  v_new      integer := 0;
  v_errors   integer := 0;
  v_before   integer;
  v_ves      numeric;
  v_monto    text;
  v_moneda   text;
  v_venc     jsonb;
  v_nv       integer;
  v_vusd     numeric;
  v_veur     numeric;
  v_vlabel   text;
  v_tusd     numeric;
  v_teur     numeric;
  v_ntot     integer;
  v_tlabel   text;
  v_tu       text;
  v_extra    jsonb;
  v_bloque   text;
  v_variante text;
  v_vars     jsonb;
  v_wa       jsonb;
  v_html     text;
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
      count(*)                                          as n_cuotas,
      count(distinct q.charge_id)                       as cargos,
      min(q.charge_id::text)::uuid                      as un_cargo,
      string_agg(distinct q.order_number::text, ', #')  as ordenes,
      count(distinct q.merchant_id)                     as clinicas,
      min(q.merchant_name)                              as una_clinica,
      -- «la Dra. Nadia Khabbaze» (o los médicos, con «y»).
      string_agg(distinct public.helios_doctor_ref(q.merchant_id), ' y ') as medicos
    from cuotas q
    join public.profiles p on p.id = q.user_id
    -- El aviso del cargo solo sale si el cargo ya se cobró.
    where p_key <> 'cargo_por_atraso_d4' or q.fee_usd > 0
    group by q.user_id, p.email, p.email_invalid_at, p.phone_e164
    order by q.user_id
  loop
    -- Lo de esta fecha.
    v_ves    := public.helios_bs_de(v_row.monto_usd, v_row.monto_eur, v_today);
    v_monto  := public.helios_amounts_label(v_row.monto_usd, v_row.monto_eur);
    v_moneda := public.helios_moneda_de(v_row.monto_usd, v_row.monto_eur);

    -- Caso 5: una cuota o varias el mismo día.
    v_tu := case when v_row.n_cuotas = 1
                 then format('tu cuota de %s de la consulta con %s', v_monto, v_row.medicos)
                 else format('tus %s cuotas de %s de las consultas con %s', v_row.n_cuotas, v_monto, v_row.medicos) end;

    -- Lo vencido de otras fechas (casos 1 y 2).
    v_venc  := public.helios_vencidas_de(v_row.user_id, v_today, v_due, null);
    v_nv    := (v_venc->>'n')::integer;
    v_vusd  := (v_venc->>'usd')::numeric;
    v_veur  := (v_venc->>'eur')::numeric;
    v_vlabel := public.helios_amounts_label(v_vusd, v_veur);
    v_tusd  := v_vusd + v_row.monto_usd;
    v_teur  := v_veur + v_row.monto_eur;
    v_ntot  := v_nv + v_row.n_cuotas;
    v_tlabel := public.helios_amounts_label(v_tusd, v_teur);

    v_bloque   := null;
    v_variante := null;
    v_extra := jsonb_build_object(
      'aviso_vencidas', '', 'aviso_vencidas_html', '',
      'situacion_vencida', case when v_row.n_cuotas = 1
        then ', y sigue pendiente. Sabemos que a veces pasa 💙 Mientras esté pendiente no podrás pagar nuevas consultas en cuotas; en cuanto pagues, se reactiva.'
        else ', y siguen pendientes. Sabemos que a veces pasa 💙 Mientras estén pendientes no podrás pagar nuevas consultas en cuotas; en cuanto pagues, se reactiva.' end,
      'opciones_vencidas', '');

    if v_nv > 0 and p_key in ('cuota_en_3_dias', 'cuota_manana', 'cuota_hoy') then
      -- Caso 1: viene una cuota y debe otra.
      v_bloque := public.helios_payment_block_doble(
        'Para ponerte al día hoy', public.helios_bs_de(v_vusd, v_veur, v_today),
        format('Es %s (%s) a la tasa BCV del %s de hoy.',
               case when v_nv = 1 then 'tu cuota vencida' else format('tus %s cuotas vencidas', v_nv) end,
               v_vlabel, public.helios_moneda_de(v_vusd, v_veur)),
        public.helios_bs_de(v_tusd, v_teur, v_today),
        format('Son tus %s cuotas (%s).', v_ntot, v_tlabel),
        public.helios_por_whatsapp('whatsapp'));
      v_extra := v_extra || jsonb_build_object(
        'aviso_vencidas', E'\n\n⚠️ También tienes '
          || case when v_nv = 1
                  then format('1 cuota vencida de %s (venció el %s). Te recomendamos pagarla primero para ponerte al día 💙',
                              v_vlabel, public.helios_dia_text((v_venc->>'antigua')::date))
                  else format('%s cuotas vencidas por %s (la más antigua venció el %s). Te recomendamos pagarlas primero para ponerte al día 💙',
                              v_nv, v_vlabel, public.helios_dia_text((v_venc->>'antigua')::date)) end,
        'aviso_vencidas_html',
          '<p style="margin:12px 0 0 0;font-family:''Source Sans 3'',''Segoe UI'',Arial,Helvetica,sans-serif;font-size:16px;line-height:24px;color:#5E3000;">&#9888;&#65039; <strong>'
          || case when v_nv = 1 then format('También tienes 1 cuota vencida de %s</strong> (venció el %s).', v_vlabel,
                                            public.helios_dia_text((v_venc->>'antigua')::date))
                  else format('También tienes %s cuotas vencidas por %s</strong> (la más antigua venció el %s).', v_nv, v_vlabel,
                              public.helios_dia_text((v_venc->>'antigua')::date)) end
          || coalesce(format(' Para ponerte al día hoy: <strong>%s</strong>. Para pagar todo de una vez hoy: <strong>%s</strong> (tus %s cuotas, %s).',
                             public.helios_ves_text(public.helios_bs_de(v_vusd, v_veur, v_today)),
                             public.helios_ves_text(public.helios_bs_de(v_tusd, v_teur, v_today)), v_ntot, v_tlabel), '')
          || '</p>',
        -- Para la plantilla de Meta.
        'cuando', case p_key
                    when 'cuota_en_3_dias' then 'el ' || public.helios_dia_text(v_due)
                    when 'cuota_manana'    then 'mañana, ' || public.helios_dia_text(v_due)
                    else 'hoy, ' || public.helios_dia_text(v_due) end,
        'vencidas_texto', case when v_nv = 1
                    then format('1 cuota vencida de %s (venció el %s)', v_vlabel, public.helios_dia_text((v_venc->>'antigua')::date))
                    else format('%s cuotas vencidas por %s (la más antigua venció el %s)', v_nv, v_vlabel,
                                public.helios_dia_text((v_venc->>'antigua')::date)) end,
        'bs_al_dia', coalesce(public.helios_ves_text(public.helios_bs_de(v_vusd, v_veur, v_today)), 'el equivalente en bolívares'),
        'al_dia_texto', format('%s (%s)', case when v_nv = 1 then 'tu cuota vencida' else format('tus %s cuotas vencidas', v_nv) end, v_vlabel),
        'moneda_al_dia', public.helios_moneda_de(v_vusd, v_veur),
        'bs_total', coalesce(public.helios_ves_text(public.helios_bs_de(v_tusd, v_teur, v_today)), 'el equivalente en bolívares'),
        'total_texto', format('tus %s cuotas (%s)', v_ntot, v_tlabel));
      v_variante := 'cuota_con_vencidas';

    elsif v_nv > 0 and p_key = 'cuota_vencida_d1' then
      -- Caso 2: se vence una cuota y ya debía otra.
      v_bloque := public.helios_payment_block_doble(
        'Para pagar la más antigua hoy',
        public.helios_bs_de((v_venc->>'antigua_usd')::numeric, (v_venc->>'antigua_eur')::numeric, v_today),
        format('Es %s del %s (%s) a la tasa BCV del %s de hoy.',
               case when (v_venc->>'n_antigua')::integer = 1 then 'tu cuota' else 'tus cuotas' end,
               public.helios_dia_text((v_venc->>'antigua')::date),
               public.helios_amounts_label((v_venc->>'antigua_usd')::numeric, (v_venc->>'antigua_eur')::numeric),
               public.helios_moneda_de((v_venc->>'antigua_usd')::numeric, (v_venc->>'antigua_eur')::numeric)),
        public.helios_bs_de(v_tusd, v_teur, v_today),
        format('Son tus %s cuotas (%s).', v_ntot, v_tlabel),
        public.helios_por_whatsapp('whatsapp'));
      v_extra := v_extra || jsonb_build_object(
        'situacion_vencida', format('. Con %s tienes %s cuotas pendientes por %s. Sabemos que a veces pasa 💙 Mientras estén pendientes no podrás pagar nuevas consultas en cuotas; en cuanto te pongas al día, se reactiva.',
                                    case when v_row.n_cuotas = 1 then 'ella' else 'ellas' end, v_ntot, v_tlabel),
        'opciones_vencidas', format(E'\n\nPuedes pagar %s de una vez o empezar por la más antigua.',
                                    case when v_ntot = 2 then 'las dos' else 'todas' end),
        'aviso_vencidas_html',
          '<p style="margin:12px 0 0 0;font-family:''Source Sans 3'',''Segoe UI'',Arial,Helvetica,sans-serif;font-size:16px;line-height:24px;color:#5E3000;">&#9888;&#65039; <strong>'
          || format('Con esta cuota tienes %s cuotas pendientes por %s.</strong> Puedes pagar %s de una vez o empezar por la más antigua.',
                    v_ntot, v_tlabel, case when v_ntot = 2 then 'las dos' else 'todas' end)
          || coalesce(format(' Para pagar la más antigua (la del %s) hoy: <strong>%s</strong>. Para pagar todo de una vez hoy: <strong>%s</strong>.',
                             public.helios_dia_text((v_venc->>'antigua')::date),
                             public.helios_ves_text(public.helios_bs_de((v_venc->>'antigua_usd')::numeric, (v_venc->>'antigua_eur')::numeric, v_today)),
                             public.helios_ves_text(public.helios_bs_de(v_tusd, v_teur, v_today))), '')
          || '</p>',
        -- Para la plantilla de Meta.
        'pendientes_texto', format('%s cuotas pendientes por %s', v_ntot, v_tlabel),
        'bs_antigua', coalesce(public.helios_ves_text(public.helios_bs_de((v_venc->>'antigua_usd')::numeric,
                                                                          (v_venc->>'antigua_eur')::numeric, v_today)),
                               'el equivalente en bolívares'),
        'fecha_antigua', public.helios_dia_text((v_venc->>'antigua')::date),
        'monto_antigua', public.helios_amounts_label((v_venc->>'antigua_usd')::numeric, (v_venc->>'antigua_eur')::numeric),
        'moneda_antigua', public.helios_moneda_de((v_venc->>'antigua_usd')::numeric, (v_venc->>'antigua_eur')::numeric),
        'bs_total', coalesce(public.helios_ves_text(public.helios_bs_de(v_tusd, v_teur, v_today)), 'el equivalente en bolívares'),
        'total_texto', format('tus %s cuotas (%s)', v_ntot, v_tlabel));
      v_variante := 'cuotas_vencidas';
    end if;

    foreach v_channel in array v_tpl.channels loop
      continue when v_channel not in ('whatsapp', 'whatsapp_manual', 'email');
      -- Sin correo válido no se encola el correo (el WhatsApp sí).
      continue when v_channel = 'email' and (v_row.email is null or v_row.email_invalid_at is not null);

      begin
        v_vars := jsonb_build_object(
            'clinica', case when v_row.clinicas = 1 then v_row.una_clinica
                            else format('%s clínicas', v_row.clinicas) end,
            'orden', v_row.ordenes,
            'monto_cuota', public.helios_amounts_text(v_row.monto_usd, v_row.monto_eur, v_today),
            'fecha', public.helios_dia_text(v_due),
            -- La tasa con la que paga (20261008000300): la de la moneda de sus
            -- cuotas. Un cargo por atraso va en dólares, así que una cuota en
            -- euros con cargo cuenta como las dos.
            'moneda', case
              when v_row.monto_eur = 0 then 'dólar'
              when v_row.monto_usd = 0 then 'euro'
              else 'dólar o del euro, según la moneda de cada cuota,'
            end,
            'medico', v_row.medicos,
            -- En las plantillas de Meta el texto es fijo («tu cuota de {{2}}»):
            -- con varias cuotas, el monto lo dice (caso 5).
            'monto', v_monto || case when v_row.n_cuotas > 1 then format(' (%s cuotas)', v_row.n_cuotas) else '' end,
            'monto_bs', coalesce(public.helios_ves_text(v_ves), 'el equivalente en bolívares'),
            'tu_cuota', v_tu,
            'tu_cuota_inicio', upper(left(v_tu, 1)) || substr(v_tu, 2),
            'vence', case when v_row.n_cuotas = 1 then 'vence' else 'vencen' end,
            'vencio', case when v_row.n_cuotas = 1 then 'venció' else 'vencieron' end,
            'bloque_de_pago', coalesce(
              case when v_bloque is not null and v_channel = 'email'
                   then replace(v_bloque, 'el comprobante por este chat', 'el comprobante ' || public.helios_por_whatsapp('email'))
                   else v_bloque end,
              public.helios_payment_block(v_ves, v_monto, v_moneda, public.helios_por_whatsapp(v_channel)))
          ) || v_extra;

        v_id := public.helios_enqueue_message(
          p_key, v_row.user_id,
          case when v_row.cargos = 1 then v_row.un_cargo end,
          v_channel, v_vars, v_due,
          format('%s:%s:%s:%s', p_key, v_channel, v_row.user_id, v_due)
        );

        -- Con algo vencido, fuera de la ventana sale la plantilla que lo dice
        -- (si ya está conectada; si no, la de siempre).
        if v_variante is not null and v_channel = 'whatsapp' then
          v_wa := public.helios_wa_template_for(v_variante, public.helios_message_builtins(v_row.user_id) || v_vars);
          if v_wa is not null then
            update public.outbound_messages set wa_template = v_wa
             where id = v_id and status = 'pendiente';
          end if;
        end if;
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
