-- ============================================================================
-- Ronda — Tres agujeros del cobro en grupo y de la liquidación
--
-- 1. EL IMPORTE QUE AUTORIZA EL PIN NO ERA EL QUE SE COBRABA
--
-- `dividir` enseña `my_share_usd` del preview y pide el PIN encima de esa
-- cifra. `confirm_charge_as_group` recalcula la cascada con capacidades
-- frescas —correcto, y es lo que evita las carreras— pero no recibía el
-- importe que el usuario tenía delante, así que nada comprobaba que siguieran
-- siendo el mismo.
--
-- Si entre ver el desglose y teclear el PIN alguien sale del grupo, se le
-- vence una cuota o se gasta su saldo en otra barra, la parte del que paga
-- SUBE — y se entera en el acuse, con la deuda ya creada.
--
-- Ahora la RPC recibe `p_expected_share_usd` y se niega si la parte real lo
-- supera. Solo hacia arriba: que baje no perjudica a nadie y abortar sería
-- fastidiar por nada. La app vuelve a pedir el preview y enseña la cifra
-- nueva.
--
-- El parámetro es OBLIGATORIO y la firma de cuatro argumentos se elimina, no
-- se deja con `default null`: un overload sin el importe esperado es la misma
-- puerta abierta con otro nombre. Mismo criterio con el que se tapió el
-- `confirm_charge` sin PIN en 20260824170000.
--
-- 2. QUIEN NO PUEDE ENDEUDARSE PODÍA COBRARLE AL GRUPO Y NO PAGAR NADA
--
-- Se comprobaba la membresía del que inicia, pero no si él mismo puede asumir
-- deuda. Los participantes del reparto se filtran por `can_take_debt` y
-- capacidad, así que el iniciador podía quedar fuera del split y la venta
-- seguía adelante: 100% de la cuenta repartido entre los demás, y él a cero.
--
-- Con una cuota vencida, o con el techo agotado, eso es exactamente lo que la
-- regla 6 de docs/05 §2 dice que no se puede expresar. Ahora se comprueba lo
-- mismo que en `create_group`/`join_group`, y además que el iniciador salga
-- en el reparto: la comprobación de capacidad y el reparto son la misma
-- cuenta, así que se mira el resultado y no la intención.
--
-- 3. UNA CONFIGURACIÓN DE LIQUIDACIÓN EN CERO TUMBABA LA CAJA O EL CRON
--
-- `settlements` tiene `check (amount_usd > 0)`. Con `upfront_pct = 0`
-- —perfectamente legal: 0 + 50 + 50 = 100— `record_advance_settlement`
-- violaba el check y TODOS los cobros de ese comercio fallaban en la caja.
-- Con `per_installment_pct = 0` el que reventaba era el cron diario, a mitad
-- de bucle, y se llevaba por delante la liquidación de todos los demás
-- comercios de ese día.
--
-- Y un comercio SIN fila de condiciones —el propio 20260825110000 documenta
-- que puede existir: seeds, borrados, cargas de datos— hacía null el importe
-- del adelanto y reventaba con un NOT NULL pelado.
--
-- Se arregla en el sitio por el que pasan los dos cobros (individual y de
-- grupo) sin reescribir ninguno de los dos:
--
--   * importe cero  → no hay nada que liquidar, no se encola nada;
--   * importe null  → faltan las condiciones: se para el cobro DICIÉNDOLO.
--
-- Y el cron deja de ser todo-o-nada: cada consumo va en su propio bloque, así
-- que un comercio mal configurado sale por `warning` en el log y los demás
-- cobran igual.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El adelanto: cero no se encola, y sin condiciones no se vende
-- ---------------------------------------------------------------------------
/**
 * Pasa por aquí el adelanto de los dos caminos —`confirm_charge` y
 * `confirm_charge_as_group`—, así que arreglarlo aquí los arregla los dos sin
 * tocar sus cuerpos, que son largos y se copian a mano.
 *
 * `p_amount` llega null exactamente cuando el comercio no tiene fila en
 * `merchant_settlement_terms`: el llamante calcula
 * `round(neto * v_terms.upfront_pct / 100, 4)` sobre un rowtype vacío. Por eso
 * null se puede leer como "faltan las condiciones" sin ambigüedad.
 */
create or replace function ledger.record_advance_settlement(
  p_merchant_id uuid, p_charge_id uuid, p_amount numeric, p_business_date date
)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if p_amount is null then
    raise exception
      'El comercio % no tiene condiciones de liquidación: configúralas antes de cobrar',
      p_merchant_id
      using errcode = '22023';
  end if;

  -- Un adelanto del 0% es una política válida (0/50/50), no un error. No hay
  -- nada que liquidar hoy, así que no se encola nada — encolarlo violaría el
  -- `check (amount_usd > 0)` de `settlements` y tumbaría la venta entera.
  if p_amount <= 0 then
    return;
  end if;

  insert into public.settlements
    (merchant_id, charge_id, reason, amount_usd, business_date, due_date, status)
  values
    (p_merchant_id, p_charge_id, 'advance', p_amount, p_business_date, p_business_date, 'pending');
end;
$$;

