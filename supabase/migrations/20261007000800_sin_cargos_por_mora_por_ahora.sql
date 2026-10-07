-- ============================================================================
-- Helios — Sin cargos por mora, por ahora (Javier, 2026-10-07)
--
-- Decisión: de momento no se cobran cargos por atraso. El motor se queda tal
-- cual, para retomarlo cuando se decida:
--
-- 1. **El interruptor es el parámetro.** `late_fee_usd` pasa a 0 desde hoy,
--    con vigencia, por el camino de siempre. `charge_late_fee` ya no cobra
--    nada con 0 («Poner el parámetro en 0 apaga el cargo entero sin
--    desconectar el motor»), el aviso `cargo_por_atraso_d4` no encuentra a
--    nadie a quien avisar (solo sale si hay cargo) y la vista previa devuelve
--    `late_fee_usd = 0`, con lo que el panel y el bot no dicen la regla.
--
-- 2. **Los textos que prometían el cargo dependen del parámetro.** En vez de
--    llevar la frase escrita, el comprobante (texto y HTML) y el aviso de
--    cuota vencida usan variables de siempre que salen vacías con el cargo en
--    0 y con la frase de antes en cuanto vuelva a valer algo:
--
--      condicion_cargo_atraso       «• Después de 3 días de gracia se suma…»
--      condicion_cargo_atraso_html  la misma fila en el HTML del comprobante
--      aviso_cargo_atraso           « Si la pagas antes de cumplir 3 días…»
--
-- PARA RETOMARLO: Ajustes › Parámetros › «Cargo por atraso» con el monto (o
-- una fila nueva de `late_fee_usd` en `business_parameters`). Nada más: los
-- textos vuelven solos. Los Términos públicos (`/legal/terminos`) sí hay que
-- volver a escribirlos a mano.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El cargo, en 0 desde hoy
-- ---------------------------------------------------------------------------

insert into public.business_parameters (key, value, effective_from, note)
values ('late_fee_usd', 0, public.helios_business_date(now()),
        'Sin cargos por mora por ahora (Javier, 2026-10-07). El motor sigue: para retomarlo, otra fila con el monto.')
on conflict (key, effective_from) do update set value = excluded.value, note = excluded.note;

-- ---------------------------------------------------------------------------
-- 2. Las variables de siempre: la regla del cargo, solo si hay cargo
-- ---------------------------------------------------------------------------

