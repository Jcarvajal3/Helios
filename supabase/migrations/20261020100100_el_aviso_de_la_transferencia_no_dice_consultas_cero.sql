-- ============================================================================
-- Helios — El aviso de la transferencia no dice «consultas $0»
--
-- 20261020100000 escribía «sus consultas ($0)» cuando la transferencia era
-- solo de comisiones del personal (`consultas_usd` vale 0 por defecto). Ahora
-- cada parte sale solo si tiene importe.
-- ============================================================================

create or replace function public.helios_notify_clinic_of_payout(p_payout_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_p          public.merchant_payouts%rowtype;
  v_clinica    text;
  v_medio      text;
  v_monto      text;
  v_ref        text;
  v_dia        text;
  v_consultas  text;
  v_comisiones text;
  v_de_que     text;
  v_texto      text;
  v_html       text;
  v_n          integer := 0;
  v_dest       record;
begin
  if not exists (
    select 1 from public.notification_templates where key = 'pago_a_clinica' and enabled
  ) then
    return 0;
  end if;

  select * into v_p from public.merchant_payouts where id = p_payout_id;
  if not found then
    return 0;
  end if;

  select m.name into v_clinica from public.merchants m where m.id = v_p.merchant_id;

  v_medio := case v_p.method
    when 'pago_movil' then 'Pago Móvil'
    when 'transferencia' then 'transferencia'
    else v_p.method end;
  v_monto := case when v_p.amount_ves is not null then public.helios_ves_text(v_p.amount_ves)
                  else public.helios_money_text(v_p.amount_usd) end;
  v_ref := nullif(btrim(coalesce(v_p.reference, '')), '');
  v_dia := to_char(coalesce(v_p.paid_on, v_p.business_date), 'DD/MM/YYYY');

  -- Cada parte solo si tiene importe. Sin reparto guardado, todo es consulta.
  v_consultas := case
    when coalesce(v_p.consultas_usd, 0) > 0 then public.helios_money_text(v_p.consultas_usd)
    when coalesce(v_p.comisiones_usd, 0) = 0 then public.helios_money_text(v_p.amount_usd)
  end;
  v_comisiones := case when coalesce(v_p.comisiones_usd, 0) > 0 then public.helios_money_text(v_p.comisiones_usd) end;
  v_de_que := concat_ws(' y ',
    case when v_consultas is not null then format('sus consultas (%s)', v_consultas) end,
    case when v_comisiones is not null then format('las comisiones de su personal (%s)', v_comisiones) end);

  v_texto := format(
    E'Hola:\n\nHelios le transfirió %s a %s por %s el %s%s.\n\nEs el pago de %s.\n\nEl equipo de Helios',
    v_monto, v_clinica, v_medio, v_dia,
    case when v_ref is not null then format(', referencia %s', v_ref) else '' end,
    v_de_que);

  v_html := format(
    '<!doctype html><html lang="es"><body style="margin:0;padding:0;background:#F4F6FA">'
    '<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" style="background:#F4F6FA"><tr><td align="center" style="padding:24px 12px">'
    '<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border:1px solid #E3E8F1;border-radius:16px;font-family:''Source Sans 3'',''Segoe UI'',Arial,sans-serif;color:#050F2C;font-size:15px;line-height:1.5">'
    '<tr><td style="padding:24px 28px 8px"><img src="https://conhelios.com/correo/logo-helios.png" width="120" height="49" alt="Helios" style="display:block;border:0;color:#002770;font-weight:700;font-size:22px"></td></tr>'
    '<tr><td style="padding:8px 28px 28px">'
    '<h1 style="margin:0 0 12px;font-family:Outfit,''Segoe UI'',Arial,sans-serif;font-size:22px;color:#002770">Te transferimos %s</h1>'
    '<p style="margin:0 0 12px">Helios le transfirió a <b>%s</b> por %s el %s.</p>'
    '<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" style="background:#E8F3FF;border-radius:12px;margin:8px 0 16px"><tr><td style="padding:14px 18px">'
    '%s%s%s'
    '</td></tr></table>'
    '<p style="margin:0;color:#6B7690;font-size:13px">Lo ves también en el panel, en Pagos.</p>'
    '</td></tr></table>'
    '<p style="margin:16px 0 0;color:#6B7690;font-size:12px;font-family:Arial,sans-serif">El equipo de Helios</p>'
    '</td></tr></table></body></html>',
    public.helios_html_escape(v_monto),
    public.helios_html_escape(v_clinica),
    public.helios_html_escape(v_medio),
    v_dia,
    case when v_consultas is not null then format(
      '<p style="margin:0;color:#46526F;font-size:13px">Sus consultas</p><p style="margin:0 0 8px;font-size:15px">%s</p>',
      public.helios_html_escape(v_consultas)) else '' end,
    case when v_comisiones is not null then format(
      '<p style="margin:0;color:#46526F;font-size:13px">Comisiones de su personal</p><p style="margin:0 0 8px;font-size:15px">%s</p>',
      public.helios_html_escape(v_comisiones)) else '' end,
    case when v_ref is not null then format(
      '<p style="margin:0;color:#46526F;font-size:13px">Referencia</p><p style="margin:0;font-family:Consolas,Menlo,monospace;font-size:15px">%s</p>',
      public.helios_html_escape(v_ref)) else '' end);

  for v_dest in
    select distinct mu.user_id, lower(au.email) as email
    from public.merchant_users mu
    join auth.users au on au.id = mu.user_id
    where mu.merchant_id = v_p.merchant_id
      and mu.role = 'gerente'
      and mu.is_active
      and au.email is not null
  loop
    insert into public.outbound_messages (
      channel, template_key, profile_id, recipient_staff_id, recipient,
      subject, rendered_text, html, status, next_attempt_at, dedupe_key
    ) values (
      'email', 'pago_a_clinica', null, v_dest.user_id, v_dest.email,
      format('Helios te transfirió %s · %s', v_monto, v_clinica), v_texto, v_html,
      'pendiente', now(),
      format('pago_a_clinica:%s:%s', v_p.id, v_dest.user_id)
    )
    on conflict (dedupe_key) do nothing;
    v_n := v_n + 1;
  end loop;

  return v_n;
exception when others then
  -- Un aviso que no sale no puede tumbar el registro de la transferencia.
  raise warning 'pago_a_clinica: no se pudo avisar de la transferencia %: %', p_payout_id, sqlerrm;
  return 0;
end;
$$;

revoke all on function public.helios_notify_clinic_of_payout(uuid) from public, anon, authenticated;
