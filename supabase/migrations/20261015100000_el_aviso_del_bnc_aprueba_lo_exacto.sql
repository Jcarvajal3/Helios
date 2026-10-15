-- ============================================================================
-- Helios — El aviso del BNC aprueba lo que encaja exacto
--
-- Portado de Ronda (20261014100000). Helios y Ronda cobran en LA MISMA cuenta
-- del BNC, así que cada pago móvil que entra dispara un SMS del banco al iPhone
-- del CEO, y su Atajo lo manda a los dos:
--
--   BNC Pago Movil Recibido Bs.5442,41 Telf.0424***9037 Dia:12/10/26-19:07
--   Ref:158795645 Llamar al 0500-2625000 si no realizo esta Operacion
--
-- La función `aviso-bnc` lo deja aquí. El aviso se coteja con los pagos que
-- registró el equipo y, si encaja con uno solo, el bot lo aprueba (modo
-- «activo») o anota que lo habría aprobado (modo «sombra», para compararlo con
-- lo que decide el equipo). Los avisos de pagos de Ronda no encajan con nada y
-- se quedan esperando: es lo esperado.
--
-- Lo que cambia frente a Ronda, porque aquí el pago lo registra el equipo
-- desde la captura (`admin_register_payment`) y no el paciente:
--   · La referencia la teclea el equipo, a veces entera y a veces el final. Se
--     comparan sus últimas cifras con las del SMS (que son las 9 últimas del
--     extracto): al menos 6, y hasta 9 si las trae.
--   · El día: con `paid_on` (el día que dice el comprobante), ese día o uno
--     de diferencia; sin él, como en Ronda, por la fecha de registro.
--   · El monto del SMS es el de la cotización al céntimo y, si el equipo lo
--     anotó, también el del comprobante (`declared_amount_ves`).
--   · El teléfono solo se mira si el pago lo trae: el registro del equipo no
--     lo pide.
--
-- Como en Ronda: referencia y monto EXACTOS, pareja ÚNICA en los dos
-- sentidos, y ante cualquier duda el pago sigue en la cola del equipo. El bot
-- nunca rechaza nada. La garantía es el iPhone, no el banco: el SMS no lleva
-- firma, y el extracto sigue siendo la verdad.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- El modo
-- ---------------------------------------------------------------------------

create table if not exists public.bank_sms_settings (
  id          boolean primary key default true check (id),
  -- apagado: se guardan los avisos y no se cotejan.
  -- sombra:  se cotejan y se anota lo que se habría aprobado.
  -- activo:  se aprueba.
  mode        text not null default 'sombra'
              check (mode in ('apagado', 'sombra', 'activo')),
  -- En modo activo, la aprobación se firma con esta persona (quien lo
  -- activó): `reviewed_by` y la bitácora piden alguien de carne y hueso. La
  -- bitácora añade `via: aviso_bnc` para distinguirlo de una aprobación a mano.
  actor       uuid references auth.users (id),
  -- El remitente del SMS del BNC tal como lo ve el iPhone. Con él puesto, un
  -- aviso de otro remitente no aprueba nada: el número de pago móvil de la
  -- cuenta es público y cualquiera puede escribirle un SMS con el mismo texto. Se
  -- fija cuando la sombra enseñe el remitente real.
  allowed_sender text,
  updated_by  uuid references auth.users (id),
  updated_at  timestamptz not null default now()
);

comment on table public.bank_sms_settings is
  'Una sola fila: en qué modo está el bot de avisos del BNC (apagado, sombra o activo).';

insert into public.bank_sms_settings (id, mode) values (true, 'sombra')
on conflict (id) do nothing;

alter table public.bank_sms_settings enable row level security;
revoke all on public.bank_sms_settings from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Los avisos
-- ---------------------------------------------------------------------------

