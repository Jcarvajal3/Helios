-- ============================================================================
-- Ronda — Bits: puntos por adelantar cuotas
--
-- Decisión de negocio (2026-08-25): premiar con **100 Bits cada cuota que el
-- usuario paga antes de su vencimiento**. Es el primer incentivo positivo del
-- producto — hasta ahora todo lo que empujaba a pagar era una consecuencia
-- (congelar, bajar de nivel, expulsar, docs/06 §3) y ninguna palanca miraba
-- al que se adelanta. Adelantar cuotas es además lo único que el usuario
-- puede hacer para arreglar la curva de caja de docs/05 §3: al comercio se le
-- liquida por fecha, así que cada dólar que entra antes es colchón que no
-- hace falta poner.
--
-- ---------------------------------------------------------------------------
-- QUÉ CUENTA COMO ADELANTO
-- ---------------------------------------------------------------------------
-- Que la cuota se salde **antes del día operativo de su vencimiento**. Ni un
-- corte concreto ni una pantalla: la fecha de la cuota contra el día en que se
-- pagó. Pagar el 31 lo que vence el 31 no es adelanto; pagar el 30, sí.
--
-- ---------------------------------------------------------------------------
-- CONTRA QUÉ FECHA SE MIDE, Y POR QUÉ NO CONTRA `paid_at`
-- ---------------------------------------------------------------------------
-- `installments.paid_at` es el instante en que **el operador aprobó** el
-- reporte, no en el que el usuario transfirió. Entre los dos hay una revisión
-- manual que puede tardar días. Medir con `paid_at` haría que el premio
-- dependiera de la cola de conciliación: el usuario adelanta el día 12 una
-- cuota que vence el 15, el panel la aprueba el 16 y se queda sin Bits sin que
-- nadie pueda explicarle por qué. Se mide contra `payment_reports.created_at`
-- —cuándo dijo el usuario que había pagado— y se cae a `paid_at` solo si la
-- cuota se saldó por un camino que no pasa por un reporte.
--
-- ---------------------------------------------------------------------------
-- POR QUÉ UN TRIGGER Y NO UNA LLAMADA DENTRO DE `reconcile_payment`
-- ---------------------------------------------------------------------------
-- El mismo motivo que las notificaciones (20260822160000): lo que hay que
-- premiar es un CAMBIO DE ESTADO escrito en una tabla —una cuota que pasa de
-- `pending` a `paid`—. Un trigger lo capta venga de donde venga: de la
-- conciliación de hoy, de un pago en efectivo mañana o de un arreglo a mano
-- del super admin. Sembrar la llamada dentro de una RPC deja un hueco en
-- cuanto aparezca el segundo camino.
--
-- ---------------------------------------------------------------------------
-- ALCANCE
-- ---------------------------------------------------------------------------
-- Aquí va **ganar y contar** Bits. Canjearlos no: el catálogo de premios no
-- existe todavía y la app lo dice ("Próximamente"). Cuando exista, se añade su
-- `reason` al check y se insertan filas con `amount` negativo — el saldo ya es
-- una suma con signo y no un contador, justo para no rehacer esta tabla ese
-- día.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Cuánto vale un adelanto
-- ---------------------------------------------------------------------------
-- Función y no constante en línea, como `helios_min_float_days()`: es un
-- parámetro de negocio, y subirlo a 150 tiene que ser un `create or replace`
-- de una línea. La app lo LEE (`my_bits()` lo devuelve) en vez de repetirlo en
-- pantalla, así que cambiarlo aquí cambia también lo que promete Inicio.

create or replace function public.helios_bits_per_early_installment()
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 100 $fn$;

comment on function public.helios_bits_per_early_installment() is
  'Bits que gana una cuota pagada antes de su vencimiento.';

revoke all on function public.helios_bits_per_early_installment() from public, anon;
grant execute on function public.helios_bits_per_early_installment() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El libro de Bits
-- ---------------------------------------------------------------------------
-- Movimientos, no un contador en `profiles`. Un saldo suelto no responde "¿por
-- qué tengo 300?", que es justo lo que llega a soporte cuando el número no
-- cuadra con lo que el usuario recuerda. Con una fila por hecho, la ficha del
-- panel enseña de dónde salió cada premio y el saldo es su suma — que además
-- no se puede desincronizar.

create table if not exists public.bits_entries (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  -- Con signo: positivo otorga. El canje, cuando exista, resta.
  amount         integer not null check (amount <> 0),
  reason         text not null check (reason in ('early_installment')),
  -- De qué cuota salió. Nulo para razones que no cuelguen de una cuota.
  installment_id uuid references public.installments (id) on delete set null,
  created_at     timestamptz not null default now()
);

