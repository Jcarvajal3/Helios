-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — Las cuotas del paciente son cada dos semanas
--
-- Decisión de Javier, 2026-11-06: las órdenes NUEVAS vencen a los 14 y 28 días
-- de su fecha (`charges.business_date`). Las que ya existen no se tocan: sus
-- `installments.due_date` están guardadas y siguen igual. A la clínica no le
-- cambia nada, sigue cobrando a los días 8 y 15: desde 20261106220000 su fecha
-- ya no sale de la cuota. La comisión del paciente tampoco cambia.
--
--   · `installment_interval_days` = 14 desde el 2026-11-06.
--   · Condiciones v3: los plazos nuevos, sin la cláusula del cargo por atraso
--     (`late_fee_usd` está en 0 desde el 2026-10-07) y con la moneda de la
--     consulta (las órdenes en euros existen desde el 2026-10-07). Las órdenes
--     viejas guardan su `terms_version_id` y siguen con las suyas.
--
-- `business_parameter_catalog` no se toca: su texto («Días entre cuotas») y el
-- de la fila de agosto no dicen ninguna cifra.
-- ═══════════════════════════════════════════════════════════════════════════

-- 0. Sin órdenes esperando un «Sí» ──────────────────────────────────────────
-- Su paciente ya vio las fechas viejas, y `helios_finalize_charge` calcula las
-- cuotas al confirmar: con el parámetro nuevo se le crearían otras. Si hay
-- alguna, la migración no se aplica y se reintenta cuando se resuelva o expire.

do $$
begin
  if exists (select 1 from public.charges where status = 'pending') then
    raise exception 'Hay órdenes pendientes de confirmar con las fechas viejas: aplicar cuando se resuelvan o expiren';
  end if;
end $$;

-- 1. El parámetro ───────────────────────────────────────────────────────────

insert into public.business_parameters (key, value, effective_from, note)
values (
  'installment_interval_days', 14, '2026-11-06',
  'Cuotas del paciente a los 14 y 28 días; solo órdenes nuevas (Javier, 2026-11-06). No mueve el pago a la clínica, que sigue a los días 8 y 15: helios_settlement_interval_days.'
)
on conflict (key, effective_from) do update
  set value = excluded.value,
      note  = excluded.note;

-- 2. Las condiciones v3 ─────────────────────────────────────────────────────
-- Primero se apaga v2: `terms_versions_current_idx` es único parcial sobre
-- `is_current` y no admite dos vigentes ni un instante.

do $$
begin
  if not exists (select 1 from public.terms_versions where version = 'v2' and is_current) then
    raise exception 'Las condiciones vigentes no son v2: revisar antes de publicar v3';
  end if;
end $$;

update public.terms_versions set is_current = false where version = 'v2';

insert into public.terms_versions (version, body, summary, is_current)
values (
  'v3',
  $terminos$Condiciones del pago en cuotas con Helios

1. Helios te permite pagar tu consulta o tratamiento en la clínica en 2 cuotas, sin inicial: la primera vence 14 días después de la fecha de la orden y la segunda, 28 días después.
2. Cada cuota incluye una parte del monto de la consulta y de la comisión de servicio de Helios: 12% sobre el monto de la consulta, más el IVA de la comisión (16%). El comprobante detalla la comisión, su IVA, el total y cada cuota.
3. Los montos están en la moneda de tu consulta, dólares o euros. Pagas en bolívares, a la tasa oficial del Banco Central de Venezuela para esa moneda del día en que pagues, por Pago Móvil o transferencia a las cuentas de Helios que aparecen en el comprobante. Después de pagar, envía el comprobante del pago por WhatsApp a Helios.
4. Tu límite inicial es de $150. Lo que pagas en cuotas ocupa ese límite hasta que pagues las dos cuotas de la orden; entonces se libera.
5. Desde el día siguiente al vencimiento de una cuota sin pagar no podrás registrar otro pago en cuotas con Helios hasta ponerte al día.
6. A los 30 días de atraso la cuenta se suspende. A los 60 días se cierra, la cédula queda en la lista de personas que no pueden usar Helios y la deuda pasa a cobranza.
7. Helios puede contactarte por WhatsApp, por teléfono o por correo, a ti o al contacto de referencia que diste al registrarte, para recordarte tus pagos.
8. Si no reconoces un pago en cuotas a tu nombre, escríbenos enseguida por WhatsApp.
9. Helios es un servicio operado por Quarto Latam, C.A.$terminos$,
  'Condiciones v3: 2 cuotas a 14 y 28 días sin inicial, comisión de servicio 12% + IVA, límite inicial $150, suspensión a los 30 días y cierre a los 60. Opera Quarto Latam, C.A.',
  true
);
