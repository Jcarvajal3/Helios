-- ═══════════════════════════════════════════════════════════════════════════
-- El logo del comercio en la pantalla de cobro
--
-- Las dos pantallas del pago —confirmar y el acuse— enseñaban el nombre del
-- local en texto y nada más. `merchants.logo_url` existe desde
-- 20260822170500 y `preview_charge` no lo estaba devolviendo.
--
-- Solo se toca `preview_charge`, y solo para añadir una clave. Lo demás que
-- necesitan esas pantallas ya viaja: el número de orden lo devuelve esta
-- misma función desde 20260822250000 (la app no lo leía) y las fechas de las
-- cuotas las devuelve `confirm_charge`.
--
-- `confirm_charge` NO se toca a propósito. Reescribirla obligaría a repetir
-- aquí sus ~140 líneas de validación de límites y asientos contables, y una
-- copia de eso en una migración se queda vieja el día que alguien toque el
-- ledger. El acuse se pinta con lo que ya tiene el preview, que sigue en
-- memoria en esa misma pantalla.
--
-- Cambio aditivo: ninguna clave existente cambia de nombre ni de tipo, así
-- que una app vieja contra este esquema sigue funcionando igual.
-- ═══════════════════════════════════════════════════════════════════════════

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
  v_branch  text;
  v_logo    text;
  v_avail   jsonb;
  v_items   jsonb;
  v_rate    numeric;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  select m.name, b.name, m.logo_url into v_name, v_branch, v_logo
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

  return jsonb_build_object(
    'charge_id', v_charge.id,
    'order_number', v_charge.order_number,
    'merchant_name', v_name,
    'branch_name', v_branch,
    -- Null si el comercio todavía no cargó su logo: la app cae al disco con
    -- la inicial, que es lo que ya hace el buscador.
    'logo_url', v_logo,
    'amount_usd', v_charge.amount_usd,
    -- El precio se pacta en dólares (docs/05 §1), pero quien paga piensa en
    -- bolívares. Se manda la tasa junto al monto para que la app pueda decir
    -- con qué número lo convirtió.
    'amount_ves', case when v_rate is null then null else round(v_charge.amount_usd * v_rate, 2) end,
    'fx_rate', v_rate,
    'items', v_items,
    'status', v_charge.status,
    'expired', v_charge.expires_at < now(),
    -- Ya reclamado por otra persona: la app debe decirlo con claridad en vez
    -- de dejar al usuario reintentando un QR muerto.
    'claimed_by_other', (v_charge.user_id is not null and v_charge.user_id <> v_user),
    'available_usd', (v_avail->>'available_usd')::numeric,
    'sufficient_balance', (v_avail->>'available_usd')::numeric >= v_charge.amount_usd
  );
end;
$$;

revoke all on function public.preview_charge(uuid) from public, anon;
grant execute on function public.preview_charge(uuid) to authenticated;
