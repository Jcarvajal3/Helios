import { MESES_LARGOS, describirRango, diasDelRango, sumarDias } from '@/components/ui'
import type { BadgeTone } from '@/components/ui'
import type { DayPoint } from '@/features/admin/metrics'
import type { SemanaResumen } from '@/features/admin/resumen'

// ═══════════════════════════════════════════════════════════════════════════
// La aritmética de calendario del Resumen, sin React ni Supabase.
//
// Qué semana se mira, cuántas hay que pedir, contra qué se compara cada cifra
// y qué dice el semáforo de capital. Todo lo que aquí se calcula son
// comparaciones y proporciones de cifras que ya da la base; ninguna cifra de
// negocio nace aquí.
//
// Los días van como texto 'YYYY-MM-DD' y se suman con `Date.UTC`: con
// `new Date('2026-09-21')` en Caracas el lunes sale domingo.
// ═══════════════════════════════════════════════════════════════════════════

/** Las semanas del gráfico: la elegida y las once anteriores. */
export const VENTANA_SEMANAS = 12

/** Lo más que devuelve `admin_weekly_summary`. */
export const TOPE_SEMANAS = 52

/** Lo más atrás que se puede ir sin que la ventana de doce quede cortada. */
export const SEMANAS_ATRAS_MAX = TOPE_SEMANAS - VENTANA_SEMANAS

/**
 * Se piden semanas de trece en trece. Así, ir una o dos semanas atrás no
 * vuelve a consultar: la respuesta de trece ya las trae.
 */
const TRAMO_DE_PEDIDO = 13

/** Un consumo se paga en dos cuotas: un ciclo de cobro son dos intervalos. */
const CUOTAS_POR_CONSUMO = 2

// ── Calendario ─────────────────────────────────────────────────────────────

const DIAS_DE_LA_SEMANA = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado']

function numeroDeDia(dia: string): number {
  const [y = 0, m = 1, d = 1] = dia.slice(0, 10).split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay()
}

/** El lunes de la semana a la que pertenece `dia`. */
export function lunesDe(dia: string): string {
  return sumarDias(dia, -((numeroDeDia(dia) + 6) % 7))
}

/** El domingo que cierra la semana que empieza en `lunes`. */
export function domingoDe(lunes: string): string {
  return sumarDias(lunes, 6)
}

/** 'jueves'. */
export function diaDeLaSemana(dia: string): string {
  return DIAS_DE_LA_SEMANA[numeroDeDia(dia)] ?? ''
}

/** 'jueves 24 de septiembre'. */
export function diaConNombre(dia: string): string {
  const [, m = '', d = ''] = dia.slice(0, 10).split('-')
  return `${diaDeLaSemana(dia)} ${Number(d)} de ${MESES_LARGOS[Number(m) - 1] ?? m}`
}

/** Semanas enteras de un lunes a otro; negativo si `hasta` es anterior. */
export function semanasEntre(desde: string, hasta: string): number {
  return Math.round((diasDelRango({ from: desde, to: hasta }) - 1) / 7)
}

/** 'del 21 al 27 de septiembre de 2026'. */
export function describirSemana(lunes: string): string {
  return describirRango({ from: lunes, to: domingoDe(lunes) })
}

// ── Qué se pide y qué se enseña ────────────────────────────────────────────

/**
 * Cuántas semanas pedirle a `admin_weekly_summary` para que la respuesta
 * traiga la elegida y sus once anteriores.
 *
 * `lunesHoy` es el lunes del calendario de Caracas, no el del día operativo:
 * el lunes antes de las 10:00 va una semana por delante del servidor, y eso
 * solo hace que se pida una semana de más.
 */
export function semanasAPedir(lunesElegido: string | undefined, lunesHoy: string): number {
  const atras = lunesElegido ? Math.max(0, semanasEntre(lunesElegido, lunesHoy)) : 0
  const tramos = Math.ceil((atras + VENTANA_SEMANAS) / TRAMO_DE_PEDIDO)
  return Math.min(TOPE_SEMANAS, tramos * TRAMO_DE_PEDIDO)
}

/** Qué semana se enseña, o por qué no se puede. */
export type Eleccion =
  | { tipo: 'semana'; indice: number; semana: SemanaResumen; enCurso: boolean }
  /** Todavía no ha empezado. */
  | { tipo: 'futura' }
  /** Es más vieja que lo que se puede pedir. */
  | { tipo: 'fuera' }
  /** El servidor no devolvió ninguna semana. */
  | { tipo: 'vacia' }

