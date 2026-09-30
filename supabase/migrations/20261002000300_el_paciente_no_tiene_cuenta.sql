-- ============================================================================
-- Helios — El paciente NO tiene cuenta (H3, docs/00 §4.4)
--
-- En Ronda cada deudor era un usuario de Auth: se registraba en la app con su
-- teléfono, `on_auth_user_created → handle_new_user` le creaba el perfil con
-- el mismo id, y todas las tablas del deudor apuntaban a `auth.users`. En
-- Helios el paciente nunca entra a ningún sitio: lo registra la secretaria
-- (H4, `create_patient_charge`) y solo existe como fila de `profiles`. En Auth
-- solo vive el PERSONAL (clínicas y equipo Helios), y esas cuentas no deben
-- crear perfiles de paciente.
--
-- 1. `profiles.id` pierde la FK a `auth.users` y nace de `gen_random_uuid()`.
--    Un paciente nuevo nace `active` y con nivel 1 (defaults nuevos): no hay
--    KYC ni PIN que lo activen. `grant_first_level_on_activation` solo mira
--    UPDATE de `pending_kyc/pending_pin → active`, así que un INSERT directo en
--    `active` no la dispara y no escribe `level_changes` (no hay subida que
--    contar: se nace en el 1).
-- 2. Fuera el trigger `on_auth_user_created` y su función `handle_new_user`:
--    `admin_create_auth_account` (personal) ya no deja perfiles huérfanos.
-- 3. Las FK de las columnas del DEUDOR que iban a `auth.users` pasan a
--    `profiles(id)`, y sin `on delete cascade`: un paciente con deuda no se
--    borra (el libro es append-only). Las columnas de ACTOR del personal
--    (`requested_by`, `reviewed_by`, `waived_by`, `blocked_by`, `actor`…)
--    siguen en `auth.users`. `collection_contacts.user_id` ya apuntaba a
--    `profiles`.
-- 4. `phone_e164` sigue obligatorio pero deja de ser único (una familia
--    comparte teléfono; el repetido será una alerta en H10). La identidad es
--    la cédula: `document_key` sigue siendo única.
-- 5. Columnas nuevas del paciente (docs/01 §1.3) y ayudas para validar,
--    normalizar y enmascarar, que usarán H4, H6 y H10.
-- 6. `profile_change_requests`: los datos que la clínica teclea distintos de
--    los registrados no se sobrescriben; quedan como propuesta para Helios.
-- 7. Fuera el acceso del deudor a lo suyo: las políticas `*_read_own` por
--    `auth.uid()` en tablas del deudor (el paciente no se autentica). Se
--    quedan las de admin y las del personal.
-- 8. `quote_installments(uuid[])` y `report_payment(...)` (la app: el deudor
--    cotizaba y reportaba con su sesión) se quedan en la base pero SIN permiso
--    de ejecución para nadie de la API. Las suites de pago las siguen usando
--    como camino interno hasta que exista `admin_register_payment` (fase 3),
--    que las sustituye. Entonces se podan.
-- 9. `metricas.solicitudes` hacía INNER JOIN con `auth.users` para leer si el
--    teléfono estaba confirmado: con pacientes sin cuenta, la vista se quedaba
--    vacía. Ahora sale solo de `profiles` (el teléfono lo registra la clínica:
--    `telefono_confirmado` = true).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1 y 2. El perfil ya no nace de Auth
-- ---------------------------------------------------------------------------

drop trigger on_auth_user_created on auth.users;
drop function public.handle_new_user();

alter table public.profiles drop constraint profiles_id_fkey;
alter table public.profiles alter column id     set default gen_random_uuid();
alter table public.profiles alter column status set default 'active';
alter table public.profiles alter column level  set default 1;

comment on table public.profiles is
  'Pacientes (deudores). No tienen cuenta en Auth: los registra el personal de una clínica. La identidad es la cédula (document_key, única).';

-- ---------------------------------------------------------------------------
-- 3. Las columnas del deudor apuntan a profiles
-- ---------------------------------------------------------------------------