revoke all on function ledger.record_advance_settlement(uuid, uuid, numeric, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. El cron: un comercio mal configurado no puede dejar sin cobrar al resto
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260827100000 salvo los tres bloques marcados.

create or replace function public.run_scheduled_settlements(p_business_date date)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_charge record;
  v_terms  public.merchant_settlement_terms%rowtype;
  v_amount numeric(18,4);
  v_count  integer := 0;
begin
  -- Un consumo por vuelta, no una cuota por vuelta: en un consumo de mesa hay
  -- una cuota por integrante venciendo el mismo día y todas hablan de la misma
  -- venta (ver 20260827080000).
  for v_charge in
    select distinct c.id as charge_id, c.merchant_id,
           coalesce(c.merchant_net_usd, c.amount_usd) as net_usd
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.due_date = p_business_date
  loop
    -- NUEVO: cada consumo en su propio bloque. Antes, una fila que reventara
    -- abortaba la función entera y ese día no cobraba NINGÚN comercio; el
    -- fallo de uno se llevaba la liquidación de todos.
    begin
      select * into v_terms from public.merchant_settlement_terms
      where merchant_id = v_charge.merchant_id;

      -- NUEVO: `null <> 'scheduled'` es null, no true, así que un comercio sin
      -- condiciones NO entraba por este `continue` y seguía hasta reventar con
      -- un importe null. El `coalesce` lo manda por donde debía ir desde el
      -- principio.
      if coalesce(v_terms.policy, '') <> 'scheduled' then
        continue;
      end if;

      if exists (
        select 1 from public.settlements
        where charge_id = v_charge.charge_id
          and reason = 'scheduled_installment'
          and business_date = p_business_date
      ) then
        continue;
      end if;

      v_amount := round(v_charge.net_usd * v_terms.per_installment_pct / 100, 4);

      -- NUEVO: un tramo del 0% es política válida. No hay nada que encolar, y
      -- encolarlo violaría el `check (amount_usd > 0)`.
      if v_amount <= 0 then
        continue;
      end if;

      insert into public.settlements
        (merchant_id, charge_id, installment_id, reason, amount_usd, business_date, due_date, status)
      values
        (v_charge.merchant_id, v_charge.charge_id, null, 'scheduled_installment',
         v_amount, p_business_date, p_business_date, 'pending');

      v_count := v_count + 1;
    exception when others then
      -- Al log de Postgres, y el bucle sigue. Es un cron sin nadie delante:
      -- callar sería peor, pero parar el resto también.
      raise warning 'Liquidación programada fallida para el consumo % (comercio %): %',
        v_charge.charge_id, v_charge.merchant_id, sqlerrm;
    end;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.run_scheduled_settlements(date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Cobrar al grupo: con el importe consentido y con el iniciador dentro
-- ---------------------------------------------------------------------------
-- La firma de cuatro argumentos se elimina más abajo. Cuerpo idéntico al de
-- 20260828010000_cobrar_al_grupo salvo los bloques marcados NUEVO.

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

    select monthly_limit_usd into v_limit
    from public.levels l
    join public.profiles p on p.level = l.level
    where p.id = v_row.user_id;

    select * into v_block
    from public.user_credit_blocks
    where user_id = v_row.user_id and closed_at is null
    for update;

    if not found then
      insert into public.user_credit_blocks (user_id) values (v_row.user_id)
      returning * into v_block;
    end if;

    -- El límite del nivel es el tope duro y va por encima de cualquier techo
    -- de grupo. La capacidad ya lo respeta; esto es el cinturón.
    if v_block.charged_usd + v_share > v_limit then
      raise exception 'Alguien del grupo ya no tiene límite para $%', v_share
        using errcode = '22023';
    end if;

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, ledger.get_or_create_account('user_receivable', v_row.user_id), v_share, 0);

    insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
      (v_charge.id, v_row.user_id, 1, round(v_share / 2, 4), v_due_1),
      (v_charge.id, v_row.user_id, 2, v_share - round(v_share / 2, 4), v_due_2);

    -- El techo es acumulativo por la noche: aquí es donde se gasta.
    update public.group_members
      set spent_usd = spent_usd + v_share
    where group_id = v_group_id and user_id = v_row.user_id;

    update public.user_credit_blocks
      set charged_usd = charged_usd + v_share
    where id = v_block.id;
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
    'confirmed_at', v_confirmed_at
  );
end;
$function$
;

revoke all on function public.confirm_charge_as_group(uuid, uuid, text, text, numeric) from public, anon;
grant execute on function public.confirm_charge_as_group(uuid, uuid, text, text, numeric) to authenticated;

comment on function public.confirm_charge_as_group(uuid, uuid, text, text, numeric) is
  'Cobra una cuenta y la reparte en el grupo. Exige PIN y el importe que el usuario autorizó: si su parte subió mientras confirmaba, no se cobra.';

/**
 * La firma vieja se tapia.
 *
 * Dejarla viva sería dejar abierta la puerta que se acaba de cerrar: cobrar
 * sin decir qué importe se autorizó. Es el mismo movimiento que el de
 * 20260824170000 con el `confirm_charge` de dos argumentos.
 */
drop function if exists public.confirm_charge_as_group(uuid, uuid, text, text);
