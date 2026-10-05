-- ============================================================================
-- Helios — El paciente acepta con un «Sí» (docs/00 §5.1, docs/01 §1.3.1 y §5)
--
-- Hasta ahora la secretaria confirmaba el financiamiento y la deuda existía al
-- instante. Desde el 2026-10-05 el paciente lo acepta respondiendo «Sí» a un
-- WhatsApp de Helios. Es volver al modelo de Ronda (`request_charge` +
-- `confirm_charge`), con el «Sí» por WhatsApp en lugar del PIN de la app:
--
--   create_patient_charge      crea la orden PENDIENTE (sin deuda), reserva el
--                              cupo y encola la plantilla `confirmar_financiamiento`
--   helios_patient_decision    el «Sí» (o el «No») que trae el webhook: revalida
--                              y confirma, o rechaza
--   helios_expire_pending_charges   cron: la que no contesta en 2 h vence
--   staff_resend_confirmation  reenviar al paciente (y reabrir una vencida)
--
-- Todo detrás del interruptor `patient_confirmation_required`, que nace en 0:
-- con 0, `create_patient_charge` confirma al instante como antes y la
-- bienvenida va a la cola manual. Se pasa a 1 cuando Meta apruebe la plantilla.
--
-- Lo que se confirma es exactamente lo de antes: el cuerpo que creaba la deuda
-- se mueve a `helios_finalize_charge` (asiento de 4 patas, devengo, cuotas con
-- `helios_assign_debt`, comisión, comprobante y bienvenida) y lo usan los dos
-- caminos. Las fechas de las cuotas salen del `business_date` de la orden: son
-- las que vio el paciente en el mensaje.
--
-- La reserva de cupo vive en `helios_credit_used_usd`: el cupo ocupado suma
-- ahora las órdenes pendientes vigentes del paciente, así que la elegibilidad,
-- la vista previa, el alta, `available_usd` y la defensa contra el doble gasto
-- de `helios_assign_debt` la respetan sin tocarlas.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Parámetros
-- ---------------------------------------------------------------------------

insert into public.business_parameters (key, value, effective_from, note) values
  ('patient_confirmation_required', 0,   date '2026-10-05', '1 = la orden espera el «Sí» del paciente por WhatsApp (docs/00 §5.1)'),
  ('patient_confirmation_minutes',  120, date '2026-10-05', 'Minutos que la orden espera el «Sí» antes de vencer'),
  ('confirmation_resends_per_day',  3,   date '2026-10-05', 'Reenvíos de la confirmación por orden y día')
on conflict (key, effective_from) do update
  set value = excluded.value, note = excluded.note;

insert into public.business_parameter_catalog (key, label, unit, grupo) values
  ('patient_confirmation_required', 'El paciente acepta por WhatsApp (1 = sí, 0 = no)', '0/1',      'producto'),
  ('patient_confirmation_minutes',  'Plazo para que el paciente acepte',                'minutos',  'producto'),
  ('confirmation_resends_per_day',  'Reenvíos de la confirmación por día',              'reenvíos', 'producto')
on conflict (key) do nothing;

create or replace function public.helios_patient_confirmation_required()
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select public.helios_parameter('patient_confirmation_required', 0) >= 1 $$;

create or replace function public.helios_patient_confirmation_minutes()
returns integer language sql stable security definer set search_path = public, pg_temp
as $$ select greatest(public.helios_parameter('patient_confirmation_minutes', 120)::integer, 1) $$;

create or replace function public.helios_confirmation_resends_per_day()
returns integer language sql stable security definer set search_path = public, pg_temp
as $$ select public.helios_parameter('confirmation_resends_per_day', 3)::integer $$;

revoke all on function public.helios_patient_confirmation_required() from public, anon;
revoke all on function public.helios_patient_confirmation_minutes()  from public, anon;
revoke all on function public.helios_confirmation_resends_per_day()  from public, anon;
grant execute on function public.helios_patient_confirmation_required() to authenticated;
grant execute on function public.helios_patient_confirmation_minutes()  to authenticated;
grant execute on function public.helios_confirmation_resends_per_day()  to authenticated;

-- ---------------------------------------------------------------------------
-- 2. La orden guarda por dónde llegó y la respuesta del paciente
-- ---------------------------------------------------------------------------

alter table public.charges
  add column channel              text not null default 'panel'
                                  check (channel in ('panel', 'whatsapp')),
  add column answered_at          timestamptz,
  add column answer_wa_message_id text,
  add column decline_reason       text
                                  check (decline_reason is null or decline_reason in ('paciente', 'no_disponible'));

create unique index charges_answer_wa_message_id_key
  on public.charges (answer_wa_message_id) where answer_wa_message_id is not null;

-- Las pendientes de un paciente (la reserva de cupo y «una sola a la vez").
create index charges_pending_user_idx
  on public.charges (user_id, expires_at) where status = 'pending';

comment on column public.charges.channel is
  'Por dónde se registró: panel o whatsapp (el bot del médico).';
comment on column public.charges.answered_at is
  'Cuándo respondió el paciente a la confirmación por WhatsApp (Sí o No).';
comment on column public.charges.answer_wa_message_id is
  'Id del mensaje de WhatsApp con la respuesta: la prueba del «Sí». Único: un reintento del webhook no confirma dos veces.';
comment on column public.charges.decline_reason is
  'paciente = dijo No; no_disponible = dijo Sí pero ya no se le podía financiar (no se dice por qué).';

-- ---------------------------------------------------------------------------
-- 3. El canal `whatsapp` (automático por la API)
-- ---------------------------------------------------------------------------

alter table public.notification_templates drop constraint notification_templates_channels_check;
alter table public.notification_templates
  add constraint notification_templates_channels_check
    check (channels <> '{}' and channels <@ array['app', 'email', 'whatsapp_manual', 'whatsapp']);

alter table public.notification_templates
  add column wa_template_name   text,
  add column wa_template_lang   text not null default 'es',
  add column wa_template_params text[] not null default '{}';

comment on column public.notification_templates.wa_template_name is
  'Nombre de la plantilla aprobada en Meta. Null = solo sale como texto libre (dentro de la ventana de 24 h).';
comment on column public.notification_templates.wa_template_params is
  'Las variables que van en {{1}}, {{2}}… de la plantilla de Meta, en orden.';

alter table public.outbound_messages drop constraint outbound_messages_channel_check;
alter table public.outbound_messages
  add constraint outbound_messages_channel_check
    check (channel in ('email', 'whatsapp_manual', 'whatsapp'));

comment on column public.outbound_messages.recipient is
  'Correo (email) o teléfono E.164 (whatsapp, whatsapp_manual) en el momento de encolar.';

/**
 * 🔁 Reescrita (20261002000700): admite el canal `whatsapp` (automático), que
 * va al teléfono registrado del paciente y nace listo para despachar. El resto
 * es igual.
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
    case when v_status = 'pendiente' and p_channel in ('email', 'whatsapp') then now() end,
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

revoke all on function public.helios_enqueue_message(text, uuid, uuid, text, jsonb, date, text) from public, anon, authenticated;

/**
 * ¿Puede salir un WhatsApp automático? Hay clave y URL de 360dialog en Vault.
 * Solo mira si EXISTEN los secretos, nunca su valor.
 */
create or replace function public.helios_whatsapp_api_ready()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from vault.secrets s where s.name = 'd360_api_key')
     and exists (select 1 from vault.secrets s where s.name = 'd360_base_url');
