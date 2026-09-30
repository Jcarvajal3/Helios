-- ============================================================================
-- Ronda — Repartir una cuenta no puede reescribir cuotas que ya están cobrándose
--
-- EL FALLO
--
-- `claim_charge_share` baja el importe de las cuotas de los que ya debían:
--
--     update public.installments set amount_usd = v_half
--     where charge_id = ... and user_id = ... and sequence = 1;
--
-- Sin mirar en qué estado están. La cabecera de 20260827040000 justificaba
-- que eso era seguro con esta lista, y el primer punto es falso:
--
--     «ninguna cuota ha podido pagarse — la cuota 1 vence a 14 días»
--
-- Vencer a 14 días no impide pagarla antes. El pago anticipado está permitido
-- (docs/06 §1) y `quote_installments` cotiza CUALQUIER cuota pendiente sin
-- mirar la fecha de vencimiento. Así que dentro de la misma ventana de
-- reparto —esa noche, hasta las 10 AM— quien pagó la cuenta puede cotizar,
-- transferir de verdad y reportar el pago.
--
-- Y si eso pasó, reescribir el importe descuadra el dinero, porque la
-- conciliación NO mira la cuota: asienta el importe que quedó congelado en
-- `payment_quote_items` cuando se cotizó.
--
--   23:00  A paga $127,60. Se le crean dos cuotas de $63,80.
--   23:05  A cotiza las dos y reporta la transferencia. El reporte queda
--          'reported', esperando que soporte lo apruebe.
--   01:00  B escanea el QR de la cuenta. El reparto baja las cuotas de A a
--          $31,90 y le abona $63,80 en `user_receivable`.
--   Al día siguiente, soporte aprueba el reporte de A: `reconcile_payment`
--          marca pagadas las cuotas (ahora de $31,90) pero asienta los
--          $127,60 cotizados.
--
-- A acaba con el receivable $63,80 NEGATIVO, con `paid_usd` inflado en el
-- bloque de crédito —que puede cerrarse antes de tiempo y devolverle el
-- límite entero— y sin ningún error en ninguna parte. No hay flujo de
-- devolución que deshaga esto.
--
-- EL ARREGLO, en dos capas
--
--   1. `claim_charge_share` se niega a repartir una cuenta cuyo dinero ya se
--      puso en marcha: alguna cuota pagada, un pago reportado esperando
--      revisión, o una cotización viva (el usuario puede estar delante del
--      cajero automático con la cifra vieja en la pantalla).
--
--   2. `reconcile_payment` comprueba que el importe cotizado siga siendo el
--      de la cuota antes de asentar nada. Es la red: hace imposible el
--      descuadre aunque mañana otra función vuelva a tocar los importes.
--      Mismo criterio que el `v_done <> v_expected` que ya tenía —ruidoso y
--      atómico en vez de silencioso y a medias—, pero mirando importes, que
--      es por donde se escapaba.
--
-- Lo que se pierde: quien madruga a pagar una cuota de 14 días esa misma
-- noche bloquea el reparto de esa cuenta. Es el caso raro del caso raro, y
-- falla diciendo por qué.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El reparto se cierra en cuanto el dinero de la orden se puso en marcha
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260828010000_cobrar_al_grupo salvo el bloque NUEVO,
-- reescrito entero porque `create or replace` sustituye la función completa.

