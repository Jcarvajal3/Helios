-- ============================================================================
-- Ronda — Almacenamiento de capturas de KYC
--
-- Bucket privado. El usuario solo puede SUBIR, dentro de su propia carpeta.
-- No puede leer, sobrescribir ni borrar: una vez enviada una cédula, no se
-- toca. Leer es exclusivo del servicio de KYC y del super admin, que corren
-- con service role.
--
-- Convención de rutas:  {user_id}/{verification_id}/{document|selfie}.jpg
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'kyc-documents',
  'kyc-documents',
  false,
  8388608,                        -- 8 MB: de sobra para una foto comprimida
  array['image/jpeg', 'image/png']
)
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Subir solo a su propia carpeta. `storage.foldername()[1]` es el primer
-- segmento de la ruta, que por convención es el uuid del usuario.
create policy "kyc_upload_own_folder"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- Sin políticas de SELECT, UPDATE ni DELETE para `authenticated`:
-- las capturas son de un solo sentido.

-- ---------------------------------------------------------------------------
-- Envío de la verificación
-- ---------------------------------------------------------------------------

-- El usuario declara que ya subió sus dos capturas. Pasa la verificación a
-- 'processing' para que el servicio de KYC la recoja.
create or replace function public.submit_kyc_verification(
  p_verification_id uuid,
  p_document_path   text,
  p_selfie_path     text
)
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, pg_temp
as $$
declare
  v_user   uuid := auth.uid();
  v_prefix text;
  v_row    kyc.verifications%rowtype;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_row
  from kyc.verifications
  where id = p_verification_id and user_id = v_user
  for update;

  if not found then
    raise exception 'Verificación no encontrada' using errcode = 'P0002';
  end if;

  if v_row.status not in ('pending', 'processing') then
    return jsonb_build_object('ok', false, 'reason', 'not_pending', 'status', v_row.status);
  end if;

  -- Las rutas las manda el cliente, así que hay que comprobar que apunten a
  -- SU carpeta. Sin esto, un usuario podría declarar la cédula de otro como
  -- suya y hacer que el KYC evaluara fotos ajenas.
  v_prefix := v_user::text || '/' || p_verification_id::text || '/';

  if p_document_path not like v_prefix || '%'
     or p_selfie_path not like v_prefix || '%' then
    raise exception 'Rutas de archivo inválidas' using errcode = '42501';
  end if;

  update kyc.verifications
    set document_path = p_document_path,
        selfie_path   = p_selfie_path,
        status        = 'processing',
        updated_at    = now()
  where id = p_verification_id;

  insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
  values (p_verification_id, v_row.status, 'processing', 'user',
          jsonb_build_object('document_path', p_document_path, 'selfie_path', p_selfie_path));

  return jsonb_build_object('ok', true, 'status', 'processing');
end;
$$;

revoke all on function public.submit_kyc_verification(uuid, text, text) from public, anon;
grant execute on function public.submit_kyc_verification(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Confirmación de los datos extraídos
-- ---------------------------------------------------------------------------
-- Tras el OCR, el usuario revisa nombre, cédula y fecha de nacimiento y los
-- confirma o corrige. Este es el momento en que los datos pasan al perfil.

create or replace function public.confirm_kyc_data(
  p_verification_id uuid,
  p_full_name       text,
  p_document_number text,
  p_birth_date      date
)
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_age  int;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if not exists (
    select 1 from kyc.verifications
    where id = p_verification_id and user_id = v_user
  ) then
    raise exception 'Verificación no encontrada' using errcode = 'P0002';
  end if;

  if coalesce(trim(p_full_name), '') = '' then
    raise exception 'El nombre no puede estar vacío' using errcode = '22023';
  end if;

  -- Cédula venezolana: entre 6 y 9 dígitos, sin prefijo de nacionalidad.
  if p_document_number !~ '^\d{6,9}$' then
    raise exception 'El número de cédula no es válido' using errcode = '22023';
  end if;

  v_age := extract(year from age(current_date, p_birth_date));

  -- La mayoría de edad es requisito legal y se comprueba en el servidor:
  -- el cliente puede mentir, la base de datos no.
  if v_age < 18 then
    update kyc.verifications
      set status = 'rejected',
          rejection_reason = 'underage',
          rejection_detail = format('Edad calculada: %s años', v_age),
          updated_at = now()
    where id = p_verification_id;

    insert into kyc.decision_log (verification_id, to_status, actor, signals)
    values (p_verification_id, 'rejected', 'system',
            jsonb_build_object('reason', 'underage', 'age', v_age));

    return jsonb_build_object('ok', false, 'reason', 'underage');
  end if;

  -- Una cédula, una cuenta. Si ya existe en otro perfil, es un intento de
  -- duplicado y hay que revisarlo a mano.
  if exists (
    select 1 from public.profiles
    where document_number = p_document_number and id <> v_user
  ) then
    update kyc.verifications
      set status = 'manual_review',
          rejection_detail = 'Cédula ya registrada en otra cuenta',
          updated_at = now()
    where id = p_verification_id;

    insert into kyc.decision_log (verification_id, to_status, actor, signals)
    values (p_verification_id, 'manual_review', 'system',
            jsonb_build_object('reason', 'duplicate_document'));

    return jsonb_build_object('ok', false, 'reason', 'duplicate_document');
  end if;

  update kyc.verifications
    set extracted_name     = p_full_name,
        extracted_document = p_document_number,
        extracted_birth    = p_birth_date,
        updated_at         = now()
  where id = p_verification_id;

  update public.profiles
    set full_name       = p_full_name,
        document_number = p_document_number,
        birth_date      = p_birth_date,
        updated_at      = now()
  where id = v_user;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.confirm_kyc_data(uuid, text, text, date) from public, anon;
grant execute on function public.confirm_kyc_data(uuid, text, text, date) to authenticated;

-- ---------------------------------------------------------------------------
-- Aceptación de términos
-- ---------------------------------------------------------------------------
-- Se registra con versión, fecha y dispositivo: si algún día hay una disputa,
-- hay que poder demostrar qué aceptó el usuario y cuándo.

create table if not exists public.terms_acceptances (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  version     text not null,
  accepted_at timestamptz not null default now(),
  device_hash text,
  unique (user_id, version)
);

alter table public.terms_acceptances enable row level security;

create policy "terms_read_own"
  on public.terms_acceptances for select to authenticated
  using (user_id = (select auth.uid()));

create or replace function public.accept_terms(p_version text, p_device_hash text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  insert into public.terms_acceptances (user_id, version, device_hash)
  values (v_user, p_version, p_device_hash)
  on conflict (user_id, version) do nothing;
end;
$$;

revoke all on function public.accept_terms(text, text) from public, anon;
grant execute on function public.accept_terms(text, text) to authenticated;
