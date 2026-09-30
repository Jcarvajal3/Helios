-- ============================================================================
-- Ronda — El recordatorio de cuota es UNO POR FECHA, y son cuatro momentos
--
-- Decisión del 2026-09-04, de la auditoría de usabilidad del pago de cuotas.
--
-- ---------------------------------------------------------------------------
-- 1. Un aviso por CUOTA no es un aviso: son tres avisos del mismo pago
-- ---------------------------------------------------------------------------
-- `notify_upcoming_installments` recorría cuotas sueltas, así que quien salió
-- dos veces el mismo fin de semana recibía dos notificaciones para el mismo
-- día, cada una con media cifra. Y ninguna de las dos decía lo que se paga ese
-- día, que es lo único que hay que saber para ir al banco.
--
-- Ahora la unidad es la **fecha de pago**: un aviso por usuario y día, con el
-- total de ese día y cuántas cuotas lo componen. Es la misma unidad que desde
-- hoy tiene la pestaña Cuotas —su línea de fechas— y la que ya usaba Inicio.
--
-- ---------------------------------------------------------------------------
-- 2. Un solo aviso para un ciclo de siete días
-- ---------------------------------------------------------------------------
-- Con cuotas semanales, una semana sin abrir la app es mora. Había UN aviso,
-- dos días antes, y después silencio: ni el día del vencimiento, ni el día que
-- la cuenta se bloquea, ni la víspera del cargo. Cada uno de esos tres momentos
-- es una consecuencia distinta y evitable, y la única forma de que se eviten es
-- decirlas cuando todavía se pueden evitar.
--
--   | Momento            | Qué ha pasado ya          | Qué se puede evitar  |
--   |--------------------|---------------------------|----------------------|
--   | −2 días            | nada                      | todo                 |
--   | el día             | nada                      | el bloqueo           |
--   | +1 día             | saldo bloqueado           | el cargo             |
--   | víspera del cargo  | saldo bloqueado           | los $2 por cuota     |
--
-- El cuarto no va clavado al día 3: sale de `helios_late_fee_grace_days()`, así
-- que si la gracia cambia, la víspera se mueve con ella. Un aviso que promete
-- una fecha equivocada es peor que no avisar.
--
-- ---------------------------------------------------------------------------
-- 3. El día de la semana, en los cuatro
-- ---------------------------------------------------------------------------
-- Las cuotas caen a 7 y 14 días del consumo (docs/00-BASES §2.2): siempre en el
-- mismo día de la semana en que se salió. "Tu cuota del sábado" es una frase
-- que alguien puede situar sin abrir el calendario; "vence el 06/09" no. El
-- marcador `{dia}` está en los cuatro avisos y sale de `helios_weekday_es`.
--
-- ---------------------------------------------------------------------------
-- 4. Quien ya reportó su pago no recibe nada
-- ---------------------------------------------------------------------------
-- Es la misma contradicción que la app acaba de quitarse de encima en Inicio:
-- una cuota con un pago esperando conciliación se sigue debiendo, pero decirle
-- a quien transfirió ayer que está vencido y bloqueado es la forma más rápida
-- de que pague dos veces. La condición es la misma de
-- `my_installments_in_review`, escrita aquí sin `auth.uid()` porque esto corre
-- en el cron y no tiene sesión.
--
-- ---------------------------------------------------------------------------
-- Al desplegar
-- ---------------------------------------------------------------------------
-- El texto de fábrica de `installment_due` cambia (pasa a hablar de la fecha y
-- no de la cuota). Lo que alguien haya PUBLICADO desde el panel no se toca: se
-- sigue usando mientras se pueda renderizar, y sus marcadores viejos —{monto},
-- {comercio}, {fecha}, {dias}— siguen existiendo con el nuevo significado por
-- fecha. Los tres avisos nuevos entran apagables y editables, cada uno con su
-- hora, y aparecen solos en el panel: el catálogo se lee entero.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El día de la semana, en castellano
-- ---------------------------------------------------------------------------
-- `to_char(d, 'TMDay')` depende del `lc_time` del servidor, que en Supabase es
-- inglés. Una tabla de siete nombres no depende de nada.

create or replace function public.helios_weekday_es(p_day date)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$
  select (array['domingo','lunes','martes','miércoles','jueves','viernes','sábado'])
         [extract(dow from p_day)::integer + 1]
$fn$;

comment on function public.helios_weekday_es(date) is
  'El dia de la semana en castellano y en minusculas. Para los avisos de cuotas: las cuotas caen siempre el mismo dia de la semana que la compra.';

