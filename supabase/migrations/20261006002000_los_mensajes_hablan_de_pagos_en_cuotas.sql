-- ============================================================================
-- Helios — Los mensajes hablan de pagos en cuotas
-- (reglas y vocabulario publicados por Javier el 2026-10-06)
--
-- Hacia fuera (pacientes y personal de las clínicas: WhatsApp, correo, bot y
-- los errores de las RPC que enseñan el panel o el bot) ya no se dice
-- «préstamo», «financiamiento», «financiar» ni «crédito». La tabla:
--
--   financiamiento (genérico)        → pago en cuotas
--   financiamiento #1042 (concreto)  → orden #1042 / tu pago en cuotas #1042
--   No podemos financiar a esta…     → Esta persona no puede pagar en cuotas con Helios
--   disponible para financiar        → disponible para pagar en cuotas
--   cargo por servicio / Servicio
--   Helios / fee                     → comisión de servicio (y «IVA de la comisión»)
--
-- Solo cambian TEXTOS. Los identificadores se quedan como están: las claves de
-- plantilla (`confirmar_financiamiento`, `comprobante_financiamiento`), las
-- variables, las columnas, los nombres de funciones y las claves JSON (la de
-- `bot_paciente_resumen` sigue siendo `financiamientos`). Lo interno (las
-- `admin_*`, el memo del libro) tampoco se toca.
--
-- 1. Las funciones con texto visible, redefinidas desde su última definición
--    con la misma firma, `security definer`, `search_path` y lógica (los
--    permisos se conservan con `create or replace`). El comprobante gana las
--    variables `comision_servicio`, `iva_pct`, `iva_comision` y `total`: al
--    paciente sí se le enseña lo que paga, desglosado.
-- 2. Las plantillas al paciente con el vocabulario nuevo. Ningún porcentaje
--    va escrito a mano: salen de `consumer_fee_pct` y `vat_pct`.
-- 3. La plantilla de Meta aprobada (`helios_confirmar_financiamiento`, v1)
--    lleva «20 %» y «financiamiento» escritos, y la v2 también dice
--    «financiamiento». Se deja de usar: con `wa_template_name` null, dentro de
--    la ventana de 24 h la pregunta sale igual como texto libre con sus
--    botones Sí / No, y fuera de la ventana `helios_whatsapp_payload` devuelve
--    null y `helios_dispatch_whatsapp_batch` la pasa a la cola manual
--    («fuera de la ventana de 24 h y sin plantilla aprobada»), como dice
--    docs/00 §15.2. Cuando Meta apruebe la v3 (`helios_confirmar_pago_en_cuotas`)
--    se activa con su `update`.
-- 4. Las condiciones del comprobante, v2 (`terms_versions`): las reglas del
--    2026-10-06, con las cifras leídas de los parámetros, y quién opera
--    Helios (Quarto Latam, C.A.).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las funciones con texto visible
-- ---------------------------------------------------------------------------

-- helios_not_available_message()
CREATE OR REPLACE FUNCTION public.helios_not_available_message()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select 'Esta persona no puede pagar en cuotas con Helios. '
         || case when x.wa is null then 'Si tiene dudas, puede escribir a Helios.'
                 else 'Si tiene dudas, puede escribir a Helios al '
                      || coalesce(public.helios_format_ve_phone(x.wa), x.wa) || '.' end
  from (select (select pc.whatsapp_number from public.platform_contact pc where pc.id) as wa) x;
$function$;

