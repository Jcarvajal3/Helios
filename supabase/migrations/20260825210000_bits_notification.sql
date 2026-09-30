-- ============================================================================
-- Ronda — "Ganaste 300 Bits": el aviso, al confirmarse el pago
--
-- Los Bits (20260825190000) se otorgan en la conciliación, que es una acción
-- del panel: el usuario adelanta, se va a dormir, y el premio aparece horas
-- después sin que nada se lo diga. Un contador que sube solo mientras nadie
-- mira no incentiva nada — el premio hay que entregarlo, no dejarlo puesto.
--
-- ---------------------------------------------------------------------------
-- POR QUÉ CUELGA DEL REPORTE Y NO DE `bits_entries`
-- ---------------------------------------------------------------------------
-- Lo natural parecería avisar al insertar el movimiento. Pero un pago cubre
-- un CORTE entero, y un corte son N cuotas de N compras distintas: adelantar
-- tres cuotas dispararía tres avisos seguidos, con tres vibraciones, por una
-- sola transferencia. El usuario no hizo tres cosas, hizo una.
--
-- Por eso el disparador es el REPORTE al pasar a `reconciled` —el momento en
-- que el operador confirma el pago— y el aviso suma lo ganado por todas las
-- cuotas de esa cotización. Un pago, un aviso.
--
-- El orden dentro de `reconcile_payment` lo permite: el bucle salda las cuotas
-- (y ahí se insertan los Bits) ANTES de marcar el reporte, así que cuando este
-- trigger corre los movimientos ya están escritos.
--
-- ---------------------------------------------------------------------------
-- SIN BITS NO HAY AVISO
-- ---------------------------------------------------------------------------
-- Pagar puntual ya tiene su aviso ('payment_reconciled', 20260822160000). Este
-- se añade solo cuando hubo adelanto, y por eso puede decir algo que el otro
-- no: que ganaste algo por adelantarte.
-- ============================================================================

create or replace function public.notify_bits_earned()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_bits  integer;
  v_count integer;
begin
  if new.status <> 'reconciled' or old.status = 'reconciled' then
    return null;
  end if;

  -- Lo ganado por las cuotas de ESTA cotización. Una cuota se salda una sola
  -- vez, así que su movimiento no puede venir de un pago anterior.
  select coalesce(sum(e.amount), 0), count(*)
    into v_bits, v_count
  from public.bits_entries e
  join public.payment_quote_items qi on qi.installment_id = e.installment_id
  where qi.quote_id = new.quote_id
    and e.reason = 'early_installment';

  if coalesce(v_bits, 0) <= 0 then
    return null;
  end if;

  perform public.notify(
    new.user_id, 'bits_earned',
    format('¡Ganaste %s Bits!', v_bits),
    format(
      'Por adelantar %s. Pronto vas a poder canjearlos por premios.',
      case when v_count = 1 then 'tu cuota' else v_count || ' cuotas' end
    ),
    jsonb_build_object('report_id', new.id, 'bits', v_bits, 'installments', v_count)
  );

  return null;
end;
$$;

comment on function public.notify_bits_earned() is
  'Avisa una sola vez, al confirmarse el pago, de los Bits que ganaron sus cuotas adelantadas.';

revoke all on function public.notify_bits_earned() from public, anon, authenticated;

drop trigger if exists payment_reports_notify_bits on public.payment_reports;

-- Nombre alfabéticamente posterior a `payment_reports_notify`, que es el orden
-- en que Postgres dispara los triggers de una misma tabla: primero llega
-- "Confirmamos tu pago" y después el premio. Al revés se felicitaría a alguien
-- antes de decirle que su pago entró.
create trigger payment_reports_notify_bits
  after update on public.payment_reports
  for each row execute function public.notify_bits_earned();

-- ---------------------------------------------------------------------------
-- El sobre, con el aviso nuevo
-- ---------------------------------------------------------------------------
-- Igual que en `20260825140000` más la línea de 'bits_earned'.
--
-- Canal 'cuotas': es la consecuencia directa de haber pagado una cuota y llega
-- pegado al aviso de confirmación. Quien silencie ese canal ha silenciado la
-- conversación entera del pago, que es coherente.
--
-- Prioridad 'normal' y no 'high': es una buena noticia, no una que tenga que
-- encender la pantalla de nadie a las 3 AM. La única que interrumpe de verdad
-- sigue siendo el cargo de grupo.

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
    'sound', case when p_type::text = 'promo' then null else 'default' end,
    'channelId', case p_type::text
                   when 'group_charge'        then 'grupos'
                   when 'group_released'      then 'grupos'
                   when 'payment_reconciled'  then 'cuotas'
                   when 'payment_rejected'    then 'cuotas'
                   when 'installment_due'     then 'cuotas'
                   when 'bits_earned'         then 'cuotas'
                   when 'promo'               then 'promociones'
                   else 'cuenta'
                 end,
    'priority', case p_type::text
                  when 'installment_due' then 'normal'
                  when 'bits_earned'     then 'normal'
                  when 'promo'           then 'normal'
                  else 'high'
                end,
    'ttl', 86400
  );
$fn$;

revoke all on function public.push_envelope(text, public.notification_type, text, text, jsonb, uuid)
  from public, anon, authenticated;
