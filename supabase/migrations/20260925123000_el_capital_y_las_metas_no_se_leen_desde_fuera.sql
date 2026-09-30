-- ============================================================================
-- Ronda — El capital, las metas y los umbrales no se leen desde fuera
--
-- `helios_parameter(key, fallback)` es `security definer` y está concedida a
-- `authenticated` desde 20260911202000: cualquier persona con sesión, también
-- un consumidor, podía pedir por RPC el capital disponible, las metas del
-- negocio y los umbrales de riesgo y de alertas (20260925110000, 20260925113000).
--
-- Desde aquí, las claves `capital_*`, `meta_*`, `umbral_*` y `alerta_*` solo
-- devuelven su valor si:
--   * la llamada viene de dentro de otra función (el caso normal: la función
--     de fuera ya decidió quién pasa), o
--   * quien llama es personal activo de la plataforma, o
--   * no es una petición de la API (cron, migraciones, service_role): PostgREST
--     fija el rol `authenticated`/`anon` y el propio sistema no.
-- Si no, devuelve el `fallback` que mandó quien llama, como si no hubiera
-- valor. Las claves del producto (fee, IVA, plazos…) no cambian: la app y las
-- funciones de la persona las siguen leyendo igual.
--
-- ── Por qué así y no quitando el permiso ────────────────────────────────────
-- Dentro de una función `security definer`, `current_user` es siempre el
-- dueño: no dice quién llamó. Lo que sí lo dice es la pila (`pg_context`):
-- una línea si se llamó sola desde la API, dos o más si la llamó otra función.
-- Comprobado en dev el 2026-09-25, como `authenticated` y como `postgres`, con
-- funciones plpgsql y sql, definer e invoker. Una función sql invoker que
-- PostgreSQL mete en línea no deja rastro en la pila y cuenta como llamada
-- directa: se queda del lado prudente.
--
-- Quién la usa (dev, 2026-09-25): once funciones, todas `security definer` y
-- todas con clave literal salvo `admin_set_business_parameter`, que es solo
-- del super admin. Ninguna política, vista, valor por defecto, índice, check
-- ni trabajo de cron. Ni la app ni el panel la llaman por RPC. Las únicas que
-- leen claves protegidas son `admin_risk_alerts` (`alerta_*`) y
-- `admin_set_business_parameter`, las dos desde dentro y para personal.
-- `helios_charge_breakdown` y `helios_installment_due_dates` son invoker e
-- inmutables, y no la llaman.
--
-- Un parámetro nuevo de capital, meta, umbral o alerta tiene que llevar el
-- prefijo para quedar protegido.
-- ============================================================================

create or replace function public.helios_parameter(p_key text, p_fallback numeric)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_ctx text;
begin
  if p_key ~ '^(capital|meta|umbral|alerta)_' then
    get diagnostics v_ctx = pg_context;
    if not (
      -- La llamó otra función: la pila tiene más de una línea.
      position(E'\n' in v_ctx) > 0
      -- El propio sistema, fuera de la API.
      or coalesce(current_setting('role', true), 'none') not in ('authenticated', 'anon')
      or public.is_platform_admin()
    ) then
      return p_fallback;
    end if;
  end if;

  return coalesce((
    select p.value
    from public.business_parameters p
    where p.key = p_key
      and p.effective_from <= public.helios_business_date(now())
    order by p.effective_from desc
    limit 1
  ), p_fallback);
end;
$$;

comment on function public.helios_parameter(text, numeric) is
  'El valor vigente HOY de un parametro. El fallback es su valor historico escrito en codigo: con la tabla vacia el sistema se comporta igual que antes de existir. Las claves capital_*, meta_*, umbral_* y alerta_* solo se devuelven dentro de otra funcion, al personal de Helios o fuera de la API; si no, sale el fallback.';

revoke all on function public.helios_parameter(text, numeric) from public, anon;
grant execute on function public.helios_parameter(text, numeric) to authenticated;
