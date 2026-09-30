-- ============================================================================
-- Ronda — Los campos de comercio que faltaban en el alta del super admin
--
-- La migración 20260822170500 le añadió a `merchants` cuatro columnas para
-- la pantalla de Buscar de la app (Figma 20:3182): `category`, `city`,
-- `handle` y `logo_url`. Pero `admin_create_merchant()` —el único lugar
-- desde donde se crea un comercio, docs/00-BASES §2.9— nunca se actualizó
-- para aceptarlos. El resultado: todo comercio dado de alta desde el panel
-- nace con los cuatro en null, y por eso ninguno aparece filtrable por
-- categoría o ciudad en la app, ni tiene logo. Los únicos comercios con
-- estos campos son los cinco de `seed.sql`, que los insertan a mano por
-- fuera de la RPC — un atajo de datos de prueba, no algo que reproduzca lo
-- que puede hacer el super admin real.
--
-- Esto cierra el hueco en los dos sentidos: se puede fijar el perfil al
-- crear, y se puede corregir después (categoría mal puesta, ciudad, un
-- logo que no existía todavía).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Alta de comercio — ahora acepta el perfil completo
-- ---------------------------------------------------------------------------
-- Solo se añaden parámetros nuevos al final, todos con default: es la forma
-- de ampliar una función por CREATE OR REPLACE sin tener que soltarla ni
-- romper el overload existente.

create or replace function public.admin_create_merchant(
  p_name       text,
  p_legal_name text default null,
  p_tax_id     text default null,
  p_category   public.merchant_category default null,
  p_city       text default null,
  p_handle     text default null,
  p_logo_url   text default null
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
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede dar de alta comercios'
      using errcode = '42501';
  end if;

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'El comercio necesita nombre' using errcode = '22023';
  end if;

  -- Se guarda sin `@`: la app ya lo antepone al mostrarlo (buscar.tsx), y
  -- guardarlo con o sin arroba según lo que tecleó cada admin habría hecho
  -- que la búsqueda por handle nunca fuera consistente.
  v_handle := nullif(trim(coalesce(p_handle, '')), '');
  if v_handle is not null then
    v_handle := regexp_replace(v_handle, '^@+', '');
  end if;

  insert into public.merchants (name, legal_name, tax_id, category, city, handle, logo_url)
  values (
    trim(p_name),
    nullif(trim(coalesce(p_legal_name, '')), ''),
    nullif(trim(coalesce(p_tax_id, '')), ''),
    p_category,
    nullif(trim(coalesce(p_city, '')), ''),
    v_handle,
    nullif(trim(coalesce(p_logo_url, '')), '')
  )
  returning * into v_row;

  perform audit.log(v_actor, 'merchant.created', v_row.id,
    jsonb_build_object('name', v_row.name, 'tax_id', v_row.tax_id, 'category', v_row.category));

  return v_row;
end;
$$;

revoke all on function public.admin_create_merchant(
  text, text, text, public.merchant_category, text, text, text
) from public, anon;
grant execute on function public.admin_create_merchant(
  text, text, text, public.merchant_category, text, text, text
) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Editar el perfil después de creado
-- ---------------------------------------------------------------------------
-- Separado de `admin_set_settlement_terms` a propósito: son dos motivos de
-- cambio distintos (condiciones de negocio vs. cómo se ve el comercio en la
-- app) y una persona puede tocar uno sin que le pidan tocar el otro.

create or replace function public.admin_set_merchant_profile(
  p_merchant_id uuid,
  p_category    public.merchant_category,
  p_city        text,
  p_handle      text,
  p_logo_url    text
)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_handle text;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede editar comercios' using errcode = '42501';
  end if;

  v_handle := nullif(trim(coalesce(p_handle, '')), '');
  if v_handle is not null then
    v_handle := regexp_replace(v_handle, '^@+', '');
  end if;

  update public.merchants
    set category = p_category,
        city     = nullif(trim(coalesce(p_city, '')), ''),
        handle   = v_handle,
        logo_url = nullif(trim(coalesce(p_logo_url, '')), ''),
        updated_at = now()
  where id = p_merchant_id;

  if not found then
    raise exception 'Comercio no encontrado' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.set_profile', p_merchant_id, jsonb_build_object(
    'category', p_category, 'city', p_city, 'handle', v_handle, 'logo_url', p_logo_url
  ));
end;
$$;

revoke all on function public.admin_set_merchant_profile(uuid, public.merchant_category, text, text, text)
  from public, anon;
grant execute on function public.admin_set_merchant_profile(uuid, public.merchant_category, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Que el panel pueda leerlos: la lista y la ficha de edición
-- ---------------------------------------------------------------------------

-- `CREATE OR REPLACE VIEW` no permite insertar columnas en medio de la
-- lista existente, solo añadirlas al final — por eso category/city/handle/
-- logo_url van después de `sales_count` y no junto a `status`, que es donde
-- se leerían más natural.
create or replace view public.merchant_directory
with (security_invoker = true)
as
select
  m.id,
  m.name,
  m.legal_name,
  m.tax_id,
  m.status,
  m.created_at,
  (select count(*) from public.merchant_users mu
     where mu.merchant_id = m.id and mu.is_active) as staff_count,
  (select count(*) from public.charges c
     where c.merchant_id = m.id and c.status = 'confirmed') as sales_count,
  m.category,
  m.city,
  m.handle,
  m.logo_url
from public.merchants m;

grant select on public.merchant_directory to authenticated;

create or replace function public.admin_merchant_detail(p_merchant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
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
    raise exception 'Comercio no encontrado' using errcode = 'P0002';
  end if;

  select * into v_terms from public.merchant_settlement_terms
  where merchant_id = p_merchant_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', mu.user_id,
    'name', coalesce(p.full_name, au.raw_user_meta_data ->> 'full_name'),
    'email', au.email,
    'phone', p.phone_e164,
    'role', mu.role,
    'branch', b.name
  ) order by mu.created_at), '[]'::jsonb) into v_staff
  from public.merchant_users mu
  join auth.users au on au.id = mu.user_id
  left join public.profiles p on p.id = mu.user_id
  left join public.merchant_branches b on b.id = mu.branch_id
  where mu.merchant_id = p_merchant_id and mu.is_active;

  select coalesce(sum(amount_usd), 0) into v_owed
  from public.settlements
  where merchant_id = p_merchant_id and status = 'pending';

  return jsonb_build_object(
    'profile', jsonb_build_object(
      'category', v_merchant.category,
      'city', v_merchant.city,
      'handle', v_merchant.handle,
      'logo_url', v_merchant.logo_url
    ),
    'terms', jsonb_build_object(
      'upfront_pct', v_terms.upfront_pct,
      'per_installment_pct', v_terms.per_installment_pct,
      'commission_pct', v_terms.commission_pct,
      'policy', v_terms.policy
    ),
    'staff', v_staff,
    'pending_usd', v_owed
  );
end;
$$;

revoke all on function public.admin_merchant_detail(uuid) from public, anon;
grant execute on function public.admin_merchant_detail(uuid) to authenticated;
