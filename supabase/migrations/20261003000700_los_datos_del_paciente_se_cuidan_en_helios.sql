-- ============================================================================
-- Helios — Los datos del paciente se cuidan en Helios (docs/01 §2.4)
--
-- El paciente no tiene cuenta: sus datos los teclea la clínica al registrarlo
-- y, desde ahí, solo los cambia el equipo de Helios.
--
-- 1. `admin_user_detail` gana la sección `datos` (la ficha del paciente:
--    documento, nacimiento y edad, sexo, contacto, dirección, referencia,
--    quién y dónde lo registró). El resto de la respuesta no cambia.
-- 2. `admin_update_patient_contact(p_user, p, p_reason)`: el equipo
--    (operador o super admin) corrige el contacto. Solo las claves que vienen;
--    el motivo es obligatorio y queda en la bitácora con el antes y el
--    después. Un correo nuevo borra la marca de rebote.
-- 3. `admin_profile_change_requests(p_status)` y
--    `admin_resolve_profile_change(p_id, p_approve, p_note)`: la cola de los
--    datos que una clínica tecleó distintos de los registrados
--    (`create_patient_charge` los deja como propuesta). Aprobar aplica los
--    valores propuestos con las mismas validaciones; las dos quedan en la
--    bitácora.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Ayudas internas
-- ---------------------------------------------------------------------------

/** La ficha del paciente (la sección `datos` de `admin_user_detail`). */
create or replace function public.helios_patient_datos(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'document', p.document_number,
    'document_key', p.document_key,
    'first_name', p.first_name,
    'last_name', p.last_name,
    'full_name', p.full_name,
    'birth_date', p.birth_date,
    'age', case when p.birth_date is not null then
             extract(year from age(public.helios_business_date(now())::timestamp,
                                   p.birth_date::timestamp))::integer end,
    'sex', p.sex,
    'phone_e164', p.phone_e164,
    'email', p.email,
    'email_invalid_at', p.email_invalid_at,
    'state', p.state,
    'city', p.city,
    'address', p.address,
    'occupation', p.occupation,
    'reference_name', p.reference_name,
    'reference_phone', p.reference_phone,
    'reference_relationship', p.reference_relationship,
    'registered_by', p.registered_by,
    'registered_by_name', public.helios_staff_name(p.registered_by),
    'registered_merchant_id', p.registered_merchant_id,
    'registered_merchant_name', (select m.name from public.merchants m where m.id = p.registered_merchant_id),
    'created_at', p.created_at,
    'pending_change_requests', (
      select count(*)::integer from public.profile_change_requests r
      where r.profile_id = p.id and r.status = 'pendiente')
  )
  from public.profiles p
  where p.id = p_user_id;
$$;

/**
 * Aplica datos del paciente (claves de la API: `phone`, `email`, …) con las
 * mismas validaciones que el registro (`helios_patient_field`). Solo las
 * claves de `p_allowed`; `null` o `''` borra los opcionales, nunca los
 * obligatorios. Devuelve `{campo: {antes, despues}}` de lo que cambió.
 * Interna: la llaman `admin_update_patient_contact` y
 * `admin_resolve_profile_change`, que ya bloquearon la fila.
 */
