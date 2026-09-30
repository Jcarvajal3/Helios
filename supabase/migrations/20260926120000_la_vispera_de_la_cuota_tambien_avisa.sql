-- ============================================================================
-- Ronda — La víspera de la cuota también avisa
--
-- Decisión de Javier del 2026-09-26. Antes del vencimiento había tres avisos
-- (−3 días a las 19:00, el día a las 08:00 y a las 19:05) y entre el primero y
-- el segundo pasaban dos días sin nada. Se añade uno la víspera, a las 19:00:
--
--   | Momento          | Hora Caracas | Clave                          |
--   |------------------|--------------|--------------------------------|
--   | −3 días          | 19:00        | installment_due                |
--   | −1 día  (NUEVO)  | 19:00        | installment_due_tomorrow       |
--   | el día           | 08:00        | installment_due_today          |
--   | el día           | 19:05        | installment_due_today_evening  |
--   | +1, +3, +5, +7   | 19:10…19:25  | installment_late_d1…d7         |
--
-- Comparte hora con el de −3 días: hablan de fechas distintas, así que nadie
-- recibe los dos por la misma deuda. Quien tenga una cuota el viernes y otra el
-- lunes recibe dos el jueves, que es lo correcto — son dos transferencias.
--
-- Como el de −3 días, es anticipado: `helios_reminder_offset` le pone el signo
-- negativo y el panel solo mueve su `lead_days`. El texto de fábrica dice
-- "mañana" cuando el aviso sale a un día del vencimiento, lo dispare la
-- plantilla que lo dispare, así que mover su día desde el panel no lo deja
-- mintiendo.
--
-- La cancelación al reportar un pago (`cancel_installment_pushes_on_report`)
-- ya lo cubre: filtra por tipo `installment_due` y fecha, no por clave.
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

  if p_key = 'installment_due' then
    return -coalesce(v_lead, 3);
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
-- 2. El texto de fábrica
-- ---------------------------------------------------------------------------
-- Igual que en 20260924120000 salvo el caso `p_offset = -1`.

