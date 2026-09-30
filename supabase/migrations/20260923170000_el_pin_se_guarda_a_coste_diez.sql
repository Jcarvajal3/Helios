-- ============================================================================
-- Ronda — El PIN se guarda a coste 10
--
-- bcrypt a coste 12 dentro de Postgres tarda ~318 ms por PIN en producción
-- (Nano); a coste 10, 74-81 ms. Cada pago, cada desbloqueo en frío y cada
-- grupo pasan por `verify_user_pin`, así que ese tiempo es CPU de la base y
-- una conexión del pool de PostgREST ocupada: con 12, el techo era de 5-6
-- PINes por segundo para todo el país.
--
-- No resta seguridad. El mismo PIN ya vive en `auth.users` como bcrypt
-- `$2a$10$` de `ronda:` + PIN, sin pepper (lo sincroniza `setPin` para el
-- login en dispositivo de confianza). Lo que protege `user_pins` es el pepper
-- de Vault —sin él, el hash no se puede atacar fuera de la base— y el bloqueo
-- por intentos, no dos vueltas más de bcrypt sobre 10.000 combinaciones.
--
-- Qué cambia:
--   · `set_user_pin` hashea con coste 10.
--   · `verify_user_pin`, cuando ACIERTA contra un hash de otro coste (los
--     `$2a$12$` guardados hasta hoy), lo rehace a 10 con el PIN que acaba de
--     comprobar. Pasa una vez por persona, en su siguiente PIN correcto.
--   · `confirm_charge` mira antes del PIN si el cobro ya lo confirmó esta
--     misma persona: el reintento tras un corte de red no vuelve a pagar un
--     bcrypt para contestar lo mismo que ya contestaba después.
--
-- El coste vive en dos sitios —el `gen_salt('bf', 10)` de las dos funciones— y
-- tienen que cambiar juntos: si `set_user_pin` subiera y `verify_user_pin` no,
-- el rehash desharía cada PIN nuevo en la primera verificación.
-- ============================================================================

-- Define o cambia el PIN del usuario autenticado. Idéntica a la de
-- 20260825150000_pin_de_cuatro_digitos.sql salvo el coste del hash.
create or replace function public.set_user_pin(p_pin text)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if p_pin !~ '^\d{4}$' then
    raise exception 'El PIN debe ser de 4 dígitos' using errcode = '22023';
  end if;

  -- PINs trivialmente adivinables. Bloquearlos aquí, en el servidor, evita
  -- depender de que el cliente valide.
  --
  -- La lista crece respecto a la de 6 dígitos porque con 4 el problema es
  -- otro: no es que el espacio sea pequeño —el bloqueo por intentos se ocupa
  -- de eso—, es que las elecciones de la gente se amontonan en un puñado de
  -- combinaciones. Aquí están las de siempre: repeticiones, escaleras arriba
  -- y abajo, pares alternos y las dos rectas del teclado (2580 / 0852).
  if p_pin in ('0000','1111','2222','3333','4444','5555','6666','7777',
               '8888','9999','1234','4321','0123','3210','1212','2121',
               '1122','2211','1313','1010','2580','0852','6969','1004')
  then
    raise exception 'Ese PIN es demasiado fácil de adivinar' using errcode = '22023';
  end if;

  insert into public.user_pins (user_id, pin_hash, updated_at)
  values (
    v_user,
    -- Coste 10: el mismo que el rehash de `verify_user_pin`.
    extensions.crypt(p_pin || public.pin_pepper(), extensions.gen_salt('bf', 10)),
    now()
  )
  on conflict (user_id) do update
    set pin_hash = excluded.pin_hash,
        updated_at = now();

  -- Un PIN nuevo limpia el historial de bloqueos.
  delete from public.pin_attempts where user_id = v_user;

  update public.profiles
    set status = case when status = 'pending_pin' then 'active' else status end,
        updated_at = now()
  where id = v_user;
end;
$$;

