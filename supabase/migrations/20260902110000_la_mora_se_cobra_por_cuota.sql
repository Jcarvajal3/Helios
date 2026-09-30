-- ============================================================================
-- Ronda — El cargo por mora pasa a ser $2 POR CUOTA, con 3 días de gracia
--
-- Decisión del 2026-09-02. Cambian las tres cosas del cargo a la vez:
--
--   |            | Antes                    | Ahora                          |
--   |------------|--------------------------|--------------------------------|
--   | Importe    | $4                       | **$2**                         |
--   | Alcance    | uno por EPISODIO de mora | **uno por CUOTA retrasada**    |
--   | Gracia     | 2 días (entra el día 3)  | **3 días (entra el día 4)**    |
--
-- El congelamiento del saldo no se toca: sigue entrando el día 1 y sigue sin
-- costar dinero. La gracia es solo para el cargo.
--
-- ---------------------------------------------------------------------------
-- Lo que de verdad cambia: el cargo deja de ser único
-- ---------------------------------------------------------------------------
-- Hasta hoy el cargo era uno por bloque de crédito, y eso hacía que toda la
-- lógica de "una sola vez" cupiera en un unique index sobre `credit_block_id`.
-- Ahora **cada cuota que se pasa de 3 días trae su propio cargo**, así que el
-- índice se muda a `installment_id` y de él cuelga todo lo demás:
--
--   · un usuario puede tener VARIOS cargos pendientes a la vez, así que se cae
--     `late_fees_one_pending_per_user` y con él la suposición de que una
--     cotización podía llevar un único `late_fee_id`. Entra una tabla de
--     enlace, `payment_quote_late_fees`, igual que `payment_quote_items`;
--   · el cargo viaja con SU cuota. Quien paga una de tres cuotas vencidas paga
--     un cargo, no tres — que es lo que quiere decir "se te suma el cargo al
--     pago total de la cuota";
--   · el aviso se manda UNA vez por corrida del motor y no uno por cargo. Tres
--     cuotas que se pasan el mismo día son una mala noticia, no tres.
--
-- **Con dos cuotas por compra, una compra impagada acumula los mismos $4 que
-- antes.** Lo que cambia es el reparto: quien se retrasa en una sola cuota paga
-- $2 en vez de $4, y quien arrastra cuotas de tres compras distintas paga $6 en
-- vez de $4. El cargo pasa a escalar con el tamaño del incumplimiento.
--
-- ⚠️ **Y con eso deja de cumplirse una de las tres condiciones que docs/00-BASES
-- §2.4 daba por la defensa legal del cargo:** era "fijo, único y anunciado", y
-- ahora es fijo y anunciado pero ya no único. El techo tampoco es infinito —no
-- puede haber más cargos que cuotas debidas, y ninguna cuota se cobra dos
-- veces— pero es un cambio de naturaleza, no de importe, y conviene que lo vea
-- un abogado antes que el esquema. Queda dicho aquí y en el doc.
--
-- ---------------------------------------------------------------------------
-- El cargo huérfano: la regla que tapa el agujero
-- ---------------------------------------------------------------------------
-- Atar el cargo a una cuota abre un caso que antes no existía: la cuota se paga
-- con una cotización hecha ANTES de que el cargo prendiera, y el cargo se queda
-- pendiente colgando de una cuota ya pagada — sin ninguna cotización futura que
-- lo pueda recoger, y bloqueando el cierre del bloque para siempre.
--
-- La regla: **un cargo cuya cuota ya no está pendiente viaja con el siguiente
-- pago, sea cual sea.** Es exactamente lo que hacía el cargo por episodio, y
-- solo se aplica cuando el cargo se queda sin su cuota. Los cargos del modelo
-- viejo, que no tienen cuota, entran por la misma puerta.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Los parámetros
-- ---------------------------------------------------------------------------

/** Cuánto se cobra por cada cuota que se pasa de la gracia. */
create or replace function public.helios_late_fee_usd()
returns numeric
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 2.00::numeric $fn$;

