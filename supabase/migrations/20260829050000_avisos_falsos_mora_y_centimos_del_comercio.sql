-- ============================================================================
-- Ronda — Seis rebabas: un push que miente, la mora que depende del cron,
--         céntimos que no cierran, y el archivo que dejó de leerse
--
-- ── B1. "X entró al grupo" cuando X ya se había ido ─────────────────────────
--
-- El guardia del trigger dice "un update que solo mueve el techo no avisa":
--
--     if tg_op = 'UPDATE' and old.left_at is null then return null; end if;
--
-- Pero eso solo tapa los updates sobre alguien que SIGUE dentro. Un update
-- sobre una fila que ya tiene `left_at` se cuela — y `claim_charge_share` hace
-- exactamente eso: al repartir una cuenta le baja el `spent_usd` también a
-- quien ya salió del grupo (correcto: su deuda bajó de verdad). Resultado:
-- todo el grupo recibe "Fulano entró a <grupo>" por alguien que se fue hace
-- horas.
--
-- Se invierte el guardia: se avisa cuando la fila ENTRA de verdad —un insert,
-- o un update que resucita a quien se había ido— y en ningún otro caso. Así el
-- trigger es correcto venga el update de donde venga, en vez de ir tapando
-- llamantes de uno en uno.
--
-- ── B2. La mora del cobro individual dependía de que el cron estuviera vivo ──
--
-- Todas las vías de grupo comprueban `can_take_debt` en el momento del cobro
-- —"cierta por construcción, no porque el cron esté vivo", dice 20260824140000—
-- pero la individual, que es la más usada, solo miraba `profiles.status`. Ese
-- estado lo pone `process_mora` a las 10:05.
--
-- Entre el cambio de día operativo (10:00) y el barrido (10:05) hay cinco
-- minutos en los que alguien con una cuota recién vencida puede seguir
-- consumiendo — y si el cron falla, el agujero dura todo el día.
--
-- ── B3. Al comercio nunca se le terminaba de pagar, por céntimos ────────────
--
-- El neto se reparte en tres liquidaciones (30 / 35 / 35) y cada una se
-- redondeaba por su cuenta. Tres redondeos independientes no suman el total:
-- queda un residuo de medio céntimo por venta que se queda para siempre en
-- `merchant_payable`, así que la cuenta del comercio nunca cierra en cero.
--
-- Es el mismo patrón que ya usan la comisión y el reparto de la cascada, y era
-- el único sitio donde faltaba: **la última liquidación no lleva un
-- porcentaje, lleva lo que falte**. Se calcula como el neto menos lo ya
-- liquidado de ese consumo, así que cierra exacto por construcción.
--
-- ── B4. Un precio con milésimas descuadraba la factura ──────────────────────
--
-- `request_charge` acepta líneas de monto libre con el precio que mande el
-- panel. Con tres decimales, la suma de las líneas guardadas en `charge_items`
-- deja de coincidir con `charges.base_usd`, que nace redondeado a dos: el
-- comprobante enseña unas líneas que no suman su propio total.
--
-- ── B6. El archivo dejó de poder leerse ─────────────────────────────────────
--
-- `my_group_ids()` pasó a filtrar por la noche de hoy (20260828000000), y esa
-- misma función es la que sostiene las políticas RLS de lectura de `groups`,
-- `group_members` y `charges`. Sin querer, eso revocó el acceso al historial
-- que `20260827030000_retirar_grupos` había prometido por escrito.
--
-- Se parte en dos, que es lo que siempre fueron: `my_group_ids()` sigue
-- respondiendo "los de esta noche" —es la que usan las reglas de negocio— y
-- las políticas de LECTURA pasan a una nueva `my_group_ids_ever()`. Leer tu
-- propio historial y poder cargar contra un grupo son dos permisos distintos.
--
-- ── B8. El código de invitación salía de `random()` ─────────────────────────
--
-- `random()` no es criptográfico: su estado se puede reconstruir observando
-- suficientes salidas. El código de seis caracteres es lo ÚNICO que hay entre
-- un desconocido y ver los techos y la capacidad de crédito de un grupo
-- (quien entra pone su propio PIN, así que el código es la única puerta).
--
-- `gen_random_bytes` es lo que ya usan los tokens de reparto — misma casa,
-- mismo cuidado.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El aviso de "entró alguien", solo cuando entra alguien
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260828010000 salvo el guardia.

