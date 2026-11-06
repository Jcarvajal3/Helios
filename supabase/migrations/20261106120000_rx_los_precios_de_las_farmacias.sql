-- ============================================================================
-- RX — Dónde conseguir los medicamentos y a qué precio
--
-- El paciente abre un enlace (sin cuenta) y ve, por cada medicamento de su
-- récipe, las farmacias que lo publican, de menor a mayor precio.
--
-- Cuatro reglas de diseño, que esta migración hace cumplir:
--
--   1. El médico no elige farmacias ni precios. Ninguna RPC suya los recibe o los
--      escribe, las tablas no tienen permisos para la API y ni siquiera recibe el
--      enlace del paciente: lo pide `rx-enviar` con la service_role. El orden es
--      el precio, sin ningún otro criterio. La Ley de Ejercicio de la Medicina le
--      impide sugerir farmacias: por eso esto no va en el PDF que él firma.
--
--   2. Mejor no mostrar nada que mostrar otro medicamento. Producto y récipe deben
--      decir lo mismo, en los dos sentidos: toda palabra de lo recetado está en el
--      producto y toda palabra del producto está en lo recetado, salvo una lista
--      cerrada de palabras neutras y las del laboratorio. Así «Metformina 500 mg»
--      no encuentra «Metformina XR 500 mg», ni «Diclofenac 75 mg» una ampolla, ni
--      «Losartán 50 mg» una combinación. Sin dosis no se busca.
--
--   3. Un dato dudoso no se carga y un precio viejo no se enseña. La carga exige
--      la fecha con su zona y rechaza precios ambiguos o fuera de rango. Lo que no
--      se vio en 14 días deja de salir.
--
--   4. La página pública no lleva texto libre del médico. Enseña solo lo que
--      coincidió con un producto, y dice cuántos medicamentos quedaron sin precio.
--      Sin el nombre del paciente ni el del médico. La lista de medicamentos sigue
--      siendo un dato de salud: el enlace lleva 122 bits al azar y vence a los 30
--      días.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las tablas
-- ---------------------------------------------------------------------------

create table public.rx_farmacias (
  id         uuid primary key default gen_random_uuid(),
  slug       text not null unique,
  nombre     text not null,
  activa     boolean not null default true,
  motivo     text,
  created_at timestamptz not null default now()
);

comment on table public.rx_farmacias is
  'RX: las farmacias admitidas. Una carga rechaza las que no estén aquí. Con activa = false no se cargan ni se enseñan sus precios.';

insert into public.rx_farmacias (slug, nombre, activa, motivo) values
  ('farmatodo', 'Farmatodo', true, null),
  ('locatel', 'Locatel', true, null),
  ('saas', 'Farmacia SAAS', true, null),
  -- No son de Caracas (Javier, 2026-11-06).
  ('farmadon', 'Farmadon', false, 'No es de Caracas'),
  ('farmapaz', 'Farmapaz', false, 'No es de Caracas');