comment on function public.helios_late_fee_usd() is
  'Cargo fijo por CADA cuota retrasada, en USD. $2 desde 2026-09-02. 0 lo desactiva sin tocar el motor. Ver docs/00-BASES 2.4.';

revoke all on function public.helios_late_fee_usd() from public, anon;
grant execute on function public.helios_late_fee_usd() to authenticated;

/**
 * Días de retraso que se perdonan antes del cargo.
 *
 * El retraso tiene que SUPERAR este número: con 3, los días 1, 2 y 3 son
 * gratis y el cargo entra el día 4. El congelamiento del saldo no lo mira —
 * ese sigue entrando el día 1.
 */
create or replace function public.helios_late_fee_grace_days()
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 3 $fn$;

comment on function public.helios_late_fee_grace_days() is
  'Dias de retraso perdonados antes del cargo por mora. 3 desde 2026-09-02: el cargo entra el dia 4. Ver docs/00-BASES 2.4.';

revoke all on function public.helios_late_fee_grace_days() from public, anon;
grant execute on function public.helios_late_fee_grace_days() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El cargo se ata a una cuota
-- ---------------------------------------------------------------------------
-- `on delete cascade` como las otras dos claves de la tabla: si se borra el
-- usuario, sus cuotas y sus cargos se van juntos y ningún orden de cascada deja
-- una fila colgando.
alter table public.late_fees
  add column if not exists installment_id uuid
    references public.installments (id) on delete cascade;

comment on column public.late_fees.installment_id is
  'La cuota que lo disparó. Null solo en los cargos del modelo por episodio (anteriores al 2026-09-02).';

-- TODA la regla de "una sola vez por cuota", en una línea. Parcial porque los
-- cargos viejos no tienen cuota a la que atarse y pueden ser varios por usuario.
drop index if exists public.late_fees_one_per_block;
drop index if exists public.late_fees_one_pending_per_user;

create unique index late_fees_one_per_installment
  on public.late_fees (installment_id) where installment_id is not null;

-- El bloque deja de ser único por usuario, pero se sigue consultando entero en
-- el castigo por incobrable.
create index if not exists late_fees_block_idx on public.late_fees (credit_block_id);

comment on table public.late_fees is
  'Cargos por mora. Uno por CUOTA retrasada desde el 2026-09-02. Ver docs/00-BASES 2.4.';

-- Los cargos ya devengados se atan a la cuota vencida más antigua que no tenga
-- uno. En producción no hay ninguno; en dev son de las pruebas. Solo los
-- `pending`: los pagados y los castigados son historia y se quedan como están.
--
-- No hay carrera posible por el índice de arriba: bajo el modelo viejo había
-- como mucho UN cargo pendiente por usuario, así que dos filas no pueden pelear
-- por la misma cuota.
with candidatos as (
  select f.id as fee_id,
         (select i.id
          from public.installments i
          where i.user_id = f.user_id
            and i.status = 'pending'
            and i.due_date < public.helios_business_date(now())
            and not exists (
              select 1 from public.late_fees f2 where f2.installment_id = i.id
            )
          order by i.due_date
          limit 1) as inst_id
  from public.late_fees f
  where f.installment_id is null and f.status = 'pending'
)
update public.late_fees f
   set installment_id = c.inst_id
  from candidatos c
 where c.fee_id = f.id and c.inst_id is not null;

-- ---------------------------------------------------------------------------
-- 3. Devengar el cargo, cuota a cuota
-- ---------------------------------------------------------------------------
-- Cambia el primer parámetro, así que hay que tirar la función: Postgres no
-- deja renombrar parámetros con `create or replace`.
drop function if exists public.charge_late_fee(uuid, integer);

/**
 * Idempotente por construcción, que es lo único que importa aquí: la llaman el
 * cron diario y cada conciliación, y las dos pueden pasar el mismo día sobre la
 * misma cuota. La red no es un `if` sino el unique index — un `if` se lo salta
 * una carrera entre dos transacciones, un índice no.
 *
 * No avisa. El aviso lo manda el motor una sola vez por corrida (§4): tres
 * cuotas que se pasan de la gracia el mismo día son una mala noticia, no tres.
 *
 * Devuelve el id del cargo, o null si no había nada que cobrar.
 */