CREATE OR REPLACE FUNCTION public.claim_charge_share(p_token text, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'pg_temp'
AS $function$
declare
  v_user    uuid := auth.uid();
  v_pin     jsonb;
  v_charge  public.charges%rowtype;
  v_parts   jsonb := '[]'::jsonb;
  v_split   jsonb;
  v_row     record;
  v_new     numeric(18,4);
  v_mine    numeric(18,4);
  v_delta   numeric(18,4);
  v_tx      uuid;
  v_due_1   date;
  v_due_2   date;
  v_half    numeric(18,4);
  v_block   public.user_credit_blocks%rowtype;
  v_limit   numeric(18,4);
  v_count   integer := 0;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  select * into v_charge from public.charges
  where share_token = trim(p_token) for update;

  if not found then
    raise exception 'Ese código no corresponde a ninguna orden' using errcode = 'P0002';
  end if;

  if public.helios_business_day_end(v_charge.business_date) <= now() then
    raise exception 'Esta orden ya se cerró: solo se reparte durante la misma noche'
      using errcode = '22023';
  end if;

  if exists (select 1 from public.installments
             where charge_id = v_charge.id and user_id = v_user) then
    raise exception 'Ya tienes una parte de esta orden' using errcode = '22023';
  end if;

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes asumir deuda nueva' using errcode = '22023';
  end if;

  -- Se bloquean las cuotas de la orden antes de leerlas: dos personas
  -- escaneando el mismo QR a la vez no pueden repartir cada una sobre la foto
  -- vieja.
  perform 1 from public.installments
  where charge_id = v_charge.id order by user_id, sequence for update;

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- Repartir REESCRIBE las cuotas de los que ya debían, y eso solo es seguro
  -- mientras ninguna se haya movido. Las dos comprobaciones van DESPUÉS del
  -- `for update` de arriba: leerlas sin el lock sería mirar una foto vieja
  -- justo en la carrera que importa.

  -- Una cuota ya pagada. Bajarle el importe reescribe una deuda saldada, y el
  -- abono al bloque de crédito ya se hizo por la cifra vieja.
  if exists (
    select 1 from public.installments
    where charge_id = v_charge.id and status <> 'pending'
  ) then
    raise exception
      'Alguien ya pagó su parte de esta cuenta: repartirla ahora descuadraría lo cobrado'
      using errcode = '22023';
  end if;

  -- Dinero en camino. Dos comprobaciones sueltas y no un join entre las dos,
  -- porque bloquean por motivos distintos y ninguna implica a la otra:
  --
  --   * Una COTIZACIÓN VIVA: el usuario puede estar delante del cajero con la
  --     cifra vieja en la pantalla. Caducada ya no estorba — no llegó a
  --     usarse.
  --   * Un REPORTE esperando revisión: la conciliación asentará el importe
  --     congelado al cotizar, y eso vale aunque su cotización ya caducara
  --     (la ventana de reparto llega hasta las 10 AM y una cotización muere a
  --     medianoche).
  if exists (
    select 1
    from public.payment_quote_items qi
    join public.installments i   on i.id = qi.installment_id
    join public.payment_quotes q on q.id = qi.quote_id
    where i.charge_id = v_charge.id
      and q.valid_until > now()
  ) or exists (
    select 1
    from public.payment_quote_items qi
    join public.installments i    on i.id = qi.installment_id
    join public.payment_reports r on r.quote_id = qi.quote_id
    where i.charge_id = v_charge.id
      and r.status in ('reported', 'in_review')
  ) then
    raise exception
      'Alguien de esta cuenta ya está pagando su parte: no se puede repartir mientras tanto'
      using errcode = '22023';
  end if;
  -- ─────────────────────────────────────────────────────────────────────────

  for v_row in select * from public.charge_debtors(v_charge.id) loop
    v_parts := v_parts || jsonb_build_object(
      'user_id', v_row.user_id, 'capacity_usd', v_row.share_usd
    );
    v_count := v_count + 1;
  end loop;

  v_parts := v_parts || jsonb_build_object(
    'user_id', v_user,
    'capacity_usd', public.claimant_capacity(v_user, v_charge.group_id)
  );

  v_split := public.helios_split_shares(v_charge.amount_usd, v_parts);

  if not coalesce((v_split->>'ok')::boolean, false) then
    if v_split->>'reason' = 'too_small' then
      raise exception 'Ya son % en esta cuenta de $%: entrar dejaría a alguien por debajo del mínimo',
        v_count, v_charge.amount_usd using errcode = '22023';
    else
      raise exception 'No te alcanza el saldo para tomar una parte de esta cuenta'
        using errcode = '22023';
    end if;
  end if;

  -- Las fechas del consumo, no las de hoy.
  select due_date into v_due_1 from public.installments
  where charge_id = v_charge.id and sequence = 1 limit 1;
  select due_date into v_due_2 from public.installments
  where charge_id = v_charge.id and sequence = 2 limit 1;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', 'claim:' || v_charge.id::text || ':' || v_user::text,
          v_charge.business_date, v_charge.id,
          format('Reparto posterior: entra 1 persona, ahora son %s',
                 (v_split->>'split_between')::integer))
  returning id into v_tx;

  -- --- A los que ya debían: se les baja ------------------------------------
  for v_row in select * from public.charge_debtors(v_charge.id) loop
    select (s->>'share_usd')::numeric into v_new
    from jsonb_array_elements(v_split->'shares') s
    where (s->>'user_id')::uuid = v_row.user_id;

    v_delta := v_row.share_usd - coalesce(v_new, v_row.share_usd);
    continue when v_delta <= 0;

    v_half := round(v_new / 2, 4);

    update public.installments set amount_usd = v_half
    where charge_id = v_charge.id and user_id = v_row.user_id and sequence = 1;
    update public.installments set amount_usd = v_new - v_half
    where charge_id = v_charge.id and user_id = v_row.user_id and sequence = 2;

    update public.user_credit_blocks
      set charged_usd = charged_usd - v_delta
    where user_id = v_row.user_id and closed_at is null;

    -- Si la orden salió de una mesa, el techo gastado también se libera.
    if v_charge.group_id is not null then
      update public.group_members
        set spent_usd = greatest(spent_usd - v_delta, 0)
      where group_id = v_charge.group_id and user_id = v_row.user_id;
    end if;

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, ledger.get_or_create_account('user_receivable', v_row.user_id), 0, v_delta);

    perform public.notify(
      v_row.user_id,
      'group_charge',
      'Tu parte bajó',
      format('Alguien más entró en la cuenta de $%s. Tu parte pasó a $%s.',
             trim(to_char(v_charge.amount_usd, 'FM999999990.00')),
             trim(to_char(v_new, 'FM999999990.00'))),
      jsonb_build_object('charge_id', v_charge.id, 'amount_usd', v_new)
    );
  end loop;

  -- --- Al que entra: su deuda ----------------------------------------------
  select (s->>'share_usd')::numeric into v_mine
  from jsonb_array_elements(v_split->'shares') s
  where (s->>'user_id')::uuid = v_user;

  select monthly_limit_usd into v_limit
  from public.levels l join public.profiles p on p.level = l.level
  where p.id = v_user;

  select * into v_block from public.user_credit_blocks
  where user_id = v_user and closed_at is null for update;

  if not found then
    insert into public.user_credit_blocks (user_id) values (v_user) returning * into v_block;
  end if;

  if v_block.charged_usd + v_mine > v_limit then
    raise exception 'Tu límite no cubre $%', v_mine using errcode = '22023';
  end if;

  v_half := round(v_mine / 2, 4);

  insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
    (v_charge.id, v_user, 1, v_half, v_due_1),
    (v_charge.id, v_user, 2, v_mine - v_half, v_due_2);

  update public.user_credit_blocks
    set charged_usd = charged_usd + v_mine
  where id = v_block.id;

  if v_charge.group_id is not null then
    update public.group_members
      set spent_usd = spent_usd + v_mine
    where group_id = v_charge.group_id and user_id = v_user and left_at is null;
  end if;

  insert into ledger.entries (transaction_id, account_id, debit, credit)
  values (v_tx, ledger.get_or_create_account('user_receivable', v_user), v_mine, 0);

  return jsonb_build_object(
    'ok', true,
    'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'share_usd', v_mine,
    'split_between', (v_split->>'split_between')::integer,
    'due_1', v_due_1,
    'due_2', v_due_2
  );
