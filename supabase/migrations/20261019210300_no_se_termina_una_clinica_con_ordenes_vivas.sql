-- ============================================================================
-- Helios — No se termina una clínica con órdenes vivas
--
-- `admin_set_merchant_status` no deja terminar una clínica a la que se le
-- debe dinero, pero solo sumaba las liquidaciones que ya existían. En Ronda
-- eso bastaba: el adelanto se devengaba al cobrar. En Helios no hay adelanto
-- y cada mitad se devenga el día en que vence su cuota, así que una clínica
-- con órdenes de esta semana no «debía» nada todavía y se podía terminar
-- aunque se le fueran a pagar los días 8 y 15. Lo destapó la prueba de
-- edición de clínicas al fijar el reparto 0/50/50 (20261019210200).
--
-- Ahora cuenta también las mitades por devengar (`metricas.mitades_por_devengar`).
-- ============================================================================

create or replace function public.admin_set_merchant_status(p_merchant_id uuid, p_status merchant_status, p_note text default null::text)
 returns merchants
 language plpgsql
 security definer
 set search_path to 'public', 'audit', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_today date := public.helios_business_date(now());
  v_row   public.merchants%rowtype;
  v_owed  numeric(18,4);
begin
  perform public.helios_assert_super_admin('cambiar el estado de una clínica');

  -- Terminar una clínica a la que todavía se le debe dinero es casi siempre
  -- un error: lo pendiente hay que pagarlo igual. Se bloquea y se dice cuánto.
  if p_status = 'terminated' then
    -- Lo que falta de lo ya devengado (las parciales cuentan por su resto)…
    select coalesce(sum(amount_usd - paid_usd), 0) into v_owed
    from public.settlements
    where merchant_id = p_merchant_id and status in ('pending', 'partial');

    -- …más las mitades de las cuotas que todavía no han vencido: se le
    -- pagan pague o no el paciente.
    v_owed := v_owed + coalesce((
      select sum(f.usd)
      from metricas.mitades_por_devengar(v_today, v_today + 60, p_merchant_id) f
    ), 0);

    if v_owed > 0 then
      -- Con dos decimales y no los cuatro de la columna: este texto se lee tal
      -- cual en el panel, y «le debes $6.0000» parece un error de la pantalla.
      raise exception 'No puedes terminar esta clínica: le debes $% (con lo que se le pagará por sus órdenes vivas). Espera a pagarle.',
        to_char(v_owed, 'FM999999990.00')
        using errcode = '22023';
    end if;
  end if;

  update public.merchants
    set status = p_status, updated_at = now()
  where id = p_merchant_id
  returning * into v_row;

  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.status_changed', p_merchant_id,
    jsonb_build_object('status', p_status, 'note', p_note));

  return v_row;
end;
$function$;
