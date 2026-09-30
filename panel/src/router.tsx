import { createRouter as createTanStackRouter } from '@tanstack/react-router'
import { routeTree } from './routeTree.gen'

import { PantallaRota } from '@/components/PantallaRota'
import { apuntarOrigenesDeFichas } from '@/components/admin/ficha/origen'
import { reportarError } from '@/lib/sentry'

/**
 * El scroll solo se toca al cambiar de PANTALLA, no al cambiar la búsqueda.
 *
 * Casi todos los filtros, pestañas y órdenes del panel viven en la URL
 * (`?vista=`, `?orden=`, `?cuota=`…), y el router trata cada cambio como una
 * navegación: volvía a la parte de arriba y quien estaba mirando una tabla a
 * media página perdía el sitio. Con la misma ruta, el scroll se queda donde
 * está; con otra, se restaura o vuelve arriba como siempre.
 *
 * El router llama a esto una vez por navegación ya pintada, así que la ruta
 * anterior es la última que se vio.
 */
let rutaVista: string | null = null
function restaurarScroll({ location }: { location: { pathname: string } }): boolean {
  const otraPantalla = rutaVista !== location.pathname
  rutaVista = location.pathname
  return otraPantalla
}

export function getRouter() {
  const router = createTanStackRouter({
    routeTree,
    scrollRestoration: restaurarScroll,
    defaultPreload: 'intent',
    defaultPreloadStaleTime: 0,
    defaultErrorComponent: PantallaRota,
    defaultOnCatch: (error, info) => reportarError(error, { componentStack: info.componentStack }),
  })

  // Cada ficha apunta de qué pantalla se abrió, para que su «volver» lleve
  // allí y no a una lista fija.
  apuntarOrigenesDeFichas(router)

  return router
}

declare module '@tanstack/react-router' {
  interface Register {
    router: ReturnType<typeof getRouter>
  }
}
