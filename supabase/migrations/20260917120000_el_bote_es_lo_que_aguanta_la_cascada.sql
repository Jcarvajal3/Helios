-- ============================================================================
-- Ronda — El bote es lo que aguanta la cascada
--
-- `group_pot_usd` decía cuánto puede cubrir un grupo, y lo calculaba como
-- **el que menos puede × integrantes**. Esa es la aritmética del REPARTO
-- PAREJO, que dejó de existir el 2026-08-30: desde entonces se reparte en
-- cascada —quien no llega pone su techo y lo que falte se reparte otra vez
-- entre los demás (docs/00 §2.7.1)—, y la cascada llega hasta la SUMA de lo
-- que pueden poner todos.
--
--   Grupo "F": A puede €11 · B puede €5      cuenta de €15
--
--     bote viejo   min(11, 5) × 2 = 10   → "al grupo no le llega"
--     cascada      λ = 7,50 → B se topa en 5 → λ = 10 → A pone 10 ✅
--
-- Las dos personas podían pagar, ninguna se pasaba de su techo, y la app las
-- paraba con una cifra —€10— que no significa nada: ni es lo que hay puesto,
-- ni es lo que se puede gastar. `preview_group_charge` habría repartido esa
-- cuenta sin pestañear; el bote era el único que decía que no.
--
-- ── Lo que cambia ──────────────────────────────────────────────────────────
--
--   · `group_pot_usd` pasa a ser la suma de las capacidades de quienes DE
--     VERDAD reparten: los que no deben nada y llegan al mínimo por persona.
--     Quien tiene menos de €2,50 queda fuera del reparto, así que su capacidad
--     no se puede gastar y no cuenta (es la regla de `helios_split_shares`).
--   · `min_charge_usd` en `my_groups` se cuenta sobre esa misma gente. Era
--     `todos los que no deben × €2,50`, e incluía a quien la cascada deja
--     fuera: pedía un mínimo mayor del que el servidor exige.
--     ⚠️ La app nueva ya no lee ese campo —el mínimo depende de QUIÉNES
--     reparten y eso lo sabe su cascada (`features/groups/fit.ts`)—, pero los
--     binarios ya instalados sí lo leen hasta que actualicen, y a ellos les
--     llegaba mal. Por eso se corrige aquí en vez de dejar de mandarlo.
--   · El rechazo al ENTRAR a un grupo viaja también con la cuenta en cupo
--     (`blocking_financed_usd`, por `helios_group_join_plan` y
--     `find_group_by_code`). Solo llevaba el total con el fee dentro, así que
--     el mensaje —"de una cuenta de €48 entre 3 te tocarían €16"— enseñaba un
--     importe con el servicio sumado y lo dividía a partes iguales, que no es
--     como reparte la cascada.
--   · `preview_group_charge` manda `min_share_usd`. El reparto tenía el motivo
--     de cada excluido en clave (`no_capacity`) y lo traducía a "se le acabó el
--     aporte máximo" incluso para quien tenía €1 sin tocar: lo que le pasa es
--     que no llega al mínimo por persona, y para decirlo hace falta la cifra.
--
-- Con esto, las tres cifras que puede enseñar una pantalla de grupo —el
-- centro del anillo, el bote y lo que la cascada admite— vuelven a ser el
-- mismo número.
--
-- ── Lo que NO cambia ───────────────────────────────────────────────────────
--
-- El reparto. `helios_split_shares` ya repartía así y sigue igual; esto es la
-- cifra que se mira ANTES, que era la única que se había quedado atrás.
--
-- Los cuerpos de `my_groups`, `helios_group_join_plan` y `find_group_by_code`
-- son los de su última migración salvo lo dicho.
-- ============================================================================

-- ── 1. El bote ─────────────────────────────────────────────────────────────

/**
 * Lo que el grupo puede poner entre todos en una cuenta.
 *
 * Es la SUMA de lo que puede cada quien, porque el reparto en cascada llega
 * hasta ahí: topa a quien no alcanza y reparte lo que falte entre los demás,
 * sin pasarse del techo de nadie.
 *
 * Solo cuenta quien entra al reparto: sin cuotas vencidas —si no, no puede
 * asumir deuda— y con al menos el mínimo por persona, porque a quien le queda
 * menos se le deja fuera para no generarle cuotas de €0,90.
 */
create or replace function public.group_pot_usd(p_group_id uuid)
returns numeric
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce(sum(capacity_usd), 0)
  from public.group_participants(p_group_id)
  where can_take_debt
    and capacity_usd >= public.min_share_usd();
$$;

revoke all on function public.group_pot_usd(uuid) from public, anon, authenticated;