create or replace function public.notify_group_joined()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name   text;
  v_group  text;
  v_member record;
  v_count  integer;
begin
  /**
   * Solo se avisa cuando la fila ENTRA de verdad.
   *
   * Antes esto era `if tg_op = 'UPDATE' and old.left_at is null then return`,
   * que solo tapaba los updates sobre quien seguía dentro. Un update sobre una
   * fila YA marcada como salida se colaba, y `claim_charge_share` hace justo
   * eso al bajarle el gastado a quien se fue: el grupo entero recibía "Fulano
   * entró" por alguien que llevaba horas fuera.
   *
   * Dicho al revés, el trigger aguanta cualquier llamante futuro: avisa en el
   * insert, y en el update solo si resucita a quien se había ido.
   */
  if tg_op = 'UPDATE' and not (old.left_at is not null and new.left_at is null) then
    return null;
  end if;

  select coalesce(p.full_name, 'Alguien') into v_name
  from public.profiles p where p.id = new.user_id;
  select g.name into v_group from public.groups g where g.id = new.group_id;

  select count(*) into v_count from public.group_members
  where group_id = new.group_id and left_at is null;

  for v_member in
    select user_id from public.group_members
    where group_id = new.group_id and left_at is null and user_id <> new.user_id
  loop
    perform public.notify(
      v_member.user_id,
      'group_charge',
      format('%s entró a %s', v_name, coalesce(v_group, 'tu grupo')),
      format('Ya son %s. Lo que pague cualquiera se reparte entre todos hasta las 10 AM.',
             v_count),
      jsonb_build_object('group_id', new.group_id, 'user_id', new.user_id)
    );
  end loop;

  return null;
end;
$$;

revoke all on function public.notify_group_joined() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. El archivo se vuelve a leer, sin abrir la puerta de cobrar
-- ---------------------------------------------------------------------------
/**
 * TODOS los grupos en los que he estado, vivos o no.
 *
 * Es solo para LEER. La otra —`my_group_ids()`, la de esta noche— sigue
 * siendo la que decide dónde se puede cargar deuda, y no se toca: eran dos
 * preguntas distintas contestadas por la misma función, y por eso endurecer
 * una rompió la otra.
 */
create or replace function public.my_group_ids_ever()
returns setof uuid
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select m.group_id
  from public.group_members m
  where m.user_id = auth.uid();
$$;

revoke all on function public.my_group_ids_ever() from public, anon;
grant execute on function public.my_group_ids_ever() to authenticated;

-- Las tres políticas de lectura pasan al histórico. Ninguna de ellas autoriza
-- a escribir nada: son `for select`.
drop policy if exists "groups_read_own" on public.groups;
create policy "groups_read_own"
  on public.groups for select to authenticated
  using (id in (select public.my_group_ids_ever()));

drop policy if exists "group_members_read_own_groups" on public.group_members;
create policy "group_members_read_own_groups"
  on public.group_members for select to authenticated
  using (group_id in (select public.my_group_ids_ever()));

drop policy if exists "charges_read_group_member" on public.charges;
create policy "charges_read_group_member"
  on public.charges for select to authenticated
  using (group_id in (select public.my_group_ids_ever()));

-- ---------------------------------------------------------------------------
-- 3. El código de invitación, de un generador criptográfico
-- ---------------------------------------------------------------------------
create or replace function public.generate_invite_code()
returns text
language plpgsql
set search_path = public, pg_catalog, pg_temp
as $$
declare
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code text;
  v_i integer;
  v_today date := public.helios_business_date(now());
