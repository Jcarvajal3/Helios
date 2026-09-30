-- ============================================================================
-- Ronda — Un grupo dura hasta la mañana siguiente a su primer pago
--
-- Hasta hoy un grupo nacía con la noche en la que se creaba
-- (`business_date = helios_business_date(now())`) y se cerraba a las 10:00 del
-- día siguiente pasara lo que pasara. Así no se podía preparar una salida con
-- días de antelación: el grupo del lunes para el sábado se cerraba el martes
-- por la mañana, antes de que nadie entrara.
--
-- ── La regla nueva ─────────────────────────────────────────────────────────
--
-- Un grupo nace SIN noche (`business_date` null) y sigue abierto —se entra,
-- se invita, se mueve el aporte— el tiempo que haga falta. Su primer pago
-- confirmado le pone la noche (la de ese pago) y desde ahí vale lo de
-- siempre: se cierra solo a las 10:00 de Caracas siguientes
-- (`helios_business_day_end`) y pasa a Anteriores.
--
--   abierto      business_date is null or business_date >= helios_business_date(now())
--   Anteriores   business_date <  helios_business_date(now())   (my_past_groups)
--
-- `business_date` sigue significando lo mismo —la noche del grupo—, solo que
-- ahora la pone el primer pago y no el alta. Por eso Anteriores, el archivo y
-- `installment_unlocks_at` no cambian: un grupo con cuentas siempre tiene
-- noche, y es la de todas sus cuentas.
--
-- Una reversa no le quita la noche a un grupo: si se revierte su única cuenta,
-- el grupo se cierra igual a las 10:00. Volver a abrir un grupo que la gente
-- ya ha visto cerrarse sería más confuso que crear otro.
--
-- ── Lo que no cambia para las apps instaladas ──────────────────────────────
--
-- `closes_at` sigue llegando siempre con un instante, porque las apps
-- publicadas lo exigen al leer `my_groups`, `group_detail`,
-- `preview_group_charge` y los acuses de crear y entrar: un null les rompería
-- la pestaña Grupos y el pago con grupo. Sin noche, es la hora a la que
-- cerraría si se pagara ahora (`helios_group_closes_at`). La app nueva lo
-- distingue con `business_date`, que llega null hasta el primer pago.
--
-- ── Lo que cambia ──────────────────────────────────────────────────────────
--
--   1. `helios_group_is_open` y `helios_group_closes_at`: la regla, escrita
--      una sola vez.
--   2. `groups.business_date` y `group_members.business_date` admiten null;
--      los grupos de esta noche que todavía no tienen ningún pago pasan a
--      null (siguen abiertos). Los cerrados no se tocan.
--   3. El código de invitación es único entre grupos abiertos: el índice pasa
--      a `nulls not distinct`, o dos grupos sin noche podrían compartirlo.
--   4. `generate_invite_code` evita los códigos de cualquier grupo abierto.
--   5. `create_group` inserta sin noche; `find_group_by_code` y `join_group`
--      buscan entre los abiertos.
--   6. `my_groups` y `group_detail` listan los abiertos y mandan
--      `business_date`.
--   7. `preview_group_charge` y `set_my_group_cap` rechazan solo los
--      cerrados; `confirm_charge_as_group` pone la noche en el primer pago y
--      bloquea el grupo antes que a sus integrantes.
--   8. `my_deletion_eligibility` y `admin_group_metrics` cuentan como abiertos
--      también los que esperan su primer pago.
--   9. `my_group_ids` (la policy que deja ver el perfil de los compañeros)
--      mira el grupo y no la copia de la fecha del integrante.
--
-- Los cuerpos son los vigentes (dev y producción idénticos el 2026-09-23)
-- salvo esas líneas.
-- ============================================================================

-- ── 1. La regla ────────────────────────────────────────────────────────────

create or replace function public.helios_group_is_open(p_business_date date)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select p_business_date is null
      or p_business_date >= public.helios_business_date(now());
$$;

comment on function public.helios_group_is_open(date) is
  'Un grupo esta abierto hasta las 10:00 siguientes a su primer pago: sin noche (null) o con la noche en curso.';

-- Sin noche, la hora a la que cerraría si se pagara ahora. Nunca null: las
-- apps publicadas exigen un instante en `closes_at`.
create or replace function public.helios_group_closes_at(p_business_date date)
returns timestamptz
language sql
stable
set search_path = public, pg_temp
as $$
  select public.helios_business_day_end(
    coalesce(p_business_date, public.helios_business_date(now()))
  );
$$;

revoke all on function public.helios_group_is_open(date) from public, anon;
revoke all on function public.helios_group_closes_at(date) from public, anon;
grant execute on function public.helios_group_is_open(date) to authenticated;
grant execute on function public.helios_group_closes_at(date) to authenticated;

-- ── 2. La noche la pone el primer pago ─────────────────────────────────────
-- El `update` va antes que el índice nuevo: las filas tienen que cumplirlo ya
-- al crearlo (en producción no hay grupos abiertos a esta hora, pero dev sí
-- puede tenerlos).

alter table public.groups alter column business_date drop default;
alter table public.groups alter column business_date drop not null;
alter table public.group_members alter column business_date drop not null;

update public.groups g
set business_date = null
where g.business_date >= public.helios_business_date(now())
  and not exists (
    select 1 from public.charges c
    where c.group_id = g.id and c.confirmed_at is not null
  );

-- La copia del integrante sigue a la del grupo.
update public.group_members m
set business_date = g.business_date
from public.groups g
where g.id = m.group_id
  and m.business_date is distinct from g.business_date;

comment on table public.groups is
  'Los grupos. Nacen sin noche (business_date null) y abiertos; el primer pago confirmado les pone la noche y se cierran solos a las 10:00 de Caracas siguientes. Abierto = helios_group_is_open(business_date).';

comment on column public.groups.business_date is
  'La noche del grupo: la de su primer pago confirmado, que la pone confirm_charge_as_group. Null = todavia sin pagos, y abierto.';

comment on column public.group_members.business_date is
  'Copia de groups.business_date. Nada decide con ella: abierto o cerrado sale del grupo.';

-- ── 3. El código es único entre los abiertos ───────────────────────────────
-- Con `nulls not distinct`, dos grupos sin noche no pueden compartir código.
-- Uno sin noche y uno de esta noche podrían en teoría, en la carrera entre la
-- comprobación de `generate_invite_code` y el alta; con 32^6 códigos no
-- compensa un candado para eso.

drop index if exists public.groups_invite_code_alive;
create unique index groups_invite_code_alive
  on public.groups (invite_code, business_date) nulls not distinct;


-- ── 4. El código de invitación ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.generate_invite_code()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog', 'pg_temp'
AS $function$
declare
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code text;
  v_i integer;
