-- ============================================================================
-- Ronda — El saldo se libera POR FACTURA, y en mora no se libera nada
--
-- Dos reglas del 2026-08-30 que van juntas porque una es la baranda de la otra.
--
-- ---------------------------------------------------------------------------
-- 1. Liberación por factura
-- ---------------------------------------------------------------------------
-- Hasta hoy el cupo volvía **solo al saldar TODA la deuda abierta**: el bloque
-- de crédito acumulaba lo cargado y no soltaba nada hasta cerrarse. Con dos
-- compras de $25, terminar de pagar una entera no devolvía ni un céntimo.
--
-- Ahora **cada compra devuelve su saldo en cuanto queda saldada**:
--
--     2 facturas de $25 → ocupado $50
--     pago las DOS cuotas de una → ocupado $25, disponible +$25
--
-- Dentro de una factura **no hay liberación parcial**: pagar una de sus dos
-- cuotas no devuelve la mitad. La unidad es la compra, no la cuota — si no,
-- pagar media factura devolvería cupo para empezar otra y la exposición dejaría
-- de estar acotada por el límite.
--
-- ---------------------------------------------------------------------------
-- 2. En mora, TODO el saldo bloqueado
-- ---------------------------------------------------------------------------
-- La liberación por factura abre un agujero que antes no existía: con dos
-- facturas y una vencida, terminar de pagar **la otra** te devolvería su cupo y
-- podrías seguir gastando estando moroso. No.
--
--     mientras haya UNA cuota vencida sin pagar → disponible = 0
--
-- No es solo "no se libera": es que el disponible entero se apaga. Ya no se
-- podía consumir —`can_take_debt` lo impedía desde 20260824140000— pero la app
-- seguía enseñando un saldo que no servía para nada, que es la peor forma de
-- decirlo.
--
-- ---------------------------------------------------------------------------
-- De dónde sale ahora el cupo ocupado
-- ---------------------------------------------------------------------------
-- De las CUOTAS, no del bloque. `user_credit_blocks` se queda con lo que sabe
-- hacer bien —el episodio de deuda: cargo por mora una vez por bloque, castigo
-- por incobrable, cuándo se saldó todo— y el cupo pasa a derivarse de
-- `installments.financed_usd`, que es donde vive la verdad por compra.
--
-- Cada cosa significa una cosa. Antes `charged_usd` intentaba ser las dos y por
-- eso no podía liberar por factura sin romper el cierre del bloque.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Estás en mora
-- ---------------------------------------------------------------------------
/**
 * Una cuota vencida y sin pagar. Nada más.
 *
 * Separada de `can_take_debt` a propósito, aunque una implique la otra:
 * `can_take_debt` mezcla el estado del perfil con la mora, y para apagar el
 * disponible hace falta exactamente la mora — si no, una cuenta que todavía no
 * ha pasado el KYC enseñaría $0 disponibles como si debiera algo.
 */
