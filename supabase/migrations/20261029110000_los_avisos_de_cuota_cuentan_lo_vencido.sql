-- ============================================================================
-- Helios — Los avisos de cuota cuentan lo vencido (2026-10-29)
--
-- Textos aprobados por Javier el 2026-10-29. Hasta hoy cada aviso de cuota
-- hablaba SOLO de las cuotas de su fecha: a quien debía la cuota 1, el aviso
-- de la cuota 2 no le decía nada de ella (y si pagaba lo que el aviso decía,
-- el pago no se podía aplicar a la 2: lo vencido va primero,
-- `helios_quote_installments`). Ahora:
--
--   Caso 1 · 3 días antes, mañana y hoy, con otra cuota vencida: «⚠️ También
--            tienes 1 cuota vencida…», y el bloque de pago con dos montos:
--            para ponerte al día y para pagar todo de una vez.
--   Caso 2 · Cuota vencida cuando ya debía otra: «Con ella tienes 2 cuotas
--            pendientes por…», «Puedes pagar las dos de una vez o empezar por
--            la más antigua», y el bloque con la más antigua y el total.
--   Caso 4 · Pago confirmado con algo aún vencido (de cualquier orden):
--            «⚠️ Aún tienes 1 cuota vencida…» y el botón «Pagar mi cuota».
--   Caso 5 · Varias cuotas el mismo día: «tus 2 cuotas de $113,92 de las
--            consultas con…» (y el verbo en plural).
--   (El caso 3, «Pagar mi cuota» en el bot, va en la Edge Function.)
--
-- Lo vencido: cuotas pendientes, de órdenes confirmadas, que vencieron antes
-- de hoy, sin pagar ni dar por perdidas, y sin un pago esperando revisión
-- (`helios_vencidas_de`).
--
-- Las plantillas de Meta: cuando hay algo vencido, el WhatsApp fuera de la
-- ventana de 24 h usa `cuota_con_vencidas` (caso 1) o `cuotas_vencidas`
-- (caso 2), dos filas nuevas que solo guardan la plantilla de Meta. Nacen sin
-- `wa_template_name`: hasta que Meta las apruebe y se conecten (docs/00
-- §15.10), sale la plantilla de siempre, sin lo vencido. El texto libre y el
-- correo ya lo dicen desde hoy.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Ayudantes
-- ---------------------------------------------------------------------------

-- «lunes 26/10».
create or replace function public.helios_dia_text(p_day date)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select public.helios_weekday_es(p_day) || ' ' || to_char(p_day, 'DD/MM');
$$;

-- «dólar», «euro» o «dólar y del euro», para «a la tasa BCV del …».
create or replace function public.helios_moneda_de(p_usd numeric, p_eur numeric)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case when coalesce(p_eur, 0) = 0 then 'dólar'
              when coalesce(p_usd, 0) = 0 then 'euro'
              else 'dólar y del euro' end;
$$;

-- Los bolívares de hoy de lo que va en cada moneda; null sin tasa.
create or replace function public.helios_bs_de(p_usd numeric, p_eur numeric, p_day date)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  return (public.helios_bolivares(coalesce(p_usd, 0), coalesce(p_eur, 0), p_day)->>'amount_ves')::numeric;
exception when sqlstate 'P0002' then
  return null;
end;
$$;

