-- ============================================================================
-- Ronda — Un solo sitio que crea deuda, y dos índices que faltaban
--
-- ── EL BUCLE QUE EXISTÍA TRES VECES ─────────────────────────────────────────
--
-- Crear deuda es siempre lo mismo: mirar el límite del nivel, bloquear (o
-- abrir) el bloque de crédito, comprobar que la cifra cabe, partir el importe
-- en dos cuotas y sumar lo cargado. Eso estaba copiado —a mano, con
-- `pg_get_functiondef`— en `confirm_charge`, `confirm_charge_as_group` y
-- `claim_charge_share`.
--
-- Y el copia-pega ya se cobró sus piezas:
--
--   · la regresión del `tab_id` (arreglada en 20260828130000),
--   · los textos que seguían diciendo "mesa" en el modelo de grupos,
--   · `confirm_charge` perdiendo `confirmed_at` por el camino,
--   · y las cuotas de medio céntimo, que hubo que arreglar en TRES sitios.
--
-- Cada uno se arregló donde se vio, y las otras dos copias siguieron mal hasta
-- que alguien las miró. Ahora el bloque vive en `helios_assign_debt` y los tres
-- caminos lo llaman. Lo que sigue siendo propio de cada uno —el asiento del
-- receivable, el techo del grupo, los mensajes— se queda donde estaba.
--
-- ── LA RETENCIÓN DE GRUPOS, QUE YA NO EXISTÍA ───────────────────────────────
--
-- `group_holds_usd` devuelve 0 desde que se retiraron los apartados
-- (20260827030000, que ya la dejó comentada como "muerta"). Seguía sumándose
-- en la comprobación de saldo de `confirm_charge` y sosteniendo una rama de
-- error —"tienes $X retenidos en grupos"— que no podía darse nunca. Sale de
-- ahí; la función se queda porque `my_available_balance` todavía la llama.
--
-- ── DOS ÍNDICES ─────────────────────────────────────────────────────────────
--
--   · `installments(due_date)`: el cron diario de liquidaciones y el barrido
--     de mora filtran por fecha de vencimiento SIN filtrar por usuario, y el
--     único índice que había es `(user_id, due_date)`. Los dos recorrían la
--     tabla entera cada mañana.
--
--   · `group_members(user_id) where left_at is null`: el que existía tenía el
--     predicado `where status = 'active'`, y ninguna consulta viva filtra ya
--     por `status` — todas miran `left_at`. Un índice parcial cuyo predicado
--     no casa con ninguna consulta no lo usa nadie: ocupa y se mantiene para
--     nada.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Los dos índices
-- ---------------------------------------------------------------------------
create index if not exists installments_due_date_idx
  on public.installments (due_date);

drop index if exists public.group_members_user_idx;
create index if not exists group_members_user_alive_idx
  on public.group_members (user_id) where left_at is null;

-- ---------------------------------------------------------------------------
-- 2. El único sitio que crea deuda
-- ---------------------------------------------------------------------------
/**
 * Le carga `p_amount` a `p_user` por el consumo `p_charge_id`.
 *
 * Hace exactamente lo que los tres caminos hacían por su cuenta:
 *
 *   1. busca el límite del nivel —el tope duro, por encima de cualquier techo
 *      de grupo—;
 *   2. bloquea el bloque de crédito abierto, o lo abre si no había;
 *   3. comprueba que la cifra cabe, y si no, levanta el mensaje que le pase
 *      quien llama (cada pantalla necesita decirlo a su manera);
 *   4. parte el importe en dos cuotas de DOS decimales, con el céntimo impar
 *      a la segunda, y las inserta;
 *   5. suma lo cargado al bloque.
 *
 * NO toca el ledger: el cobro individual mete el receivable junto con las
 * otras tres patas del asiento, y los de grupo lo meten por separado. Esa
 * diferencia es real y se queda en cada llamante.
 *
 * Devuelve los dos importes para que el acuse no tenga que recalcularlos.
 */
