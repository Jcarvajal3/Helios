-- ============================================================================
-- Helios — El contacto de Helios se configura (H11, docs/00 §4.4)
--
-- 1. `platform_contact`: una sola fila con el WhatsApp de Helios, el correo y
--    el horario de soporte, y el remitente de los correos. La edita un super
--    admin (`admin_set_platform_contact`) y queda en la bitácora. Los mensajes
--    la leen para `{whatsapp_helios}` (H7) y el comprobante (H6).
-- 2. `helios_config_status()`: lo que falta configurar, para el aviso de
--    «configuración incompleta» del Inicio (docs/01 §2.3). Para Resend mira
--    solo si EXISTE un secreto `resend_api_key` en Vault, por su nombre: nunca
--    lee el valor.
-- 3. `payment_destinations` (las cuentas de cobro de Helios): en Ronda había
--    una sola activa (Pago Móvil). En Helios puede haber VARIAS activas a la
--    vez —Pago Móvil, transferencia, Zelle— con su orden de aparición. Se va
--    el índice único de «una activa», entran `method`, `account_number`,
--    `email` y `sort_order`, y cada método exige sus datos (check).
--    `admin_set_payment_destination` gana `p_sort_order` y `p_is_active`
--    (docs/01 §2.3) y además `p_id` (para editar o apagar una cuenta
--    existente: sin él, cada llamada crea otra), `p_method`,
--    `p_account_number` y `p_email`. Dar de alta una cuenta ya NO apaga las
--    demás. `admin_payment_destinations()` devuelve las columnas nuevas.
--    `helios_quote_installments` y `report_payment`, que tomaban «la» activa
--    con un `limit 1` sin orden, toman la primera por `sort_order`.
-- 4. `helios_payment_accounts_text()`: las cuentas activas en texto, para
--    `{cuentas_de_cobro}`. Si no hay ninguna: «Helios te escribirá por
--    WhatsApp con las instrucciones de pago» (docs/00 §4.4 H11).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El contacto de Helios
-- ---------------------------------------------------------------------------

create table public.platform_contact (
  id              boolean primary key default true check (id),
  whatsapp_number text check (whatsapp_number is null or whatsapp_number ~ '^\+[0-9]{8,15}$'),
  support_email   text check (support_email is null or public.helios_valid_email(support_email)),
  support_hours   text,
  sender_name     text,
  sender_email    text check (sender_email is null or public.helios_valid_email(sender_email)),
  updated_by      uuid references auth.users(id),
  updated_at      timestamptz not null default now()
);

comment on table public.platform_contact is
  'Una sola fila: WhatsApp de Helios, soporte y remitente de los correos. La edita un super admin con admin_set_platform_contact.';

insert into public.platform_contact (id, sender_name) values (true, 'Helios');

alter table public.platform_contact enable row level security;
revoke all on public.platform_contact from anon, authenticated;
grant select on public.platform_contact to authenticated;

create policy platform_contact_read_admin on public.platform_contact
  for select to authenticated
  using ((select public.is_platform_admin()));

