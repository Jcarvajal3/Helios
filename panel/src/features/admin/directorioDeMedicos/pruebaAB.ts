import { leerMoneda } from '@/components/ui'
import type { Moneda } from '@/components/ui'
import { sumarDias } from '@/components/kit/rango'
import { unoDe } from '@/lib/busqueda'
import { booleano, comoFila, comoLista, numero, numeroONulo, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Superadmin › Directorio de médicos › Prueba A/B (2026-11-09).
//
// A es `/directorio` (sin inicial, el botón va directo al médico); B es
// `/consultas` (inicial de $15 en el texto, el botón va al WhatsApp de Helios
// con el código del médico y la marca `-B`). Lo que decide la prueba es la
// tasa de clic: visitantes que tocaron un botón / visitantes. Solo cuenta el
// tráfico público; el del equipo y el de las clínicas va aparte.
//
// Módulo puro: lo usan la vista y las pruebas. Los datos salen de
// `admin_directorio_ab(p_desde, p_hasta)` (docs/06, docs/01 §2.15).
// ═══════════════════════════════════════════════════════════════════════════

export const VARIANTES = ['a', 'b'] as const
export type Variante = (typeof VARIANTES)[number]

/** La ruta pública de cada variante: la base la manda, esto es el respaldo. */
export const RUTA_DE_VARIANTE: Record<Variante, string> = { a: '/directorio', b: '/consultas' }

/** Las cifras de una variante en el rango. */
export type CifrasDeVariante = {
  variante: Variante
  ruta: string
  visitas: number
  /** Navegadores distintos que abrieron la página. */
  visitantes: number
  /** Toques a un botón de WhatsApp. */
  clics: number
  /** Visitantes con al menos un clic de esa variante. */
  visitantesConClic: number
  /** Los que escribieron al WhatsApp de Helios. En A no existen (el botón va al médico). */
  interesados: number
  /** De esos, los que ya tuvieron una orden con ese médico (regla de docs/04). */
  convertidos: number
}

export type CifrasDelDia = { visitantes: number; visitantesConClic: number; clics: number }

export type DiaDeLaPrueba = { dia: string; a: CifrasDelDia; b: CifrasDelDia }

export type MedicoDeLaPrueba = {
  merchantId: string
  medico: string
  /** El precio de la consulta en su moneda, o `null` si no tiene. */
  precio: number | null
  moneda: Moneda
  /** Si hoy sale en `/consultas` (consulta de más de $15 y hasta $60). */
  enB: boolean
  clicsA: number
  clicsB: number
  interesadosB: number
  convertidosB: number
}

export type PruebaAB = {
  desde: string
  hasta: string
  a: CifrasDeVariante
  b: CifrasDeVariante
  /** Todos los días del rango, el más viejo primero. */
  dias: DiaDeLaPrueba[]
  /** El de más clics primero, como lo manda la base. */
  medicos: MedicoDeLaPrueba[]
  /** Lo del equipo y las clínicas: no entra en ninguna cifra de arriba. */
  excluidos: { visitasEquipo: number; clicsEquipo: number }
  /** El día de la primera visita apuntada: antes no se contaban visitas. */
  visitasDesde: string | null
}

function cifrasVacias(variante: Variante): CifrasDeVariante {
  return {
    variante,
    ruta: RUTA_DE_VARIANTE[variante],
    visitas: 0,
    visitantes: 0,
    clics: 0,
    visitantesConClic: 0,
    interesados: 0,
    convertidos: 0,
  }
}

function leerCifras(variante: Variante, raw: Record<string, unknown> | undefined): CifrasDeVariante {
  if (!raw) return cifrasVacias(variante)
  return {
    variante,
    ruta: textoONulo(raw.ruta) ?? RUTA_DE_VARIANTE[variante],
    visitas: numero(raw.visitas),
    visitantes: numero(raw.visitantes),
    clics: numero(raw.clics),
    visitantesConClic: numero(raw.visitantes_con_clic),
    interesados: numero(raw.interesados),
    convertidos: numero(raw.convertidos),
  }
}

function leerDelDia(raw: unknown): CifrasDelDia {
  const r = comoFila(raw)
  return { visitantes: numero(r.visitantes), visitantesConClic: numero(r.visitantes_con_clic), clics: numero(r.clics) }
}

/**
 * `admin_directorio_ab()`. Tolera lo raro: una variante que falta llega a
 * cero, una que se repite cuenta la primera, un día sin fecha se descarta y
 * los días se ordenan del más viejo al más nuevo.
 */
export function leerPruebaAB(raw: unknown): PruebaAB {
  const r = comoFila(raw)
  const variantes = comoLista(r.variantes).map(comoFila)
  const deLa = (v: Variante) => variantes.find((x) => unoDe(VARIANTES, x.variante) === v)
  const excluidos = comoFila(r.excluidos)
  return {
    desde: texto(r.desde),
    hasta: texto(r.hasta),
    a: leerCifras('a', deLa('a')),
    b: leerCifras('b', deLa('b')),
    dias: comoLista(r.dias)
      .map((d) => {
        const f = comoFila(d)
        return { dia: texto(f.dia), a: leerDelDia(f.a), b: leerDelDia(f.b) }
      })
      .filter((d) => /^\d{4}-\d{2}-\d{2}/.test(d.dia))
      .sort((x, y) => (x.dia < y.dia ? -1 : x.dia > y.dia ? 1 : 0)),
    medicos: comoLista(r.medicos)
      .map((fila) => {
        const m = comoFila(fila)
        return {
          merchantId: texto(m.merchant_id),
          medico: texto(m.medico, 'Sin nombre'),
          precio: numeroONulo(m.precio_cur),
          moneda: leerMoneda(m.moneda),
          enB: booleano(m.en_b),
          clicsA: numero(m.clics_a),
          clicsB: numero(m.clics_b),
          interesadosB: numero(m.interesados_b),
          convertidosB: numero(m.convertidos_b),
        }
      })
      .filter((m) => m.merchantId !== ''),
    excluidos: { visitasEquipo: numero(excluidos.visitas_equipo), clicsEquipo: numero(excluidos.clics_equipo) },
    visitasDesde: textoONulo(r.visitas_desde),
  }
}

// ── El rango ───────────────────────────────────────────────────────────────

export const RANGOS_DE_LA_PRUEBA = [7, 14, 30, 90] as const
export type RangoDeLaPrueba = (typeof RANGOS_DE_LA_PRUEBA)[number]
export const RANGO_POR_DEFECTO: RangoDeLaPrueba = 30

/** `?dias=` de la dirección: 7, 14, 30 o 90 (número o texto); lo demás, nada. */
export function leerRangoDeLaPrueba(v: unknown): RangoDeLaPrueba | undefined {
  const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v
  return RANGOS_DE_LA_PRUEBA.find((r) => r === n)
}

/** Los últimos `dias` días de Caracas, hoy incluido. */
export function rangoDeLaPrueba(dias: RangoDeLaPrueba, hoy: string): { desde: string; hasta: string } {
  return { desde: sumarDias(hoy, -(dias - 1)), hasta: hoy }
}

// ── La tasa y el veredicto ─────────────────────────────────────────────────

/**
 * Visitantes que tocaron / visitantes, entre 0 y 1; `null` sin visitantes.
 * Un clic de quien no tiene visita apuntada (antes de que se contaran, o con
 * la visita bloqueada) no sube la tasa por encima del 100 %.
 */
export function tasaDeClic(c: { visitantes: number; visitantesConClic: number }): number | null {
  if (!(c.visitantes > 0)) return null
  return Math.min(Math.max(c.visitantesConClic, 0), c.visitantes) / c.visitantes
}

/** Por debajo de esto, en cualquiera de las dos, no se da veredicto. */
export const MINIMO_DE_VISITANTES = 100

/** La confianza que hace falta para dar una ganadora. */
export const CONFIANZA_NECESARIA = 0.95

export type VeredictoAB = {
  /**
   * `pocos_datos`: alguna variante no llega a `MINIMO_DE_VISITANTES`.
   * `sin_diferencia`: hay datos, pero la confianza no llega al 95 %.
   * `gana`: una tasa es mayor que la otra con al menos 95 % de confianza.
   */
  estado: 'pocos_datos' | 'sin_diferencia' | 'gana'
  /** Solo con `gana`. */
  ganadora: Variante | null
  /** La de mayor tasa, gane o no; `null` si empatan o no hay tasas. */
  delante: Variante | null
  tasaA: number | null
  tasaB: number | null
  /**
   * Cuánto más clica la de delante, relativo a la otra: 0,25 = un 25 % más.
   * `null` si no hay quien vaya delante o la otra está en 0 %.
   */
  diferencia: number | null
  /** 1 − p (bilateral), entre 0 y 1; `null` sin visitantes en alguna. */
  confianza: number | null
  z: number | null
}

/**
 * La función de error, Abramowitz y Stegun 7.1.26 (error < 1,5·10⁻⁷): sobra
 * para decir «96 %».
 */
function erf(x: number): number {
  const signo = x < 0 ? -1 : 1
  const t = 1 / (1 + 0.3275911 * Math.abs(x))
  const y =
    1 - ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-x * x)
  return signo * y
}

