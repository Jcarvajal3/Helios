-- ============================================================================
-- Ronda — Ingesta automática de la tasa BCV
--
-- `20260822051000_fx_rates.sql` dejó la tabla, la resolución y `record_fx_rate`
-- listas, y escribió en un comentario que "la ingesta es un job diario (fuera
-- de este esquema)". Ese job nunca existió: la única tasa cargada era la
-- semilla de desarrollo (40,00), así que toda cotización en bolívares salía de
-- un número inventado. Esto lo construye.
--
-- Decisiones:
--
-- 1. **Dentro de Postgres, no en una función serverless.** Igual que el resto
--    del cron de dinero (docs/01-ARQUITECTURA.md §7): la tasa se busca con la
--    extensión `http` y se persiste en la misma transacción. Una Edge Function
--    habría metido un runtime más, un secreto de service role fuera de la base
--    y un despliegue aparte para algo que son treinta líneas de SQL.
--
-- 2. **A las 10:00 AM de Caracas**, cuando cambia el día operativo
--    (`helios_business_date`), y ANTES de que corran mora (10:05) y
--    liquidaciones (10:10): esos dos barridos cotizan en bolívares y tienen
--    que hacerlo con la tasa del día que se acaba de abrir, no con la del que
--    se cerró.
--
-- 3. **Varias fuentes, por prioridad.** El BCV no publica un JSON: publica una
--    página web con certificado propio que se cae a menudo. Se leen espejos
--    que republican la tasa oficial, en orden, y se toma la primera que
--    conteste algo válido.
--
-- 4. **Nada entra sin validar.** Una tasa manipulada o mal parseada es la
--    forma más barata de robar a Ronda —o de regalarle el consumo a todo el
--    mundo—: se rechaza lo que no sea positivo, lo que se salga del rango
--    razonable, lo que venga de un espejo congelado hace más de una semana y
--    lo que se despegue más de un 25 % de la última tasa conocida. Un rechazo
--    NO escribe: deja vigente la tasa anterior, que es exactamente lo que ya
--    pasa los fines de semana, y enciende el aviso de tasa vieja en el panel.
-- ============================================================================

create extension if not exists http with schema extensions;

-- ---------------------------------------------------------------------------
-- 1. Fuentes
-- ---------------------------------------------------------------------------
-- En tabla y no en el cuerpo de la función: cuando un espejo cambie de forma
-- o se muera —y va a pasar— se arregla con un UPDATE de una fila, no con una
-- migración y un despliegue.

create table if not exists public.fx_rate_sources (
  key         text primary key,
  url         text not null,
  rate_path   text[] not null,
  date_path   text[],
  date_format text not null default 'timestamptz'
              check (date_format in ('timestamptz', 'epoch')),
  priority    integer not null,
  is_active   boolean not null default true,
  note        text
);

comment on table public.fx_rate_sources is
  'Espejos JSON de la tasa oficial del BCV, por prioridad. Los lee sync_fx_rate().';
comment on column public.fx_rate_sources.rate_path is
  'Ruta jsonb hasta el número de la tasa, para el operador #>>. Ej: {rates,VES}.';
comment on column public.fx_rate_sources.date_path is
  'Ruta hasta la fecha de publicación de la fuente. Sirve para detectar un espejo congelado.';

alter table public.fx_rate_sources enable row level security;
-- Sin políticas: la lee sync_fx_rate() (security definer) y nadie más. De
-- dónde sale la tasa no es algo que el cliente deba ver ni, mucho menos, tocar.