alter table public.charges            drop constraint charges_user_id_fkey;
alter table public.installments       drop constraint installments_user_id_fkey;
alter table public.user_credit_blocks drop constraint user_credit_blocks_user_id_fkey;
alter table public.payment_quotes     drop constraint payment_quotes_user_id_fkey;
alter table public.payment_reports    drop constraint payment_reports_user_id_fkey;
alter table public.level_changes      drop constraint level_changes_user_id_fkey;
alter table public.notifications      drop constraint notifications_user_id_fkey;
alter table public.late_fees          drop constraint late_fees_user_id_fkey;
alter table public.user_blocks        drop constraint user_blocks_user_id_fkey;

alter table public.charges            add constraint charges_user_id_fkey            foreign key (user_id) references public.profiles(id);
alter table public.installments       add constraint installments_user_id_fkey       foreign key (user_id) references public.profiles(id);
alter table public.user_credit_blocks add constraint user_credit_blocks_user_id_fkey foreign key (user_id) references public.profiles(id);
alter table public.payment_quotes     add constraint payment_quotes_user_id_fkey     foreign key (user_id) references public.profiles(id);
alter table public.payment_reports    add constraint payment_reports_user_id_fkey    foreign key (user_id) references public.profiles(id);
alter table public.level_changes      add constraint level_changes_user_id_fkey      foreign key (user_id) references public.profiles(id);
alter table public.notifications      add constraint notifications_user_id_fkey      foreign key (user_id) references public.profiles(id);
alter table public.late_fees          add constraint late_fees_user_id_fkey          foreign key (user_id) references public.profiles(id);
alter table public.user_blocks        add constraint user_blocks_user_id_fkey        foreign key (user_id) references public.profiles(id);

-- ---------------------------------------------------------------------------
-- 4. El teléfono deja de ser único
-- ---------------------------------------------------------------------------

alter table public.profiles drop constraint profiles_phone_e164_key;
create index profiles_phone_e164_idx on public.profiles (phone_e164);

-- ---------------------------------------------------------------------------
-- 5. Ayudas: normalizar, validar y enmascarar
-- ---------------------------------------------------------------------------

/**
 * Un móvil venezolano en E.164 (`+58` + 10 dígitos), o null si no lo es.
 * Acepta `04141234567`, `4141234567`, `+58 414-123.45.67`, `584141234567`.
 * Prefijos móviles: 0412, 0414, 0416, 0422, 0424, 0426 (la misma lista que
 * Ronda desde 20260926100000_el_0422_es_un_movil).
 */
create or replace function public.helios_normalize_ve_mobile(p_phone text)
returns text
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
declare
  v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if v_digits ~ '^58[0-9]{10}$' then
    v_digits := substr(v_digits, 3);
  elsif v_digits ~ '^0[0-9]{10}$' then
    v_digits := substr(v_digits, 2);
  end if;

  if v_digits !~ '^(412|414|416|422|424|426)[0-9]{7}$' then
    return null;
  end if;

  return '+58' || v_digits;
end;
$$;

/** Un correo con forma de correo: algo@dominio.tld, sin espacios, ≤ 254. */
create or replace function public.helios_valid_email(p_email text)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select coalesce(
    length(p_email) <= 254
    and p_email ~ '^[A-Za-z0-9._%+''-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$',
    false);
$$;