-- Lo vencido de un paciente (ver arriba), sin las cuotas de `p_excluir_fecha`
-- ni las de `p_excluir_ids`. Lo de dólares (cuotas en dólares y todo cargo por
-- atraso) y lo de la otra moneda, por separado; con la más antigua aparte.
create or replace function public.helios_vencidas_de(
  p_user uuid, p_hoy date, p_excluir_fecha date default null, p_excluir_ids uuid[] default null)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with v as (
    select i.due_date,
           case when c.currency = 'EUR' then 0 else coalesce(i.amount_cur, i.amount_usd) end
             + coalesce((select sum(f.amount_usd) from public.late_fees f
                          where f.installment_id = i.id and f.status = 'pending'), 0) as usd,
           case when c.currency = 'EUR' then coalesce(i.amount_cur, i.amount_usd) else 0 end as eur
    from public.installments i
    join public.charges c on c.id = i.charge_id and c.status = 'confirmed'
    where i.user_id = p_user
      and i.status = 'pending'
      and i.written_off_at is null
      and i.due_date < p_hoy
      and (p_excluir_fecha is null or i.due_date <> p_excluir_fecha)
      and not (i.id = any (coalesce(p_excluir_ids, '{}'::uuid[])))
      and not exists (
        select 1
        from public.payment_quote_items qi
        join public.payment_reports r on r.quote_id = qi.quote_id
        where qi.installment_id = i.id
          and r.status in ('reported', 'in_review'))
  ), a as (select min(due_date) as d from v)
  select jsonb_build_object(
    'n', count(*),
    'usd', coalesce(sum(v.usd), 0),
    'eur', coalesce(sum(v.eur), 0),
    'antigua', (select d from a),
    'n_antigua', count(*) filter (where v.due_date = (select d from a)),
    'antigua_usd', coalesce(sum(v.usd) filter (where v.due_date = (select d from a)), 0),
    'antigua_eur', coalesce(sum(v.eur) filter (where v.due_date = (select d from a)), 0))
  from v;
$$;

-- El bloque de pago con dos montos (casos 1 y 2): el primero con su título y
-- su explicación, el segundo «para pagar todo de una vez». Null si falta una
-- tasa (el que llama cae al bloque de un monto).
create or replace function public.helios_payment_block_doble(
  p_titulo1 text, p_bs1 numeric, p_desc1 text, p_bs2 numeric, p_desc2 text,
  p_por text default 'por este chat')
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case when p_bs1 is null or p_bs2 is null then null else
    concat_ws(E'\n\n',
      format(E'💵 *%s: %s*\n%s', p_titulo1, public.helios_ves_text(p_bs1), p_desc1),
      format(E'💰 *Para pagar todo de una vez hoy: %s*\n%s', public.helios_ves_text(p_bs2), p_desc2),
      'Si pagas otro día, paga el equivalente a la tasa BCV de ese día.',
      public.helios_payment_accounts_block(),
      format('📸 Cuando pagues, envíanos la foto del comprobante %s.', coalesce(p_por, 'por este chat')),
      public.helios_level_reminder())
  end;
$$;

-- La plantilla de Meta de una fila de `notification_templates`, resuelta con
-- unas variables (como en `helios_enqueue_message`). Null si la fila no tiene
-- plantilla conectada o si falta una variable.
create or replace function public.helios_wa_template_for(p_key text, p_vars jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_tpl     public.notification_templates%rowtype;
  v_params  jsonb;
  v_buttons jsonb;
begin
  select * into v_tpl from public.notification_templates where key = p_key;
  if not found or nullif(btrim(v_tpl.wa_template_name), '') is null or not v_tpl.enabled then
    return null;
  end if;
  if exists (select 1 from unnest(v_tpl.wa_template_params) k where not (p_vars ? k)) then
    return null;
  end if;

  select coalesce(jsonb_agg(
           regexp_replace(regexp_replace(coalesce(p_vars ->> k, ''), '[\r\n\t]+', ' ', 'g'), ' {2,}', ' ', 'g')
           order by i), '[]'::jsonb)
    into v_params
  from unnest(v_tpl.wa_template_params) with ordinality as u(k, i);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', public.render_notification_text(b ->> 'id', p_vars),
           'title', left(b ->> 'title', 20)) order by i), '[]'::jsonb)
    into v_buttons
  from jsonb_array_elements(v_tpl.wa_buttons) with ordinality as e(b, i);

  return jsonb_build_object('name', v_tpl.wa_template_name, 'language', v_tpl.wa_template_lang,
                            'params', v_params, 'buttons', v_buttons);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Las dos plantillas de Meta de los casos 1 y 2 (solo la plantilla: el
--    texto libre y el correo salen de los avisos de siempre)
-- ---------------------------------------------------------------------------

