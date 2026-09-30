-- ============================================================================
-- Ronda — Alta de comercio: RIF obligatorio, red social y logo en Storage
--
-- Tres cambios al alta que hasta ahora dejaban comercios a medio hacer:
--
--   1. **El RIF pasa a ser obligatorio.** Es el identificador fiscal del
--      local: sin él no se le puede facturar la comisión ni justificar una
--      transferencia. Era `default null` y el 90% de las altas lo saltaba.
--
--   2. **Red social.** El local se reconoce por su Instagram más que por su
--      razón social. Va en la tarjeta de Buscar, debajo del nombre.
--
--   3. **El logo deja de ser una URL tecleada a mano.** Pasa a un bucket de
--      Storage: pegar una URL de un CDN ajeno significa que el día que esa
--      imagen desaparezca, la tarjeta del comercio se queda vacía y nadie se
--      entera.
--
-- Sobre el RIF y las filas que ya existen: la columna **no** se pone
-- `not null`. Hay comercios dados de alta antes de hoy sin RIF, y un
-- `alter column set not null` reventaría la migración en cualquier entorno
-- donde exista uno. La obligación se impone donde de verdad importa —en la
-- RPC de alta— y el editor permite completarlo después. Poner el constraint
-- cuando no quede ninguno sin RIF es una migración de una línea.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columna de red social
-- ---------------------------------------------------------------------------
-- Una sola URL, no un campo por red. Un local tiene la que tiene —casi
-- siempre Instagram— y una tabla de "redes del comercio" para eso sería
-- estructura sin uso. La app deduce de qué red es mirando el dominio.

alter table public.merchants
  add column if not exists social_url text;

comment on column public.merchants.social_url is
  'Perfil público del local (Instagram, TikTok…). Se guarda como URL completa; la app deriva el nombre de la red del dominio.';

-- Que sea una URL de verdad. Sin esto entra "instagram: @barnocturno" y la
-- app intenta abrirlo como enlace y no pasa nada — un fallo mudo.
alter table public.merchants
  add constraint merchants_social_url_is_http
  check (social_url is null or social_url ~* '^https?://[^\s]+$');

-- ---------------------------------------------------------------------------
-- 2. Bucket de logos
-- ---------------------------------------------------------------------------
-- Público, al revés que `kyc-documents`. Un logo es lo que el local enseña
-- en la calle: no hay nada que proteger, y hacerlo privado obligaría a
-- firmar una URL por cada tarjeta de la parrilla de Buscar.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'merchant-logos',
  'merchant-logos',
  true,
  2097152,                        -- 2 MB: es un logo, no una foto de producto
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Escribir solo el super admin. El alta de comercios es suya (docs/00-BASES
-- §2.9) y el logo es parte del alta; el personal del local no lo toca.
--
-- Convención de rutas: {merchant_id}/logo-{timestamp}.{ext}
-- El timestamp evita que el navegador siga enseñando el logo viejo desde su
-- caché cuando se reemplaza — con un nombre fijo, cambiar el logo no se ve.

create policy "merchant_logos_write_super_admin"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'merchant-logos'
    and exists (
      select 1 from public.platform_admins
      where user_id = (select auth.uid()) and is_active and role = 'super_admin'
    )
  );

create policy "merchant_logos_update_super_admin"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'merchant-logos'
    and exists (
      select 1 from public.platform_admins
      where user_id = (select auth.uid()) and is_active and role = 'super_admin'
    )
  );

create policy "merchant_logos_delete_super_admin"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'merchant-logos'
    and exists (
      select 1 from public.platform_admins
      where user_id = (select auth.uid()) and is_active and role = 'super_admin'
    )
  );

-- Leer no necesita política: el bucket es público.

-- ---------------------------------------------------------------------------
-- 3. Normalizar el RIF
-- ---------------------------------------------------------------------------
-- El RIF venezolano es una letra de tipo (J jurídico, G gobierno, V/E
-- persona, P pasaporte) y ocho o nueve dígitos. Llega escrito de siete
-- formas: "j-123456789", "J123456789", "J-12345678-9".
--
-- Se guarda siempre igual —mayúscula, un guion, sin espacios— porque
-- `merchants.tax_id` es `unique`: sin normalizar, el mismo local se puede dar
-- de alta dos veces escribiéndolo distinto, y el índice no lo impediría.

create or replace function public.normalize_tax_id(p_tax_id text)
returns text
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
declare
  v_clean text;
  v_letter text;
  v_digits text;
begin
  v_clean := upper(regexp_replace(coalesce(p_tax_id, ''), '[^A-Za-z0-9]', '', 'g'));

  if v_clean = '' then
    return null;
  end if;

  v_letter := substring(v_clean from 1 for 1);
  v_digits := substring(v_clean from 2);

  if v_letter !~ '^[JGVEP]$' or v_digits !~ '^[0-9]{8,9}$' then
    raise exception 'RIF no válido: debe ser una letra J, G, V, E o P seguida de 8 o 9 dígitos (ej. J-123456789)'
      using errcode = '22023';
  end if;

  return v_letter || '-' || v_digits;
end;
$$;

