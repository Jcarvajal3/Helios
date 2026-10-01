-- ============================================================================
-- Helios — Los avisos los manda una persona (H7, docs/00 §4.4 y §7.2)
--
-- Ronda mandaba 12 avisos push por cada fecha de vencimiento, cada uno con su
-- cron (`notify_reminder_loop` → `notifications` → push). Helios no tiene
-- app: los avisos salen por WhatsApp, a mano, desde la cola diaria
-- «Avisos de hoy» del superadmin, y son 5 momentos por fecha (decidido):
--
--   | Momento              | Plantilla             | Canal                  | Hora (Caracas) |
--   |----------------------|-----------------------|------------------------|----------------|
--   | Víspera              | `cuota_manana`        | whatsapp_manual + email| 19:00          |
--   | Día del vencimiento  | `cuota_hoy`           | whatsapp_manual        | 08:00          |
--   | +1 día               | `cuota_vencida_d1`    | whatsapp_manual        | 08:05          |
--   | +4 días              | `cargo_por_atraso_d4` | whatsapp_manual        | 10:30 (*)      |
--   | +7 días              | —                     | pasa a Cobranza        | —              |
--
--   (*) Detrás del motor de mora (10:05), que es quien cobra el cargo de $2:
--   el aviso solo sale para las cuotas que YA tienen su cargo, y su monto lo
--   incluye. Si el cargo está apagado (`late_fee_usd = 0`) no sale.
--   El +7 no tiene mensaje: esa persona ya está en `admin_collections`
--   (tramo «congelado» desde el día 1) y la gestiona Cobranza.
--
-- 1. Los 12 crons de Ronda se van (corrían sin hacer nada desde que
--    20261002000700 apagó sus plantillas) y sus plantillas pierden el
--    `cron_job`. Entran 4: `helios_aviso_<plantilla>`, a la hora de
--    `notification_templates.run_at`. `lead_days` y `run_at` se siguen
--    editando desde el panel: `admin_set_notification_schedule` reprograma
--    el cron.
-- 2. `helios_enqueue_reminders(p_key, p_today)`: un mensaje por paciente y
--    fecha de vencimiento (si tiene dos financiamientos que vencen el mismo
--    día, un solo mensaje con la suma y los dos números de orden), con
--    `dedupe_key` = plantilla:canal:paciente:fecha, así que correrlo dos
--    veces no duplica nada. No avisa de una cuota con un pago registrado
--    esperando conciliación (el paciente ya hizo lo suyo).
-- 3. Un pago registrado o conciliado CANCELA los avisos pendientes de las
--    fechas que cubre (`cancelado`): nadie tiene que acordarse de no mandar
--    «tu cuota vence hoy» a quien pagó ayer. Lo hace un trigger en
--    `payment_reports`, así cubre también el abono asignado.
-- 4. `pago_recibido` al conciliar, `pago_rechazado` al rechazar (trigger de
--    `payment_reports`, el mismo `notify_payment_result` de Ronda llevado a la
--    cola), `cuenta_congelada` cuando el motor de mora congela la cuenta (solo
--    en el paso activa → congelada; al descongelarse, el que no se mandó se
--    cancela). Un mensaje que no se puede encolar NUNCA tumba el pago ni la
--    mora: queda un WARNING.
-- 5. La cola del equipo: `admin_outbound_queue`, `admin_mark_outbound`
--    (`enviado` también anota la gestión en `collection_contacts`, canal
--    whatsapp) y `admin_outbound_history` (incluye los correos, con su estado
--    en Resend). docs/01 §2.2.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Fuera los 12 crons de Ronda
-- ---------------------------------------------------------------------------

do $cron$
declare
  v_job text;
begin
  foreach v_job in array array[
    'helios_installment_reminders', 'helios_installment_due_d3',
    'helios_installment_due_tomorrow', 'helios_installment_due_today',
    'helios_installment_due_today_evening',
    'helios_installment_late_d1', 'helios_installment_late_d2', 'helios_installment_late_d3',
    'helios_installment_late_d4', 'helios_installment_late_d5', 'helios_installment_late_d6',
    'helios_installment_late_d7',
    'helios_aviso_cuota_manana', 'helios_aviso_cuota_hoy',
    'helios_aviso_cuota_vencida_d1', 'helios_aviso_cargo_por_atraso_d4'
  ] loop
    begin
      perform cron.unschedule(v_job);
    exception when others then
      null;
    end;
  end loop;
