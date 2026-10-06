-- ============================================================================
-- Helios — El paciente tiene su bot, y los mensajes hablan como en Venezuela
-- (decisiones de Javier del 2026-10-06; docs/00 §15.6, docs/01 §4.2 y §5.5)
--
-- 1. Los montos de los mensajes en formato venezolano: «$100», «$1,92»,
--    «$1.250,50» (`helios_money_text`, que usan WhatsApp, el correo y los
--    textos de error). El panel formatea por su cuenta.
-- 2. La pregunta al paciente (`confirmar_financiamiento`) y la bienvenida
--    con los textos nuevos. Al PACIENTE sí se le enseña el total con el cargo
--    por servicio (cambio de regla del 2026-10-06); a la clínica, nunca. Los
--    porcentajes son variables: el cargo va a cambiar.
--    La plantilla de Meta aprobada (`helios_confirmar_financiamiento`) sigue
--    con sus 6 variables hasta que se apruebe la v2 (docs/00 §15.5).
-- 3. El bot del paciente: si un paciente escribe, el mensaje genérico con
--    tres botones (Pagar cuota, Ver financiamientos, Ayuda). Lo que recuerda
--    de cada número vive en `whatsapp_contacts` (cuándo le mostró el menú,
--    hasta cuándo lo atiende una persona, a quién identificó si el teléfono es
--    de varios pacientes). Sus lecturas son solo para el webhook.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Montos en formato venezolano
-- ---------------------------------------------------------------------------

/**
 * 🔁 (20261002000700) Un monto en dólares como texto de mensaje, al estilo
 * venezolano: «100», «1,92», «1.250,50» (sin «,00» si es entero).
 */
create or replace function public.helios_money_text(p_amount numeric)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case
    when v = trunc(v) then translate(to_char(trunc(v), 'FM999,999,999,990'), ',', '.')
    else translate(to_char(v, 'FM999,999,999,990.00'), ',.', '.,')
  end
  from (select round(coalesce(p_amount, 0), 2) as v) x;
$$;

/** Un porcentaje para un mensaje: «20», «12,5». */
create or replace function public.helios_pct_text(p_pct numeric)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select replace(rtrim(rtrim(to_char(round(coalesce(p_pct, 0), 2), 'FM990.00'), '0'), '.'), '.', ',');
$$;