/** La semana de `lunes` dentro de la respuesta; sin `lunes`, la en curso. */
export function elegirSemana(rows: readonly SemanaResumen[], lunes?: string): Eleccion {
  const ultima = rows.at(-1)
  if (!ultima) return { tipo: 'vacia' }

  const indice = lunes ? rows.findIndex((r) => r.weekStart === lunes) : rows.length - 1
  const semana = rows.at(indice)
  if (indice >= 0 && semana) return { tipo: 'semana', indice, semana, enCurso: !semana.complete }

  return lunes && lunes > ultima.weekStart ? { tipo: 'futura' } : { tipo: 'fuera' }
}

/** Las `n` semanas que acaban en `indice`, la elegida la última. */
export function ventanaHasta<T>(rows: readonly T[], indice: number, n = VENTANA_SEMANAS): T[] {
  return rows.slice(Math.max(0, indice - n + 1), indice + 1)
}

// ── Contra qué se compara ──────────────────────────────────────────────────

/**
 * Las cifras de una semana que se pueden sumar día a día. Las personas y los
 * locales no: quien consume el viernes y el sábado es una persona, no dos.
 */
const SUMABLES = [
  'financedUsd',
  'serviceFeeUsd',
  'lateFeeUsd',
  'chargeCount',
  'newUsers',
  'firstTimeBuyers',
] as const

export type CampoSumable = (typeof SUMABLES)[number]

export type CampoComparable = CampoSumable | 'activeUsers' | 'merchantsWithSales'

function esSumable(campo: CampoComparable): campo is CampoSumable {
  return SUMABLES.some((s) => s === campo)
}

/**
 * Lo que llevaba la semana anterior a la misma altura: la suma de sus
 * primeros `dias` días. `null` si la serie diaria no los trae todos.
 */
export function aEstasAlturas(
  serie: readonly DayPoint[],
  lunes: string,
  dias: number,
  campo: CampoSumable,
): number | null {
  const desde = sumarDias(lunes, -7)
  const hasta = sumarDias(desde, dias - 1)
  const tramo = serie.filter((d) => d.businessDate >= desde && d.businessDate <= hasta)
  if (tramo.length !== dias) return null
  return tramo.reduce((s, d) => s + d[campo], 0)
}

/** Contra qué se compara una cifra de la semana, y cómo se dice. */
export type Referencia = { valor: number; cual: 'semana-anterior' | 'mismos-dias' }

/**
 * El valor de la semana anterior con el que se compara `campo`.
 *
 * Una semana cerrada se compara con la anterior entera. La semana en curso no:
 * un jueves con cuatro días no se mide contra una semana de siete, sino contra
 * los mismos cuatro días de la anterior, y eso solo se puede con lo que se
 * suma día a día. Las personas y los locales de una semana en curso no tienen
 * comparación hasta que cierre.
 */
export function referenciaDe(
  rows: readonly SemanaResumen[],
  indice: number,
  campo: CampoComparable,
  serie: readonly DayPoint[] | undefined,
): Referencia | null {
  const actual = rows.at(indice)
  const previa = indice > 0 ? rows.at(indice - 1) : undefined
  if (!actual || !previa) return null

  if (actual.complete) return { valor: previa[campo], cual: 'semana-anterior' }
  if (!esSumable(campo) || !serie) return null

  const valor = aEstasAlturas(serie, actual.weekStart, actual.daysElapsed, campo)
  return valor === null ? null : { valor, cual: 'mismos-dias' }
}

/** El ritmo de las últimas `n` semanas cerradas: lo financiado de media. */
export function ritmoSemanal(
  rows: readonly SemanaResumen[],
  n = 4,
): { media: number; semanas: number } | null {
  const cerradas = rows.filter((r) => r.complete).slice(-n)
  if (cerradas.length === 0) return null
  const total = cerradas.reduce((s, r) => s + r.financedUsd, 0)
  return { media: total / cerradas.length, semanas: cerradas.length }
}

/**
 * Ayer y el mismo día de la semana pasada, de una serie diaria que acaba hoy.
 *
 * El negocio es de fin de semana: un jueves solo se compara con otro jueves.
 * Hoy va a medias, así que «ayer» es el penúltimo. Se comprueba que haya siete
 * días justos entre los dos; si faltara uno, se compararía un jueves con un
 * miércoles sin avisar.
 */
