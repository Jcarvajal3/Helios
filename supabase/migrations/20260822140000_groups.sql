-- ============================================================================
-- Ronda — Grupos: dividir la cuenta
--
-- Reglas confirmadas (docs/00-BASES §2.7, docs/05 §2, docs/06 §6):
--   * Máximo 8 integrantes.
--   * La autorización se da AL ENTRAR al grupo, no en cada consumo.
--   * El mínimo por persona se fija al crear el grupo; cada quien lo acepta.
--   * Mínimo $2,50 por persona en un consumo.
--   * **Deuda individual**: cada miembro contra su propio límite, con su
--     propio plan de dos cuotas.
--
-- ---------------------------------------------------------------------------
-- Decisiones que los docs dejaban abiertas y aquí se resuelven
-- ---------------------------------------------------------------------------
-- Ninguna es un volado: todas salen de aplicar los principios ya decididos.
-- Están marcadas para que se confirmen o se corrijan.
--
-- 1. **Cada miembro fija su tope por consumo al entrar.** docs/06 §6 lo
--    llama "el otro lado del tope" y dice que con eso el modelo queda
--    cerrado. Sin él, quien pueda iniciar un cobro consume el límite entero
--    de los demás.
--
-- 2. **Solo el creador y los marcados pueden iniciar cobros**
--    (`can_initiate`), como recomienda docs/05 §2 punto 4.
--
-- 3. **El reparto es a partes iguales.** Es lo que hace consistente el
--    "mínimo por persona": un reparto libre lo vuelve inaplicable.
--
-- 4. **Si a alguien no le alcanza, NO se reparte entre los demás.** Repartir
--    cargaría a otros por encima de lo que autorizaron, que es justo lo que
--    los topes existen para impedir. En su lugar, el cobro dice quién viene
--    corto y quien inicia decide: repetir sin esa persona (los demás ponen
--    más, dentro de su propio tope) o que ponga efectivo. docs/00-BASES §3.6
--    exige que esto se resuelva en segundos: por eso el servidor devuelve la
--    lista de quién puede y quién no en una sola llamada.
--
-- 5. **Se puede salir del grupo con deuda viva.** La deuda ya es individual:
--    salir no la traspasa a nadie. Bloquear la salida sería retener a alguien
--    en un grupo donde le pueden seguir generando cargos.
-- ============================================================================

create type public.group_status as enum ('active', 'closed');
create type public.group_member_status as enum ('active', 'paused', 'left');

create table if not exists public.groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  created_by  uuid not null references auth.users (id),
  -- Lo que cada integrante se compromete a poner como mínimo. Se acepta al
  -- entrar, así que nadie descubre el compromiso después (docs/06 §6).
  min_per_person_usd numeric(18,4) not null check (min_per_person_usd >= 2.50),
  -- Código corto para invitar. Sin ambigüedades visuales: fuera I, O, 0, 1.
  invite_code text not null unique,
  status      public.group_status not null default 'active',
  created_at  timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id   uuid not null references public.groups (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  -- Quien puede iniciar un cobro en nombre del grupo.
  can_initiate boolean not null default false,
  /**
   * El tope que fija cada quien al entrar: "autorizo hasta $30 por consumo
   * en este grupo". Es la baranda contra el abuso de la autorización
   * permanente (docs/05 §2). El límite del nivel sigue siendo el tope duro
   * por encima de este.
   */
  max_per_transaction_usd numeric(18,4) not null check (max_per_transaction_usd >= 2.50),
  -- Momento del consentimiento. Sin esto no hay autorización que enseñar si
  -- alguien reclama un cargo.
  authorized_at timestamptz not null default now(),
  status     public.group_member_status not null default 'active',
  joined_at  timestamptz not null default now(),
  primary key (group_id, user_id)
);

create index group_members_user_idx on public.group_members (user_id)
  where status = 'active';

-- Máximo 8 integrantes (docs/06 §6). Se comprueba en trigger y no en check
-- porque un check no puede consultar otras filas.
create or replace function public.enforce_group_size()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  select count(*) into v_count
  from public.group_members
  where group_id = new.group_id and status <> 'left';

  if v_count > 8 then
    raise exception 'Un grupo no puede tener más de 8 integrantes'
      using errcode = '22023';
  end if;

  return null;
