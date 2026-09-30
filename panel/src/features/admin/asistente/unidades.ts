import { formatDateTime, formatDay, formatUsd, formatUsdShort, formatNumero, formatPorcentaje } from '@/components/ui'
import type { Celda, Unidad, UnidadDeColumna } from './protocolo'

/**
 * Cómo se escribe una cifra del asistente según su unidad: la completa (para
 * leerla) y la corta (para el eje de un gráfico).
 *
 * Los euros van con sus céntimos. Un recuento entero va sin decimales y uno
 * con decimales, con uno; un porcentaje, igual.
 */
export type Formato = { completo: (v: number) => string; corto: (v: number) => string }

const decimales = (v: number) => (Number.isInteger(v) ? 0 : 1)

export const FORMATO: Record<Unidad, Formato> = {
  eur: { completo: formatUsd, corto: formatUsdShort },
  numero: {
    completo: (v) => formatNumero(v, decimales(v)),
    corto: (v) => formatNumero(v, decimales(v)),
  },
  pct: {
    completo: (v) => formatPorcentaje(v, decimales(v)),
    corto: (v) => formatPorcentaje(v, 0),
  },
}

/** Si el eje cuenta cosas enteras: personas, consumos, cuotas. */
export function esEntero(unidad: Unidad, valores: ReadonlyArray<number>): boolean {
  return unidad === 'numero' && valores.every(Number.isInteger)
}

/** Si una columna es de cifras: se alinea a la derecha, como en todo el panel. */
export function esColumnaDeCifras(unidad: UnidadDeColumna | undefined): boolean {
  return unidad === 'eur' || unidad === 'numero' || unidad === 'pct'
}

/**
 * Una celda de tabla. Un número con su unidad; una fecha (`YYYY-MM-DD`) como
 * día; un texto, tal cual. Lo que falta es una raya, nunca un cero.
 */
export function formatearCelda(valor: Celda, unidad: UnidadDeColumna | undefined): string {
  if (valor === null || valor === '') return '—'
  if (unidad === 'fecha' && typeof valor === 'string') {
    // Un día suelto (`date`) no se convierte de zona; un instante, sí: a Caracas.
    if (/^\d{4}-\d{2}-\d{2}$/.test(valor)) return formatDay(valor)
    if (/^\d{4}-\d{2}-\d{2}T/.test(valor)) return formatDateTime(valor)
  }
  if (typeof valor === 'string' || unidad === 'texto') return String(valor)
  if (unidad === 'fecha' || unidad === undefined) return formatNumero(valor, decimales(valor))
  return FORMATO[unidad].completo(valor)
}
