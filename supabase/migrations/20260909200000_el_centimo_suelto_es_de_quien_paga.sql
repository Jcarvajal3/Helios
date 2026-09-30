-- ============================================================================
-- Ronda — El céntimo suelto es de quien paga
--
-- Repartir una cuenta entre varios casi nunca da una división exacta. Alguien
-- tiene que quedarse el céntimo que sobra, y hasta ahora ese alguien se elegía
-- por ORDEN DE user_id: un identificador que nadie ve, que no significa nada y
-- que hacía que dos personas con la misma parte teórica acabaran pagando
-- cifras distintas sin que la pantalla pudiera explicar por qué.
--
-- A partir de ahora lo absorbe quien pone el cobro. Es la regla que tenía la
-- primera versión de los grupos —"el céntimo que sobra lo asume quien inicia
-- el cobro" (20260822141000)— y la única defendible en voz alta en una mesa:
-- el que paga redondea a favor de los demás.
--
-- ── Son DOS céntimos distintos, y cambian los dos ──────────────────────────
--
--   1. El del reparto de lo FINANCIADO (`helios_split_shares`): la cascada
--      divide en enteros y sobran unos céntimos que iban de uno en uno al
--      primero con hueco.
--   2. El del redondeo de lo PAGADERO (`helios_payables`, y las dos copias que
--      todavía viven dentro de `preview_group_charge` y
--      `confirm_charge_as_group`): el último de la lista cerraba la cuenta con
--      lo que faltara para cuadrar con el asiento.
--
-- Los dos pasan a caer en el pagador. En el segundo no hace falta tocar la
-- aritmética: basta con que el pagador sea el ÚLTIMO del bucle, y de eso se
-- encarga el `order by`.
--
-- ── Lo que NO cambia ───────────────────────────────────────────────────────
--
-- * El total. Se sigue repartiendo hasta el último céntimo y el libro cuadra
--   igual; lo único que se mueve es de qué bolsillo sale.
-- * La reproducibilidad. El pagador es un dato del cobro, así que dos
--   reintentos del mismo cobro siguen dando el mismo reparto — que es lo que
--   sostiene la vía idempotente.
-- * El techo de nadie. Si al pagador no le cabe el céntimo bajo su aporte
--   máximo, lo que no quepa sigue el orden de siempre. Nadie paga más de lo
--   que autorizó.
-- * La equivalencia previa/confirmación. `preview_group_charge` y
--   `confirm_charge_as_group` reciben el mismo pagador (`auth.uid()`), así que
--   la cifra de antes del PIN y la que se cobra siguen siendo la misma y el
--   guardia de `p_expected_share_usd` no salta.
--
-- Al entrar tarde a un grupo (`helios_group_join_plan`,
-- `helios_group_resplit_charge`) el pagador de cada cuenta es quien la puso en
-- su día —`charges.user_id`—, no quien entra: volver a repartir una cuenta ya
-- cobrada no le cambia de dueño el resto.
--
-- ⚠️ Las cuatro funciones de los experimentos retirados (mesa y adjudicación:
-- `preview_tab_charge`, `confirm_charge_as_tab`, `preview_charge_claim`,
-- `claim_charge_share`) siguen llamando con dos argumentos. No se tocan: el
-- `default null` las deja exactamente como estaban, y ninguna pantalla las
-- llama.
--
-- Cuerpos idénticos a los de su última migración salvo lo dicho.
-- ============================================================================

-- Se DEJAN CAER las dos firmas viejas antes de crear las nuevas: añadir un
-- parámetro con valor por defecto no reemplaza a la función de dos argumentos,
-- crea una hermana, y entonces `f(a, b)` sería ambigua y fallaría en ejecución.
drop function if exists public.helios_split_shares(numeric, jsonb);
drop function if exists public.helios_payables(jsonb, numeric, numeric);
-- Y esta cambia el tipo de retorno —una columna más—, que `create or replace`
-- no admite.
drop function if exists public.helios_group_open_charges(uuid, uuid);

-- ── 1. El reparto ──────────────────────────────────────────────────────────

