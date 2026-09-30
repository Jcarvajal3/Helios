-- ============================================================================
-- Ronda — Vuelven los grupos, con techo propio por persona
--
-- Decisión del 2026-08-28. La mesa se retira y vuelve el grupo, pero no el de
-- `main`: se queda con lo bueno de cada uno.
--
--   DEL GRUPO   el nombre y el código de 6 caracteres que se dicta en voz
--               alta, crear a propósito, invitar, entrar, salir.
--   DE LA MESA  el ciclo de vida (muere solo en el corte de las 10 AM), que
--               el techo NO retenga saldo, y el reparto en cascada.
--
-- ---------------------------------------------------------------------------
-- Lo único que cambia respecto a `main`: el ticket pasa a ser un techo propio
-- ---------------------------------------------------------------------------
-- En `main` el grupo tenía UNA cifra —el ticket de entrada— igual para todos,
-- y aceptarla RETENÍA ese saldo. Ahora cada quien pone **su** techo al entrar,
-- el creador incluido, y ese techo no aparta nada: es el máximo que le pueden
-- cargar en ese grupo, y se comprueba en cada cobro contra
-- `min(techo − gastado, saldo disponible)`.
--
-- Es lo que hace que el reparto en cascada tenga sentido. Con un ticket igual
-- para todos, "lo más parejo posible sin pasarse del techo de nadie" era
-- siempre un reparto parejo a secas: nadie podía quedarse corto antes que otro.
-- Con techos propios, la cascada es justo el mecanismo que reparte lo que a
-- uno no le llega entre los que tienen más techo.
--
-- ---------------------------------------------------------------------------
-- Y ya no hay que cerrar nada
-- ---------------------------------------------------------------------------
-- El grupo lleva su día operativo y muere con él. Desaparecen `close_group`,
-- la devolución del saldo no usado y los avisos de devolución — que existían
-- solo porque el ticket retenía. Un grupo de anoche no es un grupo: no hace
-- falta que nadie se acuerde de nada.
--
-- ⚠️ **Se puede estar en varios grupos a la vez**, como en `main`. Sin
-- retención el techo deja de acotar la exposición TOTAL —tres grupos con techo
-- de $50 son tres techos de $50—, pero el saldo disponible sigue siendo el
-- tope duro y se comprueba en cada cobro: nadie puede cargarte más de lo que
-- tienes, estés en los grupos que estés. Lo que se diluye es el significado
-- del techo, no la seguridad.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La mesa se retira
-- ---------------------------------------------------------------------------

drop function if exists public.confirm_charge_as_tab(uuid, text, text);
drop function if exists public.preview_tab_charge(uuid);
drop function if exists public.tab_participants(uuid);
drop function if exists public.set_my_tab_cap(numeric);
drop function if exists public.leave_tab();
drop function if exists public.join_tab(text, numeric, text);
drop function if exists public.preview_tab(text);
drop function if exists public.open_my_tab();
drop function if exists public.my_tab();
drop function if exists public.my_open_tab_id();

drop trigger if exists tab_members_notify_joined on public.tab_members;
drop function if exists public.notify_tab_joined();
drop trigger if exists charges_notify_tab on public.charges;
drop function if exists public.notify_tab_charge();

alter table public.charges drop column if exists tab_id;

drop table if exists public.tab_members;
drop table if exists public.tabs;

-- ---------------------------------------------------------------------------
-- 2. El grupo, reformado
-- ---------------------------------------------------------------------------

alter table public.groups
  -- La noche. Es el único mecanismo de cierre: un grupo de otro día operativo
  -- ya no es un grupo, sin que nadie tenga que cerrarlo.
  add column if not exists business_date date not null default public.helios_business_date(now());

-- Rescatar el techo de quien ya soltó su retención, ANTES de tirar el ticket.
--
-- Cuando una retención se liberaba, `reserved_usd` se ponía a cero: dejaba de
-- decir "este es mi techo" para decir "aquí ya no hay nada apartado". Al pasar
-- esa columna a ser `cap_usd` —un techo, que no aparta nada— ese cero se lee
-- como "no me pueden cargar ni un centavo", que no es lo que nadie aceptó, y
-- choca de frente con el mínimo de $2,50 de más abajo.
--
-- El número correcto no hay que inventarlo: bajo el modelo del ticket, la
-- retención de cada integrante ERA el ticket del grupo, así que
-- `entry_amount_usd` es exactamente el techo que esa persona aceptó. Se
-- recupera de ahí y no de un valor de relleno, porque `group_members` es el
-- registro de quién autorizó qué — y eso no se reescribe con una constante.
update public.group_members m
set reserved_usd = g.entry_amount_usd
from public.groups g
where g.id = m.group_id
  and m.reserved_usd < 2.50
  and g.entry_amount_usd >= greatest(2.50, m.consumed_usd);

