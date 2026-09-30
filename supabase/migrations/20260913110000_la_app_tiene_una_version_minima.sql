-- ============================================================================
-- Ronda — La versión mínima de la app
--
-- El tercer freno, después del mantenimiento global y del bloqueo manual
-- (20260909160000). Los dos primeros apagan lo que hace el servidor; este
-- apaga **la app que tiene el usuario instalada**, que hasta ahora era la
-- única pieza del sistema sobre la que no se podía hacer nada.
--
-- ---------------------------------------------------------------------------
-- Por qué hace falta
-- ---------------------------------------------------------------------------
-- Con `expo-updates` ya se empuja JavaScript sin pasar por la tienda, y eso
-- cubre casi todo. Lo que NO cubre es nativo: subir de SDK, cambiar el SDK de
-- Didit, tocar permisos, añadir Skia. Para eso hay que publicar un binario
-- nuevo — y publicar un binario no obliga a nadie a instalarlo.
--
-- Ni Apple ni Google tienen una palanca de "esta versión ya no vale". Play
-- tiene actualizaciones dentro de la app, pero es solo Android y solo para lo
-- instalado desde Play; nuestras builds de preview son APK sueltos. O sea que
-- la única forma de tener esta palanca es tenerla nosotros: la app pregunta
-- "¿sirvo todavía?" y el servidor contesta.
--
-- ---------------------------------------------------------------------------
-- Tres estados, y el bloqueo es el raro
-- ---------------------------------------------------------------------------
--   ok        Nada que decir. La respuesta del 99 % de los arranques.
--   suggest   Hay una versión nueva. Aviso descartable, la app funciona.
--   force     Esta build no puede seguir. Pantalla sin salida.
--
-- El estado normal de una actualización es `suggest`, y esto es deliberado.
-- Ronda es dinero en la calle: si a alguien se le tapia la app en la caja de
-- un local por una actualización cosmética, se le ha roto el pago delante del
-- cajero, y la tienda tarda minutos en descargar. Ese daño es inmediato y
-- real; el de no tener la última versión casi nunca lo es.
--
-- `force` se reserva para tres motivos, y conviene escribirlos para poder
-- decir que no cuando alguien pida el cuarto:
--
--   · un fallo de seguridad en la build vieja,
--   · un cambio de servidor que la build vieja ya no sabe hablar,
--   · un bug que mueve dinero mal (una mora, un cobro, un saldo).
--
-- ---------------------------------------------------------------------------
-- Se compara el BUILD, no la versión
-- ---------------------------------------------------------------------------
-- `version` en app.json lleva en "0.1.0" desde el primer día y nadie lo sube.
-- Comparar semver contra un número que nunca se mueve es un gate que no
-- bloquea nunca: parece que funciona y no hace nada.
--
-- Lo que sí se mueve es el `versionCode` de Android y el `buildNumber` de iOS,
-- porque `eas.json` los lleva en remoto con `autoIncrement`. Es un entero, es
-- monótono, y la app lo lee del binario con `expo-application` — no de la
-- config de JS, que una actualización OTA podría haber cambiado por debajo.
--
-- Los dos números son independientes entre plataformas: iOS puede ir por el
-- 40 y Android por el 55. Por eso la tabla tiene una fila por plataforma y no
-- una sola como `platform_maintenance`.
--
-- ---------------------------------------------------------------------------
-- Dos pares de textos, y no es por gusto
-- ---------------------------------------------------------------------------
-- `title`/`message` para el aviso y `force_title`/`force_message` para el
-- bloqueo. Parece duplicado hasta que se mira quién los lee: con min_build=40
-- y latest_build=55, **el mismo registro está contestando las dos cosas a la
-- vez** — `force` a quien va por el 38 y `suggest` a quien va por el 50. Un
-- solo par de textos no puede servir a los dos.
--
-- Y además: el texto del bloqueo se escribe ANTES, con calma. Tenerlo que
-- redactar la noche en que hay que echar el freno es tenerlo que redactar en
-- el peor momento posible.
--
-- ---------------------------------------------------------------------------
-- Lo lee `anon`, y eso es el punto
-- ---------------------------------------------------------------------------
-- `helios_maintenance()` es solo para quien tiene sesión. Este no puede serlo:
-- el gate corre ANTES del login. Si alguien no puede entrar porque su build es
-- vieja, pedirle sesión para averiguarlo es pedirle justo lo que no puede
-- hacer. Y el dato no es secreto: es el número de versión de una app pública.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La tabla
-- ---------------------------------------------------------------------------

