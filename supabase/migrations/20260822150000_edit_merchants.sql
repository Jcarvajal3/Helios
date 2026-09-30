-- ============================================================================
-- Ronda — Editar comercios desde el super admin
--
-- Hasta ahora los comercios solo se podían crear. Pausar uno, cerrarlo o
-- renegociar sus porcentajes era un UPDATE a mano en la base.
--
-- Los tres porcentajes son negociables por comercio (docs/05 §3), pero
-- `settlement_adds_up` obliga a que 30 + 25 + 25 + 20 = 100 exactamente. Un
-- error de tipeo aquí descuadraría el libro en silencio, así que la RPC
-- valida antes de tocar nada y explica qué falta para cuadrar.
-- ============================================================================

/**
 * Pausar, reactivar o terminar un comercio.
 *
 * `paused` deja de aceptar cobros nuevos pero conserva lo pendiente: la
 * política de lectura `merchants_read_active` solo expone los activos, así
 * que un comercio pausado desaparece de la app sin borrar su historia.
 */
create or replace function public.admin_set_merchant_status(
  p_merchant_id uuid,
  p_status      public.merchant_status,
  p_note        text default null
)
returns public.merchants
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_row   public.merchants%rowtype;
  v_owed  numeric(18,4);
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede cambiar el estado de un comercio'
      using errcode = '42501';
  end if;

  -- Terminar un comercio al que todavía se le debe dinero es casi siempre un
  -- error: lo pendiente hay que pagarlo igual. Se bloquea y se dice cuánto.
  if p_status = 'terminated' then
    select coalesce(sum(amount_usd), 0) into v_owed
    from public.settlements
    where merchant_id = p_merchant_id and status = 'pending';

    if v_owed > 0 then
      raise exception 'No puedes terminar este comercio: le debes $%. Págale primero.', v_owed
        using errcode = '22023';
    end if;
  end if;

  update public.merchants
    set status = p_status, updated_at = now()
  where id = p_merchant_id
  returning * into v_row;

  if not found then
    raise exception 'Comercio no encontrado' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.status_changed', p_merchant_id,
    jsonb_build_object('status', p_status, 'note', p_note));

  return v_row;
end;
$$;

revoke all on function public.admin_set_merchant_status(uuid, public.merchant_status, text)
  from public, anon;
grant execute on function public.admin_set_merchant_status(uuid, public.merchant_status, text)
  to authenticated;

/**
 * Renegociar las condiciones de liquidación.
 *
 * Los porcentajes deben sumar 100 entre lo que recibe el comercio y la
 * comisión: `upfront + (per_installment × 2) + commission = 100`. La base ya
 * lo exige con un check, pero rebotar con "violación de restricción" no le
 * dice nada a quien está negociando con un local — aquí se explica.
 *
 * ⚠️ Solo afecta a las ventas FUTURAS. Lo ya devengado se calculó con las
 * condiciones vigentes en su momento y no se recalcula: cambiar el pasado
 * descuadraría liquidaciones ya pagadas.
 */
