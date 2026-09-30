import { formatUsd, formatNumero } from '@/components/ui'
import type { StatTrend } from '@/components/ui'

// ═══════════════════════════════════════════════════════════════════════════
// Cómo se escriben las cifras de Métricas: el cambio frente a la semana
// anterior, el desglose de una cuota y los porcentajes.
//
// Las mismas reglas que `features/admin/tendencia.ts` (por debajo del uno por
// ciento es «igual»; una tasa cambia en puntos, no en porcentaje), con dos
// cosas más que pide el tablero de semanas: un texto corto para una columna
// estrecha (▲ 12 %) y un tono que puede ser neutro, porque hay cifras que no
// son buenas ni malas por subir (lo que vencía, lo transferido).
//
// Puro: se prueba en `formato.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Si el cambio es buena noticia, mala, o ninguna de las dos. */
export type TonoDelta = 'bueno' | 'malo' | 'neutro'

export type Delta = {
  /** `nuevo`: antes era cero y ahora no, así que no hay porcentaje. */
  direccion: 'sube' | 'baja' | 'igual' | 'nuevo'
  /** Para leer, con el sentido escrito: «12 % más», «3,1 puntos menos», «igual». */
  texto: string
  /** Para una columna estrecha: «▲ 12 %», «▼ 3,1 pts», «=». */
  corto: string
  tono: TonoDelta
}

export type OpcionesDelta = {
  /**
   * `relativo`: el cambio en porcentaje (un importe, un número de personas).
   * `puntos`: la diferencia, para lo que ya es un porcentaje (la mora, el
   * cobro a tiempo): del 4 % al 6 % son dos puntos, no un 50 %.
   */
  tipo: 'relativo' | 'puntos'
  /** Si subir es la buena noticia. `null`: no es ni buena ni mala. */
  arribaEsBueno: boolean | null
}

function tonoDe(direccion: 'sube' | 'baja', arribaEsBueno: boolean | null): TonoDelta {
  if (arribaEsBueno === null) return 'neutro'
  return (direccion === 'sube') === arribaEsBueno ? 'bueno' : 'malo'
}

const IGUAL: Delta = { direccion: 'igual', texto: 'igual', corto: '=', tono: 'neutro' }

/**
 * El cambio de `actual` frente a `anterior`. `null` si falta uno de los dos
 * (no hay con qué comparar) o si los dos son cero en un cambio relativo: no
 * ha pasado nada que contar.
 *
 * La semana en curso se compara con la anterior A LA MISMA ALTURA (los mismos
 * días operativos); eso lo decide quien pasa `anterior`, no esta función.
 */
export function delta(
  actual: number | null,
  anterior: number | null,
  { tipo, arribaEsBueno }: OpcionesDelta,
): Delta | null {
  if (actual === null || anterior === null || !Number.isFinite(actual) || !Number.isFinite(anterior)) {
    return null
  }

  if (tipo === 'puntos') {
    const puntos = actual - anterior
    const escrito = formatNumero(Math.abs(puntos))
    if (escrito === formatNumero(0)) return IGUAL
    const direccion = puntos > 0 ? 'sube' : 'baja'
    const unidad = escrito === formatNumero(1) ? 'punto' : 'puntos'
    return {
      direccion,
      texto: `${escrito} ${unidad} ${direccion === 'sube' ? 'más' : 'menos'}`,
      corto: `${direccion === 'sube' ? '▲' : '▼'} ${escrito} pts`,
      tono: tonoDe(direccion, arribaEsBueno),
    }
  }

  if (anterior === 0) {
    if (actual === 0) return null
    return { direccion: 'nuevo', texto: 'nuevo', corto: 'nuevo', tono: 'neutro' }
  }

  const pct = ((actual - anterior) / Math.abs(anterior)) * 100
  if (Math.abs(pct) < 1) return IGUAL
  const direccion = pct > 0 ? 'sube' : 'baja'
  const escrito = formatNumero(Math.abs(pct), 0)
  return {
    direccion,
    texto: `${escrito} % ${direccion === 'sube' ? 'más' : 'menos'}`,
    corto: `${direccion === 'sube' ? '▲' : '▼'} ${escrito} %`,
    tono: tonoDe(direccion, arribaEsBueno),
  }
}

/**
 * El cambio como la pastilla `Tendencia` del kit (`Stat` la pinta al lado de
 * la cifra). Un cambio neutro lleva su flecha, pero en gris.
 */
export function comoTendencia(d: Delta): StatTrend {
  const direction = d.direccion === 'baja' ? 'down' : d.direccion === 'igual' ? 'flat' : 'up'
  const upIsGood =
    d.tono === 'neutro' ? null : d.tono === 'bueno' ? direction === 'up' : direction !== 'up'
  return { label: d.texto, direction, upIsGood }
}

/**
 * Qué parte de `total` es `parte`, de 0 a 100. `null` sin total: un 0 % sobre
 * nada no es un dato.
 */
export function porcentaje(parte: number, total: number): number | null {
  if (!Number.isFinite(parte) || !Number.isFinite(total) || total === 0) return null
  return (parte / total) * 100
}

/**
 * El desglose de lo que se paga en cuotas: «Consumo $146,72 + service fee
 * $34,04». Es la línea que acompaña SIEMPRE a una cifra `payable` (la regla
 * del fee): nunca se suma en una cifra suelta sin decir de qué está hecha.
 * El service fee va con su IVA dentro (`fee_usd` = payable − financed).
 */
export function textoDeDesglose({ financedUsd, feeUsd }: { financedUsd: number; feeUsd: number }): string {
  return `Financiamiento ${formatUsd(financedUsd)} + service fee ${formatUsd(feeUsd)}`
}

/**
 * El mismo desglose para un sitio estrecho (un pie, una celda, un eje):
 * «consumo $146,72 · fee $34,04». Las mismas dos partes, con las palabras
 * cortas que pide Javier para cuando «service fee» no cabe.
 */
export function textoDeDesgloseCorto({ financedUsd, feeUsd }: { financedUsd: number; feeUsd: number }): string {
  return `financiamiento ${formatUsd(financedUsd)} · fee ${formatUsd(feeUsd)}`
}
