import type { ItemDeMenu } from '@/components/ui'

/** Un hueco de la lista: un ítem, un separador, o nada (la acción no aplica). */
export type HuecoDeMenu = ItemDeMenu | 'separador' | null | false | undefined

/**
 * Los ítems del «⋯» de una ficha, ya limpios.
 *
 * Cada ficha arma su menú con acciones que dependen del estado —un expulsado
 * no se vuelve a expulsar, un pendiente no se revierte—, así que la lista
 * llega con huecos. Aquí se quitan, y con ellos los separadores que se quedan
 * sin nada a un lado: una raya al principio, al final o dos seguidas es un
 * grupo vacío que no significa nada.
 */
export function itemsDeMenu(
  huecos: ReadonlyArray<HuecoDeMenu>,
): Array<ItemDeMenu | 'separador'> {
  const salida: Array<ItemDeMenu | 'separador'> = []
  for (const hueco of huecos) {
    if (!hueco) continue
    if (hueco === 'separador' && (salida.length === 0 || salida.at(-1) === 'separador')) continue
    salida.push(hueco)
  }
  if (salida.at(-1) === 'separador') salida.pop()
  return salida
}

/** Los datos de una cabecera en una línea: «V-12.345.678 · Caracas». Sin huecos. */
export function lineaDeDatos(datos: ReadonlyArray<string | null | undefined | false>): string {
  return datos.filter((d): d is string => typeof d === 'string' && d.trim() !== '').join(' · ')
}
