-- ============================================================================
-- Helios — plpgsql_check revisa las funciones
--
-- Postgres no valida el cuerpo de una función PL/pgSQL al crearla: una que lea
-- una tabla podada o una columna renombrada solo falla cuando alguien la llama.
-- `plpgsql_check` la hace fallar antes. La usa `supabase/poda/verificar.sql`,
-- que tiene que dar cero errores tras cada migración (docs/00 §4.1 y §9).
--
-- Solo es una herramienta de revisión: ninguna función la llama.
-- ============================================================================

create extension if not exists plpgsql_check with schema extensions;
