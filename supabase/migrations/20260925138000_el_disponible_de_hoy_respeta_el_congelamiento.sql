-- El disponible de hoy respeta el congelamiento.
--
-- Por las reglas del negocio (docs/00 §2.2), con una cuota vencida el
-- disponible es cero, y con la cuenta sin activar (congelada, suspendida,
-- expulsada o sin verificar) tampoco se puede gastar. La ficha de una persona
-- congelada decía «Disponible €26,26 de €30» y el uso del cupo sumaba ese
-- disponible nominal a lo que se puede gastar.
--
-- No se reescribe la regla: se llaman las mismas funciones que frenan una
-- compra (can_take_debt, available_usd, helios_in_arrears, helios_spend_blocked).
-- Todo es aditivo; los campos de siempre no cambian.

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
    -- Lo que puede gastar HOY, con las mismas funciones que frenan una compra
    -- (preview_charge y confirm_charge): can_take_debt dice si puede tomar
    -- deuda y available_usd cuánto, con el cupo que ocupa cada consumo hasta
    -- pagarlo entero. Con una cuota vencida, o con la cuenta sin activar, es 0.
    'available_now_usd', case
      when public.can_take_debt(p_user_id) then public.available_usd(p_user_id)
      else 0
    end,
    -- El mismo cupo, sin mirar si hoy puede gastarlo.
    'available_nominal_usd', greatest(v_limit - public.helios_credit_used_usd(p_user_id), 0),
    'available_blocked_reason', case
      when public.helios_in_arrears(p_user_id) then 'cuota_vencida'
      when (v_result ->> 'status') <> 'active' then 'estado'
      when public.helios_spend_blocked(p_user_id) then 'bloqueo'
    end
  ));

  v_result := v_result || jsonb_build_object('debt', (
    select jsonb_build_object(
      'open_usd', coalesce(sum(amount_usd) filter (where status = 'pending'), 0),
      'overdue_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and due_date < v_today), 0),
      'paid_usd', coalesce(sum(amount_usd) filter (where status = 'paid'), 0),
      'days_overdue', coalesce(max(v_today - due_date)
        filter (where status = 'pending' and due_date < v_today), 0)
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
      'days_overdue', greatest(v_today - i.due_date, 0)
    ) order by i.due_date, i.sequence)
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    join public.merchants m on m.id = ch.merchant_id
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
      'created_at', pr.created_at
    ) order by pr.created_at desc)
    from public.payment_reports pr
    join public.payment_quotes q on q.id = pr.quote_id
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

