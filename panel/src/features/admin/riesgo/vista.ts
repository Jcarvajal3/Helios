import { comoEntero } from '@/lib/busqueda'
import type { DimensionPrimeraCuota } from './credito'
import type { MedidaDeCurva } from './cosechas'

// El estado de la pantalla Riesgo de crédito, tal como vive en la URL. Va
// aparte de la ruta para que las pestañas lo lean y lo escriban con los mismos
// tipos, y para probar el validador sin montar el router.

export type VistaRiesgo = 'resumen' | 'primera-cuota' | 'cosechas' | 'cupos'

export const VISTAS_RIESGO: ReadonlyArray<{ value: VistaRiesgo; label: string }> = [
  { value: 'resumen', label: 'Resumen' },
  { value: 'primera-cuota', label: 'Primera cuota' },
  { value: 'cosechas', label: 'Cosechas' },
  { value: 'cupos', label: 'Cupos' },
]

/** La ventana del volumen, en días. */
export type VentanaRiesgo = 7 | 30 | 90

export const VENTANAS_RIESGO: readonly VentanaRiesgo[] = [7, 30, 90]

export const MEDIDAS_DE_CURVA: ReadonlyArray<{ value: MedidaDeCurva; label: string }> = [
  { value: 'vencido', label: 'Vencido sin pagar' },
  { value: 'perdido', label: 'Dado por perdido' },
]

export type BusquedaRiesgo = {
  vista?: VistaRiesgo
  dias?: VentanaRiesgo
  dim?: DimensionPrimeraCuota
  curva?: MedidaDeCurva
  /** El lunes del paso entre tramos que se está mirando. */
  corte?: string
}

/** Una ventana de la lista, venga como número o como texto. */
export function comoVentana(v: unknown): VentanaRiesgo | undefined {
  const n = typeof v === 'number' ? v : comoEntero(v)
  return VENTANAS_RIESGO.find((x) => x === n)
}