-- ── 2. Mis grupos ──────────────────────────────────────────────────────────

create or replace function public.my_groups()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user  uuid := auth.uid();
  v_bdate date := public.helios_business_date(now());
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
      'closes_at',   public.helios_business_day_end(g.business_date),
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
    where g.business_date = v_bdate
  ) s;

  return v_rows;
end;
$$;

revoke all on function public.my_groups() from public, anon;
grant execute on function public.my_groups() to authenticated;

-- ── 3. El bloqueo al entrar dice la cuenta EN CUPO ─────────────────────────

/**
 * Lo que asumes al entrar a un grupo.
 *
 * Cuando el plan se atasca, el rechazo viaja con la cuenta que lo atascó para
 * que la pantalla pueda decir cuánto falta en vez de solo que no alcanza. Esa
 * cuenta viajaba SOLO con el fee dentro, así que el único importe que la app
 * podía enseñar ahí era un total con el servicio sumado — y encima dividido a
 * partes iguales, que no es como reparte la cascada. Ahora va también en cupo.
 *
 * Cuerpo idéntico al de `20260911100000` salvo esas dos claves.
 */
create or replace function public.helios_group_join_plan(p_group_id uuid, p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_avail       numeric(18,4) := public.available_usd(p_user);
  v_assigned    numeric(18,4) := 0;
  v_payable     numeric(18,4) := 0;
  v_count       integer := 0;
  v_skipped     integer := 0;
  v_skipped_usd numeric(18,4) := 0;
  v_row         record;
  v_deb         record;
  v_parts       jsonb;
  v_split       jsonb;
  v_mine        numeric(18,4);
  v_mine_pay    numeric(18,4);
  v_n           integer;
  v_charges     jsonb := '[]'::jsonb;
  v_merchant    text;
begin
  for v_row in select * from public.helios_group_open_charges(p_group_id, p_user) loop
    v_parts := '[]'::jsonb;
    v_n     := 0;

    -- El nombre del local, que es por lo que la mesa reconoce una cuenta. Un
    -- `order_number` no le dice nada a nadie de pie en una barra.
    select m.name into v_merchant
    from public.charges c
    join public.merchants m on m.id = c.merchant_id
    where c.id = v_row.charge_id;

    -- La capacidad de quien ya debía es su parte actual. Ver la cabecera de
    -- 20260903000000: da el mismo reparto que volver a mirarle el saldo y hace
    -- imposible generarle deuda a alguien que no está delante del teléfono.
    for v_deb in select * from public.charge_debtors(v_row.charge_id) loop
      v_parts := v_parts || jsonb_build_object(
        'user_id', v_deb.user_id, 'capacity_usd', v_deb.financed_usd
      );
      v_n := v_n + 1;
    end loop;

    v_parts := v_parts || jsonb_build_object(
      'user_id', p_user, 'capacity_usd', greatest(v_avail - v_assigned, 0)
    );

    -- El céntimo suelto es de quien puso ESTA cuenta, no de quien entra.
    v_split := public.helios_split_shares(v_row.base_usd, v_parts, v_row.payer_id);

    /**
     * ESTA CUENTA NO DA PARA UNO MÁS. Se salta, no se bloquea.
     *
     * `too_small` significa exactamente eso y solo eso: el total no llega a
     * `(deudores + 1) × $2,50`. No puede venir de los deudores viejos —sus
     * partes ya cumplen el mínimo, por construcción— así que el que sobra es
     * siempre el que quiere entrar.
     *
     * Se comprueba ANTES que `ok`, porque `reason` solo viene cuando falló.
     */
    if v_split->>'reason' = 'too_small' then
      v_skipped     := v_skipped + 1;
      v_skipped_usd := v_skipped_usd + v_row.amount_usd;
      v_charges     := v_charges || jsonb_build_object(
        'charge_id',    v_row.charge_id,
        'merchant_name', coalesce(v_merchant, 'Un local'),
        'amount_usd',   v_row.amount_usd,
        'financed_usd', v_row.base_usd,
        'my_payable_usd', null::numeric,
        'skipped',      true
      );
      continue;
    end if;

    if not coalesce((v_split->>'ok')::boolean, false) then
      return jsonb_build_object(
        'ok', false,
        'reason', 'no_capacity',
        'blocking_amount_usd', v_row.amount_usd,
        -- Lo que ocupa esa cuenta de CUPO. Es la cifra que enseña la pantalla:
        -- el total lleva el fee dentro y un importe con el servicio sumado no
        -- se enseña suelto en ninguna parte.
        'blocking_financed_usd', v_row.base_usd,
        'blocking_split_between', v_n + 1
      );
    end if;

    select (s->>'share_usd')::numeric into v_mine
    from jsonb_array_elements(v_split->'shares') s
    where (s->>'user_id')::uuid = p_user;

    -- Se quedó fuera de ESTA cuenta por no llegar al mínimo con lo que le
    -- queda. Entrar sería entrar a medias, así que no entra.
    if v_mine is null then
      return jsonb_build_object(
        'ok', false,
        'reason', 'no_capacity',
        'blocking_amount_usd', v_row.amount_usd,
        -- Lo que ocupa esa cuenta de CUPO. Es la cifra que enseña la pantalla:
        -- el total lleva el fee dentro y un importe con el servicio sumado no
        -- se enseña suelto en ninguna parte.
        'blocking_financed_usd', v_row.base_usd,
        'blocking_split_between', v_n + 1
      );
    end if;

    v_mine_pay := coalesce(
      (public.helios_payables(v_split->'shares', v_row.base_usd, v_row.amount_usd,
                             v_row.payer_id)
        ->>p_user::text)::numeric, 0);

    v_assigned := v_assigned + v_mine;
    v_payable  := v_payable + v_mine_pay;
    v_count    := v_count + 1;

    -- Lo que se paga, no lo que se financia: es la cifra que aparece en las
    -- cuotas, y por tanto la única que se puede comprobar después. Las dos
    -- difieren en el fee del servicio (20260830190000).
    v_charges := v_charges || jsonb_build_object(
      'charge_id',    v_row.charge_id,
      'merchant_name', coalesce(v_merchant, 'Un local'),
      'amount_usd',   v_row.amount_usd,
      'financed_usd', v_row.base_usd,
      'my_payable_usd', v_mine_pay,
      'skipped',      false
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'charge_count', v_count,
    'financed_usd', v_assigned,
    'payable_usd', v_payable,
    -- Las que se quedaron fuera por pequeñas. La pantalla de entrada las dice:
    -- quien entra tiene derecho a saber de qué NO va a ser parte.
    'skipped_charge_count', v_skipped,
    'skipped_usd', v_skipped_usd,
    -- NUEVO: el desglose, en orden de consumo y con las saltadas dentro.
    'charges', v_charges
  );
end;
$$;

revoke all on function public.helios_group_join_plan(uuid, uuid)
  from public, anon, authenticated;

-- ── 4. Y el buscador lo deja pasar ─────────────────────────────────────────

/**
 * Buscar un grupo por su código.
 *
 * Solo reenvía la clave nueva del plan: sin esto, `blocking_financed_usd` se
 * queda dentro de `helios_group_join_plan` y la pantalla no la ve.
 *
 * Cuerpo idéntico al de `20260911160000` salvo esa clave.
 */
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

-- ── 5. El reparto dice cuál es el mínimo por persona ───────────────────────

/**
 * Lo que se enseña antes del PIN.
 *
 * Manda `min_share_usd` para que el reparto pueda explicar por qué alguien se
 * queda fuera. La pantalla solo tenía el motivo en clave —`no_capacity`— y lo
 * traducía a "se le acabó el aporte máximo", que no es lo que pasa: lo que
 * pasa es que le quedan menos de €2,50 y esa es la parte más pequeña que se
 * puede generar. Sin la cifra del servidor, la app solo podía copiarla.
 *
 * Cuerpo idéntico al de `20260909200000` salvo esa clave.
 */
create or replace function public.preview_group_charge(
  p_charge_id uuid,
  p_group_id  uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
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

  -- Repartir en un grupo de anoche no significa nada, y era además por donde se
  -- leía la capacidad de crédito de gente de un grupo ya muerto.
  if v_group.business_date <> public.helios_business_date(now()) then
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
    'closes_at',     public.helios_business_day_end(v_group.business_date),
    'amount_usd',    v_charge.amount_usd,
    -- NUEVO: lo que se reparte contra el cupo, y lo mío en las dos monedas.
    'financed_usd',  v_financed,
    'split_between', v_split->'split_between',
    'capacity_usd',  v_split->'capacity_usd',
    'min_total_usd', v_split->'min_total_usd',
    'even_share_usd', case when v_eligible > 0
      then round(v_financed / v_eligible, 2) else null end,
    -- El suelo por persona, para que la pantalla pueda DECIRLO cuando deja a
    -- alguien fuera. "Se le acabó el aporte máximo" no era ni el motivo.
    'min_share_usd', public.min_share_usd(),
    'my_share_usd',  v_my,
    'my_payable_usd', v_my_pay,
    'members',       v_rows
  );
end;
$$;

revoke all on function public.preview_group_charge(uuid, uuid) from public, anon;
grant execute on function public.preview_group_charge(uuid, uuid) to authenticated;