create or replace function public.helios_apply_patient_fields(
  p_profile_id uuid,
  p_fields     jsonb,
  p_allowed    text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_p        public.profiles%rowtype;
  v_key      text;
  v_col      text;
  v_val      text;
  v_antes    text;
  v_patch    jsonb := '{}'::jsonb;
  v_changes  jsonb := '{}'::jsonb;
  v_phone    text;
  v_ref      text;
begin
  if p_fields is null or jsonb_typeof(p_fields) <> 'object' or p_fields = '{}'::jsonb then
    raise exception 'No hay datos que cambiar' using errcode = '22023';
  end if;

  select * into v_p from public.profiles where id = p_profile_id;
  if not found then
    raise exception 'Paciente no encontrado' using errcode = 'P0002';
  end if;

  for v_key in select jsonb_object_keys(p_fields) loop
    if not (v_key = any (p_allowed)) then
      raise exception 'Ese dato no se puede cambiar aquí: %', v_key using errcode = '22023';
    end if;

    v_val := public.helios_patient_field(v_key, p_fields->>v_key);

    if v_val is null and v_key in ('first_name', 'last_name', 'birth_date', 'sex', 'phone', 'email') then
      raise exception 'El dato % es obligatorio y no se puede borrar', v_key using errcode = '22023';
    end if;

    v_col   := case when v_key = 'phone' then 'phone_e164' else v_key end;
    v_antes := to_jsonb(v_p) ->> v_col;

    if v_antes is distinct from v_val then
      v_patch   := v_patch || jsonb_build_object(v_col, v_val);
      v_changes := v_changes || jsonb_build_object(v_key,
                     jsonb_build_object('antes', v_antes, 'despues', v_val));
    end if;
  end loop;

  v_phone := coalesce(v_patch->>'phone_e164', v_p.phone_e164);
  v_ref   := case when v_patch ? 'reference_phone' then v_patch->>'reference_phone' else v_p.reference_phone end;
  if v_ref is not null and v_ref = v_phone then
    raise exception 'El teléfono del contacto de referencia tiene que ser distinto del del paciente'
      using errcode = '22023';
  end if;

  if v_patch = '{}'::jsonb then
    return v_changes;
  end if;

  update public.profiles set
    first_name  = case when v_patch ? 'first_name' then v_patch->>'first_name' else first_name end,
    last_name   = case when v_patch ? 'last_name'  then v_patch->>'last_name'  else last_name end,
    full_name   = case when v_patch ?| array['first_name', 'last_name']
                       then concat_ws(' ',
                              case when v_patch ? 'first_name' then v_patch->>'first_name' else first_name end,
                              case when v_patch ? 'last_name'  then v_patch->>'last_name'  else last_name end)
                       else full_name end,
    birth_date  = case when v_patch ? 'birth_date' then (v_patch->>'birth_date')::date else birth_date end,
    sex         = case when v_patch ? 'sex'        then v_patch->>'sex'        else sex end,
    phone_e164  = case when v_patch ? 'phone_e164' then v_patch->>'phone_e164' else phone_e164 end,
    email       = case when v_patch ? 'email'      then v_patch->>'email'      else email end,
    -- Un correo nuevo merece otra oportunidad.
    email_invalid_at = case when v_patch ? 'email' then null else email_invalid_at end,
    state       = case when v_patch ? 'state'      then v_patch->>'state'      else state end,
    city        = case when v_patch ? 'city'       then v_patch->>'city'       else city end,
    address     = case when v_patch ? 'address'    then v_patch->>'address'    else address end,
    occupation  = case when v_patch ? 'occupation' then v_patch->>'occupation' else occupation end,
    reference_name = case when v_patch ? 'reference_name' then v_patch->>'reference_name' else reference_name end,
    reference_phone = case when v_patch ? 'reference_phone' then v_patch->>'reference_phone' else reference_phone end,
    reference_relationship = case when v_patch ? 'reference_relationship'
                                  then v_patch->>'reference_relationship' else reference_relationship end
  where id = p_profile_id;

  return v_changes;
end;
$$;

revoke all on function public.helios_patient_datos(uuid) from public, anon, authenticated;
revoke all on function public.helios_apply_patient_fields(uuid, jsonb, text[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Corregir el contacto
-- ---------------------------------------------------------------------------

create or replace function public.admin_update_patient_contact(p_user uuid, p jsonb, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor   uuid := auth.uid();
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
  v_changes jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_reason is null or length(v_reason) < 3 then
    raise exception 'Escribe el motivo del cambio' using errcode = '22023';
  end if;

  perform 1 from public.profiles where id = p_user for update;
  if not found then
    raise exception 'Paciente no encontrado' using errcode = 'P0002';
  end if;

  v_changes := public.helios_apply_patient_fields(p_user, p, array[
    'phone', 'email', 'state', 'city', 'address', 'occupation',
    'reference_name', 'reference_phone', 'reference_relationship']);

  perform audit.log(v_actor, 'patient.contact_updated', p_user, jsonb_build_object(
    'changes', v_changes,
    'note', v_reason
  ));

  return jsonb_build_object(
    'ok', true,
    'changes', v_changes,
    'datos', public.helios_patient_datos(p_user)
  );
end;
$$;

revoke all on function public.admin_update_patient_contact(uuid, jsonb, text) from public, anon;
grant execute on function public.admin_update_patient_contact(uuid, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Las propuestas de cambio
-- ---------------------------------------------------------------------------

create or replace function public.admin_profile_change_requests(p_status text default 'pendiente')
returns table(
  id uuid, profile_id uuid, patient_name text, document_number text,
  merchant_id uuid, merchant_name text, requested_by uuid, requested_by_name text,
  field_changes jsonb, status text, reviewed_by uuid, reviewed_by_name text,
  reviewed_at timestamptz, note text, created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_status is not null and p_status not in ('pendiente', 'aprobado', 'rechazado') then
    raise exception 'Estado no válido: %', p_status using errcode = '22023';
  end if;

  return query
  select r.id,
         r.profile_id,
         p.full_name,
         p.document_number,
         r.merchant_id,
         m.name,
         r.requested_by,
         public.helios_staff_name(r.requested_by),
         r.field_changes,
         r.status,
         r.reviewed_by,
         (select pa.full_name from public.platform_admins pa where pa.user_id = r.reviewed_by),
         r.reviewed_at,
         r.note,
         r.created_at
  from public.profile_change_requests r
  join public.profiles p on p.id = r.profile_id
  left join public.merchants m on m.id = r.merchant_id
  where p_status is null or r.status = p_status
  order by case when r.status = 'pendiente' then r.created_at end asc nulls last,
           r.reviewed_at desc nulls last
  limit 500;
end;
$$;

create or replace function public.admin_resolve_profile_change(
  p_id      uuid,
  p_approve boolean,
  p_note    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor   uuid := auth.uid();
  v_req     public.profile_change_requests%rowtype;
  v_patch   jsonb := '{}'::jsonb;
  v_key     text;
  v_changes jsonb := '{}'::jsonb;
  v_note    text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_approve is null then
    raise exception 'Indica si se aprueba o se rechaza' using errcode = '22023';
  end if;

  select * into v_req from public.profile_change_requests where id = p_id for update;
  if not found then
    raise exception 'No existe esa propuesta' using errcode = 'P0002';
  end if;

  if v_req.status <> 'pendiente' then
    raise exception 'Esta propuesta ya se revisó' using errcode = '22023';
  end if;

  if p_approve then
    perform 1 from public.profiles where id = v_req.profile_id for update;

    for v_key in select jsonb_object_keys(v_req.field_changes) loop
      v_patch := v_patch || jsonb_build_object(v_key, v_req.field_changes->v_key->>'propuesto');
    end loop;

    v_changes := public.helios_apply_patient_fields(v_req.profile_id, v_patch, array[
      'first_name', 'last_name', 'birth_date', 'sex', 'phone', 'email',
      'state', 'city', 'address', 'occupation',
      'reference_name', 'reference_phone', 'reference_relationship']);
  end if;

  update public.profile_change_requests
     set status      = case when p_approve then 'aprobado' else 'rechazado' end,
         reviewed_by = v_actor,
         reviewed_at = now(),
         note        = v_note
   where id = p_id;

  perform audit.log(v_actor,
    case when p_approve then 'patient.change_request_approved' else 'patient.change_request_rejected' end,
    v_req.profile_id,
    jsonb_build_object('request_id', p_id, 'merchant_id', v_req.merchant_id,
                       'proposed', v_req.field_changes, 'changes', v_changes, 'note', v_note));

  return jsonb_build_object(
    'ok', true,
    'id', p_id,
    'status', case when p_approve then 'aprobado' else 'rechazado' end,
    'changes', v_changes
  );
end;
$$;

revoke all on function public.admin_profile_change_requests(text) from public, anon;
revoke all on function public.admin_resolve_profile_change(uuid, boolean, text) from public, anon;
grant execute on function public.admin_profile_change_requests(text) to authenticated;
grant execute on function public.admin_resolve_profile_change(uuid, boolean, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 1. La ficha del paciente: la sección `datos`
-- ---------------------------------------------------------------------------
-- Idéntica a la vigente (pg_get_functiondef, 2026-09-30) salvo la sección
-- `datos` al final, antes del `return`.

CREATE OR REPLACE FUNCTION public.admin_user_detail(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today  date := public.helios_business_date(now());
  v_result jsonb;
  v_block  public.user_credit_blocks%rowtype;
  v_limit  numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'user_id', p.id,
    'full_name', p.full_name,
    'phone_e164', p.phone_e164,
    'document_number', p.document_number,
    'birth_date', p.birth_date,
    'status', p.status,
    'level', p.level,
    'is_blacklisted', p.is_blacklisted,
    'blacklist_reason', p.blacklist_reason,
    'is_test', p.is_test,
    'created_at', p.created_at,
    -- PODA (Helios): el avatar lo elegía la persona en la app
    -- (`avatar_colors`, `avatar_emojis`). Las claves quedan en null.
    'avatar_emoji', null::text,
    'avatar_color', null::text
  ), l.monthly_limit_usd
  into v_result, v_limit
  from public.profiles p
  join public.levels l on l.level = p.level
  where p.id = p_user_id;

  if v_result is null then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  -- El bloque de crédito abierto explica el disponible. Es la pregunta #1 de
  -- soporte: "pagué una cuota, ¿por qué sigo en cero?" (docs/00-BASES §2.2).
  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user_id and closed_at is null;

  v_result := v_result || jsonb_build_object('credit', jsonb_build_object(
    'level_limit_usd', v_limit,
    'block_charged_usd', coalesce(v_block.charged_usd, 0),
    'block_paid_usd', coalesce(v_block.paid_usd, 0),
    'available_usd', greatest(v_limit - (coalesce(v_block.charged_usd, 0)
                                       - coalesce(v_block.paid_usd, 0)), 0),
    'to_unlock_usd', coalesce(v_block.charged_usd, 0) - coalesce(v_block.paid_usd, 0),
    'block_opened_at', v_block.opened_at,
    -- Lo que puede gastar HOY, con la misma puerta que una compra. Con una
    -- cuota vencida, la cuenta sin activar o un bloqueo, es 0.
    'available_now_usd', public.helios_available_now_usd(p_user_id),
    -- El mismo cupo, sin mirar si hoy puede gastarlo.
    'available_nominal_usd', greatest(v_limit - public.helios_credit_used_usd(p_user_id), 0),
    'available_blocked_reason', public.helios_available_blocked_reason(p_user_id)
  ));

  -- Lo dado por perdido (written_off_at) no es deuda viva: no entra en lo
  -- que debe, ni en lo vencido, ni en los días de atraso, igual que en
  -- metricas.cuotas (estado 'perdida'). Va aparte, en written_off_usd.
  -- (20260927696000; antes sumaba toda cuota 'pending'.)
  v_result := v_result || jsonb_build_object('debt', (
    select jsonb_build_object(
      'open_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and written_off_at is null), 0),
      'overdue_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and written_off_at is null and due_date < v_today), 0),
      'paid_usd', coalesce(sum(amount_usd) filter (where status = 'paid'), 0),
      -- FINANCED: el consumo de sus cuotas pagadas, la cifra que mide el
      -- motor de niveles (level_standing). paid_usd lleva el fee dentro.
      'paid_financed_usd', coalesce(sum(financed_usd) filter (where status = 'paid'), 0),
      'days_overdue', coalesce(max(v_today - due_date)
        filter (where status = 'pending' and written_off_at is null and due_date < v_today), 0),
      -- PAYABLE: las cuotas sin pagar dadas por perdidas, con su consumo.
      'written_off_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and written_off_at is not null), 0),
      'written_off_financed_usd', coalesce(sum(financed_usd)
        filter (where status = 'pending' and written_off_at is not null), 0)
    )
    from public.installments where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'charge_id', i.charge_id,
      -- El número de la orden de la que sale esta cuota: es lo que el equipo
      -- teclea en el buscador y lo que el local dicta por teléfono.
      'order_number', ch.order_number,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      -- Lo que esta cuota lleva de consumo, sin el servicio.
      'financed_usd', i.financed_usd,
      'due_date', i.due_date,
      'status', i.status,
      'paid_at', i.paid_at,
      'merchant_name', m.name,
      'days_overdue', greatest(v_today - i.due_date, 0),
      -- Dada por perdida: sigue 'pending' pero ya no es deuda viva.
      'written_off_at', i.written_off_at,
      -- El día operativo en que REPORTÓ el pago que la saldó (sin reporte, el
      -- de la aprobación): el mismo que metricas.cuotas.pagada_dia.
      'paid_day', case when i.status = 'paid' then
        coalesce(metricas.dia_operativo(pr.created_at), metricas.dia_operativo(i.paid_at)) end,
      -- Cobrada a tiempo con la regla canónica (metricas.a_tiempo: el día del
      -- reporte, como mucho el vencimiento más los días de gracia).
      'on_time', case when i.status = 'paid' then
        metricas.a_tiempo(coalesce(metricas.dia_operativo(pr.created_at),
                                   metricas.dia_operativo(i.paid_at)), i.due_date) end
    ) order by i.due_date, i.sequence)
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    join public.merchants m on m.id = ch.merchant_id
    left join public.payment_reports pr on pr.id = i.paid_by_report_id
    where i.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('charges', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ch.id,
      'order_number', ch.order_number,
      'amount_usd', ch.amount_usd,
      'status', ch.status,
      'business_date', ch.business_date,
      'confirmed_at', ch.confirmed_at,
      'merchant_name', m.name,
      'branch_name', b.name,
      'void_reason', ch.void_reason,
      -- El consumo entero, sin el servicio de Ronda (amount_usd lo lleva).
      'financed_usd', coalesce(ch.base_usd, ch.amount_usd),
      'merchant_id', ch.merchant_id
    ) order by ch.created_at desc)
    from public.charges ch
    join public.merchants m on m.id = ch.merchant_id
    join public.merchant_branches b on b.id = ch.branch_id
    where ch.user_id = p_user_id
  ), '[]'::jsonb));

  -- Los consumos en los que ESTÁ: los que puso (charges.user_id) y aquellos en
  -- los que tiene cuotas. En un grupo el cargo es de quien abrió la cuenta y
  -- las cuotas son de cada quien, así que `charges` (arriba) se queda corto.
  -- Todo en financed: la cuenta entera y su parte (la suma de sus cuotas).
  v_result := v_result || jsonb_build_object('consumos', coalesce((
    with mias as (
      select i.charge_id, sum(i.financed_usd) as parte
      from public.installments i
      where i.user_id = p_user_id
      group by i.charge_id
    ),
    ids as (
      select ch.id from public.charges ch where ch.user_id = p_user_id
      union
      select mias.charge_id from mias
    )
    select jsonb_agg(jsonb_build_object(
      'charge_id', ch.id,
      'order_number', ch.order_number,
      'status', ch.status,
      'business_date', ch.business_date,
      'created_at', ch.created_at,
      'confirmed_at', ch.confirmed_at,
      'void_reason', ch.void_reason,
      'merchant_id', ch.merchant_id,
      'merchant_name', m.name,
      'group_id', ch.group_id,
      'is_group', ch.group_id is not null,
      'started_it', coalesce(ch.user_id = p_user_id, false),
      'financed_usd', coalesce(ch.base_usd, ch.amount_usd),
      'share_financed_usd', mi.parte
    ) order by ch.created_at desc)
    from ids
    join public.charges ch on ch.id = ids.id
    join public.merchants m on m.id = ch.merchant_id
    left join mias mi on mi.charge_id = ch.id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('payments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'status', pr.status,
      'bank', pr.bank,
      'reference', pr.reference,
      'method', pr.method,
      'amount_usd', q.amount_usd,
      'amount_ves', q.amount_ves,
      'rejection_note', pr.rejection_note,
      'created_at', pr.created_at,
      -- amount_usd = cuotas (consumo + service fee) + cargos por atraso. Sus
      -- sumandos, para no enseñar un total con el fee sin desglose.
      'cuotas_payable_usd', coalesce(it.payable, 0),
      'cuotas_financed_usd', coalesce(it.financed, 0),
      'cuotas_fee_usd', coalesce(it.payable, 0) - coalesce(it.financed, 0),
      'late_fees_usd', coalesce(lf.cargos, 0)
    ) order by pr.created_at desc)
    from public.payment_reports pr
    join public.payment_quotes q on q.id = pr.quote_id
    left join lateral (
      select sum(qi.amount_usd) as payable, sum(i.financed_usd) as financed
      from public.payment_quote_items qi
      join public.installments i on i.id = qi.installment_id
      where qi.quote_id = q.id
    ) it on true
    left join lateral (
      select sum(qf.amount_usd) as cargos
      from public.payment_quote_late_fees qf
      where qf.quote_id = q.id
    ) lf on true
    where pr.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('level_changes', coalesce((
    select jsonb_agg(jsonb_build_object(
      'from_level', lc.from_level,
      'to_level', lc.to_level,
      'reason', lc.reason,
      'note', lc.note,
      'actor', lc.actor,
      'created_at', lc.created_at
    ) order by lc.created_at desc)
    from public.level_changes lc
    where lc.user_id = p_user_id
  ), '[]'::jsonb));

  -- PODA (Helios): la verificación de identidad (`kyc.verifications`), los
  -- Bits (`bits_entries`) y los aparatos de la app (`user_devices`) se fueron
  -- con la app. Las claves se quedan vacías para no cambiar la forma.
  v_result := v_result || jsonb_build_object(
    'kyc', null::jsonb,
    'bits', null::jsonb,
    'bits_entries', '[]'::jsonb,
    'devices', '[]'::jsonb
  );

  -- Helios (docs/01 §2.4): la ficha del paciente.
  v_result := v_result || jsonb_build_object('datos', public.helios_patient_datos(p_user_id));

  return v_result;
end;
$function$
;
