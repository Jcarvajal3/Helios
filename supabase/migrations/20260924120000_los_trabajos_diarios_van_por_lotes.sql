-- ============================================================================
-- Ronda — Los trabajos diarios van por lotes
--
-- La mora, las liquidaciones programadas, los niveles y los siete avisos de
-- cuota eran, cada uno, UNA transacción que recorría a toda la gente de una
-- vez. Con el piloto duran menos de 0,3 s; con un millón de cuotas la mora
-- tendría bloqueadas durante minutos las filas de miles de perfiles, no se
-- mandaría ningún aviso hasta el COMMIT final, y un fallo a mitad desharía
-- todo lo hecho.
--
-- Cada trabajo se parte en:
--   · una función `*_batch` que procesa hasta N personas (o consumos) con un
--     cursor por clave (`> p_after ... order by ... limit`), y
--   · un procedure `*_loop` que la llama y hace COMMIT después de cada lote.
--     Es lo que corre el cron, igual que `dispatch_push_queue_loop`.
--
-- Las funciones de siempre (`process_mora()`, `run_scheduled_settlements(d)`,
-- `process_level_promotions()`, `notify_installment_moment(o, k)` y sus
-- envoltorios) se quedan con la misma firma y el mismo resultado, ahora
-- recorriendo los mismos lotes sin commit: las usan el kit de QA del panel,
-- `reconcile_payment` y los avisos viejos que aún existen.
--
-- Por qué no hace falta retomar donde se quedó: el trabajo por persona ya es
-- idempotente. La mora se recalcula desde el estado, el cargo por mora es uno
-- por cuota, el aviso comprueba si ya se mandó esa fecha y la liquidación si
-- ya existe la de ese día. Si una corrida falla a mitad, lo confirmado queda
-- y la siguiente repite el resto sin duplicar nada.
--
-- Dos cambios de comportamiento, a propósito:
--
--   1. Los niveles corren DETRÁS de la mora, en el mismo trabajo, y no a una
--      hora fija. Con la mora confirmando por lotes, un trabajo de niveles a
--      su hora podría leer a alguien a quien la mora todavía no ha congelado
--      y subirle de nivel. Si la mora falla, ese día no se evalúan niveles:
--      es preferible a promocionar con un estado a medias. El trabajo
--      `helios_level_promotions` se retira.
--
--   2. Las liquidaciones repasan los últimos 7 días, no solo el de hoy. Si un
--      día no corrió (mantenimiento, reinicio, un fallo), los tramos de ese
--      día se devengaban nunca y en silencio. La comprobación de "ya existe la
--      liquidación de ese consumo en esa fecha" hace que repasar un día ya
--      hecho no cree nada. Lotes de 50 consumos: cada uno abre su propio
--      subbloque, y por debajo de 64 no se desborda la caché de
--      subtransacciones del backend.
--
-- Los procedures no llevan SECURITY DEFINER ni `set search_path`: Postgres no
-- deja hacer COMMIT en ninguno de los dos casos. Todo va cualificado con
-- `public.`. Los ejecuta pg_cron como `postgres` y ningún rol de la API puede
-- llamarlos.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Mora
-- ---------------------------------------------------------------------------

create or replace function public.process_mora_batch(p_after uuid, p_limit integer)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_bd    date := public.helios_business_date(now());
  v_row   record;
  v_last  uuid := p_after;
  v_count integer := 0;
begin
  for v_row in
    select i.user_id
      from public.installments i
     where i.status = 'pending' and i.due_date < v_bd and i.user_id > p_after
    union
    select p.id
      from public.profiles p
     where p.status in ('frozen', 'suspended') and p.id > p_after
    order by 1
    limit p_limit
  loop
    perform public.recompute_profile_mora_state(v_row.user_id);
    v_last  := v_row.user_id;
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('last', v_last, 'processed', v_count);
end;
$fn$;

