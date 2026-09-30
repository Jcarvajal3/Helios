-- ============================================================================
-- Ronda — El fee del servicio deja de comerse el cupo del usuario
--
-- EL FALLO, y es de modelo, no de código
--
-- Desde la facturación por cuenta de terceros, `charges.amount_usd` es lo que
-- DEBE el consumidor —producto + fee + IVA del fee— y esa era la cifra que se
-- descontaba del límite de su nivel. Con un nivel de $50, una cuenta de $50 de
-- producto no pasaba: el cupo tenía que cubrir también nuestros $5,80.
--
-- No tiene sentido. **Ronda financia el producto, no su propia comisión.** El
-- fee lo paga el usuario con su dinero, junto a las cuotas; su saldo
-- disponible no puede encogerse porque nosotros cobremos.
--
-- ---------------------------------------------------------------------------
-- Las dos cifras, que a partir de aquí son distintas en todas partes
-- ---------------------------------------------------------------------------
--     FINANCIADO   lo que se consume y consume cupo  = charges.base_usd
--     PAGADERO     lo que se debe y se parte en dos  = charges.amount_usd
--
--   Base 100, nivel 1 ($50 de límite):
--     financiado ...... 100,00   ← contra el límite, contra el techo del grupo
--     pagadero ........ 111,60   ← dos cuotas de 55,80
--
-- ---------------------------------------------------------------------------
-- Dónde se guarda cada una
-- ---------------------------------------------------------------------------
--   `installments.financed_usd`     cuánto cupo representa esta cuota
--   `user_credit_blocks.charged_usd`  SOLO lo financiado → manda el disponible
--   `user_credit_blocks.fee_usd`      el fee acumulado → NO toca el disponible
--
-- El bloque se cierra cuando `paid_usd >= charged_usd + fee_usd`: la regla de
-- "el saldo vuelve al saldar el total" (docs/00-BASES §2.2) no cambia, y el
-- total incluye el fee porque el usuario lo debe.
--
-- **Por qué `financed_usd` va en la CUOTA y no solo en el bloque.** Repartir
-- una cuenta ya pagada (§2.8) reescribe las partes de quienes ya debían, y para
-- moverles el cupo hay que saber cuánto de su deuda era cupo. Derivarlo cada
-- vez de `base/total` acumula céntimos de deriva a cada reparto; guardado, la
-- suma de `financed_usd` ES el `charged_usd` del bloque, y eso se puede
-- comprobar.
--
-- ---------------------------------------------------------------------------
-- Lo que NO cambia
-- ---------------------------------------------------------------------------
-- **El asiento contable.** El usuario sigue debiendo 111,60 y el comercio sigue
-- cobrando 100: `user_receivable` se carga por el pagadero, igual que antes.
-- Lo único que se movió es a qué se compara el límite del nivel.
--
-- **El reparto en grupo sigue siendo el mismo algoritmo**, solo que reparte lo
-- FINANCIADO. Es lo coherente: el techo que cada quien puso al entrar es un
-- techo de crédito, no de facturación — hasta hoy el fee se lo comía también.
-- El fee de cada integrante cae sobre su parte, y el residuo de redondeo va al
-- último para que la suma cuadre al céntimo con el asiento.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La aritmética del fee, en un solo sitio
-- ---------------------------------------------------------------------------
/**
 * Lo que se PAGA por una parte financiada de un cobro.
 *
 * Un solo sitio por lo mismo que `helios_charge_breakdown`: los cuatro caminos
 * de cobro necesitan esta regla de tres y tres sitios que redondeen por su
 * cuenta son tres respuestas distintas para la misma venta.
 *
 * Con `base` en cero o nulo devuelve lo financiado tal cual — son los cobros
 * anteriores al desglose, donde el total ERA la base y no hay fee que añadir.
 */
create or replace function public.helios_payable_usd(
  p_financed_usd numeric,
  p_base_usd     numeric,
  p_total_usd    numeric
)
returns numeric
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$
  select case
    when coalesce(p_base_usd, 0) <= 0 or p_total_usd is null then p_financed_usd
    else round(p_financed_usd * p_total_usd / p_base_usd, 2)
  end;
$fn$;

comment on function public.helios_payable_usd(numeric, numeric, numeric) is
  'Lo que se paga por una parte financiada: le anade el fee del servicio y su IVA. Ver docs/00-BASES 2.11.';