-- El ticket único desaparece: ahora cada integrante trae el suyo.
alter table public.groups
  drop column if exists entry_amount_usd;

-- El código se dicta en voz alta y solo tiene que ser único ENTRE LOS VIVOS.
-- Reservarlo para siempre agotaría un alfabeto de 32 caracteres en seis
-- posiciones mucho antes de lo necesario, y un código de anoche no colisiona
-- con nada porque ya no abre ninguna puerta.
-- La restricción primero: es ella quien es dueña del índice, así que
-- soltarlo antes falla con "constraint requires it".
alter table public.groups drop constraint if exists groups_invite_code_key;
drop index if exists groups_invite_code_key;
create unique index if not exists groups_invite_code_alive
  on public.groups (invite_code, business_date);

create index if not exists groups_business_date_idx
  on public.groups (business_date);

alter table public.group_members
  rename column reserved_usd to cap_usd;
alter table public.group_members
  rename column consumed_usd to spent_usd;

alter table public.group_members
  -- `released_at` decía "la retención sigue viva". Sin retención no dice nada.
  drop column if exists released_at,
  add column if not exists left_at timestamptz,
  -- Denormalizado desde `groups`, como en la mesa: es lo que permite filtrar
  -- los grupos de esta noche sin un join en cada consulta.
  add column if not exists business_date date;

update public.group_members m
set business_date = g.business_date
from public.groups g
where g.id = m.group_id and m.business_date is null;

alter table public.group_members
  alter column business_date set not null;

alter table public.group_members
  drop constraint if exists group_members_cap_floor,
  drop constraint if exists group_members_spent_le_cap;

alter table public.group_members
  add constraint group_members_cap_floor check (cap_usd >= 2.50),
  add constraint group_members_spent_le_cap check (spent_usd <= cap_usd);

comment on column public.group_members.cap_usd is
  'EL TECHO de esta persona en este grupo: lo máximo que se le puede cargar sumando todos los consumos. No retiene saldo — es un límite, no un apartado.';
comment on column public.group_members.spent_usd is
  'Lo que este grupo ya le cargó. El techo es acumulativo, así que cinco rondas no se lo saltan cinco veces.';

create index if not exists group_members_alive_idx
  on public.group_members (group_id) where left_at is null;

-- ---------------------------------------------------------------------------
-- 3. Utilidades
-- ---------------------------------------------------------------------------

/** Código de invitación sin caracteres que se confunden al dictarlos. */
create or replace function public.generate_invite_code()
returns text
language plpgsql
set search_path = public, pg_catalog, pg_temp
as $$
declare
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code text;
  v_i integer;
  v_today date := public.helios_business_date(now());
begin
  loop
    v_code := '';
    for v_i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;

    -- Solo choca con los grupos VIVOS: el de anoche ya no abre nada.
    exit when not exists (
      select 1 from public.groups
      where invite_code = v_code and business_date = v_today
    );
  end loop;

  return v_code;
end;
$$;

revoke all on function public.generate_invite_code() from public, anon, authenticated;

/** Los grupos vivos en los que estoy. Un solo sitio que resuelve "cuáles". */
create or replace function public.my_group_ids()
returns setof uuid
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select m.group_id
  from public.group_members m
  where m.user_id = auth.uid()
    and m.left_at is null
    and m.business_date = public.helios_business_date(now());
$$;

revoke all on function public.my_group_ids() from public, anon;
grant execute on function public.my_group_ids() to authenticated;

/**
 * Quiénes hay en el grupo y con cuánta capacidad, en el orden del reparto.
 *
 * Igual que su gemela de la mesa: la usan el preview y el cobro, y tienen que
 * ver EXACTAMENTE lo mismo. Si cada uno calculara la capacidad por su cuenta,
 * el usuario aprobaría un reparto y se le cobraría otro.
 */
