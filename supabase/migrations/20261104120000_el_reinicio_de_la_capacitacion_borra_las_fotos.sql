-- ============================================================================
-- Helios — El reinicio de la capacitación borra las fotos de las cédulas
-- (Javier, 2026-11-04; docs/00 §15.11)
--
-- 20261102233000 dejó `patient_id_photos` apuntando a `profiles` y a `charges`
-- sin que `helios_demo_purge` la mirara: en cuanto un paciente de capacitación
-- enviaba su foto, el reinicio fallaba con 23503, y el de medianoche, que va
-- con todos los números a la vez, también.
--
--  1. `helios_demo_purge` borra las filas de esas fotos antes que las órdenes.
--  2. El archivo no se puede borrar desde SQL (`storage.protect_delete`): su
--     ruta queda en `patient_id_photo_removals` y el lector de comprobantes
--     la borra con la API de Storage. Lo despierta el cron de cada minuto.
--  3. Si el lector estaba subiendo una foto mientras se reiniciaba,
--     `lector_cedula_guardada` le dice que ya no existe y la borra él mismo.
-- ============================================================================

create table if not exists public.patient_id_photo_removals (
  id            uuid primary key default gen_random_uuid(),
  storage_path  text not null unique,
  requested_at  timestamptz not null default now(),
  -- Cuándo la tomó un lector: a los 2 minutos sin confirmar, se vuelve a tomar.
  taken_at      timestamptz
);

comment on table public.patient_id_photo_removals is
  'Archivos del bucket `patient-ids` por borrar con la API de Storage: las fotos de los pacientes de capacitación que borró el reinicio (docs/00 §15.11).';

alter table public.patient_id_photo_removals enable row level security;
revoke all on public.patient_id_photo_removals from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. El reinicio
-- ---------------------------------------------------------------------------