create or replace function public.helios_assign_debt(
  p_user       uuid,
  p_charge_id  uuid,
  p_amount     numeric,
  p_due_1      date,
  p_due_2      date,
  p_over_limit_message text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_limit  numeric(18,4);
  v_block  public.user_credit_blocks%rowtype;
  v_first  numeric(18,4);
  v_second numeric(18,4);
begin
  select monthly_limit_usd into v_limit
  from public.levels l
  join public.profiles p on p.level = l.level
  where p.id = p_user;

  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user and closed_at is null
  for update;

  if not found then
    insert into public.user_credit_blocks (user_id) values (p_user)
    returning * into v_block;
  end if;

  if v_block.charged_usd + p_amount > v_limit then
    raise exception '%', p_over_limit_message using errcode = '22023';
  end if;

  -- Dos decimales y el resto a la segunda: a cuatro se guardaban cuotas de
  -- medio céntimo, impagables y que al formatear no sumaban el total.
  v_first  := round(p_amount / 2, 2);
  v_second := p_amount - v_first;

  insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
    (p_charge_id, p_user, 1, v_first,  p_due_1),
    (p_charge_id, p_user, 2, v_second, p_due_2);

  update public.user_credit_blocks
    set charged_usd = charged_usd + p_amount
  where id = v_block.id;

  return jsonb_build_object('installment_1_usd', v_first, 'installment_2_usd', v_second);
end;
$$;

-- Solo la llaman funciones `security definer` de dinero; nadie desde fuera.
revoke all on function public.helios_assign_debt(uuid, uuid, numeric, date, date, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Los tres caminos, ya sin su copia del bucle
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.confirm_charge(p_charge_id uuid, p_idempotency_key text, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'pg_temp'
AS $function$
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
  v_upfront     numeric(18,4);
  v_revenue     numeric(18,4);
  v_merchant_share numeric(18,4);
  -- Las dos cuotas (las devuelve `helios_assign_debt`) y la hora del servidor.
  v_split       jsonb;
  v_first       numeric(18,4);
  v_second      numeric(18,4);
  v_confirmed_at timestamptz;
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

  /**
   * NUEVO: la mora, comprobada AQUÍ y no heredada del cron.
   *
   * `profiles.status` lo mueve `process_mora` a las 10:05, pero el día
   * operativo cambia a las 10:00: en esos cinco minutos —y todo el día, si el
   * cron falla— alguien con una cuota recién vencida seguía consumiendo. Todas
   * las vías de grupo miran `can_take_debt` en el momento del cobro por este
   * mismo motivo (20260824140000); esta era la única que no, y es la más usada.
   */
  if not public.can_take_debt(v_user) then
    raise exception 'Tienes una cuota vencida: págala para volver a consumir'
      using errcode = '22023';
  end if;

  /**
   * El saldo, comprobado ANTES de mover nada.
   *
   * `helios_assign_debt` lo vuelve a comprobar —es su trabajo— pero aquí se
   * mira primero para poder decir la cifra concreta que falta, que es lo único
   * accionable para quien está en la caja. La retención de grupos
   * (`group_holds_usd`) salió de esta cuenta: devolvía cero desde que se
   * retiraron los apartados, y sumar cero solo servía para que el mensaje de
   * error tuviera una rama muerta.
   */
  select monthly_limit_usd into v_limit from public.levels where level = v_profile.level;

  select coalesce(charged_usd, 0) into v_open_debt
  from public.user_credit_blocks
  where user_id = v_user and closed_at is null;

  if coalesce(v_open_debt, 0) + v_charge.amount_usd > v_limit then
    raise exception 'Saldo insuficiente: disponible $%, cobro $%',
      (v_limit - coalesce(v_open_debt, 0)), v_charge.amount_usd
      using errcode = '22023';
  end if;

  select * into v_terms from public.merchant_settlement_terms where merchant_id = v_charge.merchant_id;

  v_bdate := public.helios_business_date(now());
  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_bdate);

  v_acct_recv := ledger.get_or_create_account('user_receivable', v_user);
  v_acct_pay  := ledger.get_or_create_account('merchant_payable', v_charge.merchant_id);
  v_acct_rev  := ledger.get_or_create_account('platform_revenue', null);

  v_revenue := coalesce(v_charge.consumer_fee_usd, 0) + coalesce(v_charge.merchant_fee_usd, 0);
  v_merchant_share := coalesce(v_charge.merchant_net_usd, v_charge.amount_usd - v_revenue);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', p_idempotency_key, v_bdate, v_charge.id, 'Venta en comercio')
  returning id into v_tx;

  /**
   * Las cuatro patas de una vez, saltándose las que valen cero.
   *
   * El filtro no es cosmético: `ledger.entries` tiene un check
   * (`entries_one_side`) que rechaza un asiento con debe y haber en cero, y
   * hay dos casos reales que lo producen — un comercio con comisión 0, y un
   * cobro sin IVA (los anteriores a este modelo). Enumerar y filtrar cubre
   * los dos sin un `if` por pata.
   */
  insert into ledger.entries (transaction_id, account_id, debit, credit)
  select v_tx, x.acct, x.debit, x.credit
  from (values
    (v_acct_recv, v_charge.amount_usd, 0::numeric),
    (v_acct_pay, 0::numeric, v_merchant_share),
    (v_acct_rev, 0::numeric, v_revenue),
    (ledger.get_or_create_account('vat_payable', null), 0::numeric,
     v_charge.amount_usd - v_merchant_share - v_revenue)
  ) as x(acct, debit, credit)
  where x.debit <> 0 or x.credit <> 0;

  v_upfront := round(v_merchant_share * v_terms.upfront_pct / 100, 4);
  -- --- El adelanto se DEVENGA, no se paga -------------------------------
  -- Aquí volvía a salir dinero de `cash` (ver la cabecera de esta migración).
  -- Solo queda la obligación: la caja se mueve cuando alguien transfiera de
  -- verdad y lo reporte.
  perform ledger.record_advance_settlement(v_charge.merchant_id, v_charge.id, v_upfront, v_bdate);

  -- La deuda, con el bloque de crédito y las dos cuotas: lo mismo que hacen el
  -- cobro de grupo y el reparto, en un solo sitio (`helios_assign_debt`).
  v_split  := public.helios_assign_debt(
    v_user, v_charge.id, v_charge.amount_usd, v_due_1, v_due_2,
    format('Saldo insuficiente para $%s', trim(to_char(v_charge.amount_usd, 'FM999999990.00')))
  );
  v_first  := (v_split->>'installment_1_usd')::numeric;
  v_second := (v_split->>'installment_2_usd')::numeric;

  update public.charges
    set status = 'confirmed', user_id = v_user, business_date = v_bdate, confirmed_at = now()
  where id = v_charge.id
  returning confirmed_at into v_confirmed_at;

  return jsonb_build_object(
    'ok', true, 'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'due_1', v_due_1, 'due_2', v_due_2,
    -- NUEVO: los importes de las dos cuotas, para que el acuse no los invente.
    'installment_1_usd', v_first,
    'installment_2_usd', v_second,
    -- NUEVO (restaurado): la hora del SERVIDOR. La perdió el copia-pega de
    -- 20260827110000 y el acuse llevaba desde entonces la hora del teléfono.
    'confirmed_at', v_confirmed_at
  );
end;
$function$
;

revoke all on function public.confirm_charge(uuid, text, text) from public, anon;
grant execute on function public.confirm_charge(uuid, text, text) to authenticated;

CREATE OR REPLACE FUNCTION public.confirm_charge_as_group(
  p_charge_id uuid,
  p_group_id uuid,
  p_idempotency_key text,
  p_pin text,
  p_expected_share_usd numeric
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'pg_temp'
AS $function$
declare
  v_user    uuid := auth.uid();
  v_pin     jsonb;
  v_charge  public.charges%rowtype;
  v_group_id  uuid;
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
  v_block   public.user_credit_blocks%rowtype;
  v_limit   numeric(18,4);
  -- Las dos cuotas, tal como las devuelve `helios_assign_debt`.
  v_debt     jsonb;
  v_first    numeric(18,4);
  v_second   numeric(18,4);
  v_my_first numeric(18,4);
  v_my_second numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- NUEVO: sin importe esperado no se cobra. Es el consentimiento del usuario
  -- traído hasta aquí; dejarlo opcional sería no tenerlo.
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

  if not exists (
    select 1 from public.group_members
    where group_id = v_group_id
      and user_id = v_user
      and left_at is null
      and business_date = public.helios_business_date(now())
  ) then
    raise exception 'No perteneces a este grupo' using errcode = '42501';
  end if;

  -- NUEVO: el que inicia tiene que poder asumir su parte. Se comprueba lo
  -- mismo que al crear el grupo y al entrar; sin esto, alguien con una cuota
  -- vencida quedaba fuera del reparto —los participantes se filtran por
  -- `can_take_debt`— y la venta salía adelante repartida solo entre los demás.
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

  v_split := public.helios_split_shares(v_charge.amount_usd, v_parts);

  if not coalesce((v_split->>'ok')::boolean, false) then
    if v_split->>'reason' = 'too_small' then
      raise exception 'Entre % la cuenta mínima es $% y esta es de $%',
        v_split->>'split_between', v_split->>'min_total_usd', v_charge.amount_usd
        using errcode = '22023';
    else
      raise exception 'El grupo llega a $% y la cuenta es de $%',
        v_split->>'capacity_usd', v_charge.amount_usd
        using errcode = '22023';
    end if;
  end if;

  v_shares := v_split->'shares';
  v_count  := (v_split->>'split_between')::integer;

  -- NUEVO: el iniciador tiene que salir en el reparto. La capacidad y el
  -- reparto son la misma cuenta, así que se mira el RESULTADO: si su techo se
  -- agotó o su saldo no llega al mínimo por persona, queda fuera y la cuenta
  -- entera caería sobre los demás.
  select (s->>'share_usd')::numeric into v_my
  from jsonb_array_elements(v_shares) s
  where (s->>'user_id')::uuid = v_user;

  if v_my is null then
    raise exception 'No te alcanza para poner tu parte de esta cuenta'
      using errcode = '22023';
  end if;

  -- NUEVO: y esa parte no puede pasarse de la que se autorizó con el PIN.
  --
  -- Solo hacia arriba. Que baje —porque entró alguien más, o porque a otro le
  -- subió el techo— no perjudica a quien paga, y abortar ahí sería fastidiar
  -- un cobro por una buena noticia. El céntimo de tolerancia es por el viaje
  -- del número en coma flotante desde el teléfono.
  if v_my > p_expected_share_usd + 0.01 then
    raise exception
      'Tu parte cambió a $% mientras confirmabas (habías autorizado $%): vuelve a mirar el reparto',
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

  /**
   * Las cuatro patas de una vez, saltándose las que valen cero.
   *
   * El filtro no es cosmético: `ledger.entries` tiene un check
   * (`entries_one_side`) que rechaza un asiento con debe y haber en cero, y
   * hay dos casos reales que lo producen — un comercio con comisión 0, y un
   * cobro sin IVA (los anteriores a este modelo). Enumerar y filtrar cubre
   * los dos sin un `if` por pata.
   */
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
    order by 1
  loop
    v_share := v_row.share;

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, ledger.get_or_create_account('user_receivable', v_row.user_id), v_share, 0);

    -- La deuda de este integrante: bloque de crédito, tope duro del nivel y
    -- las dos cuotas. El mismo `helios_assign_debt` que usan el cobro
    -- individual y el reparto — el límite del nivel manda por encima de
    -- cualquier techo de grupo, y la capacidad ya lo respeta: esto es el
    -- cinturón.
    v_debt   := public.helios_assign_debt(
      v_row.user_id, v_charge.id, v_share, v_due_1, v_due_2,
      format('Alguien del grupo ya no tiene límite para $%s',
             trim(to_char(v_share, 'FM999999990.00')))
    );
    v_first  := (v_debt->>'installment_1_usd')::numeric;
    v_second := (v_debt->>'installment_2_usd')::numeric;

    if v_row.user_id = v_user then
      v_my_first  := v_first;
      v_my_second := v_second;
    end if;

    -- El techo es acumulativo por la noche: aquí es donde se gasta.
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

  return jsonb_build_object(
    'ok', true,
    'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'split_between', v_count,
    'share_usd', v_my,
    'even_share_usd', round(v_charge.amount_usd / v_count, 2),
    'due_1', v_due_1,
    'due_2', v_due_2,
    -- NUEVO: los importes reales de mis dos cuotas.
    'installment_1_usd', v_my_first,
    'installment_2_usd', v_my_second,
    'confirmed_at', v_confirmed_at
  );
end;
$function$
;

revoke all on function public.confirm_charge_as_group(uuid, uuid, text, text, numeric) from public, anon;
grant execute on function public.confirm_charge_as_group(uuid, uuid, text, text, numeric) to authenticated;

CREATE OR REPLACE FUNCTION public.claim_charge_share(p_token text, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'pg_temp'
AS $function$
declare
  v_user    uuid := auth.uid();
  v_pin     jsonb;
  v_charge  public.charges%rowtype;
  v_parts   jsonb := '[]'::jsonb;
  v_split   jsonb;
  v_row     record;
  v_new     numeric(18,4);
  v_mine    numeric(18,4);
  v_delta   numeric(18,4);
  v_tx      uuid;
  v_due_1   date;
  v_due_2   date;
  v_half    numeric(18,4);
  v_block   public.user_credit_blocks%rowtype;
  v_limit   numeric(18,4);
  v_count   integer := 0;
  -- Las dos cuotas del que entra, tal como las devuelve `helios_assign_debt`.
  v_debt    jsonb;
  v_first   numeric(18,4);
  v_second  numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  select * into v_charge from public.charges
  where share_token = trim(p_token) for update;

  if not found then
    raise exception 'Ese código no corresponde a ninguna orden' using errcode = 'P0002';
  end if;

  -- NUEVO: ya tengo mi parte → se devuelve, no se lanza.
  --
  -- Antes esto era 'Ya tienes una parte de esta orden' por excepción, así que
  -- quien reclamaba bien y perdía la respuesta por la red veía un error y no
  -- recuperaba nunca su acuse. Es la misma vía idempotente que `confirm_charge`
  -- resuelve con `already_confirmed`.
  if exists (select 1 from public.installments
             where charge_id = v_charge.id and user_id = v_user) then
    select sum(amount_usd) into v_mine from public.installments
    where charge_id = v_charge.id and user_id = v_user;

    select amount_usd, due_date into v_first, v_due_1 from public.installments
    where charge_id = v_charge.id and user_id = v_user and sequence = 1;
    select amount_usd, due_date into v_second, v_due_2 from public.installments
    where charge_id = v_charge.id and user_id = v_user and sequence = 2;

    return jsonb_build_object(
      'ok', true,
      'already_claimed', true,
      'charge_id', v_charge.id,
      'amount_usd', v_charge.amount_usd,
      'share_usd', v_mine,
      'split_between', (select count(distinct user_id)::integer
                        from public.installments where charge_id = v_charge.id),
      'installment_1_usd', v_first,
      'installment_2_usd', v_second,
      'due_1', v_due_1,
      'due_2', v_due_2
    );
  end if;

  if public.helios_business_day_end(v_charge.business_date) <= now() then
    raise exception 'Esta orden ya se cerró: solo se reparte durante la misma noche'
      using errcode = '22023';
  end if;

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes asumir deuda nueva' using errcode = '22023';
  end if;

  -- Se bloquean las cuotas de la orden antes de leerlas: dos personas
  -- escaneando el mismo QR a la vez no pueden repartir cada una sobre la foto
  -- vieja.
  perform 1 from public.installments
  where charge_id = v_charge.id order by user_id, sequence for update;

  -- Repartir REESCRIBE las cuotas de los que ya debían, y eso solo es seguro
  -- mientras ninguna se haya movido (ver 20260829020000).
  if exists (
    select 1 from public.installments
    where charge_id = v_charge.id and status <> 'pending'
  ) then
    raise exception
      'Alguien ya pagó su parte de esta cuenta: repartirla ahora descuadraría lo cobrado'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.payment_quote_items qi
    join public.installments i   on i.id = qi.installment_id
    join public.payment_quotes q on q.id = qi.quote_id
    where i.charge_id = v_charge.id
      and q.valid_until > now()
  ) or exists (
    select 1
    from public.payment_quote_items qi
    join public.installments i    on i.id = qi.installment_id
    join public.payment_reports r on r.quote_id = qi.quote_id
    where i.charge_id = v_charge.id
      and r.status in ('reported', 'in_review')
  ) then
    raise exception
      'Alguien de esta cuenta ya está pagando su parte: no se puede repartir mientras tanto'
      using errcode = '22023';
  end if;

  for v_row in select * from public.charge_debtors(v_charge.id) loop
    v_parts := v_parts || jsonb_build_object(
      'user_id', v_row.user_id, 'capacity_usd', v_row.share_usd
    );
    v_count := v_count + 1;
  end loop;

  v_parts := v_parts || jsonb_build_object(
    'user_id', v_user,
    'capacity_usd', public.claimant_capacity(v_user, v_charge.group_id)
  );

  v_split := public.helios_split_shares(v_charge.amount_usd, v_parts);

  if not coalesce((v_split->>'ok')::boolean, false) then
    if v_split->>'reason' = 'too_small' then
      raise exception 'Ya son % en esta cuenta de $%: entrar dejaría a alguien por debajo del mínimo',
        v_count, v_charge.amount_usd using errcode = '22023';
    else
      raise exception 'No te alcanza el saldo para tomar una parte de esta cuenta'
        using errcode = '22023';
    end if;
  end if;

  -- Las fechas del consumo, no las de hoy.
  select due_date into v_due_1 from public.installments
  where charge_id = v_charge.id and sequence = 1 limit 1;
  select due_date into v_due_2 from public.installments
  where charge_id = v_charge.id and sequence = 2 limit 1;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', 'claim:' || v_charge.id::text || ':' || v_user::text,
          v_charge.business_date, v_charge.id,
          format('Reparto posterior: entra 1 persona, ahora son %s',
                 (v_split->>'split_between')::integer))
  returning id into v_tx;

  -- --- A los que ya debían: se les baja ------------------------------------
  for v_row in select * from public.charge_debtors(v_charge.id) loop
    select (s->>'share_usd')::numeric into v_new
    from jsonb_array_elements(v_split->'shares') s
    where (s->>'user_id')::uuid = v_row.user_id;

    v_delta := v_row.share_usd - coalesce(v_new, v_row.share_usd);
    continue when v_delta <= 0;

    -- NUEVO: dos decimales, el resto a la segunda cuota.
    v_half := round(v_new / 2, 2);

    update public.installments set amount_usd = v_half
    where charge_id = v_charge.id and user_id = v_row.user_id and sequence = 1;
    update public.installments set amount_usd = v_new - v_half
    where charge_id = v_charge.id and user_id = v_row.user_id and sequence = 2;

    update public.user_credit_blocks
      set charged_usd = charged_usd - v_delta
    where user_id = v_row.user_id and closed_at is null;

    -- Si la orden salió de una mesa, el techo gastado también se libera.
    if v_charge.group_id is not null then
      update public.group_members
        set spent_usd = greatest(spent_usd - v_delta, 0)
      where group_id = v_charge.group_id and user_id = v_row.user_id;
    end if;

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, ledger.get_or_create_account('user_receivable', v_row.user_id), 0, v_delta);

    perform public.notify(
      v_row.user_id,
      'group_charge',
      'Tu parte bajó',
      format('Alguien más entró en la cuenta de $%s. Tu parte pasó a $%s.',
             trim(to_char(v_charge.amount_usd, 'FM999999990.00')),
             trim(to_char(v_new, 'FM999999990.00'))),
      jsonb_build_object('charge_id', v_charge.id, 'amount_usd', v_new)
    );
  end loop;

  -- --- Al que entra: su deuda ----------------------------------------------
  select (s->>'share_usd')::numeric into v_mine
  from jsonb_array_elements(v_split->'shares') s
  where (s->>'user_id')::uuid = v_user;

  -- NUEVO: quedé fuera del reparto por no llegar al mínimo por persona. Sin
  -- esto, el null seguía hasta un `not null violation` crudo — después del PIN.
  if v_mine is null then
    raise exception 'No te alcanza para tomar una parte de esta cuenta'
      using errcode = '22023';
  end if;

  -- La deuda del que entra: bloque de crédito, tope duro y las dos cuotas.
  -- Lo mismo que hacen el cobro individual y el de grupo, en un solo sitio.
  v_debt   := public.helios_assign_debt(
    v_user, v_charge.id, v_mine, v_due_1, v_due_2,
    format('Tu límite no cubre $%s', trim(to_char(v_mine, 'FM999999990.00')))
  );
  v_first  := (v_debt->>'installment_1_usd')::numeric;
  v_second := (v_debt->>'installment_2_usd')::numeric;

  if v_charge.group_id is not null then
    update public.group_members
      set spent_usd = spent_usd + v_mine
    where group_id = v_charge.group_id and user_id = v_user and left_at is null;
  end if;

  insert into ledger.entries (transaction_id, account_id, debit, credit)
  values (v_tx, ledger.get_or_create_account('user_receivable', v_user), v_mine, 0);

  return jsonb_build_object(
    'ok', true,
    'already_claimed', false,
    'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'share_usd', v_mine,
    'split_between', (v_split->>'split_between')::integer,
    -- NUEVO: los importes reales, para que el acuse no los invente.
    'installment_1_usd', v_first,
    'installment_2_usd', v_second,
    'due_1', v_due_1,
    'due_2', v_due_2
  );
end;
$function$
;

revoke all on function public.claim_charge_share(text, text) from public, anon;
grant execute on function public.claim_charge_share(text, text) to authenticated;