create table if not exists public.app_release (
  platform      text primary key check (platform in ('ios', 'android')),

  -- Por debajo de esto se bloquea. 0 = el gate está dormido, que es como nace.
  min_build     integer not null default 0 check (min_build >= 0),
  -- La última publicada. Entre min y latest, solo se sugiere.
  latest_build  integer not null default 0 check (latest_build >= 0),

  -- El aviso descartable.
  title         text not null default 'Hay una versión nueva',
  message       text not null default
    'Actualiza cuando puedas para tener las últimas mejoras.',

  -- El bloqueo. Se escribe con tiempo y se usa casi nunca.
  force_title   text not null default 'Toca actualizar',
  force_message text not null default
    'Esta versión de Helios ya no puede operar. Actualízala para volver a usar tu saldo.',

  store_url     text not null,
  updated_by    uuid references auth.users (id),
  updated_at    timestamptz not null default now(),

  /**
   * EL SEGURO CONTRA TAPIAR A TODO EL MUNDO.
   *
   * Un `min_build` por encima de la última build publicada bloquea a
   * absolutamente todos los usuarios, incluidos los que acaban de actualizar
   * — y la salida que les ofrece la pantalla, ir a la tienda, no arregla nada
   * porque en la tienda está la versión que tampoco vale. El único remedio
   * sería tocar la base a mano con la app caída.
   *
   * `latest_build` es lo más cercano a "lo que hay publicado" que la base
   * puede saber, así que es el techo. No es infalible —alguien puede subir
   * los dos números a la vez— pero convierte el error de un dedo en un error
   * que hay que cometer dos veces.
   */
  constraint app_release_min_no_pasa_de_latest check (min_build <= latest_build)
);

comment on table public.app_release is
  'Version minima y ultima publicada, por plataforma. Gobierna el gate de actualizacion de la app. Ver la migracion 20260913110000.';

comment on column public.app_release.min_build is
  'Por debajo de este build la app se bloquea. 0 = gate dormido.';
comment on column public.app_release.latest_build is
  'Ultima build publicada en la tienda. Entre min y latest solo se sugiere actualizar.';

insert into public.app_release (platform, store_url) values
  ('ios',     'https://apps.apple.com/app/id6808287513'),
  ('android', 'https://play.google.com/store/apps/details?id=app.ronda')
on conflict (platform) do nothing;

-- Sin políticas: aquí no entra nadie por PostgREST. Se lee por la RPC de
-- abajo, que es `security definer`, y se escribe por la del super admin.
alter table public.app_release enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Lo que pregunta la app
-- ---------------------------------------------------------------------------

/**
 * ¿Sirve todavía esta build?
 *
 * Contesta siempre algo, y ante cualquier duda contesta `ok`:
 *
 *   · Plataforma que no está en la tabla (web, un simulador raro) → ok.
 *   · Build desconocido o cero → ok. `Application.nativeBuildVersion` es null
 *     en algunos entornos de desarrollo, y tratar "no lo sé" como "eres
 *     viejísimo" bloquearía justo a quien está depurando.
 *
 * La app hace lo mismo por su lado cuando esta llamada falla (ver
 * `features/update/gate.ts`): un gate que falla cerrado convierte un hipo de
 * red en una app tapiada para todo el mundo a la vez, y eso es un incidente
 * peor que el que el gate venía a resolver.
 */
create or replace function public.helios_app_gate(
  p_platform text,
  p_build    integer
)
returns jsonb
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce(
    (
      select case
        when coalesce(p_build, 0) <= 0 then
          jsonb_build_object('status', 'ok')

        when p_build < r.min_build then
          jsonb_build_object(
            'status',       'force',
            'title',        r.force_title,
            'message',      r.force_message,
            'store_url',    r.store_url,
            'latest_build', r.latest_build
          )

        when p_build < r.latest_build then
          jsonb_build_object(
            'status',       'suggest',
            'title',        r.title,
            'message',      r.message,
            'store_url',    r.store_url,
            'latest_build', r.latest_build
          )

        else
          jsonb_build_object('status', 'ok', 'latest_build', r.latest_build)
      end
      from public.app_release r
      where r.platform = p_platform
    ),
    jsonb_build_object('status', 'ok')
  );
