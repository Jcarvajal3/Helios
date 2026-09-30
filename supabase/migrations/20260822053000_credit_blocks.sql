-- ============================================================================
-- Ronda — Bloques de crédito (motor de límites)
--
-- Decisión confirmada 2026-08-22 (docs/00-BASES §2.2): el límite no es
-- revolvente puro ni cupo de calendario. Es un cupo por bloque:
--
--   disponible = límite del nivel actual − (cargado − pagado) del bloque abierto
--
-- El bloque se cierra, y el límite vuelve entero, en el instante en que la
-- deuda del bloque llega a cero — nunca por cambio de mes. Puede acumular
-- varios consumos mientras siga abierto; solo hay un bloque abierto por
-- usuario a la vez.
-- ============================================================================

create type public.credit_block_close_reason as enum (
  'paid',        -- el usuario saldó la deuda completa del bloque
  'charged_off'  -- se castigó como incobrable (> 30 días de mora)
);

create table if not exists public.user_credit_blocks (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  opened_at    timestamptz not null default now(),
  closed_at    timestamptz,
  close_reason public.credit_block_close_reason,
  charged_usd  numeric(18,4) not null default 0 check (charged_usd >= 0),
  paid_usd     numeric(18,4) not null default 0 check (paid_usd >= 0),
  constraint credit_blocks_paid_le_charged check (paid_usd <= charged_usd),
  constraint credit_blocks_close_consistency check ((closed_at is null) = (close_reason is null))
);

-- Solo un bloque abierto por usuario: es lo que hace "disponible" una
-- pregunta con una sola respuesta posible en todo momento.
create unique index user_credit_blocks_one_open
  on public.user_credit_blocks (user_id) where closed_at is null;

create index user_credit_blocks_user_idx on public.user_credit_blocks (user_id);

alter table public.user_credit_blocks enable row level security;

create policy "credit_blocks_read_own"
  on public.user_credit_blocks for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Sin políticas de escritura: el bloque solo lo mueven las RPC de cobro y
-- conciliación, todas SECURITY DEFINER.

-- Disponible, y cuánto falta para liberarlo. La liberación total (no
-- parcial) sorprende a un usuario que ya pagó una cuota, así que Inicio debe
-- poder mostrar "te faltan $X para liberar tu saldo" y no solo el disponible.
create or replace function public.my_available_balance()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user     uuid := auth.uid();
  v_level    smallint;
  v_limit    numeric(18,4);
  v_block    public.user_credit_blocks%rowtype;
  v_charged  numeric(18,4) := 0;
  v_to_unlock numeric(18,4) := 0;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select level into v_level from public.profiles where id = v_user;
  select monthly_limit_usd into v_limit from public.levels where level = v_level;

  select * into v_block
  from public.user_credit_blocks
  where user_id = v_user and closed_at is null;

  if found then
    -- El disponible cae con lo CARGADO, no con lo pagado: pagar una cuota no
    -- libera cupo nuevo (docs/00-BASES §2.2, "no hay liberación parcial").
    -- Solo cuenta cuánto queda para saldar el bloque por completo.
    v_charged := v_block.charged_usd;
    v_to_unlock := v_block.charged_usd - v_block.paid_usd;
  end if;

  return jsonb_build_object(
    'limit_usd', v_limit,
    'available_usd', greatest(v_limit - v_charged, 0),
    'open_debt_usd', v_charged,
    'amount_to_unlock_usd', v_to_unlock
  );
end;
$$;

revoke all on function public.my_available_balance() from public, anon;
grant execute on function public.my_available_balance() to authenticated;