create table if not exists public.bank_sms_notices (
  id                  uuid primary key default gen_random_uuid(),
  received_at         timestamptz not null default now(),
  -- El SMS tal cual llegó. Lo demás se lee de aquí.
  body                text not null,
  -- Quién mandó el SMS, según el iPhone. Lo manda el Atajo.
  sender              text,
  -- Lo leído. Todo a null si el texto no es un pago móvil recibido.
  reference           text,
  amount_ves          numeric(18,2),
  payer_phone_prefix  text,
  payer_phone_last4   text,
  -- «Dia:12/10/26-19:07», en hora de Caracas.
  paid_at             timestamptz,
  -- Lo que decidió el bot. `esperando` es el único que se vuelve a mirar.
  outcome             text not null
                      check (outcome in (
                        'ilegible',          -- no es un pago móvil recibido o cambió el formato
                        'esperando',         -- aún no hay un pago reportado que encaje
                        'varios',            -- encaja con más de uno: para el equipo
                        'telefono_distinto', -- referencia y monto sí, teléfono no: para el equipo
                        'remitente_ajeno',   -- el SMS no viene del remitente del BNC: para el equipo
                        'ya_aprobado',       -- cuando se miró, ya estaba aprobado
                        'aprobaria',         -- sombra: lo habría aprobado
                        'aprobado',          -- activo: lo aprobó
                        'error'              -- activo: falló al aprobar; sigue para el equipo
                      )),
  report_id           uuid references public.payment_reports (id),
  -- El modo en que se decidió: lo que hizo un aviso no cambia al cambiar el modo.
  mode                text check (mode in ('apagado', 'sombra', 'activo')),
  decided_at          timestamptz,
  note                text
);

comment on table public.bank_sms_notices is
  'SMS de pago móvil recibido del BNC, reenviados por el Atajo del iPhone del CEO, y lo que el bot decidió con cada uno.';

-- El Atajo puede mandar dos veces el mismo SMS: el segundo no entra.
create unique index if not exists bank_sms_notices_unique_idx
  on public.bank_sms_notices (reference, amount_ves)
  where reference is not null;

create index if not exists bank_sms_notices_received_idx
  on public.bank_sms_notices (received_at desc);

create index if not exists bank_sms_notices_waiting_idx
  on public.bank_sms_notices (right(reference, 6))
  where outcome = 'esperando';

alter table public.bank_sms_notices enable row level security;
revoke all on public.bank_sms_notices from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Leer el SMS
-- ---------------------------------------------------------------------------

/**
 * Lee un SMS de pago móvil recibido del BNC. Sin coincidencia, todo a null.
 *
 * Exige «Recibido»: el BNC también avisa de los pagos móviles que SALEN de la
 * cuenta, y esos no pueden aprobar nada. El monto viene con coma decimal; los
 * puntos, si los trae, son de miles.
 */
create or replace function public.helios_parse_bnc_sms(p_body text)
returns table (
  reference          text,
  amount_ves         numeric,
  payer_phone_prefix text,
  payer_phone_last4  text,
  paid_at            timestamptz
)
language plpgsql
stable
set search_path = public, pg_temp
as $fn$
declare
  m      text[];
  monto  text;
begin
  m := regexp_match(
    coalesce(p_body, ''),
    'pago\s+m.vil\s+recibido\s+bs\.?\s*([0-9][0-9.]*(?:,[0-9]{1,2})?)\s+'
    || 'telf\.?:?\s*(0[0-9]{3})\*+([0-9]{4})\s+'
    || 'd.a:?\s*([0-9]{1,2})/([0-9]{1,2})/([0-9]{2})\s*-\s*([0-9]{1,2}):([0-9]{2})\s+'
    || 'ref\.?:?\s*([0-9]{6,})',
    'i'
  );

  if m is null then
    return;
  end if;

  monto := m[1];
  if position(',' in monto) > 0 then
    monto := replace(replace(monto, '.', ''), ',', '.');
  elsif monto ~ '^[0-9]{1,3}(\.[0-9]{3})+$' then
    monto := replace(monto, '.', '');
  end if;

  reference          := m[9];
  amount_ves         := round(monto::numeric, 2);
  payer_phone_prefix := m[2];
  payer_phone_last4  := m[3];
  paid_at            := make_timestamptz(
    2000 + m[6]::int, m[5]::int, m[4]::int, m[7]::int, m[8]::int, 0, 'America/Caracas'
  );

  if amount_ves <= 0 then
    return;
  end if;

  return next;
