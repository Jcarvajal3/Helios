// ═══════════════════════════════════════════════════════════════════════════
// Helios — Cotizador de compras en Amazon (aéreo y marítimo)
//
// Redondeo exacto en centavos (`Math.round((n + eps) * 100) / 100`) alineado
// con `helios_purchase_calculate` en Postgres. Módulo puro, sin red ni BD.
// ═══════════════════════════════════════════════════════════════════════════

import { evaluarRestriccionMedica } from './amazon_parser.ts'
import type { CotizacionCompra, MetodoEnvio, ProductoResumen, TarifasCompra } from './tipos.ts'

/** Redondeo exacto a 2 decimales (centavos), evitando deriva de coma flotante. */
export function redondearCentavos(n: number): number {
  if (!Number.isFinite(n)) return 0
  return Math.round((n + Math.sign(n) * 1e-9) * 100) / 100
}

/** Redondeo a 4 decimales para volúmenes en pies cúbicos (ft³). */
function redondear4(n: number): number {
  if (!Number.isFinite(n)) return 0
  return Math.round((n + Math.sign(n) * 1e-9) * 10000) / 10000
}

/** Dimensiones válidas (> 0 en los tres ejes) o null. */
function dimensionesValidas(
  d: ProductoResumen['dimensionesIn'],
): { largo: number; ancho: number; alto: number } | null {
  if (!d) return null
  if (
    Number.isFinite(d.largo) &&
    d.largo > 0 &&
    Number.isFinite(d.ancho) &&
    d.ancho > 0 &&
    Number.isFinite(d.alto) &&
    d.alto > 0
  ) {
    return d
  }
  return null
}

/**
 * Recomienda envío marítimo cuando el peso real o volumétrico supera 15 lb
 * o el volumen supera 1,2 ft³; en caso contrario recomienda envío aéreo.
 */
export function recomendarEnvio(producto: Pick<ProductoResumen, 'pesoLb' | 'dimensionesIn'>): MetodoEnvio {
  const pesoReal = producto.pesoLb != null && Number.isFinite(producto.pesoLb) && producto.pesoLb > 0 ? producto.pesoLb : 0
  const dims = dimensionesValidas(producto.dimensionesIn)
  const volIn3 = dims ? dims.largo * dims.ancho * dims.alto : 0
  const pesoVolumetrico = volIn3 > 0 ? volIn3 / 139 : 0
  const volumenFt3 = volIn3 > 0 ? volIn3 / 1728 : 0

  if (Math.max(pesoReal, pesoVolumetrico) > 15 || volumenFt3 > 1.2) {
    return 'maritimo'
  }
  return 'aereo'
}

/**
 * Calcula la cotización puesta en Venezuela (USD y Bs a tasa BCV) para un
 * producto y método de envío (`aereo` o `maritimo`).
 */
export function calcularCotizacion(
  producto: Pick<ProductoResumen, 'titulo' | 'categoria' | 'precioUsd' | 'pesoLb' | 'dimensionesIn'>,
  tarifas: TarifasCompra,
  envio: MetodoEnvio,
  cantidad = 1,
): CotizacionCompra {
  const qty = Math.max(1, Math.floor(Number.isFinite(cantidad) ? cantidad : 1))
  const unitPriceUsd = redondearCentavos(Math.max(0, producto.precioUsd))
  const subtotalUsd = redondearCentavos(unitPriceUsd * qty)

  const weightEstimated =
    producto.pesoLb == null || !Number.isFinite(producto.pesoLb) || producto.pesoLb <= 0
  const weightLb = weightEstimated
    ? redondearCentavos(tarifas.fallbackWeightLb)
    : redondearCentavos(producto.pesoLb as number)

  const dims = dimensionesValidas(producto.dimensionesIn)
  const volIn3 = dims ? dims.largo * dims.ancho * dims.alto : 0
  const volumetricWeightLb = dims ? redondearCentavos(volIn3 / 139) : 0
  const volumeFt3 = dims ? redondear4(volIn3 / 1728) : 0

  const taxUsaUsd = redondearCentavos(subtotalUsd * (tarifas.taxUsaPct / 100))

  let shippingUsd: number
  if (envio === 'aereo') {
    const pesoCobrable = Math.max(weightLb, volumetricWeightLb)
    shippingUsd = Math.max(
      redondearCentavos(tarifas.airMinUsd),
      redondearCentavos(pesoCobrable * qty * tarifas.airRatePerLbUsd),
    )
  } else {
    const volumenCobrable = Math.max(dims ? volumeFt3 : 0.5, 0.1)
    shippingUsd = Math.max(
      redondearCentavos(tarifas.seaMinUsd),
      redondearCentavos(volumenCobrable * qty * tarifas.seaRatePerFt3Usd),
    )
  }

  const serviceFeeUsd = redondearCentavos(subtotalUsd * (tarifas.serviceFeePct / 100))
  const totalUsd = redondearCentavos(subtotalUsd + taxUsaUsd + shippingUsd + serviceFeeUsd)
  const totalVes = redondearCentavos(totalUsd * tarifas.fxRateUsd)
  const restriccion = evaluarRestriccionMedica(producto.titulo, producto.categoria)

  return {
    shippingMethod: envio,
    quantity: qty,
    unitPriceUsd,
    subtotalUsd,
    taxUsaUsd,
    shippingUsd,
    serviceFeeUsd,
    totalUsd,
    totalVes,
    fxRateUsd: tarifas.fxRateUsd,
    weightLb,
    volumetricWeightLb,
    volumeFt3,
    weightEstimated,
    restriccion,
  }
}
