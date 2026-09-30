import {
  MESES_LARGOS,
  formatDayShort,
  formatUsd,
  formatUsdShort,
  formatPorcentaje,
} from '@/components/ui'
import type { CohortCell } from '@/components/charts'
import type { CohortBase, CohortGrain, CohortRow, CohortTotal, UserCohorts } from '@/features/admin/growth'

// ═══════════════════════════════════════════════════════════════════════════
// Lo común de la Retención (Métricas › Gente): qué se puede elegir, cómo se
// llama cada cosa según el cubo y según de dónde sale la cohorte, y cómo se
// calcula cada celda. Sin React, para que la URL lo use al validar.
// ═══════════════════════════════════════════════════════════════════════════

// ── Lo que va en la URL ────────────────────────────────────────────────────

/** El cubo, como se escribe en la URL. En la base es `day | week | month`. */
export type Cubo = 'dia' | 'semana' | 'mes'

export const CUBOS: ReadonlyArray<Cubo> = ['dia', 'semana', 'mes']

export const GRANO_DE_CUBO: Record<Cubo, CohortGrain> = { dia: 'day', semana: 'week', mes: 'month' }

export const OPCIONES_DE_CUBO: Array<{ value: Cubo; label: string }> = [
  { value: 'dia', label: 'Día' },
  { value: 'semana', label: 'Semana' },
  { value: 'mes', label: 'Mes' },
]

export type VerCohortes = 'una' | 'todas'

export const OPCIONES_DE_VER: Array<{ value: VerCohortes; label: string }> = [
  { value: 'una', label: 'Una cohorte a la vez' },
  { value: 'todas', label: 'Comparar todas' },
]

export type Medida = 'gente' | 'gasto'

export const OPCIONES_DE_MEDIDA: Array<{ value: Medida; label: string }> = [
  { value: 'gente', label: 'Se financiaron (%)' },
  { value: 'gasto', label: 'Financiado por paciente (sin fee)' },
]

/**
 * Cuántos cubos tiene sentido pedir según el cubo.
 *
 * No es la misma pregunta con los tres: 14 días son dos semanas de vida de una
 * cohorte y 14 meses son más historia de la que tiene el producto. La primera
 * opción de cada lista es la que abre.
 */
export const PERIODOS: Record<CohortGrain, readonly number[]> = {
  day: [14, 30],
  week: [8, 12],
  month: [6, 12],
}

/** El número de cubos pedido si vale para ese cubo; si no, el primero. */
export function periodosValidos(grain: CohortGrain, pedidos: number | undefined): number {
  const opciones = PERIODOS[grain]
  return opciones.find((n) => n === pedidos) ?? opciones.at(0) ?? 8
}

// ── Cómo se llama cada cosa ────────────────────────────────────────────────

type Unidad = {
  uno: string
  unos: string
  /** 'ese día', 'esa semana', 'ese mes'. */
  ese: string
  /** 'al día siguiente', 'a la semana siguiente', 'al mes siguiente'. */
  siguiente: string
  /** 'el día', 'la semana', 'el mes'. */
  el: string
  /** 'el mismo día', 'la misma semana', 'el mismo mes'. */
  elMismo: string
  lista: string
}

/**
 * Cómo se llama cada cosa según el cubo. Es casi toda la legibilidad. Las
 * columnas se escriben con `columnasDesde`, que sabe de dónde sale la cohorte.
 */
export const UNIDAD: Record<CohortGrain, Unidad> = {
  day: {
    uno: 'día',
    unos: 'días',
    ese: 'ese día',
    siguiente: 'al día siguiente',
    el: 'el día',
    elMismo: 'el mismo día',
    lista: 'Elige un día',
  },
  week: {
    uno: 'semana',
    unos: 'semanas',
    ese: 'esa semana',
    siguiente: 'a la semana siguiente',
    el: 'la semana',
    elMismo: 'la misma semana',
    lista: 'Elige una semana',
  },
  month: {
    uno: 'mes',
    unos: 'meses',
    ese: 'ese mes',
    siguiente: 'al mes siguiente',
    el: 'el mes',
    elMismo: 'el mismo mes',
    lista: 'Elige un mes',
  },
}

// ── De dónde sale la cohorte ───────────────────────────────────────────────

type TextosDeBase = {
  /** El rótulo de la cifra y de la columna de filas: 'Se registraron'. */
  entraron: string
  /** Cómo se cuenta a los de la cohorte: '1 registro', '12 registros'. */
  miembros: (n: number) => string
  /** 'se registraron': «las personas que se registraron la misma semana». */
  verbo: string
  /** 'se registró': «La gente que se registró la semana del 14». */
  laGenteQue: string
  /** Lo que se dice cuando no hay ninguna cohorte. */
  vacio: string
}

/**
 * Sin local, una cohorte es la gente que se registró junta (la semana en que
 * se aprobó su verificación de identidad). Con un local, el
 * registro no es de ningún local y la cohorte es la gente que llegó junta a
 * ese local (su primera cuota allí): cambian las palabras, no las cuentas.
 */
