-- El padrón dice lo que se puede gastar hoy, y los pagos, quién los revisó.
--
-- 1. El disponible de hoy (20260925138000) vivía escrito en línea en la ficha
--    y en el uso del cupo. Pasa a dos funciones internas,
--    helios_available_now_usd y helios_available_blocked_reason, que usan la
--    ficha, el uso del cupo y ahora el padrón (admin_user_directory), que gana
--    available_now_usd y available_blocked_reason al final. Su available_usd
--    sigue siendo el cupo nominal: lo lee el panel de main.
-- 2. El pago de la cola y de la ficha (helios_admin_payment_item, que usan
--    admin_payment_queue y admin_payment_report) gana reviewed_at, reviewed_by
--    y reviewed_by_name: el panel ya filtra los resueltos por el día de
--    reviewed_at y no podía enseñarlo.
--
-- Todo aditivo. Los cuerpos son los vivos de dev.

create or replace function public.helios_available_now_usd(p_user uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  -- La misma puerta que una compra (preview_charge, confirm_charge): si puede
  -- tomar deuda, lo que le queda de cupo; si no, nada.
  if public.can_take_debt(p_user) then
    return public.available_usd(p_user);
  end if;
  return 0;
end;
$$;

comment on function public.helios_available_now_usd(uuid) is
  'Lo que una persona puede gastar hoy (financed): available_usd si can_take_debt la deja, 0 si no. Interna del panel.';

revoke all on function public.helios_available_now_usd(uuid) from public, anon, authenticated;
grant execute on function public.helios_available_now_usd(uuid) to service_role;

create or replace function public.helios_available_blocked_reason(p_user uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  -- Por qué no puede gastar hoy, en el orden en que se le explica: la cuota
  -- vencida primero (es lo que puede arreglar), luego el estado de la cuenta y
  -- al final el bloqueo (manual, lista de espera o mantenimiento). Null si
  -- puede gastar.
  if public.helios_in_arrears(p_user) then
    return 'cuota_vencida';
  end if;
  if not exists (select 1 from public.profiles where id = p_user and status = 'active') then
    return 'estado';
  end if;
  if public.helios_spend_blocked(p_user) then
    return 'bloqueo';
  end if;
  return null;
end;
$$;

comment on function public.helios_available_blocked_reason(uuid) is
  'Por qué una persona no puede gastar hoy: cuota_vencida, estado o bloqueo; null si puede. Interna del panel.';

revoke all on function public.helios_available_blocked_reason(uuid) from public, anon, authenticated;
grant execute on function public.helios_available_blocked_reason(uuid) to service_role;

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
      -- Lo que puede gastar hoy, con la misma puerta que una compra.
      public.helios_available_now_usd(p.id)        as ahora
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

drop function if exists public.admin_user_directory(text, text, integer);
CREATE OR REPLACE FUNCTION public.admin_user_directory(p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_limit integer DEFAULT 50)
 RETURNS TABLE(user_id uuid, full_name text, phone_e164 text, document_number text, status text, level smallint, level_limit_usd numeric, is_blacklisted boolean, is_test boolean, created_at timestamp with time zone, open_debt_usd numeric, overdue_usd numeric, days_overdue integer, charge_count integer, last_charge_at timestamp with time zone, available_usd numeric, last_merchant_name text, on_time_paid integer, on_time_total integer, available_now_usd numeric, available_blocked_reason text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today  date := public.helios_business_date(now());
  v_grace  integer := public.helios_on_time_grace_days();
  v_needle text;
  v_aguja  text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_needle := nullif(trim(coalesce(p_search, '')), '');
  -- El nombre se compara sin tildes ni mayúsculas: «jose» encuentra a «JOSÉ».
  v_aguja  := public.helios_sin_tildes(v_needle);

  return query
  select
    p.id,
    p.full_name,
    p.phone_e164,
    p.document_number,
    p.status::text,
    p.level,
    l.monthly_limit_usd,
    p.is_blacklisted,
    p.is_test,
    p.created_at,
    coalesce(d.open_debt, 0)::numeric,
    coalesce(d.overdue, 0)::numeric,
    coalesce(d.days_late, 0)::integer,
    coalesce(c.cnt, 0)::integer,
    c.last_at,
    -- El disponible sale del bloque de crédito abierto, igual que en la
    -- ficha: el cupo vuelve entero al saldar la deuda completa, nunca cuota a
    -- cuota, y restar la deuda viva del límite daría otro número.
    greatest(l.monthly_limit_usd - coalesce(b.charged_usd - b.paid_usd, 0), 0)::numeric,
    c.last_merchant,
    coalesce(o.on_time, 0)::integer,
    coalesce(o.total, 0)::integer,
    -- Lo que puede gastar hoy y por qué no, como en la ficha. available_usd
    -- (arriba) es el cupo nominal y se queda por el panel de main. Van al
    -- final de la lista a propósito: son funciones caras y el planificador
    -- las evalúa después del orden y del tope, solo para las filas que salen.
    public.helios_available_now_usd(p.id),
    public.helios_available_blocked_reason(p.id)
  from public.profiles p
  join public.levels l on l.level = p.level
  left join (
    select
      i.user_id as uid,
      sum(i.amount_usd) as open_debt,
      sum(i.amount_usd) filter (where i.due_date < v_today) as overdue,
      max(v_today - i.due_date) filter (where i.due_date < v_today) as days_late
    from public.installments i
    where i.status = 'pending'
    group by 1
  ) d on d.uid = p.id
  left join (
    select
      ch.user_id as uid,
      count(*)::integer as cnt,
      max(ch.confirmed_at) as last_at,
      -- El local del último consumo. `distinct on` sería más limpio pero no
      -- se puede agregar con el resto en la misma pasada.
      (array_agg(m.name order by ch.confirmed_at desc))[1] as last_merchant
    from public.charges ch
    join public.merchants m on m.id = ch.merchant_id
    where ch.status = 'confirmed'
    group by 1
  ) c on c.uid = p.id
  -- El bloque de crédito abierto. Hay como mucho uno por persona.
  left join public.user_credit_blocks b
    on b.user_id = p.id and b.closed_at is null
  -- Cuántas de sus cuotas vencidas pagó dentro de plazo. Es el historial que
  -- decide si a alguien se le sube el nivel a mano o se le dice que no.
  left join (
    select
      i.user_id as uid,
      count(*) filter (
        where i.status = 'paid' and i.paid_at is not null
          and public.helios_business_date(i.paid_at) <= i.due_date + v_grace
      )::integer as on_time,
      count(*)::integer as total
    from public.installments i
    where i.due_date <= v_today and i.written_off_at is null
    group by 1
  ) o on o.uid = p.id
  where
    (p_status is null or p.status::text = p_status)
    and (
      v_needle is null
      or p.phone_e164 ilike '%' || v_needle || '%'
      or public.helios_sin_tildes(p.full_name) like '%' || v_aguja || '%'
      or p.document_number ilike '%' || v_needle || '%'
    )
  -- Con texto, primero lo que más se parece: la coincidencia exacta, luego el
  -- nombre que empieza así, luego una palabra del nombre que empieza así, y al
  -- final el resto. Dentro de cada grupo (y sin texto, siempre) primero quien
  -- más atrasado está: esta lista se abre para cobrar, no para navegar el
  -- padrón.
  order by
    case
      when v_needle is null then 0
      when public.helios_sin_tildes(p.full_name) = v_aguja
        or p.phone_e164 = v_needle or p.document_number = v_needle then 0
      when public.helios_sin_tildes(p.full_name) like v_aguja || '%'
        or p.document_number ilike v_needle || '%' then 1
      when ' ' || public.helios_sin_tildes(p.full_name) like '% ' || v_aguja || '%' then 2
      else 3
    end,
    coalesce(d.days_late, 0) desc, coalesce(d.open_debt, 0) desc, p.created_at desc
  limit least(coalesce(p_limit, 50), 200);
end;
$function$;

comment on function public.admin_user_directory(text, text, integer) is
  'El padron. NO filtra las cuentas de prueba: tienen que poder buscarse y abrirse, y por eso devuelve is_test para que la pantalla las etiquete. available_usd es el cupo nominal; available_now_usd, lo que puede gastar hoy.';
revoke all on function public.admin_user_directory(text, text, integer) from public, anon;
grant execute on function public.admin_user_directory(text, text, integer) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.helios_admin_payment_item(p_report_id uuid, p_today date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'report_id',      r.id,
    'status',         r.status::text,
    'created_at',     r.created_at,
    'method',         r.method,
    'bank',           r.bank,
    'reference',      r.reference,
    'payer_document', r.payer_document,
    'payer_phone',    r.payer_phone,
    'rejection_note', r.rejection_note,
    -- Cuándo se decidió (null mientras no se decide) y quién lo tomó: en
    -- in_review es quien lo marcó para revisar; resuelto, quien lo decidió.
    'reviewed_at',      r.reviewed_at,
    'reviewed_by',      r.reviewed_by,
    'reviewed_by_name', case when r.reviewed_by is not null
                             then coalesce(pa.full_name, 'Alguien del equipo') end,

    -- `installments_usd` es lo que suman las cuotas; el resto del monto son
    -- cargos por atraso, y el operador tiene que poder cuadrar las dos cifras
    -- sin restar de cabeza.
    'amount_usd',        q.amount_usd,
    'amount_ves',        q.amount_ves,
    'fx_rate',           q.fx_rate,
    'installment_count', q.installment_count,
    'installments_usd',  q.amount_usd - q.late_fee_usd,
    'late_fee_usd',      q.late_fee_usd,

    'user', jsonb_build_object(
      'user_id',         p.id,
      'full_name',       p.full_name,
      'phone_e164',      p.phone_e164,
      'document_number', p.document_number,
      'status',          p.status::text,
      'level',           p.level
    ),

    -- Cuántos OTROS reportes no rechazados comparten banco + referencia. Con
    -- referencias de 6 dígitos esto es sospecha, no prueba (docs/00 §3.7).
    'reference_collisions', (
      select count(*) - 1 from public.payment_reports r2
      where r2.bank = r.bank and r2.reference = r.reference
        and r2.reference is not null and r2.status <> 'rejected'
    ),
    -- Movimientos del extracto importado que encajan: referencia, monto y
    -- fecha, las tres a la vez.
    'statement_matches', (
      select count(*) from public.bank_statement_lines l
      where r.reference is not null
        and l.reference like '%' || r.reference
        and abs(l.amount_ves - q.amount_ves) <= 1.00
        and l.moved_on between (r.created_at::date - 5) and (r.created_at::date + 5)
    ),

    -- Las compras que toca este pago, cada una con las cuotas que salda.
    'purchases', coalesce((
      select jsonb_agg(purchase order by business_date nulls last, order_number nulls last)
      from (
        select
          ch.business_date,
          ch.order_number,
          jsonb_build_object(
            'charge_id',         ch.id,
            'order_number',      ch.order_number,
            'merchant_id',       m.id,
            'merchant_name',     m.name,
            'branch_name',       b.name,
            'charge_amount_usd', ch.amount_usd,
            'charge_status',     ch.status::text,
            'business_date',     ch.business_date,
            'confirmed_at',      ch.confirmed_at,
            'is_group',          ch.group_id is not null,
            'group_name',        ch.group_name,
            -- El denominador del "cuota 2 de 2", sobre las cuotas de ESTA
            -- persona: en un consumo de grupo el cargo tiene cuotas de varios.
            'installments_total', (
              select count(*) from public.installments t
              where t.charge_id = ch.id and t.user_id = r.user_id
            ),
            'installments', jsonb_agg(jsonb_build_object(
              'installment_id', ins.id,
              'sequence',       ins.sequence,
              -- El congelado al cotizar: la cifra contra la que concilia el
              -- servidor. Si difiere del de la cuota, el pago no se aprueba.
              'quoted_usd',     qi.amount_usd,
              'amount_usd',     ins.amount_usd,
              'due_date',       ins.due_date,
              'status',         ins.status::text,
              'days_overdue',   greatest(p_today - ins.due_date, 0),
              -- Intentos anteriores sobre esta misma cuota.
              'other_reports', (
                select count(*)
                from public.payment_quote_items qi2
                join public.payment_reports r2 on r2.quote_id = qi2.quote_id
                where qi2.installment_id = ins.id and r2.id <> r.id
              )
            ) order by ins.sequence)
          ) as purchase
        from public.payment_quote_items qi
        join public.installments ins on ins.id = qi.installment_id
        join public.charges ch on ch.id = ins.charge_id
        join public.merchants m on m.id = ch.merchant_id
        join public.merchant_branches b on b.id = ch.branch_id
        where qi.quote_id = q.id
        group by ch.id, m.id, b.id
      ) g
    ), '[]'::jsonb),

    -- Los cargos por atraso, con la cuota que los disparó. Sin esto el monto
    -- no cuadra con ninguna suma de cuotas.
    'late_fees', coalesce((
      select jsonb_agg(jsonb_build_object(
        'late_fee_id',    f.id,
        'amount_usd',     fl.amount_usd,
        'days_late',      f.days_late,
        'business_date',  f.business_date,
        'installment_id', f.installment_id,
        'sequence',       ins.sequence,
        'order_number',   ch.order_number,
        'merchant_name',  m.name,
        -- HUÉRFANO: el de una cuota que ya se pagó, o uno sin cuota. Viaja con
        -- este pago aunque su cuota no esté aquí.
        'orphan', f.installment_id is null or not exists (
          select 1 from public.payment_quote_items qi3
          where qi3.quote_id = q.id and qi3.installment_id = f.installment_id
        )
      ) order by f.business_date, f.created_at)
      from public.payment_quote_late_fees fl
      join public.late_fees f on f.id = fl.late_fee_id
      left join public.installments ins on ins.id = f.installment_id
      left join public.charges ch on ch.id = ins.charge_id
      left join public.merchants m on m.id = ch.merchant_id
      where fl.quote_id = q.id
    ), '[]'::jsonb)
  )
  from public.payment_reports r
  join public.payment_quotes q on q.id = r.quote_id
  join public.profiles p on p.id = r.user_id
  left join public.platform_admins pa on pa.user_id = r.reviewed_by
  where r.id = p_report_id
$function$;

revoke all on function public.helios_admin_payment_item(uuid, date) from public, anon, authenticated;
