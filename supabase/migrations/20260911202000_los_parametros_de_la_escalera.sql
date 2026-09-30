-- ============================================================================
-- Ronda — Los parámetros del negocio, con fecha de vigencia
--
-- La comisión del usuario, el cargo por atraso, los días de cada cuota y los
-- tres peldaños de la escalera viven en funciones `immutable` que devuelven un
-- número escrito a mano. Cambiar cualquiera de ellos es una migración, un
-- despliegue y —lo que de verdad duele— **un cambio sin fecha**: el día que el
-- fee pasó del 10 % al 20 % no quedó registrado en ningún sitio, y hoy no hay
-- forma de saber con qué comisión nació un consumo de agosto.
--
-- ---------------------------------------------------------------------------
-- Una tabla con vigencia, no una tabla de ajustes
-- ---------------------------------------------------------------------------
-- Cada fila es «este parámetro vale X **desde** este día». No se actualiza
-- nunca: cambiar un parámetro es insertar otra fila con otra fecha. Eso da dos
-- cosas que una tabla de ajustes normal no da:
--
--   * **El histórico.** Se puede preguntar cuánto valía el fee en agosto.
--   * **El cambio programado.** Subir el cargo a partir del lunes que viene se
--     escribe hoy y entra solo.
--
-- ⚠️ **Lo que NO hace esto: reescribir el pasado.** Las funciones devuelven el
-- valor de **hoy**, y el motor de mora las llama cada mañana. Si se alarga la
-- escalera de 60 a 90 días, mañana nadie se expulsa a los 60 — ni siquiera
-- quien ya llevaba 70. Es lo correcto (la consecuencia se aplica con la regla
-- vigente) pero hay que saberlo antes de tocar nada, porque no hay forma de
-- deshacerlo.
--
-- ---------------------------------------------------------------------------
-- Y por qué las funciones dejan de ser `immutable`
-- ---------------------------------------------------------------------------
-- Porque dejan de devolver siempre lo mismo. Pasan a `stable`, que es lo que
-- de verdad son: constantes dentro de una consulta, variables entre dos.
-- Ninguna se usa en un índice, en un `check` ni en una columna generada —se
-- comprobó antes de escribir esto—, así que el cambio de volatilidad no rompe
-- nada. El `fallback` de cada una es su valor de hoy: si la tabla estuviera
-- vacía, el sistema sigue comportándose exactamente igual que antes.
-- ============================================================================

create table if not exists public.business_parameters (
  key            text not null,
  value          numeric(18,4) not null,
  effective_from date not null,
  note           text,
  created_by     uuid references auth.users (id),
  created_at     timestamptz not null default now(),
  primary key (key, effective_from)
);

comment on table public.business_parameters is
  'Los parametros del negocio con fecha de vigencia. Nunca se actualiza una fila: cambiar un parametro es insertar otra con otra fecha, y asi queda el historico y se pueden programar cambios.';

alter table public.business_parameters enable row level security;
revoke all on table public.business_parameters from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- El lector
-- ---------------------------------------------------------------------------

create or replace function public.helios_parameter(p_key text, p_fallback numeric)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select coalesce((
    select p.value
    from public.business_parameters p
    where p.key = p_key
      and p.effective_from <= public.helios_business_date(now())
    order by p.effective_from desc
    limit 1
  ), p_fallback);
$fn$;

comment on function public.helios_parameter(text, numeric) is
  'El valor vigente HOY de un parametro. El fallback es su valor historico escrito en codigo: con la tabla vacia el sistema se comporta igual que antes de existir.';

