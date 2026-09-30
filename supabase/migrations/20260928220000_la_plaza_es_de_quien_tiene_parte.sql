-- ============================================================================
-- Ronda — La plaza es de quien tiene parte de una cuenta
--
-- El tope de `max_group_members()` contaba solo a los que siguen dentro
-- (`left_at is null`). Salir no borra la deuda —lo ya asumido sigue siendo
-- tuyo—, así que quien salía con parte de una cuenta liberaba su plaza y
-- seguía dentro del reparto. El siguiente en entrar se repartía esa cuenta con
-- él: la orden #1062 (26-09, producción) acabó repartida entre 6 con un tope
-- de 5.
--
-- ── La regla ───────────────────────────────────────────────────────────────
--
-- Ocupa plaza quien está dentro O tiene cuotas en alguna cuenta del grupo.
-- Con `max_group_members()` plazas ocupadas no entra nadie nuevo. Quien ya
-- tiene la suya puede volver: no suma una persona más al reparto.
--
-- Así ninguna cuenta del grupo pasa de `max_group_members()` personas: el
-- reparto retroactivo al entrar incluye a quienes ya tienen parte, y todos
-- ellos ocupan plaza.
--
-- Quien sale sin haber asumido nada sí libera su plaza.
--
-- `member_count` y el «Ya son N» del aviso siguen contando a los de dentro:
-- es lo que ve la gente en la pantalla del grupo.
--
-- Cuerpos: los vigentes en dev y prod (idénticos) salvo el conteo del tope.
-- ============================================================================

-- ── 1. Quién ocupa plaza ────────────────────────────────────────────────────

create or replace function public.helios_group_seat_holders(p_group_id uuid)
returns table (user_id uuid)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.user_id
  from public.group_members m
  where m.group_id = p_group_id and m.left_at is null
  union
  select i.user_id
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where c.group_id = p_group_id
$$;

comment on function public.helios_group_seat_holders(uuid) is
  'Quienes ocupan plaza en un grupo: los que están dentro y los que tienen cuotas en alguna de sus cuentas. Es lo que cuenta contra max_group_members().';

-- Solo la llaman join_group y find_group_by_code, que son security definer:
-- desde fuera daría los integrantes de cualquier grupo.
revoke all on function public.helios_group_seat_holders(uuid) from public, anon, authenticated;

-- ── 2. Entrar ───────────────────────────────────────────────────────────────

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
  v_seats  integer;
  v_mine   boolean;
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
    and public.helios_group_is_open(business_date, created_at)
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

  -- El tope cuenta plazas, no gente dentro: ver la cabecera de 20260928220000.
  -- Quien ya tiene la suya —salió con parte de una cuenta— vuelve a ella.
  select count(*), coalesce(bool_or(h.user_id = v_user), false)
    into v_seats, v_mine
  from public.helios_group_seat_holders(v_group.id) h;

  if v_seats >= public.max_group_members() and not v_mine then
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


-- ── 3. La pantalla de entrar ────────────────────────────────────────────────

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
  v_seats integer;
  v_mine  boolean;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_group from public.groups
  where invite_code = upper(trim(p_code))
    and public.helios_group_is_open(business_date, created_at)
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

  -- El mismo conteo que join_group: si solo uno lo supiera, la pantalla diría
  -- que cabes y el PIN te rebotaría.
  select count(*), coalesce(bool_or(h.user_id = v_user), false)
    into v_seats, v_mine
  from public.helios_group_seat_holders(v_group.id) h;

  if v_seats >= public.max_group_members() and not v_mine then
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
