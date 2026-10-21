-- ============================================================================
-- Helios — El lector espera antes de reintentar y guarda la captura al fallar
-- (docs/03)
--
-- La primera captura real (2026-10-21) falló por un error del esquema que se
-- le manda al modelo, y enseñó dos cosas más:
--
-- 1. Los tres intentos se gastaron en siete segundos: la misma vuelta del
--    lector volvía a tomar la captura en cuanto `lector_fallo` la devolvía a
--    pendiente. Ahora una captura que falló espera dos minutos antes de
--    volver a tomarse (la recoge el cron de cada minuto).
-- 2. La captura ya estaba en el bucket, pero la lectura no guardó su ruta
--    porque eso solo lo hacía `lector_leido`. `lector_fallo` la recibe
--    también: lo que va al equipo lleva su captura.
-- ============================================================================

drop function if exists public.lector_fallo(uuid, text);

/** No se pudo leer: se reintenta hasta 3 veces (con espera); luego, al equipo. */
create or replace function public.lector_fallo(p_id uuid, p_error text, p_receipt_path text default null)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_r    public.payment_receipt_reads%rowtype;
  v_path text := nullif(btrim(coalesce(p_receipt_path, '')), '');
begin
  select * into v_r from public.payment_receipt_reads where id = p_id for update;
  if not found or v_r.status <> 'leyendo' then
    return v_r.status;
  end if;

  if v_path is not null and not (v_path like '/%' or v_path like '%..%' or length(v_path) > 500) then
    update public.payment_receipt_reads set receipt_path = v_path where id = v_r.id;
  end if;

  if v_r.attempts >= 3 then
    return public.helios_receipt_close(v_r.id,
      case when v_r.mode = 'sombra' then 'sombra' else 'para_el_equipo' end,
      'no_se_pudo_leer', left(p_error, 1000));
  end if;

  update public.payment_receipt_reads
     set status = 'pendiente', error = left(p_error, 1000)
   where id = v_r.id;
  return 'pendiente';
end;
$$;

revoke all on function public.lector_fallo(uuid, text, text) from public, anon, authenticated;
grant execute on function public.lector_fallo(uuid, text, text) to service_role;

/**
 * `lector_tomar` de 20261021200000, con una diferencia: una captura que ya
 * falló no se vuelve a tomar hasta dos minutos después de su último intento.
 */
create or replace function public.lector_tomar(p_limit integer default 3)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id   uuid;
  v_rows jsonb;
begin
  -- Un lector que se cayó a media lectura: se vuelve a intentar, o al
  -- equipo si ya van tres.
  for v_id in
    select id from public.payment_receipt_reads
    where status = 'leyendo' and taken_at < now() - interval '10 minutes'
    for update skip locked
  loop
    perform public.lector_fallo(v_id, 'El lector no respondió en 10 minutos');
  end loop;

  with tomadas as (
    select id from public.payment_receipt_reads
    where status = 'pendiente' and kind = 'captura'
      and (taken_at is null or taken_at < now() - interval '2 minutes')
    order by created_at
    limit greatest(1, least(coalesce(p_limit, 3), 10))
    for update skip locked
  ), hechas as (
    update public.payment_receipt_reads r
       set status = 'leyendo', attempts = r.attempts + 1, taken_at = now()
      from tomadas t
     where r.id = t.id
    returning r.id, r.media_id, r.mime, r.profile_id, r.created_at
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'media_id', media_id, 'mime', mime,
                                               'profile_id', profile_id) order by created_at), '[]'::jsonb)
    into v_rows
  from hechas;

  return v_rows;
end;
$$;

/**
 * `helios_lector_despertar` de 20261021200000, que solo miraba si había
 * alguna pendiente: ahora, alguna que ya se pueda tomar (sin la espera de dos
 * minutos de un reintento), para no despertar al lector en balde.
 */
create or replace function public.helios_lector_despertar()
returns boolean
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_url   text;
  v_clave text;
begin
  if not exists (
    select 1 from public.payment_receipt_reads
    where status = 'pendiente'
      and (taken_at is null or taken_at < now() - interval '2 minutes')
  ) then
    return false;
  end if;

  v_url   := public.helios_vault_secret('lector_url');
  v_clave := public.helios_vault_secret('lector_clave');
  if v_url is null or v_clave is null then
    return false;
  end if;

  begin
    perform extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '3000');
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '5000');
    perform extensions.http((
      'POST', v_url,
      array[extensions.http_header('x-helios-clave', v_clave)],
      'application/json', '{}'
    )::extensions.http_request);
  exception when others then
    raise warning 'lector: no se pudo despertar: %', sqlerrm;
    return false;
  end;
  return true;
end;
$$;