revoke all on function public.process_mora_batch(uuid, integer) from public, anon, authenticated;

create or replace function public.process_mora()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_after uuid := '00000000-0000-0000-0000-000000000000';
  v_res   jsonb;
  v_total integer := 0;
begin
  loop
    v_res   := public.process_mora_batch(v_after, 500);
    v_total := v_total + (v_res ->> 'processed')::integer;
    exit when (v_res ->> 'processed')::integer < 500;
    v_after := (v_res ->> 'last')::uuid;
  end loop;

  return v_total;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. Niveles
-- ---------------------------------------------------------------------------

create or replace function public.process_level_promotions_batch(p_after uuid, p_limit integer)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_top      smallint;
  v_row      record;
  v_result   jsonb;
  v_last     uuid := p_after;
  v_seen     integer := 0;
  v_promoted integer := 0;
begin
  select max(level) into v_top from public.levels where is_active;

  for v_row in
    select id from public.profiles
     where status = 'active' and level < v_top and id > p_after
     order by id
     limit p_limit
  loop
    v_result := public.evaluate_level(v_row.id);
    if (v_result ->> 'promoted')::boolean then
      v_promoted := v_promoted + 1;
    end if;
    v_last := v_row.id;
    v_seen := v_seen + 1;
  end loop;

  return jsonb_build_object('last', v_last, 'seen', v_seen, 'promoted', v_promoted);
end;
$fn$;

revoke all on function public.process_level_promotions_batch(uuid, integer) from public, anon, authenticated;

create or replace function public.process_level_promotions()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_after uuid := '00000000-0000-0000-0000-000000000000';
  v_res   jsonb;
  v_total integer := 0;
begin
  loop
    v_res   := public.process_level_promotions_batch(v_after, 500);
    v_total := v_total + (v_res ->> 'promoted')::integer;
    exit when (v_res ->> 'seen')::integer < 500;
    v_after := (v_res ->> 'last')::uuid;
  end loop;

  return v_total;
end;
$fn$;

create or replace procedure public.process_level_promotions_loop(p_batch integer default 500)
language plpgsql
as $proc$
declare
  v_after uuid := '00000000-0000-0000-0000-000000000000';
  v_res   jsonb;
begin
  loop
    v_res := public.process_level_promotions_batch(v_after, p_batch);
    commit;
    exit when (v_res ->> 'seen')::integer < p_batch;
    v_after := (v_res ->> 'last')::uuid;
  end loop;
end;
$proc$;

revoke all on procedure public.process_level_promotions_loop(integer) from public, anon, authenticated;

create or replace procedure public.process_mora_loop(p_batch integer default 500)
language plpgsql
as $proc$
declare
  v_after uuid := '00000000-0000-0000-0000-000000000000';
  v_res   jsonb;
begin
  loop
    v_res := public.process_mora_batch(v_after, p_batch);
    commit;
    exit when (v_res ->> 'processed')::integer < p_batch;
    v_after := (v_res ->> 'last')::uuid;
  end loop;

  -- Detrás de la mora y no a su hora: ver el punto 1 de la cabecera.
  call public.process_level_promotions_loop(p_batch);
end;
$proc$;

