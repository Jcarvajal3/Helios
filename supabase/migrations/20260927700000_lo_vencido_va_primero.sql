-- Lo que vence hoy o antes va primero.
--
-- Un pago que adelanta una cuota —una que vence después de hoy— tiene que
-- llevar también todas las cuotas de esa persona que vencen hoy o antes, sean
-- del consumo que sean. Pagar solo lo vencido, o una parte, sigue valiendo.
--
-- Por qué: el 2026-09-27 una persona pagó la cuota 2 con la 1 vencida. El
-- dinero entró, la deuda bajó y la cuenta siguió congelada, porque la mora se
-- mide por la cuota más vieja sin pagar. Hubo que pasar el pago a mano.
--
-- "Hoy" cuenta: quien adelanta la 2 dejando la 1 que vence hoy amanece
-- congelado mañana, que es el mismo caso un día después.
--
-- No se exige lo que no se puede pagar: una cuota con un pago en revisión
-- (reportado o en revisión) ni una de un grupo que sigue abierto. Si no, la
-- persona no podría pagar nada hasta que se resolvieran.
--
-- La app ya marca y desmarca en cadena (src/features/credit/plan.ts,
-- `togglePick`); esto es lo que lo garantiza para versiones viejas y para el
-- panel (`admin_assign_deposit` cotiza por aquí con p_ignore_open_report).

create or replace function public.helios_quote_installments(
  p_user uuid,
  p_installment_ids uuid[],
  p_ignore_open_report boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
      and public.installment_unlocks_at(i.id) is null
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
      from public.payment_destinations where is_active limit 1
    )
  );
end;
$function$;
