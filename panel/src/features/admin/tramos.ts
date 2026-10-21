import { valorDe } from '@/features/admin/parametros'
import type { Parametros } from '@/features/admin/parametros'

// ═══════════════════════════════════════════════════════════════════════════
// Los tramos de atraso.
//
// Cada corte es un momento en que le pasa algo a la persona, así que cada
// tramo pide una gestión distinta:
//
//   t1  1 … intervalo                la cuota 1 vencida; cuenta congelada
//   t2  intervalo+1 … baja−1         las dos cuotas vencidas
//   t3  baja … expulsión             cuenta suspendida (y baja un nivel si
//                                    tiene más de uno)
//   t4  más de expulsión             expulsado; la deuda se da por perdida
//
// Eran cinco, como en Ronda, con la primera semana partida por la gracia
// (sin cargo / con cargo por atraso). Helios no cobra cargo por atraso, así
// que desde el 2026-10-19 (Javier) son cuatro y la gracia ya no corta tramos
// (20261019220000_cuatro_tramos_de_atraso.sql).
//
// Los días salen de los parámetros vigentes, igual que en la base
// (`helios_tramo_de_atraso`): si cambia el intervalo, los tramos se mueven
// con él. Por eso aquí no hay ningún número escrito.
// ═══════════════════════════════════════════════════════════════════════════

export type Tramo = 'al_dia' | 't1' | 't2' | 't3' | 't4'
export type TramoVencido = Exclude<Tramo, 'al_dia'>

export const TRAMOS_VENCIDOS: readonly TramoVencido[] = ['t1', 't2', 't3', 't4']

/** Los tres días que cortan los tramos. */
export type CortesDeTramo = {
  intervalo: number
  baja: number
  expulsion: number
}

/** Qué le pasa a la persona en cada tramo, en una frase. */
export const QUE_PASA_EN_EL_TRAMO: Record<TramoVencido, string> = {
  t1: 'La cuota 1 vencida; cuenta congelada.',
  t2: 'Las dos cuotas vencidas.',
  t3: 'Cuenta suspendida (y baja un nivel si tiene más de uno).',
  t4: 'Expulsado; la deuda se da por perdida.',
}

/** Los cortes vigentes, o `null` mientras falte alguno. */
export function cortesDeTramo(p: Parametros | undefined): CortesDeTramo | null {
  const intervalo = valorDe(p, 'installment_interval_days')
  const baja = valorDe(p, 'mora_demotion_days')
  const expulsion = valorDe(p, 'mora_expulsion_days')
  if (intervalo === null || baja === null || expulsion === null) return null
  return { intervalo, baja, expulsion }
}

/** El tramo de alguien con `dias` de atraso (0 o menos: al día). */
export function tramoDe(dias: number, c: CortesDeTramo): Tramo {
  if (dias <= 0) return 'al_dia'
  if (dias <= c.intervalo) return 't1'
  if (dias < c.baja) return 't2'
  if (dias <= c.expulsion) return 't3'
  return 't4'
}

/** Primer y último día del tramo. `hasta: null` = sin tope. */
export function rangoDeTramo(t: TramoVencido, c: CortesDeTramo): { desde: number; hasta: number | null } {
  switch (t) {
    case 't1':
      return { desde: 1, hasta: c.intervalo }
    case 't2':
      return { desde: c.intervalo + 1, hasta: c.baja - 1 }
    case 't3':
      return { desde: c.baja, hasta: c.expulsion }
    case 't4':
      return { desde: c.expulsion + 1, hasta: null }
  }
}

/**
 * Un tramo puede quedar vacío si los parámetros se cruzan (un intervalo igual
 * o más largo que los días de la baja, por ejemplo). Un tramo vacío no se ofrece como filtro.
 */
export function tramoVacio(t: TramoVencido, c: CortesDeTramo): boolean {
  const { desde, hasta } = rangoDeTramo(t, c)
  return hasta !== null && desde > hasta
}

/** «1–7 días», «8 días», «Más de 60 días». */
export function rotuloDeTramo(t: TramoVencido, c: CortesDeTramo): string {
  const { desde, hasta } = rangoDeTramo(t, c)
  if (hasta === null) return `Más de ${desde - 1} días`
  if (desde === hasta) return desde === 1 ? '1 día' : `${desde} días`
  return `${desde}–${hasta} días`
}

/** Los tramos que tienen al menos un día, con su rótulo. Lo que pinta un filtro. */
export function tramosConRotulo(c: CortesDeTramo): Array<{ tramo: TramoVencido; rotulo: string }> {
  return TRAMOS_VENCIDOS.filter((t) => !tramoVacio(t, c)).map((tramo) => ({
    tramo,
    rotulo: rotuloDeTramo(tramo, c),
  }))
}