end;
$$;

create constraint trigger group_members_max_size
  after insert or update on public.group_members
  deferrable initially deferred
  for each row execute function public.enforce_group_size();

revoke all on function public.enforce_group_size() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.groups enable row level security;
alter table public.group_members enable row level security;

/** Grupos a los que pertenece el usuario actual. */
create or replace function public.my_group_ids()
returns setof uuid
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select group_id from public.group_members
  where user_id = auth.uid() and status <> 'left';
$$;

revoke all on function public.my_group_ids() from public, anon;
grant execute on function public.my_group_ids() to authenticated;

create policy "groups_read_own"
  on public.groups for select to authenticated
  using (id in (select public.my_group_ids()));

-- Un integrante ve a los demás: es lo que hace visible con quién comparte
-- límite. Sin esto no se puede mostrar el grupo.
create policy "group_members_read_own_groups"
  on public.group_members for select to authenticated
  using (group_id in (select public.my_group_ids()));

grant select on public.groups, public.group_members to authenticated;

-- ---------------------------------------------------------------------------
-- Un consumo puede tener VARIOS deudores
-- ---------------------------------------------------------------------------
-- `unique (charge_id, sequence)` daba por hecho un solo deudor por venta.
-- Con grupos hay N personas con dos cuotas cada una sobre la MISMA venta:
-- el comercio hizo una sola venta y se le liquida una sola vez; lo que se
-- reparte es la cuenta por cobrar.

alter table public.installments
  drop constraint if exists installments_charge_id_sequence_key;

alter table public.installments
  add constraint installments_charge_user_sequence_key
  unique (charge_id, user_id, sequence);

-- El cobro recuerda si se pagó en grupo, para poder mostrarlo después.
alter table public.charges
  add column if not exists group_id uuid references public.groups (id);

comment on column public.charges.user_id is
  'Quien reclamó el cobro. En un cobro de grupo es quien escaneó; los deudores están en installments.';

-- ---------------------------------------------------------------------------
-- Crear y unirse
-- ---------------------------------------------------------------------------

/** Código de invitación sin caracteres que se confunden al dictarlos. */
create or replace function public.generate_invite_code()
returns text
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
declare
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code text;
  v_i integer;
begin
  loop
    v_code := '';
    for v_i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;

    exit when not exists (select 1 from public.groups where invite_code = v_code);
  end loop;

  return v_code;
end;
$$;

revoke all on function public.generate_invite_code() from public, anon, authenticated;