-- helios_notify_staff_of_charge(p_charge_id uuid, p_kind text)
CREATE OR REPLACE FUNCTION public.helios_notify_staff_of_charge(p_charge_id uuid, p_kind text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_c     public.charges%rowtype;
  v_phone text;
  v_quien text;
  v_texto text;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found or v_c.channel <> 'whatsapp' then
    return;
  end if;

  select n.phone_e164 into v_phone from public.staff_whatsapp_numbers n
  where n.user_id = v_c.requested_by and n.merchant_id = v_c.merchant_id and n.revoked_at is null;
  if v_phone is null or not public.helios_whatsapp_window_open(v_phone) then
    return;
  end if;

  select concat_ws(' ', nullif(btrim(p.first_name), ''),
                   case when nullif(btrim(p.last_name), '') is not null then left(btrim(p.last_name), 1) || '.' end)
    into v_quien
  from public.profiles p where p.id = v_c.user_id;
  v_quien := coalesce(nullif(v_quien, ''), 'El paciente');

  v_texto := case p_kind
    when 'aceptada' then format('✅ %s aceptó. Orden #%s confirmada: consulta de $%s.',
                                v_quien, v_c.order_number, public.helios_money_text(coalesce(v_c.base_usd, v_c.amount_usd)))
    when 'rechazada' then case v_c.decline_reason
      when 'no_disponible' then format('La orden #%s de %s no se pudo confirmar. %s',
                                       v_c.order_number, v_quien, public.helios_not_available_message())
      else format('❌ %s no aceptó la orden #%s. No se creó ninguna deuda.', v_quien, v_c.order_number) end
    when 'vencida' then format('⌛ La orden #%s de %s venció sin respuesta. Escribe «reenviar %s» para enviársela otra vez.',
                               v_c.order_number, v_quien, v_c.order_number)
  end;
  if v_texto is null then
    return;
  end if;

  perform public.helios_whatsapp_text(v_phone, v_texto, v_c.requested_by);
exception when others then
  -- Un aviso que no sale no puede tumbar la confirmación del paciente.
  null;
end;
$function$;

-- bot_charge_by_order(p_phone text, p_order_number bigint)
CREATE OR REPLACE FUNCTION public.bot_charge_by_order(p_phone text, p_order_number bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_n  public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_id uuid;
begin
  select c.id into v_id from public.charges c
  where c.order_number = p_order_number and c.merchant_id = v_n.merchant_id;
  if v_id is null then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;
  perform public.helios_bot_as(v_n.user_id);
  return public.helios_charge_for_staff(v_id);
end;
$function$;

-- helios_charge_for_staff(p_charge_id uuid)
CREATE OR REPLACE FUNCTION public.helios_charge_for_staff(p_charge_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me    uuid := auth.uid();
  v_c     public.charges%rowtype;
  v_p     public.profiles%rowtype;
  v_role  public.merchant_role;
  v_name  text;
  v_open  boolean;
begin
  select * into v_c from public.charges where id = p_charge_id;

  -- El mismo error exista o no: probar ids a ciegas no dice cuáles son de otra
  -- clínica. El gerente ve todos los de su clínica; la secretaria, los suyos.
  if not found or not (
    public.is_platform_admin()
    or exists (
      select 1 from public.merchant_users mu
      where mu.user_id = v_me and mu.merchant_id = v_c.merchant_id and mu.is_active
        and (mu.role = 'gerente' or v_c.requested_by = v_me)
    )
  ) then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  select * into v_p from public.profiles where id = v_c.user_id;

  select mu.role into v_role
  from public.merchant_users mu
  where mu.user_id = v_c.requested_by and mu.merchant_id = v_c.merchant_id
  order by mu.is_active desc, (mu.role = 'gerente') desc, mu.created_at desc
  limit 1;

  v_name := public.helios_staff_name(v_c.requested_by);
  v_open := v_c.status in ('pending', 'declined', 'expired');

  return jsonb_build_object(
    'id', v_c.id,
    'order_number', v_c.order_number,
    'status', v_c.status::text,
    'channel', v_c.channel,
    'created_at', v_c.created_at,
    'confirmed_at', v_c.confirmed_at,
    'expires_at', case when v_c.status in ('pending', 'expired') then v_c.expires_at end,
    'business_date', v_c.business_date,
    'merchant_id', v_c.merchant_id,
    'merchant_name', (select m.name from public.merchants m where m.id = v_c.merchant_id),
    'branch_id', v_c.branch_id,
    'branch_name', (select b.name from public.merchant_branches b where b.id = v_c.branch_id),
    -- La base: lo que se le paga a la clínica. Nunca un total con el fee.
    'merchant_sale_usd', public.helios_merchant_sale_usd(v_c.base_usd, v_c.vat_usd, v_c.amount_usd),
    'concept', v_c.concept,
    'beneficiary_name', v_c.beneficiary_name,
    'patient', jsonb_build_object(
      'nombre', coalesce(nullif(btrim(v_p.full_name), ''),
                         nullif(btrim(concat_ws(' ', v_p.first_name, v_p.last_name)), '')),
      'documento_enmascarado', public.helios_mask_document(v_p.document_number),
      'email_enmascarado', public.helios_mask_email(v_p.email)
    ),
    -- Las cuotas llevan el fee dentro: es donde se permite verlo.
    'installments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sequence', (x->>'sequence')::integer,
               'due_date', (x->>'due_date')::date,
               'amount_usd', (x->>'amount_usd')::numeric)
             order by (x->>'sequence')::integer)
      from jsonb_array_elements(public.helios_charge_planned_installments(v_c.id)) x
    ), '[]'::jsonb),
    'breakdown', jsonb_build_object(
      'base_usd', v_c.base_usd,
      'consumer_fee_pct', v_c.consumer_fee_pct,
      'consumer_fee_usd', v_c.consumer_fee_usd,
      'consumer_fee_vat_usd', v_c.consumer_fee_vat_usd
    ),
    'receipt', case
      when v_open then jsonb_build_object(
        'status', 'sin_enviar', 'sent_at', null, 'last_event', null,
        'email_enmascarado', public.helios_mask_email(v_p.email))
      else public.helios_charge_receipt(v_c.id)
    end,
    'confirmation', public.helios_charge_confirmation(v_c.id),
    'decline_reason', v_c.decline_reason,
    'decline_message', case v_c.decline_reason
      when 'paciente' then 'El paciente rechazó el pago en cuotas'
      when 'no_disponible' then public.helios_not_available_message()
    end,
    'registered_by', case
      when v_name is null then null
      when v_role is null then v_name
      else v_name || ' (' || case v_role when 'gerente' then 'Administrador' else 'Secretaria' end || ')'
    end,
    'staff_commission_usd', v_c.staff_commission_usd
  );
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
      raise exception 'El monto supera lo disponible para pagar en cuotas ($%)',
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