begin
  loop
    v_code := '';
    /**
     * Un byte por carácter, y el alfabeto tiene 32: 256 es múltiplo exacto de
     * 32, así que `% 32` NO introduce sesgo — cada letra sale con la misma
     * probabilidad. (Con un alfabeto que no dividiera a 256 habría que
     * rechazar y repetir; con 32 no hace falta.)
     */
    for v_i in 0..5 loop
      v_code := v_code || substr(
        v_alphabet,
        1 + (get_byte(extensions.gen_random_bytes(6), v_i) % 32),
        1
      );
    end loop;

    -- Solo choca con los grupos ABIERTOS —los que esperan su primer pago y
    -- los de esta noche—: uno cerrado ya no abre nada. La carrera entre dos
    -- altas simultáneas la para el índice `groups_invite_code_alive`.
    exit when not exists (
      select 1 from public.groups
      where invite_code = v_code and public.helios_group_is_open(business_date)
    );
  end loop;

  return v_code;
end;
$function$;

-- ── 5. Crear, buscar y entrar ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.create_group(p_name text, p_cap_usd numeric, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_stop        jsonb;
  v_user  uuid := auth.uid();
  v_pin   jsonb;
  v_group public.groups%rowtype;
  v_avail numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  -- -- NUEVO (20260909160000) ---------------------------------------------
  -- El motivo CORRECTO, que ya no es siempre la mora: esta misma puerta la
  -- cierran ahora el mantenimiento global, un bloqueo del equipo y la lista
  -- de espera del piloto. Mandar a pagar una cuota vencida a quien esta
  -- parado por un mantenimiento es mandarlo a pagar algo que no debe.
  v_stop := public.helios_spend_block(v_user);
  if coalesce((v_stop->>'blocks_balance')::boolean, false) then
    raise exception '%', v_stop->>'message' using errcode = '22023';
  end if;
  -- ------------------------------------------------------------------------

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes crear un grupo' using errcode = '22023';
  end if;

  if coalesce(trim(p_name), '') = '' then
    raise exception 'El grupo necesita un nombre' using errcode = '22023';
  end if;

  v_avail := public.available_usd(v_user);

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu techo no puede bajar de €%', public.min_share_usd() using errcode = '22023';
  end if;

  if p_cap_usd > v_avail then
    raise exception 'Tu techo sería de €% y tienes €% disponibles', p_cap_usd, v_avail
      using errcode = '22023';
  end if;

  -- Nace sin noche: se la pone su primer pago confirmado
  -- (`confirm_charge_as_group`), y hasta entonces sigue abierto.
  insert into public.groups (name, created_by, invite_code, business_date)
  values (trim(p_name), v_user, public.generate_invite_code(), null)
  returning * into v_group;

  insert into public.group_members
    (group_id, user_id, business_date, cap_usd, spent_usd, authorized_at)
  values (v_group.id, v_user, null, p_cap_usd, 0, now());

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group.id,
    'name', v_group.name,
    'invite_code', v_group.invite_code,
    'cap_usd', p_cap_usd,
    'closes_at', public.helios_group_closes_at(null),
    'business_date', null
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.find_group_by_code(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_stop        jsonb;
  v_user  uuid := auth.uid();
  v_group public.groups%rowtype;
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
  where invite_code = upper(trim(p_code))
    and public.helios_group_is_open(business_date)
  order by business_date nulls first
  limit 1;

  if not found then
    -- Un código de un grupo cerrado y uno inventado dan lo mismo a propósito:
    -- decir "ese grupo ya cerró" obligaría a buscar entre los muertos, y no
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
      -- Y en cupo, que es la que se enseña: ver la cabecera.
      'blocking_financed_usd', (v_plan->>'blocking_financed_usd')::numeric,
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
               'color', p.avatar_color,
               -- NUEVO: lo que cada quien PUSO y lo que todavía PUEDE poner.
               -- Es lo que deja dibujar el reparto antes de entrar, con el
               -- aporte propio moviéndose dentro. Entrar a un grupo es aceptar
               -- que los demás vean eso de ti (§2.7.2) y es exactamente lo que
               -- se ve un segundo después, dentro del grupo: no se enseña nada
               -- que no fuera a verse igual al aceptar.
               'spent_usd',     gp.spent_usd,
               'capacity_usd',  gp.capacity_usd,
               'can_take_debt', gp.can_take_debt
             ) order by m.joined_at), '[]'::jsonb)
      from public.group_members m
      join public.profiles p on p.id = m.user_id
      join lateral (
        select * from public.group_participants(v_group.id) x where x.user_id = m.user_id
      ) gp on true
      where m.group_id = v_group.id and m.left_at is null
    ),
    'closes_at', public.helios_group_closes_at(v_group.business_date),
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
    /**
     * LAS QUE YA PAGUÉ AQUÍ. Son las que el plan NO mira.
     *
     * Salir de un grupo no borra la deuda —es individual—, así que al volver a
     * entrar esas cuentas ya tienen cuotas mías y `helios_group_open_charges`
     * las deja fuera: no se cobra nada otra vez, que es lo correcto, pero la
     * pantalla se quedaba sin nada que decir justo en el caso en que más miedo
     * da entrar. Con esto puede decir "esto ya lo pusiste, volver no te cuesta
     * nada" y enseñarlo.
     *
     * Las cifras salen de las CUOTAS y no de un reparto nuevo: son las que se
     * escribieron aquel día y las que el usuario va a ver en Cuotas.
     */
    'settled_charges', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'charge_id',     c.id,
               'merchant_name', coalesce(m.name, 'Un local'),
               'order_number',  c.order_number,
               'amount_usd',    c.amount_usd,
               'financed_usd',  coalesce(c.base_usd, c.amount_usd),
               'my_financed_usd', (
                 select coalesce(sum(i.financed_usd), 0) from public.installments i
                 where i.charge_id = c.id and i.user_id = v_user
               ),
               'my_payable_usd', (
                 select coalesce(sum(i.amount_usd), 0) from public.installments i
                 where i.charge_id = c.id and i.user_id = v_user
               ),
               'skipped', false,
               'items', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'name',           ci.name,
                          'quantity',       ci.quantity,
                          'unit_price_usd', ci.unit_price_usd,
                          'line_total_usd', ci.line_total_usd
                        ) order by ci.position, ci.created_at), '[]'::jsonb)
                 from public.charge_items ci
                 where ci.charge_id = c.id
               )
             ) order by c.confirmed_at, c.id), '[]'::jsonb)
      from public.charges c
      join public.merchants m on m.id = c.merchant_id
      where c.group_id = v_group.id
        and c.status = 'confirmed'
        and exists (
          select 1 from public.installments i
          where i.charge_id = c.id and i.user_id = v_user
        )
    ),
    -- El techo que propone la app: el saldo entero. Es un defecto, no una
    -- obligación; la pantalla deja bajarlo antes de aceptar.
    'suggested_cap_usd', v_max,
    'max_cap_usd', v_max,
    'min_cap_usd', greatest(public.min_share_usd(), v_owed + v_retro)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.join_group(p_invite_code text, p_cap_usd numeric, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_stop        jsonb;
  v_user   uuid := auth.uid();
  v_pin    jsonb;
  v_group  public.groups%rowtype;
  v_count  integer;
  v_avail  numeric(18,4);
  v_plan   jsonb;
  v_retro  numeric(18,4);
  v_owed   numeric(18,4);
  v_row    record;
  v_done   jsonb;
  v_paid   numeric(18,4) := 0;
  v_taken  numeric(18,4) := 0;
  v_charges integer := 0;
  v_skipped integer := 0;
  v_name   text;
  v_member record;
  v_theirs numeric(18,4);
  v_before jsonb;
  v_was    numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  -- El candado del grupo: dos personas entrando a la vez se ponen en fila, y
  -- la segunda ve el reparto que dejó la primera.
  select * into v_group from public.groups
  where invite_code = upper(trim(p_invite_code))
    and public.helios_group_is_open(business_date)
  order by business_date nulls first
  limit 1
  for update;

  if not found then
    raise exception 'Ese código no corresponde a ningún grupo abierto'
      using errcode = 'P0002';
  end if;

  -- -- NUEVO (20260909160000) ---------------------------------------------
  -- El motivo CORRECTO, que ya no es siempre la mora: esta misma puerta la
  -- cierran ahora el mantenimiento global, un bloqueo del equipo y la lista
  -- de espera del piloto. Mandar a pagar una cuota vencida a quien esta
  -- parado por un mantenimiento es mandarlo a pagar algo que no debe.
  v_stop := public.helios_spend_block(v_user);
  if coalesce((v_stop->>'blocks_balance')::boolean, false) then
    raise exception '%', v_stop->>'message' using errcode = '22023';
  end if;
  -- ------------------------------------------------------------------------

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes entrar a un grupo' using errcode = '22023';
  end if;

  select count(*) into v_count from public.group_members
  where group_id = v_group.id and left_at is null;

  if v_count >= public.max_group_members() then
    raise exception 'El grupo ya tiene % integrantes', public.max_group_members()
      using errcode = '22023';
  end if;

  v_avail := public.available_usd(v_user);

  -- ── Lo que ya lleva el grupo ──────────────────────────────────────────────
  v_plan := public.helios_group_join_plan(v_group.id, v_user);

  -- Solo se bloquea por saldo. Una cuenta demasiado pequeña para uno más no
  -- cierra el grupo: se salta esa y se entra a las demás (ver el plan).
  if not coalesce((v_plan->>'ok')::boolean, false) then
    raise exception
      'No te alcanza el saldo para tomar tu parte de lo que el grupo ya lleva gastado'
      using errcode = '22023';
  end if;

  v_retro := (v_plan->>'financed_usd')::numeric;

  -- REGLA 3: volver a entrar arranca cubriendo lo que este grupo ya me cargó,
  -- no en cero. Lo ya gastado sigue siendo deuda mía y el techo es de la noche
  -- entera, no de cada visita.
  select coalesce(sum(i.financed_usd), 0) into v_owed
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where c.group_id = v_group.id and i.user_id = v_user;

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu aporte máximo no puede bajar de €%', public.min_share_usd()
      using errcode = '22023';
  end if;

  -- REGLA 1: el techo es para lo que VIENE. Lo ya gastado no se negocia a la
  -- baja: o lo cubre, o no se entra.
  if p_cap_usd < v_owed + v_retro then
    raise exception
      'Tu aporte máximo tiene que cubrir al menos los €% que ya te tocan de lo que el grupo lleva gastado',
      trim(to_char(v_owed + v_retro, 'FM999999990.00'))
      using errcode = '22023';
  end if;

  if p_cap_usd > v_avail + v_owed then
    raise exception 'Tu aporte máximo sería de €% y tienes €% disponibles', p_cap_usd, v_avail
      using errcode = '22023';
  end if;

  -- La foto de lo que debe cada quien ANTES de tocar nada. Es lo único con lo
  -- que el aviso del final puede saber si a alguien le bajó la parte de verdad.
  select coalesce(jsonb_object_agg(t.user_id::text, t.total), '{}'::jsonb) into v_before
  from (
    select i.user_id, sum(i.amount_usd) as total
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.group_id = v_group.id
    group by i.user_id
  ) t;

  insert into public.group_members
    (group_id, user_id, business_date, cap_usd, spent_usd, left_at, authorized_at, status)
  values
    (v_group.id, v_user, v_group.business_date, p_cap_usd, v_owed, null, now(), 'active')
  on conflict (group_id, user_id) do update
    set cap_usd       = excluded.cap_usd,
        spent_usd     = excluded.spent_usd,
        left_at       = null,
        authorized_at = now(),
        status        = 'active';

  -- ── El reparto retroactivo, cuenta por cuenta ─────────────────────────────
  -- La capacidad se va gastando en el mismo orden que en el plan, así que sale
  -- exactamente la cifra que se enseñó antes del PIN.
  --
  -- ⬜ Esta lista es la que se queda corta en la carrera conocida: un cobro que
  -- se está confirmando AHORA MISMO en otra transacción no se ve desde aquí, y
  -- esa cuenta acabará sin el que entra. Punto 10 de este archivo, y
  -- `helios_group_split_gaps` para detectarlo.
  for v_row in select * from public.helios_group_open_charges(v_group.id, v_user) loop
    v_done := public.helios_group_resplit_charge(
      v_row.charge_id, v_user, greatest(v_avail - v_taken, 0)
    );

    -- Demasiado pequeña para uno más: queda como estaba y no cuenta como suya.
    if coalesce((v_done->>'skipped')::boolean, false) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_taken   := v_taken + (v_done->>'financed_usd')::numeric;
    v_paid    := v_paid  + (v_done->>'payable_usd')::numeric;
    v_charges := v_charges + 1;
  end loop;

  -- ── El aviso: uno solo, y con la cifra ya cerrada ─────────────────────────
  select coalesce(full_name, 'Alguien') into v_name from public.profiles where id = v_user;

  for v_member in
    select user_id from public.group_members
    where group_id = v_group.id and left_at is null and user_id <> v_user
  loop
    select coalesce(sum(i.amount_usd), 0) into v_theirs
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.group_id = v_group.id and i.user_id = v_member.user_id;

    /**
     * "Tu parte bajó" solo si de verdad bajó.
     *
     * No siempre baja, y el caso no es raro: un grupo de dos con una sola
     * cuenta de €6 no puede repartirla entre tres —no llega a €7,50— así que
     * el tercero entra sin asumir nada y a los dos de antes no les cambia un
     * céntimo. Decirles "bajó a €3,00" cuando siguen debiendo los mismos €3
     * es un aviso que miente sobre dinero, que es la peor clase de aviso.
     */
    v_was := coalesce((v_before->>v_member.user_id::text)::numeric, 0);

    perform public.notify(
      v_member.user_id,
      'group_charge',
      format('%s entró a %s', v_name, v_group.name),
      case
        when v_theirs < v_was then
          format('Ya son %s y tu parte bajó a €%s.',
                 v_count + 1, trim(to_char(v_theirs, 'FM999999990.00')))
        else
          format('Ya son %s. Lo que pague cualquiera se reparte entre todos%s.',
                 v_count + 1,
                 -- La hora solo existe desde el primer pago; antes no hay cierre.
                 case when v_group.business_date is null then ''
                      else ' hasta las 10 AM' end)
      end,
      jsonb_build_object('group_id', v_group.id, 'user_id', v_user)
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group.id,
    'name', v_group.name,
    'cap_usd', p_cap_usd,
    'closes_at', public.helios_group_closes_at(v_group.business_date),
    'business_date', v_group.business_date,
    -- Lo que se acaba de asumir al entrar. El acuse lo dice.
    'retro_charge_count', v_charges,
    'retro_financed_usd', v_taken,
    'retro_payable_usd', v_paid,
    -- Y de las que no es parte, por pequeñas.
    'skipped_charge_count', v_skipped
  );
end;
$function$;

-- ── 6. Lo que se lee de un grupo abierto ─────────────────────────────────────

CREATE OR REPLACE FUNCTION public.my_groups()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user  uuid := auth.uid();
  v_rows  jsonb;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(x order by x->>'created_at'), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'group_id',    g.id,
      'name',        g.name,
      'invite_code', g.invite_code,
      'created_at',  g.created_at,
      'created_by_me', g.created_by = v_user,
      'closes_at',   public.helios_group_closes_at(g.business_date),
      -- null hasta el primer pago: entonces `closes_at` es la hora a la que
      -- cerraría si se pagara ahora, no una hora a la que vaya a cerrar.
      'business_date', g.business_date,
      'members', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'user_id',       p.user_id,
                 'name',          p.name,
                 'is_me',         p.user_id = v_user,
                 'cap_usd',       p.cap_usd,
                 'spent_usd',     p.spent_usd,
                 'capacity_usd',  p.capacity_usd,
                 'can_take_debt', p.can_take_debt
               ) order by p.user_id), '[]'::jsonb)
        from public.group_participants(g.id) p
      ),
      'my_cap_usd',    mine.cap_usd,
      'my_spent_usd',  mine.spent_usd,
      'my_left_usd',   greatest(least(mine.cap_usd - mine.spent_usd,
                                      public.available_usd(v_user)), 0),
      'my_max_cap_usd', mine.spent_usd + public.available_usd(v_user),
      -- Lo que el grupo puede poner entre todos: la suma de lo que puede cada
      -- quien de los que reparten.
      'pot_usd',       public.group_pot_usd(g.id),
      -- N × $2,50, con N los que REPARTEN: por debajo de eso la cuenta no se
      -- puede dividir entre tantos. Se dice ANTES de escanear; descubrirlo con
      -- el QR ya leído es enterarse de pie en la caja.
      'min_charge_usd', (select count(*) from public.group_participants(g.id)
                         where can_take_debt
                           and capacity_usd >= public.min_share_usd())
                        * public.min_share_usd(),
      'min_share_usd', public.min_share_usd()
    ) as x
    from public.groups g
    join public.group_members mine
      on mine.group_id = g.id and mine.user_id = v_user and mine.left_at is null
    where public.helios_group_is_open(g.business_date)
  ) s;

  return v_rows;