insert into public.notification_templates
  (key, label, trigger_label, help, variables, required_variables, default_title, default_body,
   enabled, editable, can_disable, sort_order, channels, wa_template_name, wa_template_lang,
   wa_template_params, wa_buttons)
values
  ('cuota_con_vencidas',
   'Plantilla de Meta: cuota por vencer con otra vencida',
   'En vez de la plantilla de 3 días antes, mañana u hoy, si el paciente debe una cuota vencida',
   'Solo la plantilla de Meta (fuera de la ventana de 24 h). El texto del WhatsApp y del correo es el del aviso de cada día.',
   '{texto}', '{}', 'Helios', '{texto}', true, false, false, 920, '{whatsapp}', null, 'es',
   array['nombre', 'monto', 'medico', 'cuando', 'vencidas_texto', 'bs_al_dia', 'al_dia_texto',
         'moneda_al_dia', 'bs_total', 'total_texto', 'pago_movil_banco', 'pago_movil_telefono', 'pago_movil_rif'],
   '[{"id":"paciente:ya_pague","title":"Ya pagué"},{"id":"paciente:ayuda","title":"Hablar con alguien"}]'),
  ('cuotas_vencidas',
   'Plantilla de Meta: cuota vencida con otra ya vencida',
   'En vez de la plantilla de cuota vencida, si el paciente ya debía otra cuota',
   'Solo la plantilla de Meta (fuera de la ventana de 24 h). El texto del WhatsApp y del correo es el del aviso de cuota vencida.',
   '{texto}', '{}', 'Helios', '{texto}', true, false, false, 921, '{whatsapp}', null, 'es',
   array['nombre', 'monto', 'medico', 'fecha', 'pendientes_texto', 'bs_antigua', 'fecha_antigua',
         'monto_antigua', 'moneda_antigua', 'bs_total', 'total_texto', 'pago_movil_banco',
         'pago_movil_telefono', 'pago_movil_rif'],
   '[{"id":"paciente:ya_pague","title":"Ya pagué"},{"id":"paciente:ayuda","title":"Hablar con alguien"}]')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 3. Los textos de los cuatro avisos
-- ---------------------------------------------------------------------------

update public.notification_templates
   set default_body = case key
     when 'cuota_en_3_dias' then
          E'Hola, {nombre} 👋 Te recordamos que {tu_cuota} {vence} el {fecha}.{aviso_vencidas}\n\n'
       || '{bloque_de_pago}'
     when 'cuota_manana' then
          E'Hola, {nombre} 👋 Mañana, {fecha}, {vence} {tu_cuota}.{aviso_vencidas}\n\n'
       || '{bloque_de_pago}'
     when 'cuota_hoy' then
          E'¡Buenos días, {nombre}! ☀️ Hoy, {fecha}, {vence} {tu_cuota}.{aviso_vencidas}\n\n'
       || E'{bloque_de_pago}\n\n'
       || 'Si ya pagaste, ¡gracias! Puedes ignorar este mensaje.'
     when 'cuota_vencida_d1' then
          'Hola, {nombre}. {tu_cuota_inicio} {vencio} ayer, {fecha}{situacion_vencida}{aviso_cargo_atraso}{opciones_vencidas}'
       || E'\n\n{bloque_de_pago}\n\n'
       || 'Si tienes algún inconveniente, escríbenos {por_whatsapp} y lo resolvemos juntos.'
   end,
       variables = (select array_agg(distinct v order by v)
                    from unnest(variables || array['tu_cuota', 'tu_cuota_inicio', 'vence', 'vencio',
                                                   'aviso_vencidas', 'aviso_vencidas_html',
                                                   'situacion_vencida', 'opciones_vencidas']) v),
       required_variables = case key
         when 'cuota_hoy'        then array['tu_cuota', 'bloque_de_pago']
         when 'cuota_vencida_d1' then array['tu_cuota_inicio', 'fecha', 'bloque_de_pago']
         else array['tu_cuota', 'fecha', 'bloque_de_pago'] end
 where key in ('cuota_en_3_dias', 'cuota_manana', 'cuota_hoy', 'cuota_vencida_d1');

