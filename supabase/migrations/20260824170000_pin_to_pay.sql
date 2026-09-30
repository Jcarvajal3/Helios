-- ============================================================================
-- Ronda — El PIN para pagar
--
-- Hasta aquí, confirmar un cobro solo necesitaba la sesión. La app se bloquea
-- sola al pasar a segundo plano, pero eso no cubre el caso que de verdad pasa
-- en un bar: el teléfono desbloqueado, en la mano, un segundo sin mirar.
--
-- A partir de ahora las dos funciones que mueven dinero —individual y de
-- grupo— exigen el PIN. Y lo exigen ELLAS, no la pantalla: una comprobación
-- en el cliente se salta llamando al RPC directamente, y el token de sesión
-- está en el teléfono. Si el PIN es la autorización del pago, tiene que
-- pedirlo quien ejecuta el pago.
--
-- ---------------------------------------------------------------------------
-- El detalle que hace que el bloqueo progresivo siga sirviendo
-- ---------------------------------------------------------------------------
-- `verify_user_pin` anota cada fallo en `pin_attempts` y escala el bloqueo
-- (3 → 30s, 5 → 5min, 7 → exige OTP). Si un PIN incorrecto se resolviera con
-- `raise`, Postgres revertiría la transacción entera **incluido ese apunte**:
-- el contador nunca subiría y confirmar un cobro sería un oráculo para probar
-- PINes de uno en uno, sin límite y sin dejar rastro.
--
-- Por eso el PIN incorrecto se DEVUELVE como `{ok:false, reason:…}` en vez de
-- lanzarse, y el bloque va lo primero de la función: así, cuando se devuelve,
-- lo único que la transacción confirma es el intento fallido.
--
-- Para el cliente esto significa que `ok` deja de ser decorativo: un cobro
-- puede volver sin error de PostgREST y aun así no haberse hecho.
-- ============================================================================

-- Las firmas viejas se TIRAN, no se dejan conviviendo. Añadir un parámetro en
-- Postgres crea una SOBRECARGA: sin este drop, `confirm_charge(uuid, text)`
-- seguiría existiendo y cobrando sin PIN, que es exactamente la puerta que
-- esta migración viene a cerrar. Un cliente sin actualizar la encontraría.
drop function if exists public.confirm_charge(uuid, text);
drop function if exists public.confirm_charge_as_group(uuid, uuid, text);

/**
 * Consumo individual: el cupo retenido en grupos NO está disponible.
 *
 * preview_charge ya salía bien solo, porque delega en my_available_balance.
 * Esta función calculaba el disponible a mano contra charged_usd, así que sin
 * este parche dejaba pagar en solitario con dinero ya comprometido en un
 * grupo — y el cobro del grupo se caería después, delante del cajero y sin
 * que nadie entendiera por qué.
 *
 * Solo cambia el cálculo del disponible; el resto es idéntico a la versión de
 * 20260822070000_charge_claim_model.
 */
