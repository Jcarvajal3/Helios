-- ============================================================================
-- Helios — Helios Lab: la ruta del día (docs/09 §5.2)
--
-- El equipo arma la ruta (consultorios con muestras por retirar, pedidos de
-- kits o kits bajo el mínimo; al final, una parada por laboratorio que recibe
-- muestras), la inicia, y el driver marca las paradas en su teléfono.
-- `helios_puede_manejar()`: super admin, operador y driver.
-- ============================================================================

create or replace function public.helios_lab_assert_manejar()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.helios_puede_manejar() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;
  return auth.uid();
end;
$$;

revoke all on function public.helios_lab_assert_manejar() from public, anon, authenticated;

/**
 * ¿Esa parada está pendiente en una ruta en curso? Las muestras que apuntan a
 * ella ya van en el camino: armar otra ruta no se las puede quitar.
 */
create or replace function public.helios_lab_parada_en_curso(p_parada_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p_parada_id is not null and exists (
    select 1
      from public.lab_paradas pp
      join public.lab_rutas rr on rr.id = pp.ruta_id
     where pp.id = p_parada_id and pp.estado = 'pendiente' and rr.estado = 'en_curso');
$$;

revoke all on function public.helios_lab_parada_en_curso(uuid) from public, anon, authenticated;

/** La ruta de un día con sus paradas, tal como la ven el equipo y el driver. */
create or replace function public.helios_lab_ruta_json(p_fecha date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_r public.lab_rutas%rowtype;
begin
  select * into v_r from public.lab_rutas where fecha = p_fecha;
  if not found then
    return jsonb_build_object('ruta', null, 'paradas', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'ruta', jsonb_build_object('id', v_r.id, 'fecha', v_r.fecha, 'estado', v_r.estado),
    'paradas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'orden', p.orden, 'tipo', p.tipo, 'estado', p.estado,
        'nombre', case when p.tipo = 'consultorio'
                       then c.name || coalesce(' · ' || nullif(btrim(c.consultorio), ''), '')
                       else l.nombre end,
        'direccion', case when p.tipo = 'consultorio'
                          then (select b.address from public.merchant_branches b
                                 where b.merchant_id = p.merchant_id and b.is_default limit 1)
                          else l.direccion end,
        'telefono', case when p.tipo = 'consultorio' then c.contact_phone else l.telefono end,
        'nota', p.nota, 'completada_at', p.completada_at,
        'kits_a_dejar', coalesce((select jsonb_agg(jsonb_build_object('kit_tipo', k.kit_tipo, 'cantidad', k.cantidad)
                                                   order by k.kit_tipo)
                                    from public.lab_parada_kits k where k.parada_id = p.id), '[]'::jsonb),
        'muestras', coalesce((select jsonb_agg(jsonb_build_object(
                                       'codigo', m.codigo, 'examen', e.nombre, 'kit_tipo', m.kit_tipo)
                                       order by m.codigo)
                                from public.lab_muestras m
                                join public.lab_examenes e on e.id = m.examen_id
                               where m.estado <> 'anulada'
                                 and ((p.tipo = 'consultorio' and m.parada_retiro_id = p.id)
                                   or (p.tipo = 'laboratorio' and m.parada_entrega_id = p.id))), '[]'::jsonb)
      ) order by p.orden)
        from public.lab_paradas p
        left join public.merchants c on c.id = p.merchant_id
        left join public.lab_laboratorios l on l.id = p.laboratorio_id
       where p.ruta_id = v_r.id), '[]'::jsonb));
end;
$$;

revoke all on function public.helios_lab_ruta_json(date) from public, anon, authenticated;

