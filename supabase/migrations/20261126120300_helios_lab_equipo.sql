-- ============================================================================
-- Helios — Helios Lab: las RPC del equipo (docs/09 §5.2)
--
-- Lecturas y operación: `is_platform_admin()`. Catálogo, ajustes y pagos:
-- `helios_assert_super_admin()`. Toda escritura del equipo va a `audit.log`.
-- La ruta del día y las paradas están en 20261126120400.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Resumen y ajustes
-- ---------------------------------------------------------------------------

create or replace function public.admin_lab_resumen()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy date := public.helios_business_date(now());
  v_mes date := date_trunc('month', v_hoy)::date;
begin
  perform public.helios_lab_assert_equipo();
  return jsonb_build_object(
    'muestras_por_estado', coalesce((
      select jsonb_object_agg(estado, n) from (
        select estado, count(*) n from public.lab_muestras group by estado) s), '{}'::jsonb),
    'pagos_por_revisar', (select count(*) from public.lab_muestras
                           where estado <> 'anulada' and pago_estado in ('cuadra', 'para_revisar')),
    'kits', coalesce((
      select jsonb_agg(jsonb_build_object(
               'tipo', k.tipo, 'nombre', k.nombre,
               'stock_helios', public.helios_lab_stock_helios(k.tipo),
               'minimo', k.minimo_helios,
               'reponer', public.helios_lab_stock_helios(k.tipo) < k.minimo_helios,
               'en_medicos', (select coalesce(sum(case when mv.tipo = 'entrega' then mv.cantidad
                                                       when mv.tipo = 'uso' then -mv.cantidad
                                                       when mv.tipo = 'ajuste' then mv.cantidad
                                                       else 0 end), 0)
                                from public.lab_kit_movimientos mv
                               where mv.kit_tipo = k.tipo and mv.merchant_id is not null)
             ) order by k.tipo)
        from public.lab_kits k), '[]'::jsonb),
    'ganancia_hoy_usd', coalesce((select sum(cargo_helios_usd) from public.lab_muestras
                                   where pago_estado = 'verificado' and estado <> 'anulada'
                                     and public.helios_business_date(created_at) = v_hoy), 0),
    'ganancia_mes_usd', coalesce((select sum(cargo_helios_usd) from public.lab_muestras
                                   where pago_estado = 'verificado' and estado <> 'anulada'
                                     and public.helios_business_date(created_at) >= v_mes), 0),
    'muestras_hoy', (select count(*) from public.lab_muestras
                      where estado <> 'anulada' and public.helios_business_date(created_at) = v_hoy)
  );
end;
$$;

create or replace function public.admin_lab_ajustes_get()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v public.lab_ajustes%rowtype;
begin
  perform public.helios_lab_assert_equipo();
  select * into v from public.lab_ajustes where id;
  return jsonb_build_object(
    'modo', v.modo, 'cargo_helios_usd', v.cargo_helios_usd,
    'clinicas_de_prueba', (select count(*) from public.merchants where is_test),
    'updated_at', v.updated_at);
end;
$$;

