-- ============================================================================
-- Ronda — El QR de la orden: adjudicarse una parte después de pagar
--
-- Una orden ya pagada lleva su propio QR. Quien lo escanea entra en el reparto
-- de ESA cuenta: la cuenta se vuelve a dividir incluyéndolo, y a los que ya
-- estaban se les baja la parte.
--
-- Cubre dos casos con un solo mecanismo:
--
--   · EL QUE FALTÓ. Estaba en el baño, se quedó sin batería, llegó tarde. Se
--     le pasa el QR o el enlace y se lleva lo suyo.
--   · PAGUÉ YO Y LUEGO REPARTIMOS. Un cobro individual, sin mesa de por medio,
--     que se divide después. Es el flujo con el que empezó esta idea.
--
-- ---------------------------------------------------------------------------
-- La ventana: hasta el corte de las 10 AM, y por eso es seguro
-- ---------------------------------------------------------------------------
-- Reescribir una deuda que ya existe suena peligroso, y lo sería en cualquier
-- otro momento. Dentro del día operativo del consumo NO lo es, y no por
-- prudencia sino por aritmética:
--
--   · Ninguna cuota puede estar pagada. La cuota 1 vence en el próximo corte
--     con un colchón mínimo de SIETE días (docs/00 §2.2), así que dentro de la
--     misma noche no hay nada que se haya podido saldar.
--   · La mora no ha corrido: barre a las 10:05, ya fuera de la ventana.
--   · No hay Bits que deshacer: se dan al conciliar un pago, y no hay pagos.
--   · Las liquidaciones al comercio no se tocan. El total de la venta no
--     cambia: solo cambia entre cuántos se reparte.
--
-- Fuera de la ventana la deuda es de quien la asumió y no hay nada que hacer.
--
-- ---------------------------------------------------------------------------
-- La propiedad que hace que esto no pueda salir mal
-- ---------------------------------------------------------------------------
-- **A nadie le puede SUBIR la parte.** Es una propiedad del reparto en
-- cascada, no una comprobación: con el total fijo, meter a alguien con
-- capacidad solo puede bajar el nivel común `λ`, y cada parte es `min(techo,
-- λ)`. Si λ baja, ninguna parte sube.
--
-- Se apoya en ella una simplificación importante: **la capacidad de quien ya
-- debía se fija en su parte actual**. Da exactamente el mismo reparto que
-- mirarle el saldo otra vez —porque su parte nueva nunca va a ser mayor que la
-- vieja— y de paso hace imposible, por construcción, que un reparto posterior
-- le genere deuda nueva a alguien que no está delante del teléfono.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El token de la orden
-- ---------------------------------------------------------------------------

alter table public.charges
  add column if not exists share_token text unique;

/**
 * El QR/enlace de una orden ya pagada. Se genera la primera vez que se pide.
 *
 * Perezoso a propósito: no se toca `confirm_charge` ni `confirm_charge_as_tab`
 * para fabricarlo. La inmensa mayoría de las órdenes no se van a repartir
 * después, y el camino del cobro es el código más delicado del producto — no
 * se le añade trabajo para un caso minoritario.
 *
 * Solo lo puede pedir quien YA debe algo de esa orden. Un token de reparto es
 * una invitación a asumir deuda de una cuenta concreta, y quien la reparte
 * tiene que ser alguien que la pagó.
 */
create or replace function public.charge_share_token(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user   uuid := auth.uid();
  v_charge public.charges%rowtype;
  v_token  text;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found or v_charge.status <> 'confirmed' then
    raise exception 'Esa orden no existe o no está pagada' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.installments
    where charge_id = p_charge_id and user_id = v_user
  ) then
    raise exception 'No pagaste nada de esta orden' using errcode = '42501';
  end if;

  if public.helios_business_day_end(v_charge.business_date) <= now() then
    raise exception 'Esta orden ya se cerró: solo se puede repartir durante la misma noche'
      using errcode = '22023';
  end if;

  v_token := v_charge.share_token;

  if v_token is null then
    v_token := encode(extensions.gen_random_bytes(8), 'hex');
    update public.charges set share_token = v_token where id = p_charge_id;
  end if;

  return jsonb_build_object(
    'token', v_token,
    'closes_at', public.helios_business_day_end(v_charge.business_date)
  );
end;
$$;

