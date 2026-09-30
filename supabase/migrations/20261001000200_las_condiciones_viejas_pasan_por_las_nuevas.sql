-- ============================================================================
-- Helios — Las condiciones viejas pasan por las nuevas
--
-- Error heredado de Ronda, que encontró plpgsql_check (supabase/poda/NOTAS.md):
--
-- `admin_set_settlement_terms(uuid, numeric, numeric, numeric, settlement_policy)`
-- es la firma vieja, de cuando las condiciones eran UNA fila por comercio.
-- Desde 20260911206000 (las condiciones tienen vigencia) se guardan en
-- `merchant_terms`, con historia, y `merchant_settlement_terms` pasó a ser una
-- VISTA de las vigentes. Esa migración borró la firma vieja con `text`, pero la
-- de `settlement_policy` sobrevivió, y 20260925131000 la volvió a crear tal
-- cual (copiaba lo que había en producción). Su cuerpo hace
-- `update public.merchant_settlement_terms`, y una vista con `distinct on` no
-- se puede actualizar: la función revienta siempre con «cannot update view».
--
-- El panel usa la firma nueva (con `p_policy text`, vigencia y nota). La vieja
-- se queda —la llama `edit_merchants_smoke`—, pero ahora delega en la nueva,
-- que es la que sabe guardar: una renegociación que rige desde hoy.
-- ============================================================================

create or replace function public.admin_set_settlement_terms(
  p_merchant_id uuid,
  p_upfront_pct numeric,
  p_per_installment_pct numeric,
  p_commission_pct numeric,
  p_policy public.settlement_policy
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $function$
begin
  -- La nueva comprueba el super admin (con MFA), los porcentajes y deja la
  -- bitácora. Esta solo traduce la firma.
  return public.admin_set_settlement_terms(
    p_merchant_id, p_upfront_pct, p_per_installment_pct, p_commission_pct,
    p_policy::text, null::date, null::text
  );
end;
$function$;

comment on function public.admin_set_settlement_terms(uuid, numeric, numeric, numeric, public.settlement_policy) is
  'Firma vieja (sin vigencia). Delega en admin_set_settlement_terms(uuid, numeric, numeric, numeric, text, date, text) con vigencia desde hoy.';
