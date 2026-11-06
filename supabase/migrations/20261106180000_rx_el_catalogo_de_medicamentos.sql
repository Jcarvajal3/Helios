-- ============================================================================
-- RX — El buscador de medicamentos y los que aún no tienen precio
--
-- El campo de medicamento busca entre los productos cargados y los que la propia
-- clínica ya recetó. Lo que el médico escriba y no esté en ningún lado se anota
-- sin precio al emitir el récipe, para buscarle uno más adelante.
--
--   · `rx_buscar_medicamentos` devuelve solo nombres. Ni farmacia, ni precio, ni
--     si tiene precio: el orden es alfabético, y lo cargado y lo escrito salen
--     mezclados. Así el médico no sabe qué farmacia vende qué, ni a cuánto.
--
--   · Lo escrito por un médico es texto libre y puede traer datos de un paciente:
--     solo lo ve su clínica. Lo que no parezca un medicamento (un teléfono, un
--     enlace, un correo) no se anota. El récipe se emite igual.
--
--   · `rx_medicamentos_sin_precio` es la lista de trabajo para buscar precios:
--     lo más recetado primero. Sin permisos para la API.
-- ============================================================================

create table public.rx_medicamentos (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid references public.merchants (id),
  clave       text not null,
  nombre      text not null,
  veces       integer not null default 1,
  ultimo_uso  timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  unique nulls not distinct (merchant_id, clave)
);

comment on table public.rx_medicamentos is
  'RX: lo que los médicos recetan y aún no coincide con un producto cargado. merchant_id = la clínica que lo escribió, la única que lo ve; null = visible para todas, solo a mano y tras revisarlo.';

alter table public.rx_medicamentos enable row level security;
revoke all on table public.rx_medicamentos from public, anon, authenticated;

