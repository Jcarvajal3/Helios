-- ============================================================================
-- Ronda — El avatar es un emoji sobre un color
--
-- Hasta ahora el avatar de una persona era la inicial de su nombre sobre un
-- disco gris, y dentro de un grupo sobre una de las seis tintas que reparte la
-- app POR POSICIÓN en la lista. Funciona, pero no es de nadie: en una barra a
-- las tres de la mañana, cuatro discos con "J", "M", "A" y "J" no se reconocen
-- de un vistazo, y el segundo "J" obliga a leer el nombre entero.
--
-- La solución es la de WhatsApp para la foto de un grupo, y evita el bucket de
-- imágenes entero: **un emoji sobre un color, los dos elegidos por la persona**.
-- Son dos cadenas cortas que viajan dentro de la lista de integrantes y se
-- pintan al instante, sin descarga, sin caché de imágenes y sin nada que
-- moderar.
--
-- ── Lo que se añade ────────────────────────────────────────────────────────
--
--   `avatar_emojis` / `avatar_colors`   el catálogo, 72 emoji y 12 colores
--   `profiles.avatar_emoji` / `.avatar_color`   lo elegido, con FK al catálogo
--   `set_my_avatar(emoji, color)`       la única escritura del cliente
--   `find_group_by_code`                sus integrantes pasan a llevar avatar
--
-- ── Por qué un catálogo y no texto libre ───────────────────────────────────
--
-- El avatar lo ven los compañeros de grupo, así que un `text` sin restringir es
-- un campo de mensajes con cuatro caracteres: alguien acabaría escribiendo
-- "PAGA" ahí. Con la clave ajena al catálogo, lo que no está en la lista no
-- entra, y ampliar la lista es un INSERT y no una migración de constraint.
--
-- El color se guarda como CLAVE ('morado') y no como hex: así un retoque de la
-- paleta no deja a nadie con un color que ya no existe en el tema. El hex vive
-- en el catálogo para que el panel pueda pintarlo algún día; la app tiene su
-- copia en `features/profile/avatar.ts`, que es la que manda al dibujar.
--
-- ── Lo que NO cambia ───────────────────────────────────────────────────────
--
-- Nada hacia atrás: las dos columnas nacen nulas y quien no elija sigue viendo
-- su inicial, como hoy. Y sigue sin haber política de UPDATE para el cliente en
-- `profiles` — esto entra por RPC, como el PIN y el nivel.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- El catálogo
-- ---------------------------------------------------------------------------

create table if not exists public.avatar_emojis (
  emoji     text primary key,
  -- Para que el panel pueda enseñarlos agrupados igual que la app.
  category  text     not null,
  sort      smallint not null default 0,
  is_active boolean  not null default true
);

comment on table public.avatar_emojis is
  'Los emoji que se pueden elegir como avatar. La app tiene su copia para pintarlos; esta es la que autoriza.';

create table if not exists public.avatar_colors (
  key       text primary key,
  hex       text     not null check (hex ~ '^#[0-9A-Fa-f]{6}$'),
  sort      smallint not null default 0,
  is_active boolean  not null default true
);

comment on table public.avatar_colors is
  'Los fondos del avatar. Todos claros: encima va tinta oscura cuando no hay emoji, y la inicial tiene que leerse.';

alter table public.avatar_emojis enable row level security;
alter table public.avatar_colors enable row level security;

-- El catálogo no es secreto: es una lista de dibujos.
drop policy if exists "avatar_emojis_read_authenticated" on public.avatar_emojis;
create policy "avatar_emojis_read_authenticated"
  on public.avatar_emojis for select to authenticated using (true);

drop policy if exists "avatar_colors_read_authenticated" on public.avatar_colors;
create policy "avatar_colors_read_authenticated"
  on public.avatar_colors for select to authenticated using (true);

grant select on public.avatar_emojis to authenticated;
grant select on public.avatar_colors to authenticated;