comment on table public.bits_entries is
  'Movimientos de Bits. El saldo de un usuario es la suma de sus filas.';

create index bits_entries_user_idx on public.bits_entries (user_id, created_at desc);

-- Una cuota premia UNA vez. Es la red por si algún día un camino vuelve a
-- mover a `paid` una cuota que ya lo estaba: el trigger reintentaría el premio
-- y se queda aquí.
create unique index bits_entries_installment_unique
  on public.bits_entries (installment_id)
  where reason = 'early_installment';

alter table public.bits_entries enable row level security;

create policy "bits_entries_read_own"
  on public.bits_entries for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Deliberadamente sin políticas de escritura: los Bits los otorga el
-- servidor. Que el cliente pudiera insertar una fila es que pudiera regalarse
-- premios.

grant select on public.bits_entries to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El premio
-- ---------------------------------------------------------------------------

create or replace function public.award_bits_for_early_installment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_reported_at timestamptz;
begin
  -- Cuándo pagó el USUARIO, no cuándo lo aprobó el panel (ver la cabecera).
  -- Se descartan los reportes muertos —`rejected`, `duplicate`—: si la cuota
  -- se saldó, fue por otro. Dentro de `reconcile_payment` el reporte que la
  -- está saldando sigue en `reported` —se marca `reconciled` después del
  -- bucle—, así que los tres estados vivos tienen que entrar.
  select pr.created_at into v_reported_at
  from public.payment_reports pr
  join public.payment_quote_items qi on qi.quote_id = pr.quote_id
  where qi.installment_id = new.id
    and pr.status in ('reported', 'in_review', 'reconciled')
  order by pr.created_at desc
  limit 1;

  if new.due_date > public.helios_business_date(
       coalesce(v_reported_at, new.paid_at, now())
     )
  then
    insert into public.bits_entries (user_id, amount, reason, installment_id)
    values (
      new.user_id,
      public.helios_bits_per_early_installment(),
      'early_installment',
      new.id
    )
    on conflict do nothing;
  end if;

  return null;
end;
$$;

comment on function public.award_bits_for_early_installment() is
  'Otorga Bits cuando una cuota se salda antes del día operativo de su vencimiento.';

revoke all on function public.award_bits_for_early_installment()
  from public, anon, authenticated;

drop trigger if exists installments_award_bits on public.installments;

create trigger installments_award_bits
  after update of status on public.installments
  for each row
  when (old.status = 'pending' and new.status = 'paid')
  execute function public.award_bits_for_early_installment();

-- ---------------------------------------------------------------------------
-- 4. Lo que lee la app
-- ---------------------------------------------------------------------------
-- Devuelve también `per_installment` para que la tarjeta de Inicio prometa lo
-- que de verdad paga el servidor. Si el número viviera en el cliente, subirlo
-- aquí dejaría a todas las apps ya instaladas prometiendo el viejo.

create or replace function public.my_bits()
returns jsonb
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'balance', coalesce(sum(e.amount), 0),
    'awarded_count', count(*) filter (where e.reason = 'early_installment'),
    'last_award_at', max(e.created_at) filter (where e.amount > 0),
    'per_installment', public.helios_bits_per_early_installment()
  )
  from public.bits_entries e
  where e.user_id = (select auth.uid());
$$;

comment on function public.my_bits() is
  'Saldo de Bits del usuario, cuántos adelantos lo formaron y cuánto vale un adelanto hoy.';

revoke all on function public.my_bits() from public, anon;
grant execute on function public.my_bits() to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Los Bits en la ficha del super admin
-- ---------------------------------------------------------------------------
-- `admin_user_detail` es "la info del usuario" del panel: una llamada que
-- devuelve la ficha entera. Los Bits entran ahí y no en una RPC aparte para
-- que la ficha siga siendo un solo viaje y no haya un bloque que a veces
-- cargue y a veces no.
--
-- Cuerpo idéntico al de 20260822201000_admin_users.sql salvo el bloque
-- `bits` / `bits_entries` que se añade antes del `return`.
-- ---------------------------------------------------------------------------

