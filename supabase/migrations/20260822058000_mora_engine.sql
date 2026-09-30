-- ============================================================================
-- Ronda — Motor de mora
--
-- Decisión confirmada 2026-08-22 (docs/00-BASES §2.4, docs/06-REGLAS §3):
-- no hay cargo por mora. La única penalización es el bloqueo del saldo y la
-- baja de nivel:
--
--   desde el día 1 de atraso   → saldo congelado (`frozen`)
--   > 15 días de atraso        → baja 1 nivel + bloqueado (`suspended`)
--   > 30 días de atraso        → expulsión + marca interna (`expelled`)
--   al pagar                   → saldo restablecido
--
-- Cada transición queda en `public.level_changes` con motivo — el usuario
-- (o el super admin) tiene que poder ver por qué bajó de nivel, no
-- adivinarlo (docs/01 §6).
--
-- La expulsión (> 30 días) NO se revierte sola aquí: docs/00-BASES §3.10 y
-- §2.4 dejan "¿es reversible?" como pregunta abierta (D-10). Hasta que se
-- decida, expelled es terminal y solo el super admin la mueve a mano.
-- ============================================================================

create type public.level_change_reason as enum (
  'mora_15d',      -- automático: > 15 días de atraso
  'expelled',      -- automático: > 30 días de atraso (no cambia el nivel, deja rastro)
  'manual_admin'   -- ajuste a mano, siempre con motivo (docs/01 §6)
);

create table if not exists public.level_changes (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  from_level  smallint not null,
  to_level    smallint not null,
  reason      public.level_change_reason not null,
  -- null = el sistema (mora). Con valor, el admin que hizo el ajuste manual.
  actor       uuid references auth.users (id),
  note        text,
  created_at  timestamptz not null default now()
);

create index level_changes_user_idx on public.level_changes (user_id, created_at desc);

alter table public.level_changes enable row level security;

create policy "level_changes_read_own"
  on public.level_changes for select
  to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Castigo por incobrable: cierra el bloque abierto y reconoce la pérdida
-- contra la provisión (docs/05 §3 "Impago"). Ronda ya le liquidó el 100% al
-- comercio, así que la pérdida es íntegra.
-- ---------------------------------------------------------------------------

create or replace function public.charge_off_user_debt(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_block  public.user_credit_blocks%rowtype;
  v_amount numeric(18,4);
  v_tx     uuid;
  v_acct_recv     uuid;
  v_acct_provision uuid;
begin
  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user_id and closed_at is null
  for update;

  if not found then
    return;
  end if;

  v_amount := v_block.charged_usd - v_block.paid_usd;

  if v_amount <= 0 then
    update public.user_credit_blocks
      set closed_at = now(), close_reason = 'paid'
    where id = v_block.id;
    return;
  end if;

  v_acct_recv := ledger.get_or_create_account('user_receivable', p_user_id);
  v_acct_provision := ledger.get_or_create_account('bad_debt_provision', null);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'charge_off', 'charge_off:' || v_block.id::text, public.helios_business_date(now()),
    v_block.id, 'Castigo por mora > 30 días'
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_provision, v_amount, 0),
    (v_tx, v_acct_recv, 0, v_amount);

  update public.user_credit_blocks
    set closed_at = now(), close_reason = 'charged_off'
  where id = v_block.id;
end;
$$;

revoke all on function public.charge_off_user_debt(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- recompute_profile_mora_state — el corazón del motor. Idempotente: se
-- puede llamar tantas veces como haga falta (al conciliar un pago, desde el
-- cron diario) sin re-castigar dos veces el mismo atraso.
-- ---------------------------------------------------------------------------

create or replace function public.recompute_profile_mora_state(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status       public.profile_status;
  v_level        smallint;
  v_new_level    smallint;
  v_max_days_late integer;
begin
  select status, level into v_status, v_level
  from public.profiles where id = p_user_id for update;

  if not found or v_status = 'expelled' then
    -- Terminal: requiere revisión manual del super admin (D-10, sin decidir).
    return;
  end if;

  select coalesce(max(public.helios_business_date(now()) - i.due_date), 0)
    into v_max_days_late
  from public.installments i
  where i.user_id = p_user_id
    and i.status = 'pending'
    and i.due_date < public.helios_business_date(now());

  if v_max_days_late <= 0 then
    -- Sin mora. Si venía bloqueado, se restablece el acceso — pero el nivel
    -- perdido no se recupera solo, eso es un ajuste manual explícito.
    if v_status in ('frozen', 'suspended') then
      update public.profiles set status = 'active', updated_at = now() where id = p_user_id;
    end if;
    return;
  end if;

  if v_max_days_late > 30 then
    if v_status <> 'expelled' then
      update public.profiles
        set status = 'expelled', is_blacklisted = true, updated_at = now()
      where id = p_user_id;

      insert into public.level_changes (user_id, from_level, to_level, reason)
      values (p_user_id, v_level, v_level, 'expelled');

      perform public.charge_off_user_debt(p_user_id);
    end if;
    return;
  end if;

  if v_max_days_late >= 15 then
    if v_status <> 'suspended' then
      v_new_level := greatest(1, v_level - 1);

      update public.profiles
        set status = 'suspended', level = v_new_level, updated_at = now()
      where id = p_user_id;

      insert into public.level_changes (user_id, from_level, to_level, reason)
      values (p_user_id, v_level, v_new_level, 'mora_15d');
    end if;
    return;
  end if;

  -- 1 a 14 días de atraso: congelado, sin tocar el nivel.
  if v_status = 'active' then
    update public.profiles set status = 'frozen', updated_at = now() where id = p_user_id;
  end if;
end;
$$;

revoke all on function public.recompute_profile_mora_state(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- process_mora — el job diario. Recorre solo a quienes pueden tener un
-- cambio de estado pendiente: con una cuota vencida, o ya bloqueados (por si
-- el pago se conciliara fuera del flujo normal de reconcile_payment).
-- ---------------------------------------------------------------------------

create or replace function public.process_mora()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row   record;
  v_count integer := 0;
begin
  for v_row in
    select user_id from public.installments
      where status = 'pending' and due_date < public.helios_business_date(now())
    union
    select id as user_id from public.profiles where status in ('frozen', 'suspended')
  loop
    perform public.recompute_profile_mora_state(v_row.user_id);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Sin grant: solo el cron/service role la ejecuta.
revoke all on function public.process_mora() from public, anon, authenticated;