create or replace function public.charge_late_fee(
  p_installment_id uuid,
  p_days_late      integer
)
returns uuid
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_inst   public.installments%rowtype;
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

  select * into v_inst
  from public.installments where id = p_installment_id
  for update;

  -- Una cuota pagada mientras el motor corría no devenga nada.
  if not found or v_inst.status <> 'pending' then
    return null;
  end if;

  select * into v_block
  from public.user_credit_blocks
  where user_id = v_inst.user_id and closed_at is null
  for update;

  -- Sin bloque abierto no hay deuda viva a la que sumar el cargo. Pasa con un
  -- usuario ya castigado por incobrable: su bloque se cerró.
  if not found then
    return null;
  end if;

  if exists (select 1 from public.late_fees where installment_id = v_inst.id) then
    return null;
  end if;

  insert into public.late_fees
    (user_id, credit_block_id, installment_id, amount_usd, days_late, business_date)
  values
    (v_inst.user_id, v_block.id, v_inst.id, v_amount, p_days_late, v_bdate)
  returning id into v_fee_id;

  -- Ingreso devengado, sin IVA. La caja no se mueve: el dinero entra cuando el
  -- usuario pague, igual que con una cuota.
  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'late_fee', 'late_fee:' || v_fee_id::text, v_bdate, v_fee_id,
    format('Cargo por mora (cuota %s, %s dias de retraso)', v_inst.sequence, p_days_late)
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, ledger.get_or_create_account('user_receivable', v_inst.user_id), v_amount, 0),
    (v_tx, ledger.get_or_create_account('platform_revenue', null), 0, v_amount);

  -- A `fee_usd`, no a `charged_usd`. Sigue siendo deuda —el bloque no se cierra
  -- hasta cubrirlo— pero no resta del límite del nivel: no es consumo, es una
  -- penalización (20260830200000).
  update public.user_credit_blocks
    set fee_usd = fee_usd + v_amount
  where id = v_block.id;

  return v_fee_id;
end;
$$;

revoke all on function public.charge_late_fee(uuid, integer) from public, anon, authenticated;

comment on function public.charge_late_fee(uuid, integer) is
  'Devenga el cargo por mora de UNA cuota. Idempotente: el unique index sobre installment_id impide el segundo.';