end;
$function$;

CREATE OR REPLACE FUNCTION public.group_detail(p_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user  uuid := auth.uid();
  v_group public.groups%rowtype;
  v_mine  public.group_members%rowtype;
  v_avail numeric(18,4);
  v_alive boolean;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_mine from public.group_members
  where group_id = p_group_id and user_id = v_user and left_at is null;

  if not found then
    raise exception 'No estás en este grupo' using errcode = '42501';
  end if;

  select * into v_group from public.groups where id = p_group_id;
  v_avail := public.available_usd(v_user);

  v_alive := public.helios_group_is_open(v_group.business_date);

  return jsonb_build_object(
    'group_id',    v_group.id,
    'name',        v_group.name,
    'invite_code', v_group.invite_code,
    'created_by_me', v_group.created_by = v_user,
    'closes_at',   public.helios_group_closes_at(v_group.business_date),
    'business_date', v_group.business_date,
    'is_alive',    v_alive,
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'user_id',       p.user_id,
               'name',          p.name,
               'is_me',         p.user_id = v_user,
               -- El techo y lo gastado son hechos de ESA noche: no dicen nada
               -- de hoy y se quedan.
               'cap_usd',       p.cap_usd,
               'spent_usd',     p.spent_usd,
               -- La capacidad SÍ es de hoy —es `min(techo − gastado,
               -- disponible)`— así que en un grupo muerto delataría el saldo
               -- de crédito actual de gente que compartió una noche contigo
               -- hace meses. Se calla.
               'capacity_usd',  case when v_alive then p.capacity_usd else null end,
               'can_take_debt', case when v_alive then p.can_take_debt else null end
             ) order by p.user_id), '[]'::jsonb)
      from public.group_participants(p_group_id) p
    ),
    'my_cap_usd',     v_mine.cap_usd,
    'my_spent_usd',   v_mine.spent_usd,
    -- Lo mío sí puedo verlo siempre: es mi propio saldo.
    'my_left_usd',    greatest(least(v_mine.cap_usd - v_mine.spent_usd, v_avail), 0),
    'my_max_cap_usd', v_mine.spent_usd + v_avail,
    'pot_usd',        case when v_alive then public.group_pot_usd(p_group_id) else null end,
    'min_share_usd',  public.min_share_usd(),
    'charges', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'charge_id',   c.id,
               'merchant_name', mm.name,
               'amount_usd',  c.amount_usd,
               -- NUEVO: la cuenta del local, sin el servicio. Es la cifra que
               -- la fila enseña como total, igual que en el resto de la app.
               'financed_usd', coalesce(c.base_usd, c.amount_usd),
               'confirmed_at', c.confirmed_at,
               'started_by',  pr.full_name,
               'my_share_usd', mine.total,
               'my_financed_usd', mine.financed,
               /**
                * NUEVO: por qué no te tocó nada, cuando se puede probar.
                *
                * `null` cuando sí participaste —no hay nada que explicar— y
                * también cuando no participaste por un motivo que no consta.
                * La app enseña "no te tocó" a secas en ese caso, que es
                * verdad, en vez de una píldora que no lo sería.
                */
               'my_share_reason', case
                 when mine.total is not null then null
                 when coalesce(c.base_usd, c.amount_usd) <
                      ((select count(distinct i.user_id) from public.installments i
                        where i.charge_id = c.id) + 1) * public.min_share_usd()
                   then 'too_small'
                 else null
               end
             ) order by c.confirmed_at desc), '[]'::jsonb)
      from public.charges c
      join public.merchants mm on mm.id = c.merchant_id
      left join public.profiles pr on pr.id = c.user_id
      -- Se saca a un `lateral` porque ahora hace falta DOS veces —la cifra y
      -- el motivo— y repetir la subconsulta la haría correr dos veces por
      -- fila, además de dejar dos sitios donde equivocarse.
      left join lateral (
        select sum(i.amount_usd) as total, sum(i.financed_usd) as financed
        from public.installments i
        where i.charge_id = c.id and i.user_id = v_user
      ) mine on true
      where c.group_id = p_group_id and c.status = 'confirmed'
    )
  );
