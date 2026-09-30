-- ============================================================================
-- Ronda — Los contactos de cobranza
--
-- La cola de cobranza da el teléfono y abre WhatsApp con la plantilla del
-- tramo. Lo que no hace es **acordarse**: nadie sabe a quién ya se llamó, qué
-- dijo, ni si prometió pagar el jueves. Dos personas del equipo llaman al mismo
-- usuario el mismo día y al de al lado no lo llama nadie.
--
-- Sin esta tabla, la cobranza no es un proceso: son llamadas sueltas que se
-- pierden en cuanto se cuelga.
--
-- ---------------------------------------------------------------------------
-- Lo que se guarda, y lo que no
-- ---------------------------------------------------------------------------
-- Fecha y hora, canal, quién, la plantilla que se usó, la nota y —si la hubo—
-- la fecha que la persona prometió. Nada más: esto es una bitácora de
-- gestiones, no un CRM.
--
-- **La promesa no cambia lo que hace el motor.** Que alguien diga que paga el
-- jueves no descongela su cuenta ni frena el cargo por atraso: es información
-- para quien vuelve a llamar el viernes, y por eso se pinta en rojo cuando la
-- fecha ya pasó. Mover un vencimiento de verdad es otra cosa, y está aparte.
--
-- **Se puede anotar sin haber hablado.** El canal 'otro' con una nota cubre el
-- "le escribí y no contesta", que es el dato que más se repite y el que más
-- falta cuando alguien retoma una gestión ajena.
--
-- Quién puede: los dos roles. Contactar y anotar es el trabajo del operador.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Por dónde se habló
-- ---------------------------------------------------------------------------

do $do$
begin
  if not exists (select 1 from pg_type where typname = 'collection_channel') then
    create type public.collection_channel as enum ('whatsapp', 'llamada', 'en_local', 'otro');
  end if;
end
$do$;

-- ---------------------------------------------------------------------------
-- 2. La tabla
-- ---------------------------------------------------------------------------

create table if not exists public.collection_contacts (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  contacted_at timestamptz not null default now(),
  channel      public.collection_channel not null,
  -- Qué plantilla se mandó, cuando se mandó una. Sirve para saber si el
  -- mensaje del tramo funciona o solo lo parece.
  template     text,
  note         text,
  -- La fecha que la persona dijo. Null si no prometió nada.
  promise_date date,
  actor        uuid references auth.users (id),
  created_at   timestamptz not null default now()
);

comment on table public.collection_contacts is
  'Gestiones de cobranza: cuando se hablo con alguien, por donde, quien y que dijo. La promesa de pago NO cambia lo que hace el motor de mora.';

create index if not exists collection_contacts_user_idx
  on public.collection_contacts (user_id, contacted_at desc);

create index if not exists collection_contacts_promise_idx
  on public.collection_contacts (promise_date) where promise_date is not null;

-- Se toca solo por las RPC de abajo, que son security definer.
alter table public.collection_contacts enable row level security;
revoke all on table public.collection_contacts from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Anotar una gestión
-- ---------------------------------------------------------------------------

create or replace function public.admin_log_contact(
  p_user         uuid,
  p_channel      text,
  p_note         text default null,
  p_template     text default null,
  p_promise_date date default null
)
returns uuid
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_id    uuid;
  v_name  text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select full_name into v_name from public.profiles where id = p_user;
  if not found then
    raise exception 'No existe esa persona' using errcode = '22023';
  end if;

  -- Una promesa para ayer no es una promesa, es una errata.
  if p_promise_date is not null
     and p_promise_date < public.helios_business_date(now()) then
    raise exception 'La fecha prometida ya pasó' using errcode = '22023';
  end if;

  insert into public.collection_contacts (user_id, channel, template, note, promise_date, actor)
  values (
    p_user,
    p_channel::public.collection_channel,
    nullif(trim(coalesce(p_template, '')), ''),
    nullif(trim(coalesce(p_note, '')), ''),
    p_promise_date,
    v_actor
  )
  returning id into v_id;

  perform audit.log(v_actor, 'collection.contact', p_user, jsonb_build_object(
    'full_name', v_name,
    'channel', p_channel,
    'template', p_template,
    'promise_date', p_promise_date,
    'note', p_note
  ));

  return v_id;
end;
$$;

comment on function public.admin_log_contact(uuid, text, text, text, date) is
  'Registra una gestion de cobranza. La usan el boton de WhatsApp —que la llama sola— y "marcar contactado".';

