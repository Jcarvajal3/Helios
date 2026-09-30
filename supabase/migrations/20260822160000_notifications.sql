-- ============================================================================
-- Ronda — Notificaciones
--
-- docs/05 §2 punto 2: frente a la autorización permanente de los grupos, "la
-- notificación es el control, no el bloqueo". Hoy un integrante se entera de
-- que le cargaron algo cuando abre la app por su cuenta — que es justo lo que
-- ese punto pedía evitar.
--
-- ---------------------------------------------------------------------------
-- Alcance de esta migración
-- ---------------------------------------------------------------------------
-- Aquí va el CONTENIDO: qué se notifica, a quién y con qué texto, más la
-- bandeja que lo muestra. **El transporte push no va**: mandar a FCM exige
-- credenciales del proyecto y decidir antes la matriz de docs/00-BASES §3.13,
-- donde cada línea cuesta dinero (WhatsApp se paga por conversación).
--
-- La separación es deliberada y no un recorte: cuando existan las
-- credenciales, un worker lee de esta misma tabla y despacha. No hay que
-- rehacer nada de lo de aquí.
--
-- ---------------------------------------------------------------------------
-- Por qué triggers y no llamadas dentro de cada RPC
-- ---------------------------------------------------------------------------
-- Todo lo que hay que notificar es un CAMBIO DE ESTADO que queda escrito en
-- una tabla. Un trigger lo capta venga de donde venga —RPC, cron o un UPDATE
-- a mano del super admin— mientras que sembrar llamadas dentro de cada
-- función deja huecos en cuanto aparece un camino nuevo.
-- ============================================================================

create type public.notification_type as enum (
  'group_charge',        -- te cargaron tu parte de un consumo de grupo
  'payment_reconciled',  -- confirmamos tu pago
  'payment_rejected',    -- no encontramos tu pago
  'kyc_approved',
  'kyc_rejected',
  'account_frozen',      -- cuota vencida
  'account_suspended',   -- +15 días: bajaste de nivel
  'account_expelled',
  'account_restored',
  'installment_due'      -- recordatorio antes del vencimiento
);

create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  type       public.notification_type not null,
  title      text not null,
  body       text not null,
  -- Contexto para que la app pueda enlazar a la pantalla que toca.
  data       jsonb not null default '{}'::jsonb,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);

create index notifications_inbox_idx
  on public.notifications (user_id, created_at desc);

create index notifications_unread_idx
  on public.notifications (user_id) where read_at is null;

alter table public.notifications enable row level security;

create policy "notifications_read_own"
  on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));

-- Marcar como leída es lo único que el cliente puede escribir, y solo sobre
-- lo suyo. Crear notificaciones es exclusivo del servidor.
create policy "notifications_mark_own_read"
  on public.notifications for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

grant select, update on public.notifications to authenticated;

