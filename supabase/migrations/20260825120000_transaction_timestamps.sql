-- ============================================================================
-- Ronda — La HORA de cada transacción, devuelta por el servidor
--
-- La base ya guardaba el instante de todo movimiento de dinero: `charges.
-- confirmed_at`, `payment_reports.created_at`, `installments.paid_at`,
-- `ledger.transactions.created_at`. Todos son `timestamptz`, así que el
-- instante es absoluto y se pinta en `America/Caracas` al mostrarlo
-- (docs/05 §1). Lo que faltaba era DEVOLVERLO.
--
-- Sin esto, las dos pantallas de acuse de la app no tenían más remedio que
-- enseñar la hora del reloj del TELÉFONO, que es otra cosa: un móvil con la
-- hora mal —o puesto en otro huso, que es lo normal en quien viaja— imprimía
-- en el comprobante una hora que no existe en ninguna fila de la base. Ese
-- comprobante es justo el que se coteja contra el ticket del local y contra
-- el panel de soporte, y los tres tienen que decir lo mismo.
--
-- Los tres cuerpos van copiados tal cual de su última definición
-- (20260824170000_pin_to_pay.sql y 20260824110000_installments_in_review.sql).
-- Lo único que cambia:
--
--   confirm_charge / confirm_charge_as_group
--     · `returning confirmed_at into v_confirmed_at` en el UPDATE, para
--       devolver EL MISMO valor que quedó escrito, no un `now()` recalculado.
--     · `confirmed_at` en el jsonb de vuelta, también en el atajo de
--       `already_confirmed`: un reintento de red tiene que dar la hora del
--       cobro original, no la del reintento.
--
--   report_payment
--     · `reported_at` en el jsonb de vuelta.
--
-- Nada más. Ni reglas de dinero, ni límites, ni asientos.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Consumo individual
-- ---------------------------------------------------------------------------

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
  -- El instante que queda escrito en la fila. Se devuelve tal cual para que
  -- el acuse enseñe la hora del SERVIDOR y no la del reloj del teléfono.
  v_confirmed_at   timestamptz;
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
    return jsonb_build_object(
      'ok', true, 'charge_id', v_charge.id, 'already_confirmed', true,
      'confirmed_at', v_charge.confirmed_at
    );
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
  where id = v_charge.id
  returning confirmed_at into v_confirmed_at;

  return jsonb_build_object(
    'ok', true, 'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'due_1', v_due_1, 'due_2', v_due_2,
    'confirmed_at', v_confirmed_at
  );
end;
$$;

revoke all on function public.confirm_charge(uuid, text, text) from public, anon;
grant execute on function public.confirm_charge(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Consumo repartido en grupo
-- ---------------------------------------------------------------------------

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
  -- El instante que queda escrito en la fila. Se devuelve tal cual para que
  -- el acuse enseñe la hora del SERVIDOR y no la del reloj del teléfono.
  v_confirmed_at   timestamptz;
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
    return jsonb_build_object(
      'ok', true, 'charge_id', v_charge.id, 'already_confirmed', true,
      'confirmed_at', v_charge.confirmed_at
    );
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
  where id = v_charge.id
  returning confirmed_at into v_confirmed_at;

  return jsonb_build_object(
    'ok', true,
    'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'split_between', v_count,
    'share_usd', v_share,
    'due_1', v_due_1,
    'due_2', v_due_2,
    'confirmed_at', v_confirmed_at
  );
end;
$$;

revoke all on function public.confirm_charge_as_group(uuid, uuid, text, text) from public, anon;
grant execute on function public.confirm_charge_as_group(uuid, uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Reporte de pago de cuotas
-- ---------------------------------------------------------------------------

create or replace function public.report_payment(
  p_quote_id       uuid,
  p_method         text,
  p_bank           text,
  p_reference      text,
  p_payer_document text default null,
  p_payer_phone    text default null,
  p_receipt_path   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user      uuid := auth.uid();
  v_quote     public.payment_quotes%rowtype;
  v_dest      uuid;
  v_duplicate boolean;
  v_status    public.payment_report_status;
  v_row       public.payment_reports%rowtype;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_quote from public.payment_quotes where id = p_quote_id for update;
  if not found or v_quote.user_id <> v_user then
    raise exception 'Cotización no encontrada' using errcode = 'P0002';
  end if;

  if v_quote.valid_until < now() then
    raise exception 'La cotización venció, vuelve a cotizar' using errcode = '22023';
  end if;

  if p_method <> 'efectivo' and (p_reference is null or length(trim(p_reference)) = 0) then
    raise exception 'La referencia es obligatoria para %', p_method using errcode = '22023';
  end if;

  if exists (
    select 1 from public.payment_reports r
    join public.payment_quote_items i on i.quote_id = r.quote_id
    join public.payment_quote_items j on j.installment_id = i.installment_id
    where j.quote_id = p_quote_id and r.status in ('reported', 'in_review')
  ) then
    raise exception
      'Ya reportaste un pago para alguna de esas cuotas y está en revisión. Te avisamos en cuanto lo confirmemos.'
      using errcode = '22023';
  end if;

  select id into v_dest from public.payment_destinations where is_active limit 1;

  -- Coincidencia de referencia: sospechosa, no concluyente. Va a revisión.
  v_duplicate := p_reference is not null and exists (
    select 1 from public.payment_reports
    where bank = p_bank and reference = p_reference and status <> 'rejected'
  );

  v_status := case when v_duplicate then 'in_review' else 'reported' end;

  insert into public.payment_reports (
    quote_id, user_id, method, bank, reference,
    payer_document, payer_phone, destination_id, receipt_path, status,
    rejection_note
  )
  values (
    p_quote_id, v_user, p_method, p_bank, p_reference,
    p_payer_document, p_payer_phone, v_dest, p_receipt_path, v_status,
    case when v_duplicate
      then 'Referencia repetida: revisar contra el estado de cuenta antes de aprobar.'
      else null end
  )
  returning * into v_row;

  return jsonb_build_object(
    'report_id', v_row.id,
    'status', v_row.status,
    'amount_usd', v_quote.amount_usd,
    'amount_ves', v_quote.amount_ves,
    'installment_count', v_quote.installment_count,
    'reported_at', v_row.created_at
  );
end;
$$;

revoke all on function public.report_payment(uuid, text, text, text, text, text, text)
  from public, anon;
grant execute on function public.report_payment(uuid, text, text, text, text, text, text)
  to authenticated;
