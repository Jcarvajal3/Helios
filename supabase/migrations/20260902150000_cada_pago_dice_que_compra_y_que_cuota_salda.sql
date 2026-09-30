-- ============================================================================
-- Ronda — Cada pago dice qué compra y qué cuota salda
--
-- La cola de conciliación enseñaba un importe, un banco, una referencia y
-- "2 cuotas". Nada más. El operador tenía que aprobar $27 sin saber de qué
-- compra salían, de qué comercio, ni cuál de las dos cuotas de esa compra
-- estaba pagando. Aprobar así no es conciliar: es firmar a ciegas.
--
-- ---------------------------------------------------------------------------
-- Lo que ya estaba bien, y por qué no bastaba
-- ---------------------------------------------------------------------------
-- La cadena existe entera desde el 2026-08-22 y no se toca aquí:
--
--     charges ──< installments ──< payment_quote_items >── payment_quotes
--                                                              │
--     late_fees ──< payment_quote_late_fees ────────────────────┤
--                                                              │
--                                          payment_reports ────┘
--
-- Es decir: **una compra ya tiene sus cuotas, y una cuota ya sabe en qué
-- cotizaciones viajó**. Lo que faltaba eran dos cosas distintas:
--
--   1. **Nadie lo enseñaba.** La vista `payment_queue` agregaba la cadena a un
--      contador (`installment_count`) y tiraba el resto. El dato estaba en la
--      base y no llegaba a la pantalla.
--
--   2. **La cuota no decía qué pago la saldó.** `installments.paid_at` guarda
--      CUÁNDO, nunca CON QUÉ. Se podía deducir —cotización → reporte
--      conciliado— pero era una deducción de tres saltos que el esquema no
--      garantizaba única: una misma cotización puede tener un reporte
--      rechazado y otro conciliado, y nada impedía que tuviera dos vivos.
--      Deducir la contabilidad a fuerza de `join` es exactamente lo que hay
--      que no hacer.
--
-- ---------------------------------------------------------------------------
-- Lo que se añade
-- ---------------------------------------------------------------------------
--   · `installments.paid_by_report_id` y `late_fees.paid_by_report_id`: el
--     pago que las saldó, escrito por la conciliación, no deducido.
--   · Un índice único que impide dos pagos vivos sobre la misma cotización.
--   · `installment_payments`: la vista que contesta "esta cuota, ¿qué pagos ha
--     tenido?" —incluidos los rechazados, que es justo lo que hay que ver
--     cuando alguien reporta dos veces.
--   · `admin_payment_queue()`: la cola con el árbol entero —usuario, compras,
--     cuotas y cargos por mora— en vez de un contador.
--
-- El importe NO se reparte por cuota en ningún sitio nuevo: ya está congelado
-- en `payment_quote_items.amount_usd` desde que se cotizó, y esa es la cifra
-- contra la que concilia el servidor. Aquí solo se enseña.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La cuota dice qué pago la saldó
-- ---------------------------------------------------------------------------
-- `on delete restrict` implícito (el default): un reporte de pago no se borra
-- nunca —la máquina de estados lo rechaza, no lo elimina— y si alguien lo
-- intentara con cuotas colgando, mejor que reviente.

alter table public.installments
  add column if not exists paid_by_report_id uuid references public.payment_reports (id);

comment on column public.installments.paid_by_report_id is
  'El reporte de pago que la salda. Lo escribe reconcile_payment; null mientras la cuota siga pendiente.';

alter table public.late_fees
  add column if not exists paid_by_report_id uuid references public.payment_reports (id);

comment on column public.late_fees.paid_by_report_id is
  'El reporte de pago que lo salda. Lo escribe reconcile_payment; null mientras el cargo siga pendiente.';

-- El histórico. Solo se rellena donde la deducción es INEQUÍVOCA: exactamente
-- un reporte conciliado por cotización. Si hubiera dos, se deja en null antes
-- que escribir una atribución inventada — el `paid_at` sigue ahí y la vista de
-- abajo enseña los candidatos.
update public.installments ins
  set paid_by_report_id = sub.report_id
from (
  -- `(array_agg(...))[1]` y no `min()`: uuid no tiene agregado min(). Da igual
  -- cuál se coja, porque solo se usa la fila donde `n = 1`.
  select qi.installment_id, (array_agg(r.id))[1] as report_id, count(*) as n
  from public.payment_quote_items qi
  join public.payment_reports r on r.quote_id = qi.quote_id
  where r.status = 'reconciled'
  group by qi.installment_id
) sub
where sub.installment_id = ins.id
  and sub.n = 1
  and ins.status = 'paid'
  and ins.paid_by_report_id is null;