create or replace function public.create_group(
  p_name               text,
  p_min_per_person_usd numeric,
  p_my_max_usd         numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_group public.groups%rowtype;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if p_min_per_person_usd < 2.50 then
    raise exception 'El mínimo por persona no puede bajar de $2,50' using errcode = '22023';
  end if;

  if p_my_max_usd < p_min_per_person_usd then
    raise exception 'Tu tope no puede ser menor que el mínimo del grupo'
      using errcode = '22023';
  end if;

  insert into public.groups (name, created_by, min_per_person_usd, invite_code)
  values (trim(p_name), v_user, p_min_per_person_usd, public.generate_invite_code())
  returning * into v_group;

  -- Quien crea el grupo entra ya autorizado y puede iniciar cobros.
  insert into public.group_members
    (group_id, user_id, can_initiate, max_per_transaction_usd)
  values (v_group.id, v_user, true, p_my_max_usd);

  return jsonb_build_object(
    'group_id', v_group.id,
    'name', v_group.name,
    'invite_code', v_group.invite_code,
    'min_per_person_usd', v_group.min_per_person_usd
  );
end;
$$;

revoke all on function public.create_group(text, numeric, numeric) from public, anon;
grant execute on function public.create_group(text, numeric, numeric) to authenticated;

/**
 * Entrar a un grupo con el código.
 *
 * Aceptar el mínimo del grupo y fijar el propio tope es UN SOLO acto: es el
 * momento del consentimiento, y de ahí en adelante no se pide confirmación
 * por consumo.
 */
create or replace function public.join_group(
  p_invite_code text,
  p_my_max_usd  numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_group public.groups%rowtype;
  v_count integer;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_group from public.groups
  where invite_code = upper(trim(p_invite_code)) and status = 'active';

  if not found then
    raise exception 'Ese código no corresponde a ningún grupo activo'
      using errcode = 'P0002';
  end if;

  if p_my_max_usd < v_group.min_per_person_usd then
    raise exception 'El grupo pide al menos $% por persona y tu tope es $%',
      v_group.min_per_person_usd, p_my_max_usd
      using errcode = '22023';
  end if;

  select count(*) into v_count from public.group_members
  where group_id = v_group.id and status <> 'left';

  if v_count >= 8 then
    raise exception 'El grupo ya tiene 8 integrantes' using errcode = '22023';
  end if;

  insert into public.group_members
    (group_id, user_id, can_initiate, max_per_transaction_usd, authorized_at, status)
  values (v_group.id, v_user, false, p_my_max_usd, now(), 'active')
  on conflict (group_id, user_id) do update
    set status = 'active',
        max_per_transaction_usd = excluded.max_per_transaction_usd,
        authorized_at = now();

  return jsonb_build_object(
    'group_id', v_group.id,
    'name', v_group.name,
    'min_per_person_usd', v_group.min_per_person_usd
  );
end;
$$;

revoke all on function public.join_group(text, numeric) from public, anon;
grant execute on function public.join_group(text, numeric) to authenticated;

/**
 * Pausar o salir, con efecto inmediato (docs/05 §2 punto 3).
 *
 * Se puede salir con deuda viva: ya es individual, así que salir no se la
 * traspasa a nadie. Retener a alguien en un grupo donde le pueden seguir
 * generando cargos sería lo contrario de una baranda.
 */
create or replace function public.set_group_membership(
  p_group_id uuid,
  p_status   public.group_member_status
)
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

  update public.group_members
    set status = p_status
  where group_id = p_group_id and user_id = v_user;

  if not found then
    raise exception 'No perteneces a ese grupo' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

revoke all on function public.set_group_membership(uuid, public.group_member_status)
  from public, anon;
grant execute on function public.set_group_membership(uuid, public.group_member_status)
  to authenticated;

/** Cambiar el propio tope dentro de un grupo. */
create or replace function public.set_group_cap(p_group_id uuid, p_max_usd numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_min  numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select min_per_person_usd into v_min from public.groups where id = p_group_id;

  if p_max_usd < v_min then
    raise exception 'El grupo pide al menos $% por persona', v_min
      using errcode = '22023';
  end if;

  update public.group_members
    set max_per_transaction_usd = p_max_usd, authorized_at = now()
  where group_id = p_group_id and user_id = v_user;

  if not found then
    raise exception 'No perteneces a ese grupo' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true, 'max_per_transaction_usd', p_max_usd);
end;
$$;

revoke all on function public.set_group_cap(uuid, numeric) from public, anon;
grant execute on function public.set_group_cap(uuid, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Mis grupos
-- ---------------------------------------------------------------------------

create or replace function public.my_groups()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user uuid := auth.uid();
  v_rows jsonb;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.joined_at desc), '[]'::jsonb) into v_rows
  from (
    select
      g.id,
      g.name,
      g.invite_code,
      g.min_per_person_usd,
      g.status,
      me.can_initiate,
      me.max_per_transaction_usd,
      me.status as my_status,
      me.joined_at,
      (
        select coalesce(jsonb_agg(jsonb_build_object(
          'user_id', m.user_id,
          'name', p.full_name,
          'status', m.status,
          'can_initiate', m.can_initiate
        ) order by m.joined_at), '[]'::jsonb)
        from public.group_members m
        join public.profiles p on p.id = m.user_id
        where m.group_id = g.id and m.status <> 'left'
      ) as members
    from public.groups g
    join public.group_members me on me.group_id = g.id and me.user_id = v_user
    where me.status <> 'left'
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.my_groups() from public, anon;
grant execute on function public.my_groups() to authenticated;

-- Los integrantes de un grupo ven el nombre de los demás. Sin esto, el grupo
-- es una lista de identificadores.
create policy "profiles_read_group_mates"
  on public.profiles for select to authenticated
  using (
    id in (
      select m.user_id from public.group_members m
      where m.group_id in (select public.my_group_ids()) and m.status <> 'left'
    )
  );