revoke all on function public.charge_share_token(uuid) from public, anon;
grant execute on function public.charge_share_token(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Quiénes deben esta orden, y con cuánta capacidad para un reparto nuevo
-- ---------------------------------------------------------------------------
/**
 * La capacidad de quien ya debe es SU PARTE ACTUAL. Ver la cabecera: da el
 * mismo resultado que volver a mirarle el saldo, y garantiza que un reparto
 * posterior no pueda subirle la deuda a nadie.
 */
create or replace function public.charge_debtors(p_charge_id uuid)
returns table (user_id uuid, name text, share_usd numeric)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select i.user_id, p.full_name, sum(i.amount_usd)
  from public.installments i
  join public.profiles p on p.id = i.user_id
  where i.charge_id = p_charge_id
  group by i.user_id, p.full_name
  order by i.user_id;
$$;

revoke all on function public.charge_debtors(uuid) from public, anon, authenticated;

/**
 * Lo que puede poner quien se quiere adjudicar una parte.
 *
 * Si además está en la mesa que pagó la cuenta, su techo sigue mandando: una
 * adjudicación no es la puerta trasera para saltárselo.
 */
create or replace function public.claimant_capacity(p_user uuid, p_tab_id uuid)
returns numeric
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select greatest(least(
    public.available_usd(p_user),
    coalesce(
      (select m.cap_usd - m.spent_usd
       from public.tab_members m
       where m.tab_id = p_tab_id and m.user_id = p_user and m.left_at is null),
      public.available_usd(p_user)
    )
  ), 0);
$$;

revoke all on function public.claimant_capacity(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Lo que ve quien escanea, antes de comprometer nada
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
    'capacity_usd', public.claimant_capacity(v_user, v_charge.tab_id)
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

-- ---------------------------------------------------------------------------
-- 4. Adjudicarse la parte
-- ---------------------------------------------------------------------------
/**
 * Entrar en el reparto de una orden ya pagada. Exige PIN.
 *
 * Reescribe las cuotas de quienes ya debían —siempre A LA BAJA— y crea las
 * dos del que entra. Las fechas de vencimiento NO se recalculan: se copian de
 * las que ya tenía la orden, porque son las del día operativo del consumo.
 * Calcularlas de nuevo le daría más plazo a quien escanea más tarde, y dos
 * personas de la misma cuenta acabarían con fechas distintas en el mismo
 * ticket.
 *
 * En el libro contable NO se editan los asientos del cobro original: se pone
 * un asiento nuevo que mueve el cobrable de unos a otro. Un libro se escribe
 * hacia adelante; corregir el pasado es cómo se pierde la pista de lo que
 * realmente ocurrió.
 */
create or replace function public.claim_charge_share(
  p_token text,
  p_pin   text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
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

  if public.helios_business_day_end(v_charge.business_date) <= now() then
    raise exception 'Esta orden ya se cerró: solo se reparte durante la misma noche'
      using errcode = '22023';
  end if;

  if exists (select 1 from public.installments
             where charge_id = v_charge.id and user_id = v_user) then
    raise exception 'Ya tienes una parte de esta orden' using errcode = '22023';
  end if;

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes asumir deuda nueva' using errcode = '22023';
  end if;

  -- Se bloquean las cuotas de la orden antes de leerlas: dos personas
  -- escaneando el mismo QR a la vez no pueden repartir cada una sobre la foto
  -- vieja.
  perform 1 from public.installments
  where charge_id = v_charge.id order by user_id, sequence for update;

  for v_row in select * from public.charge_debtors(v_charge.id) loop
    v_parts := v_parts || jsonb_build_object(
      'user_id', v_row.user_id, 'capacity_usd', v_row.share_usd
    );
    v_count := v_count + 1;
  end loop;

  v_parts := v_parts || jsonb_build_object(
    'user_id', v_user,
    'capacity_usd', public.claimant_capacity(v_user, v_charge.tab_id)
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

    v_half := round(v_new / 2, 4);

    update public.installments set amount_usd = v_half
    where charge_id = v_charge.id and user_id = v_row.user_id and sequence = 1;
    update public.installments set amount_usd = v_new - v_half
    where charge_id = v_charge.id and user_id = v_row.user_id and sequence = 2;

    update public.user_credit_blocks
      set charged_usd = charged_usd - v_delta
    where user_id = v_row.user_id and closed_at is null;

    -- Si la orden salió de una mesa, el techo gastado también se libera.
    if v_charge.tab_id is not null then
      update public.tab_members
        set spent_usd = greatest(spent_usd - v_delta, 0)
      where tab_id = v_charge.tab_id and user_id = v_row.user_id;
    end if;

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, ledger.get_or_create_account('user_receivable', v_row.user_id), 0, v_delta);

    perform public.notify(
      v_row.user_id,
      'tab_charge',
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

  v_half := round(v_mine / 2, 4);

  insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
    (v_charge.id, v_user, 1, v_half, v_due_1),
    (v_charge.id, v_user, 2, v_mine - v_half, v_due_2);

  update public.user_credit_blocks
    set charged_usd = charged_usd + v_mine
  where id = v_block.id;

  if v_charge.tab_id is not null then
    update public.tab_members
      set spent_usd = spent_usd + v_mine
    where tab_id = v_charge.tab_id and user_id = v_user and left_at is null;
  end if;

  insert into ledger.entries (transaction_id, account_id, debit, credit)
  values (v_tx, ledger.get_or_create_account('user_receivable', v_user), v_mine, 0);

  return jsonb_build_object(
    'ok', true,
    'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'share_usd', v_mine,
    'split_between', (v_split->>'split_between')::integer,
    'due_1', v_due_1,
    'due_2', v_due_2
  );
end;
$$;

revoke all on function public.claim_charge_share(text, text) from public, anon;
grant execute on function public.claim_charge_share(text, text) to authenticated;
