/**
 * EL SITIO PÚBLICO — dirección, metadatos y lo que leen los buscadores.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * La dirección pública es `https://conhelios.com`, sin www (en Vercel, el
 * www redirige aquí). Es fija a propósito: el `canonical`, `og:url`, la
 * imagen para compartir y el sitemap apuntan siempre a producción, también
 * desde una vista previa o en local. `VITE_SITIO_URL` la cambia, si algún
 * día hace falta.
 *
 * Las páginas públicas (portada, soporte, legales) arman su `head` con
 * `cabeceraPublica`; las del panel llevan `NO_INDEXAR`.
 */

export const SITIO_URL = (import.meta.env.VITE_SITIO_URL || 'https://conhelios.com').replace(
  /\/+$/,
  '',
)

export const NOMBRE = 'Helios'

/** Los perfiles oficiales: el pie de la portada y el `sameAs` del JSON-LD. */
export const REDES = [
  { nombre: 'Instagram', url: 'https://www.instagram.com/helios.salud' },
] as const

/** 1200 × 630: lo que enseñan WhatsApp, Facebook, X y LinkedIn al compartir. */
export const IMAGEN_COMPARTIR = {
  ruta: '/compartir.jpg',
  ancho: 1200,
  alto: 630,
  alt: 'Helios — Tu salud hoy… Págala en dos cuotas.',
}

/** Las páginas que se le ofrecen al buscador (`/sitemap.xml`). */
export const PAGINAS_PUBLICAS = ['/', '/soporte', '/legal/terminos', '/legal/privacidad'] as const

export function urlAbsoluta(ruta: string): string {
  return `${SITIO_URL}${ruta === '/' ? '/' : ruta}`
}

/** El panel, el login y el superadmin no salen en Google. */
export const NO_INDEXAR = { meta: [{ name: 'robots', content: 'noindex, nofollow' }] }

/**
 * Título, descripción, canonical y tarjetas para compartir de una página
 * pública. El título va tal cual: cada página lo escribe completo.
 */
export function cabeceraPublica({
  titulo,
  descripcion,
  ruta,
}: {
  titulo: string
  descripcion: string
  ruta: (typeof PAGINAS_PUBLICAS)[number]
}) {
  const url = urlAbsoluta(ruta)
  const imagen = urlAbsoluta(IMAGEN_COMPARTIR.ruta)
  return {
    meta: [
      { title: titulo },
      { name: 'description', content: descripcion },
      { name: 'robots', content: 'index, follow, max-image-preview:large' },
      { property: 'og:type', content: 'website' },
      { property: 'og:site_name', content: NOMBRE },
      { property: 'og:locale', content: 'es_VE' },
      { property: 'og:url', content: url },
      { property: 'og:title', content: titulo },
      { property: 'og:description', content: descripcion },
      { property: 'og:image', content: imagen },
      { property: 'og:image:type', content: 'image/jpeg' },
      { property: 'og:image:width', content: String(IMAGEN_COMPARTIR.ancho) },
      { property: 'og:image:height', content: String(IMAGEN_COMPARTIR.alto) },
      { property: 'og:image:alt', content: IMAGEN_COMPARTIR.alt },
      { name: 'twitter:card', content: 'summary_large_image' },
      { name: 'twitter:title', content: titulo },
      { name: 'twitter:description', content: descripcion },
      { name: 'twitter:image', content: imagen },
    ],
    links: [{ rel: 'canonical', href: url }],
  }
}

/** JSON-LD listo para un `<script>`: sin `<` que pueda cerrar la etiqueta. */
export function jsonLd(datos: unknown) {
  return {
    type: 'application/ld+json',
    children: JSON.stringify(datos).replace(/</g, '\\u003c'),
  }
}
