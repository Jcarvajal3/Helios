-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El capacitador edita el perfil del médico
--
-- El capacitador (20261102130100) afilia médicos y veía su ficha solo para
-- leer. Desde aquí también corrige su perfil, como el super admin:
--
-- 1. `admin_set_merchant_profile`: la categoría, la ciudad, el RIF, el logo
--    y los datos del consultorio (especialidad, MPPS, teléfono, correo,
--    dirección, consultorio).
-- 2. `admin_set_merchant_owner`: el médico titular (nombre, cédula, Colegio y
--    título).
-- 3. El logo se sube a Storage (`merchant-logos`): sus tres políticas de
--    escritura dejan pasar también al capacitador.
--
-- Las tres con `helios_assert_puede_afiliar()` (super admin o capacitador,
-- con el segundo factor si se exige) en lugar de `helios_assert_super_admin()`.
-- El operador sigue sin editar. Lo que es dinero —las condiciones, la cuenta
-- de cobro, el estado de la clínica— y el personal siguen como estaban.
--
-- Los cuerpos de las funciones salen tal cual de la base, con solo la
-- guardia cambiada.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. El perfil de la clínica
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_merchant_profile(
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
  p_address     text default null,
  p_consultorio text default null
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
  perform public.helios_assert_puede_afiliar('editar el perfil de una clínica');

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
        consultorio = case when p_consultorio is null then consultorio else nullif(trim(p_consultorio), '') end,
        updated_at  = now()
  where id = p_merchant_id;

  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.set_profile', p_merchant_id, jsonb_build_object(
    'category', p_category, 'city', p_city, 'handle', v_handle,
    'logo_url', p_logo_url, 'social_url', p_social_url, 'tax_id', v_tax_id,
    'specialty', p_specialty, 'mpps_number', p_mpps_number, 'phone', p_phone,
    'email', v_email, 'address', p_address, 'consultorio', p_consultorio
  ));
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. El médico titular
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_merchant_owner(p_merchant_id uuid, p jsonb)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_puede_afiliar('editar el perfil de una clínica');
  v_nombre text := nullif(btrim(regexp_replace(p->>'owner_name', '\s+', ' ', 'g')), '');
  v_raw    text := btrim(p->>'owner_document');
  v_doc    text;
  v_col    text := btrim(p->>'college_number');
  v_titulo text := btrim(p->>'doctor_title');
begin
  if v_nombre is not null and (length(v_nombre) < 3 or length(v_nombre) > 120) then
    raise exception 'El nombre del titular no es válido' using errcode = '22023';
  end if;
  if nullif(v_raw, '') is not null then
    v_doc := public.helios_documento(v_raw, 'VEP');
    if v_doc is null then
      raise exception 'La cédula o el pasaporte del titular no parecen válidos' using errcode = '22023';
    end if;
  elsif v_raw = '' then
    v_doc := '';
  end if;
  if v_col is not null and length(v_col) > 30 then
    raise exception 'El número del Colegio es demasiado largo' using errcode = '22023';
  end if;
  if v_titulo <> '' and not (v_titulo = any (public.helios_titulos_del_medico())) then
    raise exception 'El título debe ser Dr., Dra., Lcdo., Lcda. u Od.' using errcode = '22023';
  end if;

  update public.merchants
     set owner_name     = coalesce(v_nombre, owner_name),
         owner_document = case when v_doc is null then owner_document else nullif(v_doc, '') end,
         college_number = case when v_col is null then college_number else nullif(v_col, '') end,
         doctor_title   = case when v_titulo is null then doctor_title else nullif(v_titulo, '') end,
         updated_at     = now()
   where id = p_merchant_id;

  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.set_owner', p_merchant_id, jsonb_build_object(
    'owner_name', v_nombre, 'owner_document', v_doc, 'college_number', v_col,
    'doctor_title', v_titulo));
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. El logo, en Storage
--
-- `helios_puede_ver_clinicas()` pone el segundo factor (la API no ejecuta
-- `helios_es_del_equipo`); el `exists` deja fuera al operador, que también
-- ve las clínicas.
-- ---------------------------------------------------------------------------
drop policy if exists "merchant_logos_write_super_admin" on storage.objects;
drop policy if exists "merchant_logos_update_super_admin" on storage.objects;
drop policy if exists "merchant_logos_delete_super_admin" on storage.objects;

drop policy if exists "merchant_logos_write_quien_edita" on storage.objects;
create policy "merchant_logos_write_quien_edita"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'merchant-logos'
    and (select public.helios_puede_ver_clinicas())
    and exists (
      select 1 from public.platform_admins
      where user_id = (select auth.uid()) and is_active and role in ('super_admin', 'capacitador')
    )
  );

drop policy if exists "merchant_logos_update_quien_edita" on storage.objects;
create policy "merchant_logos_update_quien_edita"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'merchant-logos'
    and (select public.helios_puede_ver_clinicas())
    and exists (
      select 1 from public.platform_admins
      where user_id = (select auth.uid()) and is_active and role in ('super_admin', 'capacitador')
    )
  );

drop policy if exists "merchant_logos_delete_quien_edita" on storage.objects;
create policy "merchant_logos_delete_quien_edita"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'merchant-logos'
    and (select public.helios_puede_ver_clinicas())
    and exists (
      select 1 from public.platform_admins
      where user_id = (select auth.uid()) and is_active and role in ('super_admin', 'capacitador')
    )
  );
