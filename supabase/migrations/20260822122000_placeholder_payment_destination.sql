-- ============================================================================
-- Ronda — Cuenta destino provisional
--
-- Decisión 2026-08-22: la cuenta real a la que paga el usuario (D-01) todavía
-- no existe, y no bloquea seguir construyendo. Se siembra un PLACEHOLDER
-- explícito para que el flujo de pago funcione de extremo a extremo.
--
-- Va en una migración y no solo en `seed.sql` porque el seed únicamente corre
-- en local: sin esto, el primer despliegue remoto tendría la pantalla de pago
-- sin cuenta a la que transferir.
--
-- ⚠️ ANTES DEL PILOTO hay que sustituirla por la cuenta de verdad. Los
-- valores están escritos para que sea imposible confundirlos con reales y
-- para que, si alguien llega a verlos en pantalla, entienda que aún no se
-- puede pagar. Cambiarla es un UPDATE desde el super admin, sin publicar
-- versión nueva de la app.
-- ============================================================================

insert into public.payment_destinations (bank_name, rif, phone, holder_name, is_active)
select 'PENDIENTE POR CONFIGURAR', 'J-000000000', '0000 0000000', 'Helios (cuenta provisional)', true
where not exists (select 1 from public.payment_destinations);

comment on table public.payment_destinations is
  'Cuentas de Pago Móvil a las que reporta el usuario. Las crea el super admin. '
  'OJO: hay una fila PLACEHOLDER sembrada por migración; sustituir antes del piloto (D-01).';
