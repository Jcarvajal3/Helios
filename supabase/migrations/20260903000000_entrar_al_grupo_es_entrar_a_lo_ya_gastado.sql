-- ============================================================================
-- Ronda — Entrar a un grupo es entrar a lo que ya se gastó
--
-- Había DOS formas de sumarse a un gasto y cada una con sus reglas:
--
--   1. Entrar al grupo, que solo valía para los cobros SIGUIENTES.
--   2. Escanear el QR de una orden ya pagada (`/c/<token>`), que daba una
--      parte de ESA cuenta y solo de esa, con su propia ventana, su propio
--      PIN y su propia pantalla.
--
-- Dos mecanismos para una sola pregunta —"llegué tarde, ¿cómo me sumo?"— es
-- una pregunta que el usuario tiene que hacerse cada vez. Se queda uno:
--
--   **Al entrar a un grupo asumes tu parte de todo lo que el grupo lleva
--   gastado esta noche, y de lo que venga.**
--
-- ── Por qué es seguro rehacer un reparto ya hecho ───────────────────────────
--
-- Por lo mismo que lo era el QR de la orden, y ahora sin la letra pequeña:
-- **meter a alguien solo puede BAJAR las partes** (docs/00 §2.7.1, propiedad
-- 3). Con el total fijo, sumar capacidad solo puede bajar el nivel común `λ`,
-- y cada parte es `min(techo, λ)`. Nadie a quien no se le pregunta puede
-- acabar debiendo más.
--
-- Y la ventana en la que eso vale ya no hay que explicarla: un grupo solo
-- existe dentro de su día operativo, así que **todas sus cuentas están dentro
-- de la ventana por construcción**. La ventana y la vida del grupo son la
-- misma cosa. Desaparece un concepto entero del vocabulario.
--
-- ── La propiedad que lo hace explicable en una frase ────────────────────────
--
-- Fijando la capacidad de quien ya debía en su parte actual —la regla que ya
-- usaba la adjudicación— el reparto final es EL MISMO que si todos hubieran
-- estado desde el principio, y no depende del orden de llegada. Comprobación:
-- si alguien estaba topado, su parte era su techo y su capacidad sigue
-- siéndolo; si no lo estaba, su parte era `λ_viejo ≥ λ_nuevo`, así que
-- `min(parte, λ_nuevo) = λ_nuevo = min(techo, λ_nuevo)`. Idéntico en los dos
-- casos.
--
--     Da igual cuándo entres: al final de la noche todos pagan lo mismo que
--     si hubieran estado desde el primer trago.
--
-- ── Las tres reglas sin las cuales esto no simplifica nada ──────────────────
--
--   1. **Entras a todo lo que se pueda repartir, y tu techo lo cubre.** El
--      aporte máximo tiene que dar para lo retroactivo: el techo es para lo
--      que VIENE, no para negociar a la baja lo que los demás ya se bebieron.
--      Si el saldo no te llega, **no entras** — eso sí sería entrar a medias.
--      La única cuenta de la que no serás parte es la que **no admite a nadie
--      más** por el mínimo de $2,50 (una de $8 entre cuatro): esa se salta, se
--      dice antes de entrar, y no cierra el grupo. Bloquear ahí dejaba un
--      grupo muerto para nuevos toda la noche por una ronda pequeña de las
--      once, y quedarse fuera de UNA cuenta no es un concepto nuevo: ya pasa
--      con quien tiene mora o agotó su techo.
--   2. **Mientras el grupo vive, sus cuotas no se pagan** (punto 2 abajo).
--      Rehacer un reparto solo es seguro mientras ningún dinero se haya
--      movido; hoy nada impedía pagar esta misma noche la cuota de hace una
--      hora. El bloqueo dura horas —el grupo muere a las 10 AM— y a cambio
--      elimina de raíz los dos errores más feos que tenía la adjudicación
--      ("alguien ya pagó" / "alguien está pagando").
--   3. **Volver a entrar no re-adjudica nada.** El plan solo mira las cuentas
--      en las que no tienes ya una cuota, y el techo arranca cubriendo lo que
--      este grupo ya te cargó, no en cero.
--
-- ── Lo que se retira ────────────────────────────────────────────────────────
--
-- `charge_share_token`, `preview_charge_claim`, `claim_charge_share`,
-- `claimant_capacity` y la columna `charges.share_token`. Con ellas se van del
-- lado app la pantalla de repartir, la de adjudicar y la rama `/c/` del
-- escáner, que pasa de leer tres formatos a leer dos.
--
-- ⬜ **Carrera conocida y asumida.** Si alguien confirma un cobro del grupo en
-- el mismo instante en que otro entra, ese cobro puede quedarse sin el que
-- entra: las dos transacciones no se ven. La degradación es benigna —esa cuenta
-- se reparte como si hubiera entrado un segundo más tarde, que es lo que pasaba
-- SIEMPRE hasta hoy— y ningún dinero queda mal.
--
--     🔎 **Está toda explicada, con su síntoma y su arreglo, en el punto 10 de
--     este mismo archivo, junto al detector `helios_group_split_gaps`.**
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El QR de la orden se retira
-- ---------------------------------------------------------------------------
-- `charge_debtors` NO se va: quiénes deben una cuenta y con cuánto es lo que
-- necesita el reparto retroactivo de aquí abajo.

