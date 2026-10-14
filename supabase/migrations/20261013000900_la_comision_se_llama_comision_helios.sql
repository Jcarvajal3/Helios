-- ============================================================================
-- Helios — La comisión se llama «Comisión Helios» (2026-10-13)
--
-- Decidido por Javier el 2026-10-13: la comisión de servicio que paga el
-- paciente (12% + IVA, `consumer_fee_pct`) se llama «Comisión Helios» en
-- todas partes. Aquí, los dos mensajes al paciente que la enseñan:
--
--   · `confirmar_financiamiento` (WhatsApp, la pregunta): el texto libre que
--     sale dentro de la ventana de 24 h. Fuera de ella sale la plantilla
--     aprobada en Meta (`helios_confirmar_pago_en_cuotas`), que dice
--     «Comisión de servicio» hasta que Meta apruebe la nueva (docs/00
--     §15.5.3): esa no se cambia desde aquí.
--   · `comprobante_financiamiento` (correo): el texto y el HTML.
--
-- Solo cambian las palabras: las variables (`comision_servicio`,
-- `cargo_servicio`, `iva_comision`…) conservan su nombre.
-- ============================================================================

create function pg_temp.comision_helios(t text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(replace(replace(t,
    'Comisión de servicio', 'Comisión Helios'),
    'comisión de servicio', 'Comisión Helios'),
    'IVA de la comisión', 'IVA de la Comisión Helios'),
    'Comisi&oacute;n de servicio', 'Comisi&oacute;n Helios'),
    'comisi&oacute;n de servicio', 'Comisi&oacute;n Helios'),
    'IVA de la comisi&oacute;n', 'IVA de la Comisi&oacute;n Helios')
$$;

update public.notification_templates
   set default_title = pg_temp.comision_helios(default_title),
       default_body  = pg_temp.comision_helios(default_body),
       title         = pg_temp.comision_helios(title),
       body          = pg_temp.comision_helios(body),
       draft_title   = pg_temp.comision_helios(draft_title),
       draft_body    = pg_temp.comision_helios(draft_body),
       default_html  = pg_temp.comision_helios(default_html),
       html          = pg_temp.comision_helios(html),
       help          = pg_temp.comision_helios(help)
 where key in ('confirmar_financiamiento', 'comprobante_financiamiento');

do $$
begin
  if exists (
    select 1 from public.notification_templates
     where concat_ws(' ', default_title, default_body, title, body, draft_title, draft_body,
                     default_html, html, help) ~* 'comisi(ó|&oacute;)n de servicio'
  ) then
    raise exception 'Queda una plantilla que dice «comisión de servicio»';
  end if;

  if not exists (
    select 1 from public.notification_templates
     where key = 'confirmar_financiamiento'
       and default_body like '%* Comisión Helios ({servicio_pct}\%): {cargo_servicio}%'
       and default_body like '%* IVA de la Comisión Helios ({iva_pct}\%): {iva_cargo_servicio}%'
  ) then
    raise exception 'La pregunta al paciente no quedó con «Comisión Helios»';
  end if;

  if not exists (
    select 1 from public.notification_templates
     where key = 'comprobante_financiamiento'
       and default_body like '%Comisión Helios ({servicio_helios_pct}\%): {comision_servicio}%'
       and default_html like '%Comisi&oacute;n Helios ({servicio_helios_pct}\%)%'
       and default_html like '%IVA de la Comisi&oacute;n Helios ({iva_pct}\%)%'
  ) then
    raise exception 'El comprobante no quedó con «Comisión Helios»';
  end if;
end;
$$;
