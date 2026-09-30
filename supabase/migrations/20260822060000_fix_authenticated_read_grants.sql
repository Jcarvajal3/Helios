-- ============================================================================
-- Ronda — Corrige un bug preexistente: faltaba GRANT SELECT para `authenticated`
--
-- Hallazgo al probar el ledger contra Postgres real (2026-08-22): ninguna
-- tabla de `public` tenía un GRANT explícito para `authenticated`. Las
-- políticas RLS existían y estaban bien escritas, pero RLS es un filtro de
-- FILAS que se evalúa DESPUÉS del permiso de tabla — sin el GRANT, Postgres
-- rechaza la consulta con "permission denied" antes de llegar a evaluar la
-- política.
--
-- Esto no es un problema nuevo de esta migración: ya afectaba a
-- `public.profiles`, la primera tabla que lee la app en Home. Se confirmó
-- reproduciéndolo con `SET ROLE authenticated; SELECT * FROM public.profiles;`
-- contra una base recién migrada.
--
-- Causa raíz: hay un `ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA
-- public` (fuera de estas migraciones, parte del arranque del proyecto) que
-- otorga a `anon`/`authenticated`/`service_role` solo `Dxtm` (delete,
-- references, trigger, maintain) sobre las tablas nuevas — nunca `r`
-- (select). Las migraciones de Supabase corren como `postgres`, así que
-- cada tabla nueva heredaba ese default incompleto en silencio.
-- ============================================================================

grant select on
  public.levels,
  public.profiles,
  public.user_devices,
  public.merchants,
  public.merchant_branches,
  public.products,
  public.product_categories,
  public.merchant_users,
  public.merchant_settlement_terms,
  public.terms_acceptances,
  public.exchange_rates,
  public.user_credit_blocks,
  public.charges,
  public.installments,
  public.payment_quotes,
  public.payment_reports,
  public.settlements,
  public.level_changes
to authenticated;

-- Para que no vuelva a pasar: toda tabla nueva que cree `postgres` en
-- `public` de aquí en adelante nace con SELECT para `authenticated`. RLS
-- sigue siendo la barrera real fila a fila; esto solo evita el permission
-- denied silencioso. Las tablas que deben quedar inaccesibles (user_pins,
-- pin_attempts) ya tienen RLS habilitado sin ninguna política — con RLS
-- así, un SELECT grant no expone nada: deniega todo por defecto.
alter default privileges for role postgres in schema public
  grant select on tables to authenticated;
