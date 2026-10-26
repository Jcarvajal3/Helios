import type { Moneda } from '@/components/ui'
import type { QueueItem } from '@/features/admin/api'

// ═══════════════════════════════════════════════════════════════════════════
// La moneda y la tasa de un pago reportado (Javier, 2026-10-26).
//
// Un pago se cotiza en bolívares: lo de órdenes en dólares (y los cargos por
// atraso) a la tasa BCV del dólar, y lo de órdenes en euros a la del euro.
// Módulo puro: lo prueba `tasaDelPago.test.ts` y lo usan la lista de Pagos
// reportados y la ficha del pago.
// ═══════════════════════════════════════════════════════════════════════════

/** Una parte del pago, en su moneda y a su tasa. */
export type ParteDelPago = {
  moneda: Moneda
  /** Lo de esta parte, en su moneda (euros en la del euro). */
  monto: number
  /** Bolívares por unidad de su moneda, de la cotización. `null` sin tasa. */
  tasa: number | null
}

type PagoConTasas = Pick<
  QueueItem,
  'amountUsd' | 'fxRate' | 'monedas' | 'fxRateEur' | 'amountEur' | 'usdPartUsd' | 'eurPartUsd'
>

/**
 * Las partes del pago, dólares primero. Sin lo de la migración
 * 20261027000000, todo el pago es una parte en dólares, que es lo que era.
 */
export function partesDelPago(pago: PagoConTasas): ParteDelPago[] {
  if (pago.monedas === undefined) {
    return [{ moneda: 'USD', monto: pago.amountUsd, tasa: pago.fxRate || null }]
  }

  const partes: ParteDelPago[] = []
  if (pago.monedas.includes('USD') && (pago.usdPartUsd ?? 0) > 0.005) {
    partes.push({ moneda: 'USD', monto: pago.usdPartUsd ?? 0, tasa: pago.fxRate || null })
  }
  if (pago.monedas.includes('EUR')) {
    partes.push({ moneda: 'EUR', monto: pago.amountEur ?? 0, tasa: pago.fxRateEur ?? null })
  }
  return partes
}

/** «Tasa euro», «Tasa dólar». */
export function etiquetaDeLaTasa(moneda: Moneda): string {
  return moneda === 'EUR' ? 'Tasa euro' : 'Tasa dólar'
}
