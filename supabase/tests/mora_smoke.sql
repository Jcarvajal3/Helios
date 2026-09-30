-- ============================================================================
-- Ronda — Prueba de humo del motor de mora
--
-- docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--   -v ON_ERROR_STOP=1 -f supabase/tests/mora_smoke.sql
--
-- Simula el paso del tiempo empujando due_date hacia atrás (no hay forma
-- limpia de viajar en el tiempo del servidor) y corre process_mora() en
-- cada punto: día 1 → frozen, pasada la gracia → cargo por cuota, día 30 →
-- suspended + baja de nivel, día 61 → expelled + castigo contable de la deuda.
-- Los umbrales se leen de los PARÁMETROS, no de números escritos aquí: la
-- escalera ya se alargó una vez (15/30 → 30/60) y esta prueba se quedó
-- comprobando tramos muertos.
--
-- 🔁 El tramo del cargo por mora entró el 2026-08-30 (20260830170000) y el
-- 2026-09-02 pasó a ser **$2 por CADA cuota retrasada, con 3 días de gracia**
-- (20260902110000). Dos cosas que hay que vigilar, y las dos son fáciles de
-- romper sin darse cuenta al tocar el motor:
--
--   1. El congelamiento entra el día 1 y el cargo NO. La gracia es solo del
--      cargo.
--   2. El cargo es uno por CUOTA y solo uno: dos cuotas vencidas son dos
--      cargos, y veinte corridas del cron siguen siendo dos.
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_customer uuid := gen_random_uuid();
  v_cajero   uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_charge   uuid;
  v_inst1    uuid;
  v_inst2    uuid;
  v_status   public.profile_status;
  v_level    smallint;
  v_recv     numeric;
  v_prov     numeric;
  /** Lo que de verdad se cobró: base + comisión del consumidor con su IVA, no
   *  la base pelada. Ver la nota equivalente en `ledger_smoke`. */
  v_amount   numeric;
  /** El cargo por mora de UNA cuota, leído del parámetro y no escrito a mano:
   *  el día que deje de ser $2 esta prueba tiene que seguir valiendo. */
  v_fee      numeric := public.helios_late_fee_usd();
  /** El primer día que ya NO está en gracia. Con 3 días de gracia, el 4. */
  v_late_day integer := public.helios_late_fee_grace_days() + 1;
  v_charged  numeric;
  /** Lo que el consumo ocupa de cupo: la base, sin el fee del servicio. */
  v_financed numeric;
  /** El fee acumulado del bloque: servicio + mora. No ocupa cupo. */
  v_block_fee numeric;
  /** Lo que se debe de verdad: cupo + fee. */
  v_owed     numeric;
