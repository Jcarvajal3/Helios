-- Lo que el panel leía a mano de las tablas, o no tenía.
--
-- La ola 1 del super admin completaba estas lecturas con consultas directas a
-- charges, installments y payment_reports. Todo lo de aquí es aditivo: campos
-- nuevos al final y parámetros nuevos con default, sin quitar nada.
--
-- · admin_charges: + financed_usd (el consumo sin el servicio).
-- · admin_user_detail: financed_usd y merchant_id en charges[], financed_usd
--   en installments[] y una lista nueva, consumos[], con los consumos en los
--   que la persona ESTÁ (los que puso y aquellos en los que tiene cuotas), con
--   la cuenta entera y su parte, las dos sin el servicio.
-- · admin_user_late_fees: + installment_id.
-- · admin_group_metrics.top: + created_by y created_by_name.
-- · admin_kyc_queue: + didit_session_id y didit_session_url.
-- · admin_payment_queue: + p_from y p_to para acotar los resueltos.
--
-- Las que devuelven filas cambian de tipo de salida y hay que borrarlas y
-- volver a crearlas, con sus permisos y su comentario.

drop function if exists public.admin_charges(text, uuid, text, date, date, integer);
CREATE OR REPLACE FUNCTION public.admin_charges(p_search text DEFAULT NULL::text, p_merchant_id uuid DEFAULT NULL::uuid, p_status text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_limit integer DEFAULT 100)
 RETURNS TABLE(charge_id uuid, order_number bigint, amount_usd numeric, status text, business_date date, created_at timestamp with time zone, confirmed_at timestamp with time zone, void_reason text, user_id uuid, full_name text, phone_e164 text, user_status text, merchant_id uuid, merchant_name text, branch_name text, is_group boolean, is_test boolean, installments_paid integer, installments_total integer, financed_usd numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_needle text;
  v_order  bigint;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_needle := nullif(trim(coalesce(p_search, '')), '');

  -- Se compara por igualdad y no por LIKE: el número es único global, así que
  -- quien escribe 1043 quiere ESA orden y no las cuarenta que empiezan por
  -- 1043.
  --
  -- El tope de 18 dígitos no es decorativo: un bigint llega hasta 19 cifras y
  -- el cast de una cadena más larga no devuelve null, revienta. Quien pegue
  -- una referencia bancaria de veinte dígitos en el buscador tiene que ver
  -- «no hay resultados», no una pantalla de error.
  if v_needle ~ '^#?\d{1,18}$' then
    v_order := replace(v_needle, '#', '')::bigint;
  else
    v_order := null;
  end if;

  return query
  select
    ch.id,
    ch.order_number,
    ch.amount_usd,
    ch.status::text,
    ch.business_date,
    ch.created_at,
    ch.confirmed_at,
    ch.void_reason,
    ch.user_id,
    p.full_name,
    p.phone_e164,
    p.status::text,
    m.id,
    m.name,
    b.name,
    -- Un consumo de grupo genera N cargos hermanos con el mismo grupo detrás.
    -- Marcarlo evita que alguien lea ocho filas de $12,50 como ocho consumos
    -- sueltos de una noche rara.
    ch.group_id is not null,
    ch.is_test,
    coalesce(i.paid, 0)::integer,
    coalesce(i.total, 0)::integer,
    -- El consumo, sin el servicio de Ronda. amount_usd lo lleva dentro.
    coalesce(ch.base_usd, ch.amount_usd)::numeric
  from public.charges ch
  left join public.profiles p on p.id = ch.user_id
  join public.merchants m on m.id = ch.merchant_id
  join public.merchant_branches b on b.id = ch.branch_id
  left join (
    -- `ins.` explícito: el OUT parameter de esta función también se llama
    -- `charge_id` y sin calificar la columna Postgres no sabe a cuál se
    -- refiere.
    select ins.charge_id as cid,
           count(*) filter (where ins.status = 'paid')::integer as paid,
           count(*)::integer as total
    from public.installments ins group by 1
  ) i on i.cid = ch.id
  where
    (p_merchant_id is null or ch.merchant_id = p_merchant_id)
    and (p_status is null or ch.status::text = p_status)
    and (p_from is null or ch.business_date >= p_from)
    and (p_to is null or ch.business_date <= p_to)
    and (
      v_needle is null
      -- El número de orden SUMA, no sustituye. Un teléfono venezolano son once
      -- dígitos, así que también casa el patrón de arriba: si lo del número
      -- excluyera al resto, buscar por teléfono en esta pantalla dejaría de
      -- funcionar. Y al revés no hay coste — si el texto no casa con nada, ese
      -- lado del OR simplemente no aporta filas.
      or (v_order is not null and ch.order_number = v_order)
      or p.phone_e164 ilike '%' || v_needle || '%'
      or p.full_name ilike '%' || v_needle || '%'
      or p.document_number ilike '%' || v_needle || '%'
      or m.name ilike '%' || v_needle || '%'
    )
  order by ch.created_at desc
  limit least(coalesce(p_limit, 100), 500);
end;
$function$;

comment on function public.admin_charges(text, uuid, text, date, date, integer) is
  'La lista de consumos del super admin. Busca por número de orden (con o sin #), teléfono, nombre, cédula y local. financed_usd es el consumo sin el servicio; amount_usd lo lleva dentro.';
revoke all on function public.admin_charges(text, uuid, text, date, date, integer) from public, anon;
grant execute on function public.admin_charges(text, uuid, text, date, date, integer) to authenticated, service_role;

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
    'block_opened_at', v_block.opened_at
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

drop function if exists public.admin_user_late_fees(uuid);
CREATE OR REPLACE FUNCTION public.admin_user_late_fees(p_user uuid)
 RETURNS TABLE(id uuid, amount_usd numeric, days_late integer, business_date date, status text, waived_at timestamp with time zone, waive_reason text, sequence smallint, due_date date, merchant_name text, installment_id uuid)
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
    f.id,
    f.amount_usd,
    f.days_late,
    f.business_date,
    f.status::text,
    f.waived_at,
    f.waive_reason,
    i.sequence,
    i.due_date,
    m.name,
    f.installment_id
  from public.late_fees f
  left join public.installments i on i.id = f.installment_id
  left join public.charges ch on ch.id = i.charge_id
  left join public.merchants m on m.id = ch.merchant_id
  where f.user_id = p_user
  order by f.created_at desc;
end;
$function$;

revoke all on function public.admin_user_late_fees(uuid) from public, anon;
grant execute on function public.admin_user_late_fees(uuid) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_group_metrics(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today  date := public.helios_business_date(now());
  v_from   date;
  v_to     date;
  v_days   integer;
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select w.desde, w.hasta, w.dias into v_from, v_to, v_days
  from public.helios_growth_window(p_from, p_to) w;

  with
  -- Un grupo es de prueba si lo es quien lo creó: no hay bandera propia y no
  -- hace falta, porque un grupo sin cargos no entra en ninguna cifra de aquí.
  grupos as (
    select g.id, g.name, g.created_at, g.business_date,
           public.helios_business_date(g.created_at) as dia,
           g.created_by, p.full_name as created_by_name
    from public.groups g
    join public.profiles p on p.id = g.created_by and not p.is_test
  ),
  miembros as (
    select gm.group_id, count(*)::int as n
    from public.group_members gm
    join grupos g on g.id = gm.group_id
    where gm.status <> 'left'
    group by 1
  ),
  -- Los cargos de la ventana, marcados con si fueron de grupo. `payers` sale
  -- de las cuotas: es entre cuánta gente se repartió esa cuenta de verdad, no
  -- cuánta gente hay apuntada en el grupo.
  cargos as (
    select c.id, c.group_id, c.business_date as dia,
           coalesce(c.base_usd, c.amount_usd) as fin,
           (select count(distinct i.user_id)
            from public.installments i where i.charge_id = c.id)::int as payers
    from public.charges c
    where c.status = 'confirmed' and not c.is_test
      and c.business_date between v_from and v_to
  )
  select jsonb_build_object(
    'business_date', v_today,
    -- El rango QUE SE USÓ, no el que se pidió: la pantalla lo pinta, y si el
    -- servidor recortó el «hasta» a hoy hay que verlo ahí y no descubrirlo
    -- comparando barras.
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,

    'groups', jsonb_build_object(
      'total',     (select count(*) from grupos),
      'created',   (select count(*) from grupos where dia between v_from and v_to),
      -- Los abiertos —esperando su primer pago o de esta noche—, sea cual
      -- sea la ventana: es una foto de ahora.
      'open',      (select count(*) from grupos where public.helios_group_is_open(business_date, created_at)),
      -- Grupos que pusieron al menos una cuenta en la ventana. Un grupo creado
      -- y nunca usado es el fracaso silencioso de esta función.
      'with_spend', (select count(distinct group_id) from cargos where group_id is not null),
      'avg_members', (select coalesce(round(avg(n), 1), 0) from miembros)
    ),

    -- Grupo contra individual, en las dos monedas que importan: cuántas
    -- cuentas y cuánto dinero.
    'split', jsonb_build_object(
      'group_charges',  (select count(*) from cargos where group_id is not null),
      'solo_charges',   (select count(*) from cargos where group_id is null),
      'group_financed', (select coalesce(sum(fin), 0) from cargos where group_id is not null),
      'solo_financed',  (select coalesce(sum(fin), 0) from cargos where group_id is null),
      'group_avg_usd',  (select coalesce(round(avg(fin), 2), 0) from cargos where group_id is not null),
      'solo_avg_usd',   (select coalesce(round(avg(fin), 2), 0) from cargos where group_id is null),
      'avg_payers',     (select coalesce(round(avg(payers), 2), 0) from cargos where group_id is not null)
    ),

    'series', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.day)
      from (
        select (v_from + k)              as day,
               coalesce(gc.n, 0)::int    as groups_created,
               coalesce(ca.n, 0)::int    as group_charges,
               coalesce(ca.f, 0)         as group_financed_usd
        from generate_series(0, v_days - 1) as g(k)
        left join (
          select dia, count(*) as n from grupos
          where dia between v_from and v_to group by 1
        ) gc on gc.dia = v_from + k
        left join (
          select dia, count(*) as n, sum(fin) as f from cargos
          where group_id is not null group by 1
        ) ca on ca.dia = v_from + k
      ) s
    ), '[]'::jsonb),

    'top', coalesce((
      select jsonb_agg(jsonb_build_object(
        'group_id',     t.id,
        'name',         t.name,
        'created_by',      t.created_by,
        'created_by_name', t.created_by_name,
        'members',      coalesce(m.n, 0),
        'charges',      t.cuentas,
        'financed_usd', t.financiado
      ) order by t.financiado desc, t.cuentas desc, t.name, t.id)
      from (
        select g.id, g.name, g.created_by, g.created_by_name,
               count(ca.id)::int         as cuentas,
               coalesce(sum(ca.fin), 0)  as financiado
        from grupos g
        join cargos ca on ca.group_id = g.id
        group by g.id, g.name, g.created_by, g.created_by_name
        -- Con desempate: en un empate el top 10 no puede cambiar de una llamada a otra.
        order by financiado desc, cuentas desc, g.name, g.id
        limit 10
      ) t
      left join miembros m on m.group_id = t.id
    ), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$function$;

revoke all on function public.admin_group_metrics(date, date) from public, anon;
grant execute on function public.admin_group_metrics(date, date) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_kyc_queue()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'kyc', 'storage', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at), '[]'::jsonb)
    into v_rows
  from (
    select
      v.id,
      v.user_id,
      p.phone_e164,
      v.extracted_name,
      v.extracted_document,
      v.extracted_birth,

      -- NUEVO: lo que el revisor no podía ver. Va de la mano con el motivo,
      -- porque la marca sola no dice si fue por mora de una cuota o por algo
      -- peor.
      p.is_blacklisted,
      p.blacklist_reason,

      -- Los puntajes se redondean a un semáforo. El revisor necesita saber si
      -- la señal es buena o dudosa, no el número exacto.
      --
      -- Los cortes son los mismos de siempre (0,75 y 0,55) leídos en la escala
      -- de cada proveedor. Didit los manda de 0 a 100 y se guardan tal cual,
      -- sin convertir: reescalarlos invitaría a compararlos con los umbrales
      -- del motor propio, que estaban calibrados contra OTRO modelo y no
      -- significan lo mismo aquí.
      case
        when coalesce(v.face_match_score * 100, d.face_match_score) is null then 'sin_dato'
        when coalesce(v.face_match_score * 100, d.face_match_score) >= 75 then 'alta'
        when coalesce(v.face_match_score * 100, d.face_match_score) >= 55 then 'media'
        else 'baja'
      end as face_match,
      case
        when coalesce(v.liveness_score * 100, d.liveness_score) is null then 'sin_dato'
        when coalesce(v.liveness_score * 100, d.liveness_score) >= 75 then 'alta'
        when coalesce(v.liveness_score * 100, d.liveness_score) >= 55 then 'media'
        else 'baja'
      end as liveness,

      v.registry_matched,
      v.rejection_detail,
      v.document_path,
      v.selfie_path,

      -- De dónde salió el veredicto. El panel lo usa para no enseñar dos
      -- marcos de foto vacíos en un expediente que nunca tuvo fotos.
      case when d.verification_id is not null then 'didit' else 'propio' end as provider,

      -- Lo único que explica una duda con palabras. Didit los manda como lista
      -- y se pasan enteros: el `rejection_detail` solo se queda con los tres
      -- primeros, y el cuarto puede ser justo el que importa.
      coalesce(d.warnings, '[]'::jsonb) as warnings,
      d.document_type,
      d.issuing_state,
      d.liveness_method,

      -- La sesión de Didit, tal cual la guarda el expediente: es el mismo
      -- enlace que abre la ficha (admin_user_verification).
      v.didit_session_id,
      v.didit_session_url,

      v.created_at,
      extract(epoch from (now() - v.created_at))::bigint as waiting_seconds
    from kyc.verifications v
    join public.profiles p on p.id = v.user_id

    -- El último veredicto de Didit para este expediente.
    --
    -- Se reconoce por `warnings`: es la única clave que añade el webhook de la
    -- decisión. El renglón que escribe `attach_didit_session` al abrir la
    -- sesión también lleva `provider: didit`, pero no trae señal ninguna, así
    -- que filtrar por el proveedor traería el renglón vacío la mitad de las
    -- veces.
    left join lateral (
      select
        l.verification_id,
        (l.signals ->> 'face_match_score')::numeric as face_match_score,
        (l.signals ->> 'liveness_score')::numeric   as liveness_score,
        l.signals ->> 'liveness_method'             as liveness_method,
        l.signals ->> 'document_type'               as document_type,
        l.signals ->> 'issuing_state'               as issuing_state,
        l.signals -> 'warnings'                     as warnings
      from kyc.decision_log l
      where l.verification_id = v.id
        and l.signals ? 'warnings'
      order by l.created_at desc
      limit 1
    ) d on true

    where v.status = 'manual_review'
      and not p.is_test
  ) q;

  return v_rows;
