import type { QueueItem } from './api'

/**
 * Las partes de un pago reportado. Sus cuotas son payable (llevan el service
 * comisión + IVA dentro), así que el pago solo se enseña con sus sumandos a la
 * vista: facturado (sin comisión), Comisión Helios + IVA y, si hay, cargos por atraso.
 *
 * `totalUsd` es lo que debía pagar: sus cuotas cotizadas más los cargos que
 * viajaban en la cotización. Es lo mismo que reportó, porque el reporte se
 * hace sobre la cotización; la comparación útil está en bolívares.
 */
export type SumandosDelPago = {
  cuotasUsd: number
  /** `null` si la base todavía no manda el desglose: no se inventa. */
  facturadoUsd: number | null
  feeUsd: number | null
  cargosUsd: number
  totalUsd: number
}

type PagoConDesglose = Pick<
  QueueItem,
  'installmentsUsd' | 'installmentsFinancedUsd' | 'installmentsFeeUsd' | 'lateFeeUsd'
>

export function sumandosDelPago(item: PagoConDesglose): SumandosDelPago {
  const facturado = item.installmentsFinancedUsd ?? null
  const fee = item.installmentsFeeUsd ?? null
  const desglose = facturado !== null && fee !== null
  return {
    cuotasUsd: item.installmentsUsd,
    facturadoUsd: desglose ? facturado : null,
    feeUsd: desglose ? fee : null,
    cargosUsd: item.lateFeeUsd,
    totalUsd: item.installmentsUsd + item.lateFeeUsd,
  }
}

/**
 * Los sumandos de varios pagos, para el total de una lista. Si a uno le falta
 * el desglose, el total se queda sin él (nunca un desglose a medias).
 */
export function sumandosDeLosPagos(items: ReadonlyArray<PagoConDesglose>): SumandosDelPago {
  const partes = items.map(sumandosDelPago)
  const completo = partes.every((p) => p.facturadoUsd !== null && p.feeUsd !== null)
  const suma = (f: (p: SumandosDelPago) => number) => partes.reduce((s, p) => s + f(p), 0)
  return {
    cuotasUsd: suma((p) => p.cuotasUsd),
    facturadoUsd: completo ? suma((p) => p.facturadoUsd ?? 0) : null,
    feeUsd: completo ? suma((p) => p.feeUsd ?? 0) : null,
    cargosUsd: suma((p) => p.cargosUsd),
    totalUsd: suma((p) => p.totalUsd),
  }
}

/**
 * La línea de los sumandos, con el formato de dinero que se le pase:
 * «facturado €30,00 + Comisión Helios + IVA €6,96 + cargos por atraso €8,00».
 * `null` sin desglose. Los cargos solo si los hay.
 */
export function lineaDeSumandos(s: SumandosDelPago, dinero: (n: number) => string): string | null {
  if (s.facturadoUsd === null || s.feeUsd === null) return null
  const partes = [`financiado ${dinero(s.facturadoUsd)}`, `Comisión Helios + IVA ${dinero(s.feeUsd)}`]
  if (s.cargosUsd > 0.005) partes.push(`cargos por atraso ${dinero(s.cargosUsd)}`)
  return partes.join(' + ')
}