create table public.rx_cargas (
  id         uuid primary key default gen_random_uuid(),
  fuente     text not null,
  archivo    text,
  recibidas  integer not null,
  aceptadas  integer not null,
  ignoradas  integer not null default 0,
  rechazadas integer not null,
  rechazos   jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

comment on table public.rx_cargas is
  'RX: cada carga de precios, con lo que se rechazó y por qué. Ignoradas: filas válidas más viejas que el dato guardado.';

create table public.rx_precios (
  id             uuid primary key default gen_random_uuid(),
  farmacia_id    uuid not null references public.rx_farmacias (id),
  clave          text not null,
  nombre         text not null,
  tokens         text[] not null,
  tokens_propios text[] not null,
  laboratorio    text,
  presentacion   text,
  sku            text,
  precio_usd     numeric(18,4),
  precio_ves     numeric(18,2),
  url            text,
  disponible     boolean,
  visto_en       timestamptz not null,
  fuente         text not null,
  carga_id       uuid not null references public.rx_cargas (id),
  updated_at     timestamptz not null default now(),
  unique (farmacia_id, clave),
  constraint rx_precios_una_moneda check ((precio_usd is null) <> (precio_ves is null)),
  constraint rx_precios_positivo check (coalesce(precio_usd, precio_ves) > 0),
  constraint rx_precios_url_segura check (url is null or url ~ '^https://')
);

comment on table public.rx_precios is
  'RX: lo que cada farmacia publica. `nombre` va tal como lo publica. `tokens`: las palabras del nombre y del laboratorio. `tokens_propios`: las que obligatoriamente deben estar en lo recetado.';

create index rx_precios_tokens_idx on public.rx_precios using gin (tokens);
create index rx_precios_visto_idx on public.rx_precios (visto_en);

alter table public.rx_farmacias enable row level security;
alter table public.rx_cargas    enable row level security;
alter table public.rx_precios   enable row level security;

revoke all on table public.rx_farmacias from public, anon, authenticated;
revoke all on table public.rx_cargas    from public, anon, authenticated;
revoke all on table public.rx_precios   from public, anon, authenticated;

-- El enlace del paciente: 122 bits al azar por récipe. `rx_listar` no lo devuelve.
alter table public.rx_recipes
  add column token_precios text not null default replace(gen_random_uuid()::text, '-', '');
create unique index rx_recipes_token_idx on public.rx_recipes (token_precios);

-- ---------------------------------------------------------------------------
-- 2. La búsqueda
-- ---------------------------------------------------------------------------

/**
 * Un nombre de medicamento en piezas comparables. Sin acentos ni mayúsculas; las
 * dosis pegadas a su unidad; «1.000 mg», «1000mg» y «1 g» son la misma pieza;
 * «875/125 mg» son dos dosis; «,5 mg» es «0.5mg», nunca «5mg». Un peso de 5 g o
 * más es el tamaño del envase. «x 21» y «30 tabletas» dicen cuánto trae la caja,
 * no qué es: esa cantidad se va. Cualquier otro número se queda, y como una pieza
 * más tiene que coincidir: «Losartán 50» no encuentra «Losartán 50 mg».
 */
create function public.rx_tokens(p_texto text)
returns text[]
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v        text := lower(coalesce(p_texto, ''));
  v_salida text[] := '{}';
  v_token  text;
  v_partes text[];
  v_numero numeric;
  v_unidad text;
  v_miles  text;
begin
  v := translate(v, 'áàäâãéèëêíìïîóòöôõúùüûñç', 'aaaaaeeeeiiiiooooouuuunc');
  -- La micro de los dos alfabetos: U+00B5 y U+03BC.
  v := replace(replace(v, chr(181) || 'g', 'mcg'), chr(956) || 'g', 'mcg');
  -- Un decimal sin cero delante, antes de que nada lo confunda: ,5 y .5 son 0.5.
  v := regexp_replace(v, '(^|[^0-9])[.,]([0-9])', '\10.\2', 'g');
  -- Miles, con los grupos que sean: 1.000 y 1.200.000. Con un cero delante es decimal.
  loop
    v_miles := (regexp_match(v, '(?:^|[^0-9.,])([1-9][0-9]{0,2}(?:[.,][0-9]{3})+)(?![0-9])'))[1];
    exit when v_miles is null;
    v := replace(v, v_miles, regexp_replace(v_miles, '[.,]', '', 'g'));
  end loop;
  v := regexp_replace(v, '([0-9]),([0-9])', '\1.\2', 'g');
  -- Dos dosis con una sola unidad: 875/125 mg.
  v := regexp_replace(v,
    '([0-9]+(?:\.[0-9]+)?)\s*/\s*([0-9]+(?:\.[0-9]+)?)\s*(mcgs?|ug|mgs?|ui|iu|grs|gr|g)(?![a-z0-9])',
    '\1\3 \2\3', 'g');
  -- Lo que trae la caja.
  v := regexp_replace(v, '(^|[^a-z0-9])(x|#|c/)\s*[0-9]+(\s*(ml|cc|grs|gr|g|l)(?![a-z0-9]))?', '\1 ', 'g');
  v := regexp_replace(v, '[0-9]+\s*(capsulas?|caps?|tabletas?|tabs?|comprimidos?|cpr)(?![a-z0-9])', '\1', 'g');
  v := regexp_replace(v, '([0-9])\s*(mcgs|mcg|ug|mgs|mg|grs|gr|g|mls|ml|cc|l|ui|iu|%)(?![a-z0-9])', '\1\2 ', 'g');

  foreach v_token in array regexp_split_to_array(v, '[^a-z0-9.%]+') loop
    v_token := btrim(v_token, '.');
    continue when v_token = '';

    v_partes := regexp_match(v_token, '^([0-9]+(?:\.[0-9]+)?)(mcgs|mcg|ug|mgs|mg|grs|gr|g|mls|ml|cc|l|ui|iu|%)$');
    if v_partes is not null then
      v_numero := v_partes[1]::numeric;
      v_unidad := v_partes[2];
      if v_unidad in ('g', 'gr', 'grs') then
        if v_numero < 5 then
          v_numero := v_numero * 1000;
          v_unidad := 'mg';
        else
          v_unidad := 'g';
        end if;
      elsif v_unidad = 'mgs' then
        v_unidad := 'mg';
      elsif v_unidad in ('ug', 'mcgs') then
        v_unidad := 'mcg';
      elsif v_unidad in ('cc', 'mls') then
        v_unidad := 'ml';
      elsif v_unidad = 'l' then
        v_numero := v_numero * 1000;
        v_unidad := 'ml';
      elsif v_unidad = 'iu' then
        v_unidad := 'ui';
      end if;
      v_token := trim_scale(v_numero)::text || v_unidad;
    elsif v_token in ('cap', 'caps', 'capsula', 'capsulas') then
      v_token := 'cap';
    elsif v_token in ('tab', 'tabs', 'tableta', 'tabletas', 'comprimido', 'comprimidos', 'cpr') then
      v_token := 'tab';
    elsif v_token in ('jbe', 'jarabe') then
      v_token := 'jarabe';
    elsif v_token in ('amp', 'ampolla', 'ampollas') then
      v_token := 'amp';
    elsif v_token in ('susp', 'suspension') then
      v_token := 'susp';
    elsif v_token in ('sol', 'solucion') then
      v_token := 'sol';
    elsif v_token in ('de', 'del', 'la', 'el', 'los', 'las', 'en', 'por', 'con', 'para', 'y') then
      continue;
    end if;

    if not v_token = any (v_salida) then
      v_salida := v_salida || v_token;
    end if;
  end loop;

  return v_salida;
end;
$$;

/**
 * Las piezas que no cambian qué medicamento es. Es una lista blanca a propósito:
 * lo que no esté aquí («xr», «retard», «ninos», «ampolla») separa dos productos.
 */
create function public.rx_palabras_neutras()
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select array['cap', 'tab', 'caja', 'cajas', 'blister', 'unidades', 'unidad', 'und', 'recubierta', 'recubiertas']::text[];
$$;

/**
 * Psicotrópicos y otros controlados: ni se cargan ni se enseñan (Javier,
 * 2026-11-06). Es una lista por palabras, de principios activos y marcas comunes:
 * no es exhaustiva y debe revisarla un farmacéutico. Una fila también puede venir
 * marcada con `controlado = si`.
 */
create table public.rx_controlados (
  palabra    text primary key,
  created_at timestamptz not null default now()
);

alter table public.rx_controlados enable row level security;
revoke all on table public.rx_controlados from public, anon, authenticated;

insert into public.rx_controlados (palabra)
select unnest(array[
  -- Benzodiacepinas e hipnóticos
  'alprazolam', 'alprazolan', 'bromazepam', 'clobazam', 'clonazepam', 'clorazepato', 'diazepam', 'flunitrazepam',
  'lorazepam', 'midazolam', 'nitrazepam', 'oxazepam', 'temazepam', 'triazolam', 'zolpidem', 'zopiclona', 'eszopiclona',
  'fenobarbital', 'pentobarbital', 'tiopental',
  -- Opioides
  'buprenorfina', 'codeina', 'fentanilo', 'hidrocodona', 'hidromorfona', 'meperidina', 'metadona', 'morfina',
  'nalbufina', 'oxicodona', 'petidina', 'tapentadol', 'tramadol',
  -- Estimulantes y anestésicos
  'anfetamina', 'dexanfetamina', 'lisdexanfetamina', 'metilfenidato', 'modafinilo', 'ketamina',
  -- Antipsicóticos y estabilizadores
  'aripiprazol', 'clozapina', 'haloperidol', 'litio', 'olanzapina', 'quetiapina', 'risperidona', 'ziprasidona',
  -- Antidepresivos
  'amitriptilina', 'bupropion', 'citalopram', 'clomipramina', 'duloxetina', 'escitalopram', 'fluoxetina', 'imipramina',
  'mirtazapina', 'paroxetina', 'sertralina', 'trazodona', 'venlafaxina',
  -- Marcas comunes
  'adderall', 'ativan', 'concerta', 'dolantina', 'dormicum', 'durogesic', 'lexapro', 'lexotanil', 'oxycontin', 'paxil',
  'prozac', 'risperdal', 'ritalin', 'ritalina', 'rivotril', 'seroquel', 'stilnox', 'tafil', 'tramal', 'valium', 'xanax',
  'zaldiar', 'zoloft', 'zyprexa'
]);

/** Las piezas de un producto que lo recetado debe decir: sin neutras ni laboratorio. */
create function public.rx_tokens_propios(p_nombre text, p_laboratorio text)
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(t), '{}')
  from unnest(public.rx_tokens(p_nombre)) t
  where not t = any (public.rx_palabras_neutras())
    and not t = any (public.rx_tokens(p_laboratorio));
