import { createFileRoute } from '@tanstack/react-router'

import { PAGINAS_PUBLICAS, urlAbsoluta } from '@/config/sitio'

/** `/sitemap.xml` — las páginas públicas, y nada del panel. */
export const Route = createFileRoute('/sitemap.xml')({
  server: {
    handlers: {
      GET: () => {
        const urls = PAGINAS_PUBLICAS.map(
          (ruta) => `  <url><loc>${urlAbsoluta(ruta)}</loc></url>`,
        ).join('\n')
        return new Response(
          `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`,
          {
            headers: {
              'Content-Type': 'application/xml; charset=utf-8',
              'Cache-Control': 'public, max-age=3600',
            },
          },
        )
      },
    },
  },
})
