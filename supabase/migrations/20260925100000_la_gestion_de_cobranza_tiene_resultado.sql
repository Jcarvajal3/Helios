-- ============================================================================
-- Ronda — La gestión de cobranza tiene resultado, y la promesa tiene estado
--
-- Una gestión decía por qué canal y cuándo, pero no qué pasó: «llamé» vale lo
-- mismo si contestó que si el número era de otra persona. Y la promesa de pago
-- era una fecha suelta que nadie volvía a mirar: el panel no sabía si se
-- cumplió, así que la persona de cobranza tenía que cruzarla a mano con los
-- pagos para decidir a quién volver a llamar.
--
-- Esta migración:
--   1. añade a `collection_contacts` el resultado (`outcome`) y la fecha de la
--      próxima acción (`next_action_on`);
--   2. `admin_log_contact` los recibe al final y con default, y se borra la
--      firma vieja para que PostgREST no tenga dos candidatas;
--   3. `admin_user_contacts` y `admin_collections` los devuelven, y la cola
--      dice además en qué estado está la promesa;
--   4. `admin_collection_promises`: la lista de promesas con su estado.
--
-- ── El estado de una promesa ─────────────────────────────────────────────────
-- `cumplida` = hay un pago reportado, no rechazado, creado entre la gestión y
-- el FINAL DEL DÍA OPERATIVO prometido (las 10:00 de Caracas del día
-- siguiente). Se usa el día operativo y no el de calendario por tres razones:
--   * es el mismo eje con el que ya se valida la promesa (`admin_log_contact`
--     rechaza una fecha anterior a `helios_business_date(now())`) y con el que
--     el panel la pinta en rojo (`promiseDate < hoy`, con `hoy` = día operativo);
--   * es el eje del motor de mora: una cuota que vence el día D no cuenta como
--     atrasada hasta las 10:00 de D+1, y quien promete «el viernes» y paga a
--     las dos de la madrugada del sábado, aún en la noche del viernes, no ha
--     incumplido nada;
--   * con el día de Caracas, una promesa «para hoy» anotada a las 09:00 (que
--     el formulario acepta, porque el día operativo aún es ayer) nacería rota.
-- `rota` = el día prometido terminó sin ese pago. `vence_hoy` y `pendiente` son
-- las que aún están a tiempo. Un pago `duplicate` tampoco cuenta: es el mismo
-- dinero reportado dos veces.
--
-- Todo es retrocompatible: solo se añaden columnas, campos y parámetros con
-- default. Las cuentas de prueba no salen en la lista de promesas.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las columnas
-- ---------------------------------------------------------------------------
alter table public.collection_contacts add column if not exists outcome text;
alter table public.collection_contacts add column if not exists next_action_on date;

alter table public.collection_contacts drop constraint if exists collection_contacts_outcome_check;
alter table public.collection_contacts add constraint collection_contacts_outcome_check
  check (outcome is null or outcome in (
    'contesto', 'no_contesta', 'numero_equivocado', 'mensaje_enviado', 'promesa', 'otro'
  ));

-- Para leer las gestiones de un rango de fechas (efectividad) sin pasar por
-- cada persona.
create index if not exists collection_contacts_contacted_idx
  on public.collection_contacts (contacted_at);

-- ---------------------------------------------------------------------------
-- 2. El estado de una promesa, en un solo sitio
-- ---------------------------------------------------------------------------
-- Lo usan la cola de cobranza y la lista de promesas: dos copias de la regla
-- acabarían diciendo cosas distintas de la misma promesa. Interna: sin grant
-- para nadie, la llaman solo funciones `security definer`.
create or replace function public.helios_promise_status(
  p_user         uuid,
  p_contacted_at timestamptz,
  p_promise_date date,
  p_today        date
)
returns text
language sql
stable
set search_path = public, pg_temp
as $$
  select case
    when p_promise_date is null then null
    when exists (
      select 1 from public.payment_reports pr
      where pr.user_id = p_user
        and pr.status not in ('rejected', 'duplicate')
        and pr.created_at >= p_contacted_at
        -- El final del día operativo prometido: las 10:00 de Caracas del día
        -- siguiente. Escrito como instante para que use el índice
        -- (user_id, created_at).
        and pr.created_at < ((p_promise_date + 1)::timestamp + interval '10 hours')
                            at time zone 'America/Caracas'
    ) then 'cumplida'
    when p_promise_date > p_today then 'pendiente'
    when p_promise_date = p_today then 'vence_hoy'
    else 'rota'
  end
$$;

