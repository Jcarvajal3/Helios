import { createFileRoute } from '@tanstack/react-router'

import { PAGINAS_PUBLICAS, urlAbsoluta } from '@/config/sitio'
import { consultarDirectorio } from '@/features/directorio/api'
import { paginasPublicas } from '@/features/directorio/paginas'

/**
 * `/sitemap.xml` — las páginas públicas con la fecha de su último cambio, y
 * nada del panel. Google ignora `priority` y `changefreq`: no se ponen.
 *
 * Además de las fijas (`PAGINAS_PUBLICAS`), las del directorio que salen de
 * la base (2026-10-30): una por especialidad con médicos y una por médico
 * publicado, con la fecha del último cambio de su tarjeta. Un médico nuevo
 * entra solo; uno que deja de salir, sale solo. Si la base no contesta, el
 * sitemap sale con las fijas: mejor eso que un error.
 */
export const Route = createFileRoute('/sitemap.xml')({
  server: {
    handlers: {
      GET: async () => {
        const medicos = await consultarDirectorio().catch(() => [])
        const urls = paginasPublicas(PAGINAS_PUBLICAS, medicos)
          .map(
            ({ ruta, actualizada }) =>
              `  <url><loc>${urlAbsoluta(ruta)}</loc>${actualizada ? `<lastmod>${actualizada}</lastmod>` : ''}</url>`,
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