create or replace function public.helios_split_shares(
  p_total_usd    numeric,
  p_participants jsonb,  -- [{"user_id": uuid, "capacity_usd": numeric}, ...]
  -- Quien paga. Los céntimos que la división entera deja sueltos son suyos.
  -- Null —o alguien que no salga en el reparto— vuelve al orden por user_id.
  p_payer        uuid default null
)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_ids      uuid[]    := '{}';
  v_cap      bigint[]  := '{}';
  v_share    bigint[]  := '{}';
  v_fixed    boolean[] := '{}';
  v_excluded uuid[]    := '{}';
  v_min      bigint := round(public.min_share_usd() * 100)::bigint;
  v_left     bigint := round(p_total_usd * 100)::bigint;
  v_capacity bigint := 0;
  v_open     integer;
  v_level    bigint;
  v_capped   integer;
  v_i        integer;
  v_p        integer;
  v_n        integer;
  v_row      jsonb;
  v_out      jsonb := '[]'::jsonb;
begin
  /**
   * Quien no llega al mínimo por persona queda FUERA del reparto, no dentro
   * con una parte diminuta. Si entrara, la cascada le asignaría su techo
   * —pongamos $1,80— y sus dos cuotas serían de $0,90, por debajo del suelo
   * que el resto del sistema da por cierto. Sale, y su parte la absorben los
   * demás.
   */
  for v_row in select * from jsonb_array_elements(p_participants) loop
    if round((v_row->>'capacity_usd')::numeric * 100)::bigint >= v_min then
      v_ids   := v_ids   || (v_row->>'user_id')::uuid;
      v_cap   := v_cap   || round((v_row->>'capacity_usd')::numeric * 100)::bigint;
      v_share := v_share || 0::bigint;
      v_fixed := v_fixed || false;
    else
      v_excluded := v_excluded || (v_row->>'user_id')::uuid;
    end if;
  end loop;

  v_n := coalesce(array_length(v_ids, 1), 0);
  select coalesce(sum(c), 0) into v_capacity from unnest(v_cap) as c;

  if v_n = 0 then
    return jsonb_build_object(
      'ok', false, 'reason', 'not_enough',
      'capacity_usd', 0, 'split_between', 0,
      'excluded', to_jsonb(v_excluded)
    );
  end if;

  -- El suelo del reparto. No se puede dividir $8 entre 5: la app lo dice y
  -- ofrece pagarla entera, que es la única salida real.
  if v_left < v_n * v_min then
    return jsonb_build_object(
      'ok', false, 'reason', 'too_small',
      'min_total_usd', round((v_n * v_min)::numeric / 100, 2),
      'split_between', v_n,
      'capacity_usd', round(v_capacity::numeric / 100, 2),
      'excluded', to_jsonb(v_excluded)
    );
  end if;

  if v_left > v_capacity then
    return jsonb_build_object(
      'ok', false, 'reason', 'not_enough',
      'capacity_usd', round(v_capacity::numeric / 100, 2),
      'split_between', v_n,
      'excluded', to_jsonb(v_excluded)
    );
  end if;

  loop
    v_open := 0;
    for v_i in 1..v_n loop
      if not v_fixed[v_i] then v_open := v_open + 1; end if;
    end loop;

    -- No puede pasar: ya se comprobó que la capacidad total llega. Si pasara,
    -- salir en silencio repartiría menos dinero del que se cobró.
    exit when v_open = 0;

    v_level := v_left / v_open;

    v_capped := 0;
    for v_i in 1..v_n loop
      if not v_fixed[v_i] and v_cap[v_i] <= v_level then
        v_share[v_i] := v_cap[v_i];
        v_fixed[v_i] := true;
        v_left       := v_left - v_cap[v_i];
        v_capped     := v_capped + 1;
      end if;
    end loop;

    if v_capped = 0 then
      -- Nadie más se topa: los abiertos se llevan el nivel...
      for v_i in 1..v_n loop
        if not v_fixed[v_i] then
          v_share[v_i] := v_level;
          v_left       := v_left - v_level;
        end if;
      end loop;

      /**
       * ...y los céntimos que la división entera dejó fuera SON DE QUIEN PAGA.
       *
       * Hasta el 2026-09-09 iban de uno en uno a quien tuviera hueco, en orden
       * de user_id. Repartía exacto y era reproducible, pero le adjudicaba unos
       * céntimos de más a alguien elegido por un identificador que nadie ve: en
       * la mesa, dos personas con la misma parte teórica acababan con cifras
       * distintas y nada en pantalla podía explicar por qué.
       *
       * Ahora los absorbe quien pone el cobro. Es la regla que ya tenía la
       * primera versión de los grupos —"el céntimo que sobra lo asume quien
       * inicia el cobro"— y la única defendible en voz alta: el que paga
       * redondea a favor de los demás.
       *
       * Sigue siendo reproducible: el pagador es un dato del cobro, no del
       * orden en que se miren los participantes.
       */
      v_p := array_position(v_ids, p_payer);
      if v_p is not null then
        while v_left > 0 and not v_fixed[v_p] and v_share[v_p] < v_cap[v_p] loop
          v_share[v_p] := v_share[v_p] + 1;
          v_left       := v_left - 1;
        end loop;
      end if;

      /**
       * Lo que no quepa bajo el techo de quien paga —o todo, si no consta—
       * sigue el orden de siempre. Sobran menos céntimos que gente abierta, así
       * que alcanza: nadie abierto está topado, luego todos tienen al menos un
       * céntimo de hueco.
       */
      v_i := 1;
      while v_left > 0 and v_i <= v_n loop
        if not v_fixed[v_i] and v_share[v_i] < v_cap[v_i] then
          v_share[v_i] := v_share[v_i] + 1;
          v_left       := v_left - 1;
        end if;
        v_i := v_i + 1;
      end loop;

      exit;
    end if;
  end loop;

  for v_i in 1..v_n loop
    v_out := v_out || jsonb_build_object(
      'user_id',   v_ids[v_i],
      'share_usd', round(v_share[v_i]::numeric / 100, 2),
      -- Permite decir "puso su máximo" sin enseñar CUÁNTO es su máximo.
      'at_cap',    v_share[v_i] = v_cap[v_i]
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'shares', v_out,
    'split_between', v_n,
    'capacity_usd', round(v_capacity::numeric / 100, 2),
    'excluded', to_jsonb(v_excluded)
  );