drop function if exists public.claim_charge_share(text, text);
drop function if exists public.preview_charge_claim(text);
drop function if exists public.charge_share_token(uuid);
drop function if exists public.claimant_capacity(uuid, uuid);

alter table public.charges drop column if exists share_token;

-- ---------------------------------------------------------------------------
-- 2. Mientras el grupo vive, sus cuotas no se pagan
-- ---------------------------------------------------------------------------
/**
 * REGLA 2. Rehacer un reparto reescribe cuotas, y eso solo es seguro mientras
 * ninguna se haya movido. Nada lo impedía: la cuota 1 vence a 7 días, pero
 * cotizar y reportar un pago esta misma noche era posible, y entonces el que
 * entrara a las 3 AM se encontraba con "todo retroactivo… menos esta cuenta".
 *
 * Se corta al COTIZAR —igual que el pago ya reportado, y por el mismo motivo—
 * porque entre cotizar y reportar la persona hace la transferencia, y negarle
 * el reporte con el dinero ya enviado es el peor momento posible.
 *
 * Va como trigger sobre `payment_quote_items` y no dentro de
 * `quote_installments`: son cuatro líneas contra reemitir una función de 150,
 * y reemitir una función grande partiendo de una copia es literalmente cómo se
 * coló la regresión del adelanto duplicado. De paso protege cualquier camino
 * futuro que meta cuotas en una cotización.
 */
create or replace function public.installment_not_in_a_live_group()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if exists (
    select 1
    from public.installments i
    join public.charges c on c.id = i.charge_id
    join public.groups   g on g.id = c.group_id
    where i.id = new.installment_id
      and g.business_date = public.helios_business_date(now())
  ) then
    raise exception
      'Esa compra es de un grupo que sigue abierto: todavía puede entrar alguien y bajarte la parte. Podrás pagarla a partir de las 10 AM.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

revoke all on function public.installment_not_in_a_live_group() from public, anon, authenticated;

drop trigger if exists payment_quote_items_live_group on public.payment_quote_items;
create trigger payment_quote_items_live_group
  before insert on public.payment_quote_items
  for each row execute function public.installment_not_in_a_live_group();

-- ---------------------------------------------------------------------------
-- 3. Los pagaderos de un reparto, en un solo sitio
-- ---------------------------------------------------------------------------
/**
 * De una lista de partes financiadas saca lo que paga cada quien, con el
 * residuo de redondeo al último para que la suma cuadre al céntimo con el
 * asiento (docs/00 §2.11).
 *
 * Existía tres veces copiado —`preview_group_charge`, `confirm_charge_as_group`
 * y la adjudicación—. Se extrae ahora porque el plan de entrada tiene que
 * enseñar ANTES del PIN exactamente la cifra que se va a cobrar DESPUÉS, y dos
 * copias del reparto del céntimo son dos cifras distintas el día que una
 * cambie.
 */
