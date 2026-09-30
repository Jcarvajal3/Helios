import { useEffect, useState } from 'react'

/**
 * ¿Se cumple esta consulta de medios ahora mismo?
 *
 * Lo normal en este panel es NO llamar a esto: una diferencia de tamaño se
 * resuelve con clases —`lg:`, o mejor, con una consulta de contenedor— y así
 * sale ya bien del render del servidor, sin un fotograma de la medida
 * equivocada. Esto es para lo que CSS no puede decir: un atributo del DOM que
 * depende del ancho.
 *
 * El caso que lo trajo: la barra lateral es un cajón por debajo de 1024 px y,
 * cerrada, se aparta con `translate-x`. Apartada no se ve, pero sigue estando
 * — el tabulador entra en sus seis enlaces y un lector de pantalla los
 * anuncia. En la tablet del local eso es una fila de enlaces invisibles entre
 * el menú y el contenido. `inert` lo arregla, pero `inert` es un atributo y
 * tiene que saber si hoy la barra es un cajón o es la barra fija.
 *
 * Arranca en `false` SIEMPRE, también en el navegador: esto se renderiza en el
 * servidor, donde no hay `matchMedia`, y sembrar el estado con la respuesta
 * buena solo en el cliente es exactamente lo que rompe la hidratación. El
 * valor de verdad entra en el primer efecto.
 */
export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(false)

  useEffect(() => {
    const mql = window.matchMedia(query)
    setMatches(mql.matches)

    const onChange = (event: MediaQueryListEvent) => setMatches(event.matches)
    mql.addEventListener('change', onChange)
    return () => mql.removeEventListener('change', onChange)
  }, [query])

  return matches
}

/**
 * El umbral del cajón, dicho una sola vez.
 *
 * Es el `lg` de Tailwind, que es el que usan la barra, el marco y el
 * esqueleto de carga. Cuando esto y las clases decían cosas distintas, la
 * pantalla daba un salto lateral justo al terminar de cargar.
 */
export const ES_CAJON = '(max-width: 1023.98px)'
