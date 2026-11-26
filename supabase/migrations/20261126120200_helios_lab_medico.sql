-- ============================================================================
-- Helios — Helios Lab: las RPC del panel del médico (docs/09 §5.1)
--
-- Personal de la clínica (gerente, cajero) con Lab habilitado para su clínica
-- (`lab_ajustes.modo`). El médico ve el precio final al paciente (base +
-- Cargo Helios + su comisión): excepción aprobada a «ningún total incluye la
-- Comisión Helios». Se llama «Cargo Helios», nunca «Comisión Helios».
-- ============================================================================

/** Para el panel: ¿tiene Lab esta clínica? Nunca falla por no estar habilitado. */
create or replace function public.lab_mi_acceso(p_merchant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rol text := public.helios_staff_role_in(p_merchant_id)::text;
  v_a   public.lab_ajustes%rowtype;
begin
  select * into v_a from public.lab_ajustes where id;
  return jsonb_build_object(
    'habilitado', v_rol is not null and public.helios_lab_habilitado(p_merchant_id),
    'modo', case when v_rol is not null then v_a.modo end,
    'rol', v_rol,
    'cargo_helios_usd', case when v_rol is not null then v_a.cargo_helios_usd end
  );
end;
$$;

/** Los exámenes activos con el precio al paciente en cada laboratorio. */
create or replace function public.lab_precios(p_merchant_id uuid)
returns table (
  examen_id uuid, codigo text, nombre text, kit_tipo text, indicaciones text,
  laboratorio_id uuid, laboratorio_nombre text,
  base_usd numeric, cargo_helios_usd numeric, comision_usd numeric, precio_usd numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_cargo numeric(18,4);
begin
  perform public.helios_lab_rol(p_merchant_id);
  select a.cargo_helios_usd into v_cargo from public.lab_ajustes a where a.id;

  return query
  select e.id, e.codigo, e.nombre, e.kit_tipo, e.indicaciones,
         l.id, l.nombre,
         p.base_usd, v_cargo, coalesce(c.comision_usd, 0::numeric(18,4)),
         (p.base_usd + v_cargo + coalesce(c.comision_usd, 0))::numeric(18,4)
    from public.lab_precios p
    join public.lab_examenes e on e.id = p.examen_id and e.activo
    join public.lab_laboratorios l on l.id = p.laboratorio_id and l.activo
    left join public.lab_comisiones c on c.examen_id = e.id and c.merchant_id = p_merchant_id
   where p.activo
   order by e.nombre, l.nombre;
end;
$$;

/** El gerente fija su comisión por examen (igual en todos los laboratorios). */
create or replace function public.lab_comision_set(
  p_merchant_id  uuid,
  p_examen_id    uuid,
  p_comision_usd numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rol text := public.helios_lab_rol(p_merchant_id);
  v_row public.lab_comisiones%rowtype;
begin
  if v_rol <> 'gerente' then
    raise exception 'Solo el administrador puede cambiar su comisión' using errcode = '42501';
  end if;
  if p_comision_usd is null or p_comision_usd < 0 or p_comision_usd > 100000 then
    raise exception 'La comisión debe ser cero o más' using errcode = '22023';
  end if;
  if not exists (select 1 from public.lab_examenes where id = p_examen_id) then
    raise exception 'No existe ese examen' using errcode = 'P0002';
  end if;

  insert into public.lab_comisiones (merchant_id, examen_id, comision_usd, updated_at, updated_by)
  values (p_merchant_id, p_examen_id, round(p_comision_usd, 4), now(), auth.uid())
  on conflict (merchant_id, examen_id) do update
    set comision_usd = excluded.comision_usd, updated_at = now(), updated_by = auth.uid()
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

/** Lo mismo que se guarda al registrar, sin guardar: para dictarle el monto al paciente. */
create or replace function public.helios_lab_cotizar_interno(
  p_merchant_id    uuid,
  p_examen_id      uuid,
  p_laboratorio_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_base    numeric(18,4);
  v_cargo   numeric(18,4);
  v_comis   numeric(18,4);
  v_precio  numeric(18,4);
  v_tasa    numeric(18,6) := public.helios_lab_tasa_hoy();
  v_kit     text;
begin
  select p.base_usd, e.kit_tipo into v_base, v_kit
    from public.lab_precios p
    join public.lab_examenes e on e.id = p.examen_id and e.activo
    join public.lab_laboratorios l on l.id = p.laboratorio_id and l.activo
   where p.examen_id = p_examen_id and p.laboratorio_id = p_laboratorio_id and p.activo;
  if v_base is null then
    raise exception 'Ese examen no tiene precio activo en ese laboratorio' using errcode = 'P0002';
  end if;
  if v_tasa is null or v_tasa <= 0 then
    raise exception 'No hay tasa BCV para hoy' using errcode = '22023';
  end if;

  select a.cargo_helios_usd into v_cargo from public.lab_ajustes a where a.id;
  select coalesce((select c.comision_usd from public.lab_comisiones c
                    where c.merchant_id = p_merchant_id and c.examen_id = p_examen_id), 0)
    into v_comis;
  v_precio := v_base + v_cargo + v_comis;

  return jsonb_build_object(
    'base_usd', v_base, 'cargo_helios_usd', v_cargo, 'comision_usd', v_comis,
    'precio_usd', v_precio, 'tasa_bcv', v_tasa,
    'monto_ves', round(v_precio * v_tasa, 2),
    'fecha_tasa', public.helios_business_date(now()),
    'kit_tipo', v_kit
  );
end;
$$;

revoke all on function public.helios_lab_cotizar_interno(uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public.lab_muestra_cotizar(
  p_merchant_id    uuid,
  p_examen_id      uuid,
  p_laboratorio_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.helios_lab_rol(p_merchant_id);
  return public.helios_lab_cotizar_interno(p_merchant_id, p_examen_id, p_laboratorio_id) - 'kit_tipo';
end;
$$;

/**
 * Registra la muestra: copia base, cargo y comisión del momento, la tasa BCV de
 * hoy y el monto en bolívares; escribe el `uso` del kit; con captura, encola la
 * lectura y despierta al lector. Idempotente por `p_idempotency_key`.
 */
create or replace function public.lab_muestra_registrar(
  p_merchant_id       uuid,
  p_examen_id         uuid,
  p_laboratorio_id    uuid,
  p_paciente_nombre   text,
  p_paciente_whatsapp text,
  p_paciente_correo   text,
  p_pago_referencia   text,
  p_pago_banco        text,
  p_comprobante_path  text,
  p_idempotency_key   text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rol    text := public.helios_lab_rol(p_merchant_id);
  v_actor  uuid := auth.uid();
  v_key    text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_nombre text := nullif(btrim(coalesce(p_paciente_nombre, '')), '');
  v_wa     text := regexp_replace(coalesce(p_paciente_whatsapp, ''), '[\s().-]', '', 'g');
  v_correo text := nullif(btrim(coalesce(p_paciente_correo, '')), '');
  v_ref    text := nullif(btrim(coalesce(p_pago_referencia, '')), '');
  v_dig    text;
  v_path   text := nullif(btrim(coalesce(p_comprobante_path, '')), '');
  v_banco  text := nullif(btrim(coalesce(p_pago_banco, '')), '');
  v_cot    jsonb;
  v_m      public.lab_muestras%rowtype;
  v_branch uuid;
  v_mime   text;
begin
  if v_key is null then
    raise exception 'Falta la clave de idempotencia' using errcode = '22023';
  end if;

  -- Misma clave → la misma muestra.
  select * into v_m from public.lab_muestras where idempotency_key = v_key;
  if found then
    if v_m.merchant_id <> p_merchant_id then
      raise exception 'Esa clave ya se usó' using errcode = '22023';
    end if;
    return jsonb_build_object('id', v_m.id, 'codigo', v_m.codigo, 'precio_usd', v_m.precio_usd,
      'monto_ves', v_m.monto_ves, 'tasa_bcv', v_m.tasa_bcv, 'pago_estado', v_m.pago_estado,
      'kits_restantes', public.helios_lab_stock_medico(p_merchant_id, v_m.kit_tipo));
  end if;

  if v_nombre is null then
    raise exception 'Falta el nombre del paciente' using errcode = '22023';
  end if;
  if v_wa ~ '^0[24][0-9]{9}$' then
    v_wa := '+58' || substr(v_wa, 2);
  end if;
  if v_wa !~ '^\+58[24][0-9]{9}$' then
    raise exception 'El WhatsApp del paciente no es válido (formato +58…)' using errcode = '22023';
  end if;
  if v_correo is not null and v_correo !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'El correo del paciente no es válido' using errcode = '22023';
  end if;
  v_dig := regexp_replace(coalesce(v_ref, ''), '\D', '', 'g');
  if length(v_dig) < 4 or length(v_dig) > 20 then
    raise exception 'La referencia del pago debe tener entre 4 y 20 dígitos' using errcode = '22023';
  end if;
  if v_path is not null and (v_path like '/%' or v_path like '%..%' or length(v_path) > 300
                             or v_path not like p_merchant_id::text || '/%') then
    raise exception 'La captura no es de esta clínica' using errcode = '22023';
  end if;
  if exists (select 1 from public.lab_muestras
              where regexp_replace(pago_referencia, '\D', '', 'g') = v_dig and estado <> 'anulada') then
    raise exception 'Esa referencia ya se usó en otra muestra' using errcode = '23505';
  end if;

  v_cot := public.helios_lab_cotizar_interno(p_merchant_id, p_examen_id, p_laboratorio_id);
  select b.id into v_branch from public.merchant_branches b
   where b.merchant_id = p_merchant_id and b.is_default limit 1;

  begin
    insert into public.lab_muestras (
      merchant_id, branch_id, registrada_por, paciente_nombre, paciente_whatsapp, paciente_correo,
      examen_id, laboratorio_id, kit_tipo,
      base_usd, cargo_helios_usd, comision_usd, precio_usd, tasa_bcv, monto_ves,
      pago_referencia, pago_banco, comprobante_path, pago_estado, idempotency_key
    ) values (
      p_merchant_id, v_branch, v_actor, v_nombre, v_wa, v_correo,
      p_examen_id, p_laboratorio_id, v_cot ->> 'kit_tipo',
      (v_cot ->> 'base_usd')::numeric, (v_cot ->> 'cargo_helios_usd')::numeric,
      (v_cot ->> 'comision_usd')::numeric, (v_cot ->> 'precio_usd')::numeric,
      (v_cot ->> 'tasa_bcv')::numeric, (v_cot ->> 'monto_ves')::numeric,
      v_ref, v_banco, v_path, case when v_path is null then 'para_revisar' else 'por_leer' end, v_key
    ) returning * into v_m;
  exception when unique_violation then
    -- Dos envíos a la vez con la misma clave: gana el primero, el otro devuelve esa muestra.
    select * into v_m from public.lab_muestras
     where idempotency_key = v_key and merchant_id = p_merchant_id;
    if found then
      return jsonb_build_object('id', v_m.id, 'codigo', v_m.codigo, 'precio_usd', v_m.precio_usd,
        'monto_ves', v_m.monto_ves, 'tasa_bcv', v_m.tasa_bcv, 'pago_estado', v_m.pago_estado,
        'kits_restantes', public.helios_lab_stock_medico(p_merchant_id, v_m.kit_tipo));
    end if;
    raise exception 'Esa referencia ya se usó en otra muestra' using errcode = '23505';
  end;

  -- El kit se gasta: el stock del médico puede quedar negativo (se avisa, no se bloquea).
  insert into public.lab_kit_movimientos (tipo, kit_tipo, cantidad, merchant_id, muestra_id, nota, actor, idempotency_key)
  values ('uso', v_m.kit_tipo, 1, p_merchant_id, v_m.id, 'Muestra ' || v_m.codigo, v_actor, 'lab-uso-' || v_m.id);

  if v_path is not null then
    v_mime := case lower(substring(v_path from '\.([A-Za-z0-9]+)$'))
                when 'png' then 'image/png' when 'webp' then 'image/webp' when 'pdf' then 'application/pdf'
                else 'image/jpeg' end;
    insert into public.lab_comprobante_lecturas (muestra_id, storage_path, mime)
    values (v_m.id, v_path, v_mime);
    begin
      perform public.helios_lector_despertar();
    exception when others then
      raise warning 'lab: no se pudo despertar al lector: %', sqlerrm;
    end;
  end if;

  return jsonb_build_object('id', v_m.id, 'codigo', v_m.codigo, 'precio_usd', v_m.precio_usd,
    'monto_ves', v_m.monto_ves, 'tasa_bcv', v_m.tasa_bcv, 'pago_estado', v_m.pago_estado,
    'kits_restantes', public.helios_lab_stock_medico(p_merchant_id, v_m.kit_tipo));
end;
$$;

/** Anula una muestra que aún no se ha retirado. */
create or replace function public.lab_muestra_anular(
  p_merchant_id uuid,
  p_muestra_id  uuid,
  p_motivo      text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rol    text := public.helios_lab_rol(p_merchant_id);
  v_motivo text := nullif(btrim(coalesce(p_motivo, '')), '');
  v_m      public.lab_muestras%rowtype;
begin
  if v_motivo is null then
    raise exception 'Falta el motivo' using errcode = '22023';
  end if;
  select * into v_m from public.lab_muestras
   where id = p_muestra_id and merchant_id = p_merchant_id for update;
  if not found then
    raise exception 'No existe esa muestra' using errcode = 'P0002';
  end if;
  if v_m.estado <> 'lista_para_retirar' then
    raise exception 'Solo se anula una muestra que aún no se ha retirado' using errcode = '22023';
  end if;

  update public.lab_muestras
     set estado = 'anulada', anulada_at = now(), anulada_motivo = left(v_motivo, 500),
         parada_retiro_id = null, parada_entrega_id = null
   where id = v_m.id
  returning * into v_m;

  return jsonb_build_object('id', v_m.id, 'codigo', v_m.codigo, 'estado', v_m.estado,
                            'anulada_at', v_m.anulada_at, 'anulada_motivo', v_m.anulada_motivo);
end;
$$;

/** Las muestras de la clínica, con el estado que ve el médico. */
create or replace function public.lab_mis_muestras(
  p_merchant_id uuid,
  p_estado      text default null,
  p_busqueda    text default null,
  p_limit       integer default 50,
  p_offset      integer default 0
)
returns table (
  id uuid, codigo text, paciente_nombre text, paciente_whatsapp text,
  examen_id uuid, examen_nombre text, laboratorio_nombre text, kit_tipo text,
  base_usd numeric, cargo_helios_usd numeric, comision_usd numeric, precio_usd numeric, monto_ves numeric,
  pago_estado text, estado text,
  created_at timestamptz, retirada_at timestamptz, en_laboratorio_at timestamptz,
  resultado_recibido_at timestamptz, resultado_entregado_at timestamptz, anulada_motivo text,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_q text := nullif(btrim(coalesce(p_busqueda, '')), '');
begin
  perform public.helios_lab_rol(p_merchant_id);
  return query
  select m.id, m.codigo, m.paciente_nombre, m.paciente_whatsapp,
         m.examen_id, e.nombre, l.nombre, m.kit_tipo,
         m.base_usd, m.cargo_helios_usd, m.comision_usd, m.precio_usd, m.monto_ves,
         m.pago_estado, m.estado,
         m.created_at, m.retirada_at, m.en_laboratorio_at,
         m.resultado_recibido_at, m.resultado_entregado_at, m.anulada_motivo,
         count(*) over ()
    from public.lab_muestras m
    join public.lab_examenes e on e.id = m.examen_id
    join public.lab_laboratorios l on l.id = m.laboratorio_id
   where m.merchant_id = p_merchant_id
     and (p_estado is null or m.estado = p_estado)
     and (v_q is null or m.codigo ilike '%' || v_q || '%' or m.paciente_nombre ilike '%' || v_q || '%'
          or e.nombre ilike '%' || v_q || '%')
   order by m.created_at desc
   limit greatest(1, least(coalesce(p_limit, 50), 200))
   offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

/** Los kits que tiene el médico en el consultorio y los que ya pidió. */
create or replace function public.lab_mis_kits(p_merchant_id uuid)
returns table (kit_tipo text, nombre text, en_consultorio integer, pedidos_pendientes integer)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform public.helios_lab_rol(p_merchant_id);
  return query
  select k.tipo, k.nombre,
         public.helios_lab_stock_medico(p_merchant_id, k.tipo),
         coalesce((select sum(p.cantidad) from public.lab_kit_pedidos p
                    where p.merchant_id = p_merchant_id and p.kit_tipo = k.tipo
                      and p.estado in ('pendiente', 'en_ruta')), 0)::integer
    from public.lab_kits k
   order by k.tipo;
end;
$$;

/** El médico pide kits: entran a la ruta del próximo día. */
create or replace function public.lab_kits_pedir(
  p_merchant_id uuid,
  p_kit_tipo    text,
  p_cantidad    integer,
  p_nota        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rol text := public.helios_lab_rol(p_merchant_id);
  v_row public.lab_kit_pedidos%rowtype;
begin
  if not exists (select 1 from public.lab_kits where tipo = p_kit_tipo) then
    raise exception 'Ese kit no existe' using errcode = '22023';
  end if;
  if p_cantidad is null or p_cantidad <= 0 or p_cantidad > 500 then
    raise exception 'La cantidad debe ser de 1 en adelante' using errcode = '22023';
  end if;

  insert into public.lab_kit_pedidos (merchant_id, kit_tipo, cantidad, nota, pedido_por)
  values (p_merchant_id, p_kit_tipo, p_cantidad, left(nullif(btrim(coalesce(p_nota, '')), ''), 500), auth.uid())
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

-- Permisos --------------------------------------------------------------
revoke all on function public.lab_mi_acceso(uuid) from public, anon;
revoke all on function public.lab_precios(uuid) from public, anon;
revoke all on function public.lab_comision_set(uuid, uuid, numeric) from public, anon;
revoke all on function public.lab_muestra_cotizar(uuid, uuid, uuid) from public, anon;
revoke all on function public.lab_muestra_registrar(uuid, uuid, uuid, text, text, text, text, text, text, text) from public, anon;
revoke all on function public.lab_muestra_anular(uuid, uuid, text) from public, anon;
revoke all on function public.lab_mis_muestras(uuid, text, text, integer, integer) from public, anon;
revoke all on function public.lab_mis_kits(uuid) from public, anon;
revoke all on function public.lab_kits_pedir(uuid, text, integer, text) from public, anon;

grant execute on function public.lab_mi_acceso(uuid) to authenticated;
grant execute on function public.lab_precios(uuid) to authenticated;
grant execute on function public.lab_comision_set(uuid, uuid, numeric) to authenticated;
grant execute on function public.lab_muestra_cotizar(uuid, uuid, uuid) to authenticated;
grant execute on function public.lab_muestra_registrar(uuid, uuid, uuid, text, text, text, text, text, text, text) to authenticated;
grant execute on function public.lab_muestra_anular(uuid, uuid, text) to authenticated;
grant execute on function public.lab_mis_muestras(uuid, text, text, integer, integer) to authenticated;
grant execute on function public.lab_mis_kits(uuid) to authenticated;
grant execute on function public.lab_kits_pedir(uuid, text, integer, text) to authenticated;