export const TEXTOS_DE_BASE: Record<CohortBase, TextosDeBase> = {
  registro: {
    entraron: 'Se registraron',
    miembros: (n) => `${n} ${n === 1 ? 'registro' : 'registros'}`,
    verbo: 'se registraron',
    laGenteQue: 'se registró',
    vacio: 'Todavía no se ha registrado nadie en este periodo.',
  },
  primera_visita: {
    entraron: 'Llegaron a la clínica',
    miembros: (n) => `${n} ${n === 1 ? 'paciente' : 'pacientes'}`,
    verbo: 'llegaron a la clínica',
    laGenteQue: 'llegó a la clínica',
    vacio: 'Nadie ha llegado a esta clínica en este periodo.',
  },
}

/** 'Semanas desde que se registraron', 'Días desde que llegaron al local'. */
export function columnasDesde(grain: CohortGrain, base: CohortBase): string {
  return `${mayuscula(UNIDAD[grain].unos)} desde que ${TEXTOS_DE_BASE[base].verbo}`
}

/**
 * La cohorte que abre la Retención cuando no se ha elegido una: la que
 * contiene la semana elegida arriba (su lunes; el día 1 de su mes si se
 * agrupa por mes). Si no está en la lista, la lista elige la suya.
 */
export function cohorteDeLaSemana(grain: CohortGrain, lunes: string): string {
  return grain === 'month' ? `${lunes.slice(0, 7)}-01` : lunes
}

/**
 * '15 sep' o 'sep 26', para la lista y los rótulos de fila.
 *
 * Partiendo la cadena y no con `new Date()`: '2026-09-15' se interpreta como
 * medianoche UTC y en Caracas eso es el 14 por la tarde. Una rejilla de
 * cohortes con todas las fechas corridas un día es exactamente la clase de
 * error que nadie mira dos veces.
 */
export function etiquetaCubo(start: string, grain: CohortGrain): string {
  const dia = formatDayShort(start)
  if (grain !== 'month') return dia
  // El mes corto sale del mismo formato que el día: de '1 sep', 'sep 26'.
  return `${dia.split(' ').at(1) ?? ''} ${start.slice(2, 4)}`
}

/** 'el 15 de septiembre', 'la semana del 15 de septiembre', 'en septiembre de 2026'. */
export function enFecha(start: string, grain: CohortGrain): string {
  const [y = '', m = '', d = ''] = start.slice(0, 10).split('-')
  const mes = MESES_LARGOS[Number(m) - 1] ?? m

  if (grain === 'month') return `en ${mes} de ${y}`
  if (grain === 'week') return `la semana del ${Number(d)} de ${mes}`
  return `el ${Number(d)} de ${mes}`
}

/** 'Ese día', 'Semana 3'. Es el rótulo del eje del gráfico. */
export function etiquetaPeriodo(k: number, grain: CohortGrain): string {
  if (k === 0) return mayuscula(UNIDAD[grain].ese)
  return `${mayuscula(UNIDAD[grain].uno)} ${k}`
}

export function mayuscula(texto: string): string {
  return texto.charAt(0).toUpperCase() + texto.slice(1)
}

// ── Las celdas ─────────────────────────────────────────────────────────────

/**
 * La columna k del renglón de totales, si existe.
 *
 * Indexar un array en TypeScript devuelve el tipo del elemento y no
 * `| undefined`, así que sin esto las guardas parecen sobrar —y no sobran:
 * pedir 1 periodo deja la columna 1 sin existir.
 */
export function totalEn(data: UserCohorts, k: number): CohortTotal | undefined {
  return data.totals.at(k)
}

/** El valor crudo de una celda, en la medida elegida. */
export function valor(row: CohortRow, k: number, medida: Medida): number | null {
  const cell = row.cells.find((c) => c.k === k)
  if (!cell || row.size === 0) return null

  return medida === 'gente' ? (cell.active / row.size) * 100 : cell.financedUsd / row.size
}

export function celda(row: CohortRow, k: number, medida: Medida, tope: number): CohortCell | null {
  const cell = row.cells.find((c) => c.k === k)
  if (!cell) return null

  const pct = row.size > 0 ? (cell.active / row.size) * 100 : 0
  const porPersona = row.size > 0 ? cell.financedUsd / row.size : 0
  const bruto = medida === 'gente' ? pct : porPersona

  return {
    intensity: tope > 0 ? bruto / tope : 0,
    text: medida === 'gente' ? `${formatPorcentaje(pct)}` : formatUsdShort(porPersona),
    title: `${cell.active} de ${row.size} se financiaron · ${formatPorcentaje(pct)} · ${cell.orders} financiamientos · ${formatUsd(cell.financedUsd)} financiado sin fee`,
    // Toda cohorte de la rejilla cabe dentro de la ventana pedida, así que la
    // última columna de cada fila es siempre el cubo en curso.
    partial: k === row.maxPeriod,
  }
}

/** '3 (25 %)': cuántas de la cohorte consumieron en la columna k. */
export function porcentaje(fila: CohortRow, k: number): string {
  const cell = fila.cells.find((c) => c.k === k)
  if (!cell || fila.size === 0) return '—'
  return `${cell.active} (${formatPorcentaje((cell.active / fila.size) * 100)})`
}