end;
$function$
;

revoke all on function public.claim_charge_share(text, text) from public, anon;
grant execute on function public.claim_charge_share(text, text) to authenticated;

comment on function public.claim_charge_share(text, text) is
  'Toma una parte de una orden ya pagada. Se niega si alguna cuota ya se pagó, está reportada o tiene una cotización viva: reescribir esos importes descuadra la conciliación.';

-- ---------------------------------------------------------------------------
-- 2. La red: conciliar comprueba que el importe cotizado siga siendo el real
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260825110000_reconcile_every_installment salvo la
-- comprobación marcada abajo y el `ins.amount_usd` que hace falta para ella.

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
           -- NUEVO: el importe que tiene la cuota AHORA, para cotejarlo con el
           -- que se congeló al cotizar.
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

    -- ── NUEVO ──────────────────────────────────────────────────────────────
    -- Lo que se asienta abajo es `v_item.amount_usd`: el importe CONGELADO al
    -- cotizar. Si la cuota vale ahora otra cosa, alguien la reescribió entre
    -- la cotización y esta aprobación —el reparto de una cuenta era la vía, y
    -- por eso se cerró arriba— y asentar la cifra vieja deja el receivable del
    -- usuario descuadrado sin forma de deshacerlo.
    --
    -- El `v_done <> v_expected` de más abajo cuenta filas; esta mira importes.
    -- Se para entera: el operador mira qué pasó y vuelve a aprobar.
    if v_item.current_amount_usd is distinct from v_item.amount_usd then
      raise exception
        'La cuota % cambió de importe desde que se cotizó ($% cotizados, $% ahora): no se concilia hasta revisarlo',
        v_item.installment_id, v_item.amount_usd, v_item.current_amount_usd
        using errcode = '22023';
    end if;
    -- ───────────────────────────────────────────────────────────────────────

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
    'installments', v_done
  );
end;
$$;

revoke all on function public.reconcile_payment(uuid, uuid, boolean, text)
  from public, anon, authenticated;

comment on function public.reconcile_payment(uuid, uuid, boolean, text) is
  'Aprueba o rechaza un reporte de pago. Al aprobar salda TODAS las cuotas de la cotización o no salda ninguna, y solo si sus importes no han cambiado desde que se cotizaron.';
