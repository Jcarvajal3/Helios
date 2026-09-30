-- ============================================================================
-- Ronda — `preview_charge_claim` se quedó hablando de la mesa
--
-- La vuelta a los grupos (20260828000000) hizo `alter table public.charges
-- drop column if exists tab_id`, y 20260828010000 regeneró sus gemelas contra
-- `group_id`: `claim_charge_share` quedó bien, y `claimant_capacity` incluso
-- cambió de parámetro (`p_tab_id` → `p_group_id`).
--
-- `preview_charge_claim` se quedó fuera de esa regeneración. Sigue siendo la
-- de 20260827040000 y pide `v_charge.tab_id`, una columna que ya no existe.
--
-- PL/pgSQL no lo detecta al crear la función —los campos de un %rowtype se
-- resuelven al ejecutar—, así que la migración aplicó sin quejarse y el fallo
-- solo aparece al escanear: `record "v_charge" has no field "tab_id"` (42703).
-- Es decir, la pantalla de "Falta alguien en esta cuenta" (el QR `/c/<token>`,
-- `adjudicar.tsx`) reventaba en la vista previa — antes de enseñar nada y
-- antes del PIN. Justo el mecanismo del que cuelgan los dos casos que cubre:
-- el que faltó, y "pagué yo y ahora repartimos".
--
-- Único cambio respecto a 20260827040000: `tab_id` → `group_id`. Lo demás va
-- verbatim, por el mismo motivo que allí se generaron en vez de transcribirse.
-- ============================================================================

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
    'my_share_usd', v_mine
  );
end;
$$;

revoke all on function public.preview_charge_claim(text) from public, anon;
grant execute on function public.preview_charge_claim(text) to authenticated;