exception
  -- Una fecha imposible (31/02) o un número raro: ilegible, no un error.
  when others then
    return;
end;
$fn$;

revoke all on function public.helios_parse_bnc_sms(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Las dos reglas de encaje que cambian frente a Ronda
-- ---------------------------------------------------------------------------

/**
 * ¿La referencia que tecleó el equipo es la del SMS? Se comparan las últimas
 * cifras: al menos 6 y, si el equipo tecleó más, hasta 9 (las que trae el SMS).
 */
create or replace function public.helios_bank_sms_ref_match(p_sms_ref text, p_report_ref text)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $fn$
  select coalesce(
    length(d) >= 6
    and right(p_sms_ref, least(length(d), 9)) = right(d, least(length(d), 9)),
    false)
  from (select regexp_replace(coalesce(p_report_ref, ''), '[^0-9]', '', 'g') as d) x
$fn$;

/**
 * ¿El pago es del día del SMS? Con `paid_on`, ese día o uno de diferencia
 * (hora de Caracas). Sin él, registrado entre un día antes y cinco después.
 */
create or replace function public.helios_bank_sms_day_match(
  p_paid_at timestamptz, p_paid_on date, p_created_at timestamptz
)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $fn$
  select case
    when p_paid_on is not null then
      abs(p_paid_on - (p_paid_at at time zone 'America/Caracas')::date) <= 1
    else
      p_created_at between p_paid_at - interval '1 day' and p_paid_at + interval '5 days'
  end
$fn$;

revoke all on function public.helios_bank_sms_ref_match(text, text) from public, anon, authenticated;
revoke all on function public.helios_bank_sms_day_match(timestamptz, date, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Cotejar un aviso
-- ---------------------------------------------------------------------------

/**
 * Decide qué hacer con un aviso y lo anota. Solo mira los que esperan: lo que
 * ya se decidió no se vuelve a decidir.
 */
create or replace function public.helios_bank_sms_evaluate(p_notice_id uuid)
returns text
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_n        public.bank_sms_notices%rowtype;
  v_cfg      public.bank_sms_settings%rowtype;
  v_count    integer;
  v_report   uuid;
  v_status   public.payment_report_status;
  v_phone    text;
  v_rivales  integer;
  v_outcome  text;
  v_note     text;
begin
  select * into v_n from public.bank_sms_notices where id = p_notice_id for update;
  if not found or v_n.outcome <> 'esperando' then
    return v_n.outcome;
  end if;

  select * into v_cfg from public.bank_sms_settings where id;
  if coalesce(v_cfg.mode, 'apagado') = 'apagado' then
    return 'esperando';
  end if;

  if v_cfg.allowed_sender is not null
     and coalesce(trim(v_n.sender), '') <> v_cfg.allowed_sender then
    update public.bank_sms_notices
    set outcome = 'remitente_ajeno', mode = v_cfg.mode, decided_at = now(),
        note = format('Remitente %s; se espera %s', coalesce(v_n.sender, 'desconocido'), v_cfg.allowed_sender)
    where id = v_n.id;
    return 'remitente_ajeno';
  end if;

  select count(*), min(r.id::text)::uuid into v_count, v_report
  from public.payment_reports r
  join public.payment_quotes q on q.id = r.quote_id
  where r.method = 'pago_movil'
    and public.helios_bank_sms_ref_match(v_n.reference, r.reference)
    and q.amount_ves = v_n.amount_ves
    and (r.declared_amount_ves is null or r.declared_amount_ves = v_n.amount_ves)
    and r.status not in ('rejected', 'duplicate')
    and public.helios_bank_sms_day_match(v_n.paid_at, r.paid_on, r.created_at);

  if v_count = 0 then
    return 'esperando';
  end if;

  if v_count > 1 then
    v_outcome := 'varios';
    v_note := format('%s pagos reportados encajan con este aviso', v_count);
  else
    select r.status, r.payer_phone into v_status, v_phone
    from public.payment_reports r where r.id = v_report;

    -- El otro sentido: otro aviso que encaje igual con ese pago.
    select count(*) into v_rivales
    from public.bank_sms_notices o
    join public.payment_reports r on r.id = v_report
    join public.payment_quotes q on q.id = r.quote_id
    where o.id <> v_n.id
      and o.reference is not null
      and public.helios_bank_sms_ref_match(o.reference, r.reference)
      and o.amount_ves = q.amount_ves
      and public.helios_bank_sms_day_match(o.paid_at, r.paid_on, r.created_at);

    if v_rivales > 0 then
      v_outcome := 'varios';
      v_note := 'Otro aviso encaja con el mismo pago';
    elsif v_phone is not null
       and (left(regexp_replace(v_phone, '^\+?58', '0'), 4) <> v_n.payer_phone_prefix
            or right(v_phone, 4) <> v_n.payer_phone_last4) then
      v_outcome := 'telefono_distinto';
      v_note := format('El SMS dice %s***%s y el pago dice %s',
        v_n.payer_phone_prefix, v_n.payer_phone_last4, v_phone);
    elsif v_status = 'reconciled' then
      v_outcome := 'ya_aprobado';
    elsif v_cfg.mode = 'sombra' then
      v_outcome := 'aprobaria';
    elsif v_cfg.actor is null then
      v_outcome := 'error';
      v_note := 'Modo activo sin persona que firme las aprobaciones';
    else
      begin
        perform public.reconcile_payment(v_report, v_cfg.actor, true, 'Aprobado por el aviso del BNC');
        perform audit.log(v_cfg.actor, 'payment.reconciled', v_report, jsonb_build_object(
          'via', 'aviso_bnc',
          'notice_id', v_n.id,
          'sms_reference', v_n.reference,
          'amount_ves', v_n.amount_ves
        ));
        v_outcome := 'aprobado';
      exception when others then
        v_outcome := 'error';
        v_note := sqlerrm;
      end;
    end if;
  end if;

  update public.bank_sms_notices
  set outcome = v_outcome,
      report_id = v_report,
      mode = v_cfg.mode,
      decided_at = now(),
      note = v_note
  where id = v_n.id;

  return v_outcome;
end;
$fn$;

revoke all on function public.helios_bank_sms_evaluate(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Recibir un aviso (lo llama la función `aviso-bnc` con la service_role)
-- ---------------------------------------------------------------------------

drop function if exists public.helios_bank_sms_ingest(text);

create or replace function public.helios_bank_sms_ingest(p_body text, p_sender text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_p   record;
  v_id  uuid;
  v_out text;
begin
  if p_body is null or length(trim(p_body)) = 0 then
    raise exception 'El aviso viene vacío' using errcode = '22023';
  end if;

  select * into v_p from public.helios_parse_bnc_sms(p_body);

  if v_p.reference is null then
    insert into public.bank_sms_notices (body, sender, outcome, decided_at)
    values (left(p_body, 2000), left(nullif(trim(p_sender), ''), 100), 'ilegible', now())
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'outcome', 'ilegible');
  end if;

  insert into public.bank_sms_notices
    (body, sender, reference, amount_ves, payer_phone_prefix, payer_phone_last4, paid_at, outcome)
  values
    (left(p_body, 2000), left(nullif(trim(p_sender), ''), 100), v_p.reference, v_p.amount_ves, v_p.payer_phone_prefix,
     v_p.payer_phone_last4, v_p.paid_at, 'esperando')
  on conflict (reference, amount_ves) where reference is not null do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', true, 'outcome', 'repetido');
  end if;

  v_out := public.helios_bank_sms_evaluate(v_id);
  return jsonb_build_object('ok', true, 'id', v_id, 'outcome', v_out);
end;
$fn$;

revoke all on function public.helios_bank_sms_ingest(text, text) from public, anon, authenticated;
grant execute on function public.helios_bank_sms_ingest(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- El pago que llega después del aviso
-- ---------------------------------------------------------------------------

/**
 * Lo normal es que el SMS llegue antes que el reporte: la persona paga y
 * luego reporta. Al llegar el reporte se miran los avisos que esperan su
 * referencia.
 *
 * Diferido al final de la transacción: `report_payment` termina su trabajo
 * (cancelar recordatorios, etc.) antes de que el bot lo apruebe. Y nada de lo
 * que pase aquí puede hacer fallar el reporte de la persona.
 */
create or replace function public.helios_bank_sms_on_report()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id uuid;
begin
  if new.method <> 'pago_movil' or new.reference is null then
    return null;
  end if;

  for v_id in
    select n.id from public.bank_sms_notices n
    where n.outcome = 'esperando'
      and public.helios_bank_sms_ref_match(n.reference, new.reference)
    order by n.received_at
  loop
    begin
      perform public.helios_bank_sms_evaluate(v_id);
    exception when others then
      raise warning 'aviso-bnc: no se pudo cotejar el aviso %: %', v_id, sqlerrm;
    end;
  end loop;

  return null;
end;
$fn$;

revoke all on function public.helios_bank_sms_on_report() from public, anon, authenticated;

drop trigger if exists bank_sms_on_report on public.payment_reports;
create constraint trigger bank_sms_on_report
  after insert on public.payment_reports
  deferrable initially deferred
  for each row execute function public.helios_bank_sms_on_report();

-- ---------------------------------------------------------------------------
-- El panel
-- ---------------------------------------------------------------------------

/**
 * Lo que hizo el bot con los avisos de un rango de días (hora de Caracas,
 * por el día en que llegó el aviso) frente a lo que hizo el equipo.
 *
 * Por aviso: lo que decidió el bot y el pago con el que lo emparejó. Si no lo
 * emparejó, el pago que tiene esa referencia (aunque no cuadre el monto), para
 * ver qué hizo el equipo con él. Aparte, los pagos móviles aprobados en el rango
 * sin aviso: lo que el iPhone no mandó.
 */
create or replace function public.admin_bank_sms_review(p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $fn$
declare
  v_cfg     public.bank_sms_settings%rowtype;
  v_primero timestamptz;
  v_avisos  jsonb;
  v_sin     jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_cfg from public.bank_sms_settings where id;
  select min(received_at) into v_primero from public.bank_sms_notices;

  select coalesce(jsonb_agg(to_jsonb(a) order by a.received_at desc), '[]'::jsonb) into v_avisos
  from (
    select
      n.id, n.received_at, n.body, n.sender, n.reference, n.amount_ves,
      n.payer_phone_prefix, n.payer_phone_last4, n.paid_at,
      n.outcome, n.mode, n.decided_at, n.note,
      (n.report_id is not null) as bot_paired,
      r.id               as report_id,
      r.user_id,
      p.full_name        as user_name,
      r.reference        as report_reference,
      r.payer_phone      as report_phone,
      r.created_at       as reported_at,
      r.status::text     as report_status,
      r.reviewed_at,
      coalesce(pa.full_name, rp.full_name) as reviewed_by_name,
      r.rejection_note,
      q.amount_ves       as report_amount_ves,
      q.amount_usd       as report_amount_usd
    from public.bank_sms_notices n
    left join lateral (
      select x.id from public.payment_reports x
      join public.payment_quotes xq on xq.id = x.quote_id
      where n.report_id is null
        and n.reference is not null
        and x.method = 'pago_movil'
        and public.helios_bank_sms_ref_match(n.reference, x.reference)
        and public.helios_bank_sms_day_match(n.paid_at, x.paid_on, x.created_at)
      order by (x.status = 'reconciled') desc, abs(xq.amount_ves - n.amount_ves), x.created_at
      limit 1
    ) cand on true
    left join public.payment_reports r on r.id = coalesce(n.report_id, cand.id)
    left join public.payment_quotes q on q.id = r.quote_id
    left join public.profiles p on p.id = r.user_id
    left join public.platform_admins pa on pa.user_id = r.reviewed_by
    left join public.profiles rp on rp.id = r.reviewed_by
    where (n.received_at at time zone 'America/Caracas')::date between p_from and p_to
  ) a;

  select coalesce(jsonb_agg(to_jsonb(s) order by s.reviewed_at desc), '[]'::jsonb) into v_sin
  from (
    select
      r.id as report_id, r.user_id, p.full_name as user_name, r.reference,
      r.payer_phone as report_phone, r.created_at as reported_at, r.reviewed_at,
      coalesce(pa.full_name, rp.full_name) as reviewed_by_name,
      q.amount_ves as report_amount_ves, q.amount_usd as report_amount_usd
    from public.payment_reports r
    join public.payment_quotes q on q.id = r.quote_id
    left join public.profiles p on p.id = r.user_id
    left join public.platform_admins pa on pa.user_id = r.reviewed_by
    left join public.profiles rp on rp.id = r.reviewed_by
    where v_primero is not null
      and r.method = 'pago_movil'
      and r.status = 'reconciled'
      and r.created_at >= v_primero
      and (r.reviewed_at at time zone 'America/Caracas')::date between p_from and p_to
      and not exists (
        select 1 from public.bank_sms_notices n
        where n.reference is not null
          and public.helios_bank_sms_ref_match(n.reference, r.reference)
          and public.helios_bank_sms_day_match(n.paid_at, r.paid_on, r.created_at)
      )
  ) s;

  return jsonb_build_object(
    'mode', v_cfg.mode,
    'mode_updated_at', v_cfg.updated_at,
    'mode_updated_by_name', (select coalesce(pa.full_name, p.full_name)
                             from auth.users u
                             left join public.platform_admins pa on pa.user_id = u.id
                             left join public.profiles p on p.id = u.id
                             where u.id = v_cfg.updated_by),
    'allowed_sender', v_cfg.allowed_sender,
    'first_notice_at', v_primero,
    'notices', v_avisos,
    'without_notice', v_sin
  );
end;
$fn$;

revoke all on function public.admin_bank_sms_review(date, date) from public, anon;
grant execute on function public.admin_bank_sms_review(date, date) to authenticated;

/**
 * Cambia el modo. Solo el super admin, y con motivo: pasar a activo es dejar
 * que el bot apruebe dinero.
 */
create or replace function public.admin_set_bank_sms_mode(p_mode text, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor uuid;
  v_antes text;
begin
  -- Rol y, si está exigido, segundo factor.
  v_actor := public.helios_assert_super_admin('cambiar el modo del bot de avisos');

  if p_mode not in ('apagado', 'sombra', 'activo') then
    raise exception 'Modo desconocido: %', p_mode using errcode = '22023';
  end if;

  if p_note is null or length(trim(p_note)) < 3 then
    raise exception 'Cambiar el modo del bot requiere motivo' using errcode = '22023';
  end if;

  select mode into v_antes from public.bank_sms_settings where id for update;

  update public.bank_sms_settings
  set mode = p_mode,
      actor = case when p_mode = 'activo' then v_actor else actor end,
      updated_by = v_actor,
      updated_at = now()
  where id;

  perform audit.log(v_actor, 'bank_sms.mode_changed', null, jsonb_build_object(
    'from', v_antes, 'to', p_mode, 'note', trim(p_note)
  ));

  return jsonb_build_object('ok', true, 'mode', p_mode);
end;
$fn$;

revoke all on function public.admin_set_bank_sms_mode(text, text) from public, anon;
grant execute on function public.admin_set_bank_sms_mode(text, text) to authenticated;