$$;

/**
 * Las ofertas de lo recetado, de menor a mayor precio. Para comparar se pasa a
 * dólares con la última tasa BCV; se enseña en su moneda original.
 *
 * Coinciden si todo lo recetado está en el producto (o en su laboratorio: nombrar
 * una marca es legítimo) y todo lo propio del producto está en lo recetado. Sin
 * una palabra de tres letras y una dosis, no se busca.
 */
create function public.rx_ofertas(p_medicamento text, p_tope integer default 8)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_pedido text[];
  v_tasa   numeric;
begin
  select coalesce(array_agg(t), '{}') into v_pedido
  from unnest(public.rx_tokens(p_medicamento)) t
  where not t = any (public.rx_palabras_neutras());

  if not exists (select 1 from unnest(v_pedido) t where t ~ '^[a-z]{3}')
     or not exists (select 1 from unnest(v_pedido) t where t ~ '^[0-9.]+(mg|mcg|ui|%)$') then
    return '[]'::jsonb;
  end if;

  select r.rate into v_tasa
  from public.exchange_rates r
  where r.source = 'BCV' and r.effective_date <= public.helios_business_date(now())
  order by r.effective_date desc
  limit 1;

  return coalesce((
    select jsonb_agg(
             jsonb_build_object(
               'farmacia',     x.farmacia,
               'producto',     x.nombre,
               'laboratorio',  coalesce(x.laboratorio, ''),
               'presentacion', coalesce(x.presentacion, ''),
               'moneda',       case when x.precio_usd is not null then 'USD' else 'VES' end,
               'precio',       coalesce(x.precio_usd, x.precio_ves),
               'url',          coalesce(x.url, ''),
               'disponible',   x.disponible,
               'visto_en',     x.visto_en
             )
             order by x.en_usd nulls last, x.farmacia, x.nombre
           )
    from (
      select f.nombre as farmacia, p.nombre, p.laboratorio, p.presentacion, p.precio_usd, p.precio_ves,
             p.url, p.disponible, p.visto_en,
             coalesce(p.precio_usd, p.precio_ves / nullif(v_tasa, 0)) as en_usd
      from public.rx_precios p
      join public.rx_farmacias f on f.id = p.farmacia_id
      where f.activa
        and p.disponible is not false
        and p.visto_en >= now() - interval '14 days'
        and p.tokens @> v_pedido
        and v_pedido @> p.tokens_propios
        and not exists (select 1 from public.rx_controlados c where c.palabra = any (p.tokens))
      order by en_usd nulls last, f.nombre, p.nombre
      limit least(greatest(coalesce(p_tope, 8), 1), 30)
    ) x
  ), '[]'::jsonb);
