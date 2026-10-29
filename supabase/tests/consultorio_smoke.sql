-- ============================================================================
-- Helios — La clínica se llama como su médico (20261029190000)
--
--   bash supabase/tests/run.sh consultorio_smoke
--
-- Lo que se vigila: el nombre que se escribe en el alta queda en
-- `consultorio` y `name` es el del titular («Dra. Ana Lara»); cambiar al
-- titular o su título rehace el nombre sin perder el consultorio; un nombre
-- que ya es el del médico no se guarda como consultorio, y sin titular el
-- nombre se queda como vino.
-- ============================================================================

begin;

do $$
declare
  v_id uuid;
  v_m  public.merchants%rowtype;
begin
  -- El alta: lo escrito en `name` es el consultorio.
  insert into public.merchants (name, owner_name, doctor_title, is_test)
  values ('Grupo Médico 708', 'ana LARA', 'Dra.', true)
  returning id into v_id;

  select * into v_m from public.merchants where id = v_id;
  if v_m.name <> 'Dra. Ana Lara' then
    raise exception 'El nombre debía ser el del médico, no %', v_m.name;
  end if;
  if v_m.consultorio is distinct from 'Grupo Médico 708' then
    raise exception 'El consultorio debía quedar guardado, no %', v_m.consultorio;
  end if;

  -- Cambiar el título rehace el nombre y no toca el consultorio.
  update public.merchants set doctor_title = 'Od.' where id = v_id;
  select * into v_m from public.merchants where id = v_id;
  if v_m.name <> 'Od. Ana Lara' or v_m.consultorio is distinct from 'Grupo Médico 708' then
    raise exception 'El título nuevo no se reflejó bien: % / %', v_m.name, v_m.consultorio;
  end if;

  -- Escribir en `name` (como `admin_create_merchant`) es cambiar el consultorio.
  update public.merchants set name = 'Centro Médico La Viña' where id = v_id;
  select * into v_m from public.merchants where id = v_id;
  if v_m.name <> 'Od. Ana Lara' or v_m.consultorio is distinct from 'Centro Médico La Viña' then
    raise exception 'Escribir el nombre debía cambiar el consultorio: % / %', v_m.name, v_m.consultorio;
  end if;

  -- Corregir el consultorio a mano no toca el nombre; vacío, lo borra.
  update public.merchants set consultorio = '  ' where id = v_id;
  select * into v_m from public.merchants where id = v_id;
  if v_m.name <> 'Od. Ana Lara' or v_m.consultorio is not null then
    raise exception 'Borrar el consultorio no debía tocar el nombre: % / %', v_m.name, v_m.consultorio;
  end if;

  -- Un nombre que ya es el médico no es un consultorio.
  insert into public.merchants (name, owner_name, doctor_title, is_test)
  values ('Dr. Victor Gómez', 'VICTOR MIGUEL GÓMEZ', 'Dr.', true)
  returning id into v_id;
  select * into v_m from public.merchants where id = v_id;
  if v_m.name <> 'Dr. Victor Miguel Gómez' or v_m.consultorio is not null then
    raise exception 'El nombre del médico no debía quedar como consultorio: % / %', v_m.name, v_m.consultorio;
  end if;

  -- Sin titular, el nombre se queda como vino.
  insert into public.merchants (name, is_test)
  values ('Consultorio Heredado', true)
  returning id into v_id;
  select * into v_m from public.merchants where id = v_id;
  if v_m.name <> 'Consultorio Heredado' then
    raise exception 'Sin titular el nombre no debía cambiar: %', v_m.name;
  end if;
end;
$$;

rollback;