/** Un texto para buscar: sin acentos ni mayúsculas. */
create function public.rx_texto_busqueda(p_texto text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select translate(lower(coalesce(p_texto, '')), 'áàäâãéèëêíìïîóòöôõúùüûñç', 'aaaaaeeeeiiiiooooouuuunc');
$$;

/** Dos formas de escribir lo mismo tienen la misma clave: sin neutras ni orden de escritura. */
create function public.rx_clave_medicamento(p_nombre text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(string_agg(t, ' ' order by t), '')
  from unnest(public.rx_tokens(p_nombre)) t
  where not t = any (public.rx_palabras_neutras());
$$;

/**
 * Anota lo que un médico recetó, si no coincide con un producto cargado. Es un
 * registro de apoyo: lo que no parezca un medicamento simplemente no se anota.
 */
create function public.rx_anotar_medicamento(p_merchant_id uuid, p_nombre text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_nombre text := nullif(btrim(coalesce(p_nombre, '')), '');
  v_pedido text[];
begin
  if v_nombre is null or char_length(v_nombre) > 160
     or public.rx_texto_busqueda(v_nombre) ~ '(https?:|www\.|@|\.(com|net|org|ve)([^a-z]|$)|[0-9]{7,}|0[0-9]{3}[- .]?[0-9]{3})' then
    return;
  end if;

  select coalesce(array_agg(t), '{}') into v_pedido
  from unnest(public.rx_tokens(v_nombre)) t
  where not t = any (public.rx_palabras_neutras());

  if not exists (select 1 from unnest(v_pedido) t where t ~ '^[a-z]{3}') then
    return;
  end if;

  if exists (
    select 1 from public.rx_precios p
    where p.tokens @> v_pedido and v_pedido @> p.tokens_propios
  ) then
    return;
  end if;

  insert into public.rx_medicamentos (merchant_id, clave, nombre)
  values (p_merchant_id, public.rx_clave_medicamento(v_nombre), v_nombre)
  on conflict (merchant_id, clave) do update
    set veces = public.rx_medicamentos.veces + 1,
        ultimo_uso = now();
end;
$$;

/** Al emitir un récipe. Pase lo que pase aquí, el récipe se emite. */
create function public.rx_recipe_anota_medicamentos()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_renglon jsonb;
begin
  for v_renglon in select value from jsonb_array_elements(new.medicamentos) loop
    begin
      perform public.rx_anotar_medicamento(new.merchant_id, v_renglon ->> 'medicamento');
    exception when others then
      raise warning 'rx_recipe_anota_medicamentos: no se pudo anotar un medicamento (%)', sqlstate;
    end;
  end loop;
  return null;
end;
$$;

create trigger rx_recipes_anotan_medicamentos
  after insert on public.rx_recipes
  for each row execute function public.rx_recipe_anota_medicamentos();

-- Lo que ya se recetó antes de que existiera el trigger.
do $$
declare
  v_recipe record;
  v_renglon jsonb;
begin
  for v_recipe in select merchant_id, medicamentos from public.rx_recipes loop
    for v_renglon in select value from jsonb_array_elements(v_recipe.medicamentos) loop
      perform public.rx_anotar_medicamento(v_recipe.merchant_id, v_renglon ->> 'medicamento');
    end loop;
  end loop;
end;
$$;

/**
 * El buscador del médico. Todas las palabras deben estar en el nombre, en cualquier
 * orden. Devuelve una lista de nombres y nada más. El orden es alfabético, con los
 * que empiezan por lo escrito primero: ni el precio ni la farmacia lo mueven.
 */
create function public.rx_buscar_medicamentos(p_busqueda text, p_limite integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_clinica  uuid := public.rx_clinica();
  v_texto    text := btrim(public.rx_texto_busqueda(p_busqueda));
  v_palabras text[];
  v_limite   integer := least(greatest(coalesce(p_limite, 20), 1), 50);
begin
  if char_length(v_texto) < 2 then
    return '[]'::jsonb;
  end if;
  v_palabras := regexp_split_to_array(v_texto, '\s+');

  return coalesce((
    select jsonb_agg(x.nombre order by x.empieza desc, x.nombre)
    from (
      select y.nombre, y.empieza
      from (
        -- Un mismo medicamento una sola vez, aunque lo vendan varias farmacias.
        select distinct on (public.rx_clave_medicamento(c.nombre))
               c.nombre,
               public.rx_texto_busqueda(c.nombre) like replace(replace(replace(v_palabras[1], '\', '\\'), '%', '\%'), '_', '\_') || '%' as empieza
        from (
          select p.nombre
          from public.rx_precios p
          join public.rx_farmacias f on f.id = p.farmacia_id
          where f.activa
            and char_length(p.nombre) <= 160
          union all
          select m.nombre
          from public.rx_medicamentos m
          where m.merchant_id is null or m.merchant_id = v_clinica
        ) c
        where not exists (
          select 1 from unnest(v_palabras) w
          where position(w in public.rx_texto_busqueda(c.nombre)) = 0
        )
        order by public.rx_clave_medicamento(c.nombre), c.nombre
      ) y
      order by y.empieza desc, y.nombre
      limit v_limite
    ) x
  ), '[]'::jsonb);
end;
$$;

/**
 * La lista de trabajo: lo que se receta y aún no coincide con ningún producto, lo
 * más recetado primero. Lleva texto libre de los médicos: es solo de uso interno.
 */
create view public.rx_medicamentos_sin_precio
with (security_invoker = true)
as
  select m.clave,
         min(m.nombre) as nombre,
         sum(m.veces) as veces,
         count(distinct m.merchant_id) as clinicas,
         max(m.ultimo_uso) as ultimo_uso
  from public.rx_medicamentos m
  where not exists (select 1 from public.rx_controlados c where c.palabra = any (public.rx_tokens(m.nombre)))
    and not exists (
      select 1
      from public.rx_precios p
      where p.tokens @> (
              select coalesce(array_agg(t), '{}') from unnest(public.rx_tokens(m.nombre)) t
              where not t = any (public.rx_palabras_neutras())
            )
        and (
              select coalesce(array_agg(t), '{}') from unnest(public.rx_tokens(m.nombre)) t
              where not t = any (public.rx_palabras_neutras())
            ) @> p.tokens_propios
    )
  group by m.clave
  order by sum(m.veces) desc, min(m.nombre);

revoke all on table public.rx_medicamentos_sin_precio from public, anon, authenticated;

revoke all on function public.rx_texto_busqueda(text) from public, anon, authenticated;
revoke all on function public.rx_clave_medicamento(text) from public, anon, authenticated;
revoke all on function public.rx_anotar_medicamento(uuid, text) from public, anon, authenticated;
revoke all on function public.rx_recipe_anota_medicamentos() from public, anon, authenticated;
revoke all on function public.rx_buscar_medicamentos(text, integer) from public, anon;
grant execute on function public.rx_buscar_medicamentos(text, integer) to authenticated;
