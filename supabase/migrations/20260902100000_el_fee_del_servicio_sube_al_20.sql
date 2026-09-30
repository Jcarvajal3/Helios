-- ============================================================================
-- Ronda — El fee del servicio sube del 10% al 20%
--
-- Decisión del 2026-09-02. Es un parámetro, no un cambio de modelo: sigue
-- siendo un fee GLOBAL al consumidor, dentro del precio, con su IVA aparte y
-- sin comisión al comercio (docs/00-BASES §1.1, §2.11).
--
--   Con la cifra que teclea el cajero en 100:
--
--     | Línea                    | Antes   | Ahora   |
--     |--------------------------|---------|---------|
--     | Producto                 | 100,00  | 100,00  |
--     | Fee del servicio         |  10,00  |  20,00  |
--     | IVA del fee (16%)        |   1,60  |   3,20  |
--     | LO QUE DEBE EL USUARIO   | 111,60  | 123,20  |
--     | Al comercio              | 100,00  | 100,00  |
--     | Ingreso de Ronda         |  10,00  |  20,00  |
--
--   Dos cuotas de 61,60 en vez de dos de 55,80.
--
-- ---------------------------------------------------------------------------
-- Por qué esto es una línea y no una migración de datos
-- ---------------------------------------------------------------------------
-- `charges` guarda el desglose con el que se emitió cada cobro
-- (`base_usd`, `consumer_fee_usd`, `consumer_fee_vat_usd`, `merchant_net_usd`)
-- y NADIE lo recalcula: una factura tiene que poder reimprimirse con los
-- números con los que se emitió. Así que los cobros anteriores conservan su 10%
-- y solo los nuevos nacen con el 20%. Es justo para lo que se guardó.
--
-- Tampoco hay índices ni columnas generadas colgando de estas funciones, que es
-- lo que haría peligroso tocar una función `immutable`.
--
-- ---------------------------------------------------------------------------
-- Lo que NO cambia, y conviene decirlo
-- ---------------------------------------------------------------------------
-- **El cupo.** Desde 20260830190000 el fee no ocupa cupo: `financed_usd` lleva
-- solo el consumo y el fee vive en `user_credit_blocks.fee_usd`. Así que subirlo
-- no encoge el límite de nadie — el mismo nivel financia el mismo consumo, y lo
-- que sube es lo que se paga por él. Si el fee siguiera comiéndose el cupo,
-- este cambio le habría partido el techo a todo el mundo de un día para otro.
--
-- **Lo que cuenta para subir de nivel** (`level_standing`) suma `financed_usd`,
-- también consumo: nadie asciende antes por pagar más comisión.
--
-- **El reparto en grupo** trabaja en moneda de crédito y el fee cae después
-- sobre la parte de cada quien (20260830190000), así que los techos siguen
-- siendo techos.
--
-- ---------------------------------------------------------------------------
-- Lo que sí cambia, y es el motivo
-- ---------------------------------------------------------------------------
-- El margen contra el impago. Por cada 100 financiados salen 100 de caja el
-- mismo día y vuelven 120 (los 3,20 del IVA nunca fueron de Ronda):
--
--     beneficio esperado = (1 − d) × 20 − d × 100 = 20 − 120d
--
-- Se hace cero en **d ≈ 16,7% de impago**, cuando con el 10% se hacía cero en
-- **d ≈ 9,1%**. Un 10% de mora deja de llevarse la comisión entera y se lleva
-- la mitad. La mora sigue siendo el negocio (docs/00-BASES §1.2), pero el
-- producto deja de estar a un punto porcentual de no ganar nada.
-- ============================================================================

/**
 * Fee que Ronda cobra al consumidor, como % de la base de los productos.
 *
 * 🔁 20% desde el 2026-09-02 (antes 10%). Global y no por comercio: lo que paga
 * el usuario por financiar no puede depender del local, o el mismo consumo
 * costaría distinto según dónde se haga.
 */
create or replace function public.helios_consumer_fee_pct()
returns numeric
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 20.00::numeric $fn$;

comment on function public.helios_consumer_fee_pct() is
  'Fee al consumidor por comprar a cuotas, como % de la base. 20% desde 2026-09-02. Va DENTRO del precio que ve el usuario.';

revoke all on function public.helios_consumer_fee_pct() from public, anon;
grant execute on function public.helios_consumer_fee_pct() to authenticated;
