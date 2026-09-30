-- ============================================================================
-- Ronda — La mora deja de ser gratis: $4, con 2 días de gracia
--
-- Decisión del 2026-08-30, y revierte la del 2026-08-22 ("no hay cargo por
-- mora", docs/00-BASES §2.4). Ahora hay tres cosas y conviene no confundirlas:
--
--   | Cuándo                 | Qué pasa                                      |
--   |------------------------|-----------------------------------------------|
--   | Día 1 de retraso       | Saldo congelado (`frozen`). SIN cargo.        |
--   | Pasados 2 días         | **$4 a la deuda**, una sola vez               |
--   | > 15 días              | Baja de nivel + `suspended`                   |
--   | > 30 días              | Expulsión + castigo contable                  |
--
-- **El estado y el cargo van por separado a propósito.** El congelamiento sigue
-- entrando al día siguiente del vencimiento: es la palanca que hace pagar y no
-- cuesta dinero a nadie. La gracia de 2 días es solo para el cargo, y cubre el
-- caso que de verdad pasa — el que paga el lunes una cuota que vencía el
-- sábado, o el que transfirió a tiempo y la conciliación tardó.
--
-- ---------------------------------------------------------------------------
-- "Una vez por usuario", dicho con precisión: una vez por BLOQUE DE CRÉDITO
-- ---------------------------------------------------------------------------
-- El cargo es uno por episodio de mora, no uno por cuota vencida: quien arrastra
-- tres cuotas de tres compras distintas paga $4, no $12.
--
-- Un "episodio" es el bloque de crédito abierto (`user_credit_blocks`), y no es
-- una analogía cómoda — es exactamente la misma cosa. El bloque nace con la
-- primera compra a crédito y solo muere cuando el usuario salda TODO
-- (docs/00-BASES §2.2). Así que "ponerse al día" y "cerrar el bloque" son el
-- mismo evento, y un unique index sobre `credit_block_id` es toda la lógica de
-- "una sola vez" que hace falta. El cron puede correr veinte veces al día sin
-- cobrar veinte veces.
--
-- De ahí sale un segundo invariante que el resto del archivo da por bueno:
-- **como solo hay un bloque abierto por usuario, solo puede haber un cargo
-- pendiente por usuario.** Se refuerza con su propio índice parcial porque de
-- él cuelga que la cotización pueda llevar un único `late_fee_id` en vez de una
-- tabla de enlace.
--
-- ---------------------------------------------------------------------------
-- Cómo se paga
-- ---------------------------------------------------------------------------
-- **Viaja pegado a la siguiente cotización, sin poder deseleccionarlo.** No es
-- una cuota: no tiene vencimiento propio ni se puede pagar suelto. El usuario
-- elige qué cuotas paga y el cargo se suma al total; si no fuera así habría que
-- inventarle una pantalla propia y un reporte propio para cobrar $4.
--
-- **Sin IVA, y es ingreso de Ronda** (Dr user_receivable / Cr platform_revenue).
-- Una penalización por incumplimiento es indemnizatoria, no la contraprestación
-- de un servicio, así que no genera débito fiscal. Ojo con la consecuencia:
-- estos $4 SÍ entran en la base de IAE y LOCTI, como el fee del servicio.
--
-- ---------------------------------------------------------------------------
-- La baranda legal
-- ---------------------------------------------------------------------------
-- docs/00-BASES §2.4 ya avisaba de que un cargo por mora mal puesto roza la ley
-- de protección al consumidor. Lo que lo mantiene defendible es que sea **fijo,
-- único y anunciado**: $4 una vez, no un porcentaje que corre ni algo que se
-- repite cada semana. Si algún día se vuelve recurrente, esa conversación hay
-- que tenerla con un abogado antes que con el esquema.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Los parámetros
-- ---------------------------------------------------------------------------

/** Cuánto se cobra por caer en mora. Una sola vez por episodio. */
create or replace function public.helios_late_fee_usd()
returns numeric
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 4.00::numeric $fn$;

comment on function public.helios_late_fee_usd() is
  'Cargo fijo por mora, en USD. 0 lo desactiva sin tocar el motor. Ver docs/00-BASES 2.4.';

revoke all on function public.helios_late_fee_usd() from public, anon;
grant execute on function public.helios_late_fee_usd() to authenticated;

/**
 * Días de retraso que se perdonan antes del cargo.
 *
 * "Pasados los 2 días": el retraso tiene que SUPERAR este número, así que los
 * días 1 y 2 son gratis y el cargo entra el día 3. El congelamiento del saldo
 * no lo mira — ese sigue entrando el día 1.
 */
create or replace function public.helios_late_fee_grace_days()
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 2 $fn$;

comment on function public.helios_late_fee_grace_days() is
  'Dias de retraso perdonados antes del cargo por mora. El cargo entra al superarlo. Ver docs/00-BASES 2.4.';

revoke all on function public.helios_late_fee_grace_days() from public, anon;
grant execute on function public.helios_late_fee_grace_days() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. La tabla
-- ---------------------------------------------------------------------------

create type public.late_fee_status as enum (
  'pending',      -- devengado y en la deuda del usuario
  'paid',         -- cobrado con una cotización
  'written_off'   -- se fue en el castigo por incobrable de los 30 días
);

create table if not exists public.late_fees (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users (id) on delete cascade,
  -- El episodio de mora. Ver la cabecera: bloque abierto = episodio.
  credit_block_id uuid not null references public.user_credit_blocks (id) on delete cascade,
  amount_usd      numeric(18,4) not null check (amount_usd > 0),
  -- Cuántos días de retraso lo dispararon. Es lo que permite explicarle al
  -- usuario —o a soporte— por qué se cobró, sin reconstruirlo a mano.
  days_late       integer not null check (days_late > 0),
  business_date   date not null,
  status          public.late_fee_status not null default 'pending',
  paid_at         timestamptz,
  created_at      timestamptz not null default now(),
  constraint late_fees_paid_consistency check ((status = 'paid') = (paid_at is not null))
);

-- TODA la regla de "una sola vez por episodio", en una línea.
create unique index late_fees_one_per_block on public.late_fees (credit_block_id);

-- El invariante del que cuelga que una cotización lleve un solo `late_fee_id`.
-- Es redundante con el de arriba mientras solo haya un bloque abierto por
-- usuario, y esa redundancia es justo el punto: si algún día se permitieran dos
-- bloques, esto revienta aquí y no en la cotización.
create unique index late_fees_one_pending_per_user
  on public.late_fees (user_id) where status = 'pending';

create index late_fees_user_idx on public.late_fees (user_id, created_at desc);

alter table public.late_fees enable row level security;

create policy "late_fees_read_own"
  on public.late_fees for select
  to authenticated
  using (user_id = (select auth.uid()));

grant select on public.late_fees to authenticated;

-- Sin políticas de escritura: solo lo mueven el motor de mora y la conciliación.

comment on table public.late_fees is
  'Cargos por mora. Uno por bloque de credito (= por episodio de mora). Ver docs/00-BASES 2.4.';

-- ---------------------------------------------------------------------------
-- 3. Devengar el cargo
-- ---------------------------------------------------------------------------
/**
 * Idempotente por construcción, que es lo único que importa aquí: la llama el
 * cron diario y también cada conciliación, y las dos pueden pasar el mismo día
 * sobre el mismo usuario. La red no es un `if` sino el unique index — un `if`
 * se lo salta una carrera entre dos transacciones, un índice no.
 *
 * Devuelve el id del cargo, o null si no había nada que cobrar.
 */
create or replace function public.charge_late_fee(
  p_user_id   uuid,
  p_days_late integer
)
returns uuid
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_block  public.user_credit_blocks%rowtype;
  v_amount numeric(18,4) := public.helios_late_fee_usd();
  v_bdate  date := public.helios_business_date(now());
  v_fee_id uuid;
  v_tx     uuid;
begin
  -- Poner el parámetro en 0 apaga el cargo entero sin desconectar el motor.
  if v_amount <= 0 then
    return null;
  end if;

  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user_id and closed_at is null
  for update;

  -- Sin bloque abierto no hay deuda viva a la que sumar el cargo. Pasa con un
  -- usuario ya castigado por incobrable: su bloque se cerró.
  if not found then
    return null;
  end if;

  if exists (select 1 from public.late_fees where credit_block_id = v_block.id) then
    return null;
  end if;

  insert into public.late_fees
    (user_id, credit_block_id, amount_usd, days_late, business_date)
  values
    (p_user_id, v_block.id, v_amount, p_days_late, v_bdate)
  returning id into v_fee_id;

  -- Ingreso devengado, sin IVA. La caja no se mueve: el dinero entra cuando el
  -- usuario pague, igual que con una cuota.
  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'late_fee', 'late_fee:' || v_fee_id::text, v_bdate, v_fee_id,
    format('Cargo por mora (%s dias de retraso)', p_days_late)
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, ledger.get_or_create_account('user_receivable', p_user_id), v_amount, 0),
    (v_tx, ledger.get_or_create_account('platform_revenue', null), 0, v_amount);

  -- A la deuda del bloque. Es lo que hace que el cupo NO vuelva hasta que el
  -- cargo esté pagado: el bloque se cierra al saldarlo entero, y el cargo ya
  -- forma parte de ese entero.
  update public.user_credit_blocks
    set charged_usd = charged_usd + v_amount
  where id = v_block.id;

  -- La deuda de alguien no puede crecer en silencio.
  perform public.notify(
    p_user_id,
    'late_fee_charged',
    'Cargo por mora',
    format(
      'Se sumaron $%s a tu deuda por %s %s de retraso. Es un cargo único: no vuelve a cobrarse aunque sigas con la cuota pendiente.',
      trim(to_char(v_amount, 'FM999999990.00')),
      p_days_late,
      case when p_days_late = 1 then 'día' else 'días' end
    ),
    jsonb_build_object(
      'late_fee_id', v_fee_id,
      'amount_usd', v_amount,
      'days_late', p_days_late
    )
  );

  return v_fee_id;