revoke all on function public.normalize_tax_id(text) from public, anon;
grant execute on function public.normalize_tax_id(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Alta de comercio: RIF obligatorio y red social
-- ---------------------------------------------------------------------------

create or replace function public.admin_create_merchant(
  p_name       text,
  p_legal_name text default null,
  p_tax_id     text default null,
  p_category   public.merchant_category default null,
  p_city       text default null,
  p_handle     text default null,
  p_logo_url   text default null,
  p_social_url text default null
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

  -- Obligatorio desde 2026-08-25. La validación vive aquí y no en un
  -- constraint de columna porque hay filas antiguas sin RIF que deben poder
  -- seguir existiendo mientras se completan.
  v_tax_id := public.normalize_tax_id(p_tax_id);
  if v_tax_id is null then
    raise exception 'El RIF es obligatorio' using errcode = '22023';
  end if;

  if exists (select 1 from public.merchants where tax_id = v_tax_id) then
    raise exception 'Ya hay un comercio dado de alta con el RIF %', v_tax_id
      using errcode = '23505';
  end if;

  -- Se guarda sin `@`: la app ya lo antepone al mostrarlo (buscar.tsx), y
  -- guardarlo con o sin arroba según lo que tecleó cada admin habría hecho
  -- que la búsqueda por handle nunca fuera consistente.
  v_handle := nullif(trim(coalesce(p_handle, '')), '');
  if v_handle is not null then
    v_handle := regexp_replace(v_handle, '^@+', '');
  end if;

  insert into public.merchants
    (name, legal_name, tax_id, category, city, handle, logo_url, social_url)
  values (
    trim(p_name),
    nullif(trim(coalesce(p_legal_name, '')), ''),
    v_tax_id,
    p_category,
    nullif(trim(coalesce(p_city, '')), ''),
    v_handle,
    nullif(trim(coalesce(p_logo_url, '')), ''),
    nullif(trim(coalesce(p_social_url, '')), '')
  )
  returning * into v_row;

  perform audit.log(v_actor, 'merchant.created', v_row.id,
    jsonb_build_object('name', v_row.name, 'tax_id', v_row.tax_id, 'category', v_row.category));

  return v_row;
end;
$$;

revoke all on function public.admin_create_merchant(
  text, text, text, public.merchant_category, text, text, text, text
) from public, anon;
grant execute on function public.admin_create_merchant(
  text, text, text, public.merchant_category, text, text, text, text
) to authenticated;

-- Las firmas viejas quedan muertas. No es limpieza cosmética: mientras
-- existan, una llamada con solo los parámetros que ellas aceptan resuelve a
-- una función que **no exige RIF**, y la obligación de arriba se salta sin
-- que nadie tenga que hacer nada raro.
--
-- La de 3 argumentos venía de 20260822110000 y llevaba desde entonces
-- conviviendo con la de 7 sin que se notara, porque el panel siempre mandaba
-- los siete.
drop function if exists public.admin_create_merchant(
  text, text, text, public.merchant_category, text, text, text
);
drop function if exists public.admin_create_merchant(text, text, text);

-- ---------------------------------------------------------------------------
-- 5. Editar el perfil: red social y RIF
-- ---------------------------------------------------------------------------
-- El RIF se puede editar aquí para poder completar los comercios que se
-- dieron de alta sin él. Se sigue admitiendo vacío en la edición: forzarlo
-- impediría guardar un cambio de ciudad en un comercio antiguo.

create or replace function public.admin_set_merchant_profile(
  p_merchant_id uuid,
  p_category    public.merchant_category,
  p_city        text,
  p_handle      text,
  p_logo_url    text,
  p_social_url  text default null,
  p_tax_id      text default null
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

  v_tax_id := public.normalize_tax_id(p_tax_id);

  if v_tax_id is not null and exists (
    select 1 from public.merchants where tax_id = v_tax_id and id <> p_merchant_id
  ) then
    raise exception 'Ese RIF ya es de otro comercio' using errcode = '23505';
  end if;

  update public.merchants
    set category   = p_category,
        city       = nullif(trim(coalesce(p_city, '')), ''),
        handle     = v_handle,
        logo_url   = nullif(trim(coalesce(p_logo_url, '')), ''),
        social_url = nullif(trim(coalesce(p_social_url, '')), ''),
        -- Null deja el RIF como estaba: la pantalla de perfil no debe poder
        -- borrar un identificador fiscal por omisión.
        tax_id     = coalesce(v_tax_id, tax_id),
        updated_at = now()
  where id = p_merchant_id;

  if not found then
    raise exception 'Comercio no encontrado' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.set_profile', p_merchant_id, jsonb_build_object(
    'category', p_category, 'city', p_city, 'handle', v_handle,
    'logo_url', p_logo_url, 'social_url', p_social_url, 'tax_id', v_tax_id
  ));
end;
$$;

revoke all on function public.admin_set_merchant_profile(
  uuid, public.merchant_category, text, text, text, text, text
) from public, anon;
grant execute on function public.admin_set_merchant_profile(
  uuid, public.merchant_category, text, text, text, text, text
) to authenticated;

drop function if exists public.admin_set_merchant_profile(
  uuid, public.merchant_category, text, text, text
);

-- ---------------------------------------------------------------------------
-- 6. Que el panel y la app lo lean
-- ---------------------------------------------------------------------------
-- `CREATE OR REPLACE VIEW` solo deja añadir columnas al final, así que
-- `social_url` va después de `logo_url`.

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
  m.logo_url,
  m.social_url
from public.merchants m;

grant select on public.merchant_directory to authenticated;

-- La ficha de edición necesita los dos campos nuevos. El RIF va aquí porque
-- el editor es el único sitio donde se puede completar el de un comercio
-- antiguo que se dio de alta sin él.

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
      'logo_url', v_merchant.logo_url,
      'social_url', v_merchant.social_url,
      'tax_id', v_merchant.tax_id
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