$$;

comment on function public.helios_app_gate(text, integer) is
  'Dice si una build puede seguir: ok / suggest / force. Ante cualquier duda, ok.';

revoke all on function public.helios_app_gate(text, integer) from public;
-- `anon` también: el gate corre antes del login.
grant execute on function public.helios_app_gate(text, integer) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Lo que ve y mueve el super admin
-- ---------------------------------------------------------------------------

/** Las dos filas, para la pantalla de Ajustes. */
create or replace function public.helios_app_releases()
returns jsonb
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.platform), '[]'::jsonb)
  from public.app_release r;
$$;

revoke all on function public.helios_app_releases() from public, anon;
grant execute on function public.helios_app_releases() to authenticated;

/**
 * Mueve los números y los textos de una plataforma.
 *
 * Sube `latest_build` después de publicar en la tienda: con eso solo se
 * sugiere, y es lo que se hace en el 95 % de las versiones. Subir `min_build`
 * es el freno de verdad y pide un motivo, que queda en la bitácora — no
 * porque haga falta técnicamente, sino porque obliga a escribir en una línea
 * por qué se está tapiando a gente, y hay motivos que no sobreviven a tener
 * que escribirlos.
 */
create or replace function public.admin_set_app_release(
  p_platform      text,
  p_min_build     integer,
  p_latest_build  integer,
  p_title         text default null,
  p_message       text default null,
  p_force_title   text default null,
  p_force_message text default null,
  p_store_url     text default null,
  p_reason        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('cambiar la versión mínima de la app');
  v_before public.app_release%rowtype;
begin
  select * into v_before from public.app_release where platform = p_platform;

  if not found then
    raise exception 'No existe la plataforma %', p_platform using errcode = '22023';
  end if;

  if p_min_build > p_latest_build then
    raise exception
      'La versión mínima (%) no puede pasar de la última publicada (%): bloquearía a todo el mundo, incluido a quien acabe de actualizar',
      p_min_build, p_latest_build
      using errcode = '22023';
  end if;

  -- Tapiar gente se explica. El resto —subir `latest_build` al publicar— no
  -- tiene por qué.
  if p_min_build > coalesce(v_before.min_build, 0)
     and (p_reason is null or length(trim(p_reason)) < 10) then
    raise exception 'Escribe por qué se bloquea a quien no actualice'
      using errcode = '22023';
  end if;

  update public.app_release set
    min_build     = p_min_build,
    latest_build  = p_latest_build,
    title         = coalesce(nullif(trim(coalesce(p_title, '')), ''), title),
    message       = coalesce(nullif(trim(coalesce(p_message, '')), ''), message),
    force_title   = coalesce(nullif(trim(coalesce(p_force_title, '')), ''), force_title),
    force_message = coalesce(nullif(trim(coalesce(p_force_message, '')), ''), force_message),
    store_url     = coalesce(nullif(trim(coalesce(p_store_url, '')), ''), store_url),
    updated_by    = v_actor,
    updated_at    = now()
  where platform = p_platform;

  perform audit.log(
    v_actor,
    case
      when p_min_build > v_before.min_build then 'app_release.block'
      else 'app_release.set'
    end,
    null,
    jsonb_build_object(
      'platform', p_platform,
      'before', jsonb_build_object(
        'min_build', v_before.min_build,
        'latest_build', v_before.latest_build
      ),
      'after', jsonb_build_object(
        'min_build', p_min_build,
        'latest_build', p_latest_build
      ),
      'reason', nullif(trim(coalesce(p_reason, '')), '')
    )
  );

  return public.helios_app_releases();
end;
$$;

revoke all on function public.admin_set_app_release(
  text, integer, integer, text, text, text, text, text, text
) from public, anon;
grant execute on function public.admin_set_app_release(
  text, integer, integer, text, text, text, text, text, text
) to authenticated;