-- Igual que la versión en la base (20261014100300), con las fotos.
create or replace function public.helios_demo_purge(p_phone text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_perfiles uuid[];
  v_ordenes  uuid[];
  v_cuotas   uuid[];
  v_claves   text[];
  v_n_ord    integer;
begin
  select coalesce(array_agg(p.id), '{}')
    into v_perfiles
  from public.profiles p
  where p.is_demo
    and (p_phone is null or p.phone_e164 = p_phone)
    -- Nada en el libro.
    and not exists (select 1 from ledger.accounts a where a.owner_id = p.id)
    and not exists (select 1 from public.charges c
                    join ledger.transactions t on t.reference_id = c.id
                    where c.user_id = p.id)
    -- Nada de dinero de verdad.
    and not exists (select 1 from public.installments i where i.user_id = p.id and i.status = 'paid')
    and not exists (select 1 from public.payment_reports r where r.user_id = p.id)
    and not exists (select 1 from public.settlements s
                    join public.charges c on c.id = s.charge_id
                    where c.user_id = p.id);

  if cardinality(v_perfiles) = 0 then
    return jsonb_build_object('borrados', 0, 'ordenes_borradas', 0);
  end if;

  select coalesce(array_agg(c.id), '{}') into v_ordenes
  from public.charges c where c.user_id = any(v_perfiles);

  select coalesce(array_agg(i.id), '{}') into v_cuotas
  from public.installments i
  where i.charge_id = any(v_ordenes) or i.user_id = any(v_perfiles);

  select coalesce(array_agg(p.document_key), '{}') into v_claves
  from public.profiles p
  where p.id = any(v_perfiles) and p.document_key is not null
    -- Una cédula que también es de alguien que se queda conserva sus consultas.
    and not exists (select 1 from public.profiles q
                    where q.document_key = p.document_key and not (q.id = any(v_perfiles)));

  -- El bot del médico que recordaba una de esas órdenes vuelve al menú.
  update public.whatsapp_sessions s
     set state = 'menu', data = '{}'::jsonb, updated_at = now()
   where exists (select 1 from unnest(v_ordenes) o where s.data::text like '%' || o::text || '%')
      or exists (select 1 from unnest(v_perfiles) p where s.data::text like '%' || p::text || '%');

  -- NUEVO (2026-11-04): las fotos de sus cédulas. El archivo lo borra el
  -- lector con la API de Storage: desde SQL no se puede.
  insert into public.patient_id_photo_removals (storage_path)
  select f.storage_path from public.patient_id_photos f where f.profile_id = any(v_perfiles)
  on conflict (storage_path) do nothing;
  delete from public.patient_id_photos where profile_id = any(v_perfiles);

  -- De las hojas a la raíz.
  delete from public.payment_quotes where user_id = any(v_perfiles);   -- sus líneas y cargos, en cascada
  delete from public.late_fees where user_id = any(v_perfiles) or installment_id = any(v_cuotas);
  delete from public.staff_commissions where charge_id = any(v_ordenes);
  delete from public.installments where id = any(v_cuotas);
  delete from public.outbound_messages where charge_id = any(v_ordenes) or profile_id = any(v_perfiles);
  delete from public.charges where id = any(v_ordenes);                -- sus líneas, en cascada
  get diagnostics v_n_ord = row_count;

  delete from public.notifications where user_id = any(v_perfiles);
  delete from public.user_credit_blocks where user_id = any(v_perfiles);
  delete from public.user_blocks where user_id = any(v_perfiles);
  delete from public.level_changes where user_id = any(v_perfiles);
  delete from public.profile_change_requests where profile_id = any(v_perfiles);
  update public.whatsapp_contacts set profile_id = null where profile_id = any(v_perfiles);
  update public.whatsapp_contacts set patient_profile_id = null where patient_profile_id = any(v_perfiles);
  update public.demo_resets set user_id = null where user_id = any(v_perfiles);
  delete from public.eligibility_lookups where document_key = any(v_claves);

  delete from public.profiles where id = any(v_perfiles);              -- collection_contacts, en cascada

  return jsonb_build_object('borrados', cardinality(v_perfiles), 'ordenes_borradas', v_n_ord);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. El lector: los archivos por borrar
-- ---------------------------------------------------------------------------

/** La siguiente tanda de archivos por borrar: `[{id, ruta}]`. */
create or replace function public.lector_cedula_por_borrar(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  with tomadas as (
    select id from public.patient_id_photo_removals
    where taken_at is null or taken_at < now() - interval '2 minutes'
    order by requested_at
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    for update skip locked
  ), hechas as (
    update public.patient_id_photo_removals r
       set taken_at = now()
      from tomadas t
     where r.id = t.id
    returning r.id, r.storage_path
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'ruta', storage_path)), '[]'::jsonb)
    into v_rows
  from hechas;

  return v_rows;
end;
$$;

/** Esos archivos ya no están en el bucket: no queda rastro de ellos. */
create or replace function public.lector_cedula_borrada(p_ids uuid[])
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  delete from public.patient_id_photo_removals where id = any(p_ids);
$$;

revoke all on function public.lector_cedula_por_borrar(integer) from public, anon, authenticated;
revoke all on function public.lector_cedula_borrada(uuid[]) from public, anon, authenticated;
grant execute on function public.lector_cedula_por_borrar(integer) to service_role;
grant execute on function public.lector_cedula_borrada(uuid[]) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Una foto que el reinicio borró mientras se subía
-- ---------------------------------------------------------------------------

drop function if exists public.lector_cedula_guardada(uuid);

/**
 * La foto ya está en el bucket: el siguiente intento no la vuelve a bajar.
 * False si su fila ya no existe (la borró el reinicio de la capacitación): el
 * lector borra lo que acaba de subir y no la lee.
 */
create function public.lector_cedula_guardada(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.patient_id_photos set stored_at = coalesce(stored_at, now()) where id = p_id;
  return found;
end;
$$;

revoke all on function public.lector_cedula_guardada(uuid) from public, anon, authenticated;
grant execute on function public.lector_cedula_guardada(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 4. El lector se despierta también por un archivo por borrar
-- ---------------------------------------------------------------------------

-- Igual que 20261102233000, con la tercera cola.
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
  ) and not exists (
    select 1 from public.patient_id_photos
    where status = 'pendiente'
      and (taken_at is null or taken_at < now() - interval '2 minutes')
  ) and not exists (
    select 1 from public.patient_id_photo_removals
    where taken_at is null or taken_at < now() - interval '2 minutes'
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