-- El correo: lo vencido va justo después del saludo.
do $$
declare
  r     record;
  v_ini integer;
  v_fin integer;
begin
  for r in select key, default_html from public.notification_templates
            where key in ('cuota_en_3_dias', 'cuota_manana', 'cuota_hoy', 'cuota_vencida_d1')
              and default_html is not null and position('{aviso_vencidas_html}' in default_html) = 0
  loop
    v_ini := position('Hola, {nombre}</h1>' in r.default_html);
    continue when v_ini = 0;
    v_fin := v_ini + position('</p>' in substr(r.default_html, v_ini)) + 3;
    update public.notification_templates
       set default_html = left(r.default_html, v_fin - 1) || '{aviso_vencidas_html}' || substr(r.default_html, v_fin)
     where key = r.key;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Los avisos
-- ---------------------------------------------------------------------------

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
                    when 'cuota_en_3_dias' then 'vence el ' || public.helios_dia_text(v_due)
                    when 'cuota_manana'    then 'vence mañana, ' || public.helios_dia_text(v_due)
                    else 'vence hoy, ' || public.helios_dia_text(v_due) end,
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

-- ---------------------------------------------------------------------------
-- 5. Caso 4: el pago confirmado dice lo que aún está vencido
-- ---------------------------------------------------------------------------