begin
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values (v_customer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          '+584140000010', now(), now(), now());
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          '+584140000011', now(), now(), now());

  update public.profiles set status = 'active', level = 2, full_name = 'Cliente Mora' where id = v_customer;

  insert into public.merchants (name) values ('Bar Mora') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role) values (v_cajero, v_merchant, v_branch, 'cajero');

  -- Helios: aquí iba el PIN de la prueba (`set_user_pin` y el pepper de
  -- Vault). Sin app no hay PIN: la deuda la crea `pg_temp.prueba_cobro`.

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  perform set_config('request.jwt.claims', json_build_object('sub', v_customer::text, 'role', 'authenticated')::text, true);
  v_charge := (pg_temp.prueba_cobro(v_customer, v_merchant, v_branch, v_cajero, 40.00, 'mora-charge-1', 'Consumo')->>'charge_id')::uuid;
  reset role;

  select amount_usd, coalesce(base_usd, amount_usd) into v_amount, v_financed
  from public.charges where id = v_charge;

  select id into v_inst1 from public.installments where charge_id = v_charge and sequence = 1;
  select id into v_inst2 from public.installments where charge_id = v_charge and sequence = 2;

  -- --- Día 1 de atraso: cuota 1 vencida ayer -> frozen, SIN cargo ---------
  update public.installments set due_date = public.helios_business_date(now()) - 1 where id = v_inst1;
  perform public.process_mora();

  select status, level into v_status, v_level from public.profiles where id = v_customer;
  if v_status <> 'frozen' then
    raise exception 'Esperaba frozen al día 1 de atraso, obtuve %', v_status;
  end if;
  if v_level <> 2 then
    raise exception 'El nivel no debía cambiar en frozen, obtuve %', v_level;
  end if;
  if exists (select 1 from public.late_fees where user_id = v_customer) then
    raise exception 'El día 1 cae dentro de la gracia: no debía haber cargo por mora';
  end if;
  raise notice 'TEST MORA 1 OK — día 1: status=%, nivel=% (sin cambio) y sin cargo (gracia de % días)',
    v_status, v_level, public.helios_late_fee_grace_days();

  -- --- Primer día fuera de la gracia: cargo de $2 sobre la CUOTA 1 --------
  update public.installments set due_date = public.helios_business_date(now()) - v_late_day
  where id = v_inst1;
  perform public.process_mora();

  if (select count(*) from public.late_fees where user_id = v_customer and status = 'pending') <> 1 then
    raise exception 'Pasada la gracia debía haber UN cargo por mora pendiente, hay %',
      (select count(*) from public.late_fees where user_id = v_customer);
  end if;
  if (select amount_usd from public.late_fees where user_id = v_customer) <> v_fee then
    raise exception 'El cargo debía ser de $%, es de $%',
      v_fee, (select amount_usd from public.late_fees where user_id = v_customer);
  end if;
  -- Y colgando de la cuota que lo disparó, no del bloque: de ahí sale que el
  -- cargo viaje con esa cuota cuando se pague.
  if (select installment_id from public.late_fees where user_id = v_customer) <> v_inst1 then
    raise exception 'El cargo debía colgar de la cuota 1, cuelga de %',
      (select installment_id from public.late_fees where user_id = v_customer);
  end if;

  -- Y tiene que estar EN LA DEUDA: si no, el cupo volvería sin haberlo pagado.
  --
  -- 🔁 En `fee_usd` y no en `charged_usd` desde 20260830200000. El cargo se debe
  -- —el bloque no se cierra sin pagarlo— pero NO ocupa cupo: no es consumo, es
  -- una penalización. Misma regla que el fee del servicio (20260830190000).
  select charged_usd, fee_usd, charged_usd + fee_usd
    into v_charged, v_block_fee, v_owed
  from public.user_credit_blocks
  where user_id = v_customer and closed_at is null;

  if v_charged <> v_financed then
    raise exception 'El cupo del bloque debía seguir siendo el consumo (%), es %',
      v_financed, v_charged;
  end if;
  if v_owed <> v_amount + v_fee then
    raise exception 'La deuda del bloque debía ser % + % = %, es %',
      v_amount, v_fee, v_amount + v_fee, v_owed;
  end if;
  raise notice 'TEST MORA 2 OK — día %: cargo de $% sobre la cuota 1; cupo $% y deuda $%',
    v_late_day, v_fee, v_charged, v_owed;

  -- --- El cargo es UNO por cuota, corra el cron las veces que corra -------
  perform public.process_mora();
  perform public.process_mora();
  if (select count(*) from public.late_fees where user_id = v_customer) <> 1 then
    raise exception 'El cargo de la cuota 1 debía cobrarse UNA vez, hay %',
      (select count(*) from public.late_fees where user_id = v_customer);
  end if;
  raise notice 'TEST MORA 3 OK — tres corridas del cron, un solo cargo';

  -- --- La segunda cuota se pasa: SEGUNDO cargo, no un cargo más caro ------
  -- Es el corazón del cambio del 2026-09-02. Con el modelo por episodio esto
  -- no cobraba nada: el bloque ya tenía su cargo.
  update public.installments set due_date = public.helios_business_date(now()) - v_late_day - 1
  where id = v_inst2;
  perform public.process_mora();

  if (select count(*) from public.late_fees where user_id = v_customer and status = 'pending') <> 2 then
    raise exception 'Dos cuotas pasadas de la gracia son DOS cargos, hay %',
      (select count(*) from public.late_fees where user_id = v_customer and status = 'pending');
  end if;
  if (select count(*) from public.late_fees
      where user_id = v_customer and installment_id in (v_inst1, v_inst2)) <> 2 then
    raise exception 'Cada cargo debía colgar de una cuota distinta';
  end if;

  select charged_usd, fee_usd, charged_usd + fee_usd
    into v_charged, v_block_fee, v_owed
  from public.user_credit_blocks
  where user_id = v_customer and closed_at is null;

  if v_owed <> v_amount + 2 * v_fee then
    raise exception 'La deuda del bloque debía ser % + 2×% = %, es %',
      v_amount, v_fee, v_amount + 2 * v_fee, v_owed;
  end if;
  if v_charged <> v_financed then
    raise exception 'Ningún cargo por mora puede tocar el cupo: esperaba %, es %',
      v_financed, v_charged;
  end if;
  raise notice 'TEST MORA 3-bis OK — dos cuotas retrasadas, dos cargos ($% cada uno); cupo intacto en $%',
    v_fee, v_charged;

  -- --- Umbral de bajada de nivel -> suspended + baja 1 nivel --------------
  update public.installments set due_date =
    public.helios_business_date(now()) - public.helios_mora_demotion_days() where id = v_inst1;
  perform public.process_mora();

  select status, level into v_status, v_level from public.profiles where id = v_customer;
  if v_status <> 'suspended' then
    raise exception 'Esperaba suspended a los % días de atraso, obtuve %',
      public.helios_mora_demotion_days(), v_status;
  end if;
  if v_level <> 1 then
    raise exception 'Esperaba nivel 1 (bajó de 2), obtuve %', v_level;
  end if;
  if not exists (
    select 1 from public.level_changes
    where user_id = v_customer and reason = 'mora_demotion' and from_level = 2 and to_level = 1
  ) then
    raise exception 'Debía quedar un level_changes con reason=mora_demotion, from=2, to=1';
  end if;
  if (select count(*) from public.late_fees where user_id = v_customer) <> 2 then
    raise exception 'Agravarse la mora no cobra cargos nuevos: son dos cuotas, dos cargos, hay %',
      (select count(*) from public.late_fees where user_id = v_customer);
  end if;
  raise notice 'TEST MORA 4 OK — umbral de bajada: status=%, nivel=% (bajó de 2), siguen siendo dos cargos',
    v_status, v_level;

  -- --- Repetir process_mora no debe volver a bajar el nivel ---------------
  perform public.process_mora();
  select level into v_level from public.profiles where id = v_customer;
  if v_level <> 1 then
    raise exception 'process_mora repetido no debe seguir bajando el nivel, quedó en %', v_level;
  end if;
  if (select count(*) from public.level_changes where user_id = v_customer and reason = 'mora_demotion') <> 1 then
    raise exception 'Solo debía existir un evento mora_demotion, no uno por cada corrida del cron';
  end if;
  raise notice 'TEST MORA 5 OK — process_mora es idempotente, no re-castiga';

  -- --- Pasado el umbral de expulsión -> expelled + castigo contable -------
  update public.installments set due_date =
    public.helios_business_date(now()) - public.helios_mora_expulsion_days() - 1
  where id in (v_inst1, v_inst2);
  perform public.process_mora();

  select status into v_status from public.profiles where id = v_customer;
  if v_status <> 'expelled' then
    raise exception 'Esperaba expelled pasados los % días, obtuve %',
      public.helios_mora_expulsion_days(), v_status;
  end if;
  if not (select is_blacklisted from public.profiles where id = v_customer) then
    raise exception 'La expulsión debía dejar is_blacklisted=true';
  end if;

  if not exists (
    select 1 from public.user_credit_blocks
    where user_id = v_customer and close_reason = 'charged_off' and closed_at is not null
  ) then
    raise exception 'El bloque debía cerrarse con close_reason=charged_off';
  end if;

  -- Los cargos se van con el castigo, TODOS. Si alguno se quedara `pending`,
  -- seguiría siendo deuda viva de un bloque ya cerrado y viajaría pegado a la
  -- siguiente cotización de un usuario al que ya se le castigó la deuda.
  if exists (
    select 1 from public.late_fees where user_id = v_customer and status <> 'written_off'
  ) then
    raise exception 'Los cargos por mora debían quedar written_off tras el castigo, hay % sin castigar',
      (select count(*) from public.late_fees where user_id = v_customer and status <> 'written_off');
  end if;

  -- 🔁 2026-09-02: y las cuotas dejan de contar como cobrables. `status` sigue
  -- en 'pending' —nadie las pagó, que es lo que esa columna dice— pero
  -- `written_off_at` marca que ya no se espera cobrarlas. Sin esto la mora del
  -- panel no podía bajar NUNCA: la deuda castigada seguía sumando al numerador
  -- de un porcentaje que se suponía cobrable.
  if exists (
    select 1 from public.installments
    where user_id = v_customer and status = 'pending' and written_off_at is null
  ) then
    raise exception 'Tras el castigo no debía quedar cuota cobrable, quedan %',
      (select count(*) from public.installments
       where user_id = v_customer and status = 'pending' and written_off_at is null);
  end if;

  select ledger.account_balance(id) into v_recv
    from ledger.accounts where account_type = 'user_receivable' and owner_id = v_customer;
  select ledger.account_balance(id) into v_prov
    from ledger.accounts where account_type = 'bad_debt_provision' and owner_id is null;

  if v_recv <> 0 then
    raise exception 'user_receivable debía quedar en 0 tras el castigo, quedó en %', v_recv;
  end if;
  -- La provisión reconoce el consumo Y los cargos por mora: los tres eran
  -- receivable y los tres se pierden.
  if v_prov <> v_amount + 2 * v_fee then
    raise exception 'bad_debt_provision debía reconocer consumo + cargos (% + 2×% = %), quedó en %',
      v_amount, v_fee, v_amount + 2 * v_fee, v_prov;
  end if;
  raise notice 'TEST MORA 6 OK — pasado el umbral: expelled, blacklisted, castigado, provisión=$% (consumo $% + mora 2×$%)',
    v_prov, v_amount, v_fee;

  raise notice '=== TODOS LOS TESTS DE MORA PASARON ===';
end $$;

-- Fuerza el disparo de los constraint triggers DIFERIDOS del ledger (el
-- cuadre de partida doble). Sin esto, el rollback los saltaria y la prueba
-- pasaria en verde sin haber comprobado nunca que el libro cuadra.
set constraints all immediate;

rollback;
