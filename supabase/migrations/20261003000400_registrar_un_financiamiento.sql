-- ============================================================================
-- Helios — Registrar un financiamiento (H4 + devengo de H5, docs/00 §5 y §6)
--
-- Sustituye a la pareja de Ronda `request_charge` (el cajero pedía el cobro)
-- + `confirm_charge` (el cliente lo reclamaba con su PIN escaneando el QR).
-- En Helios la secretaria registra al paciente y la consulta en un solo paso.
--
--   helios_patient_eligibility(merchant, cédula)      paso 1: ¿se le financia?
--   preview_patient_charge(merchant, cédula, monto)   paso 4: desglose y fechas
--   create_patient_charge(...)                        paso 5: la deuda existe
--   staff_resend_receipt(charge)                      «Reenviar comprobante»
--   helios_charge_for_staff(charge)                   lo que la clínica ve
--
-- `create_patient_charge` es el cuerpo final de `confirm_charge`
-- (20260923170000) sin PIN, QR ni reclamo, con cada guarda que Ronda aprendió:
-- el perfil `for update`, el freno de gasto (`helios_spend_block`),
-- `can_take_debt`, el cupo con la fila bloqueada (y otra vez dentro de
-- `helios_assign_debt`, que bloquea el bloque de crédito), el asiento de cuatro
-- patas, `ledger.record_advance_settlement`, la única función que crea deuda
-- (`helios_assign_debt`) y la idempotencia. De `request_charge` (20260923100000)
-- toma la autorización por sede y el «la clínica pausada no cobra».
--
-- Privacidad entre clínicas (D-H6): la clínica nunca sabe POR QUÉ una persona
-- no está disponible. La elegibilidad y la creación usan el MISMO texto neutro
-- (`helios_not_available_message`). Para que la vista previa y la creación no
-- sirvan para saltarse el límite de consultas de cédula (enumerar pacientes),
-- las dos exigen que esa persona del personal haya consultado esa cédula en
-- esa clínica en las últimas 24 horas.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Ayudas internas
-- ---------------------------------------------------------------------------

/** El rol activo de quien llama en esa clínica (gerente manda), o null. */
create or replace function public.helios_staff_role_in(p_merchant_id uuid)
returns public.merchant_role
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select mu.role
  from public.merchant_users mu
  where mu.user_id = auth.uid()
    and mu.merchant_id = p_merchant_id
    and mu.is_active
    and mu.role in ('gerente', 'cajero')
  order by (mu.role = 'gerente') desc, mu.created_at
  limit 1;
$$;

/**
 * La clínica puede operar: existe, la plataforma no está en mantenimiento que
 * apaga y la clínica está activa. Si no, 55000 con el texto para mostrar.
 */