CREATE OR REPLACE FUNCTION public.admin_credit_utilization()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today date := public.helios_business_date(now());
  v_out   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  with
  uso as (
    select i.user_id, sum(i.financed_usd) as usado
    from public.installments i
    where not i.is_test
      and exists (
        select 1 from public.installments j
        where j.charge_id = i.charge_id
          and j.user_id   = i.user_id
          and j.status    = 'pending')
    group by 1
  ),
  expuesto as (
    select i.user_id, sum(i.financed_usd) as principal
    from public.installments i
    where not i.is_test
      and i.status = 'pending'
      and i.written_off_at is null
    group by 1
  ),
  gente as (
    select
      p.id,
      p.level,
      p.status,
      l.monthly_limit_usd                         as limite,
      (l.is_active and l.level >= 1)              as en_nivel,
      coalesce(u.usado, 0)                        as usado,
      coalesce(e.principal, 0)                    as principal,
      case when l.monthly_limit_usd > 0
        then 100 * coalesce(u.usado, 0) / l.monthly_limit_usd end as pct,
      -- Lo que puede gastar hoy: el disponible, si can_take_debt lo deja (la
      -- misma puerta que una compra: cuenta activa, sin cuota vencida y sin
      -- bloqueo); si no, 0. `usado` es la misma cuenta que helios_credit_used_usd.
      case when public.can_take_debt(p.id)
        then greatest(l.monthly_limit_usd - coalesce(u.usado, 0), 0)
        else 0 end                                 as ahora
    from public.profiles p
    join public.levels l on l.level = p.level
    left join uso u      on u.user_id = p.id
    left join expuesto e on e.user_id = p.id
    where not p.is_test
  ),
  por_nivel as (
    select
      l.level,
      l.label,
      l.monthly_limit_usd                                         as limit_usd,
      count(g.id)::integer                                        as user_count,
      count(g.id) filter (where g.status = 'active')::integer     as active_count,
      count(g.id) filter (where g.usado > 0)::integer             as using_count,
      coalesce(sum(g.limite), 0)                                  as limit_total_usd,
      coalesce(sum(g.usado), 0)                                   as used_financed_usd,
      coalesce(sum(greatest(g.limite - g.usado, 0)), 0)           as available_financed_usd,
      coalesce(sum(g.ahora), 0)                                   as spendable_now_usd,
      coalesce(sum(g.principal), 0)                               as exposure_financed_usd,
      round(100 * sum(g.usado) / nullif(sum(g.limite), 0), 1)     as usage_pct,
      -- Los tramos de uso del cupo, persona a persona, en su orden.
      jsonb_build_array(
        jsonb_build_object('key', '0',     'count', count(g.id) filter (where g.pct = 0)),
        jsonb_build_object('key', '1-25',  'count', count(g.id) filter (where g.pct > 0  and g.pct <= 25)),
        jsonb_build_object('key', '26-50', 'count', count(g.id) filter (where g.pct > 25 and g.pct <= 50)),
        jsonb_build_object('key', '51-75', 'count', count(g.id) filter (where g.pct > 50 and g.pct <= 75)),
        jsonb_build_object('key', '76-99', 'count', count(g.id) filter (where g.pct > 75 and g.pct < 100)),
        jsonb_build_object('key', '100',   'count', count(g.id) filter (where g.pct >= 100))
      )                                                           as buckets
    from public.levels l
    left join gente g on g.level = l.level
    where l.is_active and l.level >= 1
    group by l.level, l.label, l.monthly_limit_usd
  )
  select jsonb_build_object(
    'business_date', v_today,
    'levels', coalesce((select jsonb_agg(to_jsonb(n) order by n.level) from por_nivel n), '[]'::jsonb),
    -- Quien está fuera de la escalera activa (nivel 0 o un nivel apagado) y
    -- aun así debe algo: suele ser gente expulsada, y su deuda es exposición.
    'outside_levels', (
      select jsonb_build_object(
        'user_count',            count(*),
        'used_financed_usd',     coalesce(sum(g.usado), 0),
        'exposure_financed_usd', coalesce(sum(g.principal), 0)
      )
      from gente g
      where not g.en_nivel and (g.usado > 0 or g.principal > 0)
    ),
    'total', (
      select jsonb_build_object(
        'user_count',             count(*) filter (where g.en_nivel),
        'using_count',            count(*) filter (where g.en_nivel and g.usado > 0),
        'limit_total_usd',        coalesce(sum(g.limite) filter (where g.en_nivel), 0),
        'used_financed_usd',      coalesce(sum(g.usado), 0),
        'available_financed_usd', coalesce(sum(greatest(g.limite - g.usado, 0)) filter (where g.en_nivel), 0),
        'spendable_now_usd',      coalesce(sum(g.ahora) filter (where g.en_nivel), 0),
        'exposure_financed_usd',  coalesce(sum(g.principal), 0),
        'usage_pct',              round(100 * sum(g.usado) filter (where g.en_nivel)
                                        / nullif(sum(g.limite) filter (where g.en_nivel), 0), 1)
      )
      from gente g
    )
  )
  into v_out;

  return v_out;
end;
$function$;

revoke all on function public.admin_credit_utilization() from public, anon;
grant execute on function public.admin_credit_utilization() to authenticated, service_role;