-- staff_resend_receipt(p_charge_id uuid)
CREATE OR REPLACE FUNCTION public.staff_resend_receipt(p_charge_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_me    uuid := auth.uid();
  v_c     public.charges%rowtype;
  v_n     integer;
  v_max   integer := public.helios_receipt_resends_per_day();
  v_msg   uuid;
  v_r     jsonb;
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

  if v_c.status <> 'confirmed' then
    raise exception 'Esta orden ya no está vigente' using errcode = '22023';
  end if;

  -- Reenvíos de hoy: los comprobantes de hoy menos el original.
  select count(*) into v_n
  from public.outbound_messages o
  where o.charge_id = p_charge_id
    and o.template_key = 'comprobante_financiamiento'
    and o.created_at >= public.helios_business_day_start()
    and o.id <> (select o2.id from public.outbound_messages o2
                 where o2.charge_id = p_charge_id and o2.template_key = 'comprobante_financiamiento'
                 order by o2.created_at, o2.id limit 1);

  if v_n >= v_max then
    raise exception 'Ya reenviaste este comprobante % veces hoy. Inténtalo mañana', v_max
      using errcode = '22023';
  end if;

  v_msg := public.helios_enqueue_charge_receipt(p_charge_id);
  v_r   := public.helios_charge_receipt(p_charge_id);

  perform audit.log(v_me, 'charge.receipt_resent', p_charge_id,
    jsonb_build_object('message_id', v_msg, 'merchant_id', v_c.merchant_id));

  return jsonb_build_object(
    'ok', true,
    'email_enmascarado', v_r->>'email_enmascarado',
    'status', v_r->>'status'
  );
end;
$function$;

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

  v_over_msg := format('El monto supera lo disponible para pagar en cuotas ($%s)',
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

-- merchant_sales_export(p_from date, p_to date)
CREATE OR REPLACE FUNCTION public.merchant_sales_export(p_from date, p_to date)
 RETURNS TABLE(order_number bigint, charge_id uuid, business_date date, confirmed_at timestamp with time zone, branch_name text, cashier text, status text, void_reason text, group_name text, payer_count integer, item_count integer, base_usd numeric, vat_pct numeric, vat_usd numeric, sale_usd numeric, consumer_fee_pct numeric, consumer_fee_usd numeric, consumer_fee_vat_usd numeric, charged_to_customer_usd numeric, merchant_fee_pct numeric, merchant_fee_usd numeric, merchant_fee_vat_usd numeric, net_to_merchant_usd numeric, fx_rate numeric, sale_ves numeric, charged_to_customer_ves numeric, net_to_merchant_ves numeric, cuota_1_due date, cuota_1_run date, cuota_2_due date, cuota_2_run date, settled_usd numeric, paid_usd numeric, is_test boolean, concept text, beneficiary_name text, staff_commission_usd numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_max      integer := 20000;
  v_count    bigint;
begin
  if v_merchant is null then
    raise exception 'Solo el administrador de la clínica puede descargar sus pagos en cuotas'
      using errcode = '42501';
  end if;

  select count(*) into v_count
  from public.charges c
  where c.merchant_id = v_merchant
    and c.business_date between p_from and p_to
    and c.status in ('confirmed', 'reverted');

  perform public.helios_assert_sales_export(p_from, p_to, v_count, v_max);

  return query
  with ventas as (
    select c.*,
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale,
           public.current_fx_rate('BCV', c.business_date) as rate
    from public.charges c
    where c.merchant_id = v_merchant
      and c.business_date between p_from and p_to
      and c.status in ('confirmed', 'reverted')
  ),
  cuotas as (
    select i.charge_id as cid,
           i.sequence  as seq,
           min(i.due_date) as due,
           public.helios_settlement_run_for(min(i.due_date)) as run
    from public.installments i
    join ventas v on v.id = i.charge_id
    group by i.charge_id, i.sequence
  ),
  lineas as (
    select ci.charge_id as cid, count(*)::integer as n
    from public.charge_items ci
    join ventas v on v.id = ci.charge_id
    group by ci.charge_id
  ),
  liquidado as (
    -- Lo liquidado por la VENTA: la comisión del personal va en su columna.
    select s.charge_id as cid,
           sum(s.amount_usd) as programado,
           sum(coalesce(s.paid_usd, 0)) as pagado
    from public.settlements s
    join ventas v on v.id = s.charge_id
    where s.reason <> 'staff_commission'
    group by s.charge_id
  )
  select
    v.order_number,
    v.id,
    v.business_date,
    v.confirmed_at,
    b.name,
    public.helios_staff_name(v.requested_by),
    v.status::text,
    v.void_reason,
    v.group_name,
    1,
    coalesce(l.n, 0),
    round(coalesce(v.base_usd, 0), 2),
    coalesce(v.vat_pct, 0),
    round(coalesce(v.vat_usd, 0), 2),
    round(v.sale, 2),
    coalesce(v.consumer_fee_pct, 0),
    round(coalesce(v.consumer_fee_usd, 0), 2),
    round(coalesce(v.consumer_fee_vat_usd, 0), 2),
    round(v.amount_usd, 2),
    coalesce(v.merchant_fee_pct, 0),
    round(coalesce(v.merchant_fee_usd, 0), 2),
    round(coalesce(v.merchant_fee_vat_usd, 0), 2),
    round(coalesce(v.merchant_net_usd, v.sale), 2),
    v.rate,
    round(v.sale * v.rate, 2),
    round(v.amount_usd * v.rate, 2),
    round(coalesce(v.merchant_net_usd, v.sale) * v.rate, 2),
    c1.due, c1.run,
    c2.due, c2.run,
    round(coalesce(s.programado, 0), 2),
    round(coalesce(s.pagado, 0), 2),
    v.is_test,
    v.concept,
    v.beneficiary_name,
    v.staff_commission_usd
  from ventas v
  left join public.merchant_branches b on b.id = v.branch_id
  left join lineas l on l.cid = v.id
  left join liquidado s on s.cid = v.id
  left join cuotas c1 on c1.cid = v.id and c1.seq = 1
  left join cuotas c2 on c2.cid = v.id and c2.seq = 2
  order by v.business_date, v.confirmed_at, v.order_number;
end;
$function$;

-- merchant_sales_export_items(p_from date, p_to date)
CREATE OR REPLACE FUNCTION public.merchant_sales_export_items(p_from date, p_to date)
 RETURNS TABLE(order_number bigint, charge_id uuid, business_date date, confirmed_at timestamp with time zone, branch_name text, status text, line_no smallint, product_id uuid, product_name text, quantity integer, unit_price_usd numeric, line_total_usd numeric, fx_rate numeric, line_total_ves numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_max      integer := 50000;
  v_count    bigint;
begin
  if v_merchant is null then
    raise exception 'Solo el administrador de la clínica puede descargar sus pagos en cuotas'
      using errcode = '42501';
  end if;

  select count(*) into v_count
  from public.charge_items ci
  join public.charges c on c.id = ci.charge_id
  where c.merchant_id = v_merchant
    and c.business_date between p_from and p_to
    and c.status in ('confirmed', 'reverted');

  perform public.helios_assert_sales_export(p_from, p_to, v_count, v_max);

  return query
  select
    c.order_number,
    c.id,
    c.business_date,
    c.confirmed_at,
    b.name,
    c.status::text,
    ci.position,
    ci.product_id,
    ci.name,
    ci.quantity,
    round(ci.unit_price_usd, 2),
    round(ci.line_total_usd, 2),
    r.rate,
    round(ci.line_total_usd * r.rate, 2)
  from public.charge_items ci
  join public.charges c on c.id = ci.charge_id
  left join public.merchant_branches b on b.id = c.branch_id
  left join lateral (
    select public.current_fx_rate('BCV', c.business_date) as rate
  ) r on true
  where c.merchant_id = v_merchant
    and c.business_date between p_from and p_to
    and c.status in ('confirmed', 'reverted')
  order by c.business_date, c.confirmed_at, c.order_number, ci.position;
end;
$function$;

-- helios_finalize_charge(p_charge_id uuid, p_welcome_channel text, p_over_limit_message text)
CREATE OR REPLACE FUNCTION public.helios_finalize_charge(p_charge_id uuid, p_welcome_channel text, p_over_limit_message text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'pg_temp'
AS $function$
declare
  v_charge   public.charges%rowtype;
  v_terms    public.merchant_terms%rowtype;
  v_due_1    date;
  v_due_2    date;
  v_financed numeric(18,4);
  v_revenue  numeric(18,4);
  v_share    numeric(18,4);
  v_tx       uuid;
  v_cuotas   text;
  v_merchant text;
begin
  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Orden no encontrada' using errcode = 'P0002';
  end if;

  if v_charge.status = 'pending' then
    update public.charges
       set status = 'confirmed', confirmed_at = now()
     where id = p_charge_id
    returning * into v_charge;
  end if;

  if v_charge.status <> 'confirmed' or v_charge.user_id is null then
    raise exception 'La orden no se puede confirmar' using errcode = '22023';
  end if;

  select * into v_terms from public.helios_terms_at(v_charge.merchant_id, v_charge.business_date);
  if v_terms.id is null then
    raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
      using errcode = '22023';
  end if;

  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_charge.business_date);

  -- El asiento de cuatro patas, saltándose las que valen cero.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);
  v_revenue  := coalesce(v_charge.consumer_fee_usd, 0) + coalesce(v_charge.merchant_fee_usd, 0);
  v_share    := coalesce(v_charge.merchant_net_usd, v_charge.amount_usd - v_revenue);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', 'charge:' || v_charge.idempotency_key, v_charge.business_date, v_charge.id,
          'Financiamiento de consulta')
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit)
  select v_tx, x.acct, x.debit, x.credit
  from (values
    (ledger.get_or_create_account('user_receivable', v_charge.user_id), v_charge.amount_usd, 0::numeric),
    (ledger.get_or_create_account('merchant_payable', v_charge.merchant_id), 0::numeric, v_share),
    (ledger.get_or_create_account('platform_revenue', null), 0::numeric, v_revenue),
    (ledger.get_or_create_account('vat_payable', null), 0::numeric,
     v_charge.amount_usd - v_share - v_revenue)
  ) as x(acct, debit, credit)
  where x.debit <> 0 or x.credit <> 0;

  -- El adelanto a la clínica (no hace nada con upfront_pct = 0).
  perform ledger.record_advance_settlement(
    v_charge.merchant_id, v_charge.id, round(v_share * v_terms.upfront_pct / 100, 4), v_charge.business_date);

  -- La deuda: las 2 cuotas a +7 y +14 días y el bloque de crédito.
  perform public.helios_assign_debt(
    v_charge.user_id, v_charge.id, v_financed, v_charge.amount_usd, v_due_1, v_due_2,
    coalesce(p_over_limit_message, public.helios_not_available_message()));

  -- La comisión de quien lo registró.
  perform public.helios_accrue_staff_commission(v_charge.id);

  -- Los mensajes: el comprobante (al correo REGISTRADO) y la bienvenida.
  perform public.helios_enqueue_charge_receipt(v_charge.id);

  select m.name into v_merchant from public.merchants m where m.id = v_charge.merchant_id;
  select string_agg(format('* $%s — %s', public.helios_money_text(i.amount_usd),
                           to_char(i.due_date, 'DD/MM/YYYY')),
                    E'\n' order by i.sequence)
    into v_cuotas
  from public.installments i where i.charge_id = v_charge.id;

  perform public.helios_enqueue_message(
    'bienvenida', v_charge.user_id, v_charge.id, p_welcome_channel,
    jsonb_build_object('clinica', v_merchant, 'orden', v_charge.order_number::text, 'cuotas', v_cuotas),
    null, 'bienvenida:' || v_charge.id::text);
end;
$function$;

-- helios_enqueue_charge_receipt(p_charge_id uuid)
CREATE OR REPLACE FUNCTION public.helios_enqueue_charge_receipt(p_charge_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_c        public.charges%rowtype;
  v_p        public.profiles%rowtype;
  v_m        public.merchants%rowtype;
  v_contact  public.platform_contact%rowtype;
  v_sede     text;
  v_staff    text;
  v_concepto text;
  v_cuotas   text;
  v_cuotas_h text;
  v_n        integer;
  v_first    public.installments%rowtype;
  v_orden    text;
  v_wa       text;
  v_wa_txt   text;
  v_link     text;
  v_td       constant text := 'padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#1f2937;';
  v_aviso    text;
  v_aviso_h  text;
  v_noreco   text;
  v_noreco_h text;
  v_iva      numeric;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found then
    raise exception 'Orden no encontrada' using errcode = 'P0002';
  end if;

  if v_c.status <> 'confirmed' or v_c.user_id is null then
    raise exception 'La orden no está confirmada' using errcode = '22023';
  end if;

  select * into v_p       from public.profiles  where id = v_c.user_id;
  select * into v_m       from public.merchants where id = v_c.merchant_id;
  select * into v_contact from public.platform_contact where id;
  select name into v_sede from public.merchant_branches where id = v_c.branch_id;

  -- Solo el nombre de pila de quien registró (docs/00 §7.3).
  v_staff := public.helios_staff_name(v_c.requested_by);
  v_staff := case
    when v_staff is null or position('@' in v_staff) > 0 then 'el personal de la clínica'
    else split_part(btrim(v_staff), ' ', 1)
  end;

  select string_agg(ci.name, ', ' order by ci.position) into v_concepto
  from public.charge_items ci where ci.charge_id = p_charge_id;

  select count(*)::integer,
         string_agg(format('• Cuota %s: $%s, vence el %s %s', i.sequence,
                           public.helios_money_text(i.amount_usd),
                           public.helios_weekday_es(i.due_date), to_char(i.due_date, 'DD/MM/YYYY')),
                    E'\n' order by i.sequence),
         string_agg(format('<tr><td style="%s">Cuota %s</td><td style="%s">%s %s</td>'
                           '<td align="right" style="%sfont-weight:bold;">$%s</td></tr>',
                           v_td, i.sequence, v_td, public.helios_weekday_es(i.due_date),
                           to_char(i.due_date, 'DD/MM/YYYY'), v_td,
                           public.helios_money_text(i.amount_usd)),
                    '' order by i.sequence)
    into v_n, v_cuotas, v_cuotas_h
  from public.installments i where i.charge_id = p_charge_id;

  if coalesce(v_n, 0) = 0 then
    raise exception 'La orden no tiene cuotas' using errcode = '22023';
  end if;

  select * into v_first from public.installments
  where charge_id = p_charge_id order by sequence limit 1;

  v_orden := coalesce(v_c.order_number::text, left(v_c.id::text, 8));
  v_wa    := v_contact.whatsapp_number;

  if v_wa is not null then
    v_wa_txt := coalesce(public.helios_format_ve_phone(v_wa), v_wa);
    v_link := 'https://wa.me/' || regexp_replace(v_wa, '\D', '', 'g') || '?text='
              || public.helios_url_encode(format('Hola, quiero avisar un pago de la orden #%s', v_orden));
    v_aviso := format('Cuando pagues, envíanos el comprobante por WhatsApp al %s: %s', v_wa_txt, v_link);
    v_aviso_h := format(
      '<p style="margin:0 0 10px 0;">Cuando pagues, env&iacute;anos el comprobante por WhatsApp al %s, indicando la orden #%s.</p>'
      '<table role="presentation" border="0" cellpadding="0" cellspacing="0"><tr>'
      '<td bgcolor="#1A56DB" style="background-color:#1A56DB;border-radius:4px;">'
      '<a href="%s" target="_blank" style="display:inline-block;padding:11px 20px;font-family:Arial,Helvetica,sans-serif;font-size:15px;font-weight:bold;color:#ffffff;text-decoration:none;">Avisar mi pago por WhatsApp</a>'
      '</td></tr></table>',
      public.helios_html_escape(v_wa_txt), public.helios_html_escape(v_orden),
      public.helios_html_escape(v_link));
    v_noreco := format('Si no reconoces este pago en cuotas, escríbenos enseguida por WhatsApp al %s%s.',
                       v_wa_txt, coalesce(' o a ' || v_contact.support_email, ''));
  else
    v_link := '';
    v_aviso := 'Helios te escribirá por WhatsApp con las instrucciones para avisar tu pago.';
    v_aviso_h := '<p style="margin:0;">Helios te escribir&aacute; por WhatsApp con las instrucciones para avisar tu pago.</p>';
    v_noreco := case
      when v_contact.support_email is not null then
        format('Si no reconoces este pago en cuotas, escríbenos enseguida a %s.', v_contact.support_email)
      else 'Si no reconoces este pago en cuotas, escríbenos enseguida respondiendo a este correo.'
    end;
  end if;
  v_noreco_h := '<strong>' || public.helios_html_escape(v_noreco) || '</strong>';

  -- El IVA de la comisión, como porcentaje de la comisión (el que se cobró de
  -- verdad), igual que en la pregunta al paciente.
  v_iva := case when coalesce(v_c.consumer_fee_usd, 0) > 0
                then round(v_c.consumer_fee_vat_usd * 100 / v_c.consumer_fee_usd, 2)
                else public.helios_parameter('vat_pct', 16) end;

  return public.helios_enqueue_message(
    'comprobante_financiamiento', v_c.user_id, p_charge_id, 'email',
    jsonb_build_object(
      'nombre_completo', coalesce(nullif(btrim(v_p.full_name), ''),
                                  btrim(concat_ws(' ', v_p.first_name, v_p.last_name))),
      'documento', coalesce(public.helios_mask_document(v_p.document_number), '—'),
      'clinica', v_m.name,
      'clinica_rif', case when v_m.tax_id is not null then '(RIF ' || v_m.tax_id || ')' else '' end,
      'sede', coalesce(v_sede, '—'),
      'registrado_por', v_staff,
      'orden', v_orden,
      'fecha_hora', to_char(coalesce(v_c.confirmed_at, v_c.created_at) at time zone 'America/Caracas',
                            'DD/MM/YYYY HH24:MI'),
      'concepto', coalesce(v_concepto, 'Consulta'),
      'monto_consulta', public.helios_money_text(coalesce(v_c.base_usd, v_c.amount_usd)),
      'servicio_helios', public.helios_money_text(coalesce(v_c.consumer_fee_usd, 0)
                                                  + coalesce(v_c.consumer_fee_vat_usd, 0)),
      'servicio_helios_pct', rtrim(to_char(coalesce(v_c.consumer_fee_pct, 0), 'FM990.##'), '.'),
      -- Al paciente sí se le enseña la comisión, su IVA y el total (Javier,
      -- 2026-10-06): es lo que paga.
      'comision_servicio', public.helios_money_text(coalesce(v_c.consumer_fee_usd, 0)),
      'iva_pct', public.helios_pct_text(v_iva),
      'iva_comision', public.helios_money_text(coalesce(v_c.consumer_fee_vat_usd, 0)),
      'total', public.helios_money_text(v_c.amount_usd),
      'n_cuotas', v_n::text,
      'cuotas', v_cuotas,
      'cuotas_html', v_cuotas_h,
      'monto_cuota', public.helios_money_text(v_first.amount_usd),
      'fecha', to_char(v_first.due_date, 'DD/MM/YYYY'),
      'whatsapp_link', v_link,
      'aviso_pago', v_aviso,
      'aviso_pago_html', v_aviso_h,
      'no_reconoces', v_noreco,
      'no_reconoces_html', v_noreco_h
    ),
    null, null);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 2. Las plantillas al paciente
-- ---------------------------------------------------------------------------

-- La pregunta al paciente. Sin plantilla de Meta (ver la cabecera, punto 3).
update public.notification_templates
   set label = 'Confirma tu pago en cuotas',
       trigger_label = 'Al registrar un pago en cuotas (y al reenviarlo)',
       help = 'La pregunta al paciente: ¿acepta? Botones Sí / No. Al paciente sí se le enseña el total con la comisión de servicio y su IVA. Dentro de la ventana de 24 h sale este texto; fuera, la plantilla aprobada en Meta (wa_template_name) o, si no hay, la cola manual. El texto no se edita aquí.',
       default_title = 'Confirma tu pago en cuotas en {clinica}',
       default_body =
            E'👋 Hola, {nombre}. Bienvenido a Helios 💙\n\n'
         || E'{clinica} registró tu consulta de ${monto_consulta} para pagarla en 2 cuotas, sin inicial.\n\n'
         || E'* Consulta: ${monto_consulta}\n'
         || E'* Comisión de servicio ({servicio_pct}%): ${cargo_servicio}\n'
         || E'* IVA de la comisión ({iva_pct}%): ${iva_cargo_servicio}\n'
         || E'* Total: ${total}\n\n'
         || E'Tus cuotas serán de {cuotas_monto}:\n'
         || E'📅 {cuotas_fechas}\n\n'
         || E'¿Confirmas tu pago en cuotas? Responde Sí o No.\n'
         || 'Tienes 2 horas para confirmar.',
       wa_template_name = null
 where key = 'confirmar_financiamiento';

update public.notification_templates
   set trigger_label = 'Al confirmarse el pago en cuotas (el «Sí» del paciente)',
       help = 'Confirma el pago en cuotas y explica cómo pagar. Con la confirmación del paciente sale sola por WhatsApp; si no, va a la cola manual.',
       default_body =
            E'🩺 ¡Listo, {nombre}! Tu pago en cuotas #{orden} ya está activo.\n\n'
         || E'Tus pagos:\n{cuotas}\n\n'
         || E'Puedes pagar en bolívares a tasa BCV del día o en efectivo en divisas.\n\n'
         || 'Te escribiremos por aquí cuando se acerque cada pago con las instrucciones. Cuando pagues, solo envíanos el comprobante por este chat. 💙'
 where key = 'bienvenida';

update public.notification_templates
   set default_body =
            E'Hola, {nombre}. Te recordamos que mañana, {fecha}, vence tu cuota de ${monto_cuota} de la orden #{orden} en {clinica}.\n\n'
         || E'Puedes pagar en bolívares a la tasa BCV del día:\n{cuentas_de_cobro}\n\n'
         || 'Cuando pagues, envíanos el comprobante por WhatsApp: {whatsapp_helios}. ¡Gracias!'
 where key = 'cuota_manana';

update public.notification_templates
   set default_body =
            E'Buenos días, {nombre}. Hoy vence tu cuota de ${monto_cuota} de la orden #{orden} en {clinica}.\n\n'
         || E'Para pagar:\n{cuentas_de_cobro}\n\n'
         || 'Cuando pagues, envíanos el comprobante por aquí. Si ya pagaste, ignora este mensaje.'
 where key = 'cuota_hoy';

update public.notification_templates
   set default_body =
            E'Hola, {nombre}. Tu cuota de ${monto_cuota} del {fecha} (orden #{orden}) sigue pendiente.\n\n'
         || E'Mientras esté vencida no podrás pagar nuevas consultas en cuotas con Helios. Si la pagas antes de cumplir {dias_gracia} días de atraso, evitas el cargo de ${cargo_atraso}.\n\n'
         || E'Para pagar:\n{cuentas_de_cobro}\n\n'
         || 'Si tienes algún inconveniente, escríbenos y lo resolvemos juntos.'
 where key = 'cuota_vencida_d1';

update public.notification_templates
   set default_body =
            E'Hola, {nombre}. Tu cuota del {fecha} (orden #{orden}) sigue pendiente y hoy se sumó el cargo por atraso de ${cargo_atraso}. El monto a pagar de esa cuota es ahora ${monto_cuota}.\n\n'
         || E'Para pagar:\n{cuentas_de_cobro}\n\n'
         || 'Si necesitas ayuda para ponerte al día, escríbenos por aquí.'
 where key = 'cargo_por_atraso_d4';

update public.notification_templates
   set default_body =
            E'Hola, {nombre}. Tienes una cuota vencida, así que por ahora no puedes pagar nuevas consultas en cuotas con Helios. En cuanto te pongas al día se reactiva sola.\n\n'
         || E'Para pagar:\n{cuentas_de_cobro}'
 where key = 'cuenta_congelada';

-- El comprobante: la comisión, su IVA y el total desglosados; las
-- condiciones de hoy.
update public.notification_templates
   set label = 'Comprobante del pago en cuotas',
       trigger_label = 'Al confirmar un pago en cuotas, y cada vez que se reenvía',
       help = 'El único documento que recibe el paciente. El asunto es el título. Al paciente sí se le enseña lo que paga: la consulta, la comisión de servicio, su IVA y el total, cada uno en su línea.',
       variables = variables || array(
         select v from unnest(array['comision_servicio', 'iva_pct', 'iva_comision', 'total']) v
         where not v = any(variables)),
       default_title = 'Tu pago en cuotas en {clinica} — {n_cuotas} cuotas de ${monto_cuota}',
       default_body =
            E'Hola, {nombre}:\n\n'
         || E'Este es el comprobante de tu pago en cuotas con Helios. Guárdalo: aquí están tus cuotas y cómo pagarlas.\n\n'
         || E'ORDEN #{orden}\n'
         || E'{fecha_hora} (hora de Caracas)\n\n'
         || E'Clínica: {clinica} {clinica_rif}\n'
         || E'Sede: {sede}\n'
         || E'Registró: {registrado_por}\n'
         || E'Titular: {nombre_completo} · C.I. {documento}\n\n'
         || E'Servicios: {concepto}\n'
         || E'Monto de la consulta: ${monto_consulta}\n'
         || E'Comisión de servicio ({servicio_helios_pct}%): ${comision_servicio}\n'
         || E'IVA de la comisión ({iva_pct}%): ${iva_comision}\n'
         || E'Total a pagar: ${total}\n\n'
         || E'TU PLAN DE PAGOS (sin inicial)\n{cuotas}\n\n'
         || E'Las cuotas ya incluyen la comisión de servicio y su IVA.\n\n'
         || E'CÓMO PAGAR\n'
         || E'Pagas en bolívares, a la tasa BCV del dólar del día en que pagues.\n{cuentas_de_cobro}\n\n'
         || E'{aviso_pago}\n\n'
         || E'CONDICIONES\n'
         || E'• Desde el día siguiente al vencimiento de una cuota sin pagar, tu cuenta queda en pausa: no podrás registrar otro pago en cuotas hasta ponerte al día.\n'
         || E'• Después de {dias_gracia} días de gracia se suma un cargo de ${cargo_atraso} por cada cuota vencida.\n'
         || E'• A los {dias_suspension} días de atraso la cuenta se suspende.\n'
         || E'• A los {dias_expulsion} días de atraso la cuenta se cierra, tu cédula ya no podrá usar Helios y la deuda pasa a cobranza.\n\n'
         || E'{no_reconoces}\n\n'
         || 'Este comprobante no es una factura fiscal. Helios es operado por Quarto Latam, C.A.',
       default_html =
         replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(
           default_html,
           '<title>Tu financiamiento con Helios</title>',
           '<title>Tu pago en cuotas con Helios</title>'),
           'mso-hide:all;">Financiamiento #{orden} en {clinica}:',
           'mso-hide:all;">Orden #{orden} en {clinica}:'),
           '>Comprobante de financiamiento</td>',
           '>Comprobante de pago en cuotas</td>'),
           '    Financiamiento <strong>#{orden}</strong> &middot;',
           '    Orden <strong>#{orden}</strong> &middot;'),
           'Este es el comprobante de tu financiamiento con Helios.',
           'Este es el comprobante de tu pago en cuotas con Helios.'),
           '>Datos del financiamiento</td>',
           '>Datos del pago en cuotas</td>'),
           $h$font-weight:bold;">${monto_consulta}</td>
  </tr>$h$,
           $h$font-weight:bold;">${monto_consulta}</td>
  </tr>
  <tr>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#64748b;">Comisi&oacute;n de servicio ({servicio_helios_pct}%)</td>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#1f2937;">${comision_servicio}</td>
  </tr>
  <tr>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#64748b;">IVA de la comisi&oacute;n ({iva_pct}%)</td>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#1f2937;">${iva_comision}</td>
  </tr>
  <tr>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#64748b;">Total a pagar</td>
    <td style="padding:8px 12px;border-top:1px solid #e5e7eb;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#1f2937;font-weight:bold;">${total}</td>
  </tr>$h$),
           'Desglose: las cuotas incluyen el <strong>Servicio Helios ({servicio_helios_pct}&nbsp;% + IVA)</strong> de ${servicio_helios}.',
           'Las cuotas ya incluyen la <strong>comisi&oacute;n de servicio</strong> y su IVA.'),
           'Desde el primer d&iacute;a de atraso tu cuenta queda congelada: no podr&aacute;s financiar nuevas consultas hasta ponerte al d&iacute;a.',
           'Desde el d&iacute;a siguiente al vencimiento de una cuota sin pagar, tu cuenta queda en pausa: no podr&aacute;s registrar otro pago en cuotas hasta ponerte al d&iacute;a.'),
           'A los {dias_expulsion} d&iacute;as de atraso la cuenta se cierra y la deuda pasa a cobranza.',
           'A los {dias_expulsion} d&iacute;as de atraso la cuenta se cierra, tu c&eacute;dula ya no podr&aacute; usar Helios y la deuda pasa a cobranza.'),
           'Este comprobante no es una factura fiscal.</p>',
           'Este comprobante no es una factura fiscal. Helios es operado por Quarto Latam, C.A.</p>')
 where key = 'comprobante_financiamiento';

