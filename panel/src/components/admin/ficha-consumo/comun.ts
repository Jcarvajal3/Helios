/** Dos decimales, para que las líneas de un desglose cierren entre sí. */
export function redondear(valor: number): number {
  return Math.round(valor * 100) / 100
}
