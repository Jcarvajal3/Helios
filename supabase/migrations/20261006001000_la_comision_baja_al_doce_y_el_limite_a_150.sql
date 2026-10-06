-- ============================================================================
-- Helios — La comisión de servicio baja al 12% y el límite inicial a $150
--
-- Reglas del negocio publicadas el 2026-10-06 (Javier):
--
-- 1. **Comisión de servicio del 12% + IVA 16% sobre la comisión**, la paga el
--    paciente (antes 20% + IVA). Una consulta de $100: comisión $12 + IVA
--    $1,92 = $113,92 en 2 cuotas de $56,96. La clínica sigue recibiendo el
--    100% de la consulta y nunca ve un total con la comisión.
--    `consumer_fee_pct` es un parámetro con vigencia: la fila nueva rige desde
--    hoy y la de 20 queda como historia. Los pagos en cuotas ya confirmados
--    guardan su desglose (`charges.fee_usd`, `vat_usd`) y no se recalculan.
-- 2. **Límite inicial de $150** (nivel 1, antes $350). Los niveles 2-5
--    siguen apagados: todavía no está definido cómo se sube, así que hacia
--    fuera solo se dice «límite inicial de $150».
--
-- La plantilla de Meta aprobada (`helios_confirmar_financiamiento`, v1) lleva
-- «20 %» escrito. La migración de textos (20261006002000) la deja de usar
-- hasta que Meta apruebe la nueva: fuera de la ventana de 24 h la pregunta al
-- paciente cae a la cola manual en lugar de salir con un porcentaje falso.
-- ============================================================================

insert into public.business_parameters (key, value, effective_from, note) values
  ('consumer_fee_pct', 12.00, date '2026-10-06',
   'Comisión de servicio al paciente: 12% + IVA sobre la comisión (Javier, 2026-10-06)')
on conflict (key, effective_from) do update
  set value = excluded.value, note = excluded.note;

update public.business_parameter_catalog
   set label = 'Comisión de servicio (la paga el paciente)'
 where key = 'consumer_fee_pct';

update public.business_parameter_catalog
   set label = 'IVA de la comisión de servicio'
 where key = 'vat_pct';

update public.levels
   set monthly_limit_usd = 150, updated_at = now()
 where level = 1;
