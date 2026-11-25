// ═══════════════════════════════════════════════════════════════════════════
// Cómo se nombra una cuota: «Inicial», «Cuota 1 de 2», «la cuota 2».
//
// Desde la inicial del 50% (2026-11-12, docs/07) una orden nueva tiene tres
// cuotas: la inicial (`sequence` 0, vence el día del «Sí») y las cuotas 1 y 2
// (a los 14 y 28 días). Las órdenes viejas siguen con las 1 y 2, sin inicial.
// Pintar «Cuota 0 de 3» sería mentir dos veces: la inicial no es una cuota del
// plan y el plan sigue teniendo dos. Por eso el rótulo sale de aquí y no de
// un `Cuota {sequence} de {total}` en cada pantalla.
//
// Módulo puro: se prueba en `rotuloDeCuota.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** El número de la inicial en `installments.sequence`. */
export const SECUENCIA_DE_LA_INICIAL = 0

/** Si la cuota es la inicial (la cuota 0). */
export function esLaInicial(sequence: number | null | undefined): boolean {
  return sequence === SECUENCIA_DE_LA_INICIAL
}

/**
 * El rótulo, con mayúscula, como va en una fila o una insignia: «Inicial»,
 * «Cuota 2» o, con `de`, «Cuota 2 de 2». `de` es cuántas cuotas tiene el plan
 * SIN contar la inicial (`cuotasDelPlan`); sin él no se pone el «de N».
 */
export function rotuloDeCuota(sequence: number | null | undefined, de?: number | null): string {
  if (esLaInicial(sequence)) return 'Inicial'
  if (sequence == null || !Number.isFinite(sequence)) return 'Cuota'
  return de != null && de > 0 ? `Cuota ${sequence} de ${de}` : `Cuota ${sequence}`
}

/** En minúscula, para una frase: «la inicial», «la cuota 2». */
export function laCuota(sequence: number | null | undefined): string {
  if (esLaInicial(sequence)) return 'la inicial'
  if (sequence == null || !Number.isFinite(sequence)) return 'una cuota'
  return `la cuota ${sequence}`
}

/** Cuántas cuotas tiene el plan sin contar la inicial: el N de «Cuota n de N». */
export function cuotasDelPlan(cuotas: ReadonlyArray<{ sequence: number | null }>): number {
  return cuotas.filter((c) => c.sequence != null && !esLaInicial(c.sequence)).length
}

/**
 * Cuántas cuotas tiene el plan a partir de lo que trae la base: el total de
 * cuotas de la orden (`installments_total`, que con inicial cuenta también la
 * cuota 0) y el % de la inicial de la orden (`down_payment_pct`; null o 0 =
 * orden sin inicial).
 */
export function cuotasDelPlanDe(total: number, downPaymentPct: number | null | undefined): number {
  return (downPaymentPct ?? 0) > 0 ? Math.max(total - 1, 0) : total
}

/**
 * Lo cobrado de una orden en una frase corta: «1 de 2» sin inicial; con ella,
 * «Inicial + 1 de 2» o «Inicial sin pagar». Sin cuotas, null.
 *
 * Con inicial, una cuota pagada es primero la inicial: la orden no se activa
 * sin ella y lo que vence hoy va primero (`helios_quote_installments`), así
 * que «pagadas» ≥ 1 quiere decir que la inicial está pagada.
 */
export function cobradoDeLaOrden(orden: {
  pagadas: number
  total: number
  downPaymentPct: number | null | undefined
}): string | null {
  if (orden.total <= 0) return null
  if ((orden.downPaymentPct ?? 0) <= 0) return `${orden.pagadas} de ${orden.total}`
  if (orden.pagadas <= 0) return 'Inicial sin pagar'
  return `Inicial + ${orden.pagadas - 1} de ${cuotasDelPlanDe(orden.total, orden.downPaymentPct)}`
}

/** Lo que hace falta de un pago reportado para saber qué cuotas salda (`QueueItem`). */
type PagoConCompras = {
  purchases: ReadonlyArray<{
    installmentsTotal: number
    downPaymentPct: number | null
    installments: ReadonlyArray<{ sequence: number }>
  }>
}

/** Si el pago salda la inicial de alguna de sus órdenes (la cuota 0). */
export function pagaLaInicial(pago: PagoConCompras): boolean {
  return pago.purchases.some((c) => c.installments.some((i) => esLaInicial(i.sequence)))
}

/**
 * Qué cuotas salda un pago, en una frase: «Inicial», «Cuota 1 de 2» o, si
 * junta varias, «Inicial + Cuota 1 de 2». Con varias órdenes se juntan todas,
 * la inicial primero.
 */
export function quePagaElPago(pago: PagoConCompras): string {
  const rotulos = pago.purchases
    .flatMap((c) => {
      const de = cuotasDelPlanDe(c.installmentsTotal, c.downPaymentPct)
      return [...c.installments].sort((a, b) => a.sequence - b.sequence).map((i) => rotuloDeCuota(i.sequence, de))
    })
    .sort((a, b) => Number(b === 'Inicial') - Number(a === 'Inicial'))
  return rotulos.join(' + ')
}

/** Solo las cuotas del plan (la 1, la 2…): lo que miran la mora, el cobro a tiempo y las cohortes. */
export function sinLaInicial<T extends { sequence: number | null }>(cuotas: ReadonlyArray<T>): T[] {
  return cuotas.filter((c) => !esLaInicial(c.sequence))
}
