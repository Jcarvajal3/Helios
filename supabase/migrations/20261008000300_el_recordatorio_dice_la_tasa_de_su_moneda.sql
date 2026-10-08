-- ============================================================================
-- Helios — El recordatorio dice la tasa de su moneda (2026-10-08)
--
-- La bienvenida, la pregunta del Sí, el comprobante y el bot ya dicen «a la
-- tasa BCV del dólar» o «del euro». El recordatorio de la víspera
-- (`cuota_manana`) decía «a la tasa BCV del día», sin moneda: a quien debe
-- €50 no le decía que paga a la tasa del euro. Y `helios_enqueue_reminders`
-- no le pasaba la moneda, así que `{moneda}` habría salido siempre «dólar»
-- (el valor por defecto de `helios_message_builtins`).
--
--   1. `helios_enqueue_reminders` pasa `moneda`: «dólar», «euro» o, si el
--      paciente debe ese día en las dos monedas (dos órdenes, o una cuota en
--      euros con un cargo por atraso, que va en dólares), «dólar o del euro,
--      según la moneda de cada cuota,». Lo demás, idéntico a 20261007000400.
--   2. `cuota_manana`, en texto y en HTML: «a la tasa BCV del {moneda} del día
--      en que pagues». Así, en una orden en euros: «a la tasa BCV del euro del
--      día en que pagues».
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Los avisos de cuota pasan la moneda
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.helios_enqueue_reminders(p_key text, p_today date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
        c.currency, coalesce(i.amount_cur, i.amount_usd) as amount_cur,
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
      -- Lo que va en dólares (cuotas en dólares y todo cargo por atraso) y lo
      -- que va en euros, por separado: cada uno a la tasa de su moneda.
      sum(case when q.currency = 'EUR' then 0 else q.amount_cur end) + sum(q.fee_usd) as monto_usd,
      sum(case when q.currency = 'EUR' then q.amount_cur else 0 end)                as monto_eur,
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
            'monto_cuota', public.helios_amounts_text(v_row.monto_usd, v_row.monto_eur, v_today),
            'fecha', public.helios_weekday_es(v_due) || ' ' || to_char(v_due, 'DD/MM'),
            -- La tasa con la que paga (20261008000300): la de la moneda de sus
            -- cuotas. Un cargo por atraso va en dólares, así que una cuota en
            -- euros con cargo cuenta como las dos.
            'moneda', case
              when v_row.monto_eur = 0 then 'dólar'
              when v_row.monto_usd = 0 then 'euro'
              else 'dólar o del euro, según la moneda de cada cuota,'
            end
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
$function$;

-- ---------------------------------------------------------------------------
-- 2. El recordatorio de la víspera
-- ---------------------------------------------------------------------------

update public.notification_templates
   set default_body =
            E'Hola, {nombre}. Te recordamos que mañana, {fecha}, vence tu cuota de {monto_cuota} de la orden #{orden} en {clinica}.\n\n'
         || E'Puedes pagar en bolívares (Pago Móvil o transferencia), a la tasa BCV del {moneda} del día en que pagues:\n'
         || E'{cuentas_de_cobro}\n\n'
         || 'Cuando pagues, envíanos el comprobante por WhatsApp: {whatsapp_helios}. ¡Gracias!',
       default_html = replace(default_html,
         'a la tasa BCV <strong style="color:#050F2C;">del d&iacute;a en que pagues</strong>',
         'a la tasa BCV del {moneda} <strong style="color:#050F2C;">del d&iacute;a en que pagues</strong>'),
       variables = (select array_agg(distinct v order by v) from unnest(variables || array['moneda']) v)
 where key = 'cuota_manana';

do $$
begin
  if (select default_body from public.notification_templates where key = 'cuota_manana') not like '%tasa BCV del {moneda} del día en que pagues%'
     or (select default_html from public.notification_templates where key = 'cuota_manana') not like '%tasa BCV del {moneda} <strong%' then
    raise exception 'El recordatorio no quedó con la tasa de su moneda';
  end if;
  if (select prosrc from pg_proc where oid = 'public.helios_enqueue_reminders(text,date)'::regprocedure) not like '%''moneda'', case%' then
    raise exception 'Los avisos de cuota no pasan la moneda';
  end if;
end
$$;