begin
  loop
    v_code := '';
    /**
     * Un byte por carácter, y el alfabeto tiene 32: 256 es múltiplo exacto de
     * 32, así que `% 32` NO introduce sesgo — cada letra sale con la misma
     * probabilidad. (Con un alfabeto que no dividiera a 256 habría que
     * rechazar y repetir; con 32 no hace falta.)
     */
    for v_i in 0..5 loop
      v_code := v_code || substr(
        v_alphabet,
        1 + (get_byte(extensions.gen_random_bytes(6), v_i) % 32),
        1
      );
    end loop;

    -- Solo choca con los grupos VIVOS: el de anoche ya no abre nada.
    exit when not exists (
      select 1 from public.groups
      where invite_code = v_code and business_date = v_today
    );
  end loop;

  return v_code;
end;
$$;

revoke all on function public.generate_invite_code() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. La última liquidación cierra la cuenta del comercio, al céntimo
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260829030000 salvo el bloque marcado.

create or replace function public.run_scheduled_settlements(p_business_date date)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_charge   record;
  v_terms    public.merchant_settlement_terms%rowtype;
  v_amount   numeric(18,4);
  v_count    integer := 0;
  -- NUEVO: para saber si esta es la última y cuánto se lleva liquidado.
  v_last_due date;
  v_settled  numeric(18,4);
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
    -- Cada consumo en su propio bloque: el fallo de uno no puede dejar sin
    -- liquidar a todos los demás ese día.
    begin
      select * into v_terms from public.merchant_settlement_terms
      where merchant_id = v_charge.merchant_id;

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

      /**
       * NUEVO: la ÚLTIMA no lleva porcentaje, lleva lo que falte.
       *
       * 30 % + 35 % + 35 % redondeados por separado no suman el neto: sobra o
       * falta medio céntimo por venta, y ese residuo se quedaba para siempre
       * en `merchant_payable` — la cuenta del comercio no cerraba nunca en
       * cero. Cerrando contra lo ya liquidado, cuadra por construcción.
       */
      select max(due_date) into v_last_due
      from public.installments where charge_id = v_charge.charge_id;

      if p_business_date >= v_last_due then
        select coalesce(sum(amount_usd), 0) into v_settled
        from public.settlements where charge_id = v_charge.charge_id;

        v_amount := v_charge.net_usd - v_settled;
      else
        v_amount := round(v_charge.net_usd * v_terms.per_installment_pct / 100, 4);
      end if;

      -- Un tramo del 0% es política válida, y en la última puede no quedar
      -- nada por liquidar. En los dos casos no hay nada que encolar, y
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
-- 5. El cobro individual comprueba la mora él mismo
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260829040000 salvo el bloque marcado.

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
-- 6. Ningún precio con más de dos decimales entra en un cobro
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260827100000 salvo el bloque marcado.

create or replace function public.request_charge(
  p_merchant_id     uuid,
  p_branch_id       uuid,
  p_items           jsonb,
  p_idempotency_key text
)
returns public.charges
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff   uuid := auth.uid();
  v_row     public.charges%rowtype;
  v_allowed boolean;
  v_item    jsonb;
  v_lines   jsonb := '[]'::jsonb;
  v_qty     integer;
  v_name    text;
  v_price   numeric(18,4);
  v_base    numeric(18,4);
  v_terms   public.merchant_settlement_terms%rowtype;
  v_b       jsonb;
