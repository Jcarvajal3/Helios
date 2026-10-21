import { escalaBonita } from '@/components/charts/comun'
import { formatUsd } from '@/components/ui'

import { frenteALaAnterior } from './rendimiento'
import { diaCorto, semanaCorta } from './semanas'
import type { FilaLocal, LocalesDeLaSemana, SerieDeLocal } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// «Consumo por semana»: un gráfico pequeño por local, todos con LA MISMA
// escala, para que la altura de una barra se compare con la de otro local.
//
// Cada fila lleva sus ocho semanas (la elegida la última, en el tono del
// área), lo que lleva la elegida y una nota: si empezó a vender dentro de la
// ventana, cuándo; si no, cómo va frente a la anterior (a la misma altura, la
// misma comparación que la tabla).
//
// Puro: se prueba en `multiples.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Cuántas semanas enseña cada local. */
export const SEMANAS_DE_MULTIPLOS = 8

export type BarraDeMultiplo = {
  semana: string
  /** El consumo de esa semana, sin la Comisión Helios. */
  valor: number
  /** Consumos y personas de esa semana: van en el globo de la barra. */
  consumos: number
  personas: number
  /** Alto de 0 a 1 sobre el tope común. */
  fraccion: number
  /** La semana elegida: en el tono del área. */
  destacada: boolean
}

export type FilaDeMultiplo = {
  merchantId: string
  nombre: string
  barras: BarraDeMultiplo[]
  /** Lo de la semana elegida (a medias si está en curso). */
  ultimo: number
  /** «empezó el 28 ago», «▲ 20 % frente a la anterior», «sin ventas». */
  nota: string
}

export type Multiplos = {
  semanas: string[]
  /** «de 3–9 ago a 21–27 sep». */
  rango: string
  /** La escala común: el tope y sus marcas redondas. */
  escala: { tope: number; marcas: number[] }
  /** La barra más alta de todas, escrita: el dato que peor se estima a ojo. */
  cima: { nombre: string; semana: string; valor: number } | null
  filas: FilaDeMultiplo[]
}

function nota(serie: SerieDeLocal, fila: FilaLocal | undefined, semanas: ReadonlyArray<string>, mismaAltura: boolean): string {
  const primera = semanas.at(0)
  const empezo = serie.primerConsumo !== null && primera !== undefined && serie.primerConsumo >= primera
  if (empezo && serie.primerConsumo !== null) return `empezó el ${diaCorto(serie.primerConsumo)}`

  if (!fila) return ''
  const cambio = frenteALaAnterior(fila)
  if (cambio === null) return 'sin financiamientos'
  if (cambio.direccion === 'nuevo') return 'sin financiamientos la anterior'
  if (cambio.direccion === 'igual') return mismaAltura ? 'igual a estas alturas' : 'igual que la anterior'
  return `${cambio.corto} ${mismaAltura ? 'a estas alturas' : 'frente a la anterior'}`
}

/**
 * Los pequeños múltiplos de la semana. Salen los locales que consumieron algo
 * en las `n` semanas, en el orden de la tabla (de más a menos consumo en la
 * elegida).
 */
export function pequenosMultiplos(d: LocalesDeLaSemana, n = SEMANAS_DE_MULTIPLOS): Multiplos {
  const semanas = d.series.semanas.slice(-n)
  const recorte = (valores: ReadonlyArray<number>) => valores.slice(-semanas.length)
  const porLocal = new Map(d.locales.map((l) => [l.merchantId, l] as const))

  const conAlgo = d.series.locales.filter((s) => recorte(s.consumoUsd).some((v) => v > 0))
  const orden = new Map(d.locales.map((l, i) => [l.merchantId, i] as const))
  conAlgo.sort(
    (a, b) =>
      (orden.get(a.merchantId) ?? Number.MAX_SAFE_INTEGER) - (orden.get(b.merchantId) ?? Number.MAX_SAFE_INTEGER) ||
      a.nombre.localeCompare(b.nombre, 'es'),
  )

  let cima: Multiplos['cima'] = null
  for (const s of conAlgo) {
    const valores = recorte(s.consumoUsd)
    for (let i = 0; i < valores.length; i++) {
      const valor = valores[i] ?? 0
      if (!cima || valor > cima.valor) cima = { nombre: s.nombre, semana: semanas[i] ?? '', valor }
    }
  }

  const escala = escalaBonita(cima?.valor ?? 0)
  const ultima = semanas.length - 1

  return {
    semanas,
    rango: semanas.length > 0 ? `de ${semanaCorta(semanas[0] ?? '')} a ${semanaCorta(semanas[ultima] ?? '')}` : '',
    escala,
    cima,
    filas: conAlgo.map((s) => {
      const valores = recorte(s.consumoUsd)
      const consumos = recorte(s.consumos)
      const personas = recorte(s.personas)
      return {
        merchantId: s.merchantId,
        nombre: s.nombre,
        barras: valores.map((valor, i) => ({
          semana: semanas[i] ?? '',
          valor,
          consumos: consumos[i] ?? 0,
          personas: personas[i] ?? 0,
          fraccion: escala.tope > 0 ? valor / escala.tope : 0,
          destacada: i === ultima,
        })),
        ultimo: valores.at(-1) ?? 0,
        nota: nota(s, porLocal.get(s.merchantId), semanas, d.anterior.mismaAltura),
      }
    }),
  }
}

/** La cifra de la barra más alta, escrita: «$563,50 · Terraza, 21–27 sep». */
export function textoDeCima(cima: Multiplos['cima']): string | null {
  if (!cima || cima.valor <= 0) return null
  return `${formatUsd(cima.valor)} · ${cima.nombre}, ${semanaCorta(cima.semana)}`
}