$$;

revoke all on function public.helios_whatsapp_api_ready() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Las plantillas
-- ---------------------------------------------------------------------------
-- `confirmar_financiamiento` es la plantilla de Meta (docs/00 §15.5): no se
-- edita en el panel, porque el texto tiene que coincidir con el aprobado. El
-- cuerpo de aquí es el texto completo que queda en la cola como prueba (y el
-- que sale como texto libre si la ventana de 24 h está abierta). El cargo por
-- servicio va desglosado y dicho con todas las letras (Javier, 2026-10-05);
-- ningún total suma el fee.

insert into public.notification_templates
  (key, type, channels, label, trigger_label, help, variables, required_variables,
   default_title, default_body, default_html, enabled, editable, can_disable, lead_days, run_at, sort_order,
   wa_template_name, wa_template_lang, wa_template_params)
values (
  'confirmar_financiamiento', null, '{whatsapp}',
  'Confirma tu financiamiento',
  'Al registrar un financiamiento (y al reenviarlo)',
  'La pregunta al paciente: ¿acepta? Botones Sí, acepto / No. Es la plantilla aprobada en Meta: el texto no se edita aquí.',
  array['nombre', 'clinica', 'monto_consulta', 'cargo_servicio', 'iva_cargo_servicio', 'cuotas_linea', 'orden', 'vence'],
  array['clinica', 'monto_consulta', 'cargo_servicio', 'iva_cargo_servicio', 'cuotas_linea'],
  'Confirma tu financiamiento en {clinica}',
  E'Hola, {nombre}. {clinica} registró a tu nombre un financiamiento con Helios para pagar tu consulta en 2 cuotas, sin inicial.\n\n'
  || E'Detalle:\n'
  || E'• Consulta: ${monto_consulta}\n'
  || E'• Cargo por servicio de Helios (20 %): ${cargo_servicio}\n'
  || E'• IVA del cargo por servicio (16 %): ${iva_cargo_servicio}\n\n'
  || E'Tus cuotas, que ya incluyen el cargo por servicio y su IVA: {cuotas_linea}\n\n'
  || '¿Aceptas? Tienes 2 horas para responder. Si no reconoces esta solicitud, responde No.',
  null, true, false, false, null, null, 15,
  'helios_confirmar_financiamiento', 'es',
  array['nombre', 'clinica', 'monto_consulta', 'cargo_servicio', 'iva_cargo_servicio', 'cuotas_linea']
)
on conflict (key) do nothing;

-- La bienvenida sale sola por la API cuando el paciente acepta (la ventana de
-- 24 h está abierta) y sigue pudiendo ir a la cola manual (interruptor en 0, o
-- si la API falla).
update public.notification_templates
   set channels      = '{whatsapp_manual,whatsapp}',
       trigger_label = 'Al confirmarse el financiamiento (el «Sí» del paciente)',
       help          = 'Confirma el financiamiento y explica cómo pagar. Con la confirmación del paciente sale sola por WhatsApp; si no, va a la cola manual.',
       default_body  =
         E'¡Listo, {nombre}! Tu financiamiento #{orden} en {clinica} está confirmado.\n\n'
         || E'Tus cuotas:\n{cuotas}\n\n'
         || E'Para pagar (en bolívares, a la tasa BCV del día del pago):\n{cuentas_de_cobro}\n\n'
         || 'Cuando pagues, envíanos el comprobante por este chat. También te mandamos todos los detalles a tu correo. Si no reconoces este financiamiento, avísanos por aquí.'
 where key = 'bienvenida';

-- ---------------------------------------------------------------------------
-- 5. La reserva de cupo
-- ---------------------------------------------------------------------------

/**
 * Lo que las órdenes pendientes VIGENTES del paciente le reservan del cupo: la
 * consulta (sin el fee, que no ocupa cupo). Una vencida ya no reserva, aunque
 * el cron todavía no la haya marcado.
 */
create or replace function public.helios_credit_reserved_usd(p_user uuid)
returns numeric
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce(sum(coalesce(c.base_usd, c.amount_usd)), 0)
  from public.charges c
  where c.user_id = p_user
    and c.status = 'pending'
    and c.expires_at > now();
$$;

comment on function public.helios_credit_reserved_usd(uuid) is
  'Cupo reservado por las órdenes pendientes vigentes (esperando el «Sí» del paciente).';

/**
 * 🔁 Reescrita (20260830240000): el cupo ocupado suma ahora lo reservado por
 * las órdenes pendientes vigentes. Así la elegibilidad, la vista previa, el
 * alta, `available_usd` y `helios_assign_debt` respetan la reserva sin
 * tocarlas. Al confirmarse, la orden deja de reservar (ya no es `pending`) y
 * pasa a ocupar por sus cuotas.
 */
create or replace function public.helios_credit_used_usd(p_user uuid)
returns numeric
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce((
           select sum(i.financed_usd)
           from public.installments i
           where i.user_id = p_user
             and exists (
               select 1 from public.installments j
               where j.charge_id = i.charge_id
                 and j.user_id   = i.user_id
                 and j.status    = 'pending'
             )
         ), 0)
       + public.helios_credit_reserved_usd(p_user);
$$;

comment on function public.helios_credit_used_usd(uuid) is
  'Cupo ocupado: lo financiado de las compras que aun tienen alguna cuota pendiente (se libera por COMPRA, no por cuota) más lo reservado por las órdenes pendientes vigentes.';

revoke all on function public.helios_credit_reserved_usd(uuid) from public, anon;
revoke all on function public.helios_credit_used_usd(uuid)     from public, anon;
grant execute on function public.helios_credit_reserved_usd(uuid) to authenticated;
grant execute on function public.helios_credit_used_usd(uuid)     to authenticated;

