import { sumarDias } from '@/components/ui'
import type { Overview } from '@/features/admin/metrics'

/** El volumen de una ventana de días, sin la Comisión Helios. */
export type VolumenDeLaVentana = {
  /** Consumo (financed), sin la Comisión Helios. */
  financiado: number
  consumos: number
  /** `null` sin consumos: un ticket de 0 no existe. */
  ticket: number | null
  /** Personas con cuota en un consumo de la ventana: en un grupo, cada una. */
  personas: number
  /** El consumo de la ventana anterior, del mismo largo. */
  anterior: number
  /** El primer y el último día operativo de la ventana, para los enlaces. */
  desde: string
  hasta: string
}

/**
 * El volumen de la ventana, con los campos sin la Comisión Helios de `admin_overview`.
 *
 * Los de siempre (`financedUsd`, `previousUsd`, `avgTicketUsd`) llevan el
 * Comisión Helios dentro, y `activeUsers` cuenta solo a quien abrió el
 * consumo de un grupo: ninguno se enseña como consumo. La ventana es la de la
 * base: los `windowDays` días operativos que terminan en `businessDate`.
 */
export function volumenDeLaVentana(
  o: Pick<Overview, 'businessDate' | 'windowDays' | 'volume'>,
): VolumenDeLaVentana {
  const v = o.volume
  return {
    financiado: v.financedVolumeUsd,
    consumos: v.chargeCount,
    ticket: v.chargeCount > 0 ? v.avgTicketFinancedUsd : null,
    personas: v.activePeople,
    anterior: v.previousFinancedVolumeUsd,
    desde: sumarDias(o.businessDate, -(Math.max(o.windowDays, 1) - 1)),
    hasta: o.businessDate,
  }
}
