import type { ChartPoint } from '@/components/charts/comun'

import { semanaCorta } from './semanas'
import type { CuotaDeCohorte, LocalesDeLaSemana, SerieDeLocal } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// La ficha analítica de un local elegido: su serie de semanas y cómo paga su
// gente semana de consumo a semana de consumo.
//
// Las cifras salen de `admin_metricas_locales` (con el local); aquí solo se
// ordenan para pintarlas.
//
// Puro: se prueba en `ficha.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** La serie del local pedido, o `null` si la base no la trajo. */
export function serieDelLocal(d: LocalesDeLaSemana, merchantId: string): SerieDeLocal | null {
  return d.series.locales.find((s) => s.merchantId === merchantId) ?? null
}

function contar(n: number, una: string, varias: string): string {
  return `${n} ${n === 1 ? una : varias}`
}

/** Las semanas de la serie como puntos de un gráfico de barras del consumo. */
export function puntosDelConsumo(semanas: ReadonlyArray<string>, s: SerieDeLocal): ChartPoint[] {
  return semanas.map((semana, i) => ({
    key: semana,
    label: semanaCorta(semana),
    values: [s.consumoUsd[i] ?? 0],
    note: `${contar(s.consumos[i] ?? 0, 'financiamiento', 'financiamientos')} · ${contar(s.personas[i] ?? 0, 'paciente', 'pacientes')}`,
  }))
}

/** Las últimas `n` semanas de una serie (o sus lunes), para la chispa de una tarjeta. */
export function ultimas<T>(valores: ReadonlyArray<T>, n = 8): T[] {
  return valores.slice(-n)
}

// ── Cómo paga su gente ─────────────────────────────────────────────────────

export type FilaDeCohorteDelLocal = {
  semana: string
  consumoUsd: number
  consumos: number
  personas: number
  cuota1: CuotaDeCohorte | null
  cuota2: CuotaDeCohorte | null
}

/**
 * Las semanas de consumo del local, de la más nueva a la más vieja, con lo
 * consumido (de la serie) y el estado de hoy de sus dos cuotas.
 */
export function cohortesDelLocal(d: LocalesDeLaSemana, merchantId: string): FilaDeCohorteDelLocal[] {
  const cohortes = d.cohortes.locales.find((c) => c.merchantId === merchantId)
  const serie = serieDelLocal(d, merchantId)
  const indice = new Map(d.series.semanas.map((s, i) => [s, i] as const))
  if (!cohortes) return []

  return [...cohortes.semanas].reverse().map((c) => {
    const i = indice.get(c.semana)
    return {
      semana: c.semana,
      consumoUsd: i === undefined || !serie ? 0 : (serie.consumoUsd[i] ?? 0),
      consumos: i === undefined || !serie ? 0 : (serie.consumos[i] ?? 0),
      personas: i === undefined || !serie ? 0 : (serie.personas[i] ?? 0),
      cuota1: c.cuota1,
      cuota2: c.cuota2,
    }
  })
}

