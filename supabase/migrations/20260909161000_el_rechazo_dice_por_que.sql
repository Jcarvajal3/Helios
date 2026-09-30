-- ============================================================================
-- Ronda -- El rechazo dice por que, y ya no siempre es la mora
--
-- 20260909160000 metio el mantenimiento, el bloqueo manual y la lista de espera
-- dentro de `can_take_debt`, que es la puerta que miran el consumo y los
-- grupos. Con eso quedan cerrados de verdad, pero el TEXTO del rechazo se
-- quedo viejo: las cinco funciones de aqui abajo dicen "tienes una cuota
-- vencida" pase lo que pase.
--
-- Durante un mantenimiento eso significa que TODO el mundo que escanee un QR
-- lee que tiene una cuota vencida. Es falso, manda a pagar algo que no se debe
-- y esconde justo el aviso que se acaba de redactar para esa emergencia.
--
-- Aqui cada una comprueba primero `helios_spend_block` y lanza el mensaje que
-- corresponda. La mora se queda con su texto de siempre, que ahora si es
-- verdad siempre que sale.
--
-- ---------------------------------------------------------------------------
-- Como se hizo
-- ---------------------------------------------------------------------------
-- Los cuerpos NO se reescribieron a mano: se extrajeron de la migracion vigente
-- de cada funcion y se les inserto el guardia. Lo unico que cambia respecto a
-- lo que corre hoy es la variable `v_stop` y el bloque marcado NUEVO.
--
-- | Funcion                  | Cuerpo tomado de                        |
-- |--------------------------|-----------------------------------------|
-- | confirm_charge           | 20260909100000_el_precio_se_pacta_en_euros |
-- | create_group             | 20260909100000_el_precio_se_pacta_en_euros |
-- | join_group               | 20260909100000_el_precio_se_pacta_en_euros |
-- | confirm_charge_as_group  | 20260909100000_el_precio_se_pacta_en_euros |
-- | find_group_by_code       | 20260903120000_entrar_ensena_las_cuentas_una_por_una |
--
-- Los `comment on function` no se reemiten: `create or replace` no los borra.
--
-- Quedan fuera, a proposito, `open_my_tab`, `preview_tab`, `join_tab`,
-- `preview_charge_claim` y `claim_charge_share`: son del modelo de mesa que se
-- retiro y la app no llama a ninguna (0 usos). Si alguna resucita hay que
-- traerla aqui. Crear deuda no pueden igualmente: `helios_assign_debt` las para
-- a todas.
--
-- `find_group_by_code` empieza a devolver `reason = blocked` con su
-- `message`. La app lo pinta desde JOIN_BLOCKER_COPY (features/groups/api.ts).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- public.confirm_charge  (1 guardia)
-- ---------------------------------------------------------------------------

