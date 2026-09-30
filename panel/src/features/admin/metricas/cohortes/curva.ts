import type { CurvaDeCuota, PuntoDeCurva } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// La geometría de la curva de cobro de una cuota: el eje de días (de seis
// días antes de vencer a catorce después), el de porcentaje (de 0 a 100) y
// qué se escribe encima.
//
// La x va en % del ancho y la y en % del alto contada desde la base, como el
// lienzo de 100 × 100 de los gráficos del panel (`charts/geometria`).
//
// Puro: se prueba en `curva.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Las marcas del eje de porcentaje: redondas, de 25 en 25. */
export const MARCAS_PCT = [0, 25, 50, 75, 100] as const

/** El primer y el último día de la curva, como los pide la base. */
export type Tramo = { desde: number; hasta: number }

/** El tramo de días de una curva; si viene vacía, el de siempre (−6 … +14). */
export function tramoDe(curva: CurvaDeCuota): Tramo {
  const dias = curva.puntos.map((p) => p.dia)
  if (dias.length === 0) return { desde: -6, hasta: 14 }
  return { desde: Math.min(...dias), hasta: Math.max(...dias) }
}

/** La x de un día, en % del ancho. */
export function xDeDia(dia: number, t: Tramo): number {
  const ancho = t.hasta - t.desde
  return ancho <= 0 ? 50 : ((dia - t.desde) / ancho) * 100
}

/** La y de un porcentaje, en % del alto desde la base, sin salirse del lienzo. */
export function yDePct(p: number): number {
  return Math.min(100, Math.max(0, p))
}

/**
 * Las marcas del eje de días: el primero, el día en que vence, una semana
 * después y el último. Las que caen fuera del tramo no salen.
 */
export function marcasDeDias(t: Tramo): number[] {
  return [t.desde, 0, 7, t.hasta].filter((d, i, todas) => d >= t.desde && d <= t.hasta && todas.indexOf(d) === i)
}

type Serie = 'esta' | 'media'

function valor(p: PuntoDeCurva, serie: Serie): number | null {
  return serie === 'esta' ? p.estaPct : p.mediaPct
}

/**
 * El `d` de un `<path>` en un lienzo de 100 × 100 con la y hacia abajo,
 * cortado donde falta un dato: un día sin cerrar no es un día a cero.
 */
export function trazoDeCurva(curva: CurvaDeCuota, serie: Serie): string {
  const t = tramoDe(curva)
  const partes: string[] = []
  let abierto = false
  for (const p of curva.puntos) {
    const v = valor(p, serie)
    if (v === null) {
      abierto = false
      continue
    }
    const x = redondo(xDeDia(p.dia, t))
    const y = redondo(100 - yDePct(v))
    partes.push(`${abierto ? 'L' : 'M'}${x} ${y}`)
    abierto = true
  }
  return partes.join(' ')
}

function redondo(n: number): string {
  return String(Math.round(n * 100) / 100)
}

/** El último punto con dato de una serie: donde se escribe su cifra. */
export function ultimoDe(curva: CurvaDeCuota, serie: Serie): { dia: number; pct: number } | null {
  for (let i = curva.puntos.length - 1; i >= 0; i--) {
    const p = curva.puntos[i]
    const v = valor(p, serie)
    if (v !== null) return { dia: p.dia, pct: v }
  }
  return null
}

/** La curva no tiene nada que dibujar: ni esta semana ni la media tienen un día cerrado. */
export function curvaVacia(curva: CurvaDeCuota): boolean {
  return curva.puntos.every((p) => p.estaPct === null && p.mediaPct === null)
}
