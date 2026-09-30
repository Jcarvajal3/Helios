import { unoDe } from '@/lib/busqueda'

// ═══════════════════════════════════════════════════════════════════════════
// Las claves propias de la pestaña Semana en la URL de `/admin/metricas`.
// Nunca `vista`, `semana` ni `local`: son del marco. El marco solo llama a
// `validarSemana` cuando Semana es la pestaña activa, así que otra pestaña
// puede usar la misma palabra sin chocar.
//
// Cada clave pasa validada o no pasa (`@/lib/busqueda`): `undefined` es «como
// si no viniera» y la pestaña usa su valor por defecto.
// ═══════════════════════════════════════════════════════════════════════════

/** Cuántas semanas enseña la tabla «Semana a semana». */
export const COLUMNAS_DE_SEMANAS = ['8', '12', '26'] as const

export type ColumnasDeSemanas = (typeof COLUMNAS_DE_SEMANAS)[number]

/** Sin clave en la URL, ocho: las que caben sin arrastrar la tabla. */
export const COLUMNAS_POR_DEFECTO: ColumnasDeSemanas = '8'

export type BusquedaSemana = {
  /** Las columnas de la tabla. Las cinco cifras de arriba miran siempre las ocho últimas. */
  semanas?: ColumnasDeSemanas
}

export function validarSemana(raw: Record<string, unknown>): BusquedaSemana {
  return { semanas: unoDe(COLUMNAS_DE_SEMANAS, raw.semanas) }
}

/** El número de columnas que se piden, con el valor por defecto aplicado. */
export function columnasDe(busqueda: BusquedaSemana): number {
  return Number(busqueda.semanas ?? COLUMNAS_POR_DEFECTO)
}