revoke all on function public.helios_pct_text(numeric) from public, anon;
grant execute on function public.helios_pct_text(numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Los mensajes al paciente
-- ---------------------------------------------------------------------------

update public.notification_templates
   set default_body =
         E'👋 Hola, {nombre}. Bienvenido a Helios 💙\n\n'
         || E'{clinica} registró tu consulta de ${monto_consulta} para pagarla en 2 cuotas, sin inicial.\n\n'
         || E'* Consulta: ${monto_consulta}\n'
         || E'* Servicio Helios ({servicio_pct}%): ${cargo_servicio}\n'
         || E'* IVA ({iva_pct}% sobre el servicio): ${iva_cargo_servicio}\n'
         || E'* Total: ${total}\n\n'
         || E'Tus cuotas serán de {cuotas_monto}:\n'
         || E'📅 {cuotas_fechas}\n\n'
         || E'¿Confirmas tu financiamiento? Responde Sí o No.\n'
         || 'Tienes 2 horas para confirmar.',
       variables = array['nombre', 'clinica', 'monto_consulta', 'servicio_pct', 'cargo_servicio', 'iva_pct',
                         'iva_cargo_servicio', 'total', 'cuotas_monto', 'cuotas_fechas', 'cuotas_linea', 'orden', 'vence'],
       required_variables = array['clinica', 'monto_consulta', 'servicio_pct', 'cargo_servicio', 'iva_pct',
                                  'iva_cargo_servicio', 'total', 'cuotas_monto', 'cuotas_fechas'],
       help = 'La pregunta al paciente: ¿acepta? Botones Sí / No. Al paciente sí se le enseña el total con el cargo por servicio. Es la plantilla aprobada en Meta: el texto no se edita aquí.',
       wa_buttons = jsonb_build_array(
         jsonb_build_object('id', 'confirmar:{charge_id}', 'title', 'Sí'),
         jsonb_build_object('id', 'rechazar:{charge_id}',  'title', 'No'))
 where key = 'confirmar_financiamiento';

update public.notification_templates
   set default_body =
         E'🩺 ¡Listo, {nombre}! Tu financiamiento #{orden} ya está activo.\n\n'
         || E'Tus pagos:\n{cuotas}\n\n'
         || E'Puedes pagar en bolívares a tasa BCV del día o en efectivo en divisas.\n\n'
         || 'Te escribiremos por aquí cuando se acerque cada pago con las instrucciones. Cuando pagues, solo envíanos el comprobante por este chat. 💙',
       variables = array['nombre', 'clinica', 'orden', 'cuotas'],
       required_variables = array['orden', 'cuotas']
 where key = 'bienvenida';

insert into public.notification_templates
  (key, type, channels, label, trigger_label, help, variables, required_variables,
   default_title, default_body, enabled, editable, can_disable, sort_order)
values (
  'bot_paciente', null, '{whatsapp}', 'Bot del paciente',
  'Cuando un paciente le escribe a Helios',
  'Lo que el bot le responde a un paciente (o a quien escriba sin ser médico). Siempre dentro de su ventana de 24 h.',
  array['texto'], array['texto'],
  'Helios', '{texto}', true, false, false, 910
)
on conflict (key) do nothing;

/**
 * 🔁 (20261005000300) La pregunta al paciente con las variables nuevas: los
 * porcentajes, el total con el cargo por servicio (solo al paciente), el
 * monto de las cuotas y sus fechas. Conserva las de la plantilla v1 de Meta
 * (`cuotas_linea`…) mientras se aprueba la v2.
 */
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
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found or v_c.status <> 'pending' then
    raise exception 'La orden no está esperando al paciente' using errcode = '22023';
  end if;

  v_plan := public.helios_charge_planned_installments(p_charge_id);

  -- En una sola línea: Meta no admite saltos de línea en una variable.
  select string_agg(format('$%s el %s', public.helios_money_text((x->>'amount_usd')::numeric),
                           to_char((x->>'due_date')::date, 'DD/MM')),
                    ' y ' order by (x->>'sequence')::integer),
         array_agg((x->>'amount_usd')::numeric order by (x->>'sequence')::integer),
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
      'monto_consulta', public.helios_money_text(coalesce(v_c.base_usd, v_c.amount_usd)),
      'servicio_pct', public.helios_pct_text(v_c.consumer_fee_pct),
      'cargo_servicio', public.helios_money_text(coalesce(v_c.consumer_fee_usd, 0)),
      'iva_pct', public.helios_pct_text(v_iva),
      'iva_cargo_servicio', public.helios_money_text(coalesce(v_c.consumer_fee_vat_usd, 0)),
      'total', public.helios_money_text(v_c.amount_usd),
      'cuotas_monto', case
        when v_montos[1] = v_montos[array_upper(v_montos, 1)] then '$' || public.helios_money_text(v_montos[1])
        else (select string_agg('$' || public.helios_money_text(m), ' y ') from unnest(v_montos) m) end,
      'cuotas_fechas', v_fechas,
      'cuotas_linea', v_linea,
      'orden', coalesce(v_c.order_number::text, left(v_c.id::text, 8)),
      'vence', to_char(v_c.expires_at at time zone 'America/Caracas', 'HH24:MI')
    ),
    null, null);
end;
$$;

