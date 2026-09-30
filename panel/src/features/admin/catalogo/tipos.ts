import type { LucideIcon } from 'lucide-react'

import type { FileRoutesByTo } from '@/routeTree.gen'
import type { Espacio } from '@/features/admin/espacios'

/**
 * Las rutas fijas del super admin, sacadas del árbol que genera TanStack
 * Router. Una ruta mal escrita, o una que se borra, deja de compilar. Las de
 * detalle (`/admin/pacientes/$id`) no entran: el catálogo no apunta a una ficha
 * concreta.
 */
export type RutaAdmin = Exclude<
  Extract<keyof FileRoutesByTo, '/admin' | `/admin/${string}`>,
  `${string}$${string}`
>

/** Lo que devuelve el `validateSearch` de esa ruta. */
type BusquedaDe<TRuta extends RutaAdmin> = FileRoutesByTo[TRuta]['types']['searchSchema']

/**
 * Adónde lleva una entrada: la ruta y, si hace falta, sus parámetros.
 *
 * Es una unión por ruta, así que `search` se comprueba contra el
 * `validateSearch` de ESA ruta: `{ to: '/admin/ajustes', search: { tab: 'x' } }`
 * no compila si `x` no es una pestaña de Ajustes. Se le pasa tal cual a
 * `<Link {...destino}>` o a `navigate(destino)`.
 */
export type Destino = {
  [TRuta in RutaAdmin]: { to: TRuta; search?: BusquedaDe<TRuta> }
}[RutaAdmin]

/**
 * Dónde vive una entrada. Los cuatro espacios de trabajo, más los sitios fijos
 * que no son de ningún equipo: Inicio y Métricas arriba, Directorio y Ajustes
 * al final. Métricas es de todos: cada pestaña lleva el tono de su área, pero
 * la pantalla es neutra.
 */
export type Ambito = Espacio | 'inicio' | 'metricas' | 'directorio' | 'ajustes'

/** Lo que llevan todas las entradas del catálogo. */
type Comun = {
  /** Único en todo el catálogo. En kebab-case y en español. */
  id: string
  /** El nombre que se pinta. En una pantalla, es el rótulo del menú. */
  titulo: string
  /** Una línea: qué es o qué hace. La lee quien busca. */
  descripcion: string
  espacio: Ambito
  /**
   * Otras formas de decirlo: lo que alguien teclearía buscándolo. Incluye los
   * nombres viejos («cobros», «cartera») y el vocabulario que la interfaz ya
   * no usa pero la gente sí («estado de cuenta», «castigado»).
   */
  sinonimos: ReadonlyArray<string>
  destino: Destino
}

/** Una pantalla del menú. */
export type Pantalla = Comun & {
  tipo: 'pantalla'
  icono: LucideIcon
}

/** Algo que se hace: un botón con consecuencias, en la pantalla de `destino`. */
export type Accion = Comun & {
  tipo: 'accion'
  /** El operador la ve apagada, con el motivo escrito. */
  soloSuperAdmin?: boolean
}

/** Un número que el panel enseña. */
export type Cifra = Comun & {
  tipo: 'cifra'
  /** Qué es, en una frase completa. Es lo que dice su InfoDot. */
  que: string
  /** La función de la base de la que sale. */
  rpc: string
}

/** Una palabra del negocio, con su definición. */
export type Termino = Comun & {
  tipo: 'termino'
  definicion: string
}

export type Entrada = Pantalla | Accion | Cifra | Termino

export type TipoEntrada = Entrada['tipo']
