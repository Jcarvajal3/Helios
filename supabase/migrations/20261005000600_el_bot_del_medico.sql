-- ============================================================================
-- Helios — El bot del médico (docs/00 §2.2 y §15.4, docs/01 §5.4)
--
-- Lo que el bot necesita de la base. La conversación vive en la Edge Function
-- (`whatsapp-webhook/bot.ts`); aquí, la identidad, el PIN y las operaciones:
--
-- 1. `whatsapp_sessions`: en qué paso va la conversación de cada número.
-- 2. El PIN (`bot_set_pin`, y la comprobación dentro de `bot_create_charge`):
--    4 dígitos, sin los obvios, bcrypt. Un PIN equivocado NO lanza error: si
--    lanzara, el intento fallido se desharía con la transacción y se podría
--    probar sin límite. Devuelve `{ok: false, error: 'pin'}` y cuenta.
-- 3. Los `bot_*`: resuelven el número → la persona y llaman a la RPC del
--    panel COMO ESA PERSONA (fijan `request.jwt.claims` en la transacción).
--    Mismas reglas que el panel: rol y sede, límite de cédulas, privacidad
--    entre clínicas, idempotencia. Solo para `service_role`.
-- 4. Las respuestas del bot y los avisos al médico salen por la cola
--    (`helios_whatsapp_text`, canal `whatsapp`, a una persona del personal en
--    lugar de a un paciente). El webhook despacha al momento.
-- 5. El médico que registró por WhatsApp se entera cuando el paciente acepta,
--    rechaza o deja vencer la orden.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Parámetros y sesiones
-- ---------------------------------------------------------------------------

insert into public.business_parameters (key, value, effective_from, note) values
  ('staff_pin_max_attempts', 5,  date '2026-10-05', 'Intentos de PIN del bot antes del bloqueo'),
  ('bot_session_minutes',    30, date '2026-10-05', 'Minutos sin actividad que reinician la conversación del bot')
on conflict (key, effective_from) do update
  set value = excluded.value, note = excluded.note;

insert into public.business_parameter_catalog (key, label, unit, grupo) values
  ('staff_pin_max_attempts', 'Intentos de PIN del bot antes del bloqueo', 'intentos', 'producto'),
  ('bot_session_minutes',    'Inactividad que reinicia la conversación del bot', 'minutos', 'producto')
on conflict (key) do nothing;