revoke all on function public.helios_enqueue_confirmation(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Lo que el bot recuerda de cada número de paciente
-- ---------------------------------------------------------------------------

alter table public.whatsapp_contacts
  add column bot_menu_at        timestamptz,
  add column human_until        timestamptz,
  add column patient_profile_id uuid references public.profiles(id),
  add column patient_state      text check (patient_state is null or patient_state in ('cedula'));

comment on column public.whatsapp_contacts.bot_menu_at is
  'Cuándo le mostró el bot del paciente el menú por última vez (como mucho una vez cada 2 h).';
comment on column public.whatsapp_contacts.human_until is
  'Hasta cuándo el bot del paciente se calla con ese número: lo atiende una persona (Ayuda, un comprobante, alguien sin financiamientos).';
comment on column public.whatsapp_contacts.patient_profile_id is
  'Si el teléfono es de varios pacientes: a quién identificó el bot por su cédula.';

alter table public.outbound_messages drop constraint outbound_messages_destinatario;
alter table public.outbound_messages
  add constraint outbound_messages_destinatario
    check (profile_id is not null or recipient_staff_id is not null or template_key = 'bot_paciente');

/**
 * Encola un WhatsApp de texto (con hasta 3 botones) del bot del paciente.
 * `p_profile_id` puede ser null (alguien que escribe sin ser paciente). Solo
 * dentro de la ventana de 24 h. El webhook lo despacha al momento.
 */
create or replace function public.helios_whatsapp_patient_text(
  p_to         text,
  p_text       text,
  p_profile_id uuid default null,
  p_buttons    jsonb default '[]'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text := public.helios_wa_e164(p_to);
  v_id    uuid;
begin
  if v_phone is null or nullif(btrim(coalesce(p_text, '')), '') is null then
    raise exception 'Mensaje del bot incompleto' using errcode = '22023';
  end if;
  if not public.helios_whatsapp_window_open(v_phone) then
    raise exception 'La ventana de 24 h de ese número está cerrada' using errcode = '22023';
  end if;

  insert into public.outbound_messages (
    channel, template_key, profile_id, recipient, subject, rendered_text, status, next_attempt_at, wa_template
  ) values (
    'whatsapp', 'bot_paciente', p_profile_id, v_phone, 'Helios', left(p_text, 4096), 'pendiente', now(),
    jsonb_build_object('name', null, 'language', 'es', 'params', '[]'::jsonb,
      'buttons', coalesce((
        select jsonb_agg(jsonb_build_object('id', left(b->>'id', 256), 'title', left(b->>'title', 20)) order by i)
        from jsonb_array_elements(coalesce(p_buttons, '[]'::jsonb)) with ordinality as e(b, i)
        where i <= 3
      ), '[]'::jsonb))
  )
  returning id into v_id;
  return v_id;
end;
$$;

/**
 * Lo que el bot del paciente necesita saber de un número: los pacientes con
 * ese teléfono (nombre de pila y cédula enmascarada), a quién identificó, en
 * qué paso va, hasta cuándo lo atiende una persona y cuándo vio el menú.
 */
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
    'menu_reciente', coalesce(v_c.bot_menu_at > now() - interval '2 hours', false)
  );
end;
$$;

/**
 * Guarda lo que el bot del paciente recuerda de un número. Solo cambia lo
 * que viene: `p_menu` (marca que acaba de ver el menú), `p_humano_horas`
 * (callarse ese tiempo; 0 lo despierta), `p_estado` ('' lo limpia) y
 * `p_profile_id`.
 */
create or replace function public.bot_paciente_guardar(
  p_phone        text,
  p_menu         boolean default null,
  p_humano_horas integer default null,
  p_estado       text default null,
  p_profile_id   uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text := public.helios_wa_e164(p_phone);
begin
  insert into public.whatsapp_contacts (phone_e164, updated_at) values (v_phone, now())
  on conflict (phone_e164) do nothing;

  update public.whatsapp_contacts
     set bot_menu_at = case when p_menu then now() else bot_menu_at end,
         human_until = case when p_humano_horas is null then human_until
                            when p_humano_horas <= 0 then null
                            else now() + make_interval(hours => p_humano_horas) end,
         patient_state = case when p_estado is null then patient_state else nullif(p_estado, '') end,
         patient_profile_id = coalesce(p_profile_id, patient_profile_id),
         updated_at = now()
   where phone_e164 = v_phone;
end;
$$;

/**
 * Los financiamientos activos de un paciente, para «Pagar cuota» y «Ver
 * financiamientos»: sus cuotas pendientes con el cargo por atraso que lleven,
 * si están vencidas, el saldo, la tasa BCV de hoy, las cuentas de cobro y si
 * tiene un pago en revisión. Montos con el cargo por servicio: es para el
 * paciente.
 */
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
    'financiamientos', coalesce((
      select jsonb_agg(f order by f->>'primera')
      from (
        select jsonb_build_object(
                 'orden', c.order_number,
                 'clinica', m.name,
                 'consulta', coalesce(c.base_usd, c.amount_usd),
                 'primera', min(i.due_date),
                 'cuotas', jsonb_agg(jsonb_build_object(
                             'sequence', i.sequence,
                             'due_date', i.due_date,
                             'monto', i.amount_usd,
                             'cargo_atraso', coalesce((select sum(lf.amount_usd) from public.late_fees lf
                                                       where lf.installment_id = i.id and lf.status = 'pending'), 0),
                             'vencida', i.due_date < v_hoy)
                           order by i.due_date, i.sequence)) as f
        from public.installments i
        join public.charges c on c.id = i.charge_id and c.status = 'confirmed'
        join public.merchants m on m.id = c.merchant_id
        where i.user_id = p_profile_id and i.status = 'pending' and i.written_off_at is null
        group by c.id, c.order_number, m.name, c.base_usd, c.amount_usd
      ) x
    ), '[]'::jsonb),
    'tasa_bcv', public.current_fx_rate('BCV'),
    'cuentas_de_cobro', public.helios_payment_accounts_text(),
    'pago_en_revision', exists (select 1 from public.payment_reports r
                                where r.user_id = p_profile_id and r.status in ('reported', 'in_review'))
  );
end;
$$;

revoke all on function public.helios_whatsapp_patient_text(text, text, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.bot_paciente_contexto(text)                            from public, anon, authenticated;
revoke all on function public.bot_paciente_guardar(text, boolean, integer, text, uuid) from public, anon, authenticated;
revoke all on function public.bot_paciente_resumen(uuid)                             from public, anon, authenticated;
grant execute on function public.helios_whatsapp_patient_text(text, text, uuid, jsonb) to service_role;
grant execute on function public.bot_paciente_contexto(text)                            to service_role;
grant execute on function public.bot_paciente_guardar(text, boolean, integer, text, uuid) to service_role;
grant execute on function public.bot_paciente_resumen(uuid)                             to service_role;

-- ---------------------------------------------------------------------------
-- 4. La bienvenida con las cuotas en el formato nuevo
-- ---------------------------------------------------------------------------
-- `helios_finalize_charge` copiada de 20261005000300; solo cambia cómo se
-- escriben las cuotas de la bienvenida: «* $56,96 — 12/10/2026».

create or replace function public.helios_finalize_charge(
  p_charge_id           uuid,
  p_welcome_channel     text,
  p_over_limit_message  text default null
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
begin
  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Financiamiento no encontrado' using errcode = 'P0002';
  end if;

  if v_charge.status = 'pending' then
    update public.charges
       set status = 'confirmed', confirmed_at = now()
     where id = p_charge_id
    returning * into v_charge;
  end if;

  if v_charge.status <> 'confirmed' or v_charge.user_id is null then
    raise exception 'El financiamiento no se puede confirmar' using errcode = '22023';
  end if;

  select * into v_terms from public.helios_terms_at(v_charge.merchant_id, v_charge.business_date);
  if v_terms.id is null then
    raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
      using errcode = '22023';
  end if;

  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_charge.business_date);

  -- El asiento de cuatro patas, saltándose las que valen cero.
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

  -- La deuda: las 2 cuotas a +7 y +14 días y el bloque de crédito.
  perform public.helios_assign_debt(
    v_charge.user_id, v_charge.id, v_financed, v_charge.amount_usd, v_due_1, v_due_2,
    coalesce(p_over_limit_message, public.helios_not_available_message()));

  -- La comisión de quien lo registró.
  perform public.helios_accrue_staff_commission(v_charge.id);

  -- Los mensajes: el comprobante (al correo REGISTRADO) y la bienvenida.
  perform public.helios_enqueue_charge_receipt(v_charge.id);

  select m.name into v_merchant from public.merchants m where m.id = v_charge.merchant_id;
  select string_agg(format('* $%s — %s', public.helios_money_text(i.amount_usd),
                           to_char(i.due_date, 'DD/MM/YYYY')),
                    E'\n' order by i.sequence)
    into v_cuotas
  from public.installments i where i.charge_id = v_charge.id;

  perform public.helios_enqueue_message(
    'bienvenida', v_charge.user_id, v_charge.id, p_welcome_channel,
    jsonb_build_object('clinica', v_merchant, 'orden', v_charge.order_number::text, 'cuotas', v_cuotas),
    null, 'bienvenida:' || v_charge.id::text);
end;
$$;

revoke all on function public.helios_finalize_charge(uuid, text, text) from public, anon, authenticated;
