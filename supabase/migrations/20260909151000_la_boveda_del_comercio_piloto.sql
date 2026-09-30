-- ============================================================================
-- Ronda — La bóveda del comercio piloto y la lista de espera
--
-- ⚠️ FUNCIONALIDAD TEMPORAL. Existe para UN comercio (La Quinta Bar) y para
-- el tiempo que dure el piloto. Está construida para apagarse con un
-- interruptor y quitarse sin tocar el modelo de cobro.
--
-- ---------------------------------------------------------------------------
-- El acuerdo
-- ---------------------------------------------------------------------------
-- El primer local exige una garantía por adelantado: Ronda le deposita un
-- monto —la BÓVEDA— y la gente compra en su local contra ese monto. Cada
-- consumo confirmado la baja en el COSTO DE LOS PRODUCTOS, nada más: ni el fee
-- del servicio ni su IVA son del comercio, así que no salen de su bóveda.
-- Es la misma cifra que ocupa cupo al usuario (`charges.base_usd`, lo
-- financiado), y no es casualidad: lo que Ronda financia es lo que el local
-- entrega.
--
-- Como Ronda solo puede operar con lo que hay en la bóveda, el gasto se acota
-- por la puerta de entrada y no por la de salida:
--
--   · Quien ya está activo consume con normalidad, aunque la bóveda se agote.
--     Puede quedar en NEGATIVO; la siguiente recarga lo repone. Bloquear a
--     alguien que ya tiene saldo aprobado sería romperle la promesa.
--   · Cuando el saldo de la bóveda cae al UMBRAL (10 % por defecto, editable
--     desde el super admin), quien se registre y verifique A PARTIR DE AHÍ
--     entra en LISTA DE ESPERA: puede usar la app, pero su saldo está
--     bloqueado hasta que el equipo lo libere, de uno en uno o por tandas,
--     conforme se recargue la bóveda.
--
-- ---------------------------------------------------------------------------
-- Por qué la bóveda se DERIVA en vez de descontarse
-- ---------------------------------------------------------------------------
-- No hay ningún gancho en el camino del cobro que reste de la bóveda. El
-- saldo es una cuenta hecha al leer:
--
--     saldo = Σ recargas − Σ base_usd de los cobros confirmados del comercio
--             desde que se abrió la bóveda
--
-- Tres razones:
--   1. Un cobro de grupo reparte y REPARTE OTRA VEZ cuando entra alguien
--      tarde (20260903000000). La base del cobro no cambia con eso; las
--      deudas por persona sí. Colgarse de las deudas obligaría a deshacer
--      y rehacer descuentos; colgarse del cobro, no.
--   2. Un cobro confirmado no se anula (docs/06 §2, "sin reversas"), así que
--      no hay nada que devolver.
--   3. Apagar la funcionalidad es apagar una fila. `confirm_charge`,
--      `confirm_charge_as_group` y `claim_charge_share` no saben que existe.
--
-- El umbral se mide contra el saldo que dejó la ÚLTIMA recarga —lo que la
-- bóveda "es" hoy—, no contra el acumulado histórico: con el acumulado, tras
-- un negativo de −100 y una recarga de 500 el 10 % del total sería mayor que
-- lo que de verdad quedó, y la lista se encendería el mismo día de recargar.
--
-- ---------------------------------------------------------------------------
-- Por qué la lista de espera NO es un estado del perfil
-- ---------------------------------------------------------------------------
-- `profiles.status` sigue en `active`: la persona está verificada, tiene PIN y
-- puede entrar. Lo que se apaga es el SALDO, y eso lo decide una sola
-- función, `helios_waitlisted(user)`, que miran:
--
--   · `available_usd`        → 0 (lo que ven grupos y elegibilidad)
--   · `my_available_balance` → 0, y dice POR QUÉ (`waitlisted`)
--   · `helios_assign_debt`    → rechaza crear deuda, con el motivo en texto
--
-- `helios_assign_debt` es "el único sitio que crea deuda" (20260829080000):
-- por eso el bloqueo se pone ahí y no en cada RPC de cobro.
--
-- ---------------------------------------------------------------------------
-- Los interruptores (todos en `merchant_vaults`)
-- ---------------------------------------------------------------------------
--   is_active               La bóveda existe: se enseña al comercio y se cuenta.
--   waitlist_auto_enroll    Los nuevos verificados entran solos en la lista
--                           cuando el saldo está en el umbral o por debajo.
--   waitlist_blocks_balance La lista bloquea saldo. APAGADO = nadie de la
--                           lista tiene el saldo bloqueado, aunque siga en ella.
--                           Es el freno de mano.
--   threshold_pct           El umbral rojo.
--
-- ---------------------------------------------------------------------------
-- Cómo se quita del todo el día que sobre
-- ---------------------------------------------------------------------------
--   1. `update merchant_vaults set is_active = false` — y ya nadie está
--      bloqueado ni el comercio ve la bóveda.
--   2. Cuando se quiera limpiar: drop trigger profiles_waitlist_on_activation,
--      re-emitir `available_usd`, `my_available_balance` y `helios_assign_debt`
--      sin la línea de `helios_waitlisted`, y drop de las tres tablas y sus
--      funciones. Nada más depende de esto.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------------