revoke all on function public.helios_promise_status(uuid, timestamptz, date, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Anotar una gestión, con su resultado
-- ---------------------------------------------------------------------------
drop function if exists public.admin_log_contact(uuid, text, text, text, date);

create or replace function public.admin_log_contact(
  p_user           uuid,
  p_channel        text,
  p_note           text default null,
  p_template       text default null,
  p_promise_date   date default null,
  p_outcome        text default null,
  p_next_action_on date default null
)
returns uuid
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor   uuid := auth.uid();
  v_id      uuid;
  v_name    text;
  v_today   date := public.helios_business_date(now());
  v_outcome text := nullif(trim(coalesce(p_outcome, '')), '');
begin
  if not public.is_platform_admin() then
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
$$;

comment on function public.admin_log_contact(uuid, text, text, text, date, text, date) is
  'Registra una gestion de cobranza con su resultado y su proxima accion. La usan el boton de WhatsApp —que la llama sola— y "marcar contactado".';

revoke all on function public.admin_log_contact(uuid, text, text, text, date, text, date)
  from public, anon;
grant execute on function public.admin_log_contact(uuid, text, text, text, date, text, date)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4. El historial de gestiones de una persona
-- ---------------------------------------------------------------------------
-- Cambia la forma de la fila, así que no vale `create or replace`. Las columnas
-- nuevas van al final: quien lee por nombre no nota nada.
drop function if exists public.admin_user_contacts(uuid, integer);

create or replace function public.admin_user_contacts(p_user uuid, p_limit integer default 20)
returns table (
  id             uuid,
  contacted_at   timestamptz,
  channel        text,
  template       text,
  note           text,
  promise_date   date,
  actor_name     text,
  outcome        text,
  next_action_on date,
  promise_status text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := public.helios_business_date(now());
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  select c.id, c.contacted_at, c.channel::text, c.template, c.note, c.promise_date,
         coalesce(pa.full_name, 'Alguien del equipo'),
         c.outcome, c.next_action_on,
         public.helios_promise_status(c.user_id, c.contacted_at, c.promise_date, v_today)
  from public.collection_contacts c
  left join public.platform_admins pa on pa.user_id = c.actor
  where c.user_id = p_user
  order by c.contacted_at desc
  limit least(coalesce(p_limit, 20), 100);
end;
$$;

revoke all on function public.admin_user_contacts(uuid, integer) from public, anon;
grant execute on function public.admin_user_contacts(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. La cola de cobranza: resultado, próxima acción y estado de la promesa
-- ---------------------------------------------------------------------------
-- Igual que la de 20260911183000 y lo que haya encima en dev; solo cambian el
-- lateral del último contacto y el de la promesa, y tres campos al final.
create or replace function public.admin_collections(p_horizon_days integer default 3)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today     date := public.helios_business_date(now());
  v_horizon   integer := greatest(least(coalesce(p_horizon_days, 3), 30), 0);
  v_demotion  integer := public.helios_mora_demotion_days();
  v_expulsion integer := public.helios_mora_expulsion_days();
  v_rows      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- El vencimiento más antiguo primero ES el mayor atraso primero (`days_late`
  -- es `hoy - min(due_date)`), y además ordena a los que aún no vencen. El
  -- orden va dentro del `jsonb_agg`: el de una subconsulta no se hereda.
  select coalesce(
           jsonb_agg(to_jsonb(q) order by q.next_due_date, q.open_usd desc),
           '[]'::jsonb
         )
    into v_rows
  from (
    with pending as (
      select
        i.user_id as uid,
        i.amount_usd,
        i.due_date,
        m.name as merchant_name
      from public.installments i
      join public.charges ch on ch.id = i.charge_id
      join public.merchants m on m.id = ch.merchant_id
      where i.status = 'pending'
        and not i.is_test
        and i.due_date <= v_today + v_horizon
    ),
    grouped as (
      select
        uid,
        sum(amount_usd) as open_usd,
        sum(amount_usd) filter (where due_date < v_today) as overdue_usd,
        sum(amount_usd) filter (where due_date >= v_today) as upcoming_usd,
        max(v_today - due_date) as days_late,
        min(due_date) as next_due,
        count(*)::integer as cnt,
        array_agg(distinct merchant_name) as merchant_names
      from pending
      group by 1
    )
    select
      g.uid as user_id,
      p.full_name,
      p.phone_e164,
      p.status::text as status,
      p.level,
      -- `>= v_demotion` y `> v_expulsion` son los de `recompute_profile_mora_state`.
      case
        when g.days_late > v_expulsion then 'expulsion'
        when g.days_late >= v_demotion then 'baja_nivel'
        when g.days_late >= 1 then 'congelado'
        when g.days_late = 0  then 'vence_hoy'
        else 'por_vencer'
      end as bucket,
      g.open_usd::numeric as open_usd,
      coalesce(g.overdue_usd, 0)::numeric as overdue_usd,
      coalesce(g.upcoming_usd, 0)::numeric as upcoming_usd,
      greatest(g.days_late, 0)::integer as days_overdue,
      g.next_due as next_due_date,
      g.cnt as installment_count,
      g.merchant_names as merchants,
      (
        select max(pr.created_at) from public.payment_reports pr
        where pr.user_id = g.uid and pr.status = 'reconciled'
      ) as last_payment_at,
      c.contacted_at as last_contact_at,
      c.channel::text as last_contact_channel,
      c.actor_name as last_contact_by,
      c.note as last_contact_note,
      -- La promesa es la de la última gestión que traía una, no la de la
      -- última gestión a secas: un «no contesta» de hoy no borra lo que la
      -- persona prometió ayer.
      pm.promise_date,
      -- Si se habló con esta persona DESPUÉS de que se le venciera lo más viejo.
      exists (
        select 1 from public.collection_contacts cs
        where cs.user_id = g.uid
          and public.helios_business_date(cs.contacted_at) >= g.next_due
      ) as contacted_since_due,
      -- Resultado y próxima acción de la ÚLTIMA gestión; estado de la promesa
      -- de `promise_date`.
      c.outcome as last_contact_outcome,
      c.next_action_on as last_contact_next_action_on,
      public.helios_promise_status(g.uid, pm.contacted_at, pm.promise_date, v_today)
        as promise_status
    from grouped g
    join public.profiles p on p.id = g.uid
    left join lateral (
      select cc.contacted_at, cc.channel, cc.note, cc.outcome, cc.next_action_on,
             coalesce(pa.full_name, 'Alguien del equipo') as actor_name
      from public.collection_contacts cc
      left join public.platform_admins pa on pa.user_id = cc.actor
      where cc.user_id = g.uid
      order by cc.contacted_at desc
      limit 1
    ) c on true
    left join lateral (
      select cp.promise_date, cp.contacted_at
      from public.collection_contacts cp
      where cp.user_id = g.uid and cp.promise_date is not null
      order by cp.contacted_at desc
      limit 1
    ) pm on true
  ) q;

  return jsonb_build_object(
    'demotion_days', v_demotion,
    'expulsion_days', v_expulsion,
    'rows', v_rows
  );
end;
$$;

revoke all on function public.admin_collections(integer) from public, anon;
grant execute on function public.admin_collections(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Las promesas
-- ---------------------------------------------------------------------------
-- Cada gestión con fecha prometida, con lo que la persona debe HOY y el último
-- pago que reportó después de la gestión. Por defecto, las de los últimos 30
-- días y todas las futuras: una promesa rota de hace dos meses ya no se
-- persigue desde aquí, se persigue desde la cartera vencida.
create or replace function public.admin_collection_promises(
  p_from date default null,
  p_to   date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := public.helios_business_date(now());
  v_from  date := coalesce(p_from, public.helios_business_date(now()) - 30);
  v_rows  jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_to is not null and p_to < v_from then
    raise exception 'El rango de fechas está al revés' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.promise_date, q.contacted_at), '[]'::jsonb)
    into v_rows
  from (
    select
      c.id as contact_id,
      c.user_id,
      p.full_name,
      p.phone_e164,
      p.status::text as user_status,
      c.contacted_at,
      c.channel::text as channel,
      c.outcome,
      c.note,
      c.actor as actor_id,
      coalesce(pa.full_name, 'Alguien del equipo') as actor_name,
      c.promise_date,
      public.helios_promise_status(c.user_id, c.contacted_at, c.promise_date, v_today) as status,
      -- Si la persona prometió otra cosa después. Una promesa rota que ya se
      -- renegoció no pide la misma llamada que una que nadie ha vuelto a tocar.
      exists (
        select 1 from public.collection_contacts c2
        where c2.user_id = c.user_id
          and c2.promise_date is not null
          and c2.contacted_at > c.contacted_at
      ) as superseded,
      -- Lo vencido HOY (payable: es deuda, con el fee dentro). Misma regla que
      -- `overdue_usd` de `admin_collections`.
      coalesce(d.overdue_usd, 0)::numeric as overdue_usd,
      coalesce(d.days_overdue, 0)::integer as days_overdue,
      lp.last_payment
    from public.collection_contacts c
    join public.profiles p on p.id = c.user_id
    left join public.platform_admins pa on pa.user_id = c.actor
    left join lateral (
      select sum(i.amount_usd) as overdue_usd,
             max(v_today - i.due_date) as days_overdue
      from public.installments i
      where i.user_id = c.user_id
        and i.status = 'pending'
        and not i.is_test
        and i.due_date < v_today
    ) d on true
    left join lateral (
      -- El último pago reportado después de la gestión, sea cual sea su estado:
      -- un rechazado también explica por qué la promesa no se cumplió.
      select jsonb_build_object(
               'report_id',  r.id,
               'created_at', r.created_at,
               'status',     r.status::text,
               'amount_usd', q2.amount_usd
             ) as last_payment
      from public.payment_reports r
      join public.payment_quotes q2 on q2.id = r.quote_id
      where r.user_id = c.user_id
        and r.created_at >= c.contacted_at
      order by r.created_at desc
      limit 1
    ) lp on true
    where c.promise_date is not null
      and c.promise_date >= v_from
      and (p_to is null or c.promise_date <= p_to)
      and not p.is_test
  ) q;

  return jsonb_build_object(
    'business_date', v_today,
    'from', v_from,
    'to', p_to,
    'summary', jsonb_build_object(
      'vence_hoy', (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'vence_hoy'),
      'pendiente', (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'pendiente'),
      'cumplida',  (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'cumplida'),
      'rota',      (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'rota')
    ),
    'rows', v_rows
  );
end;
$$;

revoke all on function public.admin_collection_promises(date, date) from public, anon;
grant execute on function public.admin_collection_promises(date, date) to authenticated;
