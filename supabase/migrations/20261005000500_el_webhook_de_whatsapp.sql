-- ============================================================================
-- Helios — El webhook de WhatsApp (docs/00 §15.3 y §15.4, docs/01 §2.7 y §5)
--
-- Lo que la Edge Function `whatsapp-webhook` necesita de la base para enrutar
-- cada mensaje que llega al número de Helios (un solo número en coexistencia:
-- el equipo atiende desde la app WhatsApp Business lo que no es del bot):
--
-- 1. `whatsapp_inbound`: cada mensaje recibido, crudo, con su wamid como clave
--    única. Los reintentos de 360dialog no repiten nada. Un PIN del personal
--    se guarda tachado.
-- 2. `staff_whatsapp_numbers` y `staff_pins`: el número de cada persona del
--    personal que usa el bot (lo registra el equipo de Helios) y su PIN. El
--    bot (el PIN, la conversación) llega en la migración siguiente; aquí va lo
--    que el superadmin administra (docs/01 §2.7).
-- 3. `helios_whatsapp_inbound(...)`: guarda el mensaje, abre la ventana de
--    24 h y devuelve con qué enrutarlo: ¿es del personal? ¿tiene el paciente
--    una orden esperando su respuesta?
-- 4. `helios_whatsapp_inbound_done(...)`: anota adónde fue y qué pasó.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Lo que llega
-- ---------------------------------------------------------------------------

create table public.whatsapp_inbound (
  wa_message_id text primary key,
  from_phone    text not null,
  type          text,
  payload       jsonb not null,
  route         text check (route is null or route in ('paciente', 'personal', 'nadie')),
  result        jsonb,
  received_at   timestamptz not null default now(),
  routed_at     timestamptz
);

comment on table public.whatsapp_inbound is
  'Cada mensaje que llega al WhatsApp de Helios (webhook), crudo. El wamid es único: un reintento no repite nada. route: paciente (su respuesta a la confirmación), personal (el bot) o nadie (lo atiende una persona desde la app).';

create index whatsapp_inbound_from_idx on public.whatsapp_inbound (from_phone, received_at desc);

alter table public.whatsapp_inbound enable row level security;
revoke all on public.whatsapp_inbound from anon, authenticated;
grant select on public.whatsapp_inbound to authenticated;
create policy whatsapp_inbound_read_admin on public.whatsapp_inbound
  for select to authenticated
  using ((select public.is_platform_admin()));

-- ---------------------------------------------------------------------------
-- 2. El número y el PIN del personal
-- ---------------------------------------------------------------------------

create table public.staff_whatsapp_numbers (
  id            uuid primary key default gen_random_uuid(),
  phone_e164    text not null check (phone_e164 ~ '^\+[0-9]{8,15}$'),
  user_id       uuid not null references auth.users(id),
  merchant_id   uuid not null references public.merchants(id),
  created_by    uuid not null references auth.users(id),
  created_at    timestamptz not null default now(),
  revoked_at    timestamptz,
  revoked_by    uuid references auth.users(id),
  revoke_reason text
);

-- Un número activo es de una sola persona; una persona tiene un solo número activo.
create unique index staff_whatsapp_numbers_phone_activo
  on public.staff_whatsapp_numbers (phone_e164) where revoked_at is null;
create unique index staff_whatsapp_numbers_user_activo
  on public.staff_whatsapp_numbers (user_id) where revoked_at is null;

comment on table public.staff_whatsapp_numbers is
  'El número de WhatsApp con el que una persona del personal usa el bot (docs/00 §15.4). Lo registra el equipo de Helios; escribir desde ese número la identifica. Por ahora un número sirve a una sola clínica.';

create table public.staff_pins (
  user_id         uuid primary key references auth.users(id),
  pin_hash        text not null,
  failed_attempts integer not null default 0 check (failed_attempts >= 0),
  locked_at       timestamptz,
  set_at          timestamptz not null default now()
);

