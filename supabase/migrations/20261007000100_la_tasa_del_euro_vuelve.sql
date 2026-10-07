-- ============================================================================
-- Helios — La tasa BCV del euro vuelve a entrar cada día (Javier, 2026-10-07)
--
-- El médico elige ahora en qué moneda cobra su consulta: dólares o euros
-- (`20261007000200_la_consulta_se_cobra_en_dolares_o_euros`). Una orden en
-- euros se cobra en bolívares con la tasa BCV DEL EURO, así que esa serie,
-- archivada el 2026-09-30 (`20261002000100_el_precio_se_pacta_en_dolares`),
-- vuelve a ser una serie viva:
--
-- 1. **Dos series en `exchange_rates`**: `BCV` (dólar, la moneda del libro)
--    y `BCV_EUR` (euro). Cada espejo de `fx_rate_sources` dice de qué serie
--    es (`series`) y se reactivan los dos del euro.
--
-- 2. **`sync_fx_rate` trae las dos.** El cuerpo de siempre pasa a
--    `helios_sync_fx_series(serie, día, forzar)`, idéntico salvo que la serie
--    deja de estar escrita a fuego. `sync_fx_rate` (lo que llaman el cron y el
--    botón del panel) corre el dólar y luego el euro; un fallo del euro no
--    tumba el del dólar. La respuesta es la de siempre (la del dólar) con el
--    euro dentro, en `eur`.
--
-- 3. **La bitácora de la ingesta sabe de qué serie es** (`fx_rate_syncs.series`)
--    y `fx_rate_status(serie)` mira solo los intentos de esa serie.
--
-- 4. **La carga a mano y el historial aceptan la moneda**:
--    `admin_set_fx_rate(…, p_currency)` y `admin_fx_rate_history(…, p_currency)`.
--
-- 5. **Lectores**: `helios_fx_series`, `helios_fx_rate` (Bs por unidad),
--    `helios_usd_per_unit` (la tasa cruzada que pasa una orden en euros al
--    libro en dólares) y `helios_fx_today()` para el panel y el bot.
--
-- 6. **El dinero en texto**: `helios_currency_symbol`, `helios_money_cur_text`
--    («€56,96») y `helios_ves_text` («Bs 55.432,10»), al estilo venezolano
--    de `helios_money_text`.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Dos series
-- ---------------------------------------------------------------------------

alter table public.fx_rate_sources
  add column if not exists series text not null default 'BCV';

alter table public.fx_rate_sources
  drop constraint if exists fx_rate_sources_series_check;
alter table public.fx_rate_sources
  add constraint fx_rate_sources_series_check check (series in ('BCV', 'BCV_EUR'));

update public.fx_rate_sources
set series    = 'BCV_EUR',
    is_active = true,
    note      = case key
      when 'dolarapi-eur' then 'DolarAPI Venezuela. Republica la tasa oficial del BCV para el euro, con su fecha de vigencia. Para las órdenes cobradas en euros.'
      else 'exchangerate-api con base EUR. Segunda opinión: su VES sigue a la oficial. Actualiza una vez al día. Para las órdenes cobradas en euros.'
    end
where key in ('dolarapi-eur', 'er-api-eur');

comment on table public.fx_rate_sources is
  'Espejos JSON de la tasa oficial del BCV, por serie (`BCV` dólar, `BCV_EUR` euro) y prioridad. Los lee sync_fx_rate().';

comment on table public.exchange_rates is
  'Tasas del BCV. `BCV` es la del DÓLAR, la moneda del libro de Helios. `BCV_EUR` es la del EURO, con la que se cobran en bolívares las órdenes en euros. La ingesta es un job diario (sync_fx_rate) que trae las dos.';

alter table public.fx_rate_syncs
  add column if not exists series text not null default 'BCV';

-- Los intentos de los espejos del euro que ya hay en la bitácora (los de la
-- historia de Ronda) son de la serie del euro.
update public.fx_rate_syncs s
set series = 'BCV_EUR'
from public.fx_rate_sources f
where f.key = s.source_key and f.series = 'BCV_EUR' and s.series <> 'BCV_EUR';

-- ---------------------------------------------------------------------------
-- 2. Lectores
-- ---------------------------------------------------------------------------

/** La serie de `exchange_rates` de una moneda de cobro. */
create or replace function public.helios_fx_series(p_currency text)
returns text
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
begin
  return case upper(coalesce(p_currency, ''))
    when 'USD' then 'BCV'
    when 'EUR' then 'BCV_EUR'
    else null
  end;
