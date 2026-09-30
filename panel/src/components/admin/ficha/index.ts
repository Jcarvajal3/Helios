/*
 * El patrón de las fichas (persona, local, consumo, pago reportado): la
 * cabecera con la identidad y el «⋯», y dos columnas, lo que se lee y el
 * carril con el resumen y las acciones.
 */
export { MarcoDeFicha } from './MarcoDeFicha'
export { CabeceraDeFicha } from './CabeceraDeFicha'
export { AccionesDeFicha, ResumenDeFicha } from './CarrilDeFicha'
export type { CifraDeFicha } from './CarrilDeFicha'
export { itemsDeMenu, lineaDeDatos } from './menu'
export type { HuecoDeMenu } from './menu'
export { VolverA } from './VolverA'
export { useVolverDeFicha } from './origen'