create or replace function public.notify_installment_moment_batch(
  p_offset integer,
  p_key text,
  p_due date,
  p_after uuid,
  p_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_row       record;
  v_last      uuid := p_after;
  v_seen      integer := 0;
  v_sent      integer := 0;
  v_fee       numeric := public.helios_late_fee_usd();
  v_grace     integer := public.helios_late_fee_grace_days();
  v_demotion  integer := public.helios_mora_demotion_days();
  v_dia       text := public.helios_weekday_es(p_due);
  v_fecha     text := to_char(p_due, 'DD/MM');
  v_comercio  text;
  v_monto     text;
begin
  for v_row in
    select i.user_id,
           sum(i.amount_usd)        as monto,
           count(*)                 as cuotas,
           min(m.name)              as un_local,
           count(distinct m.id)     as locales
    from public.installments i
    join public.charges c   on c.id = i.charge_id
    join public.merchants m on m.id = c.merchant_id
    where i.status = 'pending'
      and i.due_date = p_due
      and i.user_id > p_after
      -- Con un pago reportado esperando conciliación no se avisa: se debe,
      -- pero el usuario ya hizo lo suyo.
      and not exists (
        select 1
        from public.payment_reports r
        join public.payment_quote_items q on q.quote_id = r.quote_id
        where q.installment_id = i.id
          and r.status in ('reported', 'in_review')
      )
    group by i.user_id
    order by i.user_id
    limit p_limit
  loop
    v_last := v_row.user_id;
    v_seen := v_seen + 1;

    -- Ya se avisó de esta fecha en este momento.
    if exists (
      select 1 from public.notifications
      where user_id = v_row.user_id
        and template_key = p_key
        and data->>'due_date' = p_due::text
    ) then
      continue;
    end if;

    v_comercio := case
      when v_row.locales = 1 then v_row.un_local
      else format('%s locales', v_row.locales)
    end;

    v_monto := trim(to_char(v_row.monto, 'FM999999990.00'));

    perform public.notify(
      v_row.user_id,
      'installment_due'::public.notification_type,
      -- El texto de fábrica, por si nadie publicó nada desde el panel.
      case
        when p_offset = -1 then format('Mañana vence tu cuota de €%s', v_monto)
        when p_offset < 0  then format('Tu cuota de €%s vence el %s', v_monto, v_dia)
        when p_offset = 0 and p_key = 'installment_due_today'
                           then format('Hoy vence tu cuota de €%s', v_monto)
        when p_offset = 0  then 'Última oportunidad para pagar tu cuota de hoy'
        when p_offset = 1  then 'Tu cuota venció ayer y tu saldo está bloqueado'
        when p_offset = v_grace
                           then 'Mañana se aplicará el cargo por mora'
        when p_offset >= 7 then 'Una semana de retraso en tu cuota'
        else format('Tu cuota acumula %s días de retraso', p_offset)
      end,
      case
        when p_offset = -1 then
          format('Tu cuota de €%s vence mañana, %s %s. Puedes pagarla ahora desde la aplicación.',
                 v_monto, v_dia, v_fecha)
        when p_offset < 0 then
          format('El %s %s vence una cuota de €%s. Puedes adelantarte y pagarla ahora desde la aplicación.',
                 v_dia, v_fecha, v_monto)
        when p_offset = 0 and p_key = 'installment_due_today' then
          format('Tu cuota de €%s vence hoy, %s %s. Complétala desde la aplicación antes de que finalice el día.',
                 v_monto, v_dia, v_fecha)
        when p_offset = 0 then
          format('Tu cuota de €%s del %s %s continúa pendiente. Si no la registras hoy, mañana tu saldo quedará bloqueado.',
                 v_monto, v_dia, v_fecha)
        when p_offset = 1 then
          format('La cuota de €%s del %s %s está vencida. Regulariza el pago para recuperar tu saldo y volver a consumir en los locales.',
                 v_monto, v_dia, v_fecha)
        when p_offset = v_grace then
          format('Tu cuota de €%s del %s %s acumula %s días de retraso. Si la pagas hoy, evitarás el cargo por mora de €%s por cuota.',
                 v_monto, v_dia, v_fecha, p_offset,
                 trim(to_char(v_fee, 'FM999999990.00')))
        when p_offset >= 7 then
          format('La cuota de €%s del %s %s lleva %s días vencida. A los %s días de retraso tu nivel se reduce automáticamente.',
                 v_monto, v_dia, v_fecha, p_offset, v_demotion)
        else
          format('La cuota de €%s del %s %s continúa vencida y ya genera cargos por mora. Regularízala para detener el cargo y recuperar tu saldo.',
                 v_monto, v_dia, v_fecha)
      end,
      -- `due_date` es lo que abre Cuotas con esa fecha ya marcada, y lo que la
      -- cancelación por pago reportado usa para saber a qué aviso apunta.
      jsonb_build_object('due_date', p_due, 'moment', p_key),
      p_key,
      jsonb_build_object(
        'dia',        v_dia,
        'fecha',      v_fecha,
        'dias',       abs(p_offset),
        'monto',      v_monto,
        'cuotas',     v_row.cuotas,
        'comercio',   v_comercio,
        'cargo',      trim(to_char(v_fee, 'FM999999990.00')),
        'dias_nivel', v_demotion
      )
    );

    v_sent := v_sent + 1;
  end loop;

  return jsonb_build_object('last', v_last, 'seen', v_seen, 'sent', v_sent);
end;
$fn$;

revoke all on function public.notify_installment_moment_batch(integer, text, date, uuid, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. El catálogo
-- ---------------------------------------------------------------------------
-- Entra en el orden del panel entre el de −3 días y el del día; los de detrás
-- corren un puesto (el siguiente bloque empieza en 70).

update public.notification_templates
   set sort_order = sort_order + 1
 where key in ('installment_due_today', 'installment_due_today_evening',
               'installment_late_d1', 'installment_late_d3',
               'installment_late_d5', 'installment_late_d7')
   and sort_order between 61 and 66;

insert into public.notification_templates (
  key, type, label, trigger_label, help,
  variables, required_variables,
  default_title, default_body,
  editable, can_disable, cron_job, lead_days, run_at, sort_order
) values (
  'installment_due_tomorrow', 'installment_due'::public.notification_type,
  'Tu cuota vence mañana',
  'Cron diario, la víspera del vencimiento.',
  'La víspera, a la hora en que se puede abrir el banco. Todavía no hay nada que evitar: es el último aviso con margen antes del día del vencimiento. Si se mueve su día desde el panel, el texto de fábrica deja de decir «mañana» solo.',
  array['dias', 'dia', 'fecha', 'monto', 'cuotas', 'comercio'],
  array['monto'],
  'Mañana vence tu cuota de €{monto}',
  'Tu cuota de €{monto} vence mañana, {dia} {fecha}. Puedes pagarla ahora desde la aplicación.',
  true, true, 'helios_installment_due_tomorrow', 1, '19:00'::time, 61
)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 4. El cron
-- ---------------------------------------------------------------------------
-- 19:00 Caracas son las 23:00 UTC. `cron.schedule` con un nombre que ya existe
-- reemplaza el trabajo, así que repetir la migración no duplica nada.

select cron.schedule(
  'helios_installment_due_tomorrow',
  '0 23 * * *',
  $cron$call public.notify_reminder_loop('installment_due_tomorrow')$cron$
);

-- ---------------------------------------------------------------------------
-- 5. El asistente lo conoce
-- ---------------------------------------------------------------------------

do $c$
begin
  if to_regclass('asistente.plantillas_push') is not null then
    execute $cm$comment on view asistente.plantillas_push is
      'Las plantillas de los avisos. Los recordatorios de cuota son installment_due (antes de vencer), installment_due_tomorrow (la víspera), installment_due_today, installment_due_today_evening e installment_late_d1/d3/d5/d7 (de atraso).'$cm$;
  end if;
end;
$c$;
