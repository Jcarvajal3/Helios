-- ============================================================================
-- Ronda — El recordatorio de cuota es una escalera de SIETE momentos
--
-- Decisión de Javier del 2026-09-18. La escalera de cuatro del 2026-09-04
-- avisaba una vez antes del vencimiento y tres veces después, toda ella a
-- media mañana. Pasa a ser:
--
--   | Momento          | Hora Caracas | Qué se puede evitar todavía      |
--   |------------------|--------------|----------------------------------|
--   | −3 días          | 19:00        | todo                             |
--   | el día           | 08:00        | el bloqueo                       |
--   | el día           | 19:05        | el bloqueo, con el día acabando  |
--   | +1 día           | 19:10        | el cargo por mora                |
--   | +3 días          | 19:15        | el cargo, si la gracia sigue en 3|
--   | +5 días          | 19:20        | que siga sumando                 |
--   | +7 días          | 19:25        | la bajada de nivel               |
--
-- ---------------------------------------------------------------------------
-- 1. La tarde, y no la mañana
-- ---------------------------------------------------------------------------
-- Los cuatro avisos viejos salían entre las 10:15 y las 10:30, detrás del
-- barrido de mora, porque ese era el hueco del cron y no porque fuera buena
-- hora para nadie. Un recordatorio de pago a media mañana llega en mitad de la
-- jornada; a las siete de la tarde llega cuando la persona puede abrir el
-- banco. El único que se queda en la mañana es el del día del vencimiento, y
-- se queda a las 08:00 justamente para que quepa el día entero por delante.
--
-- ---------------------------------------------------------------------------
-- 2. Dos avisos el día del vencimiento
-- ---------------------------------------------------------------------------
-- El de las 08:00 abre el día y el de las 19:05 lo cierra. El segundo NO se
-- manda a quien ya pagó: el motor recorre cuotas en `pending` y salta a quien
-- tiene un pago esperando conciliación, así que pagar por la mañana apaga el
-- de la tarde sin que haya que programar nada.
--
-- ---------------------------------------------------------------------------
-- 3. El ancla pasa a ser el día NATURAL de Caracas
-- ---------------------------------------------------------------------------
-- Esto es el cambio de fondo, y sin él el aviso de las 08:00 saldría mal.
--
-- `helios_business_date` no devuelve el día del calendario: devuelve el día
-- OPERATIVO, que va de las 10:00 a las 10:00 (una noche que termina a las 3 de
-- la madrugada pertenece al día en que empezó). A las 08:00 de un martes, el
-- día operativo todavía es lunes. Un aviso que dijera "hoy vence tu cuota"
-- calculando sobre el día operativo estaría hablando de las cuotas de ayer.
--
-- Los cuatro avisos viejos se libraban por casualidad: corrían a las 10:15,
-- quince minutos después del cambio de día operativo. Dependían de la hora, y
-- la hora se edita desde el panel — o sea que eran una trampa esperando a que
-- alguien moviera el reloj.
--
-- Desde aquí la fecha de referencia es `helios_caracas_date`, el día del
-- calendario en Caracas. Un aviso significa lo mismo a cualquier hora a la que
-- se dispare, y mover su reloj desde el panel es seguro.
--
-- ---------------------------------------------------------------------------
-- 4. El seguro contra decirle "venciste" a quien está en plazo
-- ---------------------------------------------------------------------------
-- Cambiar de ancla abre una grieta entre la medianoche y las 10:00: en esa
-- franja el calendario ya avanzó y el motor de mora todavía no. Un aviso de
-- atraso disparado a las 07:00 diría "tu cuota venció ayer" de una cuota que
-- el sistema aún considera en plazo — y que no bloquea ningún saldo.
--
-- Por eso los cuatro avisos de atraso comprueban además que el motor de mora
-- esté de acuerdo (`helios_business_date(now()) > v_due`). A las siete de la
-- tarde eso se cumple siempre; la comprobación existe para el día en que
-- alguien mueva la hora desde el panel. Un aviso no puede prometer una
-- consecuencia que el motor no ha aplicado.
--
-- ---------------------------------------------------------------------------
-- 5. El día lo decide el panel, el signo lo decide el código
-- ---------------------------------------------------------------------------
-- `lead_days` pasa a significar lo mismo en los seis avisos que tienen día: a
-- cuántos días del vencimiento sale. Si es antes o después NO es configurable
-- —eso cambiaría el texto, y el texto es otra cosa—, así que el signo vive en
-- la función que dispara cada uno. El super admin puede mover el aviso del día
-- 5 al día 4 sin tocar una migración, y no puede convertirlo en un aviso
-- anticipado por accidente.
--
-- ---------------------------------------------------------------------------
-- 6. Las claves se renombran
-- ---------------------------------------------------------------------------
-- `installment_late_fee_eve` era "la víspera del cargo" y estaba atada a
-- `helios_late_fee_grace_days()`. Ahora la escalera de atrasos es 1, 3, 5 y 7
-- por decisión de producto, así que la clave pasa a decir el día:
-- `installment_late_d1`, `_d3`, `_d5`, `_d7`. Se renombra la fila entera —con
-- lo que alguien hubiera publicado— y también el `template_key` de los avisos
-- ya emitidos, para no partir el historial del panel en dos.
--
-- Lo que se pierde al desatar el día 3 de la gracia se recupera en el texto:
-- el aviso menciona el cargo de mañana SOLO si su día coincide con la gracia
-- vigente. Si mañana la gracia fuera 5, el aviso del día 3 deja de prometer un
-- cargo que no llega y el del día 5 lo anuncia.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El día del calendario en Caracas
-- ---------------------------------------------------------------------------

