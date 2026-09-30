-- ============================================================================
-- Ronda — La pantalla de un grupo: quiénes, cuánto y qué se gastó
--
-- Tres cosas, y la primera es un fallo que se veía desde el teléfono.
--
-- 1. UN INTEGRANTE NO PODÍA VER EL COBRO DE SU PROPIO GRUPO.
--
--    `confirm_charge_as_group` escribe `charges.user_id = quien inicia`, y la
--    única política de lectura sobre `charges` era `user_id = auth.uid()`. Los
--    otros siete tienen sus cuotas, pero la FILA DEL COBRO les está vedada.
--    Como los embeds de PostgREST son left joins, la app recibía la cuota con
--    `charges` en null y la pintaba con lo que tenía a mano:
--
--        Comercio · #0 · sin fecha
--
--    en la pestaña Cuotas, para todo el que no hubiera escaneado él mismo. La
--    política nueva usa `my_group_ids()`, que ya existe y ya es security
--    definer, así que no abre nada nuevo: los integrantes de un grupo ya se
--    ven entre sí y ya comparten esos consumos.
--
-- 2. EL NOMBRE DEL GRUPO SE CONSERVA EN EL COBRO.
--
--    El historial lo sacaba de un join vivo contra `groups`. Mientras la fila
--    exista da igual, pero un recibo no puede depender de que nadie borre ni
--    renombre nada: "Cena del sábado" tiene que seguir diciendo eso dentro de
--    un año. Se copia al confirmar, y con un trigger en vez de dentro de las
--    RPC de cobro, para que valga también para cualquier camino que se añada
--    después.
--
-- 3. `group_detail()` — todo lo de un grupo en una llamada: integrantes con su
--    ticket, el bote y el historial completo de consumos. Es lo que pide la
--    pantalla nueva, y tiene que ser SECURITY DEFINER igualmente para poder
--    decir QUIÉN inició cada cobro: los nombres de los perfiles no se leen
--    por RLS fuera de lo que ya expone `my_groups`.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Un integrante lee los cobros de sus grupos
-- ---------------------------------------------------------------------------

drop policy if exists "charges_read_group_member" on public.charges;

create policy "charges_read_group_member"
  on public.charges for select to authenticated
  using (group_id in (select public.my_group_ids()));

-- ---------------------------------------------------------------------------
-- 2. El nombre del grupo, congelado en el cobro
-- ---------------------------------------------------------------------------

alter table public.charges
  add column if not exists group_name text;

comment on column public.charges.group_name is
  'Nombre del grupo EN EL MOMENTO del consumo. Copia, no referencia: el historial no cambia si el grupo se renombra o se borra.';

create or replace function public.stamp_charge_group_name()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.group_id is not null
     and (new.group_name is null or new.group_id is distinct from old.group_id)
  then
    select name into new.group_name from public.groups where id = new.group_id;
  end if;

  return new;
end;
$$;

revoke all on function public.stamp_charge_group_name() from public, anon, authenticated;

drop trigger if exists charges_stamp_group_name on public.charges;

create trigger charges_stamp_group_name
  before insert or update of group_id on public.charges
  for each row execute function public.stamp_charge_group_name();

-- Los cobros que ya existen se quedan con el nombre de hoy, que es el único
-- que hay. A partir de aquí, el que valga en cada momento.
update public.charges c
   set group_name = g.name
  from public.groups g
 where c.group_id = g.id and c.group_name is null;

-- ---------------------------------------------------------------------------
-- 3. El historial del perfil usa la copia
-- ---------------------------------------------------------------------------
-- Idéntica a 20260825180000 salvo el `coalesce` del nombre del grupo.

create or replace function public.my_purchases(p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $fn$
declare
  v_user uuid := auth.uid();
  v_rows jsonb;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.confirmed_at desc), '[]'::jsonb)
    into v_rows
  from (
    select
      c.id                                   as charge_id,
      c.order_number,
      m.name                                 as merchant_name,
      m.logo_url                             as merchant_logo_url,
      b.name                                 as branch_name,
      c.business_date,
      c.confirmed_at,
      c.status::text                         as status,
      c.amount_usd                           as total_usd,
      mine.my_usd,
      mine.paid_usd,
      mine.pending_usd,
      mine.installments,
      (c.group_id is not null)               as is_group,
      -- La COPIA manda sobre el join vivo: el nombre que se enseña es el que
      -- tenía el grupo el día del consumo, no el de hoy. El join se queda
      -- para los cobros que el backfill no hubiera alcanzado.
      coalesce(c.group_name, g.name)         as group_name,
      split.people                           as split_between,
      (c.user_id = v_user)                   as i_started_it,
      items.lines                            as items
    from public.charges c
    join public.merchants m on m.id = c.merchant_id
    left join public.merchant_branches b on b.id = c.branch_id
    left join public.groups g on g.id = c.group_id
    join lateral (
      select
        sum(i.amount_usd)                                                  as my_usd,
        coalesce(sum(i.amount_usd) filter (where i.status = 'paid'), 0)     as paid_usd,
        coalesce(sum(i.amount_usd) filter (where i.status = 'pending'), 0)  as pending_usd,
        jsonb_agg(
          jsonb_build_object(
            'id', i.id,
            'sequence', i.sequence,
            'amount_usd', i.amount_usd,
            'due_date', i.due_date,
            'status', i.status,
            'paid_at', i.paid_at
          ) order by i.sequence
        ) as installments
      from public.installments i
      where i.charge_id = c.id and i.user_id = v_user
    ) mine on mine.my_usd is not null
    join lateral (
      select count(distinct i2.user_id) as people
      from public.installments i2
      where i2.charge_id = c.id
    ) split on true
    left join lateral (
      select jsonb_agg(
        jsonb_build_object(
          'name', ci.name,
          'quantity', ci.quantity,
          'unit_price_usd', ci.unit_price_usd,
          'line_total_usd', ci.line_total_usd
        ) order by ci.position, ci.created_at
      ) as lines
      from public.charge_items ci
      where ci.charge_id = c.id
    ) items on true
    order by c.confirmed_at desc
    limit p_limit
  ) q;

  return v_rows;