end;
$$;

revoke all on function public.helios_split_shares(numeric, jsonb, uuid)
  from public, anon, authenticated;

-- ── 2. Los pagaderos ───────────────────────────────────────────────────────

create or replace function public.helios_payables(
  p_shares    jsonb,   -- [{"user_id": uuid, "share_usd": numeric}, ...]
  p_base_usd  numeric,
  p_total_usd numeric,
  -- Quien paga se queda el residuo del redondeo, igual que el céntimo suelto
  -- del reparto (`helios_split_shares`). Null vuelve al orden por user_id.
  p_payer     uuid default null
)
returns jsonb         -- {"<user_id>": payable_usd, ...}
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_out      jsonb := '{}'::jsonb;
  v_assigned numeric(18,4) := 0;
  v_payable  numeric(18,4);
  v_i        integer := 0;
  v_n        integer := coalesce(jsonb_array_length(p_shares), 0);
  v_row      record;
begin
  for v_row in
    select (s->>'user_id')::uuid as user_id, (s->>'share_usd')::numeric as share
    from jsonb_array_elements(p_shares) s
    order by ((s->>'user_id')::uuid = p_payer) nulls first, (s->>'user_id')::uuid
  loop
    v_i := v_i + 1;

    -- El último cierra la cuenta con lo que falte, y el último es QUIEN PAGA:
    -- el `order by` lo manda al final, porque false ordena antes que true. Sin
    -- pagador todas las filas comparan a null y queda el orden por `user_id`
    -- de siempre, que es lo que hace que dos ejecuciones den lo mismo.
    --
    -- La comparación va con la expresión entera y no con el alias `user_id`:
    -- dentro de una expresión, `order by` busca una columna de
    -- `jsonb_array_elements`, que no la tiene.
    if v_i = v_n then
      v_payable := p_total_usd - v_assigned;
    else
      v_payable := public.helios_payable_usd(v_row.share, p_base_usd, p_total_usd);
    end if;

    v_assigned := v_assigned + v_payable;
    v_out := v_out || jsonb_build_object(v_row.user_id::text, v_payable);
  end loop;

  return v_out;