-- ---------------------------------------------------------------------------
-- Los 72 emoji
-- ---------------------------------------------------------------------------
-- Todos de Unicode 9.0 o anterior (2016) a propósito: el emoji lo dibuja la
-- FUENTE DEL SISTEMA, no la app, así que uno de 2023 sale como un cuadro vacío
-- en un Android que no se actualiza. Ninguno lleva tono de piel ni bandera.

insert into public.avatar_emojis (emoji, category, sort) values
  ('😀','caras',1),('😄','caras',2),('😉','caras',3),('😍','caras',4),
  ('😎','caras',5),('🤓','caras',6),('🤔','caras',7),('😇','caras',8),
  ('😴','caras',9),('🤠','caras',10),('😜','caras',11),('🤗','caras',12),

  ('🐶','animales',1),('🐱','animales',2),('🦊','animales',3),('🐼','animales',4),
  ('🐨','animales',5),('🐯','animales',6),('🦁','animales',7),('🐸','animales',8),
  ('🐵','animales',9),('🐧','animales',10),('🦉','animales',11),('🦄','animales',12),

  ('🍕','comida',1),('🍔','comida',2),('🌮','comida',3),('🍣','comida',4),
  ('🍩','comida',5),('🍪','comida',6),('🍦','comida',7),('🍓','comida',8),
  ('🍉','comida',9),('🥑','comida',10),('🍺','comida',11),('☕','comida',12),

  ('🎉','fiesta',1),('🎈','fiesta',2),('🎸','fiesta',3),('🎧','fiesta',4),
  ('🎤','fiesta',5),('🎬','fiesta',6),('💃','fiesta',7),('🕺','fiesta',8),
  ('🎲','fiesta',9),('🎯','fiesta',10),('🍻','fiesta',11),('✨','fiesta',12),

  ('⚽','calle',1),('🏀','calle',2),('🎾','calle',3),('🏄','calle',4),
  ('🚀','calle',5),('✈️','calle',6),('🚗','calle',7),('🚲','calle',8),
  ('🏆','calle',9),('🎣','calle',10),('🌴','calle',11),('🎿','calle',12),

  ('❤️','simbolos',1),('⭐','simbolos',2),('🔥','simbolos',3),('⚡','simbolos',4),
  ('🌙','simbolos',5),('☀️','simbolos',6),('🌈','simbolos',7),('💎','simbolos',8),
  ('👑','simbolos',9),('🍀','simbolos',10),('🎩','simbolos',11),('🌊','simbolos',12)
on conflict (emoji) do nothing;

-- ---------------------------------------------------------------------------
-- Los 12 colores
-- ---------------------------------------------------------------------------
-- Los seis primeros SON la paleta de integrantes de la app
-- (`features/groups/palette.ts`), y en ese orden: cuando dos personas de un
-- mismo grupo eligen el mismo color, la app desempata tomando la primera tinta
-- libre de esas seis, y el anillo del detalle sigue leyéndose.
--
-- La lima de marca no está, y no es un olvido: en esta app la lima significa
-- "lo que vas a pagar".

insert into public.avatar_colors (key, hex, sort) values
  ('morado',   '#9B86FF', 1),
  ('ambar',    '#F59E0B', 2),
  ('cian',     '#22D3EE', 3),
  ('rosa',     '#F472B6', 4),
  ('menta',    '#34D399', 5),
  ('naranja',  '#FB923C', 6),
  ('azul',     '#60A5FA', 7),
  ('coral',    '#FB7185', 8),
  ('lavanda',  '#C4B5FD', 9),
  ('turquesa', '#2DD4BF', 10),
  ('arena',    '#E8C39E', 11),
  ('perla',    '#CBD5E1', 12)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Lo elegido
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column if not exists avatar_emoji text references public.avatar_emojis(emoji),
  add column if not exists avatar_color text references public.avatar_colors(key);

comment on column public.profiles.avatar_emoji is
  'Emoji del avatar. Nulo = la inicial del nombre, que es el defecto de siempre.';

-- Los dos o ninguno: un color sin emoji es un disco de color con una inicial
-- dentro —legible, pero no es lo que la pantalla ofrece elegir— y un emoji sin
-- color no tendría fondo que lo separe del lienzo.
alter table public.profiles
  drop constraint if exists profiles_avatar_completo;
