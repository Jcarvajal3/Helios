import { createFileRoute } from '@tanstack/react-router'

import { urlAbsoluta } from '@/config/sitio'

/**
 * `/robots.txt` — todo se puede rastrear. Las pantallas del panel no se
 * bloquean aquí: llevan `noindex` (`NO_INDEXAR`), y un buscador solo lo ve si
 * puede entrar a leerlo.
 */
export const Route = createFileRoute('/robots.txt')({
  server: {
    handlers: {
      GET: () =>
        new Response(`User-agent: *\nAllow: /\n\nSitemap: ${urlAbsoluta('/sitemap.xml')}\n`, {
          headers: {
            'Content-Type': 'text/plain; charset=utf-8',
            'Cache-Control': 'public, max-age=3600',
          },
        }),
    },
  },
})