create or replace function public.helios_payment_result_whatsapp(p_report_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_r        public.payment_reports%rowtype;
  v_q        public.payment_quotes%rowtype;
  v_nombre   text;
  v_ordenes  text;
  v_n        integer;
  v_meds     text;
  v_eur_usd  numeric(18,4);
  v_txt      text;
  v_resto    text;
  v_sig      record;
  v_pagadas  uuid[];
  v_venc     jsonb;
  v_nv       integer;
  v_completa boolean;
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

  -- (2026-10-23): primero las gracias.
  v_txt := format(E'✅ ¡Gracias por tu pago%s! Ya está confirmado 💙\nRecibimos %s de %s #%s con %s.',
                  coalesce(', ' || v_nombre, ''),
                  public.helios_amounts_label(v_q.amount_usd - v_eur_usd, v_q.amount_eur),
                  case when v_n > 1 then 'tus órdenes' else 'tu orden' end,
                  coalesce(v_ordenes, ''), v_meds);

  v_pagadas := array(select qi.installment_id from public.payment_quote_items qi where qi.quote_id = v_r.quote_id);

  -- ¿Terminó de pagar las órdenes de este pago?
  v_completa := not exists (
    select 1 from public.installments i
    where i.charge_id in (select i2.charge_id from public.installments i2 where i2.id = any (v_pagadas))
      and i.status = 'pending' and i.written_off_at is null
      and not (i.id = any (v_pagadas)));

  -- NUEVO (2026-10-29), caso 4: lo que aún está vencido, de cualquier orden.
  v_venc := public.helios_vencidas_de(v_r.user_id, public.helios_business_date(now()), null, v_pagadas);
  v_nv   := (v_venc->>'n')::integer;

  if v_nv > 0 then
    v_resto := case when v_nv = 1
      then format('⚠️ Aún tienes 1 cuota vencida: %s (venció el %s). Cuando la pagues, tu cuenta se reactiva.',
                  public.helios_amounts_label((v_venc->>'usd')::numeric, (v_venc->>'eur')::numeric),
                  public.helios_dia_text((v_venc->>'antigua')::date))
      else format('⚠️ Aún tienes %s cuotas vencidas por %s (la más antigua venció el %s). Cuando las pagues, tu cuenta se reactiva.',
                  v_nv, public.helios_amounts_label((v_venc->>'usd')::numeric, (v_venc->>'eur')::numeric),
                  public.helios_dia_text((v_venc->>'antigua')::date)) end;
    if v_completa then
      v_resto := format(E'🎉 ¡Terminaste de pagar %s!\n\n',
                        case when v_n > 1 then 'esas consultas' else 'esa consulta' end) || v_resto;
    end if;
  else
    -- Lo que viene, de cualquier orden.
    select i.sequence, i.due_date, coalesce(i.amount_cur, i.amount_usd) as monto, c.currency,
           count(*) over () as quedan
      into v_sig
    from public.installments i
    join public.charges c on c.id = i.charge_id and c.status = 'confirmed'
    where i.user_id = v_r.user_id
      and i.status = 'pending' and i.written_off_at is null
      and not (i.id = any (v_pagadas))
    order by i.due_date, i.sequence
    limit 1;

    if v_sig is null or v_sig.sequence is null then
      v_resto := format('🎉 ¡Terminaste de pagar %s! Gracias por confiar en Helios para cuidar tu salud.',
                        case when v_n > 1 then 'tus consultas' else 'tu consulta' end);
    elsif v_sig.quedan = 1 then
      v_resto := case when v_completa then format(E'🎉 ¡Terminaste de pagar %s!\n\n',
                                                  case when v_n > 1 then 'esas consultas' else 'esa consulta' end) else '' end
                 || format('Te queda: %s.ª cuota de %s · %s', v_sig.sequence,
                           public.helios_money_cur_text(v_sig.monto, v_sig.currency),
                           public.helios_dia_text(v_sig.due_date));
    else
      v_resto := case when v_completa then format(E'🎉 ¡Terminaste de pagar %s!\n\n',
                                                  case when v_n > 1 then 'esas consultas' else 'esa consulta' end) else '' end
                 || format('Tu próxima cuota: %s · %s',
                           public.helios_money_cur_text(v_sig.monto, v_sig.currency),
                           public.helios_dia_text(v_sig.due_date));
    end if;
  end if;

  -- (2026-10-23): cierra con la frase de niveles.
  return v_txt || E'\n\n' || v_resto || E'\n\n' || public.helios_level_up_phrase();
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

  -- (2026-10-19): también por WhatsApp, solo con la ventana abierta (texto
  -- libre, sin plantilla: no cuesta). Con la ventana cerrada, solo el correo.
  -- NUEVO (2026-10-29): si aún debe algo vencido, con «Pagar mi cuota».
  if v_tpl.enabled then
    perform public.helios_tell_patient(
      new.user_id, public.helios_payment_result_whatsapp(new.id),
      case
        when new.status = 'rejected'
          then '[{"id":"paciente:ayuda","title":"Hablar con alguien"}]'::jsonb
        when (public.helios_vencidas_de(new.user_id, public.helios_business_date(now()), null,
                array(select qi.installment_id from public.payment_quote_items qi
                       where qi.quote_id = new.quote_id))->>'n')::integer > 0
          then '[{"id":"paciente:pagar","title":"Pagar mi cuota"}]'::jsonb
        else '[]'::jsonb end);
  end if;

  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------

revoke all on function public.helios_dia_text(date) from public, anon, authenticated;
revoke all on function public.helios_moneda_de(numeric, numeric) from public, anon, authenticated;
revoke all on function public.helios_bs_de(numeric, numeric, date) from public, anon, authenticated;
revoke all on function public.helios_vencidas_de(uuid, date, date, uuid[]) from public, anon, authenticated;
revoke all on function public.helios_payment_block_doble(text, numeric, text, numeric, text, text) from public, anon, authenticated;
revoke all on function public.helios_wa_template_for(text, jsonb) from public, anon, authenticated;
