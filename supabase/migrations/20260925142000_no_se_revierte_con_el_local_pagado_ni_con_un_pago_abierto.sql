-- ============================================================================
-- Ronda — No se revierte un consumo con el local pagado ni con un pago abierto
--
-- Dos decisiones sobre `admin_reverse_charge` (análisis en D4 §11):
--
-- 1. Si al local ya se le transfirió su parte, entera o en parte, el consumo
--    no se revierte (decisión de Javier). La función ya se negaba; ahora la
--    ficha lo dice antes de pulsar, en registro profesional: «No se puede
--    revertir: al local ya se le transfirió su parte.»
--
-- 2. Revertir reventaba con `23503 payment_quote_items_installment_id_fkey`
--    si la persona había abierto «Pagar» sin reportar: la cotización apunta a
--    las cuotas que se iban a borrar. Ahora:
--      · con una cotización vigente, se niega: la persona puede estar
--        transfiriendo con ella y su reporte se quedaría sin cotización;
--      · las caducadas y sin reporte se borran antes que las cuotas, porque
--        `report_payment` ya no las acepta.
--
-- Las razones pasan a una función interna que leen la pregunta de la ficha y
-- la escritura, para que digan lo mismo. Los textos cambian (frases completas
-- que empiezan por «No se puede revertir:»); la forma del JSON de
-- `admin_can_reverse_charge` y las firmas no.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Por qué no se puede revertir, en un solo sitio
-- ---------------------------------------------------------------------------
-- La ficha pregunta antes de enseñar el botón y la escritura vuelve a
-- preguntar al revertir. Las dos leen esta función, así que el texto que ve
-- el super admin antes de pulsar es el mismo con el que se niega el servidor.
-- Devuelve null si se puede revertir.

create or replace function public.helios_charge_reverse_blocker(p_charge_id uuid)
returns text
language plpgsql
stable
set search_path = public, pg_temp
as $fn$
declare
  v_status   public.charge_status;
  v_deudores integer;
  v_n        integer;
  v_quien    text;
  v_caduca   timestamptz;
begin
  select status into v_status from public.charges where id = p_charge_id;
  if not found then
    return 'No se puede revertir: el consumo no existe.';
  end if;

  if v_status <> 'confirmed' then
    return format('No se puede revertir: el consumo está %s y solo se revierte uno confirmado.',
      case v_status
        when 'pending'  then 'pendiente'
        when 'voided'   then 'anulado'
        when 'reverted' then 'revertido'
        else v_status::text
      end);
  end if;

  -- Cuántas personas se reparten el cargo. En un consumo de grupo quien frena
  -- la reversión puede ser cualquiera de ellas, y el super admin está mirando
  -- la ficha de quien puso la cuenta: el texto dice quién es.
  select count(distinct user_id) into v_deudores
  from public.installments where charge_id = p_charge_id;

  -- 1. Cuotas pagadas: revertir sería devolver dinero.
  select count(*), string_agg(distinct pr.full_name, ', ')
  into v_n, v_quien
  from public.installments i
  left join public.profiles pr on pr.id = i.user_id
  where i.charge_id = p_charge_id and i.status = 'paid';

  if v_n > 0 then
    return case when v_deudores > 1 and v_quien is not null then
      format('No se puede revertir: ya hay cuotas pagadas (%s), y revertirlo obligaría a devolver dinero.', v_quien)
    else
      'No se puede revertir: ya hay cuotas pagadas, y revertirlo obligaría a devolver dinero.'
    end;
  end if;

  -- 2. Un pago reportado, en cualquier estado: el reporte apunta a su
  --    cotización y la cotización a las cuotas, así que tampoco se podrían
  --    borrar.
  select count(*), string_agg(distinct pr.full_name, ', ')
  into v_n, v_quien
  from public.payment_reports r
  join public.payment_quote_items qi on qi.quote_id = r.quote_id
  join public.installments i on i.id = qi.installment_id
  left join public.profiles pr on pr.id = i.user_id
  where i.charge_id = p_charge_id;

  if v_n > 0 then
    return case when v_deudores > 1 and v_quien is not null then
      format('No se puede revertir: %s reportó un pago para una de sus cuotas.', v_quien)
    else
      'No se puede revertir: hay un pago reportado para una de sus cuotas.'
    end;
  end if;

  -- 3. Al local ya se le transfirió algo. Decisión de Javier (2026-09-25): no
  --    se revierte; compensarlo con el local es otra operación, a mano.
  if exists (
    select 1 from public.settlements
    where charge_id = p_charge_id and status in ('paid', 'partial')
  ) then
    return 'No se puede revertir: al local ya se le transfirió su parte.';
  end if;

  -- 4. Una cotización vigente y sin reportar: la persona abrió «Pagar» y
  --    puede estar transfiriendo ahora mismo con ella. Borrarla dejaría su
  --    reporte sin cotización. Las caducadas no frenan: el servidor las borra
  --    al revertir, porque `report_payment` ya no las acepta.
  select count(distinct q.id), string_agg(distinct pr.full_name, ', '), max(q.valid_until)
  into v_n, v_quien, v_caduca
  from public.payment_quotes q
  join public.payment_quote_items qi on qi.quote_id = q.id
  join public.installments i on i.id = qi.installment_id
  left join public.profiles pr on pr.id = q.user_id
  where i.charge_id = p_charge_id
    and q.valid_until > now()
    and not exists (select 1 from public.payment_reports r where r.quote_id = q.id);

  if v_n > 0 then
    return format(
      'No se puede revertir: %s tiene un pago abierto sin reportar. Se podrá revertir cuando caduque, a las %s.',
      case when v_deudores > 1 and v_quien is not null then v_quien else 'la persona' end,
      to_char(v_caduca at time zone 'America/Caracas', 'HH24:MI'));
  end if;

  return null;
