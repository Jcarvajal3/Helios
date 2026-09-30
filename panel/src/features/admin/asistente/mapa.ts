import type { Entrada, Pantalla } from '@/features/admin/catalogo'
import { FICHAS } from './enlaces'

// ═══════════════════════════════════════════════════════════════════════════
// El mapa de pantallas que lee la función `admin-asistente` (`mapa.json`).
//
// Sale del catálogo del panel para que el asistente y el menú hablen con los
// mismos nombres y las mismas rutas: una pantalla renombrada aquí se renombra
// allí al volver a generar el archivo (`npm run asistente:mapa`). La forma es
// la que lee `leerMapa` en la función (`admin-asistente/mapa.ts`). Puro, para
// probarlo en `mapa.test.ts`; el script solo lo escribe.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Los valores que admite cada parámetro de la URL de una pantalla. La función
 * rechaza un enlace con un parámetro o un valor que no esté aquí, y el modelo
 * corrige. `null` sería «cualquier texto»; el catálogo solo da listas.
 */
export type SearchDelMapa = Record<string, string[] | null>

export type PantallaDelMapa = {
  id: string
  titulo: string
  descripcion: string
  ruta: string
  espacio: string
  search: SearchDelMapa
}

export type CifraDelMapa = {
  id: string
  titulo: string
  que: string
  rpc: string
  /** El id de la pantalla donde se ve, o `null` si ninguna del catálogo es suya. */
  pantalla: string | null
}

export type FichaDelMapa = { id: string; titulo: string; ruta: string }

export type Mapa = {
  version: 1
  /** `false`: este es el generado, no el provisional escrito a mano. */
  regenerar: false
  pantallas: PantallaDelMapa[]
  fichas: FichaDelMapa[]
  cifras: CifraDelMapa[]
}

/** Un valor de `search` como texto, que es como viaja en un enlace. */
function comoTexto(v: unknown): string | null {
  if (typeof v === 'string') return v
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return null
}

/**
 * Los parámetros que el catálogo usa para una ruta y sus valores, sin
 * repetir y en orden. Es lo más parecido a «qué filtros acepta» que se puede
 * sacar sin ejecutar el `validateSearch` de la ruta: solo lo que alguna
 * entrada del catálogo ya enlaza.
 */
function searchDeLaRuta(ruta: string, catalogo: ReadonlyArray<Entrada>): SearchDelMapa {
  const valores = new Map<string, Set<string>>()
  for (const e of catalogo) {
    if (e.destino.to !== ruta || !e.destino.search) continue
    for (const [clave, v] of Object.entries(e.destino.search)) {
      const t = comoTexto(v)
      if (t === null) continue
      const vistos = valores.get(clave) ?? new Set<string>()
      vistos.add(t)
      valores.set(clave, vistos)
    }
  }
  return Object.fromEntries(
    [...valores.entries()]
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([clave, vistos]) => [clave, [...vistos].sort()]),
  )
}

/** La pantalla dueña de una ruta: la primera del catálogo con ella. */
function pantallaDeLaRuta(ruta: string, pantallas: ReadonlyArray<Pantalla>): Pantalla | null {
  return pantallas.find((p) => p.destino.to === ruta) ?? null
}

export function construirMapa(catalogo: ReadonlyArray<Entrada>): Mapa {
  const pantallas = catalogo.filter((e): e is Pantalla => e.tipo === 'pantalla')

  return {
    version: 1,
    regenerar: false,
    pantallas: pantallas.map((p) => ({
      id: p.id,
      titulo: p.titulo,
      descripcion: p.descripcion,
      ruta: p.destino.to,
      espacio: p.espacio,
      search: searchDeLaRuta(p.destino.to, catalogo),
    })),
    fichas: FICHAS.map((f) => ({ id: f.id, titulo: f.titulo, ruta: f.ruta })),
    cifras: catalogo.flatMap((e) =>
      e.tipo === 'cifra'
        ? [
            {
              id: e.id,
              titulo: e.titulo,
              que: e.que,
              rpc: e.rpc,
              pantalla: pantallaDeLaRuta(e.destino.to, pantallas)?.id ?? null,
            },
          ]
        : [],
    ),
  }
}