revoke all on function public.helios_parameter(text, numeric) from public, anon;
grant execute on function public.helios_parameter(text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Los valores de hoy, sembrados
-- ---------------------------------------------------------------------------
-- La fecha es anterior a la primera venta: son los que han estado vigentes
-- desde siempre según el sistema. El histórico real de cuándo cambió cada uno
-- se perdió al no existir esta tabla, y inventarlo sería peor que no tenerlo.

insert into public.business_parameters (key, value, effective_from, note) values
  ('consumer_fee_pct',          20.00, '2026-08-01', 'Lo que el usuario paga de más por usar Helios'),
  ('vat_pct',                   16.00, '2026-08-01', 'IVA sobre la comisión'),
  ('late_fee_usd',               2.00, '2026-08-01', 'Cargo por cada cuota con atraso'),
  ('late_fee_grace_days',        3.00, '2026-08-01', 'Días de atraso antes de que caiga el cargo'),
  ('installment_interval_days',  7.00, '2026-08-01', 'Días entre el consumo y la cuota 1, y entre la 1 y la 2'),
  ('mora_demotion_days',        30.00, '2026-08-01', 'Días de atraso que cuestan un nivel y bloquean'),
  ('mora_expulsion_days',       60.00, '2026-08-01', 'Días de atraso que cuestan la cuenta y castigan la deuda'),
  ('on_time_grace_days',         2.00, '2026-08-01', 'Días de reintento que siguen contando como a tiempo'),
  ('min_float_days',             7.00, '2026-08-01', 'Mínimo entre el consumo y su primera cuota'),
  ('charge_ttl_minutes',        15.00, '2026-08-01', 'Minutos que vive un cobro pendiente antes de expirar')
on conflict (key, effective_from) do nothing;

-- ---------------------------------------------------------------------------
-- Y los ocho lectores, ahora leyendo de la tabla
-- ---------------------------------------------------------------------------
-- Misma firma y mismo valor por defecto. Lo único que cambia es de dónde sale
-- el número y que pasan de `immutable` a `stable`.

create or replace function public.helios_consumer_fee_pct()
returns numeric language sql stable security definer set search_path = public, pg_temp
as $fn$ select public.helios_parameter('consumer_fee_pct', 20.00) $fn$;

create or replace function public.helios_vat_pct()
returns numeric language sql stable security definer set search_path = public, pg_temp
as $fn$ select public.helios_parameter('vat_pct', 16.00) $fn$;

create or replace function public.helios_late_fee_usd()
returns numeric language sql stable security definer set search_path = public, pg_temp
as $fn$ select public.helios_parameter('late_fee_usd', 2.00) $fn$;

create or replace function public.helios_late_fee_grace_days()
returns integer language sql stable security definer set search_path = public, pg_temp
as $fn$ select public.helios_parameter('late_fee_grace_days', 3)::integer $fn$;

create or replace function public.helios_installment_interval_days()
returns integer language sql stable security definer set search_path = public, pg_temp
as $fn$ select public.helios_parameter('installment_interval_days', 7)::integer $fn$;

create or replace function public.helios_mora_demotion_days()
returns integer language sql stable security definer set search_path = public, pg_temp
as $fn$ select public.helios_parameter('mora_demotion_days', 30)::integer $fn$;

create or replace function public.helios_mora_expulsion_days()
returns integer language sql stable security definer set search_path = public, pg_temp
as $fn$ select public.helios_parameter('mora_expulsion_days', 60)::integer $fn$;

create or replace function public.helios_on_time_grace_days()
returns integer language sql stable security definer set search_path = public, pg_temp
as $fn$ select public.helios_parameter('on_time_grace_days', 2)::integer $fn$;

create or replace function public.helios_min_float_days()
returns integer language sql stable security definer set search_path = public, pg_temp
as $fn$ select public.helios_parameter('min_float_days', 7)::integer $fn$;

grant execute on function public.helios_consumer_fee_pct() to authenticated;
grant execute on function public.helios_vat_pct() to authenticated;
grant execute on function public.helios_late_fee_usd() to authenticated;
grant execute on function public.helios_late_fee_grace_days() to authenticated;
grant execute on function public.helios_installment_interval_days() to authenticated;
grant execute on function public.helios_mora_demotion_days() to authenticated;
grant execute on function public.helios_mora_expulsion_days() to authenticated;
grant execute on function public.helios_on_time_grace_days() to authenticated;
grant execute on function public.helios_min_float_days() to authenticated;

-- ---------------------------------------------------------------------------
-- Verlos y cambiarlos
-- ---------------------------------------------------------------------------

create or replace function public.admin_business_parameters()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today date := public.helios_business_date(now());
  v_rows  jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.key), '[]'::jsonb)
  into v_rows
  from (
    select
      k.key,
      -- El vigente hoy.
      (select p.value from public.business_parameters p
        where p.key = k.key and p.effective_from <= v_today
        order by p.effective_from desc limit 1) as value,
      (select p.effective_from from public.business_parameters p
        where p.key = k.key and p.effective_from <= v_today
        order by p.effective_from desc limit 1) as effective_from,
      (select p.note from public.business_parameters p
        where p.key = k.key and p.effective_from <= v_today
        order by p.effective_from desc limit 1) as note,
      -- El programado, si lo hay. Es lo que deja ver "sube a €3 el lunes".
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
       from public.business_parameters h where h.key = k.key) as history
    from (select distinct key from public.business_parameters) k
  ) q;

  return jsonb_build_object('business_date', v_today, 'rows', v_rows);
end;
$$;

create or replace function public.admin_set_business_parameter(
  p_key            text,
  p_value          numeric,
  p_effective_from date default null,
  p_note           text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_today date := public.helios_business_date(now());
  v_desde date;
  v_antes numeric;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede cambiar un parámetro del negocio'
      using errcode = '42501';
  end if;

  if not exists (select 1 from public.business_parameters where key = p_key) then
    raise exception 'No existe el parámetro %', p_key using errcode = '22023';
  end if;

  v_desde := coalesce(p_effective_from, v_today);

  -- Hacia atrás no. Cambiar la vigencia de un parámetro en el pasado no
  -- reescribe lo que ya pasó —el motor aplicó lo que aplicó— pero sí haría
  -- que el histórico mintiera sobre ello.
  if v_desde < v_today then
    raise exception 'Un parámetro no puede entrar en vigor en el pasado'
      using errcode = '22023';
  end if;

  if p_value < 0 then
    raise exception 'Un parámetro no puede ser negativo' using errcode = '22023';
  end if;

  select public.helios_parameter(p_key, null) into v_antes;

  insert into public.business_parameters (key, value, effective_from, note, created_by)
  values (p_key, p_value, v_desde, nullif(trim(coalesce(p_note, '')), ''), v_actor)
  on conflict (key, effective_from) do update
    set value = excluded.value, note = excluded.note,
        created_by = excluded.created_by, created_at = now();

  perform audit.log(v_actor, 'parameter.set', null, jsonb_build_object(
    'key', p_key,
    'from_value', v_antes,
    'to_value', p_value,
    'effective_from', v_desde,
    'note', p_note
  ));

  return jsonb_build_object(
    'ok', true, 'key', p_key, 'value', p_value, 'effective_from', v_desde
  );
end;
$$;

comment on function public.admin_set_business_parameter(text, numeric, date, text) is
  'Cambia un parametro desde una fecha. No reescribe el pasado: el motor aplica el valor vigente el dia que corre, asi que alargar la escalera no des-expulsa a nadie.';

revoke all on function public.admin_business_parameters() from public, anon;
revoke all on function public.admin_set_business_parameter(text, numeric, date, text) from public, anon;
grant execute on function public.admin_business_parameters() to authenticated;
grant execute on function public.admin_set_business_parameter(text, numeric, date, text) to authenticated;