create or replace function public.helios_assert_merchant_operating(p_merchant_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_status public.merchant_status;
  v_stop   jsonb;
begin
  select status into v_status from public.merchants where id = p_merchant_id;
  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  -- Sin paciente, `helios_spend_block` solo puede devolver el mantenimiento.
  v_stop := public.helios_spend_block(null::uuid);
  if coalesce((v_stop->>'blocks_balance')::boolean, false) then
    raise exception '%', v_stop->>'message' using errcode = '55000';
  end if;

  if v_status = 'paused' then
    raise exception 'La clínica está pausada' using errcode = '55000';
  elsif v_status <> 'active' then
    raise exception 'La clínica ya no opera con Helios' using errcode = '55000';
  end if;
end;
$$;

/** La cédula normalizada (`V12345678`/`E12345678`), o 22023 «Cédula inválida». */
create or replace function public.helios_document_key(p_document text)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_key text := public.normalize_document(p_document);
begin
  if v_key is null or v_key !~ '^[VE][0-9]{6,9}$' then
    raise exception 'Cédula inválida' using errcode = '22023';
  end if;
  return v_key;
end;
$$;

/** El comienzo del día operativo de hoy (medianoche de Caracas), como instante. */
create or replace function public.helios_business_day_start()
returns timestamptz
language sql
stable
set search_path = public, pg_temp
as $$
  select public.helios_business_date(now())::timestamp at time zone 'America/Caracas';
$$;

/**
 * El texto neutro de «no disponible» (docs/01 §1.1). El mismo para mora,
 * lista negra, bloqueo, expulsión y cupo agotado: nunca dice por qué.
 */
create or replace function public.helios_not_available_message()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select 'No podemos financiar a esta persona. '
         || case when x.wa is null then 'Si tiene dudas, puede escribir a Helios.'
                 else 'Si tiene dudas, puede escribir a Helios al '
                      || coalesce(public.helios_format_ve_phone(x.wa), x.wa) || '.' end
  from (select (select pc.whatsapp_number from public.platform_contact pc where pc.id) as wa) x;
$$;

/**
 * Un dato del paciente, normalizado. Null si viene vacío; 22023 con el texto
 * para mostrar si viene mal. Claves (las de `p_patient`, docs/01 §1.3):
 * first_name, last_name, birth_date, sex, phone, email, state, city, address,
 * occupation, reference_name, reference_phone, reference_relationship.
 */
create or replace function public.helios_patient_field(p_key text, p_value text)
returns text
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v      text := nullif(regexp_replace(btrim(coalesce(p_value, '')), '\s+', ' ', 'g'), '');
  v_date date;
  v_age  integer;
  v_dig  text;
begin
  if v is null then
    return null;
  end if;

  case p_key
    when 'first_name', 'last_name' then
      if length(v) > 60 then
        raise exception 'Los nombres y apellidos admiten como mucho 60 caracteres' using errcode = '22023';
      end if;
      return v;

    when 'birth_date' then
      begin
        v_date := v::date;
      exception when others then
        raise exception 'Fecha de nacimiento inválida' using errcode = '22023';
      end;
      v_age := extract(year from age(public.helios_business_date(now())::timestamp, v_date::timestamp))::integer;
      if v_date > public.helios_business_date(now()) or v_age > 120 then
        raise exception 'Fecha de nacimiento inválida' using errcode = '22023';
      end if;
      if v_age < 18 then
        raise exception 'El titular debe ser mayor de edad. Si el paciente es menor, registra a su representante'
          using errcode = '22023';
      end if;
      return to_char(v_date, 'YYYY-MM-DD');

    when 'sex' then
      v := upper(v);
      if v not in ('F', 'M') then
        raise exception 'El sexo debe ser F o M' using errcode = '22023';
      end if;
      return v;

    when 'phone' then
      v := public.helios_normalize_ve_mobile(v);
      if v is null then
        raise exception 'Teléfono móvil inválido' using errcode = '22023';
      end if;
      return v;

    when 'email' then
      v := lower(v);
      if not public.helios_valid_email(v) then
        raise exception 'Correo inválido' using errcode = '22023';
      end if;
      return v;

    when 'reference_phone' then
      -- Un móvil, o un fijo venezolano (02xx): la referencia puede ser la casa.
      if public.helios_normalize_ve_mobile(v) is not null then
        return public.helios_normalize_ve_mobile(v);
      end if;
      v_dig := regexp_replace(v, '\D', '', 'g');
      if v_dig ~ '^58[0-9]{10}$' then v_dig := substr(v_dig, 3); end if;
      if v_dig ~ '^0[0-9]{10}$'  then v_dig := substr(v_dig, 2); end if;
      if v_dig !~ '^2[0-9]{9}$' then
        raise exception 'Teléfono del contacto de referencia inválido' using errcode = '22023';
      end if;
      return '+58' || v_dig;

    when 'state', 'city', 'address', 'occupation', 'reference_name', 'reference_relationship' then
      if length(v) > 200 then
        raise exception 'Un dato del paciente admite como mucho 200 caracteres' using errcode = '22023';
      end if;
      return v;

    else
      raise exception 'Dato del paciente desconocido: %', p_key using errcode = '22023';
  end case;
end;
$$;

/**
 * Los datos del paciente de `p_patient`, normalizados, con las claves de la
 * API. Estricto (paciente nuevo): exige todo lo obligatorio y lanza el primer
 * error. Laxo (paciente conocido, solo para comparar): se queda con lo que
 * viene bien y descarta lo demás en silencio.
 */
create or replace function public.helios_patient_input(p_patient jsonb, p_strict boolean)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_out  jsonb := '{}'::jsonb;
  v_key  text;
  v_val  text;
  v_keys text[] := array['first_name', 'last_name', 'birth_date', 'sex', 'phone', 'email',
                         'state', 'city', 'address', 'occupation',
                         'reference_name', 'reference_phone', 'reference_relationship'];
begin
  foreach v_key in array v_keys loop
    if p_strict then
      v_val := public.helios_patient_field(v_key, p_patient->>v_key);
    else
      begin
        v_val := public.helios_patient_field(v_key, p_patient->>v_key);
      exception when others then
        v_val := null;
      end;
    end if;
    if v_val is not null then
      v_out := v_out || jsonb_build_object(v_key, v_val);
    end if;
  end loop;

  if p_strict then
    if v_out->>'first_name' is null or v_out->>'last_name' is null then
      raise exception 'Faltan los nombres y apellidos del paciente' using errcode = '22023';
    end if;
    if v_out->>'birth_date' is null then
      raise exception 'Falta la fecha de nacimiento del paciente' using errcode = '22023';
    end if;
    if v_out->>'sex' is null then
      raise exception 'El sexo debe ser F o M' using errcode = '22023';
    end if;
    if v_out->>'phone' is null then
      raise exception 'Teléfono móvil inválido' using errcode = '22023';
    end if;
    if v_out->>'email' is null then
      raise exception 'Correo inválido' using errcode = '22023';
    end if;
    if v_out->>'state' is null or v_out->>'city' is null or v_out->>'address' is null then
      raise exception 'Falta la dirección del paciente (estado, ciudad y dirección)' using errcode = '22023';
    end if;
    if v_out->>'reference_name' is null or v_out->>'reference_phone' is null
       or v_out->>'reference_relationship' is null then
      raise exception 'Falta el contacto de referencia' using errcode = '22023';
    end if;
  end if;

  return v_out;
end;
$$;

/**
 * El estado del comprobante de un financiamiento, derivado del último correo
 * `comprobante_financiamiento` encolado para él:
 *
 *   pendiente       en cola (o todavía no hay ninguno)
 *   sin_configurar  en cola pero no hay clave de Resend en Vault (solo se mira
 *                   si EXISTE el secreto `resend_api_key`, nunca su valor), o
 *                   la plantilla está apagada
 *   enviado         aceptado por el proveedor
 *   entregado       el proveedor confirmó la entrega
 *   rebotado        rebotó, se marcó como spam, o no salió porque el paciente
 *                   no tiene correo o su correo ya había rebotado
 *   fallido         el despacho se rindió o se canceló
 */
create or replace function public.helios_charge_receipt(p_charge_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_m      public.outbound_messages%rowtype;
  v_email  text;
  v_status text;
begin
  select p.email into v_email
  from public.charges c join public.profiles p on p.id = c.user_id
  where c.id = p_charge_id;

  select * into v_m
  from public.outbound_messages
  where charge_id = p_charge_id and template_key = 'comprobante_financiamiento'
  order by created_at desc, id desc
  limit 1;

  v_status := case
    when v_m.id is null then 'pendiente'
    when v_m.last_event in ('bounced', 'complained') then 'rebotado'
    when v_m.status = 'pendiente' then
      case when exists (select 1 from vault.secrets s where s.name = 'resend_api_key')
           then 'pendiente' else 'sin_configurar' end
    when v_m.status = 'enviado' then
      case when v_m.last_event = 'delivered' then 'entregado' else 'enviado' end
    when v_m.status = 'omitido' then
      case when v_m.last_error = 'La plantilla está apagada' then 'sin_configurar' else 'rebotado' end
    else 'fallido'
  end;

  return jsonb_build_object(
    'status', v_status,
    'sent_at', v_m.sent_at,
    'last_event', v_m.last_event,
    'email_enmascarado', public.helios_mask_email(coalesce(v_m.recipient, v_email))
  );
end;
$$;

revoke all on function public.helios_staff_role_in(uuid)               from public, anon, authenticated;
revoke all on function public.helios_assert_merchant_operating(uuid)   from public, anon, authenticated;
revoke all on function public.helios_document_key(text)                from public, anon, authenticated;
revoke all on function public.helios_business_day_start()              from public, anon, authenticated;
revoke all on function public.helios_not_available_message()          from public, anon, authenticated;
revoke all on function public.helios_patient_field(text, text)         from public, anon, authenticated;
revoke all on function public.helios_patient_input(jsonb, boolean)     from public, anon, authenticated;
revoke all on function public.helios_charge_receipt(uuid)              from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Lo que la clínica ve de un financiamiento
-- ---------------------------------------------------------------------------
-- En Ronda devolvía una fila de `charges` con los campos del personal. Ahora es
-- la respuesta de `create_patient_charge` (docs/01 §1.3). Cambia el tipo de
-- retorno: se borra y se crea. Nadie más la llamaba (`request_charge` se podó).

drop function public.helios_charge_for_staff(uuid);

create function public.helios_charge_for_staff(p_charge_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me    uuid := auth.uid();
  v_c     public.charges%rowtype;
  v_p     public.profiles%rowtype;
  v_role  public.merchant_role;
  v_name  text;
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
    raise exception 'No existe ese financiamiento' using errcode = 'P0002';
  end if;

  select * into v_p from public.profiles where id = v_c.user_id;

  select mu.role into v_role
  from public.merchant_users mu
  where mu.user_id = v_c.requested_by and mu.merchant_id = v_c.merchant_id
  order by mu.is_active desc, (mu.role = 'gerente') desc, mu.created_at desc
  limit 1;

  v_name := public.helios_staff_name(v_c.requested_by);

  return jsonb_build_object(
    'id', v_c.id,
    'order_number', v_c.order_number,
    'status', v_c.status::text,
    'created_at', v_c.created_at,
    'confirmed_at', v_c.confirmed_at,
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
               'sequence', x.sequence, 'due_date', x.due_date, 'amount_usd', x.amount_usd)
             order by x.sequence)
      from (
        select i.sequence, min(i.due_date) as due_date, sum(i.amount_usd) as amount_usd
        from public.installments i where i.charge_id = v_c.id group by i.sequence
      ) x
    ), '[]'::jsonb),
    'breakdown', jsonb_build_object(
      'base_usd', v_c.base_usd,
      'consumer_fee_pct', v_c.consumer_fee_pct,
      'consumer_fee_usd', v_c.consumer_fee_usd,
      'consumer_fee_vat_usd', v_c.consumer_fee_vat_usd
    ),
    'receipt', public.helios_charge_receipt(v_c.id),
    'registered_by', case
      when v_name is null then null
      when v_role is null then v_name
      else v_name || ' (' || case v_role when 'gerente' then 'Administrador' else 'Secretaria' end || ')'
    end,
    'staff_commission_usd', v_c.staff_commission_usd
  );