insert into public.fx_rate_sources (key, url, rate_path, date_path, date_format, priority, note)
values
  ('dolarapi',
   'https://ve.dolarapi.com/v1/dolares/oficial',
   '{promedio}', '{fechaActualizacion}', 'timestamptz', 1,
   'DolarAPI Venezuela. Republica la tasa oficial del BCV con su fecha de vigencia.'),
  ('er-api',
   'https://open.er-api.com/v6/latest/USD',
   '{rates,VES}', '{time_last_update_unix}', 'epoch', 2,
   'exchangerate-api. Segunda opinión: su VES sigue a la oficial. Actualiza una vez al día.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Bitácora de ingestas
-- ---------------------------------------------------------------------------
-- Cada intento deja rastro, incluidos los que fallan. Sin esto, un espejo que
-- lleva tres días devolviendo basura se ve igual que un fin de semana: una
-- tasa que no cambia.

create table if not exists public.fx_rate_syncs (
  id             bigint generated always as identity primary key,
  source_key     text,
  effective_date date not null,
  status         text not null check (status in (
                   'ok', 'skipped', 'network_error', 'http_error',
                   'parse_error', 'rejected', 'no_source', 'manual'
                 )),
  -- `numeric` a secas, no numeric(18,6) como en `exchange_rates`: aquí se
  -- guarda también lo que se rechaza, y un espejo que devuelve 1e20 no puede
  -- reventar el job justo cuando se está apuntando que ese espejo va mal.
  rate           numeric,
  http_status    integer,
  published_at   timestamptz,
  detail         text,
  payload        jsonb,
  created_at     timestamptz not null default now()
);

create index if not exists fx_rate_syncs_recent_idx
  on public.fx_rate_syncs (created_at desc);

comment on table public.fx_rate_syncs is
  'Historial de intentos de ingesta de la tasa. Se purga a los 90 días.';

alter table public.fx_rate_syncs enable row level security;
-- Sin políticas: el panel la lee por admin_fx_rate_history().

-- ---------------------------------------------------------------------------
-- 3. Guardarraíl
-- ---------------------------------------------------------------------------
-- Aparte del job y no dentro de él para poder probarlo: lo que decide si una
-- tasa entra o no es la única parte de esta migración que se puede ejercer sin
-- red, y es también la única que, si se equivoca, cobra de más a todo el mundo.
--
-- Devuelve null si la tasa es aceptable, o el motivo del rechazo.

create or replace function public.fx_rate_rejection(
  p_rate      numeric,
  p_previous  numeric,
  p_published timestamptz,
  p_effective date
)
returns text
language plpgsql
stable
set search_path = public, pg_temp
as $fn$
declare
  -- El salto máximo diario es generoso a propósito: el bolívar se devalúa a
  -- saltos, pero un 25 % en un día es un error de parseo o de unidad mucho más
  -- a menudo que una devaluación real. Si de verdad ocurre, un super admin la
  -- carga a mano y queda firmada en la bitácora.
  c_max_drift constant numeric := 0.25;
  c_min_rate  constant numeric := 0.01;
  c_max_rate  constant numeric := 100000000;
  c_max_age   constant integer := 7;   -- días que puede tener la publicación del espejo
begin
  if p_rate is null or p_rate < c_min_rate or p_rate > c_max_rate then
    return format('Tasa fuera de rango: %s', coalesce(p_rate::text, 'null'));
  end if;

  if p_published is not null
     and public.helios_business_date(p_published) < p_effective - c_max_age then
    return format('El espejo lleva congelado desde %s', p_published::date);
  end if;

  if p_previous is not null and p_previous > 0
     and abs(p_rate - p_previous) / p_previous > c_max_drift then
    return format('Salto del %s %% sobre la tasa anterior (%s)',
                  round(abs(p_rate - p_previous) / p_previous * 100, 1), p_previous);
  end if;

  return null;
end;
$fn$;

comment on function public.fx_rate_rejection(numeric, numeric, timestamptz, date) is
  'Motivo por el que NO se acepta una tasa traída de un espejo, o null si es buena.';

revoke all on function public.fx_rate_rejection(numeric, numeric, timestamptz, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. El job
-- ---------------------------------------------------------------------------

create or replace function public.sync_fx_rate(
  p_effective_date date default null,
  p_force          boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_effective  date := coalesce(p_effective_date, public.helios_business_date(now()));
  v_previous   numeric;
  v_src        public.fx_rate_sources%rowtype;
  v_status     integer;
  v_body       text;
  v_payload    jsonb;
  v_rate       numeric;
  v_published  timestamptz;
  v_reject     text;
  v_failed     boolean;
  v_tried      integer := 0;
begin
  -- Tasa contra la que se compara el salto: la última ANTERIOR al día que se
  -- está cargando. Si se comparase contra la del propio día, un reintento
  -- forzado se estaría midiendo contra sí mismo.
  select rate into v_previous
  from public.exchange_rates
  where source = 'BCV' and effective_date < v_effective
  order by effective_date desc
  limit 1;

  -- Ya hay tasa para este día operativo: no se vuelve a pedir. Esto es lo que
  -- hace que los reintentos horarios sean gratis — el de las 11 AM no hace ni
  -- una petición si el de las 10 funcionó.
  if not p_force and exists (
    select 1 from public.exchange_rates
    where source = 'BCV' and effective_date = v_effective
  ) then
    return jsonb_build_object(
      'ok', true, 'skipped', true, 'effective_date', v_effective,
      'rate', public.current_fx_rate('BCV', v_effective)
    );
  end if;

  -- Sin tope de tiempo, un espejo que acepta la conexión y no contesta nunca
  -- deja colgado al worker del cron. Va en su propio bloque: que la extensión
  -- no conozca una de estas opciones no puede ser lo que impida traer la tasa.
  begin
    perform extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '4000');
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
  exception when others then
    null;
  end;

  for v_src in
    select * from public.fx_rate_sources where is_active order by priority
  loop
    v_tried     := v_tried + 1;
    v_status    := null;
    v_body      := null;
    v_payload   := null;
    v_rate      := null;
    v_published := null;
    v_failed    := false;

    -- --- Pedir -------------------------------------------------------------
    -- El `continue` va fuera del manejador a propósito: saltar de dentro de un
    -- bloque de excepción al siguiente ciclo del bucle es justo el tipo de
    -- cosa que funciona hasta que un día no.
    begin
      select r.status, r.content into v_status, v_body
      from extensions.http((
        'GET',
        v_src.url,
        array[
          extensions.http_header('Accept', 'application/json'),
          extensions.http_header('User-Agent', 'Helios/1.0 (fx ingest)')
        ],
        null,
        null
      )::extensions.http_request) as r;
    exception when others then
      insert into public.fx_rate_syncs (source_key, effective_date, status, detail)
      values (v_src.key, v_effective, 'network_error', left(sqlerrm, 500));
      v_failed := true;
    end;

    if v_failed then
      continue;
    end if;

    if v_status is distinct from 200 then
      insert into public.fx_rate_syncs (source_key, effective_date, status, http_status, detail)
      values (v_src.key, v_effective, 'http_error', v_status, left(coalesce(v_body, ''), 500));
      continue;
    end if;

    -- --- Parsear -----------------------------------------------------------
    begin
      v_payload := v_body::jsonb;
      v_rate    := (v_payload #>> v_src.rate_path)::numeric;

      if v_src.date_path is not null then
        v_published := case v_src.date_format
          when 'epoch' then to_timestamp((v_payload #>> v_src.date_path)::double precision)
          else (v_payload #>> v_src.date_path)::timestamptz
        end;
      end if;
    exception when others then
      insert into public.fx_rate_syncs
        (source_key, effective_date, status, http_status, detail, payload)
      values (v_src.key, v_effective, 'parse_error', v_status, left(sqlerrm, 500), v_payload);
      v_failed := true;
    end;

    if v_failed then
      continue;
    end if;

    -- --- Validar -----------------------------------------------------------
    v_reject := public.fx_rate_rejection(v_rate, v_previous, v_published, v_effective);

    if v_reject is not null then
      insert into public.fx_rate_syncs
        (source_key, effective_date, status, http_status, rate, published_at, detail, payload)
      values (v_src.key, v_effective, 'rejected', v_status, v_rate, v_published,
              v_reject, v_payload);
      continue;
    end if;

    -- --- Guardar -----------------------------------------------------------
    perform public.record_fx_rate(v_rate, v_effective, 'BCV');

    insert into public.fx_rate_syncs
      (source_key, effective_date, status, http_status, rate, published_at, payload)
    values (v_src.key, v_effective, 'ok', v_status, v_rate, v_published, v_payload);

    -- La bitácora vieja no sirve para nada y esta tabla crece todos los días.
    delete from public.fx_rate_syncs where created_at < now() - interval '90 days';

    return jsonb_build_object(
      'ok', true, 'skipped', false, 'source', v_src.key,
      'rate', v_rate, 'effective_date', v_effective, 'published_at', v_published
    );
  end loop;

  -- Ninguna fuente sirvió. No se escribe nada: sigue vigente la última tasa
  -- buena y `fx_rate_status()` empieza a avisar de que está vieja.
  insert into public.fx_rate_syncs (effective_date, status, detail)
  values (v_effective, case when v_tried = 0 then 'no_source' else 'rejected' end,
          format('%s fuente(s) intentadas, ninguna válida', v_tried));

  return jsonb_build_object(
    'ok', false, 'skipped', false, 'effective_date', v_effective,
    'sources_tried', v_tried, 'rate', v_previous
  );
end;
$fn$;

comment on function public.sync_fx_rate(date, boolean) is
  'Busca la tasa BCV en los espejos configurados, la valida y la persiste. La llama el cron a las 10 AM.';

-- Solo el cron (postgres) y los envoltorios de admin de más abajo.
revoke all on function public.sync_fx_rate(date, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Estado de la tasa
-- ---------------------------------------------------------------------------
-- docs/05-REGLAS-CONFIRMADAS.md §1 pedía "alerta obligatoria si la tasa lleva
-- más de 48 h sin actualizarse en día hábil". Aquí está el dato; el panel lo
-- pinta y el operador lo ve al entrar en Configuración.

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
  last_sync_detail text
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
    last_sync.detail
  from bd
  left join last_rate on true
  left join last_sync on true;
$fn$;

comment on function public.fx_rate_status(text) is
  'Tasa vigente + antigüedad + resultado del último intento de ingesta. La pinta el panel.';

revoke all on function public.fx_rate_status(text) from public, anon;
grant execute on function public.fx_rate_status(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Manos del operador
-- ---------------------------------------------------------------------------

/** Fuerza una ingesta ahora mismo. Cualquier admin: no escribe una tasa a
 *  dedo, solo adelanta el job — lo peor que puede pasar es que no encuentre
 *  nada y quede el intento apuntado en la bitácora. */
create or replace function public.admin_sync_fx_rate()
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor  uuid := auth.uid();
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  v_result := public.sync_fx_rate(null, true);
  perform audit.log(v_actor, 'fx_rate.sync', null, v_result);
  return v_result;
end;
$fn$;

revoke all on function public.admin_sync_fx_rate() from public, anon;
grant execute on function public.admin_sync_fx_rate() to authenticated;

/** Carga la tasa a mano. Válvula de escape para el día en que los espejos
 *  estén todos caídos o el BCV publique un salto que el guardarraíl rechaza.
 *
 *  Solo super_admin, y firmada en la bitácora: quien pueda escribir la tasa
 *  decide cuánto paga —y cuánto cobra— todo el mundo ese día. */
create or replace function public.admin_set_fx_rate(
  p_rate           numeric,
  p_effective_date date default null,
  p_note           text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor     uuid := auth.uid();
  v_effective date := coalesce(p_effective_date, public.helios_business_date(now()));
  v_previous  numeric := public.current_fx_rate('BCV', v_effective);
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super_admin puede cargar la tasa a mano'
      using errcode = '42501';
  end if;

  if p_rate is null or p_rate <= 0 then
    raise exception 'La tasa debe ser positiva' using errcode = '22023';
  end if;

  if v_effective > public.helios_business_date(now()) then
    raise exception 'No se puede cargar la tasa de un día que aún no empezó'
      using errcode = '22023';
  end if;

  perform public.record_fx_rate(p_rate, v_effective, 'BCV');

  insert into public.fx_rate_syncs (source_key, effective_date, status, rate, detail)
  values ('manual', v_effective, 'manual', p_rate,
          coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Carga manual'));

  perform audit.log(v_actor, 'fx_rate.manual', null, jsonb_build_object(
    'rate', p_rate, 'previous', v_previous, 'effective_date', v_effective, 'note', p_note
  ));

  return jsonb_build_object('ok', true, 'rate', p_rate, 'effective_date', v_effective);
end;
$fn$;

revoke all on function public.admin_set_fx_rate(numeric, date, text) from public, anon;
grant execute on function public.admin_set_fx_rate(numeric, date, text) to authenticated;

/** Últimas tasas con el intento de ingesta que las trajo. */
create or replace function public.admin_fx_rate_history(p_limit integer default 30)
returns table (
  effective_date date,
  rate           numeric,
  fetched_at     timestamptz,
  source_key     text,
  sync_status    text,
  sync_detail    text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select
    r.effective_date,
    r.rate,
    r.fetched_at,
    s.source_key,
    s.status,
    s.detail
  from public.exchange_rates r
  left join lateral (
    select fs.source_key, fs.status, fs.detail
    from public.fx_rate_syncs fs
    where fs.effective_date = r.effective_date
      and fs.status in ('ok', 'manual')
    order by fs.created_at desc
    limit 1
  ) s on true
  where r.source = 'BCV'
    and public.is_platform_admin()
  order by r.effective_date desc
  limit least(coalesce(p_limit, 30), 180);
$fn$;

revoke all on function public.admin_fx_rate_history(integer) from public, anon;
grant execute on function public.admin_fx_rate_history(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Cron
-- ---------------------------------------------------------------------------
-- Caracas es UTC−4 todo el año: 10:00 AM local = 14:00 UTC. Va cinco minutos
-- por delante de `helios_process_mora` (14:05) y diez de
-- `helios_scheduled_settlements` (14:10) a propósito — los dos cotizan en
-- bolívares y tienen que ver ya la tasa del día que se abre.
--
-- El reintento cada hora hasta las 6 PM cubre el espejo que tarda en publicar
-- o el que estaba caído a las 10. No cuesta nada: si la tasa del día ya está,
-- `sync_fx_rate` devuelve `skipped` sin salir a la red.

create extension if not exists pg_cron with schema extensions;

select cron.schedule(
  'helios_sync_fx_rate',
  '0 14 * * *',
  $cron$ select public.sync_fx_rate(); $cron$
);

select cron.schedule(
  'helios_sync_fx_rate_retry',
  '20 15-22 * * *',
  $cron$ select public.sync_fx_rate(); $cron$
);

-- ---------------------------------------------------------------------------
-- 8. Primera carga
-- ---------------------------------------------------------------------------
-- La semilla de desarrollo que dejó `20260822051000_fx_rates.sql` (40,00) no
-- es una tasa: es un relleno para que las cotizaciones locales no fallaran. Y
-- es justo la cifra contra la que el guardarraíl mediría la primera tasa de
-- verdad — 784 contra 40 es un salto del 1.860 %, así que la primera ingesta
-- real quedaría rechazada y el sistema se quedaría cobrando a 40 Bs./$ para
-- siempre. Se borra antes de encender el job.
--
-- Es un DELETE seguro: `exchange_rates` no tiene nada que dependa de ella —las
-- cotizaciones ya emitidas guardan su propia `fx_rate` en `payment_quotes`— y
-- 40,00 Bs./$ es una tasa que el BCV dejó atrás hace años.

-- Y se trae la de hoy aquí mismo, sin esperar a las 10 AM de mañana: entre
-- desplegar esto y el primer cron no puede haber ni un minuto sin tasa. Si la
-- red falla, se repone la semilla y se avisa: una tasa mala se arregla en el
-- panel en diez segundos, pero sin ninguna tasa la app no puede ni cotizar un
-- pago.

do $boot$
declare
  v_result jsonb;
begin
  delete from public.exchange_rates where source = 'BCV' and rate = 40.00;

  v_result := public.sync_fx_rate(null, true);

  if not (v_result->>'ok')::boolean
     and not exists (select 1 from public.exchange_rates where source = 'BCV') then
    insert into public.exchange_rates (source, rate, effective_date)
    values ('BCV', 40.00, public.helios_business_date(now()))
    on conflict (source, effective_date) do nothing;

    raise warning 'No se pudo traer la tasa BCV al migrar (%). Se repuso la semilla de 40,00: CÁRGALA A MANO en Configuración → Tasa BCV antes de operar.',
      v_result;
  end if;
end
$boot$;
