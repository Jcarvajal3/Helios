import type { CortesDeTramo, Tramo, TramoVencido } from '@/features/admin/tramos'
import { TRAMOS_VENCIDOS, rotuloDeTramo, tramoDe } from '@/features/admin/tramos'
import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// El paso entre tramos: de un lunes al siguiente, adónde se movió la gente.
//
// La mora por tramo dice cuánta gente hay en cada escalón hoy; esto dice si
// esa gente sube, baja o se queda. Una mora estable puede esconder que la
// mitad se pone al día y otra mitad entra nueva: el flujo lo enseña.
//
// Los datos son de `admin_collection_flow`, que desde 20260927551000 lee el
// tramo de cada persona de `metricas.cobranza_tramos_al` (el mismo de la mora
// por tramo) y se parte por local y por semana. Aquí solo se leen y se
// ordenan en una matriz; no se recalcula nada.
// ═══════════════════════════════════════════════════════════════════════════

/** De dónde viene alguien: un tramo, o `nuevo` si no tenía cuotas el lunes anterior. */
export type OrigenDelPaso = Tramo | 'nuevo'

/** Todos los tramos, del mejor al peor. El orden decide qué es mejorar. */
export const TRAMOS: readonly Tramo[] = ['al_dia', ...TRAMOS_VENCIDOS]

export type Paso = { desde: OrigenDelPaso; hacia: Tramo; personas: number }

export type Cura = {
  /** Estaban en el tramo el lunes anterior. */
  estaban: number
  /** De esos, están al día este lunes. */
  curados: number
  /** `null` si no había nadie: no es un 0 %. */
  pct: number | null
}

export type SemanaDeFlujo = {
  /**
   * El día que hace de «hoy» en el corte: un lunes (el cierre del domingo) o,
   * si el corte es ahora, hoy. 'YYYY-MM-DD'.
   */
  corte: string
  /** El del corte anterior: el paso va de `desde` a `corte`. `null` si la base no lo manda. */
  desde: string | null
  /** El corte es ahora mismo: la semana todavía no ha cerrado. */
  enCurso: boolean
  personas: number
  porTramo: Record<Tramo, number>
  /** Deuda vencida y sin pagar en el corte (payable). */
  deudaVencida: Record<TramoVencido, number>
  /** Su desglose: el consumo y el service fee (con su IVA), por tramo. */
  deudaFinanciada: Record<TramoVencido, number>
  deudaServicio: Record<TramoVencido, number>
  pasos: Paso[]
  cura: Record<TramoVencido, Cura>
}

export type FlujoEntreTramos = {
  businessDate: string
  /** Los cortes con los que la base clasificó todas las semanas. */
  cortes: CortesDeTramo
  /** Del lunes más viejo al más nuevo. */
  semanas: SemanaDeFlujo[]
}

function esTramo(v: unknown): v is Tramo {
  return TRAMOS.some((t) => t === v)
}

function esOrigen(v: unknown): v is OrigenDelPaso {
  return v === 'nuevo' || esTramo(v)
}

function porTramoVencido<T>(raw: unknown, leer: (v: unknown) => T): Record<TramoVencido, T> {
  const f = comoFila(raw)
  return { t1: leer(f.t1), t2: leer(f.t2), t3: leer(f.t3), t4: leer(f.t4), t5: leer(f.t5) }
}

function porTramo<T>(raw: unknown, leer: (v: unknown) => T): Record<Tramo, T> {
  return { al_dia: leer(comoFila(raw).al_dia), ...porTramoVencido(raw, leer) }
}

function leerCura(raw: unknown): Cura {
  const f = comoFila(raw)
  return {
    estaban: Number(f.from_people ?? 0),
    curados: Number(f.cured ?? 0),
    pct: numeroONulo(f.pct),
  }
}

function leerSemana(raw: unknown): SemanaDeFlujo {
  const f = comoFila(raw)
  const cantidad = (v: unknown) => Number(v ?? 0)

  const pasos: Paso[] = []
  for (const p of comoLista(f.transitions)) {
    const fila = comoFila(p)
    if (esOrigen(fila.from) && esTramo(fila.to)) {
      pasos.push({ desde: fila.from, hacia: fila.to, personas: Number(fila.people ?? 0) })
    }
  }

  return {
    corte: String(f.cut_date),
    desde: textoONulo(f.from_date),
    enCurso: f.en_curso === true,
    personas: Number(f.people_total ?? 0),
    porTramo: porTramo(f.people, cantidad),
    deudaVencida: porTramoVencido(f.overdue_usd, cantidad),
    deudaFinanciada: porTramoVencido(f.overdue_financed_usd, cantidad),
    deudaServicio: porTramoVencido(f.overdue_fee_usd, cantidad),
    pasos,
    cura: porTramoVencido(f.cure, leerCura),
  }
}

