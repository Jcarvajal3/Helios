-- ============================================================================
-- Ronda — Facturar y Grupos en tiempo real
--
-- Facturar preguntaba cada 2 s si el cliente ya había pagado, y las pantallas
-- de grupo cada 10-15 s si había entrado alguien. Ahora la base avisa en el
-- momento, por Supabase Realtime (Broadcast desde la base), y el sondeo queda
-- solo como red de seguridad, mucho más lento.
--
-- El aviso NO lleva los datos: dice "cambió algo" y la pantalla vuelve a pedir
-- lo suyo con la misma RPC de siempre. Así el mensaje no puede enseñar nada que
-- la RPC no enseñe, y la regla de quién ve qué sigue en un solo sitio.
--
-- Dos clases de canal, los dos privados:
--
--   · `charge:<id>` — el estado de un cobro, para la tablet que lo sacó. Lo
--     puede escuchar quien puede leer ese cobro con `merchant_charge_status`:
--     el gerente de ese local, o el cajero que lo pidió.
--
--   · `user:<id>` — el canal de cada persona en la app. Cuando cambia un grupo
--     (alguien entra o sale, cambia su aporte, se paga un cobro del grupo), se
--     avisa a cada integrante vivo; como mucho son 5. Así la app escucha UN
--     canal que no depende de qué grupos tenga cargados. Solo lo escucha su
--     dueño.
--
-- Los avisos salen de triggers, dentro de la transacción que cambia el dato:
-- si se deshace, el aviso también. `realtime.send` atrapa sus propios errores
-- (deja un WARNING), así que un fallo de Realtime no puede tumbar un cobro.
--
-- Un pago de grupo toca hasta 5 filas de `group_members` y el cobro; sin
-- freno serían 30 avisos para decir lo mismo. Se avisa una vez por grupo y
-- transacción: los mensajes solo se ven al hacer COMMIT, así que uno basta.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Quién puede escuchar qué
-- ---------------------------------------------------------------------------

create or replace function public.realtime_can_listen(p_topic text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_user uuid := auth.uid();
  v_id   uuid;
begin
  if v_user is null or p_topic is null then
    return false;
  end if;

  if p_topic = 'user:' || v_user::text then
    return true;
  end if;

  if p_topic ~ '^charge:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_id := substr(p_topic, 8)::uuid;
    -- La regla de `merchant_charge_status`, tal cual.
    return exists (
      select 1
      from public.charges c
      where c.id = v_id
        and c.merchant_id in (select public.my_merchant_ids())
        and (c.merchant_id = public.my_merchant_id_as_gerente() or c.requested_by = v_user)
    );
  end if;

  return false;
end;
$fn$;

comment on function public.realtime_can_listen(text) is
  'Si la persona con sesión puede escuchar ese canal de Realtime: el suyo (user:<id>) o el de un cobro que puede leer (charge:<id>).';

-- La evalúa la política de `realtime.messages` con el rol de quien se conecta.
revoke all on function public.realtime_can_listen(text) from public, anon;
grant execute on function public.realtime_can_listen(text) to authenticated;

-- Realtime la evalúa al entrar al canal y la guarda mientras dure la conexión:
-- no se consulta la base por cada mensaje.
drop policy if exists helios_cada_quien_escucha_lo_suyo on realtime.messages;
create policy helios_cada_quien_escucha_lo_suyo
  on realtime.messages
  for select
  to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and public.realtime_can_listen((select realtime.topic()))
  );

-- ---------------------------------------------------------------------------
-- 2. Los avisos
-- ---------------------------------------------------------------------------

-- Avisa a cada integrante vivo del grupo, una vez por transacción. `p_also` es
-- alguien que ya no cuenta como integrante —quien acaba de salir— y también
-- tiene que enterarse.
create or replace function public.realtime_nudge_group(p_group_id uuid, p_also uuid default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_done text := coalesce(current_setting('helios.rt_grupos', true), '');
begin
  if p_group_id is null then
    return;
  end if;

  if position(p_group_id::text in v_done) = 0 then
    perform set_config('helios.rt_grupos', v_done || p_group_id::text || ',', true);

    perform realtime.send(
      jsonb_build_object('kind', 'group', 'group_id', p_group_id),
      'changed',
      'user:' || gm.user_id::text,
      true
    )
    from public.group_members gm
    where gm.group_id = p_group_id
      and gm.left_at is null;
  end if;

  if p_also is not null then
    perform realtime.send(
      jsonb_build_object('kind', 'group', 'group_id', p_group_id),
      'changed',
      'user:' || p_also::text,
      true
    );
  end if;
end;
$fn$;

revoke all on function public.realtime_nudge_group(uuid, uuid) from public, anon, authenticated;

create or replace function public.realtime_on_group_members()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  if tg_op = 'DELETE' then
    perform public.realtime_nudge_group(old.group_id, old.user_id);
  elsif tg_op = 'UPDATE' and old.left_at is null and new.left_at is not null then
    perform public.realtime_nudge_group(new.group_id, new.user_id);
  else
    perform public.realtime_nudge_group(new.group_id);
  end if;
  return null;
end;
$fn$;

revoke all on function public.realtime_on_group_members() from public, anon, authenticated;

drop trigger if exists group_members_realtime on public.group_members;
create trigger group_members_realtime
  after insert or update or delete on public.group_members
  for each row execute function public.realtime_on_group_members();

create or replace function public.realtime_on_groups()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  perform public.realtime_nudge_group(new.id);
  return null;
end;
$fn$;

revoke all on function public.realtime_on_groups() from public, anon, authenticated;

drop trigger if exists groups_realtime on public.groups;
create trigger groups_realtime
  after update on public.groups
  for each row execute function public.realtime_on_groups();

create or replace function public.realtime_on_charges()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    perform realtime.send(
      jsonb_build_object('status', new.status),
      'status',
      'charge:' || new.id::text,
      true
    );
  end if;

  if new.group_id is not null
     and (tg_op = 'INSERT' or new.status is distinct from old.status) then
    perform public.realtime_nudge_group(new.group_id);
  end if;

  return null;
end;
$fn$;

revoke all on function public.realtime_on_charges() from public, anon, authenticated;

drop trigger if exists charges_realtime on public.charges;
create trigger charges_realtime
  after insert or update of status on public.charges
  for each row execute function public.realtime_on_charges();
