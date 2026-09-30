-- ============================================================================
-- Ronda — Revertir una cuenta de grupo le devuelve el cupo a cada quien
-- ============================================================================
--
-- Corrige `admin_reverse_charge`, que entró con 20260911207000. Va aparte y no
-- editando aquella porque una migración ya aplicada no se vuelve a ejecutar:
-- cambiar su fichero solo hace que la base y el repo digan cosas distintas.
--
-- ---------------------------------------------------------------------------
-- El fallo: un cargo, varios deudores
-- ---------------------------------------------------------------------------
-- Un consumo de grupo es UN cargo con una cuota por integrante —mismo
-- `charge_id`, distinto `user_id`—, no un cargo por persona. La versión
-- anterior borraba las cuotas de todos, sumaba lo financiado de todas y se lo
-- devolvía al bloque de crédito de UNA sola: `charges.user_id`, quien puso la
-- cuenta.
--
-- En una cuenta de dos personas a €3,00 cada una:
--
--   * A quien la puso se le devolvían €6,00 de cupo, €3,00 de los cuales nunca
--     gastó. Su bloque queda descuadrado hacia abajo.
--   * A la otra se le borraba la deuda y el bloque se le quedaba con sus €3,00
--     puestos. Descuadrado hacia arriba no se cierra nunca: el cierre compara
--     `paid_usd` contra `charged_usd + fee_usd`, y ese resto no lo va a pagar
--     nadie porque su cuota ya no existe. El motor de impago lo hereda igual:
--     castiga `charged_usd + fee_usd − paid_usd`, o sea provisiona contra
--     dinero que ya no se debe.
--
-- El límite de gasto se salvó de milagro: `helios_credit_used_usd` lo calcula
-- sumando cuotas, no leyendo el bloque, y las cuotas sí se borraban. Por eso
-- nadie se quedaba sin poder comprar y el fallo no se vio. Todo lo demás que
-- lee el bloque —el cierre, el castigo, las cifras de la ficha— sí se
-- descuadraba.
--
-- Y había un tercer final, y ese al menos se nota: `user_credit_blocks` lleva
-- un `check (paid_usd <= charged_usd + fee_usd)`. Restarle a quien puso la
-- cuenta el financiado y el fee de TODOS podía dejarle esa suma por debajo de
-- lo que ya llevaba pagado —de otros consumos; los de este no podían estar
-- pagados o la reversión ni empieza—, y entonces la reversión no se
-- descuadraba: reventaba con un 23514 que no explica nada. Con esta misma
-- cuenta de €9,57 entre dos y €2,00 pagados en el bloque, la versión anterior
-- falla así.
--
-- ---------------------------------------------------------------------------
-- El arreglo
-- ---------------------------------------------------------------------------
-- 1. Las cuotas se agrupan por `user_id` ANTES de borrarlas, y a cada bloque se
--    le descuenta lo suyo: su `sum(financed_usd)` de `charged_usd` y su
--    `sum(amount_usd) − sum(financed_usd)` de `fee_usd`. Es exactamente lo
--    contrario de lo que `helios_assign_debt` sumó al crearlas, y se hace igual
--    que allí: una persona, una cuenta.
--
-- 2. El techo del grupo vuelve con él. `group_members.spent_usd` es lo que esa
--    mesa ya le cargó a cada quien esa noche, y nadie lo deshacía — así que un
--    €500 tecleado en vez de €50 quemaba el techo de los cuatro y revertirlo no
--    se lo devolvía: la mesa se quedaba sin sitio para volver a pasar el
--    consumo bueno. Que es el caso para el que existe esta función.
--
-- 3. El aviso va a cada integrante con SU cifra. Antes solo lo recibía quien
--    puso la cuenta, y con el total del cargo: los demás perdían la deuda sin
--    enterarse, y quien lo recibía leía un número que no era el suyo. Para un
--    consumo de una sola persona el texto no cambia ni una letra: su parte ES
--    el total.
--
-- 4. La bitácora y la respuesta guardan el reparto en `split`, no solo los
--    totales. Si mañana hay que revisar una reversión de grupo, la respuesta
--    tiene que estar en el evento y no en una reconstrucción.
--
-- ---------------------------------------------------------------------------
-- Lo que no cambia, y por qué
-- ---------------------------------------------------------------------------
-- Las tres redes ya miraban el cargo entero —cuotas pagadas, reportes,
-- liquidaciones—, así que un pago de cualquier integrante ya frenaba la
-- reversión de todos. Correcto y se queda: se revierte entera o no se revierte.
--
-- Lo que sí se aclara es el MOTIVO de `admin_can_reverse_charge`. En un grupo
-- quien frena suele ser otro, y el super admin está mirando la ficha de quien
-- puso la cuenta: «ya tiene cuotas pagadas» a secas le manda a buscar un pago
-- que en esa ficha no aparece. Ahora el motivo dice de quién, cuando el cargo
-- tiene más de un deudor.
--
-- Lo que NO se hace es aprovechar `reason` para anunciar que se revierte la
-- cuenta entera cuando sí se puede revertir. El panel usa ese campo como
-- bloqueo —`disabled={!!bloqueo || !canReverse}` en `FichaConsumo`—, o sea que
-- un `reason` no nulo con `can_reverse` true deshabilitaría el botón que acaba
-- de decir que sí. El alcance ya lo avisa el diálogo de esa misma pantalla, con
-- el reparto que le manda `admin_charge_detail`.
-- ============================================================================

