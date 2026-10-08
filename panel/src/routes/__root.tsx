import { HeadContent, Scripts, createRootRoute } from '@tanstack/react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { useState } from 'react'

import { initSentry } from '@/lib/sentry'
import { SCRIPT_DEL_TEMA } from '@/lib/tema'

import appCss from '../styles.css?url'

const FUENTES_DEL_PANEL =
  'https://fonts.googleapis.com/css2?family=Outfit:wght@400;500;600;700;900&family=Source+Sans+3:wght@400;500;600;700&display=swap'

// Antes de pintar nada, para que un fallo del primer render también llegue.
initSentry()

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: 'utf-8' },
      { name: 'viewport', content: 'width=device-width, initial-scale=1' },
      { title: 'Helios' },
      // El color de la barra del navegador en el móvil: el del lienzo claro.
      { name: 'theme-color', content: '#F3F6FB' },
    ],
    links: [
      // En la pestaña el icono mide 16 px, y ahí el logotipo entero es una
      // mancha: va el isotipo, que se lee a ese tamaño.
      { rel: 'icon', type: 'image/svg+xml', href: '/icon.svg' },
      { rel: 'apple-touch-icon', href: '/apple-touch-icon.png' },
      { rel: 'preconnect', href: 'https://fonts.googleapis.com' },
      { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossOrigin: 'anonymous' },
      // Las fuentes del panel. Antes eran un `@import` dentro de styles.css, y
      // el navegador no las pedía hasta tener esa hoja: una ida y vuelta más
      // antes de pintar, también en la portada, que ni las usa.
      { rel: 'stylesheet', href: FUENTES_DEL_PANEL },
      { rel: 'stylesheet', href: appCss },
    ],
    // El tema guardado, antes de pintar: sin esto el oscuro parpadea en claro.
    scripts: [{ children: SCRIPT_DEL_TEMA }],
  }),
  shellComponent: RootDocument,
})

function RootDocument({ children }: { children: React.ReactNode }) {
  // El cliente se crea dentro del componente para que cada petición del
  // servidor tenga el suyo: uno a nivel de módulo se compartiría entre
  // usuarios distintos en SSR.
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            // El panel queda abierto en la recepción toda la jornada.
            // Reintentar en bucle contra una red caída solo llena la consola.
            retry: 1,
            refetchOnWindowFocus: false,
          },
        },
      }),
  )

  return (
    // `suppressHydrationWarning`: el script del tema pone `data-theme` en <html>
    // antes de que React hidrate, y ese atributo no sale del servidor.
    <html lang="es" suppressHydrationWarning>
      <head>
        <HeadContent />
      </head>
      <body>
        <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
        <Scripts />
      </body>
    </html>
  )
}