revoke all on function public.admin_log_contact(uuid, text, text, text, date) from public, anon;
grant execute on function public.admin_log_contact(uuid, text, text, text, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Las gestiones de una persona, para su ficha
-- ---------------------------------------------------------------------------

create or replace function public.admin_user_contacts(
  p_user  uuid,
  p_limit integer default 20
)
returns table (
  id           uuid,
  contacted_at timestamptz,
  channel      text,
  template     text,
  note         text,
  promise_date date,
  actor_name   text
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  select c.id, c.contacted_at, c.channel::text, c.template, c.note, c.promise_date,
         coalesce(pa.full_name, 'Alguien del equipo')
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
-- 5. La cola los lleva consigo
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260911180000 salvo las cinco claves nuevas y el
-- lateral que las trae.

create or replace function public.admin_collections(p_horizon_days integer default 3)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today     date := public.helios_business_date(now());
  v_horizon   integer := greatest(least(coalesce(p_horizon_days, 3), 30), 0);
  -- NUEVO: los umbrales salen de los parámetros, como en el motor de mora.
  v_demotion  integer := public.helios_mora_demotion_days();
  v_expulsion integer := public.helios_mora_expulsion_days();
  v_rows      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- El orden es el de siempre —el más atrasado arriba, y a igual atraso el que
  -- más debe— escrito sobre `next_due_date` porque es el mismo dato:
  -- `days_late` es `max(hoy - due_date)`, o sea `hoy - min(due_date)`, así que
  -- el vencimiento más antiguo primero ES el mayor atraso primero, y además
  -- ordena entre sí a los que aún no vencen, que `days_overdue` aplana a cero.
  -- Hay que decirlo dentro del `jsonb_agg`: el orden de una subconsulta no se
  -- hereda al agregarla.
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
      -- ── NUEVO: los umbrales, y los operadores del motor ──────────────────
      -- `>= v_demotion` y `> v_expulsion` son los de
      -- `recompute_profile_mora_state` y los de docs/00-BASES §2.4. Aquí ponía
      -- `> 30` / `> 15`: ni los días eran esos, ni el corte era ese.
      --
      -- El tramo es la consecuencia NUEVA, y se suma a las anteriores: quien
      -- cae en 'baja_nivel' sigue con el saldo cerrado, ahora como bloqueado.
      case
        when g.days_late > v_expulsion then 'expulsion'
        when g.days_late >= v_demotion then 'baja_nivel'
        when g.days_late >= 1 then 'congelado'
        when g.days_late = 0  then 'vence_hoy'
        else 'por_vencer'
      end as bucket,
      -- ─────────────────────────────────────────────────────────────────────
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
      -- ── NUEVO (2026-09-11): el último contacto y la promesa ──────────────
      -- La lista se abre para hablar con alguien. Sin saber quién ya lo hizo
      -- y qué dijo, dos personas del equipo llaman al mismo usuario el mismo
      -- día y nadie llama al de al lado.
      c.contacted_at as last_contact_at,
      c.channel::text as last_contact_channel,
      c.actor_name as last_contact_by,
      c.note as last_contact_note,
      (
        select cp.promise_date
        from public.collection_contacts cp
        where cp.user_id = g.uid and cp.promise_date is not null
        order by cp.contacted_at desc
        limit 1
      ) as promise_date,
      -- Si se habló con esta persona DESPUÉS de que se le venciera lo más
      -- viejo. Un contacto de la semana pasada sobre otra cuota no cuenta:
      -- la pregunta es si alguien la ha llamado por lo que debe ahora.
      exists (
        select 1 from public.collection_contacts cs
        where cs.user_id = g.uid
          and public.helios_business_date(cs.contacted_at) >= g.next_due
      ) as contacted_since_due
    from grouped g
    join public.profiles p on p.id = g.uid
    left join lateral (
      select cc.contacted_at, cc.channel, cc.note,
             coalesce(pa.full_name, 'Alguien del equipo') as actor_name
      from public.collection_contacts cc
      left join public.platform_admins pa on pa.user_id = cc.actor
      where cc.user_id = g.uid
      order by cc.contacted_at desc
      limit 1
    ) c on true
  ) q;

  -- NUEVO: los umbrales viajan con la cola, no dentro del panel. Van fuera de
  -- las filas para que una cola vacía siga sabiendo etiquetar sus tramos.
  return jsonb_build_object(
    'demotion_days', v_demotion,
    'expulsion_days', v_expulsion,
    'rows', v_rows
  );
end;
$$;

comment on function public.admin_collections(integer) is
  'Cola de cobranza por persona, con su tramo, lo que debe y la ultima gestion. Los umbrales viajan fuera de las filas para que una cola vacia siga sabiendo etiquetar sus tramos.';

revoke all on function public.admin_collections(integer) from public, anon;
grant execute on function public.admin_collections(integer) to authenticated;