revoke all on procedure public.process_mora_loop(integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Liquidaciones programadas
-- ---------------------------------------------------------------------------
-- El cuerpo de cada consumo es el de 20260911206000, sin cambios: condiciones
-- del día de la venta, "ya existe", techo del neto y un bloque por consumo.

create or replace function public.run_scheduled_settlements_batch(
  p_business_date date,
  p_after uuid,
  p_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_charge  record;
  v_terms   public.merchant_terms;
  v_amount  numeric(18,4);
  v_room    numeric(18,4);
  v_last    uuid := p_after;
  v_seen    integer := 0;
  v_created integer := 0;
begin
  for v_charge in
    select distinct c.id as charge_id, c.merchant_id, c.business_date,
           coalesce(c.merchant_net_usd, c.amount_usd) as net_usd
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.due_date = p_business_date
      and c.id > p_after
    order by c.id
    limit p_limit
  loop
    v_last := v_charge.charge_id;
    v_seen := v_seen + 1;

    begin
      select * into v_terms
      from public.helios_terms_at(
        v_charge.merchant_id,
        coalesce(v_charge.business_date, p_business_date)
      );

      if coalesce(v_terms.policy::text, '') <> 'scheduled' then
        continue;
      end if;

      if exists (
        select 1 from public.settlements
        where charge_id = v_charge.charge_id
          and reason = 'scheduled_installment'
          and business_date = p_business_date
      ) then
        continue;
      end if;

      v_amount := round(v_charge.net_usd * v_terms.per_installment_pct / 100, 4);

      -- Por un consumo nunca se devenga más que su neto.
      select v_charge.net_usd - coalesce(sum(s.amount_usd), 0)
        into v_room
      from public.settlements s
      where s.charge_id = v_charge.charge_id;

      v_amount := least(v_amount, v_room);

      if v_amount <= 0 then
        continue;
      end if;

      insert into public.settlements
        (merchant_id, charge_id, installment_id, reason, amount_usd, business_date, due_date, status)
      values
        (v_charge.merchant_id, v_charge.charge_id, null, 'scheduled_installment',
         v_amount, p_business_date, p_business_date, 'pending');

      v_created := v_created + 1;
    exception when others then
      raise warning 'Liquidación programada fallida para el consumo % (comercio %): %',
        v_charge.charge_id, v_charge.merchant_id, sqlerrm;
    end;
  end loop;

  return jsonb_build_object('last', v_last, 'seen', v_seen, 'created', v_created);
end;
$fn$;

revoke all on function public.run_scheduled_settlements_batch(date, uuid, integer) from public, anon, authenticated;

create or replace function public.run_scheduled_settlements(p_business_date date)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_after uuid := '00000000-0000-0000-0000-000000000000';
  v_res   jsonb;
  v_total integer := 0;
begin
  loop
    v_res   := public.run_scheduled_settlements_batch(p_business_date, v_after, 50);
    v_total := v_total + (v_res ->> 'created')::integer;
    exit when (v_res ->> 'seen')::integer < 50;
    v_after := (v_res ->> 'last')::uuid;
  end loop;

  return v_total;
end;
$fn$;

create or replace procedure public.run_scheduled_settlements_loop(
  p_days_back integer default 7,
  p_batch integer default 50
)
language plpgsql
as $proc$
declare
  v_today date := public.helios_business_date(now());
  v_day   date;
  v_after uuid;
  v_res   jsonb;
begin
  -- Del día más viejo al de hoy: lo atrasado se devenga antes que lo nuevo.
  for v_back in reverse p_days_back .. 0 loop
    v_day   := v_today - v_back;
    v_after := '00000000-0000-0000-0000-000000000000';
    loop
      v_res := public.run_scheduled_settlements_batch(v_day, v_after, p_batch);
      commit;
      exit when (v_res ->> 'seen')::integer < p_batch;
      v_after := (v_res ->> 'last')::uuid;
    end loop;
  end loop;
end;
$proc$;

revoke all on procedure public.run_scheduled_settlements_loop(integer, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Avisos de cuota
-- ---------------------------------------------------------------------------

-- Cuántos días antes (negativo) o después (positivo) del vencimiento sale cada
-- aviso. Es la regla que tenían repartida los envoltorios de cada cron.
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

-- La fecha de vencimiento de la que habla un aviso, o null si hoy no sale:
-- apagado desde el panel, o un aviso de atraso que el motor de mora todavía
-- no da por vencido.
create or replace function public.helios_reminder_due_date(p_offset integer, p_key text)
returns date
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_enabled boolean;
  v_due     date := public.helios_caracas_date(now()) - p_offset;
begin
  select enabled into v_enabled from public.notification_templates where key = p_key;

  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = '22023';
  end if;

  if not v_enabled then
    return null;
  end if;

  if p_offset > 0 and public.helios_business_date(now()) <= v_due then
    return null;
  end if;

  return v_due;
end;
$fn$;

revoke all on function public.helios_reminder_due_date(integer, text) from public, anon, authenticated;

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

create or replace function public.notify_installment_moment(p_offset integer, p_key text)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_due   date := public.helios_reminder_due_date(p_offset, p_key);
  v_after uuid := '00000000-0000-0000-0000-000000000000';
  v_res   jsonb;
  v_total integer := 0;
begin
  if v_due is null then
    return 0;
  end if;

  loop
    v_res   := public.notify_installment_moment_batch(p_offset, p_key, v_due, v_after, 500);
    v_total := v_total + (v_res ->> 'sent')::integer;
    exit when (v_res ->> 'seen')::integer < 500;
    v_after := (v_res ->> 'last')::uuid;
  end loop;

  return v_total;
end;
$fn$;

create or replace procedure public.notify_reminder_loop(p_key text, p_batch integer default 500)
language plpgsql
as $proc$
declare
  v_offset integer := public.helios_reminder_offset(p_key);
  -- Se calcula una vez: la fecha del aviso no puede moverse entre lotes.
  v_due    date := public.helios_reminder_due_date(v_offset, p_key);
  v_after  uuid := '00000000-0000-0000-0000-000000000000';
  v_res    jsonb;
begin
  if v_due is null then
    return;
  end if;

  loop
    v_res := public.notify_installment_moment_batch(v_offset, p_key, v_due, v_after, p_batch);
    -- Los avisos del lote quedan en la cola del push antes de seguir: el
    -- despachador ya puede ir mandándolos.
    commit;
    exit when (v_res ->> 'seen')::integer < p_batch;
    v_after := (v_res ->> 'last')::uuid;
  end loop;
end;
$proc$;

revoke all on procedure public.notify_reminder_loop(text, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Cron
-- ---------------------------------------------------------------------------
-- Solo cambia el comando. La hora se queda: los avisos la editan desde el
-- panel (`admin_set_notification_schedule`), que reprograma copiando el
-- comando que encuentre, así que sigue funcionando con el nuevo.

select cron.alter_job(
  job_id  := (select jobid from cron.job where jobname = 'helios_process_mora'),
  command := 'call public.process_mora_loop()'
);

select cron.alter_job(
  job_id  := (select jobid from cron.job where jobname = 'helios_scheduled_settlements'),
  command := 'call public.run_scheduled_settlements_loop()'
);

select cron.unschedule('helios_level_promotions')
where exists (select 1 from cron.job where jobname = 'helios_level_promotions');

-- "Subiste de nivel" ya no tiene hora propia: sale cuando termina la mora. Sin
-- `cron_job`, el panel deja de ofrecer una hora que ya no manda nada, y
-- `admin_set_notification_schedule` responde que lo dispara un evento.
update public.notification_templates
   set cron_job      = null,
       run_at        = null,
       trigger_label = 'Cada mañana, en cuanto termina el barrido de mora de las 10:05.'
 where key = 'level_up';

select cron.alter_job(
  job_id  := j.jobid,
  command := format('call public.notify_reminder_loop(%L)', k.key)
)
from (values
  ('helios_installment_reminders',         'installment_due'),
  ('helios_installment_due_today',         'installment_due_today'),
  ('helios_installment_due_today_evening', 'installment_due_today_evening'),
  ('helios_installment_late_d1',           'installment_late_d1'),
  ('helios_installment_late_d3',           'installment_late_d3'),
  ('helios_installment_late_d5',           'installment_late_d5'),
  ('helios_installment_late_d7',           'installment_late_d7')
) as k(job, key)
join cron.job j on j.jobname = k.job;
