-- ============================================================================
-- Helios — «Mi saldo y cuotas» dice el nivel y el saldo total (2026-10-23)
--
-- Textos aprobados por Javier el 2026-10-22: el mensaje del botón «Mi saldo y
-- cuotas» enseña el nivel del paciente, su saldo total (el tope de su
-- nivel) y lo disponible, y ya no lista los pagos terminados (el mensaje se
-- hacía largo).
--
-- `bot_paciente_resumen` añade `nivel` (número), `nivel_nombre` («Nivel 1») y
-- `limite_usd` (el tope mensual de su nivel, de `levels`); quita `terminados`.
-- Un paciente en el nivel 0 («Sin nivel») o con el tope en 0 llega con
-- `limite_usd` = 0 y el bot no enseña ni nivel ni saldo total.
-- ============================================================================

create or replace function public.bot_paciente_resumen(p_profile_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy date := public.helios_business_date(now());
  v_lvl public.levels%rowtype;
begin
  select l.* into v_lvl
  from public.profiles p
  join public.levels l on l.level = p.level
  where p.id = p_profile_id;

  return jsonb_build_object(
    'nombre', (select coalesce(nullif(btrim(p.first_name), ''), split_part(btrim(coalesce(p.full_name, '')), ' ', 1))
               from public.profiles p where p.id = p_profile_id),
    -- Cada orden en su moneda: la consulta y las cuotas en ella; el cargo por
    -- atraso, en dólares. `cuotas`: las pendientes; `pagadas` (2026-10-19):
    -- las ya pagadas de la misma orden.
    'financiamientos', coalesce((
      select jsonb_agg(f order by f->>'primera')
      from (
        select jsonb_build_object(
                 'orden', c.order_number,
                 'clinica', m.name,
                 'medico', public.helios_doctor_name(c.merchant_id),
                 'medico_ref', public.helios_doctor_ref(c.merchant_id),
                 'moneda', c.currency,
                 'consulta', coalesce(c.base_cur, c.base_usd, c.amount_usd),
                 'primera', min(i.due_date),
                 'cuotas', jsonb_agg(jsonb_build_object(
                             'sequence', i.sequence,
                             'due_date', i.due_date,
                             'monto', coalesce(i.amount_cur, i.amount_usd),
                             'cargo_atraso', coalesce((select sum(lf.amount_usd) from public.late_fees lf
                                                       where lf.installment_id = i.id and lf.status = 'pending'), 0),
                             'vencida', i.due_date < v_hoy)
                           order by i.due_date, i.sequence),
                 'pagadas', coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'sequence', pi.sequence,
                            'due_date', pi.due_date,
                            'monto', coalesce(pi.amount_cur, pi.amount_usd))
                          order by pi.sequence)
                   from public.installments pi
                   where pi.charge_id = c.id and pi.status = 'paid'), '[]'::jsonb)) as f
        from public.installments i
        join public.charges c on c.id = i.charge_id and c.status = 'confirmed'
        join public.merchants m on m.id = c.merchant_id
        where i.user_id = p_profile_id and i.status = 'pending' and i.written_off_at is null
        group by c.id, c.order_number, m.name, c.merchant_id, c.currency, c.base_cur, c.base_usd, c.amount_usd
      ) x
    ), '[]'::jsonb),
    -- NUEVO (2026-10-23): su nivel y el saldo total que le da.
    'nivel', v_lvl.level,
    'nivel_nombre', v_lvl.label,
    'limite_usd', coalesce(v_lvl.monthly_limit_usd, 0),
    -- Lo que puede usar hoy (la misma cifra que ve el médico) y, si es cero,
    -- por qué ('cuota_vencida', 'estado', 'bloqueo').
    'disponible_usd', public.helios_available_now_usd(p_profile_id),
    'bloqueo', public.helios_available_blocked_reason(p_profile_id),
    'tasa_bcv', public.current_fx_rate('BCV'),
    'tasa_bcv_eur', public.current_fx_rate('BCV_EUR'),
    'cuentas_de_cobro', public.helios_payment_accounts_text(),
    'datos_de_pago', public.helios_payment_accounts_block(),
    'pago_en_revision', exists (select 1 from public.payment_reports r
                                where r.user_id = p_profile_id and r.status in ('reported', 'in_review'))
  );
end;
$$;

revoke all on function public.bot_paciente_resumen(uuid) from public, anon, authenticated;
grant execute on function public.bot_paciente_resumen(uuid) to service_role;