begin
  if v_staff is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select exists (
    select 1 from public.merchant_users
    where user_id = v_staff
      and merchant_id = p_merchant_id
      and is_active
      and (branch_id is null or branch_id = p_branch_id)
  ) into v_allowed;

  if not v_allowed then
    raise exception 'No autorizado a cobrar en este comercio/sucursal' using errcode = '42501';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El cobro no tiene productos' using errcode = '22023';
  end if;

  if jsonb_array_length(p_items) > 100 then
    raise exception 'Demasiadas líneas en un mismo cobro' using errcode = '22023';
  end if;

  -- --- Resolver cada línea contra el catálogo ---------------------------
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_qty := coalesce((v_item->>'quantity')::integer, 1);

    if v_qty < 1 or v_qty > 999 then
      raise exception 'Cantidad no válida: %', v_qty using errcode = '22023';
    end if;

    if nullif(v_item->>'product_id', '') is not null then
      select p.name, p.price_usd into v_name, v_price
      from public.products p
      where p.id = (v_item->>'product_id')::uuid
        and p.merchant_id = p_merchant_id
        and p.is_active;

      if not found then
        raise exception 'Un producto del pedido ya no está en tu carta; quítalo y vuelve a intentar'
          using errcode = '22023';
      end if;
    else
      v_name  := coalesce(nullif(btrim(v_item->>'name'), ''), 'Consumo');
      v_price := (v_item->>'unit_price_usd')::numeric;

      if v_price is null or v_price < 0 then
        raise exception 'Precio no válido en una línea del cobro' using errcode = '22023';
      end if;
    end if;

    /**
     * NUEVO: nada de milésimas, venga de la carta o de una línea libre.
     *
     * `base_usd` nace redondeado a dos decimales pero las líneas se guardan
     * tal cual llegan, así que un precio con tres decimales hace que el
     * comprobante enseñe unas líneas que no suman su propio total. Se corta en
     * la entrada, que es donde se puede decir cuál es la línea mala.
     */
    if scale(v_price) > 2 then
      raise exception 'El precio de "%" tiene más de dos decimales', v_name
        using errcode = '22023';
    end if;

    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'product_id',     nullif(v_item->>'product_id', ''),
      'name',           v_name,
      'unit_price_usd', v_price,
      'quantity',       v_qty
    ));
  end loop;

  select sum(round((l->>'unit_price_usd')::numeric * (l->>'quantity')::integer, 4))
  into v_base
  from jsonb_array_elements(v_lines) l;

  -- El mínimo se comprueba sobre la BASE que acaba de calcular la base de
  -- datos, no sobre uno que venga de fuera ni sobre el total con impuestos.
  if v_base < 5.00 then
    raise exception 'El monto mínimo por cobro es $5.00' using errcode = '22023';
  end if;

  select * into v_terms from public.merchant_settlement_terms where merchant_id = p_merchant_id;
  v_b := public.helios_charge_breakdown(v_base, coalesce(v_terms.commission_pct, 10));

  -- Idempotente: si ya existe un cobro con esta clave (reintento de red del
  -- cajero), se devuelve el mismo en vez de generar un segundo QR vivo.
  insert into public.charges (
    merchant_id, branch_id, requested_by, idempotency_key,
    amount_usd,
    base_usd, vat_pct, vat_usd,
    consumer_fee_pct, consumer_fee_usd, consumer_fee_vat_usd,
    merchant_fee_pct, merchant_fee_usd, merchant_fee_vat_usd, merchant_net_usd
  )
  values (
    p_merchant_id, p_branch_id, v_staff, p_idempotency_key,
    (v_b->>'consumer_total_usd')::numeric,
    (v_b->>'base_usd')::numeric,
    (v_b->>'vat_pct')::numeric,
    (v_b->>'vat_usd')::numeric,
    (v_b->>'consumer_fee_pct')::numeric,
    (v_b->>'consumer_fee_usd')::numeric,
    (v_b->>'consumer_fee_vat_usd')::numeric,
    (v_b->>'merchant_fee_pct')::numeric,
    (v_b->>'merchant_fee_usd')::numeric,
    (v_b->>'merchant_fee_vat_usd')::numeric,
    (v_b->>'merchant_net_usd')::numeric
  )
  on conflict (idempotency_key) do nothing
  returning * into v_row;

  if v_row.id is null then
    -- Ya existía: NO se vuelven a insertar las líneas, o el reintento
    -- duplicaría el detalle de un cobro que ya está en pantalla.
    select * into v_row from public.charges where idempotency_key = p_idempotency_key;
    return v_row;
  end if;

  insert into public.charge_items
    (charge_id, product_id, name, unit_price_usd, quantity, position)
  select
    v_row.id,
    (l->>'product_id')::uuid,
    l->>'name',
    (l->>'unit_price_usd')::numeric,
    (l->>'quantity')::integer,
    (ord - 1)::smallint
  from jsonb_array_elements(v_lines) with ordinality as t(l, ord);

  return v_row;
end;
$$;

revoke all on function public.request_charge(uuid, uuid, jsonb, text) from public, anon;
grant execute on function public.request_charge(uuid, uuid, jsonb, text) to authenticated;
