-- ============================================================================
-- Helios — Al paciente se le sigue diciendo «comisión de servicio» (2026-10-13)
--
-- Deshace 20261013000900 (Javier, 2026-10-13): «Comisión Helios» es para lo
-- que ve el médico; a los pacientes no hace falta enseñárselo. La pregunta de
-- WhatsApp (`confirmar_financiamiento`) y el comprobante por correo
-- (`comprobante_financiamiento`) vuelven a su texto, que además coincide con
-- la plantilla aprobada en Meta (`helios_confirmar_pago_en_cuotas`).
-- ============================================================================

create function pg_temp.comision_de_servicio(t text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(replace(replace(t,
    'IVA de la Comisión Helios', 'IVA de la comisión'),
    'IVA de la Comisi&oacute;n Helios', 'IVA de la comisi&oacute;n'),
    'la Comisión Helios', 'la comisión de servicio'),
    'la Comisi&oacute;n Helios', 'la comisi&oacute;n de servicio'),
    'Comisión Helios', 'Comisión de servicio'),
    'Comisi&oacute;n Helios', 'Comisi&oacute;n de servicio')
$$;

update public.notification_templates
   set default_title = pg_temp.comision_de_servicio(default_title),
       default_body  = pg_temp.comision_de_servicio(default_body),
       title         = pg_temp.comision_de_servicio(title),
       body          = pg_temp.comision_de_servicio(body),
       draft_title   = pg_temp.comision_de_servicio(draft_title),
       draft_body    = pg_temp.comision_de_servicio(draft_body),
       default_html  = pg_temp.comision_de_servicio(default_html),
       html          = pg_temp.comision_de_servicio(html),
       help          = pg_temp.comision_de_servicio(help)
 where key in ('confirmar_financiamiento', 'comprobante_financiamiento');

do $$
begin
  if exists (
    select 1 from public.notification_templates
     where concat_ws(' ', default_title, default_body, title, body, draft_title, draft_body,
                     default_html, html, help) ~* 'comisi(ó|&oacute;)n helios'
  ) then
    raise exception 'Queda una plantilla que dice «Comisión Helios»';
  end if;

  if not exists (
    select 1 from public.notification_templates
     where key = 'confirmar_financiamiento'
       and default_body like '%* Comisión de servicio ({servicio_pct}\%): {cargo_servicio}%'
       and default_body like '%* IVA de la comisión ({iva_pct}\%): {iva_cargo_servicio}%'
  ) then
    raise exception 'La pregunta al paciente no volvió a su texto';
  end if;

  if not exists (
    select 1 from public.notification_templates
     where key = 'comprobante_financiamiento'
       and default_body like '%Comisión de servicio ({servicio_helios_pct}\%): {comision_servicio}%'
       and default_body like '%Las cuotas ya incluyen la comisión de servicio y su IVA.%'
       and default_html like '%Comisi&oacute;n de servicio ({servicio_helios_pct}\%)%'
       and default_html like '%IVA de la comisi&oacute;n ({iva_pct}\%)%'
       and default_html like '%la comisi&oacute;n de servicio y su IVA.%'
  ) then
    raise exception 'El comprobante no volvió a su texto';
  end if;
end;
$$;