end;
$$;

/** Lo que se busca de un renglón del récipe: la presentación también lo define. */
create function public.rx_ofertas_del_renglon(p_renglon jsonb, p_tope integer default 8)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.rx_ofertas(
    coalesce(p_renglon ->> 'medicamento', '') || ' ' || coalesce(p_renglon ->> 'presentacion', ''),
    p_tope
  );
$$;

revoke all on function public.rx_tokens(text) from public, anon, authenticated;
revoke all on function public.rx_palabras_neutras() from public, anon, authenticated;
revoke all on function public.rx_tokens_propios(text, text) from public, anon, authenticated;
revoke all on function public.rx_ofertas(text, integer) from public, anon, authenticated;
revoke all on function public.rx_ofertas_del_renglon(jsonb, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Lo que ve el paciente
-- ---------------------------------------------------------------------------

/**
 * Lo que abre el enlace del correo, sin cuenta. Solo los medicamentos que
 * coincidieron con un producto: su texto, por construcción, no trae palabras que
 * el producto no tenga. De los demás, solo cuántos son. Un enlace falso y uno
 * vencido dan el mismo error.
 */
create function public.rx_precios_publicos(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipe public.rx_recipes%rowtype;
begin
  if p_token is not null and p_token ~ '^[0-9a-f]{32}$' then
    select * into v_recipe from public.rx_recipes
     where token_precios = p_token and created_at >= now() - interval '30 days';
  end if;
  if v_recipe.id is null then
    raise exception 'Este enlace no existe o ya venció.' using errcode = 'P0002';
  end if;

  return (
    with renglones as (
      select o, m ->> 'medicamento' as nombre, public.rx_ofertas_del_renglon(m) as ofertas
      from jsonb_array_elements(v_recipe.medicamentos) with ordinality as e (m, o)
    )
    select jsonb_build_object(
      'medicamentos', coalesce(
        jsonb_agg(jsonb_build_object('nombre', nombre, 'ofertas', ofertas) order by o)
          filter (where jsonb_array_length(ofertas) > 0),
        '[]'::jsonb
      ),
      'sin_precio', count(*) filter (where jsonb_array_length(ofertas) = 0)
    )
    from renglones
  );
end;
$$;

revoke all on function public.rx_precios_publicos(text) from public;
grant execute on function public.rx_precios_publicos(text) to anon, authenticated;

/**
 * Lo que `rx-enviar` necesita para el enlace. Solo la service_role: el médico no
 * recibe el enlace de su paciente, ni puede probar qué textos encuentran precios.
 */
create function public.rx_datos_precios_envio(p_recipe_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'token_precios', r.token_precios,
    'hay_precios', r.created_at >= now() - interval '30 days' and exists (
      select 1 from jsonb_array_elements(r.medicamentos) m
      where jsonb_array_length(public.rx_ofertas_del_renglon(m, 1)) > 0
    )
  )
  from public.rx_recipes r
  where r.id = p_recipe_id;
$$;

revoke all on function public.rx_datos_precios_envio(uuid) from public, anon, authenticated;
grant execute on function public.rx_datos_precios_envio(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 4. La carga
-- ---------------------------------------------------------------------------

/** Cómo se compara el nombre de una farmacia: sin «Farmacia» delante. */
create function public.rx_slug_farmacia(p_nombre text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select regexp_replace(
    regexp_replace(
      translate(lower(btrim(coalesce(p_nombre, ''))), 'áàäâéèëêíìïîóòöôúùüûñ', 'aaaaeeeeiiiioooouuuun'),
      '^farmacias?\s+', ''
    ),
    '[^a-z0-9]', '', 'g'
  );
$$;

revoke all on function public.rx_slug_farmacia(text) from public, anon, authenticated;

/** Admite una farmacia nueva. Solo la service_role o el dueño de la base. */
create function public.rx_agregar_farmacia(p_nombre text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_nombre text := nullif(btrim(coalesce(p_nombre, '')), '');
  v_slug   text := public.rx_slug_farmacia(p_nombre);
begin
  if v_nombre is null or v_slug = '' or char_length(v_nombre) > 80 then
    raise exception 'Revisa el nombre de la farmacia.' using errcode = '22023';
  end if;
  if v_slug ~ '(farmadon|farmapaz)' then
    raise exception 'Esa farmacia está excluida: no es de Caracas.' using errcode = '22023';
  end if;
  insert into public.rx_farmacias (slug, nombre)
  values (v_slug, v_nombre)
  on conflict (slug) do nothing;
  return v_slug;
end;
$$;

revoke all on function public.rx_agregar_farmacia(text) from public, anon, authenticated;
grant execute on function public.rx_agregar_farmacia(text) to service_role;

/**
 * Carga un lote de filas (`rx/scripts/cargar-precios.mjs`). Solo la service_role
 * o el dueño de la base. Cada fila se acepta o se rechaza con su motivo, sin
 * tumbar el lote. Una farmacia desconocida se rechaza: `Farmadon C.A.` no puede
 * colarse como una farmacia nueva. Un dato más viejo no pisa uno más nuevo.
 */
create function public.rx_cargar_precios(p_fuente text, p_archivo text, p_filas jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_min_usd   constant numeric := 0.05;
  c_max_usd   constant numeric := 1000;
  v_carga     uuid := gen_random_uuid();
  v_fuente    text := nullif(btrim(coalesce(p_fuente, '')), '');
  v_tasa      numeric;
  v_fila      jsonb;
  v_indice    integer := 0;
  v_numero    integer;
  v_aceptadas integer := 0;
  v_ignoradas integer := 0;
  v_rechazadas integer := 0;
  v_rechazos  jsonb := '[]'::jsonb;
  v_motivo    text;
  v_farmacia  text;
  v_nombre    text;
  v_laboratorio text;
  v_presentacion text;
  v_moneda    text;
  v_precio_t  text;
  v_precio    numeric;
  v_en_usd    numeric;
  v_sku       text;
  v_url       text;
  v_disp      text;
  v_visto_t   text;
  v_visto     timestamptz;
  v_tokens    text[];
  v_f_id      uuid;
  v_f_activa  boolean;
  v_filas     integer;
begin
  if v_fuente is null then
    raise exception 'Falta la fuente de la carga.' using errcode = '22023';
  end if;
  if p_filas is null or jsonb_typeof(p_filas) <> 'array' then
    raise exception 'Las filas deben venir en una lista.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_filas) > 2000 then
    raise exception 'Máximo 2000 filas por lote.' using errcode = '22023';
  end if;

  select r.rate into v_tasa
  from public.exchange_rates r
  where r.source = 'BCV' and r.effective_date <= public.helios_business_date(now())
  order by r.effective_date desc
  limit 1;

  insert into public.rx_cargas (id, fuente, archivo, recibidas, aceptadas, rechazadas)
  values (v_carga, v_fuente, p_archivo, jsonb_array_length(p_filas), 0, 0);

  for v_fila in select value from jsonb_array_elements(p_filas) loop
    v_indice := v_indice + 1;
    v_motivo := null;
    v_numero := coalesce(nullif(v_fila ->> 'fila_archivo', '')::integer, v_indice);

    v_farmacia := nullif(btrim(coalesce(v_fila ->> 'farmacia', '')), '');
    v_nombre   := nullif(btrim(coalesce(v_fila ->> 'nombre', '')), '');
    v_laboratorio  := left(nullif(btrim(coalesce(v_fila ->> 'laboratorio', '')), ''), 160);
    v_presentacion := left(nullif(btrim(coalesce(v_fila ->> 'presentacion', '')), ''), 160);
    v_moneda   := upper(btrim(coalesce(v_fila ->> 'moneda', '')));
    v_precio_t := btrim(coalesce(v_fila ->> 'precio', ''));
    v_sku      := nullif(btrim(coalesce(v_fila ->> 'sku', '')), '');
    v_url      := nullif(btrim(coalesce(v_fila ->> 'url', '')), '');
    v_disp     := lower(btrim(coalesce(v_fila ->> 'disponible', '')));
    v_visto_t  := btrim(coalesce(v_fila ->> 'visto_en', ''));

    if v_farmacia is null then
      v_motivo := 'Falta la farmacia';
    elsif v_nombre is null then
      v_motivo := 'Falta el nombre';
    elsif char_length(v_nombre) > 300 then
      v_motivo := 'Texto demasiado largo';
    elsif v_sku is not null and char_length(v_sku) > 120 then
      v_motivo := 'SKU demasiado largo';
    elsif position(chr(65533) in v_nombre || coalesce(v_laboratorio, '') || coalesce(v_presentacion, '')) > 0 then
      v_motivo := 'Caracteres dañados: guarda el archivo como CSV UTF-8';
    elsif v_moneda not in ('VES', 'USD') then
      v_motivo := 'La moneda debe ser VES o USD';
    -- 1.234 puede ser mil o uno y pico: no se adivina.
    elsif v_precio_t !~ '^[0-9]{1,12}(\.[0-9]{1,4})?$' or v_precio_t ~ '^[0-9]{1,3}\.[0-9]{3}$' then
      v_motivo := 'Precio no válido';
    elsif v_disp not in ('', 'si', 'sí', 'no') then
      v_motivo := 'Disponible debe ser si, no o vacío';
    elsif v_visto_t !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}(:?[0-9]{2})?)$' then
      v_motivo := 'La fecha debe ser ISO y con zona, como 2026-11-06T10:00:00-04:00';
    else
      v_precio := v_precio_t::numeric;
      if v_moneda = 'VES' then
        v_precio := round(v_precio, 2);
        v_en_usd := v_precio / nullif(v_tasa, 0);
      else
        v_precio := round(v_precio, 4);
        v_en_usd := v_precio;
      end if;
      -- Una moneda equivocada cae aquí: Bs 1.117 como dólares, o $5 como bolívares.
      if v_en_usd is null then
        v_motivo := 'Sin tasa BCV para validar el precio';
      elsif v_en_usd < c_min_usd or v_en_usd > c_max_usd then
        v_motivo := 'Precio fuera de rango: revisa el monto y la moneda';
      end if;
    end if;

    if v_motivo is null then
      begin
        v_visto := v_visto_t::timestamptz;
        if v_visto > now() + interval '1 day' then
          v_motivo := 'La fecha está en el futuro';
        end if;
      exception when others then
        v_motivo := 'Fecha no válida';
      end;
    end if;

    if v_motivo is null then
      v_tokens := public.rx_tokens(v_nombre);
      if not exists (select 1 from unnest(v_tokens) t where t ~ '^[a-z]{3}') then
        v_motivo := 'El nombre no dice un medicamento';
      elsif lower(btrim(coalesce(v_fila ->> 'controlado', ''))) in ('si', 'sí')
         or exists (
           select 1 from public.rx_controlados c
           where c.palabra = any (v_tokens || public.rx_tokens(v_laboratorio))
         ) then
        v_motivo := 'Medicamento controlado';
      end if;
    end if;

    if v_motivo is null then
      select id, activa into v_f_id, v_f_activa
      from public.rx_farmacias
      where slug = public.rx_slug_farmacia(v_farmacia);
      if v_f_id is null then
        v_motivo := 'Farmacia desconocida';
      elsif not v_f_activa then
        v_motivo := 'Farmacia excluida';
      end if;
    end if;

    -- Un enlace que no sea https no se guarda: la página del paciente lo abriría.
    if v_url is not null and (v_url !~ '^https://[^[:space:]"<>]+$' or char_length(v_url) > 1000) then
      v_url := null;
    end if;

    if v_motivo is null then
      begin
        insert into public.rx_precios (
          farmacia_id, clave, nombre, tokens, tokens_propios, laboratorio, presentacion, sku,
          precio_usd, precio_ves, url, disponible, visto_en, fuente, carga_id
        ) values (
          v_f_id,
          coalesce(
            'sku:' || v_sku,
            'nombre:' || array_to_string(v_tokens, ' ')
              || '|' || lower(coalesce(v_laboratorio, ''))
              || '|' || lower(coalesce(v_presentacion, ''))
          ),
          v_nombre,
          (select array(select distinct t from unnest(v_tokens || public.rx_tokens(v_laboratorio)) t)),
          public.rx_tokens_propios(v_nombre, v_laboratorio),
          v_laboratorio,
          v_presentacion,
          v_sku,
          case when v_moneda = 'USD' then v_precio end,
          case when v_moneda = 'VES' then v_precio end,
          v_url,
          case when v_disp = 'no' then false when v_disp in ('si', 'sí') then true end,
          v_visto,
          left(coalesce(nullif(btrim(coalesce(v_fila ->> 'fuente', '')), ''), v_fuente), 40),
          v_carga
        )
        on conflict (farmacia_id, clave) do update
          set nombre = excluded.nombre,
              tokens = excluded.tokens,
              tokens_propios = excluded.tokens_propios,
              laboratorio = excluded.laboratorio,
              presentacion = excluded.presentacion,
              sku = excluded.sku,
              precio_usd = excluded.precio_usd,
              precio_ves = excluded.precio_ves,
              url = excluded.url,
              disponible = excluded.disponible,
              visto_en = excluded.visto_en,
              fuente = excluded.fuente,
              carga_id = excluded.carga_id,
              updated_at = now()
          where excluded.visto_en >= rx_precios.visto_en;
        get diagnostics v_filas = row_count;
        if v_filas = 0 then
          v_ignoradas := v_ignoradas + 1;
        else
          v_aceptadas := v_aceptadas + 1;
        end if;
      exception when others then
        v_motivo := 'No se pudo guardar la fila';
      end;
    end if;

    if v_motivo is not null then
      v_rechazadas := v_rechazadas + 1;
      if jsonb_array_length(v_rechazos) < 200 then
        v_rechazos := v_rechazos || jsonb_build_object('fila', v_numero, 'motivo', v_motivo);
      end if;
    end if;
  end loop;

  update public.rx_cargas
     set aceptadas = v_aceptadas,
         ignoradas = v_ignoradas,
         rechazadas = v_rechazadas,
         rechazos = v_rechazos
   where id = v_carga;

  return jsonb_build_object(
    'carga_id',   v_carga,
    'recibidas',  v_indice,
    'aceptadas',  v_aceptadas,
    'ignoradas',  v_ignoradas,
    'rechazadas', v_rechazadas,
    'rechazos',   v_rechazos
  );
end;
$$;

revoke all on function public.rx_cargar_precios(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.rx_cargar_precios(text, text, jsonb) to service_role;

/** Si cambian las reglas de `rx_tokens`, recalcula lo ya cargado. Devuelve cuántos. */
create function public.rx_recalcular_tokens()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_filas integer;
begin
  update public.rx_precios
     set tokens = (select array(select distinct t from unnest(public.rx_tokens(nombre) || public.rx_tokens(laboratorio)) t)),
         tokens_propios = public.rx_tokens_propios(nombre, laboratorio);
  get diagnostics v_filas = row_count;
  return v_filas;
end;
$$;

revoke all on function public.rx_recalcular_tokens() from public, anon, authenticated;
grant execute on function public.rx_recalcular_tokens() to service_role;
