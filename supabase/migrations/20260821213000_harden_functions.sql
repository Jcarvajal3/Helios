-- ============================================================================
-- Endurecimiento de funciones — hallazgos del linter de Supabase
--
-- 1. Postgres otorga EXECUTE a PUBLIC por defecto en toda función nueva. El
--    `grant ... to authenticated` de las migraciones anteriores no quitaba ese
--    permiso implícito, así que el rol `anon` podía invocar set_user_pin y
--    verify_user_pin sin sesión. Fallaban en la comprobación de auth.uid(),
--    pero dejaban expuesta una superficie innecesaria (y con bcrypt de por
--    medio, un vector barato de agotamiento de CPU).
--
-- 2. touch_updated_at corría con search_path mutable.
-- ============================================================================

-- --- 1. Quitar el EXECUTE implícito de PUBLIC/anon --------------------------

revoke all on function public.set_user_pin(text) from public, anon;
revoke all on function public.verify_user_pin(text) from public, anon;
revoke all on function public.has_user_pin() from public, anon;
revoke all on function public.my_kyc_status() from public, anon;
revoke all on function public.start_kyc_verification() from public, anon;
revoke all on function public.register_device(text, text, text) from public, anon;

-- Volvemos a conceder solo al rol que corresponde.
grant execute on function public.set_user_pin(text) to authenticated;
grant execute on function public.verify_user_pin(text) to authenticated;
grant execute on function public.has_user_pin() to authenticated;
grant execute on function public.my_kyc_status() to authenticated;
grant execute on function public.start_kyc_verification() to authenticated;
grant execute on function public.register_device(text, text, text) to authenticated;

-- handle_new_user es una función de trigger: nadie debe poder llamarla por RPC.
revoke all on function public.handle_new_user() from public, anon, authenticated;

-- --- 2. search_path fijo en el trigger de updated_at ------------------------

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.touch_updated_at() from public, anon, authenticated;