create or replace function public.helios_message_builtins(p_profile_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_p       public.profiles%rowtype;
  v_c       public.platform_contact%rowtype;
  v_wa      text;
  v_cuentas text := public.helios_payment_accounts_text();
  v_tasa    numeric := public.current_fx_rate('BCV');
  v_tasa_e  numeric := public.current_fx_rate('BCV_EUR');
  v_cargo   numeric := public.helios_late_fee_usd();
  v_gracia  integer := public.helios_late_fee_grace_days();
  v_cargo_t text    := public.helios_money_cur_text(v_cargo, 'USD');
begin
  select * into v_p from public.profiles where id = p_profile_id;
  select * into v_c from public.platform_contact where id;

  v_wa := coalesce(public.helios_format_ve_phone(v_c.whatsapp_number), v_c.whatsapp_number);

  return jsonb_build_object(
    'nombre', coalesce(nullif(btrim(v_p.first_name), ''),
                       nullif(split_part(btrim(coalesce(v_p.full_name, '')), ' ', 1), ''),
                       'paciente'),
    'whatsapp_helios', coalesce(v_wa, 'te escribiremos en breve desde el WhatsApp de Helios'),
    'whatsapp_link', case when v_c.whatsapp_number is not null
                          then 'https://wa.me/' || regexp_replace(v_c.whatsapp_number, '\D', '', 'g')
                          else '' end,
    'cuentas_de_cobro', v_cuentas,
    'cuentas_de_cobro_html', replace(public.helios_html_escape(v_cuentas), E'\n', '<br>'),
    'soporte_email', coalesce(v_c.support_email, ''),
    'soporte_horario', coalesce(v_c.support_hours, ''),
    'tasa_bcv', case when v_tasa is null then 'del día'
                     else trim(to_char(v_tasa, 'FM999999990.00')) end,
    'tasa_bcv_euro', case when v_tasa_e is null then 'del día'
                          else trim(to_char(v_tasa_e, 'FM999999990.00')) end,
    -- La de la orden la pisa (20261007000600).
    'moneda', 'dólar',
    -- Con su símbolo: el cargo por atraso es en dólares.
    'cargo_atraso', v_cargo_t,
    'dias_gracia', v_gracia::text,
    'dias_suspension', public.helios_mora_demotion_days()::text,
    'dias_expulsion', public.helios_mora_expulsion_days()::text,
    -- La regla del cargo, solo si hay cargo (20261007000800). Con el cargo en
    -- 0, vacías: nadie promete un cargo que no se cobra.
    'condicion_cargo_atraso', case when v_cargo > 0 then
      format(E'• Después de %s días de gracia se suma un cargo de %s por cada cuota vencida.\n',
             v_gracia, v_cargo_t) else '' end,
    'condicion_cargo_atraso_html', case when v_cargo > 0 then
      format(E'<tr><td valign="top" width="18" style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1A56DB;">&bull;</td>\n'
             '      <td style="padding-bottom:6px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1f2937;">Despu&eacute;s de %s d&iacute;as de gracia se suma un cargo de %s por cada cuota vencida.</td></tr>\n  ',
             v_gracia, public.helios_html_escape(v_cargo_t)) else '' end,
    'aviso_cargo_atraso', case when v_cargo > 0 then
      format(' Si la pagas antes de cumplir %s días de atraso, evitas el cargo de %s.', v_gracia, v_cargo_t)
      else '' end
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Las plantillas usan esas variables (las tres capas)
-- ---------------------------------------------------------------------------

update public.notification_templates
set default_body = replace(default_body,
      E'\n• Después de {dias_gracia} días de gracia se suma un cargo de {cargo_atraso} por cada cuota vencida.\n',
      E'\n{condicion_cargo_atraso}'),
    body = replace(body,
      E'\n• Después de {dias_gracia} días de gracia se suma un cargo de {cargo_atraso} por cada cuota vencida.\n',
      E'\n{condicion_cargo_atraso}'),
    draft_body = replace(draft_body,
      E'\n• Después de {dias_gracia} días de gracia se suma un cargo de {cargo_atraso} por cada cuota vencida.\n',
      E'\n{condicion_cargo_atraso}'),
    default_html = replace(default_html,
      E'<tr><td valign="top" width="18" style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1A56DB;">&bull;</td>\n'
      '      <td style="padding-bottom:6px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1f2937;">Despu&eacute;s de {dias_gracia} d&iacute;as de gracia se suma un cargo de {cargo_atraso} por cada cuota vencida.</td></tr>\n  ',
      '{condicion_cargo_atraso_html}'),
    html = replace(html,
      E'<tr><td valign="top" width="18" style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1A56DB;">&bull;</td>\n'
      '      <td style="padding-bottom:6px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#1f2937;">Despu&eacute;s de {dias_gracia} d&iacute;as de gracia se suma un cargo de {cargo_atraso} por cada cuota vencida.</td></tr>\n  ',
      '{condicion_cargo_atraso_html}'),
    variables = (select array_agg(distinct v order by v)
                 from unnest(variables || array['condicion_cargo_atraso', 'condicion_cargo_atraso_html']) v)
where key = 'comprobante_financiamiento';

update public.notification_templates
set default_body = replace(default_body,
      ' Si la pagas antes de cumplir {dias_gracia} días de atraso, evitas el cargo de {cargo_atraso}.',
      '{aviso_cargo_atraso}'),
    body = replace(body,
      ' Si la pagas antes de cumplir {dias_gracia} días de atraso, evitas el cargo de {cargo_atraso}.',
      '{aviso_cargo_atraso}'),
    draft_body = replace(draft_body,
      ' Si la pagas antes de cumplir {dias_gracia} días de atraso, evitas el cargo de {cargo_atraso}.',
      '{aviso_cargo_atraso}'),
    variables = (select array_agg(distinct v order by v)
                 from unnest(variables || array['aviso_cargo_atraso']) v)
where key = 'cuota_vencida_d1';

-- La red: si alguna plantilla no tenía la frase exacta, que se sepa ahora.
do $$
begin
  if exists (select 1 from public.notification_templates
             where key in ('comprobante_financiamiento', 'cuota_vencida_d1')
               and concat(default_body, body, draft_body, default_html, html) like '%cargo de {cargo_atraso}%') then
    raise exception 'Queda una frase del cargo por atraso escrita a mano en las plantillas';
  end if;
end
$$;
