import { HeadContent, Scripts, createRootRoute } from '@tanstack/react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { useState } from 'react'

import { initSentry } from '@/lib/sentry'
import { SCRIPT_DEL_TEMA } from '@/lib/tema'

import appCss from '../styles.css?url'

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
      // El de respaldo, en PNG: el que usan Google (junto al resultado) y los
      // navegadores sin SVG. Google pide múltiplos de 48 px.
      { rel: 'icon', type: 'image/png', sizes: '512x512', href: '/icon-512.png' },
      { rel: 'apple-touch-icon', href: '/apple-touch-icon.png' },
      { rel: 'preconnect', href: 'https://fonts.googleapis.com' },
      { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossOrigin: 'anonymous' },
      // Las fuentes no van aquí: cada ruta pide las suyas (`lib/fuentes.ts`).
      // Así la portada no descarga las del panel, que bloqueaban su primer
      // pintado sin usarlas.
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
    <html lang="es-VE" suppressHydrationWarning>
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