comment on table public.staff_pins is
  'El PIN de 4 dígitos del bot (hash bcrypt). Se pide para crear una orden. Tras los intentos fallidos de staff_pin_max_attempts se bloquea hasta que Helios lo resetee.';

alter table public.staff_whatsapp_numbers enable row level security;
alter table public.staff_pins enable row level security;
revoke all on public.staff_whatsapp_numbers from anon, authenticated;
revoke all on public.staff_pins from anon, authenticated;
-- Ni el equipo lee los hashes: todo por RPC.

/** El nombre de la persona y su rol en la clínica, para el bot y el superadmin. */
create or replace function public.helios_staff_whatsapp_row(p_n public.staff_whatsapp_numbers)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', p_n.id,
    'phone_e164', p_n.phone_e164,
    'user_id', p_n.user_id,
    'staff_name', public.helios_staff_name(p_n.user_id),
    'role', (select mu.role::text from public.merchant_users mu
              where mu.user_id = p_n.user_id and mu.merchant_id = p_n.merchant_id and mu.is_active
              order by (mu.role = 'gerente') desc limit 1),
    'merchant_id', p_n.merchant_id,
    'merchant_name', (select m.name from public.merchants m where m.id = p_n.merchant_id),
    'has_pin', exists (select 1 from public.staff_pins s where s.user_id = p_n.user_id),
    'pin_locked', exists (select 1 from public.staff_pins s where s.user_id = p_n.user_id and s.locked_at is not null),
    'last_inbound_at', (select c.last_inbound_at from public.whatsapp_contacts c where c.phone_e164 = p_n.phone_e164),
    'created_at', p_n.created_at,
    'created_by_name', public.helios_staff_name(p_n.created_by),
    'revoked_at', p_n.revoked_at,
    'revoked_by_name', case when p_n.revoked_by is not null then public.helios_staff_name(p_n.revoked_by) end,
    'revoke_reason', p_n.revoke_reason
  );
$$;

revoke all on function public.helios_staff_whatsapp_row(public.staff_whatsapp_numbers) from public, anon, authenticated;