create or replace function public.confirm_charge(
  p_charge_id       uuid,
  p_idempotency_key text,
  p_pin             text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_user        uuid := auth.uid();
  v_pin       jsonb;
  v_charge      public.charges%rowtype;
  v_profile     public.profiles%rowtype;
  v_limit       numeric(18,4);
  v_block       public.user_credit_blocks%rowtype;
  v_open_debt   numeric(18,4);
  v_reserved    numeric(18,4);
  v_terms       public.merchant_settlement_terms%rowtype;
  v_bdate       date;
  v_due_1       date;
  v_due_2       date;
  v_tx          uuid;
  v_acct_recv   uuid;
  v_acct_pay    uuid;
  v_acct_rev    uuid;
  v_acct_cash   uuid;
  v_upfront     numeric(18,4);
  v_revenue     numeric(18,4);
  v_merchant_share numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  /**
   * EL PIN, ANTES DE TOCAR NADA.
   *
   * Se comprueba con `verify_user_pin`, que es quien lleva el bloqueo
   * progresivo (3 fallos → 30s, 5 → 5min, 7 → exige OTP) y lo anota en
   * `pin_attempts`.
   *
   * Un PIN incorrecto se DEVUELVE, no se lanza — y esa diferencia es la que
   * hace que el bloqueo funcione. Un `raise` revertiría la transacción
   * entera, **incluido el intento fallido que acaba de anotarse**, y este
   * cobro quedaría convertido en un oráculo para probar PINes sin límite ni
   * rastro. Devolviendo, la transacción confirma y el contador sube.
   *
   * Por eso va lo PRIMERO: cuando se devuelve por PIN incorrecto, lo único
   * escrito en la transacción es ese intento.
   */
  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  if v_charge.status = 'confirmed' then
    if v_charge.user_id <> v_user then
      raise exception 'Este cobro ya fue tomado por otra persona' using errcode = '42501';
    end if;
    return jsonb_build_object('ok', true, 'charge_id', v_charge.id, 'already_confirmed', true);
  end if;

  if v_charge.status <> 'pending' then
    raise exception 'Este cobro ya no está disponible (%)', v_charge.status using errcode = '22023';
  end if;

  if v_charge.expires_at < now() then
    raise exception 'Este QR caducó, pídele al local que genere uno nuevo' using errcode = '22023';
  end if;

  if v_charge.user_id is not null and v_charge.user_id <> v_user then
    raise exception 'Este cobro ya fue tomado por otra persona' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where id = v_user for update;

  if v_profile.status <> 'active' then
    raise exception 'Tu cuenta no puede consumir en este estado (%)', v_profile.status
      using errcode = '22023';
  end if;

  select monthly_limit_usd into v_limit from public.levels where level = v_profile.level;

  select * into v_block
  from public.user_credit_blocks
  where user_id = v_user and closed_at is null
  for update;

  if not found then
    insert into public.user_credit_blocks (user_id) values (v_user)
    returning * into v_block;
  end if;

  v_open_debt := v_block.charged_usd;
  v_reserved  := public.group_holds_usd(v_user);

  if v_open_debt + v_reserved + v_charge.amount_usd > v_limit then
    if v_reserved > 0 then
      raise exception 'Saldo insuficiente: disponible $%, cobro $%. Tienes $% retenidos en grupos',
        (v_limit - v_open_debt - v_reserved), v_charge.amount_usd, v_reserved
        using errcode = '22023';
    end if;

    raise exception 'Saldo insuficiente: disponible $%, cobro $%',
      (v_limit - v_open_debt), v_charge.amount_usd
      using errcode = '22023';
  end if;

  select * into v_terms from public.merchant_settlement_terms where merchant_id = v_charge.merchant_id;

  v_bdate := public.helios_business_date(now());
  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_bdate);

  v_acct_recv := ledger.get_or_create_account('user_receivable', v_user);
  v_acct_pay  := ledger.get_or_create_account('merchant_payable', v_charge.merchant_id);
  v_acct_rev  := ledger.get_or_create_account('platform_revenue', null);
  v_acct_cash := ledger.get_or_create_account('cash', null);

  v_revenue := round(v_charge.amount_usd * v_terms.commission_pct / 100, 4);
  v_merchant_share := v_charge.amount_usd - v_revenue;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', p_idempotency_key, v_bdate, v_charge.id, 'Venta en comercio')
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_recv, v_charge.amount_usd, 0),
    (v_tx, v_acct_pay, 0, v_merchant_share),
    (v_tx, v_acct_rev, 0, v_revenue);

  v_upfront := round(v_charge.amount_usd * v_terms.upfront_pct / 100, 4);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('merchant_advance', p_idempotency_key || ':advance', v_bdate, v_charge.id, 'Adelanto al vender')
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_pay, v_upfront, 0),
    (v_tx, v_acct_cash, 0, v_upfront);

  perform ledger.record_advance_settlement(v_charge.merchant_id, v_charge.id, v_upfront, v_bdate);

  insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
    (v_charge.id, v_user, 1, round(v_charge.amount_usd / 2, 4), v_due_1),
    (v_charge.id, v_user, 2, v_charge.amount_usd - round(v_charge.amount_usd / 2, 4), v_due_2);

  update public.user_credit_blocks
    set charged_usd = charged_usd + v_charge.amount_usd
  where id = v_block.id;

  update public.charges
    set status = 'confirmed', user_id = v_user, business_date = v_bdate, confirmed_at = now()
  where id = v_charge.id;

  return jsonb_build_object(
    'ok', true, 'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'due_1', v_due_1, 'due_2', v_due_2
  );
end;
$$;

revoke all on function public.confirm_charge(uuid, text, text) from public, anon;
grant execute on function public.confirm_charge(uuid, text, text) to authenticated;

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
  p_idempotency_key text,
  p_pin             text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_user      uuid := auth.uid();
  v_pin       jsonb;
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

  /**
   * EL PIN, ANTES DE TOCAR NADA.
   *
   * Se comprueba con `verify_user_pin`, que es quien lleva el bloqueo
   * progresivo (3 fallos → 30s, 5 → 5min, 7 → exige OTP) y lo anota en
   * `pin_attempts`.
   *
   * Un PIN incorrecto se DEVUELVE, no se lanza — y esa diferencia es la que
   * hace que el bloqueo funcione. Un `raise` revertiría la transacción
   * entera, **incluido el intento fallido que acaba de anotarse**, y este
   * cobro quedaría convertido en un oráculo para probar PINes sin límite ni
   * rastro. Devolviendo, la transacción confirma y el contador sube.
   *
   * Por eso va lo PRIMERO: cuando se devuelve por PIN incorrecto, lo único
   * escrito en la transacción es ese intento.
   */
  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
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

  if v_share < public.min_share_usd() then
    raise exception 'La parte de cada quien quedaría en $% y el mínimo es $%',
      v_share, public.min_share_usd()
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

revoke all on function public.confirm_charge_as_group(uuid, uuid, text, text) from public, anon;
grant execute on function public.confirm_charge_as_group(uuid, uuid, text, text) to authenticated;