/** Crea una notificación. Solo la llaman los triggers y el cron. */
create or replace function public.notify(
  p_user_id uuid,
  p_type    public.notification_type,
  p_title   text,
  p_body    text,
  p_data    jsonb default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.notifications (user_id, type, title, body, data)
  values (p_user_id, p_type, p_title, p_body, p_data);
$$;

revoke all on function public.notify(uuid, public.notification_type, text, text, jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Cargo de grupo iniciado por otra persona
-- ---------------------------------------------------------------------------
-- El control antiabuso de docs/05 §2. Se dispara sobre `installments` porque
-- ahí es donde queda escrito que a alguien le tocó una parte, y se filtra a
-- la cuota 1 para no avisar dos veces del mismo consumo.

create or replace function public.notify_group_charge()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_charge   public.charges%rowtype;
  v_group    text;
  v_merchant text;
  v_who      text;
  v_total    numeric(18,4);
begin
  if new.sequence <> 1 then
    return null;
  end if;

  select * into v_charge from public.charges where id = new.charge_id;

  -- Solo los consumos de grupo, y no a quien lo inició: esa persona estaba
  -- delante del cajero decidiendo el reparto.
  if v_charge.group_id is null or v_charge.user_id = new.user_id then
    return null;
  end if;

  select g.name into v_group from public.groups g where g.id = v_charge.group_id;
  select m.name into v_merchant from public.merchants m where m.id = v_charge.merchant_id;
  select coalesce(p.full_name, 'Alguien') into v_who
  from public.profiles p where p.id = v_charge.user_id;

  select coalesce(sum(amount_usd), 0) into v_total
  from public.installments
  where charge_id = new.charge_id and user_id = new.user_id;

  perform public.notify(
    new.user_id,
    'group_charge',
    format('%s dividió una cuenta contigo', v_who),
    format('Te tocaron $%s en %s, del grupo %s. Se paga en dos cuotas.',
           trim(to_char(v_total, 'FM999999990.00')), v_merchant, v_group),
    jsonb_build_object(
      'charge_id', v_charge.id,
      'group_id', v_charge.group_id,
      'amount_usd', v_total,
      'initiated_by', v_charge.user_id
    )
  );

  return null;
end;
$$;

revoke all on function public.notify_group_charge() from public, anon, authenticated;

create trigger installments_notify_group
  after insert on public.installments
  for each row execute function public.notify_group_charge();

-- ---------------------------------------------------------------------------
-- 2. Resultado de un pago reportado
-- ---------------------------------------------------------------------------

create or replace function public.notify_payment_result()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_quote public.payment_quotes%rowtype;
begin
  if new.status = old.status then
    return null;
  end if;

  select * into v_quote from public.payment_quotes where id = new.quote_id;

  if new.status = 'reconciled' then
    perform public.notify(
      new.user_id, 'payment_reconciled',
      'Confirmamos tu pago',
      format('Recibimos $%s. %s cuota(s) quedaron al día.',
             trim(to_char(v_quote.amount_usd, 'FM999999990.00')),
             v_quote.installment_count),
      jsonb_build_object('report_id', new.id, 'amount_usd', v_quote.amount_usd)
    );

  elsif new.status = 'rejected' then
    perform public.notify(
      new.user_id, 'payment_rejected',
      'No pudimos confirmar tu pago',
      coalesce(new.rejection_note, 'No encontramos esa referencia. Revísala y vuelve a reportarla.'),
      jsonb_build_object('report_id', new.id)
    );
  end if;

  return null;
end;
$$;

revoke all on function public.notify_payment_result() from public, anon, authenticated;

create trigger payment_reports_notify
  after update on public.payment_reports
  for each row execute function public.notify_payment_result();

-- ---------------------------------------------------------------------------
-- 3. Cambios de estado de la cuenta
-- ---------------------------------------------------------------------------
-- Cubre mora (congelado, bloqueado, expulsado), la restauración al pagar y el
-- resultado del KYC. Un solo trigger sobre `profiles.status` los capta todos,
-- venga el cambio del cron de mora o de la revisión manual.

create or replace function public.notify_account_status()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_level_change public.level_changes%rowtype;
begin
  if new.status = old.status then
    return null;
  end if;

  if new.status = 'frozen' then
    perform public.notify(
      new.id, 'account_frozen',
      'Tu saldo está congelado',
      'Tienes una cuota vencida. Al ponerte al día vuelves a poder consumir.',
      '{}'::jsonb
    );

  elsif new.status = 'suspended' then
    select * into v_level_change from public.level_changes
    where user_id = new.id order by created_at desc limit 1;

    perform public.notify(
      new.id, 'account_suspended',
      'Bajaste de nivel',
      format('Llevas más de 15 días de retraso. Pasaste al nivel %s.',
             coalesce(v_level_change.to_level, new.level)),
      jsonb_build_object('level', new.level)
    );

  elsif new.status = 'expelled' then
    perform public.notify(
      new.id, 'account_expelled',
      'Tu cuenta quedó cerrada',
      'Pasaron más de 30 días sin pago. Escríbenos para resolver tu situación.',
      '{}'::jsonb
    );

  elsif new.status = 'active' and old.status in ('frozen', 'suspended') then
    perform public.notify(
      new.id, 'account_restored',
      'Tu cuenta volvió a la normalidad',
      'Te pusiste al día. Ya puedes volver a consumir.',
      '{}'::jsonb
    );

  elsif new.status = 'pending_pin' and old.status = 'pending_kyc' then
    perform public.notify(
      new.id, 'kyc_approved',
      'Verificamos tu identidad',
      'Ya puedes crear tu PIN y empezar a usar Helios.',
      '{}'::jsonb
    );
  end if;

  return null;
end;
$$;

revoke all on function public.notify_account_status() from public, anon, authenticated;

create trigger profiles_notify_status
  after update on public.profiles
  for each row execute function public.notify_account_status();

-- KYC rechazado no cambia `profiles.status`, así que va sobre su propia tabla.
create or replace function public.notify_kyc_rejected()
returns trigger
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $$
begin
  if new.status = 'rejected' and old.status <> 'rejected' then
    perform public.notify(
      new.user_id, 'kyc_rejected',
      'No pudimos verificar tu identidad',
      coalesce(new.rejection_detail, 'Vuelve a intentarlo con mejor luz y la cédula completa en el recuadro.'),
      jsonb_build_object('verification_id', new.id)
    );
  end if;

  return null;
end;
$$;

revoke all on function public.notify_kyc_rejected() from public, anon, authenticated;

create trigger kyc_notify_rejected
  after update on kyc.verifications
  for each row execute function public.notify_kyc_rejected();

-- ---------------------------------------------------------------------------
-- 4. Recordatorio antes del vencimiento
-- ---------------------------------------------------------------------------

/**
 * Avisa de las cuotas que vencen dentro de `p_days_ahead` días.
 *
 * Idempotente por día: si el cron corre dos veces, no manda dos avisos de la
 * misma cuota. Se comprueba contra las notificaciones ya creadas hoy en vez
 * de llevar una marca en la cuota — así el aviso no ensucia el dato de la
 * deuda.
 */
create or replace function public.notify_upcoming_installments(p_days_ahead integer default 2)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row   record;
  v_count integer := 0;
  v_due   date := public.helios_business_date(now()) + p_days_ahead;
begin
  for v_row in
    select i.id, i.user_id, i.amount_usd, i.due_date, i.sequence, m.name as merchant
    from public.installments i
    join public.charges c on c.id = i.charge_id
    join public.merchants m on m.id = c.merchant_id
    where i.status = 'pending' and i.due_date = v_due
  loop
    if exists (
      select 1 from public.notifications
      where user_id = v_row.user_id
        and type = 'installment_due'
        and data->>'installment_id' = v_row.id::text
    ) then
      continue;
    end if;

    perform public.notify(
      v_row.user_id, 'installment_due',
      format('Tu cuota vence en %s días', p_days_ahead),
      format('$%s de %s. Vence el %s.',
             trim(to_char(v_row.amount_usd, 'FM999999990.00')),
             v_row.merchant,
             to_char(v_row.due_date, 'DD/MM')),
      jsonb_build_object('installment_id', v_row.id, 'due_date', v_row.due_date)
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.notify_upcoming_installments(integer)
  from public, anon, authenticated;

select cron.schedule(
  'helios_installment_reminders',
  -- 10:15 AM Caracas, justo después del barrido de mora.
  '15 14 * * *',
  $$ select public.notify_upcoming_installments(2); $$
);

-- ---------------------------------------------------------------------------
-- 5. La bandeja
-- ---------------------------------------------------------------------------

create or replace function public.my_notifications(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user uuid := auth.uid();
  v_rows jsonb;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc), '[]'::jsonb) into v_rows
  from (
    select id, type, title, body, data, read_at, created_at
    from public.notifications
    where user_id = v_user
    order by created_at desc
    limit p_limit
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.my_notifications(integer) from public, anon;
grant execute on function public.my_notifications(integer) to authenticated;

create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_count integer;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  update public.notifications
    set read_at = now()
  where user_id = v_user
    and read_at is null
    and (p_ids is null or id = any(p_ids));

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.mark_notifications_read(uuid[]) from public, anon;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;