end;
$cron$;

update public.notification_templates
   set cron_job = null
 where 'app' = any (channels) and cron_job is not null;

update public.notification_templates
   set cron_job = 'helios_aviso_' || key,
       run_at = case key
                  when 'cuota_manana'        then coalesce(run_at, time '19:00')
                  when 'cuota_hoy'           then coalesce(run_at, time '08:00')
                  when 'cuota_vencida_d1'    then coalesce(run_at, time '08:05')
                  when 'cargo_por_atraso_d4' then coalesce(run_at, time '10:30')
                end,
       lead_days = case key
                     when 'cuota_manana'        then coalesce(lead_days, 1)
                     when 'cuota_hoy'           then 0
                     when 'cuota_vencida_d1'    then coalesce(lead_days, 1)
                     when 'cargo_por_atraso_d4' then coalesce(lead_days, 4)
                   end,
       trigger_label = case key
                         when 'cuota_manana'        then 'La víspera del vencimiento'
                         when 'cuota_hoy'           then 'El día del vencimiento'
                         when 'cuota_vencida_d1'    then 'Al día siguiente del vencimiento'
                         when 'cargo_por_atraso_d4' then 'Cuando se cobra el cargo por atraso (tras los días de gracia)'
                       end
 where key in ('cuota_manana', 'cuota_hoy', 'cuota_vencida_d1', 'cargo_por_atraso_d4');

-- ---------------------------------------------------------------------------
-- 2. El momento de cada aviso
-- ---------------------------------------------------------------------------

/**
 * Días entre el vencimiento y el aviso: negativo antes (víspera = -1), 0 el
 * día, positivo después. Lee `lead_days` de la plantilla. Conserva las claves
 * de Ronda (sus plantillas quedan apagadas y sin cron).
 */
create or replace function public.helios_reminder_offset(p_key text)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_lead integer;
begin
  select lead_days into v_lead from public.notification_templates where key = p_key;

  case p_key
    when 'cuota_manana'        then return -greatest(coalesce(v_lead, 1), 1);
    when 'cuota_hoy'           then return 0;
    when 'cuota_vencida_d1'    then return greatest(coalesce(v_lead, 1), 1);
    when 'cargo_por_atraso_d4' then return greatest(coalesce(v_lead, 4), 1);
    -- Ronda (apagadas):
    when 'installment_due_d3'  then return -coalesce(v_lead, 3);
    when 'installment_due'     then return -coalesce(v_lead, 2);
    when 'installment_due_tomorrow' then return -coalesce(v_lead, 1);
    when 'installment_due_today', 'installment_due_today_evening' then return 0;
    else null;
  end case;

  if v_lead is null or v_lead < 1 then
    raise exception 'El aviso % no tiene un día de atraso configurado', p_key
      using errcode = '22023';
  end if;

  return v_lead;
end;
$$;

/**
 * Cancela los avisos de cuota PENDIENTES de un paciente cuyas fechas ya no
 * tienen nada que avisar: todas sus cuotas de esa fecha están pagadas o con
 * un pago registrado esperando conciliación. Devuelve cuántos canceló.
 */