create or replace function public.helios_in_arrears(p_user uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select exists (
    select 1 from public.installments
    where user_id = p_user
      and status = 'pending'
      and due_date < public.helios_business_date(now())
  );
$$;

comment on function public.helios_in_arrears(uuid) is
  'Tiene al menos una cuota vencida sin pagar. Mientras sea cierto, el disponible es 0. Ver docs/00-BASES 2.2.';

revoke all on function public.helios_in_arrears(uuid) from public, anon;
grant execute on function public.helios_in_arrears(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El cupo ocupado, por factura
-- ---------------------------------------------------------------------------
/**
 * Lo que las compras sin saldar le ocupan del límite.
 *
 * Una compra ocupa cupo mientras le quede ALGUNA cuota pendiente, y lo ocupa
 * ENTERO — por eso el `exists` mira las cuotas del cobro y la suma las coge
 * todas, pagadas incluidas. Sumar solo las pendientes sería liberar media
 * factura al pagar su primera cuota, que es justo lo que no se quiere.
 */
create or replace function public.helios_credit_used_usd(p_user uuid)
returns numeric
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce(sum(i.financed_usd), 0)
  from public.installments i
  where i.user_id = p_user
    and exists (
      select 1 from public.installments j
      where j.charge_id = i.charge_id
        and j.user_id   = i.user_id
        and j.status    = 'pending'
    );
$$;

comment on function public.helios_credit_used_usd(uuid) is
  'Cupo ocupado: la suma de lo financiado de las compras que aun tienen alguna cuota pendiente. Se libera por COMPRA, no por cuota.';

revoke all on function public.helios_credit_used_usd(uuid) from public, anon;
grant execute on function public.helios_credit_used_usd(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El disponible
-- ---------------------------------------------------------------------------
/**
 * 🔁 Reescrita. Restaba `user_credit_blocks.charged_usd`, que solo bajaba al
 * cerrarse el bloque entero.
 *
 * La llaman `group_participants` (la capacidad de cada integrante) y
 * `claimant_capacity`, así que cambiando el cuerpo pasan a la regla nueva todas
 * a la vez — que es el motivo de que esta función existiera desde el principio.
 */
create or replace function public.available_usd(p_user uuid)
returns numeric
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select case
    -- En mora, TODO bloqueado. No solo lo de la factura vencida.
    when public.helios_in_arrears(p_user) then 0
    else greatest(
      coalesce((select l.monthly_limit_usd
                from public.profiles p
                join public.levels l on l.level = p.level
                where p.id = p_user), 0)
      - public.helios_credit_used_usd(p_user),
      0
    )
  end;
$$;

revoke all on function public.available_usd(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Lo que ve el usuario
-- ---------------------------------------------------------------------------
/**
 * Cuerpo reescrito sobre el de 20260830190000.
 *
 * `amount_to_unlock_usd` cambia de significado y hacía falta: con liberación por
 * factura, "lo que falta para recuperar el límite ENTERO" ya no es el número
 * accionable — lo es "lo que falta de la compra que tienes más cerca de saldar,
 * y cuánto te devuelve". Se devuelven los dos: el total sigue estando para quien
 * quiera dejarlo todo a cero.
 */
create or replace function public.my_available_balance()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user      uuid := auth.uid();
  v_level     smallint;
  v_limit     numeric(18,4);
  v_block     public.user_credit_blocks%rowtype;
  v_used      numeric(18,4) := 0;
  v_fee       numeric(18,4) := 0;
  v_to_unlock numeric(18,4) := 0;
  v_reserved  numeric(18,4) := 0;
  v_arrears   boolean := false;
  v_next_owed numeric(18,4);
  v_next_free numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select level into v_level from public.profiles where id = v_user;
  select monthly_limit_usd into v_limit from public.levels where level = v_level;

  v_arrears := public.helios_in_arrears(v_user);
  v_used    := public.helios_credit_used_usd(v_user);

  select * into v_block
  from public.user_credit_blocks
  where user_id = v_user and closed_at is null;

  if found then
    v_fee := v_block.fee_usd;
    -- Lo que falta para dejar la deuda a cero y recuperar el límite entero.
    v_to_unlock := v_block.charged_usd + v_block.fee_usd - v_block.paid_usd;
  end if;

  -- La compra a la que menos le falta, y cuánto cupo devuelve al saldarla. Es
  -- la frase que hace entender la regla nueva: "paga X y recuperas Y".
  select owed, frees into v_next_owed, v_next_free
  from (
    select
      sum(i.amount_usd) filter (where i.status = 'pending') as owed,
      sum(i.financed_usd)                                   as frees
    from public.installments i
    where i.user_id = v_user
      and exists (
        select 1 from public.installments j
        where j.charge_id = i.charge_id and j.user_id = i.user_id and j.status = 'pending'
      )
    group by i.charge_id
  ) c
  order by owed
  limit 1;

  v_reserved := public.group_holds_usd(v_user);

  return jsonb_build_object(
    'limit_usd', v_limit,
    -- 0 en mora, y no "el límite menos lo ocupado": mientras haya una cuota
    -- vencida no hay saldo que valga, ni el de una factura ya saldada.
    'available_usd', case
      when v_arrears then 0
      else greatest(v_limit - v_used - v_reserved, 0)
    end,
    -- NUEVO: para que la app pueda decir POR QUÉ el disponible es cero.
    'in_arrears', v_arrears,
    'open_debt_usd', v_used,
    'service_fee_usd', v_fee,
    'amount_to_unlock_usd', v_to_unlock,
    -- NUEVO: la siguiente compra que se libera.
    'next_unlock_owed_usd', v_next_owed,
    'next_unlock_frees_usd', v_next_free,
    'reserved_in_groups_usd', v_reserved
  );
end;
$$;

revoke all on function public.my_available_balance() from public, anon;
grant execute on function public.my_available_balance() to authenticated;

-- ---------------------------------------------------------------------------
-- 5. El límite, comprobado contra lo mismo que se enseña
-- ---------------------------------------------------------------------------
/**
 * Cuerpo idéntico al de 20260830190000 salvo el bloque marcado NUEVO.
 *
 * El tope se comprueba contra `helios_credit_used_usd`, no contra
 * `charged_usd`. Si se hubiera quedado mirando el bloque, alguien que acabara de
 * saldar una compra vería el saldo devuelto en la app y el cobro le rebotaría en
 * la caja — la peor forma posible de descubrir que dos números no cuadran.
 *
 * Las cuotas de ESTE cobro todavía no existen cuando se llama, así que la cuenta
 * es la de antes de esta compra, que es lo correcto.
 */
create or replace function public.helios_assign_debt(
  p_user          uuid,
  p_charge_id     uuid,
  p_financed_usd  numeric,
  p_payable_usd   numeric,
  p_due_1         date,
  p_due_2         date,
  p_over_limit_message text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_limit    numeric(18,4);
  v_block    public.user_credit_blocks%rowtype;
  v_used     numeric(18,4);
  v_first    numeric(18,4);
  v_second   numeric(18,4);
  v_fin_1    numeric(18,4);
  v_fin_2    numeric(18,4);
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

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  v_used := public.helios_credit_used_usd(p_user);

  if v_used + p_financed_usd > v_limit then
    raise exception '%', p_over_limit_message using errcode = '22023';
  end if;
  -- ─────────────────────────────────────────────────────────────────────────

  -- Dos decimales y el resto a la segunda: a cuatro se guardaban cuotas de
  -- medio céntimo, impagables y que al formatear no sumaban el total. Las dos
  -- cifras se parten igual para que la suma de `financed_usd` de las cuotas
  -- siga siendo exactamente lo que se sumó al bloque.
  v_first  := round(p_payable_usd / 2, 2);
  v_second := p_payable_usd - v_first;
  v_fin_1  := round(p_financed_usd / 2, 2);
  v_fin_2  := p_financed_usd - v_fin_1;

  insert into public.installments
    (charge_id, user_id, sequence, amount_usd, due_date, financed_usd) values
    (p_charge_id, p_user, 1, v_first,  p_due_1, v_fin_1),
    (p_charge_id, p_user, 2, v_second, p_due_2, v_fin_2);

  update public.user_credit_blocks
    set charged_usd = charged_usd + p_financed_usd,
        fee_usd     = fee_usd + (p_payable_usd - p_financed_usd)
  where id = v_block.id;

  return jsonb_build_object(
    'installment_1_usd', v_first,
    'installment_2_usd', v_second,
    'financed_usd', p_financed_usd,
    'payable_usd', p_payable_usd
  );
end;
$$;

revoke all on function public.helios_assign_debt(uuid, uuid, numeric, numeric, date, date, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. El aviso temprano del cobro individual
-- ---------------------------------------------------------------------------
-- `confirm_charge` comprueba el saldo ANTES de mover nada, para poder decir la
-- cifra concreta que falta. Leía `charged_usd`; pasa a leer lo mismo que el
-- resto. Solo cambia ese `select`: el cuerpo entero se reemitiría igual, así que
-- se hace con el mínimo ruido posible.
create or replace function public.confirm_charge(p_charge_id uuid, p_idempotency_key text, p_pin text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'ledger', 'pg_temp'
as $function$
declare
  v_user        uuid := auth.uid();
  v_pin       jsonb;
  v_charge      public.charges%rowtype;
  v_profile     public.profiles%rowtype;
  v_limit       numeric(18,4);
  v_open_debt   numeric(18,4);
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
  v_financed    numeric(18,4);
  v_split       jsonb;
  v_first       numeric(18,4);
  v_second      numeric(18,4);
  v_confirmed_at timestamptz;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- El PIN, antes de tocar nada. Un PIN incorrecto se DEVUELVE, no se lanza:
  -- un `raise` revertiría el intento fallido recién anotado y convertiría este
  -- cobro en un oráculo para probar PINes sin límite ni rastro.
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

  -- La mora, comprobada AQUÍ y no heredada del cron: `profiles.status` lo mueve
  -- `process_mora` a las 10:05 pero el día operativo cambia a las 10:00.
  if not public.can_take_debt(v_user) then
    raise exception 'Tienes una cuota vencida: págala para volver a consumir'
      using errcode = '22023';
  end if;

  -- Lo que financia Ronda, que es lo único que ocupa cupo. En los cobros
  -- anteriores al desglose la base es nula y el total ERA la base.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);

  select monthly_limit_usd into v_limit from public.levels where level = v_profile.level;

  -- NUEVO: el cupo ocupado sale de las cuotas, que es de donde sale el
  -- disponible que el usuario tenía delante.
  v_open_debt := public.helios_credit_used_usd(v_user);

  if v_open_debt + v_financed > v_limit then
    raise exception 'Saldo insuficiente: disponible $%, consumo $%',
      (v_limit - v_open_debt), v_financed
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

  -- Las cuatro patas de una vez, saltándose las que valen cero: `entries` tiene
  -- un check que rechaza un asiento con debe y haber en cero.
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
  perform ledger.record_advance_settlement(v_charge.merchant_id, v_charge.id, v_upfront, v_bdate);

  v_split  := public.helios_assign_debt(
    v_user, v_charge.id, v_financed, v_charge.amount_usd, v_due_1, v_due_2,
    format('Saldo insuficiente para un consumo de $%s',
           trim(to_char(v_financed, 'FM999999990.00')))
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
    'financed_usd', v_financed,
    'due_1', v_due_1, 'due_2', v_due_2,
    'installment_1_usd', v_first,
    'installment_2_usd', v_second,
    'confirmed_at', v_confirmed_at
  );
end;
$function$
;

revoke all on function public.confirm_charge(uuid, text, text) from public, anon;
grant execute on function public.confirm_charge(uuid, text, text) to authenticated;
