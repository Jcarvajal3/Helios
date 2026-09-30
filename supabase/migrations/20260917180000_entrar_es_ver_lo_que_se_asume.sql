-- ============================================================================
-- Ronda — Entrar es ver lo que se asume
--
-- Entrar a un grupo que ya gastó CREA DEUDA en el acto, y la pantalla que lo
-- pide enseñaba de cada cuenta el nombre del local, su total y lo que te va a
-- costar con el fee dentro. Faltaba lo único con lo que esa cifra se puede
-- comprobar: **qué se consumió**, y **cuánto de eso ocupa de tu cupo**.
--
-- Sin esas dos, la pantalla pide aceptar una deuda de unos desconocidos con
-- dos números que no se pueden cuadrar entre sí — el de la cuenta va sin
-- servicio y el tuyo con él.
--
-- Cada cuenta del plan pasa a llevar:
--
--   my_financed_usd   mi parte EN CUPO: lo que se me descuenta del saldo.
--   items             las líneas del local, como en cualquier otra pantalla.
--   order_number      el identificador de la orden, que ya usan las demás.
--
-- Las saltadas —demasiado pequeñas para uno más— no llevan líneas: de esas no
-- se es parte, y enseñar lo que consumieron otros sería mirar la mesa de al
-- lado.
--
-- `find_group_by_code` no se toca: reenvía `charges` entero.
--
-- Cuerpo idéntico al de `20260917120000` salvo lo dicho.
-- ============================================================================

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
  v_order       bigint;
begin
  for v_row in select * from public.helios_group_open_charges(p_group_id, p_user) loop
    v_parts := '[]'::jsonb;
    v_n     := 0;

    -- El nombre del local, que es por lo que la mesa reconoce una cuenta. Un
    -- `order_number` no le dice nada a nadie de pie en una barra.
    select m.name, c.order_number into v_merchant, v_order
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
        'order_number', v_order,
        'amount_usd',   v_row.amount_usd,
        'financed_usd', v_row.base_usd,
        'my_financed_usd', null::numeric,
        'my_payable_usd', null::numeric,
        'skipped',      true,
        -- Sin líneas: de esta cuenta no se es parte, así que enseñar lo que
        -- consumieron otros sería mirar la mesa de al lado.
        'items',        '[]'::jsonb
      );
      continue;
    end if;

    if not coalesce((v_split->>'ok')::boolean, false) then
      return jsonb_build_object(
        'ok', false,
        'reason', 'no_capacity',
        'blocking_amount_usd', v_row.amount_usd,
        -- Lo que ocupa esa cuenta de CUPO. Es la cifra que enseña la pantalla:
        -- el total lleva el fee dentro y un importe con el servicio sumado no
        -- se enseña suelto en ninguna parte.
        'blocking_financed_usd', v_row.base_usd,
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
        -- Lo que ocupa esa cuenta de CUPO. Es la cifra que enseña la pantalla:
        -- el total lleva el fee dentro y un importe con el servicio sumado no
        -- se enseña suelto en ninguna parte.
        'blocking_financed_usd', v_row.base_usd,
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
      'order_number', v_order,
      'amount_usd',   v_row.amount_usd,
      'financed_usd', v_row.base_usd,
      -- MI PARTE, en las dos monedas. La de cupo faltaba y es la que se
      -- enseña: es lo que se descuenta del saldo, y lo único comparable con
      -- el total de la cuenta que tiene al lado.
      'my_financed_usd', v_mine,
      'my_payable_usd', v_mine_pay,
      'skipped',      false,
      -- QUÉ SE CONSUMIÓ. Es lo que convierte "asumes €12,32 de Bar Central"
      -- en algo que se puede comprobar con la mesa que tienes delante.
      'items', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'name',           ci.name,
                 'quantity',       ci.quantity,
                 'unit_price_usd', ci.unit_price_usd,
                 'line_total_usd', ci.line_total_usd
               ) order by ci.position, ci.created_at), '[]'::jsonb)
        from public.charge_items ci
        where ci.charge_id = v_row.charge_id
      )
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
