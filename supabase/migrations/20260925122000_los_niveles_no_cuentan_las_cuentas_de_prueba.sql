-- ============================================================================
-- Ronda — Los niveles no cuentan las cuentas de prueba
--
-- `admin_level_config` contaba a todo el mundo en cada nivel, y sumaba su
-- deuda, sin mirar `is_test`. Se quedó fuera de la migración que sacó las
-- cuentas de prueba de las cifras (20260911180000).
--
-- Solo cambia eso. `exposure_usd` sigue siendo lo que era: la deuda pendiente
-- de la gente del nivel, en payable y con lo dado por perdido dentro. Para el
-- uso del cupo y la exposición en consumo está `admin_credit_utilization`.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_level_config()
 RETURNS TABLE(level smallint, label text, monthly_limit_usd numeric, required_spend_usd numeric, required_months smallint, is_active boolean, user_count integer, exposure_usd numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  select
    l.level, l.label, l.monthly_limit_usd, l.required_spend_usd,
    l.required_months, l.is_active,
    coalesce(u.cnt, 0)::integer,
    coalesce(u.debt, 0)::numeric
  from public.levels l
  left join (
    select p.level as lvl, count(*)::integer as cnt,
           sum(coalesce(d.open_debt, 0)) as debt
    from public.profiles p
    left join (
      select ins.user_id as uid, sum(ins.amount_usd) as open_debt
      from public.installments ins
      where ins.status = 'pending' and not ins.is_test
      group by 1
    ) d on d.uid = p.id
    where not p.is_test
    group by 1
  ) u on u.lvl = l.level
  where l.level >= 1
  order by l.level;
end;
$function$;

revoke all on function public.admin_level_config() from public, anon;
grant execute on function public.admin_level_config() to authenticated;