end;
$function$;

revoke all on function public.admin_kyc_queue() from public, anon;
grant execute on function public.admin_kyc_queue() to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_payment_queue(p_statuses text[] DEFAULT ARRAY['reported'::text, 'in_review'::text], p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today  date := public.helios_business_date(now());
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_from is not null and p_to is not null and p_to < p_from then
    raise exception 'El rango de fechas está al revés' using errcode = '22023';
  end if;

  select coalesce(
           jsonb_agg(public.helios_admin_payment_item(r.id, v_today) order by r.created_at),
           '[]'::jsonb
         )
    into v_result
  from public.payment_reports r
  join public.payment_quotes q on q.id = r.quote_id
  join public.profiles p on p.id = r.user_id
  where r.status::text = any(p_statuses)
    and not p.is_test
    -- El rango solo acota los resueltos, por el día operativo en que se
    -- decidieron (reviewed_at; created_at si no lo tuviera). La cola viva
    -- (reportados y en revisión) sale entera: no depende de fechas.
    and (
      r.status::text in ('reported', 'in_review')
      or (
        (p_from is null or public.helios_business_date(coalesce(r.reviewed_at, r.created_at)) >= p_from)
        and (p_to is null or public.helios_business_date(coalesce(r.reviewed_at, r.created_at)) <= p_to)
      )
    );

  return v_result;
end;
$function$;

comment on function public.admin_payment_queue(text[], date, date) is
  'Cola de conciliacion con el arbol entero: pago -> usuario, compras, cuotas y cargos por mora. p_from/p_to acotan solo los resueltos, por el dia operativo de reviewed_at.';
revoke all on function public.admin_payment_queue(text[], date, date) from public, anon;
grant execute on function public.admin_payment_queue(text[], date, date) to authenticated, service_role;
drop function if exists public.admin_payment_queue(text[]);
