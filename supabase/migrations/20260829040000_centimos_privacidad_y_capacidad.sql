-- ============================================================================
-- Ronda — Céntimos que no existen, crédito ajeno a la vista, y capacidad nula
--
-- Seis arreglos que comparten un tema: el servidor sabía la cifra buena y no
-- la decía, o decía de más.
--
-- ── 1. CUOTAS DE MEDIO CÉNTIMO ──────────────────────────────────────────────
--
-- Las tres funciones que crean deuda partían el importe con `round(x / 2, 4)`.
-- Una parte de $20,05 daba dos cuotas de $10,025: un importe que no se puede
-- transferir, que ninguna pantalla puede escribir honestamente y que al
-- formatearse a dos decimales sale $10,03 dos veces — $20,06, un céntimo más
-- que la deuda real.
--
-- Se parte a DOS decimales y el resto va a la segunda cuota:
--
--     cuota 1 = round(total / 2, 2)
--     cuota 2 = total − cuota 1
--
-- Suma exacta por construcción, las dos pagables. Es el mismo patrón de
-- "redondea una vez y el resto al otro lado" que ya usan la comisión y la
-- cascada del reparto; era el único sitio que no lo seguía.
--
-- Y las RPC devuelven ahora los DOS importes. El cliente los estaba
-- recalculando por su cuenta —`amount_usd / 2` en el acuse— así que la
-- pantalla podía enseñar una cifra y la base guardar otra.
--
-- ── 2. `confirm_charge` había perdido `confirmed_at` ────────────────────────
--
-- Regresión de 20260827110000 al copiar el cuerpo: 20260825120000 lo había
-- añadido. Sin él, el acuse de un cobro individual fecha con el reloj del
-- TELÉFONO, que es justo lo que ese cambio quitó de en medio — un móvil con la
-- hora mal imprime un comprobante que no cuadra ni con la base ni con el
-- ticket del local. Se restaura.
--
-- ── 3. El crédito ajeno quedaba a la vista para siempre ─────────────────────
--
-- `group_detail` comprobaba solo `left_at is null`, sin mirar la noche — y
-- `left_at` no se marca nunca al morir el grupo. Como `capacity_usd` es
-- `min(techo − gastado, disponible)` y el techo queda congelado, cualquiera
-- que compartió un grupo contigo UNA noche podía llamarla meses después y
-- leerte el saldo disponible actual.
--
-- El grupo muerto sigue siendo consultable —es tu historial y no se toca—
-- pero deja de decir lo que es de HOY: `capacity_usd` y `can_take_debt` salen
-- en null. El techo y lo gastado sí se quedan: son hechos de esa noche, no
-- datos vivos.
--
-- Y las dos funciones que ACTÚAN sobre un grupo —previsualizar un cobro y
-- mover el techo— se niegan sobre uno muerto. Solo `confirm_charge_as_group`
-- lo comprobaba, así que las de al lado seguían contestando sobre algo que ya
-- no existe.
--
-- ── 4. Mover el techo hacia arriba no pedía PIN ─────────────────────────────
--
-- Crear un grupo y entrar en él exigen PIN porque comprometen crédito. Subir
-- el techo compromete MÁS crédito —es el máximo que el grupo te puede cargar—
-- y era un toque sin autenticar: cualquiera con el teléfono desbloqueado
-- podía ponerlo al saldo entero. Ahora subirlo pide PIN. Bajarlo no: reducir
-- tu propia exposición no necesita ceremonia.
--
-- ── 5. Sin capacidad, la parte salía null y reventaba después del PIN ───────
--
-- `helios_split_shares` deja fuera en silencio a quien no llega al mínimo por
-- persona, y devuelve `ok:true` igual (los que ya debían siempre suman el
-- total). Ni el preview ni el claim miraban si el que pregunta quedó fuera:
-- el preview decía `ok:true` con la parte en null —pantalla rota— y el claim
-- se lo llevaba hasta un `not null violation` crudo DESPUÉS de teclear el PIN.
--
-- ── 6. Reclamar dos veces daba un error para algo que sí había salido ───────
--
-- `claim_charge_share` levantaba 'Ya tienes una parte de esta orden'. Quien
-- reclamó bien pero perdió la respuesta por la red veía un error y no
-- recuperaba nunca su acuse. Ahora esa vía devuelve la parte que ya tiene,
-- igual que hace `confirm_charge` con `already_confirmed`.
--
-- Además: índice único para la idempotencia del cron de liquidaciones, que se
-- comprobaba con un `exists` sin índice y sin constraint (dos corridas a la
-- vez encolaban el pago dos veces).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. La idempotencia del cron, por constraint y no por buena fe
-- ---------------------------------------------------------------------------
/**
 * `run_scheduled_settlements` comprobaba `exists (... charge_id, reason,
 * business_date)` y seguía. Entre la comprobación y el insert cabe otra
 * corrida —el cron solapado, o alguien lanzándolo a mano—, y las dos pasaban:
 * al comercio se le encolaba dos veces la misma cuota.
 *
 * El índice lo hace imposible, y de paso da el índice que esa consulta no
 * tenía (hoy es un scan por cada consumo que vence).
 */
