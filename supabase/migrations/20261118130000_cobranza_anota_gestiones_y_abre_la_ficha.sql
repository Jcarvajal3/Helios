-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — Cobranza trabaja el caso: anota gestiones y abre la ficha
--
-- 20261118120100 le dio al rol `cobranza` la lectura de superadmin › Por
-- cobrar. Para llevar el proceso también tiene que poder:
--
-- 1. Anotar la gestión de cobro (llamada, mensaje, promesa de pago, próxima
--    acción): `admin_log_contact`. Queda en la bitácora con su nombre.
-- 2. Abrir la ficha de la persona desde la cola: `helios_admin_user_detail_base`
--    (de ahí cuelga `admin_user_detail`), sus bloqueos, los parámetros y la
--    configuración de niveles que la ficha lee.
--
-- Sigue sin poder tocar la cuenta: bloquear, cambiar el nivel o el estado,
-- condonar, aprobar pagos y el libro son de `is_platform_admin()`. Los
-- cuerpos salen tal cual de la base, con solo la guardia sustituida por
-- `helios_puede_cobrar()`.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.admin_business_parameters(p_incluir_sin_valor boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today date := public.helios_business_date(now());
  v_rows  jsonb;
begin
  if not public.helios_puede_cobrar() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.key), '[]'::jsonb)
  into v_rows
  from (
    select
      k.key,
      -- El vigente hoy. Null = sin definir.
      vig.value,
      vig.effective_from,
      vig.note,
      -- El programado, si lo hay. Es lo que deja ver "sube a $3 el lunes".
      (select p.value from public.business_parameters p
        where p.key = k.key and p.effective_from > v_today
        order by p.effective_from limit 1) as next_value,
      (select p.effective_from from public.business_parameters p
        where p.key = k.key and p.effective_from > v_today
        order by p.effective_from limit 1) as next_from,
      -- El histórico entero, para poder explicar un consumo viejo.
      (select coalesce(jsonb_agg(jsonb_build_object(
          'value', h.value, 'effective_from', h.effective_from,
          'note', h.note, 'created_at', h.created_at
        ) order by h.effective_from desc), '[]'::jsonb)
       from public.business_parameters h where h.key = k.key) as history,
      cat.label,
      cat.unit,
      cat.grupo,
      vig.value is not null as has_value
    from (
      select key from public.business_parameters
      union
      select key from public.business_parameter_catalog where p_incluir_sin_valor
    ) k
    left join public.business_parameter_catalog cat on cat.key = k.key
    left join lateral (
      select p.value, p.effective_from, p.note
      from public.business_parameters p
      where p.key = k.key and p.effective_from <= v_today
      order by p.effective_from desc
      limit 1
    ) vig on true
  ) q;

  return jsonb_build_object('business_date', v_today, 'rows', v_rows);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_level_config()
 RETURNS TABLE(level smallint, label text, monthly_limit_usd numeric, required_spend_usd numeric, required_months smallint, is_active boolean, user_count integer, exposure_usd numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.helios_puede_cobrar() then
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

CREATE OR REPLACE FUNCTION public.admin_log_contact(p_user uuid, p_channel text, p_note text DEFAULT NULL::text, p_template text DEFAULT NULL::text, p_promise_date date DEFAULT NULL::date, p_outcome text DEFAULT NULL::text, p_next_action_on date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor   uuid := auth.uid();
  v_id      uuid;
  v_name    text;
  v_today   date := public.helios_business_date(now());
  v_outcome text := nullif(trim(coalesce(p_outcome, '')), '');
begin
  if not public.helios_puede_cobrar() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select full_name into v_name from public.profiles where id = p_user;
  if not found then
    raise exception 'No existe esa persona' using errcode = '22023';
  end if;

  -- Una promesa para ayer no es una promesa, es una errata.
  if p_promise_date is not null and p_promise_date < v_today then
    raise exception 'La fecha prometida ya pasó' using errcode = '22023';
  end if;

  -- El check de la tabla también lo impide, pero con un mensaje que nadie del
  -- equipo entendería.
  if v_outcome is not null and v_outcome not in (
    'contesto', 'no_contesta', 'numero_equivocado', 'mensaje_enviado', 'promesa', 'otro'
  ) then
    raise exception 'Ese resultado de gestión no existe' using errcode = '22023';
  end if;

  if v_outcome = 'promesa' and p_promise_date is null then
    raise exception 'Una promesa de pago necesita la fecha prometida' using errcode = '22023';
  end if;

  if p_next_action_on is not null and p_next_action_on < v_today then
    raise exception 'La próxima acción no puede quedar en el pasado' using errcode = '22023';
  end if;

  insert into public.collection_contacts
    (user_id, channel, template, note, promise_date, actor, outcome, next_action_on)
  values (
    p_user,
    p_channel::public.collection_channel,
    nullif(trim(coalesce(p_template, '')), ''),
    nullif(trim(coalesce(p_note, '')), ''),
    p_promise_date,
    v_actor,
    v_outcome,
    p_next_action_on
  )
  returning id into v_id;

  perform audit.log(v_actor, 'collection.contact', p_user, jsonb_build_object(
    'full_name', v_name,
    'channel', p_channel,
    'template', p_template,
    'promise_date', p_promise_date,
    'outcome', v_outcome,
    'next_action_on', p_next_action_on,
    'note', p_note
  ));

  return v_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_user_blocks(p_user_id uuid)
 RETURNS TABLE(id uuid, reason text, message text, blocked_at timestamp with time zone, blocked_by_name text, lifted_at timestamp with time zone, lift_note text, lifted_by_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select
    b.id, b.reason, b.message, b.blocked_at, ba.full_name,
    b.lifted_at, b.lift_note, la.full_name
  from public.user_blocks b
  left join public.platform_admins ba on ba.user_id = b.blocked_by
  left join public.platform_admins la on la.user_id = b.lifted_by
  where public.helios_puede_cobrar()
    and b.user_id = p_user_id
  order by (b.lifted_at is not null), b.blocked_at desc;
$function$;

CREATE OR REPLACE FUNCTION public.helios_admin_user_detail_base(p_user_id uuid)
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
  if not public.helios_puede_cobrar() then
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
    -- PODA (Helios): el avatar lo elegía la persona en la app
    -- (`avatar_colors`, `avatar_emojis`). Las claves quedan en null.
    'avatar_emoji', null::text,
    'avatar_color', null::text
  ), l.monthly_limit_usd
  into v_result, v_limit
  from public.profiles p
  join public.levels l on l.level = p.level
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
        filter (where status = 'pending' and written_off_at is null and due_date < v_today
                  and sequence > 0), 0),  -- NUEVO (2026-11-12, la inicial)
      'paid_usd', coalesce(sum(amount_usd) filter (where status = 'paid'), 0),
      -- FINANCED: el consumo de sus cuotas pagadas, la cifra que mide el
      -- motor de niveles (level_standing). paid_usd lleva el fee dentro.
      'paid_financed_usd', coalesce(sum(financed_usd) filter (where status = 'paid'), 0),
      'days_overdue', coalesce(max(v_today - due_date)
        filter (where status = 'pending' and written_off_at is null and due_date < v_today
                  and sequence > 0), 0),  -- NUEVO (2026-11-12, la inicial)
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
      'days_overdue', case when i.sequence = 0 then 0 else greatest(v_today - i.due_date, 0) end,  -- NUEVO (2026-11-12, la inicial)
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
      -- NUEVO (2026-11-12, la inicial).
      'down_payment_pct', ch.down_payment_pct,
      'down_payment_due_at', ch.down_payment_due_at,
      'activated_at', ch.activated_at,
      'down_payment_expired_at', ch.down_payment_expired_at,
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

  -- PODA (Helios): la verificación de identidad (`kyc.verifications`), los
  -- Bits (`bits_entries`) y los aparatos de la app (`user_devices`) se fueron
  -- con la app. Las claves se quedan vacías para no cambiar la forma.
  v_result := v_result || jsonb_build_object(
    'kyc', null::jsonb,
    'bits', null::jsonb,
    'bits_entries', '[]'::jsonb,
    'devices', '[]'::jsonb
  );

  -- Helios (docs/01 §2.4): la ficha del paciente.
  v_result := v_result || jsonb_build_object('datos', public.helios_patient_datos(p_user_id));

  return v_result;
end;
$function$;

