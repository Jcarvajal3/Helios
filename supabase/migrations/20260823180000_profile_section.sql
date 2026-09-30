-- ============================================================================
-- Ronda — La sección de Perfil
--
-- Tres cosas que el perfil necesita y que hoy no existen en la base:
--
--   1. HISTORIAL DE COMPRAS. `fetchOrders` lee `installments` y sube al cobro
--      por el join anidado, pero la política de `charges` solo deja ver las
--      filas donde `user_id = auth.uid()` — y en un cobro de grupo ese campo
--      es de QUIEN ESCANEÓ, no de cada deudor (ver 20260822140000, comentario
--      de charges.user_id). Resultado: a los demás integrantes el comercio y
--      la fecha les salen en blanco. `my_purchases` resuelve por el lado
--      correcto —"los cobros donde YO tengo cuotas"— y de paso trae el
--      reparto del grupo.
--
--   2. MÉTODOS DE PAGO GUARDADOS. Reportar un pago pide banco, cédula y
--      teléfono cada vez (metodo-pago.tsx). Son siempre los mismos y
--      teclearlos mal es la primera causa de que una conciliación no cuadre.
--
--   3. SINCRONIZAR EL TELÉFONO. Cambiar el número lo hace GoTrue sobre
--      `auth.users`; `profiles.phone_e164` es una copia que nadie actualiza.
--      Sin esto, el perfil enseñaría para siempre el número viejo.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Historial de compras
-- ---------------------------------------------------------------------------

/**
 * Los consumos del usuario, del más reciente al más antiguo.
 *
 * Devuelve MI parte, no la de la mesa: en un cobro de grupo `total_usd` es la
 * cuenta entera y `my_usd` lo que me tocó. Las dos hacen falta — "pagué $20
 * de una cuenta de $80 entre 4" es la frase que la pantalla tiene que poder
 * escribir.
 *
 * Es SECURITY DEFINER para poder leer el cobro y sus líneas de un consumo de
 * grupo que inició otra persona. El filtro es siempre "tengo cuotas en él",
 * así que no abre nada que no fuera ya mío.
 */
create or replace function public.my_purchases(p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $fn$
declare
  v_user uuid := auth.uid();
  v_rows jsonb;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.confirmed_at desc), '[]'::jsonb)
    into v_rows
  from (
    select
      c.id                                   as charge_id,
      c.order_number,
      m.name                                 as merchant_name,
      b.name                                 as branch_name,
      c.business_date,
      c.confirmed_at,
      c.status::text                         as status,
      c.amount_usd                           as total_usd,
      mine.my_usd,
      mine.paid_usd,
      mine.pending_usd,
      mine.installments,
      -- El grupo puede haberse cerrado o renombrado después; lo que importa
      -- para el historial es si el consumo se repartió, y entre cuántos.
      (c.group_id is not null)               as is_group,
      g.name                                 as group_name,
      split.people                           as split_between,
      (c.user_id = v_user)                   as i_started_it,
      items.lines                            as items
    from public.charges c
    join public.merchants m on m.id = c.merchant_id
    left join public.merchant_branches b on b.id = c.branch_id
    left join public.groups g on g.id = c.group_id
    join lateral (
      select
        sum(i.amount_usd)                                                  as my_usd,
        coalesce(sum(i.amount_usd) filter (where i.status = 'paid'), 0)     as paid_usd,
        coalesce(sum(i.amount_usd) filter (where i.status = 'pending'), 0)  as pending_usd,
        jsonb_agg(
          jsonb_build_object(
            'id', i.id,
            'sequence', i.sequence,
            'amount_usd', i.amount_usd,
            'due_date', i.due_date,
            'status', i.status,
            'paid_at', i.paid_at
          ) order by i.sequence
        ) as installments
      from public.installments i
      where i.charge_id = c.id and i.user_id = v_user
    ) mine on mine.my_usd is not null
    join lateral (
      select count(distinct i2.user_id) as people
      from public.installments i2
      where i2.charge_id = c.id
    ) split on true
    left join lateral (
      select jsonb_agg(
        jsonb_build_object(
          'name', ci.name,
          'quantity', ci.quantity,
          'unit_price_usd', ci.unit_price_usd,
          'line_total_usd', ci.line_total_usd
        ) order by ci.position, ci.created_at
      ) as lines
      from public.charge_items ci
      where ci.charge_id = c.id
    ) items on true
    order by c.confirmed_at desc
    limit p_limit
  ) q;

  return v_rows;
