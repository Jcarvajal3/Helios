import type { Moneda } from '@/components/ui'
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
  staff_commission: 'Comisión del personal',
}

export type PayoutMethod = 'pago_movil' | 'transferencia' | 'zelle' | 'usdt' | 'efectivo'

/** El nombre de cada medio, también de los que ya no se ofrecen: un pago viejo se sigue leyendo. */
const NOMBRE_DEL_MEDIO: Record<PayoutMethod, string> = {
  pago_movil: 'Pago Móvil',
  transferencia: 'Transferencia',
  zelle: 'Zelle',
  usdt: 'USDT',
  efectivo: 'Efectivo',
}

/**
 * Los medios por los que se le paga a una clínica: a la clínica se le paga en
 * bolívares, por Pago Móvil o transferencia, como el archivo del pago masivo.
 * Zelle, USDT y efectivo eran de Ronda: siguen en el enum de la base para leer
 * lo viejo, pero no se ofrecen. NO son los del paciente
 * (`METODOS_DEL_PACIENTE`, en `pagosRegistrados/registrarPago.ts`).
 */
export const METODOS_DE_PAGO: Array<{ value: PayoutMethod; label: string }> = (
  ['pago_movil', 'transferencia'] as const
).map((value) => ({ value, label: NOMBRE_DEL_MEDIO[value] }))

/** El nombre de un medio. Uno que no está en la lista sale tal cual, no en blanco. */
export function nombreDelMedio(metodo: string): string {
  return (NOMBRE_DEL_MEDIO as Partial<Record<string, string>>)[metodo] ?? metodo
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

/** Un monto (en dólares o en euros) a bolívares con su tasa, al céntimo. */
export function aBolivares(monto: number, tasa: number): number {
  return Math.round(monto * tasa * 100) / 100
}

// ── Lo que va en cada moneda ──────────────────────────────────────────────

/**
 * Una liquidación marcada, con lo que hace falta para saber en qué moneda va
 * (2026-10-07: una orden se cobra en dólares o en euros, y a la clínica se le
 * paga en bolívares a la tasa BCV de esa moneda del día del pago).
 */
export type LineaAPagar = {
  id: string
  dueDate: string
  currency: Moneda
  amountUsd: number
  amountCur: number
  pendingUsd: number
  pendingCur: number
  /** Lo que falta, en bolívares de hoy a la tasa de su moneda (lo manda la base). */
  pendingVesHoy?: number | null
}

/** Lo que un pago lleva en cada moneda, cada parte en la suya. */
export type PartesPorMoneda = Record<Moneda, number>

/** Las monedas de lo marcado, sin repetir: dólares primero. */
export function monedasDe(lineas: ReadonlyArray<Pick<LineaAPagar, 'currency'>>): Moneda[] {
  const hay = new Set(lineas.map((l) => l.currency))
  return (['USD', 'EUR'] as const).filter((m) => hay.has(m))
}

/**
 * Cuánto de un pago de `importeUsd` dólares va en cada moneda, con el mismo
 * reparto que la base (`admin_report_merchant_payout`): de la liquidación más
 * antigua a la más nueva; la que se salda entera aporta lo que le faltaba en
 * su moneda, y la última, si queda a medias, la parte proporcional.
 */
export function partesPorMoneda(lineas: ReadonlyArray<LineaAPagar>, importeUsd: number): PartesPorMoneda {
  const partes: PartesPorMoneda = { USD: 0, EUR: 0 }
  let restante = importeUsd
  const ordenadas = [...lineas].sort((a, b) => a.dueDate.localeCompare(b.dueDate) || a.id.localeCompare(b.id))

  for (const l of ordenadas) {
    if (restante <= 0) break
    const aplicado = Math.min(restante, l.pendingUsd)
    if (aplicado <= 0) continue
    const saldaEntera = aplicado >= l.pendingUsd - 0.005
    const enSuMoneda =
      saldaEntera || l.amountUsd <= 0
        ? l.pendingCur
        : Math.round(((aplicado * l.amountCur) / l.amountUsd) * 100) / 100
    partes[l.currency] = Math.round((partes[l.currency] + enSuMoneda) * 100) / 100
    restante -= aplicado
  }
  return partes
}

/**
 * Los bolívares de unas partes, cada una a la tasa de su moneda, como los
 * calcula la base (cada parte redondeada al céntimo y luego sumadas). `null`
 * si falta la tasa de una parte que no es cero: no se inventa.
 */
export function bolivaresPorMoneda(
  partes: PartesPorMoneda,
  tasas: Record<Moneda, number | null>,
): number | null {
  let total = 0
  for (const moneda of ['USD', 'EUR'] as const) {
    if (partes[moneda] <= 0) continue
    const tasa = tasas[moneda]
    if (tasa === null || tasa <= 0) return null
    total += aBolivares(partes[moneda], tasa)
  }
  return Math.round(total * 100) / 100
}
