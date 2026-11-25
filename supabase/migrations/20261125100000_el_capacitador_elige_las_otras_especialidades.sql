-- ============================================================================
-- Helios — El capacitador elige las otras especialidades del médico
--
-- Las otras especialidades (`directory_listings.other_specialty_keys`,
-- 20261110120000) se eligen ahora en el perfil del médico, no en la ficha del
-- directorio. El capacitador ya corrige ese perfil (20261102230000), pero la
-- única puerta a esa columna era `admin_directorio_guardar`, que exige
-- `is_platform_admin()` y además publica, oculta y cambia precios y WhatsApp
-- de la tarjeta: eso sigue siendo solo del super admin.
--
--   1. `admin_medico_especialidades(p_merchant_id)`: la principal y las otras
--      de un médico, para pintar el perfil.
--   2. `admin_medico_especialidades_guardar(p_merchant_id, p_otras)`: reemplaza
--      la lista de otras especialidades y nada más. Mismas reglas que
--      `admin_directorio_guardar`: sin repetir, sin «otra», sin la principal y
--      como mucho tres. Si el médico aún no tiene tarjeta, la crea oculta (no
--      publica nada).
--
-- Las dos con `helios_assert_puede_afiliar()` (super admin o capacitador, con
-- el segundo factor si se exige). El operador sigue sin editar.
-- ============================================================================

-- ── 1. Leer ─────────────────────────────────────────────────────────────────

create function public.admin_medico_especialidades(p_merchant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_f record;
begin
  perform public.helios_assert_puede_afiliar('ver las especialidades de un médico');

  select f.specialty_key, f.other_specialty_keys into v_f
    from public.helios_directorio_fichas() f
   where f.merchant_id = p_merchant_id;
  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'specialty_key', v_f.specialty_key,
    'other_specialty_keys', to_jsonb(v_f.other_specialty_keys));
end;
$function$;

comment on function public.admin_medico_especialidades(uuid) is
  'Perfil del médico: su especialidad principal del directorio (specialty_key) y las otras en las que sale (other_specialty_keys, sin la principal). Super admin o capacitador.';
revoke all on function public.admin_medico_especialidades(uuid) from public, anon;
grant execute on function public.admin_medico_especialidades(uuid) to authenticated;

-- ── 2. Guardar ──────────────────────────────────────────────────────────────

create function public.admin_medico_especialidades_guardar(p_merchant_id uuid, p_otras jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor    uuid := public.helios_assert_puede_afiliar('cambiar las especialidades de un médico');
  v_f        record;
  v_antes    text[];
  v_otras    text[] := '{}';
  v_valor    text;
begin
  select f.clinic_name, f.specialty_key, f.other_specialty_keys into v_f
    from public.helios_directorio_fichas() f
   where f.merchant_id = p_merchant_id;
  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;
  v_antes := v_f.other_specialty_keys;

  if p_otras is null or jsonb_typeof(p_otras) <> 'array' then
    raise exception 'Las otras especialidades van en una lista' using errcode = '22023';
  end if;

  -- Sin repetir y sin la principal, que ya cuenta; en el orden en que llegan.
  for v_valor in
    select btrim(e.v)
      from jsonb_array_elements_text(p_otras) with ordinality as e(v, n)
     order by e.n
  loop
    if not (v_valor = any (public.helios_directorio_especialidades())) or v_valor = 'otra' then
      raise exception 'Especialidad desconocida: %', v_valor using errcode = '22023';
    end if;
    if not (v_valor = any (v_otras)) and v_valor is distinct from v_f.specialty_key then
      v_otras := v_otras || v_valor;
    end if;
  end loop;
  if cardinality(v_otras) > 3 then
    raise exception 'Como mucho tres especialidades además de la principal' using errcode = '22023';
  end if;

  -- Un médico sin tarjeta la recibe oculta: elegir especialidades no lo publica.
  insert into public.directory_listings as d
    (merchant_id, is_visible, consultation_currency, other_specialty_keys, updated_by, updated_at)
  values
    (p_merchant_id, false, 'USD', v_otras, v_actor, now())
  on conflict (merchant_id) do update set
    other_specialty_keys = excluded.other_specialty_keys,
    updated_by = excluded.updated_by,
    updated_at = excluded.updated_at;

  perform audit.log(v_actor, 'directory.listing.update', p_merchant_id, jsonb_build_object(
    'merchant_name', v_f.clinic_name,
    'cambios', jsonb_build_object('other_specialty_keys', to_jsonb(v_otras)),
    'antes', jsonb_build_object('other_specialty_keys', to_jsonb(v_antes)),
    'despues', jsonb_build_object('other_specialty_keys', to_jsonb(v_otras))
  ));
end;
$function$;

comment on function public.admin_medico_especialidades_guardar(uuid, jsonb) is
  'Perfil del médico: reemplaza las otras especialidades en las que sale (una lista de hasta tres claves, sin repetir, sin «otra» y sin la principal). No toca nada más de la tarjeta; si no tiene, la crea oculta. Super admin o capacitador; queda en audit.admin_actions.';
revoke all on function public.admin_medico_especialidades_guardar(uuid, jsonb) from public, anon;
grant execute on function public.admin_medico_especialidades_guardar(uuid, jsonb) to authenticated;