create or replace function public.admin_reverse_charge(
  p_charge_id uuid,
  p_reason    text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $$
declare
  v_actor    uuid := auth.uid();
  v_charge   public.charges%rowtype;
  v_bdate    date := public.helios_business_date(now());
  v_financed numeric(18,4);
  v_payable  numeric(18,4);
  v_pagadas  integer;
  v_reportes integer;
  v_liq_pag  integer;
  v_tx       uuid;
  v_origen   record;
  v_name     text;
  v_partes   jsonb;
  v_parte    record;
  v_n        integer;
begin
  -- Revertir mueve el libro hacia atrás: es del super admin.
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede revertir un consumo'
      using errcode = '42501';
  end if;

  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'Revertir un consumo requiere motivo' using errcode = '22023';
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;

  if not found then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  if v_charge.status <> 'confirmed' then
    raise exception 'Solo se puede revertir un consumo confirmado (este está %)',
      v_charge.status using errcode = '22023';
  end if;

  -- ── Las tres redes ───────────────────────────────────────────────────────

  select count(*) into v_pagadas
  from public.installments
  where charge_id = p_charge_id and status = 'paid';

  if v_pagadas > 0 then
    raise exception 'Este consumo ya tiene % cuota(s) pagada(s): revertirlo sería devolver dinero, y eso no se hace desde aquí',
      v_pagadas using errcode = '22023';
  end if;

  select count(*) into v_reportes
  from public.payment_reports r
  join public.payment_quote_items qi on qi.quote_id = r.quote_id
  join public.installments i on i.id = qi.installment_id
  where i.charge_id = p_charge_id;

  if v_reportes > 0 then
    raise exception 'Alguien ya reportó un pago para una cuota de este consumo: resuélvelo antes de revertir'
      using errcode = '22023';
  end if;

  select count(*) into v_liq_pag
  from public.settlements
  where charge_id = p_charge_id and status in ('paid', 'partial');

  if v_liq_pag > 0 then
    raise exception 'Al local ya se le pagó parte de este consumo: compensarlo en el próximo cierre es otra operación'
      using errcode = '22023';
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
$$;

comment on function public.admin_reverse_charge(uuid, text) is
  'Deshace un consumo confirmado: asiento contrario —el original se queda—, cuotas borradas, liquidaciones no pagadas canceladas y cupo devuelto. El cupo vuelve POR PERSONA y con el el techo del grupo, porque un consumo de grupo es UN cargo con una cuota por integrante; y avisa a cada integrante con su cifra. Solo si ninguna cuota tiene pagos y al local no se le pago nada de el. Solo super admin.';

revoke all on function public.admin_reverse_charge(uuid, text) from public, anon;
grant execute on function public.admin_reverse_charge(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Si se puede revertir, y por qué no
-- ---------------------------------------------------------------------------
-- La pantalla necesita saberlo **antes** de enseñar el botón. Un botón que
-- explica al pulsarlo por qué no se puede pulsar es un callejón.

create or replace function public.admin_can_reverse_charge(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_charge    public.charges%rowtype;
  v_pagadas   integer;
  v_reportes  integer;
  v_liq_pag   integer;
  v_deudores  integer;
  v_quien     text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  if v_charge.status <> 'confirmed' then
    return jsonb_build_object('can_reverse', false,
      'reason', format('El consumo está %s, no confirmado', v_charge.status));
  end if;

  -- Cuántas personas se reparten este cargo. Un consumo de grupo es UN cargo
  -- con una cuota por integrante, así que quien frena la reversión puede ser
  -- cualquiera de ellos —mientras el super admin está mirando la ficha de quien
  -- puso la cuenta—. Un «ya tiene cuotas pagadas» a secas le manda a buscar en
  -- esa ficha un pago que no está ahí.
  select count(distinct user_id) into v_deudores
  from public.installments where charge_id = p_charge_id;

  select count(*), string_agg(distinct pr.full_name, ', ')
  into v_pagadas, v_quien
  from public.installments i
  left join public.profiles pr on pr.id = i.user_id
  where i.charge_id = p_charge_id and i.status = 'paid';

  if v_pagadas > 0 then
    return jsonb_build_object('can_reverse', false,
      'reason', case when v_deudores > 1 and v_quien is not null then
        format('Ya tiene cuotas pagadas (%s): revertirlo sería devolver dinero', v_quien)
      else
        'Ya tiene cuotas pagadas: revertirlo sería devolver dinero'
      end);
  end if;

  select count(*), string_agg(distinct pr.full_name, ', ')
  into v_reportes, v_quien
  from public.payment_reports r
  join public.payment_quote_items qi on qi.quote_id = r.quote_id
  join public.installments i on i.id = qi.installment_id
  left join public.profiles pr on pr.id = i.user_id
  where i.charge_id = p_charge_id;

  if v_reportes > 0 then
    return jsonb_build_object('can_reverse', false,
      'reason', case when v_deudores > 1 and v_quien is not null then
        format('%s reportó un pago para una de sus cuotas', v_quien)
      else
        'Alguien reportó un pago para una de sus cuotas'
      end);
  end if;

  select count(*) into v_liq_pag
  from public.settlements
  where charge_id = p_charge_id and status in ('paid', 'partial');

  if v_liq_pag > 0 then
    return jsonb_build_object('can_reverse', false,
      'reason', 'Al local ya se le pagó parte de este consumo');
  end if;

  return jsonb_build_object('can_reverse', true, 'reason', null);
end;
$$;

revoke all on function public.admin_can_reverse_charge(uuid) from public, anon;
grant execute on function public.admin_can_reverse_charge(uuid) to authenticated;
