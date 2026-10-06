-- ============================================================================
-- Helios — Los textos que el panel de la clínica espera, y cuándo se confirmó
-- cada comisión (2026-10-06, a continuación de 20261006002000)
--
-- 1. El error de cupo dice «El monto supera lo disponible ($X).», sin más:
--    es la frase exacta que reconoce el panel nuevo (`create_patient_charge`,
--    y la revalidación de `staff_resend_confirmation`). El texto neutro de
--    «no disponible» ya quedó en 20261006002000: «Esta persona no puede pagar
--    en cuotas con Helios. Si tiene dudas, puede escribir a Helios[ al …].»
-- 2. `merchant_commission_items` devuelve también `confirmed_at` de la orden:
--    la comisión de la secretaria se le paga a la clínica el día siguiente al
--    día operativo de la confirmación, y el panel lo calcula con ese dato. Al
--    cambiar las columnas que devuelve hay que borrarla y crearla de nuevo
--    (la columna nueva va al final) y repetir sus permisos.
-- ============================================================================

-- create_patient_charge(p_merchant_id uuid, p_branch_id uuid, p_patient jsonb, p_amount_usd numeric, p_concept text, p_beneficiary_name text, p_idempotency_key text)
CREATE OR REPLACE FUNCTION public.create_patient_charge(p_merchant_id uuid, p_branch_id uuid, p_patient jsonb, p_amount_usd numeric, p_concept text, p_beneficiary_name text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'audit', 'pg_temp'
AS $function$
declare
  v_staff      uuid := auth.uid();
  v_key        text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_confirm    boolean := public.helios_patient_confirmation_required();
  v_canal      text := coalesce(nullif(current_setting('helios.canal', true), ''), 'panel');
  v_existing   public.charges%rowtype;
  v_role       public.merchant_role;
  v_branch     uuid;
  v_concept    text;
  v_benef      text;
  v_doc        text;
  v_in         jsonb;
  v_profile    public.profiles%rowtype;
  v_new        boolean := false;
  v_changes    jsonb := '{}'::jsonb;
  v_field      text;
  v_actual     text;
  v_limit      numeric(18,4);
  v_used       numeric(18,4);
  v_avail      numeric(18,4);
  v_min        numeric := public.helios_min_charge_usd();
  v_terms      public.merchant_terms%rowtype;
  v_b          jsonb;
  v_bdate      date;
  v_charge     public.charges%rowtype;
  v_commission numeric(18,4);
  v_over_msg   text;
begin
  if v_staff is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if v_key is null or length(v_key) > 200 then
    raise exception 'Falta la clave de idempotencia del formulario' using errcode = '22023';
  end if;

  if v_canal not in ('panel', 'whatsapp') then
    v_canal := 'panel';
  end if;

  -- 1. Idempotencia. El doble clic y la recarga devuelven el mismo
  --    financiamiento sin tocar nada. Serializado por clave: dos peticiones
  --    con la misma clave a la vez no crean dos.
  perform pg_advisory_xact_lock(hashtextextended('create_patient_charge:' || v_key, 0));

  select * into v_existing from public.charges where idempotency_key = v_key;
  if found then
    if v_existing.merchant_id = p_merchant_id and public.helios_staff_role_in(p_merchant_id) is not null then
      return public.helios_charge_for_staff(v_existing.id);
    end if;
    raise exception 'Esa clave de idempotencia ya se usó en otra orden' using errcode = '22023';
  end if;

  -- 2. Autorización. Gerente: cualquier sede de su clínica (sin sede, la
  --    principal). Secretaria: solo la suya.
  v_role := public.helios_staff_role_in(p_merchant_id);
  if v_role is null then
    raise exception 'No tienes permiso para registrar en esta clínica' using errcode = '42501';
  end if;

  perform public.helios_assert_merchant_operating(p_merchant_id);

  -- Con la confirmación del paciente, sin WhatsApp no hay a quién preguntar.
  if v_confirm and not public.helios_whatsapp_api_ready() then
    raise exception 'No podemos escribirle a este paciente por WhatsApp. Escribe a Helios'
      using errcode = '22023';
  end if;

  if v_role = 'gerente' then
    v_branch := coalesce(
      p_branch_id,
      (select b.id from public.merchant_branches b
        where b.merchant_id = p_merchant_id and b.is_active
        order by b.is_default desc, b.created_at
        limit 1));
  elsif p_branch_id is not null then
    if not exists (
      select 1 from public.merchant_users mu
      where mu.user_id = v_staff and mu.merchant_id = p_merchant_id and mu.is_active
        and mu.role = 'cajero' and mu.branch_id = p_branch_id
    ) then
      raise exception 'No tienes permiso para registrar en esa sede' using errcode = '42501';
    end if;
    v_branch := p_branch_id;
  else
    if (select count(distinct mu.branch_id) from public.merchant_users mu
         where mu.user_id = v_staff and mu.merchant_id = p_merchant_id and mu.is_active
           and mu.role = 'cajero') > 1 then
      raise exception 'Elige la sede donde se registra el pago en cuotas' using errcode = '22023';
    end if;
    select mu.branch_id into v_branch
    from public.merchant_users mu
    where mu.user_id = v_staff and mu.merchant_id = p_merchant_id and mu.is_active and mu.role = 'cajero'
    limit 1;
  end if;

  if v_branch is null or not exists (
    select 1 from public.merchant_branches b
    where b.id = v_branch and b.merchant_id = p_merchant_id and b.is_active
  ) then
    raise exception 'La sede no es de esta clínica o está inactiva' using errcode = '22023';
  end if;

  -- 3. Monto, concepto y paciente atendido.
  perform public.helios_assert_charge_amount(p_amount_usd);

  v_concept := nullif(regexp_replace(btrim(coalesce(p_concept, '')), '\s+', ' ', 'g'), '');
  if length(v_concept) > 80 then
    raise exception 'El concepto admite como mucho 80 caracteres' using errcode = '22023';
  end if;
  v_concept := coalesce(v_concept, 'Consulta');

  v_benef := nullif(regexp_replace(btrim(coalesce(p_beneficiary_name, '')), '\s+', ' ', 'g'), '');
  if length(v_benef) > 120 then
    raise exception 'El nombre del paciente atendido admite como mucho 120 caracteres' using errcode = '22023';
  end if;

  -- 4. El paciente, por cédula.
  if p_patient is null or jsonb_typeof(p_patient) <> 'object' then
    raise exception 'Faltan los datos del paciente' using errcode = '22023';
  end if;

  v_doc := public.helios_document_key(p_patient->>'document');
  perform public.helios_assert_document_looked_up(p_merchant_id, v_doc);

  select * into v_profile from public.profiles where document_key = v_doc for update;

  if not found then
    -- Nuevo: se validan todos los datos y nace activo, nivel 1. Con la
    -- confirmación, se crea ya aquí: hace falta su teléfono para preguntarle.
    v_in := public.helios_patient_input(p_patient, true);

    insert into public.profiles (
      document_number, first_name, last_name, full_name, birth_date, sex,
      phone_e164, email, state, city, address, occupation,
      reference_name, reference_phone, reference_relationship,
      registered_by, registered_merchant_id
    ) values (
      v_doc, v_in->>'first_name', v_in->>'last_name',
      (v_in->>'first_name') || ' ' || (v_in->>'last_name'),
      (v_in->>'birth_date')::date, v_in->>'sex',
      v_in->>'phone', v_in->>'email', v_in->>'state', v_in->>'city', v_in->>'address',
      v_in->>'occupation', v_in->>'reference_name', v_in->>'reference_phone',
      v_in->>'reference_relationship', v_staff, p_merchant_id
    )
    on conflict (document_key) do nothing
    returning * into v_profile;

    if v_profile.id is null then
      -- Otra sede lo registró entre la búsqueda y el INSERT: es un conocido.
      select * into v_profile from public.profiles where document_key = v_doc for update;
    else
      v_new := true;
    end if;
  end if;

  if not v_new then
    -- Conocido: con la fila bloqueada. Mora, lista negra, bloqueo, expulsión:
    -- el mismo texto neutro que la elegibilidad.
    if v_profile.status <> 'active'
       or v_profile.is_blacklisted
       or public.helios_spend_blocked(v_profile.id)
       or not public.can_take_debt(v_profile.id) then
      raise exception '%', public.helios_not_available_message() using errcode = '22023';
    end if;

    -- Una sola orden esperando respuesta por paciente (sin decir de qué clínica).
    if exists (
      select 1 from public.charges c
      where c.user_id = v_profile.id and c.status = 'pending' and c.expires_at > now()
    ) then
      raise exception 'Este paciente tiene otra solicitud esperando su respuesta. Inténtalo cuando la responda o venza'
        using errcode = '22023';
    end if;

    -- Sus datos NO se sobrescriben: lo que venga distinto queda como
    -- propuesta para Helios. El comprobante va al correo ya registrado y la
    -- pregunta, al teléfono ya registrado.
    v_in := public.helios_patient_input(p_patient, false);
    for v_field in select jsonb_object_keys(v_in) loop
      v_actual := to_jsonb(v_profile) ->> (case when v_field = 'phone' then 'phone_e164' else v_field end);
      if v_actual is distinct from v_in->>v_field then
        v_changes := v_changes || jsonb_build_object(v_field,
          jsonb_build_object('antes', v_actual, 'propuesto', v_in->>v_field));
      end if;
    end loop;

    if v_changes <> '{}'::jsonb then
      insert into public.profile_change_requests (profile_id, merchant_id, requested_by, field_changes)
      values (v_profile.id, p_merchant_id, v_staff, v_changes);
    end if;
  end if;

  -- 5. El cupo, con la fila bloqueada: la defensa contra el doble gasto (dos
  --    sedes a la vez). Cuenta lo reservado por órdenes pendientes.
  --    `helios_assign_debt` lo vuelve a mirar con el bloque de crédito bloqueado.
  select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_profile.level;
  v_used  := public.helios_credit_used_usd(v_profile.id);
  v_avail := greatest(coalesce(v_limit, 0) - v_used, 0);

  if not v_new and v_avail < v_min then
    -- Cupo agotado es también «no disponible», sin decir por qué.
    raise exception '%', public.helios_not_available_message() using errcode = '22023';
  end if;

  v_over_msg := format('El monto supera lo disponible ($%s).',
                       public.helios_money_text(trunc(v_avail, 2)));
  if round(p_amount_usd, 2) > v_avail then
    raise exception '%', v_over_msg using errcode = '22023';
  end if;

  -- 6. Condiciones, desglose y comisión.
  v_bdate := public.helios_business_date(now());

  select * into v_terms from public.helios_terms_at(p_merchant_id, v_bdate);
  if v_terms.id is null then
    raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
      using errcode = '22023';
  end if;

  v_b := public.helios_charge_breakdown(p_amount_usd, coalesce(v_terms.commission_pct, 0));
  v_commission := public.helios_staff_commission_for(p_merchant_id, v_bdate);

  -- 7. La orden: pendiente (espera el «Sí») o, con el interruptor en 0,
  --    directamente confirmada.
  insert into public.charges (
    merchant_id, branch_id, requested_by, idempotency_key, user_id, status,
    business_date, confirmed_at, expires_at, channel,
    amount_usd, base_usd, vat_pct, vat_usd,
    consumer_fee_pct, consumer_fee_usd, consumer_fee_vat_usd,
    merchant_fee_pct, merchant_fee_usd, merchant_fee_vat_usd, merchant_net_usd,
    concept, beneficiary_name, terms_version_id,
    staff_commission_usd, commission_staff_id
  ) values (
    p_merchant_id, v_branch, v_staff, v_key, v_profile.id,
    case when v_confirm then 'pending' else 'confirmed' end::public.charge_status,
    v_bdate,
    case when v_confirm then null else now() end,
    case when v_confirm then now() + make_interval(mins => public.helios_patient_confirmation_minutes())
         else now() end,
    v_canal,
    (v_b->>'consumer_total_usd')::numeric, (v_b->>'base_usd')::numeric,
    (v_b->>'vat_pct')::numeric, (v_b->>'vat_usd')::numeric,
    (v_b->>'consumer_fee_pct')::numeric, (v_b->>'consumer_fee_usd')::numeric,
    (v_b->>'consumer_fee_vat_usd')::numeric,
    (v_b->>'merchant_fee_pct')::numeric, (v_b->>'merchant_fee_usd')::numeric,
    (v_b->>'merchant_fee_vat_usd')::numeric, (v_b->>'merchant_net_usd')::numeric,
    v_concept, v_benef,
    (select t.id from public.terms_versions t where t.is_current order by t.published_at desc limit 1),
    nullif(v_commission, 0), case when v_commission > 0 then v_staff end
  )
  returning * into v_charge;

  -- Una sola línea libre (D-H4: sin catálogo).
  insert into public.charge_items (charge_id, product_id, name, unit_price_usd, quantity, position)
  values (v_charge.id, null, v_concept, v_charge.base_usd, 1, 0);

  if v_confirm then
    -- 8. La pregunta al paciente, por WhatsApp.
    perform public.helios_enqueue_confirmation(v_charge.id);
  else
    -- 8-12. Asiento, adelanto, cuotas, comisión, comprobante y bienvenida.
    perform public.helios_finalize_charge(v_charge.id, 'whatsapp_manual', v_over_msg);
  end if;

  -- 13. Bitácora.
  perform audit.log(v_staff, 'charge.created', v_charge.id, jsonb_build_object(
    'merchant_id', p_merchant_id,
    'branch_id', v_branch,
    'user_id', v_profile.id,
    'new_patient', v_new,
    'base_usd', v_charge.base_usd,
    'amount_usd', v_charge.amount_usd,
    'concept', v_concept,
    'beneficiary_name', v_benef,
    'staff_commission_usd', v_charge.staff_commission_usd,
    'change_request', v_changes <> '{}'::jsonb,
    'business_date', v_bdate,
    'status', case when v_confirm then 'pending' else 'confirmed' end,
    'expires_at', case when v_confirm then v_charge.expires_at end,
    'canal', v_canal
  ));

  return public.helios_charge_for_staff(v_charge.id);
end;
$function$;

-- staff_resend_confirmation(p_charge_id uuid)
CREATE OR REPLACE FUNCTION public.staff_resend_confirmation(p_charge_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_me     uuid := auth.uid();
  v_c      public.charges%rowtype;
  v_p      public.profiles%rowtype;
  v_first  uuid;
  v_n      integer;
  v_max    integer := public.helios_confirmation_resends_per_day();
  v_limit  numeric(18,4);
  v_avail  numeric(18,4);
  v_min    numeric := public.helios_min_charge_usd();
  v_terms  public.merchant_terms%rowtype;
  v_b      jsonb;
  v_bdate  date;
  v_comm   numeric(18,4);
  v_base   numeric(18,4);
  v_msg    uuid;
  v_reopen boolean := false;
begin
  if v_me is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_c from public.charges where id = p_charge_id for update;

  -- La misma regla que el detalle: el gerente, los de su clínica; la
  -- secretaria, los que registró. El mismo error exista o no.
  if not found or not exists (
    select 1 from public.merchant_users mu
    where mu.user_id = v_me and mu.merchant_id = v_c.merchant_id and mu.is_active
      and (mu.role = 'gerente' or (mu.role = 'cajero' and v_c.requested_by = v_me))
  ) then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  if v_c.status = 'pending' and v_c.expires_at <= now() then
    update public.charges set status = 'expired' where id = v_c.id returning * into v_c;
  end if;

  if v_c.status not in ('pending', 'expired') then
    raise exception 'Esta orden ya no se puede reenviar' using errcode = '22023';
  end if;

  if not public.helios_whatsapp_api_ready() then
    raise exception 'No podemos escribirle a este paciente por WhatsApp. Escribe a Helios'
      using errcode = '22023';
  end if;

  -- Reenvíos de hoy: las preguntas de hoy menos la primera de todas.
  select o.id into v_first
  from public.outbound_messages o
  where o.charge_id = p_charge_id and o.template_key = 'confirmar_financiamiento'
  order by o.created_at, o.id limit 1;

  select count(*) into v_n
  from public.outbound_messages o
  where o.charge_id = p_charge_id and o.template_key = 'confirmar_financiamiento'
    and o.created_at >= public.helios_business_day_start()
    and o.id is distinct from v_first;

  if v_n >= v_max then
    raise exception 'Ya reenviaste esta solicitud % veces hoy. Inténtalo mañana', v_max
      using errcode = '22023';
  end if;

  if v_c.status = 'expired' then
    v_reopen := true;

    perform public.helios_assert_merchant_operating(v_c.merchant_id);

    select * into v_p from public.profiles where id = v_c.user_id for update;
    if v_p.status <> 'active'
       or v_p.is_blacklisted
       or public.helios_spend_blocked(v_p.id)
       or not public.can_take_debt(v_p.id) then
      raise exception '%', public.helios_not_available_message() using errcode = '22023';
    end if;

    if exists (
      select 1 from public.charges c
      where c.user_id = v_p.id and c.id <> v_c.id and c.status = 'pending' and c.expires_at > now()
    ) then
      raise exception 'Este paciente tiene otra solicitud esperando su respuesta. Inténtalo cuando la responda o venza'
        using errcode = '22023';
    end if;

    v_base := coalesce(v_c.base_usd, v_c.amount_usd);
    select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_p.level;
    v_avail := greatest(coalesce(v_limit, 0) - public.helios_credit_used_usd(v_p.id), 0);
    if v_avail < v_min then
      raise exception '%', public.helios_not_available_message() using errcode = '22023';
    end if;
    if round(v_base, 2) > v_avail then
      raise exception 'El monto supera lo disponible ($%).',
        public.helios_money_text(trunc(v_avail, 2)) using errcode = '22023';
    end if;

    v_bdate := public.helios_business_date(now());
    select * into v_terms from public.helios_terms_at(v_c.merchant_id, v_bdate);
    if v_terms.id is null then
      raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
        using errcode = '22023';
    end if;

    v_b    := public.helios_charge_breakdown(v_base, coalesce(v_terms.commission_pct, 0));
    v_comm := public.helios_staff_commission_for(v_c.merchant_id, v_bdate);

    update public.charges
       set status = 'pending',
           business_date = v_bdate,
           expires_at = now() + make_interval(mins => public.helios_patient_confirmation_minutes()),
           amount_usd = (v_b->>'consumer_total_usd')::numeric,
           base_usd = (v_b->>'base_usd')::numeric,
           vat_pct = (v_b->>'vat_pct')::numeric,
           vat_usd = (v_b->>'vat_usd')::numeric,
           consumer_fee_pct = (v_b->>'consumer_fee_pct')::numeric,
           consumer_fee_usd = (v_b->>'consumer_fee_usd')::numeric,
           consumer_fee_vat_usd = (v_b->>'consumer_fee_vat_usd')::numeric,
           merchant_fee_pct = (v_b->>'merchant_fee_pct')::numeric,
           merchant_fee_usd = (v_b->>'merchant_fee_usd')::numeric,
           merchant_fee_vat_usd = (v_b->>'merchant_fee_vat_usd')::numeric,
           merchant_net_usd = (v_b->>'merchant_net_usd')::numeric,
           terms_version_id = (select t.id from public.terms_versions t
                                where t.is_current order by t.published_at desc limit 1),
           staff_commission_usd = nullif(v_comm, 0),
           commission_staff_id = case when v_comm > 0 then v_c.requested_by end
     where id = v_c.id;
  end if;

  v_msg := public.helios_enqueue_confirmation(v_c.id);

  perform audit.log(v_me, 'charge.confirmation_resent', p_charge_id,
    jsonb_build_object('message_id', v_msg, 'merchant_id', v_c.merchant_id, 'reopened', v_reopen));

  return public.helios_charge_for_staff(p_charge_id);
end;
$function$;

drop function public.merchant_commission_items(date, date, uuid);

-- merchant_commission_items(p_from date, p_to date, p_staff_user_id uuid)
CREATE FUNCTION public.merchant_commission_items(p_from date, p_to date, p_staff_user_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(charge_id uuid, order_number bigint, created_at timestamp with time zone, amount_usd numeric, status text, payout_id uuid, paid_on date, staff_user_id uuid, staff_name text, business_date date, confirmed_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me         uuid := auth.uid();
  v_gerente_de uuid := public.my_merchant_id_as_gerente();
begin
  if v_me is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if not exists (select 1 from public.merchant_users mu
                 where mu.user_id = v_me and mu.is_active and mu.role in ('gerente', 'cajero')) then
    raise exception 'Solo el personal de una clínica' using errcode = '42501';
  end if;

  return query
  select sc.charge_id,
         c.order_number,
         sc.created_at,
         sc.amount_usd,
         sc.status,
         po.id,
         case when sc.status = 'pagada' then po.paid_on end,
         sc.staff_user_id,
         public.helios_staff_name(sc.staff_user_id),
         c.business_date,
         c.confirmed_at
  from public.staff_commissions sc
  join public.charges c on c.id = sc.charge_id
  left join lateral (
    select mp.id, coalesce(mp.paid_on, mp.business_date) as paid_on
    from public.merchant_payout_items it
    join public.merchant_payouts mp on mp.id = it.payout_id
    where sc.settlement_id is not null and it.settlement_id = sc.settlement_id
    order by mp.created_at desc
    limit 1
  ) po on true
  where sc.merchant_id in (select public.my_merchant_ids())
    and (sc.merchant_id = v_gerente_de or sc.staff_user_id = v_me)
    and (p_staff_user_id is null or sc.staff_user_id = p_staff_user_id)
    and c.business_date between p_from and p_to
  order by sc.created_at desc;
end;
$function$;

revoke all on function public.merchant_commission_items(date, date, uuid) from public, anon;
grant execute on function public.merchant_commission_items(date, date, uuid) to authenticated;