create or replace function public.helios_cancel_covered_reminders(p_profile_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n integer;
begin
  update public.outbound_messages o
     set status = 'cancelado',
         last_error = 'Ya pagó o registró el pago de las cuotas de esa fecha',
         next_attempt_at = null
   where o.profile_id = p_profile_id
     and o.status = 'pendiente'
     and o.template_key in ('cuota_manana', 'cuota_hoy', 'cuota_vencida_d1', 'cargo_por_atraso_d4')
     and o.installment_due_date is not null
     and not exists (
       select 1
       from public.installments i
       where i.user_id = p_profile_id
         and i.due_date = o.installment_due_date
         and i.status = 'pending'
         and not exists (
           select 1
           from public.payment_quote_items qi
           join public.payment_reports r on r.quote_id = qi.quote_id
           where qi.installment_id = i.id
             and r.status in ('reported', 'in_review')
         )
     );
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function public.helios_cancel_covered_reminders(uuid) from public, anon, authenticated;

/**
 * Encola los avisos de un momento (`cuota_manana`, `cuota_hoy`,
 * `cuota_vencida_d1`, `cargo_por_atraso_d4`) para el día operativo `p_today`
 * (por defecto hoy, a medianoche de Caracas). Un mensaje por paciente,
 * fecha y canal de la plantilla; `dedupe_key` evita repetirlo. Devuelve
 * `{key, due_date, enqueued, skipped?}`.
 */
create or replace function public.helios_enqueue_reminders(p_key text, p_today date default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tpl     public.notification_templates%rowtype;
  v_today   date := coalesce(p_today, public.helios_business_date(now()));
  v_offset  integer;
  v_due     date;
  v_row     record;
  v_channel text;
  v_id      uuid;
  v_new     integer := 0;
  v_errors  integer := 0;
  v_before  integer;
begin
  if p_key is null or p_key not in ('cuota_manana', 'cuota_hoy', 'cuota_vencida_d1', 'cargo_por_atraso_d4') then
    raise exception 'No es un aviso de cuota: %', coalesce(p_key, 'null') using errcode = '22023';
  end if;

  select * into v_tpl from public.notification_templates where key = p_key;
  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = 'P0002';
  end if;

  v_offset := public.helios_reminder_offset(p_key);
  v_due    := v_today - v_offset;

  -- Apagado es apagado: ni siquiera filas `omitido` en la cola del día.
  if not v_tpl.enabled then
    return jsonb_build_object('key', p_key, 'due_date', v_due, 'enqueued', 0, 'skipped', 'apagada');
  end if;

  select count(*) into v_before from public.outbound_messages
  where template_key = p_key and installment_due_date = v_due;

  for v_row in
    with cuotas as (
      select
        i.id, i.user_id, i.charge_id, i.amount_usd,
        c.order_number, m.id as merchant_id, m.name as merchant_name,
        coalesce((select sum(f.amount_usd) from public.late_fees f
                   where f.installment_id = i.id and f.status = 'pending'), 0) as fee_usd
      from public.installments i
      join public.charges c   on c.id = i.charge_id
      join public.merchants m on m.id = c.merchant_id
      where i.status = 'pending'
        and i.due_date = v_due
        and c.status = 'confirmed'
        -- Con un pago registrado esperando conciliación no se avisa.
        and not exists (
          select 1
          from public.payment_quote_items qi
          join public.payment_reports r on r.quote_id = qi.quote_id
          where qi.installment_id = i.id
            and r.status in ('reported', 'in_review')
        )
    )
    select
      q.user_id,
      p.email, p.email_invalid_at, p.phone_e164,
      sum(q.amount_usd + q.fee_usd)                     as monto,
      count(distinct q.charge_id)                       as cargos,
      min(q.charge_id::text)::uuid                      as un_cargo,
      string_agg(distinct q.order_number::text, ', #')  as ordenes,
      count(distinct q.merchant_id)                     as clinicas,
      min(q.merchant_name)                              as una_clinica
    from cuotas q
    join public.profiles p on p.id = q.user_id
    -- El aviso del cargo solo sale si el cargo ya se cobró.
    where p_key <> 'cargo_por_atraso_d4' or q.fee_usd > 0
    group by q.user_id, p.email, p.email_invalid_at, p.phone_e164
    order by q.user_id
  loop
    foreach v_channel in array v_tpl.channels loop
      continue when v_channel not in ('whatsapp_manual', 'email');
      -- El correo de la víspera es un extra automático: sin correo válido no
      -- se encola nada (el WhatsApp sí).
      continue when v_channel = 'email' and (v_row.email is null or v_row.email_invalid_at is not null);

      begin
        v_id := public.helios_enqueue_message(
          p_key, v_row.user_id,
          case when v_row.cargos = 1 then v_row.un_cargo end,
          v_channel,
          jsonb_build_object(
            'clinica', case when v_row.clinicas = 1 then v_row.una_clinica
                            else format('%s clínicas', v_row.clinicas) end,
            'orden', v_row.ordenes,
            'monto_cuota', public.helios_money_text(v_row.monto),
            'fecha', public.helios_weekday_es(v_due) || ' ' || to_char(v_due, 'DD/MM')
          ),
          v_due,
          format('%s:%s:%s:%s', p_key, v_channel, v_row.user_id, v_due)
        );
      exception when others then
        -- Un paciente con un dato raro no puede dejar sin aviso a los demás.
        v_errors := v_errors + 1;
        raise warning 'Aviso % de % no encolado: %', p_key, v_row.user_id, sqlerrm;
      end;
    end loop;
  end loop;

  select count(*) - v_before into v_new from public.outbound_messages
  where template_key = p_key and installment_due_date = v_due;

  return jsonb_build_object('key', p_key, 'due_date', v_due, 'enqueued', v_new, 'errors', v_errors);
end;
$$;

comment on function public.helios_enqueue_reminders(text, date) is
  'Encola en outbound_messages los avisos de cuota de un momento (docs/00 §7.2). La llaman los crons helios_aviso_*.';

revoke all on function public.helios_enqueue_reminders(text, date) from public, anon, authenticated;

/**
 * La de Ronda, que ya no escribe en la bandeja de la app: para las claves de
 * Helios delega en `helios_enqueue_reminders`; las de Ronda no hacen nada
 * (sus plantillas están apagadas y sin cron).
 */
create or replace procedure public.notify_reminder_loop(p_key text, p_batch integer default 500)
language plpgsql
as $$
begin
  if p_key in ('cuota_manana', 'cuota_hoy', 'cuota_vencida_d1', 'cargo_por_atraso_d4') then
    perform public.helios_enqueue_reminders(p_key, null);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3 y 4. Pagos y estado de la cuenta → cola
-- ---------------------------------------------------------------------------

/**
 * Trigger de `payment_reports` (alta y cambio de estado):
 *  - reportado / en revisión / conciliado → cancela los avisos de cuota que
 *    ya no hacen falta;
 *  - conciliado → `pago_recibido`; rechazado → `pago_rechazado`.
 * Nada de esto puede tumbar el pago: un fallo al encolar es un WARNING.
 */
create or replace function public.notify_payment_result()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_quote   public.payment_quotes%rowtype;
  v_ordenes text;
  v_cargo   uuid;
  v_n       integer;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return null;
  end if;

  if new.status in ('reported', 'in_review', 'reconciled') then
    perform public.helios_cancel_covered_reminders(new.user_id);
  end if;

  if tg_op <> 'UPDATE' or new.status not in ('reconciled', 'rejected') then
    return null;
  end if;

  select * into v_quote from public.payment_quotes where id = new.quote_id;

  select string_agg(distinct c.order_number::text, ', #'),
         count(distinct c.id),
         min(c.id::text)::uuid
    into v_ordenes, v_n, v_cargo
  from public.payment_quote_items qi
  join public.installments i on i.id = qi.installment_id
  join public.charges c on c.id = i.charge_id
  where qi.quote_id = new.quote_id;

  begin
    if new.status = 'reconciled' then
      perform public.helios_enqueue_message(
        'pago_recibido', new.user_id, case when v_n = 1 then v_cargo end, 'whatsapp_manual',
        jsonb_build_object(
          'monto', public.helios_money_text(v_quote.amount_usd),
          'orden', coalesce(v_ordenes, '')
        ),
        null, 'pago_recibido:' || new.id);
    else
      perform public.helios_enqueue_message(
        'pago_rechazado', new.user_id, case when v_n = 1 then v_cargo end, 'whatsapp_manual',
        jsonb_build_object(
          'motivo', coalesce(nullif(btrim(new.rejection_note), ''),
                             'no encontramos ese pago en nuestra cuenta'),
          'orden', coalesce(v_ordenes, '')
        ),
        null, 'pago_rechazado:' || new.id);
    end if;
  exception when others then
    raise warning 'No se encoló el aviso del pago %: %', new.id, sqlerrm;
  end;

  return null;
end;
$$;

drop trigger if exists payment_reports_notify on public.payment_reports;
create trigger payment_reports_notify
  after insert or update of status on public.payment_reports
  for each row execute function public.notify_payment_result();

/**
 * Trigger de `profiles` (cambio de estado). Activa → congelada (el motor de
 * mora, día 1): `cuenta_congelada` por WhatsApp. Al salir de congelada, el
 * aviso que siguiera sin mandarse se cancela. Los avisos de la app de Ronda
 * (suspendida, expulsada, restablecida, KYC) se fueron con la app.
 */
create or replace function public.notify_account_status()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status is not distinct from old.status then
    return null;
  end if;

  begin
    if new.status = 'frozen' and old.status = 'active' then
      perform public.helios_enqueue_message(
        'cuenta_congelada', new.id, null, 'whatsapp_manual', '{}'::jsonb, null,
        format('cuenta_congelada:%s:%s', new.id, public.helios_business_date(now())));
    elsif old.status = 'frozen' then
      update public.outbound_messages
         set status = 'cancelado', last_error = 'La cuenta ya no está congelada'
       where profile_id = new.id
         and template_key = 'cuenta_congelada'
         and status = 'pendiente';
    end if;
  exception when others then
    raise warning 'No se encoló el aviso de estado de %: %', new.id, sqlerrm;
  end;

  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1b. La hora y la antelación se editan desde el panel
-- ---------------------------------------------------------------------------

/**
 * Cambia la hora (Caracas) y, si viene, los días de antelación o de atraso de
 * un aviso de cuota, y reprograma su cron. Solo super admin, con bitácora.
 * `cuota_hoy` no tiene días: es el día del vencimiento.
 */
create or replace function public.admin_set_notification_schedule(
  p_key       text,
  p_run_at    time,
  p_lead_days integer default null
)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := public.helios_assert_super_admin('cambiar el horario de un aviso');
  v_tpl   public.notification_templates%rowtype;
  v_utc   time;
begin
  select * into v_tpl from public.notification_templates where key = p_key;
  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = '22023';
  end if;

  if v_tpl.cron_job is null
     or p_key not in ('cuota_manana', 'cuota_hoy', 'cuota_vencida_d1', 'cargo_por_atraso_d4') then
    raise exception '"%" no lo dispara el cron: lo dispara un evento, y un evento no tiene hora',
      v_tpl.label using errcode = '22023';
  end if;

  if p_run_at is null then
    raise exception 'Hace falta una hora' using errcode = '22023';
  end if;

  if p_key = 'cuota_hoy' and coalesce(p_lead_days, 0) <> 0 then
    raise exception 'Este aviso sale el mismo día del vencimiento: no lleva días' using errcode = '22023';
  end if;

  if p_key <> 'cuota_hoy' and p_lead_days is not null and p_lead_days not between 1 and 30 then
    raise exception 'Los días van entre 1 y 30' using errcode = '22023';
  end if;

  v_utc := (((current_date + p_run_at) at time zone 'America/Caracas') at time zone 'UTC')::time;

  perform cron.schedule(
    v_tpl.cron_job,
    format('%s %s * * *', extract(minute from v_utc)::integer, extract(hour from v_utc)::integer),
    format('select public.helios_enqueue_reminders(%L);', p_key)
  );

  update public.notification_templates
     set run_at    = p_run_at,
         lead_days = case when p_key = 'cuota_hoy' then 0 else coalesce(p_lead_days, lead_days) end
   where key = p_key;

  perform audit.log(v_actor, 'notification.schedule', null::uuid,
    jsonb_build_object('key', p_key, 'run_at', p_run_at, 'lead_days', p_lead_days));
end;
$$;

revoke all on function public.admin_set_notification_schedule(text, time, integer) from public, anon;
grant execute on function public.admin_set_notification_schedule(text, time, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. La cola del equipo
-- ---------------------------------------------------------------------------

/** El enlace wa.me con el texto ya puesto (vacío si no hay teléfono). */
create or replace function public.helios_whatsapp_url(p_phone_e164 text, p_text text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case
    when nullif(regexp_replace(coalesce(p_phone_e164, ''), '\D', '', 'g'), '') is null then null
    else 'https://wa.me/' || regexp_replace(p_phone_e164, '\D', '', 'g')
         || '?text=' || public.helios_url_encode(p_text)
  end;
$$;

revoke all on function public.helios_whatsapp_url(text, text) from public, anon;
grant execute on function public.helios_whatsapp_url(text, text) to authenticated;

/**
 * «Avisos de hoy» (docs/01 §2.2). Del día `p_day` (por defecto hoy): los
 * encolados ese día y, si es hoy, además todo lo que siga `pendiente` de días
 * anteriores (lo que no se mandó ayer no desaparece). `p_channel` null =
 * todos. Orden: por plantilla (su `sort_order`) y por antigüedad.
 * Además de las columnas del contrato: `whatsapp_url` (wa.me con el texto),
 * `recipient` y `last_error`.
 */
create or replace function public.admin_outbound_queue(
  p_day     date default null,
  p_channel text default 'whatsapp_manual'
)
returns table (
  id             uuid,
  channel        text,
  template_key   text,
  template_label text,
  profile_id     uuid,
  patient_name   text,
  phone_e164     text,
  charge_id      uuid,
  order_number   bigint,
  due_date       date,
  rendered_text  text,
  status         text,
  created_at     timestamptz,
  sent_at        timestamptz,
  sent_by_name   text,
  whatsapp_url   text,
  recipient      text,
  last_error     text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := public.helios_business_date(now());
  v_day   date;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_day := coalesce(p_day, v_today);

  return query
  select
    o.id, o.channel, o.template_key, t.label,
    o.profile_id,
    coalesce(nullif(btrim(p.full_name), ''), btrim(concat_ws(' ', p.first_name, p.last_name))),
    coalesce(case when o.channel = 'whatsapp_manual' then o.recipient end, p.phone_e164),
    o.charge_id, c.order_number, o.installment_due_date,
    o.rendered_text, o.status, o.created_at, o.sent_at,
    case when o.sent_by is not null then coalesce(pa.full_name, 'Alguien del equipo') end,
    case when o.channel = 'whatsapp_manual'
         then public.helios_whatsapp_url(coalesce(o.recipient, p.phone_e164), o.rendered_text) end,
    o.recipient, o.last_error
  from public.outbound_messages o
  join public.notification_templates t on t.key = o.template_key
  join public.profiles p on p.id = o.profile_id
  left join public.charges c on c.id = o.charge_id
  left join public.platform_admins pa on pa.user_id = o.sent_by
  where (p_channel is null or o.channel = p_channel)
    and (
      public.helios_business_date(o.created_at) = v_day
      or (v_day = v_today and o.status = 'pendiente'
          and public.helios_business_date(o.created_at) < v_day)
    )
  order by t.sort_order, o.created_at, o.id;
end;
$$;

revoke all on function public.admin_outbound_queue(date, text) from public, anon;
grant execute on function public.admin_outbound_queue(date, text) to authenticated;

/**
 * Marca un mensaje de la cola (docs/01 §2.2). Operador o super admin.
 *  - `enviado`: solo WhatsApp (los correos los manda el sistema). Anota la
 *    gestión en `collection_contacts` (canal whatsapp, «mensaje enviado»).
 *  - `omitido`: exige una nota (por qué no se manda).
 * Solo desde `pendiente`; marcar lo que ya está así no hace nada.
 */
create or replace function public.admin_mark_outbound(p_id uuid, p_status text, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_msg   public.outbound_messages%rowtype;
  v_label text;
  v_note  text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_status is null or p_status not in ('enviado', 'omitido') then
    raise exception 'Estado no válido: se marca como enviado u omitido' using errcode = '22023';
  end if;

  select * into v_msg from public.outbound_messages where id = p_id for update;
  if not found then
    raise exception 'No existe ese mensaje' using errcode = 'P0002';
  end if;

  if v_msg.status = p_status then
    return;
  end if;

  if v_msg.status <> 'pendiente' then
    raise exception 'Este mensaje ya está %', v_msg.status using errcode = '22023';
  end if;

  if p_status = 'enviado' and v_msg.channel <> 'whatsapp_manual' then
    raise exception 'Los correos los manda el sistema: no se marcan a mano' using errcode = '22023';
  end if;

  if p_status = 'omitido' and (v_note is null or length(v_note) < 3) then
    raise exception 'Para omitir un mensaje hace falta decir por qué' using errcode = '22023';
  end if;

  select label into v_label from public.notification_templates where key = v_msg.template_key;

  if p_status = 'enviado' then
    update public.outbound_messages
       set status = 'enviado', sent_by = v_actor, sent_at = now(), last_error = null
     where id = p_id;

    insert into public.collection_contacts (user_id, channel, template, note, actor, outcome)
    values (v_msg.profile_id, 'whatsapp', v_msg.template_key,
            coalesce(v_note, 'Aviso por WhatsApp: ' || coalesce(v_label, v_msg.template_key)),
            v_actor, 'mensaje_enviado');
  else
    update public.outbound_messages
       set status = 'omitido', sent_by = v_actor, last_error = v_note, next_attempt_at = null
     where id = p_id;
  end if;

  perform audit.log(v_actor, 'outbound.marked', p_id, jsonb_build_object(
    'status', p_status,
    'template_key', v_msg.template_key,
    'channel', v_msg.channel,
    'profile_id', v_msg.profile_id,
    'note', v_note
  ));
end;
$$;

revoke all on function public.admin_mark_outbound(uuid, text, text) from public, anon;
grant execute on function public.admin_mark_outbound(uuid, text, text) to authenticated;

/**
 * El historial de la cola, correos incluidos (docs/01 §2.2). Filtros
 * opcionales: canal, estado y `p_q` (nombre, cédula, teléfono, correo, número
 * de orden o id del proveedor). Lo más nuevo primero. `total_count` es el
 * total con los filtros, para paginar.
 */
create or replace function public.admin_outbound_history(
  p_channel text    default null,
  p_status  text    default null,
  p_q       text    default null,
  p_limit   integer default 50,
  p_offset  integer default 0
)
returns table (
  id              uuid,
  channel         text,
  template_key    text,
  template_label  text,
  profile_id      uuid,
  patient_name    text,
  phone_e164      text,
  email           text,
  charge_id       uuid,
  order_number    bigint,
  due_date        date,
  subject         text,
  rendered_text   text,
  status          text,
  provider_id     text,
  last_event      text,
  last_event_at   timestamptz,
  attempts        integer,
  next_attempt_at timestamptz,
  last_error      text,
  created_at      timestamptz,
  sent_at         timestamptz,
  sent_by_name    text,
  total_count     bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_q      text := nullif(lower(btrim(coalesce(p_q, ''))), '');
  v_digits text;
  v_limit  integer := greatest(least(coalesce(p_limit, 50), 500), 1);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_digits := nullif(regexp_replace(coalesce(v_q, ''), '\D', '', 'g'), '');

  return query
  select
    o.id, o.channel, o.template_key, t.label,
    o.profile_id,
    coalesce(nullif(btrim(p.full_name), ''), btrim(concat_ws(' ', p.first_name, p.last_name))),
    coalesce(case when o.channel = 'whatsapp_manual' then o.recipient end, p.phone_e164),
    case when o.channel = 'email' then o.recipient else p.email end,
    o.charge_id, c.order_number, o.installment_due_date,
    o.subject, o.rendered_text, o.status,
    o.provider_id, o.last_event, o.last_event_at, o.attempts, o.next_attempt_at, o.last_error,
    o.created_at, o.sent_at,
    case when o.sent_by is not null then coalesce(pa.full_name, 'Alguien del equipo') end,
    count(*) over ()
  from public.outbound_messages o
  join public.notification_templates t on t.key = o.template_key
  join public.profiles p on p.id = o.profile_id
  left join public.charges c on c.id = o.charge_id
  left join public.platform_admins pa on pa.user_id = o.sent_by
  where (p_channel is null or o.channel = p_channel)
    and (p_status is null or o.status = p_status)
    and (
      v_q is null
      or lower(coalesce(p.full_name, concat_ws(' ', p.first_name, p.last_name))) like '%' || v_q || '%'
      or lower(coalesce(o.recipient, '')) like '%' || v_q || '%'
      or lower(coalesce(p.email, '')) like '%' || v_q || '%'
      or lower(coalesce(o.provider_id, '')) = v_q
      or (v_digits is not null and (
            coalesce(p.document_number, '') like '%' || v_digits || '%'
            or regexp_replace(coalesce(p.phone_e164, ''), '\D', '', 'g') like '%' || v_digits || '%'
            or c.order_number::text = v_digits))
    )
  order by o.created_at desc, o.id
  limit v_limit offset v_offset;
end;
$$;

revoke all on function public.admin_outbound_history(text, text, text, integer, integer) from public, anon;
grant execute on function public.admin_outbound_history(text, text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Cron: los cuatro momentos, a la hora de su plantilla (Caracas = UTC-4)
-- ---------------------------------------------------------------------------

do $cron$
declare
  v_tpl record;
  v_utc time;
begin
  for v_tpl in
    select key, cron_job, run_at from public.notification_templates
    where key in ('cuota_manana', 'cuota_hoy', 'cuota_vencida_d1', 'cargo_por_atraso_d4')
  loop
    v_utc := (((current_date + v_tpl.run_at) at time zone 'America/Caracas') at time zone 'UTC')::time;
    perform cron.schedule(
      v_tpl.cron_job,
      format('%s %s * * *', extract(minute from v_utc)::integer, extract(hour from v_utc)::integer),
      format('select public.helios_enqueue_reminders(%L);', v_tpl.key)
    );
  end loop;
end;
$cron$;