end;
$fn$;

revoke all on function public.my_purchases(integer) from public, anon;
grant execute on function public.my_purchases(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Métodos de pago guardados
-- ---------------------------------------------------------------------------
-- No guardan dinero ni credenciales: son los datos del PAGADOR que hay que
-- teclear al reportar un Pago Móvil (banco de origen, cédula y teléfono).
-- Guardarlos no autoriza ningún cobro; solo rellena el formulario.

create table if not exists public.user_payment_methods (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  -- Único método por ahora. El check documenta el supuesto: cuando entre otro
  -- (transferencia, Zelle) hay que revisar quién lee esta tabla.
  method         text not null default 'pago_movil' check (method in ('pago_movil')),
  bank           text not null check (btrim(bank) <> ''),
  -- 'V-12345678'. El formato lo valida la base y no solo la pantalla: una
  -- fila mal formada rompe la conciliación días después, lejos de donde se
  -- creó.
  payer_document text not null check (payer_document ~ '^[VEJPG]-[0-9]{6,9}$'),
  payer_phone    text not null check (payer_phone ~ '^0(412|414|416|424|426)[0-9]{7}$'),
  is_default     boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  -- Guardar dos veces el mismo banco + teléfono es siempre un accidente.
  unique (user_id, bank, payer_phone)
);

create index if not exists user_payment_methods_user_idx
  on public.user_payment_methods (user_id);

-- Un solo predeterminado por usuario, garantizado por la base. Un flag suelto
-- se desincroniza en cuanto dos pantallas escriben a la vez.
create unique index if not exists user_payment_methods_one_default_idx
  on public.user_payment_methods (user_id) where is_default;

alter table public.user_payment_methods enable row level security;

create policy "payment_methods_read_own"
  on public.user_payment_methods for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Sin políticas de escritura: las RPC de abajo mantienen el invariante del
-- predeterminado, que una política sola no puede.
grant select on public.user_payment_methods to authenticated;

drop trigger if exists user_payment_methods_touch_updated_at on public.user_payment_methods;
create trigger user_payment_methods_touch_updated_at
  before update on public.user_payment_methods
  for each row execute function public.touch_updated_at();

/** Cuántos métodos puede guardar una persona. Más que esto no es una lista,
 *  es un desorden — y cada fila lleva la cédula y el teléfono de alguien. */
create or replace function public.max_payment_methods()
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 5 $fn$;

revoke all on function public.max_payment_methods() from public, anon;
grant execute on function public.max_payment_methods() to authenticated;

/**
 * Guarda (o actualiza) un método de pago.
 *
 * Repetir banco + teléfono actualiza la fila existente en vez de crear una
 * gemela: es lo que pasa cuando alguien vuelve a marcar "guardar" en el
 * formulario de pago con los mismos datos.
 */
create or replace function public.save_payment_method(
  p_bank           text,
  p_payer_document text,
  p_payer_phone    text,
  p_make_default   boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_user  uuid := auth.uid();
  v_id    uuid;
  v_count integer;
  v_first boolean;
  v_default boolean;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select count(*) into v_count
  from public.user_payment_methods
  where user_id = v_user;

  v_first := v_count = 0;
  -- El primero es el predeterminado quiera o no: si no, habría métodos
  -- guardados y ninguno con el que rellenar la pantalla de pago.
  v_default := p_make_default or v_first;

  if v_count >= public.max_payment_methods()
     and not exists (
       select 1 from public.user_payment_methods
       where user_id = v_user and bank = p_bank and payer_phone = p_payer_phone
     )
  then
    raise exception 'Ya tienes % métodos guardados. Borra uno antes de añadir otro.',
      public.max_payment_methods() using errcode = '22023';
  end if;

  if v_default then
    update public.user_payment_methods
      set is_default = false
    where user_id = v_user and is_default;
  end if;

  insert into public.user_payment_methods
    (user_id, bank, payer_document, payer_phone, is_default)
  values
    (v_user, p_bank, upper(btrim(p_payer_document)), p_payer_phone, v_default)
  on conflict (user_id, bank, payer_phone) do update
    set payer_document = excluded.payer_document,
        -- Nunca a la baja: volver a guardar un método sin marcar "usar
        -- siempre este" no debe dejar al usuario sin predeterminado. Si
        -- `v_default` es true, el update de arriba ya limpió esta misma fila,
        -- así que el `or` no la resucita por accidente.
        is_default = excluded.is_default or public.user_payment_methods.is_default,
        updated_at = now()
  returning id into v_id;

  return v_id;
end;
$fn$;

revoke all on function public.save_payment_method(text, text, text, boolean) from public, anon;
grant execute on function public.save_payment_method(text, text, text, boolean) to authenticated;

create or replace function public.set_default_payment_method(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.user_payment_methods where id = p_id and user_id = v_user
  ) then
    raise exception 'Método de pago no encontrado' using errcode = 'P0002';
  end if;

  -- Limpiar primero: el índice único parcial no admite dos predeterminados ni
  -- por un instante dentro de la transacción.
  update public.user_payment_methods
    set is_default = false
  where user_id = v_user and is_default and id <> p_id;

  update public.user_payment_methods
    set is_default = true
  where id = p_id;
end;
$fn$;

revoke all on function public.set_default_payment_method(uuid) from public, anon;
grant execute on function public.set_default_payment_method(uuid) to authenticated;

/** Borra uno. Si era el predeterminado, asciende al más reciente que quede:
 *  quedarse sin predeterminado deja el formulario de pago vacío sin motivo. */
create or replace function public.delete_payment_method(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_user        uuid := auth.uid();
  v_was_default boolean;
  v_next        uuid;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  delete from public.user_payment_methods
  where id = p_id and user_id = v_user
  returning is_default into v_was_default;

  if not found then
    raise exception 'Método de pago no encontrado' using errcode = 'P0002';
  end if;

  if v_was_default then
    select id into v_next
    from public.user_payment_methods
    where user_id = v_user
    order by updated_at desc
    limit 1;

    if v_next is not null then
      update public.user_payment_methods set is_default = true where id = v_next;
    end if;
  end if;
end;
$fn$;

revoke all on function public.delete_payment_method(uuid) from public, anon;
grant execute on function public.delete_payment_method(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Sincronizar el teléfono tras cambiarlo
-- ---------------------------------------------------------------------------

/**
 * Copia a `profiles` el teléfono que GoTrue ya dio por bueno.
 *
 * No acepta el número como parámetro a propósito: lo lee de `auth.users`. Si
 * lo aceptara, cualquiera podría poner en su perfil un número que no ha
 * verificado — y `profiles.phone_e164` es lo que ve el panel de soporte.
 *
 * GoTrue guarda el teléfono sin el '+'; el resto del sistema lo usa en E.164.
 */
create or replace function public.sync_phone_e164()
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_user  uuid := auth.uid();
  v_phone text;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select phone into v_phone from auth.users where id = v_user;

  if v_phone is null or btrim(v_phone) = '' then
    raise exception 'La sesión no tiene teléfono' using errcode = '22023';
  end if;

  if left(v_phone, 1) <> '+' then
    v_phone := '+' || v_phone;
  end if;

  update public.profiles
    set phone_e164 = v_phone,
        updated_at = now()
  where id = v_user;

  return v_phone;
end;
$fn$;

revoke all on function public.sync_phone_e164() from public, anon;
grant execute on function public.sync_phone_e164() to authenticated;
