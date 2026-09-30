-- ============================================================================
-- Ronda — Super admin: cola de KYC y alta de comercios
--
-- Dos cosas que hasta ahora solo se podían hacer por SQL a mano:
--   * Aprobar o rechazar una verificación de identidad en revisión manual.
--   * Dar de alta un comercio con su personal.
--
-- El esquema `kyc` sigue sellado al cliente (sin grant, sin RLS de lectura):
-- la cola se expone por RPC en `public`, que devuelve solo lo que el revisor
-- necesita ver. En particular NO se devuelven los puntajes crudos de
-- similitud facial: sirven para decidir, no para que nadie calibre intentos.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Cola de KYC
-- ---------------------------------------------------------------------------

create or replace function public.admin_kyc_queue()
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, storage, pg_temp
stable
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at), '[]'::jsonb)
    into v_rows
  from (
    select
      v.id,
      v.user_id,
      p.phone_e164,
      v.extracted_name,
      v.extracted_document,
      v.extracted_birth,
      -- Los puntajes se redondean a un semáforo. El revisor necesita saber
      -- si la señal es buena o dudosa, no el número exacto.
      case
        when v.face_match_score is null then 'sin_dato'
        when v.face_match_score >= 0.75 then 'alta'
        when v.face_match_score >= 0.55 then 'media'
        else 'baja'
      end as face_match,
      case
        when v.liveness_score is null then 'sin_dato'
        when v.liveness_score >= 0.75 then 'alta'
        when v.liveness_score >= 0.55 then 'media'
        else 'baja'
      end as liveness,
      v.registry_matched,
      v.rejection_detail,
      v.document_path,
      v.selfie_path,
      v.created_at,
      extract(epoch from (now() - v.created_at))::bigint as waiting_seconds
    from kyc.verifications v
    join public.profiles p on p.id = v.user_id
    where v.status = 'manual_review'
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_kyc_queue() from public, anon;
grant execute on function public.admin_kyc_queue() to authenticated;

/**
 * Resuelve una verificación en revisión manual.
 *
 * Delega en kyc.review(), que ya sabe mover el perfil al estado que toca y
 * dejar rastro en kyc.decision_log. Aquí solo se añade la comprobación de
 * permisos y la bitácora de admin.
 */
create or replace function public.admin_review_kyc(
  p_verification_id uuid,
  p_approve         boolean,
  p_note            text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  if not p_approve and (p_note is null or length(trim(p_note)) = 0) then
    raise exception 'Rechazar una verificación requiere motivo' using errcode = '22023';
  end if;

  v_result := kyc.review(p_verification_id, p_approve, v_actor, p_note);

  perform audit.log(
    v_actor,
    case when p_approve then 'kyc.approved' else 'kyc.rejected' end,
    p_verification_id,
    jsonb_build_object('note', p_note)
  );

  return v_result;
end;
$$;

revoke all on function public.admin_review_kyc(uuid, boolean, text) from public, anon;
grant execute on function public.admin_review_kyc(uuid, boolean, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El revisor tiene que poder VER las capturas
-- ---------------------------------------------------------------------------
-- El bucket es privado y la política existente solo deja al usuario leer su
-- propia carpeta. Sin esto, la cola muestra nombres de archivo que nadie
-- puede abrir — y revisar una identidad sin mirar la cédula no es revisar.

create policy "kyc_read_admin"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'kyc-documents' and public.is_platform_admin()
  );

-- ---------------------------------------------------------------------------
-- 3. Alta de comercios
-- ---------------------------------------------------------------------------

/**
 * Crea un comercio. El trigger bootstrap_merchant le pone sola su sucursal
 * "Principal" y sus condiciones de liquidación por defecto (30/25/25/20).
 *
 * Solo `super_admin`: un operador concilia pagos y revisa identidades, pero
 * firmar un local es una decisión de negocio.
 */
create or replace function public.admin_create_merchant(
  p_name       text,
  p_legal_name text default null,
  p_tax_id     text default null
)
returns public.merchants
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_row   public.merchants%rowtype;
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

  insert into public.merchants (name, legal_name, tax_id)
  values (trim(p_name), nullif(trim(coalesce(p_legal_name, '')), ''),
          nullif(trim(coalesce(p_tax_id, '')), ''))
  returning * into v_row;

  perform audit.log(v_actor, 'merchant.created', v_row.id,
    jsonb_build_object('name', v_row.name, 'tax_id', v_row.tax_id));

  return v_row;
end;
$$;

revoke all on function public.admin_create_merchant(text, text, text) from public, anon;
grant execute on function public.admin_create_merchant(text, text, text) to authenticated;

/**
 * Vincula a una persona con un comercio por su teléfono.
 *
 * Se busca por teléfono y no por id porque es lo único que el dueño del local
 * sabe de su cajero. Si esa persona todavía no se ha registrado en la app, no
 * se puede vincular: se dice explícitamente en vez de crear un usuario
 * fantasma que luego colisiona cuando se registre de verdad.
 */
create or replace function public.admin_add_merchant_staff(
  p_merchant_id uuid,
  p_phone       text,
  p_role        public.merchant_role,
  p_branch_id   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_user   uuid;
  v_branch uuid := p_branch_id;
  v_digits text;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede asignar personal' using errcode = '42501';
  end if;

  -- GoTrue guarda el teléfono sin `+` ni separadores. Se normaliza a dígitos
  -- para que dé igual cómo lo escriba quien da de alta.
  v_digits := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');

  select id into v_user from auth.users
  where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_digits
  limit 1;

  if v_user is null then
    raise exception 'No hay ninguna cuenta con el teléfono %. Pídele que se registre primero en la app.', p_phone
      using errcode = 'P0002';
  end if;

  -- Un cajero siempre trabaja en una sucursal concreta (lo exige el check
  -- cajero_requires_branch). Si no se indica, va a la principal.
  if p_role = 'cajero' and v_branch is null then
    select id into v_branch from public.merchant_branches
    where merchant_id = p_merchant_id and is_default;
  end if;

  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_user, p_merchant_id, v_branch, p_role)
  on conflict (user_id, merchant_id, branch_id) do update
    set role = excluded.role, is_active = true;

  perform audit.log(v_actor, 'merchant.staff_added', p_merchant_id,
    jsonb_build_object('user_id', v_user, 'role', p_role));

  return jsonb_build_object('ok', true, 'user_id', v_user, 'branch_id', v_branch);
end;
$$;

revoke all on function public.admin_add_merchant_staff(uuid, text, public.merchant_role, uuid)
  from public, anon;
grant execute on function public.admin_add_merchant_staff(uuid, text, public.merchant_role, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Listado de comercios para el panel
-- ---------------------------------------------------------------------------
-- `merchants_read_active` ya deja a cualquier autenticado ver los comercios
-- activos, pero el super admin necesita también los pausados y terminados, y
-- el conteo de personal.

create policy "merchants_read_admin"
  on public.merchants for select to authenticated
  using (public.is_platform_admin());

create policy "merchant_users_read_admin"
  on public.merchant_users for select to authenticated
  using (public.is_platform_admin());

create policy "branches_read_admin"
  on public.merchant_branches for select to authenticated
  using (public.is_platform_admin());

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
     where c.merchant_id = m.id and c.status = 'confirmed') as sales_count
from public.merchants m;

grant select on public.merchant_directory to authenticated;
