import { describirRango, sumarDias } from '@/components/ui'
import type { Rango } from '@/components/ui'
import { domingoDe } from '@/features/admin/semana'

// ═══════════════════════════════════════════════════════════════════════════
// La ventana de Métricas › Gente: cuántas semanas se miran, acabando en la
// semana elegida arriba.
//
// Resumen, Uso y Grupos cuentan lo que pasó en un tramo de días. En vez de un
// rango de fechas propio, el tramo acaba el domingo de la semana global (o
// hoy, si está en curso) y dura una semana, cuatro, doce o todo lo que lleva
// Ronda. Así «esta semana» dice lo mismo aquí que en la pestaña Semana.
//
// Puro: se prueba en `ventana.test.ts`. Los días van como 'YYYY-MM-DD' y se
// suman con `sumarDias` (`Date.UTC` por dentro).
// ═══════════════════════════════════════════════════════════════════════════

export const VENTANAS_GENTE = ['semana', '4', '12', 'inicio'] as const
export type VentanaGente = (typeof VENTANAS_GENTE)[number]

/** La que se abre: la semana elegida, igual que la pestaña Semana. */
export const VENTANA_POR_DEFECTO: VentanaGente = 'semana'

export const OPCIONES_DE_VENTANA: ReadonlyArray<{ value: VentanaGente; label: string }> = [
  { value: 'semana', label: 'La semana' },
  { value: '4', label: '4 semanas' },
  { value: '12', label: '12 semanas' },
  { value: 'inicio', label: 'Desde el inicio' },
]

/**
 * Cuántas semanas pide «desde el inicio». La base recorta el «desde» al
 * primer día con actividad, y su serie diaria no pasa de 366 días: con
 * cincuenta y dos semanas cabe entera. Cuando Ronda cumpla un año, «desde el
 * inicio» enseñará el último año (lo dice `textoDeLaVentana`).
 */
export const SEMANAS_DESDE_EL_INICIO = 52

function semanasDe(ventana: VentanaGente): number {
  if (ventana === 'semana') return 1
  if (ventana === 'inicio') return SEMANAS_DESDE_EL_INICIO
  return Number(ventana)
}

/**
 * Los días que se piden: del lunes de la primera semana de la ventana al
 * domingo de la elegida, sin pasar de hoy.
 */
export function rangoDeLaVentana(ventana: VentanaGente, lunes: string, hoy: string): Rango {
  const domingo = domingoDe(lunes)
  return {
    from: sumarDias(lunes, -7 * (semanasDe(ventana) - 1)),
    to: domingo < hoy ? domingo : hoy,
  }
}

/**
 * Contra qué se comparan las flechas, dicho una vez debajo de las cifras.
 * La base compara con la ventana anterior del mismo largo, corrida en
 * semanas enteras: con la semana a medias son los mismos días de la
 * anterior. Desde el inicio no hay con qué comparar: `null`.
 */
export function comparacionDeLaVentana(ventana: VentanaGente, aMedias: boolean): string | null {
  const altura = aMedias ? ', a la misma altura' : ''
  if (ventana === 'inicio') return null
  if (ventana === 'semana') return `Las flechas comparan con la semana anterior${altura}.`
  return `Las flechas comparan con las ${ventana} semanas anteriores${altura}.`
}

/**
 * La línea que dice qué días se están mirando, con los que USÓ la base (que
 * puede haber recortado el «desde» al primer día de Ronda o el «hasta» a
 * hoy): «Del 1 al 26 de septiembre de 2026 · 26 días».
 */
export function textoDeLaVentana(usado: Rango, dias: number): string {
  const rango = describirRango(usado)
  const mayuscula = rango.charAt(0).toUpperCase() + rango.slice(1)
  return `${mayuscula} · ${dias} ${dias === 1 ? 'día' : 'días'}`
}

/**
 * Si la ventana termina hoy y la semana va a medias, las cifras van a medias
 * también: la pantalla lo dice para que nadie compare una semana a medias
 * con una entera.
 */
export function ventanaAMedias(rango: Rango, lunes: string): boolean {
  return rango.to < domingoDe(lunes)
}