create unique index if not exists settlements_scheduled_once
  on public.settlements (charge_id, reason, business_date)
  where charge_id is not null;

-- ---------------------------------------------------------------------------
-- 1. Cobro individual: céntimos de verdad, y la hora del servidor de vuelta
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260827110000 salvo los bloques marcados.

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
  -- NUEVO: las dos cuotas y la hora del servidor.
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

  -- NUEVO: dos decimales y el resto a la segunda. `round(x / 2, 4)` guardaba
  -- cuotas de medio céntimo que nadie puede transferir.
  v_first  := round(v_charge.amount_usd / 2, 2);
  v_second := v_charge.amount_usd - v_first;

  insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
    (v_charge.id, v_user, 1, v_first, v_due_1),
    (v_charge.id, v_user, 2, v_second, v_due_2);

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

-- ---------------------------------------------------------------------------
-- 2. Lo que se enseña antes de aceptar: con el IVA y la comisión desglosados
-- ---------------------------------------------------------------------------
/**
 * `preview_charge` no se actualizó cuando la facturación pasó a ser por cuenta
 * de terceros (20260827100000). Desde entonces `amount_usd` incluye IVA y
 * comisión del consumidor, pero las líneas que devuelve suman solo la base:
 * la pantalla donde se ACEPTA UNA DEUDA enseñaba unos productos que sumaban
 * $100 y un total de $127,60, sin nada en medio que lo explicara.
 *
 * Los datos ya estaban en `charges`. Solo había que decirlos.
 *
 * Del lado del comercio no se dice nada: su comisión y su neto son cosa suya
 * y del panel, no del cliente que paga.
 */
create or replace function public.preview_charge(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user    uuid := auth.uid();
  v_charge  public.charges%rowtype;
  v_name    text;
  v_legal   text;
  v_tax_id  text;
  v_branch  text;
  v_address text;
  v_logo    text;
  v_items   jsonb;
  v_avail   jsonb;
  v_rate    numeric(18,6);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  select m.name, m.legal_name, m.tax_id, b.name, b.address, m.logo_url
    into v_name, v_legal, v_tax_id, v_branch, v_address, v_logo
  from public.merchants m
  join public.merchant_branches b on b.id = v_charge.branch_id
  where m.id = v_charge.merchant_id;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'name', ci.name,
             'quantity', ci.quantity,
             'unit_price_usd', ci.unit_price_usd,
             'line_total_usd', ci.line_total_usd
           ) order by ci.position
         ), '[]'::jsonb)
  into v_items
  from public.charge_items ci
  where ci.charge_id = v_charge.id;

  v_avail := public.my_available_balance();
  v_rate  := public.current_fx_rate();

  return jsonb_build_object(
    'charge_id', v_charge.id,
    'order_number', v_charge.order_number,
    'merchant_name', v_name,
    -- Razón social y RIF: quién emite el cobro, tal como hay que nombrarlo
    -- para reclamar. Null en los comercios dados de alta antes de que el RIF
    -- fuera obligatorio (20260825170000); la app se calla en ese caso en vez
    -- de imprimir un hueco.
    'merchant_legal_name', v_legal,
    'merchant_tax_id', v_tax_id,
    'branch_name', v_branch,
    'branch_address', v_address,
    -- Null si el comercio todavía no cargó su logo: la app cae al disco con
    -- la inicial, que es lo que ya hace el buscador.
    'logo_url', v_logo,
    'amount_usd', v_charge.amount_usd,
    -- NUEVO: de dónde sale ese total. Null en los cobros anteriores al modelo
    -- de facturación por cuenta de terceros — la app enseña entonces solo el
    -- total, como hasta ahora.
    'base_usd', v_charge.base_usd,
    'vat_usd', v_charge.vat_usd,
    'consumer_fee_usd', v_charge.consumer_fee_usd,
    'consumer_fee_vat_usd', v_charge.consumer_fee_vat_usd,
    -- El precio se pacta en dólares (docs/05 §1), pero quien paga piensa en
    -- bolívares. Se manda la tasa junto al monto para que la app pueda decir
    -- con qué número lo convirtió.
    'amount_ves', case when v_rate is null then null else round(v_charge.amount_usd * v_rate, 2) end,
    'fx_rate', v_rate,
    'items', v_items,
    'status', v_charge.status,
    'expired', v_charge.expires_at < now(),
    -- Ya reclamado por otra persona: la app debe decirlo con claridad en vez
    -- de dejar al usuario reintentando un QR muerto.
    'claimed_by_other', v_charge.user_id is not null and v_charge.user_id <> v_user,
    'available_usd', (v_avail->>'available_usd')::numeric,
    'sufficient_balance',
      (v_avail->>'available_usd')::numeric >= v_charge.amount_usd
  );