create table if not exists public.merchant_vaults (
  merchant_id             uuid primary key references public.merchants (id) on delete cascade,
  is_active               boolean not null default true,
  waitlist_auto_enroll    boolean not null default true,
  waitlist_blocks_balance boolean not null default true,
  threshold_pct           numeric(5,2) not null default 10.00
                          check (threshold_pct >= 0 and threshold_pct <= 100),
  -- Desde cuándo cuentan los cobros. Un comercio con historia previa no
  -- arranca la bóveda debiendo lo que vendió antes del acuerdo.
  opened_at               timestamptz not null default now(),
  note                    text,
  updated_at              timestamptz not null default now()
);

comment on table public.merchant_vaults is
  'TEMPORAL (piloto): la garantía depositada en un comercio y los interruptores de la lista de espera. Ver 20260909151000.';

create table if not exists public.merchant_vault_topups (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references public.merchant_vaults (merchant_id) on delete cascade,
  amount_usd  numeric(18,4) not null check (amount_usd > 0),
  note        text,
  actor       uuid not null references auth.users (id),
  created_at  timestamptz not null default now()
);

create index if not exists merchant_vault_topups_merchant_idx
  on public.merchant_vault_topups (merchant_id, created_at desc);

comment on table public.merchant_vault_topups is
  'Recargas de la bóveda. Append-only: una recarga que se pueda borrar no sirve de garantía.';

-- Append-only, como el ledger y la bitácora. Un error se corrige con otra
-- fila, nunca editando la que está.
create or replace function public.vault_topups_block_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
begin
  raise exception 'merchant_vault_topups es append-only: % no está permitido', tg_op;
end;
$$;

drop trigger if exists vault_topups_no_update on public.merchant_vault_topups;
create trigger vault_topups_no_update before update on public.merchant_vault_topups
  for each row execute function public.vault_topups_block_mutation();
drop trigger if exists vault_topups_no_delete on public.merchant_vault_topups;
create trigger vault_topups_no_delete before delete on public.merchant_vault_topups
  for each row execute function public.vault_topups_block_mutation();

create table if not exists public.credit_waitlist (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  -- La bóveda que lo puso en espera. Si se apaga, la espera se apaga con ella.
  merchant_id  uuid not null references public.merchant_vaults (merchant_id) on delete cascade,
  entered_at   timestamptz not null default now(),
  -- 'auto': entró solo al verificarse con la bóveda en rojo.
  -- 'manual': lo metió alguien del equipo desde el panel.
  entry_reason text not null check (entry_reason in ('auto', 'manual')),
  entered_by   uuid references auth.users (id),
  entry_note   text,
  released_at  timestamptz,
  released_by  uuid references auth.users (id),
  release_note text,
  constraint credit_waitlist_release_consistency
    check ((released_at is null) = (released_by is null))
);

-- Una espera abierta por persona. Es lo que hace "¿está en la lista?" una
-- pregunta con una sola respuesta.
create unique index if not exists credit_waitlist_one_open
  on public.credit_waitlist (user_id) where released_at is null;

create index if not exists credit_waitlist_merchant_idx
  on public.credit_waitlist (merchant_id, entered_at);

comment on table public.credit_waitlist is
  'TEMPORAL (piloto): quién tiene el saldo en espera y quién lo liberó. Ver 20260909151000.';

-- Sin políticas: todo pasa por RPC. Un usuario no necesita leer su fila —
-- `my_available_balance` ya le dice que está en espera y desde cuándo.
alter table public.merchant_vaults        enable row level security;
alter table public.merchant_vault_topups  enable row level security;
alter table public.credit_waitlist        enable row level security;

-- ---------------------------------------------------------------------------
-- 2. ¿Está bloqueado el saldo de esta persona?
-- ---------------------------------------------------------------------------
/**
 * Verdadero solo si hay una espera abierta Y la bóveda que la causó sigue
 * activa Y con el freno de mano quitado. Apagar cualquiera de los dos
 * interruptores desbloquea a todo el mundo sin tocar la lista.
 */