-- ---------------------------------------------------------------------------
-- 3. Las condiciones del comprobante, v2
-- ---------------------------------------------------------------------------
-- Las cifras salen de los parámetros vigentes (la comisión y el límite los
-- fija 20261006001000); el texto publicado queda fijo, como la v1.

update public.terms_versions
   set is_current = false
 where is_current
   and not exists (select 1 from public.terms_versions where version = 'v2');

insert into public.terms_versions (version, body, summary, published_at, is_current)
select
  'v2',
  E'Condiciones del pago en cuotas con Helios\n\n'
  || E'1. Helios te permite pagar tu consulta o tratamiento en la clínica en 2 cuotas, sin inicial: la primera vence 7 días después de la fecha de la orden y la segunda, 14 días después.\n'
  || format(E'2. Cada cuota incluye una parte del monto de la consulta y de la comisión de servicio de Helios: %s%% sobre el monto de la consulta, más el IVA de la comisión (%s%%). El comprobante detalla la comisión, su IVA, el total y cada cuota.\n',
            public.helios_pct_text(public.helios_consumer_fee_pct()), public.helios_pct_text(public.helios_vat_pct()))
  || E'3. Los montos están en dólares (dólar BCV). Pagas en bolívares, a la tasa oficial del Banco Central de Venezuela del día en que pagues, por Pago Móvil o transferencia a las cuentas de Helios que aparecen en el comprobante. Después de pagar, envía el comprobante del pago por WhatsApp a Helios.\n'
  || format(E'4. Tu límite inicial es de $%s. Lo que pagas en cuotas ocupa ese límite hasta que pagues las dos cuotas de la orden; entonces se libera.\n', l.limite)
  || E'5. Desde el día siguiente al vencimiento de una cuota sin pagar no podrás registrar otro pago en cuotas con Helios hasta ponerte al día.\n'
  || format(E'6. Si una cuota sigue sin pagar después de %s días de su vencimiento, se suma un cargo por atraso de $%s a esa cuota.\n',
            public.helios_late_fee_grace_days(), public.helios_money_text(public.helios_late_fee_usd()))
  || format(E'7. A los %s días de atraso la cuenta se suspende. A los %s días se cierra, la cédula queda en la lista de personas que no pueden usar Helios y la deuda pasa a cobranza.\n',
            public.helios_mora_demotion_days(), public.helios_mora_expulsion_days())
  || E'8. Helios puede contactarte por WhatsApp, por teléfono o por correo, a ti o al contacto de referencia que diste al registrarte, para recordarte tus pagos.\n'
  || E'9. Si no reconoces un pago en cuotas a tu nombre, escríbenos enseguida por WhatsApp.\n'
  || '10. Helios es un servicio operado por Quarto Latam, C.A.',
  format('Condiciones v2: 2 cuotas a 7 y 14 días sin inicial, comisión de servicio %s%% + IVA, límite inicial $%s, cargo de $%s tras %s días de atraso, suspensión a los %s días y cierre a los %s. Opera Quarto Latam, C.A.',
         public.helios_pct_text(public.helios_consumer_fee_pct()), l.limite,
         public.helios_money_text(public.helios_late_fee_usd()), public.helios_late_fee_grace_days(),
         public.helios_mora_demotion_days(), public.helios_mora_expulsion_days()),
  now(),
  true
