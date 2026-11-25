-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El médico sale en el directorio al darse de alta
--
-- Antes (20261109120000) la ficha del directorio nacía **oculta** y solo con
-- precio; publicarla era una tarea más del equipo en superadmin › Directorio.
-- Ahora el alta la deja publicada:
--
--   · `helios_crear_clinica` (la usan `admin_create_clinic` y
--     `admin_approve_merchant_application`) crea siempre la fila de
--     `directory_listings` con `is_visible = true` y `published_at = now()`,
--     con o sin precio de la consulta. El trigger `directory_listings_pone_slug`
--     le da su enlace (`/medico/<slug>`) y la columna `lead_code` su código.
--   · No se salta ninguna regla de publicación: la clínica sale en la página
--     solo cuando `helios_directorio_fichas()` no la bloquea (activa, no de
--     prueba y con WhatsApp). Si el alta no trae ni teléfono de contacto ni
--     uno personal válido, la ficha queda habilitada y sale sola cuando se le
--     cargue el WhatsApp. El equipo sigue pudiendo ocultarla con
--     `admin_directorio_guardar`.
--   · Solo cambia el alta: las clínicas que ya existen no se tocan.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.helios_crear_clinica(p jsonb, p_actor uuid)
returns uuid
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  d      jsonb := public.helios_datos_de_alta(p);
  v_id   uuid;
  v_logo text := nullif(btrim(coalesce(p->>'logo_url', '')), '');
  v_cto_raw text := nullif(btrim(coalesce(p->>'contact_phone', '')), '');
  v_cto  text := public.helios_normalize_ve_phone(nullif(btrim(coalesce(p->>'contact_phone', '')), ''));
  -- El precio de la consulta del directorio (20261109120000): opcional.
  v_precio_raw text := nullif(btrim(coalesce(p->>'consultation_price_cur', '')), '');
  v_moneda     text := upper(coalesce(nullif(btrim(coalesce(p->>'consultation_currency', '')), ''), 'USD'));
  v_precio     numeric(18,4);
begin
  if v_cto_raw is not null and v_cto is null then
    raise exception 'El teléfono de contacto no parece venezolano: 0212 5551234 o 0414 1234567.' using errcode = '22023';
  end if;

  -- Las mismas reglas que admin_directorio_guardar. Dos comprobaciones aparte:
  -- la conversión no puede correr sobre un texto que no sea un número.
  if v_precio_raw is not null then
    if v_precio_raw !~ '^[0-9]{1,5}(\.[0-9]{1,2})?$' then
      raise exception 'El precio de la consulta debe ser un monto entre 1 y 10.000.' using errcode = '22023';
    end if;
    if v_precio_raw::numeric not between 1 and 10000 then
      raise exception 'El precio de la consulta debe ser un monto entre 1 y 10.000.' using errcode = '22023';
    end if;
    if v_moneda not in ('USD', 'EUR') then
      raise exception 'La moneda del precio debe ser dólares o euros.' using errcode = '22023';
    end if;
    v_precio := v_precio_raw::numeric(18,4);
  end if;

  if d->>'tax_id' is not null and exists (select 1 from public.merchants where tax_id = d->>'tax_id') then
    raise exception 'Ya hay una clínica dada de alta con el RIF %', d->>'tax_id' using errcode = '23505';
  end if;

  insert into public.merchants
    (name, tax_id, category, logo_url, specialty, mpps_number, phone, contact_phone, email, address,
     owner_name, owner_document, college_number, doctor_title, social_network, social_user)
  values (
    d->>'clinic_name', d->>'tax_id', public.helios_categoria_por_especialidad(d->>'specialty'), v_logo,
    d->>'specialty', d->>'mpps_number', d->>'phone', v_cto, d->>'email', d->>'address',
    d->>'owner_name', d->>'owner_document', d->>'college_number', d->>'doctor_title',
    d->>'social_network', d->>'social_user'
  )
  returning id into v_id;

  insert into public.merchant_payout_accounts
    (merchant_id, account_holder, holder_document, bank, account_number,
     pago_movil_phone, pago_movil_bank, updated_by)
  values (
    v_id, d->>'account_holder', d->>'holder_document', d->>'bank', d->>'account_number',
    d->>'pago_movil_phone', d->>'pago_movil_bank', p_actor
  );

  -- La ficha del directorio nace habilitada (con o sin precio). Sale en la
  -- página si helios_directorio_fichas() no la bloquea; ocultarla sigue siendo
  -- cosa del equipo, en superadmin › Directorio.
  insert into public.directory_listings
    (merchant_id, is_visible, published_at, consultation_price_cur, consultation_currency, updated_by, updated_at)
  values (v_id, true, now(), v_precio, case when v_precio is not null then v_moneda else 'USD' end, p_actor, now());

  perform audit.log(p_actor, 'merchant.created', v_id, jsonb_build_object(
    'name', d->>'clinic_name', 'tax_id', d->>'tax_id', 'specialty', d->>'specialty',
    'owner_name', d->>'owner_name', 'owner_document', d->>'owner_document',
    'doctor_title', d->>'doctor_title',
    'mpps_number', d->>'mpps_number', 'college_number', d->>'college_number',
    'social_network', d->>'social_network', 'social_user', d->>'social_user',
    'contact_phone', v_cto,
    'consultation_price_cur', v_precio,
    'consultation_currency', case when v_precio is not null then v_moneda end,
    'directory_visible', true));

  perform audit.log(p_actor, 'merchant.payout_account_set', v_id, jsonb_build_object(
    'antes', null,
    'despues', (select to_jsonb(a) - 'updated_by' - 'updated_at'
                from public.merchant_payout_accounts a where a.merchant_id = v_id)));

  return v_id;
end;
$$;

revoke all on function public.helios_crear_clinica(jsonb, uuid) from public, anon, authenticated;
