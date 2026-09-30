/**
 * Los espacios de trabajo del super admin: uno por equipo.
 *
 * Son una forma de ordenar Inicio y el catálogo y de dar tono a cada
 * pantalla, NO permisos. Los roles siguen siendo `super_admin` y `operador`,
 * y cualquiera puede abrir cualquier pantalla.
 *
 * El menú ya no tiene un bloque por espacio (`config/navigation.ts`): Cobranza
 * y Riesgo comparten «Cobranza y riesgo», y Gerencia no tiene bloque porque su
 * análisis vive en Métricas. Los cuatro siguen existiendo como tonos (el
 * violeta de Riesgo en Verificaciones y Alertas, el rosa de Gerencia en las
 * pestañas de Métricas que eran suyas) y como rótulos de Inicio, que no cambia.
 */
export type Espacio = 'cobranza' | 'caja' | 'riesgo' | 'gerencia'

export type DefinicionEspacio = {
  id: Espacio
  rotulo: string
  /** Posición en el menú y en Inicio. */
  orden: number
}

export const ESPACIOS: ReadonlyArray<DefinicionEspacio> = [
  { id: 'cobranza', rotulo: 'Cobranza', orden: 1 },
  { id: 'caja', rotulo: 'Caja y contabilidad', orden: 2 },
  { id: 'riesgo', rotulo: 'Riesgo', orden: 3 },
  { id: 'gerencia', rotulo: 'Gerencia', orden: 4 },
]

/** Los cuatro espacios, en el orden del menú. */
export const TODOS_LOS_ESPACIOS: ReadonlyArray<Espacio> = [...ESPACIOS]
  .sort((a, b) => a.orden - b.orden)
  .map((e) => e.id)

export function rotuloDeEspacio(espacio: Espacio): string {
  return ESPACIOS.find((e) => e.id === espacio)?.rotulo ?? espacio
}
