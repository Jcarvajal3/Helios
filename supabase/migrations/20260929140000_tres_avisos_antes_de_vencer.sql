-- ============================================================================
-- Ronda — Tres avisos antes de vencer: −3, −2 y −1
--
-- Decisión de Javier del 2026-09-29. En producción el primer aviso
-- (`installment_due`) se movió desde el panel a dos días antes, así que
-- antes del vencimiento quedaban −2 y −1. Entra otro a los tres días:
--
--   | Día | Hora Caracas | Clave                      |
--   |-----|--------------|----------------------------|
--   | −3  | 19:00  NUEVO | installment_due_d3         |
--   | −2  | la suya      | installment_due            |
--   | −1  | 19:00        | installment_due_tomorrow   |
--   |  0  | 08:00, 19:05 | installment_due_today(_evening) |
--
-- `installment_due` se deja en −2 donde todavía estuviera en −3 (dev): si no,
-- el nuevo y él saldrían el mismo día. Donde ya está en −2 (producción) no se
-- toca, ni su hora.
--
-- El texto de fábrica del nuevo es el de cualquier aviso anticipado que no
-- sea la víspera («Tu cuota de €X vence el viernes»), ya escrito en
-- `notify_installment_moment_batch`; aquí no se reescribe esa función.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El signo
-- ---------------------------------------------------------------------------

create or replace function public.helios_reminder_offset(p_key text)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_lead integer;
begin
  select lead_days into v_lead from public.notification_templates where key = p_key;

  if p_key = 'installment_due_d3' then
    return -coalesce(v_lead, 3);
  end if;

  if p_key = 'installment_due' then
    return -coalesce(v_lead, 2);
  end if;

  if p_key = 'installment_due_tomorrow' then
    return -coalesce(v_lead, 1);
  end if;

  if p_key in ('installment_due_today', 'installment_due_today_evening') then
    return 0;
  end if;

  if v_lead is null or v_lead < 1 then
    raise exception 'El aviso % no tiene un día de atraso configurado', p_key
      using errcode = '22023';
  end if;

  return v_lead;
end;
$fn$;

revoke all on function public.helios_reminder_offset(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. El de −2 deja sitio
-- ---------------------------------------------------------------------------

update public.notification_templates
   set lead_days = 2
 where key = 'installment_due'
   and lead_days = 3;

update public.notification_templates
   set trigger_label = 'Cron diario, dos días antes del vencimiento.'
 where key = 'installment_due'
   and lead_days = 2;

-- ---------------------------------------------------------------------------
-- 3. El nuevo
-- ---------------------------------------------------------------------------

insert into public.notification_templates (
  key, type, label, trigger_label, help,
  variables, required_variables,
  default_title, default_body,
  editable, can_disable, cron_job, lead_days, run_at, sort_order
) values (
  'installment_due_d3', 'installment_due'::public.notification_type,
  'Primer aviso antes de vencer',
  'Cron diario, tres días antes del vencimiento.',
  'Abre la cuenta atrás con margen para organizarse: todavía no hay nada que evitar. Un aviso por FECHA de pago, no por cuota: {monto} es el total de ese día y {cuotas} cuántas lo componen.',
  array['dias', 'dia', 'fecha', 'monto', 'cuotas', 'comercio'],
  array['monto'],
  'Tu cuota de €{monto} vence el {dia}',
  'El {dia} {fecha} vence una cuota de €{monto}. Puedes adelantarte y pagarla ahora desde la aplicación.',
  true, true, 'helios_installment_due_d3', 3, '19:00'::time, 59
)
on conflict (key) do nothing;

-- 19:00 Caracas son las 23:00 UTC. `cron.schedule` con un nombre que ya existe
-- reemplaza el trabajo, así que repetir la migración no duplica nada.
select cron.schedule(
  'helios_installment_due_d3',
  '0 23 * * *',
  $cron$call public.notify_reminder_loop('installment_due_d3')$cron$
);

-- ---------------------------------------------------------------------------
-- 4. El asistente lo conoce
-- ---------------------------------------------------------------------------

do $c$
begin
  if to_regclass('asistente.plantillas_push') is not null then
    execute $cm$comment on view asistente.plantillas_push is
      'Las plantillas de los avisos. Los recordatorios de cuota son installment_due_d3 (tres días antes), installment_due (dos días antes), installment_due_tomorrow (la víspera), installment_due_today, installment_due_today_evening e installment_late_d1 a installment_late_d7 (uno por cada día de atraso de la primera semana).'$cm$;
  end if;
end;
$c$;