end;
$$;

/**
 * Bolívares por una unidad de la moneda, con la tasa BCV vigente ese día (la
 * última publicada hasta esa fecha). Null si no hay ninguna.
 */
create or replace function public.helios_fx_rate(p_currency text, p_as_of date default null)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.current_fx_rate(public.helios_fx_series(p_currency), p_as_of);
$$;

/**
 * Dólares por una unidad de la moneda ese día: 1 para el dólar y, para el
 * euro, la tasa cruzada del BCV (euro en Bs ÷ dólar en Bs), con 6 decimales
 * como toda tasa. Es la que pasa una orden en euros al libro en dólares el día
 * en que se registra. Sin alguna de las dos tasas, error.
 */
create or replace function public.helios_usd_per_unit(p_currency text, p_as_of date default null)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_usd numeric;
  v_cur numeric;
begin
  if public.helios_fx_series(p_currency) is null then
    raise exception 'Moneda no válida: dólares (USD) o euros (EUR)' using errcode = '22023';
  end if;

  if upper(p_currency) = 'USD' then
    return 1;
  end if;

  v_usd := public.helios_fx_rate('USD', p_as_of);
  v_cur := public.helios_fx_rate(p_currency, p_as_of);

  if v_usd is null or v_usd <= 0 or v_cur is null or v_cur <= 0 then
    raise exception 'No hay tasa BCV del % vigente: pídele a Helios que la cargue',
      case upper(p_currency) when 'EUR' then 'euro' else 'dólar' end
      using errcode = 'P0002';
  end if;

  return round(v_cur / v_usd, 6);
end;
$$;

revoke all on function public.helios_usd_per_unit(text, date) from public, anon, authenticated;
revoke all on function public.helios_fx_rate(text, date) from public, anon, authenticated;

/**
 * Las tasas de hoy, para el paso del monto (panel y bot): Bs por dólar, Bs por
 * euro y la cruzada. Las tasas del BCV son públicas; lo que no se expone es
 * nada de la base. Para cualquiera con sesión.
 */
create or replace function public.helios_fx_today()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy date := public.helios_business_date(now());
  v_usd record;
  v_eur record;
begin
  if auth.uid() is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select r.rate, r.effective_date into v_usd
  from public.exchange_rates r
  where r.source = 'BCV' and r.effective_date <= v_hoy
  order by r.effective_date desc limit 1;

  select r.rate, r.effective_date into v_eur
  from public.exchange_rates r
  where r.source = 'BCV_EUR' and r.effective_date <= v_hoy
  order by r.effective_date desc limit 1;

  return jsonb_build_object(
    'business_date', v_hoy,
    'usd', case when v_usd.rate is not null then
      jsonb_build_object('rate', v_usd.rate, 'effective_date', v_usd.effective_date) end,
    'eur', case when v_eur.rate is not null then
      jsonb_build_object('rate', v_eur.rate, 'effective_date', v_eur.effective_date) end,
    'usd_per_eur', case when v_usd.rate > 0 and v_eur.rate > 0
                        then round(v_eur.rate / v_usd.rate, 6) end
  );
end;
$$;

revoke all on function public.helios_fx_today() from public, anon;
grant execute on function public.helios_fx_today() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El dinero en texto
-- ---------------------------------------------------------------------------