revoke all on function public.helios_weekday_es(date) from public, anon;
grant execute on function public.helios_weekday_es(date) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El motor: un aviso por usuario y fecha de pago
-- ---------------------------------------------------------------------------
/**
 * `p_offset` son días transcurridos desde el vencimiento:
 *
 *   −2  dos días antes        0  el mismo día
 *   +1  un día de retraso     +3 tres días de retraso
 *
 * Se llama una vez por momento con su clave de plantilla, y cada llamada es
 * idempotente: si ya hay un aviso de esa clave para esa fecha, no manda otro.
 * Dos corridas del cron el mismo día no duplican nada.
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
  v_row     record;
  v_count   integer := 0;
  v_due     date := public.helios_business_date(now()) - p_offset;
  v_tpl     public.notification_templates%rowtype;
  v_fee     numeric := public.helios_late_fee_usd();
  v_dia     text := public.helios_weekday_es(v_due);
  v_fecha   text := to_char(v_due, 'DD/MM');
  v_comercio text;
begin
  select * into v_tpl from public.notification_templates where key = p_key;

  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = '22023';
  end if;

  -- Apagado desde el panel: ni se busca a quién avisar. `notify` lo comprobaría
  -- igual, pero por fila y después de recorrer la tabla entera.
  if not v_tpl.enabled then
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
      -- pero el usuario ya hizo lo suyo.
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

    perform public.notify(
      v_row.user_id,
      'installment_due'::public.notification_type,
      -- El texto de fábrica, por si nadie publicó nada desde el panel. Se
      -- construye igual que el de la plantilla, con los mismos datos.
      case
        when p_offset < 0 then format('Tu cuota del %s', v_dia)
        when p_offset = 0 then format('Hoy pagas $%s',
                                      trim(to_char(v_row.monto, 'FM999999990.00')))
        when p_offset = 1 then 'Tu cuota está vencida'
        else 'Mañana se suma el cargo por mora'
      end,
      case
        when p_offset < 0 then format('$%s el %s %s. Toca para pagarla.',
                                      trim(to_char(v_row.monto, 'FM999999990.00')),
                                      v_dia, v_fecha)
        when p_offset = 0 then format('Tu cuota del %s %s. Hoy es el último día sin bloqueo.',
                                      v_dia, v_fecha)
        when p_offset = 1 then format('$%s del %s %s. Hasta que la pagues no puedes pagar en locales.',
                                      trim(to_char(v_row.monto, 'FM999999990.00')),
                                      v_dia, v_fecha)
        else format('Paga hoy los $%s del %s %s y te ahorras $%s por cuota.',
                    trim(to_char(v_row.monto, 'FM999999990.00')),
                    v_dia, v_fecha,
                    trim(to_char(v_fee, 'FM999999990.00')))
      end,
      -- `due_date` es lo que abre Cuotas con esa fecha ya marcada. Viajaba
      -- desde el primer día y hasta ahora no lo usaba nadie.
      jsonb_build_object('due_date', v_due, 'moment', p_key),
      p_key,
      jsonb_build_object(
        'dia',      v_dia,
        'fecha',    v_fecha,
        'dias',     abs(p_offset),
        'monto',    trim(to_char(v_row.monto, 'FM999999990.00')),
        'cuotas',   v_row.cuotas,
        'comercio', v_comercio,
        'cargo',    trim(to_char(v_fee, 'FM999999990.00'))
      )
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$fn$;

comment on function public.notify_installment_moment(integer, text) is
  'Un aviso por usuario y FECHA de pago, con el total del dia. p_offset son dias desde el vencimiento: -2 antes, 0 el dia, +1 y +3 despues. Idempotente por (plantilla, fecha).';

revoke all on function public.notify_installment_moment(integer, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Los cuatro momentos
-- ---------------------------------------------------------------------------
-- El primero conserva su nombre y su firma: la orden del cron y la antelación
-- que se edita desde el panel siguen apuntando aquí.

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
    2
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

create or replace function public.notify_installments_late_first()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $fn$
  select public.notify_installment_moment(1, 'installment_late_first');
$fn$;

revoke all on function public.notify_installments_late_first()
  from public, anon, authenticated;

/**
 * La víspera del cargo, y no "el día 3".
 *
 * El cargo entra cuando el retraso SUPERA la gracia, así que la víspera es
 * exactamente el último día de gracia. Leerlo de la función en vez de fijarlo
 * evita el peor fallo posible en un aviso: prometer una fecha que el motor de
 * mora no respeta.
 */