end;
$function$;

-- ── 7. Pagar y mover el aporte ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.preview_group_charge(p_charge_id uuid, p_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user     uuid := auth.uid();
  v_group    public.groups%rowtype;
  v_charge   public.charges%rowtype;
  v_parts    jsonb := '[]'::jsonb;
  v_split    jsonb;
  v_rows     jsonb := '[]'::jsonb;
  v_row      record;
  v_shares   jsonb;
  v_share    numeric(18,4);
  v_my       numeric(18,4) := 0;
  v_eligible integer := 0;
  -- NUEVO
  v_financed  numeric(18,4);
  v_payables  jsonb := '{}'::jsonb;
  v_payable   numeric(18,4);
  v_assigned  numeric(18,4) := 0;
  v_i         integer := 0;
  v_n         integer;
  v_my_pay    numeric(18,4) := 0;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.group_members
    where group_id = p_group_id and user_id = v_user and left_at is null
  ) then
    raise exception 'No estás en este grupo' using errcode = '42501';
  end if;

  select * into v_group  from public.groups  where id = p_group_id;

  -- Repartir en un grupo cerrado no significa nada, y era además por donde se
  -- leía la capacidad de crédito de gente de un grupo ya muerto.
  if not public.helios_group_is_open(v_group.business_date) then
    return jsonb_build_object('ok', false, 'reason', 'closed');
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  for v_row in select * from public.group_participants(p_group_id) loop
    if v_row.can_take_debt then
      v_parts := v_parts || jsonb_build_object(
        'user_id', v_row.user_id, 'capacity_usd', v_row.capacity_usd
      );
      if v_row.capacity_usd >= public.min_share_usd() then
        v_eligible := v_eligible + 1;
      end if;
    end if;
  end loop;

  -- NUEVO: se reparte lo financiado.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);
  v_split  := public.helios_split_shares(v_financed, v_parts, v_user);
  v_shares := coalesce(v_split->'shares', '[]'::jsonb);

  -- Los pagaderos, con el mismo residuo A QUIEN PAGA que usa `confirm`. Las
  -- dos cifras tienen que salir idénticas: si no, el guardia de
  -- `p_expected_share_usd` rechazaría un cobro que nadie ha cambiado.
  v_n := coalesce((v_split->>'split_between')::integer, 0);
  for v_row in
    select (s->>'user_id')::uuid as user_id, (s->>'share_usd')::numeric as share
    from jsonb_array_elements(v_shares) s
    order by ((s->>'user_id')::uuid = v_user), (s->>'user_id')::uuid
  loop
    v_i := v_i + 1;
    if v_i = v_n then
      v_payable := v_charge.amount_usd - v_assigned;
    else
      v_payable := public.helios_payable_usd(v_row.share, v_financed, v_charge.amount_usd);
    end if;
    v_assigned := v_assigned + v_payable;
    v_payables := v_payables || jsonb_build_object(v_row.user_id::text, v_payable);
  end loop;

  for v_row in select * from public.group_participants(p_group_id) loop
    select (s->>'share_usd')::numeric into v_share
    from jsonb_array_elements(v_shares) s
    where (s->>'user_id')::uuid = v_row.user_id;

    if v_row.user_id = v_user then
      v_my     := coalesce(v_share, 0);
      v_my_pay := coalesce((v_payables->>v_row.user_id::text)::numeric, 0);
    end if;

    v_rows := v_rows || jsonb_build_object(
      'user_id',      v_row.user_id,
      'name',         v_row.name,
      'is_me',        v_row.user_id = v_user,
      'cap_usd',      v_row.cap_usd,
      'spent_usd',    v_row.spent_usd,
      'capacity_usd', v_row.capacity_usd,
      'share_usd',    v_share,
      -- NUEVO: lo que esa parte le va a costar pagar.
      'payable_usd',  (v_payables->>v_row.user_id::text)::numeric,
      'participates', v_share is not null,
      'at_cap',       coalesce((
        select (s->>'at_cap')::boolean from jsonb_array_elements(v_shares) s
        where (s->>'user_id')::uuid = v_row.user_id
      ), false),
      'blocked_reason', case
        when not v_row.can_take_debt then 'overdue'
        when v_row.capacity_usd < public.min_share_usd() then 'no_capacity'
        else null
      end
    );
  end loop;

  return jsonb_build_object(
    'ok',            coalesce((v_split->>'ok')::boolean, false),
    'reason',        v_split->>'reason',
    'group_id',      p_group_id,
    'group_name',    v_group.name,
    'closes_at',     public.helios_group_closes_at(v_group.business_date),
    'amount_usd',    v_charge.amount_usd,
    -- NUEVO: lo que se reparte contra el cupo, y lo mío en las dos monedas.
    'financed_usd',  v_financed,
    'split_between', v_split->'split_between',
    'capacity_usd',  v_split->'capacity_usd',
    'min_total_usd', v_split->'min_total_usd',
    'even_share_usd', case when v_eligible > 0
      then round(v_financed / v_eligible, 2) else null end,
    'my_share_usd',  v_my,
    'my_payable_usd', v_my_pay,
    'members',       v_rows
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.confirm_charge_as_group(p_charge_id uuid, p_group_id uuid, p_idempotency_key text, p_pin text, p_expected_share_usd numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'pg_temp'
AS $function$
declare
  v_stop        jsonb;
  v_user    uuid := auth.uid();
  v_pin     jsonb;
  v_charge  public.charges%rowtype;
  v_group_id  uuid;
  v_group_bdate date;
  v_terms   public.merchant_settlement_terms%rowtype;
  v_parts   jsonb := '[]'::jsonb;
  v_split   jsonb;
  v_shares  jsonb;
  v_row     record;
  v_share   numeric(18,4);
  v_my      numeric(18,4) := 0;
  v_count   integer;
  v_bdate   date;
  v_due_1   date;
  v_due_2   date;
  v_tx      uuid;
  v_acct_pay uuid;
  v_acct_rev uuid;
  v_upfront  numeric(18,4);
  v_revenue  numeric(18,4);
  v_merchant_share numeric(18,4);
  v_confirmed_at   timestamptz;
  v_debt     jsonb;
  v_first    numeric(18,4);
  v_second   numeric(18,4);
  v_my_first numeric(18,4);
  v_my_second numeric(18,4);
  -- NUEVO: lo financiado del cobro, el pagadero de cada quien y el acumulado
  -- que hace que la suma cuadre al céntimo con el asiento.
  v_financed  numeric(18,4);
  v_payable   numeric(18,4);
  v_assigned  numeric(18,4) := 0;
  v_i         integer := 0;
  v_my_payable numeric(18,4) := 0;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- Sin importe esperado no se cobra. Es el consentimiento del usuario traído
  -- hasta aquí; dejarlo opcional sería no tenerlo.
  if p_expected_share_usd is null then
    raise exception 'Falta el importe autorizado' using errcode = '22023';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  if v_charge.status = 'confirmed' then
    return jsonb_build_object(
      'ok', true, 'charge_id', v_charge.id, 'already_confirmed', true,
      'confirmed_at', v_charge.confirmed_at
    );
  end if;

  if v_charge.status <> 'pending' then
    raise exception 'Este cobro ya no está disponible (%)', v_charge.status
      using errcode = '22023';
  end if;

  if v_charge.expires_at < now() then
    raise exception 'Este QR caducó, pídele al local que genere uno nuevo'
      using errcode = '22023';
  end if;

  v_group_id := p_group_id;

  -- El candado del grupo va ANTES que el de sus integrantes, en el mismo
  -- orden que `join_group`: quien entra y quien paga se ponen en fila en vez
  -- de cruzarse. Sin él, el sello de la noche de abajo esperaría a un
  -- `join_group` que a su vez espera a las filas de integrantes de aquí.
  select business_date into v_group_bdate
  from public.groups where id = v_group_id
  for no key update;

  if not exists (
    select 1 from public.group_members
    where group_id = v_group_id
      and user_id = v_user
      and left_at is null
  ) then
    raise exception 'No perteneces a este grupo' using errcode = '42501';
  end if;

  if not public.helios_group_is_open(v_group_bdate) then
    raise exception 'Este grupo ya se cerró' using errcode = '22023';
  end if;

  -- El que inicia tiene que poder asumir su parte: sin esto, alguien con una
  -- cuota vencida quedaba fuera del reparto y la venta salía repartida solo
  -- entre los demás.
  -- -- NUEVO (20260909160000) ---------------------------------------------
  -- El motivo CORRECTO, que ya no es siempre la mora: esta misma puerta la
  -- cierran ahora el mantenimiento global, un bloqueo del equipo y la lista
  -- de espera del piloto. Mandar a pagar una cuota vencida a quien esta
  -- parado por un mantenimiento es mandarlo a pagar algo que no debe.
  v_stop := public.helios_spend_block(v_user);
  if coalesce((v_stop->>'blocks_balance')::boolean, false) then
    raise exception '%', v_stop->>'message' using errcode = '22023';
  end if;
  -- ------------------------------------------------------------------------

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes iniciar un cobro del grupo'
      using errcode = '22023';
  end if;

  -- Se bloquean las filas del grupo antes de leer capacidades: dos cobros
  -- simultáneos en el mismo grupo no pueden repartir cada uno sobre el mismo
  -- techo sin verse.
  perform 1 from public.group_members
  where group_id = v_group_id and left_at is null
  order by user_id
  for update;

  for v_row in select * from public.group_participants(v_group_id) loop
    if v_row.can_take_debt then
      v_parts := v_parts || jsonb_build_object(
        'user_id', v_row.user_id, 'capacity_usd', v_row.capacity_usd
      );
    end if;
  end loop;

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- Se reparte lo FINANCIADO. Las capacidades son de crédito (techo menos
  -- gastado, contra el saldo disponible), así que el total que se reparte tiene
  -- que estar en la misma moneda.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);
  v_split := public.helios_split_shares(v_financed, v_parts, v_user);
  -- ─────────────────────────────────────────────────────────────────────────

  if not coalesce((v_split->>'ok')::boolean, false) then
    if v_split->>'reason' = 'too_small' then
      raise exception 'Entre % la cuenta mínima es €% y esta es de €%',
        v_split->>'split_between', v_split->>'min_total_usd', v_financed
        using errcode = '22023';
    else
      raise exception 'El grupo llega a €% y la cuenta es de €%',
        v_split->>'capacity_usd', v_financed
        using errcode = '22023';
    end if;
  end if;

  v_shares := v_split->'shares';
  v_count  := (v_split->>'split_between')::integer;

  -- El iniciador tiene que salir en el reparto: si su techo se agotó o su saldo
  -- no llega al mínimo por persona, la cuenta entera caería sobre los demás.
  select (s->>'share_usd')::numeric into v_my
  from jsonb_array_elements(v_shares) s
  where (s->>'user_id')::uuid = v_user;

  if v_my is null then
    raise exception 'No te alcanza para poner tu parte de esta cuenta'
      using errcode = '22023';
  end if;

  -- Y esa parte no puede pasarse de la que se autorizó con el PIN. Solo hacia
  -- arriba: que baje no perjudica a quien paga. El céntimo de tolerancia es por
  -- el viaje del número en coma flotante desde el teléfono.
  if v_my > p_expected_share_usd + 0.01 then
    raise exception
      'Tu parte cambió a €% mientras confirmabas (habías autorizado €%): vuelve a mirar el reparto',
      trim(to_char(v_my, 'FM999999990.00')),
      trim(to_char(p_expected_share_usd, 'FM999999990.00'))
      using errcode = '22023';
  end if;

  select * into v_terms from public.merchant_settlement_terms
  where merchant_id = v_charge.merchant_id;

  v_bdate := public.helios_business_date(now());
  select due_1, due_2 into v_due_1, v_due_2
  from public.helios_installment_due_dates(v_bdate);

  v_acct_pay := ledger.get_or_create_account('merchant_payable', v_charge.merchant_id);
  v_acct_rev := ledger.get_or_create_account('platform_revenue', null);

  v_revenue        := coalesce(v_charge.consumer_fee_usd, 0) + coalesce(v_charge.merchant_fee_usd, 0);
  v_merchant_share := coalesce(v_charge.merchant_net_usd, v_charge.amount_usd - v_revenue);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', p_idempotency_key, v_bdate, v_charge.id,
          format('Venta repartida en grupo entre %s personas', v_count))
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit)
  select v_tx, x.acct, x.debit, x.credit
  from (values
    (v_acct_pay, 0::numeric, v_merchant_share),
    (v_acct_rev, 0::numeric, v_revenue),
    (ledger.get_or_create_account('vat_payable', null), 0::numeric,
     v_charge.amount_usd - v_merchant_share - v_revenue)
  ) as x(acct, debit, credit)
  where x.debit <> 0 or x.credit <> 0;

  -- --- Una deuda por integrante, contra su propio límite -------------------
  for v_row in
    select (s->>'user_id')::uuid as user_id, (s->>'share_usd')::numeric as share
    from jsonb_array_elements(v_shares) s
    order by ((s->>'user_id')::uuid = v_user), (s->>'user_id')::uuid
  loop
    v_share := v_row.share;
    v_i := v_i + 1;

    -- ── NUEVO ──────────────────────────────────────────────────────────────
    -- El fee de cada quien cae sobre su parte. **El residuo de redondeo lo
    -- absorbe QUIEN PAGA** y no se reparte: la suma de los pagaderos tiene que
    -- dar EXACTO el total del cobro, porque es la contrapartida del asiento de
    -- arriba y el libro cuadra al céntimo o no cuadra.
    --
    -- Quien paga va el ÚLTIMO del bucle (ver el `order by`), así que sigue
    -- cerrando la cuenta `v_i = v_count`. Lo que cambia es quién es ese.
    if v_i = v_count then
      v_payable := v_charge.amount_usd - v_assigned;
    else
      v_payable := public.helios_payable_usd(v_share, v_financed, v_charge.amount_usd);
    end if;
    v_assigned := v_assigned + v_payable;
    -- ───────────────────────────────────────────────────────────────────────

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, ledger.get_or_create_account('user_receivable', v_row.user_id), v_payable, 0);

    v_debt   := public.helios_assign_debt(
      v_row.user_id, v_charge.id, v_share, v_payable, v_due_1, v_due_2,
      format('Alguien del grupo ya no tiene límite para €%s',
             trim(to_char(v_share, 'FM999999990.00')))
    );
    v_first  := (v_debt->>'installment_1_usd')::numeric;
    v_second := (v_debt->>'installment_2_usd')::numeric;

    if v_row.user_id = v_user then
      v_my_first   := v_first;
      v_my_second  := v_second;
      v_my_payable := v_payable;
    end if;

    -- El techo es acumulativo por la noche: aquí es donde se gasta. Se gasta lo
    -- FINANCIADO, que es de lo que es techo.
    update public.group_members
      set spent_usd = spent_usd + v_share
    where group_id = v_group_id and user_id = v_row.user_id;
  end loop;

  v_upfront := round(v_merchant_share * v_terms.upfront_pct / 100, 4);
  perform ledger.record_advance_settlement(v_charge.merchant_id, v_charge.id, v_upfront, v_bdate);

  update public.charges
    set status = 'confirmed', user_id = v_user, group_id = v_group_id,
        business_date = v_bdate, confirmed_at = now()
  where id = v_charge.id
  returning confirmed_at into v_confirmed_at;

  -- El primer pago le pone la noche al grupo, y con ella el cierre: las 10:00
  -- siguientes. Los demás pagos de esa noche la encuentran ya puesta. Una
  -- reversa no la quita: la noche existió.
  if v_group_bdate is null then
    update public.groups set business_date = v_bdate where id = v_group_id;
    update public.group_members set business_date = v_bdate where group_id = v_group_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    -- NUEVO: lo financiado del cobro entero y lo mío, en las dos monedas.
    'financed_usd', v_financed,
    'split_between', v_count,
    'share_usd', v_my,
    'my_payable_usd', v_my_payable,
    'even_share_usd', round(v_financed / v_count, 2),
    'due_1', v_due_1,
    'due_2', v_due_2,
    'installment_1_usd', v_my_first,
    'installment_2_usd', v_my_second,
    'confirmed_at', v_confirmed_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_my_group_cap(p_group_id uuid, p_cap_usd numeric, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user  uuid := auth.uid();
  v_mine  public.group_members%rowtype;
  v_avail numeric(18,4);
  v_group public.groups%rowtype;
  v_pin   jsonb;
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

  -- NUEVO: un grupo cerrado no admite cambios. Cobrar ya lo comprobaba;
  -- esto contestaba igual y dejaba mover el techo de algo que ya murió.
  select * into v_group from public.groups where id = p_group_id;

  if not public.helios_group_is_open(v_group.business_date) then
    raise exception 'Este grupo ya se cerró' using errcode = '22023';
  end if;

  -- NUEVO: subirlo compromete más crédito, así que se firma.
  if p_cap_usd > v_mine.cap_usd then
    v_pin := public.verify_user_pin(p_pin);
    if not coalesce((v_pin->>'ok')::boolean, false) then
      return v_pin;
    end if;
  end if;

  if p_cap_usd < v_mine.spent_usd then
    raise exception 'Ya llevas €% en este grupo, el techo no puede bajar de ahí',
      v_mine.spent_usd using errcode = '22023';
  end if;

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu techo no puede bajar de €%', public.min_share_usd()
      using errcode = '22023';
  end if;

  v_avail := public.available_usd(v_user);

  -- El disponible ya tiene descontado lo gastado, así que el techo máximo es
  -- lo gastado más lo que queda.
  if p_cap_usd > v_mine.spent_usd + v_avail then
    raise exception 'Tu techo sería de €% y solo puedes llegar a €%',
      p_cap_usd, v_mine.spent_usd + v_avail using errcode = '22023';
  end if;

  update public.group_members set cap_usd = p_cap_usd
  where group_id = p_group_id and user_id = v_user;

  return jsonb_build_object('ok', true, 'cap_usd', p_cap_usd);
end;
$function$;

-- ── 8. Lo que cuenta grupos abiertos ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.my_deletion_eligibility()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user       uuid := auth.uid();
  v_due_count  integer;
  v_due_amount numeric(18,4);
  v_in_review  integer;
  v_groups     integer;
  v_request    public.account_deletion_requests%rowtype;
begin
  if v_user is null then
    raise exception 'No hay sesion iniciada' using errcode = '28000';
  end if;

  select count(*), coalesce(sum(amount_usd), 0)
    into v_due_count, v_due_amount
  from public.installments
  where user_id = v_user
    and status = 'pending';

  select count(*)
    into v_in_review
  from public.payment_reports
  where user_id = v_user
    and status in ('reported', 'in_review');

  -- Los grupos abiertos de los que no ha salido: en ellos todavía le pueden
  -- cargar una cuenta. Se cumple saliendo, o a las 10:00 siguientes al primer
  -- pago del grupo.
  select count(*)
    into v_groups
  from public.group_members gm
  join public.groups g on g.id = gm.group_id
  where gm.user_id = v_user
    and gm.left_at is null
    and public.helios_group_is_open(g.business_date);

  select * into v_request
  from public.account_deletion_requests
  where user_id = v_user
    and status = 'pending';

  return jsonb_build_object(
    'can_request',
      v_due_count = 0 and v_in_review = 0 and v_groups = 0 and v_request.id is null,
    'due_count',          v_due_count,
    'due_amount_usd',     v_due_amount,
    'payments_in_review', v_in_review,
    'open_groups',        v_groups,
    'pending_request',
      case when v_request.id is null then null else jsonb_build_object(
        'id',           v_request.id,
        'requested_at', v_request.requested_at
      ) end
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_group_metrics(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today  date := public.helios_business_date(now());
  v_from   date;
  v_to     date;
  v_days   integer;
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select w.desde, w.hasta, w.dias into v_from, v_to, v_days
  from public.helios_growth_window(p_from, p_to) w;

  with
  -- Un grupo es de prueba si lo es quien lo creó: no hay bandera propia y no
  -- hace falta, porque un grupo sin cargos no entra en ninguna cifra de aquí.
  grupos as (
    select g.id, g.name, g.created_at, g.business_date,
           public.helios_business_date(g.created_at) as dia
    from public.groups g
    join public.profiles p on p.id = g.created_by and not p.is_test
  ),
  miembros as (
    select gm.group_id, count(*)::int as n
    from public.group_members gm
    join grupos g on g.id = gm.group_id
    where gm.status <> 'left'
    group by 1
  ),
  -- Los cargos de la ventana, marcados con si fueron de grupo. `payers` sale
  -- de las cuotas: es entre cuánta gente se repartió esa cuenta de verdad, no
  -- cuánta gente hay apuntada en el grupo.
  cargos as (
    select c.id, c.group_id, c.business_date as dia,
           coalesce(c.base_usd, c.amount_usd) as fin,
           (select count(distinct i.user_id)
            from public.installments i where i.charge_id = c.id)::int as payers
    from public.charges c
    where c.status = 'confirmed' and not c.is_test
      and c.business_date between v_from and v_to
  )
  select jsonb_build_object(
    'business_date', v_today,
    -- El rango QUE SE USÓ, no el que se pidió: la pantalla lo pinta, y si el
    -- servidor recortó el «hasta» a hoy hay que verlo ahí y no descubrirlo
    -- comparando barras.
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,

    'groups', jsonb_build_object(
      'total',     (select count(*) from grupos),
      'created',   (select count(*) from grupos where dia between v_from and v_to),
      -- Los abiertos —esperando su primer pago o de esta noche—, sea cual
      -- sea la ventana: es una foto de ahora.
      'open',      (select count(*) from grupos where public.helios_group_is_open(business_date)),
      -- Grupos que pusieron al menos una cuenta en la ventana. Un grupo creado
      -- y nunca usado es el fracaso silencioso de esta función.
      'with_spend', (select count(distinct group_id) from cargos where group_id is not null),
      'avg_members', (select coalesce(round(avg(n), 1), 0) from miembros)
    ),

    -- Grupo contra individual, en las dos monedas que importan: cuántas
    -- cuentas y cuánto dinero.
    'split', jsonb_build_object(
      'group_charges',  (select count(*) from cargos where group_id is not null),
      'solo_charges',   (select count(*) from cargos where group_id is null),
      'group_financed', (select coalesce(sum(fin), 0) from cargos where group_id is not null),
      'solo_financed',  (select coalesce(sum(fin), 0) from cargos where group_id is null),
      'group_avg_usd',  (select coalesce(round(avg(fin), 2), 0) from cargos where group_id is not null),
      'solo_avg_usd',   (select coalesce(round(avg(fin), 2), 0) from cargos where group_id is null),
      'avg_payers',     (select coalesce(round(avg(payers), 2), 0) from cargos where group_id is not null)
    ),

    'series', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.day)
      from (
        select (v_from + k)              as day,
               coalesce(gc.n, 0)::int    as groups_created,
               coalesce(ca.n, 0)::int    as group_charges,
               coalesce(ca.f, 0)         as group_financed_usd
        from generate_series(0, v_days - 1) as g(k)
        left join (
          select dia, count(*) as n from grupos
          where dia between v_from and v_to group by 1
        ) gc on gc.dia = v_from + k
        left join (
          select dia, count(*) as n, sum(fin) as f from cargos
          where group_id is not null group by 1
        ) ca on ca.dia = v_from + k
      ) s
    ), '[]'::jsonb),

    'top', coalesce((
      select jsonb_agg(jsonb_build_object(
        'group_id',     t.id,
        'name',         t.name,
        'members',      coalesce(m.n, 0),
        'charges',      t.cuentas,
        'financed_usd', t.financiado
      ) order by t.financiado desc)
      from (
        select g.id, g.name,
               count(ca.id)::int         as cuentas,
               coalesce(sum(ca.fin), 0)  as financiado
        from grupos g
        join cargos ca on ca.group_id = g.id
        group by g.id, g.name
        order by 4 desc
        limit 10
      ) t
      left join miembros m on m.group_id = t.id
    ), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$function$;

-- ── 9. Los compañeros que se ven ───────────────────────────────────────────
-- `group_members.business_date` es una copia; la que decide es la del grupo.

create or replace function public.my_group_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.group_id
  from public.group_members m
  join public.groups g on g.id = m.group_id
  where m.user_id = auth.uid()
    and m.left_at is null
    and public.helios_group_is_open(g.business_date);
$$;

-- ── 10. El aviso editable ──────────────────────────────────────────────────
-- `join_group` redacta su propio aviso y no lee esta plantilla, pero el panel
-- la enseña en Avisos: que no prometa una hora que un grupo sin pagos no
-- tiene. Solo si nadie la cambió.

update public.notification_templates
set default_body = 'Ya son {personas}. Lo que pague cualquiera se reparte entre todos.'
where key = 'group_charge.entra'
  and default_body = 'Ya son {personas}. Lo que pague cualquiera se reparte entre todos hasta las 10 AM.';
