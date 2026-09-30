-- ============================================================================
-- Ronda — Volver a un grupo donde ya pusiste
--
-- Salir de un grupo no borra la deuda: es individual, y las cuentas que ya
-- pagaste siguen siendo tuyas. Por eso volver a entrar NO cobra nada otra vez
-- —`helios_group_open_charges` deja fuera las cuentas donde ya tienes cuotas— y
-- eso funciona desde siempre.
--
-- Lo que no funcionaba era decirlo. La pantalla de entrar solo sabe de lo que
-- vas a ASUMIR, así que en este caso se quedaba muda y ofrecía la barra del
-- aporte a secas, justo en el momento en que la pregunta del usuario es "¿me
-- van a volver a cobrar lo que ya pagué?".
--
-- `find_group_by_code` pasa a mandar `settled_charges`: las cuentas de ese
-- grupo de las que YA soy deudor, con su número de orden, lo que consumí y mi
-- parte —de las CUOTAS que se escribieron entonces, no de un reparto nuevo—.
--
-- El plan de entrada no se toca: lo que decide quién paga qué sigue igual.
--
-- Cuerpo idéntico al de `20260917120000` salvo esa clave.
-- ============================================================================

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
$$;

revoke all on function public.find_group_by_code(text) from public, anon;
grant execute on function public.find_group_by_code(text) to authenticated;