create or replace function public.helios_caracas_date(p_ts timestamptz)
returns date
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$
  select (p_ts at time zone 'America/Caracas')::date;
$fn$;

comment on function public.helios_caracas_date(timestamptz) is
  'El dia del CALENDARIO en Caracas. No confundir con helios_business_date, que es el dia operativo de 10 AM a 10 AM. Los avisos usan este; el dinero usa aquel.';

revoke all on function public.helios_caracas_date(timestamptz) from public, anon;
grant execute on function public.helios_caracas_date(timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El motor
-- ---------------------------------------------------------------------------
/**
 * Un aviso por usuario y FECHA de pago, con el total de ese día.
 *
 * `p_offset` son días transcurridos desde el vencimiento: negativo antes del
 * vencimiento, 0 el mismo día, positivo en atraso. Idempotente por plantilla
 * y fecha, así que dos corridas del cron no duplican nada.
 */
create or replace function public.notify_installment_moment(
  p_offset integer,
  p_key    text
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_row       record;
  v_count     integer := 0;
  v_due       date := public.helios_caracas_date(now()) - p_offset;
  v_tpl       public.notification_templates%rowtype;
  v_fee       numeric := public.helios_late_fee_usd();
  v_grace     integer := public.helios_late_fee_grace_days();
  v_demotion  integer := public.helios_mora_demotion_days();
  v_dia       text := public.helios_weekday_es(v_due);
  v_fecha     text := to_char(v_due, 'DD/MM');
  v_comercio  text;
  v_monto     text;
begin
  select * into v_tpl from public.notification_templates where key = p_key;

  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = '22023';
  end if;

  -- Apagado desde el panel: ni se busca a quién avisar.
  if not v_tpl.enabled then
    return 0;
  end if;

  -- El seguro del punto 4 de la cabecera: en atraso, el motor de mora tiene
  -- que estar de acuerdo en que esa fecha ya venció.
  if p_offset > 0 and public.helios_business_date(now()) <= v_due then
    return 0;
  end if;

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
      and i.due_date = v_due
      -- Con un pago reportado esperando conciliación no se avisa: se debe,
      -- pero el usuario ya hizo lo suyo. Es lo que apaga el aviso de la tarde
      -- para quien pagó por la mañana.
      and not exists (
        select 1
        from public.payment_reports r
        join public.payment_quote_items q on q.quote_id = r.quote_id
        where q.installment_id = i.id
          and r.status in ('reported', 'in_review')
      )
    group by i.user_id
  loop
    -- Ya se avisó de esta fecha en este momento.
    if exists (
      select 1 from public.notifications
      where user_id = v_row.user_id
        and template_key = p_key
        and data->>'due_date' = v_due::text
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
      jsonb_build_object('due_date', v_due, 'moment', p_key),
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

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$fn$;

comment on function public.notify_installment_moment(integer, text) is
  'Un aviso por usuario y FECHA de pago, con el total del dia. p_offset son dias desde el vencimiento: negativo antes, 0 el dia, positivo en atraso. Idempotente por (plantilla, fecha).';

revoke all on function public.notify_installment_moment(integer, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Los siete disparadores
-- ---------------------------------------------------------------------------
-- Cada uno lee su propio `lead_days` del catálogo, así que el día se cambia
-- desde el panel. El signo no: ver el punto 5 de la cabecera.

create or replace function public.notify_upcoming_installments(p_days_ahead integer default null)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_lead integer := coalesce(
    p_days_ahead,
    (select lead_days from public.notification_templates where key = 'installment_due'),
    3
  );
begin
  return public.notify_installment_moment(-v_lead, 'installment_due');
end;
$fn$;

revoke all on function public.notify_upcoming_installments(integer)
  from public, anon, authenticated;

create or replace function public.notify_installments_due_today()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $fn$
  select public.notify_installment_moment(0, 'installment_due_today');
$fn$;

revoke all on function public.notify_installments_due_today()
  from public, anon, authenticated;

/** El cierre del día del vencimiento. Solo lo recibe quien no ha pagado. */
create or replace function public.notify_installments_due_today_evening()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $fn$
  select public.notify_installment_moment(0, 'installment_due_today_evening');
$fn$;

revoke all on function public.notify_installments_due_today_evening()
  from public, anon, authenticated;

/**
 * Cualquiera de los peldaños de atraso.
 *
 * Uno solo para los cuatro: lo que los distingue es el `lead_days` de su
 * plantilla, y eso lo edita el panel. Cuatro funciones idénticas habrían sido
 * cuatro sitios donde corregir el mismo fallo.
 */
create or replace function public.notify_installments_late(p_key text)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_days integer;
begin
  select lead_days into v_days
  from public.notification_templates where key = p_key;

  if v_days is null or v_days < 1 then
    raise exception 'El aviso % no tiene un día de atraso configurado', p_key
      using errcode = '22023';
  end if;

  return public.notify_installment_moment(v_days, p_key);
end;
$fn$;

comment on function public.notify_installments_late(text) is
  'Un peldano de la escalera de atrasos. El dia sale del lead_days de su plantilla, que se edita en el panel.';

revoke all on function public.notify_installments_late(text)
  from public, anon, authenticated;

-- Los dos nombres viejos se quedan como alias de su peldaño. No se borran: una
-- función que sigue existiendo pero llama a una clave que ya no está sería una
-- excepción esperando a que alguien la invoque desde una consola o desde un
-- cron que se hubiera quedado atrás.
create or replace function public.notify_installments_late_first()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $fn$
  select public.notify_installments_late('installment_late_d1');
$fn$;

revoke all on function public.notify_installments_late_first()
  from public, anon, authenticated;

create or replace function public.notify_installments_before_late_fee()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $fn$
  select public.notify_installments_late('installment_late_d3');
$fn$;

revoke all on function public.notify_installments_before_late_fee()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. El catálogo
-- ---------------------------------------------------------------------------
-- Primero los renombrados, con el historial detrás. `notifications.template_key`
-- no tiene clave foránea —es texto suelto— así que se actualiza a mano.

update public.notifications set template_key = 'installment_late_d1'
 where template_key = 'installment_late_first';
update public.notifications set template_key = 'installment_late_d3'
 where template_key = 'installment_late_fee_eve';

update public.notification_templates set key = 'installment_late_d1'
 where key = 'installment_late_first';
update public.notification_templates set key = 'installment_late_d3'
 where key = 'installment_late_fee_eve';

-- Los cuatro que ya existían: día, hora, rótulos y texto de fábrica.

update public.notification_templates
   set label         = 'Tu cuota vence pronto',
       trigger_label = 'Cron diario, tres días antes del vencimiento.',
       help          = 'Un aviso por FECHA de pago, no por cuota: {monto} es el total de ese día y {cuotas} cuántas lo componen. {dia} es el día de la semana, que es lo que hace la fecha recordable.',
       variables     = array['dias', 'dia', 'fecha', 'monto', 'cuotas', 'comercio'],
       required_variables = array['monto'],
       default_title = 'Tu cuota de €{monto} vence el {dia}',
       default_body  = 'El {dia} {fecha} vence una cuota de €{monto}. Puedes adelantarte y pagarla ahora desde la aplicación.',
       cron_job      = 'helios_installment_reminders',
       lead_days     = 3,
       run_at        = '19:00'::time,
       sort_order    = 60
 where key = 'installment_due';

update public.notification_templates
   set label         = 'Tu cuota vence hoy (mañana)',
       trigger_label = 'Cron diario, la mañana del vencimiento.',
       help          = 'Abre el día del vencimiento. Último día sin consecuencias: al siguiente se bloquea el saldo. El cargo por mora todavía no toca — para eso está el peldaño que coincide con la gracia.',
       variables     = array['dia', 'fecha', 'monto', 'cuotas', 'comercio'],
       required_variables = array['monto'],
       default_title = 'Hoy vence tu cuota de €{monto}',
       default_body  = 'Tu cuota de €{monto} vence hoy, {dia} {fecha}. Complétala desde la aplicación antes de que finalice el día.',
       cron_job      = 'helios_installment_due_today',
       lead_days     = null,
       run_at        = '08:00'::time,
       sort_order    = 61
 where key = 'installment_due_today';

update public.notification_templates
   set label         = 'Cuota vencida: primer día',
       trigger_label = 'Cron diario, el día siguiente al vencimiento.',
       help          = 'El bloqueo entra el día 1 y no cuesta dinero: es lo único que hay que decir aquí. El cargo llega después y tiene su propio peldaño.',
       variables     = array['dias', 'dia', 'fecha', 'monto', 'cuotas', 'comercio'],
       required_variables = array['monto'],
       default_title = 'Tu cuota venció ayer y tu saldo está bloqueado',
       default_body  = 'La cuota de €{monto} del {dia} {fecha} está vencida. Regulariza el pago para recuperar tu saldo y volver a consumir en los locales.',
       cron_job      = 'helios_installment_late_d1',
       lead_days     = 1,
       run_at        = '19:10'::time,
       sort_order    = 63
 where key = 'installment_late_d1';

update public.notification_templates
   set label         = 'Cuota vencida: tercer día',
       trigger_label = 'Cron diario, al tercer día de retraso.',
       help          = 'Coincide con los días de gracia de la mora, así que su texto de fábrica anuncia el cargo de mañana. Si alguien cambia la gracia o mueve este día, el texto deja de prometer el cargo solo. {cargo} es lo que cuesta cada cuota retrasada.',
       variables     = array['dias', 'dia', 'fecha', 'monto', 'cuotas', 'comercio', 'cargo'],
       required_variables = array['monto'],
       default_title = 'Mañana se aplicará el cargo por mora',
       default_body  = 'Tu cuota de €{monto} del {dia} {fecha} acumula {dias} días de retraso. Si la pagas hoy, evitarás el cargo por mora de €{cargo} por cuota.',
       cron_job      = 'helios_installment_late_d3',
       lead_days     = 3,
       run_at        = '19:15'::time,
       sort_order    = 64
 where key = 'installment_late_d3';

-- Los tres nuevos.

insert into public.notification_templates (
  key, type, label, trigger_label, help,
  variables, required_variables,
  default_title, default_body,
  editable, can_disable, cron_job, lead_days, run_at, sort_order
) values
(
  'installment_due_today_evening', 'installment_due'::public.notification_type,
  'Tu cuota vence hoy (tarde)',
  'Cron diario, la tarde del vencimiento.',
  'Cierra el día del vencimiento y solo le llega a quien no ha pagado: el motor salta a quien ya reportó un pago. Es el último aviso antes del bloqueo, así que dice la consecuencia y no repite la cifra dos veces.',
  array['dia', 'fecha', 'monto', 'cuotas', 'comercio'],
  array['monto'],
  'Última oportunidad para pagar tu cuota de hoy',
  'Tu cuota de €{monto} del {dia} {fecha} continúa pendiente. Si no la registras hoy, mañana tu saldo quedará bloqueado.',
  true, true, 'helios_installment_due_today_evening', null, '19:05'::time, 62
),
(
  'installment_late_d5', 'installment_due'::public.notification_type,
  'Cuota vencida: quinto día',
  'Cron diario, al quinto día de retraso.',
  'El cargo por mora ya corre. Aquí no se anuncia nada nuevo: se recuerda que la cuenta sigue bloqueada y que el cargo sigue sumando.',
  array['dias', 'dia', 'fecha', 'monto', 'cuotas', 'comercio', 'cargo'],
  array['monto'],
  'Tu cuota acumula {dias} días de retraso',
  'La cuota de €{monto} del {dia} {fecha} continúa vencida y ya genera cargos por mora. Regularízala para detener el cargo y recuperar tu saldo.',
  true, true, 'helios_installment_late_d5', 5, '19:20'::time, 65
),
(
  'installment_late_d7', 'installment_due'::public.notification_type,
  'Cuota vencida: una semana',
  'Cron diario, al séptimo día de retraso.',
  'El último de la escalera. Nombra la siguiente consecuencia real —la bajada de nivel— leyendo el parámetro del servidor en {dias_nivel}, para no prometer una fecha que el motor de mora no respete.',
  array['dias', 'dia', 'fecha', 'monto', 'cuotas', 'comercio', 'cargo', 'dias_nivel'],
  array['monto'],
  'Una semana de retraso en tu cuota',
  'La cuota de €{monto} del {dia} {fecha} lleva {dias} días vencida. A los {dias_nivel} días de retraso tu nivel se reduce automáticamente.',
  true, true, 'helios_installment_late_d7', 7, '19:25'::time, 66
)
on conflict (key) do nothing;

-- El marcador nuevo llega a los cuatro peldaños de atraso: cualquiera de ellos
-- puede querer nombrar la bajada de nivel, no solo el último.
update public.notification_templates
   set variables = array['dias', 'dia', 'fecha', 'monto', 'cuotas', 'comercio', 'cargo', 'dias_nivel']
 where key in ('installment_late_d1', 'installment_late_d3', 'installment_late_d5', 'installment_late_d7');

-- ---------------------------------------------------------------------------
-- 5. Los crons
-- ---------------------------------------------------------------------------
-- Uno por momento, porque el panel edita la hora de CADA aviso por separado.
-- Las horas son de Caracas (UTC−4, sin horario de verano): 19:00 son las 23:00
-- UTC y las 08:00 son las 12:00 UTC.
--
-- Los cinco de la tarde van escalonados de cinco en cinco a partir de las
-- 19:00 y no todos a la vez: son cinco recorridos de la tabla de cuotas y
-- solaparlos no gana nada. Una persona con dos deudas de tramos distintos
-- recibe dos avisos, que es lo correcto — son dos fechas de pago distintas.
--
-- `cron.schedule` con un nombre que ya existe reemplaza el trabajo, así que
-- volver a correr esta migración no duplica nada.

select cron.schedule(
  'helios_installment_reminders',
  '0 23 * * *',
  $cron$ select public.notify_upcoming_installments(); $cron$
);

select cron.schedule(
  'helios_installment_due_today',
  '0 12 * * *',
  $cron$ select public.notify_installments_due_today(); $cron$
);

select cron.schedule(
  'helios_installment_due_today_evening',
  '5 23 * * *',
  $cron$ select public.notify_installments_due_today_evening(); $cron$
);

select cron.schedule(
  'helios_installment_late_d1',
  '10 23 * * *',
  $cron$ select public.notify_installments_late('installment_late_d1'); $cron$
);

select cron.schedule(
  'helios_installment_late_d3',
  '15 23 * * *',
  $cron$ select public.notify_installments_late('installment_late_d3'); $cron$
);

select cron.schedule(
  'helios_installment_late_d5',
  '20 23 * * *',
  $cron$ select public.notify_installments_late('installment_late_d5'); $cron$
);

select cron.schedule(
  'helios_installment_late_d7',
  '25 23 * * *',
  $cron$ select public.notify_installments_late('installment_late_d7'); $cron$
);

-- Los dos trabajos con el nombre viejo se retiran DESPUÉS de programar los
-- nuevos: si algo fallara por el camino, lo que quedaría es un aviso repetido
-- y no un aviso perdido.
do $old$
begin
  begin
    perform cron.unschedule('helios_installment_late_first');
  exception when others then
    null;
  end;

  begin
    perform cron.unschedule('helios_installment_late_fee_eve');
  exception when others then
    null;
  end;
end;
$old$;

-- ---------------------------------------------------------------------------
-- 6. Reportar un pago frena los avisos que quedaran en cola
-- ---------------------------------------------------------------------------
-- El motor ya salta a quien tiene un pago esperando conciliación, así que un
-- aviso FUTURO no se crea. Lo que faltaba es lo que ya está escrito: entre que
-- el cron crea el aviso y `dispatch_push_queue` lo manda pasan hasta quince
-- segundos, y el reporte puede caer justo en medio. Son pocos segundos, pero
-- el aviso que se cuela por ahí es el peor de todos: le pide pagar a alguien
-- que acaba de pagar.
--
-- Se cancela por FECHA DE VENCIMIENTO, no todo lo del usuario: si alguien paga
-- la cuota del viernes y tiene otra vencida del lunes, el aviso del lunes sigue
-- siendo verdad y tiene que salir.
--
-- La bandeja de la app se trata igual: los recordatorios de esas fechas que
-- siguieran sin leer se marcan como leídos. Un pago reportado y un "paga tu
-- cuota" esperando en Avisos es la misma contradicción, solo que sin sonido.

create or replace function public.cancel_installment_pushes_on_report()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_dates text[];
begin
  select coalesce(array_agg(distinct i.due_date::text), '{}'::text[])
    into v_dates
  from public.payment_quote_items q
  join public.installments i on i.id = q.installment_id
  where q.quote_id = new.quote_id;

  if array_length(v_dates, 1) is null then
    return null;
  end if;

  with avisos as (
    select n.id
    from public.notifications n
    where n.user_id = new.user_id
      and n.type = 'installment_due'
      and n.data->>'due_date' = any (v_dates)
  )
  update public.push_deliveries d
     set status     = 'cancelled',
         error      = 'Cancelado: el usuario reportó el pago antes de que saliera',
         settled_at = now()
    from avisos a
   where d.notification_id = a.id
     and d.status = 'pending';

  update public.notifications
     set read_at = now()
   where user_id = new.user_id
     and type = 'installment_due'
     and read_at is null
     and data->>'due_date' = any (v_dates);

  return null;
end;
$fn$;

comment on function public.cancel_installment_pushes_on_report() is
  'Al reportar un pago, frena los recordatorios de esas fechas que siguieran en la cola de push y apaga los que quedaran sin leer en la bandeja.';

revoke all on function public.cancel_installment_pushes_on_report()
  from public, anon, authenticated;

drop trigger if exists payment_reports_cancel_pushes on public.payment_reports;
create trigger payment_reports_cancel_pushes
  after insert on public.payment_reports
  for each row execute function public.cancel_installment_pushes_on_report();

-- ---------------------------------------------------------------------------
-- 7. El panel cuenta también lo cancelado
-- ---------------------------------------------------------------------------
-- Sin esto, un aviso cancelado desaparecería de la cuenta del panel: saldría
-- en "avisos" y no en "entregados" ni en "fallidos", y la resta parecería una
-- fuga. Es justo el número que hay que poder enseñar — dice cuántas veces el
-- sistema se calló a tiempo.

create or replace function public.admin_notification_catalog()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo para el equipo de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.sort_order), '[]'::jsonb)
    into v_rows
  from (
    select
      t.key, t.type::text as type, t.label, t.trigger_label, t.help,
      t.variables, t.required_variables,
      t.default_title, t.default_body,
      t.title, t.body,
      t.draft_title, t.draft_body, t.draft_at,
      t.enabled, t.editable, t.can_disable,
      t.cron_job, t.lead_days, t.run_at, t.sort_order,
      t.published_at,
      pa.full_name as published_by,
      da.full_name as draft_by,

      -- Cómo lo pinta el teléfono. Se lo preguntamos al sobre real.
      (public.push_envelope(
        'preview', t.type, '', '', '{}'::jsonb,
        '00000000-0000-0000-0000-000000000000'::uuid
      ) ->> 'channelId') as channel,
      (public.push_envelope(
        'preview', t.type, '', '', '{}'::jsonb,
        '00000000-0000-0000-0000-000000000000'::uuid
      ) ->> 'priority') as priority,

      -- Los últimos 30 días.
      (select count(*) from public.notifications n
        where n.template_key = t.key
          and n.created_at > now() - interval '30 days') as sent,
      (select count(*) from public.notifications n
        where n.template_key = t.key
          and n.created_at > now() - interval '30 days'
          and n.read_at is not null) as opened,
      (select count(*) from public.push_deliveries d
        join public.notifications n on n.id = d.notification_id
        where n.template_key = t.key
          and n.created_at > now() - interval '30 days'
          and d.status = 'delivered') as delivered,
      (select count(*) from public.push_deliveries d
        join public.notifications n on n.id = d.notification_id
        where n.template_key = t.key
          and n.created_at > now() - interval '30 days'
          and d.status = 'failed') as failed,
      (select count(*) from public.push_deliveries d
        join public.notifications n on n.id = d.notification_id
        where n.template_key = t.key
          and n.created_at > now() - interval '30 days'
          and d.status = 'cancelled') as cancelled,
      (select max(n.created_at) from public.notifications n
        where n.template_key = t.key) as last_sent_at
    from public.notification_templates t
    left join public.platform_admins pa on pa.user_id = t.published_by
    left join public.platform_admins da on da.user_id = t.draft_by
  ) q;

  return v_rows;
end;
$fn$;

comment on function public.admin_notification_catalog() is
  'Los avisos automáticos: qué los dispara, su texto, su borrador y su alcance real.';

revoke all on function public.admin_notification_catalog() from public, anon;
grant execute on function public.admin_notification_catalog() to authenticated;

-- ---------------------------------------------------------------------------
-- 8. La prioridad del recordatorio sube a 'high'
-- ---------------------------------------------------------------------------
-- Cuando el recordatorio era uno solo y salía dos días antes, 'normal' —que
-- espera a que el teléfono salga de reposo— era la elección correcta: podía
-- esperar. La escalera de siete ya no puede. Cinco de sus peldaños hablan de
-- un saldo bloqueado o de un cargo que entra mañana, y llegar media hora tarde
-- a las siete de la tarde es llegar cuando el banco ya se cerró.

create or replace function public.push_envelope(
  p_token           text,
  p_type            public.notification_type,
  p_title           text,
  p_body            text,
  p_data            jsonb,
  p_notification_id uuid
)
returns jsonb
language sql
immutable
set search_path = public, pg_temp
as $fn$
  select jsonb_build_object(
    'to',    p_token,
    'title', p_title,
    'body',  p_body,
    'data',  coalesce(p_data, '{}'::jsonb)
             || jsonb_build_object('type', p_type::text, 'notification_id', p_notification_id),
    'sound', 'default',
    'channelId', case p_type::text
                   when 'group_charge'        then 'grupos'
                   when 'group_released'      then 'grupos'
                   when 'payment_reconciled'  then 'cuotas'
                   when 'payment_rejected'    then 'cuotas'
                   when 'installment_due'     then 'cuotas'
                   else 'cuenta'
                 end,
    -- 'normal' se queda para lo que de verdad puede esperar a que el teléfono
    -- salga de reposo: nada de esto informa de una consecuencia con fecha.
    'priority', case p_type::text
                  when 'promo'             then 'normal'
                  when 'bits_earned'       then 'normal'
                  when 'level_up'          then 'normal'
                  when 'waitlist_joined'   then 'normal'
                  when 'waitlist_released' then 'normal'
                  else 'high'
                end,
    'ttl', 86400
  );
$fn$;

comment on function public.push_envelope(text, public.notification_type, text, text, jsonb, uuid) is
  'Mensaje para la API de Expo a partir de un aviso. Decide canal y prioridad.';

revoke all on function public.push_envelope(text, public.notification_type, text, text, jsonb, uuid)
  from public, anon, authenticated;