end;
$$;

revoke all on function public.preview_charge(uuid) from public, anon;
grant execute on function public.preview_charge(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El grupo muerto: consultable, pero sin decir nada de hoy
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260828010000 salvo los bloques marcados.

create or replace function public.group_detail(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user  uuid := auth.uid();
  v_group public.groups%rowtype;
  v_mine  public.group_members%rowtype;
  v_avail numeric(18,4);
  -- NUEVO: ¿sigue vivo el grupo esta noche?
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

  v_alive := v_group.business_date = public.helios_business_date(now());

  return jsonb_build_object(
    'group_id',    v_group.id,
    'name',        v_group.name,
    'invite_code', v_group.invite_code,
    'created_by_me', v_group.created_by = v_user,
    'closes_at',   public.helios_business_day_end(v_group.business_date),
    -- NUEVO: la app ya no tiene que deducirlo de la fecha.
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
               -- NUEVO: la capacidad SÍ es de hoy —es `min(techo − gastado,
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
               'confirmed_at', c.confirmed_at,
               'started_by',  pr.full_name,
               'my_share_usd', (select sum(i.amount_usd) from public.installments i
                                where i.charge_id = c.id and i.user_id = v_user)
             ) order by c.confirmed_at desc), '[]'::jsonb)
      from public.charges c
      join public.merchants mm on mm.id = c.merchant_id
      left join public.profiles pr on pr.id = c.user_id
      where c.group_id = p_group_id and c.status = 'confirmed'
    )
  );
end;
$$;

revoke all on function public.group_detail(uuid) from public, anon;
grant execute on function public.group_detail(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Mover el techo: solo en un grupo vivo, y hacia arriba con PIN
-- ---------------------------------------------------------------------------
/**
 * La firma de dos argumentos se elimina abajo. Subir el techo es ampliar lo
 * que el grupo te puede cargar —el mismo compromiso que se firma con PIN al
 * entrar—, así que pide PIN. Bajarlo no: reducir tu propia exposición no
 * necesita ceremonia, y pedirla invitaría a dejar el techo alto por pereza.
 */
create or replace function public.set_my_group_cap(
  p_group_id uuid,
  p_cap_usd  numeric,
  p_pin      text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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

  -- NUEVO: un grupo de anoche no admite cambios. Cobrar ya lo comprobaba;
  -- esto contestaba igual y dejaba mover el techo de algo que ya murió.
  select * into v_group from public.groups where id = p_group_id;

  if v_group.business_date <> public.helios_business_date(now()) then
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
    raise exception 'Ya llevas $% en este grupo, el techo no puede bajar de ahí',
      v_mine.spent_usd using errcode = '22023';
  end if;

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu techo no puede bajar de $%', public.min_share_usd()
      using errcode = '22023';
  end if;

  v_avail := public.available_usd(v_user);

  -- El disponible ya tiene descontado lo gastado, así que el techo máximo es
  -- lo gastado más lo que queda.
  if p_cap_usd > v_mine.spent_usd + v_avail then
    raise exception 'Tu techo sería de $% y solo puedes llegar a $%',
      p_cap_usd, v_mine.spent_usd + v_avail using errcode = '22023';
  end if;

  update public.group_members set cap_usd = p_cap_usd
  where group_id = p_group_id and user_id = v_user;

  return jsonb_build_object('ok', true, 'cap_usd', p_cap_usd);
end;
$$;

revoke all on function public.set_my_group_cap(uuid, numeric, text) from public, anon;
grant execute on function public.set_my_group_cap(uuid, numeric, text) to authenticated;

-- La de dos argumentos se tapia: dejarla viva sería dejar la puerta sin PIN.
drop function if exists public.set_my_group_cap(uuid, numeric);

-- ---------------------------------------------------------------------------
-- 5. Previsualizar el reparto: no sobre un grupo muerto
-- ---------------------------------------------------------------------------
/**
 * Solo se añade la comprobación de la noche. El resto del cuerpo lo fija
 * 20260828010000 y no se toca, así que en vez de copiar 90 líneas se envuelve:
 * se comprueba y se delega.
 *
 * No se puede hacer con un `create or replace` parcial —una función se
 * sustituye entera— pero sí renombrando la de dentro. Aquí se hace al revés y
 * más simple: la comprobación vive en la que llama la app, y la vieja pasa a
 * ser privada.
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

  -- NUEVO: repartir en un grupo de anoche no significa nada. `confirm` ya lo
  -- rechazaba, así que dejar que el preview contestara era enseñar un reparto
  -- que no se puede cobrar — y era, de paso, por donde se leía la capacidad
  -- de crédito de gente de un grupo ya muerto.
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

  v_split  := public.helios_split_shares(v_charge.amount_usd, v_parts);
  v_shares := coalesce(v_split->'shares', '[]'::jsonb);

  for v_row in select * from public.group_participants(p_group_id) loop
    select (s->>'share_usd')::numeric into v_share
    from jsonb_array_elements(v_shares) s
    where (s->>'user_id')::uuid = v_row.user_id;

    if v_row.user_id = v_user then
      v_my := coalesce(v_share, 0);
    end if;

    v_rows := v_rows || jsonb_build_object(
      'user_id',      v_row.user_id,
      'name',         v_row.name,
      'is_me',        v_row.user_id = v_user,
      'cap_usd',      v_row.cap_usd,
      'spent_usd',    v_row.spent_usd,
      'capacity_usd', v_row.capacity_usd,
      'share_usd',    v_share,
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
    'split_between', v_split->'split_between',
    'capacity_usd',  v_split->'capacity_usd',
    'min_total_usd', v_split->'min_total_usd',
    'even_share_usd', case when v_eligible > 0
      then round(v_charge.amount_usd / v_eligible, 2) else null end,
    'my_share_usd',  v_my,
    'members',       v_rows
  );
end;
$$;

revoke all on function public.preview_group_charge(uuid, uuid) from public, anon;
grant execute on function public.preview_group_charge(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Tomar parte de una cuenta: sin capacidad se dice, y reclamar es idempotente
-- ---------------------------------------------------------------------------

create or replace function public.preview_charge_claim(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user     uuid := auth.uid();
  v_charge   public.charges%rowtype;
  v_parts    jsonb := '[]'::jsonb;
  v_split    jsonb;
  v_row      record;
  v_mine     numeric(18,4);
  v_merchant text;
  v_branch   text;
  v_logo     text;
  v_count    integer := 0;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_charge from public.charges where share_token = trim(p_token);
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  if public.helios_business_day_end(v_charge.business_date) <= now() then
    return jsonb_build_object('ok', false, 'reason', 'closed');
  end if;

  if exists (select 1 from public.installments
             where charge_id = v_charge.id and user_id = v_user) then
    return jsonb_build_object('ok', false, 'reason', 'already_in');
  end if;

  if not public.can_take_debt(v_user) then
    return jsonb_build_object('ok', false, 'reason', 'overdue');
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

  select m.name, b.name, m.logo_url into v_merchant, v_branch, v_logo
  from public.merchants m
  join public.merchant_branches b on b.id = v_charge.branch_id
  where m.id = v_charge.merchant_id;

  if not coalesce((v_split->>'ok')::boolean, false) then
    return jsonb_build_object(
      'ok', false,
      -- `too_small` aquí significa algo muy concreto: ya son demasiados para
      -- esta cuenta. Entrar dejaría a alguien por debajo del mínimo por
      -- persona, así que el que sobra es quien acaba de escanear.
      'reason', case when v_split->>'reason' = 'too_small'
                     then 'too_many' else 'no_capacity' end,
      'amount_usd', v_charge.amount_usd,
      'split_between', v_count,
      'merchant_name', v_merchant
    );
  end if;

  select (s->>'share_usd')::numeric into v_mine
  from jsonb_array_elements(v_split->'shares') s
  where (s->>'user_id')::uuid = v_user;

  -- NUEVO: `helios_split_shares` devuelve `ok:true` aunque a MÍ me haya dejado
  -- fuera — los que ya debían siempre suman el total por sí solos. Sin esto,
  -- la pantalla pintaba una parte en null y el claim reventaba después del PIN
  -- con un `not null violation` pelado.
  if v_mine is null then
    return jsonb_build_object(
      'ok', false,
      'reason', 'no_capacity',
      'amount_usd', v_charge.amount_usd,
      'split_between', v_count,
      'merchant_name', v_merchant
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'charge_id', v_charge.id,
    'order_number', v_charge.order_number,
    'merchant_name', v_merchant,
    'branch_name', v_branch,
    'logo_url', v_logo,
    'amount_usd', v_charge.amount_usd,
    'confirmed_at', v_charge.confirmed_at,
    'closes_at', public.helios_business_day_end(v_charge.business_date),
    -- Cuántos la pagan HOY y cuántos serían contigo.
    'split_between', v_count,
    'split_between_after', (v_split->>'split_between')::integer,
    'my_share_usd', v_mine
  );
end;
$$;

revoke all on function public.preview_charge_claim(text) from public, anon;
grant execute on function public.preview_charge_claim(text) to authenticated;

-- Cuerpo idéntico al de 20260829020000 salvo los bloques marcados.

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
  -- NUEVO: las dos cuotas del que entra.
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

  select monthly_limit_usd into v_limit
  from public.levels l join public.profiles p on p.level = l.level
  where p.id = v_user;

  select * into v_block from public.user_credit_blocks
  where user_id = v_user and closed_at is null for update;

  if not found then
    insert into public.user_credit_blocks (user_id) values (v_user) returning * into v_block;
  end if;

  if v_block.charged_usd + v_mine > v_limit then
    raise exception 'Tu límite no cubre $%', v_mine using errcode = '22023';
  end if;

  -- NUEVO: dos decimales, el resto a la segunda cuota.
  v_first  := round(v_mine / 2, 2);
  v_second := v_mine - v_first;

  insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
    (v_charge.id, v_user, 1, v_first, v_due_1),
    (v_charge.id, v_user, 2, v_second, v_due_2);

  update public.user_credit_blocks
    set charged_usd = charged_usd + v_mine
  where id = v_block.id;

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

-- ---------------------------------------------------------------------------
-- 7. Cobro en grupo: las mismas cuotas de dos decimales
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260829030000 salvo el reparto de las cuotas y los
-- dos importes nuevos en la respuesta.

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
  -- NUEVO: las dos cuotas, calculadas a dos decimales.
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

    -- NUEVO: dos decimales y el resto a la segunda. A cuatro se guardaban
    -- cuotas de medio céntimo, impagables y que al formatear no sumaban.
    v_first  := round(v_share / 2, 2);
    v_second := v_share - v_first;

    if v_row.user_id = v_user then
      v_my_first  := v_first;
      v_my_second := v_second;
    end if;

    insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
      (v_charge.id, v_row.user_id, 1, v_first, v_due_1),
      (v_charge.id, v_row.user_id, 2, v_second, v_due_2);

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