create or replace function public.admin_user_detail(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_result jsonb;
  v_block  public.user_credit_blocks%rowtype;
  v_limit  numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'user_id', p.id,
    'full_name', p.full_name,
    'phone_e164', p.phone_e164,
    'document_number', p.document_number,
    'birth_date', p.birth_date,
    'status', p.status,
    'level', p.level,
    'is_blacklisted', p.is_blacklisted,
    'blacklist_reason', p.blacklist_reason,
    'created_at', p.created_at
  ), l.monthly_limit_usd
  into v_result, v_limit
  from public.profiles p
  join public.levels l on l.level = p.level
  where p.id = p_user_id;

  if v_result is null then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  -- El bloque de crédito abierto explica el disponible. Es la pregunta #1 de
  -- soporte: "pagué una cuota, ¿por qué sigo en cero?" (docs/00-BASES §2.2).
  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user_id and closed_at is null;

  v_result := v_result || jsonb_build_object('credit', jsonb_build_object(
    'level_limit_usd', v_limit,
    'block_charged_usd', coalesce(v_block.charged_usd, 0),
    'block_paid_usd', coalesce(v_block.paid_usd, 0),
    'available_usd', greatest(v_limit - (coalesce(v_block.charged_usd, 0)
                                       - coalesce(v_block.paid_usd, 0)), 0),
    'to_unlock_usd', coalesce(v_block.charged_usd, 0) - coalesce(v_block.paid_usd, 0),
    'block_opened_at', v_block.opened_at
  ));

  v_result := v_result || jsonb_build_object('debt', (
    select jsonb_build_object(
      'open_usd', coalesce(sum(amount_usd) filter (where status = 'pending'), 0),
      'overdue_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and due_date < v_today), 0),
      'paid_usd', coalesce(sum(amount_usd) filter (where status = 'paid'), 0),
      'days_overdue', coalesce(max(v_today - due_date)
        filter (where status = 'pending' and due_date < v_today), 0)
    )
    from public.installments where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'charge_id', i.charge_id,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      'due_date', i.due_date,
      'status', i.status,
      'paid_at', i.paid_at,
      'merchant_name', m.name,
      'days_overdue', greatest(v_today - i.due_date, 0)
    ) order by i.due_date, i.sequence)
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    join public.merchants m on m.id = ch.merchant_id
    where i.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('charges', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ch.id,
      'amount_usd', ch.amount_usd,
      'status', ch.status,
      'business_date', ch.business_date,
      'confirmed_at', ch.confirmed_at,
      'merchant_name', m.name,
      'branch_name', b.name,
      'void_reason', ch.void_reason
    ) order by ch.created_at desc)
    from public.charges ch
    join public.merchants m on m.id = ch.merchant_id
    join public.merchant_branches b on b.id = ch.branch_id
    where ch.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('payments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'status', pr.status,
      'bank', pr.bank,
      'reference', pr.reference,
      'method', pr.method,
      'amount_usd', q.amount_usd,
      'amount_ves', q.amount_ves,
      'rejection_note', pr.rejection_note,
      'created_at', pr.created_at
    ) order by pr.created_at desc)
    from public.payment_reports pr
    join public.payment_quotes q on q.id = pr.quote_id
    where pr.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('level_changes', coalesce((
    select jsonb_agg(jsonb_build_object(
      'from_level', lc.from_level,
      'to_level', lc.to_level,
      'reason', lc.reason,
      'note', lc.note,
      'actor', lc.actor,
      'created_at', lc.created_at
    ) order by lc.created_at desc)
    from public.level_changes lc
    where lc.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('kyc', (
    select jsonb_build_object(
      'status', v.status,
      'rejection_reason', v.rejection_reason,
      'rejection_detail', v.rejection_detail,
      'reviewed_at', v.reviewed_at,
      'created_at', v.created_at
    )
    from kyc.verifications v
    where v.user_id = p_user_id
    order by v.created_at desc limit 1
  ));

  -- Bits. El saldo va con SUS MOVIMIENTOS y no solo con la cifra: la pregunta
  -- que llega a soporte no es cuántos tiene, es de dónde salieron.
  v_result := v_result || jsonb_build_object('bits', (
    select jsonb_build_object(
      'balance', coalesce(sum(amount), 0),
      'awarded_count', count(*) filter (where reason = 'early_installment'),
      'last_award_at', max(created_at) filter (where amount > 0)
    )
    from public.bits_entries where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('bits_entries', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', e.id,
      'amount', e.amount,
      'reason', e.reason,
      'created_at', e.created_at,
      -- De qué cuota salió: el vencimiento que se adelantó y dónde se gastó.
      -- Los joins son LEFT porque un movimiento futuro (un canje) no cuelga
      -- de ninguna cuota, y borrar una cuota anula la referencia sin borrar
      -- el premio.
      'due_date', i.due_date,
      'paid_at', i.paid_at,
      'merchant_name', m.name
    ) order by e.created_at desc)
    from public.bits_entries e
    left join public.installments i on i.id = e.installment_id
    left join public.charges ch on ch.id = i.charge_id
    left join public.merchants m on m.id = ch.merchant_id
    where e.user_id = p_user_id
  ), '[]'::jsonb));

  return v_result;
end;
$$;

revoke all on function public.admin_user_detail(uuid) from public, anon;
grant execute on function public.admin_user_detail(uuid) to authenticated;