/** La respuesta de `admin_collection_flow`, ya tipada. */
export function leerFlujo(raw: unknown): FlujoEntreTramos {
  const f = comoFila(raw)
  const t = comoFila(f.tramos)
  return {
    businessDate: textoONulo(f.business_date) ?? '',
    cortes: {
      gracia: Number(t.grace_days),
      intervalo: Number(t.interval_days),
      baja: Number(t.demotion_days),
      expulsion: Number(t.expulsion_days),
    },
    semanas: comoLista(f.weeks).map(leerSemana),
  }
}

// ── La matriz ──────────────────────────────────────────────────────────────

/** «Al día», «1–3 días», «Nuevos». */
export function rotuloDeOrigen(o: OrigenDelPaso, c: CortesDeTramo): string {
  if (o === 'nuevo') return 'Nuevos'
  if (o === 'al_dia') return 'Al día'
  return rotuloDeTramo(o, c)
}

/** Hacia dónde fue un paso, que es lo que decide su color. */
export type SentidoDelPaso = 'entra' | 'mejora' | 'igual' | 'empeora'

export function sentidoDelPaso(desde: OrigenDelPaso, hacia: Tramo): SentidoDelPaso {
  if (desde === 'nuevo') return 'entra'
  const a = TRAMOS.indexOf(desde)
  const b = TRAMOS.indexOf(hacia)
  if (b < a) return 'mejora'
  if (b > a) return 'empeora'
  return 'igual'
}

export type FilaDeFlujo = {
  desde: OrigenDelPaso
  /** Personas que fueron a cada tramo. Un tramo sin nadie es un 0 de verdad. */
  hacia: Record<Tramo, number>
  total: number
}

/** Los orígenes en el orden en que se leen: del mejor tramo al peor, y los nuevos al final. */
const ORIGENES: readonly OrigenDelPaso[] = [...TRAMOS, 'nuevo']

/**
 * Los pasos de una semana como filas: de dónde venían (fila) y adónde fueron
 * (columna). Solo salen los orígenes con alguien dentro; la base no manda los
 * pasos en cero, así que una celda que falta vale cero.
 */
export function matrizDeFlujo(semana: SemanaDeFlujo): FilaDeFlujo[] {
  return ORIGENES.map((desde) => {
    const hacia: Record<Tramo, number> = { al_dia: 0, t1: 0, t2: 0, t3: 0, t4: 0, t5: 0 }
    for (const p of semana.pasos) if (p.desde === desde) hacia[p.hacia] += p.personas
    const total = TRAMOS.reduce((s, t) => s + hacia[t], 0)
    return { desde, hacia, total }
  }).filter((f) => f.total > 0)
}

/** Cuántas personas mejoraron, empeoraron o se curaron del todo en la semana. */
export function resumenDelFlujo(semana: SemanaDeFlujo): {
  mejoran: number
  empeoran: number
  curados: number
  estabanVencidos: number
} {
  let mejoran = 0
  let empeoran = 0
  for (const p of semana.pasos) {
    const sentido = sentidoDelPaso(p.desde, p.hacia)
    if (sentido === 'mejora') mejoran += p.personas
    if (sentido === 'empeora') empeoran += p.personas
  }
  const curados = TRAMOS_VENCIDOS.reduce((s, t) => s + semana.cura[t].curados, 0)
  const estabanVencidos = TRAMOS_VENCIDOS.reduce((s, t) => s + semana.cura[t].estaban, 0)
  return { mejoran, empeoran, curados, estabanVencidos }
}

// ── La mora de hoy, por tramo ──────────────────────────────────────────────

export type DeudaDelTramo = { personas: number; vencido: number }

/**
 * La deuda vencida de hoy repartida por tramos, persona a persona.
 *
 * Cada persona cae entera en el tramo de su cuota más atrasada, que es el
 * mismo criterio del flujo y de la lista de cobranza: a quien debe una cuota
 * de hace cinco días y otra de hace cuarenta se la llama por la de cuarenta.
 * Quien no tiene nada vencido no cuenta.
 */
export function deudaPorTramo(
  personas: ReadonlyArray<{ diasDeAtraso: number; vencido: number }>,
  cortes: CortesDeTramo,
): Record<TramoVencido, DeudaDelTramo> {
  const salida: Record<TramoVencido, DeudaDelTramo> = {
    t1: { personas: 0, vencido: 0 },
    t2: { personas: 0, vencido: 0 },
    t3: { personas: 0, vencido: 0 },
    t4: { personas: 0, vencido: 0 },
    t5: { personas: 0, vencido: 0 },
  }
  for (const p of personas) {
    const tramo = tramoDe(p.diasDeAtraso, cortes)
    if (tramo === 'al_dia' || p.vencido <= 0) continue
    salida[tramo].personas += 1
    salida[tramo].vencido += p.vencido
  }
  return salida
}