update public.late_fees f
  set paid_by_report_id = sub.report_id
from (
  select fl.late_fee_id, (array_agg(r.id))[1] as report_id, count(*) as n
  from public.payment_quote_late_fees fl
  join public.payment_reports r on r.quote_id = fl.quote_id
  where r.status = 'reconciled'
  group by fl.late_fee_id
) sub
where sub.late_fee_id = f.id
  and sub.n = 1
  and f.status = 'paid'
  and f.paid_by_report_id is null;

-- Una cuota pendiente no puede apuntar a un pago. Al revés sí se admite —una
-- cuota pagada sin reporte— porque el histórico anterior a esta migración
-- existe y castigarlo dejaría la base sin poder arrancar.
alter table public.installments
  drop constraint if exists installments_paid_by_report_only_when_paid;
alter table public.installments
  add constraint installments_paid_by_report_only_when_paid
  check (paid_by_report_id is null or status = 'paid');

alter table public.late_fees
  drop constraint if exists late_fees_paid_by_report_only_when_paid;
alter table public.late_fees
  add constraint late_fees_paid_by_report_only_when_paid
  check (paid_by_report_id is null or status = 'paid');

-- "Qué saldó este pago" se pregunta desde la ficha del pago, así que el índice
-- va por el reporte y no por la cuota.
create index if not exists installments_paid_by_report_idx
  on public.installments (paid_by_report_id) where paid_by_report_id is not null;

create index if not exists late_fees_paid_by_report_idx
  on public.late_fees (paid_by_report_id) where paid_by_report_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Una cotización, un pago
-- ---------------------------------------------------------------------------
-- `report_payment` ya impide reportar dos veces las MISMAS cuotas mientras
-- haya uno en revisión, así que este índice no debería poder saltar nunca. Esa
-- es la idea: la regla deja de vivir solo dentro de una función que cualquiera
-- puede reescribir mañana.
--
-- Los rechazados quedan fuera del predicado a propósito: reportar otra vez tras
-- un rechazo es el camino normal, y la cotización sigue siendo la misma.
do $$
declare
  v_dupes text;
begin
  select string_agg(quote_id::text, ', ')
    into v_dupes
  from (
    select quote_id
    from public.payment_reports
    where status in ('reported', 'in_review', 'reconciled')
    group by quote_id
    having count(*) > 1
  ) d;

  if v_dupes is not null then
    raise exception
      'Hay cotizaciones con mas de un pago vivo y hay que resolverlas a mano antes de esta migracion: %',
      v_dupes
      using errcode = '23505';
  end if;
end;
$$;

create unique index if not exists payment_reports_one_live_per_quote
  on public.payment_reports (quote_id)
  where status in ('reported', 'in_review', 'reconciled');

-- ---------------------------------------------------------------------------
-- 3. Cada cuota, sus pagos
-- ---------------------------------------------------------------------------
/**
 * Todos los reportes que han tocado una cuota, en cualquier estado.
 *
 * Es la otra mitad de `paid_by_report_id`: esa columna dice cuál la saldó, y
 * esta dice cuáles lo intentaron. La diferencia importa cuando alguien reporta,
 * se le rechaza por referencia inventada y vuelve a reportar — el operador
 * tiene que ver los dos intentos, no solo el bueno.
 *
 * `security_invoker`: el usuario ve los suyos por `payment_reports_read_own` y
 * el personal de Ronda los de todos por `payment_reports_read_admin`. La vista
 * no añade permisos, solo la forma.
 */
create or replace view public.installment_payments
with (security_invoker = true)
as
select
  qi.installment_id,
  r.id            as report_id,
  r.user_id,
  r.status,
  r.method,
  r.bank,
  r.reference,
  r.created_at    as reported_at,
  r.reviewed_at,
  r.rejection_note,
  q.id            as quote_id,
  q.fx_rate,
  -- El importe con el que esta cuota entró en ESE pago, congelado al cotizar.
  qi.amount_usd   as quoted_usd
from public.payment_quote_items qi
join public.payment_quotes  q on q.id = qi.quote_id
join public.payment_reports r on r.quote_id = q.id;

comment on view public.installment_payments is
  'Los pagos reportados que tocan cada cuota, en cualquier estado. Para la cuota que los saldo de verdad, installments.paid_by_report_id.';

grant select on public.installment_payments to authenticated;

