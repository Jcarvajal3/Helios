import { createFileRoute } from '@tanstack/react-router'

import { urlAbsoluta } from '@/config/sitio'

/**
 * `/robots.txt` — todo se puede rastrear. Las pantallas del panel no se
 * bloquean aquí: llevan `noindex` (`NO_INDEXAR`), y un buscador solo lo ve si
 * puede entrar a leerlo. Solo se cierra `/plantillas/`, que son archivos de
 * trabajo (el pago masivo del banco) y no páginas.
 */
export const Route = createFileRoute('/robots.txt')({
  server: {
    handlers: {
      GET: () =>
        new Response(
          `User-agent: *\nAllow: /\nDisallow: /plantillas/\n\nSitemap: ${urlAbsoluta('/sitemap.xml')}\n`,
          {
            headers: {
              'Content-Type': 'text/plain; charset=utf-8',
              'Cache-Control': 'public, max-age=3600',
            },
          },
        ),
    },
  },
})
