-- ============================================================================
-- Ronda — La ficha del usuario separa lo perdido, juzga «a tiempo» como las
-- métricas y parte los pagos en sus sumandos
--
-- Repaso de rigor de la operación (AUD-OPERACION, fichas C2, C3, C5 y C8),
-- aprobado por Javier el 2026-09-28. Solo cambia admin_user_detail(uuid).
--
-- PARTE DE LA VERSIÓN VIVA EN DEV, que es la de
-- 20260925139500_el_padron_y_los_pagos_dicen_lo_de_hoy_y_quien_reviso.sql
-- (ninguna migración posterior la había tocado). Todo lo que traía se queda;
-- solo se AÑADEN claves y se filtran tres sumas:
--
--   * C5 · debt.open_usd, debt.overdue_usd y debt.days_overdue ya no cuentan
--     las cuotas dadas por perdidas (written_off_at): «Deuda hoy» decía €36,77
--     y «67 días» a quien metricas.cuotas le da vencido 0 y perdido €36,77.
--     Nuevas: debt.written_off_usd, debt.written_off_financed_usd e
--     installments[].written_off_at, para pintar la cuota como «Perdida».
--   * C2 · debt.paid_financed_usd: el consumo pagado (sin fee), la cifra del
--     motor de niveles (level_standing). debt.paid_usd sigue igual.
--   * C3 · installments[].paid_day (día operativo del REPORTE, el de
--     metricas.cuotas.pagada_dia) e installments[].on_time
--     (metricas.a_tiempo, con los días de gracia): la línea de tiempo decía
--     «Con atraso» con el día de la aprobación y sin gracia (165 contra 72).
--   * C8 · payments[].cuotas_payable_usd, cuotas_financed_usd, cuotas_fee_usd
--     y late_fees_usd: el monto reportado es cuotas (consumo + fee) + cargos
--     por atraso, y se enseñaba sin sumandos.
--
-- credit.to_unlock_usd se queda en el JSON (retrocompatible), pero el panel ya
-- no lo pinta: restaba consumo sin fee menos cuotas con fee (C1).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_user_detail(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today  date := public.helios_business_date(now());
  v_result jsonb;
  v_block  public.user_credit_blocks%rowtype;
  v_limit  numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'user_id', p.id,
    'full_name', p.full_name,
    'phone_e164', p.phone_e164,
    'document_number', p.document_number,
    'birth_date', p.birth_date,
    'status', p.status,
    'level', p.level,
    'is_blacklisted', p.is_blacklisted,
    'blacklist_reason', p.blacklist_reason,
    'is_test', p.is_test,
    'created_at', p.created_at,
    -- El avatar que eligió, si eligió alguno. El hex sale del catálogo y no
    -- de una copia en el panel: la app tiene la suya
    -- (`features/profile/avatar.ts`) y dos paletas que se retocan por
    -- separado acaban enseñando colores distintos para la misma persona.
    'avatar_emoji', p.avatar_emoji,
    'avatar_color', c.hex
  ), l.monthly_limit_usd
  into v_result, v_limit
  from public.profiles p
  join public.levels l on l.level = p.level
  -- `left`: las dos columnas nacen nulas y la mayoría de la gente sigue sin
  -- avatar. Con un join normal, la ficha de quien no lo eligió no existiría.
  left join public.avatar_colors c on c.key = p.avatar_color
  where p.id = p_user_id;

  if v_result is null then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  -- El bloque de crédito abierto explica el disponible. Es la pregunta #1 de
  -- soporte: "pagué una cuota, ¿por qué sigo en cero?" (docs/00-BASES §2.2).
  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user_id and closed_at is null;

  v_result := v_result || jsonb_build_object('credit', jsonb_build_object(
    'level_limit_usd', v_limit,
    'block_charged_usd', coalesce(v_block.charged_usd, 0),
    'block_paid_usd', coalesce(v_block.paid_usd, 0),
    'available_usd', greatest(v_limit - (coalesce(v_block.charged_usd, 0)
                                       - coalesce(v_block.paid_usd, 0)), 0),
    'to_unlock_usd', coalesce(v_block.charged_usd, 0) - coalesce(v_block.paid_usd, 0),
    'block_opened_at', v_block.opened_at,
    -- Lo que puede gastar HOY, con la misma puerta que una compra. Con una
    -- cuota vencida, la cuenta sin activar o un bloqueo, es 0.
    'available_now_usd', public.helios_available_now_usd(p_user_id),
    -- El mismo cupo, sin mirar si hoy puede gastarlo.
    'available_nominal_usd', greatest(v_limit - public.helios_credit_used_usd(p_user_id), 0),
    'available_blocked_reason', public.helios_available_blocked_reason(p_user_id)
  ));

  -- Lo dado por perdido (written_off_at) no es deuda viva: no entra en lo
  -- que debe, ni en lo vencido, ni en los días de atraso, igual que en
  -- metricas.cuotas (estado 'perdida'). Va aparte, en written_off_usd.
  -- (20260927696000; antes sumaba toda cuota 'pending'.)
  v_result := v_result || jsonb_build_object('debt', (
    select jsonb_build_object(
      'open_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and written_off_at is null), 0),
      'overdue_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and written_off_at is null and due_date < v_today), 0),
      'paid_usd', coalesce(sum(amount_usd) filter (where status = 'paid'), 0),
      -- FINANCED: el consumo de sus cuotas pagadas, la cifra que mide el
      -- motor de niveles (level_standing). paid_usd lleva el fee dentro.
      'paid_financed_usd', coalesce(sum(financed_usd) filter (where status = 'paid'), 0),
      'days_overdue', coalesce(max(v_today - due_date)
        filter (where status = 'pending' and written_off_at is null and due_date < v_today), 0),
      -- PAYABLE: las cuotas sin pagar dadas por perdidas, con su consumo.
      'written_off_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and written_off_at is not null), 0),
      'written_off_financed_usd', coalesce(sum(financed_usd)
        filter (where status = 'pending' and written_off_at is not null), 0)
    )
    from public.installments where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'charge_id', i.charge_id,
      -- El número de la orden de la que sale esta cuota: es lo que el equipo
      -- teclea en el buscador y lo que el local dicta por teléfono.
      'order_number', ch.order_number,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      -- Lo que esta cuota lleva de consumo, sin el servicio.
      'financed_usd', i.financed_usd,
      'due_date', i.due_date,
      'status', i.status,
      'paid_at', i.paid_at,
      'merchant_name', m.name,
      'days_overdue', greatest(v_today - i.due_date, 0),
      -- Dada por perdida: sigue 'pending' pero ya no es deuda viva.
      'written_off_at', i.written_off_at,
      -- El día operativo en que REPORTÓ el pago que la saldó (sin reporte, el
      -- de la aprobación): el mismo que metricas.cuotas.pagada_dia.
      'paid_day', case when i.status = 'paid' then
        coalesce(metricas.dia_operativo(pr.created_at), metricas.dia_operativo(i.paid_at)) end,
      -- Cobrada a tiempo con la regla canónica (metricas.a_tiempo: el día del
      -- reporte, como mucho el vencimiento más los días de gracia).
      'on_time', case when i.status = 'paid' then
        metricas.a_tiempo(coalesce(metricas.dia_operativo(pr.created_at),
                                   metricas.dia_operativo(i.paid_at)), i.due_date) end
    ) order by i.due_date, i.sequence)
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    join public.merchants m on m.id = ch.merchant_id
    left join public.payment_reports pr on pr.id = i.paid_by_report_id
    where i.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('charges', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ch.id,
      'order_number', ch.order_number,
      'amount_usd', ch.amount_usd,
      'status', ch.status,
      'business_date', ch.business_date,
      'confirmed_at', ch.confirmed_at,
      'merchant_name', m.name,
      'branch_name', b.name,
      'void_reason', ch.void_reason,
      -- El consumo entero, sin el servicio de Ronda (amount_usd lo lleva).
      'financed_usd', coalesce(ch.base_usd, ch.amount_usd),
      'merchant_id', ch.merchant_id
    ) order by ch.created_at desc)
    from public.charges ch
    join public.merchants m on m.id = ch.merchant_id
    join public.merchant_branches b on b.id = ch.branch_id
    where ch.user_id = p_user_id
  ), '[]'::jsonb));

  -- Los consumos en los que ESTÁ: los que puso (charges.user_id) y aquellos en
  -- los que tiene cuotas. En un grupo el cargo es de quien abrió la cuenta y
  -- las cuotas son de cada quien, así que `charges` (arriba) se queda corto.
  -- Todo en financed: la cuenta entera y su parte (la suma de sus cuotas).
  v_result := v_result || jsonb_build_object('consumos', coalesce((
    with mias as (
      select i.charge_id, sum(i.financed_usd) as parte
      from public.installments i
      where i.user_id = p_user_id
      group by i.charge_id
    ),
    ids as (
      select ch.id from public.charges ch where ch.user_id = p_user_id
      union
      select mias.charge_id from mias
    )
    select jsonb_agg(jsonb_build_object(
      'charge_id', ch.id,
      'order_number', ch.order_number,
      'status', ch.status,
      'business_date', ch.business_date,
      'created_at', ch.created_at,
      'confirmed_at', ch.confirmed_at,
      'void_reason', ch.void_reason,
      'merchant_id', ch.merchant_id,
      'merchant_name', m.name,
      'group_id', ch.group_id,
      'is_group', ch.group_id is not null,
      'started_it', coalesce(ch.user_id = p_user_id, false),
      'financed_usd', coalesce(ch.base_usd, ch.amount_usd),
      'share_financed_usd', mi.parte
    ) order by ch.created_at desc)
    from ids
    join public.charges ch on ch.id = ids.id
    join public.merchants m on m.id = ch.merchant_id
    left join mias mi on mi.charge_id = ch.id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('payments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'status', pr.status,
      'bank', pr.bank,
      'reference', pr.reference,
      'method', pr.method,
      'amount_usd', q.amount_usd,
      'amount_ves', q.amount_ves,
      'rejection_note', pr.rejection_note,
      'created_at', pr.created_at,
      -- amount_usd = cuotas (consumo + service fee) + cargos por atraso. Sus
      -- sumandos, para no enseñar un total con el fee sin desglose.
      'cuotas_payable_usd', coalesce(it.payable, 0),
      'cuotas_financed_usd', coalesce(it.financed, 0),
      'cuotas_fee_usd', coalesce(it.payable, 0) - coalesce(it.financed, 0),
      'late_fees_usd', coalesce(lf.cargos, 0)
    ) order by pr.created_at desc)
    from public.payment_reports pr
    join public.payment_quotes q on q.id = pr.quote_id
    left join lateral (
      select sum(qi.amount_usd) as payable, sum(i.financed_usd) as financed
      from public.payment_quote_items qi
      join public.installments i on i.id = qi.installment_id
      where qi.quote_id = q.id
    ) it on true
    left join lateral (
      select sum(qf.amount_usd) as cargos
      from public.payment_quote_late_fees qf
      where qf.quote_id = q.id
    ) lf on true
    where pr.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('level_changes', coalesce((
    select jsonb_agg(jsonb_build_object(
      'from_level', lc.from_level,
      'to_level', lc.to_level,
      'reason', lc.reason,
      'note', lc.note,
      'actor', lc.actor,
      'created_at', lc.created_at
    ) order by lc.created_at desc)
    from public.level_changes lc
    where lc.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('kyc', (
    select jsonb_build_object(
      'status', v.status,
      'rejection_reason', v.rejection_reason,
      'rejection_detail', v.rejection_detail,
      'reviewed_at', v.reviewed_at,
      'created_at', v.created_at
    )
    from kyc.verifications v
    where v.user_id = p_user_id
    order by v.created_at desc limit 1
  ));

  -- Bits. El saldo va con SUS MOVIMIENTOS y no solo con la cifra: la pregunta
  -- que llega a soporte no es cuántos tiene, es de dónde salieron.
  v_result := v_result || jsonb_build_object('bits', (
    select jsonb_build_object(
      'balance', coalesce(sum(amount), 0),
      'awarded_count', count(*) filter (where amount > 0),
      'last_award_at', max(created_at) filter (where amount > 0)
    )
    from public.bits_entries where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('bits_entries', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', e.id,
      'amount', e.amount,
      'reason', e.reason,
      'created_at', e.created_at,
      -- De qué cuota salió. `business_date` es el día de la COMPRA, que con la
      -- escalera es la mitad de la explicación: los Bits son la distancia
      -- entre esa fecha y el día en que se pagó.
      'business_date', ch.business_date,
      'due_date', i.due_date,
      'paid_at', i.paid_at,
      'merchant_name', m.name
    ) order by e.created_at desc)
    from public.bits_entries e
    left join public.installments i on i.id = e.installment_id
    left join public.charges ch on ch.id = i.charge_id
    left join public.merchants m on m.id = ch.merchant_id
    where e.user_id = p_user_id
  ), '[]'::jsonb));

  -- ── Qué teléfono lleva ──────────────────────────────────────────────────
  -- Los aparatos de esa persona, el último visto primero. Es lo que contesta
  -- «¿en iOS o en Android?» y «¿tiene la build nueva?» sin tener que
  -- preguntárselo por WhatsApp — que es como se preguntaba hasta ahora.
  --
  -- `app_build` puede venir null y eso NO es un aparato raro: es un aparato
  -- que no ha vuelto a registrarse desde que la app aprendió a mandarlo. La
  -- pantalla lo dice con un guion.
  v_result := v_result || jsonb_build_object('devices', coalesce((
    select jsonb_agg(jsonb_build_object(
      'device_name',   d.device_name,
      'platform',      d.platform,
      'app_build',     d.app_build,
      'app_version',   d.app_version,
      'os_version',    d.os_version,
      'is_trusted',    d.is_trusted,
      'first_seen_at', d.first_seen_at,
      'last_seen_at',  d.last_seen_at
    ) order by d.last_seen_at desc)
    from public.user_devices d
    where d.user_id = p_user_id
  ), '[]'::jsonb));

  return v_result;
end;
$function$;

revoke all on function public.admin_user_detail(uuid) from public, anon;
grant execute on function public.admin_user_detail(uuid) to authenticated, service_role;