/**
 * Prueba z de dos proporciones (con la proporción común) sobre la tasa de
 * clic de A y de B. La confianza es 1 − p bilateral: la probabilidad de que
 * la diferencia no sea casualidad. Con menos de `MINIMO_DE_VISITANTES` en
 * alguna variante, o con menos de 95 % de confianza, no hay ganadora.
 */
export function veredictoAB(
  a: { visitantes: number; visitantesConClic: number },
  b: { visitantes: number; visitantesConClic: number },
): VeredictoAB {
  const tasaA = tasaDeClic(a)
  const tasaB = tasaDeClic(b)
  const pocos = !(a.visitantes >= MINIMO_DE_VISITANTES && b.visitantes >= MINIMO_DE_VISITANTES)

  if (tasaA === null || tasaB === null) {
    return { estado: 'pocos_datos', ganadora: null, delante: null, tasaA, tasaB, diferencia: null, confianza: null, z: null }
  }

  const nA = a.visitantes
  const nB = b.visitantes
  const xA = tasaA * nA
  const xB = tasaB * nB
  const comun = (xA + xB) / (nA + nB)
  const error = Math.sqrt(comun * (1 - comun) * (1 / nA + 1 / nB))
  // Las dos al 0 % o las dos al 100 %: no hay nada que distinga una de otra.
  const z = error > 0 ? (tasaB - tasaA) / error : 0
  const confianza = erf(Math.abs(z) / Math.SQRT2)

  const delante: Variante | null = tasaA === tasaB ? null : tasaB > tasaA ? 'b' : 'a'
  const otra = delante === 'a' ? tasaB : tasaA
  const diferencia = delante === null || otra === 0 ? null : (Math.max(tasaA, tasaB) - otra) / otra

  const estado = pocos ? 'pocos_datos' : delante !== null && confianza >= CONFIANZA_NECESARIA ? 'gana' : 'sin_diferencia'
  return {
    estado,
    ganadora: estado === 'gana' ? delante : null,
    delante,
    tasaA,
    tasaB,
    diferencia,
    confianza,
    z,
  }
}

// ── Las sumas de la tabla por médico ───────────────────────────────────────

/** Cuántos médicos salen hoy en B y cuántos clics de cada variante hay en la tabla. */
export function resumenDeMedicos(medicos: readonly MedicoDeLaPrueba[]): {
  enB: number
  clicsA: number
  clicsB: number
} {
  return {
    enB: medicos.filter((m) => m.enB).length,
    clicsA: medicos.reduce((s, m) => s + m.clicsA, 0),
    clicsB: medicos.reduce((s, m) => s + m.clicsB, 0),
  }
}
