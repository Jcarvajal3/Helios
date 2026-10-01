-- ============================================================================
-- Helios — Bootstrap del primer super_admin
--
-- Uso único: correr esto a mano en el SQL Editor del dashboard de Supabase
-- (proyecto Helios, rol postgres) SOLO para crear el primer super_admin.
-- `admin_set_platform_admin()` exige que ya exista uno que autorice la
-- llamada, y este es el huevo-o-gallina. Al resto del equipo se le da acceso
-- desde el panel: Ajustes › Equipo.
--
-- Reemplaza los tres valores de abajo antes de ejecutar. La contraseña no
-- queda en ningún sitio: se guarda solo su hash (bcrypt, coste 10). No
-- guardes este fichero con tus datos dentro.
--
-- Igual que en Ronda (Ronda-app/supabase/bootstrap_superadmin.sql), con una
-- diferencia: en Helios crear una cuenta de auth NO crea un `profiles`
-- (H3, 20261002000300: los pacientes no tienen cuenta), así que una cuenta del
-- equipo nunca aparece como paciente.
--
-- Después de entrar al panel (/login → /admin), activa el segundo factor en
-- Ajustes › Seguridad y, cuando todo el equipo lo tenga, exígelo para todos.
-- ============================================================================

do $$
declare
  v_email     text := 'TU_CORREO@ejemplo.com';
  v_password  text := 'UNA_CONTRASEÑA_DE_AL_MENOS_8_CARACTERES';
  v_full_name text := 'Nombre Completo';
  v_user_id   uuid := gen_random_uuid();
begin
  if v_email like 'TU_CORREO%' or v_password like 'UNA_CONTRASEÑA%' then
    raise exception 'Reemplaza el correo y la contraseña antes de ejecutar';
  end if;
  if length(v_password) < 8 then
    raise exception 'La contraseña debe tener al menos 8 caracteres';
  end if;
  if exists (select 1 from auth.users where lower(email) = lower(trim(v_email))) then
    raise exception 'Ya existe una cuenta con ese correo';
  end if;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) values (
    '00000000-0000-0000-0000-000000000000',
    v_user_id, 'authenticated', 'authenticated', lower(trim(v_email)),
    extensions.crypt(v_password, extensions.gen_salt('bf', 10)),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('full_name', v_full_name),
    '', '', '', ''
  );

  insert into auth.identities (
    id, provider_id, user_id, identity_data, provider,
    created_at, updated_at, last_sign_in_at
  ) values (
    gen_random_uuid(), v_user_id, v_user_id,
    jsonb_build_object('sub', v_user_id::text, 'email', lower(trim(v_email))),
    'email', now(), now(), now()
  );

  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_user_id, 'super_admin', v_full_name, true);

  perform audit.log(v_user_id, 'platform_admin.bootstrap', v_user_id,
                    jsonb_build_object('email', lower(trim(v_email)), 'role', 'super_admin'));

  raise notice 'super_admin creado: % (%)', v_email, v_user_id;
end $$;
