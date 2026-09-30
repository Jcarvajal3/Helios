import type { SettlementReason } from '@/features/admin/api'

// ═══════════════════════════════════════════════════════════════════════════
// Los nombres de los pagos a clínicas, en un solo sitio.
//
// El tipo de liquidación estaba escrito dos veces (la página del local y la de
// una transferencia) y el medio de pago tres. Módulo puro: lo prueban
// `liquidaciones.test.ts` y lo usan las pantallas y `api.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Por qué se le debe a la clínica una liquidación. */
export const MOTIVO_DE_LIQUIDACION: Record<SettlementReason, string> = {
  advance: 'Adelanto',
  scheduled_installment: 'Cuota por fecha',
  on_collection: 'Cuota cobrada',
}

export type PayoutMethod = 'pago_movil' | 'transferencia' | 'zelle' | 'usdt' | 'efectivo'

/**
 * Los medios por los que se le paga a una clínica, con su nombre. Son también
 * los de los pacientes al registrar un pago.
 */
export const METODOS_DE_PAGO: Array<{ value: PayoutMethod; label: string }> = [
  { value: 'pago_movil', label: 'Pago Móvil' },
  { value: 'transferencia', label: 'Transferencia' },
  { value: 'zelle', label: 'Zelle' },
  { value: 'usdt', label: 'USDT' },
  { value: 'efectivo', label: 'Efectivo' },
]

/** El nombre de un medio. Uno que no está en la lista sale tal cual, no en blanco. */
export function nombreDelMedio(metodo: string): string {
  return METODOS_DE_PAGO.find((m) => m.value === metodo)?.label ?? metodo
}

/** Si el medio sale en el extracto en bolívares y lleva referencia. */
export function medioConReferencia(metodo: PayoutMethod): boolean {
  return metodo !== 'efectivo'
}

// ── La tasa del día de salida ─────────────────────────────────────────────

/**
 * La tasa BCV vigente un día: la publicada ese día o, si no hubo (fin de
 * semana, feriado), la última anterior. `null` si no hay ninguna tan vieja.
 *
 * Es la tasa con la que el banco convirtió la transferencia el día que salió,
 * que no es la de hoy si se registra el lunes lo que se pagó el viernes.
 */
export function tasaDelDia(
  historial: ReadonlyArray<{ effectiveDate: string; rate: number }>,
  dia: string,
): number | null {
  let mejor: { effectiveDate: string; rate: number } | null = null
  for (const fila of historial) {
    if (fila.effectiveDate > dia) continue
    if (!mejor || fila.effectiveDate > mejor.effectiveDate) mejor = fila
  }
  return mejor?.rate ?? null
}

/** Dólares a bolívares, al céntimo. */
export function aBolivares(eur: number, tasa: number): number {
  return Math.round(eur * tasa * 100) / 100
}