create or replace function public.notify_installments_before_late_fee()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $fn$
  select public.notify_installment_moment(
    public.helios_late_fee_grace_days(),
    'installment_late_fee_eve'
  );
$fn$;

revoke all on function public.notify_installments_before_late_fee()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. El catálogo
-- ---------------------------------------------------------------------------
-- El de fábrica de `installment_due` pasa a hablar de la FECHA. Se actualizan
-- `default_*` y `variables` —el texto del código manda sobre el catálogo— y no
-- se toca `title`/`body`, que es lo que alguien pueda haber publicado.

update public.notification_templates
   set label         = 'Tu cuota vence pronto',
       trigger_label = 'Cron diario. Avisa de lo que vence dentro de los días de antelación.',
       help          = 'Un aviso por FECHA de pago, no por cuota: {monto} es el total de ese día y {cuotas} cuántas lo componen. {dia} es el día de la semana, que es lo que hace la fecha recordable.',
       variables     = array['dias', 'dia', 'fecha', 'monto', 'cuotas', 'comercio'],
       default_title = 'Tu cuota del {dia}',
       default_body  = '${monto} el {dia} {fecha}. Toca para pagarla.'
 where key = 'installment_due';

insert into public.notification_templates (
  key, type, label, trigger_label, help,
  variables, required_variables,
  default_title, default_body,
  editable, can_disable, cron_job, lead_days, run_at, sort_order
) values
(
  'installment_due_today', 'installment_due'::public.notification_type,
  'Tu cuota vence hoy',
  'Cron diario, la mañana del vencimiento.',
  'Último día sin consecuencias: al día siguiente se bloquea el saldo. No repitas aquí el cargo por mora, que todavía no toca — para eso está el aviso de la víspera.',
  array['dia', 'fecha', 'monto', 'cuotas', 'comercio'],
  array['monto'],
  'Hoy pagas ${monto}',
  'Tu cuota del {dia} {fecha}. Hoy es el último día sin bloqueo.',
  true, true, 'helios_installment_due_today', null, '10:20'::time, 61
),
(
  'installment_late_first', 'installment_due'::public.notification_type,
  'Cuota vencida: cuenta bloqueada',
  'Cron diario, el día siguiente al vencimiento.',
  'El bloqueo entra el día 1 y no cuesta dinero: es lo único que hay que decir aquí. El cargo llega después y tiene su propio aviso.',
  array['dia', 'fecha', 'monto', 'cuotas', 'comercio'],
  array['monto'],
  'Tu cuota está vencida',
  '${monto} del {dia} {fecha}. Hasta que la pagues no puedes pagar en locales.',
  true, true, 'helios_installment_late_first', null, '10:25'::time, 62
),
(
  'installment_late_fee_eve', 'installment_due'::public.notification_type,
  'Mañana se suma el cargo por mora',
  'Cron diario, el último día de gracia antes del cargo.',
  'El día sale de helios_late_fee_grace_days(), así que si la gracia cambia el aviso se mueve solo. {cargo} es lo que cuesta cada cuota retrasada.',
  array['dia', 'fecha', 'monto', 'cuotas', 'comercio', 'cargo'],
  array['monto', 'cargo'],
  'Mañana se suma el cargo por mora',
  'Paga hoy los ${monto} del {dia} {fecha} y te ahorras ${cargo} por cuota.',
  true, true, 'helios_installment_late_fee_eve', null, '10:30'::time, 63
)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 5. Los crons
-- ---------------------------------------------------------------------------
-- Uno por momento, y no uno que los dispare todos: el panel edita la hora de
-- CADA aviso (`admin_set_notification_schedule` reprograma el `cron_job` de su
-- plantilla), así que compartir trabajo sería mover tres avisos al cambiar uno.
--
-- Escalonados de cinco en cinco a partir de las 10:15 de Caracas (14:15 UTC),
-- justo después del barrido de mora. `cron.schedule` con un nombre que ya
-- existe reemplaza el trabajo, así que volver a correr esta migración no
-- duplica nada.

select cron.schedule(
  'helios_installment_due_today',
  '20 14 * * *',
  $cron$ select public.notify_installments_due_today(); $cron$
);

select cron.schedule(
  'helios_installment_late_first',
  '25 14 * * *',
  $cron$ select public.notify_installments_late_first(); $cron$
);

select cron.schedule(
  'helios_installment_late_fee_eve',
  '30 14 * * *',
  $cron$ select public.notify_installments_before_late_fee(); $cron$
);