/** Los números del bot (de una clínica, o de todas). docs/01 §2.7. */
create or replace function public.admin_staff_whatsapp(p_merchant_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(public.helios_staff_whatsapp_row(n)
                     order by (n.revoked_at is null) desc, n.created_at desc)
    from public.staff_whatsapp_numbers n
    where p_merchant_id is null or n.merchant_id = p_merchant_id
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.admin_staff_whatsapp(uuid) from public, anon;
grant execute on function public.admin_staff_whatsapp(uuid) to authenticated;

/**
 * Registra el número de WhatsApp de una persona del personal (docs/01 §2.7).
 * Si esa persona ya tenía otro activo, se revoca («cambio de número»).
 */
create or replace function public.admin_set_staff_whatsapp(p_user_id uuid, p_merchant_id uuid, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_me    uuid := public.helios_assert_super_admin('registrar números del bot');
  v_phone text := public.helios_normalize_ve_mobile(p_phone);
  v_otro  public.staff_whatsapp_numbers%rowtype;
  v_row   public.staff_whatsapp_numbers%rowtype;
begin

  if not exists (
    select 1 from public.merchant_users mu
    where mu.user_id = p_user_id and mu.merchant_id = p_merchant_id and mu.is_active
      and mu.role in ('gerente', 'cajero')
  ) then
    raise exception 'Esa persona no es personal activo de esa clínica' using errcode = '22023';
  end if;

  if v_phone is null then
    raise exception 'Teléfono móvil inválido' using errcode = '22023';
  end if;

  select * into v_otro from public.staff_whatsapp_numbers
  where phone_e164 = v_phone and revoked_at is null;
  if found then
    if v_otro.user_id = p_user_id and v_otro.merchant_id = p_merchant_id then
      return public.helios_staff_whatsapp_row(v_otro);
    end if;
    raise exception 'Ese número ya está registrado para %', coalesce(public.helios_staff_name(v_otro.user_id), 'otra persona')
      using errcode = '22023';
  end if;

  update public.staff_whatsapp_numbers
     set revoked_at = now(), revoked_by = v_me, revoke_reason = 'Cambio de número'
   where user_id = p_user_id and revoked_at is null;

  insert into public.staff_whatsapp_numbers (phone_e164, user_id, merchant_id, created_by)
  values (v_phone, p_user_id, p_merchant_id, v_me)
  returning * into v_row;

  perform audit.log(v_me, 'staff.whatsapp_set', p_user_id, jsonb_build_object(
    'merchant_id', p_merchant_id, 'phone_e164', v_phone, 'number_id', v_row.id));

  return public.helios_staff_whatsapp_row(v_row);
end;
$$;

revoke all on function public.admin_set_staff_whatsapp(uuid, uuid, text) from public, anon;
grant execute on function public.admin_set_staff_whatsapp(uuid, uuid, text) to authenticated;

/** Revoca un número del bot. El motivo es obligatorio. */
create or replace function public.admin_revoke_staff_whatsapp(p_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_me     uuid := public.helios_assert_super_admin('revocar números del bot');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_row    public.staff_whatsapp_numbers%rowtype;
begin

  if v_reason is null or length(v_reason) < 3 then
    raise exception 'Escribe el motivo' using errcode = '22023';
  end if;

  update public.staff_whatsapp_numbers
     set revoked_at = now(), revoked_by = v_me, revoke_reason = v_reason
   where id = p_id and revoked_at is null
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Ese número no existe o ya estaba revocado' using errcode = 'P0002';
  end if;

  perform audit.log(v_me, 'staff.whatsapp_revoked', v_row.user_id, jsonb_build_object(
    'merchant_id', v_row.merchant_id, 'phone_e164', v_row.phone_e164, 'number_id', v_row.id,
    'reason', v_reason));

  return public.helios_staff_whatsapp_row(v_row);
end;
$$;

revoke all on function public.admin_revoke_staff_whatsapp(uuid, text) from public, anon;
grant execute on function public.admin_revoke_staff_whatsapp(uuid, text) to authenticated;

/** Borra el PIN (y el bloqueo): el bot pide crear otro en el próximo mensaje. */
create or replace function public.admin_reset_staff_pin(p_user_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_me     uuid := public.helios_assert_super_admin('resetear el PIN del bot');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_had    boolean;
begin

  if v_reason is null or length(v_reason) < 3 then
    raise exception 'Escribe el motivo' using errcode = '22023';
  end if;

  delete from public.staff_pins where user_id = p_user_id;
  v_had := found;

  perform audit.log(v_me, 'staff.pin_reset', p_user_id, jsonb_build_object(
    'reason', v_reason, 'had_pin', v_had));

  return jsonb_build_object('ok', true, 'had_pin', v_had);
end;
$$;

revoke all on function public.admin_reset_staff_pin(uuid, text) from public, anon;
grant execute on function public.admin_reset_staff_pin(uuid, text) to authenticated;

/** Dar de baja a una persona revoca su número del bot. */
create or replace function public.helios_revoke_whatsapp_of_inactive_staff()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.staff_whatsapp_numbers
     set revoked_at = now(), revoke_reason = 'La persona se dio de baja en la clínica'
   where user_id = new.user_id and merchant_id = new.merchant_id and revoked_at is null;
  return new;
end;
$$;

revoke all on function public.helios_revoke_whatsapp_of_inactive_staff() from public, anon, authenticated;

create trigger merchant_users_revoke_whatsapp
  after update of is_active on public.merchant_users
  for each row
  when (old.is_active and not new.is_active)
  execute function public.helios_revoke_whatsapp_of_inactive_staff();

-- ---------------------------------------------------------------------------
-- 3. Recibir un mensaje
-- ---------------------------------------------------------------------------

/**
 * Lo primero que hace el webhook con cada mensaje (docs/01 §5.2): lo guarda
 * (si ya estaba: `{duplicate: true}` y nada más), abre la ventana de 24 h del
 * número y devuelve con qué enrutarlo:
 *
 *   `staff`             la persona del personal dueña del número (o null)
 *   `pending_charge_id` la ÚNICA orden pendiente vigente cuyo paciente tiene
 *                       ese teléfono registrado (o null si no hay o hay varias)
 *
 * Un texto de solo 4 dígitos de un número del personal se guarda como «[PIN]».
 * Solo para `service_role`.
 */
create or replace function public.helios_whatsapp_inbound(
  p_message_id text,
  p_from       text,
  p_type       text,
  p_payload    jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone   text := public.helios_wa_e164(p_from);
  v_staff   public.staff_whatsapp_numbers%rowtype;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_pend    uuid[];
  v_profile uuid;
begin
  if nullif(btrim(coalesce(p_message_id, '')), '') is null or v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'peticion_invalida');
  end if;

  select n.* into v_staff
  from public.staff_whatsapp_numbers n
  join public.merchant_users mu
    on mu.user_id = n.user_id and mu.merchant_id = n.merchant_id and mu.is_active
   and mu.role in ('gerente', 'cajero')
  where n.phone_e164 = v_phone and n.revoked_at is null
  limit 1;

  if v_staff.id is not null and coalesce(v_payload -> 'text' ->> 'body', '') ~ '^\s*[0-9]{4}\s*$' then
    v_payload := jsonb_set(v_payload, '{text,body}', '"[PIN]"');
  end if;

  insert into public.whatsapp_inbound (wa_message_id, from_phone, type, payload)
  values (p_message_id, v_phone, p_type, v_payload)
  on conflict (wa_message_id) do nothing;

  if not found then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;

  select array_agg(c.id order by c.created_at), min(p.id::text)::uuid
    into v_pend, v_profile
  from public.charges c
  join public.profiles p on p.id = c.user_id
  where c.status = 'pending' and c.expires_at > now()
    and regexp_replace(coalesce(p.phone_e164, ''), '\D', '', 'g') = regexp_replace(v_phone, '\D', '', 'g');

  if v_profile is null then
    select p.id into v_profile from public.profiles p
    where p.phone_e164 = v_phone order by p.created_at desc limit 1;
  end if;

  insert into public.whatsapp_contacts (phone_e164, last_inbound_at, profile_id, staff_user_id, updated_at)
  values (v_phone, now(), v_profile, v_staff.user_id, now())
  on conflict (phone_e164) do update
    set last_inbound_at = now(),
        profile_id = coalesce(excluded.profile_id, whatsapp_contacts.profile_id),
        staff_user_id = excluded.staff_user_id,
        updated_at = now();

  return jsonb_build_object(
    'ok', true,
    'duplicate', false,
    'phone_e164', v_phone,
    'staff', case when v_staff.id is not null then public.helios_staff_whatsapp_row(v_staff) end,
    'pending_charge_id', case when cardinality(v_pend) = 1 then v_pend[1] end
  );
end;
$$;

revoke all on function public.helios_whatsapp_inbound(text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.helios_whatsapp_inbound(text, text, text, jsonb) to service_role;

/** Anota adónde fue un mensaje recibido y qué pasó. Solo para `service_role`. */
create or replace function public.helios_whatsapp_inbound_done(
  p_message_id text,
  p_route      text,
  p_result     jsonb default null
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.whatsapp_inbound
     set route = p_route, result = p_result, routed_at = now()
   where wa_message_id = p_message_id;
$$;

revoke all on function public.helios_whatsapp_inbound_done(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.helios_whatsapp_inbound_done(text, text, jsonb) to service_role;
