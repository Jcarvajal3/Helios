import { createFileRoute } from '@tanstack/react-router'

import { PAGINAS_PUBLICAS, urlAbsoluta } from '@/config/sitio'

/**
 * `/sitemap.xml` — las páginas públicas con la fecha de su último cambio, y
 * nada del panel. Google ignora `priority` y `changefreq`: no se ponen.
 */
export const Route = createFileRoute('/sitemap.xml')({
  server: {
    handlers: {
      GET: () => {
        const urls = Object.entries(PAGINAS_PUBLICAS)
          .map(
            ([ruta, { actualizada }]) =>
              `  <url><loc>${urlAbsoluta(ruta)}</loc><lastmod>${actualizada}</lastmod></url>`,
          )
          .join('\n')
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
