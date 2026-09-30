-- ============================================================================
-- Ronda — Entrar enseña las cuentas, no solo el total
--
-- Desde el 2026-09-03 tocar "Entrar al grupo" crea deuda en el acto: es el
-- único sitio de la app donde alguien asume dinero SIN VER la cuenta de la que
-- sale. Lo que la pantalla podía enseñar era "Asumes ahora, de 2 cuentas ·
-- $23,50", porque es lo único que el servidor le mandaba.
--
-- "De 2 cuentas" obliga a confiar. "Bar Central $48 → $12" se comprueba con la
-- mesa que está delante, que es la única verificación que esa persona tiene a
-- mano y la que decide si pone el PIN. Y la cuenta que NO entra —la de $6 que
-- no admite a uno más— pasa de ser un párrafo con paréntesis a una fila
-- tachada, que es lo que de verdad evita que un "$0,00" en el detalle del
-- grupo se lea después como un fallo.
--
-- Por lo mismo viajan los NOMBRES de quienes ya están dentro. La pantalla
-- decía "3 personas dentro", y un código tecleado mal cae casi siempre en "no
-- existe" pero puede caer en otro grupo real: ver "AN · LM · RP" es lo que
-- distingue el grupo de tus amigos del de unos desconocidos, y es la única
-- comprobación posible antes de asumir su deuda. Un número no la permite.
--
-- Esto no cambia ni un céntimo del reparto: el plan ya calculaba la parte de
-- cada cuenta una por una —la capacidad se va gastando en orden, y el orden es
-- fijo— y lo que hacía era sumarlas y tirar el desglose. Aquí solo se deja de
-- tirar.
--
-- ── Por qué el desglose viaja desde el plan y no se recalcula en la pantalla ─
--
-- Por lo mismo que el total: la peor versión posible de esta pantalla es una
-- que diga que te toca $12 y un PIN que te cobre $14. El plan es la MISMA
-- función que ejecuta la entrada de verdad (`helios_group_join_plan`), así que
-- el desglose que se enseña sale del mismo bucle que la cifra que se cobra.
-- Rehacer la cascada en el cliente sería una segunda implementación de la
-- regla más delicada del producto.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El plan de entrada, con el desglose que ya calculaba
-- ---------------------------------------------------------------------------
/**
 * Cuerpo de 20260903000000 más `charges`. Todo lo demás es idéntico, y el
 * comentario de aquel archivo sigue siendo la explicación de por qué una
 * cuenta se salta y otra bloquea.
 *
 * Las filas van en ORDEN DE CONSUMO, el mismo del bucle, y por el mismo motivo
 * por el que el bucle lo tiene fijo: la capacidad de quien entra se va gastando
 * cuenta a cuenta, así que "la primera" y "la última" no son intercambiables.
 * Enseñarlas en ese orden es enseñar por qué a la de las 2 AM le tocó menos.
 *
 * Las saltadas van EN LA MISMA LISTA y no en un recuento aparte. Son parte de
 * lo que pasó esa noche, y sacarlas de la lista para contarlas en una frase es
 * exactamente lo que había antes.
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

    v_split := public.helios_split_shares(v_row.base_usd, v_parts);

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
        'blocking_split_between', v_n + 1
      );
    end if;

    v_mine_pay := coalesce(
      (public.helios_payables(v_split->'shares', v_row.base_usd, v_row.amount_usd)
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

revoke all on function public.helios_group_join_plan(uuid, uuid) from public, anon, authenticated;

comment on function public.helios_group_join_plan(uuid, uuid) is
  'Lo que asumiría alguien al entrar al grupo ahora mismo, cuenta por cuenta. No escribe. Ver docs/00-BASES 2.7.4.';

-- ---------------------------------------------------------------------------
-- 2. Buscar el grupo: el desglose viaja con el total
-- ---------------------------------------------------------------------------
/**
 * Cuerpo de 20260903000000 más `retro_charges`, que es el `charges` del plan
 * tal cual.
 *
 * Sigue sin comprometer nada —esto no escribe— y sigue sin decir de más: son
 * las cuentas de un grupo al que se está a punto de entrar con un código
 * válido, que es el mismo permiso con el que se ven un segundo después en el
 * detalle.
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
    'member_names', (
      select coalesce(jsonb_agg(p.full_name order by m.joined_at), '[]'::jsonb)
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

comment on function public.find_group_by_code(text) is
  'Buscar un grupo por su código: quién está, qué lleva gastado cuenta por cuenta, y qué te tocaría al entrar. No escribe.';