end;
$$;

revoke all on function public.helios_payables(jsonb, numeric, numeric, uuid)
  from public, anon, authenticated;

-- ── 3. Las cuentas abiertas de un grupo, ahora con su pagador ──────────────

create or replace function public.helios_group_open_charges(p_group_id uuid, p_user uuid)
-- `payer_id` es nuevo: quien puso la cuenta, para que el céntimo suelto del
-- reparto caiga en él y no en el primer user_id.
returns table (charge_id uuid, base_usd numeric, amount_usd numeric, payer_id uuid)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select c.id, coalesce(c.base_usd, c.amount_usd), c.amount_usd, c.user_id
  from public.charges c
  where c.group_id = p_group_id
    and c.status = 'confirmed'
    and not exists (
      select 1 from public.installments i
      where i.charge_id = c.id and i.user_id = p_user
    )
  order by c.confirmed_at, c.id;
$$;

revoke all on function public.helios_group_open_charges(uuid, uuid)
  from public, anon, authenticated;

-- ── 4. El plan de entrada ──────────────────────────────────────────────────

create or replace function public.helios_group_join_plan(p_group_id uuid, p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_avail       numeric(18,4) := public.available_usd(p_user);
  v_assigned    numeric(18,4) := 0;
  v_payable     numeric(18,4) := 0;
  v_count       integer := 0;
  v_skipped     integer := 0;
  v_skipped_usd numeric(18,4) := 0;
  v_row         record;
  v_deb         record;
  v_parts       jsonb;
  v_split       jsonb;
  v_mine        numeric(18,4);
  v_mine_pay    numeric(18,4);
  v_n           integer;
  v_charges     jsonb := '[]'::jsonb;
  v_merchant    text;
begin
  for v_row in select * from public.helios_group_open_charges(p_group_id, p_user) loop
    v_parts := '[]'::jsonb;
    v_n     := 0;

    -- El nombre del local, que es por lo que la mesa reconoce una cuenta. Un
    -- `order_number` no le dice nada a nadie de pie en una barra.
    select m.name into v_merchant
    from public.charges c
    join public.merchants m on m.id = c.merchant_id
    where c.id = v_row.charge_id;

    -- La capacidad de quien ya debía es su parte actual. Ver la cabecera de
    -- 20260903000000: da el mismo reparto que volver a mirarle el saldo y hace
    -- imposible generarle deuda a alguien que no está delante del teléfono.
    for v_deb in select * from public.charge_debtors(v_row.charge_id) loop
      v_parts := v_parts || jsonb_build_object(
        'user_id', v_deb.user_id, 'capacity_usd', v_deb.financed_usd
      );
      v_n := v_n + 1;
    end loop;

    v_parts := v_parts || jsonb_build_object(
      'user_id', p_user, 'capacity_usd', greatest(v_avail - v_assigned, 0)
    );

    -- El céntimo suelto es de quien puso ESTA cuenta, no de quien entra.
    v_split := public.helios_split_shares(v_row.base_usd, v_parts, v_row.payer_id);

    /**
     * ESTA CUENTA NO DA PARA UNO MÁS. Se salta, no se bloquea.
     *
     * `too_small` significa exactamente eso y solo eso: el total no llega a
     * `(deudores + 1) × $2,50`. No puede venir de los deudores viejos —sus
     * partes ya cumplen el mínimo, por construcción— así que el que sobra es
     * siempre el que quiere entrar.
     *
     * Se comprueba ANTES que `ok`, porque `reason` solo viene cuando falló.
     */
    if v_split->>'reason' = 'too_small' then
      v_skipped     := v_skipped + 1;
      v_skipped_usd := v_skipped_usd + v_row.amount_usd;
      v_charges     := v_charges || jsonb_build_object(
        'charge_id',    v_row.charge_id,
        'merchant_name', coalesce(v_merchant, 'Un local'),
        'amount_usd',   v_row.amount_usd,
        'my_payable_usd', null::numeric,
        'skipped',      true
      );
      continue;
    end if;

    if not coalesce((v_split->>'ok')::boolean, false) then
      return jsonb_build_object(
        'ok', false,
        'reason', 'no_capacity',
        'blocking_amount_usd', v_row.amount_usd,
        'blocking_split_between', v_n + 1
      );
    end if;

    select (s->>'share_usd')::numeric into v_mine
    from jsonb_array_elements(v_split->'shares') s
    where (s->>'user_id')::uuid = p_user;

    -- Se quedó fuera de ESTA cuenta por no llegar al mínimo con lo que le
    -- queda. Entrar sería entrar a medias, así que no entra.
    if v_mine is null then
      return jsonb_build_object(
        'ok', false,
        'reason', 'no_capacity',
        'blocking_amount_usd', v_row.amount_usd,
        'blocking_split_between', v_n + 1
      );
    end if;

    v_mine_pay := coalesce(
      (public.helios_payables(v_split->'shares', v_row.base_usd, v_row.amount_usd,
                             v_row.payer_id)
        ->>p_user::text)::numeric, 0);

    v_assigned := v_assigned + v_mine;
    v_payable  := v_payable + v_mine_pay;
    v_count    := v_count + 1;

    -- Lo que se paga, no lo que se financia: es la cifra que aparece en las
    -- cuotas, y por tanto la única que se puede comprobar después. Las dos
    -- difieren en el fee del servicio (20260830190000).
    v_charges := v_charges || jsonb_build_object(
      'charge_id',    v_row.charge_id,
      'merchant_name', coalesce(v_merchant, 'Un local'),
      'amount_usd',   v_row.amount_usd,
      'my_payable_usd', v_mine_pay,
      'skipped',      false
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'charge_count', v_count,
    'financed_usd', v_assigned,
    'payable_usd', v_payable,
    -- Las que se quedaron fuera por pequeñas. La pantalla de entrada las dice:
    -- quien entra tiene derecho a saber de qué NO va a ser parte.
    'skipped_charge_count', v_skipped,
    'skipped_usd', v_skipped_usd,
    -- NUEVO: el desglose, en orden de consumo y con las saltadas dentro.
    'charges', v_charges
  );
end;
$$;

revoke all on function public.helios_group_join_plan(uuid, uuid)
  from public, anon, authenticated;

-- ── 5. Volver a repartir una cuenta ya cobrada ─────────────────────────────

create or replace function public.helios_group_resplit_charge(
  p_charge_id    uuid,
  p_user         uuid,
  p_capacity_usd numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_charge    public.charges%rowtype;
  v_parts     jsonb := '[]'::jsonb;
  v_split     jsonb;
  v_payables  jsonb;
  v_row       record;
  v_financed  numeric(18,4);
  v_new       numeric(18,4);
  v_new_pay   numeric(18,4);
  v_fin_delta numeric(18,4);
  v_delta     numeric(18,4);
  v_fee_delta numeric(18,4);
  v_half      numeric(18,4);
  v_mine      numeric(18,4);
  v_mine_pay  numeric(18,4);
  v_due_1     date;
  v_due_2     date;
  v_tx        uuid;
  v_n         integer;
begin
  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  -- Las cuotas de la cuenta, bloqueadas antes de leerlas y en orden fijo: dos
  -- personas entrando a la vez no pueden repartir cada una sobre la foto vieja.
  perform 1 from public.installments
  where charge_id = p_charge_id order by user_id, sequence for update;

  -- Defensivo. Con la regla 2 (punto 2) ninguna cuota de un grupo vivo puede
  -- haberse movido, así que esto no debería dispararse nunca; si se dispara es
  -- que apareció otro camino para pagar y hay que mirarlo, no que el usuario
  -- hizo algo raro.
  if exists (
    select 1 from public.installments
    where charge_id = p_charge_id and status <> 'pending'
  ) then
    raise exception 'Una de las cuentas del grupo ya se está pagando: no se puede repartir ahora'
      using errcode = '22023';
  end if;

  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);

  for v_row in select * from public.charge_debtors(p_charge_id) loop
    v_parts := v_parts || jsonb_build_object(
      'user_id', v_row.user_id, 'capacity_usd', v_row.financed_usd
    );
  end loop;

  v_parts := v_parts || jsonb_build_object(
    'user_id', p_user, 'capacity_usd', p_capacity_usd
  );

  -- El céntimo suelto vuelve a caer en quien puso la cuenta, que es quien lo
  -- asumió cuando se cobró: repartirla otra vez no le cambia de dueño el resto.
  v_split := public.helios_split_shares(v_financed, v_parts, v_charge.user_id);

  -- Demasiado pequeña para uno más: se deja intacta y se avisa a quien llama,
  -- que la contará como saltada. Mismo criterio que `helios_group_join_plan`, y
  -- por eso sale la misma cifra que se enseñó antes del PIN.
  if v_split->>'reason' = 'too_small' then
    return jsonb_build_object('charge_id', p_charge_id, 'skipped', true);
  end if;

  if not coalesce((v_split->>'ok')::boolean, false) then
    raise exception 'No se pudo repartir una de las cuentas del grupo' using errcode = '22023';
  end if;

  v_n        := (v_split->>'split_between')::integer;
  v_payables := public.helios_payables(v_split->'shares', v_financed, v_charge.amount_usd,
                                      v_charge.user_id);

  -- Las fechas del consumo, no las de hoy: quien entra hereda las de la orden.
  -- Calcularlas de nuevo le daría más plazo por llegar más tarde, y dos
  -- personas del mismo ticket acabarían con fechas distintas.
  select due_date into v_due_1 from public.installments
  where charge_id = p_charge_id and sequence = 1 limit 1;
  select due_date into v_due_2 from public.installments
  where charge_id = p_charge_id and sequence = 2 limit 1;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', 'join:' || p_charge_id::text || ':' || p_user::text,
          v_charge.business_date, p_charge_id,
          format('Entra alguien al grupo: esta cuenta pasa a repartirse entre %s', v_n))
  returning id into v_tx;

  -- ── A los que ya debían: se les baja ──────────────────────────────────────
  for v_row in select * from public.charge_debtors(p_charge_id) loop
    select (s->>'share_usd')::numeric into v_new
    from jsonb_array_elements(v_split->'shares') s
    where (s->>'user_id')::uuid = v_row.user_id;

    v_new     := coalesce(v_new, v_row.financed_usd);
    v_new_pay := coalesce((v_payables->>v_row.user_id::text)::numeric, v_row.share_usd);

    -- Dos deltas: el de cupo mueve el bloque y el techo del grupo; el de
    -- pagadero mueve el libro y las cuotas.
    v_fin_delta := v_row.financed_usd - v_new;
    v_delta     := v_row.share_usd - v_new_pay;
    v_fee_delta := v_delta - v_fin_delta;

    continue when v_delta <= 0 and v_fin_delta <= 0;

    v_half := round(v_new_pay / 2, 2);
    update public.installments
      set amount_usd = v_half, financed_usd = round(v_new / 2, 2)
    where charge_id = p_charge_id and user_id = v_row.user_id and sequence = 1;
    update public.installments
      set amount_usd = v_new_pay - v_half, financed_usd = v_new - round(v_new / 2, 2)
    where charge_id = p_charge_id and user_id = v_row.user_id and sequence = 2;

    update public.user_credit_blocks
      set charged_usd = charged_usd - v_fin_delta,
          fee_usd     = greatest(fee_usd - v_fee_delta, 0)
    where user_id = v_row.user_id and closed_at is null;

    -- Se libera CUPO, que es de lo que el techo es techo.
    if v_charge.group_id is not null then
      update public.group_members
        set spent_usd = greatest(spent_usd - v_fin_delta, 0)
      where group_id = v_charge.group_id and user_id = v_row.user_id;
    end if;

    if v_delta > 0 then
      insert into ledger.entries (transaction_id, account_id, debit, credit)
      values (v_tx, ledger.get_or_create_account('user_receivable', v_row.user_id), 0, v_delta);
    end if;
  end loop;

  -- ── Al que entra: su deuda ────────────────────────────────────────────────
  select (s->>'share_usd')::numeric into v_mine
  from jsonb_array_elements(v_split->'shares') s
  where (s->>'user_id')::uuid = p_user;

  if v_mine is null then
    raise exception 'No te alcanza para tomar parte de una de las cuentas del grupo'
      using errcode = '22023';
  end if;

  v_mine_pay := coalesce((v_payables->>p_user::text)::numeric,
                         public.helios_payable_usd(v_mine, v_financed, v_charge.amount_usd));

  perform public.helios_assign_debt(
    p_user, p_charge_id, v_mine, v_mine_pay, v_due_1, v_due_2,
    format('Tu límite no cubre €%s de lo que el grupo ya lleva',
           trim(to_char(v_mine, 'FM999999990.00')))
  );

  if v_charge.group_id is not null then
    update public.group_members
      set spent_usd = spent_usd + v_mine
    where group_id = v_charge.group_id and user_id = p_user and left_at is null;
  end if;

  insert into ledger.entries (transaction_id, account_id, debit, credit)
  values (v_tx, ledger.get_or_create_account('user_receivable', p_user), v_mine_pay, 0);

  return jsonb_build_object(
    'charge_id', p_charge_id,
    'financed_usd', v_mine,
    'payable_usd', v_mine_pay,
    'split_between', v_n
  );
