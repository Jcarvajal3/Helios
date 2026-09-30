-- ---------------------------------------------------------------------------
-- Ronda — El que entra a una cuenta ve QUÉ se consumió
-- ---------------------------------------------------------------------------
--
-- `preview_charge_claim` devolvía el local, el total y la parte que toca, pero
-- no el recibo. O sea: la pantalla donde alguien ACEPTA UNA DEUDA le pedía
-- confiar en un importe sin decirle de qué era.
--
-- No es un detalle cosmético. Quien escanea el QR de una cuenta ya pagada casi
-- nunca es quien estuvo pidiendo: es el que llegó tarde o el que se quedó sin
-- batería. "Bar X, $80, te tocan $20" no le deja comprobar nada — ni que sea
-- la cuenta que cree, ni que el total cuadre con lo que se bebió la mesa. Las
-- líneas ya estaban guardadas en `charge_items` desde 20260822250000 y
-- `preview_charge` ya las devuelve para el cobro individual; aquí faltaba
-- pedirlas.
--
-- Las líneas se leen con `security definer`, como todo lo demás de esta
-- función: quien reclama todavía no es deudor del cobro, así que la política
-- `charge_items_read_own` no le alcanza. El control de acceso es el token del
-- QR, que solo tiene quien pagó y a quien se lo pasó.
--
-- Solo van en la respuesta `ok`. En las de bloqueo —cerrada, ya estás dentro,
-- no cabes— no hay nada que decidir, y un recibo ahí es ruido.
--
-- Cuerpo idéntico al de 20260829040000 salvo los tres bloques marcados.
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
  v_items    jsonb;
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
    'capacity_usd', public.claimant_capacity(v_user, v_charge.group_id)
  );

  v_split := public.helios_split_shares(v_charge.amount_usd, v_parts);

  select m.name, b.name, m.logo_url into v_merchant, v_branch, v_logo
  from public.merchants m
  join public.merchant_branches b on b.id = v_charge.branch_id
  where m.id = v_charge.merchant_id;

  -- Qué se consumió. Mismo formato y mismo orden que `preview_charge`, para
  -- que las dos pantallas puedan pintarlo con la misma tarjeta.
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

  -- NUEVO: `helios_split_shares` devuelve `ok:true` aunque a MÍ me haya dejado
  -- fuera — los que ya debían siempre suman el total por sí solos. Sin esto,
  -- la pantalla pintaba una parte en null y el claim reventaba después del PIN
  -- con un `not null violation` pelado.
  if v_mine is null then
    return jsonb_build_object(
      'ok', false,
      'reason', 'no_capacity',
      'amount_usd', v_charge.amount_usd,
      'split_between', v_count,
      'merchant_name', v_merchant
    );
  end if;

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
    'my_share_usd', v_mine,
    'items', v_items
  );
end;
$$;

revoke all on function public.preview_charge_claim(text) from public, anon;
grant execute on function public.preview_charge_claim(text) to authenticated;
