-- ============================================================================
-- Ronda — La primera semana de mora avisa cada día
--
-- Decisión de Javier del 2026-09-28. Los peldaños de atraso eran 1, 3, 5 y 7;
-- pasan a ser uno por día durante la primera semana. Entran el 2, el 4 y el 6:
--
--   | Día | Hora Caracas | Clave                | Qué dice                         |
--   |-----|--------------|----------------------|----------------------------------|
--   | +1  | 19:10        | installment_late_d1  | saldo bloqueado                  |
--   | +2  | 19:12 NUEVO  | installment_late_d2  | sigue bloqueado; aún sin cargo   |
--   | +3  | 19:15        | installment_late_d3  | mañana entra el cargo            |
--   | +4  | 19:17 NUEVO  | installment_late_d4  | el cargo ya corre                |
--   | +5  | 19:20        | installment_late_d5  | el cargo ya corre                |
--   | +6  | 19:22 NUEVO  | installment_late_d6  | el cargo ya corre                |
--   | +7  | 19:25        | installment_late_d7  | la siguiente consecuencia: nivel |
--
-- Las horas nuevas caen entre las viejas para que ningún recorrido de la tabla
-- de cuotas coincida con otro; a la persona le llega uno por día igual, porque
-- cada peldaño habla de una fecha de vencimiento distinta.
--
-- El texto de fábrica de un peldaño ANTES de la gracia es nuevo: el genérico
-- dice "ya genera cargos por mora", y el día 2 eso es falso — el cargo entra
-- cuando el retraso supera `helios_late_fee_grace_days()` (hoy, el día 4 a las
-- 10:05). Como el resto de la escalera, el texto se decide comparando con la
-- gracia vigente y no con el número del día, así que si la gracia cambia los
-- textos se mueven solos.
--
-- `helios_reminder_offset` no cambia: cualquier clave de atraso lee su día de
-- `lead_days`.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El texto de fábrica
-- ---------------------------------------------------------------------------
-- Igual que en 20260926120000 salvo el caso `p_offset < v_grace`.

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
        when p_offset < v_grace
                           then format('Tu cuota lleva %s días vencida', p_offset)
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
        when p_offset < v_grace then
          format('La cuota de €%s del %s %s sigue vencida y tu saldo continúa bloqueado. Regularízala pronto para evitar el cargo por mora de €%s por cuota.',
                 v_monto, v_dia, v_fecha,
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
-- 2. El catálogo
-- ---------------------------------------------------------------------------
-- Los siete peldaños ocupan del 64 al 70 en el orden del panel; el cargo por
-- mora, que vivía en el 70, pasa al 71.

update public.notification_templates
   set sort_order = case key
         when 'installment_late_d1' then 64
         when 'installment_late_d3' then 66
         when 'installment_late_d5' then 68
         when 'installment_late_d7' then 70
         when 'late_fee_charged'    then 71
       end
 where key in ('installment_late_d1', 'installment_late_d3', 'installment_late_d5',
               'installment_late_d7', 'late_fee_charged');

insert into public.notification_templates (
  key, type, label, trigger_label, help,
  variables, required_variables,
  default_title, default_body,
  editable, can_disable, cron_job, lead_days, run_at, sort_order
) values
(
  'installment_late_d2', 'installment_due'::public.notification_type,
  'Cuota vencida: segundo día',
  'Cron diario, al segundo día de retraso.',
  'El saldo sigue bloqueado y el cargo por mora todavía no entra. Su texto de fábrica lo dice mientras el día quede antes de la gracia; si alguien lo mueve más allá, pasa a decir que el cargo ya corre.',
  array['dias', 'dia', 'fecha', 'monto', 'cuotas', 'comercio', 'cargo', 'dias_nivel'],
  array['monto'],
  'Tu cuota lleva {dias} días vencida',
  'La cuota de €{monto} del {dia} {fecha} sigue vencida y tu saldo continúa bloqueado. Regularízala pronto para evitar el cargo por mora de €{cargo} por cuota.',
  true, true, 'helios_installment_late_d2', 2, '19:12'::time, 65
),
(
  'installment_late_d4', 'installment_due'::public.notification_type,
  'Cuota vencida: cuarto día',
  'Cron diario, al cuarto día de retraso.',
  'El primer día con el cargo por mora aplicado: esa mañana ya le llegó el aviso del cargo. Este recuerda que la cuenta sigue bloqueada y que pagar lo detiene.',
  array['dias', 'dia', 'fecha', 'monto', 'cuotas', 'comercio', 'cargo', 'dias_nivel'],
  array['monto'],
  'Tu cuota acumula {dias} días de retraso',
  'La cuota de €{monto} del {dia} {fecha} continúa vencida y ya genera cargos por mora. Regularízala para detener el cargo y recuperar tu saldo.',
  true, true, 'helios_installment_late_d4', 4, '19:17'::time, 67
),
(
  'installment_late_d6', 'installment_due'::public.notification_type,
  'Cuota vencida: sexto día',
  'Cron diario, al sexto día de retraso.',
  'Víspera de la semana de retraso. Mismo mensaje que el cuarto y el quinto: la cuenta sigue bloqueada y el cargo sigue sumando.',
  array['dias', 'dia', 'fecha', 'monto', 'cuotas', 'comercio', 'cargo', 'dias_nivel'],
  array['monto'],
  'Tu cuota acumula {dias} días de retraso',
  'La cuota de €{monto} del {dia} {fecha} continúa vencida y ya genera cargos por mora. Regularízala para detener el cargo y recuperar tu saldo.',
  true, true, 'helios_installment_late_d6', 6, '19:22'::time, 69
)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 3. Los crons
-- ---------------------------------------------------------------------------
-- Horas de Caracas (UTC−4): 19:12 son las 23:12 UTC. `cron.schedule` con un
-- nombre que ya existe reemplaza el trabajo, así que repetir la migración no
-- duplica nada.

select cron.schedule(
  'helios_installment_late_d2',
  '12 23 * * *',
  $cron$call public.notify_reminder_loop('installment_late_d2')$cron$
);

select cron.schedule(
  'helios_installment_late_d4',
  '17 23 * * *',
  $cron$call public.notify_reminder_loop('installment_late_d4')$cron$
);

select cron.schedule(
  'helios_installment_late_d6',
  '22 23 * * *',
  $cron$call public.notify_reminder_loop('installment_late_d6')$cron$
);

-- ---------------------------------------------------------------------------
-- 4. El asistente lo conoce
-- ---------------------------------------------------------------------------

do $c$
begin
  if to_regclass('asistente.plantillas_push') is not null then
    execute $cm$comment on view asistente.plantillas_push is
      'Las plantillas de los avisos. Los recordatorios de cuota son installment_due (antes de vencer), installment_due_tomorrow (la víspera), installment_due_today, installment_due_today_evening e installment_late_d1 a installment_late_d7 (uno por cada día de atraso de la primera semana).'$cm$;
  end if;
end;
$c$;