create or replace function public.confirm_charge(p_charge_id uuid, p_idempotency_key text, p_pin text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'ledger', 'pg_temp'
as $function$
declare
  v_stop        jsonb;
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
  -- -- NUEVO (20260909160000) ---------------------------------------------
  -- El motivo CORRECTO, que ya no es siempre la mora: esta misma puerta la
  -- cierran ahora el mantenimiento global, un bloqueo del equipo y la lista
  -- de espera del piloto. Mandar a pagar una cuota vencida a quien esta
  -- parado por un mantenimiento es mandarlo a pagar algo que no debe.
  v_stop := public.helios_spend_block(v_user);
  if coalesce((v_stop->>'blocks_balance')::boolean, false) then
    raise exception '%', v_stop->>'message' using errcode = '22023';
  end if;
  -- ------------------------------------------------------------------------

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
    raise exception 'Saldo insuficiente: disponible €%, consumo €%',
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
    format('Saldo insuficiente para un consumo de €%s',
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

-- ---------------------------------------------------------------------------
-- public.create_group  (1 guardia)
-- ---------------------------------------------------------------------------

create or replace function public.create_group(
  p_name    text,
  p_cap_usd numeric,
  p_pin     text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stop        jsonb;
  v_user  uuid := auth.uid();
  v_pin   jsonb;
  v_group public.groups%rowtype;
  v_avail numeric(18,4);
  v_bdate date := public.helios_business_date(now());
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  -- -- NUEVO (20260909160000) ---------------------------------------------
  -- El motivo CORRECTO, que ya no es siempre la mora: esta misma puerta la
  -- cierran ahora el mantenimiento global, un bloqueo del equipo y la lista
  -- de espera del piloto. Mandar a pagar una cuota vencida a quien esta
  -- parado por un mantenimiento es mandarlo a pagar algo que no debe.
  v_stop := public.helios_spend_block(v_user);
  if coalesce((v_stop->>'blocks_balance')::boolean, false) then
    raise exception '%', v_stop->>'message' using errcode = '22023';
  end if;
  -- ------------------------------------------------------------------------

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes crear un grupo' using errcode = '22023';
  end if;

  if coalesce(trim(p_name), '') = '' then
    raise exception 'El grupo necesita un nombre' using errcode = '22023';
  end if;

  v_avail := public.available_usd(v_user);

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu techo no puede bajar de €%', public.min_share_usd() using errcode = '22023';
  end if;

  if p_cap_usd > v_avail then
    raise exception 'Tu techo sería de €% y tienes €% disponibles', p_cap_usd, v_avail
      using errcode = '22023';
  end if;

  insert into public.groups (name, created_by, invite_code, business_date)
  values (trim(p_name), v_user, public.generate_invite_code(), v_bdate)
  returning * into v_group;

  insert into public.group_members
    (group_id, user_id, business_date, cap_usd, spent_usd, authorized_at)
  values (v_group.id, v_user, v_bdate, p_cap_usd, 0, now());

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group.id,
    'name', v_group.name,
    'invite_code', v_group.invite_code,
    'cap_usd', p_cap_usd,
    'closes_at', public.helios_business_day_end(v_bdate)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- public.join_group  (1 guardia)
-- ---------------------------------------------------------------------------

create or replace function public.join_group(
  p_invite_code text,
  p_cap_usd     numeric,
  p_pin         text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stop        jsonb;
  v_user   uuid := auth.uid();
  v_pin    jsonb;
  v_group  public.groups%rowtype;
  v_bdate  date := public.helios_business_date(now());
  v_count  integer;
  v_avail  numeric(18,4);
  v_plan   jsonb;
  v_retro  numeric(18,4);
  v_owed   numeric(18,4);
  v_row    record;
  v_done   jsonb;
  v_paid   numeric(18,4) := 0;
  v_taken  numeric(18,4) := 0;
  v_charges integer := 0;
  v_skipped integer := 0;
  v_name   text;
  v_member record;
  v_theirs numeric(18,4);
  v_before jsonb;
  v_was    numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  -- El candado del grupo: dos personas entrando a la vez se ponen en fila, y
  -- la segunda ve el reparto que dejó la primera.
  select * into v_group from public.groups
  where invite_code = upper(trim(p_invite_code)) and business_date = v_bdate
  for update;

  if not found then
    raise exception 'Ese código no corresponde a ningún grupo de esta noche'
      using errcode = 'P0002';
  end if;

  -- -- NUEVO (20260909160000) ---------------------------------------------
  -- El motivo CORRECTO, que ya no es siempre la mora: esta misma puerta la
  -- cierran ahora el mantenimiento global, un bloqueo del equipo y la lista
  -- de espera del piloto. Mandar a pagar una cuota vencida a quien esta
  -- parado por un mantenimiento es mandarlo a pagar algo que no debe.
  v_stop := public.helios_spend_block(v_user);
  if coalesce((v_stop->>'blocks_balance')::boolean, false) then
    raise exception '%', v_stop->>'message' using errcode = '22023';
  end if;
  -- ------------------------------------------------------------------------

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes entrar a un grupo' using errcode = '22023';
  end if;

  select count(*) into v_count from public.group_members
  where group_id = v_group.id and left_at is null;

  if v_count >= public.max_group_members() then
    raise exception 'El grupo ya tiene % integrantes', public.max_group_members()
      using errcode = '22023';
  end if;

  v_avail := public.available_usd(v_user);

  -- ── Lo que ya lleva el grupo ──────────────────────────────────────────────
  v_plan := public.helios_group_join_plan(v_group.id, v_user);

  -- Solo se bloquea por saldo. Una cuenta demasiado pequeña para uno más no
  -- cierra el grupo: se salta esa y se entra a las demás (ver el plan).
  if not coalesce((v_plan->>'ok')::boolean, false) then
    raise exception
      'No te alcanza el saldo para tomar tu parte de lo que el grupo ya lleva gastado'
      using errcode = '22023';
  end if;

  v_retro := (v_plan->>'financed_usd')::numeric;

  -- REGLA 3: volver a entrar arranca cubriendo lo que este grupo ya me cargó,
  -- no en cero. Lo ya gastado sigue siendo deuda mía y el techo es de la noche
  -- entera, no de cada visita.
  select coalesce(sum(i.financed_usd), 0) into v_owed
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where c.group_id = v_group.id and i.user_id = v_user;

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu aporte máximo no puede bajar de €%', public.min_share_usd()
      using errcode = '22023';
  end if;

  -- REGLA 1: el techo es para lo que VIENE. Lo ya gastado no se negocia a la
  -- baja: o lo cubre, o no se entra.
  if p_cap_usd < v_owed + v_retro then
    raise exception
      'Tu aporte máximo tiene que cubrir al menos los €% que ya te tocan de lo que el grupo lleva gastado',
      trim(to_char(v_owed + v_retro, 'FM999999990.00'))
      using errcode = '22023';
  end if;

  if p_cap_usd > v_avail + v_owed then
    raise exception 'Tu aporte máximo sería de €% y tienes €% disponibles', p_cap_usd, v_avail
      using errcode = '22023';
  end if;

  -- La foto de lo que debe cada quien ANTES de tocar nada. Es lo único con lo
  -- que el aviso del final puede saber si a alguien le bajó la parte de verdad.
  select coalesce(jsonb_object_agg(t.user_id::text, t.total), '{}'::jsonb) into v_before
  from (
    select i.user_id, sum(i.amount_usd) as total
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.group_id = v_group.id
    group by i.user_id
  ) t;

  insert into public.group_members
    (group_id, user_id, business_date, cap_usd, spent_usd, left_at, authorized_at, status)
  values
    (v_group.id, v_user, v_bdate, p_cap_usd, v_owed, null, now(), 'active')
  on conflict (group_id, user_id) do update
    set cap_usd       = excluded.cap_usd,
        spent_usd     = excluded.spent_usd,
        left_at       = null,
        authorized_at = now(),
        status        = 'active';

  -- ── El reparto retroactivo, cuenta por cuenta ─────────────────────────────
  -- La capacidad se va gastando en el mismo orden que en el plan, así que sale
  -- exactamente la cifra que se enseñó antes del PIN.
  --
  -- ⬜ Esta lista es la que se queda corta en la carrera conocida: un cobro que
  -- se está confirmando AHORA MISMO en otra transacción no se ve desde aquí, y
  -- esa cuenta acabará sin el que entra. Punto 10 de este archivo, y
  -- `helios_group_split_gaps` para detectarlo.
  for v_row in select * from public.helios_group_open_charges(v_group.id, v_user) loop
    v_done := public.helios_group_resplit_charge(
      v_row.charge_id, v_user, greatest(v_avail - v_taken, 0)
    );

    -- Demasiado pequeña para uno más: queda como estaba y no cuenta como suya.
    if coalesce((v_done->>'skipped')::boolean, false) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_taken   := v_taken + (v_done->>'financed_usd')::numeric;
    v_paid    := v_paid  + (v_done->>'payable_usd')::numeric;
    v_charges := v_charges + 1;
  end loop;

  -- ── El aviso: uno solo, y con la cifra ya cerrada ─────────────────────────
  select coalesce(full_name, 'Alguien') into v_name from public.profiles where id = v_user;

  for v_member in
    select user_id from public.group_members
    where group_id = v_group.id and left_at is null and user_id <> v_user
  loop
    select coalesce(sum(i.amount_usd), 0) into v_theirs
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.group_id = v_group.id and i.user_id = v_member.user_id;

    /**
     * "Tu parte bajó" solo si de verdad bajó.
     *
     * No siempre baja, y el caso no es raro: un grupo de dos con una sola
     * cuenta de €6 no puede repartirla entre tres —no llega a €7,50— así que
     * el tercero entra sin asumir nada y a los dos de antes no les cambia un
     * céntimo. Decirles "bajó a €3,00" cuando siguen debiendo los mismos €3
     * es un aviso que miente sobre dinero, que es la peor clase de aviso.
     */
    v_was := coalesce((v_before->>v_member.user_id::text)::numeric, 0);

    perform public.notify(
      v_member.user_id,
      'group_charge',
      format('%s entró a %s', v_name, v_group.name),
      case
        when v_theirs < v_was then
          format('Ya son %s y tu parte de la noche bajó a €%s.',
                 v_count + 1, trim(to_char(v_theirs, 'FM999999990.00')))
        else
          format('Ya son %s. Lo que pague cualquiera se reparte entre todos hasta las 10 AM.',
                 v_count + 1)
      end,
      jsonb_build_object('group_id', v_group.id, 'user_id', v_user)
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group.id,
    'name', v_group.name,
    'cap_usd', p_cap_usd,
    'closes_at', public.helios_business_day_end(v_group.business_date),
    -- Lo que se acaba de asumir al entrar. El acuse lo dice.
    'retro_charge_count', v_charges,
    'retro_financed_usd', v_taken,
    'retro_payable_usd', v_paid,
    -- Y de las que no es parte, por pequeñas.
    'skipped_charge_count', v_skipped
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- public.confirm_charge_as_group  (1 guardia)
-- ---------------------------------------------------------------------------

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
  v_stop        jsonb;
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
  -- -- NUEVO (20260909160000) ---------------------------------------------
  -- El motivo CORRECTO, que ya no es siempre la mora: esta misma puerta la
  -- cierran ahora el mantenimiento global, un bloqueo del equipo y la lista
  -- de espera del piloto. Mandar a pagar una cuota vencida a quien esta
  -- parado por un mantenimiento es mandarlo a pagar algo que no debe.
  v_stop := public.helios_spend_block(v_user);
  if coalesce((v_stop->>'blocks_balance')::boolean, false) then
    raise exception '%', v_stop->>'message' using errcode = '22023';
  end if;
  -- ------------------------------------------------------------------------

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
      raise exception 'Entre % la cuenta mínima es €% y esta es de €%',
        v_split->>'split_between', v_split->>'min_total_usd', v_financed
        using errcode = '22023';
    else
      raise exception 'El grupo llega a €% y la cuenta es de €%',
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
      'Tu parte cambió a €% mientras confirmabas (habías autorizado €%): vuelve a mirar el reparto',
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
      format('Alguien del grupo ya no tiene límite para €%s',
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

-- ---------------------------------------------------------------------------
-- public.find_group_by_code  (1 guardia)
-- ---------------------------------------------------------------------------

create or replace function public.find_group_by_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_stop        jsonb;
  v_user  uuid := auth.uid();
  v_group public.groups%rowtype;
  v_bdate date := public.helios_business_date(now());
  v_count integer;
  v_avail numeric(18,4);
  v_plan  jsonb;
  v_retro numeric(18,4);
  v_owed  numeric(18,4);
  v_max   numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_group from public.groups
  where invite_code = upper(trim(p_code)) and business_date = v_bdate;

  if not found then
    -- Un código de anoche y uno inventado dan lo mismo a propósito: decir
    -- "ese grupo era de ayer" obligaría a buscar entre los muertos, y no
    -- cambia nada de lo que la persona puede hacer ahora.
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  select count(*) into v_count from public.group_members
  where group_id = v_group.id and left_at is null;

  if exists (
    select 1 from public.group_members
    where group_id = v_group.id and user_id = v_user and left_at is null
  ) then
    return jsonb_build_object('ok', false, 'reason', 'already_in',
      'group_id', v_group.id, 'name', v_group.name, 'member_count', v_count);
  end if;

  -- -- NUEVO (20260909160000) ---------------------------------------------
  -- Igual que en confirm_charge: el motivo viaja con su texto y la app lo
  -- pinta tal cual, en vez de inventarse una cuota vencida que no existe.
  v_stop := public.helios_spend_block(v_user);
  if coalesce((v_stop->>'blocks_balance')::boolean, false) then
    return jsonb_build_object('ok', false, 'reason', 'blocked',
                              'message', v_stop->>'message');
  end if;
  -- ------------------------------------------------------------------------

  if not public.can_take_debt(v_user) then
    return jsonb_build_object('ok', false, 'reason', 'overdue');
  end if;

  if v_count >= public.max_group_members() then
    return jsonb_build_object('ok', false, 'reason', 'full');
  end if;

  v_avail := public.available_usd(v_user);

  if v_avail < public.min_share_usd() then
    return jsonb_build_object('ok', false, 'reason', 'no_balance',
      'available_usd', v_avail, 'min_share_usd', public.min_share_usd());
  end if;

  -- Lo que ya lleva el grupo, y si se puede entrar a ello.
  v_plan := public.helios_group_join_plan(v_group.id, v_user);

  -- El único bloqueo que queda es por saldo: una cuenta demasiado pequeña para
  -- uno más se salta, no cierra el grupo.
  --
  -- `blocking_amount_usd` viaja con él desde 20260903000000 y ahora la app lo
  -- usa: el bloqueo decía "no te alcanza" sin decir cuánto falta, que es la
  -- única cifra con la que esa persona puede hacer algo.
  if not coalesce((v_plan->>'ok')::boolean, false) then
    return jsonb_build_object(
      'ok', false,
      'reason', v_plan->>'reason',
      'name', v_group.name,
      'member_count', v_count,
      'available_usd', v_avail,
      'min_share_usd', public.min_share_usd(),
      'blocking_amount_usd', (v_plan->>'blocking_amount_usd')::numeric,
      'blocking_split_between', (v_plan->>'blocking_split_between')::integer
    );
  end if;

  v_retro := (v_plan->>'financed_usd')::numeric;

  -- Lo que este grupo ya me cargó en una entrada anterior. Sale del disponible
  -- pero cuenta contra el techo, así que el suelo y el tope del campo lo llevan
  -- dentro: sin esto la pantalla ofrecería un techo que el PIN rechazaría.
  select coalesce(sum(i.financed_usd), 0) into v_owed
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where c.group_id = v_group.id and i.user_id = v_user;

  v_max := floor((v_avail + v_owed) * 100) / 100;

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group.id,
    'name', v_group.name,
    'member_count', v_count,
    -- Quiénes están, en orden de llegada. Es el mismo permiso con el que se
    -- ven un segundo después en el detalle del grupo: se llega aquí con un
    -- código válido de un grupo vivo, y a eso se entra.
    'member_names', (
      select coalesce(jsonb_agg(p.full_name order by m.joined_at), '[]'::jsonb)
      from public.group_members m
      join public.profiles p on p.id = m.user_id
      where m.group_id = v_group.id and m.left_at is null
    ),
    'closes_at', public.helios_business_day_end(v_group.business_date),
    -- Lo ya gastado y lo que de eso me toca. Es la mitad de lo que se acepta.
    'retro_charge_count', (v_plan->>'charge_count')::integer,
    'retro_financed_usd', v_retro,
    'retro_payable_usd', (v_plan->>'payable_usd')::numeric,
    -- Y de qué NO voy a ser parte: las cuentas demasiado pequeñas para uno
    -- más. Se dice antes de entrar, no se descubre en el detalle del grupo.
    'skipped_charge_count', (v_plan->>'skipped_charge_count')::integer,
    'skipped_usd', (v_plan->>'skipped_usd')::numeric,
    -- NUEVO: las cuentas una por una, en orden de consumo y con las saltadas
    -- dentro. Es lo que convierte "de 2 cuentas" en algo comprobable.
    'retro_charges', coalesce(v_plan->'charges', '[]'::jsonb),
    -- El techo que propone la app: el saldo entero. Es un defecto, no una
    -- obligación; la pantalla deja bajarlo antes de aceptar.
    'suggested_cap_usd', v_max,
    'max_cap_usd', v_max,
    'min_cap_usd', greatest(public.min_share_usd(), v_owed + v_retro)
  );
end;
$$;


revoke all on function public.find_group_by_code(text) from public, anon;
grant execute on function public.find_group_by_code(text) to authenticated;