/** La ruta del día (driver y equipo). */
create or replace function public.lab_ruta_del_dia(p_fecha date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.helios_lab_assert_manejar();
  return public.helios_lab_ruta_json(coalesce(p_fecha, public.helios_business_date(now())));
end;
$$;

/**
 * Arma (o rehace) el borrador de la ruta de un día. Consultorios: con muestras
 * por retirar, pedidos de kits pendientes, o con kits bajo el mínimo (solo si
 * ya han tenido movimientos de kits). Al final, un laboratorio por cada uno que
 * recibe muestras de esta ruta o que ya tiene muestras retiradas sin entregar.
 */
create or replace function public.admin_lab_ruta_armar(p_fecha date)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor   uuid := public.helios_lab_assert_manejar();
  v_ruta    public.lab_rutas%rowtype;
  v_orden   integer := 0;
  v_pid     uuid;
  r         record;
  k         record;
  v_ped     integer;
  v_ped_id  uuid;
  v_falta   integer;
  v_cant    integer;
begin
  if p_fecha is null then
    raise exception 'Falta la fecha' using errcode = '22023';
  end if;

  select * into v_ruta from public.lab_rutas where fecha = p_fecha for update;
  if found and v_ruta.estado <> 'borrador' then
    raise exception 'Esa ruta ya empezó: no se rehace' using errcode = '22023';
  end if;
  if not found then
    insert into public.lab_rutas (fecha, created_by) values (p_fecha, v_actor) returning * into v_ruta;
  end if;

  -- Deshace el borrador anterior.
  update public.lab_muestras set parada_retiro_id = null
   where parada_retiro_id in (select id from public.lab_paradas where ruta_id = v_ruta.id);
  update public.lab_muestras set parada_entrega_id = null
   where parada_entrega_id in (select id from public.lab_paradas where ruta_id = v_ruta.id);
  update public.lab_kit_pedidos set estado = 'pendiente', parada_id = null
   where estado = 'en_ruta' and parada_id in (select id from public.lab_paradas where ruta_id = v_ruta.id);
  delete from public.lab_paradas where ruta_id = v_ruta.id;

  -- Consultorios.
  for r in
    select c.id as merchant_id
      from public.merchants c
     where exists (select 1 from public.lab_muestras m
                    where m.merchant_id = c.id and m.estado = 'lista_para_retirar'
                      and not public.helios_lab_parada_en_curso(m.parada_retiro_id))
        or exists (select 1 from public.lab_kit_pedidos p
                    where p.merchant_id = c.id and p.estado = 'pendiente')
        or (exists (select 1 from public.lab_kit_movimientos mv where mv.merchant_id = c.id)
            and exists (select 1 from public.lab_kits kk
                         where kk.minimo_por_medico > 0
                           and public.helios_lab_stock_medico(c.id, kk.tipo) < kk.minimo_por_medico))
     order by c.name
  loop
    v_orden := v_orden + 1;
    insert into public.lab_paradas (ruta_id, orden, tipo, merchant_id)
    values (v_ruta.id, v_orden, 'consultorio', r.merchant_id)
    returning id into v_pid;

    update public.lab_muestras set parada_retiro_id = v_pid
     where merchant_id = r.merchant_id and estado = 'lista_para_retirar'
       and not public.helios_lab_parada_en_curso(parada_retiro_id);

    for k in select tipo, minimo_por_medico from public.lab_kits order by tipo loop
      select coalesce(sum(p.cantidad), 0)::integer, (array_agg(p.id order by p.created_at))[1]
        into v_ped, v_ped_id
        from public.lab_kit_pedidos p
       where p.merchant_id = r.merchant_id and p.kit_tipo = k.tipo and p.estado = 'pendiente';

      v_falta := 0;
      if k.minimo_por_medico > 0
         and exists (select 1 from public.lab_kit_movimientos mv where mv.merchant_id = r.merchant_id) then
        v_falta := greatest(k.minimo_por_medico - public.helios_lab_stock_medico(r.merchant_id, k.tipo), 0);
      end if;

      v_cant := greatest(v_ped, v_falta);
      if v_cant > 0 then
        insert into public.lab_parada_kits (parada_id, kit_tipo, cantidad, pedido_id)
        values (v_pid, k.tipo, v_cant, v_ped_id);
      end if;
    end loop;

    update public.lab_kit_pedidos set estado = 'en_ruta', parada_id = v_pid
     where merchant_id = r.merchant_id and estado = 'pendiente';
  end loop;

  -- Laboratorios que reciben muestras (de esta ruta o ya retiradas).
  for r in
    select l.id as laboratorio_id
      from public.lab_laboratorios l
     where exists (select 1 from public.lab_muestras m
                    where m.laboratorio_id = l.id and m.estado <> 'anulada'
                      and ((m.estado = 'retirada' and not public.helios_lab_parada_en_curso(m.parada_entrega_id))
                           or m.parada_retiro_id in (select id from public.lab_paradas where ruta_id = v_ruta.id)))
     order by l.nombre
  loop
    v_orden := v_orden + 1;
    insert into public.lab_paradas (ruta_id, orden, tipo, laboratorio_id)
    values (v_ruta.id, v_orden, 'laboratorio', r.laboratorio_id)
    returning id into v_pid;

    update public.lab_muestras set parada_entrega_id = v_pid
     where laboratorio_id = r.laboratorio_id and estado <> 'anulada'
       and ((estado = 'retirada' and not public.helios_lab_parada_en_curso(parada_entrega_id))
            or parada_retiro_id in (select id from public.lab_paradas where ruta_id = v_ruta.id));
  end loop;

  perform audit.log(v_actor, 'lab.ruta_armar', v_ruta.id, jsonb_build_object(
    'fecha', p_fecha, 'paradas', v_orden));
  return public.helios_lab_ruta_json(p_fecha);
end;
$$;

/** Mueve una parada a otra posición (1 = primera); las demás se reordenan. */
create or replace function public.admin_lab_parada_mover(p_parada_id uuid, p_orden integer)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.helios_lab_assert_manejar();
  v_p     public.lab_paradas%rowtype;
  v_r     public.lab_rutas%rowtype;
  v_ids   uuid[];
  v_pos   integer;
begin
  select * into v_p from public.lab_paradas where id = p_parada_id;
  if not found then
    raise exception 'No existe esa parada' using errcode = 'P0002';
  end if;
  select * into v_r from public.lab_rutas where id = v_p.ruta_id for update;
  if v_r.estado = 'cerrada' then
    raise exception 'La ruta ya está cerrada' using errcode = '22023';
  end if;
  if p_orden is null then
    raise exception 'Falta la posición' using errcode = '22023';
  end if;

  v_ids := array(select id from public.lab_paradas
                  where ruta_id = v_p.ruta_id and id <> p_parada_id order by orden, id);
  v_pos := greatest(1, least(p_orden, cardinality(v_ids) + 1));
  v_ids := v_ids[1:v_pos - 1] || p_parada_id || v_ids[v_pos:cardinality(v_ids)];

  update public.lab_paradas p set orden = x.n
    from unnest(v_ids) with ordinality as x(id, n)
   where p.id = x.id;

  perform audit.log(v_actor, 'lab.parada_mover', p_parada_id, jsonb_build_object('orden', v_pos));
  return public.helios_lab_ruta_json(v_r.fecha);
end;
$$;

/** Fija cuántos kits de un tipo se dejan en una parada de consultorio (0 la quita). */
create or replace function public.admin_lab_parada_kits(p_parada_id uuid, p_kit_tipo text, p_cantidad integer)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.helios_lab_assert_manejar();
  v_p     public.lab_paradas%rowtype;
  v_r     public.lab_rutas%rowtype;
begin
  select * into v_p from public.lab_paradas where id = p_parada_id;
  if not found then
    raise exception 'No existe esa parada' using errcode = 'P0002';
  end if;
  if v_p.tipo <> 'consultorio' then
    raise exception 'Los kits se dejan en consultorios' using errcode = '22023';
  end if;
  select * into v_r from public.lab_rutas where id = v_p.ruta_id for update;
  if v_r.estado = 'cerrada' or v_p.estado <> 'pendiente' then
    raise exception 'Esa parada ya no se puede cambiar' using errcode = '22023';
  end if;
  if not exists (select 1 from public.lab_kits where tipo = p_kit_tipo) then
    raise exception 'Ese kit no existe' using errcode = '22023';
  end if;
  if p_cantidad is null or p_cantidad < 0 or p_cantidad > 500 then
    raise exception 'La cantidad debe ser cero o más' using errcode = '22023';
  end if;

  if p_cantidad = 0 then
    delete from public.lab_parada_kits where parada_id = p_parada_id and kit_tipo = p_kit_tipo;
    -- Sin kits de ese tipo en la parada, sus pedidos no se entregan en esta
    -- ruta: vuelven a la cola para la siguiente.
    update public.lab_kit_pedidos set estado = 'pendiente', parada_id = null
     where parada_id = p_parada_id and kit_tipo = p_kit_tipo and estado = 'en_ruta';
  else
    insert into public.lab_parada_kits (parada_id, kit_tipo, cantidad)
    values (p_parada_id, p_kit_tipo, p_cantidad)
    on conflict (parada_id, kit_tipo) do update set cantidad = excluded.cantidad;
  end if;

  perform audit.log(v_actor, 'lab.parada_kits', p_parada_id, jsonb_build_object(
    'kit_tipo', p_kit_tipo, 'cantidad', p_cantidad));
  return public.helios_lab_ruta_json(v_r.fecha);
end;
$$;

create or replace function public.admin_lab_ruta_iniciar(p_fecha date)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.helios_lab_assert_manejar();
  v_r     public.lab_rutas%rowtype;
begin
  select * into v_r from public.lab_rutas where fecha = p_fecha for update;
  if not found then
    raise exception 'No hay ruta armada para ese día' using errcode = 'P0002';
  end if;
  if v_r.estado <> 'borrador' then
    raise exception 'Esa ruta ya empezó' using errcode = '22023';
  end if;
  if not exists (select 1 from public.lab_paradas where ruta_id = v_r.id) then
    raise exception 'La ruta no tiene paradas' using errcode = '22023';
  end if;
  update public.lab_rutas set estado = 'en_curso' where id = v_r.id;
  perform audit.log(v_actor, 'lab.ruta_iniciar', v_r.id, jsonb_build_object('fecha', p_fecha));
  return public.helios_lab_ruta_json(p_fecha);
end;
$$;

/**
 * El driver (o el equipo) completa una parada. Idempotente.
 * Consultorio: sus muestras pasan a `retirada`, los kits a dejar se asientan
 * como `entrega` y sus pedidos pasan a `entregado`. Laboratorio: sus muestras
 * retiradas pasan a `en_laboratorio`. La última parada cierra la ruta.
 */
create or replace function public.lab_parada_completar(p_parada_id uuid, p_nota text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.helios_lab_assert_manejar();
  v_p     public.lab_paradas%rowtype;
  v_r     public.lab_rutas%rowtype;
  v_n     integer;
  v_kits  integer := 0;
  k       record;
begin
  -- Primero la ruta, luego la parada: el mismo orden de candados que al armar.
  select * into v_p from public.lab_paradas where id = p_parada_id;
  if not found then
    raise exception 'No existe esa parada' using errcode = 'P0002';
  end if;
  select * into v_r from public.lab_rutas where id = v_p.ruta_id for update;
  select * into v_p from public.lab_paradas where id = p_parada_id for update;
  if not found then
    raise exception 'No existe esa parada' using errcode = 'P0002';
  end if;

  if v_p.estado = 'completada' then
    return jsonb_build_object('ok', true, 'ya_completada', true, 'ruta_estado', v_r.estado);
  end if;
  if v_r.estado <> 'en_curso' then
    raise exception 'La ruta no está en curso' using errcode = '22023';
  end if;

  if v_p.tipo = 'consultorio' then
    update public.lab_muestras
       set estado = 'retirada', retirada_at = now()
     where parada_retiro_id = v_p.id and estado = 'lista_para_retirar';
    get diagnostics v_n = row_count;

    for k in select kit_tipo, cantidad from public.lab_parada_kits where parada_id = v_p.id loop
      insert into public.lab_kit_movimientos (tipo, kit_tipo, cantidad, merchant_id, parada_id, nota, actor, idempotency_key)
      values ('entrega', k.kit_tipo, k.cantidad, v_p.merchant_id, v_p.id, 'Ruta ' || v_r.fecha, v_actor,
              'lab-entrega-' || v_p.id || '-' || k.kit_tipo)
      on conflict (idempotency_key) do nothing;
      v_kits := v_kits + k.cantidad;
    end loop;

    update public.lab_kit_pedidos set estado = 'entregado', atendido_at = now()
     where parada_id = v_p.id and estado = 'en_ruta';
  else
    update public.lab_muestras
       set estado = 'en_laboratorio', en_laboratorio_at = now()
     where parada_entrega_id = v_p.id and estado = 'retirada';
    get diagnostics v_n = row_count;
  end if;

  update public.lab_paradas
     set estado = 'completada', completada_at = now(), completada_por = v_actor,
         nota = left(nullif(btrim(coalesce(p_nota, '')), ''), 500)
   where id = v_p.id;

  if not exists (select 1 from public.lab_paradas where ruta_id = v_r.id and estado = 'pendiente') then
    update public.lab_rutas set estado = 'cerrada' where id = v_r.id;
    v_r.estado := 'cerrada';
  end if;

  perform audit.log(v_actor, 'lab.parada_completar', v_p.id, jsonb_build_object(
    'tipo', v_p.tipo, 'muestras', v_n, 'kits', v_kits, 'fecha', v_r.fecha));
  return jsonb_build_object('ok', true, 'ya_completada', false, 'muestras', v_n, 'kits', v_kits,
                            'ruta_estado', v_r.estado);
end;
$$;

do $$
declare
  v_f record;
begin
  for v_f in
    select p.oid::regprocedure as firma
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('lab_ruta_del_dia', 'admin_lab_ruta_armar', 'admin_lab_parada_mover',
                         'admin_lab_parada_kits', 'admin_lab_ruta_iniciar', 'lab_parada_completar')
  loop
    execute format('revoke all on function %s from public, anon', v_f.firma);
    execute format('grant execute on function %s to authenticated', v_f.firma);
  end loop;
end;
$$;
