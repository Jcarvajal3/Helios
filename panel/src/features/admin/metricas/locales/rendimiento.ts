import { delta } from '@/features/admin/metricas/formato'
import type { Delta } from '@/features/admin/metricas/formato'

import type { FilaLocal, LocalesDeLaSemana } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// Las cuentas de pintar de los locales en la semana: quién vendió, contra qué
// se compara y qué parte de su gente ya había venido.
//
// Viene de lo que era Directorio › Locales › Rendimiento
// (`features/admin/rendimientoLocales.ts`), sobre la fila de
// `admin_metricas_locales`. Ninguna cifra de negocio nace aquí: son
// proporciones y comparaciones de lo que ya da la base.
//
// Puro: se prueba en `rendimiento.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Los locales que consumieron algo en la semana, en el mismo orden. */
export function conVentas(locales: ReadonlyArray<FilaLocal>): FilaLocal[] {
  return locales.filter((l) => l.consumoUsd > 0)
}

/**
 * El que más consumió, si alguien consumió y no empata con otro: una frase no
 * puede coronar a uno cuando dos vendieron exactamente lo mismo.
 */
export function elQueMasConsumio(locales: ReadonlyArray<FilaLocal>): FilaLocal | null {
  const vendieron = [...conVentas(locales)].sort((a, b) => b.consumoUsd - a.consumoUsd)
  const uno = vendieron.at(0)
  const dos = vendieron.at(1)
  if (uno === undefined) return null
  return dos !== undefined && dos.consumoUsd === uno.consumoUsd ? null : uno
}

/**
 * El consumo frente a la semana anterior (a la misma altura si la elegida va
 * a medias). `null` si no consumió ni ahora ni antes.
 */
export function frenteALaAnterior(l: FilaLocal): Delta | null {
  return delta(l.consumoUsd, l.consumoAnteriorUsd, { tipo: 'relativo', arribaEsBueno: true })
}

/** Los consumos frente a la semana anterior, con la misma regla. */
export function consumosFrenteALaAnterior(l: FilaLocal): Delta | null {
  return delta(l.consumos, l.consumosAnteriores, { tipo: 'relativo', arribaEsBueno: true })
}

/** El ticket medio de la semana anterior, o `null` si no hubo consumos. */
export function ticketAnterior(l: FilaLocal): number | null {
  return l.consumosAnteriores > 0 ? l.consumoAnteriorUsd / l.consumosAnteriores : null
}

/**
 * El cambio en porcentaje, para ordenar y para el CSV. Nulo si antes fue
 * cero: de nada a algo no es un «∞ %», y ordenar por eso lo pondría arriba.
 */
export function variacion(actual: number, anterior: number): number | null {
  if (anterior === 0) return null
  return ((actual - anterior) / Math.abs(anterior)) * 100
}

/** La gente que ya había consumido en el local antes de esta semana. */
export function recurrentes(l: FilaLocal): number {
  return Math.max(0, l.personas - l.nuevas)
}

/**
 * Qué parte de sus consumos fue en grupo, de 0 a 100. Nulo sin consumos.
 * Heredado de Ronda: en Helios no hay grupos y la tabla ya no lo enseña.
 */
export function pctEnGrupo(l: FilaLocal): number | null {
  return l.consumos > 0 ? (l.consumosEnGrupo / l.consumos) * 100 : null
}

/**
 * El local que más creció frente a la anterior, entre los que ya vendían
 * antes y suben al menos un 1 %. `null` si ninguno sube.
 */
export function elQueMasCrecio(locales: ReadonlyArray<FilaLocal>): { local: FilaLocal; pct: number } | null {
  let mejor: { local: FilaLocal; pct: number } | null = null
  for (const l of locales) {
    const pct = variacion(l.consumoUsd, l.consumoAnteriorUsd)
    if (pct === null || pct < 1) continue
    if (!mejor || pct > mejor.pct) mejor = { local: l, pct }
  }
  return mejor
}

/** Con qué se compara la semana, dicho en palabras. */
export function referenciaDeLaAnterior(d: Pick<LocalesDeLaSemana, 'anterior'>): string {
  return d.anterior.mismaAltura ? 'la semana pasada a la misma altura' : 'la semana anterior'
}
