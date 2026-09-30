-- ============================================================================
-- Ronda — El calendario de feriados
--
-- «Día hábil» se aproximaba descartando sábados y domingos. En Venezuela eso
-- se queda corto: entre Carnaval, Semana Santa y las fiestas nacionales hay
-- más de una docena de días en que el BCV no publica y los bancos no mueven
-- nada. Esos días:
--
--   * La tasa se arrastra, y el panel no sabía decir que era normal. El aviso
--     de «la tasa lleva días sin actualizarse» saltaba un martes de Carnaval.
--   * Una transferencia hecha el viernes no llega hasta el martes, y el cierre
--     que «ya debería haber salido» todavía no ha podido salir.
--
-- El calendario lo mantiene el super admin: no se puede deducir, cambia cada
-- año y a veces lo anuncian con una semana de aviso.
--
-- ---------------------------------------------------------------------------
-- Qué cuenta como hábil
-- ---------------------------------------------------------------------------
-- Ni sábado, ni domingo, ni un día del calendario. Nada más: no hay medios
-- días ni feriados bancarios distintos de los nacionales, y meter esa
-- distinción ahora sería modelar una complejidad que todavía no existe.
-- ============================================================================

create table if not exists public.holidays (
  day         date primary key,
  name        text not null,
  -- Nacional, regional, bancario. Hoy todos cuentan igual; la columna existe
  -- para poder distinguirlos el día que haga falta sin migrar datos.
  kind        text not null default 'nacional',
  created_by  uuid references auth.users (id),
  created_at  timestamptz not null default now()
);

comment on table public.holidays is
  'Dias en que ni el BCV publica ni los bancos mueven dinero. Lo mantiene el super admin: no se puede deducir y cambia cada año.';

alter table public.holidays enable row level security;
revoke all on table public.holidays from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Los dos predicados
-- ---------------------------------------------------------------------------

create or replace function public.helios_is_business_day(p_day date)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select extract(isodow from p_day) < 6
     and not exists (select 1 from public.holidays h where h.day = p_day);
$fn$;

comment on function public.helios_is_business_day(date) is
  'Ni sabado, ni domingo, ni feriado. Es el unico sitio donde se decide que es un dia habil.';

/**
 * Cuántos días hábiles hay entre dos fechas, sin contar la primera.
 *
 * Es lo que convierte «la tasa lleva 60 horas sin cambiar» en «lleva dos días
 * hábiles», que es la frase con la que se decide si el scraper está roto o si
 * simplemente es martes de Carnaval.
 */
create or replace function public.helios_business_days_between(p_from date, p_to date)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select count(*)::integer
  from generate_series(p_from + 1, p_to, interval '1 day') d
  where public.helios_is_business_day(d::date);
$fn$;