-- ---------------------------------------------------------------------------
-- 6. El plan de cuotas de una orden
-- ---------------------------------------------------------------------------

/**
 * Las cuotas de un financiamiento: las de verdad si ya existen, o las que
 * tendrá (el mismo reparto que `helios_assign_debt`, desde su
 * `business_date`) si todavía es una orden. Es lo que se le enseña al
 * paciente antes de aceptar. `[{sequence, due_date, amount_usd, financed_usd}]`.
 */
create or replace function public.helios_charge_planned_installments(p_charge_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_c     public.charges%rowtype;
  v_out   jsonb;
  v_due_1 date;
  v_due_2 date;
  v_total numeric(18,4);
  v_base  numeric(18,4);
  v_first numeric(18,4);
  v_fin_1 numeric(18,4);
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'sequence', x.sequence, 'due_date', x.due_date,
           'amount_usd', x.amount_usd, 'financed_usd', x.financed_usd)
         order by x.sequence), null)
    into v_out
  from (
    select i.sequence, min(i.due_date) as due_date,
           sum(i.amount_usd) as amount_usd, sum(i.financed_usd) as financed_usd
    from public.installments i where i.charge_id = p_charge_id group by i.sequence
  ) x;

  if v_out is not null then
    return v_out;
  end if;

  select * into v_c from public.charges where id = p_charge_id;
  if not found then
    return '[]'::jsonb;
  end if;

  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_c.business_date);
  v_total := v_c.amount_usd;
  v_base  := coalesce(v_c.base_usd, v_c.amount_usd);
  v_first := round(v_total / 2, 2);
  v_fin_1 := round(v_base / 2, 2);

  return jsonb_build_array(
    jsonb_build_object('sequence', 1, 'due_date', v_due_1, 'amount_usd', v_first, 'financed_usd', v_fin_1),
    jsonb_build_object('sequence', 2, 'due_date', v_due_2, 'amount_usd', v_total - v_first,
                       'financed_usd', v_base - v_fin_1)
  );
end;
$$;

revoke all on function public.helios_charge_planned_installments(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. La confirmación: el estado que ve la clínica
-- ---------------------------------------------------------------------------

/**
 * El estado de la confirmación del paciente (docs/01 §1.3.1), o null si el
 * financiamiento no pasó por ella (registrado con el interruptor en 0):
 *
 *   por_enviar | enviada | entregada | leida | fallida     (la orden espera)
 *   aceptada | rechazada | vencida                          (ya terminó)
 */
create or replace function public.helios_charge_confirmation(p_charge_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_c      public.charges%rowtype;
  v_m      public.outbound_messages%rowtype;
  v_first  public.outbound_messages%rowtype;
  v_phone  text;
  v_n      integer;
  v_status text;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found then
    return null;
  end if;

  select * into v_m from public.outbound_messages
  where charge_id = p_charge_id and template_key = 'confirmar_financiamiento'
  order by created_at desc, id desc limit 1;

  if v_m.id is null and v_c.status not in ('pending', 'declined', 'expired') then
    return null;
  end if;

  select * into v_first from public.outbound_messages
  where charge_id = p_charge_id and template_key = 'confirmar_financiamiento'
  order by created_at, id limit 1;

  select count(*) into v_n
  from public.outbound_messages o
  where o.charge_id = p_charge_id and o.template_key = 'confirmar_financiamiento'
    and o.created_at >= public.helios_business_day_start()
    and o.id <> v_first.id;

  select p.phone_e164 into v_phone from public.profiles p where p.id = v_c.user_id;

  v_status := case
    when v_c.status in ('confirmed', 'reverted') then 'aceptada'
    when v_c.status = 'declined' then 'rechazada'
    when v_c.status = 'expired' or (v_c.status = 'pending' and v_c.expires_at <= now()) then 'vencida'
    when v_c.status = 'voided' then 'rechazada'
    when v_m.id is null or v_m.status = 'pendiente' then 'por_enviar'
    when v_m.status = 'enviado' then
      case v_m.last_event when 'read' then 'leida' when 'delivered' then 'entregada' else 'enviada' end
    else 'fallida'
  end;

  return jsonb_build_object(
    'status', v_status,
    'telefono_enmascarado', public.helios_mask_phone(coalesce(v_m.recipient, v_phone)),
    'sent_at', v_m.sent_at,
    'answered_at', v_c.answered_at,
    'resends_today', coalesce(v_n, 0)
  );
end;
$$;

revoke all on function public.helios_charge_confirmation(uuid) from public, anon, authenticated;

/**
 * 🔁 Reescrita (20261003000400). Añade lo de la confirmación del paciente:
 * `expires_at`, `confirmation`, `channel`, `decline_reason` y
 * `decline_message`. Mientras la orden no está confirmada, las cuotas son las
 * planeadas (las que vio el paciente) y el comprobante está `sin_enviar`.
 */
create or replace function public.helios_charge_for_staff(p_charge_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me    uuid := auth.uid();
  v_c     public.charges%rowtype;
  v_p     public.profiles%rowtype;
  v_role  public.merchant_role;
  v_name  text;
  v_open  boolean;
begin
  select * into v_c from public.charges where id = p_charge_id;

  -- El mismo error exista o no: probar ids a ciegas no dice cuáles son de otra
  -- clínica. El gerente ve todos los de su clínica; la secretaria, los suyos.
  if not found or not (
    public.is_platform_admin()
    or exists (
      select 1 from public.merchant_users mu
      where mu.user_id = v_me and mu.merchant_id = v_c.merchant_id and mu.is_active
        and (mu.role = 'gerente' or v_c.requested_by = v_me)
    )
  ) then
    raise exception 'No existe ese financiamiento' using errcode = 'P0002';
  end if;

  select * into v_p from public.profiles where id = v_c.user_id;

  select mu.role into v_role
  from public.merchant_users mu
  where mu.user_id = v_c.requested_by and mu.merchant_id = v_c.merchant_id
  order by mu.is_active desc, (mu.role = 'gerente') desc, mu.created_at desc
  limit 1;

  v_name := public.helios_staff_name(v_c.requested_by);
  v_open := v_c.status in ('pending', 'declined', 'expired');

  return jsonb_build_object(
    'id', v_c.id,
    'order_number', v_c.order_number,
    'status', v_c.status::text,
    'channel', v_c.channel,
    'created_at', v_c.created_at,
    'confirmed_at', v_c.confirmed_at,
    'expires_at', case when v_c.status in ('pending', 'expired') then v_c.expires_at end,
    'business_date', v_c.business_date,
    'merchant_id', v_c.merchant_id,
    'merchant_name', (select m.name from public.merchants m where m.id = v_c.merchant_id),
    'branch_id', v_c.branch_id,
    'branch_name', (select b.name from public.merchant_branches b where b.id = v_c.branch_id),
    -- La base: lo que se le paga a la clínica. Nunca un total con el fee.
    'merchant_sale_usd', public.helios_merchant_sale_usd(v_c.base_usd, v_c.vat_usd, v_c.amount_usd),
    'concept', v_c.concept,
    'beneficiary_name', v_c.beneficiary_name,
    'patient', jsonb_build_object(
      'nombre', coalesce(nullif(btrim(v_p.full_name), ''),
                         nullif(btrim(concat_ws(' ', v_p.first_name, v_p.last_name)), '')),
      'documento_enmascarado', public.helios_mask_document(v_p.document_number),
      'email_enmascarado', public.helios_mask_email(v_p.email)
    ),
    -- Las cuotas llevan el fee dentro: es donde se permite verlo.
    'installments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sequence', (x->>'sequence')::integer,
               'due_date', (x->>'due_date')::date,
               'amount_usd', (x->>'amount_usd')::numeric)
             order by (x->>'sequence')::integer)
      from jsonb_array_elements(public.helios_charge_planned_installments(v_c.id)) x
    ), '[]'::jsonb),
    'breakdown', jsonb_build_object(
      'base_usd', v_c.base_usd,
      'consumer_fee_pct', v_c.consumer_fee_pct,
      'consumer_fee_usd', v_c.consumer_fee_usd,
      'consumer_fee_vat_usd', v_c.consumer_fee_vat_usd
    ),
    'receipt', case
      when v_open then jsonb_build_object(
        'status', 'sin_enviar', 'sent_at', null, 'last_event', null,
        'email_enmascarado', public.helios_mask_email(v_p.email))
      else public.helios_charge_receipt(v_c.id)
    end,
    'confirmation', public.helios_charge_confirmation(v_c.id),
    'decline_reason', v_c.decline_reason,
    'decline_message', case v_c.decline_reason
      when 'paciente' then 'El paciente rechazó el financiamiento'
      when 'no_disponible' then public.helios_not_available_message()
    end,
    'registered_by', case
      when v_name is null then null
      when v_role is null then v_name
      else v_name || ' (' || case v_role when 'gerente' then 'Administrador' else 'Secretaria' end || ')'
    end,
    'staff_commission_usd', v_c.staff_commission_usd
  );