end;
$fn$;

revoke all on function public.my_purchases(integer) from public, anon;
grant execute on function public.my_purchases(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Todo lo de un grupo, en una llamada
-- ---------------------------------------------------------------------------
-- Las cifras salen de las MISMAS fórmulas que `my_groups` —mismo bote, mismo
-- mínimo— para que la tarjeta de la lista y la pantalla de detalle no puedan
-- decir cosas distintas del mismo grupo.

create or replace function public.group_detail(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $fn$
declare
  v_user  uuid := auth.uid();
  v_group public.groups%rowtype;
  v_me    public.group_members%rowtype;
  v_out   jsonb;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_group from public.groups where id = p_group_id;
  if not found then
    raise exception 'Grupo no encontrado' using errcode = 'P0002';
  end if;

  -- Se exige pertenecer, y vale también quien ya salió: su historial sigue
  -- siendo suyo, y su deuda también.
  select * into v_me from public.group_members
  where group_id = p_group_id and user_id = v_user;

  if not found then
    raise exception 'No perteneces a este grupo' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'id', v_group.id,
    'name', v_group.name,
    'invite_code', v_group.invite_code,
    'entry_amount_usd', v_group.entry_amount_usd,
    'status', v_group.status,
    'is_creator', (v_group.created_by = v_user),
    'created_at', v_group.created_at,
    'my_status', v_me.status,
    'my_reserved_usd', v_me.reserved_usd,
    'my_consumed_usd', v_me.consumed_usd,
    'my_remaining_usd', case when v_me.released_at is null
                             then v_me.reserved_usd - v_me.consumed_usd else 0 end,
    'my_released', (v_me.released_at is not null),

    'member_count', (
      select count(*) from public.group_members m
      where m.group_id = p_group_id and m.status = 'active'
    ),

    -- El techo lo marca el que menos tiene: mismo cálculo que `my_groups`.
    'pot_usd', (
      select coalesce(min(m.reserved_usd - m.consumed_usd), 0) * count(*)
      from public.group_members m
      where m.group_id = p_group_id and m.status = 'active' and m.released_at is null
        and public.can_take_debt(m.user_id)
    ),
    'min_charge_usd', (
      select count(*) * public.min_share_usd()
      from public.group_members m
      where m.group_id = p_group_id and m.status = 'active' and m.released_at is null
        and public.can_take_debt(m.user_id)
    ),

    -- Lo que pusieron entre todos y lo que llevan gastado. Es la respuesta a
    -- "¿de qué tamaño fue la noche?", que ninguna otra cifra da.
    'reserved_total_usd', (
      select coalesce(sum(m.reserved_usd), 0)
      from public.group_members m
      where m.group_id = p_group_id and m.status <> 'left'
    ),
    'consumed_total_usd', (
      select coalesce(sum(m.consumed_usd), 0)
      from public.group_members m
      where m.group_id = p_group_id and m.status <> 'left'
    ),

    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'user_id', m.user_id,
        'name', p.full_name,
        'status', m.status,
        'is_me', (m.user_id = v_user),
        'is_creator', (m.user_id = v_group.created_by),
        'reserved_usd', m.reserved_usd,
        'consumed_usd', m.consumed_usd,
        'remaining_usd', case when m.released_at is null
                              then m.reserved_usd - m.consumed_usd else 0 end,
        'released', (m.released_at is not null),
        'joined_at', m.joined_at
      ) order by m.joined_at), '[]'::jsonb)
      from public.group_members m
      join public.profiles p on p.id = m.user_id
      where m.group_id = p_group_id and m.status <> 'left'
    ),

    -- El historial del GRUPO, no el mío: aquí salen también los consumos
    -- anteriores a que yo entrara, que son los que explican por qué al bote
    -- le queda menos de lo que suman los tickets.
    'charges', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'charge_id', c.id,
        'order_number', c.order_number,
        'merchant_name', mm.name,
        'merchant_logo_url', mm.logo_url,
        'business_date', c.business_date,
        'confirmed_at', c.confirmed_at,
        'amount_usd', c.amount_usd,
        'split_between', shares.people,
        'my_usd', shares.mine,
        'started_by_name', starter.full_name,
        'i_started_it', (c.user_id = v_user)
      ) order by c.confirmed_at desc), '[]'::jsonb)
      from public.charges c
      join public.merchants mm on mm.id = c.merchant_id
      left join public.profiles starter on starter.id = c.user_id
      join lateral (
        select count(distinct i.user_id) as people,
               coalesce(sum(i.amount_usd) filter (where i.user_id = v_user), 0) as mine
        from public.installments i
        where i.charge_id = c.id
      ) shares on true
      where c.group_id = p_group_id and c.status = 'confirmed'
    )
  ) into v_out;

  return v_out;
end;
$fn$;

comment on function public.group_detail(uuid) is
  'Un grupo entero para su pantalla: integrantes con su ticket, bote e historial de consumos.';

revoke all on function public.group_detail(uuid) from public, anon;
grant execute on function public.group_detail(uuid) to authenticated;