end;
$fn$;

comment on function public.helios_charge_reverse_blocker(uuid) is
  'Por qué un consumo no se puede revertir (texto para enseñar), o null si se puede. La usan admin_can_reverse_charge y admin_reverse_charge.';

revoke all on function public.helios_charge_reverse_blocker(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- La pregunta de la ficha
-- ---------------------------------------------------------------------------

create or replace function public.admin_can_reverse_charge(p_charge_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_reason text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if not exists (select 1 from public.charges where id = p_charge_id) then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  v_reason := public.helios_charge_reverse_blocker(p_charge_id);

  return jsonb_build_object('can_reverse', v_reason is null, 'reason', v_reason);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Revertir
-- ---------------------------------------------------------------------------
-- El cuerpo es el de 20260917140000 con la guarda de 20260925131000. Cambian
-- las redes, que pasan a la función de arriba, y el borrado de las
-- cotizaciones caducadas antes que las cuotas. Los permisos no cambian.

create or replace function public.admin_reverse_charge(p_charge_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'audit', 'pg_temp'
AS $function$
declare
  v_actor    uuid := auth.uid();
  v_charge   public.charges%rowtype;
  v_bdate    date := public.helios_business_date(now());
  v_financed numeric(18,4);
  v_payable  numeric(18,4);
  v_bloqueo  text;
  v_tx       uuid;
  v_origen   record;
  v_name     text;
  v_partes   jsonb;
  v_parte    record;
  v_n        integer;
begin
  -- Revertir mueve el libro hacia atrás: es del super admin.
  perform public.helios_assert_super_admin('revertir un consumo');

  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'Revertir un consumo requiere motivo' using errcode = '22023';
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;

  if not found then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  -- ── Las redes ───────────────────────────────────────────────────────────
  -- Las mismas que la ficha enseña antes de pulsar, con el mismo texto: las
  -- dos leen `helios_charge_reverse_blocker`. Van después del `for update`,
  -- con el consumo ya bloqueado.
  v_bloqueo := public.helios_charge_reverse_blocker(p_charge_id);
  if v_bloqueo is not null then
    raise exception '%', v_bloqueo using errcode = '22023';
  end if;

select full_name into v_name from public.profiles where id = v_charge.user_id;

  select
    coalesce(sum(financed_usd), 0),
    coalesce(sum(amount_usd), 0)
  into v_financed, v_payable
  from public.installments where charge_id = p_charge_id;

  -- Y las mismas dos cifras POR PERSONA, que es lo que de verdad hace falta
  -- para devolver algo. Se toman AQUÍ, antes de que el borrado de más abajo se
  -- lleve las cuotas por delante: después de él ya no hay dónde mirar quién
  -- puso cuánto.
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id',  s.user_id,
           'financed', s.financed,
           'payable',  s.payable
         ) order by s.user_id), '[]'::jsonb)
  into v_partes
  from (
    select i.user_id,
           sum(i.financed_usd) as financed,
           sum(i.amount_usd)   as payable
    from public.installments i
    where i.charge_id = p_charge_id
    group by i.user_id
  ) s;

  v_n := jsonb_array_length(v_partes);

  -- ── 1. El asiento contrario ──────────────────────────────────────────────
  -- Se refleja lo que se escribió, pata por pata, en vez de recalcularlo: si
  -- el consumo se asentó con una comisión o un IVA distintos de los de hoy
  -- —porque los parámetros cambiaron— recalcular dejaría un residuo.

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'manual_adjustment',
    'reverse_charge:' || p_charge_id::text,
    v_bdate,
    p_charge_id,
    format('Consumo revertido: %s', trim(p_reason))
  )
  returning id into v_tx;

  for v_origen in
    select e.account_id, e.debit, e.credit
    from ledger.transactions t
    join ledger.entries e on e.transaction_id = t.id
    where t.reference_id = p_charge_id
      and t.type <> 'manual_adjustment'
  loop
    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, v_origen.account_id, v_origen.credit, v_origen.debit);
  end loop;

  -- ── 2. Las cuotas ────────────────────────────────────────────────────────
  -- Se borran, no se marcan. Sin pagos detrás no dejan nada que auditar —lo
  -- que pasó está en el asiento y en la bitácora— y dejarlas con un estado
  -- nuevo obligaría a que las quince consultas que filtran por 'pending' se
  -- acordaran de excluirlo.

  -- Antes, las cotizaciones caducadas y sin reporte que tocan estas cuotas:
  -- su clave foránea impedía borrarlas. Ya no se pueden reportar
  -- (`report_payment` rechaza una caducada), así que no guardan nada. Se
  -- borran enteras, con sus líneas y cargos en cascada, aunque llevaran también
  -- cuotas de otro consumo: caducada, tampoco servía para pagar esas. Las
  -- vigentes ya frenaron arriba.
  delete from public.payment_quotes q
  where q.valid_until <= now()
    and not exists (select 1 from public.payment_reports r where r.quote_id = q.id)
    and exists (
      select 1
      from public.payment_quote_items qi
      join public.installments i on i.id = qi.installment_id
      where qi.quote_id = q.id and i.charge_id = p_charge_id
    );

  delete from public.installments where charge_id = p_charge_id;

  -- ── 3. Las liquidaciones al local que no se han pagado ───────────────────

  delete from public.settlements
  where charge_id = p_charge_id and status = 'pending';

  -- ── 4. El cupo vuelve, a cada quien lo suyo ──────────────────────────────
  -- Exactamente lo contrario de lo que `helios_assign_debt` sumó al crear las
  -- cuotas: el financiado de esa persona sale de `charged_usd` y su fee —el
  -- pagadero menos el financiado— de `fee_usd`. Persona por persona, porque
  -- persona por persona se sumó.
  --
  -- El techo del grupo va en el mismo viaje. `group_members.spent_usd` es lo
  -- que esta mesa ya le cargó a cada quien esta noche, y nadie lo deshacía: un
  -- €500 tecleado en vez de €50 quemaba el techo de los cuatro y revertirlo no
  -- se lo devolvía, así que la mesa se quedaba sin sitio para el consumo bueno.
  -- Que es el caso para el que existe esta función.

  for v_parte in
    select (e->>'user_id')::uuid     as user_id,
           (e->>'financed')::numeric as financed,
           (e->>'payable')::numeric  as payable
    from jsonb_array_elements(v_partes) e
  loop
    update public.user_credit_blocks
    set charged_usd = greatest(charged_usd - v_parte.financed, 0),
        fee_usd     = greatest(fee_usd - (v_parte.payable - v_parte.financed), 0)
    where user_id = v_parte.user_id and closed_at is null;

    if v_charge.group_id is not null then
      update public.group_members
      set spent_usd = greatest(spent_usd - v_parte.financed, 0)
      where group_id = v_charge.group_id and user_id = v_parte.user_id;
    end if;
  end loop;

  -- ── 5. El consumo queda marcado ──────────────────────────────────────────

  update public.charges
  set status      = 'reverted',
      void_reason = trim(p_reason),
      voided_by   = v_actor,
      voided_at   = now()
  where id = p_charge_id;

  -- Cada quien tiene que enterarse: le desapareció una deuda y un cargo de su
  -- historial. Enterarse por sorpresa es peor que el error original.
  --
  -- TODOS los que debían, no solo quien puso la cuenta, y cada uno con SU
  -- parte: mandarle a alguien el total de la mesa es contarle mal lo que le
  -- acaba de pasar.
  for v_parte in
    select (e->>'user_id')::uuid    as user_id,
           (e->>'payable')::numeric as payable
    from jsonb_array_elements(v_partes) e
  loop
    perform public.notify(
      v_parte.user_id,
      'payment_reconciled',
      'Anulamos un consumo',
      case when v_n > 1 then
        format('Anulamos la cuenta del grupo. Tu parte de €%s ya no la debes y tu cupo vuelve a estar disponible.',
               to_char(v_parte.payable, 'FM999999990.00'))
      else
        format('Anulamos el consumo de €%s. Ya no lo debes y tu cupo vuelve a estar disponible.',
               to_char(v_parte.payable, 'FM999999990.00'))
      end
    );
  end loop;

  perform audit.log(v_actor, 'charge.reverted', p_charge_id, jsonb_build_object(
    'user_id', v_charge.user_id,
    'full_name', v_name,
    'merchant_id', v_charge.merchant_id,
    'amount_usd', v_charge.amount_usd,
    'financed_usd', v_financed,
    'payable_usd', v_payable,
    -- El reparto entero. Los totales no dicen a quién se le devolvió qué, y esa
    -- es justo la pregunta que se le hace a la bitácora cuando hay que revisar
    -- una reversión de grupo meses después.
    'debtors', v_n,
    'split', v_partes,
    'business_date', v_charge.business_date,
    'reason', trim(p_reason)
  ));

  return jsonb_build_object(
    'ok', true,
    'charge_id', p_charge_id,
    'amount_usd', v_charge.amount_usd,
    -- El total devuelto, y debajo a quién. Con un cargo de grupo el total solo
    -- no dice nada: son varios bloques de crédito los que se movieron.
    'credit_returned_usd', v_financed,
    'debtors', v_n,
    'split', v_partes
  );
end;
$function$;
