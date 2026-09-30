-- El segundo factor también vale para escribir.
--
-- is_platform_admin() pide una sesión aal2 cuando platform_security.require_mfa
-- está encendida, pero las escrituras del super admin no pasaban por ella:
-- helios_assert_super_admin y la consulta a mano a platform_admins que copiaban
-- una treintena de funciones solo miraban el rol. Con la exigencia encendida,
-- una sesión de solo contraseña leía poco y podía escribir todo llamando a la
-- API.
--
-- 1. helios_assert_super_admin exige además lo mismo que is_platform_admin():
--    si la exigencia está apagada, se comporta igual que antes.
-- 2. Las funciones que miraban platform_admins a mano pasan a llamarla. Solo
--    cambia la guarda: el cuerpo de cada una es el vivo de dev, copiado tal cual.
--    Las que además ganan p_note van en 20260925132000.

create or replace function public.helios_assert_super_admin(p_what text)
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede %', p_what using errcode = '42501';
  end if;

  -- La misma comprobación que las lecturas. Aquí ya se sabe que es un super
  -- admin activo, así que un false solo puede ser la sesión: la exigencia está
  -- encendida y no pasó por el segundo factor.
  if not public.is_platform_admin() then
    raise exception 'Para % hace falta entrar con el segundo factor. Vuelve a iniciar sesión.', p_what
      using errcode = '42501';
  end if;

  return v_actor;
end;
$$;

comment on function public.helios_assert_super_admin(text) is
  'Guarda de las escrituras del super admin: rol activo y, si platform_security.require_mfa está encendida, sesión aal2 (la misma comprobación que is_platform_admin). Devuelve auth.uid().';

revoke all on function public.helios_assert_super_admin(text) from public, anon, authenticated;

-- public.admin_create_merchant(text, text, text, merchant_category, text, text, text, text)
CREATE OR REPLACE FUNCTION public.admin_create_merchant(p_name text, p_legal_name text DEFAULT NULL::text, p_tax_id text DEFAULT NULL::text, p_category merchant_category DEFAULT NULL::merchant_category, p_city text DEFAULT NULL::text, p_handle text DEFAULT NULL::text, p_logo_url text DEFAULT NULL::text, p_social_url text DEFAULT NULL::text)
 RETURNS merchants
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor  uuid := auth.uid();
  v_row    public.merchants%rowtype;
  v_handle text;
  v_tax_id text;
begin
  perform public.helios_assert_super_admin('dar de alta comercios');

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'El comercio necesita nombre' using errcode = '22023';
  end if;

  -- Obligatorio desde 2026-08-25. La validación vive aquí y no en un
  -- constraint de columna porque hay filas antiguas sin RIF que deben poder
  -- seguir existiendo mientras se completan.
  v_tax_id := public.normalize_tax_id(p_tax_id);
  if v_tax_id is null then
    raise exception 'El RIF es obligatorio' using errcode = '22023';
  end if;

  if exists (select 1 from public.merchants where tax_id = v_tax_id) then
    raise exception 'Ya hay un comercio dado de alta con el RIF %', v_tax_id
      using errcode = '23505';
  end if;

  -- Se guarda sin `@`: la app ya lo antepone al mostrarlo (buscar.tsx), y
  -- guardarlo con o sin arroba según lo que tecleó cada admin habría hecho
  -- que la búsqueda por handle nunca fuera consistente.
  v_handle := nullif(trim(coalesce(p_handle, '')), '');
  if v_handle is not null then
    v_handle := regexp_replace(v_handle, '^@+', '');
  end if;

  insert into public.merchants
    (name, legal_name, tax_id, category, city, handle, logo_url, social_url)
  values (
    trim(p_name),
    nullif(trim(coalesce(p_legal_name, '')), ''),
    v_tax_id,
    p_category,
    nullif(trim(coalesce(p_city, '')), ''),
    v_handle,
    nullif(trim(coalesce(p_logo_url, '')), ''),
    nullif(trim(coalesce(p_social_url, '')), '')
  )
  returning * into v_row;

  perform audit.log(v_actor, 'merchant.created', v_row.id,
    jsonb_build_object('name', v_row.name, 'tax_id', v_row.tax_id, 'category', v_row.category));

  return v_row;
end;
$function$;