alter table public.profiles
  add constraint profiles_avatar_completo
  check ((avatar_emoji is null) = (avatar_color is null));

-- ---------------------------------------------------------------------------
-- Elegirlo
-- ---------------------------------------------------------------------------

create or replace function public.set_my_avatar(p_emoji text, p_color text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- Quitarlo: se vuelve a la inicial. Es la misma llamada con los dos nulos.
  if p_emoji is null or p_color is null then
    update public.profiles
    set avatar_emoji = null, avatar_color = null, updated_at = now()
    where id = v_user;

    return jsonb_build_object('ok', true, 'emoji', null, 'color', null);
  end if;

  -- La clave ajena ya lo impediría; se comprueba antes para que el error diga
  -- algo en vez de llegar a la app como una violación de constraint.
  if not exists (
    select 1 from public.avatar_emojis where emoji = p_emoji and is_active
  ) then
    raise exception 'Ese emoji no está en el catálogo' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.avatar_colors where key = p_color and is_active
  ) then
    raise exception 'Ese color no está en el catálogo' using errcode = '22023';
  end if;

  update public.profiles
  set avatar_emoji = p_emoji, avatar_color = p_color, updated_at = now()
  where id = v_user;

  return jsonb_build_object('ok', true, 'emoji', p_emoji, 'color', p_color);
end;
$$;

comment on function public.set_my_avatar(text, text) is
  'Elegir emoji y color del avatar. No hay política de UPDATE en profiles: esta es la única puerta.';