-- ---------------------------------------------------------------------------
-- 4. La conciliación escribe el vínculo
-- ---------------------------------------------------------------------------
/**
 * Cuerpo idéntico al de 20260902110000 salvo los dos bloques marcados NUEVO,
 * que guardan el reporte en la cuota y en el cargo que salda.
 *
 * Se escribe en el mismo `update` que ya ponía `status` y `paid_at`: si algún
 * día se pudiera saldar una cuota por otra vía, el vínculo tendría que salir de
 * ahí también, y tenerlo pegado al cambio de estado es lo que hace evidente que
 * falta.
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

    -- ── NUEVO ──────────────────────────────────────────────────────────────
    -- `paid_by_report_id`: con qué pago se saldó, y no solo cuándo.
    update public.installments
      set status = 'paid', paid_at = now(), paid_by_report_id = p_report_id
    where id = v_item.installment_id;
    -- ───────────────────────────────────────────────────────────────────────

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

    -- ── NUEVO ──────────────────────────────────────────────────────────────
    update public.late_fees
      set status = 'paid', paid_at = now(), paid_by_report_id = p_report_id
    where id = v_fee.late_fee_id;
    -- ───────────────────────────────────────────────────────────────────────

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
  'Aprueba o rechaza un reporte de pago. Al aprobar salda TODAS las cuotas de la cotizacion y TODOS sus cargos por mora —dejando en cada una el reporte que la salda—, o no salda ninguno. El bloque se cierra cuando lo pagado cubre cupo Y fee.';

-- ---------------------------------------------------------------------------
-- 5. La cola, con el árbol entero
-- ---------------------------------------------------------------------------
/**
 * Lo que ve quien concilia: el pago, quién lo hizo, y QUÉ salda.
 *
 * Sustituye a la vista `payment_queue` como fuente del panel. La vista sigue
 * ahí —la usan las pruebas de humo— pero no puede crecer a esto: lo que hace
 * falta es un árbol (pago → compras → cuotas), y una vista plana solo sabe
 * devolver un contador.
 *
 * `security definer` con el portero de siempre, como todas las `admin_*`. La
 * vista es `security_invoker` y depende de siete políticas de RLS que hoy
 * existen; el día que falte una para una tabla nueva, el operador no vería un
 * error sino un array vacío, que es el fallo más caro que hay en este panel.
 *
 * Las compras van agrupadas y no como lista plana de cuotas porque la pregunta
 * del operador es "¿de qué es este pago?", y la respuesta es una compra en un
 * comercio un día — no cuatro identificadores.
 */
