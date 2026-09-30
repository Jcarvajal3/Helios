-- ============================================================================
-- Ronda — El gasto se divide SIEMPRE entre todos
--
-- Decisión del 2026-08-24. Hasta aquí `confirm_charge_as_group` recibía un
-- `p_user_ids` con quiénes entraban en el reparto, y la app lo alimentaba con
-- unas casillas que dejaban marcar y desmarcar gente.
--
-- Eso venía del modelo de topes propios, donde cada quien tenía un máximo
-- distinto y sacar del reparto al que venía corto era LA solución (así estaba
-- escrito en docs/00 §2.7). Con el ticket de entrada dejó de tener sentido y
-- pasó a ser un agujero: todos ponen lo mismo, así que quitar a alguien solo
-- SUBE la parte de los demás — y quien iniciaba podía quitarse a sí mismo y
-- cargarle a los otros un consumo que él no se llevaba.
--
-- A partir de aquí no hay nada que elegir: el servidor decide quiénes pagan y
-- son todos. El cliente ya no manda la lista, así que el abuso no es que esté
-- prohibido — es que no se puede expresar.
--
-- ---------------------------------------------------------------------------
-- La única exclusión que queda, y es automática
-- ---------------------------------------------------------------------------
-- Quien tiene una cuota vencida no puede tomar deuda nueva: la base se niega.
-- Incluirlo tumbaría el cobro entero, así que una sola cuota vencida de un
-- amigo paralizaría la noche de los otros siete. Se le excluye solo, sin que
-- nadie decida nada, y su ticket queda intacto para devolvérselo al cerrar.
--
-- Y por el mismo motivo tampoco puede entrar ni crear grupos: comprometer un
-- ticket que después no se le va a poder cobrar es retenerle un saldo para
-- nada.
--
-- ---------------------------------------------------------------------------
-- El bote deja de ser una suma
-- ---------------------------------------------------------------------------
-- Con reparto a partes iguales manda el que menos tiene. Si A y B llevan $10 y
-- C entró tarde con $30, la suma dice $50 pero el grupo solo puede gastar $30
-- ($10 cada uno). La capacidad real es `mínimo × integrantes`, y es lo que
-- pasan a devolver `my_groups` y `preview_group_charge`. Sumar prometía un
-- dinero que no se podía gastar.
-- ============================================================================

/**
 * ¿Puede esta persona asumir deuda nueva?
 *
 * Dos cosas, y hacen falta las dos. `profiles.status` lo pone el motor de mora,
 * que corre UNA vez al día (10:05, ver 20260822059000_ledger_cron): entre que
 * una cuota vence y el barrido lo escribe, el perfil sigue diciendo 'active'.
 * Por eso se mira también la cuota directamente — así la regla es cierta por
 * construcción y no porque el cron esté vivo.
 *
 * El criterio de "vencida" es EL MISMO que usa `process_mora`, a propósito: si
 * los dos sitios no coinciden, alguien acaba congelado por una regla y cobrado
 * por la otra.
 */
