-- ============================================================================
-- Helios — El personal y la ficha de una clínica (H8, parte 2)
--
-- 1. `merchants` gana los datos de una clínica o consultorio: especialidad,
--    número MPPS (médico independiente), teléfono, correo y dirección.
-- 2. `merchant_payout_accounts`: a dónde se le transfiere a la clínica. Ronda
--    no lo guardaba (el equipo lo tenía fuera del sistema). Una fila por
--    clínica. La lee el equipo y el gerente (administrador) de esa clínica;
--    la escribe solo un super admin, por RPC y con bitácora.
-- 3. `admin_create_merchant` y `admin_set_merchant_profile` aceptan los datos
--    nuevos. Se añaden AL FINAL y con default, así que cualquier llamada
--    existente (posicional o por nombre) sigue igual. Como cambia la lista de
--    argumentos, se borra la firma vieja y se crea la nueva (con dos firmas
--    que solo difieren en parámetros con default, una llamada corta sería
--    ambigua). La categoría de una clínica NUEVA tiene que ser médica.
-- 4. `admin_merchant_detail` devuelve los datos nuevos y la cuenta de pago.
-- 5. El rol `inventario` (era del catálogo de productos, podado) queda en el
--    enum por las filas viejas, pero `merchant_staff_add` y
--    `merchant_staff_update` ya no lo asignan.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La ficha de la clínica
-- ---------------------------------------------------------------------------

alter table public.merchants
  add column specialty   text,
  add column mpps_number text,
  add column phone       text,
  add column email       text,
  add column address     text;

alter table public.merchants
  add constraint merchants_email_check check (
    email is null or (email = lower(btrim(email)) and public.helios_valid_email(email)));

comment on column public.merchants.specialty   is 'Especialidad de la clínica o del médico (texto libre).';
comment on column public.merchants.mpps_number is 'Número del Ministerio del Poder Popular para la Salud (médico independiente). Opcional.';

-- ---------------------------------------------------------------------------
-- 2. La cuenta de pago de la clínica
-- ---------------------------------------------------------------------------

create table public.merchant_payout_accounts (
  merchant_id      uuid primary key references public.merchants(id),
  bank             text,
  account_holder   text not null check (btrim(account_holder) <> ''),
  holder_document  text not null check (btrim(holder_document) <> ''),
  account_number   text check (account_number is null or account_number ~ '^[0-9]{20}$'),
  pago_movil_phone text,
  pago_movil_bank  text,
  updated_by       uuid references auth.users(id),
  updated_at       timestamptz not null default now(),
  constraint merchant_payout_accounts_algun_destino
    check (account_number is not null or pago_movil_phone is not null)
);

comment on table public.merchant_payout_accounts is
  'A dónde se le paga a cada clínica (transferencia y/o Pago Móvil). La escribe un super admin con admin_set_merchant_payout_account.';

alter table public.merchant_payout_accounts enable row level security;
revoke all on public.merchant_payout_accounts from anon, authenticated;
grant select on public.merchant_payout_accounts to authenticated;

create policy merchant_payout_accounts_read_admin on public.merchant_payout_accounts
  for select to authenticated
  using ((select public.is_platform_admin()));

create policy merchant_payout_accounts_read_gerente on public.merchant_payout_accounts
  for select to authenticated
  using (merchant_id in (
    select public.my_merchant_ids_with_role(array['gerente']::public.merchant_role[])));

/** La cuenta de pago de una clínica, o null si no tiene. Solo el equipo. */
create or replace function public.admin_merchant_payout_account(p_merchant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.merchant_payout_accounts%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_row from public.merchant_payout_accounts where merchant_id = p_merchant_id;
  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'merchant_id',      v_row.merchant_id,
    'bank',             v_row.bank,
    'account_holder',   v_row.account_holder,
    'holder_document',  v_row.holder_document,
    'account_number',   v_row.account_number,
    'pago_movil_phone', v_row.pago_movil_phone,
    'pago_movil_bank',  v_row.pago_movil_bank,
    'updated_at',       v_row.updated_at,
    'updated_by_name',  (select full_name from public.platform_admins where user_id = v_row.updated_by)
  );
end;
$$;