end;
$$;

revoke all on function public.helios_charge_for_staff(uuid) from public, anon;
grant execute on function public.helios_charge_for_staff(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Confirmar: lo que crea la deuda
-- ---------------------------------------------------------------------------

/**
 * Confirma un financiamiento: lo que antes hacía `create_patient_charge` desde
 * el asiento (pasos 8-12 de 20261003000400). Si la orden está `pending`, la
 * pasa a `confirmed`. Las fechas salen de su `business_date`.
 *
 *   asiento de 4 patas ('charge:<idempotency_key>') → adelanto a la clínica →
 *   `helios_assign_debt` (las 2 cuotas, el bloque de crédito y otra vez el
 *   cupo) → comisión → comprobante (correo) → bienvenida (`p_welcome_channel`)
 *
 * Interna. Quien la llama ya validó al paciente y el cupo con la fila
 * bloqueada; `helios_assign_debt` lo vuelve a mirar.
 */
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
  select string_agg(format('• Cuota %s: $%s, vence el %s %s', i.sequence,
                           public.helios_money_text(i.amount_usd),
                           public.helios_weekday_es(i.due_date), to_char(i.due_date, 'DD/MM/YYYY')),
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

-- ---------------------------------------------------------------------------
-- 9. Encolar la pregunta al paciente
-- ---------------------------------------------------------------------------

/**
 * Encola la plantilla `confirmar_financiamiento` de una orden pendiente, al
 * teléfono REGISTRADO del paciente. Cada envío (y cada reenvío) es otro
 * mensaje. Devuelve su id. Interna.
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
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found or v_c.status <> 'pending' then
    raise exception 'La orden no está esperando al paciente' using errcode = '22023';
  end if;

  v_plan := public.helios_charge_planned_installments(p_charge_id);

  -- En una sola línea: Meta no admite saltos de línea en una variable.
  select string_agg(format('$%s el %s', public.helios_money_text((x->>'amount_usd')::numeric),
                           to_char((x->>'due_date')::date, 'DD/MM')),
                    ' y ' order by (x->>'sequence')::integer)
    into v_linea
  from jsonb_array_elements(v_plan) x;

  return public.helios_enqueue_message(
    'confirmar_financiamiento', v_c.user_id, p_charge_id, 'whatsapp',
    jsonb_build_object(
      'clinica', (select m.name from public.merchants m where m.id = v_c.merchant_id),
      'monto_consulta', public.helios_money_text(coalesce(v_c.base_usd, v_c.amount_usd)),
      'cargo_servicio', public.helios_money_text(coalesce(v_c.consumer_fee_usd, 0)),
      'iva_cargo_servicio', public.helios_money_text(coalesce(v_c.consumer_fee_vat_usd, 0)),
      'cuotas_linea', v_linea,
      'orden', coalesce(v_c.order_number::text, left(v_c.id::text, 8)),
      'vence', to_char(v_c.expires_at at time zone 'America/Caracas', 'HH24:MI')
    ),
    null, null);
end;
$$;

revoke all on function public.helios_enqueue_confirmation(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 10. Registrar: la orden pendiente (o, con el interruptor en 0, confirmada)
-- ---------------------------------------------------------------------------

/**
 * 🔁 Reescrita (20261003000400). Los pasos 1-6 son los mismos (idempotencia,
 * autorización y sede, monto, paciente, cupo, condiciones). Después:
 *
 * - con `patient_confirmation_required` = 1: la orden nace `pending` con
 *   `expires_at`, reserva el cupo, y se le pregunta al paciente por WhatsApp
 *   (a su teléfono REGISTRADO). Sin deuda, comisión ni comprobante: eso pasa
 *   con su «Sí» (`helios_patient_decision`). Una sola pendiente por paciente.
 * - con 0: como antes, confirmada al instante (`helios_finalize_charge`) y la
 *   bienvenida a la cola manual.
 *
 * `charges.channel` sale de la variable de sesión `helios.canal` ('whatsapp'
 * la pone el bot del médico); por defecto 'panel'.
 */
create or replace function public.create_patient_charge(
  p_merchant_id      uuid,
  p_branch_id        uuid,
  p_patient          jsonb,
  p_amount_usd       numeric,
  p_concept          text,
  p_beneficiary_name text,
  p_idempotency_key  text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $$
declare
  v_staff      uuid := auth.uid();
  v_key        text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_confirm    boolean := public.helios_patient_confirmation_required();
  v_canal      text := coalesce(nullif(current_setting('helios.canal', true), ''), 'panel');
  v_existing   public.charges%rowtype;
  v_role       public.merchant_role;
  v_branch     uuid;
  v_concept    text;
  v_benef      text;
  v_doc        text;
  v_in         jsonb;
  v_profile    public.profiles%rowtype;
  v_new        boolean := false;
  v_changes    jsonb := '{}'::jsonb;
  v_field      text;
  v_actual     text;
  v_limit      numeric(18,4);
  v_used       numeric(18,4);
  v_avail      numeric(18,4);
  v_min        numeric := public.helios_min_charge_usd();
  v_terms      public.merchant_terms%rowtype;
  v_b          jsonb;
  v_bdate      date;
  v_charge     public.charges%rowtype;
  v_commission numeric(18,4);
  v_over_msg   text;
begin
  if v_staff is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if v_key is null or length(v_key) > 200 then
    raise exception 'Falta la clave de idempotencia del formulario' using errcode = '22023';
  end if;

  if v_canal not in ('panel', 'whatsapp') then
    v_canal := 'panel';
  end if;

  -- 1. Idempotencia. El doble clic y la recarga devuelven el mismo
  --    financiamiento sin tocar nada. Serializado por clave: dos peticiones
  --    con la misma clave a la vez no crean dos.
  perform pg_advisory_xact_lock(hashtextextended('create_patient_charge:' || v_key, 0));

  select * into v_existing from public.charges where idempotency_key = v_key;
  if found then
    if v_existing.merchant_id = p_merchant_id and public.helios_staff_role_in(p_merchant_id) is not null then
      return public.helios_charge_for_staff(v_existing.id);
    end if;
    raise exception 'Esa clave de idempotencia ya se usó en otro financiamiento' using errcode = '22023';
  end if;

  -- 2. Autorización. Gerente: cualquier sede de su clínica (sin sede, la
  --    principal). Secretaria: solo la suya.
  v_role := public.helios_staff_role_in(p_merchant_id);
  if v_role is null then
    raise exception 'No tienes permiso para registrar en esta clínica' using errcode = '42501';
  end if;

  perform public.helios_assert_merchant_operating(p_merchant_id);

  -- Con la confirmación del paciente, sin WhatsApp no hay a quién preguntar.
  if v_confirm and not public.helios_whatsapp_api_ready() then
    raise exception 'No podemos escribirle a este paciente por WhatsApp. Escribe a Helios'
      using errcode = '22023';
  end if;

  if v_role = 'gerente' then
    v_branch := coalesce(
      p_branch_id,
      (select b.id from public.merchant_branches b
        where b.merchant_id = p_merchant_id and b.is_active
        order by b.is_default desc, b.created_at
        limit 1));
  elsif p_branch_id is not null then
    if not exists (
      select 1 from public.merchant_users mu
      where mu.user_id = v_staff and mu.merchant_id = p_merchant_id and mu.is_active
        and mu.role = 'cajero' and mu.branch_id = p_branch_id
    ) then
      raise exception 'No tienes permiso para registrar en esa sede' using errcode = '42501';
    end if;
    v_branch := p_branch_id;
  else
    if (select count(distinct mu.branch_id) from public.merchant_users mu
         where mu.user_id = v_staff and mu.merchant_id = p_merchant_id and mu.is_active
           and mu.role = 'cajero') > 1 then
      raise exception 'Elige la sede donde se registra el financiamiento' using errcode = '22023';
    end if;
    select mu.branch_id into v_branch
    from public.merchant_users mu
    where mu.user_id = v_staff and mu.merchant_id = p_merchant_id and mu.is_active and mu.role = 'cajero'
    limit 1;
  end if;

  if v_branch is null or not exists (
    select 1 from public.merchant_branches b
    where b.id = v_branch and b.merchant_id = p_merchant_id and b.is_active
  ) then
    raise exception 'La sede no es de esta clínica o está inactiva' using errcode = '22023';
  end if;

  -- 3. Monto, concepto y paciente atendido.
  perform public.helios_assert_charge_amount(p_amount_usd);

  v_concept := nullif(regexp_replace(btrim(coalesce(p_concept, '')), '\s+', ' ', 'g'), '');
  if length(v_concept) > 80 then
    raise exception 'El concepto admite como mucho 80 caracteres' using errcode = '22023';
  end if;
  v_concept := coalesce(v_concept, 'Consulta');

  v_benef := nullif(regexp_replace(btrim(coalesce(p_beneficiary_name, '')), '\s+', ' ', 'g'), '');
  if length(v_benef) > 120 then
    raise exception 'El nombre del paciente atendido admite como mucho 120 caracteres' using errcode = '22023';
  end if;

  -- 4. El paciente, por cédula.
  if p_patient is null or jsonb_typeof(p_patient) <> 'object' then
    raise exception 'Faltan los datos del paciente' using errcode = '22023';
  end if;

  v_doc := public.helios_document_key(p_patient->>'document');
  perform public.helios_assert_document_looked_up(p_merchant_id, v_doc);

  select * into v_profile from public.profiles where document_key = v_doc for update;

  if not found then
    -- Nuevo: se validan todos los datos y nace activo, nivel 1. Con la
    -- confirmación, se crea ya aquí: hace falta su teléfono para preguntarle.
    v_in := public.helios_patient_input(p_patient, true);

    insert into public.profiles (
      document_number, first_name, last_name, full_name, birth_date, sex,
      phone_e164, email, state, city, address, occupation,
      reference_name, reference_phone, reference_relationship,
      registered_by, registered_merchant_id
    ) values (
      v_doc, v_in->>'first_name', v_in->>'last_name',
      (v_in->>'first_name') || ' ' || (v_in->>'last_name'),
      (v_in->>'birth_date')::date, v_in->>'sex',
      v_in->>'phone', v_in->>'email', v_in->>'state', v_in->>'city', v_in->>'address',
      v_in->>'occupation', v_in->>'reference_name', v_in->>'reference_phone',
      v_in->>'reference_relationship', v_staff, p_merchant_id
    )
    on conflict (document_key) do nothing
    returning * into v_profile;

    if v_profile.id is null then
      -- Otra sede lo registró entre la búsqueda y el INSERT: es un conocido.
      select * into v_profile from public.profiles where document_key = v_doc for update;
    else
      v_new := true;
    end if;
  end if;

  if not v_new then
    -- Conocido: con la fila bloqueada. Mora, lista negra, bloqueo, expulsión:
    -- el mismo texto neutro que la elegibilidad.
    if v_profile.status <> 'active'
       or v_profile.is_blacklisted
       or public.helios_spend_blocked(v_profile.id)
       or not public.can_take_debt(v_profile.id) then
      raise exception '%', public.helios_not_available_message() using errcode = '22023';
    end if;

    -- Una sola orden esperando respuesta por paciente (sin decir de qué clínica).
    if exists (
      select 1 from public.charges c
      where c.user_id = v_profile.id and c.status = 'pending' and c.expires_at > now()
    ) then
      raise exception 'Este paciente tiene otra solicitud esperando su respuesta. Inténtalo cuando la responda o venza'
        using errcode = '22023';
    end if;

    -- Sus datos NO se sobrescriben: lo que venga distinto queda como
    -- propuesta para Helios. El comprobante va al correo ya registrado y la
    -- pregunta, al teléfono ya registrado.
    v_in := public.helios_patient_input(p_patient, false);
    for v_field in select jsonb_object_keys(v_in) loop
      v_actual := to_jsonb(v_profile) ->> (case when v_field = 'phone' then 'phone_e164' else v_field end);
      if v_actual is distinct from v_in->>v_field then
        v_changes := v_changes || jsonb_build_object(v_field,
          jsonb_build_object('antes', v_actual, 'propuesto', v_in->>v_field));
      end if;
    end loop;

    if v_changes <> '{}'::jsonb then
      insert into public.profile_change_requests (profile_id, merchant_id, requested_by, field_changes)
      values (v_profile.id, p_merchant_id, v_staff, v_changes);
    end if;
  end if;

  -- 5. El cupo, con la fila bloqueada: la defensa contra el doble gasto (dos
  --    sedes a la vez). Cuenta lo reservado por órdenes pendientes.
  --    `helios_assign_debt` lo vuelve a mirar con el bloque de crédito bloqueado.
  select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_profile.level;
  v_used  := public.helios_credit_used_usd(v_profile.id);
  v_avail := greatest(coalesce(v_limit, 0) - v_used, 0);

  if not v_new and v_avail < v_min then
    -- Cupo agotado es también «no disponible», sin decir por qué.
    raise exception '%', public.helios_not_available_message() using errcode = '22023';
  end if;

  v_over_msg := format('El monto supera lo disponible para financiar ($%s)',
                       public.helios_money_text(trunc(v_avail, 2)));
  if round(p_amount_usd, 2) > v_avail then
    raise exception '%', v_over_msg using errcode = '22023';
  end if;

  -- 6. Condiciones, desglose y comisión.
  v_bdate := public.helios_business_date(now());

  select * into v_terms from public.helios_terms_at(p_merchant_id, v_bdate);
  if v_terms.id is null then
    raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
      using errcode = '22023';
  end if;

  v_b := public.helios_charge_breakdown(p_amount_usd, coalesce(v_terms.commission_pct, 0));
  v_commission := public.helios_staff_commission_for(p_merchant_id, v_bdate);

  -- 7. La orden: pendiente (espera el «Sí») o, con el interruptor en 0,
  --    directamente confirmada.
  insert into public.charges (
    merchant_id, branch_id, requested_by, idempotency_key, user_id, status,
    business_date, confirmed_at, expires_at, channel,
    amount_usd, base_usd, vat_pct, vat_usd,
    consumer_fee_pct, consumer_fee_usd, consumer_fee_vat_usd,
    merchant_fee_pct, merchant_fee_usd, merchant_fee_vat_usd, merchant_net_usd,
    concept, beneficiary_name, terms_version_id,
    staff_commission_usd, commission_staff_id
  ) values (
    p_merchant_id, v_branch, v_staff, v_key, v_profile.id,
    case when v_confirm then 'pending' else 'confirmed' end::public.charge_status,
    v_bdate,
    case when v_confirm then null else now() end,
    case when v_confirm then now() + make_interval(mins => public.helios_patient_confirmation_minutes())
         else now() end,
    v_canal,
    (v_b->>'consumer_total_usd')::numeric, (v_b->>'base_usd')::numeric,
    (v_b->>'vat_pct')::numeric, (v_b->>'vat_usd')::numeric,
    (v_b->>'consumer_fee_pct')::numeric, (v_b->>'consumer_fee_usd')::numeric,
    (v_b->>'consumer_fee_vat_usd')::numeric,
    (v_b->>'merchant_fee_pct')::numeric, (v_b->>'merchant_fee_usd')::numeric,
    (v_b->>'merchant_fee_vat_usd')::numeric, (v_b->>'merchant_net_usd')::numeric,
    v_concept, v_benef,
    (select t.id from public.terms_versions t where t.is_current order by t.published_at desc limit 1),
    nullif(v_commission, 0), case when v_commission > 0 then v_staff end
  )
  returning * into v_charge;

  -- Una sola línea libre (D-H4: sin catálogo).
  insert into public.charge_items (charge_id, product_id, name, unit_price_usd, quantity, position)
  values (v_charge.id, null, v_concept, v_charge.base_usd, 1, 0);

  if v_confirm then
    -- 8. La pregunta al paciente, por WhatsApp.
    perform public.helios_enqueue_confirmation(v_charge.id);
  else
    -- 8-12. Asiento, adelanto, cuotas, comisión, comprobante y bienvenida.
    perform public.helios_finalize_charge(v_charge.id, 'whatsapp_manual', v_over_msg);
  end if;

  -- 13. Bitácora.
  perform audit.log(v_staff, 'charge.created', v_charge.id, jsonb_build_object(
    'merchant_id', p_merchant_id,
    'branch_id', v_branch,
    'user_id', v_profile.id,
    'new_patient', v_new,
    'base_usd', v_charge.base_usd,
    'amount_usd', v_charge.amount_usd,
    'concept', v_concept,
    'beneficiary_name', v_benef,
    'staff_commission_usd', v_charge.staff_commission_usd,
    'change_request', v_changes <> '{}'::jsonb,
    'business_date', v_bdate,
    'status', case when v_confirm then 'pending' else 'confirmed' end,
    'expires_at', case when v_confirm then v_charge.expires_at end,
    'canal', v_canal
  ));

  return public.helios_charge_for_staff(v_charge.id);
end;
$$;

revoke all on function public.create_patient_charge(uuid, uuid, jsonb, numeric, text, text, text) from public, anon;
grant execute on function public.create_patient_charge(uuid, uuid, jsonb, numeric, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 11. La respuesta del paciente (la llama el webhook de WhatsApp)
-- ---------------------------------------------------------------------------

/**
 * El «Sí» o el «No» del paciente a una orden pendiente (docs/01 §5.2).
 *
 * - Solo vale desde el teléfono REGISTRADO del paciente, con la orden
 *   `pending` y sin vencer.
 * - Idempotente por `p_wa_message_id`: un reintento del webhook devuelve lo
 *   mismo y no confirma dos veces.
 * - «Sí»: con el paciente bloqueado, revalida lo que pudo cambiar en la espera
 *   (estado, lista negra, bloqueo, mora, mantenimiento, clínica activa, cupo)
 *   y confirma (`helios_finalize_charge`, bienvenida por WhatsApp). Si la
 *   revalidación o la confirmación fallan, la orden queda `declined` con
 *   `no_disponible`: no se dice por qué.
 * - «No»: `declined` con `paciente`.
 *
 * No lanza errores de negocio (el webhook no debe reintentar en bucle):
 * devuelve `{ok, status, order_number}` o `{ok: false, reason}`. Solo para
 * `service_role`.
 */
create or replace function public.helios_patient_decision(
  p_charge_id      uuid,
  p_decision       text,
  p_from_phone     text,
  p_wa_message_id  text
)
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
    return jsonb_build_object('ok', false, 'reason', 'no_pendiente', 'status', v_c.status::text);
  end if;

  if v_c.expires_at <= now() then
    update public.charges set status = 'expired' where id = v_c.id;
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
    return jsonb_build_object('ok', false, 'reason', 'no_disponible', 'charge_id', v_c.id,
                              'status', 'declined', 'order_number', v_c.order_number);
  end if;

  return jsonb_build_object('ok', true, 'charge_id', v_c.id, 'status', 'confirmed',
                            'order_number', v_c.order_number);
end;
$$;

revoke all on function public.helios_patient_decision(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.helios_patient_decision(uuid, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 12. Vencer las que no contestan
-- ---------------------------------------------------------------------------

/**
 * Pasa a `expired` las órdenes pendientes cuyo plazo ya pasó (libera la
 * reserva; el trigger cancela la pregunta si aún no salió). Devuelve cuántas.
 * La corre `pg_cron` cada minuto.
 */
create or replace function public.helios_expire_pending_charges()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n integer;
begin
  with x as (
    update public.charges
       set status = 'expired'
     where status = 'pending' and expires_at <= now()
    returning id
  )
  select count(*) into v_n from x;
  return v_n;
end;
$$;

revoke all on function public.helios_expire_pending_charges() from public, anon, authenticated;

select cron.schedule('helios_expire_pending_charges', '* * * * *',
                     $c$ select public.helios_expire_pending_charges(); $c$);

-- ---------------------------------------------------------------------------
-- 13. Reenviar la pregunta (y reabrir una vencida)
-- ---------------------------------------------------------------------------

/**
 * «Reenviar al paciente» (docs/01 §1.3.2). Mismos permisos que
 * `staff_resend_receipt`.
 *
 * - `pending` (vigente): otro mensaje, sin alargar el plazo.
 * - `expired`: revalida paciente, clínica y cupo como el alta, recalcula el
 *   día operativo, el desglose, la comisión y las fechas, abre otro plazo y
 *   vuelve a `pending`.
 * - Límite `confirmation_resends_per_day` por orden y día.
 */
create or replace function public.staff_resend_confirmation(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_me     uuid := auth.uid();
  v_c      public.charges%rowtype;
  v_p      public.profiles%rowtype;
  v_first  uuid;
  v_n      integer;
  v_max    integer := public.helios_confirmation_resends_per_day();
  v_limit  numeric(18,4);
  v_avail  numeric(18,4);
  v_min    numeric := public.helios_min_charge_usd();
  v_terms  public.merchant_terms%rowtype;
  v_b      jsonb;
  v_bdate  date;
  v_comm   numeric(18,4);
  v_base   numeric(18,4);
  v_msg    uuid;
  v_reopen boolean := false;
begin
  if v_me is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_c from public.charges where id = p_charge_id for update;

  -- La misma regla que el detalle: el gerente, los de su clínica; la
  -- secretaria, los que registró. El mismo error exista o no.
  if not found or not exists (
    select 1 from public.merchant_users mu
    where mu.user_id = v_me and mu.merchant_id = v_c.merchant_id and mu.is_active
      and (mu.role = 'gerente' or (mu.role = 'cajero' and v_c.requested_by = v_me))
  ) then
    raise exception 'No existe ese financiamiento' using errcode = 'P0002';
  end if;

  if v_c.status = 'pending' and v_c.expires_at <= now() then
    update public.charges set status = 'expired' where id = v_c.id returning * into v_c;
  end if;

  if v_c.status not in ('pending', 'expired') then
    raise exception 'Este financiamiento ya no se puede reenviar' using errcode = '22023';
  end if;

  if not public.helios_whatsapp_api_ready() then
    raise exception 'No podemos escribirle a este paciente por WhatsApp. Escribe a Helios'
      using errcode = '22023';
  end if;

  -- Reenvíos de hoy: las preguntas de hoy menos la primera de todas.
  select o.id into v_first
  from public.outbound_messages o
  where o.charge_id = p_charge_id and o.template_key = 'confirmar_financiamiento'
  order by o.created_at, o.id limit 1;

  select count(*) into v_n
  from public.outbound_messages o
  where o.charge_id = p_charge_id and o.template_key = 'confirmar_financiamiento'
    and o.created_at >= public.helios_business_day_start()
    and o.id is distinct from v_first;

  if v_n >= v_max then
    raise exception 'Ya reenviaste esta solicitud % veces hoy. Inténtalo mañana', v_max
      using errcode = '22023';
  end if;

  if v_c.status = 'expired' then
    v_reopen := true;

    perform public.helios_assert_merchant_operating(v_c.merchant_id);

    select * into v_p from public.profiles where id = v_c.user_id for update;
    if v_p.status <> 'active'
       or v_p.is_blacklisted
       or public.helios_spend_blocked(v_p.id)
       or not public.can_take_debt(v_p.id) then
      raise exception '%', public.helios_not_available_message() using errcode = '22023';
    end if;

    if exists (
      select 1 from public.charges c
      where c.user_id = v_p.id and c.id <> v_c.id and c.status = 'pending' and c.expires_at > now()
    ) then
      raise exception 'Este paciente tiene otra solicitud esperando su respuesta. Inténtalo cuando la responda o venza'
        using errcode = '22023';
    end if;

    v_base := coalesce(v_c.base_usd, v_c.amount_usd);
    select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_p.level;
    v_avail := greatest(coalesce(v_limit, 0) - public.helios_credit_used_usd(v_p.id), 0);
    if v_avail < v_min then
      raise exception '%', public.helios_not_available_message() using errcode = '22023';
    end if;
    if round(v_base, 2) > v_avail then
      raise exception 'El monto supera lo disponible para financiar ($%)',
        public.helios_money_text(trunc(v_avail, 2)) using errcode = '22023';
    end if;

    v_bdate := public.helios_business_date(now());
    select * into v_terms from public.helios_terms_at(v_c.merchant_id, v_bdate);
    if v_terms.id is null then
      raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
        using errcode = '22023';
    end if;

    v_b    := public.helios_charge_breakdown(v_base, coalesce(v_terms.commission_pct, 0));
    v_comm := public.helios_staff_commission_for(v_c.merchant_id, v_bdate);

    update public.charges
       set status = 'pending',
           business_date = v_bdate,
           expires_at = now() + make_interval(mins => public.helios_patient_confirmation_minutes()),
           amount_usd = (v_b->>'consumer_total_usd')::numeric,
           base_usd = (v_b->>'base_usd')::numeric,
           vat_pct = (v_b->>'vat_pct')::numeric,
           vat_usd = (v_b->>'vat_usd')::numeric,
           consumer_fee_pct = (v_b->>'consumer_fee_pct')::numeric,
           consumer_fee_usd = (v_b->>'consumer_fee_usd')::numeric,
           consumer_fee_vat_usd = (v_b->>'consumer_fee_vat_usd')::numeric,
           merchant_fee_pct = (v_b->>'merchant_fee_pct')::numeric,
           merchant_fee_usd = (v_b->>'merchant_fee_usd')::numeric,
           merchant_fee_vat_usd = (v_b->>'merchant_fee_vat_usd')::numeric,
           merchant_net_usd = (v_b->>'merchant_net_usd')::numeric,
           terms_version_id = (select t.id from public.terms_versions t
                                where t.is_current order by t.published_at desc limit 1),
           staff_commission_usd = nullif(v_comm, 0),
           commission_staff_id = case when v_comm > 0 then v_c.requested_by end
     where id = v_c.id;
  end if;

  v_msg := public.helios_enqueue_confirmation(v_c.id);

  perform audit.log(v_me, 'charge.confirmation_resent', p_charge_id,
    jsonb_build_object('message_id', v_msg, 'merchant_id', v_c.merchant_id, 'reopened', v_reopen));

  return public.helios_charge_for_staff(p_charge_id);
end;
$$;

revoke all on function public.staff_resend_confirmation(uuid) from public, anon;
grant execute on function public.staff_resend_confirmation(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 14. Rechazada o vencida: se callan sus mensajes pendientes
-- ---------------------------------------------------------------------------
-- El mismo trigger de la reversa (20261005000100), ahora también para
-- `declined` y `expired`: la pregunta que aún no salió no debe salir.

drop trigger if exists charges_cancel_messages_on_revert on public.charges;
create trigger charges_cancel_messages_on_revert
  after update of status on public.charges
  for each row
  when (new.status in ('reverted', 'voided', 'declined', 'expired')
        and old.status is distinct from new.status and new.user_id is not null)
  execute function public.helios_cancel_messages_of_reverted_charge();

-- ---------------------------------------------------------------------------
-- 15. La lista de la clínica muestra también las órdenes
-- ---------------------------------------------------------------------------
-- 🔁 (20261003000600) Añade `status` y `expires_at` al final y lista también
-- las pendientes, rechazadas y vencidas. Los totales del día
-- (`merchant_transactions_summary`), las métricas, las comisiones y la
-- exportación siguen contando solo las confirmadas.

drop function public.merchant_transactions(date, date, integer);

create function public.merchant_transactions(p_from date, p_to date, p_limit integer default 500)
returns table(
  charge_id uuid, order_number bigint, business_date date, confirmed_at timestamptz,
  amount_usd numeric, merchant_sale_usd numeric, customer_name text, staff_name text,
  cuota_1_due date, cuota_1_run date, cuota_2_due date, cuota_2_run date,
  concept text, beneficiary_name text, receipt_status text,
  staff_commission_usd numeric, registered_by_name text,
  status text, expires_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit      integer := greatest(least(coalesce(p_limit, 500), 500), 1);
  v_gerente_de uuid    := public.my_merchant_id_as_gerente();
  v_me         uuid    := auth.uid();
begin
  return query
  with mias as (
    select c.id,
           c.order_number as num,
           c.business_date as bdate,
           c.confirmed_at as conf,
           c.created_at as creado,
           c.amount_usd as charged,
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale,
           c.user_id as quien,
           c.merchant_id as local,
           c.requested_by as cobro,
           c.concept as concepto,
           c.beneficiary_name as atendido,
           c.staff_commission_usd as comision,
           c.status::text as estado,
           c.expires_at as vence
    from public.charges c
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status in ('confirmed', 'pending', 'declined', 'expired')
      and c.business_date between p_from and p_to
      -- El gerente de ESA clínica ve todos; cualquier otro, solo los suyos.
      and (c.merchant_id = v_gerente_de or c.requested_by = v_me)
    order by c.business_date desc, coalesce(c.confirmed_at, c.created_at) desc
    limit v_limit
  ),
  cuotas as (
    select (m.id)                                                  as cid,
           (x->>'sequence')::integer                               as seq,
           (x->>'due_date')::date                                  as due,
           public.helios_settlement_run_for((x->>'due_date')::date) as run
    from mias m
    cross join lateral jsonb_array_elements(public.helios_charge_planned_installments(m.id)) x
  )
  select m.id,
         m.num,
         m.bdate,
         m.conf,
         m.charged,
         m.sale,
         p.full_name,
         case when m.local = v_gerente_de or m.cobro = v_me
              then public.helios_staff_name(m.cobro) end,
         c1.due,
         c1.run,
         c2.due,
         c2.run,
         m.concepto,
         m.atendido,
         case when m.estado = 'confirmed' then public.helios_charge_receipt(m.id) ->> 'status'
              else 'sin_enviar' end,
         m.comision,
         case when m.local = v_gerente_de or m.cobro = v_me
              then public.helios_staff_name(m.cobro) end,
         m.estado,
         case when m.estado in ('pending', 'expired') then m.vence end
  from mias m
  left join public.profiles p on p.id = m.quien
  left join cuotas c1 on c1.cid = m.id and c1.seq = 1
  left join cuotas c2 on c2.cid = m.id and c2.seq = 2
  order by m.bdate desc, coalesce(m.conf, m.creado) desc;
end;
$$;

revoke all on function public.merchant_transactions(date, date, integer) from public, anon;
grant execute on function public.merchant_transactions(date, date, integer) to authenticated;
