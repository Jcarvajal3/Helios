-- ============================================================================
-- Ronda — Corrige el trigger de cuadre del ledger
--
-- Bug encontrado al ejercitar confirm_charge fuera de una transacción de
-- prueba (2026-08-22): `permission denied for schema ledger`.
--
-- Causa: `ledger.check_transaction_balances()` es un CONSTRAINT TRIGGER
-- DEFERRABLE INITIALLY DEFERRED, así que no corre durante el INSERT —
-- corre en el COMMIT. Para entonces el contexto SECURITY DEFINER de
-- `confirm_charge` (que corre como `postgres`) ya se cerró, y el trigger se
-- ejecuta con el rol de la sesión: `authenticated`, que no tiene USAGE sobre
-- el esquema `ledger` por diseño.
--
-- Resultado: TODA venta confirmada desde la app fallaba en el commit. El
-- ledger estaba correcto; lo que no podía era cerrarse.
--
-- Por qué no lo detectaron las pruebas de humo: envolvían todo en
-- `begin; ... rollback;`, y un constraint trigger diferido nunca dispara si
-- la transacción no llega a commit. Las pruebas pasaban sin haber ejecutado
-- ni una vez la comprobación de cuadre. Corregido en los tests con
-- `set constraints all immediate` antes del rollback.
-- ============================================================================

create or replace function ledger.check_transaction_balances()
returns trigger
language plpgsql
-- SECURITY DEFINER: el trigger corre en el COMMIT, con el rol de la sesión.
-- Sin esto, ningún rol que no sea `postgres` puede cerrar una transacción
-- que toque el ledger.
security definer
set search_path = ledger, pg_temp
as $$
declare
  v_diff numeric(18,4);
begin
  select coalesce(sum(debit) - sum(credit), 0) into v_diff
  from ledger.entries
  where transaction_id = new.transaction_id;

  if v_diff <> 0 then
    raise exception 'ledger.entries no cuadra para la transacción %: diferencia %',
      new.transaction_id, v_diff;
  end if;

  return null;
end;
$$;

revoke all on function ledger.check_transaction_balances() from public, anon, authenticated;
