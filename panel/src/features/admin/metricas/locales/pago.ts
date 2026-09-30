import type { CuotaDeCohorte, LocalesDeLaSemana } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// «Cómo paga la gente de cada local»: la cuota 1 cobrada a tiempo, por semana
// de consumo, en las cuatro semanas ANTERIORES a la elegida (la elegida
// todavía no tiene su cuota 1 juzgada si está en curso).
//
// Una cuota se juzga cuando cierra su plazo (vencimiento + días de gracia):
// antes no se sabe si llegará a tiempo. Es la tasa canónica —a tiempo ÷ con
// el plazo cerrado— de `metricas.cuotas`, la misma de Cohortes y Cobranza.
//
// Puro: se prueba en `pago.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Cuántas semanas de consumo se enseñan por local. */
export const COHORTES_DE_PAGO = 4

export type CeldaDePago =
  /** El local no vendió esa semana. */
  | { semana: string; estado: 'sin-ventas' }
  /** Vendió, pero ninguna cuota 1 ha cerrado su plazo todavía. */
  | { semana: string; estado: 'sin-veredicto'; cuotas: number }
  | {
      semana: string
      estado: 'juzgada'
      /** De 0 a 100. */
      pct: number
      cuotas: number
      juzgadas: number
      aTiempo: number
    }

export type FilaDePago = { merchantId: string; nombre: string; celdas: CeldaDePago[] }

function celda(semana: string, c: CuotaDeCohorte | null): CeldaDePago {
  if (!c || c.cuotas === 0) return { semana, estado: 'sin-ventas' }
  if (c.juzgadas === 0 || c.pctATiempo === null) return { semana, estado: 'sin-veredicto', cuotas: c.cuotas }
  return {
    semana,
    estado: 'juzgada',
    pct: c.pctATiempo,
    cuotas: c.cuotas,
    juzgadas: c.juzgadas,
    aTiempo: c.aTiempoJuzgadas,
  }
}

/**
 * Las celdas de cada local. Salen los que vendieron en alguna de esas
 * semanas, en el orden de la tabla (de más a menos consumo en la elegida).
 */
export function comoPagaLaGente(
  d: LocalesDeLaSemana,
  n = COHORTES_DE_PAGO,
): { semanas: string[]; filas: FilaDePago[] } {
  const semanas = d.cohortes.semanas.filter((s) => s < d.semana.desde).slice(-n)
  const orden = new Map(d.locales.map((l, i) => [l.merchantId, i] as const))

  const filas = d.cohortes.locales
    .map((l) => {
      const porSemana = new Map(l.semanas.map((s) => [s.semana, s.cuota1] as const))
      return {
        merchantId: l.merchantId,
        nombre: l.nombre,
        celdas: semanas.map((s) => celda(s, porSemana.get(s) ?? null)),
      }
    })
    .filter((f) => f.celdas.some((c) => c.estado !== 'sin-ventas'))
    .sort(
      (a, b) =>
        (orden.get(a.merchantId) ?? Number.MAX_SAFE_INTEGER) - (orden.get(b.merchantId) ?? Number.MAX_SAFE_INTEGER) ||
        a.nombre.localeCompare(b.nombre, 'es'),
    )

  return { semanas, filas }
}
