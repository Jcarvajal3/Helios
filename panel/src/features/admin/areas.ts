import { PANTALLAS } from '@/features/admin/catalogo'
import type { Ambito } from '@/features/admin/catalogo'
import { TODOS_LOS_ESPACIOS } from '@/features/admin/espacios'
import type { Espacio } from '@/features/admin/espacios'

/**
 * El tono de cada sitio del super admin.
 *
 * Los cuatro espacios de trabajo llevan un color propio que orienta —el menú,
 * los iconos de Inicio, la serie principal de un gráfico— y los sitios que no
 * son de ningún equipo (Inicio, Métricas, Directorio y Ajustes) van en
 * neutro. Métricas es neutra como pantalla y cada pestaña se pone el tono de
 * su área sobre sí misma (`features/admin/metricas/pestanas.ts`).
 * El valor es lo que se escribe en `data-area`: el CSS de `styles.css`
 * convierte ese atributo en `var(--area)`.
 */
export type TonoDeArea = Espacio | 'neutro'

function esEspacio(ambito: Ambito): ambito is Espacio {
  return TODOS_LOS_ESPACIOS.some((e) => e === ambito)
}

export function tonoDeAmbito(ambito: Ambito): TonoDeArea {
  return esEspacio(ambito) ? ambito : 'neutro'
}

const INICIO = '/admin'

/** Cada pantalla del catálogo con la ruta de la que cuelga, la más larga primero. */
const PREFIJOS: ReadonlyArray<{ ruta: string; ambito: Ambito }> = PANTALLAS.map((p) => ({
  ruta: p.destino.to,
  ambito: p.espacio,
})).sort((a, b) => b.ruta.length - a.ruta.length)

/**
 * El ámbito de una ruta del super admin, o `null` si no es del super admin.
 *
 * Sale del catálogo, así que una pantalla nueva no hay que darla de alta en
 * dos sitios. Una ficha hereda el de su lista (`/admin/pacientes/x` es de
 * Directorio) y una ruta que no cuelga de ninguna pantalla conocida, pero sí
 * del super admin, se queda en Inicio.
 */
export function ambitoDeRuta(pathname: string): Ambito | null {
  const ruta = pathname.length > 1 ? pathname.replace(/\/+$/, '') : pathname
  if (ruta !== INICIO && !ruta.startsWith(`${INICIO}/`)) return null

  for (const p of PREFIJOS) {
    if (p.ruta === INICIO) continue
    if (ruta === p.ruta || ruta.startsWith(`${p.ruta}/`)) return p.ambito
  }
  return 'inicio'
}

/** El tono de una ruta: lo que el marco escribe en `data-area` de `<main>`. */
export function tonoDeRuta(pathname: string): TonoDeArea {
  const ambito = ambitoDeRuta(pathname)
  return ambito === null ? 'neutro' : tonoDeAmbito(ambito)
}
