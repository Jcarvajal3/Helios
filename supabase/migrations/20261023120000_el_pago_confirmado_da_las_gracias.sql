-- ============================================================================
-- Helios — El pago confirmado da las gracias y habla del nivel
-- (Javier, 2026-10-23)
--
-- El aviso de «Pago confirmado» era seco. Pasa a dar las gracias, a ser más
-- cercano y a cerrar con la frase de niveles de «Mi saldo y cuotas»
-- (`FRASE_SUBIR_DE_NIVEL` en el bot, aprobada el 2026-10-22):
--
--   1. `helios_level_up_phrase()`: esa frase, en la base. Tiene que decir lo
--      mismo que `FRASE_SUBIR_DE_NIVEL` (textos_paciente.ts).
--   2. El WhatsApp (`helios_payment_result_whatsapp`, de 20261019000200;
--      solo cambia el pago confirmado, no el rechazado).
--   3. El correo `pago_recibido`: el texto por defecto (asunto, cuerpo y
--      HTML). Nadie lo había editado desde el panel (`title`, `body` y
--      `html` en null), así que el texto por defecto es el que sale.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La frase de niveles para el saldo
-- ---------------------------------------------------------------------------

/** «⭐ Si pagas a tiempo, puedes subir de nivel y aumentar tu saldo máximo.» (= `FRASE_SUBIR_DE_NIVEL`). */
create or replace function public.helios_level_up_phrase()
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select '⭐ Si pagas a tiempo, puedes subir de nivel y aumentar tu saldo máximo.'::text
$$;

revoke all on function public.helios_level_up_phrase() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. El WhatsApp
-- ---------------------------------------------------------------------------

create or replace function public.helios_payment_result_whatsapp(p_report_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_r       public.payment_reports%rowtype;
  v_q       public.payment_quotes%rowtype;
  v_nombre  text;
  v_ordenes text;
  v_n       integer;
  v_meds    text;
  v_eur_usd numeric(18,4);
  v_txt     text;
  v_resto   text;
  v_sig     record;
begin
  select * into v_r from public.payment_reports where id = p_report_id;
  if not found then
    return null;
  end if;
  select * into v_q from public.payment_quotes where id = v_r.quote_id;

  select coalesce(nullif(btrim(p.first_name), ''), nullif(split_part(btrim(coalesce(p.full_name, '')), ' ', 1), ''))
    into v_nombre
  from public.profiles p where p.id = v_r.user_id;

  if v_r.status::text = 'rejected' then
    v_txt := coalesce(v_nombre || ', ', '') ||
             format(E'no pudimos confirmar el pago que nos enviaste 😕\nMotivo: %s\n\nRevisa el comprobante y envíanoslo de nuevo por aquí. Si crees que es un error, lo vemos juntos.',
                    coalesce(nullif(btrim(v_r.rejection_note), ''), 'no encontramos ese pago en nuestra cuenta'));
    return upper(left(v_txt, 1)) || substr(v_txt, 2);
  end if;

  if v_r.status::text <> 'reconciled' then
    return null;
  end if;

  select string_agg(distinct c.order_number::text, ', #'),
         count(distinct c.id),
         string_agg(distinct public.helios_doctor_ref(c.merchant_id), ' y ')
    into v_ordenes, v_n, v_meds
  from public.payment_quote_items qi
  join public.installments i on i.id = qi.installment_id
  join public.charges c on c.id = i.charge_id
  where qi.quote_id = v_r.quote_id;

  select coalesce(sum(qi.amount_usd), 0) into v_eur_usd
  from public.payment_quote_items qi
  where qi.quote_id = v_r.quote_id and qi.currency = 'EUR';

  -- NUEVO (2026-10-23): primero las gracias.
  v_txt := format(E'✅ ¡Gracias por tu pago%s! Ya está confirmado 💙\nRecibimos %s de %s #%s con %s.',
                  coalesce(', ' || v_nombre, ''),
                  public.helios_amounts_label(v_q.amount_usd - v_eur_usd, v_q.amount_eur),
                  case when v_n > 1 then 'tus órdenes' else 'tu orden' end,
                  coalesce(v_ordenes, ''), v_meds);

  -- Lo que queda de esas órdenes, sin las cuotas de este pago.
  select i.sequence, i.due_date, coalesce(i.amount_cur, i.amount_usd) as monto, c.currency,
         count(*) over () as quedan
    into v_sig
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where i.charge_id in (select i2.charge_id from public.payment_quote_items qi2
                        join public.installments i2 on i2.id = qi2.installment_id
                        where qi2.quote_id = v_r.quote_id)
    and i.status = 'pending' and i.written_off_at is null
    and i.id not in (select qi3.installment_id from public.payment_quote_items qi3 where qi3.quote_id = v_r.quote_id)
  order by i.due_date, i.sequence
  limit 1;

  if v_sig is null or v_sig.sequence is null then
    v_resto := format('🎉 ¡Terminaste de pagar %s! Gracias por confiar en Helios para cuidar tu salud.',
                      case when v_n > 1 then 'tus consultas' else 'tu consulta' end);
  elsif v_sig.quedan = 1 then
    v_resto := format('Te queda: %s.ª cuota de %s · %s', v_sig.sequence,
                      public.helios_money_cur_text(v_sig.monto, v_sig.currency),
                      public.helios_weekday_es(v_sig.due_date) || ' ' || to_char(v_sig.due_date, 'DD/MM'));
  else
    v_resto := format('Tu próxima cuota: %s · %s',
                      public.helios_money_cur_text(v_sig.monto, v_sig.currency),
                      public.helios_weekday_es(v_sig.due_date) || ' ' || to_char(v_sig.due_date, 'DD/MM'));
  end if;

  -- NUEVO (2026-10-23): cierra con la frase de niveles.
  return v_txt || E'\n\n' || v_resto || E'\n\n' || public.helios_level_up_phrase();
end;
$$;

revoke all on function public.helios_payment_result_whatsapp(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. El correo
-- ---------------------------------------------------------------------------

update public.notification_templates
   set default_title = '¡Gracias por tu pago!',
       default_body  = 'Hola, {nombre}. ¡Gracias por tu pago de {monto}! Ya está confirmado. '
                       || 'Gracias por confiar en Helios para cuidar tu salud.' || E'\n\n'
                       || public.helios_level_up_phrase(),
       default_html  = replace(replace(replace(replace(default_html,
         '<title>Confirmamos tu pago</title>',
         '<title>&iexcl;Gracias por tu pago!</title>'),
         'Recibimos y confirmamos tu pago de {monto}.</div>',
         '&iexcl;Gracias por tu pago de {monto}! Ya est&aacute; confirmado.</div>'),
         'Recibimos y confirmamos tu pago. &iexcl;Gracias por confiar en Helios!</p>',
         '&iexcl;Gracias por tu pago! Ya est&aacute; confirmado. Gracias por confiar en Helios para cuidar tu salud.</p>'),
         -- El párrafo vacío bajo el monto, en el recuadro «Pago confirmado».
         'color:#46526F;"></p>' || E'\n' || '  </td></tr>',
         'color:#46526F;">' || public.helios_level_up_phrase() || '</p>' || E'\n' || '  </td></tr>')
 where key = 'pago_recibido';

do $$
declare
  v_html text;
begin
  select default_html into v_html from public.notification_templates where key = 'pago_recibido';
  if v_html like '%Recibimos y confirmamos%' or v_html not like '%subir de nivel%'
     or v_html not like '%Gracias por tu pago!</title>%' then
    raise exception 'El HTML de pago_recibido no tiene la forma esperada: no se cambió entero';
  end if;
end $$;