end;
$$;

revoke all on function public.helios_charge_for_staff(uuid) from public, anon;
grant execute on function public.helios_charge_for_staff(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Paso 1: ¿se le puede financiar?
-- ---------------------------------------------------------------------------

create or replace function public.helios_patient_eligibility(p_merchant_id uuid, p_document text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff  uuid := auth.uid();
  v_key    text;
  v_n      integer;
  v_p      public.profiles%rowtype;
  v_limit  numeric(18,4);
  v_avail  numeric(18,4);
  v_min    numeric := public.helios_min_charge_usd();
  v_out    jsonb;
  v_result text;
begin
  if v_staff is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if public.helios_staff_role_in(p_merchant_id) is null then
    raise exception 'No tienes permiso para consultar en esta clínica' using errcode = '42501';
  end if;

  perform public.helios_assert_merchant_operating(p_merchant_id);

  v_key := public.helios_document_key(p_document);

  -- El límite por persona y día. Serializado por persona: dos pestañas a la
  -- vez no se cuelan las dos por la última plaza. Pasado el límite, error (y
  -- nada queda anotado: el error deshace la transacción). La alerta
  -- `consultas_de_cedula_excesivas` mira cuántas hay.
  perform pg_advisory_xact_lock(hashtextextended('helios_eligibility:' || v_staff::text, 0));

  select count(*) into v_n
  from public.eligibility_lookups
  where staff_user_id = v_staff
    and created_at >= public.helios_business_day_start();

  if v_n >= public.helios_eligibility_lookups_per_staff_day() then
    raise exception 'Llegaste al límite de consultas de hoy. Inténtalo mañana.' using errcode = '22023';
  end if;

  select * into v_p from public.profiles where document_key = v_key;

  if not found then
    v_result := 'nuevo';
    v_out := jsonb_build_object(
      'estado', 'nuevo',
      'min_charge_usd', v_min,
      'limite_usd', (select l.monthly_limit_usd from public.levels l where l.level = 1)
    );
  else
    select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_p.level;
    v_avail := greatest(coalesce(v_limit, 0) - public.helios_credit_used_usd(v_p.id), 0);

    if v_p.status = 'active'
       and not v_p.is_blacklisted
       and public.can_take_debt(v_p.id)
       and v_avail >= v_min then
      v_result := 'disponible';
      v_out := jsonb_build_object(
        'estado', 'disponible',
        'disponible_usd', trunc(v_avail, 2),
        'min_charge_usd', v_min,
        'nombre_enmascarado', public.helios_mask_name(
          coalesce(nullif(btrim(v_p.full_name), ''), concat_ws(' ', v_p.first_name, v_p.last_name))),
        'telefono_enmascarado', public.helios_mask_phone(v_p.phone_e164),
        'email_enmascarado', public.helios_mask_email(v_p.email)
      );
    else
      -- Mora, lista negra, bloqueo, expulsión o cupo agotado: no se dice cuál.
      v_result := 'no_disponible';
      v_out := jsonb_build_object(
        'estado', 'no_disponible',
        'mensaje', public.helios_not_available_message(),
        'whatsapp_helios', (select pc.whatsapp_number from public.platform_contact pc where pc.id)
      );
    end if;
  end if;

  insert into public.eligibility_lookups (staff_user_id, merchant_id, document_key, result)
  values (v_staff, p_merchant_id, v_key, v_result);

  return v_out;
end;
$$;

revoke all on function public.helios_patient_eligibility(uuid, text) from public, anon;
grant execute on function public.helios_patient_eligibility(uuid, text) to authenticated;

/**
 * ¿Consultó esta persona esa cédula en esa clínica en las últimas 24 horas?
 * La vista previa y la creación lo exigen: si no, servirían para averiguar el
 * disponible de cualquier cédula sin pasar por el límite de consultas.
 */
create or replace function public.helios_assert_document_looked_up(p_merchant_id uuid, p_key text)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1 from public.eligibility_lookups
    where staff_user_id = auth.uid()
      and merchant_id = p_merchant_id
      and document_key = p_key
      and result <> 'limite'
      and created_at > now() - interval '24 hours'
  ) then
    raise exception 'Primero consulta la cédula del paciente' using errcode = '22023';
  end if;
end;
$$;

revoke all on function public.helios_assert_document_looked_up(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Paso 4: la vista previa
-- ---------------------------------------------------------------------------

create or replace function public.preview_patient_charge(
  p_merchant_id uuid,
  p_document    text,
  p_amount_usd  numeric
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_key     text;
  v_p       public.profiles%rowtype;
  v_terms   public.merchant_terms%rowtype;
  v_b       jsonb;
  v_bdate   date := public.helios_business_date(now());
  v_due_1   date;
  v_due_2   date;
  v_total   numeric(18,4);
  v_base    numeric(18,4);
  v_first   numeric(18,4);
  v_fin_1   numeric(18,4);
  v_limit   numeric(18,4);
  v_avail   numeric(18,4);
  v_level1  numeric(18,4) := (select l.monthly_limit_usd from public.levels l where l.level = 1);
  v_min     numeric := public.helios_min_charge_usd();
begin
  if auth.uid() is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if public.helios_staff_role_in(p_merchant_id) is null then
    raise exception 'No tienes permiso para registrar en esta clínica' using errcode = '42501';
  end if;

  perform public.helios_assert_merchant_operating(p_merchant_id);
  perform public.helios_assert_charge_amount(p_amount_usd);

  if nullif(btrim(coalesce(p_document, '')), '') is not null then
    v_key := public.helios_document_key(p_document);
    perform public.helios_assert_document_looked_up(p_merchant_id, v_key);
    select * into v_p from public.profiles where document_key = v_key;
  end if;

  select * into v_terms from public.helios_terms_at(p_merchant_id, v_bdate);
  if v_terms.id is null then
    raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
      using errcode = '22023';
  end if;

  v_b := public.helios_charge_breakdown(p_amount_usd, coalesce(v_terms.commission_pct, 0));
  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_bdate);

  -- El mismo reparto que `helios_assign_debt`.
  v_total := (v_b->>'consumer_total_usd')::numeric;
  v_base  := (v_b->>'base_usd')::numeric;
  v_first := round(v_total / 2, 2);
  v_fin_1 := round(v_base / 2, 2);

  if v_p.id is not null then
    select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_p.level;
    v_avail := greatest(coalesce(v_limit, 0) - public.helios_credit_used_usd(v_p.id), 0);
    -- Sin decir por qué: si no puede financiar, su disponible es 0.
    if not (v_p.status = 'active' and not v_p.is_blacklisted and public.can_take_debt(v_p.id))
       or v_avail < v_min then
      v_avail := 0;
    end if;
    v_avail := trunc(v_avail, 2);
  end if;

  return jsonb_build_object(
    'base_usd', v_base,
    'consumer_fee_pct', (v_b->>'consumer_fee_pct')::numeric,
    'consumer_fee_usd', (v_b->>'consumer_fee_usd')::numeric,
    'consumer_fee_vat_usd', (v_b->>'consumer_fee_vat_usd')::numeric,
    'business_date', v_bdate,
    'installments', jsonb_build_array(
      jsonb_build_object('sequence', 1, 'due_date', v_due_1, 'amount_usd', v_first, 'financed_usd', v_fin_1),
      jsonb_build_object('sequence', 2, 'due_date', v_due_2, 'amount_usd', v_total - v_first,
                         'financed_usd', v_base - v_fin_1)
    ),
    'late_fee_usd', public.helios_late_fee_usd(),
    'late_fee_grace_days', public.helios_late_fee_grace_days(),
    'cabe', case when v_p.id is null then v_base <= v_level1 else v_base <= v_avail end,
    'disponible_usd', case when v_p.id is null then null else v_avail end,
    'limite_usd', case when v_p.id is null then v_level1 end
  );
end;
$$;

revoke all on function public.preview_patient_charge(uuid, text, numeric) from public, anon;
grant execute on function public.preview_patient_charge(uuid, text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. La comisión de quien lo registró (H5)
-- ---------------------------------------------------------------------------

/**
 * Devenga la comisión de un financiamiento confirmado, con la instantánea
 * guardada en `charges` (docs/00 §6):
 *
 *   Dr commission_expense / Cr merchant_payable (la clínica)
 *   idempotencia 'staff_commission:<charge_id>'
 *
 * y una liquidación `staff_commission` que vence el mismo día operativo, así
 * que entra en el primer lunes de cierre DESPUÉS del alta, aunque las cuotas
 * vayan más tarde. Idempotente. Devuelve el id de `staff_commissions` o null
 * si no hay comisión. Interna.
 */
create or replace function public.helios_accrue_staff_commission(p_charge_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_c   public.charges%rowtype;
  v_id  uuid;
  v_tx  uuid;
  v_set uuid;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found or v_c.status <> 'confirmed' then
    raise exception 'El financiamiento no está confirmado' using errcode = '22023';
  end if;

  if coalesce(v_c.staff_commission_usd, 0) <= 0 or v_c.commission_staff_id is null then
    return null;
  end if;

  select id into v_id from public.staff_commissions where charge_id = p_charge_id;
  if found then
    return v_id;
  end if;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('staff_commission', 'staff_commission:' || p_charge_id::text, v_c.business_date, p_charge_id,
          'Comisión del personal de la clínica')
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, ledger.get_or_create_account('commission_expense', null), v_c.staff_commission_usd, 0),
    (v_tx, ledger.get_or_create_account('merchant_payable', v_c.merchant_id), 0, v_c.staff_commission_usd);

  insert into public.settlements
    (merchant_id, charge_id, reason, amount_usd, business_date, due_date, status)
  values
    (v_c.merchant_id, p_charge_id, 'staff_commission', v_c.staff_commission_usd,
     v_c.business_date, v_c.business_date, 'pending')
  returning id into v_set;

  insert into public.staff_commissions (charge_id, merchant_id, staff_user_id, amount_usd, settlement_id)
  values (p_charge_id, v_c.merchant_id, v_c.commission_staff_id, v_c.staff_commission_usd, v_set)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.helios_accrue_staff_commission(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Paso 5: registrar el financiamiento
-- ---------------------------------------------------------------------------

create or replace function public.create_patient_charge(
  p_merchant_id      uuid,
  p_branch_id        uuid,
  p_patient          jsonb,
  p_amount_usd       numeric,
  p_concept          text,
  p_beneficiary_name text,
  p_idempotency_key  text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $$
declare
  v_staff      uuid := auth.uid();
  v_key        text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
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
  v_due_1      date;
  v_due_2      date;
  v_charge     public.charges%rowtype;
  v_financed   numeric(18,4);
  v_revenue    numeric(18,4);
  v_share      numeric(18,4);
  v_tx         uuid;
  v_commission numeric(18,4);
  v_over_msg   text;
  v_cuotas     text;
  v_merchant   text;
begin
  if v_staff is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if v_key is null or length(v_key) > 200 then
    raise exception 'Falta la clave de idempotencia del formulario' using errcode = '22023';
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
    raise exception 'Esa clave de idempotencia ya se usó en otro financiamiento' using errcode = '22023';
  end if;

  -- 2. Autorización. Gerente: cualquier sede de su clínica (sin sede, la
  --    principal). Secretaria: solo la suya.
  v_role := public.helios_staff_role_in(p_merchant_id);
  if v_role is null then
    raise exception 'No tienes permiso para registrar en esta clínica' using errcode = '42501';
  end if;

  perform public.helios_assert_merchant_operating(p_merchant_id);

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
      raise exception 'Elige la sede donde se registra el financiamiento' using errcode = '22023';
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
    -- Nuevo: se validan todos los datos y nace activo, nivel 1.
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

    -- Sus datos NO se sobrescriben: lo que venga distinto queda como
    -- propuesta para Helios. El comprobante va al correo ya registrado.
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
  --    sedes a la vez). `helios_assign_debt` lo vuelve a mirar con el bloque
  --    de crédito bloqueado.
  select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_profile.level;
  v_used  := public.helios_credit_used_usd(v_profile.id);
  v_avail := greatest(coalesce(v_limit, 0) - v_used, 0);

  if not v_new and v_avail < v_min then
    -- Cupo agotado es también «no disponible», sin decir por qué.
    raise exception '%', public.helios_not_available_message() using errcode = '22023';
  end if;

  v_over_msg := format('El monto supera lo disponible para financiar ($%s)',
                       public.helios_money_text(trunc(v_avail, 2)));
  if round(p_amount_usd, 2) > v_avail then
    raise exception '%', v_over_msg using errcode = '22023';
  end if;

  -- 6. Condiciones, desglose y fechas.
  v_bdate := public.helios_business_date(now());

  select * into v_terms from public.helios_terms_at(p_merchant_id, v_bdate);
  if v_terms.id is null then
    raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
      using errcode = '22023';
  end if;

  v_b := public.helios_charge_breakdown(p_amount_usd, coalesce(v_terms.commission_pct, 0));
  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_bdate);

  v_commission := public.helios_staff_commission_for(p_merchant_id, v_bdate);

  -- 7. El financiamiento, directamente confirmado.
  insert into public.charges (
    merchant_id, branch_id, requested_by, idempotency_key, user_id, status,
    business_date, confirmed_at,
    amount_usd, base_usd, vat_pct, vat_usd,
    consumer_fee_pct, consumer_fee_usd, consumer_fee_vat_usd,
    merchant_fee_pct, merchant_fee_usd, merchant_fee_vat_usd, merchant_net_usd,
    concept, beneficiary_name, terms_version_id,
    staff_commission_usd, commission_staff_id
  ) values (
    p_merchant_id, v_branch, v_staff, v_key, v_profile.id, 'confirmed',
    v_bdate, now(),
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

  -- 8. El asiento de cuatro patas, saltándose las que valen cero.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);
  v_revenue  := coalesce(v_charge.consumer_fee_usd, 0) + coalesce(v_charge.merchant_fee_usd, 0);
  v_share    := coalesce(v_charge.merchant_net_usd, v_charge.amount_usd - v_revenue);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', 'charge:' || v_key, v_bdate, v_charge.id, 'Financiamiento de consulta')
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit)
  select v_tx, x.acct, x.debit, x.credit
  from (values
    (ledger.get_or_create_account('user_receivable', v_profile.id), v_charge.amount_usd, 0::numeric),
    (ledger.get_or_create_account('merchant_payable', p_merchant_id), 0::numeric, v_share),
    (ledger.get_or_create_account('platform_revenue', null), 0::numeric, v_revenue),
    (ledger.get_or_create_account('vat_payable', null), 0::numeric,
     v_charge.amount_usd - v_share - v_revenue)
  ) as x(acct, debit, credit)
  where x.debit <> 0 or x.credit <> 0;

  -- 9. El adelanto a la clínica (no hace nada con upfront_pct = 0).
  perform ledger.record_advance_settlement(
    p_merchant_id, v_charge.id, round(v_share * v_terms.upfront_pct / 100, 4), v_bdate);

  -- 10. La deuda: las 2 cuotas a +7 y +14 días y el bloque de crédito.
  perform public.helios_assign_debt(
    v_profile.id, v_charge.id, v_financed, v_charge.amount_usd, v_due_1, v_due_2, v_over_msg);

  -- 11. La comisión de quien lo registró.
  perform public.helios_accrue_staff_commission(v_charge.id);

  -- 12. Los mensajes: el comprobante (correo, al correo REGISTRADO) y la
  --     bienvenida (WhatsApp manual).
  perform public.helios_enqueue_charge_receipt(v_charge.id);

  select m.name into v_merchant from public.merchants m where m.id = p_merchant_id;
  select string_agg(format('• Cuota %s: $%s, vence el %s %s', i.sequence,
                           public.helios_money_text(i.amount_usd),
                           public.helios_weekday_es(i.due_date), to_char(i.due_date, 'DD/MM/YYYY')),
                    E'\n' order by i.sequence)
    into v_cuotas
  from public.installments i where i.charge_id = v_charge.id;

  perform public.helios_enqueue_message(
    'bienvenida', v_profile.id, v_charge.id, 'whatsapp_manual',
    jsonb_build_object('clinica', v_merchant, 'orden', v_charge.order_number::text, 'cuotas', v_cuotas),
    null, 'bienvenida:' || v_charge.id::text);

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
    'business_date', v_bdate
  ));

  return public.helios_charge_for_staff(v_charge.id);
end;
$$;

revoke all on function public.create_patient_charge(uuid, uuid, jsonb, numeric, text, text, text) from public, anon;
grant execute on function public.create_patient_charge(uuid, uuid, jsonb, numeric, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Reenviar el comprobante
-- ---------------------------------------------------------------------------

create or replace function public.staff_resend_receipt(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
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
    raise exception 'No existe ese financiamiento' using errcode = 'P0002';
  end if;

  if v_c.status <> 'confirmed' then
    raise exception 'Este financiamiento ya no está vigente' using errcode = '22023';
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
$$;

revoke all on function public.staff_resend_receipt(uuid) from public, anon;
grant execute on function public.staff_resend_receipt(uuid) to authenticated;