revoke all on function public.helios_is_business_day(date) from public, anon;
revoke all on function public.helios_business_days_between(date, date) from public, anon;
grant execute on function public.helios_is_business_day(date) to authenticated;
grant execute on function public.helios_business_days_between(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- La tasa lo usa
-- ---------------------------------------------------------------------------
-- Cuerpo del de 20260824100000 con dos columnas más. `is_stale` sigue saliendo
-- de las 48 h del `fetched_at` —mide si el job corre— y la nueva
-- `business_days_behind` mide otra cosa: cuántos días hábiles lleva la tasa
-- vigente sin cambiar de fecha. Son distintas y las dos importan: el job puede
-- estar corriendo y trayendo siempre la misma tasa vieja.
--
-- `drop` antes del `create or replace`: se suman tres columnas nuevas y
-- Postgres no deja cambiar la fila de retorno de una función existente sin
-- borrarla primero.
drop function if exists public.fx_rate_status(text);

create or replace function public.fx_rate_status(p_source text default 'BCV')
returns table (
  rate             numeric,
  effective_date   date,
  fetched_at       timestamptz,
  business_date    date,
  is_current       boolean,
  age_hours        numeric,
  is_stale         boolean,
  last_sync_at     timestamptz,
  last_sync_status text,
  last_sync_detail text,
  business_days_behind integer,
  today_is_holiday boolean,
  holiday_name     text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  with bd as (
    select public.helios_business_date(now()) as d
  ),
  last_rate as (
    select r.rate, r.effective_date, r.fetched_at
    from public.exchange_rates r, bd
    where r.source = p_source and r.effective_date <= bd.d
    order by r.effective_date desc
    limit 1
  ),
  last_sync as (
    select s.created_at, s.status, s.detail
    from public.fx_rate_syncs s
    order by s.created_at desc
    limit 1
  )
  select
    last_rate.rate,
    last_rate.effective_date,
    last_rate.fetched_at,
    bd.d,
    last_rate.effective_date = bd.d,
    round((extract(epoch from now() - last_rate.fetched_at) / 3600)::numeric, 1),
    -- Vieja de verdad: más de 48 h sin que entre una tasa nueva. Un fin de
    -- semana no la enciende: el job corre igual sábado y domingo y reescribe
    -- la misma cifra, refrescando `fetched_at`. Solo se prende cuando el job
    -- de verdad dejó de traer nada.
    now() - last_rate.fetched_at > interval '48 hours',
    last_sync.created_at,
    last_sync.status,
    last_sync.detail,
    -- Cuántos días hábiles lleva la tasa vigente sin cambiar de fecha. Esta es
    -- la que sabe que un martes de Carnaval no cuenta.
    public.helios_business_days_between(last_rate.effective_date, bd.d),
    not public.helios_is_business_day(bd.d),
    (select h.name from public.holidays h where h.day = bd.d)
  from bd
  left join last_rate on true
  left join last_sync on true;
$fn$;

comment on function public.fx_rate_status(text) is
  'Tasa vigente, antiguedad y ultimo intento de ingesta. `is_stale` dice si el job dejo de correr; `business_days_behind` dice si la tasa lleva dias habiles sin cambiar, que es otra cosa.';

revoke all on function public.fx_rate_status(text) from public, anon;
grant execute on function public.fx_rate_status(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Mantenerlo
-- ---------------------------------------------------------------------------

create or replace function public.admin_holidays(p_year integer default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.day), '[]'::jsonb)
  into v_rows
  from (
    select h.day, h.name, h.kind
    from public.holidays h
    where p_year is null or extract(year from h.day) = p_year
    order by h.day
  ) q;

  return v_rows;
end;
$$;

create or replace function public.admin_set_holiday(
  p_day    date,
  p_name   text,
  p_kind   text default 'nacional',
  p_remove boolean default false
)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede tocar el calendario'
      using errcode = '42501';
  end if;

  if p_remove then
    delete from public.holidays where day = p_day;
    perform audit.log(v_actor, 'holiday.removed', null,
      jsonb_build_object('day', p_day));
    return;
  end if;

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'El feriado necesita nombre' using errcode = '22023';
  end if;

  insert into public.holidays (day, name, kind, created_by)
  values (p_day, trim(p_name), coalesce(nullif(trim(p_kind), ''), 'nacional'), v_actor)
  on conflict (day) do update
    set name = excluded.name, kind = excluded.kind;

  perform audit.log(v_actor, 'holiday.set', null,
    jsonb_build_object('day', p_day, 'name', trim(p_name), 'kind', p_kind));
end;
$$;

revoke all on function public.admin_holidays(integer) from public, anon;
revoke all on function public.admin_set_holiday(date, text, text, boolean) from public, anon;
grant execute on function public.admin_holidays(integer) to authenticated;
grant execute on function public.admin_set_holiday(date, text, text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Los feriados nacionales de Venezuela de 2026
-- ---------------------------------------------------------------------------
-- Los fijos por ley y los dos móviles de este año. Se siembran para que el
-- calendario nazca útil; el super admin corrige lo que haga falta.

insert into public.holidays (day, name, kind) values
  ('2026-01-01', 'Año Nuevo', 'nacional'),
  ('2026-02-16', 'Carnaval', 'nacional'),
  ('2026-02-17', 'Carnaval', 'nacional'),
  ('2026-04-02', 'Jueves Santo', 'nacional'),
  ('2026-04-03', 'Viernes Santo', 'nacional'),
  ('2026-04-19', 'Declaración de la Independencia', 'nacional'),
  ('2026-05-01', 'Día del Trabajador', 'nacional'),
  ('2026-06-24', 'Batalla de Carabobo', 'nacional'),
  ('2026-07-05', 'Día de la Independencia', 'nacional'),
  ('2026-07-24', 'Natalicio de Simón Bolívar', 'nacional'),
  ('2026-10-12', 'Día de la Resistencia Indígena', 'nacional'),
  ('2026-12-24', 'Nochebuena', 'bancario'),
  ('2026-12-25', 'Navidad', 'nacional'),
  ('2026-12-31', 'Fin de año', 'bancario')
on conflict (day) do nothing;
