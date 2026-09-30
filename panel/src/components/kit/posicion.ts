// ═══════════════════════════════════════════════════════════════════════════
// Dónde se pinta lo que flota junto a su disparador.
//
// Pura para poder probarla: recibe las medidas y devuelve la esquina de arriba
// a la izquierda en coordenadas de la ventana, porque la capa va en
// `position: fixed`. Así no depende de qué contenedor desplaza.
// ═══════════════════════════════════════════════════════════════════════════

export type LadoFlotante = 'arriba' | 'abajo'
export type AlineacionFlotante = 'inicio' | 'centro' | 'fin'

/** Lo que hace falta de un `DOMRect`. */
export type CajaDelAncla = { top: number; left: number; width: number; height: number }

export type Posicion = { top: number; left: number; lado: LadoFlotante }

/** Lo que se deja libre hasta el borde de la ventana. */
export const MARGEN_DE_BORDE = 8

function limitar(valor: number, minimo: number, maximo: number): number {
  // Si la capa es más grande que la ventana, manda el borde de arriba o de la
  // izquierda: es donde empieza a leerse.
  if (maximo < minimo) return minimo
  return Math.min(Math.max(valor, minimo), maximo)
}

/**
 * La posición de la capa.
 *
 * Se da la vuelta solo si en su lado no cabe y en el otro sí; si no cabe en
 * ninguno, se queda en el suyo y se pega al borde. En horizontal se desplaza
 * lo justo para no salirse, sin dejar de estar junto al disparador.
 */
export function calcularPosicion({
  ancla,
  capa,
  vista,
  lado,
  alineacion,
  separacion,
  margen = MARGEN_DE_BORDE,
}: {
  ancla: CajaDelAncla
  capa: { ancho: number; alto: number }
  vista: { ancho: number; alto: number }
  lado: LadoFlotante
  alineacion: AlineacionFlotante
  separacion: number
  margen?: number
}): Posicion {
  const topArriba = ancla.top - separacion - capa.alto
  const topAbajo = ancla.top + ancla.height + separacion
  const cabeArriba = topArriba >= margen
  const cabeAbajo = topAbajo + capa.alto <= vista.alto - margen

  let final: LadoFlotante = lado
  if (lado === 'abajo' && !cabeAbajo && cabeArriba) final = 'arriba'
  if (lado === 'arriba' && !cabeArriba && cabeAbajo) final = 'abajo'

  const top = limitar(
    final === 'abajo' ? topAbajo : topArriba,
    margen,
    vista.alto - margen - capa.alto,
  )

  const izquierda =
    alineacion === 'inicio'
      ? ancla.left
      : alineacion === 'fin'
        ? ancla.left + ancla.width - capa.ancho
        : ancla.left + ancla.width / 2 - capa.ancho / 2
  const left = limitar(izquierda, margen, vista.ancho - margen - capa.ancho)

  return { top: Math.round(top), left: Math.round(left), lado: final }
}
