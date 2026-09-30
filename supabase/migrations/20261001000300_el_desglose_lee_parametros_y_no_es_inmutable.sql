-- ============================================================================
-- Helios — El desglose lee parámetros y no es inmutable
--
-- Aviso de plpgsql_check heredado de Ronda (supabase/poda/NOTAS.md):
-- `helios_charge_breakdown` está declarada IMMUTABLE, pero lee el IVA y el fee
-- del servicio de `business_parameters` (`helios_vat_pct()`,
-- `helios_consumer_fee_pct()`, que son STABLE). Una función IMMUTABLE le
-- promete a Postgres que con los mismos argumentos da siempre lo mismo, así que
-- el planificador puede evaluarla una vez y guardar el resultado en el plan
-- cacheado de una función PL/pgSQL: tras cambiar el fee desde Ajustes, una
-- sesión que ya lo tenía cacheado seguiría cobrando el viejo.
--
-- STABLE es lo que de verdad es: mismo resultado dentro de una sentencia.
-- Nada la usa en un índice ni en una columna generada (que exigirían
-- IMMUTABLE).
-- ============================================================================

alter function public.helios_charge_breakdown(numeric, numeric) stable;