create or replace function public.admin_set_settlement_terms(
  p_merchant_id         uuid,
  p_upfront_pct         numeric,
  p_per_installment_pct numeric,
  p_commission_pct      numeric,
  p_policy              public.settlement_policy
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_total numeric(6,2);
  v_old   public.merchant_settlement_terms%rowtype;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede cambiar las condiciones'
      using errcode = '42501';
  end if;

  if p_upfront_pct < 0 or p_per_installment_pct < 0 or p_commission_pct < 0 then
    raise exception 'Ningún porcentaje puede ser negativo' using errcode = '22023';
  end if;

  v_total := p_upfront_pct + (p_per_installment_pct * 2) + p_commission_pct;

  if v_total <> 100.00 then
    -- Sin signos de porcentaje literales en el mensaje: en RAISE, `%` es el
    -- marcador y `%%` el signo, y mezclarlos hace que el número de huecos no
    -- cuadre con los argumentos.
    raise exception
      'Los porcentajes suman % y deben sumar 100. Adelanto: %. Por cuota: % (x2). Comisión: %.',
      v_total, p_upfront_pct, p_per_installment_pct, p_commission_pct
      using errcode = '22023';
  end if;

  select * into v_old from public.merchant_settlement_terms
  where merchant_id = p_merchant_id;

  if not found then
    raise exception 'Ese comercio no tiene condiciones que cambiar' using errcode = 'P0002';
  end if;

  update public.merchant_settlement_terms
    set upfront_pct = p_upfront_pct,
        per_installment_pct = p_per_installment_pct,
        commission_pct = p_commission_pct,
        policy = p_policy,
        updated_at = now()
  where merchant_id = p_merchant_id;

  perform audit.log(v_actor, 'merchant.terms_changed', p_merchant_id,
    jsonb_build_object(
      'antes', jsonb_build_object(
        'upfront', v_old.upfront_pct, 'per_installment', v_old.per_installment_pct,
        'commission', v_old.commission_pct, 'policy', v_old.policy),
      'despues', jsonb_build_object(
        'upfront', p_upfront_pct, 'per_installment', p_per_installment_pct,
        'commission', p_commission_pct, 'policy', p_policy)
    ));

  return jsonb_build_object(
    'ok', true,
    'upfront_pct', p_upfront_pct,
    'per_installment_pct', p_per_installment_pct,
    'commission_pct', p_commission_pct,
    'policy', p_policy
  );
end;
$$;

revoke all on function public.admin_set_settlement_terms(uuid, numeric, numeric, numeric, public.settlement_policy)
  from public, anon;
grant execute on function public.admin_set_settlement_terms(uuid, numeric, numeric, numeric, public.settlement_policy)
  to authenticated;

/** Quitar a alguien del personal de un comercio, con efecto inmediato. */
create or replace function public.admin_remove_merchant_staff(
  p_merchant_id uuid,
  p_user_id     uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede quitar personal' using errcode = '42501';
  end if;

  -- Se desactiva en vez de borrar: los cobros que generó esa persona apuntan
  -- a su fila, y borrarla dejaría el historial sin saber quién cobró.
  update public.merchant_users
    set is_active = false
  where merchant_id = p_merchant_id and user_id = p_user_id;

  if not found then
    raise exception 'Esa persona no es personal de este comercio' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.staff_removed', p_merchant_id,
    jsonb_build_object('user_id', p_user_id));

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.admin_remove_merchant_staff(uuid, uuid) from public, anon;
grant execute on function public.admin_remove_merchant_staff(uuid, uuid) to authenticated;

/** Detalle de un comercio para la pantalla de edición: condiciones y personal. */
create or replace function public.admin_merchant_detail(p_merchant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_terms public.merchant_settlement_terms%rowtype;
  v_staff jsonb;
  v_owed  numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_terms from public.merchant_settlement_terms
  where merchant_id = p_merchant_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', mu.user_id,
    'name', p.full_name,
    'phone', p.phone_e164,
    'role', mu.role,
    'branch', b.name
  ) order by mu.created_at), '[]'::jsonb) into v_staff
  from public.merchant_users mu
  join public.profiles p on p.id = mu.user_id
  left join public.merchant_branches b on b.id = mu.branch_id
  where mu.merchant_id = p_merchant_id and mu.is_active;

  select coalesce(sum(amount_usd), 0) into v_owed
  from public.settlements
  where merchant_id = p_merchant_id and status = 'pending';

  return jsonb_build_object(
    'terms', jsonb_build_object(
      'upfront_pct', v_terms.upfront_pct,
      'per_installment_pct', v_terms.per_installment_pct,
      'commission_pct', v_terms.commission_pct,
      'policy', v_terms.policy
    ),
    'staff', v_staff,
    'pending_usd', v_owed
  );
end;
$$;

revoke all on function public.admin_merchant_detail(uuid) from public, anon;
grant execute on function public.admin_merchant_detail(uuid) to authenticated;
