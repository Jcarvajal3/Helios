-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — La red social se guarda limpia, y lo que se anota sale
--
-- Javier (2026-11-06): el Dr. Eleazar Wacher anotó su Instagram como
-- «@ ginecoproblema» y no salía en su tarjeta ni en su ficha, porque con el
-- espacio no se podía armar el enlace. Un Instagram anotado tiene que salir.
--
--   1. `helios_usuario_de_red(text)` quita todo espacio, también los invisibles
--      que deja el copiar y pegar. Un usuario o un enlace nunca llevan.
--   2. Un trigger en las tres tablas que lo guardan (`merchants`,
--      `merchant_applications`, `directory_listings`): cualquier vía queda
--      limpia, también las que se escriban mañana.
--   3. Lo ya guardado se limpia aquí.
--   4. `helios_red_social_tiene_enlace(red, usuario)` dice si se puede armar
--      el enlace, con la misma regla que `formaDelUsuarioDeRed` en el panel, y
--      `helios_datos_de_alta` rechaza lo que no: mejor pedirlo otra vez que
--      guardar algo que nunca va a salir.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.helios_usuario_de_red(p_usuario text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select nullif(regexp_replace(coalesce(p_usuario, ''), '[[:space:]\u00A0\u200B-\u200D\u2060\uFEFF]+', '', 'g'), '');
$$;

comment on function public.helios_usuario_de_red(text) is
  'El usuario o enlace de una red social sin ningún espacio, también los invisibles. Null si no queda nada.';

/**
 * Si con esa red y ese usuario se puede armar el enlace al perfil. Un enlace
 * vale en cualquier red; un usuario suelto, en todas menos en «otra», que no
 * se sabe adónde lleva. La misma regla que `formaDelUsuarioDeRed`.
 */
create or replace function public.helios_red_social_tiene_enlace(p_red text, p_usuario text)
returns boolean
language sql
immutable
set search_path = pg_catalog, public, pg_temp
as $$
  select u is not null and (
    u ~ '^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+/[^[:space:]]*$'
    or (p_red is distinct from 'otra' and u ~ '^[A-Za-z0-9_.-]{1,100}$')
  )
  from (
    select regexp_replace(regexp_replace(public.helios_usuario_de_red(p_usuario), '^@', ''), '^https?://', '', 'i') as u
  ) x;
$$;

revoke all on function public.helios_usuario_de_red(text) from public, anon, authenticated;
revoke all on function public.helios_red_social_tiene_enlace(text, text) from public, anon, authenticated;

create or replace function public.helios_red_social_limpia()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.social_user := public.helios_usuario_de_red(new.social_user);
  return new;
end;
$$;

revoke all on function public.helios_red_social_limpia() from public, anon, authenticated;

create trigger merchants_red_social_limpia
  before insert or update of social_user on public.merchants
  for each row execute function public.helios_red_social_limpia();
create trigger merchant_applications_red_social_limpia
  before insert or update of social_user on public.merchant_applications
  for each row execute function public.helios_red_social_limpia();
create trigger directory_listings_red_social_limpia
  before insert or update of social_user on public.directory_listings
  for each row execute function public.helios_red_social_limpia();

-- Lo ya guardado (el trigger hace la limpieza).
update public.merchants set social_user = social_user
 where social_user is distinct from public.helios_usuario_de_red(social_user);
update public.merchant_applications set social_user = social_user
 where social_user is distinct from public.helios_usuario_de_red(social_user);
update public.directory_listings set social_user = social_user
 where social_user is distinct from public.helios_usuario_de_red(social_user);

-- ---------------------------------------------------------------------------
-- El alta: el usuario limpio, y rechaza lo que no se puede enlazar
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.helios_datos_de_alta(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_nombre  text := nullif(btrim(regexp_replace(coalesce(p->>'owner_name', ''), '\s+', ' ', 'g')), '');
  v_titulo  text := nullif(btrim(coalesce(p->>'doctor_title', '')), '');
  v_doc     text := public.helios_documento(p->>'owner_document', 'VEP');
  v_rif     text;
  v_esp     text := nullif(btrim(coalesce(p->>'specialty', '')), '');
  v_colegio text := nullif(btrim(coalesce(p->>'college_number', '')), '');
  v_mpps    text := nullif(btrim(coalesce(p->>'mpps_number', '')), '');
  v_clinica text := nullif(btrim(regexp_replace(coalesce(p->>'clinic_name', ''), '\s+', ' ', 'g')), '');
  v_dir     text := nullif(btrim(coalesce(p->>'address', '')), '');
  v_tel     text;
  v_correo  text := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  v_red     text := nullif(lower(btrim(coalesce(p->>'social_network', ''))), '');
  v_usuario text := public.helios_usuario_de_red(p->>'social_user');
  v_titular text := nullif(btrim(regexp_replace(coalesce(p->>'account_holder', ''), '\s+', ' ', 'g')), '');
  v_tit_doc text := public.helios_documento(p->>'holder_document', 'VEJGP');
  v_banco   text := nullif(btrim(coalesce(p->>'bank', '')), '');
  v_cuenta  text := nullif(regexp_replace(coalesce(p->>'account_number', ''), '\D', '', 'g'), '');
  v_pm_bank text := nullif(btrim(coalesce(p->>'pago_movil_bank', '')), '');
  v_pm_raw  text := nullif(btrim(coalesce(p->>'pago_movil_phone', '')), '');
  v_pm_tel  text;
begin
  if v_nombre is null or length(v_nombre) < 3 or length(v_nombre) > 120 then
    raise exception 'Escribe tu nombre completo.' using errcode = '22023';
  end if;
  if v_titulo is null then
    raise exception 'Elige cómo te nombran tus pacientes: Dr., Dra., Lcdo., Lcda. u Od.' using errcode = '22023';
  end if;
  if not (v_titulo = any (public.helios_titulos_del_medico())) then
    raise exception 'Elige el título de la lista: Dr., Dra., Lcdo., Lcda. u Od.' using errcode = '22023';
  end if;
  if v_doc is null then
    raise exception 'La cédula o el pasaporte no parecen válidos: elige V, E o P y escribe solo los números.'
      using errcode = '22023';
  end if;

  if nullif(btrim(coalesce(p->>'tax_id', '')), '') is not null then
    v_rif := public.helios_documento(p->>'tax_id', 'JGVEP');
    if v_rif is null or v_rif !~ '^[JGVEP]-?[0-9]{8,9}$' then
      raise exception 'El RIF no parece válido: elige la letra y escribe sus 8 o 9 números.' using errcode = '22023';
    end if;
    v_rif := public.normalize_tax_id(v_rif);
  end if;

  if v_esp is null or length(v_esp) > 80 then
    raise exception 'Escribe tu especialidad.' using errcode = '22023';
  end if;
  if v_colegio is not null and length(v_colegio) > 30 then
    raise exception 'El número del Colegio o la Federación es demasiado largo.' using errcode = '22023';
  end if;
  if v_mpps is not null and length(v_mpps) > 30 then
    raise exception 'La matrícula o el MPPS es demasiado largo.' using errcode = '22023';
  end if;

  if v_clinica is null or length(v_clinica) < 2 or length(v_clinica) > 120 then
    raise exception 'Escribe el nombre del consultorio o centro médico.' using errcode = '22023';
  end if;
  if v_dir is null or length(v_dir) < 5 or length(v_dir) > 300 then
    raise exception 'Escribe la dirección del consultorio.' using errcode = '22023';
  end if;

  v_tel := public.helios_normalize_ve_phone(p->>'phone');
  if v_tel is null then
    raise exception 'El teléfono no parece venezolano: 0212 5551234 o 0414 1234567.' using errcode = '22023';
  end if;
  if v_correo is null or not public.helios_valid_email(v_correo) then
    raise exception 'El correo no parece un correo.' using errcode = '22023';
  end if;

  -- La red social: opcional, pero la red y el usuario van juntos.
  if v_red is not null and not (v_red = any (public.helios_redes_sociales())) then
    raise exception 'Elige la red social de la lista.' using errcode = '22023';
  end if;
  if v_usuario is not null and v_red is null then
    raise exception 'Elige qué red social es.' using errcode = '22023';
  end if;
  if v_red is not null and v_usuario is null then
    raise exception 'Escribe el usuario o el enlace de la red social.' using errcode = '22023';
  end if;
  if v_usuario is not null and length(v_usuario) > 150 then
    raise exception 'El usuario o el enlace de la red social es demasiado largo.' using errcode = '22023';
  end if;
  -- Lo que se anota tiene que salir: sin enlace no saldría nunca.
  if v_usuario is not null and not public.helios_red_social_tiene_enlace(v_red, v_usuario) then
    if v_red = 'otra' then
      raise exception 'Pega el enlace a tu perfil en esa red.' using errcode = '22023';
    end if;
    raise exception 'Revisa la red social: escribe tu usuario, como @draperez, o el enlace a tu perfil.' using errcode = '22023';
  end if;

  -- Los datos de pago
  if v_titular is null or length(v_titular) < 3 or length(v_titular) > 120 then
    raise exception 'Escribe el titular de la cuenta.' using errcode = '22023';
  end if;
  if v_tit_doc is null then
    raise exception 'La cédula o el RIF del titular no parecen válidos: elige la letra y escribe solo los números.'
      using errcode = '22023';
  end if;

  if v_cuenta is not null then
    if v_cuenta !~ '^[0-9]{20}$' then
      raise exception 'El número de cuenta tiene 20 dígitos.' using errcode = '22023';
    end if;
    if v_banco is null or length(v_banco) > 60 then
      raise exception 'Elige el banco de la cuenta.' using errcode = '22023';
    end if;
  else
    v_banco := null;
  end if;

  if v_pm_raw is not null then
    v_pm_tel := public.helios_normalize_ve_mobile(v_pm_raw);
    if v_pm_tel is null then
      raise exception 'El teléfono del Pago Móvil tiene que ser un celular: 0414 1234567.' using errcode = '22023';
    end if;
    if v_pm_bank is null or length(v_pm_bank) > 60 then
      raise exception 'Elige el banco del Pago Móvil.' using errcode = '22023';
    end if;
  else
    v_pm_bank := null;
  end if;

  if v_cuenta is null and v_pm_tel is null then
    raise exception 'Pon los datos de la transferencia.' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'owner_name',       v_nombre,
    'doctor_title',     v_titulo,
    'owner_document',   v_doc,
    'tax_id',           v_rif,
    'specialty',        v_esp,
    'college_number',   v_colegio,
    'mpps_number',      v_mpps,
    'clinic_name',      v_clinica,
    'address',          v_dir,
    'phone',            v_tel,
    'email',            v_correo,
    'social_network',   v_red,
    'social_user',      v_usuario,
    'account_holder',   v_titular,
    'holder_document',  v_tit_doc,
    'bank',             v_banco,
    'account_number',   v_cuenta,
    'pago_movil_bank',  v_pm_bank,
    'pago_movil_phone', v_pm_tel
  );
end;
$function$;