create or replace function public.can_take_debt(p_user uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select
    exists (select 1 from public.profiles where id = p_user and status = 'active')
    and not exists (
      select 1 from public.installments
      where user_id = p_user
        and status = 'pending'
        and due_date < public.helios_business_date(now())
    );
$$;

revoke all on function public.can_take_debt(uuid) from public, anon;
grant execute on function public.can_take_debt(uuid) to authenticated;

-- La firma cambia (se va `p_user_ids`), así que hay que tirar la vieja: si no,
-- las dos conviven y un cliente sin actualizar seguiría eligiendo a dedo.
drop function if exists public.confirm_charge_as_group(uuid, uuid, uuid[], text);

/**
 * Crear un grupo. Una sola decisión: cuánto pone cada quien.
 *
 * Quien lo crea entra ya aceptado —fijar el ticket es aceptarlo—, sin ningún
 * privilegio sobre los demás salvo poder cerrar el grupo. Crear también
 * RETIENE: si no le alcanza el saldo para su propio ticket, el grupo no
 * llega a existir.
 */
create or replace function public.create_group(
  p_name             text,
  p_entry_amount_usd numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_group public.groups%rowtype;
  v_avail numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if not public.can_take_debt(v_user) then
    raise exception 'No puedes crear un grupo con cuotas vencidas' using errcode = '22023';
  end if;

  if coalesce(trim(p_name), '') = '' then
    raise exception 'El grupo necesita un nombre' using errcode = '22023';
  end if;

  if p_entry_amount_usd < 2.50 then
    raise exception 'El ticket de entrada no puede bajar de $2,50' using errcode = '22023';
  end if;

  v_avail := (public.my_available_balance()->>'available_usd')::numeric;

  if v_avail < p_entry_amount_usd then
    raise exception 'Tu ticket sería de $% y tienes $% disponibles',
      p_entry_amount_usd, v_avail
      using errcode = '22023';
  end if;

  insert into public.groups (name, created_by, entry_amount_usd, invite_code)
  values (trim(p_name), v_user, p_entry_amount_usd, public.generate_invite_code())
  returning * into v_group;

  insert into public.group_members
    (group_id, user_id, reserved_usd, consumed_usd, authorized_at)
  values (v_group.id, v_user, p_entry_amount_usd, 0, now());

  return jsonb_build_object(
    'group_id', v_group.id,
    'name', v_group.name,
    'invite_code', v_group.invite_code,
    'entry_amount_usd', v_group.entry_amount_usd
  );
end;
$$;

revoke all on function public.create_group(text, numeric) from public, anon;
grant execute on function public.create_group(text, numeric) to authenticated;

/**
 * Aceptar el ticket y entrar.
 *
 * Aquí ocurre TODO el consentimiento del grupo: a partir de este instante
 * pueden cargarte tu parte sin preguntarte, y por eso este acto retiene el
 * ticket completo. De ahí en adelante no hay ninguna cifra que elegir.
 *
 * Volver a entrar después de haber salido concede un ticket nuevo. No es la
 * recarga que se descartó: quien sale pierde su sitio y necesita el código
 * otra vez, y vuelve a pasar por la pantalla de aceptación con el importe
 * delante.
 */
create or replace function public.join_group(p_invite_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_group public.groups%rowtype;
  v_count integer;
  v_avail numeric(18,4);
  v_mine  public.group_members%rowtype;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if not public.can_take_debt(v_user) then
    raise exception 'No puedes entrar a un grupo con cuotas vencidas' using errcode = '22023';
  end if;

  select * into v_group from public.groups
  where invite_code = upper(trim(p_invite_code));

  if not found then
    raise exception 'Ese código no corresponde a ningún grupo' using errcode = 'P0002';
  end if;

  if v_group.status <> 'active' then
    raise exception 'Ese grupo ya está cerrado' using errcode = '22023';
  end if;

  select * into v_mine from public.group_members
  where group_id = v_group.id and user_id = v_user;

  if found and v_mine.status = 'active' then
    raise exception 'Ya estás en este grupo' using errcode = '22023';
  end if;

  select count(*) into v_count from public.group_members
  where group_id = v_group.id and status = 'active';

  if v_count >= 8 then
    raise exception 'El grupo ya tiene 8 integrantes' using errcode = '22023';
  end if;

  v_avail := (public.my_available_balance()->>'available_usd')::numeric;

  if v_avail < v_group.entry_amount_usd then
    raise exception 'El ticket es de $% y tienes $% disponibles',
      v_group.entry_amount_usd, v_avail
      using errcode = '22023';
  end if;

  insert into public.group_members
    (group_id, user_id, reserved_usd, consumed_usd, released_at, authorized_at, status)
  values
    (v_group.id, v_user, v_group.entry_amount_usd, 0, null, now(), 'active')
  on conflict (group_id, user_id) do update
    set status       = 'active',
        reserved_usd = excluded.reserved_usd,
        consumed_usd = 0,
        released_at  = null,
        authorized_at = now();

  return jsonb_build_object(
    'group_id', v_group.id,
    'name', v_group.name,
    'entry_amount_usd', v_group.entry_amount_usd,
    'reserved_usd', v_group.entry_amount_usd
  );
end;
$$;

revoke all on function public.join_group(text) from public, anon;
grant execute on function public.join_group(text) to authenticated;

/**
 * Los grupos de los que formo parte, con el estado del bote.
 *
 * `pot_usd` —la suma de lo que le queda a cada integrante activo— es el dato
 * que decide si una cuenta se puede pagar con el grupo, así que va calculado
 * aquí y no reconstruido en la app.
 */
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
      g.entry_amount_usd,
      g.status,
      (g.created_by = v_user) as is_creator,
      me.status as my_status,
      me.reserved_usd as my_reserved_usd,
      me.consumed_usd as my_consumed_usd,
      case when me.released_at is null
           then me.reserved_usd - me.consumed_usd
           else 0
      end as my_remaining_usd,
      (me.released_at is not null) as my_released,
      me.joined_at,
      (
        select count(*) from public.group_members m
        where m.group_id = g.id and m.status = 'active'
      ) as member_count,
      -- El bote NO es la suma de lo que queda: con reparto a partes iguales
      -- manda el que menos tiene, así que la capacidad real del grupo es
      -- (mínimo × integrantes). Sumar prometía un dinero que el grupo no
      -- puede gastar — ver 20260824140000.
      (
        select coalesce(min(m.reserved_usd - m.consumed_usd), 0) * count(*)
        from public.group_members m
        where m.group_id = g.id and m.status = 'active' and m.released_at is null
          and public.can_take_debt(m.user_id)
      ) as pot_usd,
      (
        select coalesce(jsonb_agg(jsonb_build_object(
          'user_id', m.user_id,
          'name', p.full_name,
          'status', m.status,
          'remaining_usd', case when m.released_at is null
                                then m.reserved_usd - m.consumed_usd else 0 end
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

/**
 * Confirma el cobro repartiéndolo entre los integrantes indicados.
 *
 * Cada parte sale del ticket de esa persona: baja lo retenido y sube la deuda
 * en la misma cifra, así que su disponible no se mueve. Es la promesa que se
 * le hizo en la pantalla de aceptación — el dinero ya estaba apartado.
 *
 * Si a alguno no le da su ticket, la operación entera se cae con el motivo.
 * Nunca se reparte de más entre los otros: el ticket es también máximo, y
 * cargarle a alguien por encima sería usar una autorización que no dio.
 */
create or replace function public.confirm_charge_as_group(
  p_charge_id       uuid,
  p_group_id        uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_user      uuid := auth.uid();
  v_charge    public.charges%rowtype;
  v_group     public.groups%rowtype;
  v_terms     public.merchant_settlement_terms%rowtype;
  v_count     integer;
  v_share     numeric(18,4);
  v_remainder numeric(18,4);
  v_bdate     date;
  v_due_1     date;
  v_due_2     date;
  v_tx        uuid;
  v_acct_pay  uuid;
  v_acct_rev  uuid;
  v_upfront   numeric(18,4);
  v_revenue   numeric(18,4);
  v_merchant_share numeric(18,4);
  v_member    record;
  v_amount    numeric(18,4);
  v_block     public.user_credit_blocks%rowtype;
  v_limit     numeric(18,4);
  v_i         integer := 0;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  if v_charge.status = 'confirmed' then
    return jsonb_build_object('ok', true, 'charge_id', v_charge.id, 'already_confirmed', true);
  end if;

  if v_charge.status <> 'pending' then
    raise exception 'Este cobro ya no está disponible (%)', v_charge.status using errcode = '22023';
  end if;

  if v_charge.expires_at < now() then
    raise exception 'Este QR caducó, pídele al local que genere uno nuevo' using errcode = '22023';
  end if;

  select * into v_group from public.groups where id = p_group_id for update;
  if not found or v_group.status <> 'active' then
    raise exception 'Ese grupo ya está cerrado' using errcode = '22023';
  end if;

  -- Cualquier integrante activo con el ticket vivo puede iniciar un cobro
  -- (decisión del 2026-08-24). Lo que sigue siendo obligatorio comprobar es
  -- que QUIEN LLAMA sea del grupo: sin esta guarda, cualquiera con el uuid
  -- de un grupo podría gastarse el bote de ocho desconocidos.
  if not exists (
    select 1 from public.group_members
    where group_id = p_group_id and user_id = v_user
      and status = 'active' and released_at is null
  ) then
    raise exception 'No perteneces a este grupo' using errcode = '42501';
  end if;

  /**
   * Quiénes pagan: TODOS los que pueden, y no una lista que mande el cliente.
   *
   * Antes llegaba `p_user_ids` y quien iniciaba elegía. Eso era del modelo de
   * topes propios, donde sacar al que venía corto era la única salida. Con el
   * ticket no hay nada que elegir —el gasto se divide siempre entre todos— y
   * dejar la lista abierta permitía que quien inicia se quitara a sí mismo y
   * le cargara a los demás algo que él no se llevaba.
   *
   * Se excluye solo a quien NO PUEDE tomar deuda (cuota vencida): la base se
   * negaría a generársela, así que incluirlo tumbaría el cobro entero y una
   * cuota vencida de un amigo paralizaría la noche de los otros siete.
   */
  select count(*) into v_count
  from public.group_members m
  where m.group_id = p_group_id and m.status = 'active' and m.released_at is null
    and public.can_take_debt(m.user_id);

  if v_count = 0 then
    raise exception 'Nadie del grupo puede asumir este consumo ahora mismo'
      using errcode = '22023';
  end if;

  v_share := round(v_charge.amount_usd / v_count, 4);
  -- El céntimo que sobra del reparto recae en el primer integrante por
  -- user_id (ver el bucle). Da igual a quién le toque mientras sea SIEMPRE el
  -- mismo: lo que no puede pasar es que dos reintentos del mismo cobro
  -- repartan distinto.
  v_remainder := v_charge.amount_usd - (v_share * v_count);

  if v_share < 2.50 then
    raise exception 'La parte de cada quien quedaría en $%, y el mínimo es $2,50', v_share
      using errcode = '22023';
  end if;

  select * into v_terms from public.merchant_settlement_terms
  where merchant_id = v_charge.merchant_id;

  v_bdate := public.helios_business_date(now());
  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_bdate);

  v_acct_pay := ledger.get_or_create_account('merchant_payable', v_charge.merchant_id);
  v_acct_rev := ledger.get_or_create_account('platform_revenue', null);

  v_revenue := round(v_charge.amount_usd * v_terms.commission_pct / 100, 4);
  v_merchant_share := v_charge.amount_usd - v_revenue;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', p_idempotency_key, v_bdate, v_charge.id,
          format('Venta repartida entre %s personas', v_count))
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_pay, 0, v_merchant_share),
    (v_tx, v_acct_rev, 0, v_revenue);

  -- --- Una deuda por integrante, pagada con su ticket ---------------------
  for v_member in
    select m.user_id,
           (m.reserved_usd - m.consumed_usd) as remaining,
           p.status as profile_status,
           p.full_name
    from public.group_members m
    join public.profiles p on p.id = m.user_id
    where m.group_id = p_group_id
      and m.status = 'active' and m.released_at is null
      and public.can_take_debt(m.user_id)
    order by m.user_id
    for update of m
  loop
    v_i := v_i + 1;
    -- El primero de la lista carga con el céntimo sobrante si lo hay; se
    -- ordena por user_id para que el reparto sea determinista.
    v_amount := v_share + (case when v_i = 1 then v_remainder else 0 end);

    if v_member.profile_status <> 'active' then
      raise exception 'La cuenta de % está bloqueada', coalesce(v_member.full_name, 'un integrante')
        using errcode = '22023';
    end if;

    if v_amount > v_member.remaining then
      raise exception 'A % le tocarían $% y de su ticket le quedan $%',
        coalesce(v_member.full_name, 'un integrante'), v_amount, v_member.remaining
        using errcode = '22023';
    end if;

    select monthly_limit_usd into v_limit
    from public.levels l
    join public.profiles p on p.level = l.level
    where p.id = v_member.user_id;

    select * into v_block
    from public.user_credit_blocks
    where user_id = v_member.user_id and closed_at is null
    for update;

    if not found then
      insert into public.user_credit_blocks (user_id) values (v_member.user_id)
      returning * into v_block;
    end if;

    -- Con el ticket ya retenido esto solo salta si el nivel bajó después de
    -- aceptar. Se comprueba igual: el límite del nivel es el tope duro y
    -- ninguna retención puede pasarse de él.
    if v_block.charged_usd + v_amount > v_limit then
      raise exception 'A % le bajó el nivel y su límite ya no cubre $%',
        coalesce(v_member.full_name, 'un integrante'), v_amount
        using errcode = '22023';
    end if;

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, ledger.get_or_create_account('user_receivable', v_member.user_id), v_amount, 0);

    insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
      (v_charge.id, v_member.user_id, 1, round(v_amount / 2, 4), v_due_1),
      (v_charge.id, v_member.user_id, 2, v_amount - round(v_amount / 2, 4), v_due_2);

    -- Lo retenido baja y la deuda sube en la misma cifra: el disponible del
    -- integrante no se mueve, que es lo que se le prometió al entrar.
    update public.group_members
      set consumed_usd = consumed_usd + v_amount
    where group_id = p_group_id and user_id = v_member.user_id;

    update public.user_credit_blocks
      set charged_usd = charged_usd + v_amount
    where id = v_block.id;
  end loop;

  -- --- Adelanto devengado al comercio (sin mover caja) -------------------
  v_upfront := round(v_charge.amount_usd * v_terms.upfront_pct / 100, 4);
  perform ledger.record_advance_settlement(v_charge.merchant_id, v_charge.id, v_upfront, v_bdate);

  update public.charges
    set status = 'confirmed', user_id = v_user, group_id = p_group_id,
        business_date = v_bdate, confirmed_at = now()
  where id = v_charge.id;

  return jsonb_build_object(
    'ok', true,
    'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'split_between', v_count,
    'share_usd', v_share,
    'due_1', v_due_1,
    'due_2', v_due_2
  );
end;
$$;

revoke all on function public.confirm_charge_as_group(uuid, uuid, text) from public, anon;
grant execute on function public.confirm_charge_as_group(uuid, uuid, text) to authenticated;

/**
 * Quién pondría cuánto, y si el grupo da. No cambia nada: solo informa.
 *
 * Se rehace entera (no es un parche) porque cambia su forma:
 *
 *   · El reparto es entre TODOS los que pueden. Ya no hay lista que mandar ni
 *     casillas que marcar — quien inicia confirma, no elige.
 *   · `pot_usd` deja de ser la suma de lo que queda y pasa a ser la capacidad
 *     REAL: con partes iguales manda el que menos tiene, así que es
 *     (mínimo × integrantes). La suma prometía dinero que no se podía gastar.
 *   · Se siguen devolviendo TODOS los integrantes activos, incluidos los que
 *     quedan fuera, para que la pantalla pueda decir "a X no se le cobra
 *     ahora" en vez de que desaparezca de la lista sin explicación.
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
  v_user    uuid := auth.uid();
  v_charge  public.charges%rowtype;
  v_group   public.groups%rowtype;
  v_members integer;          -- los que pagan
  v_active  integer;          -- todos los activos, paguen o no
  v_share   numeric(18,4);
  v_min     numeric(18,4);
  v_pot     numeric(18,4);
  v_rows    jsonb;
  v_can     integer;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  select * into v_group from public.groups where id = p_group_id and status = 'active';
  if not found then
    raise exception 'Ese grupo ya está cerrado' using errcode = 'P0002';
  end if;

  -- Quien llama tiene que ser del grupo. Cualquiera de dentro vale.
  if not exists (
    select 1 from public.group_members
    where group_id = p_group_id and user_id = v_user
      and status = 'active' and released_at is null
  ) then
    raise exception 'No perteneces a este grupo' using errcode = '42501';
  end if;

  select count(*) into v_active
  from public.group_members
  where group_id = p_group_id and status = 'active' and released_at is null;

  -- Los que pagan: todos menos quien no puede asumir deuda ahora mismo.
  select count(*), coalesce(min(reserved_usd - consumed_usd), 0)
    into v_members, v_min
  from public.group_members m
  where m.group_id = p_group_id and m.status = 'active' and m.released_at is null
    and public.can_take_debt(m.user_id);

  if v_members = 0 then
    raise exception 'Nadie del grupo puede asumir este consumo ahora mismo'
      using errcode = '22023';
  end if;

  -- Reparto a partes iguales. El último céntimo se ajusta al confirmar.
  v_share := round(v_charge.amount_usd / v_members, 4);
  -- La capacidad real, no la suma: manda el que menos ticket tiene.
  v_pot := v_min * v_members;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.name), '[]'::jsonb),
         count(*) filter (where q.can_pay)
    into v_rows, v_can
  from (
    select
      m.user_id,
      p.full_name                              as name,
      public.can_take_debt(m.user_id)          as participates,
      -- Quien no participa no tiene "parte": ponerle una cifra al lado sería
      -- decirle que va a pagar eso.
      case when public.can_take_debt(m.user_id) then v_share else 0 end as share_usd,
      m.reserved_usd,
      m.consumed_usd,
      (m.reserved_usd - m.consumed_usd)        as remaining_usd,
      -- Los motivos, en el orden en que le importan a quien mira la pantalla
      -- de pie delante del cajero.
      case
        when not public.can_take_debt(m.user_id)           then 'cuota_vencida'
        when m.reserved_usd - m.consumed_usd <= 0          then 'sin_ticket'
        when v_share > m.reserved_usd - m.consumed_usd     then 'ticket_corto'
        when v_share < 2.50                                then 'bajo_el_minimo'
        -- Solo puede pasar si el nivel bajó por mora DESPUÉS de aceptar: la
        -- retención se tomó contra un límite que ya no existe.
        when coalesce(b.charged_usd, 0) + v_share
             > coalesce(l.monthly_limit_usd, 0)            then 'sin_saldo'
        else null
      end                                      as blocked_reason,
      (
        public.can_take_debt(m.user_id)
        and v_share <= m.reserved_usd - m.consumed_usd
        and v_share >= 2.50
        and coalesce(b.charged_usd, 0) + v_share <= coalesce(l.monthly_limit_usd, 0)
      )                                        as can_pay
    from public.group_members m
    join public.profiles p on p.id = m.user_id
    left join public.levels l on l.level = p.level
    left join public.user_credit_blocks b
      on b.user_id = m.user_id and b.closed_at is null
    where m.group_id = p_group_id and m.status = 'active' and m.released_at is null
  ) q;

  return jsonb_build_object(
    'charge_id', v_charge.id,
    'group_id', v_group.id,
    'group_name', v_group.name,
    'entry_amount_usd', v_group.entry_amount_usd,
    'amount_usd', v_charge.amount_usd,
    -- Cuántos pagan (los que se reparten la cuenta)...
    'member_count', v_members,
    -- ...y cuántos hay en total, para poder decir "6 de 7".
    'active_count', v_active,
    'excluded_count', v_active - v_members,
    'share_usd', v_share,
    'pot_usd', v_pot,
    'covers_amount', v_charge.amount_usd <= v_pot,
    'can_pay_count', v_can,
    'everyone_can_pay', v_can = v_members,
    'members', v_rows
  );
end;
$$;

revoke all on function public.preview_group_charge(uuid, uuid) from public, anon;
grant execute on function public.preview_group_charge(uuid, uuid) to authenticated;
