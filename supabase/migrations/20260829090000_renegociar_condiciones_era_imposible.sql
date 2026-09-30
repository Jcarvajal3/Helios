-- ============================================================================
-- Ronda — Renegociar las condiciones de un comercio era imposible
--
-- EL FALLO
--
-- `admin_set_settlement_terms` validaba así:
--
--     v_total := upfront + (per_installment * 2) + commission;
--     if v_total <> 100 then raise ...
--
-- Y el check de la tabla, desde la facturación por cuenta de terceros
-- (20260827100000), pide otra cosa:
--
--     CHECK (upfront_pct + per_installment_pct * 2 = 100.00)
--
-- Las dos solo se pueden cumplir a la vez si la comisión es CERO. Con
-- cualquier comisión real, el súper admin recibía o el error de la función o
-- una violación de constraint — así que las condiciones de un comercio no se
-- podían tocar desde que cambió el modelo.
--
-- La razón del desajuste: antes el comercio cobraba el 80 % del consumo y la
-- comisión era el 20 % restante, así que los cuatro números sumaban 100. Ahora
-- la comisión se le cobra al comercio aparte y los tres tramos reparten SU
-- NETO. El check de la tabla se actualizó; la función que escribe en ella, no.
--
-- Lo encontró `edit_merchants_smoke` al repararlo, que llevaba roto desde el
-- 27 de agosto por esta misma aritmética.
--
-- EL ARREGLO
--
-- La función valida lo mismo que la tabla —los tramos cubren el neto entero—
-- y comprueba la comisión por su cuenta. El mensaje de error dice además que
-- la comisión no entra en esa suma, que es justo lo que confundía.
-- ============================================================================

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

  /**
   * LOS TRAMOS CUBREN EL NETO; LA COMISIÓN VA APARTE.
   *
   * 🐛 Esta comprobación sumaba también `p_commission_pct` y exigía 100:
   *
   *     v_total := upfront + (per_installment * 2) + commission;
   *
   * Era la aritmética del modelo anterior, donde el comercio cobraba el 80 %
   * del consumo y la comisión era el 20 % restante. Con la facturación por
   * cuenta de terceros (20260827100000) la comisión pasó a cobrarse aparte y
   * los tres tramos reparten el NETO — y el check de la tabla se cambió a
   * `upfront + per_installment*2 = 100`, pero esta función no.
   *
   * Las dos condiciones son incompatibles salvo con comisión 0, así que
   * renegociar las condiciones de un comercio era IMPOSIBLE desde el súper
   * admin: o rebotaba aquí, o rebotaba en el constraint. Lo cazó
   * `edit_merchants_smoke`.
   */
  v_total := p_upfront_pct + (p_per_installment_pct * 2);

  if v_total <> 100.00 then
    -- Sin signos de porcentaje literales en el mensaje: en RAISE, `%` es el
    -- marcador y `%%` el signo, y mezclarlos hace que el número de huecos no
    -- cuadre con los argumentos.
    raise exception
      'Los tramos de liquidación suman % y deben sumar 100. Adelanto: %. Por cuota: % (x2). La comisión (%) va aparte y no entra en esta suma.',
      v_total, p_upfront_pct, p_per_installment_pct, p_commission_pct
      using errcode = '22023';
  end if;

  if p_commission_pct > 100.00 then
    raise exception 'La comisión no puede pasar del 100' using errcode = '22023';
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
