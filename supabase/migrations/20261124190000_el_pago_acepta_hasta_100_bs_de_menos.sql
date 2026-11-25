-- ============================================================================
-- Helios — Un pago cuadra hasta con 100 Bs de menos (2026-11-24)
--
-- El margen por debajo de lo cotizado era de 10 Bs (20261026150000). Dos pagos
-- de la última semana fueron al equipo con `monto_no_cuadra` aunque el
-- comprobante estaba bien leído y el aviso del BNC sí había llegado:
--
--   · Bs 41.878,83 pagados contra Bs 41.916,32 cotizados (24-nov): 37,49 Bs
--     por debajo.
--   · Bs 23.493,68 (19-nov): tampoco cuadró con su cuota.
--
-- Desde ahora un monto pagado CUADRA con lo cotizado si está entre 100 Bs por
-- debajo y 100 Bs por encima (`payment_margin_under_ves` = 100,
-- `payment_margin_over_ves` = 100, sin tocar este último). Es el mismo
-- parámetro que usan el lector de comprobantes, el aviso del BNC, el cruce con
-- el extracto y los pagos de las compras Amazon (`helios_monto_cuadra`): no
-- hay nada más que cambiar. La diferencia ni se cobra ni se devuelve.
--
-- Un parámetro no se actualiza: se inserta otra fila con otra fecha de
-- vigencia (docs/00 «parámetros del negocio»). Se puede volver atrás desde
-- Ajustes › Parámetros, o con otra migración con una fecha posterior.
-- ============================================================================

insert into public.business_parameters (key, value, effective_from, note)
values ('payment_margin_under_ves', 100, public.helios_business_date(now()),
        '2026-11-24: 100 Bs de menos se aceptan (dos pagos con monto_no_cuadra fueron al equipo)')
on conflict (key, effective_from) do update
   set value = excluded.value,
       note  = excluded.note;