end;
$$;

revoke all on function public.helios_group_resplit_charge(uuid, uuid, numeric)
  from public, anon, authenticated;

-- ── 6. Lo que se enseña antes del PIN ──────────────────────────────────────

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
  v_split  := public.helios_split_shares(v_financed, v_parts, v_user);
  v_shares := coalesce(v_split->'shares', '[]'::jsonb);

  -- Los pagaderos, con el mismo residuo A QUIEN PAGA que usa `confirm`. Las
  -- dos cifras tienen que salir idénticas: si no, el guardia de
  -- `p_expected_share_usd` rechazaría un cobro que nadie ha cambiado.
  v_n := coalesce((v_split->>'split_between')::integer, 0);
  for v_row in
    select (s->>'user_id')::uuid as user_id, (s->>'share_usd')::numeric as share
    from jsonb_array_elements(v_shares) s
    order by ((s->>'user_id')::uuid = v_user), (s->>'user_id')::uuid
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

-- ── 7. El cobro ────────────────────────────────────────────────────────────

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
  v_split := public.helios_split_shares(v_financed, v_parts, v_user);
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
    order by ((s->>'user_id')::uuid = v_user), (s->>'user_id')::uuid
  loop
    v_share := v_row.share;
    v_i := v_i + 1;

    -- ── NUEVO ──────────────────────────────────────────────────────────────
    -- El fee de cada quien cae sobre su parte. **El residuo de redondeo lo
    -- absorbe QUIEN PAGA** y no se reparte: la suma de los pagaderos tiene que
    -- dar EXACTO el total del cobro, porque es la contrapartida del asiento de
    -- arriba y el libro cuadra al céntimo o no cuadra.
    --
    -- Quien paga va el ÚLTIMO del bucle (ver el `order by`), así que sigue
    -- cerrando la cuenta `v_i = v_count`. Lo que cambia es quién es ese.
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

revoke all on function public.confirm_charge_as_group(uuid, uuid, text, text, numeric)
  from public, anon;
grant execute on function public.confirm_charge_as_group(uuid, uuid, text, text, numeric)
  to authenticated;