/**
 * Crea o reemplaza la cuenta de pago de una clínica. `p` trae `bank`,
 * `account_holder`, `holder_document`, `account_number` (20 dígitos),
 * `pago_movil_phone` (móvil VE) y `pago_movil_bank`. Hace falta titular,
 * documento y al menos un destino (cuenta o Pago Móvil). Solo super admin;
 * queda en la bitácora con el antes y el después.
 */
create or replace function public.admin_set_merchant_payout_account(p_merchant_id uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor   uuid := public.helios_assert_super_admin('cambiar la cuenta de pago de una clínica');
  v_antes   jsonb;
  v_holder  text := nullif(btrim(coalesce(p->>'account_holder', '')), '');
  v_doc     text := nullif(btrim(coalesce(p->>'holder_document', '')), '');
  v_account text := nullif(regexp_replace(coalesce(p->>'account_number', ''), '\D', '', 'g'), '');
  v_phone   text := nullif(btrim(coalesce(p->>'pago_movil_phone', '')), '');
  v_pm      text;
begin
  if not exists (select 1 from public.merchants where id = p_merchant_id) then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  if v_holder is null or v_doc is null then
    raise exception 'El titular y su RIF o cédula son obligatorios' using errcode = '22023';
  end if;

  -- RIF (J-123456789) o cédula (V12345678).
  if upper(v_doc) ~ '^[JGP]' then
    v_doc := public.normalize_tax_id(v_doc);
  else
    v_doc := public.normalize_document(v_doc);
  end if;

  if v_account is not null and v_account !~ '^[0-9]{20}$' then
    raise exception 'El número de cuenta tiene 20 dígitos' using errcode = '22023';
  end if;

  if v_phone is not null then
    v_pm := public.helios_normalize_ve_mobile(v_phone);
    if v_pm is null then
      raise exception 'Teléfono de Pago Móvil inválido' using errcode = '22023';
    end if;
  end if;

  if v_account is null and v_pm is null then
    raise exception 'Hace falta una cuenta bancaria o un Pago Móvil' using errcode = '22023';
  end if;

  select to_jsonb(a) - 'updated_by' - 'updated_at' into v_antes
  from public.merchant_payout_accounts a where a.merchant_id = p_merchant_id;

  insert into public.merchant_payout_accounts as a (
    merchant_id, bank, account_holder, holder_document, account_number,
    pago_movil_phone, pago_movil_bank, updated_by, updated_at
  ) values (
    p_merchant_id,
    nullif(btrim(coalesce(p->>'bank', '')), ''),
    v_holder, v_doc, v_account, v_pm,
    nullif(btrim(coalesce(p->>'pago_movil_bank', '')), ''),
    v_actor, now()
  )
  on conflict (merchant_id) do update
    set bank             = excluded.bank,
        account_holder   = excluded.account_holder,
        holder_document  = excluded.holder_document,
        account_number   = excluded.account_number,
        pago_movil_phone = excluded.pago_movil_phone,
        pago_movil_bank  = excluded.pago_movil_bank,
        updated_by       = excluded.updated_by,
        updated_at       = excluded.updated_at;

  perform audit.log(v_actor, 'merchant.payout_account_set', p_merchant_id, jsonb_build_object(
    'antes', v_antes,
    'despues', (select to_jsonb(a) - 'updated_by' - 'updated_at'
                from public.merchant_payout_accounts a where a.merchant_id = p_merchant_id)
  ));

  return public.admin_merchant_payout_account(p_merchant_id);
end;
$$;

revoke all on function public.admin_merchant_payout_account(uuid)            from public, anon;
revoke all on function public.admin_set_merchant_payout_account(uuid, jsonb) from public, anon;
grant execute on function public.admin_merchant_payout_account(uuid)            to authenticated;
grant execute on function public.admin_set_merchant_payout_account(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Alta y perfil de una clínica
-- ---------------------------------------------------------------------------

drop function public.admin_create_merchant(text, text, text, public.merchant_category, text, text, text, text);

create function public.admin_create_merchant(
  p_name        text,
  p_legal_name  text default null,
  p_tax_id      text default null,
  p_category    public.merchant_category default null,
  p_city        text default null,
  p_handle      text default null,
  p_logo_url    text default null,
  p_social_url  text default null,
  p_specialty   text default null,
  p_mpps_number text default null,
  p_phone       text default null,
  p_email       text default null,
  p_address     text default null
)
returns public.merchants
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_row    public.merchants%rowtype;
  v_handle text;
  v_tax_id text;
  v_email  text := nullif(lower(btrim(coalesce(p_email, ''))), '');
begin
  perform public.helios_assert_super_admin('dar de alta clínicas');

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'La clínica necesita nombre' using errcode = '22023';
  end if;

  -- Obligatorio desde 2026-08-25. La validación vive aquí y no en un
  -- constraint de columna porque hay filas antiguas sin RIF que deben poder
  -- seguir existiendo mientras se completan.
  v_tax_id := public.normalize_tax_id(p_tax_id);
  if v_tax_id is null then
    raise exception 'El RIF es obligatorio' using errcode = '22023';
  end if;

  if exists (select 1 from public.merchants where tax_id = v_tax_id) then
    raise exception 'Ya hay una clínica dada de alta con el RIF %', v_tax_id
      using errcode = '23505';
  end if;

  -- Helios: las categorías de la noche siguen en el enum, pero una clínica
  -- nueva es médica (o «otros»).
  if p_category in ('discoteca', 'conciertos') then
    raise exception 'Categoría no válida para una clínica' using errcode = '22023';
  end if;

  if v_email is not null and not public.helios_valid_email(v_email) then
    raise exception 'Correo inválido' using errcode = '22023';
  end if;

  -- Se guarda sin `@`.
  v_handle := nullif(trim(coalesce(p_handle, '')), '');
  if v_handle is not null then
    v_handle := regexp_replace(v_handle, '^@+', '');
  end if;

  insert into public.merchants
    (name, legal_name, tax_id, category, city, handle, logo_url, social_url,
     specialty, mpps_number, phone, email, address)
  values (
    trim(p_name),
    nullif(trim(coalesce(p_legal_name, '')), ''),
    v_tax_id,
    p_category,
    nullif(trim(coalesce(p_city, '')), ''),
    v_handle,
    nullif(trim(coalesce(p_logo_url, '')), ''),
    nullif(trim(coalesce(p_social_url, '')), ''),
    nullif(trim(coalesce(p_specialty, '')), ''),
    nullif(trim(coalesce(p_mpps_number, '')), ''),
    nullif(trim(coalesce(p_phone, '')), ''),
    v_email,
    nullif(trim(coalesce(p_address, '')), '')
  )
  returning * into v_row;

  perform audit.log(v_actor, 'merchant.created', v_row.id,
    jsonb_build_object('name', v_row.name, 'tax_id', v_row.tax_id, 'category', v_row.category,
                       'specialty', v_row.specialty, 'mpps_number', v_row.mpps_number));

  return v_row;
end;
$$;

revoke all on function public.admin_create_merchant(text, text, text, public.merchant_category, text, text, text, text, text, text, text, text, text) from public, anon;
grant execute on function public.admin_create_merchant(text, text, text, public.merchant_category, text, text, text, text, text, text, text, text, text) to authenticated;

drop function public.admin_set_merchant_profile(uuid, public.merchant_category, text, text, text, text, text);

/**
 * Edita el perfil de una clínica. Los campos de Ronda se comportan como antes
 * (se sobrescriben; el RIF null se deja). Los de Helios (especialidad, MPPS,
 * teléfono, correo, dirección): null = se deja como está, '' = se borra, para
 * que una pantalla que aún no los manda no los borre.
 */
create function public.admin_set_merchant_profile(
  p_merchant_id uuid,
  p_category    public.merchant_category,
  p_city        text,
  p_handle      text,
  p_logo_url    text,
  p_social_url  text default null,
  p_tax_id      text default null,
  p_specialty   text default null,
  p_mpps_number text default null,
  p_phone       text default null,
  p_email       text default null,
  p_address     text default null
)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_handle text;
  v_tax_id text;
  v_email  text := lower(btrim(p_email));
begin
  perform public.helios_assert_super_admin('editar clínicas');

  v_handle := nullif(trim(coalesce(p_handle, '')), '');
  if v_handle is not null then
    v_handle := regexp_replace(v_handle, '^@+', '');
  end if;

  v_tax_id := public.normalize_tax_id(p_tax_id);

  if v_tax_id is not null and exists (
    select 1 from public.merchants where tax_id = v_tax_id and id <> p_merchant_id
  ) then
    raise exception 'Ese RIF ya es de otra clínica' using errcode = '23505';
  end if;

  if nullif(v_email, '') is not null and not public.helios_valid_email(v_email) then
    raise exception 'Correo inválido' using errcode = '22023';
  end if;

  update public.merchants
    set category    = p_category,
        city        = nullif(trim(coalesce(p_city, '')), ''),
        handle      = v_handle,
        logo_url    = nullif(trim(coalesce(p_logo_url, '')), ''),
        social_url  = nullif(trim(coalesce(p_social_url, '')), ''),
        -- Null deja el RIF como estaba: la pantalla de perfil no debe poder
        -- borrar un identificador fiscal por omisión.
        tax_id      = coalesce(v_tax_id, tax_id),
        specialty   = case when p_specialty   is null then specialty   else nullif(trim(p_specialty), '')   end,
        mpps_number = case when p_mpps_number is null then mpps_number else nullif(trim(p_mpps_number), '') end,
        phone       = case when p_phone       is null then phone       else nullif(trim(p_phone), '')       end,
        email       = case when p_email       is null then email       else nullif(v_email, '')             end,
        address     = case when p_address     is null then address     else nullif(trim(p_address), '')     end,
        updated_at  = now()
  where id = p_merchant_id;

  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.set_profile', p_merchant_id, jsonb_build_object(
    'category', p_category, 'city', p_city, 'handle', v_handle,
    'logo_url', p_logo_url, 'social_url', p_social_url, 'tax_id', v_tax_id,
    'specialty', p_specialty, 'mpps_number', p_mpps_number, 'phone', p_phone,
    'email', v_email, 'address', p_address
  ));