-- public.admin_publish_terms(text, text, text, text)
CREATE OR REPLACE FUNCTION public.admin_publish_terms(p_version text, p_body text, p_summary text DEFAULT NULL::text, p_url text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
begin
  perform public.helios_assert_super_admin('publicar los términos');

  if p_version is null or length(trim(p_version)) = 0 then
    raise exception 'La versión necesita nombre' using errcode = '22023';
  end if;

  if p_body is null or length(trim(p_body)) < 50 then
    raise exception 'El texto de los términos no puede estar vacío' using errcode = '22023';
  end if;

  -- Una versión publicada no se reescribe: hay gente que la aceptó.
  if exists (select 1 from public.terms_versions where version = trim(p_version)) then
    raise exception 'La versión % ya está publicada. Publica otra.', trim(p_version)
      using errcode = '23505';
  end if;

  update public.terms_versions set is_current = false where is_current;

  insert into public.terms_versions (version, body, summary, url, published_by, is_current)
  values (
    trim(p_version), p_body,
    nullif(trim(coalesce(p_summary, '')), ''),
    nullif(trim(coalesce(p_url, '')), ''),
    v_actor, true
  );

  perform audit.log(v_actor, 'terms.published', null, jsonb_build_object(
    'version', trim(p_version), 'summary', p_summary
  ));

  return jsonb_build_object('ok', true, 'version', trim(p_version));
end;
$function$;

-- public.admin_record_bank_balance(numeric, numeric, date, text)
CREATE OR REPLACE FUNCTION public.admin_record_bank_balance(p_balance_ves numeric DEFAULT NULL::numeric, p_balance_usd numeric DEFAULT NULL::numeric, p_checked_on date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'audit', 'pg_temp'
AS $function$
declare
  v_actor  uuid := auth.uid();
  v_day    date;
  v_fx     numeric;
  v_usd    numeric(18,4);
  v_ledger numeric(18,4);
begin
  perform public.helios_assert_super_admin('anotar el saldo del banco');

  if p_balance_ves is null and p_balance_usd is null then
    raise exception 'Escribe el saldo, en bolívares o en euros' using errcode = '22023';
  end if;

  v_day := coalesce(p_checked_on, public.helios_business_date(now()));

  if v_day > public.helios_business_date(now()) then
    raise exception 'No se puede anotar el saldo de un día que no ha pasado'
      using errcode = '22023';
  end if;

  v_fx := public.current_fx_rate('BCV', v_day);

  if p_balance_usd is not null then
    v_usd := p_balance_usd;
  elsif v_fx is null then
    raise exception 'No hay tasa para ese día: escribe el saldo en euros'
      using errcode = '22023';
  else
    v_usd := round(p_balance_ves / v_fx, 4);
  end if;

  -- La caja del libro a esa fecha: todo lo que movió caja hasta ese día
  -- operativo, incluido.
  select coalesce(sum(e.debit) - sum(e.credit), 0)
  into v_ledger
  from ledger.entries e
  join ledger.accounts a on a.id = e.account_id
  join ledger.transactions t on t.id = e.transaction_id
  where a.account_type = 'cash'
    and t.business_date <= v_day;

  insert into public.bank_balance_checks
    (checked_on, balance_ves, balance_usd, fx_rate, ledger_usd, note, recorded_by)
  values (v_day, p_balance_ves, v_usd, v_fx, v_ledger,
          nullif(trim(coalesce(p_note, '')), ''), v_actor)
  on conflict (checked_on) do update
    set balance_ves = excluded.balance_ves,
        balance_usd = excluded.balance_usd,
        fx_rate     = excluded.fx_rate,
        ledger_usd  = excluded.ledger_usd,
        note        = excluded.note,
        recorded_by = excluded.recorded_by,
        created_at  = now();

  perform audit.log(v_actor, 'bank_balance.recorded', null, jsonb_build_object(
    'checked_on', v_day,
    'balance_usd', v_usd,
    'ledger_usd', v_ledger,
    'difference_usd', round(v_usd - v_ledger, 4),
    'note', p_note
  ));

  return jsonb_build_object(
    'ok', true,
    'checked_on', v_day,
    'balance_usd', v_usd,
    'ledger_usd', v_ledger,
    'difference_usd', round(v_usd - v_ledger, 4)
  );
end;
$function$;

-- public.admin_report_merchant_payout(uuid, uuid[], text, text, numeric, numeric, text, numeric, date, text)
CREATE OR REPLACE FUNCTION public.admin_report_merchant_payout(p_merchant_id uuid, p_settlement_ids uuid[], p_method text, p_reference text DEFAULT NULL::text, p_amount_ves numeric DEFAULT NULL::numeric, p_fx_rate numeric DEFAULT NULL::numeric, p_note text DEFAULT NULL::text, p_amount_usd numeric DEFAULT NULL::numeric, p_paid_on date DEFAULT NULL::date, p_receipt_path text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'audit', 'pg_temp'
AS $function$
declare
  v_actor       uuid := auth.uid();
  v_pendiente   numeric(18,4);
  v_total       numeric(18,4);
  v_restante    numeric(18,4);
  v_aplicado    numeric(18,4);
  v_count       integer;
  v_bdate       date;
  v_paid_on     date;
  v_payout      public.merchant_payouts%rowtype;
  v_tx          uuid;
  v_acct_pay    uuid;
  v_acct_cash   uuid;
  v_fx          numeric;
  v_ves         numeric;
  v_fila        record;
begin
  -- Registrar un pago mueve la caja del libro: es del super admin.
  perform public.helios_assert_super_admin('registrar pagos a comercios');

  if p_settlement_ids is null or array_length(p_settlement_ids, 1) is null then
    raise exception 'Selecciona al menos una liquidación' using errcode = '22023';
  end if;

  -- Se bloquean las filas antes de sumar: dos operadores pagando el mismo
  -- comercio a la vez no pueden liquidar dos veces lo mismo.
  perform 1 from public.settlements
  where id = any(p_settlement_ids) for update;

  select coalesce(sum(amount_usd - paid_usd), 0), count(*)
    into v_pendiente, v_count
  from public.settlements
  where id = any(p_settlement_ids)
    and merchant_id = p_merchant_id
    and status in ('pending', 'partial');

  if v_count <> array_length(p_settlement_ids, 1) then
    raise exception 'Alguna liquidación no es de este comercio o ya está pagada entera'
      using errcode = '22023';
  end if;

  -- Sin importe se paga todo lo marcado, que es el caso normal.
  v_total := coalesce(p_amount_usd, v_pendiente);

  if v_total <= 0 then
    raise exception 'El importe tiene que ser mayor que cero' using errcode = '22023';
  end if;

  -- Hacia arriba no: pagar de más no es un pago parcial al revés, es un error
  -- de tecleo que dejaría el libro con caja negativa contra ese comercio.
  if v_total > v_pendiente + 0.005 then
    raise exception 'No puedes registrar % cuando lo marcado suma %',
      v_total, v_pendiente using errcode = '22023';
  end if;

  v_bdate   := public.helios_business_date(now());
  v_paid_on := coalesce(p_paid_on, v_bdate);

  -- Una fecha de pago en el futuro es siempre un error de tecleo.
  if v_paid_on > v_bdate then
    raise exception 'La fecha del pago no puede ser posterior a hoy' using errcode = '22023';
  end if;

  -- La conversión, si toca. `current_fx_rate()` puede devolver null si la
  -- ingesta lleva días rota: en ese caso se guarda null, en vez de inventar
  -- una tasa. El aviso de tasa vieja del panel es lo que tiene que sonar ahí.
  if p_method in ('pago_movil', 'transferencia') then
    v_fx  := coalesce(p_fx_rate, public.current_fx_rate('BCV', v_paid_on));
    v_ves := coalesce(p_amount_ves, round(v_total * v_fx, 2));
  else
    v_fx  := p_fx_rate;
    v_ves := p_amount_ves;
  end if;

  insert into public.merchant_payouts
    (merchant_id, amount_usd, amount_ves, fx_rate, method, reference, note,
     paid_by, business_date, paid_on, receipt_path)
  values
    (p_merchant_id, v_total, v_ves, v_fx, p_method, p_reference, p_note,
     v_actor, v_bdate, v_paid_on, nullif(trim(coalesce(p_receipt_path, '')), ''))
  returning * into v_payout;

  -- El reparto: de la más antigua a la más nueva. La última que alcanza queda
  -- parcial con su resto y sigue apareciendo en el cierre.
  v_restante := v_total;

  for v_fila in
    select id, amount_usd, paid_usd, due_date
    from public.settlements
    where id = any(p_settlement_ids)
    order by due_date, id
  loop
    exit when v_restante <= 0;

    v_aplicado := least(v_restante, v_fila.amount_usd - v_fila.paid_usd);
    if v_aplicado <= 0 then
      continue;
    end if;

    update public.settlements
    set paid_usd = paid_usd + v_aplicado,
        status = case
          when paid_usd + v_aplicado >= amount_usd - 0.005 then 'paid'::public.settlement_status
          else 'partial'::public.settlement_status
        end
    where id = v_fila.id;

    insert into public.merchant_payout_items (payout_id, settlement_id, amount_usd)
    values (v_payout.id, v_fila.id, v_aplicado);

    v_restante := v_restante - v_aplicado;
  end loop;

  -- AHORA sí sale el dinero: es el momento en que de verdad salió del banco.
  v_acct_pay  := ledger.get_or_create_account('merchant_payable', p_merchant_id);
  v_acct_cash := ledger.get_or_create_account('cash', null);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'merchant_settlement', 'payout:' || v_payout.id::text, v_bdate, v_payout.id,
    format('Pago al comercio (%s liquidaciones)', v_count)
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_pay, v_total, 0),
    (v_tx, v_acct_cash, 0, v_total);

  perform audit.log(v_actor, 'merchant.payout', p_merchant_id,
    jsonb_build_object(
      'payout_id', v_payout.id, 'amount_usd', v_total,
      'pending_usd', v_pendiente,
      'partial', v_total < v_pendiente - 0.005,
      'settlements', v_count, 'method', p_method, 'reference', p_reference,
      'paid_on', v_paid_on, 'amount_ves', v_ves, 'fx_rate', v_fx,
      'has_receipt', p_receipt_path is not null
    ));

  return jsonb_build_object(
    'ok', true, 'payout_id', v_payout.id,
    'amount_usd', v_total, 'pending_usd', v_pendiente, 'settlements', v_count,
    'amount_ves', v_ves, 'fx_rate', v_fx, 'paid_on', v_paid_on
  );
end;
$function$;

-- public.admin_reset_collection_template(text)
CREATE OR REPLACE FUNCTION public.admin_reset_collection_template(p_bucket text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
begin
  perform public.helios_assert_super_admin('cambiar las plantillas de cobranza');

  update public.collection_templates
  set body = default_body, updated_by = v_actor, updated_at = now()
  where bucket = p_bucket;

  perform audit.log(v_actor, 'collection_template.reset', null,
    jsonb_build_object('bucket', p_bucket));
end;
$function$;

-- public.admin_resolve_deletion_request(uuid, account_deletion_status, text)
CREATE OR REPLACE FUNCTION public.admin_resolve_deletion_request(p_id uuid, p_status account_deletion_status, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_row   public.account_deletion_requests%rowtype;
  v_note  text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform public.helios_assert_super_admin('resolver una solicitud de eliminación');

  if p_status not in ('completed', 'rejected') then
    raise exception 'Una solicitud se cierra como completada o rechazada'
      using errcode = '22023';
  end if;

  if p_status = 'rejected' and v_note is null then
    raise exception 'Escribe el motivo del rechazo' using errcode = '22023';
  end if;

  update public.account_deletion_requests
  set status      = p_status,
      reviewed_by = v_actor,
      reviewed_at = now(),
      review_note = v_note
  where id = p_id
    and status = 'pending'
  returning * into v_row;

  if not found then
    raise exception 'Esa solicitud ya no esta pendiente' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'account_deletion.' || p_status, p_id, jsonb_build_object(
    'user_id', v_row.user_id,
    'note',    v_note
  ));

  return jsonb_build_object('id', v_row.id, 'status', v_row.status);
end;
$function$;

-- public.admin_reverse_charge(uuid, text)
CREATE OR REPLACE FUNCTION public.admin_reverse_charge(p_charge_id uuid, p_reason text)
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
  perform public.helios_assert_super_admin('revertir un consumo');

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
$function$;

-- public.admin_set_blacklist(uuid, boolean, text)
CREATE OR REPLACE FUNCTION public.admin_set_blacklist(p_user_id uuid, p_flag boolean, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
begin
  perform public.helios_assert_super_admin('marcar una cuenta');

  if p_flag and (p_reason is null or length(trim(p_reason)) < 3) then
    raise exception 'Marcar una cuenta requiere motivo' using errcode = '22023';
  end if;

  update public.profiles
    set is_blacklisted = p_flag,
        blacklist_reason = case when p_flag then p_reason else null end,
        updated_at = now()
  where id = p_user_id;

  if not found then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'user.set_blacklist', p_user_id, jsonb_build_object(
    'flag', p_flag, 'reason', p_reason
  ));
end;
$function$;

-- public.admin_set_business_parameter(text, numeric, date, text)
CREATE OR REPLACE FUNCTION public.admin_set_business_parameter(p_key text, p_value numeric, p_effective_from date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_today date := public.helios_business_date(now());
  v_desde date;
  v_antes numeric;
  v_unit  text;
begin
  perform public.helios_assert_super_admin('cambiar un parámetro del negocio');

  select c.unit into v_unit
  from public.business_parameter_catalog c where c.key = p_key;

  if v_unit is null
     and not exists (select 1 from public.business_parameters where key = p_key) then
    raise exception 'No existe el parámetro %', p_key using errcode = '22023';
  end if;

  if p_value is null then
    raise exception 'El parámetro necesita un valor' using errcode = '22023';
  end if;

  v_desde := coalesce(p_effective_from, v_today);

  -- Hacia atrás no. Cambiar la vigencia de un parámetro en el pasado no
  -- reescribe lo que ya pasó —el motor aplicó lo que aplicó— pero sí haría
  -- que el histórico mintiera sobre ello.
  if v_desde < v_today then
    raise exception 'Un parámetro no puede entrar en vigor en el pasado'
      using errcode = '22023';
  end if;

  if p_value < 0 then
    raise exception 'Un parámetro no puede ser negativo' using errcode = '22023';
  end if;

  if v_unit = '%' and p_value > 100 then
    raise exception 'Un porcentaje no puede pasar de 100' using errcode = '22023';
  end if;

  select public.helios_parameter(p_key, null) into v_antes;

  insert into public.business_parameters (key, value, effective_from, note, created_by)
  values (p_key, p_value, v_desde, nullif(trim(coalesce(p_note, '')), ''), v_actor)
  on conflict (key, effective_from) do update
    set value = excluded.value, note = excluded.note,
        created_by = excluded.created_by, created_at = now();

  perform audit.log(v_actor, 'parameter.set', null, jsonb_build_object(
    'key', p_key,
    'from_value', v_antes,
    'to_value', p_value,
    'effective_from', v_desde,
    'note', p_note
  ));

  return jsonb_build_object(
    'ok', true, 'key', p_key, 'value', p_value, 'effective_from', v_desde
  );
end;
$function$;

-- public.admin_set_collection_template(text, text)
CREATE OR REPLACE FUNCTION public.admin_set_collection_template(p_bucket text, p_body text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor    uuid := auth.uid();
  v_antes    text;
  v_permitidas text[] := array[
    'nombre', 'monto_usd', 'monto_bs', 'fecha_vencimiento',
    'banco', 'telefono_pago', 'cedula_pago'
  ];
  v_desconocida text;
begin
  -- Cambiar el texto que se le manda a la gente es del super admin, igual que
  -- publicar un aviso automático.
  perform public.helios_assert_super_admin('cambiar las plantillas de cobranza');

  select body into v_antes from public.collection_templates where bucket = p_bucket;
  if not found then
    raise exception 'No existe la plantilla %', p_bucket using errcode = '22023';
  end if;

  if p_body is null or length(trim(p_body)) < 20 then
    raise exception 'El mensaje no puede estar vacío' using errcode = '22023';
  end if;

  -- Una variable que no existe sale con las llaves a la vista en el teléfono
  -- de alguien. Se corta aquí.
  select m[1] into v_desconocida
  from regexp_matches(p_body, '\{(\w+)\}', 'g') m
  where not (m[1] = any(v_permitidas))
  limit 1;

  if v_desconocida is not null then
    raise exception 'La plantilla usa {%}, que no existe. Las disponibles son: %',
      v_desconocida, array_to_string(v_permitidas, ', ')
      using errcode = '22023';
  end if;

  update public.collection_templates
  set body = trim(p_body), updated_by = v_actor, updated_at = now()
  where bucket = p_bucket;

  perform audit.log(v_actor, 'collection_template.set', null, jsonb_build_object(
    'bucket', p_bucket,
    'from_body', v_antes,
    'to_body', trim(p_body)
  ));

  return jsonb_build_object('ok', true, 'bucket', p_bucket);
end;
$function$;

-- public.admin_set_fx_rate(numeric, date, text)
CREATE OR REPLACE FUNCTION public.admin_set_fx_rate(p_rate numeric, p_effective_date date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor     uuid := auth.uid();
  v_effective date := coalesce(p_effective_date, public.helios_business_date(now()));
  v_previous  numeric := public.current_fx_rate('BCV', v_effective);
begin
  perform public.helios_assert_super_admin('cargar la tasa a mano');

  if p_rate is null or p_rate <= 0 then
    raise exception 'La tasa debe ser positiva' using errcode = '22023';
  end if;

  if v_effective > public.helios_business_date(now()) then
    raise exception 'No se puede cargar la tasa de un día que aún no empezó'
      using errcode = '22023';
  end if;

  perform public.record_fx_rate(p_rate, v_effective, 'BCV');

  insert into public.fx_rate_syncs (source_key, effective_date, status, rate, detail)
  values ('manual', v_effective, 'manual', p_rate,
          coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Carga manual'));

  perform audit.log(v_actor, 'fx_rate.manual', null, jsonb_build_object(
    'rate', p_rate, 'previous', v_previous, 'effective_date', v_effective, 'note', p_note
  ));

  return jsonb_build_object('ok', true, 'rate', p_rate, 'effective_date', v_effective);
end;
$function$;

-- public.admin_set_holiday(date, text, text, boolean)
CREATE OR REPLACE FUNCTION public.admin_set_holiday(p_day date, p_name text, p_kind text DEFAULT 'nacional'::text, p_remove boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
begin
  perform public.helios_assert_super_admin('tocar el calendario');

  if p_remove then
    delete from public.holidays where day = p_day;
    perform audit.log(v_actor, 'holiday.removed', null,
      jsonb_build_object('day', p_day));
    return;
  end if;

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'El feriado necesita nombre' using errcode = '22023';
  end if;

  insert into public.holidays (day, name, kind, created_by)
  values (p_day, trim(p_name), coalesce(nullif(trim(p_kind), ''), 'nacional'), v_actor)
  on conflict (day) do update
    set name = excluded.name, kind = excluded.kind;

  perform audit.log(v_actor, 'holiday.set', null,
    jsonb_build_object('day', p_day, 'name', trim(p_name), 'kind', p_kind));
end;
$function$;

-- public.admin_set_merchant_profile(uuid, merchant_category, text, text, text, text, text)
CREATE OR REPLACE FUNCTION public.admin_set_merchant_profile(p_merchant_id uuid, p_category merchant_category, p_city text, p_handle text, p_logo_url text, p_social_url text DEFAULT NULL::text, p_tax_id text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor  uuid := auth.uid();
  v_handle text;
  v_tax_id text;
begin
  perform public.helios_assert_super_admin('editar comercios');

  v_handle := nullif(trim(coalesce(p_handle, '')), '');
  if v_handle is not null then
    v_handle := regexp_replace(v_handle, '^@+', '');
  end if;

  v_tax_id := public.normalize_tax_id(p_tax_id);

  if v_tax_id is not null and exists (
    select 1 from public.merchants where tax_id = v_tax_id and id <> p_merchant_id
  ) then
    raise exception 'Ese RIF ya es de otro comercio' using errcode = '23505';
  end if;

  update public.merchants
    set category   = p_category,
        city       = nullif(trim(coalesce(p_city, '')), ''),
        handle     = v_handle,
        logo_url   = nullif(trim(coalesce(p_logo_url, '')), ''),
        social_url = nullif(trim(coalesce(p_social_url, '')), ''),
        -- Null deja el RIF como estaba: la pantalla de perfil no debe poder
        -- borrar un identificador fiscal por omisión.
        tax_id     = coalesce(v_tax_id, tax_id),
        updated_at = now()
  where id = p_merchant_id;

  if not found then
    raise exception 'Comercio no encontrado' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.set_profile', p_merchant_id, jsonb_build_object(
    'category', p_category, 'city', p_city, 'handle', v_handle,
    'logo_url', p_logo_url, 'social_url', p_social_url, 'tax_id', v_tax_id
  ));
end;
$function$;

-- public.admin_set_merchant_status(uuid, merchant_status, text)
CREATE OR REPLACE FUNCTION public.admin_set_merchant_status(p_merchant_id uuid, p_status merchant_status, p_note text DEFAULT NULL::text)
 RETURNS merchants
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_row   public.merchants%rowtype;
  v_owed  numeric(18,4);
begin
  perform public.helios_assert_super_admin('cambiar el estado de un comercio');

  -- Terminar un comercio al que todavía se le debe dinero es casi siempre un
  -- error: lo pendiente hay que pagarlo igual. Se bloquea y se dice cuánto.
  if p_status = 'terminated' then
    -- NUEVO (2026-09-18): las parciales cuentan, y cuenta lo que FALTA.
    --
    -- Sumaba el importe entero de las `pending` y se olvidaba de las
    -- `partial`, que existen desde 20260911191000 y son justo las que llevan
    -- un resto por transferir. Con una liquidación a medias como única deuda,
    -- esto daba cero y dejaba terminar un comercio al que todavía se le debe
    -- dinero —dinero que sigue vivo y sigue saliendo en el cierre del lunes,
    -- porque `helios_settlement_outlook` sí las cuenta—.
    select coalesce(sum(amount_usd - paid_usd), 0) into v_owed
    from public.settlements
    where merchant_id = p_merchant_id and status in ('pending', 'partial');

    if v_owed > 0 then
      -- Con dos decimales y no los cuatro de la columna: este texto se lee tal
      -- cual en el panel, y «le debes €6.0000» parece un error de la pantalla.
      raise exception 'No puedes terminar este comercio: le debes €%. Págale primero.',
        to_char(v_owed, 'FM999999990.00')
        using errcode = '22023';
    end if;
  end if;

  update public.merchants
    set status = p_status, updated_at = now()
  where id = p_merchant_id
  returning * into v_row;

  if not found then
    raise exception 'Comercio no encontrado' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.status_changed', p_merchant_id,
    jsonb_build_object('status', p_status, 'note', p_note));

  return v_row;
end;
$function$;

-- public.admin_set_notification_schedule(text, time without time zone, integer)
CREATE OR REPLACE FUNCTION public.admin_set_notification_schedule(p_key text, p_run_at time without time zone, p_lead_days integer DEFAULT NULL::integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_tpl   public.notification_templates%rowtype;
  v_cmd   text;
  v_utc   time;
begin
  perform public.helios_assert_super_admin('cambiar el horario de un aviso');

  select * into v_tpl from public.notification_templates where key = p_key;
  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = '22023';
  end if;

  if v_tpl.cron_job is null then
    raise exception '"%" no lo dispara el cron: lo dispara un evento, y un evento no tiene hora',
      v_tpl.label using errcode = '22023';
  end if;

  if p_run_at is null then
    raise exception 'Hace falta una hora' using errcode = '22023';
  end if;

  if p_lead_days is not null and p_lead_days not between 1 and 30 then
    raise exception 'La antelación va entre 1 y 30 días' using errcode = '22023';
  end if;

  select command into v_cmd from cron.job where jobname = v_tpl.cron_job;
  if v_cmd is null then
    raise exception 'El cron no tiene ningún trabajo llamado %', v_tpl.cron_job
      using errcode = '22023';
  end if;

  v_utc := (((current_date + p_run_at) at time zone 'America/Caracas')
            at time zone 'UTC')::time;

  perform cron.schedule(
    v_tpl.cron_job,
    format('%s %s * * *',
           extract(minute from v_utc)::integer,
           extract(hour   from v_utc)::integer),
    v_cmd
  );

  update public.notification_templates
     set run_at    = p_run_at,
         lead_days = coalesce(p_lead_days, lead_days)
   where key = p_key;

  perform audit.log(v_actor, 'notification.schedule', null::uuid,
    jsonb_build_object('key', p_key, 'run_at', p_run_at, 'lead_days', p_lead_days));
end;
$function$;

-- public.admin_set_require_mfa(boolean)
CREATE OR REPLACE FUNCTION public.admin_set_require_mfa(p_require boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_total integer;
  v_con   integer;
begin
  perform public.helios_assert_super_admin('tocar la seguridad del panel');

  if p_require then
    select
      count(*)::integer,
      count(*) filter (where public.helios_has_mfa(t.user_id))::integer
    into v_total, v_con
    from public.platform_admins t
    where t.is_active;

    -- La red que impide dejar al equipo fuera. Vive aquí y no solo en la
    -- pantalla: una regla que solo vive en la pantalla no es una regla.
    if v_con < v_total then
      raise exception 'Todavía hay % de % personas del equipo sin segundo factor. Que lo activen antes de exigirlo.',
        v_total - v_con, v_total using errcode = '22023';
    end if;

    -- Y quien lo enciende tiene que estar entrando con el suyo, o se queda
    -- fuera en el mismo instante en que lo enciende.
    if coalesce(
      current_setting('request.jwt.claims', true)::jsonb ->> 'aal', 'aal1'
    ) <> 'aal2' then
      raise exception 'Tu sesión es de un solo factor. Vuelve a entrar con el segundo factor antes de exigirlo.'
        using errcode = '22023';
    end if;
  end if;

  update public.platform_security
  set require_mfa = p_require, updated_by = v_actor, updated_at = now()
  where id;

  perform audit.log(v_actor, 'security.require_mfa', null,
    jsonb_build_object('require_mfa', p_require));

  return jsonb_build_object('ok', true, 'require_mfa', p_require);
end;
$function$;

-- public.admin_set_settlement_terms(uuid, numeric, numeric, numeric, settlement_policy)
CREATE OR REPLACE FUNCTION public.admin_set_settlement_terms(p_merchant_id uuid, p_upfront_pct numeric, p_per_installment_pct numeric, p_commission_pct numeric, p_policy settlement_policy)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_total numeric(6,2);
  v_old   public.merchant_settlement_terms%rowtype;
begin
  perform public.helios_assert_super_admin('cambiar las condiciones de un comercio');

  if p_upfront_pct < 0 or p_per_installment_pct < 0 or p_commission_pct < 0 then
    raise exception 'Ningún porcentaje puede ser negativo' using errcode = '22023';
  end if;

  /**
   * LOS TRAMOS CUBREN EL NETO; LA COMISIÓN VA APARTE.
   *
   * 🐛 Esta comprobación sumaba también `p_commission_pct` y exigía 100:
   *
   *     v_total := upfront + (per_installment * 2) + commission;
   *
   * Era la aritmética del modelo anterior, donde el comercio cobraba el 80 %
   * del consumo y la comisión era el 20 % restante. Con la facturación por
   * cuenta de terceros (20260827100000) la comisión pasó a cobrarse aparte y
   * los tres tramos reparten el NETO — y el check de la tabla se cambió a
   * `upfront + per_installment*2 = 100`, pero esta función no.
   *
   * Las dos condiciones son incompatibles salvo con comisión 0, así que
   * renegociar las condiciones de un comercio era IMPOSIBLE desde el súper
   * admin: o rebotaba aquí, o rebotaba en el constraint. Lo cazó
   * `edit_merchants_smoke`.
   */
  v_total := p_upfront_pct + (p_per_installment_pct * 2);

  if v_total <> 100.00 then
    -- Sin signos de porcentaje literales en el mensaje: en RAISE, `%` es el
    -- marcador y `%%` el signo, y mezclarlos hace que el número de huecos no
    -- cuadre con los argumentos.
    raise exception
      'Los tramos de liquidación suman % y deben sumar 100. Adelanto: %. Por cuota: % (x2). La comisión (%) va aparte y no entra en esta suma.',
      v_total, p_upfront_pct, p_per_installment_pct, p_commission_pct
      using errcode = '22023';
  end if;

  if p_commission_pct > 100.00 then
    raise exception 'La comisión no puede pasar del 100' using errcode = '22023';
  end if;

  select * into v_old from public.merchant_settlement_terms
  where merchant_id = p_merchant_id;

  if not found then
    raise exception 'Ese comercio no tiene condiciones que cambiar' using errcode = 'P0002';
  end if;

  update public.merchant_settlement_terms
    set upfront_pct = p_upfront_pct,
        per_installment_pct = p_per_installment_pct,
        commission_pct = p_commission_pct,
        policy = p_policy,
        updated_at = now()
  where merchant_id = p_merchant_id;

  perform audit.log(v_actor, 'merchant.terms_changed', p_merchant_id,
    jsonb_build_object(
      'antes', jsonb_build_object(
        'upfront', v_old.upfront_pct, 'per_installment', v_old.per_installment_pct,
        'commission', v_old.commission_pct, 'policy', v_old.policy),
      'despues', jsonb_build_object(
        'upfront', p_upfront_pct, 'per_installment', p_per_installment_pct,
        'commission', p_commission_pct, 'policy', p_policy)
    ));

  return jsonb_build_object(
    'ok', true,
    'upfront_pct', p_upfront_pct,
    'per_installment_pct', p_per_installment_pct,
    'commission_pct', p_commission_pct,
    'policy', p_policy
  );
end;
$function$;

-- public.admin_set_settlement_terms(uuid, numeric, numeric, numeric, text, date, text)
CREATE OR REPLACE FUNCTION public.admin_set_settlement_terms(p_merchant_id uuid, p_upfront_pct numeric, p_per_installment_pct numeric, p_commission_pct numeric, p_policy text, p_effective_from date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_today date := public.helios_business_date(now());
  v_desde date;
  v_antes public.merchant_terms;
  v_name  text;
begin
  perform public.helios_assert_super_admin('cambiar las condiciones de un comercio');

  select name into v_name from public.merchants where id = p_merchant_id;
  if not found then
    raise exception 'No existe ese comercio' using errcode = '22023';
  end if;

  v_desde := coalesce(p_effective_from, v_today);

  -- Hacia atrás no. Cambiar las condiciones de un día que ya pasó reescribiría
  -- lo que se le liquidó al local por ventas que ya se liquidaron.
  if v_desde < v_today then
    raise exception 'Las condiciones no pueden entrar en vigor en el pasado'
      using errcode = '22023';
  end if;

  if abs(p_upfront_pct + (p_per_installment_pct * 2) - 100.00) > 0.001 then
    raise exception 'El adelanto y las dos cuotas tienen que repartir el neto entero: % + (% × 2) da %, no 100',
      p_upfront_pct, p_per_installment_pct,
      p_upfront_pct + (p_per_installment_pct * 2)
      using errcode = '22023';
  end if;

  if p_upfront_pct < 0 or p_per_installment_pct < 0 or p_commission_pct < 0 then
    raise exception 'Ningún porcentaje puede ser negativo' using errcode = '22023';
  end if;

  select * into v_antes from public.helios_terms_at(p_merchant_id, v_today);

  insert into public.merchant_terms
    (merchant_id, upfront_pct, per_installment_pct, commission_pct, policy,
     effective_from, note, created_by)
  values (
    p_merchant_id, p_upfront_pct, p_per_installment_pct, p_commission_pct,
    p_policy::public.settlement_policy, v_desde,
    nullif(trim(coalesce(p_note, '')), ''), v_actor
  )
  on conflict (merchant_id, effective_from) do update
    set upfront_pct = excluded.upfront_pct,
        per_installment_pct = excluded.per_installment_pct,
        commission_pct = excluded.commission_pct,
        policy = excluded.policy,
        note = excluded.note,
        created_by = excluded.created_by,
        created_at = now();

  perform audit.log(v_actor, 'merchant.set_terms', p_merchant_id, jsonb_build_object(
    'merchant_name', v_name,
    'effective_from', v_desde,
    'from_upfront_pct', v_antes.upfront_pct,
    'to_upfront_pct', p_upfront_pct,
    'from_per_installment_pct', v_antes.per_installment_pct,
    'to_per_installment_pct', p_per_installment_pct,
    'from_commission_pct', v_antes.commission_pct,
    'to_commission_pct', p_commission_pct,
    'from_policy', v_antes.policy,
    'to_policy', p_policy,
    'note', p_note
  ));

  return jsonb_build_object('ok', true, 'effective_from', v_desde);
end;
$function$;

-- public.admin_set_test_account(text, uuid, boolean, text)
CREATE OR REPLACE FUNCTION public.admin_set_test_account(p_kind text, p_id uuid, p_flag boolean, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor  uuid := auth.uid();
  v_before boolean;
  v_name   text;
begin
  -- Marcar una cuenta como de prueba la saca de todas las cifras: es una
  -- palanca del super admin, no del operador.
  perform public.helios_assert_super_admin('marcar cuentas de prueba');

  if p_kind = 'user' then
    select is_test, full_name into v_before, v_name
    from public.profiles where id = p_id for update;

    if not found then
      raise exception 'No existe esa persona' using errcode = '22023';
    end if;

    update public.profiles set is_test = p_flag, updated_at = now() where id = p_id;

  elsif p_kind = 'merchant' then
    select is_test, name into v_before, v_name
    from public.merchants where id = p_id for update;

    if not found then
      raise exception 'No existe ese comercio' using errcode = '22023';
    end if;

    update public.merchants set is_test = p_flag, updated_at = now() where id = p_id;

  else
    raise exception 'Tipo de cuenta desconocido: %', p_kind using errcode = '22023';
  end if;

  -- Lo ya vendido cambia de lado con la bandera: si no, marcar hoy dejaría
  -- todos los consumos de ayer contando como reales para siempre.
  perform public.helios_resync_test_flags();

  perform audit.log(v_actor, 'account.set_test', p_id, jsonb_build_object(
    'kind', p_kind,
    'name', v_name,
    'from_is_test', v_before,
    'to_is_test', p_flag,
    'note', p_note
  ));
end;
$function$;

-- public.admin_set_user_level(uuid, smallint, text)
CREATE OR REPLACE FUNCTION public.admin_set_user_level(p_user_id uuid, p_level smallint, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor  uuid := auth.uid();
  v_before smallint;
begin
  perform public.helios_assert_super_admin('ajustar el nivel');

  if p_note is null or length(trim(p_note)) < 3 then
    raise exception 'Ajustar el nivel requiere motivo' using errcode = '22023';
  end if;

  if not exists (select 1 from public.levels where level = p_level and is_active) then
    raise exception 'El nivel % no está activo', p_level using errcode = '22023';
  end if;

  select level into v_before from public.profiles where id = p_user_id for update;
  if not found then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  if v_before = p_level then
    return;
  end if;

  update public.profiles set level = p_level, updated_at = now() where id = p_user_id;

  insert into public.level_changes (user_id, from_level, to_level, reason, actor, note)
  values (p_user_id, v_before, p_level, 'manual_admin', v_actor, p_note);

  perform audit.log(v_actor, 'user.set_level', p_user_id, jsonb_build_object(
    'before', v_before, 'after', p_level, 'note', p_note
  ));
end;
$function$;

-- public.admin_set_user_status(uuid, profile_status, text)
CREATE OR REPLACE FUNCTION public.admin_set_user_status(p_user_id uuid, p_status profile_status, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_before public.profile_status;
begin
  perform public.helios_assert_super_admin('cambiar el estado de una cuenta');

  if p_note is null or length(trim(p_note)) < 3 then
    raise exception 'Cambiar el estado de una cuenta requiere motivo'
      using errcode = '22023';
  end if;

  select status into v_before from public.profiles where id = p_user_id for update;
  if not found then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  if v_before = p_status then
    return;
  end if;

  update public.profiles set status = p_status, updated_at = now() where id = p_user_id;

  perform audit.log(v_actor, 'user.set_status', p_user_id, jsonb_build_object(
    'before', v_before, 'after', p_status, 'note', p_note
  ));
end;
$function$;

-- public.admin_waive_late_fee(uuid, text)
CREATE OR REPLACE FUNCTION public.admin_waive_late_fee(p_fee_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'audit', 'pg_temp'
AS $function$
declare
  v_actor  uuid := auth.uid();
  v_fee    public.late_fees%rowtype;
  v_tx     uuid;
  v_name   text;
begin
  -- Condonar mueve el libro: es del super admin.
  perform public.helios_assert_super_admin('condonar un cargo');

  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'Condonar un cargo requiere motivo' using errcode = '22023';
  end if;

  select * into v_fee from public.late_fees where id = p_fee_id for update;

  if not found then
    raise exception 'No existe ese cargo' using errcode = 'P0002';
  end if;

  -- Un cargo ya cobrado no se condona: se devuelve, y devolver dinero es otra
  -- operación con otras consecuencias. Uno ya castigado tampoco: ya salió.
  if v_fee.status <> 'pending' then
    raise exception 'Solo se puede condonar un cargo pendiente (este está %)', v_fee.status
      using errcode = '22023';
  end if;

  select full_name into v_name from public.profiles where id = v_fee.user_id;

  update public.late_fees
  set status = 'written_off',
      waived_at = now(),
      waived_by = v_actor,
      waive_reason = trim(p_reason)
  where id = p_fee_id;

  -- El asiento contrario. El original se queda donde está.
  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'manual_adjustment',
    'late_fee_waived:' || p_fee_id::text,
    public.helios_business_date(now()),
    p_fee_id,
    format('Cargo por atraso condonado: %s', trim(p_reason))
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, ledger.get_or_create_account('platform_revenue', null), v_fee.amount_usd, 0),
    (v_tx, ledger.get_or_create_account('user_receivable', v_fee.user_id), 0, v_fee.amount_usd);

  -- Y fuera del bloque, para que el cupo no se quede cerrado por una deuda que
  -- ya no existe.
  update public.user_credit_blocks
  set charged_usd = greatest(charged_usd - v_fee.amount_usd, 0)
  where id = v_fee.credit_block_id;

  -- La deuda de alguien no baja en silencio, igual que no sube en silencio.
  perform public.notify(
    v_fee.user_id,
    'late_fee_waived',
    'Te quitamos el cargo',
    format('Quitamos el cargo por atraso de €%s de tu deuda. Ya no lo debes.',
           to_char(v_fee.amount_usd, 'FM999999990.00'))
  );

  perform audit.log(v_actor, 'late_fee.waived', p_fee_id, jsonb_build_object(
    'user_id', v_fee.user_id,
    'full_name', v_name,
    'amount_usd', v_fee.amount_usd,
    'days_late', v_fee.days_late,
    'reason', trim(p_reason)
  ));

  return jsonb_build_object(
    'ok', true,
    'amount_usd', v_fee.amount_usd,
    'user_id', v_fee.user_id
  );
end;
$function$;