revoke all on function public.helios_payable_usd(numeric, numeric, numeric) from public, anon;
grant execute on function public.helios_payable_usd(numeric, numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Cada cuota sabe cuánto cupo representa
-- ---------------------------------------------------------------------------

alter table public.installments
  add column if not exists financed_usd numeric(18,4);

-- Las cuotas que ya existen: se les reparte la base en la misma proporción en
-- que se les repartió el total. En los cobros sin desglose las dos cifras
-- coinciden y esto es la identidad.
update public.installments i
set financed_usd = case
      when c.base_usd is null or coalesce(c.amount_usd, 0) <= 0 then i.amount_usd
      else round(i.amount_usd * c.base_usd / c.amount_usd, 2)
    end
from public.charges c
where c.id = i.charge_id
  and i.financed_usd is null;

alter table public.installments
  alter column financed_usd set not null;

comment on column public.installments.financed_usd is
  'Cuanto CUPO representa esta cuota. amount_usd es lo que se paga (lleva el fee dentro); esta es la parte que descuenta del limite del nivel.';

-- ---------------------------------------------------------------------------
-- 3. El bloque separa cupo de fee
-- ---------------------------------------------------------------------------

alter table public.user_credit_blocks
  add column if not exists fee_usd numeric(18,4) not null default 0;

/**
 * Los bloques abiertos, reclasificados.
 *
 * `charged_usd` traía el pagadero entero; se le saca la parte de fee. La
 * atribución de cobros a bloque va por `confirmed_at >= opened_at`, que es
 * exacta: solo hay un bloque abierto por usuario a la vez y uno nuevo no nace
 * hasta que el anterior se cierra, así que un cobro pertenece al bloque que
 * estaba vivo cuando se confirmó.
 *
 * Los bloques ya CERRADOS no se tocan: su `charged_usd` es historia de lo que
 * de verdad se les cargó, y reescribirla no arregla nada que alguien vaya a
 * mirar.
 */
with por_bloque as (
  select b.id as block_id,
         coalesce(sum(i.amount_usd - i.financed_usd), 0) as fee
  from public.user_credit_blocks b
  join public.installments i on i.user_id = b.user_id
  join public.charges c      on c.id = i.charge_id
  where b.closed_at is null
    and c.confirmed_at >= b.opened_at
  group by b.id
)
update public.user_credit_blocks b
set fee_usd     = round(p.fee, 4),
    charged_usd = b.charged_usd - round(p.fee, 4)
from por_bloque p
where p.block_id = b.id
  and p.fee > 0
  and b.charged_usd >= round(p.fee, 4);

-- El invariante de pago sube con el fee: lo pagado cubre cupo Y fee.
alter table public.user_credit_blocks
  drop constraint if exists credit_blocks_paid_le_charged;

alter table public.user_credit_blocks
  add constraint credit_blocks_paid_le_owed
    check (paid_usd <= charged_usd + fee_usd);

comment on column public.user_credit_blocks.charged_usd is
  'Cupo consumido: SOLO lo financiado. Es lo que resta del limite del nivel. Desde 2026-08-30 NO incluye el fee del servicio.';
comment on column public.user_credit_blocks.fee_usd is
  'Fee del servicio y su IVA acumulados en este bloque. Se debe y hay que pagarlo para cerrar el bloque, pero NO consume cupo.';

-- ---------------------------------------------------------------------------
-- 4. Quién debe qué de un cobro
-- ---------------------------------------------------------------------------
-- Cambia el tipo de retorno, así que hay que tirarla y rehacerla.
drop function if exists public.charge_debtors(uuid);

/**
 * Los que ya deben algo de este cobro, con las dos cifras.
 *
 * `share_usd` sigue siendo lo que PAGAN —es lo que se enseña— y `financed_usd`
 * es lo que les consume de cupo, que es sobre lo que se vuelve a repartir
 * cuando entra alguien más.
 */
create or replace function public.charge_debtors(p_charge_id uuid)
returns table (user_id uuid, name text, share_usd numeric, financed_usd numeric)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select i.user_id, p.full_name, sum(i.amount_usd), sum(i.financed_usd)
  from public.installments i
  join public.profiles p on p.id = i.user_id
  where i.charge_id = p_charge_id
  group by i.user_id, p.full_name
  order by i.user_id;
$$;

revoke all on function public.charge_debtors(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. El único sitio que crea deuda, con las dos cifras
-- ---------------------------------------------------------------------------
-- Firma nueva: hay que tirar la vieja o quedarían las dos como sobrecargas y
-- una llamada con cinco argumentos elegiría la que ya no vale.
drop function if exists public.helios_assign_debt(uuid, uuid, numeric, date, date, text);

/**
 * La deuda de una persona por un cobro: bloque de crédito, tope del nivel y las
 * dos cuotas.
 *
 * 🔁 Recibe las DOS cifras desde el 2026-08-30:
 *
 *   `p_financed_usd`  lo que consume de cupo. Es lo que se compara con el
 *                     límite del nivel y lo que suma a `charged_usd`.
 *   `p_payable_usd`   lo que se debe. Es lo que se parte en las dos cuotas.
 *
 * El límite se comprueba contra lo FINANCIADO: ese es el cambio, y es el
 * motivo entero de esta migración.
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

  -- Contra lo FINANCIADO. El fee no ocupa cupo.
  if v_block.charged_usd + p_financed_usd > v_limit then
    raise exception '%', p_over_limit_message using errcode = '22023';
  end if;

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
-- 6. Cobro individual
-- ---------------------------------------------------------------------------
-- Idéntico al de 20260829080000 salvo los bloques marcados NUEVO: el saldo se
-- compara con lo financiado y la deuda se crea con las dos cifras.
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
  -- NUEVO: lo que consume cupo, separado de lo que se paga.
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

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- Lo que financia Ronda, que es lo único que ocupa cupo. En los cobros
  -- anteriores al desglose la base es nula y el total ERA la base.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);
  -- ─────────────────────────────────────────────────────────────────────────

  select monthly_limit_usd into v_limit from public.levels where level = v_profile.level;

  select coalesce(charged_usd, 0) into v_open_debt
  from public.user_credit_blocks
  where user_id = v_user and closed_at is null;

  -- NUEVO: contra lo financiado, no contra el total. El mensaje también, que es
  -- lo accionable para quien está en la caja.
  if coalesce(v_open_debt, 0) + v_financed > v_limit then
    raise exception 'Saldo insuficiente: disponible $%, consumo $%',
      (v_limit - coalesce(v_open_debt, 0)), v_financed
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
  -- un check que rechaza un asiento con debe y haber en cero, y hay dos casos
  -- reales que lo producen (comisión 0, y los cobros sin IVA).
  --
  -- El receivable sigue cargándose por el TOTAL: el usuario debe el fee aunque
  -- no le ocupe cupo. El asiento no cambia en nada.
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

  -- NUEVO: las dos cifras. El cobro individual es el caso exacto — lo pagadero
  -- ES el total del cobro, sin regla de tres que redondee.
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
    -- NUEVO: lo que se descontó del saldo, para que el acuse lo pueda decir.
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

-- ---------------------------------------------------------------------------
-- 7. Cobro repartido en grupo
-- ---------------------------------------------------------------------------
-- Idéntico al de 20260829080000 salvo los bloques marcados NUEVO. Lo que se
-- reparte pasa a ser lo FINANCIADO: el techo que cada quien puso al entrar es
-- un techo de crédito, y hasta hoy se lo comía también nuestro fee.
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
  v_debt     jsonb;
  v_first    numeric(18,4);
  v_second   numeric(18,4);
  v_my_first numeric(18,4);
  v_my_second numeric(18,4);
  -- NUEVO: lo financiado del cobro, el pagadero de cada quien y el acumulado
  -- que hace que la suma cuadre al céntimo con el asiento.
  v_financed  numeric(18,4);
  v_payable   numeric(18,4);
  v_assigned  numeric(18,4) := 0;
  v_i         integer := 0;
  v_my_payable numeric(18,4) := 0;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- Sin importe esperado no se cobra. Es el consentimiento del usuario traído
  -- hasta aquí; dejarlo opcional sería no tenerlo.
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

  -- El que inicia tiene que poder asumir su parte: sin esto, alguien con una
  -- cuota vencida quedaba fuera del reparto y la venta salía repartida solo
  -- entre los demás.
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

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- Se reparte lo FINANCIADO. Las capacidades son de crédito (techo menos
  -- gastado, contra el saldo disponible), así que el total que se reparte tiene
  -- que estar en la misma moneda.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);
  v_split := public.helios_split_shares(v_financed, v_parts);
  -- ─────────────────────────────────────────────────────────────────────────

  if not coalesce((v_split->>'ok')::boolean, false) then
    if v_split->>'reason' = 'too_small' then
      raise exception 'Entre % la cuenta mínima es $% y esta es de $%',
        v_split->>'split_between', v_split->>'min_total_usd', v_financed
        using errcode = '22023';
    else
      raise exception 'El grupo llega a $% y la cuenta es de $%',
        v_split->>'capacity_usd', v_financed
        using errcode = '22023';
    end if;
  end if;

  v_shares := v_split->'shares';
  v_count  := (v_split->>'split_between')::integer;

  -- El iniciador tiene que salir en el reparto: si su techo se agotó o su saldo
  -- no llega al mínimo por persona, la cuenta entera caería sobre los demás.
  select (s->>'share_usd')::numeric into v_my
  from jsonb_array_elements(v_shares) s
  where (s->>'user_id')::uuid = v_user;

  if v_my is null then
    raise exception 'No te alcanza para poner tu parte de esta cuenta'
      using errcode = '22023';
  end if;

  -- Y esa parte no puede pasarse de la que se autorizó con el PIN. Solo hacia
  -- arriba: que baje no perjudica a quien paga. El céntimo de tolerancia es por
  -- el viaje del número en coma flotante desde el teléfono.
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
    v_i := v_i + 1;

    -- ── NUEVO ──────────────────────────────────────────────────────────────
    -- El fee de cada quien cae sobre su parte. **El residuo de redondeo va al
    -- último** y no se reparte: la suma de los pagaderos tiene que dar EXACTO
    -- el total del cobro, porque es la contrapartida del asiento de arriba y el
    -- libro cuadra al céntimo o no cuadra.
    if v_i = v_count then
      v_payable := v_charge.amount_usd - v_assigned;
    else
      v_payable := public.helios_payable_usd(v_share, v_financed, v_charge.amount_usd);
    end if;
    v_assigned := v_assigned + v_payable;
    -- ───────────────────────────────────────────────────────────────────────

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, ledger.get_or_create_account('user_receivable', v_row.user_id), v_payable, 0);

    v_debt   := public.helios_assign_debt(
      v_row.user_id, v_charge.id, v_share, v_payable, v_due_1, v_due_2,
      format('Alguien del grupo ya no tiene límite para $%s',
             trim(to_char(v_share, 'FM999999990.00')))
    );
    v_first  := (v_debt->>'installment_1_usd')::numeric;
    v_second := (v_debt->>'installment_2_usd')::numeric;

    if v_row.user_id = v_user then
      v_my_first   := v_first;
      v_my_second  := v_second;
      v_my_payable := v_payable;
    end if;

    -- El techo es acumulativo por la noche: aquí es donde se gasta. Se gasta lo
    -- FINANCIADO, que es de lo que es techo.
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
    -- NUEVO: lo financiado del cobro entero y lo mío, en las dos monedas.
    'financed_usd', v_financed,
    'split_between', v_count,
    'share_usd', v_my,
    'my_payable_usd', v_my_payable,
    'even_share_usd', round(v_financed / v_count, 2),
    'due_1', v_due_1,
    'due_2', v_due_2,
    'installment_1_usd', v_my_first,
    'installment_2_usd', v_my_second,
    'confirmed_at', v_confirmed_at
  );
end;
$function$
;

revoke all on function public.confirm_charge_as_group(uuid, uuid, text, text, numeric) from public, anon;
grant execute on function public.confirm_charge_as_group(uuid, uuid, text, text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Repartir una cuenta ya pagada
-- ---------------------------------------------------------------------------
-- Idéntico al de 20260829080000 salvo los bloques marcados NUEVO. Es el camino
-- que REESCRIBE deuda existente, así que es donde `installments.financed_usd`
-- se gana el sitio: sin él habría que deducir de `base/total` cuánto de la parte
-- de cada quien era cupo, y esa deducción acumula céntimos a cada reparto.
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
  v_count   integer := 0;
  v_debt    jsonb;
  v_first   numeric(18,4);
  v_second  numeric(18,4);
  -- NUEVO: las dos monedas y el mapa de pagaderos con el residuo ya repartido.
  v_financed   numeric(18,4);
  v_payables   jsonb := '{}'::jsonb;
  v_payable    numeric(18,4);
  v_new_pay    numeric(18,4);
  v_fin_delta  numeric(18,4);
  v_fee_delta  numeric(18,4);
  v_mine_pay   numeric(18,4);
  v_assigned   numeric(18,4) := 0;
  v_i          integer := 0;
  v_n          integer;
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

  -- Ya tengo mi parte → se devuelve, no se lanza. Quien reclamaba bien y perdía
  -- la respuesta por la red veía un error y no recuperaba nunca su acuse.
  if exists (select 1 from public.installments
             where charge_id = v_charge.id and user_id = v_user) then
    select sum(amount_usd), sum(financed_usd) into v_mine, v_financed
    from public.installments
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
      'share_usd', v_financed,
      'my_payable_usd', v_mine,
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

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- Las capacidades de los que ya debían son lo que tienen FINANCIADO, no lo
  -- que pagan: se está repartiendo cupo. La regla de "a quien ya debía se le
  -- fija la capacidad en su parte actual" (docs/00-BASES §2.8) no cambia — solo
  -- cambia en qué moneda se expresa.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);

  for v_row in select * from public.charge_debtors(v_charge.id) loop
    v_parts := v_parts || jsonb_build_object(
      'user_id', v_row.user_id, 'capacity_usd', v_row.financed_usd
    );
    v_count := v_count + 1;
  end loop;

  v_parts := v_parts || jsonb_build_object(
    'user_id', v_user,
    'capacity_usd', public.claimant_capacity(v_user, v_charge.group_id)
  );

  v_split := public.helios_split_shares(v_financed, v_parts);
  -- ─────────────────────────────────────────────────────────────────────────

  if not coalesce((v_split->>'ok')::boolean, false) then
    if v_split->>'reason' = 'too_small' then
      raise exception 'Ya son % en esta cuenta de $%: entrar dejaría a alguien por debajo del mínimo',
        v_count, v_financed using errcode = '22023';
    else
      raise exception 'No te alcanza el saldo para tomar una parte de esta cuenta'
        using errcode = '22023';
    end if;
  end if;

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- Los pagaderos de TODOS de una vez, con el residuo al último, ANTES de tocar
  -- nada. Tienen que sumar exactamente el total del cobro: lo que se le baja a
  -- los que ya debían es la contrapartida de lo que se le carga al que entra, y
  -- si no cuadran al céntimo el asiento no cuadra.
  v_n := (v_split->>'split_between')::integer;

  for v_row in
    select (s->>'user_id')::uuid as user_id, (s->>'share_usd')::numeric as share
    from jsonb_array_elements(v_split->'shares') s
    order by 1
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
  -- ─────────────────────────────────────────────────────────────────────────

  -- Las fechas del consumo, no las de hoy.
  select due_date into v_due_1 from public.installments
  where charge_id = v_charge.id and sequence = 1 limit 1;
  select due_date into v_due_2 from public.installments
  where charge_id = v_charge.id and sequence = 2 limit 1;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', 'claim:' || v_charge.id::text || ':' || v_user::text,
          v_charge.business_date, v_charge.id,
          format('Reparto posterior: entra 1 persona, ahora son %s', v_n))
  returning id into v_tx;

  -- --- A los que ya debían: se les baja ------------------------------------
  for v_row in select * from public.charge_debtors(v_charge.id) loop
    select (s->>'share_usd')::numeric into v_new
    from jsonb_array_elements(v_split->'shares') s
    where (s->>'user_id')::uuid = v_row.user_id;

    v_new     := coalesce(v_new, v_row.financed_usd);
    v_new_pay := coalesce((v_payables->>v_row.user_id::text)::numeric, v_row.share_usd);

    -- NUEVO: dos deltas. El de cupo mueve el bloque y el techo del grupo; el de
    -- pagadero mueve el libro y las cuotas.
    v_fin_delta := v_row.financed_usd - v_new;
    v_delta     := v_row.share_usd - v_new_pay;
    v_fee_delta := v_delta - v_fin_delta;

    continue when v_delta <= 0 and v_fin_delta <= 0;

    -- Dos decimales, el resto a la segunda cuota. Las dos cifras se parten
    -- igual, para que la suma de `financed_usd` siga siendo el cupo del bloque.
    v_half := round(v_new_pay / 2, 2);
    update public.installments
      set amount_usd = v_half, financed_usd = round(v_new / 2, 2)
    where charge_id = v_charge.id and user_id = v_row.user_id and sequence = 1;
    update public.installments
      set amount_usd = v_new_pay - v_half, financed_usd = v_new - round(v_new / 2, 2)
    where charge_id = v_charge.id and user_id = v_row.user_id and sequence = 2;

    update public.user_credit_blocks
      set charged_usd = charged_usd - v_fin_delta,
          fee_usd     = greatest(fee_usd - v_fee_delta, 0)
    where user_id = v_row.user_id and closed_at is null;

    -- Si la orden salió de un grupo, el techo gastado también se libera. Se
    -- libera CUPO, que es de lo que es techo.
    if v_charge.group_id is not null then
      update public.group_members
        set spent_usd = greatest(spent_usd - v_fin_delta, 0)
      where group_id = v_charge.group_id and user_id = v_row.user_id;
    end if;

    if v_delta > 0 then
      insert into ledger.entries (transaction_id, account_id, debit, credit)
      values (v_tx, ledger.get_or_create_account('user_receivable', v_row.user_id), 0, v_delta);
    end if;

    perform public.notify(
      v_row.user_id,
      'group_charge',
      'Tu parte bajó',
      format('Alguien más entró en la cuenta de $%s. Ahora pagas $%s.',
             trim(to_char(v_charge.amount_usd, 'FM999999990.00')),
             trim(to_char(v_new_pay, 'FM999999990.00'))),
      jsonb_build_object('charge_id', v_charge.id, 'amount_usd', v_new_pay)
    );
  end loop;

  -- --- Al que entra: su deuda ----------------------------------------------
  select (s->>'share_usd')::numeric into v_mine
  from jsonb_array_elements(v_split->'shares') s
  where (s->>'user_id')::uuid = v_user;

  -- Quedé fuera del reparto por no llegar al mínimo por persona. Sin esto, el
  -- null seguía hasta un `not null violation` crudo — después del PIN.
  if v_mine is null then
    raise exception 'No te alcanza para tomar una parte de esta cuenta'
      using errcode = '22023';
  end if;

  v_mine_pay := coalesce((v_payables->>v_user::text)::numeric,
                         public.helios_payable_usd(v_mine, v_financed, v_charge.amount_usd));

  v_debt   := public.helios_assign_debt(
    v_user, v_charge.id, v_mine, v_mine_pay, v_due_1, v_due_2,
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
  values (v_tx, ledger.get_or_create_account('user_receivable', v_user), v_mine_pay, 0);

  return jsonb_build_object(
    'ok', true,
    'already_claimed', false,
    'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'share_usd', v_mine,
    'my_payable_usd', v_mine_pay,
    'split_between', v_n,
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
-- 9. El saldo disponible
-- ---------------------------------------------------------------------------
/**
 * Cuerpo idéntico al de 20260824121000 salvo los bloques marcados NUEVO.
 *
 * `available_usd` no cambia de fórmula —sigue siendo límite menos cargado— y sin
 * embargo cambia de resultado, porque `charged_usd` ya no lleva el fee dentro.
 * Eso ERA el fallo.
 *
 * Lo que sí cambia de fórmula es `amount_to_unlock_usd`: para recuperar el cupo
 * hay que saldar la deuda entera, y el fee es deuda.
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
  v_charged   numeric(18,4) := 0;
  v_fee       numeric(18,4) := 0;
  v_to_unlock numeric(18,4) := 0;
  v_reserved  numeric(18,4) := 0;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select level into v_level from public.profiles where id = v_user;
  select monthly_limit_usd into v_limit from public.levels where level = v_level;

  select * into v_block
  from public.user_credit_blocks
  where user_id = v_user and closed_at is null;

  if found then
    -- El disponible cae con lo CARGADO, no con lo pagado: pagar una cuota no
    -- libera cupo nuevo (docs/00-BASES §2.2, "no hay liberación parcial").
    v_charged := v_block.charged_usd;
    v_fee     := v_block.fee_usd;
    -- NUEVO: lo que falta para liberar incluye el fee. Se debe, aunque no ocupe
    -- cupo, y el bloque no se cierra hasta que esté pagado.
    v_to_unlock := v_block.charged_usd + v_block.fee_usd - v_block.paid_usd;
  end if;

  v_reserved := public.group_holds_usd(v_user);

  return jsonb_build_object(
    'limit_usd', v_limit,
    'available_usd', greatest(v_limit - v_charged - v_reserved, 0),
    'open_debt_usd', v_charged,
    -- NUEVO: el fee que se debe y que NO ocupa cupo. La app lo necesita para
    -- poder explicar por qué "lo que falta para liberar" es mayor que "el saldo
    -- usado" — sin esto, las dos cifras se contradicen sin motivo visible.
    'service_fee_usd', v_fee,
    'amount_to_unlock_usd', v_to_unlock,
    -- Lo apartado en grupos y todavía sin gastar. No es deuda: no tiene cuotas
    -- ni vencimiento, y vuelve entero si el grupo se cierra sin usarlo.
    'reserved_in_groups_usd', v_reserved
  );
end;
$$;

revoke all on function public.my_available_balance() from public, anon;
grant execute on function public.my_available_balance() to authenticated;

-- ---------------------------------------------------------------------------
-- 10. El castigo por incobrable se lleva también el fee
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260830170000 salvo la línea marcada NUEVO. Sin ella
-- se castigaría solo el cupo y el receivable quedaría con el fee colgando.
create or replace function public.charge_off_user_debt(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_block  public.user_credit_blocks%rowtype;
  v_amount numeric(18,4);
  v_tx     uuid;
  v_acct_recv     uuid;
  v_acct_provision uuid;
begin
  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user_id and closed_at is null
  for update;

  if not found then
    return;
  end if;

  -- NUEVO: cupo + fee − pagado. Todo eso es receivable.
  v_amount := v_block.charged_usd + v_block.fee_usd - v_block.paid_usd;

  if v_amount <= 0 then
    update public.user_credit_blocks
      set closed_at = now(), close_reason = 'paid'
    where id = v_block.id;
    return;
  end if;

  v_acct_recv := ledger.get_or_create_account('user_receivable', p_user_id);
  v_acct_provision := ledger.get_or_create_account('bad_debt_provision', null);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'charge_off', 'charge_off:' || v_block.id::text, public.helios_business_date(now()),
    v_block.id, 'Castigo por mora > 30 días'
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_provision, v_amount, 0),
    (v_tx, v_acct_recv, 0, v_amount);

  update public.late_fees
    set status = 'written_off'
  where credit_block_id = v_block.id and status = 'pending';

  update public.user_credit_blocks
    set closed_at = now(), close_reason = 'charged_off'
  where id = v_block.id;
end;
$$;

revoke all on function public.charge_off_user_debt(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 11. El bloque se cierra cuando se ha pagado TODO, fee incluido
-- ---------------------------------------------------------------------------
/**
 * Un solo cambio sobre 20260830170000, y es de una línea: el cierre del bloque
 * compara contra `charged_usd + fee_usd`.
 *
 * Sin esto el bloque se cerraría al cubrir solo el cupo —el fee quedaría
 * impagado y el límite volvería entero—, que es justo el agujero que la regla
 * de "el saldo vuelve al saldar el total" existe para tapar.
 */
create or replace function public.reconcile_payment(
  p_report_id uuid,
  p_actor     uuid,
  p_approve   boolean,
  p_note      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_report    public.payment_reports%rowtype;
  v_quote     public.payment_quotes%rowtype;
  v_item      record;
  v_fee       public.late_fees%rowtype;
  v_fee_usd   numeric(18,4) := 0;
  v_bdate     date;
  v_tx        uuid;
  v_acct_recv uuid;
  v_acct_cash uuid;
  v_block     public.user_credit_blocks%rowtype;
  v_total     numeric(18,4) := 0;
  v_settled   numeric(18,4);
  v_done      integer := 0;
  v_expected  integer;
begin
  select * into v_report from public.payment_reports where id = p_report_id for update;
  if not found then
    raise exception 'Reporte no encontrado' using errcode = 'P0002';
  end if;

  if v_report.status not in ('reported', 'in_review') then
    raise exception 'Este reporte ya fue resuelto (%)', v_report.status using errcode = '22023';
  end if;

  if not p_approve then
    update public.payment_reports
      set status = 'rejected', reviewed_by = p_actor, reviewed_at = now(),
          rejection_note = p_note
    where id = p_report_id;

    return jsonb_build_object('ok', true, 'status', 'rejected');
  end if;

  select * into v_quote from public.payment_quotes where id = v_report.quote_id;

  select count(*) into v_expected
  from public.payment_quote_items where quote_id = v_quote.id;

  if v_expected = 0 then
    raise exception 'La cotización % no tiene cuotas', v_quote.id using errcode = '22023';
  end if;

  v_bdate := public.helios_business_date(now());
  v_acct_recv := ledger.get_or_create_account('user_receivable', v_report.user_id);
  v_acct_cash := ledger.get_or_create_account('cash', null);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'installment_payment', 'reconcile:' || p_report_id::text, v_bdate, p_report_id,
    format('Pago conciliado de %s cuota(s)', v_quote.installment_count)
  )
  returning id into v_tx;

  for v_item in
    select i.installment_id, i.amount_usd, c.merchant_id,
           t.policy, t.per_installment_pct,
           ins.due_date,
           ins.amount_usd as current_amount_usd
    from public.payment_quote_items i
    join public.installments ins on ins.id = i.installment_id
    join public.charges c on c.id = ins.charge_id
    left join public.merchant_settlement_terms t on t.merchant_id = c.merchant_id
    where i.quote_id = v_quote.id
    for update of ins
  loop
    if v_item.policy is null then
      raise exception
        'El comercio % no tiene condiciones de liquidación: configúralas antes de conciliar este pago',
        v_item.merchant_id
        using errcode = '22023';
    end if;

    if (select status from public.installments where id = v_item.installment_id) = 'paid' then
      raise exception 'La cuota % ya estaba pagada', v_item.installment_id using errcode = '22023';
    end if;

    if v_item.current_amount_usd is distinct from v_item.amount_usd then
      raise exception
        'La cuota % cambió de importe desde que se cotizó ($% cotizados, $% ahora): no se concilia hasta revisarlo',
        v_item.installment_id, v_item.amount_usd, v_item.current_amount_usd
        using errcode = '22023';
    end if;

    update public.installments
      set status = 'paid', paid_at = now()
    where id = v_item.installment_id;

    v_total := v_total + v_item.amount_usd;
    v_done  := v_done + 1;

    if v_item.policy = 'on_collection' then
      v_settled := round(v_item.amount_usd * v_item.per_installment_pct * 2 / 100, 4);

      insert into public.settlements
        (merchant_id, installment_id, reason, amount_usd, business_date, due_date, status)
      values
        (v_item.merchant_id, v_item.installment_id, 'on_collection', v_settled,
         v_bdate, v_bdate, 'pending');
    end if;
  end loop;

  if v_done <> v_expected then
    raise exception
      'Se saldaron % de % cuotas de la cotización %: no se concilia a medias',
      v_done, v_expected, v_quote.id
      using errcode = '22023';
  end if;

  -- El cargo por mora que viajaba en la cotización.
  if v_quote.late_fee_id is not null then
    select * into v_fee
    from public.late_fees where id = v_quote.late_fee_id for update;

    if not found or v_fee.status <> 'pending' then
      raise exception
        'El cargo por mora de esta cotización ya no está pendiente (%): revísalo antes de conciliar',
        coalesce(v_fee.status::text, 'no encontrado')
        using errcode = '22023';
    end if;

    if v_fee.amount_usd is distinct from v_quote.late_fee_usd then
      raise exception
        'El cargo por mora cambió de importe desde que se cotizó ($% cotizados, $% ahora): no se concilia hasta revisarlo',
        v_quote.late_fee_usd, v_fee.amount_usd
        using errcode = '22023';
    end if;

    update public.late_fees
      set status = 'paid', paid_at = now()
    where id = v_fee.id;

    v_fee_usd := v_fee.amount_usd;
    v_total   := v_total + v_fee_usd;
  end if;

  -- Lo único que mueve caja aquí es el dinero que ENTRÓ del usuario.
  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_cash, v_total, 0),
    (v_tx, v_acct_recv, 0, v_total);

  update public.payment_reports
    set status = 'reconciled', reviewed_by = p_actor, reviewed_at = now(),
        rejection_note = coalesce(p_note, rejection_note)
  where id = p_report_id;

  select * into v_block
  from public.user_credit_blocks
  where user_id = v_report.user_id and closed_at is null
  for update;

  if found then
    update public.user_credit_blocks
      set paid_usd = paid_usd + v_total
    where id = v_block.id;

    -- NUEVO: contra cupo + fee. El fee es deuda: hasta que esté pagado, el
    -- bloque sigue abierto y el límite sigue ocupado.
    if v_block.paid_usd + v_total >= v_block.charged_usd + v_block.fee_usd then
      update public.user_credit_blocks
        set closed_at = now(), close_reason = 'paid'
      where id = v_block.id;
    end if;
  end if;

  perform public.recompute_profile_mora_state(v_report.user_id);

  return jsonb_build_object(
    'ok', true, 'status', 'reconciled',
    'amount_usd', v_total,
    'installments', v_done,
    'late_fee_usd', v_fee_usd
  );
end;
$$;

revoke all on function public.reconcile_payment(uuid, uuid, boolean, text)
  from public, anon, authenticated;

comment on function public.reconcile_payment(uuid, uuid, boolean, text) is
  'Aprueba o rechaza un reporte de pago. Al aprobar salda TODAS las cuotas de la cotizacion y su cargo por mora, o no salda ninguna. El bloque se cierra cuando lo pagado cubre cupo Y fee.';

-- ---------------------------------------------------------------------------
-- 12. Los tres previews enseñan las DOS cifras
-- ---------------------------------------------------------------------------
-- Es lo que pidió el cambio: en la pantalla de aceptar hay que ver cuánto se
-- descuenta del saldo y cuánto se va a pagar, por separado. Y los previews de
-- grupo tienen que repartir sobre lo mismo que reparte `confirm`, o el guardia
-- de "tu parte cambió mientras confirmabas" saltaría en cada cobro.

/**
 * Cuerpo idéntico al de 20260829060000 salvo los bloques marcados NUEVO.
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
  v_financed numeric(18,4);
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

  -- NUEVO: lo que de verdad se descuenta del saldo.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);

  return jsonb_build_object(
    'charge_id', v_charge.id,
    'order_number', v_charge.order_number,
    'merchant_name', v_name,
    'merchant_legal_name', v_legal,
    'merchant_tax_id', v_tax_id,
    'branch_name', v_branch,
    'branch_address', v_address,
    'logo_url', v_logo,
    'amount_usd', v_charge.amount_usd,
    -- NUEVO: la cifra que ocupa cupo. En los cobros anteriores al desglose es
    -- igual que el total y la pantalla no tiene nada que separar.
    'financed_usd', v_financed,
    'base_usd', v_charge.base_usd,
    'vat_usd', v_charge.vat_usd,
    'consumer_fee_usd', v_charge.consumer_fee_usd,
    'consumer_fee_vat_usd', v_charge.consumer_fee_vat_usd,
    'amount_ves', case when v_rate is null then null else round(v_charge.amount_usd * v_rate, 2) end,
    'fx_rate', v_rate,
    'items', v_items,
    'status', v_charge.status,
    'expired', v_charge.expires_at < now(),
    'expires_at', v_charge.expires_at,
    'claimed_by_other', v_charge.user_id is not null and v_charge.user_id <> v_user,
    'available_usd', (v_avail->>'available_usd')::numeric,
    -- NUEVO: contra lo financiado. Comparar el saldo con el total era el fallo:
    -- rechazaba un consumo que el cupo sí cubre.
    'sufficient_balance',
      (v_avail->>'available_usd')::numeric >= v_financed
  );
end;
$$;

revoke all on function public.preview_charge(uuid) from public, anon;
grant execute on function public.preview_charge(uuid) to authenticated;

/**
 * Cuerpo idéntico al de 20260829040000 salvo los bloques marcados NUEVO.
 *
 * El reparto se calcula sobre lo FINANCIADO —igual que `confirm_charge_as_group`,
 * y con el mismo residuo al último— para que las dos funciones den exactamente
 * la misma cifra. Si divergieran, el guardia de `p_expected_share_usd` saltaría
 * en cobros perfectamente válidos.
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
  v_split  := public.helios_split_shares(v_financed, v_parts);
  v_shares := coalesce(v_split->'shares', '[]'::jsonb);

  -- NUEVO: los pagaderos, con el mismo residuo al último que usa `confirm`.
  v_n := coalesce((v_split->>'split_between')::integer, 0);
  for v_row in
    select (s->>'user_id')::uuid as user_id, (s->>'share_usd')::numeric as share
    from jsonb_array_elements(v_shares) s
    order by 1
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
    'my_share_usd',  v_my,
    'my_payable_usd', v_my_pay,
    'members',       v_rows
  );
end;
$$;

revoke all on function public.preview_group_charge(uuid, uuid) from public, anon;
grant execute on function public.preview_group_charge(uuid, uuid) to authenticated;

/**
 * Cuerpo idéntico al de 20260830130000 salvo los bloques marcados NUEVO.
 */
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
  v_items    jsonb;
  -- NUEVO
  v_financed numeric(18,4);
  v_mine_pay numeric(18,4);
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

  -- NUEVO: capacidades y total en CUPO, igual que `claim_charge_share`.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);

  for v_row in select * from public.charge_debtors(v_charge.id) loop
    v_parts := v_parts || jsonb_build_object(
      'user_id', v_row.user_id, 'capacity_usd', v_row.financed_usd
    );
    v_count := v_count + 1;
  end loop;

  v_parts := v_parts || jsonb_build_object(
    'user_id', v_user,
    'capacity_usd', public.claimant_capacity(v_user, v_charge.group_id)
  );

  v_split := public.helios_split_shares(v_financed, v_parts);

  select m.name, b.name, m.logo_url into v_merchant, v_branch, v_logo
  from public.merchants m
  join public.merchant_branches b on b.id = v_charge.branch_id
  where m.id = v_charge.merchant_id;

  -- Qué se consumió. Mismo formato y mismo orden que `preview_charge`, para que
  -- las dos pantallas puedan pintarlo con la misma tarjeta.
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

  if not coalesce((v_split->>'ok')::boolean, false) then
    return jsonb_build_object(
      'ok', false,
      'reason', case when v_split->>'reason' = 'too_small'
                     then 'too_many' else 'no_capacity' end,
      'amount_usd', v_charge.amount_usd,
      'financed_usd', v_financed,
      'split_between', v_count,
      'merchant_name', v_merchant
    );
  end if;

  select (s->>'share_usd')::numeric into v_mine
  from jsonb_array_elements(v_split->'shares') s
  where (s->>'user_id')::uuid = v_user;

  -- `helios_split_shares` devuelve `ok:true` aunque a MÍ me haya dejado fuera:
  -- los que ya debían siempre suman el total por sí solos.
  if v_mine is null then
    return jsonb_build_object(
      'ok', false,
      'reason', 'no_capacity',
      'amount_usd', v_charge.amount_usd,
      'financed_usd', v_financed,
      'split_between', v_count,
      'merchant_name', v_merchant
    );
  end if;

  -- NUEVO: lo que esa parte cuesta pagar. Aquí no hace falta el residuo: es una
  -- cifra para la pantalla, y la de verdad la fija `claim_charge_share`.
  v_mine_pay := public.helios_payable_usd(v_mine, v_financed, v_charge.amount_usd);

  return jsonb_build_object(
    'ok', true,
    'charge_id', v_charge.id,
    'order_number', v_charge.order_number,
    'merchant_name', v_merchant,
    'branch_name', v_branch,
    'logo_url', v_logo,
    'amount_usd', v_charge.amount_usd,
    'financed_usd', v_financed,
    'confirmed_at', v_charge.confirmed_at,
    'closes_at', public.helios_business_day_end(v_charge.business_date),
    'split_between', v_count,
    'split_between_after', (v_split->>'split_between')::integer,
    'my_share_usd', v_mine,
    'my_payable_usd', v_mine_pay,
    'items', v_items
  );
end;
$$;

revoke all on function public.preview_charge_claim(text) from public, anon;
grant execute on function public.preview_charge_claim(text) to authenticated;
