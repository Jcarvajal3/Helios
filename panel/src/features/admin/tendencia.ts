import { formatNumero } from '@/components/ui'
import type { StatTrend } from '@/components/ui'

// ═══════════════════════════════════════════════════════════════════════════
// La flecha de una cifra frente a su periodo anterior.
//
// Vivía dentro de Crecimiento › Gente y el Resumen necesitaba la misma: dos
// copias acaban decidiendo distinto qué es «igual» y la misma subida sale
// verde en una pantalla y gris en otra.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * El cambio en porcentaje: «35 % más».
 *
 * En porcentaje y no en unidades porque es lo que se compara entre tarjetas:
 * «+4» no dice nada si no se sabe si eran 6 o 600. Sin periodo anterior no hay
 * porcentaje, pero pasar de nada a algo se dice («nuevo»). Por debajo del uno
 * por ciento la flecha sería ruido y se escribe «igual».
 */
export function tendencia(
  actual: number,
  anterior: number,
  { upIsGood = true }: { upIsGood?: boolean } = {},
): StatTrend | undefined {
  if (anterior === 0) {
    return actual === 0 ? undefined : { label: 'nuevo', direction: 'up', upIsGood }
  }

  const pct = ((actual - anterior) / Math.abs(anterior)) * 100
  if (Math.abs(pct) < 1) return { label: 'igual', direction: 'flat', upIsGood }

  return {
    label: `${formatNumero(Math.abs(pct), 0)} % ${pct > 0 ? 'más' : 'menos'}`,
    direction: pct > 0 ? 'up' : 'down',
    upIsGood,
  }
}

/**
 * El cambio de una tasa, en puntos: «2,1 puntos más».
 *
 * Una mora que pasa del 4 % al 6 % no ha subido «un 50 %»: ha subido dos
 * puntos, y dicho en porcentaje asusta sin motivo. Sin uno de los dos valores
 * no hay flecha. Por defecto subir es malo, que es lo que pasa con una tasa de
 * mora o de impago.
 */
export function tendenciaEnPuntos(
  actual: number | null,
  anterior: number | null,
  { upIsGood = false }: { upIsGood?: boolean } = {},
): StatTrend | undefined {
  if (actual === null || anterior === null) return undefined

  const puntos = actual - anterior
  const escrito = formatNumero(Math.abs(puntos))
  if (escrito === formatNumero(0)) return { label: 'igual', direction: 'flat', upIsGood }

  return {
    label: `${escrito} ${escrito === formatNumero(1) ? 'punto' : 'puntos'} ${puntos > 0 ? 'más' : 'menos'}`,
    direction: puntos > 0 ? 'up' : 'down',
    upIsGood,
  }
}