export function ayerFrenteASemanaPasada(
  serie: readonly DayPoint[],
): { ayer: DayPoint; hace: DayPoint } | null {
  if (serie.length < 9) return null
  const ayer = serie.at(-2)
  const hace = serie.at(-9)
  if (!ayer || !hace || sumarDias(hace.businessDate, 7) !== ayer.businessDate) return null
  return { ayer, hace }
}

// ── Metas ──────────────────────────────────────────────────────────────────

/** Si la meta es llegar a algo (financiado) o no pasar de algo (mora). */
export type Sentido = 'subir' | 'bajar'

export type Progreso = {
  /** Cuánto de la meta: 100 es justo la meta. `null` si no se puede decir. */
  pct: number | null
  cumplida: boolean
  /** Lo que falta para llegar, o lo que sobra por encima del techo. */
  distancia: number
}

export function progresoDeMeta(
  valor: number | null,
  meta: number | null,
  sentido: Sentido,
): Progreso | null {
  if (valor === null || meta === null) return null

  if (sentido === 'subir') {
    return {
      pct: meta > 0 ? (valor / meta) * 100 : null,
      cumplida: valor >= meta,
      distancia: Math.max(0, meta - valor),
    }
  }

  return {
    pct: meta > 0 ? (valor / meta) * 100 : null,
    cumplida: valor <= meta,
    distancia: Math.max(0, valor - meta),
  }
}

// ── Semáforo de capital ────────────────────────────────────────────────────

/** Las semanas de un ciclo de cobro: las dos cuotas. `null` sin el intervalo. */
export function semanasDeUnCiclo(intervaloDias: number | null): number | null {
  if (intervaloDias === null || intervaloDias <= 0) return null
  return (intervaloDias * CUOTAS_POR_CONSUMO) / 7
}

export type Capital = {
  capital: number
  /** El consumo que la gente todavía no ha devuelto, sin el fee. */
  comprometido: number
  /** `null` con un capital de cero. */
  usadoPct: number | null
  queda: number
  /** Semanas de consumo que caben en lo que queda. `null` sin ritmo. */
  semanas: number | null
  tono: BadgeTone
}

/**
 * Cuánto del capital está comprometido y cuántas semanas quedan.
 *
 * Lo comprometido es el consumo sin saldar, y nada más. La parte de cada
 * consumo que le toca al local es fija: esté ya transferida o por transferir,
 * lo que la persona devuelve la va reduciendo. Sumarle «lo que se debe a los
 * locales» contaba dos veces el mismo dinero (Javier, 2026-09-25). Si hay caja
 * para lo que sale el lunes lo dice otro semáforo, el del cierre.
 *
 * Las semanas suponen que no vuelve nada: lo que queda dividido entre lo que
 * se financia de media en una semana. Es el peor caso a propósito.
 *
 * El color no usa un porcentaje inventado, sino el ciclo de cobro: si lo que
 * queda no alcanza para un ciclo entero (las dos cuotas), el dinero de los
 * consumos nuevos no habrá vuelto cuando se acabe, y es rojo. Menos de dos
 * ciclos es ámbar. Sin el intervalo de cuotas no hay color.
 */
export function semaforoDeCapital({
  capital,
  consumoSinSaldar,
  ritmo,
  semanasDeCiclo,
}: {
  capital: number
  consumoSinSaldar: number
  ritmo: number | null
  semanasDeCiclo: number | null
}): Capital {
  const comprometido = consumoSinSaldar
  const queda = capital - comprometido
  const usadoPct = capital > 0 ? (comprometido / capital) * 100 : null
  const semanas = queda <= 0 ? 0 : ritmo !== null && ritmo > 0 ? queda / ritmo : null

  let tono: BadgeTone
  if (queda <= 0) tono = comprometido > 0 || capital > 0 ? 'error' : 'neutral'
  else if (semanas === null) tono = 'success'
  else if (semanasDeCiclo === null) tono = 'neutral'
  else if (semanas < semanasDeCiclo) tono = 'error'
  else if (semanas < semanasDeCiclo * 2) tono = 'warning'
  else tono = 'success'

  return { capital, comprometido, usadoPct, queda, semanas, tono }
}