from (select public.helios_money_text(monthly_limit_usd) as limite
      from public.levels where level = 1) l
where not exists (select 1 from public.terms_versions where version = 'v2');

-- ---------------------------------------------------------------------------
-- Comprobación: nada visible dice préstamo, financiamiento ni crédito
-- ---------------------------------------------------------------------------

do $$
declare
  v_malas text;
begin
  select string_agg(t.key, ', ') into v_malas
  from public.notification_templates t
  where t.enabled
    and concat_ws(' ', t.label, t.trigger_label, t.help, t.default_title, t.default_body, t.title, t.body,
                  t.draft_title, t.draft_body, t.default_html, t.html)
        ~* 'financ|pr[eé]stamo|cr[eé]dito|servicio helios|cargo por servicio';
  if v_malas is not null then
    raise exception 'Plantillas que todavía dicen financiamiento: %', v_malas;
  end if;

  if (select wa_template_name from public.notification_templates where key = 'confirmar_financiamiento') is not null then
    raise exception 'La pregunta al paciente no debía quedar con plantilla de Meta';
  end if;

  if (select default_html from public.notification_templates where key = 'comprobante_financiamiento')
       not like '%${comision_servicio}%${iva_comision}%${total}%' then
    raise exception 'El HTML del comprobante no quedó con la comisión, su IVA y el total';
  end if;

  if (select count(*) from public.terms_versions where is_current) <> 1
     or (select version from public.terms_versions where is_current) <> 'v2'
     or (select body from public.terms_versions where is_current) ~* 'financ|pr[eé]stamo|cr[eé]dito' then
    raise exception 'Las condiciones vigentes debían ser la v2, sin financiamiento';
  end if;

  select string_agg(p.proname, ', ') into v_malas
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname in ('helios_not_available_message', 'helios_notify_staff_of_charge', 'bot_charge_by_order',
                      'helios_charge_for_staff', 'staff_resend_confirmation', 'staff_resend_receipt',
                      'create_patient_charge', 'merchant_sales_export', 'merchant_sales_export_items',
                      'helios_finalize_charge', 'helios_enqueue_charge_receipt')
    and pg_get_functiondef(p.oid) ~ ('(No existe ese financiamiento|disponible para financiar|podemos financiar'
                                     '|Financiamiento no encontrado|El financiamiento no|Este financiamiento'
                                     '|otro financiamiento|registra el financiamiento|sus financiamientos'
                                     '|del financiamiento #|el financiamiento #|reconoces este financiamiento'
                                     '|rechazó el financiamiento|Financiamiento #%s confirmado)');
  if v_malas is not null then
    raise exception 'Funciones con textos que todavía dicen financiamiento: %', v_malas;
  end if;
end;
$$;