create or replace function public.helios_waitlisted(p_user uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select exists (
    select 1
    from public.credit_waitlist w
    join public.merchant_vaults v on v.merchant_id = w.merchant_id
    where w.user_id = p_user
      and w.released_at is null
      and v.is_active
      and v.waitlist_blocks_balance
  );
$$;

comment on function public.helios_waitlisted(uuid) is
  'TEMPORAL (piloto): el saldo de esta persona esta en lista de espera. Mientras sea cierto, el disponible es 0 y no se le crea deuda.';

revoke all on function public.helios_waitlisted(uuid) from public, anon;
grant execute on function public.helios_waitlisted(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El estado de una bóveda
-- ---------------------------------------------------------------------------
/**
 * La cuenta entera, hecha al leer. Interna: la envuelven las RPC del super
 * admin y del gerente, que son las que deciden quién ve qué.
 *
 *   funded_usd     Σ recargas
 *   consumed_usd   Σ base de los cobros confirmados desde `opened_at`
 *   balance_usd    lo uno menos lo otro; puede ser negativo
 *   reference_usd  el saldo que dejó la última recarga: contra eso va el %
 *   threshold_usd  el umbral en euros, que es lo que hay que mirar
 */
create or replace function public.merchant_vault_state(p_merchant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_vault      public.merchant_vaults%rowtype;
  v_name       text;
  v_funded     numeric(18,4) := 0;
  v_topups     integer := 0;
  v_last_topup timestamptz;
  v_consumed   numeric(18,4) := 0;
  v_charges    integer := 0;
  v_before     numeric(18,4) := 0;
  v_balance    numeric(18,4);
  v_reference  numeric(18,4);
  v_threshold  numeric(18,4);
  v_waiting    integer := 0;
  v_released   integer := 0;
begin
  select * into v_vault from public.merchant_vaults where merchant_id = p_merchant_id;
  if not found then
    return null;
  end if;

  select name into v_name from public.merchants where id = p_merchant_id;

  select coalesce(sum(amount_usd), 0), count(*), max(created_at)
    into v_funded, v_topups, v_last_topup
  from public.merchant_vault_topups
  where merchant_id = p_merchant_id;

  -- La BASE, no el total: el fee y su IVA no salen de la bóveda del local.
  -- En los cobros anteriores al desglose la base es nula y el total ERA la
  -- base (misma regla que `confirm_charge`).
  select coalesce(sum(coalesce(base_usd, amount_usd)), 0), count(*)
    into v_consumed, v_charges
  from public.charges
  where merchant_id = p_merchant_id
    and status = 'confirmed'
    and confirmed_at >= v_vault.opened_at;

  -- Lo consumido ANTES de la última recarga, para saber qué saldo dejó.
  select coalesce(sum(coalesce(base_usd, amount_usd)), 0)
    into v_before
  from public.charges
  where merchant_id = p_merchant_id
    and status = 'confirmed'
    and confirmed_at >= v_vault.opened_at
    and confirmed_at < coalesce(v_last_topup, v_vault.opened_at);

  v_balance   := v_funded - v_consumed;
  v_reference := v_funded - v_before;
  v_threshold := round(greatest(v_reference, 0) * v_vault.threshold_pct / 100, 2);

  select
    count(*) filter (where released_at is null),
    count(*) filter (where released_at is not null)
    into v_waiting, v_released
  from public.credit_waitlist
  where merchant_id = p_merchant_id;

  return jsonb_build_object(
    'merchant_id',             p_merchant_id,
    'merchant_name',           v_name,
    'is_active',               v_vault.is_active,
    'waitlist_auto_enroll',    v_vault.waitlist_auto_enroll,
    'waitlist_blocks_balance', v_vault.waitlist_blocks_balance,
    'threshold_pct',           v_vault.threshold_pct,
    'opened_at',               v_vault.opened_at,
    'note',                    v_vault.note,
    'funded_usd',              v_funded,
    'topup_count',             v_topups,
    'last_topup_at',           v_last_topup,
    'consumed_usd',            v_consumed,
    'charge_count',            v_charges,
    'balance_usd',             v_balance,
    'reference_usd',           v_reference,
    'threshold_usd',           v_threshold,
    -- "Llega al 10 %": en el umbral o por debajo. Sin ninguna recarga todo
    -- vale 0 y esto es cierto: sin garantía no hay saldo que prometer.
    'below_threshold',         (v_balance <= v_threshold),
    'waiting_count',           v_waiting,
    'released_count',          v_released
  );
end;
$$;

revoke all on function public.merchant_vault_state(uuid) from public, anon, authenticated;

/**
 * La bóveda que hoy manda a la gente nueva a la lista, si hay alguna.
 *
 * Devuelve el comercio y no un booleano para que la fila de la lista sepa de
 * qué bóveda cuelga — y se apague con ella.
 */
create or replace function public.helios_vault_wanting_waitlist()
returns uuid
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select v.merchant_id
  from public.merchant_vaults v
  where v.is_active
    and v.waitlist_auto_enroll
    and coalesce((public.merchant_vault_state(v.merchant_id)->>'below_threshold')::boolean, false)
  order by v.opened_at
  limit 1;
$$;

revoke all on function public.helios_vault_wanting_waitlist() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Entrar en la lista al activarse
-- ---------------------------------------------------------------------------
/**
 * Se dispara cuando un perfil pasa de "a medio registro" a `active`, que es
 * el instante en que `kyc.advance_profile` da por verificada a la persona.
 *
 * Solo la PRIMERA activación. Volver de `frozen` o `suspended` no es
 * registrarse: quien ya estaba dentro cuando la bóveda se puso en rojo sigue
 * usando su saldo (regla del acuerdo).
 *
 * Es un trigger y no una línea dentro de `advance_profile` a propósito: se
 * quita con un `drop trigger` y el KYC no se entera de que existió.
 */
create or replace function public.enroll_in_waitlist_on_activation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_merchant uuid;
begin
  if new.status <> 'active' or old.status not in ('pending_kyc', 'pending_pin') then
    return null;
  end if;

  v_merchant := public.helios_vault_wanting_waitlist();
  if v_merchant is null then
    return null;
  end if;

  insert into public.credit_waitlist (user_id, merchant_id, entry_reason)
  values (new.id, v_merchant, 'auto')
  on conflict (user_id) where released_at is null do nothing;

  if not found then
    return null;
  end if;

  perform public.notify(
    new.id, 'waitlist_joined',
    'Tu saldo está en lista de espera',
    'Ya estás dentro de Helios. Te avisamos en cuanto puedas usar tu saldo.',
    jsonb_build_object('merchant_id', v_merchant),
    'waitlist_joined', '{}'::jsonb
  );

  return null;
end;
$$;

revoke all on function public.enroll_in_waitlist_on_activation() from public, anon, authenticated;

drop trigger if exists profiles_waitlist_on_activation on public.profiles;
create trigger profiles_waitlist_on_activation
  after update of status on public.profiles
  for each row execute function public.enroll_in_waitlist_on_activation();

-- ---------------------------------------------------------------------------
-- 5. El saldo se apaga mientras se espera
-- ---------------------------------------------------------------------------
/**
 * Cuerpo de 20260830240000 con UNA rama más. En espera, disponible 0 — igual
 * que en mora, y por lo mismo: es lo que ven grupos y elegibilidad.
 */
create or replace function public.available_usd(p_user uuid)
returns numeric
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select case
    when public.helios_in_arrears(p_user) then 0
    -- NUEVO (piloto): en lista de espera, nada.
    when public.helios_waitlisted(p_user) then 0
    else greatest(
      coalesce((select l.monthly_limit_usd
                from public.profiles p
                join public.levels l on l.level = p.level
                where p.id = p_user), 0)
      - public.helios_credit_used_usd(p_user),
      0
    )
  end;
$$;

revoke all on function public.available_usd(uuid) from public, anon, authenticated;

/**
 * Cuerpo de 20260830240000 con dos campos nuevos: `waitlisted` y
 * `waitlisted_since`. La app tiene que poder decir POR QUÉ el disponible es
 * cero, o se lee como un error — misma razón que `in_arrears`.
 */
create or replace function public.my_available_balance()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user      uuid := auth.uid();
  v_level     smallint;
  v_limit     numeric(18,4);
  v_block     public.user_credit_blocks%rowtype;
  v_used      numeric(18,4) := 0;
  v_fee       numeric(18,4) := 0;
  v_to_unlock numeric(18,4) := 0;
  v_reserved  numeric(18,4) := 0;
  v_arrears   boolean := false;
  v_waitlisted boolean := false;
  v_since     timestamptz;
  v_next_owed numeric(18,4);
  v_next_free numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select level into v_level from public.profiles where id = v_user;
  select monthly_limit_usd into v_limit from public.levels where level = v_level;

  v_arrears := public.helios_in_arrears(v_user);
  v_used    := public.helios_credit_used_usd(v_user);

  -- NUEVO (piloto)
  v_waitlisted := public.helios_waitlisted(v_user);
  if v_waitlisted then
    select entered_at into v_since
    from public.credit_waitlist
    where user_id = v_user and released_at is null;
  end if;

  select * into v_block
  from public.user_credit_blocks
  where user_id = v_user and closed_at is null;

  if found then
    v_fee := v_block.fee_usd;
    v_to_unlock := v_block.charged_usd + v_block.fee_usd - v_block.paid_usd;
  end if;

  select owed, frees into v_next_owed, v_next_free
  from (
    select
      sum(i.amount_usd) filter (where i.status = 'pending') as owed,
      sum(i.financed_usd)                                   as frees
    from public.installments i
    where i.user_id = v_user
      and exists (
        select 1 from public.installments j
        where j.charge_id = i.charge_id and j.user_id = i.user_id and j.status = 'pending'
      )
    group by i.charge_id
  ) c
  order by owed
  limit 1;

  v_reserved := public.group_holds_usd(v_user);

  return jsonb_build_object(
    'limit_usd', v_limit,
    'available_usd', case
      when v_arrears or v_waitlisted then 0
      else greatest(v_limit - v_used - v_reserved, 0)
    end,
    'in_arrears', v_arrears,
    -- NUEVO (piloto): el saldo está en lista de espera, y desde cuándo.
    'waitlisted', v_waitlisted,
    'waitlisted_since', v_since,
    'open_debt_usd', v_used,
    'service_fee_usd', v_fee,
    'amount_to_unlock_usd', v_to_unlock,
    'next_unlock_owed_usd', v_next_owed,
    'next_unlock_frees_usd', v_next_free,
    'reserved_in_groups_usd', v_reserved
  );
end;
$$;

revoke all on function public.my_available_balance() from public, anon;
grant execute on function public.my_available_balance() to authenticated;

/**
 * Cuerpo de 20260830240000 con el bloque marcado NUEVO. Es el único sitio que
 * crea deuda, así que es el único sitio donde hace falta cerrar la puerta:
 * `confirm_charge`, el cobro de grupo y la adjudicación pasan todos por aquí.
 *
 * Solo si hay algo que financiar: en un reparto de grupo alguien en espera
 * tiene capacidad 0 y podría recibir una parte de 0 — eso no es deuda y no
 * debe tumbar la cuenta de los demás.
 */
create or replace function public.helios_assign_debt(
  p_user          uuid,
  p_charge_id     uuid,
  p_financed_usd  numeric,
  p_payable_usd   numeric,
  p_due_1         date,
  p_due_2         date,
  p_over_limit_message text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_limit    numeric(18,4);
  v_block    public.user_credit_blocks%rowtype;
  v_used     numeric(18,4);
  v_first    numeric(18,4);
  v_second   numeric(18,4);
  v_fin_1    numeric(18,4);
  v_fin_2    numeric(18,4);
begin
  -- ── NUEVO (piloto) ──────────────────────────────────────────────────────
  if p_financed_usd > 0 and public.helios_waitlisted(p_user) then
    raise exception 'Tu saldo está en lista de espera: te avisaremos cuando puedas usarlo'
      using errcode = '22023';
  end if;
  -- ─────────────────────────────────────────────────────────────────────────

  select monthly_limit_usd into v_limit
  from public.levels l
  join public.profiles p on p.level = l.level
  where p.id = p_user;

  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user and closed_at is null
  for update;

  if not found then
    insert into public.user_credit_blocks (user_id) values (p_user)
    returning * into v_block;
  end if;

  v_used := public.helios_credit_used_usd(p_user);

  if v_used + p_financed_usd > v_limit then
    raise exception '%', p_over_limit_message using errcode = '22023';
  end if;

  v_first  := round(p_payable_usd / 2, 2);
  v_second := p_payable_usd - v_first;
  v_fin_1  := round(p_financed_usd / 2, 2);
  v_fin_2  := p_financed_usd - v_fin_1;

  insert into public.installments
    (charge_id, user_id, sequence, amount_usd, due_date, financed_usd) values
    (p_charge_id, p_user, 1, v_first,  p_due_1, v_fin_1),
    (p_charge_id, p_user, 2, v_second, p_due_2, v_fin_2);

  update public.user_credit_blocks
    set charged_usd = charged_usd + p_financed_usd,
        fee_usd     = fee_usd + (p_payable_usd - p_financed_usd)
  where id = v_block.id;

  return jsonb_build_object(
    'installment_1_usd', v_first,
    'installment_2_usd', v_second,
    'financed_usd', p_financed_usd,
    'payable_usd', p_payable_usd
  );
end;
$$;

revoke all on function public.helios_assign_debt(uuid, uuid, numeric, numeric, date, date, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Lo que ve el comercio
-- ---------------------------------------------------------------------------
/**
 * La bóveda del local de quien pregunta, o null si no tiene (o está apagada):
 * el panel no pinta nada y la funcionalidad desaparece sin dejar rastro.
 *
 * Solo el gerente: es dinero del local, como Métricas y Liquidaciones.
 */
create or replace function public.my_merchant_vault()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_state    jsonb;
  v_topups   jsonb;
begin
  if v_merchant is null then
    return null;
  end if;

  v_state := public.merchant_vault_state(v_merchant);
  if v_state is null or not (v_state->>'is_active')::boolean then
    return null;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id,
      'amount_usd', t.amount_usd,
      'note', t.note,
      'created_at', t.created_at
    ) order by t.created_at desc), '[]'::jsonb)
    into v_topups
  from (
    select * from public.merchant_vault_topups
    where merchant_id = v_merchant
    order by created_at desc
    limit 20
  ) t;

  -- Al local le interesa cuánto hay y cómo se mueve. Los interruptores de la
  -- lista de espera son cosa de Ronda.
  return jsonb_build_object(
    'funded_usd',      v_state->'funded_usd',
    'consumed_usd',    v_state->'consumed_usd',
    'balance_usd',     v_state->'balance_usd',
    'reference_usd',   v_state->'reference_usd',
    'threshold_pct',   v_state->'threshold_pct',
    'threshold_usd',   v_state->'threshold_usd',
    'below_threshold', v_state->'below_threshold',
    'charge_count',    v_state->'charge_count',
    'opened_at',       v_state->'opened_at',
    'last_topup_at',   v_state->'last_topup_at',
    'topups',          v_topups
  );
end;
$$;

revoke all on function public.my_merchant_vault() from public, anon;
grant execute on function public.my_merchant_vault() to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Super admin
-- ---------------------------------------------------------------------------

/** Mismo criterio que el resto de acciones que mueven dinero o parámetros. */
create or replace function public.helios_assert_super_admin(p_what text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super_admin puede %', p_what using errcode = '42501';
  end if;
  return v_actor;
end;
$$;

revoke all on function public.helios_assert_super_admin(text) from public, anon, authenticated;

/** Todas las bóvedas con su estado. Lectura: la ve también el operador. */
create or replace function public.admin_vault_overview()
returns jsonb
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select case
    when not public.is_platform_admin() then null
    else coalesce((
      select jsonb_agg(public.merchant_vault_state(v.merchant_id) order by v.opened_at)
      from public.merchant_vaults v
    ), '[]'::jsonb)
  end;
$$;

revoke all on function public.admin_vault_overview() from public, anon;
grant execute on function public.admin_vault_overview() to authenticated;

/** Las recargas de una bóveda, con quién las anotó. */
create or replace function public.admin_vault_topups(p_merchant_id uuid, p_limit integer default 50)
returns table (
  id          uuid,
  amount_usd  numeric,
  note        text,
  actor       uuid,
  actor_name  text,
  created_at  timestamptz
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select t.id, t.amount_usd, t.note, t.actor, a.full_name, t.created_at
  from public.merchant_vault_topups t
  left join public.platform_admins a on a.user_id = t.actor
  where public.is_platform_admin()
    and t.merchant_id = p_merchant_id
  order by t.created_at desc
  limit greatest(coalesce(p_limit, 50), 1);
$$;

revoke all on function public.admin_vault_topups(uuid, integer) from public, anon;
grant execute on function public.admin_vault_topups(uuid, integer) to authenticated;

/**
 * Crea o ajusta la bóveda de un comercio: interruptores y umbral.
 *
 * Abrirla no deposita nada — para eso está `admin_vault_topup`. Apagarla
 * (`p_is_active = false`) desbloquea a todo el mundo al instante y esconde la
 * bóveda al comercio; la historia se queda.
 */
create or replace function public.admin_set_vault(
  p_merchant_id             uuid,
  p_is_active               boolean,
  p_waitlist_auto_enroll    boolean,
  p_waitlist_blocks_balance boolean,
  p_threshold_pct           numeric,
  p_note                    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('configurar la bóveda');
  v_before jsonb;
begin
  if not exists (select 1 from public.merchants where id = p_merchant_id) then
    raise exception 'Comercio no encontrado' using errcode = 'P0002';
  end if;

  if p_threshold_pct is null or p_threshold_pct < 0 or p_threshold_pct > 100 then
    raise exception 'El umbral es un porcentaje entre 0 y 100' using errcode = '22023';
  end if;

  v_before := public.merchant_vault_state(p_merchant_id);

  insert into public.merchant_vaults as v
    (merchant_id, is_active, waitlist_auto_enroll, waitlist_blocks_balance, threshold_pct, note)
  values
    (p_merchant_id, p_is_active, p_waitlist_auto_enroll, p_waitlist_blocks_balance,
     p_threshold_pct, nullif(trim(coalesce(p_note, '')), ''))
  on conflict (merchant_id) do update set
    is_active               = excluded.is_active,
    waitlist_auto_enroll    = excluded.waitlist_auto_enroll,
    waitlist_blocks_balance = excluded.waitlist_blocks_balance,
    threshold_pct           = excluded.threshold_pct,
    note                    = coalesce(excluded.note, v.note),
    updated_at              = now();

  perform audit.log(v_actor, 'vault.configured', p_merchant_id, jsonb_build_object(
    'before', case when v_before is null then null else jsonb_build_object(
      'is_active', v_before->'is_active',
      'waitlist_auto_enroll', v_before->'waitlist_auto_enroll',
      'waitlist_blocks_balance', v_before->'waitlist_blocks_balance',
      'threshold_pct', v_before->'threshold_pct'
    ) end,
    'after', jsonb_build_object(
      'is_active', p_is_active,
      'waitlist_auto_enroll', p_waitlist_auto_enroll,
      'waitlist_blocks_balance', p_waitlist_blocks_balance,
      'threshold_pct', p_threshold_pct
    ),
    'note', p_note
  ));

  return public.merchant_vault_state(p_merchant_id);
end;
$$;

revoke all on function public.admin_set_vault(uuid, boolean, boolean, boolean, numeric, text)
  from public, anon;
grant execute on function public.admin_set_vault(uuid, boolean, boolean, boolean, numeric, text)
  to authenticated;

/**
 * Anota una recarga. Es dinero que salió de Ronda hacia el local, así que
 * exige motivo (la referencia de la transferencia, normalmente) y queda en la
 * bitácora.
 *
 * NO libera a nadie de la lista: la liberación es manual y progresiva, que es
 * lo que permite dosificar el gasto contra lo que se acaba de depositar.
 */
create or replace function public.admin_vault_topup(
  p_merchant_id uuid,
  p_amount_usd  numeric,
  p_note        text
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := public.helios_assert_super_admin('recargar la bóveda');
  v_id    uuid;
begin
  if p_amount_usd is null or p_amount_usd <= 0 then
    raise exception 'La recarga tiene que ser mayor que cero' using errcode = '22023';
  end if;

  if p_note is null or length(trim(p_note)) < 3 then
    raise exception 'Recargar la bóveda requiere motivo o referencia' using errcode = '22023';
  end if;

  if not exists (select 1 from public.merchant_vaults where merchant_id = p_merchant_id) then
    raise exception 'Ese comercio no tiene bóveda: ábrela primero' using errcode = '22023';
  end if;

  insert into public.merchant_vault_topups (merchant_id, amount_usd, note, actor)
  values (p_merchant_id, round(p_amount_usd, 2), trim(p_note), v_actor)
  returning id into v_id;

  perform audit.log(v_actor, 'vault.topup', p_merchant_id, jsonb_build_object(
    'topup_id', v_id, 'amount_usd', round(p_amount_usd, 2), 'note', trim(p_note)
  ));

  return public.merchant_vault_state(p_merchant_id);
end;
$$;

revoke all on function public.admin_vault_topup(uuid, numeric, text) from public, anon;
grant execute on function public.admin_vault_topup(uuid, numeric, text) to authenticated;

/** La lista de espera de una bóveda: quién espera, desde cuándo, y quién salió. */
create or replace function public.admin_waitlist(
  p_merchant_id      uuid,
  p_include_released boolean default false,
  p_limit            integer default 200
)
returns table (
  id               uuid,
  user_id          uuid,
  full_name        text,
  phone_e164       text,
  document_number  text,
  user_status      text,
  level            smallint,
  entered_at       timestamptz,
  entry_reason     text,
  entry_note       text,
  entered_by_name  text,
  released_at      timestamptz,
  release_note     text,
  released_by_name text
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select
    w.id, w.user_id, p.full_name, p.phone_e164, p.document_number,
    p.status::text, p.level,
    w.entered_at, w.entry_reason, w.entry_note, ea.full_name,
    w.released_at, w.release_note, ra.full_name
  from public.credit_waitlist w
  join public.profiles p on p.id = w.user_id
  left join public.platform_admins ea on ea.user_id = w.entered_by
  left join public.platform_admins ra on ra.user_id = w.released_by
  where public.is_platform_admin()
    and w.merchant_id = p_merchant_id
    and (p_include_released or w.released_at is null)
  -- Los que esperan primero y por orden de llegada: es el orden en que se
  -- liberan. Los ya liberados, los más recientes arriba.
  order by (w.released_at is not null), w.entered_at, w.released_at desc
  limit greatest(coalesce(p_limit, 200), 1);
$$;

revoke all on function public.admin_waitlist(uuid, boolean, integer) from public, anon;
grant execute on function public.admin_waitlist(uuid, boolean, integer) to authenticated;

/**
 * Libera a una persona: su saldo vuelve y se le avisa.
 *
 * Es la acción que gasta bóveda, así que va de una en una con motivo. Para
 * una tanda está `admin_waitlist_release_oldest`, que llama a esta.
 */
create or replace function public.admin_waitlist_release(p_user_id uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := public.helios_assert_super_admin('liberar la lista de espera');
  v_row   public.credit_waitlist%rowtype;
begin
  if p_note is null or length(trim(p_note)) < 3 then
    raise exception 'Liberar a alguien requiere motivo' using errcode = '22023';
  end if;

  update public.credit_waitlist
    set released_at = now(), released_by = v_actor, release_note = trim(p_note)
  where user_id = p_user_id and released_at is null
  returning * into v_row;

  if not found then
    raise exception 'Esa persona no está en la lista de espera' using errcode = 'P0002';
  end if;

  perform public.notify(
    p_user_id, 'waitlist_released',
    'Ya puedes usar tu saldo',
    'Tu saldo quedó activo. Sal hoy y paga en dos cuotas.',
    jsonb_build_object('merchant_id', v_row.merchant_id),
    'waitlist_released', '{}'::jsonb
  );

  perform audit.log(v_actor, 'waitlist.released', p_user_id, jsonb_build_object(
    'waitlist_id', v_row.id, 'merchant_id', v_row.merchant_id,
    'waited_since', v_row.entered_at, 'note', trim(p_note)
  ));

  return jsonb_build_object('ok', true, 'user_id', p_user_id, 'released_at', v_row.released_at);
end;
$$;

revoke all on function public.admin_waitlist_release(uuid, text) from public, anon;
grant execute on function public.admin_waitlist_release(uuid, text) to authenticated;

/** Libera a los N que más llevan esperando. Devuelve cuántos salieron. */
create or replace function public.admin_waitlist_release_oldest(
  p_merchant_id uuid,
  p_count       integer,
  p_note        text
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor    uuid := public.helios_assert_super_admin('liberar la lista de espera');
  v_user     uuid;
  v_released integer := 0;
begin
  if p_count is null or p_count < 1 or p_count > 500 then
    raise exception 'Indica cuántas personas liberar (1 a 500)' using errcode = '22023';
  end if;

  for v_user in
    select user_id from public.credit_waitlist
    where merchant_id = p_merchant_id and released_at is null
    order by entered_at
    limit p_count
    for update skip locked
  loop
    perform public.admin_waitlist_release(v_user, p_note);
    v_released := v_released + 1;
  end loop;

  perform audit.log(v_actor, 'waitlist.released_batch', p_merchant_id, jsonb_build_object(
    'requested', p_count, 'released', v_released, 'note', p_note
  ));

  return jsonb_build_object('ok', true, 'released', v_released);
end;
$$;

revoke all on function public.admin_waitlist_release_oldest(uuid, integer, text) from public, anon;
grant execute on function public.admin_waitlist_release_oldest(uuid, integer, text) to authenticated;

/**
 * Mete a alguien en la lista a mano. Para el control fino: un activo que se
 * quiere frenar, o alguien que se coló entre dos recargas.
 */
create or replace function public.admin_waitlist_enroll(
  p_user_id     uuid,
  p_merchant_id uuid,
  p_note        text
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('meter a alguien en la lista de espera');
  v_status public.profile_status;
  v_id     uuid;
begin
  if p_note is null or length(trim(p_note)) < 3 then
    raise exception 'Meter a alguien en la lista requiere motivo' using errcode = '22023';
  end if;

  if not exists (select 1 from public.merchant_vaults where merchant_id = p_merchant_id) then
    raise exception 'Ese comercio no tiene bóveda' using errcode = '22023';
  end if;

  select status into v_status from public.profiles where id = p_user_id;
  if not found then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  insert into public.credit_waitlist (user_id, merchant_id, entry_reason, entered_by, entry_note)
  values (p_user_id, p_merchant_id, 'manual', v_actor, trim(p_note))
  on conflict (user_id) where released_at is null do nothing
  returning id into v_id;

  if v_id is null then
    raise exception 'Esa persona ya está en la lista de espera' using errcode = '22023';
  end if;

  perform public.notify(
    p_user_id, 'waitlist_joined',
    'Tu saldo está en lista de espera',
    'Ya estás dentro de Helios. Te avisamos en cuanto puedas usar tu saldo.',
    jsonb_build_object('merchant_id', p_merchant_id),
    'waitlist_joined', '{}'::jsonb
  );

  perform audit.log(v_actor, 'waitlist.enrolled', p_user_id, jsonb_build_object(
    'waitlist_id', v_id, 'merchant_id', p_merchant_id,
    'user_status', v_status, 'note', trim(p_note)
  ));

  return jsonb_build_object('ok', true, 'waitlist_id', v_id);
end;
$$;

revoke all on function public.admin_waitlist_enroll(uuid, uuid, text) from public, anon;
grant execute on function public.admin_waitlist_enroll(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Los avisos, editables desde el panel
-- ---------------------------------------------------------------------------
insert into public.notification_templates (
  key, type, label, trigger_label, help,
  variables, required_variables,
  default_title, default_body,
  editable, can_disable, cron_job, lead_days, run_at, sort_order
) values
(
  'waitlist_joined', 'waitlist_joined'::public.notification_type,
  'Saldo en lista de espera',
  'Al verificarse alguien con la bóveda del comercio piloto en rojo, o al meterlo a mano desde el panel.',
  'TEMPORAL (piloto). La app ya lo enseña en Inicio; este aviso lo confirma en la bandeja.',
  '{}', '{}',
  'Tu saldo está en lista de espera',
  'Ya estás dentro de Helios. Te avisamos en cuanto puedas usar tu saldo.',
  true, true, null, null, null, 160
),
(
  'waitlist_released', 'waitlist_released'::public.notification_type,
  'Saldo liberado',
  'Al liberar a alguien de la lista de espera desde el panel.',
  'TEMPORAL (piloto). No se puede apagar: es la única forma en que la persona se entera de que ya puede salir.',
  '{}', '{}',
  'Ya puedes usar tu saldo',
  'Tu saldo quedó activo. Sal hoy y paga en dos cuotas.',
  true, false, null, null, null, 170
)
on conflict (key) do nothing;
