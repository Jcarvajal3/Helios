import { useMatches } from '@tanstack/react-router'
import type { StaticDataRouteOption } from '@tanstack/react-router'

/**
 * Cuánto se deja crecer al contenido de una pantalla.
 *
 *   wide    lo que se escanea: una tabla, un tablero. Tope alto, porque aquí
 *           el ancho es lo que evita el scroll horizontal.
 *   ficha   una ficha: lo que se lee y, a la derecha, un carril con el
 *           resumen y las acciones. A 960 dejaba 240 px vacíos al lado.
 *   normal  lo que se lee y se rellena. La medida de una columna de texto
 *           cómoda con sitio para una segunda al lado.
 */
export type PageWidth = 'wide' | 'ficha' | 'normal'

declare module '@tanstack/react-router' {
  interface StaticDataRouteOption {
    /**
     * Lo que dice la barra de arriba, y la pestaña del navegador.
     *
     * Vive en la ruta y no en la pantalla a propósito. Cuando lo pintaba la
     * pantalla, cada una tenía que acordarse de hacerlo en sus tres ramas
     * —cargando, error y contenido—. Aquí no se puede olvidar, y además sale
     * ya en el HTML del servidor.
     */
    title?: string
    /** Por defecto 'normal'. */
    width?: PageWidth
    /**
     * La pantalla es su propia cabecera: la barra de arriba se queda sin
     * título, buscador, botón del asistente ni borde, y solo conserva el botón
     * que abre el menú por debajo de 1024 px. El contenido ocupa todo el alto.
     * La usa Inicio, cuya barra del asistente ya es título y buscador.
     */
    inmersiva?: boolean
  }
}

/** Lo que el marco lee de la ruta que se está viendo. */
export type MarcoDeLaRuta = { title: string; width: PageWidth; inmersiva: boolean }

/**
 * El título, el ancho y el modo de la pantalla que se está viendo.
 *
 * Gana la última coincidencia que los declare: una ruta hija siempre manda
 * sobre su padre.
 *
 * Son tres lecturas y no una que devuelva el objeto porque el selector se
 * compara con Object.is: un objeto nuevo en cada lectura nunca es igual al
 * anterior y el marco entero se repintaría con cada movimiento del store del
 * router. Tres valores sueltos sí se comparan bien.
 */
export function useMarcoDeLaRuta(): MarcoDeLaRuta {
  const title = useMatches({ select: (matches) => ultimo(matches, 'title') ?? '' })
  const width = useMatches({ select: (matches) => ultimo(matches, 'width') ?? 'normal' })
  const inmersiva = useMatches({ select: (matches) => ultimo(matches, 'inmersiva') ?? false })
  return { title, width, inmersiva }
}

function ultimo<TCampo extends keyof StaticDataRouteOption>(
  matches: ReadonlyArray<{ staticData: StaticDataRouteOption }>,
  campo: TCampo,
): StaticDataRouteOption[TCampo] | undefined {
  for (let i = matches.length - 1; i >= 0; i -= 1) {
    const valor = matches[i].staticData[campo]
    if (valor !== undefined) return valor
  }
  return undefined
}
