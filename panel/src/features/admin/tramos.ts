import { valorDe } from '@/features/admin/parametros'
import type { Parametros } from '@/features/admin/parametros'

// ═══════════════════════════════════════════════════════════════════════════
// Los tramos de atraso.
//
// Cada corte es un momento en que le pasa algo a la persona, así que cada
// tramo pide una gestión distinta:
//
//   t1  1 … gracia                   cupo congelado, todavía sin cargo
//   t2  gracia+1 … intervalo         ya lleva cargo por atraso
//   t3  intervalo+1 … baja−1         la segunda cuota también venció
//   t4  baja … expulsión             baja de nivel y cuenta suspendida
//   t5  más de expulsión             expulsión; la deuda se da por perdida
//
// Los días salen de los parámetros vigentes, igual que en la base
// (`admin_collection_flow`, 20260925101000): si cambia la gracia, los tramos
// se mueven con ella. Por eso aquí no hay ningún número escrito.
// ═══════════════════════════════════════════════════════════════════════════

export type Tramo = 'al_dia' | 't1' | 't2' | 't3' | 't4' | 't5'
export type TramoVencido = Exclude<Tramo, 'al_dia'>

export const TRAMOS_VENCIDOS: readonly TramoVencido[] = ['t1', 't2', 't3', 't4', 't5']

/** Los cuatro días que cortan los tramos. */
export type CortesDeTramo = {
  gracia: number
  intervalo: number
  baja: number
  expulsion: number
}

/** Qué le pasa a la persona en cada tramo, en una frase. */
export const QUE_PASA_EN_EL_TRAMO: Record<TramoVencido, string> = {
  t1: 'Cupo congelado, todavía sin cargo por atraso.',
  t2: 'Ya lleva cargo por atraso.',
  t3: 'La segunda cuota también está vencida.',
  t4: 'Baja de nivel y cuenta suspendida.',
  t5: 'Expulsión; la deuda se da por perdida.',
}

/** Los cortes vigentes, o `null` mientras falte alguno. */
export function cortesDeTramo(p: Parametros | undefined): CortesDeTramo | null {
  const gracia = valorDe(p, 'late_fee_grace_days')
  const intervalo = valorDe(p, 'installment_interval_days')
  const baja = valorDe(p, 'mora_demotion_days')
  const expulsion = valorDe(p, 'mora_expulsion_days')
  if (gracia === null || intervalo === null || baja === null || expulsion === null) return null
  return { gracia, intervalo, baja, expulsion }
}

/** El tramo de alguien con `dias` de atraso (0 o menos: al día). */
export function tramoDe(dias: number, c: CortesDeTramo): Tramo {
  if (dias <= 0) return 'al_dia'
  if (dias <= c.gracia) return 't1'
  if (dias <= c.intervalo) return 't2'
  if (dias < c.baja) return 't3'
  if (dias <= c.expulsion) return 't4'
  return 't5'
}

/** Primer y último día del tramo. `hasta: null` = sin tope. */
export function rangoDeTramo(t: TramoVencido, c: CortesDeTramo): { desde: number; hasta: number | null } {
  switch (t) {
    case 't1':
      return { desde: 1, hasta: c.gracia }
    case 't2':
      return { desde: c.gracia + 1, hasta: c.intervalo }
    case 't3':
      return { desde: c.intervalo + 1, hasta: c.baja - 1 }
    case 't4':
      return { desde: c.baja, hasta: c.expulsion }
    case 't5':
      return { desde: c.expulsion + 1, hasta: null }
  }
}

/**
 * Un tramo puede quedar vacío si los parámetros se cruzan (una gracia más larga
 * que el intervalo, por ejemplo). Un tramo vacío no se ofrece como filtro.
 */
export function tramoVacio(t: TramoVencido, c: CortesDeTramo): boolean {
  const { desde, hasta } = rangoDeTramo(t, c)
  return hasta !== null && desde > hasta
}

/** «1–3 días», «8 días», «Más de 60 días». */
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