create or replace function public.admin_payment_queue(
  p_statuses text[] default array['reported', 'in_review']
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(item order by created_at), '[]'::jsonb)
    into v_result
  from (
    select
      r.created_at,
      jsonb_build_object(
        'report_id',      r.id,
        'status',         r.status::text,
        'created_at',     r.created_at,
        'method',         r.method,
        'bank',           r.bank,
        'reference',      r.reference,
        'payer_document', r.payer_document,
        'payer_phone',    r.payer_phone,
        'rejection_note', r.rejection_note,

        -- El dinero. `installments_usd` es lo que suman las cuotas; el resto
        -- del importe son cargos por mora, y el operador tiene que poder
        -- cuadrar las dos cifras sin restar de cabeza.
        'amount_usd',        q.amount_usd,
        'amount_ves',        q.amount_ves,
        'fx_rate',           q.fx_rate,
        'installment_count', q.installment_count,
        'installments_usd',  q.amount_usd - q.late_fee_usd,
        'late_fee_usd',      q.late_fee_usd,

        'user', jsonb_build_object(
          'user_id',         p.id,
          'full_name',       p.full_name,
          'phone_e164',      p.phone_e164,
          'document_number', p.document_number,
          'status',          p.status::text,
          'level',           p.level
        ),

        -- Cuántos OTROS reportes no rechazados comparten banco + referencia.
        -- Con referencias de 6 dígitos esto es sospecha, no prueba (docs/00
        -- §3.7).
        'reference_collisions', (
          select count(*) - 1 from public.payment_reports r2
          where r2.bank = r.bank and r2.reference = r.reference
            and r2.reference is not null and r2.status <> 'rejected'
        ),
        -- Movimientos del estado de cuenta importado que encajan: referencia,
        -- monto y fecha, las tres a la vez.
        'statement_matches', (
          select count(*) from public.bank_statement_lines l
          where r.reference is not null
            and l.reference like '%' || r.reference
            and abs(l.amount_ves - q.amount_ves) <= 1.00
            and l.moved_on between (r.created_at::date - 5) and (r.created_at::date + 5)
        ),

        -- Las compras que toca este pago, cada una con las cuotas que salda.
        'purchases', coalesce((
          select jsonb_agg(purchase order by business_date nulls last, order_number nulls last)
          from (
            select
              ch.business_date,
              ch.order_number,
              jsonb_build_object(
                'charge_id',         ch.id,
                'order_number',      ch.order_number,
                'merchant_id',       m.id,
                'merchant_name',     m.name,
                'branch_name',       b.name,
                'charge_amount_usd', ch.amount_usd,
                'charge_status',     ch.status::text,
                'business_date',     ch.business_date,
                'confirmed_at',      ch.confirmed_at,
                -- Un consumo de grupo son N cargos hermanos. Sin decirlo, tres
                -- cuotas de $8,33 del mismo sitio parecen un error de dedo.
                'is_group',          ch.group_id is not null,
                'group_name',        ch.group_name,
                -- El denominador del "cuota 2 de 2". Se cuenta sobre las de
                -- ESTE usuario: en un consumo de grupo el cargo tiene cuotas
                -- de varios.
                'installments_total', (
                  select count(*) from public.installments t
                  where t.charge_id = ch.id and t.user_id = r.user_id
                ),
                'installments', jsonb_agg(jsonb_build_object(
                  'installment_id', ins.id,
                  'sequence',       ins.sequence,
                  -- El congelado al cotizar. Es la cifra contra la que concilia
                  -- el servidor; si difiere del de la cuota, el pago no se
                  -- concilia y aquí se ve por qué.
                  'quoted_usd',     qi.amount_usd,
                  'amount_usd',     ins.amount_usd,
                  'due_date',       ins.due_date,
                  'status',         ins.status::text,
                  'days_overdue',   greatest(v_today - ins.due_date, 0),
                  -- Intentos anteriores sobre esta misma cuota: un rechazo y un
                  -- segundo reporte es normal, pero el operador tiene que
                  -- saberlo antes de aprobar.
                  'other_reports', (
                    select count(*)
                    from public.payment_quote_items qi2
                    join public.payment_reports r2 on r2.quote_id = qi2.quote_id
                    where qi2.installment_id = ins.id and r2.id <> r.id
                  )
                ) order by ins.sequence)
              ) as purchase
            from public.payment_quote_items qi
            join public.installments ins on ins.id = qi.installment_id
            join public.charges ch on ch.id = ins.charge_id
            join public.merchants m on m.id = ch.merchant_id
            join public.merchant_branches b on b.id = ch.branch_id
            where qi.quote_id = q.id
            group by ch.id, m.id, b.id
          ) g
        ), '[]'::jsonb),

        -- Los cargos por mora, con la cuota que los disparó. Sin esto el
        -- importe no cuadra con ninguna suma de cuotas y un pago correcto se
        -- marca como sospechoso.
        'late_fees', coalesce((
          select jsonb_agg(jsonb_build_object(
            'late_fee_id',    f.id,
            'amount_usd',     fl.amount_usd,
            'days_late',      f.days_late,
            'business_date',  f.business_date,
            'installment_id', f.installment_id,
            'sequence',       ins.sequence,
            'order_number',   ch.order_number,
            'merchant_name',  m.name,
            -- Un cargo HUÉRFANO es el de una cuota que ya se pagó (o el del
            -- modelo por episodio, sin cuota). Viaja con este pago aunque su
            -- cuota no esté aquí — y esa es justo la pregunta que se hace el
            -- operador al ver un cargo suelto.
            'orphan', f.installment_id is null or not exists (
              select 1 from public.payment_quote_items qi3
              where qi3.quote_id = q.id and qi3.installment_id = f.installment_id
            )
          ) order by f.business_date, f.created_at)
          from public.payment_quote_late_fees fl
          join public.late_fees f on f.id = fl.late_fee_id
          left join public.installments ins on ins.id = f.installment_id
          left join public.charges ch on ch.id = ins.charge_id
          left join public.merchants m on m.id = ch.merchant_id
          where fl.quote_id = q.id
        ), '[]'::jsonb)
      ) as item
    from public.payment_reports r
    join public.payment_quotes q on q.id = r.quote_id
    join public.profiles p on p.id = r.user_id
    where r.status::text = any(p_statuses)
  ) s;

  return v_result;
end;
$$;

comment on function public.admin_payment_queue(text[]) is
  'Cola de conciliacion con el arbol entero: pago -> usuario, compras, cuotas y cargos por mora. Sustituye a la vista payment_queue en el panel.';

revoke all on function public.admin_payment_queue(text[]) from public, anon;
grant execute on function public.admin_payment_queue(text[]) to authenticated;