/** Un WhatsApp en E.164: móvil VE normalizado, u otro número internacional. */
create or replace function public.helios_normalize_whatsapp(p_phone text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select coalesce(
    public.helios_normalize_ve_mobile(p_phone),
    case when regexp_replace(coalesce(p_phone, ''), '[\s().-]', '', 'g') ~ '^\+[1-9][0-9]{7,14}$'
         then regexp_replace(p_phone, '[\s().-]', '', 'g') end
  );
$$;

revoke all on function public.helios_normalize_whatsapp(text) from public, anon;
grant execute on function public.helios_normalize_whatsapp(text) to authenticated;

create or replace function public.admin_platform_contact()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v public.platform_contact%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v from public.platform_contact where id;

  return jsonb_build_object(
    'whatsapp_number', v.whatsapp_number,
    'support_email',   v.support_email,
    'support_hours',   v.support_hours,
    'sender_name',     v.sender_name,
    'sender_email',    v.sender_email,
    'updated_at',      v.updated_at,
    'updated_by_name', (select full_name from public.platform_admins where user_id = v.updated_by)
  );
end;
$$;

/**
 * Cambia el contacto de Helios. Solo cambian las claves que vienen en `p`
 * (`whatsapp_number`, `support_email`, `support_hours`, `sender_name`,
 * `sender_email`); una clave con null o '' se borra. Solo super admin, con
 * bitácora (antes y después).
 */
create or replace function public.admin_set_platform_contact(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := public.helios_assert_super_admin('cambiar el contacto de Helios');
  v_antes public.platform_contact%rowtype;
  v_new   public.platform_contact%rowtype;
  v_txt   text;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Faltan los datos' using errcode = '22023';
  end if;

  select * into v_antes from public.platform_contact where id for update;
  v_new := v_antes;

  if p ? 'whatsapp_number' then
    v_txt := nullif(btrim(coalesce(p->>'whatsapp_number', '')), '');
    v_new.whatsapp_number := public.helios_normalize_whatsapp(v_txt);
    if v_txt is not null and v_new.whatsapp_number is null then
      raise exception 'Número de WhatsApp inválido' using errcode = '22023';
    end if;
  end if;

  if p ? 'support_email' then
    v_new.support_email := nullif(lower(btrim(coalesce(p->>'support_email', ''))), '');
    if v_new.support_email is not null and not public.helios_valid_email(v_new.support_email) then
      raise exception 'Correo de soporte inválido' using errcode = '22023';
    end if;
  end if;

  if p ? 'sender_email' then
    v_new.sender_email := nullif(lower(btrim(coalesce(p->>'sender_email', ''))), '');
    if v_new.sender_email is not null and not public.helios_valid_email(v_new.sender_email) then
      raise exception 'Correo del remitente inválido' using errcode = '22023';
    end if;
  end if;

  if p ? 'support_hours' then
    v_new.support_hours := nullif(btrim(coalesce(p->>'support_hours', '')), '');
  end if;

  if p ? 'sender_name' then
    v_new.sender_name := nullif(btrim(coalesce(p->>'sender_name', '')), '');
  end if;

  update public.platform_contact
     set whatsapp_number = v_new.whatsapp_number,
         support_email   = v_new.support_email,
         support_hours   = v_new.support_hours,
         sender_name     = v_new.sender_name,
         sender_email    = v_new.sender_email,
         updated_by      = v_actor,
         updated_at      = now()
   where id;

  perform audit.log(v_actor, 'platform.contact_set', null, jsonb_build_object(
    'antes',   to_jsonb(v_antes) - 'id' - 'updated_by' - 'updated_at',
    'despues', to_jsonb(v_new)   - 'id' - 'updated_by' - 'updated_at'
  ));

  return public.admin_platform_contact();
end;
$$;

revoke all on function public.admin_platform_contact()          from public, anon;
revoke all on function public.admin_set_platform_contact(jsonb) from public, anon;
grant execute on function public.admin_platform_contact()          to authenticated;
grant execute on function public.admin_set_platform_contact(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Varias cuentas de cobro activas
-- ---------------------------------------------------------------------------

drop index public.payment_destinations_one_active;

alter table public.payment_destinations
  add column method         text not null default 'pago_movil'
                            check (method in ('pago_movil', 'transferencia', 'zelle')),
  add column account_number text,
  add column email          text,
  add column sort_order     integer not null default 100,
  add column updated_at     timestamptz not null default now();

alter table public.payment_destinations
  alter column bank_name drop not null,
  alter column rif       drop not null,
  alter column phone     drop not null;

alter table public.payment_destinations
  add constraint payment_destinations_datos_del_metodo check (
    case method
      when 'pago_movil'    then bank_name is not null and rif is not null and phone is not null
      when 'transferencia' then bank_name is not null and rif is not null
                                and account_number is not null and holder_name is not null
      when 'zelle'         then email is not null and holder_name is not null
    end
  );

create index payment_destinations_activas_idx on public.payment_destinations (sort_order, created_at)
  where is_active;

comment on table public.payment_destinations is
  'Cuentas de cobro de Helios (a dónde paga el paciente). Puede haber varias activas; se listan por sort_order.';

drop function public.admin_set_payment_destination(text, text, text, text, text);

/**
 * Crea (sin `p_id`) o edita (con `p_id`) una cuenta de cobro. Cada método
 * exige sus datos: Pago Móvil banco, RIF/C.I. y teléfono; transferencia
 * banco, RIF/C.I., número de cuenta y titular; Zelle correo y titular. Crear
 * una ya NO apaga las demás. `p_is_active = false` la retira de los mensajes.
 * Solo super admin, con bitácora.
 */
create function public.admin_set_payment_destination(
  p_bank_name      text,
  p_rif            text,
  p_phone          text,
  p_holder_name    text    default null,
  p_note           text    default null,
  p_sort_order     integer default null,
  p_is_active      boolean default true,
  p_id             uuid    default null,
  p_method         text    default 'pago_movil',
  p_account_number text    default null,
  p_email          text    default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor   uuid := auth.uid();
  v_id      uuid;
  v_method  text := coalesce(nullif(btrim(p_method), ''), 'pago_movil');
  v_bank    text := nullif(btrim(coalesce(p_bank_name, '')), '');
  v_rif     text := nullif(btrim(coalesce(p_rif, '')), '');
  v_phone   text := nullif(btrim(coalesce(p_phone, '')), '');
  v_holder  text := nullif(btrim(coalesce(p_holder_name, '')), '');
  v_account text := nullif(regexp_replace(coalesce(p_account_number, ''), '\D', '', 'g'), '');
  v_email   text := nullif(lower(btrim(coalesce(p_email, ''))), '');
begin
  perform public.helios_assert_super_admin('cambiar las cuentas de cobro');

  if v_method not in ('pago_movil', 'transferencia', 'zelle') then
    raise exception 'Método de cobro no válido: %', v_method using errcode = '22023';
  end if;

  if v_method = 'pago_movil' and (v_bank is null or v_rif is null or v_phone is null) then
    raise exception 'Banco, RIF y teléfono son obligatorios' using errcode = '22023';
  end if;

  if v_method = 'transferencia'
     and (v_bank is null or v_rif is null or v_account is null or v_holder is null) then
    raise exception 'Banco, RIF, número de cuenta y titular son obligatorios' using errcode = '22023';
  end if;

  if v_method = 'transferencia' and v_account !~ '^[0-9]{20}$' then
    raise exception 'El número de cuenta tiene 20 dígitos' using errcode = '22023';
  end if;

  if v_method = 'zelle' and (v_email is null or v_holder is null) then
    raise exception 'Correo y titular son obligatorios' using errcode = '22023';
  end if;

  if v_email is not null and not public.helios_valid_email(v_email) then
    raise exception 'Correo inválido' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.payment_destinations
      (method, bank_name, rif, phone, holder_name, account_number, email, is_active, sort_order)
    values (v_method, v_bank, v_rif, v_phone, v_holder, v_account, v_email,
            coalesce(p_is_active, true), coalesce(p_sort_order, 100))
    returning id into v_id;
  else
    update public.payment_destinations
       set method         = v_method,
           bank_name      = v_bank,
           rif            = v_rif,
           phone          = v_phone,
           holder_name    = v_holder,
           account_number = v_account,
           email          = v_email,
           is_active      = coalesce(p_is_active, is_active),
           sort_order     = coalesce(p_sort_order, sort_order),
           updated_at     = now()
     where id = p_id
    returning id into v_id;

    if v_id is null then
      raise exception 'Cuenta de cobro no encontrada' using errcode = 'P0002';
    end if;
  end if;

  perform audit.log(v_actor, 'payment_destination.set', v_id, jsonb_build_object(
    'method', v_method, 'bank_name', v_bank, 'rif', v_rif, 'phone', v_phone,
    'holder_name', v_holder, 'account_number', v_account, 'email', v_email,
    'is_active', coalesce(p_is_active, true), 'sort_order', p_sort_order,
    'edit', p_id is not null, 'note', nullif(trim(p_note), '')
  ));

  return v_id;
end;
$$;

revoke all on function public.admin_set_payment_destination(text, text, text, text, text, integer, boolean, uuid, text, text, text) from public, anon;
grant execute on function public.admin_set_payment_destination(text, text, text, text, text, integer, boolean, uuid, text, text, text) to authenticated;

drop function public.admin_payment_destinations();

create function public.admin_payment_destinations()
returns table(
  id uuid, bank_name text, rif text, phone text, holder_name text, is_active boolean,
  created_at timestamptz, report_count integer,
  method text, account_number text, email text, sort_order integer
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

  return query
  select d.id, d.bank_name, d.rif, d.phone, d.holder_name, d.is_active, d.created_at,
         coalesce(r.cnt, 0)::integer,
         d.method, d.account_number, d.email, d.sort_order
  from public.payment_destinations d
  left join (
    select destination_id as did, count(*)::integer as cnt
    from public.payment_reports where destination_id is not null group by 1
  ) r on r.did = d.id
  order by d.is_active desc, d.sort_order, d.created_at desc;
end;
$$;

revoke all on function public.admin_payment_destinations() from public, anon;
grant execute on function public.admin_payment_destinations() to authenticated;

/** «+584141234567» → «0414-1234567». Null si no es un móvil venezolano. */
create or replace function public.helios_format_ve_phone(p_phone text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select '0' || substr(e, 4, 3) || '-' || substr(e, 7)
  from (select public.helios_normalize_ve_mobile(p_phone) as e) x
  where e is not null;
$$;

revoke all on function public.helios_format_ve_phone(text) from public, anon;
grant execute on function public.helios_format_ve_phone(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Las cuentas de cobro en texto
-- ---------------------------------------------------------------------------

/**
 * Las cuentas de cobro activas, una por línea, para `{cuentas_de_cobro}`.
 * Si no hay ninguna, el texto de reserva de docs/00 §4.4 (H11).
 */
create or replace function public.helios_payment_accounts_text()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    string_agg(
      case d.method
        when 'pago_movil' then
          format('• Pago Móvil: %s · %s · %s%s', d.bank_name, d.rif,
                 coalesce(public.helios_format_ve_phone(d.phone), d.phone),
                 coalesce(' · ' || d.holder_name, ''))
        when 'transferencia' then
          format('• Transferencia: %s · Cuenta %s · %s · %s', d.bank_name, d.account_number,
                 d.holder_name, d.rif)
        when 'zelle' then
          format('• Zelle: %s · %s', d.email, d.holder_name)
      end,
      E'\n' order by d.sort_order, d.created_at),
    'Helios te escribirá por WhatsApp con las instrucciones de pago.')
  from public.payment_destinations d
  where d.is_active;
$$;

revoke all on function public.helios_payment_accounts_text() from public, anon;
grant execute on function public.helios_payment_accounts_text() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Qué falta configurar
-- ---------------------------------------------------------------------------

/**
 * `{whatsapp, cuentas_de_cobro, resend, remitente}` (docs/01 §2.3). `resend`
 * dice si existe en Vault un secreto llamado `resend_api_key`: se busca por
 * NOMBRE en `vault.secrets` y jamás se lee ni se descifra el valor.
 */
create or replace function public.helios_config_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v public.platform_contact%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v from public.platform_contact where id;

  return jsonb_build_object(
    'whatsapp',         v.whatsapp_number is not null,
    'cuentas_de_cobro', (select count(*)::integer from public.payment_destinations where is_active),
    'resend',           exists (select 1 from vault.secrets s where s.name = 'resend_api_key'),
    'remitente',        v.sender_email is not null and v.sender_name is not null
  );
end;
$$;

revoke all on function public.helios_config_status() from public, anon;
grant execute on function public.helios_config_status() to authenticated;

-- ---------------------------------------------------------------------------
-- 3b. La cotización y el reporte toman la primera cuenta activa por orden
-- ---------------------------------------------------------------------------
-- Copiadas de la base (pg_get_functiondef, 2026-09-30) con el `limit 1`
-- ordenado y nada más. `report_payment` conserva sus permisos (ninguno para la
-- API, H3).

-- ── public.helios_quote_installments
CREATE OR REPLACE FUNCTION public.helios_quote_installments(p_user uuid, p_installment_ids uuid[], p_ignore_open_report boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user       uuid := p_user;
  v_bd         date := public.helios_business_date(now());
  v_left       integer;
  v_rate       numeric(18,6);
  v_total_usd  numeric(18,4);
  v_count      integer;
  v_fee_ids    uuid[];
  v_fee_usd    numeric(18,4) := 0;
  v_grand_usd  numeric(18,4);
  v_quote      public.payment_quotes%rowtype;
begin
  if v_user is null then
    raise exception 'Falta de quién es el pago' using errcode = '22023';
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
  if not p_ignore_open_report and exists (
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

  -- Lo que vence hoy o antes va primero: adelantar una cuota exige llevar
  -- todas las que vencen hoy o antes y se pueden pagar.
  if exists (
    select 1 from public.installments
    where id = any(p_installment_ids) and due_date > v_bd
  ) then
    select count(*) into v_left
    from public.installments i
    where i.user_id = v_user
      and i.status = 'pending'
      and i.due_date <= v_bd
      and not (i.id = any(p_installment_ids))
      and not exists (
        select 1
        from public.payment_quote_items qi
        join public.payment_reports r on r.quote_id = qi.quote_id
        where qi.installment_id = i.id
          and r.status in ('reported', 'in_review')
      );

    if v_left > 0 then
      if p_ignore_open_report then
        -- El panel: quien asigna el abono no es quien debe.
        raise exception
          'Esta persona tiene % cuota(s) que vencen hoy o antes y no están en la selección: para adelantar una cuota hay que incluirlas.',
          v_left using errcode = '22023';
      end if;

      raise exception
        'Tienes una cuota que vence hoy o antes. Inclúyela en este pago para poder adelantar las siguientes.'
        using errcode = '22023';
    end if;
  end if;

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

  -- El detalle de los cargos, con su importe congelado.
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
    -- Cuántos son: deja escribir "2 cargos por mora" en vez de una cifra
    -- suelta que ya no se explica sola.
    'late_fee_count', coalesce(array_length(v_fee_ids, 1), 0),
    'valid_until', v_quote.valid_until,
    'destination', (
      select jsonb_build_object(
        'bank_name', bank_name, 'rif', rif, 'phone', phone, 'holder_name', holder_name
      )
      from public.payment_destinations where is_active
      -- Helios (H11): puede haber varias activas; va la primera por orden.
      order by sort_order, created_at limit 1
    )
  );
end;
$function$
;

-- ── public.report_payment
CREATE OR REPLACE FUNCTION public.report_payment(p_quote_id uuid, p_method text, p_bank text, p_reference text, p_payer_document text DEFAULT NULL::text, p_payer_phone text DEFAULT NULL::text, p_receipt_path text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user      uuid := auth.uid();
  v_quote     public.payment_quotes%rowtype;
  v_dest      uuid;
  v_duplicate boolean;
  v_status    public.payment_report_status;
  v_row       public.payment_reports%rowtype;
  v_early     integer;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_quote from public.payment_quotes where id = p_quote_id for update;
  if not found or v_quote.user_id <> v_user then
    raise exception 'Cotización no encontrada' using errcode = 'P0002';
  end if;

  if v_quote.valid_until < now() then
    raise exception 'La cotización venció, vuelve a cotizar' using errcode = '22023';
  end if;

  if p_method <> 'efectivo' and (p_reference is null or length(trim(p_reference)) = 0) then
    raise exception 'La referencia es obligatoria para %', p_method using errcode = '22023';
  end if;

  if exists (
    select 1 from public.payment_reports r
    join public.payment_quote_items i on i.quote_id = r.quote_id
    join public.payment_quote_items j on j.installment_id = i.installment_id
    where j.quote_id = p_quote_id and r.status in ('reported', 'in_review')
  ) then
    raise exception
      'Ya reportaste un pago para alguna de esas cuotas y está en revisión. Te avisamos en cuanto lo confirmemos.'
      using errcode = '22023';
  end if;

  -- Helios (H11): puede haber varias activas; va la primera por orden.
  select id into v_dest from public.payment_destinations where is_active
  order by sort_order, created_at limit 1;

  -- Coincidencia de referencia: sospechosa, no concluyente. Va a revisión.
  v_duplicate := p_reference is not null and exists (
    select 1 from public.payment_reports
    where bank = p_bank and reference = p_reference and status <> 'rejected'
  );

  v_status := case when v_duplicate then 'in_review' else 'reported' end;

  insert into public.payment_reports (
    quote_id, user_id, method, bank, reference,
    payer_document, payer_phone, destination_id, receipt_path, status,
    rejection_note
  )
  values (
    p_quote_id, v_user, p_method, p_bank, p_reference,
    p_payer_document, p_payer_phone, v_dest, p_receipt_path, v_status,
    case when v_duplicate
      then 'Referencia repetida: revisar contra el estado de cuenta antes de aprobar.'
      else null end
  )
  returning * into v_row;

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- Cuántas de las cuotas de este pago son ADELANTO. PODA (Helios): el premio
  -- en Bits que se calculaba aquí se fue con los Bits; `bits_pending` queda
  -- en 0 para no cambiar la forma de la respuesta.
  select
    count(*) filter (where i.due_date > public.helios_business_date(v_row.created_at))
  into v_early
  from public.payment_quote_items qi
  join public.installments i on i.id = qi.installment_id
  join public.charges ch on ch.id = i.charge_id
  where qi.quote_id = p_quote_id;
  -- ─────────────────────────────────────────────────────────────────────────

  return jsonb_build_object(
    'report_id', v_row.id,
    'status', v_row.status,
    'amount_usd', v_quote.amount_usd,
    'amount_ves', v_quote.amount_ves,
    'installment_count', v_quote.installment_count,
    'reported_at', v_row.created_at,
    'early_count', v_early,
    -- NUEVO
    'bits_pending', 0
  );
end;
$function$
;