create table public.whatsapp_sessions (
  phone_e164  text primary key check (phone_e164 ~ '^\+[0-9]{8,15}$'),
  user_id     uuid not null references auth.users(id),
  state       text not null default 'menu',
  data        jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

comment on table public.whatsapp_sessions is
  'En qué paso va la conversación del bot con cada número del personal. La lee y la escribe la Edge Function (service_role). Pasados bot_session_minutes sin actividad se reinicia.';

alter table public.whatsapp_sessions enable row level security;
revoke all on public.whatsapp_sessions from anon, authenticated;

/** La sesión vigente de un número (o una nueva en `menu`), y los minutos de vida. */
create or replace function public.bot_session(p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_s public.whatsapp_sessions%rowtype;
  v_n public.staff_whatsapp_numbers%rowtype;
begin
  v_n := public.helios_bot_number(p_phone);
  select * into v_s from public.whatsapp_sessions where phone_e164 = v_n.phone_e164;
  if not found or v_s.user_id <> v_n.user_id
     or v_s.updated_at < now() - make_interval(mins => public.helios_parameter('bot_session_minutes', 30)::integer) then
    return jsonb_build_object('state', 'menu', 'data', '{}'::jsonb, 'nueva', true);
  end if;
  return jsonb_build_object('state', v_s.state, 'data', v_s.data, 'nueva', false);
end;
$$;

/** Guarda el paso de la conversación. */
create or replace function public.bot_session_save(p_phone text, p_state text, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n public.staff_whatsapp_numbers%rowtype;
begin
  v_n := public.helios_bot_number(p_phone);
  insert into public.whatsapp_sessions (phone_e164, user_id, state, data, updated_at)
  values (v_n.phone_e164, v_n.user_id, coalesce(p_state, 'menu'), coalesce(p_data, '{}'::jsonb), now())
  on conflict (phone_e164) do update
    set user_id = excluded.user_id, state = excluded.state, data = excluded.data, updated_at = now();
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Quién escribe, y actuar como esa persona
-- ---------------------------------------------------------------------------

/**
 * El número activo del personal, con la persona aún activa en esa clínica.
 * Si no: 42501 «Este número no está registrado en Helios».
 */
create or replace function public.helios_bot_number(p_phone text)
returns public.staff_whatsapp_numbers
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v public.staff_whatsapp_numbers%rowtype;
begin
  select n.* into v
  from public.staff_whatsapp_numbers n
  join public.merchant_users mu
    on mu.user_id = n.user_id and mu.merchant_id = n.merchant_id and mu.is_active
   and mu.role in ('gerente', 'cajero')
  where n.phone_e164 = public.helios_wa_e164(p_phone) and n.revoked_at is null
  limit 1;
  if v.id is null then
    raise exception 'Este número no está registrado en Helios' using errcode = '42501';
  end if;
  return v;
end;
$$;

/**
 * Desde aquí, en esta transacción, `auth.uid()` es esa persona: las RPC del
 * panel aplican sus reglas (rol, sede, límites, privacidad) como si hubiera
 * entrado al panel. Y `helios.canal` = 'whatsapp' marca lo que registre.
 */
create or replace function public.helios_bot_as(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('helios.canal', 'whatsapp', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. El PIN
-- ---------------------------------------------------------------------------

/** 4 dígitos, sin los obvios: todos iguales o seguidos (1234, 9876…). */
create or replace function public.helios_pin_aceptable(p_pin text)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select p_pin ~ '^[0-9]{4}$'
     and p_pin !~ '^(.)\1{3}$'
     and position(p_pin in '0123456789') = 0
     and position(p_pin in '9876543210') = 0;
$$;

/** Crea el PIN del bot (solo si no tiene). */
create or replace function public.bot_set_pin(p_phone text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_n   public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_pin text := btrim(coalesce(p_pin, ''));
begin
  if exists (select 1 from public.staff_pins where user_id = v_n.user_id) then
    raise exception 'Ya tienes un PIN. Si lo olvidaste, escribe a Helios para resetearlo' using errcode = '22023';
  end if;
  if v_pin !~ '^[0-9]{4}$' then
    raise exception 'El PIN son 4 números' using errcode = '22023';
  end if;
  if not public.helios_pin_aceptable(v_pin) then
    raise exception 'Elige un PIN menos obvio (no 1234, 0000 ni parecidos)' using errcode = '22023';
  end if;

  insert into public.staff_pins (user_id, pin_hash) values (v_n.user_id, crypt(v_pin, gen_salt('bf', 8)));
  return jsonb_build_object('ok', true);
end;
$$;

/**
 * Comprueba el PIN SIN LANZAR (un error desharía el intento contado).
 * `{ok: true}` o `{ok: false, error: 'pin', message, attempts_left, locked}`.
 */
create or replace function public.helios_bot_check_pin(p_user uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_p   public.staff_pins%rowtype;
  v_max integer := greatest(public.helios_parameter('staff_pin_max_attempts', 5)::integer, 1);
  v_n   integer;
begin
  select * into v_p from public.staff_pins where user_id = p_user for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'sin_pin',
      'message', 'Todavía no tienes PIN. Escribe «hola» para crearlo.');
  end if;
  if v_p.locked_at is not null then
    return jsonb_build_object('ok', false, 'error', 'pin', 'locked', true, 'attempts_left', 0,
      'message', 'Tu PIN está bloqueado. Escribe a Helios para resetearlo.');
  end if;

  if crypt(btrim(coalesce(p_pin, '')), v_p.pin_hash) = v_p.pin_hash then
    if v_p.failed_attempts > 0 then
      update public.staff_pins set failed_attempts = 0 where user_id = p_user;
    end if;
    return jsonb_build_object('ok', true);
  end if;

  v_n := v_p.failed_attempts + 1;
  update public.staff_pins
     set failed_attempts = v_n,
         locked_at = case when v_n >= v_max then now() end
   where user_id = p_user;

  if v_n >= v_max then
    return jsonb_build_object('ok', false, 'error', 'pin', 'locked', true, 'attempts_left', 0,
      'message', 'PIN incorrecto. Tu PIN quedó bloqueado: escribe a Helios para resetearlo.');
  end if;
  return jsonb_build_object('ok', false, 'error', 'pin', 'locked', false, 'attempts_left', v_max - v_n,
    'message', format('PIN incorrecto. Te quedan %s intentos.', v_max - v_n));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Las operaciones del bot (como la persona)
-- ---------------------------------------------------------------------------

create or replace function public.bot_patient_eligibility(p_phone text, p_document text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
begin
  perform public.helios_bot_as(v_n.user_id);
  return public.helios_patient_eligibility(v_n.merchant_id, p_document);
end;
$$;

create or replace function public.bot_preview_charge(p_phone text, p_document text, p_amount_usd numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
begin
  perform public.helios_bot_as(v_n.user_id);
  return public.preview_patient_charge(v_n.merchant_id, p_document, p_amount_usd);
end;
$$;

/**
 * Registra la orden (docs/01 §5.4). Primero el PIN, que no lanza: un PIN
 * equivocado devuelve `{ok: false, error: 'pin', …}` y el intento queda
 * contado. Con el PIN bien, `create_patient_charge` como la persona y con
 * `charges.channel = 'whatsapp'`; sus errores de negocio lanzan como en el
 * panel. Devuelve `{ok: true, charge: helios_charge_for_staff}`.
 */
create or replace function public.bot_create_charge(
  p_phone            text,
  p_pin              text,
  p_patient          jsonb,
  p_amount_usd       numeric,
  p_concept          text,
  p_beneficiary_name text,
  p_idempotency_key  text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n   public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_pin jsonb;
begin
  v_pin := public.helios_bot_check_pin(v_n.user_id, p_pin);
  if not (v_pin->>'ok')::boolean then
    return v_pin;
  end if;

  perform public.helios_bot_as(v_n.user_id);
  return jsonb_build_object('ok', true, 'charge',
    public.create_patient_charge(v_n.merchant_id, null, p_patient, p_amount_usd,
                                 p_concept, p_beneficiary_name, p_idempotency_key));
end;
$$;

/** Los financiamientos de los últimos 30 días (el `cajero` ve los suyos). */
create or replace function public.bot_recent_charges(p_phone text, p_limit integer default 10)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n   public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_hoy date := public.helios_business_date(now());
begin
  perform public.helios_bot_as(v_n.user_id);
  return coalesce((
    select jsonb_agg(to_jsonb(t) order by t.business_date desc, coalesce(t.confirmed_at, t.expires_at) desc)
    from (
      select * from public.merchant_transactions(v_hoy - 30, v_hoy, greatest(least(coalesce(p_limit, 10), 20), 1))
    ) t
  ), '[]'::jsonb);
end;
$$;

create or replace function public.bot_resend_confirmation(p_phone text, p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
begin
  perform public.helios_bot_as(v_n.user_id);
  return public.staff_resend_confirmation(p_charge_id);
end;
$$;

create or replace function public.bot_resend_receipt(p_phone text, p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
begin
  perform public.helios_bot_as(v_n.user_id);
  return public.staff_resend_receipt(p_charge_id);
end;
$$;

/** Una orden del bot por su número (#1042), si es de la clínica de esa persona. */
create or replace function public.bot_charge_by_order(p_phone text, p_order_number bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n  public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_id uuid;
begin
  select c.id into v_id from public.charges c
  where c.order_number = p_order_number and c.merchant_id = v_n.merchant_id;
  if v_id is null then
    raise exception 'No existe ese financiamiento' using errcode = 'P0002';
  end if;
  perform public.helios_bot_as(v_n.user_id);
  return public.helios_charge_for_staff(v_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Mensajes a una persona del personal
-- ---------------------------------------------------------------------------

alter table public.outbound_messages
  alter column profile_id drop not null,
  add column recipient_staff_id uuid references auth.users(id),
  add constraint outbound_messages_destinatario
    check (profile_id is not null or recipient_staff_id is not null);

comment on column public.outbound_messages.recipient_staff_id is
  'Si el mensaje es para una persona del personal (el bot del médico) en lugar de para un paciente.';

insert into public.notification_templates
  (key, type, channels, label, trigger_label, help, variables, required_variables,
   default_title, default_body, enabled, editable, can_disable, sort_order)
values (
  'bot_respuesta', null, '{whatsapp}', 'Bot del médico',
  'Cada respuesta del bot y cada aviso al médico',
  'Lo que el bot le escribe a una persona del personal. Siempre dentro de su ventana de 24 h.',
  array['texto'], array['texto'],
  'Helios', '{texto}', true, false, false, 900
)
on conflict (key) do nothing;

/**
 * Encola un WhatsApp de texto (con hasta 3 botones de respuesta) a una
 * persona del personal. Solo dentro de su ventana de 24 h (si no, 22023). El
 * webhook lo despacha al momento con `helios_dispatch_whatsapp_batch`.
 * `p_buttons`: `[{id, title}]`.
 */
create or replace function public.helios_whatsapp_text(
  p_to            text,
  p_text          text,
  p_staff_user_id uuid,
  p_buttons       jsonb default '[]'::jsonb
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
  if v_phone is null or nullif(btrim(coalesce(p_text, '')), '') is null or p_staff_user_id is null then
    raise exception 'Mensaje del bot incompleto' using errcode = '22023';
  end if;
  if not public.helios_whatsapp_window_open(v_phone) then
    raise exception 'La ventana de 24 h de ese número está cerrada' using errcode = '22023';
  end if;

  insert into public.outbound_messages (
    channel, template_key, profile_id, recipient_staff_id, recipient,
    subject, rendered_text, status, next_attempt_at, wa_template
  ) values (
    'whatsapp', 'bot_respuesta', null, p_staff_user_id, v_phone,
    'Helios', left(p_text, 4096), 'pendiente', now(),
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
 * Avisa al médico que registró por WhatsApp de lo que pasó con su orden
 * (`aceptada`, `rechazada`, `vencida`). Solo si su ventana está abierta: si
 * no, el resultado queda en el panel. Nunca lanza.
 */
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
    when 'aceptada' then format('✅ %s aceptó. Financiamiento #%s confirmado: consulta de $%s.',
                                v_quien, v_c.order_number, public.helios_money_text(coalesce(v_c.base_usd, v_c.amount_usd)))
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
-- 6. El «Sí» y el vencimiento avisan al médico
-- ---------------------------------------------------------------------------

/** 🔁 (20261005000300) Igual, y al final avisa al médico si registró por WhatsApp. */
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
    perform public.helios_notify_staff_of_charge(v_c.id, 'vencida');
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
    return jsonb_build_object('ok', false, 'reason', 'no_disponible', 'charge_id', v_c.id,
                              'status', 'declined', 'order_number', v_c.order_number);
  end if;

  perform public.helios_notify_staff_of_charge(v_c.id, 'aceptada');
  return jsonb_build_object('ok', true, 'charge_id', v_c.id, 'status', 'confirmed',
                            'order_number', v_c.order_number);
end;
$$;

/** 🔁 (20261005000300) Igual, y avisa al médico de cada orden que vence. */
create or replace function public.helios_expire_pending_charges()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_n  integer := 0;
begin
  for v_id in
    update public.charges
       set status = 'expired'
     where status = 'pending' and expires_at <= now()
    returning id
  loop
    v_n := v_n + 1;
    perform public.helios_notify_staff_of_charge(v_id, 'vencida');
  end loop;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Permisos: todo esto es del webhook (service_role)
-- ---------------------------------------------------------------------------

revoke all on function public.helios_bot_number(text)                    from public, anon, authenticated;
revoke all on function public.helios_bot_as(uuid)                        from public, anon, authenticated;
revoke all on function public.helios_pin_aceptable(text)                 from public, anon, authenticated;
revoke all on function public.helios_bot_check_pin(uuid, text)           from public, anon, authenticated;
revoke all on function public.helios_notify_staff_of_charge(uuid, text)  from public, anon, authenticated;
revoke all on function public.helios_patient_decision(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.helios_expire_pending_charges()            from public, anon, authenticated;

revoke all on function public.bot_session(text)                          from public, anon, authenticated;
revoke all on function public.bot_session_save(text, text, jsonb)        from public, anon, authenticated;
revoke all on function public.bot_set_pin(text, text)                    from public, anon, authenticated;
revoke all on function public.bot_patient_eligibility(text, text)        from public, anon, authenticated;
revoke all on function public.bot_preview_charge(text, text, numeric)    from public, anon, authenticated;
revoke all on function public.bot_create_charge(text, text, jsonb, numeric, text, text, text) from public, anon, authenticated;
revoke all on function public.bot_recent_charges(text, integer)          from public, anon, authenticated;
revoke all on function public.bot_resend_confirmation(text, uuid)        from public, anon, authenticated;
revoke all on function public.bot_resend_receipt(text, uuid)             from public, anon, authenticated;
revoke all on function public.bot_charge_by_order(text, bigint)          from public, anon, authenticated;
revoke all on function public.helios_whatsapp_text(text, text, uuid, jsonb) from public, anon, authenticated;

grant execute on function public.helios_patient_decision(uuid, text, text, text) to service_role;
grant execute on function public.bot_session(text)                       to service_role;
grant execute on function public.bot_session_save(text, text, jsonb)     to service_role;
grant execute on function public.bot_set_pin(text, text)                 to service_role;
grant execute on function public.bot_patient_eligibility(text, text)     to service_role;
grant execute on function public.bot_preview_charge(text, text, numeric) to service_role;
grant execute on function public.bot_create_charge(text, text, jsonb, numeric, text, text, text) to service_role;
grant execute on function public.bot_recent_charges(text, integer)       to service_role;
grant execute on function public.bot_resend_confirmation(text, uuid)     to service_role;
grant execute on function public.bot_resend_receipt(text, uuid)          to service_role;
grant execute on function public.bot_charge_by_order(text, bigint)       to service_role;
grant execute on function public.helios_whatsapp_text(text, text, uuid, jsonb) to service_role;
-- Para responder al momento: el webhook despacha en cuanto termina cada mensaje.
grant execute on function public.helios_dispatch_whatsapp_batch(integer) to service_role;