create or replace function public.admin_lab_ajustes_set(p_modo text, p_cargo_helios_usd numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.helios_assert_super_admin('cambiar los ajustes de Helios Lab');
  v_antes public.lab_ajustes%rowtype;
begin
  if p_modo is null or p_modo not in ('apagado', 'prueba', 'todos') then
    raise exception 'El modo debe ser apagado, prueba o todos' using errcode = '22023';
  end if;
  if p_cargo_helios_usd is null or p_cargo_helios_usd < 0 or p_cargo_helios_usd > 100000 then
    raise exception 'El cargo debe ser cero o más' using errcode = '22023';
  end if;
  select * into v_antes from public.lab_ajustes where id for update;

  update public.lab_ajustes
     set modo = p_modo, cargo_helios_usd = round(p_cargo_helios_usd, 4),
         updated_at = now(), updated_by = v_actor
   where id;

  perform audit.log(v_actor, 'lab.ajustes_set', null, jsonb_build_object(
    'modo_antes', v_antes.modo, 'modo', p_modo,
    'cargo_antes', v_antes.cargo_helios_usd, 'cargo', round(p_cargo_helios_usd, 4)));
  return public.admin_lab_ajustes_get();
end;
$$;

-- ---------------------------------------------------------------------------
-- Catálogo
-- ---------------------------------------------------------------------------

create or replace function public.admin_lab_laboratorios()
returns table (id uuid, nombre text, correo text, telefono text, direccion text, activo boolean, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform public.helios_lab_assert_equipo();
  return query
  select l.id, l.nombre, l.correo, l.telefono, l.direccion, l.activo, l.created_at
    from public.lab_laboratorios l order by l.nombre;
end;
$$;

create or replace function public.admin_lab_laboratorio_guardar(
  p_id        uuid,
  p_nombre    text,
  p_correo    text,
  p_telefono  text,
  p_direccion text,
  p_activo    boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('guardar laboratorios');
  v_nombre text := nullif(btrim(coalesce(p_nombre, '')), '');
  v_row    public.lab_laboratorios%rowtype;
begin
  if v_nombre is null then
    raise exception 'Falta el nombre del laboratorio' using errcode = '22023';
  end if;
  if p_id is null then
    insert into public.lab_laboratorios (nombre, correo, telefono, direccion, activo)
    values (v_nombre, nullif(btrim(coalesce(p_correo, '')), ''), nullif(btrim(coalesce(p_telefono, '')), ''),
            nullif(btrim(coalesce(p_direccion, '')), ''), coalesce(p_activo, true))
    returning * into v_row;
  else
    update public.lab_laboratorios
       set nombre = v_nombre, correo = nullif(btrim(coalesce(p_correo, '')), ''),
           telefono = nullif(btrim(coalesce(p_telefono, '')), ''),
           direccion = nullif(btrim(coalesce(p_direccion, '')), ''), activo = coalesce(p_activo, activo)
     where id = p_id
    returning * into v_row;
    if not found then
      raise exception 'No existe ese laboratorio' using errcode = 'P0002';
    end if;
  end if;
  perform audit.log(v_actor, 'lab.laboratorio_guardar', v_row.id, to_jsonb(v_row));
  return to_jsonb(v_row);
end;
$$;

create or replace function public.admin_lab_examenes()
returns table (id uuid, codigo text, nombre text, kit_tipo text, indicaciones text, activo boolean, precios jsonb)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform public.helios_lab_assert_equipo();
  return query
  select e.id, e.codigo, e.nombre, e.kit_tipo, e.indicaciones, e.activo,
         coalesce((select jsonb_agg(jsonb_build_object(
                     'laboratorio_id', p.laboratorio_id, 'laboratorio_nombre', l.nombre,
                     'base_usd', p.base_usd, 'activo', p.activo) order by l.nombre)
                     from public.lab_precios p
                     join public.lab_laboratorios l on l.id = p.laboratorio_id
                    where p.examen_id = e.id), '[]'::jsonb)
    from public.lab_examenes e order by e.nombre;
end;
$$;

create or replace function public.admin_lab_examen_guardar(
  p_id           uuid,
  p_codigo       text,
  p_nombre       text,
  p_kit_tipo     text,
  p_indicaciones text,
  p_activo       boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('guardar exámenes');
  v_codigo text := nullif(btrim(coalesce(p_codigo, '')), '');
  v_nombre text := nullif(btrim(coalesce(p_nombre, '')), '');
  v_row    public.lab_examenes%rowtype;
begin
  if v_codigo is null or v_nombre is null then
    raise exception 'Faltan el código y el nombre del examen' using errcode = '22023';
  end if;
  if not exists (select 1 from public.lab_kits where tipo = p_kit_tipo) then
    raise exception 'Ese kit no existe' using errcode = '22023';
  end if;
  if exists (select 1 from public.lab_examenes where codigo = v_codigo and id is distinct from p_id) then
    raise exception 'Ya hay un examen con ese código' using errcode = '23505';
  end if;
  if p_id is null then
    insert into public.lab_examenes (codigo, nombre, kit_tipo, indicaciones, activo)
    values (v_codigo, v_nombre, p_kit_tipo, nullif(btrim(coalesce(p_indicaciones, '')), ''), coalesce(p_activo, true))
    returning * into v_row;
  else
    update public.lab_examenes
       set codigo = v_codigo, nombre = v_nombre, kit_tipo = p_kit_tipo,
           indicaciones = nullif(btrim(coalesce(p_indicaciones, '')), ''), activo = coalesce(p_activo, activo)
     where id = p_id
    returning * into v_row;
    if not found then
      raise exception 'No existe ese examen' using errcode = 'P0002';
    end if;
  end if;
  perform audit.log(v_actor, 'lab.examen_guardar', v_row.id, to_jsonb(v_row));
  return to_jsonb(v_row);
end;
$$;

create or replace function public.admin_lab_precio_guardar(
  p_laboratorio_id uuid,
  p_examen_id      uuid,
  p_base_usd       numeric,
  p_activo         boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.helios_assert_super_admin('guardar precios de laboratorio');
  v_row   public.lab_precios%rowtype;
begin
  if p_base_usd is null or p_base_usd <= 0 or p_base_usd > 100000 then
    raise exception 'El precio base debe ser mayor que cero' using errcode = '22023';
  end if;
  if not exists (select 1 from public.lab_laboratorios where id = p_laboratorio_id)
     or not exists (select 1 from public.lab_examenes where id = p_examen_id) then
    raise exception 'No existe ese laboratorio o ese examen' using errcode = 'P0002';
  end if;
  insert into public.lab_precios (laboratorio_id, examen_id, base_usd, activo, updated_at)
  values (p_laboratorio_id, p_examen_id, round(p_base_usd, 4), coalesce(p_activo, true), now())
  on conflict (laboratorio_id, examen_id) do update
    set base_usd = excluded.base_usd, activo = excluded.activo, updated_at = now()
  returning * into v_row;
  perform audit.log(v_actor, 'lab.precio_guardar', v_row.examen_id, to_jsonb(v_row));
  return to_jsonb(v_row);
end;
$$;

-- ---------------------------------------------------------------------------
-- Kits
-- ---------------------------------------------------------------------------

create or replace function public.admin_lab_kits()
returns table (tipo text, nombre text, stock_helios integer, en_medicos integer,
               minimo_helios integer, minimo_por_medico integer, reponer boolean)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform public.helios_lab_assert_equipo();
  return query
  select k.tipo, k.nombre,
         public.helios_lab_stock_helios(k.tipo),
         (select coalesce(sum(case when mv.tipo = 'entrega' then mv.cantidad
                                   when mv.tipo = 'uso' then -mv.cantidad
                                   when mv.tipo = 'ajuste' then mv.cantidad else 0 end), 0)::integer
            from public.lab_kit_movimientos mv where mv.kit_tipo = k.tipo and mv.merchant_id is not null),
         k.minimo_helios, k.minimo_por_medico,
         public.helios_lab_stock_helios(k.tipo) < k.minimo_helios
    from public.lab_kits k order by k.tipo;
end;
$$;

create or replace function public.admin_lab_kit_minimo_guardar(
  p_tipo              text,
  p_minimo_helios     integer,
  p_minimo_por_medico integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.helios_lab_assert_equipo();
  v_row   public.lab_kits%rowtype;
begin
  if p_minimo_helios is null or p_minimo_helios < 0 or p_minimo_por_medico is null or p_minimo_por_medico < 0 then
    raise exception 'Los mínimos deben ser cero o más' using errcode = '22023';
  end if;
  update public.lab_kits
     set minimo_helios = p_minimo_helios, minimo_por_medico = p_minimo_por_medico
   where tipo = p_tipo
  returning * into v_row;
  if not found then
    raise exception 'Ese kit no existe' using errcode = 'P0002';
  end if;
  perform audit.log(v_actor, 'lab.kit_minimo', null, to_jsonb(v_row));
  return to_jsonb(v_row);
end;
$$;

/** Entrada de kits a Helios, o ajuste (cantidad con signo; con médico, ajusta el suyo). Idempotente. */
create or replace function public.admin_lab_kit_movimiento(
  p_tipo            text,
  p_kit_tipo        text,
  p_cantidad        integer,
  p_merchant_id     uuid default null,
  p_nota            text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.helios_lab_assert_equipo();
  v_key   text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_row   public.lab_kit_movimientos%rowtype;
begin
  if p_tipo is null or p_tipo not in ('entrada', 'ajuste') then
    raise exception 'El tipo debe ser entrada o ajuste' using errcode = '22023';
  end if;
  if not exists (select 1 from public.lab_kits where tipo = p_kit_tipo) then
    raise exception 'Ese kit no existe' using errcode = '22023';
  end if;
  if p_cantidad is null or p_cantidad = 0 or (p_tipo = 'entrada' and p_cantidad < 0) or abs(p_cantidad) > 100000 then
    raise exception 'La cantidad no es válida' using errcode = '22023';
  end if;
  if p_tipo = 'entrada' and p_merchant_id is not null then
    raise exception 'Una entrada es de Helios, no de un médico' using errcode = '22023';
  end if;
  if p_merchant_id is not null and not exists (select 1 from public.merchants where id = p_merchant_id) then
    raise exception 'No existe esa clínica' using errcode = 'P0002';
  end if;
  if v_key is null then
    raise exception 'Falta la clave de idempotencia' using errcode = '22023';
  end if;

  select * into v_row from public.lab_kit_movimientos where idempotency_key = v_key;
  if found then
    return to_jsonb(v_row);
  end if;

  insert into public.lab_kit_movimientos (tipo, kit_tipo, cantidad, merchant_id, nota, actor, idempotency_key)
  values (p_tipo, p_kit_tipo, p_cantidad, p_merchant_id, left(nullif(btrim(coalesce(p_nota, '')), ''), 500), v_actor, v_key)
  on conflict (idempotency_key) do nothing
  returning * into v_row;
  if not found then
    -- Otro envío con la misma clave llegó primero: devuelve ese movimiento.
    select * into v_row from public.lab_kit_movimientos where idempotency_key = v_key;
    return to_jsonb(v_row);
  end if;

  perform audit.log(v_actor, 'lab.kit_movimiento', p_merchant_id, jsonb_build_object(
    'tipo', p_tipo, 'kit_tipo', p_kit_tipo, 'cantidad', p_cantidad, 'nota', p_nota));
  return to_jsonb(v_row);
end;
$$;

create or replace function public.admin_lab_inventario_por_medico()
returns table (merchant_id uuid, medico text, consultorio text, sangre integer, orina integer, biopsia integer,
               entregados_total integer, usados_total integer, bajo_minimo boolean)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform public.helios_lab_assert_equipo();
  return query
  select m.id, m.name, m.consultorio,
         public.helios_lab_stock_medico(m.id, 'sangre'),
         public.helios_lab_stock_medico(m.id, 'orina'),
         public.helios_lab_stock_medico(m.id, 'biopsia'),
         (select coalesce(sum(mv.cantidad), 0)::integer from public.lab_kit_movimientos mv
           where mv.merchant_id = m.id and mv.tipo = 'entrega'),
         (select coalesce(sum(mv.cantidad), 0)::integer from public.lab_kit_movimientos mv
           where mv.merchant_id = m.id and mv.tipo = 'uso'),
         exists (select 1 from public.lab_kits k
                  where public.helios_lab_stock_medico(m.id, k.tipo) < k.minimo_por_medico)
    from public.merchants m
   where exists (select 1 from public.lab_kit_movimientos mv where mv.merchant_id = m.id)
      or exists (select 1 from public.lab_muestras s where s.merchant_id = m.id)
   order by m.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- Muestras y cobros
-- ---------------------------------------------------------------------------

/**
 * La última lectura del comprobante de una muestra, normalizada:
 * `{status, cuadra, error, lectura:{monto_ves, referencia, banco, fecha}}`, o null.
 */
create or replace function public.helios_lab_lectura_json(p_muestra_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
           'status', r.status, 'cuadra', r.cuadra, 'error', r.error,
           'lectura', case when r.lectura is null then null else jsonb_build_object(
             'monto_ves', public.helios_lab_monto_de_texto(r.lectura ->> 'monto_texto'),
             'referencia', nullif(regexp_replace(coalesce(r.lectura ->> 'referencia', ''), '\D', '', 'g'), ''),
             'banco', coalesce(r.lectura ->> 'banco_origen', r.lectura ->> 'banco_destino'),
             'fecha', r.lectura ->> 'fecha') end)
    from public.lab_comprobante_lecturas r
   where r.muestra_id = p_muestra_id
   order by r.created_at desc
   limit 1;
$$;

revoke all on function public.helios_lab_lectura_json(uuid) from public, anon, authenticated;

create or replace function public.admin_lab_muestras(
  p_estado      text default null,
  p_pago_estado text default null,
  p_merchant_id uuid default null,
  p_desde       date default null,
  p_hasta       date default null,
  p_busqueda    text default null,
  p_limit       integer default 50,
  p_offset      integer default 0
)
returns table (
  id uuid, codigo text, merchant_id uuid, medico text, consultorio text,
  paciente_nombre text, paciente_whatsapp text, paciente_correo text,
  examen text, laboratorio text, kit_tipo text,
  base_usd numeric, cargo_helios_usd numeric, comision_usd numeric, precio_usd numeric,
  tasa_bcv numeric, monto_ves numeric,
  pago_referencia text, pago_banco text, pago_nota text, tiene_comprobante boolean, comprobante_path text, lectura jsonb,
  pago_estado text, estado text, created_at timestamptz, total_count bigint
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
  perform public.helios_lab_assert_equipo();
  return query
  select m.id, m.codigo, m.merchant_id, c.name, c.consultorio,
         m.paciente_nombre, m.paciente_whatsapp, m.paciente_correo,
         e.nombre, l.nombre, m.kit_tipo,
         m.base_usd, m.cargo_helios_usd, m.comision_usd, m.precio_usd,
         m.tasa_bcv, m.monto_ves,
         m.pago_referencia, m.pago_banco, m.pago_nota, m.comprobante_path is not null, m.comprobante_path,
         public.helios_lab_lectura_json(m.id),
         m.pago_estado, m.estado, m.created_at, count(*) over ()
    from public.lab_muestras m
    join public.merchants c on c.id = m.merchant_id
    join public.lab_examenes e on e.id = m.examen_id
    join public.lab_laboratorios l on l.id = m.laboratorio_id
   where (p_estado is null or m.estado = p_estado)
     and (p_pago_estado is null or m.pago_estado = p_pago_estado)
     and (p_merchant_id is null or m.merchant_id = p_merchant_id)
     and (p_desde is null or public.helios_business_date(m.created_at) >= p_desde)
     and (p_hasta is null or public.helios_business_date(m.created_at) <= p_hasta)
     and (v_q is null or m.codigo ilike '%' || v_q || '%' or m.paciente_nombre ilike '%' || v_q || '%'
          or m.pago_referencia ilike '%' || v_q || '%' or c.name ilike '%' || v_q || '%'
          or e.nombre ilike '%' || v_q || '%')
   order by m.created_at desc
   limit greatest(1, least(coalesce(p_limit, 50), 500))
   offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

create or replace function public.admin_lab_muestra(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_m public.lab_muestras%rowtype;
begin
  perform public.helios_lab_assert_equipo();
  select * into v_m from public.lab_muestras where id = p_id;
  if not found then
    raise exception 'No existe esa muestra' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'muestra', to_jsonb(v_m) || jsonb_build_object(
      'medico', (select c.name from public.merchants c where c.id = v_m.merchant_id),
      'consultorio', (select c.consultorio from public.merchants c where c.id = v_m.merchant_id),
      'examen', (select e.nombre from public.lab_examenes e where e.id = v_m.examen_id),
      'laboratorio', (select l.nombre from public.lab_laboratorios l where l.id = v_m.laboratorio_id)),
    'lectura', public.helios_lab_lectura_json(v_m.id),
    'historia', coalesce((select jsonb_agg(jsonb_build_object(
                  'created_at', a.created_at, 'accion', a.action,
                  'actor_nombre', coalesce((select pa.full_name from public.platform_admins pa
                                             where pa.user_id = a.actor), 'Equipo'),
                  'nota', coalesce(a.detail ->> 'nota', a.detail ->> 'motivo'))
                  order by a.created_at)
                  from audit.admin_actions a where a.target_id = v_m.id and a.action like 'lab.%'), '[]'::jsonb)
  );
end;
$$;

/** El equipo corrige cualquier paso a mano. Quien retrocede borra las marcas de los pasos posteriores. */
create or replace function public.admin_lab_muestra_estado(
  p_id     uuid,
  p_estado text,
  p_canal  text default null,
  p_nota   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.helios_lab_assert_equipo();
  v_m     public.lab_muestras%rowtype;
  v_orden text[] := array['lista_para_retirar', 'retirada', 'en_laboratorio', 'resultado_recibido', 'resultado_entregado'];
  v_i     integer := array_position(v_orden, p_estado);
  v_nota  text := nullif(btrim(coalesce(p_nota, '')), '');
  v_antes text;
  v_cur   integer;
begin
  if p_estado is null or (v_i is null and p_estado <> 'anulada') then
    raise exception 'Estado no válido' using errcode = '22023';
  end if;
  select * into v_m from public.lab_muestras where id = p_id for update;
  if not found then
    raise exception 'No existe esa muestra' using errcode = 'P0002';
  end if;
  v_antes := v_m.estado;
  v_cur := array_position(v_orden, v_m.estado);
  if p_estado = 'resultado_entregado' and coalesce(p_canal, '') not in ('correo', 'whatsapp') then
    raise exception 'Falta el canal por el que se entregó (correo o whatsapp)' using errcode = '22023';
  end if;
  if p_estado = 'anulada' and v_nota is null then
    raise exception 'Falta el motivo' using errcode = '22023';
  end if;

  begin
  if p_estado = 'anulada' then
    update public.lab_muestras
       set estado = 'anulada', anulada_at = coalesce(anulada_at, now()), anulada_motivo = left(v_nota, 500),
           parada_retiro_id = null, parada_entrega_id = null
     where id = p_id returning * into v_m;
  else
    update public.lab_muestras
       set estado = p_estado,
           -- Quien retrocede sale de las paradas que ya no le tocan.
           parada_retiro_id  = case when v_i < coalesce(v_cur, 0) and v_i = 1 then null else parada_retiro_id end,
           parada_entrega_id = case when v_i < coalesce(v_cur, 0) and v_i <= 2 then null else parada_entrega_id end,
           retirada_at            = case when v_i >= 2 then coalesce(retirada_at, now()) end,
           en_laboratorio_at      = case when v_i >= 3 then coalesce(en_laboratorio_at, now()) end,
           resultado_recibido_at  = case when v_i >= 4 then coalesce(resultado_recibido_at, now()) end,
           resultado_entregado_at = case when v_i >= 5 then coalesce(resultado_entregado_at, now()) end,
           resultado_canal        = case when v_i >= 5 then p_canal end,
           anulada_at = null, anulada_motivo = null
     where id = p_id returning * into v_m;
  end if;
  exception when unique_violation then
    -- Al sacarla de «anulada», su referencia ya la usa otra muestra.
    raise exception 'La referencia de esta muestra ya la usa otra muestra' using errcode = '23505';
  end;

  perform audit.log(v_actor, 'lab.muestra_estado', v_m.id, jsonb_build_object(
    'codigo', v_m.codigo, 'antes', v_antes, 'estado', p_estado, 'canal', p_canal, 'nota', v_nota));
  return jsonb_build_object('id', v_m.id, 'codigo', v_m.codigo, 'estado', v_m.estado,
                            'resultado_canal', v_m.resultado_canal);
end;
$$;

create or replace function public.admin_lab_pago_revisar(p_id uuid, p_aprobar boolean, p_nota text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.helios_lab_assert_equipo();
  v_m     public.lab_muestras%rowtype;
  v_nota  text := nullif(btrim(coalesce(p_nota, '')), '');
begin
  if p_aprobar is null then
    raise exception 'Falta decidir si se aprueba' using errcode = '22023';
  end if;
  if not p_aprobar and v_nota is null then
    raise exception 'Falta el motivo del rechazo' using errcode = '22023';
  end if;
  select * into v_m from public.lab_muestras where id = p_id for update;
  if not found then
    raise exception 'No existe esa muestra' using errcode = 'P0002';
  end if;
  update public.lab_muestras
     set pago_estado = case when p_aprobar then 'verificado' else 'rechazado' end,
         pago_nota = coalesce(left(v_nota, 500), pago_nota),
         pago_revisado_por = v_actor, pago_revisado_at = now()
   where id = p_id returning * into v_m;
  perform audit.log(v_actor, 'lab.pago_revisar', v_m.id, jsonb_build_object(
    'codigo', v_m.codigo, 'aprobar', p_aprobar, 'nota', v_nota));
  return jsonb_build_object('id', v_m.id, 'codigo', v_m.codigo, 'pago_estado', v_m.pago_estado);
end;
$$;

create or replace function public.admin_lab_pagos_confirmar_cuadrados(p_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.helios_lab_assert_equipo();
  v_ids   uuid[];
begin
  with hechas as (
    update public.lab_muestras
       set pago_estado = 'verificado', pago_revisado_por = v_actor, pago_revisado_at = now()
     where id = any (coalesce(p_ids, '{}')) and pago_estado = 'cuadra' and estado <> 'anulada'
    returning id
  )
  select coalesce(array_agg(id), '{}') into v_ids from hechas;

  -- Una fila de auditoría por muestra, para que salga en su historia.
  perform audit.log(v_actor, 'lab.pago_revisar', x, jsonb_build_object('aprobar', true, 'masivo', true))
     from unnest(v_ids) x;
  return jsonb_build_object('confirmados', cardinality(v_ids));
end;
$$;

-- ---------------------------------------------------------------------------
-- Logística (lectura)
-- ---------------------------------------------------------------------------

create or replace function public.admin_lab_logistica(p_fecha date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.helios_lab_assert_equipo();
  return jsonb_build_object(
    'fecha', coalesce(p_fecha, public.helios_business_date(now())),
    'por_retirar', coalesce((
      select jsonb_agg(jsonb_build_object(
               'merchant_id', c.id, 'medico', c.name, 'consultorio', c.consultorio,
               'direccion', (select b.address from public.merchant_branches b
                              where b.merchant_id = c.id and b.is_default limit 1),
               'telefono', c.contact_phone,
               'muestras', (select jsonb_agg(jsonb_build_object(
                                     'codigo', m.codigo, 'examen', e.nombre, 'kit_tipo', m.kit_tipo)
                                     order by m.codigo)
                              from public.lab_muestras m join public.lab_examenes e on e.id = m.examen_id
                             where m.merchant_id = c.id and m.estado = 'lista_para_retirar')) order by c.name)
        from public.merchants c
       where exists (select 1 from public.lab_muestras m
                      where m.merchant_id = c.id and m.estado = 'lista_para_retirar')), '[]'::jsonb),
    'pedidos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'merchant_id', p.merchant_id, 'medico', c.name, 'kit_tipo', p.kit_tipo,
               'cantidad', p.cantidad, 'nota', p.nota, 'estado', p.estado, 'created_at', p.created_at)
               order by p.created_at)
        from public.lab_kit_pedidos p join public.merchants c on c.id = p.merchant_id
       where p.estado in ('pendiente', 'en_ruta')), '[]'::jsonb),
    'bajo_minimo', coalesce((
      select jsonb_agg(jsonb_build_object(
               'merchant_id', c.id, 'medico', c.name, 'consultorio', c.consultorio,
               'sangre', public.helios_lab_stock_medico(c.id, 'sangre'),
               'orina', public.helios_lab_stock_medico(c.id, 'orina'),
               'biopsia', public.helios_lab_stock_medico(c.id, 'biopsia'))
               order by c.name)
        from public.merchants c
       where exists (select 1 from public.lab_kit_movimientos mv where mv.merchant_id = c.id)
         and exists (select 1 from public.lab_kits k
                      where k.minimo_por_medico > 0
                        and public.helios_lab_stock_medico(c.id, k.tipo) < k.minimo_por_medico)), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Ganancia y por pagar
-- ---------------------------------------------------------------------------

create or replace function public.admin_lab_ganancia(p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hasta date := coalesce(p_hasta, public.helios_business_date(now()));
  v_desde date := coalesce(p_desde, date_trunc('month', coalesce(p_hasta, public.helios_business_date(now())))::date);
begin
  perform public.helios_lab_assert_equipo();
  return (
    with f as (
      select m.id, m.codigo, public.helios_business_date(m.created_at) fecha, c.name medico,
             e.nombre examen, l.nombre laboratorio,
             m.precio_usd, m.base_usd, m.comision_usd, m.cargo_helios_usd
        from public.lab_muestras m
        join public.merchants c on c.id = m.merchant_id
        join public.lab_examenes e on e.id = m.examen_id
        join public.lab_laboratorios l on l.id = m.laboratorio_id
       where m.pago_estado = 'verificado' and m.estado <> 'anulada'
         and public.helios_business_date(m.created_at) between v_desde and v_hasta
    )
    select jsonb_build_object(
      'desde', v_desde, 'hasta', v_hasta,
      'totales', jsonb_build_object(
        'muestras', (select count(*) from f),
        'cobrado_usd', coalesce((select sum(precio_usd) from f), 0),
        'base_usd', coalesce((select sum(base_usd) from f), 0),
        'comision_usd', coalesce((select sum(comision_usd) from f), 0),
        'cargo_helios_usd', coalesce((select sum(cargo_helios_usd) from f), 0)),
      'filas', coalesce((select jsonb_agg(jsonb_build_object(
                 'muestra_id', id, 'codigo', codigo, 'fecha', fecha, 'medico', medico, 'examen', examen,
                 'laboratorio', laboratorio, 'cobrado_usd', precio_usd, 'base_usd', base_usd,
                 'comision_usd', comision_usd, 'cargo_helios_usd', cargo_helios_usd)
                 order by fecha desc, codigo desc) from f), '[]'::jsonb))
  );
end;
$$;

create or replace function public.admin_lab_por_pagar()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.helios_lab_assert_equipo();
  return jsonb_build_object(
    'medicos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'merchant_id', s.merchant_id, 'medico', c.name, 'consultorio', c.consultorio,
               'comision_usd', s.total, 'muestras', s.n, 'muestra_ids', s.ids) order by c.name)
        from (select merchant_id, sum(comision_usd) total, count(*) n, array_agg(id order by created_at) ids
                from public.lab_muestras
               where pago_estado = 'verificado' and estado <> 'anulada'
                 and comision_pagada_at is null and comision_usd > 0
               group by merchant_id) s
        join public.merchants c on c.id = s.merchant_id), '[]'::jsonb),
    'laboratorios', coalesce((
      select jsonb_agg(jsonb_build_object(
               'laboratorio_id', s.laboratorio_id, 'nombre', l.nombre,
               'base_usd', s.total, 'muestras', s.n, 'muestra_ids', s.ids) order by l.nombre)
        from (select laboratorio_id, sum(base_usd) total, count(*) n, array_agg(id order by created_at) ids
                from public.lab_muestras
               where pago_estado = 'verificado' and estado <> 'anulada' and base_pagada_at is null
               group by laboratorio_id) s
        join public.lab_laboratorios l on l.id = s.laboratorio_id), '[]'::jsonb)
  );
end;
$$;

create or replace function public.admin_lab_marcar_pagado(
  p_tipo         text,
  p_muestra_ids  uuid[],
  p_referencia   text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.helios_assert_super_admin('marcar pagos de Helios Lab');
  v_ref   text := nullif(btrim(coalesce(p_referencia, '')), '');
  v_ids   uuid[];
begin
  if p_tipo is null or p_tipo not in ('comision', 'base') then
    raise exception 'El tipo debe ser comision o base' using errcode = '22023';
  end if;
  if v_ref is null then
    raise exception 'Falta la referencia del pago' using errcode = '22023';
  end if;

  if p_tipo = 'comision' then
    with h as (
      update public.lab_muestras
         set comision_pagada_at = now(), comision_pago_ref = left(v_ref, 120)
       where id = any (coalesce(p_muestra_ids, '{}')) and pago_estado = 'verificado'
         and estado <> 'anulada' and comision_pagada_at is null
      returning id)
    select coalesce(array_agg(id), '{}') into v_ids from h;
  else
    with h as (
      update public.lab_muestras
         set base_pagada_at = now(), base_pago_ref = left(v_ref, 120)
       where id = any (coalesce(p_muestra_ids, '{}')) and pago_estado = 'verificado'
         and estado <> 'anulada' and base_pagada_at is null
      returning id)
    select coalesce(array_agg(id), '{}') into v_ids from h;
  end if;

  perform audit.log(v_actor, 'lab.marcar_pagado', null, jsonb_build_object(
    'tipo', p_tipo, 'referencia', v_ref, 'ids', v_ids));
  return jsonb_build_object('marcadas', cardinality(v_ids));
end;
$$;

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------

do $$
declare
  v_f record;
begin
  for v_f in
    select p.oid::regprocedure as firma
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in (
         'admin_lab_resumen', 'admin_lab_ajustes_get', 'admin_lab_ajustes_set', 'admin_lab_laboratorios',
         'admin_lab_laboratorio_guardar', 'admin_lab_examenes', 'admin_lab_examen_guardar',
         'admin_lab_precio_guardar', 'admin_lab_kits', 'admin_lab_kit_minimo_guardar',
         'admin_lab_kit_movimiento', 'admin_lab_inventario_por_medico', 'admin_lab_muestras',
         'admin_lab_muestra', 'admin_lab_muestra_estado', 'admin_lab_pago_revisar',
         'admin_lab_pagos_confirmar_cuadrados', 'admin_lab_logistica', 'admin_lab_ganancia',
         'admin_lab_por_pagar', 'admin_lab_marcar_pagado')
  loop
    execute format('revoke all on function %s from public, anon', v_f.firma);
    execute format('grant execute on function %s to authenticated', v_f.firma);
  end loop;
end;
$$;