create or replace function public.group_participants(p_group_id uuid)
returns table (
  user_id       uuid,
  name          text,
  cap_usd       numeric,
  spent_usd     numeric,
  capacity_usd  numeric,
  can_take_debt boolean
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select
    m.user_id,
    p.full_name,
    m.cap_usd,
    m.spent_usd,
    greatest(least(m.cap_usd - m.spent_usd, public.available_usd(m.user_id)), 0),
    public.can_take_debt(m.user_id)
  from public.group_members m
  join public.profiles p on p.id = m.user_id
  where m.group_id = p_group_id and m.left_at is null
  order by m.user_id;
$$;

revoke all on function public.group_participants(uuid) from public, anon, authenticated;

/**
 * Lo que el grupo puede cubrir de una cuenta que se reparta parejo.
 *
 * NO es la suma de capacidades: con reparto parejo manda el que menos puede,
 * así que el techo real es `el menor × integrantes`. Sumar prometería un
 * dinero que solo se puede gastar si el reparto queda muy desigual, y esa es
 * la excepción.
 */
create or replace function public.group_pot_usd(p_group_id uuid)
returns numeric
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce(min(capacity_usd) * count(*), 0)
  from public.group_participants(p_group_id)
  where can_take_debt;
$$;

revoke all on function public.group_pot_usd(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Crear, buscar, entrar, mover el techo, salir
-- ---------------------------------------------------------------------------

/**
 * Crear un grupo. Dos decisiones: el nombre y TU techo.
 *
 * Crear es también entrar: quien lo crea queda dentro con el techo que acaba
 * de poner, sin ningún privilegio sobre los demás. El grupo nace con el día
 * operativo de hoy y morirá con él.
 */
create or replace function public.create_group(
  p_name    text,
  p_cap_usd numeric,
  p_pin     text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_pin   jsonb;
  v_group public.groups%rowtype;
  v_avail numeric(18,4);
  v_bdate date := public.helios_business_date(now());
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes crear un grupo' using errcode = '22023';
  end if;

  if coalesce(trim(p_name), '') = '' then
    raise exception 'El grupo necesita un nombre' using errcode = '22023';
  end if;

  v_avail := public.available_usd(v_user);

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu techo no puede bajar de $%', public.min_share_usd() using errcode = '22023';
  end if;

  if p_cap_usd > v_avail then
    raise exception 'Tu techo sería de $% y tienes $% disponibles', p_cap_usd, v_avail
      using errcode = '22023';
  end if;

  insert into public.groups (name, created_by, invite_code, business_date)
  values (trim(p_name), v_user, public.generate_invite_code(), v_bdate)
  returning * into v_group;

  insert into public.group_members
    (group_id, user_id, business_date, cap_usd, spent_usd, authorized_at)
  values (v_group.id, v_user, v_bdate, p_cap_usd, 0, now());

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group.id,
    'name', v_group.name,
    'invite_code', v_group.invite_code,
    'cap_usd', p_cap_usd,
    'closes_at', public.helios_business_day_end(v_bdate)
  );
end;
$$;

revoke all on function public.create_group(text, numeric, text) from public, anon;
grant execute on function public.create_group(text, numeric, text) to authenticated;

/**
 * Lo que ve quien teclea un código, ANTES de comprometer nada.
 *
 * Buscar no compromete, así que esto no escribe. Devuelve el motivo por el que
 * no se puede entrar en vez de lanzar: la pantalla tiene que poder explicarlo,
 * y un error de PostgREST no se maqueta.
 */
create or replace function public.find_group_by_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user  uuid := auth.uid();
  v_group public.groups%rowtype;
  v_bdate date := public.helios_business_date(now());
  v_count integer;
  v_avail numeric(18,4);
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

  if not public.can_take_debt(v_user) then
    return jsonb_build_object('ok', false, 'reason', 'overdue');
  end if;

  if v_count >= 8 then
    return jsonb_build_object('ok', false, 'reason', 'full');
  end if;

  v_avail := public.available_usd(v_user);

  if v_avail < public.min_share_usd() then
    return jsonb_build_object('ok', false, 'reason', 'no_balance',
      'available_usd', v_avail, 'min_share_usd', public.min_share_usd());
  end if;

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group.id,
    'name', v_group.name,
    'member_count', v_count,
    'closes_at', public.helios_business_day_end(v_group.business_date),
    -- El techo que propone la app: el saldo entero. Es un defecto, no una
    -- obligación; la pantalla deja bajarlo antes de aceptar.
    'suggested_cap_usd', floor(v_avail * 100) / 100,
    'max_cap_usd', floor(v_avail * 100) / 100,
    'min_cap_usd', public.min_share_usd()
  );
end;
$$;

revoke all on function public.find_group_by_code(text) from public, anon;
grant execute on function public.find_group_by_code(text) to authenticated;

/**
 * Entrar al grupo poniendo mi techo. Exige PIN.
 *
 * Aquí ocurre TODO el consentimiento: a partir de este instante, cualquiera
 * del grupo puede generarme deuda hasta ese techo sin volver a preguntarme.
 * Por eso pide PIN — es un acto que compromete crédito, no una preferencia.
 *
 * El PIN se DEVUELVE fallido en vez de lanzarse, igual que en los cobros: un
 * `raise` revertiría el intento recién anotado y convertiría esta función en
 * un oráculo para probar PINes sin dejar rastro (ver 20260824170000).
 */
create or replace function public.join_group(
  p_invite_code text,
  p_cap_usd     numeric,
  p_pin         text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_pin   jsonb;
  v_group public.groups%rowtype;
  v_bdate date := public.helios_business_date(now());
  v_count integer;
  v_avail numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  select * into v_group from public.groups
  where invite_code = upper(trim(p_invite_code)) and business_date = v_bdate
  for update;

  if not found then
    raise exception 'Ese código no corresponde a ningún grupo de esta noche'
      using errcode = 'P0002';
  end if;

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes entrar a un grupo' using errcode = '22023';
  end if;

  select count(*) into v_count from public.group_members
  where group_id = v_group.id and left_at is null;

  if v_count >= 8 then
    raise exception 'El grupo ya tiene 8 integrantes' using errcode = '22023';
  end if;

  v_avail := public.available_usd(v_user);

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu techo no puede bajar de $%', public.min_share_usd() using errcode = '22023';
  end if;

  if p_cap_usd > v_avail then
    raise exception 'Tu techo sería de $% y tienes $% disponibles', p_cap_usd, v_avail
      using errcode = '22023';
  end if;

  /**
   * Volver a entrar después de haber salido empieza de cero: techo nuevo y
   * `spent_usd` a 0. No es un agujero — lo ya gastado siguió siendo deuda suya
   * y sigue descontando de su disponible, así que el saldo real lo acota.
   */
  insert into public.group_members
    (group_id, user_id, business_date, cap_usd, spent_usd, left_at, authorized_at, status)
  values
    (v_group.id, v_user, v_bdate, p_cap_usd, 0, null, now(), 'active')
  on conflict (group_id, user_id) do update
    set cap_usd       = excluded.cap_usd,
        spent_usd     = 0,
        left_at       = null,
        authorized_at = now(),
        status        = 'active';

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group.id,
    'name', v_group.name,
    'cap_usd', p_cap_usd,
    'closes_at', public.helios_business_day_end(v_group.business_date)
  );
end;
$$;

revoke all on function public.join_group(text, numeric, text) from public, anon;
grant execute on function public.join_group(text, numeric, text) to authenticated;

/**
 * Mover mi techo con el grupo ya andando.
 *
 * Sin esto, agotar el techo a las 3 de la mañana es un callejón sin salida: en
 * `main` había que cerrar el grupo entero y abrir otro, con todo el mundo
 * volviendo a entrar. Esto es cada quien moviendo su propio máximo, desde su
 * teléfono, en un grupo que se muere solo dentro de unas horas.
 *
 * No se puede bajar por debajo de lo ya gastado: esa deuda ya existe.
 */
create or replace function public.set_my_group_cap(
  p_group_id uuid,
  p_cap_usd  numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_mine  public.group_members%rowtype;
  v_avail numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_mine from public.group_members
  where group_id = p_group_id and user_id = v_user and left_at is null
  for update;

  if not found then
    raise exception 'No estás en este grupo' using errcode = 'P0002';
  end if;

  if p_cap_usd < v_mine.spent_usd then
    raise exception 'Ya llevas $% en este grupo, el techo no puede bajar de ahí',
      v_mine.spent_usd using errcode = '22023';
  end if;

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu techo no puede bajar de $%', public.min_share_usd()
      using errcode = '22023';
  end if;

  v_avail := public.available_usd(v_user);

  -- El disponible ya tiene descontado lo gastado, así que el techo máximo es
  -- lo gastado más lo que queda.
  if p_cap_usd > v_mine.spent_usd + v_avail then
    raise exception 'Tu techo sería de $% y solo puedes llegar a $%',
      p_cap_usd, v_mine.spent_usd + v_avail using errcode = '22023';
  end if;

  update public.group_members set cap_usd = p_cap_usd
  where group_id = p_group_id and user_id = v_user;

  return jsonb_build_object('ok', true, 'cap_usd', p_cap_usd);
end;
$$;

revoke all on function public.set_my_group_cap(uuid, numeric) from public, anon;
grant execute on function public.set_my_group_cap(uuid, numeric) to authenticated;

/**
 * Salir del grupo. Un toque, efecto inmediato, nada que devolver.
 *
 * En `main` salir devolvía el ticket retenido y era media pantalla de
 * explicación. Aquí no se retuvo nada: salir solo significa que los cobros
 * siguientes ya no te incluyen. La deuda que ya asumiste sigue siendo tuya.
 */
create or replace function public.leave_group(p_group_id uuid)
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
    set left_at = now(), status = 'left'
  where group_id = p_group_id and user_id = v_user and left_at is null;

  return jsonb_build_object('ok', true, 'group_id', p_group_id);
end;
$$;

revoke all on function public.leave_group(uuid) from public, anon;
grant execute on function public.leave_group(uuid) to authenticated;