-- Verifica el PIN del usuario autenticado, con el bloqueo progresivo.
-- Idéntica a la de 20260821210000_auth_core.sql salvo el rehash del acierto.
create or replace function public.verify_user_pin(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user     uuid := auth.uid();
  v_hash     text;
  v_pepper   text;
  v_attempts public.pin_attempts%rowtype;
  v_ok       boolean;
  v_failed   smallint;
  v_lock     timestamptz;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- Serializa los intentos concurrentes del mismo usuario: sin esto, N
  -- peticiones en paralelo consumirían un solo intento.
  insert into public.pin_attempts (user_id) values (v_user)
  on conflict (user_id) do nothing;

  select * into v_attempts
  from public.pin_attempts
  where user_id = v_user
  for update;

  if v_attempts.locked_until is not null and v_attempts.locked_until > now() then
    return jsonb_build_object(
      'ok', false,
      'reason', 'locked',
      'retry_after_seconds', ceil(extract(epoch from (v_attempts.locked_until - now())))::int,
      'requires_otp', v_attempts.requires_otp
    );
  end if;

  if v_attempts.requires_otp then
    return jsonb_build_object('ok', false, 'reason', 'requires_otp', 'requires_otp', true);
  end if;

  select pin_hash into v_hash from public.user_pins where user_id = v_user;
  if v_hash is null then
    return jsonb_build_object('ok', false, 'reason', 'no_pin_set');
  end if;

  v_pepper := public.pin_pepper();
  v_ok := (extensions.crypt(p_pin || v_pepper, v_hash) = v_hash);

  if v_ok then
    update public.pin_attempts
      set failed_count = 0, locked_until = null,
          requires_otp = false, last_attempt_at = now()
    where user_id = v_user;

    -- El coste va escrito en el propio hash (`$2a$12$…`) y `crypt` lo hereda
    -- de ahí, así que bajar el de `set_user_pin` no abarata los PINes que ya
    -- estaban guardados. Se rehacen aquí, que es el único momento en que se
    -- tiene el PIN en claro y comprobado. `updated_at` no se toca: el PIN es
    -- el mismo.
    if split_part(v_hash, '$', 3) <> '10' then
      update public.user_pins
        set pin_hash = extensions.crypt(p_pin || v_pepper, extensions.gen_salt('bf', 10))
      where user_id = v_user and pin_hash = v_hash;
    end if;

    return jsonb_build_object('ok', true);
  end if;

  v_failed := v_attempts.failed_count + 1;

  -- Escalada: 3 fallos → 30s, 5 → 5min, 7 → exige OTP.
  v_lock := case
    when v_failed >= 7 then now() + interval '15 minutes'
    when v_failed >= 5 then now() + interval '5 minutes'
    when v_failed >= 3 then now() + interval '30 seconds'
    else null
  end;

  update public.pin_attempts
    set failed_count = v_failed,
        locked_until = v_lock,
        requires_otp = (v_failed >= 7),
        last_attempt_at = now()
  where user_id = v_user;

  return jsonb_build_object(
    'ok', false,
    'reason', 'wrong_pin',
    'attempts_left', greatest(0, 7 - v_failed),
    'retry_after_seconds',
      case when v_lock is null then 0
           else ceil(extract(epoch from (v_lock - now())))::int end,
    'requires_otp', v_failed >= 7
  );
end;
$$;

-- Confirma un cobro con el PIN. Idéntica a la de 20260909161000_el_rechazo_dice_por_que.sql
-- salvo la respuesta temprana al reintento de quien ya lo confirmó.
CREATE OR REPLACE FUNCTION public.confirm_charge(p_charge_id uuid, p_idempotency_key text, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'pg_temp'
AS $function$
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

  -- Un reintento del MISMO pago —la respuesta se perdió por el camino y la
  -- app vuelve a mandarlo— se contesta antes del PIN: es lo mismo que se
  -- contestaba después, sin pagar otro bcrypt. Solo a quien lo confirmó; a
  -- cualquier otro le toca el camino entero, que es el que decide qué decirle.
  if exists (select 1 from public.charges
              where id = p_charge_id and status = 'confirmed' and user_id = v_user) then
    return jsonb_build_object('ok', true, 'charge_id', p_charge_id, 'already_confirmed', true);
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
$function$;