revoke all on function public.set_my_avatar(text, text) from public, anon;
grant execute on function public.set_my_avatar(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Entrar a un grupo: quiénes están, ahora con su cara
-- ---------------------------------------------------------------------------
-- El resto de pantallas de grupo leen el avatar directamente de `profiles`:
-- `profiles_read_group_mates` ya deja ver a los compañeros. ESTA no puede —
-- quien llega con un código todavía no es de la casa—, así que el avatar tiene
-- que viajar dentro de la respuesta, con el mismo permiso con el que ya viaja
-- el nombre.
--
-- `member_names` (texto suelto) pasa a `members` (objetos). Solo lo leía la
-- pantalla de aceptar la invitación.

create or replace function public.find_group_by_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_stop        jsonb;
  v_user  uuid := auth.uid();
  v_group public.groups%rowtype;
  v_bdate date := public.helios_business_date(now());
  v_count integer;
  v_avail numeric(18,4);
  v_plan  jsonb;
  v_retro numeric(18,4);
  v_owed  numeric(18,4);
  v_max   numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_group from public.groups
  where invite_code = upper(trim(p_code)) and business_date = v_bdate;

  if not found then
    -- Un código de anoche y uno inventado dan lo mismo a propósito: decir
    -- "ese grupo era de ayer" obligaría a buscar entre los muertos, y no
    -- cambia nada de lo que la persona puede hacer ahora.
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  select count(*) into v_count from public.group_members
  where group_id = v_group.id and left_at is null;

  if exists (
    select 1 from public.group_members
    where group_id = v_group.id and user_id = v_user and left_at is null
  ) then
    return jsonb_build_object('ok', false, 'reason', 'already_in',
      'group_id', v_group.id, 'name', v_group.name, 'member_count', v_count);
  end if;

  -- -- NUEVO (20260909160000) ---------------------------------------------
  -- Igual que en confirm_charge: el motivo viaja con su texto y la app lo
  -- pinta tal cual, en vez de inventarse una cuota vencida que no existe.
  v_stop := public.helios_spend_block(v_user);
  if coalesce((v_stop->>'blocks_balance')::boolean, false) then
    return jsonb_build_object('ok', false, 'reason', 'blocked',
                              'message', v_stop->>'message');
  end if;
  -- ------------------------------------------------------------------------

  if not public.can_take_debt(v_user) then
    return jsonb_build_object('ok', false, 'reason', 'overdue');
  end if;

  if v_count >= public.max_group_members() then
    return jsonb_build_object('ok', false, 'reason', 'full');
  end if;

  v_avail := public.available_usd(v_user);

  if v_avail < public.min_share_usd() then
    return jsonb_build_object('ok', false, 'reason', 'no_balance',
      'available_usd', v_avail, 'min_share_usd', public.min_share_usd());
  end if;

  -- Lo que ya lleva el grupo, y si se puede entrar a ello.
  v_plan := public.helios_group_join_plan(v_group.id, v_user);

  -- El único bloqueo que queda es por saldo: una cuenta demasiado pequeña para
  -- uno más se salta, no cierra el grupo.
  --
  -- `blocking_amount_usd` viaja con él desde 20260903000000 y ahora la app lo
  -- usa: el bloqueo decía "no te alcanza" sin decir cuánto falta, que es la
  -- única cifra con la que esa persona puede hacer algo.
  if not coalesce((v_plan->>'ok')::boolean, false) then
    return jsonb_build_object(
      'ok', false,
      'reason', v_plan->>'reason',
      'name', v_group.name,
      'member_count', v_count,
      'available_usd', v_avail,
      'min_share_usd', public.min_share_usd(),
      'blocking_amount_usd', (v_plan->>'blocking_amount_usd')::numeric,
      'blocking_split_between', (v_plan->>'blocking_split_between')::integer
    );
  end if;

  v_retro := (v_plan->>'financed_usd')::numeric;

  -- Lo que este grupo ya me cargó en una entrada anterior. Sale del disponible
  -- pero cuenta contra el techo, así que el suelo y el tope del campo lo llevan
  -- dentro: sin esto la pantalla ofrecería un techo que el PIN rechazaría.
  select coalesce(sum(i.financed_usd), 0) into v_owed
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where c.group_id = v_group.id and i.user_id = v_user;

  v_max := floor((v_avail + v_owed) * 100) / 100;

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group.id,
    'name', v_group.name,
    'member_count', v_count,
    -- Quiénes están, en orden de llegada. Es el mismo permiso con el que se
    -- ven un segundo después en el detalle del grupo: se llega aquí con un
    -- código válido de un grupo vivo, y a eso se entra.
    --
    -- NUEVO: con su emoji y su color, porque aquí `profiles` no se puede leer
    -- desde fuera todavía.
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'name',  p.full_name,
               'emoji', p.avatar_emoji,
               'color', p.avatar_color
             ) order by m.joined_at), '[]'::jsonb)
      from public.group_members m
      join public.profiles p on p.id = m.user_id
      where m.group_id = v_group.id and m.left_at is null
    ),
    'closes_at', public.helios_business_day_end(v_group.business_date),
    -- Lo ya gastado y lo que de eso me toca. Es la mitad de lo que se acepta.
    'retro_charge_count', (v_plan->>'charge_count')::integer,
    'retro_financed_usd', v_retro,
    'retro_payable_usd', (v_plan->>'payable_usd')::numeric,
    -- Y de qué NO voy a ser parte: las cuentas demasiado pequeñas para uno
    -- más. Se dice antes de entrar, no se descubre en el detalle del grupo.
    'skipped_charge_count', (v_plan->>'skipped_charge_count')::integer,
    'skipped_usd', (v_plan->>'skipped_usd')::numeric,
    -- NUEVO: las cuentas una por una, en orden de consumo y con las saltadas
    -- dentro. Es lo que convierte "de 2 cuentas" en algo comprobable.
    'retro_charges', coalesce(v_plan->'charges', '[]'::jsonb),
    -- El techo que propone la app: el saldo entero. Es un defecto, no una
    -- obligación; la pantalla deja bajarlo antes de aceptar.
    'suggested_cap_usd', v_max,
    'max_cap_usd', v_max,
    'min_cap_usd', greatest(public.min_share_usd(), v_owed + v_retro)
  );
end;
$$;

revoke all on function public.find_group_by_code(text) from public, anon;
grant execute on function public.find_group_by_code(text) to authenticated;