end;
$$;

revoke all on function public.charge_late_fee(uuid, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. El motor de mora lo dispara
-- ---------------------------------------------------------------------------
/**
 * Cuerpo idéntico al de 20260822058000 salvo el bloque marcado NUEVO.
 *
 * El cargo va ANTES de las ramas de estado, y no dentro de una de ellas, porque
 * no depende de en cuál caiga el usuario: a partir del día 3 de retraso se cobra
 * igual esté congelado, suspendido o de camino a la expulsión. Meterlo en la
 * rama de `frozen` —que es donde apetece— habría dejado sin cargo justo a quien
 * más se retrasa, porque esa rama es la del tramo 1-14 días.
 */
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

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- El cargo por mora, pasada la gracia. No toca el estado ni depende de él:
  -- la función de arriba se encarga de que solo prenda una vez por episodio.
  if v_max_days_late > public.helios_late_fee_grace_days() then
    perform public.charge_late_fee(p_user_id, v_max_days_late);
  end if;
  -- ─────────────────────────────────────────────────────────────────────────

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
-- 5. El castigo se lleva el cargo por delante
-- ---------------------------------------------------------------------------
/**
 * Cuerpo idéntico al de 20260822058000 salvo el bloque marcado NUEVO.
 *
 * El importe castigado no cambia: el cargo ya estaba dentro de `charged_usd`
 * desde que se devengó, así que `charged − paid` lo incluye solo. Lo que hace
 * falta es sacarlo de `pending`, y no por pulcritud: si se quedara pendiente,
 * el índice `late_fees_one_pending_per_user` impediría cobrarle un cargo nuevo
 * a un usuario que volviera a operar, para siempre.
 */
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

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  update public.late_fees
    set status = 'written_off'
  where credit_block_id = v_block.id and status = 'pending';
  -- ─────────────────────────────────────────────────────────────────────────

  update public.user_credit_blocks
    set closed_at = now(), close_reason = 'charged_off'
  where id = v_block.id;
end;
$$;

revoke all on function public.charge_off_user_debt(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. La cotización lo arrastra
-- ---------------------------------------------------------------------------

alter table public.payment_quotes
  add column if not exists late_fee_id  uuid references public.late_fees (id),
  add column if not exists late_fee_usd numeric(18,4) not null default 0;

comment on column public.payment_quotes.late_fee_usd is
  'Cargo por mora incluido en esta cotizacion. Va dentro de amount_usd y de amount_ves; installment_count NO lo cuenta.';

/**
 * Cuerpo idéntico al de 20260824110000 salvo los bloques marcados NUEVO.
 *
 * El cargo pendiente se mete SIEMPRE y no se puede quitar. El cliente elige
 * cuotas; el cargo no es una cuota, no tiene vencimiento propio y no cabe en
 * `payment_quote_items` —que exige `installment_id`—, así que viaja como una
 * columna de la cotización.
 *
 * Va en `amount_usd` y en `amount_ves` porque esa es la cifra que el usuario va
 * a transferir y contra la que se concilia; `installment_count` NO lo cuenta,
 * porque es lo que la conciliación coteja contra las filas de
 * `payment_quote_items` y sumarlo ahí haría fallar esa comprobación.
 */
create or replace function public.quote_installments(p_installment_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user       uuid := auth.uid();
  v_rate       numeric(18,6);
  v_total_usd  numeric(18,4);
  v_count      integer;
  v_fee        public.late_fees%rowtype;
  v_fee_usd    numeric(18,4) := 0;
  v_grand_usd  numeric(18,4);
  v_quote      public.payment_quotes%rowtype;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if p_installment_ids is null or array_length(p_installment_ids, 1) is null then
    raise exception 'Selecciona al menos una cuota' using errcode = '22023';
  end if;

  -- Solo cuotas propias y pendientes. Si el cliente manda una ajena o ya
  -- pagada, no se cotiza a medias: se rechaza entero.
  select coalesce(sum(amount_usd), 0), count(*)
    into v_total_usd, v_count
  from public.installments
  where id = any(p_installment_ids)
    and user_id = v_user
    and status = 'pending';

  if v_count <> array_length(p_installment_ids, 1) then
    raise exception 'Alguna de las cuotas no es tuya o ya está pagada'
      using errcode = '22023';
  end if;

  -- Cuota con un pago ya reportado y sin conciliar. Se corta AQUÍ, en la
  -- cotización, y no al reportar: entre una cosa y la otra el usuario hace la
  -- transferencia, y negarle el reporte con el dinero ya enviado es el peor
  -- momento posible para decirle que no hacía falta pagar.
  if exists (
    select 1
    from public.payment_quote_items i
    join public.payment_reports r on r.quote_id = i.quote_id
    where i.installment_id = any(p_installment_ids)
      and r.user_id = v_user
      and r.status in ('reported', 'in_review')
  ) then
    raise exception
      'Ya reportaste un pago para alguna de esas cuotas y está en revisión. Te avisamos en cuanto lo confirmemos.'
      using errcode = '22023';
  end if;

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- El cargo por mora pendiente, si lo hay. Como máximo uno
  -- (`late_fees_one_pending_per_user`), así que no hace falta sumar nada.
  select * into v_fee
  from public.late_fees
  where user_id = v_user and status = 'pending';

  if found then
    v_fee_usd := v_fee.amount_usd;
  end if;

  v_grand_usd := v_total_usd + v_fee_usd;
  -- ─────────────────────────────────────────────────────────────────────────

  v_rate := public.current_fx_rate();
  if v_rate is null then
    raise exception 'No hay tasa de cambio vigente' using errcode = 'P0002';
  end if;

  insert into public.payment_quotes
    (user_id, amount_usd, fx_rate, amount_ves, installment_count, valid_until,
     late_fee_id, late_fee_usd)
  values (
    v_user,
    v_grand_usd,
    v_rate,
    round(v_grand_usd * v_rate, 2),
    v_count,
    -- Fin del día calendario en Caracas (docs/05 §1): el BCV publica una vez
    -- al día, así que una cotización de la tarde sigue viva esa noche.
    (date_trunc('day', now() at time zone 'America/Caracas') + interval '1 day')
      at time zone 'America/Caracas',
    -- Nulos los dos si no había cargo: `select into` sin fila deja el record
    -- entero en null.
    v_fee.id,
    v_fee_usd
  )
  returning * into v_quote;

  insert into public.payment_quote_items (quote_id, installment_id, amount_usd)
  select v_quote.id, id, amount_usd
  from public.installments
  where id = any(p_installment_ids);

  return jsonb_build_object(
    'quote_id', v_quote.id,
    'amount_usd', v_quote.amount_usd,
    'fx_rate', v_quote.fx_rate,
    'amount_ves', v_quote.amount_ves,
    'installment_count', v_quote.installment_count,
    -- NUEVO: partido, para que la pantalla pueda enseñar el cargo en su propia
    -- línea sin restar dos cifras que ya sabe el servidor.
    'installments_usd', v_total_usd,
    'late_fee_usd', v_quote.late_fee_usd,
    'valid_until', v_quote.valid_until,
    'destination', (
      select jsonb_build_object(
        'bank_name', bank_name, 'rif', rif, 'phone', phone, 'holder_name', holder_name
      )
      from public.payment_destinations where is_active limit 1
    )
  );
end;
$$;

revoke all on function public.quote_installments(uuid[]) from public, anon;
grant execute on function public.quote_installments(uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. La conciliación lo salda
-- ---------------------------------------------------------------------------
/**
 * Cuerpo idéntico al de 20260829020000 salvo el bloque marcado NUEVO.
 *
 * El cargo se salda con las mismas dos redes que las cuotas: tiene que seguir
 * pendiente y tiene que valer lo que valía al cotizar. Si no, se para entera —
 * asentar caja por una cifra distinta de la que se cotizó deja el receivable
 * descuadrado y sin forma de deshacerlo.
 *
 * Al sumarlo a `v_total` entra solo en las tres cosas que importan: el asiento
 * de caja, `paid_usd` del bloque y, por tanto, el cierre del bloque. Es lo
 * correcto: `user_receivable` se cargó cuando se devengó el cargo, y esto lo
 * cancela.
 */
create or replace function public.reconcile_payment(
  p_report_id uuid,
  p_actor     uuid,
  p_approve   boolean,
  p_note      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_report    public.payment_reports%rowtype;
  v_quote     public.payment_quotes%rowtype;
  v_item      record;
  v_fee       public.late_fees%rowtype;
  v_fee_usd   numeric(18,4) := 0;
  v_bdate     date;
  v_tx        uuid;
  v_acct_recv uuid;
  v_acct_cash uuid;
  v_block     public.user_credit_blocks%rowtype;
  v_total     numeric(18,4) := 0;
  v_settled   numeric(18,4);
  v_done      integer := 0;
  v_expected  integer;
begin
  select * into v_report from public.payment_reports where id = p_report_id for update;
  if not found then
    raise exception 'Reporte no encontrado' using errcode = 'P0002';
  end if;

  if v_report.status not in ('reported', 'in_review') then
    raise exception 'Este reporte ya fue resuelto (%)', v_report.status using errcode = '22023';
  end if;

  if not p_approve then
    update public.payment_reports
      set status = 'rejected', reviewed_by = p_actor, reviewed_at = now(),
          rejection_note = p_note
    where id = p_report_id;

    return jsonb_build_object('ok', true, 'status', 'rejected');
  end if;

  select * into v_quote from public.payment_quotes where id = v_report.quote_id;

  select count(*) into v_expected
  from public.payment_quote_items where quote_id = v_quote.id;

  if v_expected = 0 then
    raise exception 'La cotización % no tiene cuotas', v_quote.id using errcode = '22023';
  end if;

  v_bdate := public.helios_business_date(now());
  v_acct_recv := ledger.get_or_create_account('user_receivable', v_report.user_id);
  v_acct_cash := ledger.get_or_create_account('cash', null);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'installment_payment', 'reconcile:' || p_report_id::text, v_bdate, p_report_id,
    format('Pago conciliado de %s cuota(s)', v_quote.installment_count)
  )
  returning id into v_tx;

  for v_item in
    select i.installment_id, i.amount_usd, c.merchant_id,
           t.policy, t.per_installment_pct,
           ins.due_date,
           -- El importe que tiene la cuota AHORA, para cotejarlo con el que se
           -- congeló al cotizar.
           ins.amount_usd as current_amount_usd
    from public.payment_quote_items i
    join public.installments ins on ins.id = i.installment_id
    join public.charges c on c.id = ins.charge_id
    -- LEFT: la falta de condiciones de liquidación no puede sacar la cuota
    -- del bucle. `ins` sigue en el lado no anulable, así que el `for update`
    -- de abajo es válido.
    left join public.merchant_settlement_terms t on t.merchant_id = c.merchant_id
    where i.quote_id = v_quote.id
    for update of ins
  loop
    if v_item.policy is null then
      raise exception
        'El comercio % no tiene condiciones de liquidación: configúralas antes de conciliar este pago',
        v_item.merchant_id
        using errcode = '22023';
    end if;

    if (select status from public.installments where id = v_item.installment_id) = 'paid' then
      raise exception 'La cuota % ya estaba pagada', v_item.installment_id using errcode = '22023';
    end if;

    if v_item.current_amount_usd is distinct from v_item.amount_usd then
      raise exception
        'La cuota % cambió de importe desde que se cotizó ($% cotizados, $% ahora): no se concilia hasta revisarlo',
        v_item.installment_id, v_item.amount_usd, v_item.current_amount_usd
        using errcode = '22023';
    end if;

    update public.installments
      set status = 'paid', paid_at = now()
    where id = v_item.installment_id;

    v_total := v_total + v_item.amount_usd;
    v_done  := v_done + 1;

    -- En 'on_collection' la obligación nace al cobrar. Se DEVENGA, igual que
    -- el adelanto: la caja se mueve cuando se reporte la transferencia.
    if v_item.policy = 'on_collection' then
      v_settled := round(v_item.amount_usd * v_item.per_installment_pct * 2 / 100, 4);

      insert into public.settlements
        (merchant_id, installment_id, reason, amount_usd, business_date, due_date, status)
      values
        (v_item.merchant_id, v_item.installment_id, 'on_collection', v_settled,
         v_bdate, v_bdate, 'pending');
    end if;
  end loop;

  -- La red. Si el bucle no tocó todas las cuotas de la cotización, algo las
  -- descartó: se deshace todo antes de asentar dinero por una cifra que no
  -- corresponde con lo que se acaba de saldar.
  if v_done <> v_expected then
    raise exception
      'Se saldaron % de % cuotas de la cotización %: no se concilia a medias',
      v_done, v_expected, v_quote.id
      using errcode = '22023';
  end if;

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- El cargo por mora que viajaba en la cotización.
  if v_quote.late_fee_id is not null then
    select * into v_fee
    from public.late_fees where id = v_quote.late_fee_id for update;

    if not found or v_fee.status <> 'pending' then
      raise exception
        'El cargo por mora de esta cotización ya no está pendiente (%): revísalo antes de conciliar',
        coalesce(v_fee.status::text, 'no encontrado')
        using errcode = '22023';
    end if;

    if v_fee.amount_usd is distinct from v_quote.late_fee_usd then
      raise exception
        'El cargo por mora cambió de importe desde que se cotizó ($% cotizados, $% ahora): no se concilia hasta revisarlo',
        v_quote.late_fee_usd, v_fee.amount_usd
        using errcode = '22023';
    end if;

    update public.late_fees
      set status = 'paid', paid_at = now()
    where id = v_fee.id;

    v_fee_usd := v_fee.amount_usd;
    v_total   := v_total + v_fee_usd;
  end if;
  -- ─────────────────────────────────────────────────────────────────────────

  -- Lo único que mueve caja aquí es el dinero que ENTRÓ del usuario.
  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_cash, v_total, 0),
    (v_tx, v_acct_recv, 0, v_total);

  update public.payment_reports
    set status = 'reconciled', reviewed_by = p_actor, reviewed_at = now(),
        rejection_note = coalesce(p_note, rejection_note)
  where id = p_report_id;

  select * into v_block
  from public.user_credit_blocks
  where user_id = v_report.user_id and closed_at is null
  for update;

  if found then
    update public.user_credit_blocks
      set paid_usd = paid_usd + v_total
    where id = v_block.id;

    if v_block.paid_usd + v_total >= v_block.charged_usd then
      update public.user_credit_blocks
        set closed_at = now(), close_reason = 'paid'
      where id = v_block.id;
    end if;
  end if;

  perform public.recompute_profile_mora_state(v_report.user_id);

  return jsonb_build_object(
    'ok', true, 'status', 'reconciled',
    'amount_usd', v_total,
    'installments', v_done,
    'late_fee_usd', v_fee_usd
  );
end;
$$;

revoke all on function public.reconcile_payment(uuid, uuid, boolean, text)
  from public, anon, authenticated;

comment on function public.reconcile_payment(uuid, uuid, boolean, text) is
  'Aprueba o rechaza un reporte de pago. Al aprobar salda TODAS las cuotas de la cotizacion y su cargo por mora, o no salda ninguna, y solo si sus importes no han cambiado desde que se cotizaron.';

-- ---------------------------------------------------------------------------
-- 8. Lo que la app tiene que poder leer
-- ---------------------------------------------------------------------------
/**
 * El cargo pendiente del usuario, o null.
 *
 * Existe aparte de la cotización porque la pantalla de Cuotas tiene que
 * enseñarlo ANTES de que el usuario seleccione nada — si apareciera solo al
 * cotizar, el total saltaría $4 en el último paso y eso es exactamente cómo se
 * pierde la confianza en una cifra.
 */
create or replace function public.my_pending_late_fee()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id',            id,
    'amount_usd',    amount_usd,
    'days_late',     days_late,
    'business_date', business_date,
    'created_at',    created_at
  )
  from public.late_fees
  where user_id = auth.uid() and status = 'pending'
  limit 1;
$$;

comment on function public.my_pending_late_fee() is
  'El cargo por mora pendiente del usuario, o null. Se paga junto a la siguiente cotizacion.';

revoke all on function public.my_pending_late_fee() from public, anon;
grant execute on function public.my_pending_late_fee() to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Lo que tiene que ver quien concilia
-- ---------------------------------------------------------------------------
/**
 * `payment_queue` con el cargo por mora.
 *
 * Sin esto, el operador ve un importe que no cuadra con ninguna suma de cuotas
 * y no tiene forma de saber de dónde salen esos $4 — que es exactamente el
 * momento en el que un pago legítimo se marca como sospechoso.
 *
 * La columna va AL FINAL: `create or replace view` deja añadir columnas por la
 * cola, pero no reordenar ni quitar las que ya existen.
 */
create or replace view public.payment_queue
with (security_invoker = true)
as
select
  r.id                as report_id,
  r.status,
  r.created_at,
  r.bank,
  r.reference,
  r.payer_document,
  r.payer_phone,
  r.rejection_note,
  q.amount_usd,
  q.amount_ves,
  q.fx_rate,
  q.installment_count,
  p.id                as user_id,
  p.full_name,
  p.phone_e164,
  p.status            as user_status,
  (
    select count(*) - 1 from public.payment_reports r2
    where r2.bank = r.bank and r2.reference = r.reference
      and r2.reference is not null and r2.status <> 'rejected'
  )                   as reference_collisions,
  -- Cuántos movimientos del banco encajan. 1 = verificado; 0 = no aparece
  -- (todavía); más de 1 = hay que mirarlo a mano.
  (
    select count(*) from public.bank_statement_lines l
    where r.reference is not null
      and l.reference like '%' || r.reference
      and abs(l.amount_ves - q.amount_ves) <= 1.00
      and l.moved_on between (r.created_at::date - 5) and (r.created_at::date + 5)
  )                   as statement_matches,
  q.late_fee_usd
from public.payment_reports r
join public.payment_quotes q on q.id = r.quote_id
join public.profiles p on p.id = r.user_id;

comment on view public.payment_queue is
  'Cola de conciliacion. `statement_matches` coteja contra el estado de cuenta importado; `late_fee_usd` es la parte del importe que NO son cuotas.';

grant select on public.payment_queue to authenticated;