create or replace function public.helios_currency_symbol(p_currency text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case upper(coalesce(p_currency, 'USD')) when 'EUR' then '€' else '$' end;
$$;

/** «$100», «€56,96», «€1.250,50»: el símbolo de la moneda pegado al monto. */
create or replace function public.helios_money_cur_text(p_amount numeric, p_currency text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select public.helios_currency_symbol(p_currency) || public.helios_money_text(p_amount);
$$;

/** «Bs 55.432,10»: los bolívares siempre con sus dos decimales. */
create or replace function public.helios_ves_text(p_amount_ves numeric)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select 'Bs ' || translate(to_char(round(coalesce(p_amount_ves, 0), 2), 'FM999,999,999,990.00'), ',.', '.,');
$$;

-- ---------------------------------------------------------------------------
-- 4. La ingesta, por serie
-- ---------------------------------------------------------------------------

/**
 * El cuerpo de siempre de `sync_fx_rate`, con la serie como parámetro: busca
 * la tasa de esa serie en sus espejos, la valida contra la anterior DE LA
 * MISMA SERIE y la guarda.
 */
create or replace function public.helios_sync_fx_series(
  p_series         text,
  p_effective_date date default null,
  p_force          boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
  if p_series not in ('BCV', 'BCV_EUR') then
    raise exception 'Serie de tasas no válida: %', p_series using errcode = '22023';
  end if;

  -- Tasa contra la que se compara el salto: la última ANTERIOR al día que se
  -- está cargando. Si se comparase contra la del propio día, un reintento
  -- forzado se estaría midiendo contra sí mismo.
  select rate into v_previous
  from public.exchange_rates
  where source = p_series and effective_date < v_effective
  order by effective_date desc
  limit 1;

  -- Ya hay tasa para este día operativo: no se vuelve a pedir. Esto es lo que
  -- hace que los reintentos horarios sean gratis.
  if not p_force and exists (
    select 1 from public.exchange_rates
    where source = p_series and effective_date = v_effective
  ) then
    return jsonb_build_object(
      'ok', true, 'skipped', true, 'series', p_series, 'effective_date', v_effective,
      'rate', public.current_fx_rate(p_series, v_effective)
    );
  end if;

  -- Sin tope de tiempo, un espejo que acepta la conexión y no contesta nunca
  -- deja colgado al worker del cron.
  begin
    perform extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '4000');
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
  exception when others then
    null;
  end;

  for v_src in
    select * from public.fx_rate_sources where is_active and series = p_series order by priority
  loop
    v_tried     := v_tried + 1;
    v_status    := null;
    v_body      := null;
    v_payload   := null;
    v_rate      := null;
    v_published := null;
    v_failed    := false;

    -- --- Pedir -------------------------------------------------------------
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
      insert into public.fx_rate_syncs (source_key, series, effective_date, status, detail)
      values (v_src.key, p_series, v_effective, 'network_error', left(sqlerrm, 500));
      v_failed := true;
    end;

    if v_failed then
      continue;
    end if;

    if v_status is distinct from 200 then
      insert into public.fx_rate_syncs (source_key, series, effective_date, status, http_status, detail)
      values (v_src.key, p_series, v_effective, 'http_error', v_status, left(coalesce(v_body, ''), 500));
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
        (source_key, series, effective_date, status, http_status, detail, payload)
      values (v_src.key, p_series, v_effective, 'parse_error', v_status, left(sqlerrm, 500), v_payload);
      v_failed := true;
    end;

    if v_failed then
      continue;
    end if;

    -- --- Validar -----------------------------------------------------------
    v_reject := public.fx_rate_rejection(v_rate, v_previous, v_published, v_effective);

    if v_reject is not null then
      insert into public.fx_rate_syncs
        (source_key, series, effective_date, status, http_status, rate, published_at, detail, payload)
      values (v_src.key, p_series, v_effective, 'rejected', v_status, v_rate, v_published,
              v_reject, v_payload);
      continue;
    end if;

    -- --- Guardar -----------------------------------------------------------
    perform public.record_fx_rate(v_rate, v_effective, p_series);

    insert into public.fx_rate_syncs
      (source_key, series, effective_date, status, http_status, rate, published_at, payload)
    values (v_src.key, p_series, v_effective, 'ok', v_status, v_rate, v_published, v_payload);

    -- La bitácora vieja no sirve para nada y esta tabla crece todos los días.
    delete from public.fx_rate_syncs where created_at < now() - interval '90 days';

    return jsonb_build_object(
      'ok', true, 'skipped', false, 'series', p_series, 'source', v_src.key,
      'rate', v_rate, 'effective_date', v_effective, 'published_at', v_published
    );
  end loop;

  -- Ninguna fuente sirvió. No se escribe nada: sigue vigente la última tasa
  -- buena y `fx_rate_status()` empieza a avisar de que está vieja.
  insert into public.fx_rate_syncs (series, effective_date, status, detail)
  values (p_series, v_effective, case when v_tried = 0 then 'no_source' else 'rejected' end,
          format('%s fuente(s) intentadas, ninguna válida', v_tried));

  return jsonb_build_object(
    'ok', false, 'skipped', false, 'series', p_series, 'effective_date', v_effective,
    'sources_tried', v_tried, 'rate', v_previous
  );
end;
$$;

revoke all on function public.helios_sync_fx_series(text, date, boolean) from public, anon, authenticated;

/**
 * La ingesta diaria: el dólar y el euro. Devuelve lo de siempre (el dólar,
 * que es la del libro) con el euro en `eur`. Un error del euro queda en su
 * propia respuesta y no deshace el dólar.
 */
create or replace function public.sync_fx_rate(p_effective_date date default null, p_force boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_usd jsonb;
  v_eur jsonb;
begin
  v_usd := public.helios_sync_fx_series('BCV', p_effective_date, p_force);

  begin
    v_eur := public.helios_sync_fx_series('BCV_EUR', p_effective_date, p_force);
  exception when others then
    v_eur := jsonb_build_object('ok', false, 'series', 'BCV_EUR', 'error', left(sqlerrm, 300));
  end;

  return v_usd || jsonb_build_object('eur', v_eur);
end;
$$;

comment on function public.sync_fx_rate(date, boolean) is
  'Busca las tasas BCV del dólar y del euro en los espejos configurados, las valida y las persiste. La llama el cron cada mañana y sus reintentos.';

-- `fx_rate_status`: la misma lectura de siempre, con los intentos de su serie.
create or replace function public.fx_rate_status(p_source text default 'BCV')
returns table(
  rate numeric, effective_date date, fetched_at timestamptz, business_date date,
  is_current boolean, age_hours numeric, is_stale boolean, last_sync_at timestamptz,
  last_sync_status text, last_sync_detail text, business_days_behind integer,
  today_is_holiday boolean, holiday_name text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
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
    where s.series = p_source
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
    -- Vieja de verdad: más de 48 h sin que entre una tasa nueva.
    now() - last_rate.fetched_at > interval '48 hours',
    last_sync.created_at,
    last_sync.status,
    last_sync.detail,
    public.helios_business_days_between(last_rate.effective_date, bd.d),
    not public.helios_is_business_day(bd.d),
    (select h.name from public.holidays h where h.day = bd.d)
  from bd
  left join last_rate on true
  left join last_sync on true;
$$;

-- ---------------------------------------------------------------------------
-- 5. La carga a mano y el historial, por moneda
-- ---------------------------------------------------------------------------

drop function if exists public.admin_set_fx_rate(numeric, date, text);

create or replace function public.admin_set_fx_rate(
  p_rate           numeric,
  p_effective_date date default null,
  p_note           text default null,
  p_currency       text default 'USD'
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor     uuid := auth.uid();
  v_series    text := public.helios_fx_series(p_currency);
  v_effective date := coalesce(p_effective_date, public.helios_business_date(now()));
  v_previous  numeric;
begin
  perform public.helios_assert_super_admin('cargar la tasa a mano');

  if v_series is null then
    raise exception 'Moneda no válida: dólares (USD) o euros (EUR)' using errcode = '22023';
  end if;

  if p_rate is null or p_rate <= 0 then
    raise exception 'La tasa debe ser positiva' using errcode = '22023';
  end if;

  if v_effective > public.helios_business_date(now()) then
    raise exception 'No se puede cargar la tasa de un día que aún no empezó'
      using errcode = '22023';
  end if;

  v_previous := public.current_fx_rate(v_series, v_effective);

  perform public.record_fx_rate(p_rate, v_effective, v_series);

  insert into public.fx_rate_syncs (source_key, series, effective_date, status, rate, detail)
  values ('manual', v_series, v_effective, 'manual', p_rate,
          coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Carga manual'));

  perform audit.log(v_actor, 'fx_rate.manual', null, jsonb_build_object(
    'currency', upper(p_currency), 'series', v_series,
    'rate', p_rate, 'previous', v_previous, 'effective_date', v_effective, 'note', p_note
  ));

  return jsonb_build_object('ok', true, 'currency', upper(p_currency), 'rate', p_rate,
                            'effective_date', v_effective);
end;
$$;

revoke all on function public.admin_set_fx_rate(numeric, date, text, text) from public, anon;
grant execute on function public.admin_set_fx_rate(numeric, date, text, text) to authenticated;

drop function if exists public.admin_fx_rate_history(integer);

create or replace function public.admin_fx_rate_history(p_limit integer default 30, p_currency text default 'USD')
returns table(effective_date date, rate numeric, fetched_at timestamptz, source_key text,
              sync_status text, sync_detail text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
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
      and fs.series = r.source
      and fs.status in ('ok', 'manual')
    order by fs.created_at desc
    limit 1
  ) s on true
  where r.source = public.helios_fx_series(p_currency)
    and public.is_platform_admin()
  order by r.effective_date desc
  limit least(coalesce(p_limit, 30), 180);
$$;

revoke all on function public.admin_fx_rate_history(integer, text) from public, anon;
grant execute on function public.admin_fx_rate_history(integer, text) to authenticated;