/** «José Pérez» → «J*** P***». Cada palabra: su inicial y tres asteriscos. */
create or replace function public.helios_mask_name(p_name text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select nullif(string_agg(left(w, 1) || '***', ' ' order by n), '')
  from regexp_split_to_table(btrim(coalesce(p_name, '')), '\s+') with ordinality as t(w, n)
  where w <> '';
$$;

/** «+584141234567» → «0414-***-**67». Lo que no sea un móvil VE: «***» + 2 últimos. */
create or replace function public.helios_mask_phone(p_phone text)
returns text
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
declare
  v_e164   text := public.helios_normalize_ve_mobile(p_phone);
  v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if v_e164 is not null then
    return '0' || substr(v_e164, 4, 3) || '-***-**' || right(v_e164, 2);
  end if;
  if length(v_digits) < 2 then
    return null;
  end if;
  return '***' || right(v_digits, 2);
end;
$$;

/** «jose@gmail.com» → «j***@gmail.com». */
create or replace function public.helios_mask_email(p_email text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case
    when p_email is null or position('@' in p_email) < 2 then null
    else left(p_email, 1) || '***' || substr(p_email, position('@' in p_email))
  end;
$$;

/** «V12345678» → «V-****5678». Pasaporte u otro: «****» + 4 últimos. */
create or replace function public.helios_mask_document(p_document text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case
    when public.normalize_document(p_document) is null then null
    when public.normalize_document(p_document) ~ '^[VE][0-9]+$'
      then left(public.normalize_document(p_document), 1) || '-****'
           || right(public.normalize_document(p_document), 4)
    else '****' || right(public.normalize_document(p_document), 4)
  end;
$$;

revoke all on function public.helios_normalize_ve_mobile(text) from public, anon;
revoke all on function public.helios_valid_email(text)          from public, anon;
revoke all on function public.helios_mask_name(text)            from public, anon;
revoke all on function public.helios_mask_phone(text)           from public, anon;
revoke all on function public.helios_mask_email(text)           from public, anon;
revoke all on function public.helios_mask_document(text)        from public, anon;
grant execute on function public.helios_normalize_ve_mobile(text) to authenticated;
grant execute on function public.helios_valid_email(text)          to authenticated;
grant execute on function public.helios_mask_name(text)            to authenticated;
grant execute on function public.helios_mask_phone(text)           to authenticated;
grant execute on function public.helios_mask_email(text)           to authenticated;
grant execute on function public.helios_mask_document(text)        to authenticated;

-- ---------------------------------------------------------------------------
-- 5b. Columnas nuevas del paciente
-- ---------------------------------------------------------------------------
-- `email` es obligatorio para los pacientes nuevos (lo exige
-- `create_patient_charge`, H4: ahí llega el comprobante) pero nullable en la
-- tabla. Se guarda en minúsculas. `email_invalid_at` lo marca el despacho de
-- correos (H6) cuando el comprobante rebota.

alter table public.profiles
  add column email                  text,
  add column email_invalid_at       timestamptz,
  add column sex                    text,
  add column state                  text,
  add column city                   text,
  add column address                text,
  add column occupation             text,
  add column reference_name         text,
  add column reference_phone        text,
  add column reference_relationship text,
  add column registered_by          uuid references auth.users(id),
  add column registered_merchant_id uuid references public.merchants(id);

alter table public.profiles
  add constraint profiles_sex_check   check (sex is null or sex in ('F', 'M')),
  add constraint profiles_email_check check (
    email is null or (email = lower(btrim(email)) and public.helios_valid_email(email)));

create index profiles_email_idx on public.profiles (email) where email is not null;
create index profiles_registered_merchant_idx on public.profiles (registered_merchant_id)
  where registered_merchant_id is not null;

comment on column public.profiles.email is 'Correo del paciente, en minúsculas. Ahí llega el comprobante del financiamiento (H6).';
comment on column public.profiles.email_invalid_at is 'Cuándo rebotó un correo a esta dirección (H6). Null = sin rebotes.';
comment on column public.profiles.registered_by is 'Personal (auth.users) que registró al paciente.';
comment on column public.profiles.registered_merchant_id is 'Clínica donde se registró el paciente por primera vez.';

-- ---------------------------------------------------------------------------
-- 6. Propuestas de cambio de datos
-- ---------------------------------------------------------------------------

create table public.profile_change_requests (
  id            uuid primary key default gen_random_uuid(),
  profile_id    uuid not null references public.profiles(id),
  merchant_id   uuid references public.merchants(id),
  requested_by  uuid references auth.users(id),
  field_changes jsonb not null check (jsonb_typeof(field_changes) = 'object'),
  status        text not null default 'pendiente'
                check (status in ('pendiente', 'aprobado', 'rechazado')),
  reviewed_by   uuid references auth.users(id),
  reviewed_at   timestamptz,
  note          text,
  created_at    timestamptz not null default now(),
  constraint profile_change_requests_revisada
    check ((status = 'pendiente') = (reviewed_at is null))
);

comment on table public.profile_change_requests is
  'Datos de contacto que una clínica tecleó distintos de los registrados. No sobrescriben nada: los revisa Helios. field_changes = {campo: {"antes": …, "propuesto": …}}.';

create index profile_change_requests_pendientes_idx
  on public.profile_change_requests (created_at) where status = 'pendiente';
create index profile_change_requests_profile_idx
  on public.profile_change_requests (profile_id);

alter table public.profile_change_requests enable row level security;
revoke all on public.profile_change_requests from anon, authenticated;
grant select on public.profile_change_requests to authenticated;

create policy profile_change_requests_read_admin on public.profile_change_requests
  for select to authenticated
  using ((select public.is_platform_admin()));

-- ---------------------------------------------------------------------------
-- 7. Sin acceso del deudor a lo suyo
-- ---------------------------------------------------------------------------

drop policy profiles_read_own          on public.profiles;
drop policy charges_read_own           on public.charges;
drop policy charges_read_debtor        on public.charges;
drop policy charge_items_read_own      on public.charge_items;
drop policy installments_read_own      on public.installments;
drop policy late_fees_read_own         on public.late_fees;
drop policy level_changes_read_own     on public.level_changes;
drop policy notifications_read_own     on public.notifications;
drop policy notifications_mark_own_read on public.notifications;
drop policy payment_quotes_read_own    on public.payment_quotes;
drop policy quote_items_read_own       on public.payment_quote_items;
drop policy quote_late_fees_read_own   on public.payment_quote_late_fees;
drop policy payment_reports_read_own   on public.payment_reports;
drop policy credit_blocks_read_own     on public.user_credit_blocks;

-- `merchants_read_visible` dejaba ver al deudor los locales donde debía.
-- Se queda el resto: los activos y los propios del personal.
drop policy merchants_read_visible on public.merchants;
create policy merchants_read_visible on public.merchants
  for select to authenticated
  using (
    ((status = 'active'::public.merchant_status) and not is_test)
    or id in (select public.my_merchant_ids())
  );

-- ---------------------------------------------------------------------------
-- 8. Las RPC del deudor con sesión: sin ejecución desde la API
-- ---------------------------------------------------------------------------

revoke execute on function public.quote_installments(uuid[]) from public, anon, authenticated;
revoke execute on function public.report_payment(uuid, text, text, text, text, text, text)
  from public, anon, authenticated;

comment on function public.quote_installments(uuid[]) is
  'App de Ronda (el deudor cotizaba con su sesión). En Helios sin permiso para la API: solo la usan las suites. Se poda con admin_register_payment (fase 3).';
comment on function public.report_payment(uuid, text, text, text, text, text, text) is
  'App de Ronda (el deudor reportaba su pago). En Helios sin permiso para la API: solo la usan las suites. Se poda con admin_register_payment (fase 3).';

-- ---------------------------------------------------------------------------
-- 9. metricas.solicitudes sin auth.users
-- ---------------------------------------------------------------------------

create or replace view metricas.solicitudes as
 SELECT p.id AS user_id,
    p.created_at AS solicito_en,
    metricas.dia_operativo(p.created_at) AS solicito_dia,
    metricas.lunes(metricas.dia_operativo(p.created_at)) AS solicito_semana,
    -- Helios: el teléfono lo registra la clínica; no hay código que confirmar.
    true AS telefono_confirmado,
    ap.en IS NOT NULL AS verificado,
    ap.en AS verificado_en,
    metricas.dia_operativo(ap.en) AS verificado_dia,
    metricas.lunes(metricas.dia_operativo(ap.en)) AS verificado_semana,
        CASE
            WHEN ap.en IS NOT NULL THEN 'verificado'::text
            ELSE 'confirmo_el_telefono'::text
        END AS etapa,
    p.status::text AS estado,
    p.level AS nivel
   FROM profiles p
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN p.status::text <> ALL (ARRAY['pending_kyc'::text, 'pending_pin'::text]) THEN p.created_at
                    ELSE NULL::timestamp with time zone
                END AS en) ap
  WHERE NOT p.is_test;