-- ---------------------------------------------------------------------------
-- 4. El motor recorre las cuotas
-- ---------------------------------------------------------------------------
/**
 * Cuerpo idéntico al de 20260830230000 salvo el bloque marcado NUEVO.
 *
 * El cargo va ANTES de las ramas de estado, y no dentro de una de ellas, porque
 * no depende de en cuál caiga el usuario: pasada la gracia se cobra igual esté
 * congelado, suspendido o de camino a la expulsión.
 *
 * `v_max_days_late` sigue mandando en la ESCALERA DE ESTADOS —esa mira al
 * usuario entero, no cuota a cuota— y el cargo pasa a mirar cada cuota por
 * separado. Son dos preguntas distintas sobre los mismos datos.
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
  v_inst         record;
  v_fee_id       uuid;
  v_fee_amount   numeric(18,4);
  v_fees         integer := 0;
  v_fees_usd     numeric(18,4) := 0;
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
    -- perdido no se recupera solo aquí: eso lo hace `evaluate_level` cuando
    -- pasa el enfriamiento.
    if v_status in ('frozen', 'suspended') then
      update public.profiles set status = 'active', updated_at = now() where id = p_user_id;
    end if;
    return;
  end if;

  -- ── NUEVO: un cargo por cada cuota pasada de la gracia ───────────────────
  for v_inst in
    select i.id, (public.helios_business_date(now()) - i.due_date) as days_late
    from public.installments i
    where i.user_id = p_user_id
      and i.status = 'pending'
      and (public.helios_business_date(now()) - i.due_date) > public.helios_late_fee_grace_days()
    order by i.due_date
  loop
    v_fee_id := public.charge_late_fee(v_inst.id, v_inst.days_late);

    -- Null cuando esa cuota ya lo tenía: el cargo es uno por cuota, corra el
    -- cron las veces que corra.
    if v_fee_id is not null then
      select amount_usd into v_fee_amount from public.late_fees where id = v_fee_id;
      v_fees     := v_fees + 1;
      v_fees_usd := v_fees_usd + v_fee_amount;
    end if;
  end loop;

  -- Un solo aviso por corrida, con el total. La deuda de alguien no puede
  -- crecer en silencio, pero tampoco a base de tres empujones seguidos.
  if v_fees > 0 then
    perform public.notify(
      p_user_id,
      'late_fee_charged',
      'Cargo por mora',
      case when v_fees = 1 then
        format(
          'Se sumaron $%s a tu deuda por una cuota con más de %s días de retraso. Va incluido en tu próximo pago.',
          trim(to_char(v_fees_usd, 'FM999999990.00')),
          public.helios_late_fee_grace_days()
        )
      else
        format(
          'Se sumaron $%s a tu deuda: $%s por cada una de tus %s cuotas con más de %s días de retraso. Van incluidos en tu próximo pago.',
          trim(to_char(v_fees_usd, 'FM999999990.00')),
          trim(to_char(public.helios_late_fee_usd(), 'FM999999990.00')),
          v_fees,
          public.helios_late_fee_grace_days()
        )
      end,
      jsonb_build_object(
        'late_fee_count', v_fees,
        'amount_usd', v_fees_usd,
        'days_late', v_max_days_late
      )
    );
  end if;
  -- ─────────────────────────────────────────────────────────────────────────

  if v_max_days_late > public.helios_mora_expulsion_days() then
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

  if v_max_days_late >= public.helios_mora_demotion_days() then
    if v_status <> 'suspended' then
      v_new_level := greatest(1, v_level - 1);

      update public.profiles
        set status = 'suspended', level = v_new_level, updated_at = now()
      where id = p_user_id;

      insert into public.level_changes (user_id, from_level, to_level, reason)
      values (p_user_id, v_level, v_new_level, 'mora_demotion');
    end if;
    return;
  end if;

  -- Antes del umbral de bajada: congelado, sin tocar el nivel.
  if v_status = 'active' then
    update public.profiles set status = 'frozen', updated_at = now() where id = p_user_id;
  end if;
end;
$$;

revoke all on function public.recompute_profile_mora_state(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. La cotización puede llevar varios cargos
-- ---------------------------------------------------------------------------
-- Una tabla de enlace, igual que `payment_quote_items`, por la misma razón:
-- deja de haber "el cargo" y pasa a haber "los cargos de este pago". El importe
-- se congela aquí, que es contra lo que la conciliación coteja.
create table if not exists public.payment_quote_late_fees (
  quote_id    uuid not null references public.payment_quotes (id) on delete cascade,
  late_fee_id uuid not null references public.late_fees (id),
  amount_usd  numeric(18,4) not null check (amount_usd > 0),
  primary key (quote_id, late_fee_id)
);

create index payment_quote_late_fees_fee_idx
  on public.payment_quote_late_fees (late_fee_id);

alter table public.payment_quote_late_fees enable row level security;

create policy "quote_late_fees_read_own"
  on public.payment_quote_late_fees for select to authenticated
  using (
    quote_id in (select id from public.payment_quotes where user_id = (select auth.uid()))
  );

grant select on public.payment_quote_late_fees to authenticated;

comment on table public.payment_quote_late_fees is
  'Los cargos por mora que viajan en una cotizacion, con el importe congelado al cotizar.';

-- Las cotizaciones vivas conservan su cargo: sin esto, un pago ya reportado y
-- sin conciliar perdería la referencia y el operador vería un importe que no
-- cuadra con ninguna suma.
insert into public.payment_quote_late_fees (quote_id, late_fee_id, amount_usd)
select q.id, q.late_fee_id, q.late_fee_usd
from public.payment_quotes q
where q.late_fee_id is not null and q.late_fee_usd > 0
on conflict do nothing;

-- Y la columna se va: un `late_fee_id` suelto ya no puede representar lo que
-- lleva una cotización.
alter table public.payment_quotes drop column if exists late_fee_id;

comment on column public.payment_quotes.late_fee_usd is
  'Suma de los cargos por mora de esta cotizacion (el detalle, en payment_quote_late_fees). Va dentro de amount_usd y de amount_ves; installment_count NO los cuenta.';

/**
 * Cuerpo idéntico al de 20260830170000 salvo los bloques marcados NUEVO.
 *
 * Los cargos que se cobran aquí son los de las cuotas ELEGIDAS, más los
 * huérfanos — los que perdieron su cuota porque ya se pagó, y los del modelo
 * viejo, que nunca tuvieron. Un cargo huérfano no tiene ninguna otra cotización
 * futura que lo pueda recoger, así que si no viajara con el siguiente pago se
 * quedaría pendiente para siempre y el bloque no cerraría nunca.
 *
 * Van en `amount_usd` y en `amount_ves` porque esa es la cifra que el usuario va
 * a transferir y contra la que se concilia; `installment_count` NO los cuenta,
 * porque es lo que la conciliación coteja contra las filas de
 * `payment_quote_items` y sumarlos ahí haría fallar esa comprobación.
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
  v_fee_ids    uuid[];
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
  -- Los cargos de las cuotas elegidas, más los huérfanos. Se guardan los ids
  -- para no repetir el predicado al escribir el enlace.
  select coalesce(array_agg(f.id), '{}'::uuid[]), coalesce(sum(f.amount_usd), 0)
    into v_fee_ids, v_fee_usd
  from public.late_fees f
  left join public.installments i on i.id = f.installment_id
  where f.user_id = v_user
    and f.status = 'pending'
    and (
      f.installment_id = any(p_installment_ids)
      or f.installment_id is null
      or i.status <> 'pending'
    );

  v_grand_usd := v_total_usd + v_fee_usd;
  -- ─────────────────────────────────────────────────────────────────────────

  v_rate := public.current_fx_rate();
  if v_rate is null then
    raise exception 'No hay tasa de cambio vigente' using errcode = 'P0002';
  end if;

  insert into public.payment_quotes
    (user_id, amount_usd, fx_rate, amount_ves, installment_count, valid_until,
     late_fee_usd)
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
    v_fee_usd
  )
  returning * into v_quote;

  insert into public.payment_quote_items (quote_id, installment_id, amount_usd)
  select v_quote.id, id, amount_usd
  from public.installments
  where id = any(p_installment_ids);

  -- NUEVO: el detalle de los cargos, con su importe congelado.
  insert into public.payment_quote_late_fees (quote_id, late_fee_id, amount_usd)
  select v_quote.id, f.id, f.amount_usd
  from public.late_fees f
  where f.id = any(v_fee_ids);

  return jsonb_build_object(
    'quote_id', v_quote.id,
    'amount_usd', v_quote.amount_usd,
    'fx_rate', v_quote.fx_rate,
    'amount_ves', v_quote.amount_ves,
    'installment_count', v_quote.installment_count,
    -- Partido, para que la pantalla pueda enseñar los cargos en su propia
    -- línea sin restar dos cifras que ya sabe el servidor.
    'installments_usd', v_total_usd,
    'late_fee_usd', v_quote.late_fee_usd,
    -- NUEVO: cuántos son. Es lo que deja escribir "2 cargos por mora" en vez de
    -- una cifra suelta que ya no se explica sola.
    'late_fee_count', coalesce(array_length(v_fee_ids, 1), 0),
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
-- 6. La conciliación los salda todos, o ninguno
-- ---------------------------------------------------------------------------
/**
 * Cuerpo idéntico al de 20260830190000 salvo el bloque marcado NUEVO, que pasa
 * de mirar un cargo a recorrer los de la tabla de enlace.
 *
 * Cada cargo se salda con las mismas dos redes que las cuotas: tiene que seguir
 * pendiente y tiene que valer lo que valía al cotizar. Y al final se comprueba
 * el TOTAL contra `late_fee_usd`, que es la cifra que el usuario transfirió:
 * asentar caja por una distinta deja el receivable descuadrado y sin forma de
 * deshacerlo.
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
  v_fee       record;
  v_fee_usd   numeric(18,4) := 0;
  v_fee_count integer := 0;
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
  -- Los cargos por mora que viajaban en la cotización, uno a uno.
  for v_fee in
    select l.late_fee_id, l.amount_usd as quoted_usd,
           f.status, f.amount_usd as current_usd
    from public.payment_quote_late_fees l
    join public.late_fees f on f.id = l.late_fee_id
    where l.quote_id = v_quote.id
    for update of f
  loop
    if v_fee.status <> 'pending' then
      raise exception
        'El cargo por mora % de esta cotización ya no está pendiente (%): revísalo antes de conciliar',
        v_fee.late_fee_id, v_fee.status
        using errcode = '22023';
    end if;

    if v_fee.current_usd is distinct from v_fee.quoted_usd then
      raise exception
        'El cargo por mora % cambió de importe desde que se cotizó ($% cotizados, $% ahora): no se concilia hasta revisarlo',
        v_fee.late_fee_id, v_fee.quoted_usd, v_fee.current_usd
        using errcode = '22023';
    end if;

    update public.late_fees
      set status = 'paid', paid_at = now()
    where id = v_fee.late_fee_id;

    v_fee_usd   := v_fee_usd + v_fee.quoted_usd;
    v_fee_count := v_fee_count + 1;
  end loop;

  -- La misma red que arriba, en la otra moneda: lo que se salda tiene que sumar
  -- lo que se cotizó, o el asiento de caja no es el dinero que entró.
  if v_fee_usd is distinct from v_quote.late_fee_usd then
    raise exception
      'Los cargos por mora de la cotización % suman $% y se cotizaron $%: no se concilia hasta revisarlo',
      v_quote.id, v_fee_usd, v_quote.late_fee_usd
      using errcode = '22023';
  end if;

  v_total := v_total + v_fee_usd;
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

    -- Contra cupo + fee. El fee es deuda: hasta que esté pagado, el bloque
    -- sigue abierto y el límite sigue ocupado.
    if v_block.paid_usd + v_total >= v_block.charged_usd + v_block.fee_usd then
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
    'late_fee_usd', v_fee_usd,
    'late_fee_count', v_fee_count
  );
end;
$$;

revoke all on function public.reconcile_payment(uuid, uuid, boolean, text)
  from public, anon, authenticated;

comment on function public.reconcile_payment(uuid, uuid, boolean, text) is
  'Aprueba o rechaza un reporte de pago. Al aprobar salda TODAS las cuotas de la cotizacion y TODOS sus cargos por mora, o no salda ninguno. El bloque se cierra cuando lo pagado cubre cupo Y fee.';

-- ---------------------------------------------------------------------------
-- 7. Lo que la app tiene que poder leer
-- ---------------------------------------------------------------------------
-- El singular se va con el modelo por episodio: ya no hay "el cargo".
drop function if exists public.my_pending_late_fee();

/**
 * Lo que el usuario arrastra en cargos por mora, agregado, o null si no hay.
 *
 * Existe aparte de la cotización porque la pantalla de Cuotas tiene que
 * enseñarlo ANTES de que el usuario seleccione nada — si apareciera solo al
 * cotizar, el total saltaría en el último paso y así es exactamente como se
 * pierde la confianza en una cifra.
 *
 * Agregado y no en lista: la tarjeta contesta "cuánto llevo y por qué", no
 * "cuál cuota lo trajo". El detalle por cuota vive en la cotización, que es
 * donde de verdad importa saber cuáles viajan con este pago.
 */
create or replace function public.my_pending_late_fees()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case when count(*) = 0 then null else jsonb_build_object(
    'count',         count(*),
    'total_usd',     sum(amount_usd),
    'unit_usd',      public.helios_late_fee_usd(),
    'max_days_late', max(days_late),
    'since',         min(business_date)
  ) end
  from public.late_fees
  where user_id = auth.uid() and status = 'pending';
$$;

comment on function public.my_pending_late_fees() is
  'Los cargos por mora pendientes del usuario, agregados, o null. Se pagan junto a la siguiente cotizacion.';

revoke all on function public.my_pending_late_fees() from public, anon;
grant execute on function public.my_pending_late_fees() to authenticated;