create or replace function public.helios_payables(
  p_shares    jsonb,   -- [{"user_id": uuid, "share_usd": numeric}, ...]
  p_base_usd  numeric,
  p_total_usd numeric
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
    order by 1
  loop
    v_i := v_i + 1;

    -- El último cierra la cuenta con lo que falte. El orden por `user_id` es
    -- lo que hace que dos ejecuciones del mismo reparto den lo mismo.
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

revoke all on function public.helios_payables(jsonb, numeric, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Las cuentas del grupo que a alguien le faltan
-- ---------------------------------------------------------------------------
/**
 * REGLA 3. Solo las cuentas en las que esa persona NO tiene ya una cuota.
 * Quien sale y vuelve a entrar no vuelve a asumir lo que ya asumió.
 *
 * El orden es el del consumo y es determinante: la capacidad de quien entra se
 * va gastando cuenta a cuenta, así que el orden decide cuánto le queda para la
 * siguiente. Fijo, para que el plan que se enseña y el que se ejecuta
 * coincidan.
 */
create or replace function public.helios_group_open_charges(p_group_id uuid, p_user uuid)
returns table (charge_id uuid, base_usd numeric, amount_usd numeric)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select c.id, coalesce(c.base_usd, c.amount_usd), c.amount_usd
  from public.charges c
  where c.group_id = p_group_id
    and c.status = 'confirmed'
    and not exists (
      select 1 from public.installments i
      where i.charge_id = c.id and i.user_id = p_user
    )
  order by c.confirmed_at, c.id;
$$;

revoke all on function public.helios_group_open_charges(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. El plan de entrada: qué me toca de lo ya gastado
-- ---------------------------------------------------------------------------
/**
 * Lo que asumiría esta persona si entrara ahora mismo. No escribe nada.
 *
 * Es la MISMA cuenta que hace la entrada de verdad, y por eso vive en una
 * función y no copiada en dos: la peor versión posible de esto es una pantalla
 * que dice que cabes y un PIN que te rechaza (o al revés).
 *
 * La capacidad para cada cuenta es lo que le queda de saldo descontando lo que
 * este mismo plan ya le comprometió en las anteriores. NO se acota por el
 * techo que esté eligiendo: lo retroactivo se calcula a capacidad plena y
 * luego el techo tiene que cubrirlo (regla 1). Un techo bajo no es una forma
 * de entrar pagando menos de lo que te toca de lo que ya se bebieron.
 *
 * Hay dos formas de que una cuenta no admita al que entra, y NO se tratan
 * igual — la diferencia es de quién es el problema:
 *
 *   · **La cuenta no da para uno más** sin bajar del mínimo por persona (una
 *     de $8 entre cuatro). Esa cuenta **se salta** y se sigue con las demás:
 *     el que entra no es deudor de ella, exactamente igual que quien quedó
 *     fuera de un reparto por mora o por techo agotado, que es algo que pasa
 *     desde siempre. Bloquear la entrada aquí dejaba un grupo **cerrado toda
 *     la noche** por una cuenta pequeña de las once, y eso es peor que la
 *     excepción.
 *   · **No le alcanza el saldo** para su parte de las que sí se pueden
 *     repartir (`no_capacity`). Ahí sí se bloquea: eso es entrar a medias por
 *     falta de dinero, no por una cuenta indivisible, y tiene arreglo de su
 *     lado — pagar cuotas y volver.
 */
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
  v_n           integer;
begin
  for v_row in select * from public.helios_group_open_charges(p_group_id, p_user) loop
    v_parts := '[]'::jsonb;
    v_n     := 0;

    -- La capacidad de quien ya debía es su parte actual. Ver la cabecera: da
    -- el mismo reparto que volver a mirarle el saldo y hace imposible generarle
    -- deuda a alguien que no está delante del teléfono.
    for v_deb in select * from public.charge_debtors(v_row.charge_id) loop
      v_parts := v_parts || jsonb_build_object(
        'user_id', v_deb.user_id, 'capacity_usd', v_deb.financed_usd
      );
      v_n := v_n + 1;
    end loop;

    v_parts := v_parts || jsonb_build_object(
      'user_id', p_user, 'capacity_usd', greatest(v_avail - v_assigned, 0)
    );

    v_split := public.helios_split_shares(v_row.base_usd, v_parts);

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

    v_assigned := v_assigned + v_mine;
    v_payable  := v_payable + coalesce(
      (public.helios_payables(v_split->'shares', v_row.base_usd, v_row.amount_usd)
        ->>p_user::text)::numeric, 0);
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'charge_count', v_count,
    'financed_usd', v_assigned,
    'payable_usd', v_payable,
    -- Las que se quedaron fuera por pequeñas. La pantalla de entrada las dice:
    -- quien entra tiene derecho a saber de qué NO va a ser parte.
    'skipped_charge_count', v_skipped,
    'skipped_usd', v_skipped_usd
  );
end;
$$;

revoke all on function public.helios_group_join_plan(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Rehacer el reparto de UNA cuenta con alguien más dentro
-- ---------------------------------------------------------------------------
/**
 * El cuerpo de lo que hacía `claim_charge_share`, sin el token, sin el PIN y
 * sin la ventana: los tres los comprueba ahora quien llama, una sola vez para
 * todas las cuentas del grupo.
 *
 * Tampoco avisa: con varias cuentas serían N notificaciones por persona para
 * un solo hecho. El aviso lo manda `join_group` al final, con la cifra ya
 * cerrada.
 *
 * En el libro NO se editan los asientos originales: se pone uno nuevo que
 * mueve el cobrable de unos a otro, uno por cuenta, porque la liquidación al
 * comercio también es por cuenta.
 */
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

  v_split := public.helios_split_shares(v_financed, v_parts);

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
  v_payables := public.helios_payables(v_split->'shares', v_financed, v_charge.amount_usd);

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
    format('Tu límite no cubre $%s de lo que el grupo ya lleva',
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

-- ---------------------------------------------------------------------------
-- 7. Buscar el grupo: la cifra antes del PIN
-- ---------------------------------------------------------------------------
/**
 * Cuerpo de 20260830120000 más lo retroactivo. Buscar sigue sin comprometer
 * nada: esto no escribe.
 *
 * Lo que se añade es la cifra que decide si entras o no —cuánto llevan
 * gastado, cuánto te toca— y el suelo del techo, que ya no es $2,50 sino lo
 * que te toca de lo ya gastado. Un techo por debajo sería aceptar una deuda y
 * declarar acto seguido que no la cubres.
 */
create or replace function public.find_group_by_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
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
  if not coalesce((v_plan->>'ok')::boolean, false) then
    return jsonb_build_object(
      'ok', false,
      'reason', v_plan->>'reason',
      'name', v_group.name,
      'member_count', v_count,
      'available_usd', v_avail,
      'min_share_usd', public.min_share_usd()
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
    'closes_at', public.helios_business_day_end(v_group.business_date),
    -- Lo ya gastado y lo que de eso me toca. Es la mitad de lo que se acepta.
    'retro_charge_count', (v_plan->>'charge_count')::integer,
    'retro_financed_usd', v_retro,
    'retro_payable_usd', (v_plan->>'payable_usd')::numeric,
    -- Y de qué NO voy a ser parte: las cuentas demasiado pequeñas para uno
    -- más. Se dice antes de entrar, no se descubre en el detalle del grupo.
    'skipped_charge_count', (v_plan->>'skipped_charge_count')::integer,
    'skipped_usd', (v_plan->>'skipped_usd')::numeric,
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

-- ---------------------------------------------------------------------------
-- 8. Entrar: asumir lo ya gastado y autorizar lo que venga
-- ---------------------------------------------------------------------------
/**
 * Cuerpo de 20260830120000 más el reparto retroactivo. Sigue exigiendo PIN por
 * lo de siempre —a partir de este botón cualquiera del grupo puede generarte
 * deuda hasta tu techo— y ahora, además, porque la entrada misma crea deuda.
 */
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
    raise exception 'Tu aporte máximo no puede bajar de $%', public.min_share_usd()
      using errcode = '22023';
  end if;

  -- REGLA 1: el techo es para lo que VIENE. Lo ya gastado no se negocia a la
  -- baja: o lo cubre, o no se entra.
  if p_cap_usd < v_owed + v_retro then
    raise exception
      'Tu aporte máximo tiene que cubrir al menos los $% que ya te tocan de lo que el grupo lleva gastado',
      trim(to_char(v_owed + v_retro, 'FM999999990.00'))
      using errcode = '22023';
  end if;

  if p_cap_usd > v_avail + v_owed then
    raise exception 'Tu aporte máximo sería de $% y tienes $% disponibles', p_cap_usd, v_avail
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
     * cuenta de $6 no puede repartirla entre tres —no llega a $7,50— así que
     * el tercero entra sin asumir nada y a los dos de antes no les cambia un
     * céntimo. Decirles "bajó a $3,00" cuando siguen debiendo los mismos $3
     * es un aviso que miente sobre dinero, que es la peor clase de aviso.
     */
    v_was := coalesce((v_before->>v_member.user_id::text)::numeric, 0);

    perform public.notify(
      v_member.user_id,
      'group_charge',
      format('%s entró a %s', v_name, v_group.name),
      case
        when v_theirs < v_was then
          format('Ya son %s y tu parte de la noche bajó a $%s.',
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

revoke all on function public.join_group(text, numeric, text) from public, anon;
grant execute on function public.join_group(text, numeric, text) to authenticated;

comment on function public.join_group(text, numeric, text) is
  'Entrar a un grupo: asume tu parte de lo ya gastado esta noche y autoriza lo que venga, hasta tu techo. Ver docs/00-BASES 2.7.';

-- ---------------------------------------------------------------------------
-- 9. El aviso viejo se retira
-- ---------------------------------------------------------------------------
-- Lo mandaba un trigger al insertar el integrante, es decir ANTES de que el
-- reparto retroactivo existiera: no podía decir la cifra nueva, y dejarlo
-- mandaría dos avisos por el mismo hecho. `create_group` no lo echa de menos:
-- un grupo recién creado no tiene a quién avisar.

drop trigger if exists group_members_notify_joined on public.group_members;
drop function if exists public.notify_group_joined();

-- ---------------------------------------------------------------------------
-- 10. 🔎 EL DETECTOR DE LA CARRERA CONOCIDA
-- ---------------------------------------------------------------------------
/**
 * ⬜ CARRERA CONOCIDA Y ASUMIDA — "entró al grupo y esa cuenta no le tocó".
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * QUÉ ES. Si alguien confirma un cobro del grupo en el MISMO instante en que
 * otro entra, las dos transacciones no se ven: la que cobra lee los
 * participantes sin el que entra, y la que entra lee las cuentas sin ese
 * cobro. Resultado: ese cobro se reparte entre los de antes y el que entró
 * no tiene parte en él.
 *
 * QUÉ NO ES. No hay descuadre: las partes de esa cuenta suman el total, el
 * libro cuadra, nadie se pasa de su techo y a nadie le subió la parte. Lo
 * único roto es la promesa de §2.7.4 —"entras a todo lo de esta noche"— para
 * esa cuenta concreta. Es el comportamiento que tenía el producto ENTERO
 * hasta el 2026-09-03, así que ningún dinero queda mal.
 *
 * SÍNTOMA VISIBLE. En Grupos → detalle, esa persona ve la cuenta con
 * **"tu parte de $100: $0,00"**. Es la única señal, y se confunde con las
 * exclusiones legítimas —mora, techo agotado, o una cuenta demasiado pequeña
 * para uno más— que se ven exactamente igual.
 *
 * CÓMO SE MIRA:
 *
 *     select * from public.helios_group_split_gaps
 *     where diagnosis in ('race_likely', 'joined_after_and_missed');
 *
 * POR QUÉ NO ESTÁ ARREGLADO. Hay que tomar el candado del grupo ANTES de leer
 * los participantes, y eso es dentro de `confirm_charge_as_group`: 266 líneas
 * que PostgreSQL obliga a reemitir enteras para añadir una. Reemitir funciones
 * grandes es cómo se coló la regresión del adelanto duplicado (20260825220000),
 * así que se hace en su propio cambio y no dentro de este.
 *
 * CÓMO SE ARREGLARÍA. Copiar VERBATIM el cuerpo de `confirm_charge_as_group`
 * de 20260830190000 —la última versión, no una anterior, que fue justo el
 * error del 25-ago— y añadir, justo antes del `for v_row in select * from
 * public.group_participants(...)`:
 *
 *     perform 1 from public.groups where id = v_group_id for update;
 *
 * Con eso las dos transacciones se ponen en fila: `join_group` ya toma esa
 * misma fila `for update`.
 */
create or replace view public.helios_group_split_gaps as
select
  g.id                as group_id,
  g.name              as group_name,
  g.business_date,
  c.id                as charge_id,
  c.amount_usd,
  c.confirmed_at,
  m.user_id,
  p.full_name         as name,
  m.authorized_at,
  round(extract(epoch from (c.confirmed_at - m.authorized_at))::numeric, 3) as gap_seconds,
  case
    /**
     * La cuenta no admite a nadie más: no llega a `(deudores + 1) × $2,50`.
     * Es la exclusión que el propio reparto retroactivo aplica a propósito
     * (regla 1), y va PRIMERO porque es legítima venga cuando venga.
     */
    when coalesce(c.base_usd, c.amount_usd) <
         ((select count(distinct i.user_id) from public.installments i
           where i.charge_id = c.id) + 1) * public.min_share_usd()
      then 'too_small_to_split'
    /**
     * Entró DESPUÉS de que el cobro existiera, la cuenta sí daba para uno más
     * y aun así no tiene parte. No puede pasar por ningún camino legítimo: si
     * no hubiera podido tomar su parte, `join_group` habría rechazado la
     * entrada. Si aparece una fila así, es un fallo.
     */
    when m.authorized_at > c.confirmed_at then 'joined_after_and_missed'
    /**
     * Entró en el mismo suspiro en que se confirmaba el cobro. Es la carrera.
     * Cinco segundos es holgado a propósito: las dos transacciones duran
     * milisegundos, así que un hueco mayor casi siempre es otra cosa.
     */
    when c.confirmed_at - m.authorized_at < interval '5 seconds' then 'race_likely'
    /**
     * Estaba dentro mucho antes y el servidor lo dejó fuera de ese reparto: o
     * tenía una cuota vencida, o no le llegaba el techo a los $2,50 (docs/00
     * §2.7). Esto es correcto y no hay nada que mirar.
     */
    else 'excluded_legitimately'
  end as diagnosis
from public.charges c
join public.groups g        on g.id = c.group_id
join public.group_members m on m.group_id = g.id
join public.profiles p      on p.id = m.user_id
where c.status = 'confirmed'
  -- Quien ya se había ido cuando se cobró no tenía por qué entrar en ese
  -- reparto: no es un hueco.
  and (m.left_at is null or m.left_at > c.confirmed_at)
  and not exists (
    select 1 from public.installments i
    where i.charge_id = c.id and i.user_id = m.user_id
  );

comment on view public.helios_group_split_gaps is
  'Diagnostico: integrantes de un grupo SIN parte en una cuenta de ese grupo. Filtrar por diagnosis in (''race_likely'', ''joined_after_and_missed'') para ver la carrera conocida de docs/00-BASES 2.7.5; el resto son exclusiones correctas.';

-- Solo para quien tenga acceso a la base. No es una pantalla: enseña la deuda
-- de otras personas, y su sitio es el SQL editor o el super admin, no la app.
revoke all on public.helios_group_split_gaps from public, anon, authenticated;