end;
$$;

revoke all on function public.admin_set_merchant_profile(uuid, public.merchant_category, text, text, text, text, text, text, text, text, text, text) from public, anon;
grant execute on function public.admin_set_merchant_profile(uuid, public.merchant_category, text, text, text, text, text, text, text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. La ficha que ve el equipo
-- ---------------------------------------------------------------------------
-- La de Ronda, con los datos nuevos en `profile` y la clave nueva
-- `payout_account`. El teléfono del personal sale de Auth: el personal ya no
-- tiene fila en `profiles` (H3).

create or replace function public.admin_merchant_detail(p_merchant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_merchant public.merchants%rowtype;
  v_terms    public.merchant_settlement_terms%rowtype;
  v_staff    jsonb;
  v_owed     numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_merchant from public.merchants where id = p_merchant_id;
  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  select * into v_terms from public.merchant_settlement_terms
  where merchant_id = p_merchant_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', mu.user_id,
    'name', coalesce(nullif(trim(au.raw_user_meta_data ->> 'full_name'), ''), au.email),
    'email', au.email,
    'phone', au.phone,
    'role', mu.role,
    'branch', b.name
  ) order by mu.created_at), '[]'::jsonb) into v_staff
  from public.merchant_users mu
  join auth.users au on au.id = mu.user_id
  left join public.merchant_branches b on b.id = mu.branch_id
  where mu.merchant_id = p_merchant_id and mu.is_active;

  -- La misma cuenta que el guardia de `terminated`: es la cifra que la ficha
  -- enseña como «Le debes X» y la que decide si el botón de Terminar está vivo.
  select coalesce(sum(amount_usd - paid_usd), 0) into v_owed
  from public.settlements
  where merchant_id = p_merchant_id and status in ('pending', 'partial');

  return jsonb_build_object(
    'profile', jsonb_build_object(
      'category', v_merchant.category,
      'city', v_merchant.city,
      'handle', v_merchant.handle,
      'logo_url', v_merchant.logo_url,
      'social_url', v_merchant.social_url,
      'tax_id', v_merchant.tax_id,
      'specialty', v_merchant.specialty,
      'mpps_number', v_merchant.mpps_number,
      'phone', v_merchant.phone,
      'email', v_merchant.email,
      'address', v_merchant.address
    ),
    'terms', jsonb_build_object(
      'upfront_pct', v_terms.upfront_pct,
      'per_installment_pct', v_terms.per_installment_pct,
      'commission_pct', v_terms.commission_pct,
      'policy', v_terms.policy
    ),
    'staff', v_staff,
    'pending_usd', v_owed,
    'payout_account', public.admin_merchant_payout_account(p_merchant_id)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. El rol inventario no se asigna
-- ---------------------------------------------------------------------------
-- Copiadas de la base (pg_get_functiondef, 2026-09-30) con el bloque del rol
-- añadido y nada más.

-- ── public.merchant_staff_add
CREATE OR REPLACE FUNCTION public.merchant_staff_add(p_merchant_id uuid, p_email text, p_password text, p_full_name text, p_role merchant_role, p_branch_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor  uuid := auth.uid();
  v_user   uuid;
  v_branch uuid;
begin
  perform public.helios_assert_staff_manager(p_merchant_id);

  -- Helios (H8): el rol «inventario» era del catálogo de productos, que no
  -- existe. Queda en el enum por las filas viejas, pero no se asigna.
  if p_role = 'inventario' then
    raise exception 'El rol inventario no existe en Helios: elige administrador o secretaria'
      using errcode = '22023';
  end if;

  v_user   := public.admin_create_auth_account(p_email, p_password, p_full_name);
  v_branch := public.helios_branch_for_role(p_merchant_id, p_role, p_branch_id);

  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_user, p_merchant_id, v_branch, p_role)
  on conflict (user_id, merchant_id, branch_id) do update
    set role = excluded.role, is_active = true;

  perform audit.log(v_actor, 'merchant.staff_added', p_merchant_id,
    jsonb_build_object(
      'user_id', v_user,
      'email',   lower(trim(p_email)),
      'role',    p_role
    ));

  return jsonb_build_object('ok', true, 'user_id', v_user, 'branch_id', v_branch);
end;
$function$
;

-- ── public.merchant_staff_update
CREATE OR REPLACE FUNCTION public.merchant_staff_update(p_merchant_id uuid, p_user_id uuid, p_full_name text, p_role merchant_role, p_branch_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor  uuid := auth.uid();
  v_antes  public.merchant_role;
  v_nombre text := nullif(trim(coalesce(p_full_name, '')), '');
  v_branch uuid;
begin
  perform public.helios_assert_staff_manager(p_merchant_id, p_user_id);

  select role into v_antes
  from public.merchant_users
  where merchant_id = p_merchant_id and user_id = p_user_id and is_active
  order by created_at
  limit 1;

  if v_antes is null then
    raise exception 'Esa persona no es personal de este comercio' using errcode = 'P0002';
  end if;

  -- Helios (H8): el rol «inventario» era del catálogo de productos, que no
  -- existe. Queda en el enum por las filas viejas, pero no se asigna.
  if p_role = 'inventario' and v_antes is distinct from 'inventario' then
    raise exception 'El rol inventario no existe en Helios: elige administrador o secretaria'
      using errcode = '22023';
  end if;

  -- Candado 2: cambiarse el propio rol deja al local sin quien gestione su
  -- personal. El nombre sí se puede cambiar.
  if p_user_id = v_actor and p_role is distinct from v_antes then
    raise exception 'No puedes cambiarte el rol a ti mismo. Que lo haga otro gerente o el equipo de Helios.'
      using errcode = '42501';
  end if;

  if v_nombre is not null then
    update auth.users
      set raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
                               || jsonb_build_object('full_name', v_nombre),
          updated_at = now()
    where id = p_user_id;

    -- Solo si ya existe: una cuenta de panel no tiene fila en `profiles` y
    -- crearla aqui la metería en el padrón de consumidores, que es otra cosa.
    update public.profiles set full_name = v_nombre where id = p_user_id;
  end if;

  if p_role is distinct from v_antes or p_branch_id is not null then
    v_branch := public.helios_branch_for_role(p_merchant_id, p_role, p_branch_id);

    update public.merchant_users
      set is_active = false
    where merchant_id = p_merchant_id and user_id = p_user_id;

    insert into public.merchant_users (user_id, merchant_id, branch_id, role)
    values (p_user_id, p_merchant_id, v_branch, p_role)
    on conflict (user_id, merchant_id, branch_id) do update
      set role = excluded.role, is_active = true;
  end if;

  perform audit.log(v_actor, 'merchant.staff_updated', p_merchant_id,
    jsonb_build_object(
      'user_id', p_user_id,
      'name',    v_nombre,
      'before',  v_antes,
      'after',   p_role
    ));

  return jsonb_build_object('ok', true);
end;
$function$
;

